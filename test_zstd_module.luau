local fs = require("@lune/fs")
local luau = require("@lune/luau")
local stdio = require("@lune/stdio")

local function loadModule(path)
    local src = fs.readFile(path)
    local fn, err = luau.load(src, { debugName = path, optimizationLevel = 1 })
    if not fn then
        error("Failed to load " .. path .. ": " .. tostring(err))
    end
    return fn()
end

local zstd = loadModule("zstd.luau")
local data = fs.readFile("/tmp/test_zstd.lua.zst")
print("magic ok:", zstd.isZstd(data))
print("len:", #data)
local out, err = zstd.decompress(data)
if out then
    print("decompressed len:", #out)
    print("first 100 chars:", string.sub(out, 1, 100))
    local nulls = 0
    for i = 1, #out do
        if out:byte(i, i) == 0 then nulls = nulls + 1 end
    end
    print("null bytes:", nulls)
else
    print("decompress failed:", err)
end
