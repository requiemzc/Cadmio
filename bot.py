import os
import io
import re
import sys
import struct
import asyncio
import tempfile
import subprocess

import discord
from discord.ext import commands
from dotenv import load_dotenv
import aiohttp

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
_HERE = os.path.dirname(os.path.abspath(__file__))
LUNE_SCRIPT = os.path.join(_HERE, "catlog.luau")
STUFF_DIR = os.path.join(_HERE, "stuff")
API_DUMP = os.path.join(STUFF_DIR, "API-Dump.json")
CLASSES_JSON = os.path.join(STUFF_DIR, "classes.json")
ENUMS_JSON = os.path.join(STUFF_DIR, "enums.json")
ASSETIDS_JSON = os.path.join(STUFF_DIR, "assetids.json")
LUNE_BIN = os.getenv("LUNE_BIN", "lune")
TIMEOUT_SECONDS = 30
NO_MENTIONS = discord.AllowedMentions.none()

_TOK_RE = re.compile(
    r"""
    (?:--\[\[.*?\]\])
    | (?:--[^\n]*)
    | (?:\[\[[^\]]*\]\])
    | (?:"(?:\\.|[^"\\])*")
    | (?:'(?:\\.|[^'\\])*')
    | (?:\[(=*)\[[\s\S]*?\]\1\])
    | \.\.\.
    | (?:::|==|~=|<=|>=|\.\.|\->|\+=|-=|\*=|/=|%=|\^=|\.\.=|\*\*|//|<<|>>|\^\^)
    | [A-Za-z_][A-Za-z0-9_]*
    | \d+(?:\.\d+)?(?:[eE][+-]?\d+)?
    | [^\sA-Za-z0-9_]
    | \s+
    """,
    re.VERBOSE | re.DOTALL,
)

_DANGER = {
    ("-", "-"), ("-", "="), ("~", "="), ("=", "="), ("<", "="),
    (">", "="), (".", "."), (":", ":"), ("<", "<"), (">", ">"),
    ("/", "/"), ("^", "^"), ("*", "*"), ("+", "="), ("-", "="),
    ("*", "="), ("/", "="), ("%", "="), ("^", "="),
}


def _toks(src):
    pos, n = 0, len(src)
    while pos < n:
        m = _TOK_RE.match(src, pos)
        if not m:
            yield ("punct", src[pos])
            pos += 1
            continue
        t = m.group(0)
        pos = m.end()
        if t.startswith("--"):
            yield ("comment", t)
        elif t.startswith("[") or t.startswith('"') or t.startswith("'"):
            yield ("string", t)
        elif t[0].isspace():
            yield ("ws", t)
        elif t[0].isalpha() or t[0] == "_":
            yield ("ident", t)
        elif t[0].isdigit():
            yield ("num", t)
        else:
            yield ("punct", t)


def minify_lua(src):
    out, prev, prev_k = [], "", ""
    for k, t in _toks(src):
        if k in ("comment", "ws"):
            continue
        if prev:
            a_id = prev_k in ("ident", "num")
            b_id = k in ("ident", "num")
            if a_id and b_id:
                out.append(" ")
            elif prev_k == "punct" and k == "punct" and (prev[-1], t[0]) in _DANGER:
                out.append(" ")
            elif a_id and t.startswith("-"):
                out.append(" ")
        out.append(t)
        prev, prev_k = t, k
    return "".join(out)


_LZ_MAGIC = b"CZLZ"
_LZ_VER = 1
_LZ_MIN = 3
_LZ_MAX = 18
_LZ_WIN = 255


def cadmio_lz_compress(data):
    data = bytes(data)
    out = bytearray(_LZ_MAGIC)
    out.append(_LZ_VER)
    out += struct.pack("<I", len(data))
    clen_off = len(out)
    out += struct.pack("<I", 0)

    tokens = bytearray()
    flag_buf = flag_bits = 0
    flag_pos = len(tokens)
    tokens.append(0)
    pos, n = 0, len(data)

    def flush():
        nonlocal flag_buf, flag_bits, flag_pos
        tokens[flag_pos] = flag_buf
        flag_buf = flag_bits = 0
        flag_pos = len(tokens)
        tokens.append(0)

    while pos < n:
        best_len = best_off = 0
        start = max(0, pos - _LZ_WIN)
        for off in range(pos - start, 0, -1):
            sp = pos - off
            ml = 0
            while ml < _LZ_MAX and pos + ml < n and data[sp + ml] == data[pos + ml]:
                ml += 1
            if ml > best_len:
                best_len, best_off = ml, off
                if best_len >= _LZ_MAX:
                    break

        if best_len >= _LZ_MIN:
            flag_buf |= (1 << flag_bits)
            flag_bits += 1
            tokens.append(best_off)
            tokens.append(best_len - _LZ_MIN)
            pos += best_len
        else:
            flag_bits += 1
            tokens.append(data[pos])
            pos += 1

        if flag_bits == 8:
            flush()

    if flag_bits > 0:
        tokens[flag_pos] = flag_buf
        if len(tokens) > flag_pos + 1 and tokens[-1] == 0:
            tokens.pop()
    else:
        if tokens and tokens[-1] == 0 and len(tokens) - 1 == flag_pos:
            tokens.pop()

    out += tokens
    struct.pack_into("<I", out, clen_off, len(tokens))
    return bytes(out)


_ZSTD_MAGIC = b"\x28\xB5\x2F\xFD"
_ZSTD_MAX_BLOCK = 128 * 1024 - 1


def zstd_raw_wrap(payload, content_size=None):
    if content_size is None:
        content_size = len(payload)
    out = bytearray(_ZSTD_MAGIC)
    if content_size <= 256:
        out.append(0x20)
        out.append(content_size & 0xFF)
    elif content_size <= 0xFFFFFFFF:
        out.append(0x80)
        out.append(0x80)
        out += struct.pack("<I", content_size)
    else:
        raise ValueError("payload too big")

    pos, n = 0, len(payload)
    if n == 0:
        bh = 1
        out += struct.pack("<I", bh)[:3]
    else:
        while pos < n:
            chunk = payload[pos:pos + _ZSTD_MAX_BLOCK]
            clen = len(chunk)
            last = (pos + clen) >= n
            bh = 1 if last else 0
            bh |= (clen << 3)
            out += struct.pack("<I", bh)[:3]
            out += chunk
            pos += clen
    return bytes(out)


_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _b64(data):
    out, n, i = [], len(data), 0
    while i + 2 < n:
        v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
        out.append(_B64[(v >> 18) & 0x3F])
        out.append(_B64[(v >> 12) & 0x3F])
        out.append(_B64[(v >> 6) & 0x3F])
        out.append(_B64[v & 0x3F])
        i += 3
    rem = n - i
    if rem == 1:
        v = data[i] << 16
        out.append(_B64[(v >> 18) & 0x3F])
        out.append(_B64[(v >> 12) & 0x3F])
        out.append("==")
    elif rem == 2:
        v = (data[i] << 16) | (data[i + 1] << 8)
        out.append(_B64[(v >> 18) & 0x3F])
        out.append(_B64[(v >> 12) & 0x3F])
        out.append(_B64[(v >> 6) & 0x3F])
        out.append("=")
    return "".join(out)


def _quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


_BOOT = r"""local _M = {{}}
do
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

  local B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local B64_IDX = {{}}
  for i = 1, #B64_ALPHA do
    B64_IDX[B64_ALPHA:byte(i, i)] = i - 1
  end

  local function b64decode(s)
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

  local ZSTD_MAGIC = string.char(0x28, 0xB5, 0x2F, 0xFD)
  local function _byte(data, i) return string.byte(data, i, i) or 0 end

  local function zstd_decode_raw(data)
    if #data < 6 then return nil, "short" end
    if data:sub(1, 4) ~= ZSTD_MAGIC then return nil, "magic" end
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
    if not ss then pos = pos + 1 end
    if fcs_size > 0 then pos = pos + fcs_size end
    local out = {{}}
    while pos <= #data do
      if pos + 2 > #data then return nil, "trunc" end
      local bh = _byte(data, pos) + _byte(data, pos + 1) * 256 + _byte(data, pos + 2) * 65536
      pos = pos + 3
      local last = band(bh, 1) ~= 0
      local btype = band(rshift(bh, 1), 0x03)
      local bsize = rshift(bh, 3)
      if btype == 0 then
        if pos + bsize - 1 > #data then return nil, "trunc raw" end
        out[#out + 1] = data:sub(pos, pos + bsize - 1)
        pos = pos + bsize
      elseif btype == 1 then
        if pos > #data then return nil, "trunc rle" end
        local ch = data:sub(pos, pos)
        out[#out + 1] = ch:rep(bsize)
        pos = pos + 1
      else
        return nil, "no compressed"
      end
      if last then break end
    end
    return table.concat(out)
  end

  local LZ_MAGIC = "CZLZ"
  local LZ_MIN = 3
  local function lz_decode(data)
    if #data < 13 then return nil, "short" end
    if data:sub(1, 4) ~= LZ_MAGIC then return nil, "magic" end
    if string.byte(data, 5, 5) ~= 1 then return nil, "ver" end
    local expected = string.byte(data, 6, 6)
                  + string.byte(data, 7, 7) * 256
                  + string.byte(data, 8, 8) * 65536
                  + string.byte(data, 9, 9) * 16777216
    local comp_len = string.byte(data, 10, 10)
                    + string.byte(data, 11, 11) * 256
                    + string.byte(data, 12, 12) * 65536
                    + string.byte(data, 13, 13) * 16777216
    local body = data:sub(14, 14 + comp_len - 1)
    if #body < comp_len then return nil, "trunc body" end
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
          local base_pos = #out - off + 1
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

  local PAYLOAD_B64 = {payload_b64}

  local function run()
    local z = b64decode(PAYLOAD_B64)
    if not z or #z == 0 then error("b64") end
    local lz, e = zstd_decode_raw(z)
    if not lz then error("zstd: " .. tostring(e)) end
    local src, e2 = lz_decode(lz)
    if not src then error("lz: " .. tostring(e2)) end
    local fn, e3 = loadstring(src)
    if not fn then error("load: " .. tostring(e3)) end
    return fn()
  end

  _M.run = run
end

return _M.run()
"""


def build_bootstrap(obf_lua):
    minified = minify_lua(obf_lua).encode("utf-8")
    lz = cadmio_lz_compress(minified)
    z = zstd_raw_wrap(lz, content_size=len(lz))
    b64 = _b64(z)
    return _BOOT.format(payload_b64=_quote(b64))


def sanitize_output(text):
    zwsp = '\u200b'
    text = text.replace("@everyone", "@" + zwsp + "everyone")
    text = text.replace("@here", "@" + zwsp + "here")
    text = re.sub(r'<@&(\d+)>', lambda m: '<@&' + zwsp + m.group(1) + '>', text)
    text = re.sub(r'<@!?(\d+)>', lambda m: '<@' + zwsp + m.group(1) + '>', text)
    text = re.sub(r'<#(\d+)>', lambda m: '<#' + zwsp + m.group(1) + '>', text)
    return text


intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix=".", intents=intents, help_command=None,
                   allowed_mentions=discord.AllowedMentions.none())

URL_RE = re.compile(r'https?://\S+')


async def download_from_url(url):
    if "github.com" in url and "/blob/" in url:
        url = url.replace("github.com", "raw.githubusercontent.com").replace("/blob/", "/")
    elif "pastebin.com" in url and "/raw/" not in url:
        pid = url.split("/")[-1]
        url = f"https://pastebin.com/raw/{pid}"
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(url, timeout=10) as r:
                if r.status == 200:
                    return await r.text(errors="ignore")
    except Exception:
        return None
    return None


async def extract_code(ctx, content):
    if ctx.message.attachments:
        d = await ctx.message.attachments[0].read()
        return d.decode("utf-8", errors="ignore")

    if ctx.message.reference:
        try:
            ref = await ctx.channel.fetch_message(ctx.message.reference.message_id)
        except discord.NotFound:
            ref = None
        if ref:
            if ref.attachments:
                d = await ref.attachments[0].read()
                return d.decode("utf-8", errors="ignore")
            if ref.content:
                content = ref.content + "\n" + content

    m = URL_RE.search(content)
    if m:
        c = await download_from_url(m.group(0))
        if c:
            return c

    if "```" in content:
        parts = content.split("```")
        if len(parts) >= 2:
            block = parts[1]
            first, _, rest = block.partition("\n")
            if first.strip().isalpha():
                return rest
            return block

    return None


def run_lune(code):
    with tempfile.TemporaryDirectory() as tmp:
        ip = os.path.join(tmp, "input.lua")
        op = os.path.join(tmp, "out.lua")
        with open(ip, "w", encoding="utf-8") as f:
            f.write(code)
        cmd = [LUNE_BIN, "run", LUNE_SCRIPT, "--", ip, f"out={op}", f"api_dump={API_DUMP}"]
        if os.path.isfile(CLASSES_JSON):
            cmd.append(f"classes={CLASSES_JSON}")
        if os.path.isfile(ENUMS_JSON):
            cmd.append(f"enums={ENUMS_JSON}")
        if os.path.isfile(ASSETIDS_JSON):
            cmd.append(f"assetids={ASSETIDS_JSON}")
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=TIMEOUT_SECONDS, cwd=tmp)
        except FileNotFoundError:
            return False, "lune executable not found, set LUNE_BIN"
        except subprocess.TimeoutExpired:
            return False, "timeout"

        if proc.returncode != 0 and not os.path.exists(op):
            err = (proc.stderr or proc.stdout or "unknown").strip()
            return False, err[:1900]

        if os.path.exists(op):
            with open(op, "r", encoding="utf-8", errors="ignore") as f:
                return True, f.read()

        return False, (proc.stdout or "no output").strip()[:1900]


def postprocess(obf):
    try:
        return True, build_bootstrap(obf)
    except Exception as e:
        return False, f"-- postproc fail: {e!r}\n" + obf


@bot.command(name="l")
async def l_cmd(ctx, *, text: str = ""):
    code = await extract_code(ctx, text)
    if not code or not code.strip():
        await ctx.reply(
            "Attach a .lua/.luau file, reply to one, use ```lua ... ``` or paste a link.",
            allowed_mentions=NO_MENTIONS)
        return

    async with ctx.typing():
        loop = asyncio.get_running_loop()
        ok, result = await loop.run_in_executor(None, run_lune, code)
        if not ok:
            await ctx.reply(f"Error:\n```\n{sanitize_output(result)}\n```",
                            allowed_mentions=NO_MENTIONS)
            return
        ok_pp, result = await loop.run_in_executor(None, postprocess, result)

    result = sanitize_output(result)
    if len(result) > 1900:
        f = discord.File(io.BytesIO(result.encode("utf-8")), filename="result.lua")
        await ctx.reply("done, attached:", file=f, allowed_mentions=NO_MENTIONS)
    else:
        await ctx.reply(f"Result:\n```lua\n{result}\n```", allowed_mentions=NO_MENTIONS)


@bot.event
async def on_ready():
    print(f"Logged in as {bot.user} (ID: {bot.user.id})")


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("DISCORD_TOKEN missing in .env")
    bot.run(TOKEN)
