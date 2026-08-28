local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local net = require("@lune/net")

local ZSTD_MAGIC = string.char(0x28, 0xB5, 0x2F, 0xFD)

local band, bor, bxor, bnot, lshift, rshift, arshift
local ok_bit32, bit32 = pcall(function() return bit32 end)
if ok_bit32 and bit32 then
    band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
    lshift, rshift = bit32.lshift, bit32.rshift
    arshift = bit32.arshift
else
    local function tsh(n, s) return math.floor(n / (2 ^ s)) end
    local function sh(n, s) return (n * (2 ^ s)) % (2 ^ 32) end
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
    lshift = sh
    rshift = tsh
    arshift = tsh
end

local function byte(data, i)
    return string.byte(data, i, i) or 0
end

local function le16(data, i)
    return byte(data, i) + byte(data, i + 1) * 256
end

local function le32(data, i)
    return byte(data, i) + byte(data, i + 1) * 256 + byte(data, i + 2) * 65536 + byte(data, i + 3) * 16777216
end

local function le64(data, i)
    local lo = le32(data, i)
    local hi = le32(data, i + 4)
    return lo + hi * 4294967296
end

local function isZstd(data: string): boolean
    if not data or #data < 4 then return false end
    return data:sub(1, 4) == ZSTD_MAGIC
end

local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data: string, pos: number)
    return setmetatable({
        data = data,
        pos = pos or 1,
        bitbuf = 0,
        bitcnt = 0,
    }, BitReader)
end

function BitReader:readBits(n: number)
    while self.bitcnt < n do
        if self.pos > #self.data then
            self.bitbuf = bor(lshift(self.bitbuf, 8), 0)
        else
            local b = string.byte(self.data, self.pos, self.pos) or 0
            self.bitbuf = bor(lshift(self.bitbuf, 8), b)
            self.pos += 1
        end
        self.bitcnt += 8
    end
    local mask = band(lshift(1, n) - 1, 0xFFFFFFFF)
    local out = band(self.bitbuf, mask)
    self.bitbuf = rshift(self.bitbuf, n)
    self.bitcnt -= n
    return out
end

local function readFrameContentSize(data: string, pos: number): (number?, number)
    local fhd = byte(data, pos)
    local fcs_flag = rshift(band(fhd, 0xC0), 6)
    local ss = band(fhd, 0x20) ~= 0
    local did_flag = band(fhd, 0x03)

    pos += 1
    local fcs_size = 0
    if fcs_flag == 0 then
        fcs_size = ss and 1 or 0
    elseif fcs_flag == 1 then
        fcs_size = 2
    elseif fcs_flag == 2 then
        fcs_size = 4
    else
        fcs_size = 8
    end

    local did_size = 0
    if did_flag == 1 then did_size = 1
    elseif did_flag == 2 then did_size = 2
    elseif did_flag == 3 then did_size = 4 end

    pos += did_size

    local content_size = 0
    if fcs_size > 0 then
        if fcs_size == 1 then
            content_size = byte(data, pos)
        elseif fcs_size == 2 then
            content_size = le16(data, pos) + 256
        elseif fcs_size == 4 then
            content_size = le32(data, pos)
        elseif fcs_size == 8 then
            content_size = le64(data, pos)
        end
        pos += fcs_size
    end

    return content_size, pos
end

local function tryDecodeRawOnly(data: string): (string, boolean)
    if #data < 6 then return "", false end
    local pos = 1
    if data:sub(1, 4) ~= ZSTD_MAGIC then
        return "", false
    end
    pos = 5

    local content_size, pos2 = readFrameContentSize(data, pos)
    if not pos2 then return "", false end
    pos = pos2

    local out = {}
    local out_size = 0

    while pos <= #data do
        if pos + 2 > #data then
            return "", false
        end
        local bh_val = byte(data, pos) + byte(data, pos + 1) * 256 + byte(data, pos + 2) * 65536
        pos += 3

        local last_block = band(bh_val, 1) ~= 0
        local block_type = band(rshift(bh_val, 1), 0x03)
        local block_size = rshift(bh_val, 3)

        if block_type == 0 then
            if pos + block_size - 1 > #data then
                return "", false
            end
            table.insert(out, data:sub(pos, pos + block_size - 1))
            out_size += block_size
            pos += block_size
        elseif block_type == 1 then
            if pos > #data then return "", false end
            local ch = data:sub(pos, pos)
            table.insert(out, ch:rep(block_size))
            out_size += block_size
            pos += 1
        else
            return "", false
        end

        if last_block then break end
    end

    return table.concat(out), true
end

local function findPythonWithZstandard(): string?
    local candidates = {
        "/usr/bin/python3",
        "/usr/bin/python3.13",
        "/usr/bin/python3.12",
        "python3",
        "python3.13",
    }
    for _, py in ipairs(candidates) do
        local r = process.exec(py, {
            "-c",
            "import zstandard, sys; sys.exit(0 if zstandard.__version__ else 1)",
        })
        if r and r.code == 0 then
            return py
        end
    end
    return nil
end

local function decompressViaPython(data: string): string?
    local py = findPythonWithZstandard()
    if not py then return nil end

    local tmp_in = "/tmp/cadmio_zstd_in_" .. tostring(math.random(1, 1e9)) .. ".zst"
    local tmp_out = "/tmp/cadmio_zstd_out_" .. tostring(math.random(1, 1e9)) .. ".bin"
    local script = string.format([[
import sys, zstandard
with open(%q, "rb") as f:
    data = f.read()
try:
    out = zstandard.ZstdDecompressor().decompress(data)
    with open(%q, "wb") as f:
        f.write(out)
    sys.exit(0)
except Exception as e:
    sys.stderr.write("zstd error: " + str(e) + "\n")
    sys.exit(1)
]], tmp_in, tmp_out)

    pcall(function()
        fs.writeFile(tmp_in, data)
    end)
    local result = process.exec(py, { "-c", script })
    pcall(function() fs.removeFile(tmp_in) end)

    if not result or result.code ~= 0 then
        return nil
    end
    local ok, out = pcall(fs.readFile, tmp_out)
    pcall(function() fs.removeFile(tmp_out) end)
    if ok then return out end
    return nil
end

local function decompressViaCli(data: string): string?
    local tmp_in = "/tmp/cadmio_zstd_in_" .. tostring(math.random(1, 1e9)) .. ".zst"
    pcall(function() fs.writeFile(tmp_in, data) end)

    local result = process.exec("zstd", { "-d", "-c", tmp_in, "-q" })
    pcall(function() fs.removeFile(tmp_in) end)

    if not result or result.code ~= 0 then
        return nil
    end
    return result.stdout
end

local function decompress(data: string): string?
    if not isZstd(data) then
        return data
    end

    local ok, decoded = pcall(function()
        local out, ok = tryDecodeRawOnly(data)
        return out, ok
    end)
    if ok then
        local success, out, did = true, nil, false
        local out2, did2 = tryDecodeRawOnly(data)
        if did2 and #out2 > 0 then
            return out2
        end
    end

    local out = decompressViaCli(data)
    if out and #out > 0 then return out end

    out = decompressViaPython(data)
    if out and #out > 0 then return out end

    return nil, "zstd decompression failed"
end

local function compress(data: string, level: number?): string?
    local lvl = level or 3

    local tmp_in = "/tmp/cadmio_zstd_comp_in_" .. tostring(math.random(1, 1e9)) .. ".bin"
    pcall(function() fs.writeFile(tmp_in, data) end)

    local result = process.exec("zstd", { "-" .. tostring(lvl), "-c", tmp_in, "-q" })
    pcall(function() fs.removeFile(tmp_in) end)

    if result and result.code == 0 and #result.stdout > 0 then
        return result.stdout
    end

    local py = findPythonWithZstandard()
    if not py then return nil end

    local tmp_out = "/tmp/cadmio_zstd_comp_out_" .. tostring(math.random(1, 1e9)) .. ".zst"
    local script = string.format([[
import sys, zstandard
try:
    cctx = zstandard.ZstdCompressor(level=%d)
    with open(%q, "rb") as f:
        data = f.read()
    out = cctx.compress(data)
    with open(%q, "wb") as f:
        f.write(out)
    sys.exit(0)
except Exception as e:
    sys.stderr.write("zstd error: " + str(e) + "\n")
    sys.exit(1)
]], lvl, tmp_in, tmp_out)

    pcall(function() fs.writeFile(tmp_in, data) end)
    local res = process.exec(py, { "-c", script })
    pcall(function() fs.removeFile(tmp_in) end)

    if not res or res.code ~= 0 then
        return nil
    end
    local ok, out = pcall(fs.readFile, tmp_out)
    pcall(function() fs.removeFile(tmp_out) end)
    if ok then return out end
    return nil
end

return {
    isZstd = isZstd,
    decompress = decompress,
    compress = compress,
    magic = ZSTD_MAGIC,
    _tryDecodeRawOnly = tryDecodeRawOnly,
    _BitReader = BitReader,
    _le16 = le16,
    _le32 = le32,
    _le64 = le64,
}
