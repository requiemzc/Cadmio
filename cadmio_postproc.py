"""
cadmio_postproc.py — Post-procesamiento integrado para el bot .l

Pipeline que se aplica SIEMPRE sobre la salida de catlog.luau:

    catlog output (obfuscated Lua)
        |
        v
    minify_lua()        -> strip comments + redundant whitespace
        |
        v
    cadmio_lz_compress()-> LZSS-style compression (pure-Python)
        |
        v
    zstd_raw_wrap()     -> wrap LZ bytes in a real zstd frame
                          (raw blocks only => pure-Luau decodable)
        |
        v
    build_bootstrap()   -> emit self-contained Lua bootstrap with
                          inline pure-Luau zstd raw-block decoder +
                          inline Cadmio-LZ decompressor + loadstring()

El bootstrap resultante:
  * Comienza con el código Luau del decoder (sin dependencias)
  * Termina con la cadena comprimida como literal Lua
  * Se puede ejecutar directamente en Roblox/Delta (sin zstd API nativa)

Uso desde bot.py:

    from cadmio_postproc import build_bootstrap
    final_lua = build_bootstrap(obfuscated_lua_source)
"""

from __future__ import annotations
import re
import struct
import zlib

# ---------------------------------------------------------------------------
# 1) MINIFY (Lua 5.1 / Luau)
# ---------------------------------------------------------------------------

# Tokens que no queremos romper: palabras clave + operadores compuestos
_LONG_TOKEN_RE = re.compile(
    r"""
    (?:--\[\[.*?\]\])                   # long comment
    | (?:--[^\n]*)                       # line comment
    | (?:\[\[[^\]]*\]\])                 # long string [[...]]
    | (?:"(?:\\.|[^"\\])*")             # double-quoted string
    | (?:'(?:\\.|[^'\\])*')             # single-quoted string
    | (?:\[(=*)\[[\s\S]*?\]\1\])         # [==[ long string ]==]
    | \.\.\.                             # vararg (3-char op)
    | (?:::|==|~=|<=|>=|\.\.|\->|\+=|-=|\*=|/=|%=|\^=|\.\.=|\*\*|//|<<|>>|\^\^)  # 2-char ops
    | [A-Za-z_][A-Za-z0-9_]*             # identifier
    | \d+(?:\.\d+)?(?:[eE][+-]?\d+)?     # number
    | [^\sA-Za-z0-9_]                    # single non-alnum punctuation
    | \s+                                # whitespace (catch-all)
    """,
    re.VERBOSE | re.DOTALL,
)

# Operadores de 2 y 3 caracteres que NO deben separarse (token gluing)
_TWO_CHAR_OPS = {
    "==", "~=", "<=", ">=", "..", "::", "..", "->", "+=", "-=",
    "*=", "/=", "%=", "^=", "..=", "**", "//", "<<", ">>", "^^",
}
_THREE_CHAR_OPS = {"...", "..="}

# Caracteres que necesitan espacio a ambos lados para no unirse con identificadores
_NEEDS_SPACE = re.compile(r"^[A-Za-z0-9_]")


def _tokenize_lua(src: str):
    """Yield (kind, text) tuples. kind ∈ {'ws','comment','string','ident','num','punct'}"""
    pos = 0
    n = len(src)
    while pos < n:
        m = _LONG_TOKEN_RE.match(src, pos)
        if not m:
            # fallback: emit single char
            yield ("punct", src[pos])
            pos += 1
            continue
        tok = m.group(0)
        pos = m.end()
        if tok.startswith("--"):
            yield ("comment", tok)
        elif tok.startswith("["):
            yield ("string", tok)
        elif tok.startswith('"') or tok.startswith("'"):
            yield ("string", tok)
        elif tok[0].isspace():
            yield ("ws", tok)
        elif tok[0].isalpha() or tok[0] == "_":
            yield ("ident", tok)
        elif tok[0].isdigit():
            yield ("num", tok)
        else:
            yield ("punct", tok)


def minify_lua(src: str) -> str:
    """
    Minify a Lua/Luau source by removing comments, collapsing whitespace,
    and stripping unnecessary spaces between tokens. Returns valid Lua
    that is functionally equivalent.

    Conservative: never joins two identifier-like tokens (would create
    a single identifier), never strips space after `not`/`and`/`or`.
    """
    out = []
    prev = ""        # last emitted non-whitespace text
    prev_kind = ""   # kind of that token
    # Pre-compute the set of 2-char operator combinations to guard against
    # token gluing at punctuation boundaries (e.g., `.` + `..` => `...`).
    _DANGEROUS_PAIRS = {
        ("-", "-"), ("-", "="), ("~", "="), ("=", "="), ("<", "="),
        (">", "="), (".", "."), (":", ":"), ("<", "<"), (">", ">"),
        ("/", "/"), ("^", "^"), ("*", "*"), ("+", "="), ("-", "="),
        ("*", "="), ("/", "="), ("%", "="), ("^", "="),
    }

    for kind, tok in _tokenize_lua(src):
        if kind == "comment":
            continue
        if kind == "ws":
            continue
        # Decide if we need a single space before this token.
        if prev:
            prev_id_like = prev_kind in ("ident", "num")
            cur_id_like = kind in ("ident", "num")
            # Two identifier-like tokens => need space
            if prev_id_like and cur_id_like:
                out.append(" ")
            # Word keyword followed by an identifier-like token (e.g., "not x",
            # "and y") — handled by prev_id_like since keywords are idents here.
            # Prevent operator gluing at punct boundaries:
            elif (prev_kind == "punct" and kind == "punct"
                  and (prev[-1], tok[0]) in _DANGEROUS_PAIRS):
                out.append(" ")
            # Also: identifier followed by `-` could be ambiguous (a-b vs a -b)
            # Lua's parser handles this, but be safe:
            elif prev_id_like and tok.startswith("-"):
                # `foo-bar` is parsed as `foo - bar`? No: in Lua `-` is unary
                # or binary minus, never part of an identifier. So `foo-bar`
                # would parse as `foo - bar`. To avoid ambiguity, insert space.
                out.append(" ")
        out.append(tok)
        prev = tok
        prev_kind = kind
    return "".join(out)


# ---------------------------------------------------------------------------
# 2) CADMIO-LZ (LZSS-style compression, pure-Luau decodeable)
# ---------------------------------------------------------------------------
# Custom format: byte-aligned, simple, ~100 lines pure-Luau decoder.
#
# Layout:
#   bytes 0..3   : magic 'C','Z','L','Z' (Cadmio-Z Luau LZ)
#   byte  4      : version (1)
#   bytes 5..8  : u32 LE uncompressed length
#   bytes 9..12 : u32 LE compressed length (rest of blob, excl. header)
#   bytes 13..  : token stream
#
# Token stream:
#   Each token starts with a flag byte: 1 bit per subsequent unit (8 units per flag byte).
#   For each unit:
#     - bit=0: literal, next byte is copied verbatim
#     - bit=1: match, next 2 bytes are (offset, length) where
#              offset in [1..255], length in [3..18] (encoded as length-3)
#
# Simplest viable: gives ~40-60% size reduction on Lua source.

_LZ_MAGIC = b"CZLZ"
_LZ_VERSION = 1
_LZ_MIN_MATCH = 3
_LZ_MAX_MATCH = 18
_LZ_WINDOW = 255  # byte offset


def cadmio_lz_compress(data: bytes) -> bytes:
    """Compress bytes using simple LZSS. Output is the Cadmio-LZ blob."""
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("data must be bytes")
    data = bytes(data)
    out = bytearray()
    out += _LZ_MAGIC
    out.append(_LZ_VERSION)
    out += struct.pack("<I", len(data))
    # placeholder for compressed length
    compressed_len_offset = len(out)
    out += struct.pack("<I", 0)

    pos = 0
    n = len(data)
    tokens = bytearray()
    flag_buf = 0
    flag_bits = 0
    flag_pos = len(tokens)
    tokens.append(0)  # reserve flag byte

    def flush_flag():
        nonlocal flag_buf, flag_bits, flag_pos
        tokens[flag_pos] = flag_buf
        flag_buf = 0
        flag_bits = 0
        flag_pos = len(tokens)
        tokens.append(0)  # reserve next flag

    while pos < n:
        best_len = 0
        best_off = 0
        start = max(0, pos - _LZ_WINDOW)
        # naive search for the best match
        for off in range(pos - start, 0, -1):
            sp = pos - off
            ml = 0
            while (
                ml < _LZ_MAX_MATCH
                and pos + ml < n
                and data[sp + ml] == data[pos + ml]
            ):
                ml += 1
            if ml > best_len:
                best_len = ml
                best_off = off
                if best_len >= _LZ_MAX_MATCH:
                    break

        if best_len >= _LZ_MIN_MATCH:
            # emit match: bit=1, then 2 bytes (offset, length-3)
            flag_buf |= (1 << flag_bits)
            flag_bits += 1
            tokens.append(best_off)
            tokens.append(best_len - _LZ_MIN_MATCH)
            pos += best_len
        else:
            # emit literal: bit=0, then 1 byte
            flag_bits += 1  # bit stays 0
            tokens.append(data[pos])
            pos += 1

        if flag_bits == 8:
            flush_flag()

    # finalize last flag if it has any pending bits
    if flag_bits > 0:
        tokens[flag_pos] = flag_buf
        # drop the reserved next flag byte (it's all-zero, harmless, but trim it)
        if len(tokens) > flag_pos + 1 and tokens[-1] == 0:
            tokens.pop()
    else:
        # we just flushed the previous flag and reserved a new flag byte
        # that was never used; remove it
        if tokens and tokens[-1] == 0 and len(tokens) - 1 == flag_pos:
            tokens.pop()

    out += tokens
    # backfill compressed length
    struct.pack_into("<I", out, compressed_len_offset, len(tokens))
    return bytes(out)


def cadmio_lz_decompress_test(blob: bytes) -> bytes:
    """Reference decoder (for testing). Pure-Python mirror of the Luau decoder."""
    if blob[:4] != _LZ_MAGIC:
        raise ValueError("bad magic")
    if blob[4] != _LZ_VERSION:
        raise ValueError("bad version")
    expected = struct.unpack("<I", blob[5:9])[0]
    comp_len = struct.unpack("<I", blob[9:13])[0]
    body = blob[13:13 + comp_len]
    out = bytearray()
    i = 0
    n = len(body)
    while i < n:
        flag = body[i]
        i += 1
        for bit in range(8):
            if i >= n:
                break
            if flag & (1 << bit):
                # match
                if i + 1 >= n:
                    raise ValueError("truncated match token")
                off = body[i]
                ln = body[i + 1] + _LZ_MIN_MATCH
                i += 2
                sp = len(out) - off
                if sp < 0:
                    raise ValueError("bad offset")
                for k in range(ln):
                    out.append(out[sp + k])
            else:
                # literal
                out.append(body[i])
                i += 1
            if len(out) >= expected:
                break
        if len(out) >= expected:
            break
    return bytes(out[:expected])


# ---------------------------------------------------------------------------
# 3) ZSTD RAW-BLOCK FRAME WRAPPER (pure-Python writer)
# ---------------------------------------------------------------------------
# Construct a real zstd frame that uses ONLY raw blocks (block_type=0).
# This means the entire payload is framed but uncompressed at the zstd layer.
# Combined with Cadmio-LZ pre-compression, we get:
#   * Valid zstd magic (0x28 0xB5 0x2F 0xFD) at the start
#   * A frame any zstd decoder can decompress
#   * Real compression via Cadmio-LZ (the payload inside the raw blocks)
#
# Frame layout (zstd spec):
#   Magic_Number                : 4 bytes (0x28 0xB5 0x2F 0xFD)
#   Frame_Header_Descriptor     : 1 byte
#       bit 7-6 FCS_flag, bit 5 SS, bit 4 unused, bit 3 reserved,
#       bit 2 checksum, bit 1-0 DID
#   Single_Segment flag set + FCS_flag=0 -> FCS_size = 1
#   Frame_Content_Size          : 1 byte (if FCS_flag=0 + SS=1)
#   Blocks:
#       Block_Header (3 bytes LE):
#           bit 0: Last_Block
#           bit 1-2: Block_Type (0=Raw, 1=RLE, 2=Compressed, 3=Reserved)
#           bit 3-23: Block_Size
#       Block_Content (Block_Size bytes for Raw)
#   [Content_Checksum] optional
#
# We split payload into max 128 KB blocks (zstd max block size = 128 KB - 1).
# For our use case scripts are < 128 KB so we use one block.

_ZSTD_MAGIC = b"\x28\xB5\x2F\xFD"
_ZSTD_MAX_BLOCK = 128 * 1024 - 1


def zstd_raw_wrap(payload: bytes, content_size: int | None = None) -> bytes:
    """
    Build a valid zstd frame whose blocks are all raw (uncompressed).
    The frame is decodable by:
       - any compliant zstd decoder
       - the pure-Luau raw-block decoder in zstd.luau
       - the inline decoder embedded in our bootstrap
    """
    if content_size is None:
        content_size = len(payload)

    out = bytearray()
    out += _ZSTD_MAGIC

    # Frame header: we want Single_Segment=1 (no Window_Descriptor),
    # FCS_flag=0 -> FCS_size = 1 byte (when SS=1)
    # FCS_flag = 0 means we encode content_size-1 if SS=1 (size <= 256).
    # For larger sizes, we need FCS_flag=2 (4 bytes).
    if content_size <= 256:
        # SS=1, FCS_flag=0 -> 1 byte FCS = content_size - 1 (if SS=1)
        # Actually: FCS_flag=0, SS=1 -> FCS_field is 1 byte, value = content_size (no -1 here?)
        # Per spec: "When FCS_Field is 1 byte, the actual content size is stored_value"
        # Wait — spec says: FCS_flag=0 + SS=1 -> 1 byte, value = content_size (no -1)
        fhd = 0x20  # SS=1, FCS_flag=0, no checksum, no DID
        out.append(fhd)
        out.append(content_size & 0xFF)
    elif content_size <= 0xFFFFFFFF:
        # FCS_flag=2 -> 4 bytes (value = content_size)
        fhd = 0x80  # FCS_flag=2 (binary 10), SS=0, no checksum, no DID
        out.append(fhd)
        # Window_Descriptor: 1 byte required when SS=0
        # Use window=128 KB (Exponent=8, Mantis=0) -> 0x80
        out.append(0x80)
        out += struct.pack("<I", content_size)
    else:
        raise ValueError("content too large for zstd raw frame (>4GB)")

    # Write blocks (split if payload > max block size)
    pos = 0
    n = len(payload)
    if n == 0:
        # Single empty raw block, marked as last
        bh = 0 | (0 << 1) | (0 << 3) | (1 << 0)  # raw, size 0, last
        out += struct.pack("<I", bh)[:3]
    else:
        while pos < n:
            chunk = payload[pos:pos + _ZSTD_MAX_BLOCK]
            chunk_len = len(chunk)
            is_last = (pos + chunk_len) >= n
            bh = 0  # block_type=0 (Raw)
            if is_last:
                bh |= 1
            bh |= (chunk_len << 3)
            # Block header is 3 bytes LE
            out += struct.pack("<I", bh)[:3]
            out += chunk
            pos += chunk_len

    return bytes(out)


# ---------------------------------------------------------------------------
# 4) BASE64 PAYLOAD ENCODING
# ---------------------------------------------------------------------------
# We base64-encode the zstd bytes for compact embedding. Base64 gives 4
# chars per 3 bytes (~1.33x expansion), versus string.char(a,b,c,...) which
# is ~4 chars per byte. On a 13KB payload that's the difference between
# ~18KB and ~52KB of embedded text.
#
# At runtime, a small inline base64 decoder reverses it.

_B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _base64_encode(data: bytes) -> str:
    """Standard base64 encode with padding. Returns ASCII string."""
    out = []
    n = len(data)
    i = 0
    while i + 2 < n:
        v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
        out.append(_B64_ALPHA[(v >> 18) & 0x3F])
        out.append(_B64_ALPHA[(v >> 12) & 0x3F])
        out.append(_B64_ALPHA[(v >> 6) & 0x3F])
        out.append(_B64_ALPHA[v & 0x3F])
        i += 3
    rem = n - i
    if rem == 1:
        v = data[i] << 16
        out.append(_B64_ALPHA[(v >> 18) & 0x3F])
        out.append(_B64_ALPHA[(v >> 12) & 0x3F])
        out.append("==")
    elif rem == 2:
        v = (data[i] << 16) | (data[i + 1] << 8)
        out.append(_B64_ALPHA[(v >> 18) & 0x3F])
        out.append(_B64_ALPHA[(v >> 12) & 0x3F])
        out.append(_B64_ALPHA[(v >> 6) & 0x3F])
        out.append("=")
    return "".join(out)


# ---------------------------------------------------------------------------
# 5) LUA STRING ESCAPING (for safe embedding of base64 text)
# ---------------------------------------------------------------------------
# Base64 alphabet is all printable ASCII letters/digits/+/=, so no
# escaping needed except for `"` and `\`. We just wrap in quotes.

def _lua_quoted(text: str) -> str:
    """Wrap a string in Lua double quotes with minimal escaping."""
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return '"' + escaped + '"'


# ---------------------------------------------------------------------------
# 5) BOOTSTRAP BUILDER
# ---------------------------------------------------------------------------
# The bootstrap is a Lua script that:
#   1. Defines an inline pure-Luau zstd raw-block decoder
#   2. Defines an inline Cadmio-LZ decompressor
#   3. Stitches the embedded zstd bytes
#   4. Decompresses to get Cadmio-LZ bytes
#   5. Cadmio-LZ decompresses to get the obfuscated Lua source
#   6. loadstring()s and runs it
#
# The bootstrap is self-contained: no executor APIs required, no zstd lib,
# no RC4 lib. Pure Lua 5.1 + bit32 (Roblox/Delta compatible).

_LUAU_BOOTSTRAP_TEMPLATE = r"""-- Cadmio bootstrap: zstd-framed + Cadmio-LZ compressed payload (base64-encoded)
-- Auto-generated by cadmio_postproc.py
-- Original: {orig}B | Minified: {minified}B | LZ: {lz}B | Zstd: {zstd}B | b64: {b64}B
local _M = {{}}
do
  -- ===== inline bit ops (bit32 fallback) =====
  local band, bor, bxor, bnot, lshift, rshift
  local ok_b, bit32 = pcall(function() return bit32 end)
  if ok_b and bit32 then
    band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
    lshift, rshift = bit32.lshift, bit32.rshift
  else
    local function tsh(n, s) return math.floor(n / (2 ^ s)) end
    local function sh(n, s)  return (n * (2 ^ s)) % (2 ^ 32) end
    band = function(a, b)
      local r, p = 0, 1
      for i = 0, 31 do
        local ba = math.floor(a / p) % 2
        local bb = math.floor(b / p) % 2
        if ba == 1 and bb == 1 then r = r + p end
        p = p * 2
      end
      return r
    end
    bor = function(a, b) return a + b - band(a, b) end
    bxor = function(a, b) return a + b - 2 * band(a, b) end
    bnot = function(a) return (2 ^ 32 - 1) - a end
    lshift = sh; rshift = tsh
  end

  -- ===== base64 decoder (pure Luau, ~25 lines) =====
  local B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local B64_IDX = {{}}
  for i = 1, #B64_ALPHA do
    B64_IDX[B64_ALPHA:byte(i, i)] = i - 1
  end

  local function b64decode(s)
    -- Strip padding
    s = s:gsub("=", "")
    local n = #s
    local out = {{}}
    local i = 1
    while i + 3 <= n do
      local a = B64_IDX[s:byte(i, i)] or 0
      local b = B64_IDX[s:byte(i + 1, i + 1)] or 0
      local c = B64_IDX[s:byte(i + 2, i + 2)] or 0
      local d = B64_IDX[s:byte(i + 3, i + 3)] or 0
      local v = a * 262144 + b * 4096 + c * 64 + d
      out[#out + 1] = string.char(math.floor(v / 65536) % 256)
      out[#out + 1] = string.char(math.floor(v / 256) % 256)
      out[#out + 1] = string.char(v % 256)
      i = i + 4
    end
    -- Handle remaining 2 or 3 chars (no padding)
    local rem = n - i + 1
    if rem == 2 then
      local a = B64_IDX[s:byte(i, i)] or 0
      local b = B64_IDX[s:byte(i + 1, i + 1)] or 0
      local v = a * 262144 + b * 4096
      out[#out + 1] = string.char(math.floor(v / 65536) % 256)
    elseif rem == 3 then
      local a = B64_IDX[s:byte(i, i)] or 0
      local b = B64_IDX[s:byte(i + 1, i + 1)] or 0
      local c = B64_IDX[s:byte(i + 2, i + 2)] or 0
      local v = a * 262144 + b * 4096 + c * 64
      out[#out + 1] = string.char(math.floor(v / 65536) % 256)
      out[#out + 1] = string.char(math.floor(v / 256) % 256)
    end
    return table.concat(out)
  end

  -- ===== zstd raw-block decoder (pure Luau) =====
  local ZSTD_MAGIC = string.char(0x28, 0xB5, 0x2F, 0xFD)
  local function _byte(data, i) return string.byte(data, i, i) or 0 end

  local function zstd_decode_raw(data)
    if #data < 6 then return nil, "too short" end
    if data:sub(1, 4) ~= ZSTD_MAGIC then return nil, "bad magic" end
    local pos = 5
    local fhd = _byte(data, pos); pos = pos + 1
    local fcs_flag = band(rshift(fhd, 6), 0x03)
    local ss = band(fhd, 0x20) ~= 0
    local did_flag = band(fhd, 0x03)
    local fcs_size
    if fcs_flag == 0 then fcs_size = ss and 1 or 0
    elseif fcs_flag == 1 then fcs_size = 2
    elseif fcs_flag == 2 then fcs_size = 4
    else fcs_size = 8 end
    local did_size = 0
    if did_flag == 1 then did_size = 1
    elseif did_flag == 2 then did_size = 2
    elseif did_flag == 3 then did_size = 4 end
    pos = pos + did_size
    if not ss then
      -- Window_Descriptor: 1 byte
      pos = pos + 1
    end
    if fcs_size > 0 then pos = pos + fcs_size end
    local out = {{}}
    while pos <= #data do
      if pos + 2 > #data then return nil, "truncated block header" end
      local bh = _byte(data, pos) + _byte(data, pos + 1) * 256 + _byte(data, pos + 2) * 65536
      pos = pos + 3
      local last = band(bh, 1) ~= 0
      local btype = band(rshift(bh, 1), 0x03)
      local bsize = rshift(bh, 3)
      if btype == 0 then
        -- Raw block
        if pos + bsize - 1 > #data then return nil, "truncated raw block" end
        out[#out + 1] = data:sub(pos, pos + bsize - 1)
        pos = pos + bsize
      elseif btype == 1 then
        -- RLE block
        if pos > #data then return nil, "truncated rle" end
        local ch = data:sub(pos, pos)
        out[#out + 1] = ch:rep(bsize)
        pos = pos + 1
      else
        return nil, "compressed block not supported in pure-Luau raw decoder"
      end
      if last then break end
    end
    return table.concat(out)
  end

  -- ===== Cadmio-LZ decoder (pure Luau) =====
  local LZ_MAGIC = "CZLZ"
  local LZ_MIN = 3
  local function lz_decode(data)
    if #data < 13 then return nil, "too short" end
    if data:sub(1, 4) ~= LZ_MAGIC then return nil, "bad lz magic" end
    if string.byte(data, 5, 5) ~= 1 then return nil, "bad lz version" end
    local expected = string.byte(data, 6, 6)
                  + string.byte(data, 7, 7) * 256
                  + string.byte(data, 8, 8) * 65536
                  + string.byte(data, 9, 9) * 16777216
    local comp_len = string.byte(data, 10, 10)
                    + string.byte(data, 11, 11) * 256
                    + string.byte(data, 12, 12) * 65536
                    + string.byte(data, 13, 13) * 16777216
    local body = data:sub(14, 14 + comp_len - 1)
    if #body < comp_len then return nil, "truncated body" end
    -- Store single-char strings in `out`. For overlapping match copies,
    -- we need to be careful: when off < ln, we read positions we just
    -- wrote. So we must build incrementally — which `out[#out+1]=...` does.
    local out = {{}}
    local i = 1
    local n = #body
    while i <= n do
      local flag = string.byte(body, i, i); i = i + 1
      for bit = 0, 7 do
        if i > n then break end
        if band(flag, lshift(1, bit)) ~= 0 then
          local off = string.byte(body, i, i)
          local ln  = string.byte(body, i + 1, i + 1) + LZ_MIN
          i = i + 2
          local base_pos = #out - off + 1  -- 1-indexed start of source
          for k = 1, ln do
            out[#out + 1] = out[base_pos + k - 1]
          end
        else
          out[#out + 1] = body:sub(i, i)
          i = i + 1
        end
        if #out >= expected then break end
      end
      if #out >= expected then break end
    end
    local s = table.concat(out)
    return s:sub(1, expected)
  end

  -- ===== payload (base64-encoded zstd-framed Cadmio-LZ bytes) =====
  local PAYLOAD_B64 = {payload_b64}

  -- ===== decompress pipeline =====
  local function run()
    local zstd_data = b64decode(PAYLOAD_B64)
    if not zstd_data or #zstd_data == 0 then
      error("Cadmio bootstrap: b64 decode failed")
    end
    local lz_data, err = zstd_decode_raw(zstd_data)
    if not lz_data then
      error("Cadmio bootstrap: zstd decode failed: " .. tostring(err))
    end
    local lua_src, err2 = lz_decode(lz_data)
    if not lua_src then
      error("Cadmio bootstrap: lz decode failed: " .. tostring(err2))
    end
    local fn, e = loadstring(lua_src)
    if not fn then
      error("Cadmio bootstrap: loadstring failed: " .. tostring(e))
    end
    return fn()
  end

  _M.run = run
end

return _M.run()
"""


def build_bootstrap(obfuscated_lua: str) -> str:
    """
    Take the obfuscated Lua source (output of catlog.luau) and produce a
    fully self-contained bootstrap that, when run, decompresses and executes
    the obfuscated source.

    Pipeline: minify -> Cadmio-LZ compress -> zstd raw-frame wrap -> base64 -> embed.
    """
    orig_size = len(obfuscated_lua.encode("utf-8"))

    # Step 1: minify
    minified = minify_lua(obfuscated_lua)
    minified_bytes = minified.encode("utf-8")
    minified_size = len(minified_bytes)

    # Step 2: Cadmio-LZ compress
    lz_blob = cadmio_lz_compress(minified_bytes)
    lz_size = len(lz_blob)

    # Step 3: zstd raw-frame wrap
    zstd_blob = zstd_raw_wrap(lz_blob, content_size=lz_size)
    zstd_size = len(zstd_blob)

    # Step 4: base64 encode
    b64_str = _base64_encode(zstd_blob)
    b64_size = len(b64_str)

    # Step 5: render bootstrap
    bootstrap = _LUAU_BOOTSTRAP_TEMPLATE.format(
        orig=orig_size,
        minified=minified_size,
        lz=lz_size,
        zstd=zstd_size,
        b64=b64_size,
        payload_b64=_lua_quoted(b64_str),
    )

    return bootstrap


# ---------------------------------------------------------------------------
# 6) SELF-TEST (python -m cadmio_postproc)
# ---------------------------------------------------------------------------

def _self_test():
    import sys
    sample = """
    --[[
      This is a long comment
      that should be stripped.
    ]]
    local function hello(name)
      -- line comment
      print("Hello, " .. name .. "!")
      return name .. "_suffix"
    end
    local x = 1 + 2 * 3
    local y = not (x > 5 and x < 10)
    hello("world")
    """
    print("=== MINIFY ===")
    m = minify_lua(sample)
    print(m)
    print(f"orig={len(sample)} minified={len(m)}")

    print("\n=== LZ ===")
    blob = cadmio_lz_compress(m.encode())
    print(f"minified bytes={len(m)} lz blob={len(blob)}")
    rt = cadmio_lz_decompress_test(blob)
    assert rt == m.encode(), "LZ roundtrip failed"
    print("LZ roundtrip OK")

    print("\n=== ZSTD RAW WRAP ===")
    z = zstd_raw_wrap(blob, content_size=len(blob))
    print(f"lz={len(blob)} zstd={len(z)}")
    # Verify magic
    assert z[:4] == b"\x28\xB5\x2F\xFD", "bad zstd magic"
    print("zstd magic OK")

    # Verify with real zstd python lib if available
    try:
        import zstandard
        d = zstandard.ZstdDecompressor().decompress(z)
        assert d == blob, "zstd lib decoded payload does not match LZ blob"
        print(f"zstd lib verification OK (decoded {len(d)} bytes)")
    except ImportError:
        print("zstandard lib not installed, skipping lib verification")

    print("\n=== FULL BOOTSTRAP ===")
    b = build_bootstrap(sample)
    print(f"bootstrap size: {len(b)} bytes")
    print("first 200 chars:")
    print(b[:200])
    print("...")
    print("last 200 chars:")
    print(b[-200:])

    print("\n=== DONE ===")


if __name__ == "__main__":
    _self_test()
