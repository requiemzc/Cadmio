-- main envlogger
local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local net = require("@lune/net")

local Settings = {
    out = "out.lua",
    timeout = 60,
    ipt = nil :: string?,
    beautify = true,
    inline = true,
}
for _, arg in process.args do
    local k, v = string.match(arg, "([%w_]+)=(.+)")
    if k then
        if v:sub(1,1) == "'" and v:sub(-1) == "'" then v = v:sub(2, -2)
        elseif v:sub(1,1) == '"' and v:sub(-1) == '"' then v = v:sub(2, -2) end
        Settings[k] = if v == "true" then true elseif v == "false" then false elseif tonumber(v) then tonumber(v) else v
    else
        local val = arg
        if val:sub(1,1) == "'" and val:sub(-1) == "'" then val = val:sub(2, -2)
        elseif val:sub(1,1) == '"' and val:sub(-1) == '"' then val = val:sub(2, -2) end
        if not Settings.ipt and not string.match(val, "^%-") then
            Settings.ipt = val
        end
    end
end

local API_DUMP_PATH = "stuff/API-Dump.json"
local apiClassesByName = {}

local function getScriptDir(): string?
    for level = 1, 16 do
        local ok, source = pcall(debug.info, level, "s")
        if not ok or type(source) ~= "string" or source == "" then
            break
        end
        if source ~= "[C]" then
            local path = source:match('^%[string "(.-)"%]$') or source:match("^@(.+)$") or source
            local dir = path:match("(.*[/\\])")
            if dir and dir ~= "" then
                return dir
            end
        end
    end
    return nil
end

local SCRIPT_DIR = getScriptDir()

local function resolveApiDumpPath(): string?
    if type(Settings.api_dump) == "string" and Settings.api_dump ~= "" then
        local ok = pcall(fs.readFile, Settings.api_dump)
        if ok then return Settings.api_dump end
    end
    if type(process.env.CADMIO_API_DUMP) == "string" and process.env.CADMIO_API_DUMP ~= "" then
        local ok = pcall(fs.readFile, process.env.CADMIO_API_DUMP)
        if ok then return process.env.CADMIO_API_DUMP end
    end
    do
        local ok = pcall(fs.readFile, API_DUMP_PATH)
        if ok then return API_DUMP_PATH end
    end
    if SCRIPT_DIR then
        local candidate = SCRIPT_DIR .. API_DUMP_PATH
        local ok = pcall(fs.readFile, candidate)
        if ok then return candidate end
    end
    local cwd = process.cwd or ""
    for _ = 1, 6 do
        if cwd == "" then break end
        local candidate = cwd .. "/" .. API_DUMP_PATH
        local ok = pcall(fs.readFile, candidate)
        if ok then return candidate end
        local parent = cwd:match("(.*)/[^/]*")
        if not parent or parent == cwd then break end
        cwd = parent
    end
    return nil
end

local NUMBER_PRIMITIVE_TYPES = {
    int = true,
    int64 = true,
    float = true,
    double = true,
}

local STRING_LIKE_DATA_TYPES = {
    BinaryString = true,
    Content = true,
    ContentId = true,
    ProtectedString = true,
    SharedString = true,
}

local SERVER_ONLY_SERVICES = {
    ServerScriptService = true,
    ServerStorage = true,
}

local function makeTagSet(items)
    local tags = {}
    if type(items) == "table" then
        for _, item in ipairs(items) do
            tags[tostring(item)] = true
        end
    end
    return tags
end

local function normalizeApiType(typeInfo)
    if type(typeInfo) ~= "table" or type(typeInfo.Name) ~= "string" then
        return nil
    end

    return {
        category = tostring(typeInfo.Category or ""),
        name = typeInfo.Name,
    }
end

local RESOLVED_API_DUMP_PATH = resolveApiDumpPath()

local function loadApiDump()
    if not RESOLVED_API_DUMP_PATH then
        local scriptDirHint = SCRIPT_DIR and (" (script dir: " .. SCRIPT_DIR .. ")") or ""
        error(
            "API dump not found. Looked for '" .. API_DUMP_PATH
            .. "' relative to CWD, the script directory" .. scriptDirHint
            .. ", and parent directories. You can pass an explicit path with"
            .. " `api_dump=/abs/path/to/API-Dump.json` or set CADMIO_API_DUMP.",
            0
        )
    end
    local raw = fs.readFile(RESOLVED_API_DUMP_PATH)
    local decoded = serde.decode("json", raw)

    for _, classEntry in ipairs(decoded.Classes or {}) do
        if type(classEntry.Name) == "string" and classEntry.Name ~= "" then
            local classInfo = {
                name = classEntry.Name,
                superclass = classEntry.Superclass,
                tags = makeTagSet(classEntry.Tags),
                members = {},
            }

            for _, member in ipairs(classEntry.Members or {}) do
                if type(member.Name) == "string" and member.Name ~= "" then
                    classInfo.members[member.Name] = {
                        memberType = tostring(member.MemberType or ""),
                        name = member.Name,
                        security = member.Security,
                        serialization = member.Serialization,
                        threadSafety = member.ThreadSafety,
                        tags = makeTagSet(member.Tags),
                        valueType = normalizeApiType(member.ValueType),
                        returnType = normalizeApiType(member.ReturnType),
                        parameters = member.Parameters,
                    }
                end
            end

            apiClassesByName[classInfo.name] = classInfo
        end
    end
end

local apiLoadOk, apiLoadErr = pcall(loadApiDump)
if not apiLoadOk then
    local location = RESOLVED_API_DUMP_PATH or API_DUMP_PATH
    error("Failed to load API dump from " .. location .. ": " .. tostring(apiLoadErr))
end

local enumsData = {}
local function loadEnums()
    if type(Settings.enums) == "string" and Settings.enums ~= "" then
        local ok, raw = pcall(fs.readFile, Settings.enums)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                enumsData = decoded
                return
            end
        end
    end
    if type(process.env.CADMIO_ENUMS) == "string" and process.env.CADMIO_ENUMS ~= "" then
        local ok, raw = pcall(fs.readFile, process.env.CADMIO_ENUMS)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                enumsData = decoded
                return
            end
        end
    end
    local enumPath = SCRIPT_DIR and (SCRIPT_DIR .. "stuff/enums.json") or "stuff/enums.json"
    local raw, ok
    ok, raw = pcall(fs.readFile, enumPath)
    if not ok or not raw then
        local resolved = resolveApiDumpPath()
        if resolved then
            local altPath = resolved:gsub("API%-Dump%.json$", "enums.json")
            ok, raw = pcall(fs.readFile, altPath)
        end
    end
    if ok and raw then
        local decoded = serde.decode("json", raw)
        if type(decoded) == "table" then
            enumsData = decoded
        end
    end
end
pcall(loadEnums)

local classesData = {}
local function loadClasses()
    if type(Settings.classes) == "string" and Settings.classes ~= "" then
        local ok, raw = pcall(fs.readFile, Settings.classes)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                classesData = decoded
                return
            end
        end
    end
    if type(process.env.CADMIO_CLASSES) == "string" and process.env.CADMIO_CLASSES ~= "" then
        local ok, raw = pcall(fs.readFile, process.env.CADMIO_CLASSES)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                classesData = decoded
                return
            end
        end
    end
    local classPath = SCRIPT_DIR and (SCRIPT_DIR .. "stuff/classes.json") or "stuff/classes.json"
    local raw, ok
    ok, raw = pcall(fs.readFile, classPath)
    if not ok or not raw then
        local resolved = resolveApiDumpPath()
        if resolved then
            local altPath = resolved:gsub("API%-Dump%.json$", "classes.json")
            ok, raw = pcall(fs.readFile, altPath)
        end
    end
    if ok and raw then
        local decoded = serde.decode("json", raw)
        if type(decoded) == "table" then
            classesData = decoded
        end
    end
end
pcall(loadClasses)

local assetIdsData = {}
local function loadAssetIds()
    if type(Settings.assetids) == "string" and Settings.assetids ~= "" then
        local ok, raw = pcall(fs.readFile, Settings.assetids)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                assetIdsData = decoded
                return
            end
        end
    end
    if type(process.env.CADMIO_ASSETIDS) == "string" and process.env.CADMIO_ASSETIDS ~= "" then
        local ok, raw = pcall(fs.readFile, process.env.CADMIO_ASSETIDS)
        if ok and raw then
            local decoded = serde.decode("json", raw)
            if type(decoded) == "table" then
                assetIdsData = decoded
                return
            end
        end
    end
    local assetPath = SCRIPT_DIR and (SCRIPT_DIR .. "stuff/assetids.json") or "stuff/assetids.json"
    local raw, ok
    ok, raw = pcall(fs.readFile, assetPath)
    if not ok or not raw then
        local resolved = resolveApiDumpPath()
        if resolved then
            local altPath = resolved:gsub("API%-Dump%.json$", "assetids.json")
            ok, raw = pcall(fs.readFile, altPath)
        end
    end
    if ok and raw then
        local decoded = serde.decode("json", raw)
        if type(decoded) == "table" then
            assetIdsData = decoded
        end
    end
end
pcall(loadAssetIds)

local function getApiClassInfo(className)
    if type(className) ~= "string" then
        return nil
    end
    return apiClassesByName[className]
end

local function resolveApiMember(className, memberName)
    if type(className) ~= "string" or type(memberName) ~= "string" then
        return nil, nil
    end

    local classInfo = getApiClassInfo(className)
    while classInfo do
        local memberInfo = classInfo.members[memberName]
        if memberInfo then
            return memberInfo, classInfo
        end

        if type(classInfo.superclass) ~= "string" or classInfo.superclass == "" then
            break
        end
        classInfo = getApiClassInfo(classInfo.superclass)
    end

    return nil, nil
end

local function classIsA(className, targetClassName)
    if type(className) ~= "string" or type(targetClassName) ~= "string" then
        return false
    end
    if className == targetClassName then
        return true
    end

    local classInfo = getApiClassInfo(className)
    while classInfo and type(classInfo.superclass) == "string" and classInfo.superclass ~= "" do
        if classInfo.superclass == targetClassName then
            return true
        end
        classInfo = getApiClassInfo(classInfo.superclass)
    end

    return false
end

local function isApiServiceClass(className)
    local classInfo = getApiClassInfo(className)
    return classInfo ~= nil and classInfo.tags.Service == true
end

local function isApiCreatableClass(className)
    local classInfo = getApiClassInfo(className)
    return classInfo ~= nil and not classInfo.tags.NotCreatable
end

local function getRuntimeTypeName(apiType)
    if not apiType then
        return nil
    end

    if apiType.category == "Primitive" then
        if apiType.name == "bool" then
            return "boolean"
        end
        if apiType.name == "string" then
            return "string"
        end
        if apiType.name == "null" then
            return "nil"
        end
        if NUMBER_PRIMITIVE_TYPES[apiType.name] then
            return "number"
        end
    elseif apiType.category == "Enum" then
        return "EnumItem"
    elseif apiType.category == "Class" then
        return "Instance"
    elseif apiType.category == "DataType" then
        if apiType.name == "RBXScriptSignal" then
            return "RBXScriptSignal"
        end
        if STRING_LIKE_DATA_TYPES[apiType.name] then
            return "string"
        end
        return apiType.name
    end

    return nil
end

local function isPropertyMember(memberInfo)
    return memberInfo ~= nil and memberInfo.memberType == "Property"
end

local function isReadablePropertyMember(memberInfo)
    if not isPropertyMember(memberInfo) then
        return false
    end
    if memberInfo.tags.NotScriptable then
        return false
    end
    if type(memberInfo.security) ~= "table" then
        return false
    end
    return tostring(memberInfo.security.Read or "") == "None"
end

local function isWritablePropertyMember(memberInfo)
    if not isPropertyMember(memberInfo) then
        return false
    end
    if memberInfo.tags.ReadOnly or memberInfo.tags.NotScriptable then
        return false
    end
    if type(memberInfo.security) ~= "table" then
        return false
    end
    return tostring(memberInfo.security.Write or "") == "None"
end

local function isCallableMember(memberInfo)
    return memberInfo ~= nil and (memberInfo.memberType == "Function" or memberInfo.memberType == "Callback")
end

local function isEventMember(memberInfo)
    return memberInfo ~= nil and memberInfo.memberType == "Event"
end

local function isScriptableFunctionMember(memberInfo)
    if not (isCallableMember(memberInfo) or isEventMember(memberInfo)) then
        return false
    end
    if memberInfo.tags.NotScriptable then
        return false
    end
    return true
end

local makeProxy: (string) -> any

local _game = game
if _game == nil and roblox ~= nil then
    local ok, resolved = pcall(function() return (roblox).game end)
    if ok then _game = resolved end
end

if _game ~= nil then
    local oldGetService = _game.GetService

    _game.GetService = function(self, serviceName)
        return oldGetService(self, serviceName)
    end
end

local lines = {}
local varCount = 0
local usedVars = {}
local opCount = 0
local OP_BUDGET = 5000000
local BUDGET_ERROR = "__OP_BUDGET_EXCEEDED__"

local PARTIAL_DUMP_PATH = "/tmp/catlog_partial_dump.lua"
local lastFlushCount = 0
local function flushPartial()
    if #lines == lastFlushCount then return end
    lastFlushCount = #lines
    pcall(function()
        local env_line = ""
        if Settings.ipt then
            env_line = "-- input: " .. tostring(Settings.ipt) .. "\n"
        end
        fs.writeFile(PARTIAL_DUMP_PATH, env_line .. table.concat(lines, "\n"))
    end)
end

local function emit(text: string)
    table.insert(lines, text)
    if #lines % 50 == 0 then
        flushPartial()
    end
end
local function genVar(prefix: string?): string
    varCount += 1
    return (prefix or "v") .. tostring(varCount)
end

local function tick()
    opCount += 1
    if opCount > OP_BUDGET then
        error(BUDGET_ERROR, 0)
    end
end

local function isProxy(v: any): boolean
    return type(v) == "table" and getmetatable(v) ~= nil and getmetatable(v)._isProxy == true
end

local dataMTs = {}
local function makeDataProxy(ctorName, ctorArgs, name)
    if not dataMTs[ctorName] then
        local dmt = {
            _isProxy = true,
            __eq = function(a, b)
                if rawequal(a, b) then return true end
                local aa = rawget(a, "_ctorArgs")
                local ba = rawget(b, "_ctorArgs")
                local ac = rawget(a, "_ctorName")
                local bc = rawget(b, "_ctorName")
                if ac and bc and ac == bc and aa and ba then
                    if #aa == #ba then
                        local allEq = true
                        for i, v in ipairs(aa) do
                            if v ~= ba[i] then allEq = false break end
                        end
                        if allEq then return true end
                    end
                end
                return false
            end,
            __tostring = function(a)
                local cn = rawget(a, "_ctorName") or ctorName
                local args = rawget(a, "_ctorArgs") or {}
                if cn == "Vector3" then
                    return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. ", " .. tostring(args[3] or 0)
                elseif cn == "Vector2" then
                    return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0)
                elseif cn == "Color3" then
                    return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. ", " .. tostring(args[3] or 0)
                elseif cn == "UDim2" then
                    return "{" .. tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. "}, {" .. tostring(args[3] or 0) .. ", " .. tostring(args[4] or 0) .. "}"
                end
                return rawget(a, "_name") or ctorName
            end,
            __index = function(a, k)
                local args = rawget(a, "_ctorArgs") or {}
                local cn = rawget(a, "_ctorName") or ctorName
                if cn == "CFrame" then
                    if k == "Position" then
                        return makeDataProxy("Vector3", { args[1] or 0, args[2] or 0, args[3] or 0 }, (rawget(a,"_name") or "cf")..".Position")
                    end
                    if k == "X" then return args[1] or 0 end
                    if k == "Y" then return args[2] or 0 end
                    if k == "Z" then return args[3] or 0 end
                    if k == "LookVector" then return makeDataProxy("Vector3", {0, 0, -1}, "LookVector") end
                    if k == "RightVector" then return makeDataProxy("Vector3", {1, 0, 0}, "RightVector") end
                    if k == "UpVector" then return makeDataProxy("Vector3", {0, 1, 0}, "UpVector") end
                end
                if k == "X" or k == "x" then return args[1] or 0 end
                if k == "Y" or k == "y" then return args[2] or 0 end
                if k == "Z" or k == "z" then return args[3] or 0 end
                if k == "Magnitude" then
                    local x, y, z = args[1] or 0, args[2] or 0, args[3] or 0
                    return math.sqrt(x*x + y*y + z*z)
                end
                if k == "Unit" then
                    local x, y, z = args[1] or 0, args[2] or 0, args[3] or 0
                    local mag = math.sqrt(x*x + y*y + z*z)
                    if mag == 0 then mag = 1 end
                    return makeDataProxy(ctorName, {x/mag, y/mag, z/mag}, (rawget(a,"_name") or "v")..".Unit")
                end
                if k == "R" then return args[1] or 0 end
                if k == "G" then return args[2] or 0 end
                if k == "B" then return args[3] or 0 end
                if k == "Scale" then return args[1] or 0 end
                if k == "Offset" then return args[2] or 0 end
                if k == "Width" then return args[1] or 0 end
                if k == "Height" then return args[2] or 0 end
                local DATA_METHODS = { Lerp = true, Dot = true, Cross = true, Angle = true, FuzzyEq = true, Abs = true, ToHSV = true, ToHex = true, ToRGB = true, ToOrientation = true, Inverse = true, ToWorldSpace = true, ToObjectSpace = true, PointToObjectSpace = true }
                if DATA_METHODS[k] then
                    return function(self, ...)
                        local retName = genVar("v")
                        local parentName = rawget(a, "_name") or ctorName
                        local args = {...}
                        local parts = {}
                        for i = 1, select("#", ...) do
                            local arg = args[i]
                            if type(arg) == "table" and rawget(arg, "_name") then
                                table.insert(parts, rawget(arg, "_name"))
                            elseif type(arg) == "string" then
                                table.insert(parts, '"' .. arg .. '"')
                            else
                                table.insert(parts, tostring(arg))
                            end
                        end
                        emit(string.format('local %s = %s:%s(%s)', retName, parentName, k, table.concat(parts, ", ")))
                        if k == "Lerp" then
                            local proxy = makeProxy(retName)
                            local pmt = getmetatable(proxy)
                            pmt._ctorName = ctorName
                            return proxy
                        elseif k == "Cross" then
                            local proxy = makeProxy(retName)
                            local pmt = getmetatable(proxy)
                            pmt._ctorName = "Vector3"
                            return proxy
                        elseif k == "Dot" or k == "Angle" then
                            return 0
                        elseif k == "ToHSV" then
                            return 0, 0, 0, 0
                        elseif k == "ToHex" then
                            return "ffffff"
                        elseif k == "ToRGB" then
                            return 255, 255, 255
                        elseif k == "ToOrientation" then
                            return 0, 0, 0
                        elseif k == "FuzzyEq" then
                            return true
                        elseif k == "Inverse" or k == "ToWorldSpace" or k == "ToObjectSpace" or k == "PointToObjectSpace" or k == "Abs" then
                            local proxy = makeProxy(retName)
                            local pmt = getmetatable(proxy)
                            pmt._ctorName = ctorName
                            return proxy
                        end
                        return makeProxy(retName)
                    end
                end
                return nil
            end,
            __mul = function(a, b)
                local cn = rawget(a, "_ctorName") or ctorName
                local v = genVar("v")
                local sa = rawget(a, "_name") or cn
                local sb = isProxy(b) and (rawget(b, "_name") or (getmetatable(b) and getmetatable(b)._ctorName) or "v") or tostring(b)
                emit(string.format('local %s = %s * %s', v, sa, sb))
                if cn == "CFrame" then
                    local aa = rawget(a, "_ctorArgs") or {}
                    local bc = isProxy(b) and (rawget(b, "_ctorName") or (getmetatable(b) and getmetatable(b)._ctorName)) or ""
                    if bc == "Vector3" then
                        local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                        return makeDataProxy("Vector3", {(aa[1] or 0)+(ba[1] or 0), (aa[2] or 0)+(ba[2] or 0), (aa[3] or 0)+(ba[3] or 0)}, v)
                    end
                    local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                    return makeDataProxy("CFrame", {(aa[1] or 0)+(ba[1] or 0), (aa[2] or 0)+(ba[2] or 0), (aa[3] or 0)+(ba[3] or 0)}, v)
                end
                local aa = rawget(a, "_ctorArgs") or {}
                local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                if aa and ba and aa[1] and ba[1] then
                    return makeDataProxy(cn, {aa[1]*ba[1], aa[2]*ba[2], aa[3]*ba[3]}, v)
                end
                if aa and type(b) == "number" then
                    return makeDataProxy(cn, {aa[1]*b, aa[2]*b, aa[3]*b}, v)
                end
                return makeDataProxy(cn, {0, 0, 0}, v)
            end,
            __add = function(a, b)
                local aa = rawget(a, "_ctorArgs") or {}
                local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                if aa and ba and aa[1] and ba[1] then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]+ba[1], aa[2]+ba[2], aa[3]+ba[3]}, (rawget(a,"_name") or "v").."+")
                end
                if aa and type(b) == "number" then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]+b, aa[2]+b, aa[3]+b}, (rawget(a,"_name") or "v").."+")
                end
                return makeProxy("v")
            end,
            __sub = function(a, b)
                local aa = rawget(a, "_ctorArgs") or {}
                local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                if aa and ba and aa[1] and ba[1] then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]+ba[1], aa[2]+ba[2], aa[3]+ba[3]}, (rawget(a,"_name") or "v").."+")
                end
                if aa and type(b) == "number" then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]+b, aa[2]+b, aa[3]+b}, (rawget(a,"_name") or "v").."+")
                end
                return makeProxy("v")
            end,
            __sub = function(a, b)
                local aa = rawget(a, "_ctorArgs") or {}
                local ba = type(b) == "table" and rawget(b, "_ctorArgs") or {}
                if aa and ba and aa[1] and ba[1] then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]-ba[1], aa[2]-ba[2], aa[3]-ba[3]}, (rawget(a,"_name") or "v").."-")
                end
                if aa and type(b) == "number" then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]-b, aa[2]-b, aa[3]-b}, (rawget(a,"_name") or "v").."-")
                end
                return makeProxy("v")
            end,
            __div = function(a, b)
                local aa = rawget(a, "_ctorArgs") or {}
                if aa and type(b) == "number" then
                    return makeDataProxy(rawget(a, "_ctorName") or "Vector3", {aa[1]/b, aa[2]/b, aa[3]/b}, (rawget(a,"_name") or "v").."/")
                end
                return makeProxy("v")
            end,
        }
        dataMTs[ctorName] = dmt
    end
    local proxy = setmetatable({}, dataMTs[ctorName])
    rawset(proxy, "_ctorName", ctorName)
    rawset(proxy, "_ctorArgs", ctorArgs)
    rawset(proxy, "_name", name or ctorName:lower())
    return proxy
end

local function proxyName(v: any): string
    if isProxy(v) then
        local name = rawget(v, "_name") or getmetatable(v)._name
        return name or "proxy"
    end
    return "nil"
end

local function proxyParent(v: any): any?
    if isProxy(v) then return getmetatable(v)._parent end
    return nil
end

local function proxyField(v: any): string?
    if isProxy(v) then return getmetatable(v)._fieldName end
    return nil
end

local function markUsed(v: any)
    if not isProxy(v) then return end
    local mt = getmetatable(v)
    local nm = rawget(v, "_name") or mt._name
    if nm then
        usedVars[nm] = true
    end
    if mt._parent then
        markUsed(mt._parent)
    end
end

local serialize: (any, number?) -> string
function serialize(value: any, depth: number?): string
    depth = depth or 0
    if depth > 6 then return "nil" end
    local t = typeof(value)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then return "0/0"
        elseif value == math.huge then return "math.huge"
        elseif value == -math.huge then return "-math.huge" end
        return tostring(value)
    elseif t == "string" then
        if #value > 200 then return string.format("[=[%s...]=]", string.sub(value, 1, 200)) end
        local escaped = string.gsub(value, "\\", "\\\\")
        escaped = string.gsub(escaped, "\"", "\\\"")
        escaped = string.gsub(escaped, "\n", "\\n")
        escaped = string.gsub(escaped, "\r", "\\r")
        escaped = string.gsub(escaped, "\t", "\\t")
        return '"' .. escaped .. '"'
    elseif t == "table" then
        local m = getmetatable(value)
        if m and m._serialName then
            return m._serialName
        end
        if m and m._isProxy then
            markUsed(value)
            local nm = rawget(value, "_name") or m._name
            return nm or "proxy"
        end
        local parts = {}
        local isArray = true
        local count = 0
        for k, v in pairs(value) do
            count += 1
            if type(k) ~= "number" then isArray = false end
        end
        if isArray and count > 0 then
            for i = 1, #value do
                table.insert(parts, serialize(value[i], depth + 1))
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, v in pairs(value) do
            local keyStr = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k else "[" .. serialize(k, depth + 1) .. "]"
            table.insert(parts, keyStr .. " = " .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "function" then return "function() end" end
    return "nil"
end

local usedVarNames = {}
local function sanitizeName(s: string): string
    s = tostring(s or "")
    s = string.gsub(s, "[^%w_]", "_")
    if s == "" then return "v" end
    if string.match(s, "^%d") then s = "_" .. s end
    return s
end

local function makeDescriptiveVar(methodName: string?, firstArg: any?): string
    if methodName == "GetService" and type(firstArg) == "string" then
        local s = firstArg
        return s
    end
    if (methodName == "WaitForChild" or methodName == "FindFirstChild" or
        methodName == "FindFirstDescendant" or methodName == "FindFirstChildWhichIsA" or
        methodName == "FindFirstChildOfClass") and type(firstArg) == "string" then
        return sanitizeName(firstArg)
    end
    if (methodName == "Window" or methodName == "Tab" or methodName == "Section" or
        methodName == "Toggle" or methodName == "Button" or methodName == "Dropdown" or
        methodName == "Label" or methodName == "Slider" or methodName == "Colorpicker" or
        methodName == "Textbox" or methodName == "Keybind" or methodName == "Toggle") then
        return methodName
    end
    return genVar("v")
end

local applyClassDefaults: (any, string) -> ()
local spyInstance: (string, string?, boolean?) -> ()
local knownCFunctions: { [any]: boolean } = {}

local function getPropertyRuntimeType(className: string?, memberName: string): string?
    local memberInfo = resolveApiMember(className or "", memberName)
    if not isPropertyMember(memberInfo) then
        return nil
    end
    return getRuntimeTypeName(memberInfo.valueType)
end

local function makeTypedProxy(path: string, runtimeTypeName: string, apiType): any
    local proxy = makeProxy(path)
    local mt = getmetatable(proxy)
    if runtimeTypeName == "EnumItem" then
        mt._className = "EnumItem"
        mt._ctorName = "EnumItem"
    elseif runtimeTypeName == "Instance" then
        if apiType and apiType.category == "Class" and type(apiType.name) == "string" and apiType.name ~= "" then
            mt._className = apiType.name
            mt._storedValues["ClassName"] = apiType.name
            mt._setKeys["ClassName"] = true
        else
            mt._className = "Instance"
        end
    else
        mt._ctorName = runtimeTypeName
    end
    return proxy
end

local function makeDefaultValueForRuntimeType(path: string, runtimeTypeName: string?, apiType)
    if runtimeTypeName == "nil" then
        return nil
    end
    if runtimeTypeName == "boolean" then
        return false
    end
    if runtimeTypeName == "number" then
        return 0
    end
    if runtimeTypeName == "string" then
        return ""
    end
    if runtimeTypeName == "RBXScriptSignal" then
        local signal = makeProxy(path)
        local mt = getmetatable(signal)
        mt._className = "RBXScriptSignal"
        return signal
    end
    if runtimeTypeName == "Vector3" then
        return makeDataProxy("Vector3", {0, 0, 0}, path)
    end
    if runtimeTypeName == "Vector2" then
        return makeDataProxy("Vector2", {0, 0}, path)
    end
    if runtimeTypeName == "CFrame" then
        return makeDataProxy("CFrame", {0, 0, 0}, path)
    end
    if runtimeTypeName == "UDim2" then
        return makeDataProxy("UDim2", {0, 0, 0, 0}, path)
    end
    if runtimeTypeName == "Color3" then
        return makeDataProxy("Color3", {0.631373, 0.647059, 0.631373}, path)
    end
    if runtimeTypeName ~= nil then
        return makeTypedProxy(path, runtimeTypeName, apiType)
    end
    return nil
end

local function getMemberDefaultValue(className: string?, memberName: string, path: string)
    local memberInfo = resolveApiMember(className or "", memberName)
    if not isReadablePropertyMember(memberInfo) then
        return nil, memberInfo
    end

    local runtimeTypeName = getRuntimeTypeName(memberInfo.valueType)
    return makeDefaultValueForRuntimeType(path, runtimeTypeName, memberInfo.valueType), memberInfo
end

local propertyChangeCallbacks: { [string]: { (any) -> () } } = {}
local eventConnections: { { proxy: any, eventName: string, callback: (any) -> () } } = {}
local instanceTags: { [string]: { string } } = {}
local serviceCache: { [string]: any } = {}
local destroyedInstances: { [string]: boolean } = {}
local memStorage: { [string]: any } = {}
local parentChildMap: { [string]: { [string]: any } } = {}
local workspaceProxy: any = nil
local awakePartsCount = 0
local unanchoredParts = setmetatable({}, { __mode = "k" })
local _realCollectgarbage = collectgarbage

local function firePropertyChange(proxyNameStr: string, fieldName: string, value: any)
    local key = proxyNameStr .. "." .. fieldName
    local cbs = propertyChangeCallbacks[key]
    if cbs then
        for _, cb in ipairs(cbs) do
            pcall(cb, value)
        end
    end
end

local function fireAllConnectionsForEvent(proxyNameStr: string, eventName: string, ...: any)
    local args = {...}
    for _, conn in ipairs(eventConnections) do
        local connProxyName = ""
        local m = getmetatable(conn.proxy)
        if m and m._isProxy then connProxyName = m._name end
        if connProxyName == proxyNameStr and conn.eventName == eventName then
            pcall(conn.callback, table.unpack(args))
        end
    end
end

local numericPseudoProps = {
    AccelerationLean, AccelerationTime, AirDensity, AirTurbulenceIntensity, Angle,
    AngleSnapIncrement, AngularDamping, AngularResponsiveness, AngularRestitution,
    AngularSpeed, AngularStrength, AngularVelocity, AnimationIdForRestPose, AspectRatio,
    AssetId, Attack, AutoFRMLevel, BackgroundTransparency, BalanceMaxTorque, BalanceSpeed,
    BaseAngle, BaseMoveSpeed, BaseTextureId, BaseTurnSpeed, BlastPressure, BlastRadius,
    BodyTypeScale, BorderSizePixel, Brightness, BubbleDuration, BubblesSpacing,
    BuildDebouncePeriod, CameraMaxZoomDistance, CameraMinZoomDistance, CameraMouseMultiplier,
    CameraOrbitSensitivity, CameraPanSensitivity, CameraShiftFactor, CameraZoomSpeed,
    CartoonFactor, Channel, CharacterAppearanceId, CharacterJumpHeight, CharacterJumpPower,
    CharacterMaxSlopeAngle, CharacterWalkSpeed, ChestSize, ChinRaiser, ChinRaiserUpperLip,
    ClimbAnimation, ClockTime, Coils, CommandBarHistoryLen, ComparisonDiffThreshold,
    ComparisonPsnrThreshold, Contrast, ConversationDistance, Corrugator, Cover, CurrentAngle,
    CursorPosition, CurveSize0, CurveSize1, CustomBackAccessoryId, CustomBodyBundleId,
    CustomClassicPantsAccessoryId, CustomClassicShirtsAccessoryId,
    CustomClassicTShirtsAccessoryId, CustomClimbAnimationId, CustomDressSkirtAccessoryId,
    CustomEyebrowId, CustomEyelashId, CustomFaceAccessoryId, CustomFaceId,
    CustomFallAnimationId, CustomFrontAccessoryId, CustomHairAccessoryId,
    CustomHeadAccessoryId, CustomHeadId, CustomIdleAlt1AnimationId, CustomIdleAlt2AnimationId,
    CustomIdleAnimationId, CustomJacketAccessoryId, CustomJumpAnimationId, CustomLeftArmId,
    CustomLeftLegId, CustomLeftShoesAccessoryId, CustomMoodId, CustomNeckAccessoryId,
    CustomPantsAccessoryId, CustomRightArmId, CustomRightLegId, CustomRightShoesAccessoryId,
    CustomRunAnimationId, CustomShirtAccessoryId, CustomShortsAccessoryId,
    CustomShoulderAccessoryId, CustomSweaterAccessoryId, CustomSwimAnimationId,
    CustomSwimIdleAnimationId, CustomTShirtAccessoryId, CustomTorsoId, CustomWaistAccessoryId,
    CustomWalkAnimationId, CycleOffset, D, Damping, DataComplexityLimit, DecayRatio,
    DecayTime, DecelerationTime, Delay, DelayTime, Density, Depth, DepthScale, DesiredAngle,
    DestroyJointRadiusPercent, DiagonalFieldOfView, Diffusion, DisplayOrder, DistanceFactor,
    DistanceLowerLimit, DistanceStep, DistanceUpperLimit, DistributedGameTime, DopplerScale,
    Drag, DragRotation, DraggerLengthFactor, DraggerMajorGridIncrement, DraggerMaxSoftSnaps,
    DraggerScaleFactor, DraggerSoftSnapMarginFactor, DraggerSummonMarginFactor,
    DraggerTiltRotateDuration, DryLevel, Duration, Duty, EarlyDelayTime, EmissiveStrength,
    EmitterSize, EnvironmentDiffuseScale, EnvironmentSpecularScale, ExplorerImageIndex,
    ExplorerOrder, ExposureCompensation, EyesLookDown, EyesLookLeft, EyesLookRight,
    EyesLookUp, Face, FallAnimation, FallenPartsDestroyHeight, FarIntensity, Feedback,
    FieldOfView, FillDirectionMaxCells, FillTransparency, FlatPucker, FlipbookSizeX,
    FlipbookSizeY, FluidForceDrawScale, FocusDistance, FogEnd, FogStart, Force,
    ForceDrawScale, ForceVisualizationSmoothingSteps, FrameId, FreeLength, Frequency,
    Friction, FrictionWeight, Funneler, Gain, GainMakeup, GamepadCameraSensitivity,
    GeographicLatitude, Glare, GraphicTShirt, GraphicsQualityLevel, Gravity, GroundOffset,
    GroupTransparency, GrowRatio, Haze, Head, HeadBaseSize, HeadScale, Health,
    HealthDisplayDistance, Heat, Height, HeightScale, HighCutFrequency, HighGain, HipHeight,
    HipHeightScales, HoldDuration, HoverAnimateFrequency, HoverThickness, IdleAnimation,
    ImageTransparency, InFocusRadius, InboundNetworkJitterMs, InboundNetworkLossPercent,
    InboundNetworkMinDelayMs, InclinationAngle, IncomingReplicationLag, IndexSize,
    InnerRadius, InputLatency, Intensity, InviteUser, JawDrop, JawLeft, JawRight,
    JumpAnimation, JumpHeight, JumpPower, LODLevel, LadderSearchHeight, LadderSearchOffset,
    LargeFileLineCountThreshold, LargeFileThreshold, LateDelayTime, LayoutOrder,
    LeftAnkleSize, LeftArm, LeftBrowLowerer, LeftCheekPuff, LeftCheekRaiser, LeftClavicleSize,
    LeftDimpler, LeftElbowSize, LeftEyeClosed, LeftEyeUpperLidRaiser, LeftHipSize,
    LeftInnerBrowRaiser, LeftKneeSize, LeftLeg, LeftLipCornerDown, LeftLipCornerPuller,
    LeftLipStretcher, LeftLowerLipDepressor, LeftNoseWrinkler, LeftOuterBrowRaiser,
    LeftShoulderSize, LeftToeBaseSize, LeftUpperLipRaiser, LeftWristSize, Length, Level,
    Lifetime, LightEmission, LightInfluence, LimitAngle0, LimitAngle1, LineHeight,
    LineThickness, LineVelocity, LinearDamping, LinearResponsiveness, LinearSnapIncrement,
    LinearStrength, LipPresser, LipsTogether, LowGain, LowShelfFrequency, LowShelfGain,
    LowerAngle, LowerLimit, LowerLipSuck, Magnitude, MakeupGain, MasterVolume,
    MasterVolumeStudio, MaxAcceleration, MaxActivationDistance, MaxAngle, MaxAngularVelocity,
    MaxAxisDistance, MaxAxisFieldOfView, MaxBlurSize, MaxBubbles, MaxDistance, MaxDragAngle,
    MaxDuration, MaxFindReplaceAllResults, MaxForce, MaxFrictionTorque, MaxHealth,
    MaxIndicatorDistance, MaxIndicatorsVisible, MaxItems, MaxLength, MaxLevel, MaxPlayers,
    MaxPromptsVisible, MaxRollAngleLeft, MaxRollAngleRight, MaxSlopeAngle, MaxSpeed,
    MaxTextSize, MaxThrust, MaxTorque, MaxValue, MaxVelocity, MaxVisibleGraphemes,
    MaximumSimulationRadius, MeshCacheSize, MeshId, MidGain, MiddleSize, MinDistance,
    MinDragAngle, MinDuration, MinLength, MinTextSize, MinValue, MinimizeDistance, Mix,
    MoodAnimation, MoonAngularSize, MotorMaxAcceleration, MotorMaxAngularAcceleration,
    MotorMaxForce, MotorMaxTorque, MouseDeltaSensitivity, MouseSensitivity, MouthLeft,
    MouthRight, MoveMaxForce, MoveSpeedFactor, NameDisplayDistance, NearIntensity, NearPlaneZ,
    NeckSize, NumPlayers, NumberOfPlayers, Octave, Offset, OffsetStudsU, OffsetStudsV,
    Opacity, Order, OutboundNetworkJitterMs, OutboundNetworkLossPercent,
    OutboundNetworkMinDelayMs, OutlineTransparency, OverlayTextureId, P, Padding,
    PaddingBottom, PaddingLeft, PaddingRight, PaddingTop, Pants, PartyVoiceVolume, PinkySize,
    Pitch, PitchMaxTorque, PitchSpeedFactor, PixelsPerStud, PlaybackSpeed, PointerIndex, Port,
    PreferredUploadId, PressedThreshold, PriorFrameInvoked, Priority, PromptHoldDuration,
    PropertyOrder, ProportionScale, Pucker, Q, QualityLevel, RCCProfilerRecordFrameRate,
    RCCProfilerRecordTimeFrame, Radius, RampTime, Range, Rate, Ratio, ReferenceFrequency,
    Reflectance, Release, ReleasedThreshold, RenderingTestFrameCount, RespawnTime,
    ResponseCurve, Responsiveness, Restitution, RightAnkleSize, RightArm, RightBrowLowerer,
    RightCheekPuff, RightCheekRaiser, RightClavicleSize, RightDimpler, RightElbowSize,
    RightEyeClosed, RightEyeUpperLidRaiser, RightHipSize, RightInnerBrowRaiser, RightKneeSize,
    RightLeg, RightLipCornerDown, RightLipCornerPuller, RightLipStretcher,
    RightLowerLipDepressor, RightNoseWrinkler, RightOuterBrowRaiser, RightShoulderSize,
    RightToeBaseSize, RightUpperLipRaiser, RightWristSize, RingSize, RiseVelocity,
    RollMaxTorque, RollOffMaxDistance, RollOffMinDistance, RollSpeedFactor, RolloffScale,
    RootPriority, RootSize, Rotation, RunAnimation, Saturation, Scale, ScaleFactor,
    ScriptTimeoutLength, ScrollBarImageTransparency, ScrollBarThickness, SearchDistance, Seed,
    Segments, SelectedControlPoint, SelectionModeRotateSpeed, SelectionOrder, SelectionStart,
    ServoMaxForce, ServoMaxTorque, ShadowSoftness, Shape, ShapePartial, Shirt, ShrinkRatio,
    Sides, SimulateSecondsLag, SimulationRadius, Size, Skew, SliceScale, SmoothTime,
    SmoothingAngle, Speed, SpineSize, Spread, SpringDamping, SpringStiffness, Square,
    StandForce, StandSpeed, StarCount, Steer, SteerFloat, StepIdOffset, Stiffness,
    StudsBetweenTextures, StudsPerTile, StudsPerTileU, StudsPerTileV, SunAngularSize,
    SurfaceTransparency, SwimAnimation, TargetAngle, TargetPosition, TargetRadius,
    Temperature, TextSize, TextStrokeTransparency, TextTransparency, TextureLength,
    TextureSpeed, Thickness, Threshold, Throttle, ThrottleAdjustTime, ThrottleFloat, ThrustD,
    ThrustP, ThrustSpeed, ThumbSize, Time, TimePosition, TimeScale, Timeout, TongueDown,
    TongueOut, TongueUp, ToolPunchThroughDistance, TopP, Torque, TorqueDrawScale, Torso,
    TrackballRadialPullFactor, TrackballRollFactor, Transparency, TriangleCount,
    TriggerDistance, TurnD, TurnMaxTorque, TurnP, TurnSpeed, TurnSpeedFactor, TweenTime,
    TwistLowerAngle, TwistUpperAngle, UIMaximum, UIMinimum, UINumTicks, UpperAngle,
    UpperLimit, UpperLipSuck, UserId, VRRotationIntensity, Value, Velocity,
    VelocityInheritance, VersionNumber, VersionedAssetId, VerticalStudsOffset,
    VideoTransparency, VoiceChatVolume, Volume, WaistSize, WalkAnimation, WalkSpeed,
    WalkSpeedScales, WaterReflectance, WaterTransparency, WaterWaveSize, WaterWaveSpeed,
    Weight, WetLevel, Width, Width0, Width1, WidthScale, WinchForce, WinchResponsiveness,
    WinchSpeed, WinchTarget, WireRadius, ZIndex, ZOffset,
}

local positiveNumberProps = {
    AccelerationTime, AirDensity, AirTurbulenceIntensity, Angle, AngleSnapIncrement,
    AngularDamping, AngularResponsiveness, AngularRestitution, AngularSpeed, AspectRatio,
    BalanceMaxTorque, BalanceSpeed, BaseAngle, BaseMoveSpeed, BaseTurnSpeed, BlastPressure,
    BlastRadius, BodyTypeScale, BorderSizePixel, Brightness, CameraMaxZoomDistance,
    CameraMinZoomDistance, CameraZoomSpeed, CharacterJumpHeight, CharacterJumpPower,
    CharacterMaxSlopeAngle, CharacterWalkSpeed, ChestSize, ClockTime, ComparisonDiffThreshold,
    ComparisonPsnrThreshold, ConversationDistance, CurrentAngle, CursorPosition, CurveSize0,
    CurveSize1, CycleOffset, Damping, DataComplexityLimit, DecayRatio, DecayTime,
    DecelerationTime, DelayTime, Density, Depth, DepthScale, DesiredAngle,
    DestroyJointRadiusPercent, DiagonalFieldOfView, DistanceFactor, DistanceLowerLimit,
    DistanceStep, DistanceUpperLimit, DistributedGameTime, DopplerScale, DraggerLengthFactor,
    DraggerScaleFactor, EarlyDelayTime, EmitterSize, EnvironmentDiffuseScale,
    EnvironmentSpecularScale, FallenPartsDestroyHeight, FarIntensity, FieldOfView,
    FlipbookSizeX, FlipbookSizeY, FluidForceDrawScale, FocusDistance, FogEnd, FogStart, Force,
    ForceDrawScale, ForceVisualizationSmoothingSteps, FreeLength, Frequency, Friction,
    FrictionWeight, Glare, Gravity, GroundOffset, Haze, HeadBaseSize, HeadScale, Health,
    HealthDisplayDistance, Height, HeightScale, HighCutFrequency, HipHeight, HipHeightScales,
    HoverAnimateFrequency, HoverThickness, InFocusRadius, InclinationAngle, IndexSize,
    InnerRadius, Intensity, JumpHeight, JumpPower, LadderSearchHeight, LadderSearchOffset,
    LargeFileLineCountThreshold, LargeFileThreshold, LateDelayTime, LayoutOrder,
    LeftAnkleSize, LeftClavicleSize, LeftElbowSize, LeftHipSize, LeftKneeSize,
    LeftShoulderSize, LeftToeBaseSize, LeftWristSize, Length, Lifetime, LightEmission,
    LightInfluence, LimitAngle0, LimitAngle1, LineHeight, LineThickness, LinearDamping,
    LinearResponsiveness, LowShelfFrequency, LowerAngle, MasterVolume, MasterVolumeStudio,
    MaxAcceleration, MaxActivationDistance, MaxAngle, MaxAxisDistance, MaxBlurSize,
    MaxDistance, MaxDragAngle, MaxForce, MaxFrictionTorque, MaxHealth, MaxIndicatorDistance,
    MaxIndicatorsVisible, MaxItems, MaxLength, MaxPlayers, MaxPromptsVisible,
    MaxRollAngleLeft, MaxRollAngleRight, MaxSlopeAngle, MaxSpeed, MaxTextSize, MaxThrust,
    MaxTorque, MaxVisibleGraphemes, MaximumSimulationRadius, MeshCacheSize, MiddleSize,
    MinDistance, MinDragAngle, MinLength, MinTextSize, MinimizeDistance, MoonAngularSize,
    MotorMaxForce, MotorMaxTorque, MoveMaxForce, MoveSpeedFactor, NameDisplayDistance,
    NearIntensity, NearPlaneZ, NeckSize, NumPlayers, Offset, OffsetStudsU, OffsetStudsV,
    Padding, PaddingBottom, PaddingLeft, PaddingRight, PaddingTop, PartyVoiceVolume,
    PinkySize, PitchMaxTorque, PitchSpeedFactor, PixelsPerStud, PlaybackSpeed,
    PressedThreshold, PromptHoldDuration, ProportionScale, RCCProfilerRecordFrameRate,
    RCCProfilerRecordTimeFrame, Radius, RampTime, Range, Rate, ReferenceFrequency,
    ReleasedThreshold, RenderingTestFrameCount, RespawnTime, Responsiveness, Restitution,
    RightAnkleSize, RightClavicleSize, RightElbowSize, RightHipSize, RightKneeSize,
    RightShoulderSize, RightToeBaseSize, RightWristSize, RingSize, RollMaxTorque,
    RollOffMaxDistance, RollOffMinDistance, RollSpeedFactor, RolloffScale, RootSize, Scale,
    ScaleFactor, ScriptTimeoutLength, ScrollBarThickness, SearchDistance,
    SelectionModeRotateSpeed, ServoMaxForce, ServoMaxTorque, SimulationRadius, Size,
    SliceScale, SmoothTime, SmoothingAngle, Speed, SpineSize, Spread, SpringDamping,
    SpringStiffness, StandForce, StandSpeed, StarCount, StepIdOffset, Stiffness,
    StudsPerTileU, StudsPerTileV, SunAngularSize, TargetAngle, TargetPosition, TargetRadius,
    TextSize, TextureLength, TextureSpeed, Thickness, Threshold, ThrottleAdjustTime,
    ThrustSpeed, ThumbSize, Time, TimePosition, TimeScale, Timeout, ToolPunchThroughDistance,
    Torque, TorqueDrawScale, TriangleCount, TriggerDistance, TurnMaxTorque, TurnSpeed,
    TurnSpeedFactor, TweenTime, TwistLowerAngle, TwistUpperAngle, UpperAngle,
    VRRotationIntensity, VerticalStudsOffset, VoiceChatVolume, Volume, WaistSize, WalkSpeed,
    WalkSpeedScales, WaterWaveSize, WaterWaveSpeed, Width, Width0, Width1, WidthScale,
    WinchForce, WinchResponsiveness, WinchSpeed, WireRadius, ZIndex, ZOffset,
}

local booleanPseudoProps = {
    AcousticSimulationEnabled, Active, AddModelToInventory, AddPathsToBundle,
    AlignDraggedObjects, AllScopes, AllTutorialsDisabled, AllowInsertFreeAssets, AllowSleep,
    AllowTeamChangeOnTouch, AllowThirdPartySales, AlwaysOnTop, Anchored, AngleSnapEnabled,
    AngularLimitsEnabled, AnimateHover, Animated, ApplyAtCenterOfMass, Archivable,
    AreAnchorsShown, AreAssembliesShown, AreAssemblyCentersOfMassShown,
    AreAwakePartsHighlighted, AreBodyTypesShown, AreCollisionCostsShown,
    AreConstraintForcesShownForSelectedOrHoveredInstances,
    AreConstraintTorquesShownForSelectedOrHoveredInstances,
    AreContactForcesShownForSelectedOrHoveredAssemblies, AreContactIslandsShown,
    AreContactPointsShown, AreGravityForcesShownForSelectedOrHoveredAssemblies,
    AreJointCoordinatesShown, AreMagnitudesShownForDrawnForcesAndTorques, AreMechanismsShown,
    AreModelCoordsShown, AreNonAnchorsShown, AreOwnersShown, ArePartCoordsShown,
    AreRegionsShown, AreSolverIslandsShown, AreTerrainReplicationRegionsShown,
    AreTimestepsShown, AreUnalignedPartsShown, AreWorldCoordsShown, AudioCanCollide,
    AutoAssignable, AutoButtonColor, AutoHideParent, AutoJumpEnabled, AutoLoad, AutoLocalize,
    AutoPlay, AutoResumeSyncOnPlaceOpen, AutoRotate, AutoRuns, AutoSelectGuiEnabled,
    AutoUpdate, AutoUpdateEnabled, AutocompleteEnabled, AutocompleteVisible, AutomaticRetry,
    AutomaticScalingEnabled, AvatarGestures, BadgeVisible, BalanceRigidityEnabled,
    BreakJointsOnDeath, Browsable, BubbleChatEnabled, Bypass, CageMeshIntersectedPreview,
    CageNonManifoldPreview, CageOverlappingVerticesPreview, CageUVMisMatchedPreview,
    CameraAdaptiveSpeed, CameraAltLeftMouseToRotate, CameraTweenFocus,
    CameraZoomToMousePosition, CanBeDropped, CanCollide, CanLoadCharacterAppearance, CanQuery,
    CanSend, CanTouch, CastShadow, CelestialBodiesShown, CharacterAutoLoads,
    CharacterBreakJointsOnDeath, CharacterUseJumpPower, ChatTranslationEnabled, ChatVisible,
    Circular, ClampMagnitudeToOne, ClassicDeath, ClearTextOnFocus, ClickablePrompt,
    ClickableWhenViewportHidden, ClientOnly, ClipToDeviceSafeArea, ClipsDescendants,
    CloseWhenScreenshotTaken, Closed, CollisionsEnabled, CommandBarEnterExec,
    CommandBarLocalState, ContinueExecution, CoverageInfo, CreateDefaultCommands,
    CreateDefaultTextChannels, CustomBackAccessoryEnabled, CustomClassicPantsAccessoryEnabled,
    CustomClassicShirtsAccessoryEnabled, CustomClassicTShirtsAccessoryEnabled,
    CustomClimbAnimationEnabled, CustomDressSkirtAccessoryEnabled, CustomEyebrowEnabled,
    CustomEyelashEnabled, CustomFaceAccessoryEnabled, CustomFaceEnabled,
    CustomFallAnimationEnabled, CustomFrontAccessoryEnabled, CustomHairAccessoryEnabled,
    CustomHeadAccessoryEnabled, CustomHeadEnabled, CustomIdleAlt1AnimationEnabled,
    CustomIdleAlt2AnimationEnabled, CustomIdleAnimationEnabled, CustomJacketAccessoryEnabled,
    CustomJumpAnimationEnabled, CustomLeftArmEnabled, CustomLeftLegEnabled,
    CustomLeftShoesAccessoryEnabled, CustomMoodEnabled, CustomNeckAccessoryEnabled,
    CustomPantsAccessoryEnabled, CustomRightArmEnabled, CustomRightLegEnabled,
    CustomRightShoesAccessoryEnabled, CustomRunAnimationEnabled, CustomShirtAccessoryEnabled,
    CustomShortsAccessoryEnabled, CustomShoulderAccessoryEnabled,
    CustomSweaterAccessoryEnabled, CustomSwimAnimationEnabled, CustomSwimIdleAnimationEnabled,
    CustomTShirtAccessoryEnabled, CustomTorsoEnabled, CustomWaistAccessoryEnabled,
    CustomWalkAnimationEnabled, DebugInfo, Deprecated, DeprecatedObjectsShown,
    DevEnableMouseLock, DiffractionEnabled, DisableCSGv2, DisableCSGv3ForPlugins,
    DisableUIDragDetectorDrags, Disabled, DoubleSided, DraggerShowAxisTicks,
    DraggerShowHoverRuler, DraggerShowMeasurement, DraggerShowNegativeAxes, DraggerShowPlanes,
    DraggerShowTargetSnap, DraggerShowTrackball, DraggerShowWhileDragging,
    DrawConstraintsNetForce, DrawContactsNetForce, DrawTotalNetForce, EagerBulkExecution,
    EditModeActive, EditingDisabled, Editor, EnableClimbing, EnableCodeAssist,
    EnableCrouching, EnableDefaultVoice, EnableEmissives, EnableFallingDown, EnableFindOnType,
    EnableFluidForces, EnableForceVisualizationSmoothing, EnableGettingUp, EnableHolding,
    EnableIndentationRulers, EnableJumping, EnableMouseLockOption, EnableReaching,
    EnableRunning, EnableSelectionTooltips, EnableSitting, EnableSkinning, EnableSound,
    EnableSprinting, EnableStrafing, EnableStudioStreaming, EnableSwimming, EnableVFX,
    EnableVideoAds, Enabled, EvaluateStateMachine, ExecuteWithStudioRun,
    ExportMergeByMaterial, FaceCamera, FadeOutViewOnCollision, FallHeightEnabled,
    FillEmptySpaceColumns, FillEmptySpaceRows, FlattenTree, FlipbookBlendFrames,
    FlipbookStartRandom, ForceLimitsEnabled, ForwardInput, Fullscreen, FullySubmerged,
    GamepadCursorEnabled, GamepadInputEnabled, GlobalShadows, GoodbyeChoiceActive,
    GuiNavigationEnabled, HasEverUsedVR, HasRobloxSubscription, HasVerifiedBadge, HeadLocked,
    HeadsUpDisplay, HideCoreGuiForCaptures, HidePlayerGuiForCaptures, HighCompression, Hollow,
    HttpEnabled, HttpProxyEnabled, IgnoreGuiInset, IgnoreVertexColors, ImportAsModelAsset,
    ImportAsPackage, InUse, InsertInWorkspace, InsertWithScenePosition, Insertable,
    Interactable, InverseSquareLaw, InvertNegativeFaces, IrrelevantCageModifiedPreview,
    IsArrowVisible, IsBackend, IsBidirectional, IsCaptureModeForReport, IsDebuggable,
    IsEnabled, IsInterpolationThrottleShown, IsKinematic, IsLayered,
    IsPhysicsEnvironmentalThrottled, IsPlaying, IsReceiveAgeShown, IsRecording,
    IsScriptStackTracingEnabled, IsSleepAllowed, IsTreeShown, JointsEnabled, Jump,
    KeepPlayerHead, KeepZeroInfluenceBones, LimitsEnabled, LinearSnapEnabled,
    LoadAllBuiltinPluginsInRunModes, LoadCharacterAppearance, LoadDefaultChat,
    LoadInternalPlugins, LoadUserPluginsInRunModes, Loaded, LockCameraSpeed, Locked,
    LockedToPart, LoggingEnabled, Loop, Looped, Looping, LuaDebuggerEnabled,
    MaintainAngularMomentum, MaintainLinearMomentum, ManualActivationOnly, Massless,
    MaxQualityEnabled, MergeMeshes, MeshHoleDetectedPreview, Modal, MouseIconEnabled,
    MultiLine, Muted, Neutral, OcclusionEnabled, Open, OuterCageFarExtendedFromMeshPreview,
    PackAsSource, PartSnapEnabled, PassThrough, PerfTest, PivotSnapToGeometry, PlatformStand,
    PlayOnRemove, PlaybackRegionsEnabled, PlayerListVisible, PlayerNamesEnabled, Playing,
    PluginDebuggingEnabled, PreferLodEnabled, PrimaryAxisOnly, PrintJoinSizeBreakdown,
    PrintPhysicsErrors, PrintStreamInstanceQuota, PrioritizeLightingQuality, PublishLocked,
    QualityAuto, RandomizeJoinInstanceOrder, ReactionForceEnabled, ReactionTorqueEnabled,
    ReloadAssets, ReloadBuiltinPluginsOnChange, ReloadLocalPluginsOnChange,
    RenderCSGTrianglesDebug, RenderStreamedRegions, ReportSoundWarnings, RequiresHandle,
    RequiresLineOfSight, RequiresNeck, ResetOnSpawn, RespectFilteringEnabled, ReverbEnabled,
    RichText, RigVisualization, RigidityEnabled, RotationAxisVisible, RunLocally, Sandboxed,
    ScrollWheelInputEnabled, ScrollingEnabled, Selectable, Selected, SelectionGroup,
    SerializePatch, ServerOnly, Shadows, ShouldImport, ShouldReserveServer, ShouldSkip,
    ShowActiveAnimationAsset, ShowBoundingBoxes, ShowCorePackagesInExplorer,
    ShowDecompositionGeometry, ShowDevelopmentGui,
    ShowFluidForcesForSelectedOrHoveredMechanisms, ShowHover,
    ShowInstanceNamesForDrawnForcesAndTorques, ShowNativeInput, ShowPivotIndicator, Sink, Sit,
    SpectrumEnabled, StartServer, StaticFacialAnimation, StickyWheels, StreamingEnabled,
    TailVisible, TextEditable, TextScaled, TextWrapped, ThrottlePhysicsToRealtime,
    TouchControlsEnabled, TouchInputEnabled, TouchingSurface, TwistLimitsEnabled,
    Use2022Materials, UseAvatarSettings, UseCSGv2, UseCache, UseDefaultExternalEditor,
    UseFileLevelCompressionInsteadOfChunk, UseImportedPivot, UseJumpPower, UseLocalSpace,
    UsePartColor, UseSceneOriginAsPivot, UsedCoreGuiIsVisibleToggle,
    UsedCustomGuiIsVisibleToggle, UsedHideHudShortcut, UserEmotesEnabled, UsesCages,
    VREnabled, VRSmoothRotationEnabled, VRTiltAndRollEnabled, ValidateUgcBody, Value,
    VignetteEnabled, Visible, WinchEnabled, WindAffectsDrag, Wraps, ZstdCompression,
    isContextDependentBreakpoint,
}

local stringPseudoProps = {
    ActionText, AdorneeName, Album, Artist, AudioInteractionGroup, BackAccessory, CameraId,
    ClassCategory, CollisionGroup, Condition, Constraint, ContentId, ContextLabel,
    DefaultName, Description, DiffuseFilePath, DisplayLanguage, DisplayName, EditorType,
    EmissiveFilePath, ExistingPackageId, Expression, FFlag, FaceAccessory,
    FlipbookIncompatible, FrontAccessory, GoodbyeDialog, HairAccessory, HatAccessory,
    HeadShape, HttpProxyURL, Icon, ImportName, InitialPrompt, Interface, InviteMessageId,
    Label, LaunchData, LogExpression, Manifest, MaterialVariant, MessageId, Metadata,
    MetalnessFilePath, Name, NeckAccessory, NodeId, NormalFilePath, ObjectText,
    OnboardingsCompleted, OpenTypeFeatures, OutputPath, PatchId, PlaceholderText,
    PreferredParent, PrefixText, PrimaryAlias, PromptMessage, ReservedServerAccessCode,
    ResponseDialog, RoughnessFilePath, Rulers, ScriptContext, SearchKeyword, SecondaryAlias,
    Secrets, SelectedTheme, Selector, ServerInstanceId, ShouldersAccessory, SliderScaling,
    SourceLocaleId, SourceName, SystemPrompt, Tag, TargetName, TargetPath, Text, Ticket,
    TimeOfDay, Title, ToolTip, Translation, UserDialog, Value, VoiceId, WaistAccessory,
}

local color3PseudoProps = {
    Ambient, BackgroundColor3, BorderColor3, Color, Color3, ColorShift_Bottom, ColorShift_Top,
    Decay, DraggerActiveColor, DraggerPassiveColor, EmissiveTint, FillColor, FogColor,
    GeometrySnapColor, GroupColor3, HeadColor, HeadColor3, HintColor, HoverBackgroundColor3,
    ImageColor3, IndentationRulerColor, InformationColor, LeftArmColor, LeftArmColor3,
    LeftLegColor, LeftLegColor3, LightColor, OutdoorAmbient, OutlineColor, PlaceholderColor3,
    RightArmColor, RightArmColor3, RightLegColor, RightLegColor3, ScrollBarImageColor3,
    SecondaryColor, SelectedTabTextColor3, SparkleColor, SurfaceColor3, TextColor3,
    TextStrokeColor3, TintColor, TorsoColor, TorsoColor3, TypeColor, VAxisColor, Value,
    VideoColor3, WaterColor, XAxisColor, YAxisColor, ZAxisColor,
}

local vector3PseudoProps = {
    Acceleration, AngularVelocity, AssemblyAngularVelocity, AssemblyLinearVelocity, Axis,
    CameraOffset, ChestRangeMax, ChestRangeMin, Delta, ExtentsOffset, ExtentsOffsetWorldSpace,
    F0, F1, F2, F3, FacingDirection, Force, GlobalWind, HeadBaseRangeMax, HeadBaseRangeMin,
    HitNormal, IndexRange, InsertPoint, LeftAnkleRangeMax, LeftAnkleRangeMin,
    LeftClavicleRangeMax, LeftClavicleRangeMin, LeftElbowRangeMax, LeftElbowRangeMin,
    LeftHipRangeMax, LeftHipRangeMin, LeftKneeRangeMax, LeftKneeRangeMin,
    LeftShoulderRangeMax, LeftShoulderRangeMin, LeftToeBaseRangeMax, LeftToeBaseRangeMin,
    LeftWristRangeMax, LeftWristRangeMin, LightDirection, LimitBounds, LineDirection,
    LocalPlayerStudsOffset, Location, LookAtPosition, MaxAxesForce, MaxDragTranslation,
    MaxForce, MaxTorque, MiddleRange, MinDragTranslation, MovingDirection, NeckRangeMax,
    NeckRangeMin, Offset, Orientation, PinkyRange, Point, Position, PrimaryAxis,
    PrimaryTangentAxis, RightAnkleRangeMax, RightAnkleRangeMin, RightClavicleRangeMax,
    RightClavicleRangeMin, RightElbowRangeMax, RightElbowRangeMin, RightHipRangeMax,
    RightHipRangeMin, RightKneeRangeMax, RightKneeRangeMin, RightShoulderRangeMax,
    RightShoulderRangeMin, RightToeBaseRangeMax, RightToeBaseRangeMin, RightWristRangeMax,
    RightWristRangeMin, RingRange, RootRangeMax, RootRangeMin, Rotation, Scale, SecondaryAxis,
    SecondaryTangentAxis, SingleColliderSize, Size, SizeRelativeOffset, SkyboxOrientation,
    SpineRangeMax, SpineRangeMin, StudsOffset, StudsOffsetWorldSpace, TargetOffset,
    TargetPoint, ThumbRange, Torque, TriggerOffset, UpDirection, Value, Vector3Scale,
    VectorVelocity, Velocity, VertexColor, WaistRangeMax, WaistRangeMin, WalkToPoint,
    WorldAxis, WorldSecondaryAxis,
}

local udim2PseudoProps = {
    CameraButtonPosition, CanvasSize, CellPadding, CellSize, CloseButtonPosition, DragUDim2,
    MaxDragTranslation, MinDragTranslation, Offset, Padding, Position, SelectionModeDragSpeed,
    Size, Spread, TileSize,
}
local classDefaultProperties: { [string]: { [string]: any } } = {
    AccessoryDescription = {
        AssetId = 0, IsLayered = false, Order = 0, Position = "Vector3", Rotation = "Vector3", Scale = "Vector3",
    },
    Accoutrement = {
        AttachmentPoint = "CFrame",
    },
    Actor = {},
    AdGui = {
        EnableVideoAds = false,
    },
    AdService = {},
    AirController = {
        BalanceMaxTorque = 0, BalanceSpeed = 0, MaintainAngularMomentum = false, MaintainLinearMomentum = false,
        MoveMaxForce = 0, TurnMaxTorque = 0, TurnSpeedFactor = 0,
    },
    AlignOrientation = {
        CFrame = "CFrame", LookAtPosition = "Vector3", MaxAngularVelocity = 0, MaxTorque = 0, PrimaryAxis = "Vector3",
        PrimaryAxisOnly = false, ReactionTorqueEnabled = false, Responsiveness = 0, RigidityEnabled = false,
        SecondaryAxis = "Vector3",
    },
    AlignPosition = {
        ApplyAtCenterOfMass = false, MaxAxesForce = "Vector3", MaxForce = 0, MaxVelocity = 0, Position = "Vector3",
        ReactionForceEnabled = false, Responsiveness = 0, RigidityEnabled = false,
    },
    AngularVelocity = {
        AngularVelocity = "Vector3", MaxTorque = 0, ReactionTorqueEnabled = false,
    },
    AnimationClip = {
        Loop = false,
    },
    AnimationClipProvider = {},
    AnimationConstraint = {
        AngularDamping = 0, AngularStrength = 0, IsKinematic = false, LinearDamping = 0, LinearStrength = 0,
        MaxForce = 0, MaxTorque = 0, Transform = "CFrame",
    },
    AnimationTrack = {
        Looped = false, TimePosition = 0,
    },
    Animator = {
        PreferLodEnabled = false,
    },
    AppStorageService = {},
    AppUpdateService = {},
    AssetDeliveryProxy = {
        Interface = "", Port = 0, StartServer = false,
    },
    AssetPatchSettings = {
        ContentId = "", OutputPath = "", PatchId = "",
    },
    AssetService = {
        AllowInsertFreeAssets = false,
    },
    Atmosphere = {
        Color = "Color3", Decay = "Color3", Density = 0.395, Glare = 0, Haze = 0, Offset = 0,
    },
    Attachment = {
        Axis = "Vector3", CFrame = "CFrame", SecondaryAxis = "Vector3", Visible = false, WorldAxis = "Vector3",
        WorldCFrame = "CFrame", WorldSecondaryAxis = "Vector3",
    },
    AudioAnalyzer = {
        SpectrumEnabled = false,
    },
    AudioChorus = {
        Bypass = false, Depth = 0, Mix = 0, Rate = 0,
    },
    AudioCompressor = {
        Attack = 0, Bypass = false, MakeupGain = 0, Ratio = 0, Release = 0, Threshold = 0,
    },
    AudioDeviceInput = {
        Active = false, Muted = false, Volume = 0,
    },
    AudioDistortion = {
        Bypass = false, Level = 0,
    },
    AudioEcho = {
        Bypass = false, DelayTime = 0, DryLevel = 0, Feedback = 0, RampTime = 0, WetLevel = 0,
    },
    AudioEmitter = {
        AcousticSimulationEnabled = false, AudioInteractionGroup = "",
    },
    AudioEqualizer = {
        Bypass = false, HighGain = 0, LowGain = 0, MidGain = 0, MidRange = "NumberRange",
    },
    AudioFader = {
        Bypass = false, Volume = 0,
    },
    AudioFilter = {
        Bypass = false, Frequency = 0, Gain = 0, Q = 0,
    },
    AudioFlanger = {
        Bypass = false, Depth = 0, Mix = 0, Rate = 0,
    },
    AudioFocusService = {},
    AudioGate = {
        Attack = 0, Bypass = false, Release = 0, Threshold = "NumberRange",
    },
    AudioLimiter = {
        Bypass = false, MaxLevel = 0, Release = 0,
    },
    AudioListener = {
        AcousticSimulationEnabled = false, AudioInteractionGroup = "",
    },
    AudioPitchShifter = {
        Bypass = false, Pitch = 0,
    },
    AudioPlayer = {
        AutoLoad = false, AutoPlay = false, IsPlaying = false, LoopRegion = "NumberRange", Looping = false,
        PlaybackRegion = "NumberRange", PlaybackSpeed = 0, TimePosition = 0, Volume = 0,
    },
    AudioRecorder = {
        IsRecording = false,
    },
    AudioReverb = {
        Bypass = false, DecayRatio = 0, DecayTime = 0, Density = 0, Diffusion = 0, DryLevel = 0,
        EarlyDelayTime = 0, HighCutFrequency = 0, LateDelayTime = 0, LowShelfFrequency = 0, LowShelfGain = 0,
        ReferenceFrequency = 0, WetLevel = 0,
    },
    AudioSearchParams = {
        Album = "", Artist = "", MaxDuration = 0, MinDuration = 0, SearchKeyword = "", Tag = "",
        Title = "",
    },
    AudioSpeechToText = {
        Enabled = false, Text = "",
    },
    AudioTextToSpeech = {
        IsPlaying = false, Looping = false, Pitch = 0, PlaybackSpeed = 0, Speed = 0, Text = "",
        TimePosition = 0, VoiceId = "", Volume = 0,
    },
    AudioTremolo = {
        Bypass = false, Depth = 0, Duty = 0, Frequency = 0, Shape = 0, Skew = 0, Square = 0,
    },
    AuroraScriptObject = {
        FrameId = 0, LODLevel = 0, PriorFrameInvoked = 0,
    },
    AvatarChatService = {
        ServerFeatures = 0,
    },
    AvatarCreationService = {},
    AvatarEditorService = {},
    BadgeService = {},
    BallSocketConstraint = {
        LimitsEnabled = false, MaxFrictionTorque = 0, Radius = 0, Restitution = 0, TwistLimitsEnabled = false,
        TwistLowerAngle = 0, TwistUpperAngle = 0, UpperAngle = 0,
    },
    BaseCoreGuiConfiguration = {
        Enabled = false,
    },
    BaseImportData = {
        ImportName = "", ShouldImport = false,
    },
    BasePart = {
        Anchored = false, AssemblyAngularVelocity = "Vector3", AssemblyLinearVelocity = "Vector3",
        AudioCanCollide = false, CFrame = "CFrame", CanCollide = true, CanQuery = true, CanTouch = true,
        CastShadow = true, CollisionGroup = "", Color = "Color3", EnableFluidForces = false, Locked = false,
        Massless = false, MaterialVariant = "", PivotOffset = "CFrame", Reflectance = 0, RootPriority = 0,
        Rotation = "Vector3", Size = "Vector3", Transparency = 0, CanFrameCached = true, Archivable = true,
        FrontParamA = -0.5, FrontParamB = 0.5, BackParamA = -0.5, BackParamB = 0.5, LeftParamA = -0.5,
        LeftParamB = 0.5, RightParamA = -0.5, RightParamB = 0.5, TopParamA = -0.5, TopParamB = 0.5,
        BottomParamA = -0.5, BottomParamB = 0.5, Friction = 0.3, Elasticity = 0.2, ElasticityWeight = 1.0,
        FrictionWeight = 1.0, CollisionGroupId = 0,
    },
    BaseScript = {
        Disabled = false, Enabled = false,
    },
    BaseWrap = {
        CageOrigin = "CFrame", ImportOrigin = "CFrame",
    },
    Beam = {
        Brightness = 0, CurveSize0 = 0, CurveSize1 = 0, Enabled = true, FaceCamera = false, LightEmission = 0,
        LightInfluence = 0, Segments = 10, TextureLength = 1, TextureSpeed = 0, Width0 = 1, Width1 = 1,
        ZOffset = 0,
    },
    BillboardGui = {
        Active = false, AlwaysOnTop = false, Brightness = 0, ClipsDescendants = false, DistanceStep = 0,
        ExtentsOffset = "Vector3", ExtentsOffsetWorldSpace = "Vector3", LightInfluence = 0, MaxDistance = 100,
        Size = "UDim2", SizeOffset = "Vector2", StudsOffset = "Vector3", StudsOffsetWorldSpace = "Vector3",
        PixelsPerStud = 50,
    },
    BindableEvent = {},
    BindableFunction = {},
    BloomEffect = {
        Intensity = 0.4, Size = 24, Threshold = 0.95, Enabled = true,
    },
    BlurEffect = {
        Size = 24, Enabled = true,
    },
    BodyAngularVelocity = {
        AngularVelocity = "Vector3", MaxTorque = "Vector3", P = 0,
    },
    BodyColors = {
        HeadColor3 = "Color3", LeftArmColor3 = "Color3", LeftLegColor3 = "Color3", RightArmColor3 = "Color3",
        RightLegColor3 = "Color3", TorsoColor3 = "Color3",
    },
    BodyForce = {
        Force = "Vector3",
    },
    BodyGyro = {
        CFrame = "CFrame", D = 0, MaxTorque = "Vector3", P = 0,
    },
    BodyPartDescription = {
        AssetId = 0, Color = "Color3", HeadShape = "",
    },
    BodyPosition = {
        D = 0, MaxForce = "Vector3", P = 0, Position = "Vector3",
    },
    BodyThrust = {
        Force = "Vector3", Location = "Vector3",
    },
    BodyVelocity = {
        MaxForce = "Vector3", P = 0, Velocity = "Vector3",
    },
    Bone = {
        Transform = "CFrame",
    },
    BoolValue = {
        Value = false,
    },
    BoxHandleAdornment = {
        Size = "Vector3",
    },
    BubbleChatConfiguration = {
        AdorneeName = "", BackgroundColor3 = "Color3", BackgroundTransparency = 0, BubbleDuration = 0,
        BubblesSpacing = 0, Enabled = false, LocalPlayerStudsOffset = "Vector3", MaxBubbles = 0,
        MaxDistance = 0, MinimizeDistance = 0, TailVisible = false, TextColor3 = "Color3", TextSize = 0,
        VerticalStudsOffset = 0,
    },
    BubbleChatMessageProperties = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, TailVisible = false, TextColor3 = "Color3",
        TextSize = 0,
    },
    BuoyancySensor = {
        FullySubmerged = false, TouchingSurface = false,
    },
    CFrameValue = {
        Value = "CFrame",
    },
    Camera = {
        CFrame = "CFrame", DiagonalFieldOfView = 70, FieldOfView = 70, Focus = "CFrame", HeadLocked = true,
        HeadScale = 1, MaxAxisFieldOfView = 70, VRTiltAndRollEnabled = false, CameraType = "Enum.CameraType.Custom",
        CameraMinZoomDistance = 0.5, CameraMaxZoomDistance = 128, MaxRollAngleRight = 0, MaxRollAngleLeft = 0,
        NearPlaneZ = -0.1, FieldOfViewMode = "Enum.FieldOfViewMode.Vertical",
    },
    CanvasGroup = {
        GroupColor3 = "Color3", GroupTransparency = 0,
    },
    CaptureService = {},
    CapturesViewConfiguration = {
        Open = false,
    },
    ChannelSelectorSoundEffect = {
        Channel = 0,
    },
    ChannelTabsConfiguration = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false, HoverBackgroundColor3 = "Color3",
        SelectedTabTextColor3 = "Color3", TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3",
        TextStrokeTransparency = 0,
    },
    CharacterMesh = {
        BaseTextureId = 0, MeshId = 0, OverlayTextureId = 0,
    },
    Chat = {
        BubbleChatEnabled = false, LoadDefaultChat = true, IsAutoMigrated = true, ModerationMode = "TextFilter",
    },
    ChatInputBarConfiguration = {
        AutocompleteEnabled = false, BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false,
        PlaceholderColor3 = "Color3", TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3",
        TextStrokeTransparency = 0,
    },
    ChatWindowConfiguration = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false, HeightScale = 0,
        TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        WidthScale = 0,
    },
    ChatWindowMessageProperties = {
        TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
    },
    ChorusSoundEffect = {
        Depth = 0, Mix = 0, Rate = 0,
    },
    ClickDetector = {
        MaxActivationDistance = 0,
    },
    ClimbController = {
        AccelerationTime = 0, BalanceMaxTorque = 0, BalanceSpeed = 0, MoveMaxForce = 0,
    },
    Clothing = {
        Color3 = "Color3",
    },
    Clouds = {
        Color = "Color3", Cover = 0, Density = 0, Enabled = false,
    },
    CollectionService = {
        NitrateScale = 1,
    },
    Color3Value = {
        Value = "Color3",
    },
    ColorCorrectionEffect = {
        Brightness = 0, Contrast = 0, Saturation = 0, TintColor = "Color3", Enabled = true,
    },
    CompressorSoundEffect = {
        Attack = 0, GainMakeup = 0, Ratio = 0, Release = 0, Threshold = 0,
    },
    ConeHandleAdornment = {
        Height = 0, Hollow = false, Radius = 0,
    },
    Configuration = {},
    Constraint = {
        Enabled = false, Visible = false,
    },
    ContentProvider = {
        RequestQueueSize = 0, CacheAssets = false,
    },
    ContextActionService = {
        NitrateScale = 1,
    },
    ControllerBase = {
        BalanceRigidityEnabled = false, MoveSpeedFactor = 0,
    },
    ControllerManager = {
        BaseMoveSpeed = 0, BaseTurnSpeed = 0, FacingDirection = "Vector3", MovingDirection = "Vector3",
        UpDirection = "Vector3",
    },
    ControllerPartSensor = {
        HitFrame = "CFrame", HitNormal = "Vector3", LadderSearchHeight = 0, LadderSearchOffset = 0,
        SearchDistance = 0,
    },
    CylinderHandleAdornment = {
        Angle = 0, Height = 0, InnerRadius = 0, Radius = 0,
    },
    CylindricalConstraint = {
        AngularLimitsEnabled = false, AngularResponsiveness = 0, AngularRestitution = 0, AngularSpeed = 0,
        AngularVelocity = 0, InclinationAngle = 0, LowerAngle = 0, MotorMaxAngularAcceleration = 0,
        MotorMaxTorque = 0, RotationAxisVisible = false, ServoMaxTorque = 0, TargetAngle = 0, UpperAngle = 0,
    },
    DataModel = {
        CreatorId = 0, CreatorType = "Enum.CreatorType.User", GameId = 0, Genre = "Enum.Genre.All",
        JobId = "", PlaceId = 0, PlaceVersion = 0, PrivateServerId = "", PrivateServerOwnerId = 0,
        Workspace = nil, Guid = "",
    },
    DataModelMesh = {
        Offset = "Vector3", Scale = "Vector3", VertexColor = "Vector3",
    },
    DataStoreGetOptions = {
        UseCache = false,
    },
    DataStoreOptions = {
        AllScopes = false,
    },
    DataStoreService = {
        LegacyNamingScheme = false, AutomaticRetry = true,
    },
    Debris = {
        MaxItems = 1000,
    },
    DebuggerBreakpoint = {
        Condition = "", ContinueExecution = false, IsEnabled = false, LogExpression = "", isContextDependentBreakpoint = false,
    },
    DebuggerWatch = {
        Expression = "",
    },
    Decal = {
        AutoLocalize = false, Color3 = "Color3", Rotation = 0, Transparency = 0, UVOffset = "Vector2",
        UVScale = "Vector2", ZIndex = 1, Shiny = 0, Specular = 0,
    },
    DepthOfFieldEffect = {
        FarIntensity = 0, FocusDistance = 0, InFocusRadius = 0, NearIntensity = 0, Enabled = true,
        FocalLength = 25,
    },
    Dialog = {
        ConversationDistance = 0, GoodbyeChoiceActive = false, GoodbyeDialog = "", InUse = false,
        InitialPrompt = "", TriggerDistance = 0, TriggerOffset = "Vector3",
    },
    DialogChoice = {
        GoodbyeChoiceActive = false, GoodbyeDialog = "", ResponseDialog = "", UserDialog = "",
    },
    DigitsRigDescription = {
        Index1TposeAdjustment = "CFrame", Index2TposeAdjustment = "CFrame", Index3TposeAdjustment = "CFrame",
        IndexRange = "Vector3", IndexSize = 0, Middle1TposeAdjustment = "CFrame", Middle2TposeAdjustment = "CFrame",
        Middle3TposeAdjustment = "CFrame", MiddleRange = "Vector3", MiddleSize = 0, Pinky1TposeAdjustment = "CFrame",
        Pinky2TposeAdjustment = "CFrame", Pinky3TposeAdjustment = "CFrame", PinkyRange = "Vector3",
        PinkySize = 0, Ring1TposeAdjustment = "CFrame", Ring2TposeAdjustment = "CFrame", Ring3TposeAdjustment = "CFrame",
        RingRange = "Vector3", RingSize = 0, Thumb1TposeAdjustment = "CFrame", Thumb2TposeAdjustment = "CFrame",
        Thumb3TposeAdjustment = "CFrame", ThumbRange = "Vector3", ThumbSize = 0,
    },
    DistortionSoundEffect = {
        Level = 0,
    },
    DoubleConstrainedValue = {
        MaxValue = 0, MinValue = 0, Value = 0,
    },
    DragDetector = {
        ApplyAtCenterOfMass = false, Axis = "Vector3", DragFrame = "CFrame", Enabled = false, MaxDragAngle = 0,
        MaxDragTranslation = "Vector3", MaxForce = 0, MaxTorque = 0, MinDragAngle = 0, MinDragTranslation = "Vector3",
        Orientation = "Vector3", Responsiveness = 0, RunLocally = false, SecondaryAxis = "Vector3",
        TrackballRadialPullFactor = 0, TrackballRollFactor = 0, WorldAxis = "Vector3", WorldSecondaryAxis = "Vector3",
    },
    DraggerService = {
        AlignDraggedObjects = false, AngleSnapEnabled = false, AngleSnapIncrement = 0, AnimateHover = false,
        CollisionsEnabled = false, GeometrySnapColor = "Color3", HoverAnimateFrequency = 0, HoverThickness = 0,
        JointsEnabled = false, LinearSnapEnabled = false, LinearSnapIncrement = 0, ShowHover = false,
        ShowPivotIndicator = false,
    },
    DynamicRotate = {
        BaseAngle = 0,
    },
    EchoSoundEffect = {
        Delay = 0, DryLevel = 0, Feedback = 0, WetLevel = 0,
    },
    EqualizerSoundEffect = {
        HighGain = 0, LowGain = 0, MidGain = 0,
    },
    EventIngestService = {},
    ExperienceInviteOptions = {
        InviteMessageId = "", InviteUser = 0, LaunchData = "", PromptMessage = "",
    },
    ExperienceStateCaptureService = {
        HiddenSelectionEnabled = false,
    },
    Explosion = {
        BlastPressure = 500000, BlastRadius = 8, DestroyJointRadiusPercent = 1, Position = "Vector3",
        TimeScale = 1, Visible = true,
    },
    FaceAnimatorService = {
        AudioAnimationEnabled = false, FlipHeadOrientation = false, VideoAnimationEnabled = false,
    },
    Fire = {
        Color = "Color3", Enabled = true, Heat = 1, SecondaryColor = "Color3", Size = 1, TimeScale = 1,
        Lifetime = 1, FadeTime = 1,
    },
    FlangeSoundEffect = {
        Depth = 0, Mix = 0, Rate = 0,
    },
    FloorWire = {
        CycleOffset = 0, StudsBetweenTextures = 0, TextureSize = "Vector2", Velocity = 0, WireRadius = 0,
    },
    FlyweightService = {},
    Folder = {},
    ForceField = {
        Visible = false,
    },
    Frame = {
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ClipsDescendants = false,
        BackgroundColor = "Enum", BorderColor = "Enum",
    },
    FriendService = {},
    FunctionalTest = {
        Description = "",
    },
    GamepadService = {
        GamepadCursorEnabled = false,
    },
    GeometryService = {},
    GetTextBoundsParams = {
        RichText = false, Size = 0, Text = "", Width = 0,
    },
    Glue = {
        F0 = "Vector3", F1 = "Vector3", F2 = "Vector3", F3 = "Vector3",
    },
    GroundController = {
        AccelerationLean = 0, AccelerationTime = 0, BalanceMaxTorque = 0, BalanceSpeed = 0, DecelerationTime = 0,
        Friction = 0, FrictionWeight = 0, GroundOffset = 0, StandForce = 0, StandSpeed = 0, TurnSpeedFactor = 0,
    },
    GroupImportData = {
        Anchored = false, ImportAsModelAsset = false, InsertInWorkspace = false,
    },
    GroupService = {},
    GuiBase2d = {
        AutoLocalize = false, SelectionGroup = false,
    },
    GuiBase3d = {
        Color3 = "Color3", Transparency = 0, Visible = false,
    },
    GuiButton = {
        AutoButtonColor = false, Modal = false, Selected = false,
    },
    GuiObject = {
        Active = false, AnchorPoint = "Vector2", BackgroundColor3 = "Color3", BackgroundTransparency = 0,
        BorderColor3 = "Color3", BorderSizePixel = 0, ClipsDescendants = false, Interactable = false,
        LayoutOrder = 0, Position = "UDim2", Rotation = 0, Selectable = false, SelectionOrder = 0,
        Size = "UDim2", Visible = false, ZIndex = 0,
    },
    GuiService = {
        AutoSelectGuiEnabled = false, GuiNavigationEnabled = false, TouchControlsEnabled = true,
        CoreGuiNavigationEnabled = false, SelectedObject = nil,
    },
    HandleAdornment = {
        AlwaysOnTop = false, CFrame = "CFrame", SizeRelativeOffset = "Vector3", ZIndex = 0,
    },
    HapticEffect = {
        Looped = false, Position = "Vector3", Radius = 0,
    },
    HapticService = {},
    HeapProfilerService = {},
    Highlight = {
        Enabled = false, FillColor = "Color3", FillTransparency = 0, OutlineColor = "Color3", OutlineTransparency = 0,
    },
    HingeConstraint = {
        AngularResponsiveness = 0, AngularSpeed = 0, AngularVelocity = 0, LimitsEnabled = false,
        LowerAngle = 0, MotorMaxAcceleration = 0, MotorMaxTorque = 0, Radius = 0, Restitution = 0,
        ServoMaxTorque = 0, TargetAngle = 0, UpperAngle = 0,
    },
    Hopper = {},
    HopperBin = {
        Active = false, ManualActivationOnly = false, CanBeDropped = true, ToolTip = "",
    },
    HttpRbxApiService = {},
    HttpService = {
        HttpEnabled = false,
    },
    Humanoid = {
        AutoJumpEnabled = false, AutoRotate = true, AutomaticScalingEnabled = true, BreakJointsOnDeath = true,
        CameraOffset = "Vector3", DisplayName = "", EvaluateStateMachine = false, Health = 100,
        HealthDisplayDistance = 100, HipHeight = 0, Jump = false, JumpHeight = 7.2, JumpPower = 50,
        MaxHealth = 100, MaxSlopeAngle = 89, NameDisplayDistance = 100, PlatformStand = false, RequiresNeck = true,
        Sit = false, TargetPoint = "Vector3", UseJumpPower = false, WalkSpeed = 16, WalkToPoint = "Vector3",
        CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, RigScale = 1, DisplayDistanceType = "Enum.HumanoidDisplayDistanceType.Viewer",
        CollisionType = "Enum.HumanoidCollisionType.OuterSurface",
    },
    HumanoidDescription = {
        BackAccessory = "", BodyTypeScale = 0, ClimbAnimation = 0, DepthScale = 0, Face = 0, FaceAccessory = "",
        FallAnimation = 0, FrontAccessory = "", GraphicTShirt = 0, HairAccessory = "", HatAccessory = "",
        Head = 0, HeadColor = "Color3", HeadScale = 0, HeightScale = 0, IdleAnimation = 0, JumpAnimation = 0,
        LeftArm = 0, LeftArmColor = "Color3", LeftLeg = 0, LeftLegColor = "Color3", MoodAnimation = 0,
        NeckAccessory = "", Pants = 0, ProportionScale = 0, RightArm = 0, RightArmColor = "Color3",
        RightLeg = 0, RightLegColor = "Color3", RunAnimation = 0, Shirt = 0, ShouldersAccessory = "",
        StaticFacialAnimation = false, SwimAnimation = 0, Torso = 0, TorsoColor = "Color3", UseAvatarSettings = false,
        WaistAccessory = "", WalkAnimation = 0, WidthScale = 0,
    },
    HumanoidRigDescription = {
        ChestRangeMax = "Vector3", ChestRangeMin = "Vector3", ChestSize = 0, ChestTposeAdjustment = "CFrame",
        HeadBaseRangeMax = "Vector3", HeadBaseRangeMin = "Vector3", HeadBaseSize = 0, HeadBaseTposeAdjustment = "CFrame",
        LeftAnkleRangeMax = "Vector3", LeftAnkleRangeMin = "Vector3", LeftAnkleSize = 0, LeftAnkleTposeAdjustment = "CFrame",
        LeftClavicleRangeMax = "Vector3", LeftClavicleRangeMin = "Vector3", LeftClavicleSize = 0,
        LeftClavicleTposeAdjustment = "CFrame", LeftElbowRangeMax = "Vector3", LeftElbowRangeMin = "Vector3",
        LeftElbowSize = 0, LeftElbowTposeAdjustment = "CFrame", LeftHipRangeMax = "Vector3", LeftHipRangeMin = "Vector3",
        LeftHipSize = 0, LeftHipTposeAdjustment = "CFrame", LeftKneeRangeMax = "Vector3", LeftKneeRangeMin = "Vector3",
        LeftKneeSize = 0, LeftKneeTposeAdjustment = "CFrame", LeftShoulderRangeMax = "Vector3",
        LeftShoulderRangeMin = "Vector3", LeftShoulderSize = 0, LeftShoulderTposeAdjustment = "CFrame",
        LeftToeBaseRangeMax = "Vector3", LeftToeBaseRangeMin = "Vector3", LeftToeBaseSize = 0, LeftToeBaseTposeAdjustment = "CFrame",
        LeftWristRangeMax = "Vector3", LeftWristRangeMin = "Vector3", LeftWristSize = 0, LeftWristTposeAdjustment = "CFrame",
        NeckRangeMax = "Vector3", NeckRangeMin = "Vector3", NeckSize = 0, NeckTposeAdjustment = "CFrame",
        RightAnkleRangeMax = "Vector3", RightAnkleRangeMin = "Vector3", RightAnkleSize = 0, RightAnkleTposeAdjustment = "CFrame",
        RightClavicleRangeMax = "Vector3", RightClavicleRangeMin = "Vector3", RightClavicleSize = 0,
        RightClavicleTposeAdjustment = "CFrame", RightElbowRangeMax = "Vector3", RightElbowRangeMin = "Vector3",
        RightElbowSize = 0, RightElbowTposeAdjustment = "CFrame", RightHipRangeMax = "Vector3",
        RightHipRangeMin = "Vector3", RightHipSize = 0, RightHipTposeAdjustment = "CFrame", RightKneeRangeMax = "Vector3",
        RightKneeRangeMin = "Vector3", RightKneeSize = 0, RightKneeTposeAdjustment = "CFrame", RightShoulderRangeMax = "Vector3",
        RightShoulderRangeMin = "Vector3", RightShoulderSize = 0, RightShoulderTposeAdjustment = "CFrame",
        RightToeBaseRangeMax = "Vector3", RightToeBaseRangeMin = "Vector3", RightToeBaseSize = 0,
        RightToeBaseTposeAdjustment = "CFrame", RightWristRangeMax = "Vector3", RightWristRangeMin = "Vector3",
        RightWristSize = 0, RightWristTposeAdjustment = "CFrame", RootRangeMax = "Vector3", RootRangeMin = "Vector3",
        RootSize = 0, RootTposeAdjustment = "CFrame", SpineRangeMax = "Vector3", SpineRangeMin = "Vector3",
        SpineSize = 0, SpineTposeAdjustment = "CFrame", WaistRangeMax = "Vector3", WaistRangeMin = "Vector3",
        WaistSize = 0, WaistTposeAdjustment = "CFrame",
    },
    IKControl = {
        Enabled = false, EndEffectorOffset = "CFrame", Offset = "CFrame", Priority = 0, SmoothTime = 0,
        Weight = 0,
    },
    IXPService = {},
    ImageButton = {
        ImageColor3 = "Color3", ImageRectOffset = "Vector2", ImageRectSize = "Vector2", ImageTransparency = 0,
        SliceCenter = "Rect", SliceScale = 0, TileSize = "UDim2", ScaleType = "Enum.ScaleType.Stretch",
        ResampleMode = "Enum.ResampleMode.Default", AutoButtonColor = true, BackgroundColor3 = "Color3",
        BackgroundTransparency = 1, BorderSizePixel = 0,
    },
    ImageHandleAdornment = {
        Size = "Vector2",
    },
    ImageLabel = {
        ImageColor3 = "Color3", ImageRectOffset = "Vector2", ImageRectSize = "Vector2", ImageTransparency = 0,
        SliceCenter = "Rect", SliceScale = 0, TileSize = "UDim2", ScaleType = "Enum.ScaleType.Stretch",
        ResampleMode = "Enum.ResampleMode.Default", BackgroundColor3 = "Color3", BackgroundTransparency = 1,
        BorderSizePixel = 0,
    },
    IncrementalPatchBuilder = {
        AddPathsToBundle = false, BuildDebouncePeriod = 0, HighCompression = false, SerializePatch = false,
        UseFileLevelCompressionInsteadOfChunk = false, ZstdCompression = false,
    },
    InputAction = {
        Enabled = false,
    },
    InputBinding = {
        ClampMagnitudeToOne = false, PointerIndex = 0, PressedThreshold = 0, ReleasedThreshold = 0,
        ResponseCurve = 0, Scale = 0, Vector2Scale = "Vector2", Vector3Scale = "Vector3",
    },
    InputContext = {
        Enabled = false, Priority = 0, Sink = false,
    },
    InputObject = {
        Delta = "Vector3", Position = "Vector3",
    },
    InsertService = {
        AllowInsertFreeModels = false,
    },
    Instance = {
        Archivable = false, Name = "", Sandboxed = false,
    },
    IntConstrainedValue = {
        MaxValue = 0, MinValue = 0, Value = 0,
    },
    IntValue = {
        Value = 0,
    },
    JointInstance = {
        C0 = "CFrame", C1 = "CFrame", Enabled = false,
    },
    JointsService = {},
    Keyframe = {
        Time = 0,
    },
    KeyframeMarker = {
        Value = "",
    },
    KeyframeSequenceProvider = {},
    LayerCollector = {
        Enabled = false, ResetOnSpawn = false,
    },
    Light = {
        Brightness = 0, Color = "Color3", Enabled = false, Shadows = false,
    },
    Lighting = {
        Ambient = "Color3", Brightness = 2, ClockTime = 14, ColorShift_Bottom = "Color3", ColorShift_Top = "Color3",
        EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1, ExposureCompensation = 0, FogColor = "Color3",
        FogEnd = 100000, FogStart = 0, GeographicLatitude = 0, GlobalShadows = true, OutdoorAmbient = "Color3",
        PrioritizeLightingQuality = false, ShadowSoftness = 0.2, TimeOfDay = "14:00:00", Technology = "Enum.Technology.Future",
        ShadowColor = "Color3", Outlines = false,
    },
    LineForce = {
        ApplyAtCenterOfMass = false, InverseSquareLaw = false, Magnitude = 0, MaxForce = 0, ReactionForceEnabled = false,
    },
    LineHandleAdornment = {
        Length = 0, Thickness = 0,
    },
    LinearVelocity = {
        ForceLimitsEnabled = false, LineDirection = "Vector3", LineVelocity = 0, MaxAxesForce = "Vector3",
        MaxForce = 0, MaxPlanarAxesForce = "Vector2", PlaneVelocity = "Vector2", PrimaryTangentAxis = "Vector3",
        ReactionForceEnabled = false, SecondaryTangentAxis = "Vector3", VectorVelocity = "Vector3",
    },
    LocalScript = { Source = "" },
    LocalizationService = {
        ForcePlayModeGameLocaleId = "", ForcePlayModeRobloxLocaleId = "", IsTextScraperRunning = false,
        RobloxForcePlayModeGameLocaleId = "", RobloxForcePlayModeRobloxLocaleId = "",
        RobloxLocaleId = "en-us", CoreScriptLocaleId = "en-us",
    },
    LocalizationTable = {
        SourceLocaleId = "",
    },
    LogService = {},
    MakeupDescription = {
        AssetId = 0, Order = 0,
    },
    MarketplaceService = {
        IsPurchaseSimulated = false,
    },
    MaterialGenerationService = {},
    MaterialImportData = {
        DiffuseFilePath = "", EmissiveFilePath = "", MetalnessFilePath = "", NormalFilePath = "",
        RoughnessFilePath = "",
    },
    MaterialVariant = {
        EmissiveStrength = 0, EmissiveTint = "Color3", StudsPerTile = 0,
    },
    MemStorageService = {},
    MeshContentProvider = {},
    MeshImportData = {
        Anchored = false, CageMeshIntersectedPreview = false, CageNonManifoldPreview = false, CageOverlappingVerticesPreview = false,
        CageUVMisMatchedPreview = false, DoubleSided = false, IgnoreVertexColors = false, IrrelevantCageModifiedPreview = false,
        MeshHoleDetectedPreview = false, OuterCageFarExtendedFromMeshPreview = false, UseImportedPivot = false,
    },
    MeshPart = {
        DoubleSided = false,
    },
    Message = {
        Text = "",
    },
    MessageBusService = {},
    MicroProfilerService = {
        ContextLabel = "",
    },
    Model = {
        WorldPivot = "CFrame",
    },
    ModuleScript = {
        LinkedSource = "", Source = "",
    },
    Motor = {
        CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0,
    },
    NetworkServer = {},
    NetworkSettings = {
        HttpProxyEnabled = false, HttpProxyURL = "", IncomingReplicationLag = 0, PrintJoinSizeBreakdown = false,
        PrintPhysicsErrors = false, PrintStreamInstanceQuota = false, RandomizeJoinInstanceOrder = false,
        RenderStreamedRegions = false, ShowActiveAnimationAsset = false,
    },
    NoCollisionConstraint = {
        Enabled = false,
    },
    NotificationService = {
        SelectedTheme = "",
    },
    NumberPose = {
        Value = 0,
    },
    NumberValue = {
        Value = 0,
    },
    OpenCloudService = {},
    PackageLink = {
        DefaultName = "", VersionNumber = 0,
    },
    Part = {
        Shape = "Enum.PartType.Block", Material = "Enum.Material.Plastic", TopSurface = "Enum.SurfaceType.Smooth",
        BottomSurface = "Enum.SurfaceType.Smooth", FrontSurface = "Enum.SurfaceType.Smooth", BackSurface = "Enum.SurfaceType.Smooth",
        LeftSurface = "Enum.SurfaceType.Smooth", RightSurface = "Enum.SurfaceType.Smooth",
    },
    PartOperation = {
        SmoothingAngle = 0, TriangleCount = 0, UsePartColor = false,
    },
    ParticleEmitter = {
        Acceleration = "Vector3", Brightness = 1, Drag = 0, Enabled = true, FlipbookBlendFrames = true,
        FlipbookFramerate = "NumberRange", FlipbookIncompatible = "", FlipbookSizeX = 0, FlipbookSizeY = 0,
        FlipbookStartRandom = false, Lifetime = "NumberRange", LightEmission = 0, LightInfluence = 0,
        LockedToPart = false, Rate = 10, RotSpeed = "NumberRange", Rotation = "NumberRange", ShapePartial = 0,
        Speed = "NumberRange", SpreadAngle = "Vector2", TimeScale = 1, VelocityInheritance = 0,
        WindAffectsDrag = false, ZOffset = 2,
    },
    PatchMapping = {
        FlattenTree = false, PatchId = "", TargetPath = "",
    },
    Path2D = {
        Closed = false, Color3 = "Color3", Thickness = 0, Visible = false, ZIndex = 0,
    },
    PathfindingLink = {
        IsBidirectional = false, Label = "",
    },
    PathfindingModifier = {
        Label = "", PassThrough = false,
    },
    PathfindingService = {
        EmptyCutoff = 0,
    },
    PhysicsService = {
        ThrottlePhysicsIslands = false, PhysicsEnvironmentalThrottle = "Enum.EnvironmentalPhysicsThrottle.DefaultAuto",
    },
    PitchShiftSoundEffect = {
        Octave = 0,
    },
    PlatformFriendsService = {},
    Player = {
        AutoJumpEnabled = false, CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, CanLoadCharacterAppearance = true,
        CharacterAppearanceId = 0, DevEnableMouseLock = false, DisplayName = "", HasRobloxSubscription = false,
        HasVerifiedBadge = false, HealthDisplayDistance = 100, NameDisplayDistance = 100, Neutral = true,
        UserId = 0, CharacterAppearance = "", ChatAvailabilityStatus = "", DataComplexityLimit = 600,
        GameplayPaused = false, InputLatency = 0, MaximumSimulationRadius = 1000, OsPlatform = "",
        PartyId = "", PlatformName = "", SimulationRadius = 0, StepIdOffset = 0, TeleportedIn = false,
        VRDevice = "", VREnabled = false, userId = 0, CameraMode = "Enum.CameraMode.Custom", DevCameraOcclusionMode = "Enum.DevCameraOcclusionMode.Zoom",
        DevComputerCameraMode = "Enum.DevComputerCameraMode.UserChoice", DevTouchCameraMode = "Enum.DevTouchCameraMode.UserChoice",
    },
    PlayerListConfiguration = {
        Open = false,
    },
    Players = {
        CharacterAutoLoads = true, RespawnTime = 5, MaxPlayers = 16, NumPlayers = 0, BanningEnabled = false,
        BubbleChat = false, ClassicChat = true, MaxPlayersInternal = 16, LocalPlayer = nil, ShowFailedJoinPopup = false,
    },
    PluginAction = {
        Text = "",
    },
    PluginGui = {
        Title = "",
    },
    PluginMenu = {
        Icon = "", Title = "",
    },
    PluginToolbarButton = {
        ClickableWhenViewportHidden = false, Enabled = false,
    },
    PointLight = {
        Range = 8, Brightness = 1, Shadows = false, Enabled = true, Color = "Color3",
    },
    PointsService = {},
    PolicyService = {},
    Pose = {
        CFrame = "CFrame",
    },
    PoseBase = {
        Weight = 0,
    },
    PostEffect = {
        Enabled = false,
    },
    ProceduralModel = {
        Size = "Vector3",
    },
    ProximityPrompt = {
        ActionText = "", AutoLocalize = true, ClickablePrompt = true, Enabled = true, HoldDuration = 0,
        MaxActivationDistance = 10, MaxIndicatorDistance = 12, ObjectText = "", RequiresLineOfSight = true,
        UIOffset = "Vector2", MaxDistance = 10, Style = "Enum.ProximityPromptStyle.Default",
    },
    ProximityPromptService = {
        Enabled = true, MaxIndicatorsVisible = 4, MaxPromptsVisible = 4, PromptButtonHolder = nil,
    },
    PyramidHandleAdornment = {
        Height = 0, Sides = 0, Size = 0,
    },
    RbxAnalyticsService = {},
    ReflectionMetadataClass = {
        ExplorerImageIndex = 0, ExplorerOrder = 0, Insertable = false, PreferredParent = "",
    },
    ReflectionMetadataItem = {
        Browsable = false, ClassCategory = "", ClientOnly = false, Constraint = "", Deprecated = false,
        EditingDisabled = false, EditorType = "", FFlag = "", IsBackend = false, PropertyOrder = 0,
        ScriptContext = "", ServerOnly = false, SliderScaling = "", UIMaximum = 0, UIMinimum = 0,
        UINumTicks = 0,
    },
    RemoteEvent = {},
    RemoteFunction = {},
    RenderingTest = {
        CFrame = "CFrame", ComparisonDiffThreshold = 0, ComparisonPsnrThreshold = 0, Description = "",
        FieldOfView = 0, PerfTest = false, QualityAuto = false, QualityLevel = 0, RenderingTestFrameCount = 0,
        ShouldSkip = false, Ticket = "", Timeout = 0,
    },
    ReplicatedFirst = {},
    ReplicatedStorage = {},
    ReverbSoundEffect = {
        DecayTime = 0, Density = 0, Diffusion = 0, DryLevel = 0, WetLevel = 0,
    },
    RobloxReplicatedStorage = {},
    RocketPropulsion = {
        CartoonFactor = 0, MaxSpeed = 0, MaxThrust = 0, MaxTorque = "Vector3", TargetOffset = "Vector3",
        TargetRadius = 0, ThrustD = 0, ThrustP = 0, TurnD = 0, TurnP = 0,
    },
    RodConstraint = {
        Length = 0, LimitAngle0 = 0, LimitAngle1 = 0, LimitsEnabled = false, Thickness = 0,
    },
    RootImportData = {
        AddModelToInventory = false, Anchored = false, AnimationIdForRestPose = 0, ExistingPackageId = "",
        ImportAsModelAsset = false, ImportAsPackage = false, InsertInWorkspace = false, InsertWithScenePosition = false,
        InvertNegativeFaces = false, KeepZeroInfluenceBones = false, MergeMeshes = false, PreferredUploadId = 0,
        RigVisualization = false, ScaleFactor = 0, UseSceneOriginAsPivot = false, UsesCages = false,
        ValidateUgcBody = false, VersionedAssetId = 0,
    },
    RopeConstraint = {
        Length = 0, Restitution = 0, Thickness = 0, WinchEnabled = false, WinchForce = 0, WinchResponsiveness = 0,
        WinchSpeed = 0, WinchTarget = 0,
    },
    RunService = {
        ClientGitHash = "", FrameNumber = 0, RunState = "Enum.RunState.Running",
    },
    SafetyService = {
        IsCaptureModeForReport = false,
    },
    ScreenGui = {
        ClipToDeviceSafeArea = false, DisplayOrder = 0, IgnoreGuiInset = false,
    },
    ScreenshotHud = {
        CameraButtonPosition = "UDim2", CloseButtonPosition = "UDim2", CloseWhenScreenshotTaken = false,
        HideCoreGuiForCaptures = false, HidePlayerGuiForCaptures = false, Visible = false,
    },
    Script = {
        Source = "",
    },
    ScriptContext = {
        ScriptsDisabled = false,
    },
    ScriptProfilerService = {},
    ScrollingFrame = {
        CanvasPosition = "Vector2", CanvasSize = "UDim2", ScrollBarImageColor3 = "Color3", ScrollBarImageTransparency = 0,
        ScrollBarThickness = 8, ScrollingEnabled = true, ElasticBehavior = "Enum.ElasticBehavior.Always",
        AutomaticCanvasSize = "Enum.AutomaticSize.None",
    },
    Seat = {
        Disabled = false, Occupant = nil, IsSit = true,
    },
    SelectionBox = {
        LineThickness = 0.05, SurfaceColor3 = "Color3", SurfaceTransparency = 0, Transparency = 0,
        Adornee = nil, Color3 = "Color3",
    },
    SelectionPointLasso = {
        Point = "Vector3",
    },
    SelectionSphere = {
        SurfaceColor3 = "Color3", SurfaceTransparency = 0,
    },
    SelfViewConfiguration = {
        Open = false,
    },
    SessionService = {},
    ShirtGraphic = {
        Color3 = "Color3",
    },
    SkateboardPlatform = {
        Steer = 0, StickyWheels = false, Throttle = 0,
    },
    Sky = {
        CelestialBodiesShown = true, MoonAngularSize = 11, SkyboxOrientation = "Vector3", StarCount = 3000,
        SunAngularSize = 11, SunEnabled = true, MoonEnabled = true, SunTextureId = "rbxassetid://1683788242",
        MoonTextureId = "rbxasset://sky/moon.jpg", SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex",
        SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex", SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex",
        SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex", SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex",
        SkyboxUp = "rbxasset://textures/sky/sky512_up.tex",
    },
    SlidingBallConstraint = {
        LimitsEnabled = false, LinearResponsiveness = 0, LowerLimit = 0, MotorMaxAcceleration = 0,
        MotorMaxForce = 0, Restitution = 0, ServoMaxForce = 0, Size = 0, Speed = 0, TargetPosition = 0,
        UpperLimit = 0, Velocity = 0,
    },
    Smoke = {
        Color = "Color3", Enabled = true, Opacity = 0.5, RiseVelocity = 1, Size = 1, TimeScale = 1,
        Lifetime = 1,
    },
    SocialService = {},
    Sound = {
        AcousticSimulationEnabled = false, LoopRegion = "NumberRange", Looped = false, PlayOnRemove = false,
        PlaybackRegion = "NumberRange", PlaybackRegionsEnabled = false, PlaybackSpeed = 1, Playing = false,
        RollOffMaxDistance = 10000, RollOffMinDistance = 10, TimePosition = 0, Volume = 0.5, Pitch = 1,
        RollOffMode = "Enum.RollOffMode.Inverse", EmitterSize = 0, RollOffGain = 1, MaxDistance = 10000,
        MinDistance = 10,
    },
    SoundEffect = {
        Enabled = false, Priority = 0,
    },
    SoundGroup = {
        Volume = 0,
    },
    SoundService = {
        AcousticSimulationEnabled = false, DiffractionEnabled = false, DistanceFactor = 3.32, DopplerScale = 1,
        ListenerCFrame = "CFrame", OcclusionEnabled = false, RespectFilteringEnabled = true, ReverbEnabled = false,
        RolloffScale = 1, IsNewExpForAudioApiByDefault = "Enum.RolloutState.Rollout", AmbientReverb = "Enum.ReverbType.NoReverb",
        AudioApiByDefault = "Enum.RolloutState.Rollout",
    },
    Sparkles = {
        Enabled = true, SparkleColor = "Color3", TimeScale = 1, Lifetime = 1, SparkleCount = 24,
    },
    SpawnLocation = {
        AllowTeamChangeOnTouch = false, Duration = 0, Enabled = false, Neutral = false,
    },
    SpecialMesh = {
        Scale = "Vector3", Offset = "Vector3", MeshType = "Enum.MeshType.Brick", VertexColor = "Color3",
        TextureID = "",
    },
    SphereHandleAdornment = {
        Radius = 0,
    },
    SpotLight = {
        Angle = 90, Range = 8, Brightness = 1, Shadows = false, Enabled = true, Face = "Enum.NormalId.Front",
    },
    SpringConstraint = {
        Coils = 0, Damping = 0, FreeLength = 0, LimitsEnabled = false, MaxForce = 0, MaxLength = 0,
        MinLength = 0, Radius = 0, Stiffness = 0, Thickness = 0,
    },
    StarterGui = {
        ShowDevelopmentGui = true, ProcessUserInput = false, ResetPlayerGuiOnSpawn = true, ScreenOrientation = "Enum.ScreenOrientation.Landscape",
        VRLaserPointerMode = "Enum.VRLaserPointerMode.Disabled",
    },
    StarterPlayer = {
        AutoJumpEnabled = false, CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, CharacterBreakJointsOnDeath = true,
        CharacterJumpHeight = 7.2, CharacterJumpPower = 50, CharacterMaxSlopeAngle = 89, CharacterUseJumpPower = false,
        CharacterWalkSpeed = 16, ClassicDeath = true, EnableMouseLockOption = true, HealthDisplayDistance = 100,
        LoadCharacterAppearance = true, NameDisplayDistance = 100, UserEmotesEnabled = true, AllowCustomAnimations = true,
        CreateDefaultPlayerModule = true, PlayerModuleStatus = 0,
    },
    Stats = {
        ProfilingWindow = "Enum.StatsProfilingWindow.TenSeconds",
    },
    StringValue = {
        Value = "",
    },
    StudioAttachment = {
        AutoHideParent = false, IsArrowVisible = false, Offset = "Vector2", SourceAnchorPoint = "Vector2",
        TargetAnchorPoint = "Vector2",
    },
    StudioService = {
        UseLocalSpace = false, AlignDraggedObjects = false, Secrets = "", HighlightColor = "Color3",
    },
    StyleDerive = {
        Priority = 0,
    },
    StyleRule = {
        Priority = 0, Selector = "",
    },
    SunRaysEffect = {
        Intensity = 0.25, Spread = 1, Enabled = true,
    },
    SurfaceAppearance = {
        Color = "Color3", EmissiveStrength = 0, EmissiveTint = "Color3",
    },
    SurfaceGui = {
        AlwaysOnTop = false, Brightness = 0, CanvasSize = "Vector2", ClipsDescendants = false, LightInfluence = 0,
        MaxDistance = 0, PixelsPerStud = 50, ToolPunchThroughDistance = 0, ZOffset = 0,
    },
    SurfaceGuiBase = {
        Active = false,
    },
    SurfaceLight = {
        Angle = 90, Range = 8, Brightness = 1, Shadows = false, Enabled = true, Face = "Enum.NormalId.Front",
    },
    SurfaceSelection = {
        LineThickness = 0.05, Transparency = 0, Adornee = nil, Face = "Enum.NormalId.Top",
    },
    SwimController = {
        AccelerationTime = 0, PitchMaxTorque = 0, PitchSpeedFactor = 0, RollMaxTorque = 0, RollSpeedFactor = 0,
    },
    SyncScriptBuilder = {
        CoverageInfo = false, DebugInfo = false, PackAsSource = false,
    },
    Team = {
        AutoAssignable = false,
    },
    Teams = {},
    TelemetryService = {},
    TeleportOptions = {
        ReservedServerAccessCode = "", ServerInstanceId = "", ShouldReserveServer = false,
    },
    TeleportService = {
        CustomizedTeleportUI = false,
    },
    Terrain = {
        WaterColor = "Color3", WaterReflectance = 0, WaterTransparency = 0, WaterWaveSize = 0, WaterWaveSpeed = 0,
        DecorationGridSize = 1024, GrassLength = "Enum.GrassSoleLength", SmoothVoxelsUpgraded = false,
        Decoration = false,
    },
    TerrainDetail = {
        EmissiveStrength = 0, EmissiveTint = "Color3", StudsPerTile = 0,
    },
    TestService = {
        AutoRuns = false, Description = "", ExecuteWithStudioRun = false, IsPhysicsEnvironmentalThrottled = false,
        IsSleepAllowed = false, NumberOfPlayers = 0, SimulateSecondsLag = 0, ThrottlePhysicsToRealtime = false,
        Timeout = 0,
    },
    TextBox = {
        ClearTextOnFocus = true, CursorPosition = -1, LineHeight = 0, MaxVisibleGraphemes = 0, MultiLine = false,
        OpenTypeFeatures = "", PlaceholderColor3 = "Color3", PlaceholderText = "", RichText = false,
        SelectionStart = -1, ShowNativeInput = true, Text = "", TextColor3 = "Color3", TextEditable = true,
        TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        TextXAlignment = "Enum.TextXAlignment.Left", TextYAlignment = "Enum.TextYAlignment.Center",
        Font = "Enum.Font.SourceSans",
    },
    TextButton = {
        LineHeight = 0, MaxVisibleGraphemes = 0, OpenTypeFeatures = "", RichText = false, Text = "",
        TextColor3 = "Color3", TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, AutoButtonColor = true, Modal = false, BackgroundTransparency = 1,
        BorderSizePixel = 0, Font = "Enum.Font.SourceSans",
    },
    TextChatCommand = {
        AutocompleteVisible = false, Enabled = false, PrimaryAlias = "", SecondaryAlias = "",
    },
    TextChatMessage = {
        MessageId = "", Metadata = "", PrefixText = "", Text = "", Timestamp = "DateTime", Translation = "",
    },
    TextChatMessageProperties = {
        PrefixText = "", Text = "", Translation = "",
    },
    TextChatService = {
        ChatTranslationEnabled = false, CreateDefaultCommands = true, CreateDefaultTextChannels = true,
        ChatTranslationFTUXShown = false, ChatTranslationToggleEnabled = false, HasSeenDeprecationDialog = false,
        IsLegacyChatDisabled = false,
    },
    TextGenerator = {
        Seed = 0, SystemPrompt = "", Temperature = 0, TopP = 0,
    },
    TextLabel = {
        LineHeight = 0, MaxVisibleGraphemes = 0, OpenTypeFeatures = "", RichText = false, Text = "",
        TextColor3 = "Color3", TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        TextXAlignment = "Enum.TextXAlignment.Left", TextYAlignment = "Enum.TextYAlignment.Center",
        Font = "Enum.Font.SourceSans",
    },
    TextSource = {
        CanSend = false,
    },
    Texture = {
        OffsetStudsU = 0, OffsetStudsV = 0, StudsPerTileU = 1, StudsPerTileV = 1, Transparency = 0,
        Color3 = "Color3",
    },
    TextureGenerationService = {},
    Tool = {
        CanBeDropped = true, Enabled = false, Grip = "CFrame", ManualActivationOnly = false, RequiresHandle = true,
        ToolTip = "",
    },
    Torque = {
        Torque = "Vector3",
    },
    TorsionSpringConstraint = {
        Coils = 0, Damping = 0, LimitsEnabled = false, MaxAngle = 0, MaxTorque = 0, Radius = 0,
        Restitution = 0, Stiffness = 0,
    },
    Trail = {
        Brightness = 1, Enabled = true, FaceCamera = false, Lifetime = 1, LightEmission = 0, LightInfluence = 0,
        MaxLength = 0, MinLength = 0.1, TextureLength = 1, TextureMode = "Enum.TextureMode.Stretch",
    },
    TremoloSoundEffect = {
        Depth = 0, Duty = 0, Frequency = 0,
    },
    TweenService = {},
    UGCValidationService = {},
    UIAspectRatioConstraint = {
        AspectRatio = 0,
    },
    UICorner = {
        BottomLeftRadius = "UDim", BottomRightRadius = "UDim", CornerRadius = "UDim", TopLeftRadius = "UDim",
        TopRightRadius = "UDim",
    },
    UIDragDetector = {
        DragAxis = "Vector2", DragRotation = 0, DragUDim2 = "UDim2", Enabled = false, MaxDragAngle = 0,
        MaxDragTranslation = "UDim2", MinDragAngle = 0, MinDragTranslation = "UDim2", SelectionModeDragSpeed = "UDim2",
        SelectionModeRotateSpeed = 0,
    },
    UIFlexItem = {
        GrowRatio = 0, ShrinkRatio = 0,
    },
    UIGradient = {
        Enabled = false, Offset = "Vector2", Rotation = 0, Scale = 0,
    },
    UIGridLayout = {
        CellPadding = "UDim2", CellSize = "UDim2", FillDirectionMaxCells = 0,
    },
    UIListLayout = {
        Padding = "UDim", Wraps = false,
    },
    UIPadding = {
        PaddingBottom = "UDim", PaddingLeft = "UDim", PaddingRight = "UDim", PaddingTop = "UDim",
    },
    UIPageLayout = {
        Animated = false, Circular = false, GamepadInputEnabled = false, Padding = "UDim", ScrollWheelInputEnabled = false,
        TouchInputEnabled = false, TweenTime = 0,
    },
    UIScale = {
        Scale = 0,
    },
    UIShadow = {
        BlurRadius = "UDim", Color = "Color3", Enabled = false, Offset = "UDim2", Spread = "UDim2",
        Transparency = 0, ZIndex = 0,
    },
    UISizeConstraint = {
        MaxSize = "Vector2", MinSize = "Vector2",
    },
    UIStroke = {
        BorderOffset = "UDim", Color = "Color3", Enabled = false, Thickness = 0, Transparency = 0,
        ZIndex = 0,
    },
    UITableLayout = {
        FillEmptySpaceColumns = false, FillEmptySpaceRows = false, Padding = "UDim2",
    },
    UITextSizeConstraint = {
        MaxTextSize = 0, MinTextSize = 0,
    },
    UniversalConstraint = {
        LimitsEnabled = false, MaxAngle = 0, Radius = 0, Restitution = 0,
    },
    UserGameSettings = {
        GamepadCameraSensitivity = 0, MouseSensitivity = 0, RCCProfilerRecordFrameRate = 0, RCCProfilerRecordTimeFrame = 0,
        VRSmoothRotationEnabled = false, VignetteEnabled = false,
    },
    UserInputService = {
        MouseDeltaSensitivity = 1, MouseIconEnabled = true, LegacyInputEventsEnabled = true, ModalEnabled = false,
        AccelerometerEnabled = false, GamepadEnabled = true, GyroscopeEnabled = false, KeyboardEnabled = true,
        TouchEnabled = false, VREnabled = false, MouseBehavior = "Enum.MouseBehavior.Default", MouseIcon = "rbxasset://textures/ArrowCursor.png",
    },
    UserService = {},
    VRService = {
        AvatarGestures = false, FadeOutViewOnCollision = true, QuestASWState = false, QuestDisplayRefreshRate = 0,
        AutomaticThermalStatus = "Enum.RolloutState.Rollout",
    },
    Vector3Value = {
        Value = "Vector3",
    },
    VectorForce = {
        ApplyAtCenterOfMass = false, Force = "Vector3",
    },
    VehicleSeat = {
        Disabled = false, HeadsUpDisplay = false, MaxSpeed = 0, Steer = 0, SteerFloat = 0, Throttle = 0,
        ThrottleFloat = 0, Torque = 0, TurnSpeed = 0, IsSit = true,
    },
    VelocityMotor = {
        CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0,
    },
    VideoCaptureService = {
        Active = false, CameraID = "",
    },
    VideoDeviceInput = {
        Active = false, CameraId = "",
    },
    VideoDisplay = {
        TileSize = "UDim2", VideoColor3 = "Color3", VideoRectOffset = "Vector2", VideoRectSize = "Vector2",
        VideoTransparency = 0,
    },
    VideoFrame = {
        Looped = false, Playing = false, RollOffMaxDistance = 0, RollOffMinDistance = 0, TimePosition = 0,
        Volume = 0,
    },
    VideoPlayer = {
        Looping = false, PlaybackSpeed = 0, TimePosition = 0, Volume = 0,
    },
    ViewportFrame = {
        Ambient = "Color3", ImageColor3 = "Color3", ImageTransparency = 0, LightColor = "Color3",
        LightDirection = "Vector3",
    },
    VoiceChatService = {
        EnableDefaultVoice = true, UseNewAudioApi = "Enum.RolloutState.Rollout", UseNewControlPaths = false,
        UseNewJoinFlow = "Enum.RolloutState.Rollout", UseStreamSwitching = "Enum.RolloutState.Rollout",
        VoiceChatEnabledForPlaceOnRcc = false, VoiceChatEnabledForUniverseOnRcc = false,
    },
    WeldConstraint = {
        Enabled = false,
    },
    Wire = {
        SourceName = "", TargetName = "",
    },
    WireframeHandleAdornment = {
        Scale = "Vector3", Thickness = 0,
    },
    Workspace = {
        AirDensity = 0, AirTurbulenceIntensity = 0, AllowThirdPartySales = false, DistributedGameTime = 0,
        FallHeightEnabled = false, FallenPartsDestroyHeight = -500, GlobalWind = "Vector3", Gravity = 196.2,
        InsertPoint = "Vector3", StreamingEnabled = false, FilteringEnabled = true, StreamingMinRadius = 0,
        StreamingTargetRadius = 0, TouchesUseCollisionGroups = false,
    },
    WorldModel = {},
    WrapLayer = {
        BindOffset = "CFrame", Enabled = false, Order = 0, ReferenceOrigin = "CFrame",
    },
    WrapTextureTransfer = {
        UVMaxBound = "Vector2", UVMinBound = "Vector2",
    },
}


makeProxy = function(name: string): any
    local children = {}
    local storedValues = {}
    local setKeys = {}
    local mt = {
        _name = name,
        _isProxy = true,
        _parent = nil,
        _fieldName = nil,
        _descriptive = false,
        _storedValues = storedValues,
        _setKeys = setKeys,
    }
    mt.__index = function(t, k)
        tick()
        local ks = tostring(k)
        if ks == "Parent" and not setKeys[ks] then
            return nil
        end
        if setKeys[ks] then
            return storedValues[ks]
        end
        if ks == "Parent" and destroyedInstances[name] then
            return nil
        end
        if mt._className == "DataModel" and isApiServiceClass(ks) then
            if not serviceCache[ks] then
                if SERVER_ONLY_SERVICES[ks] then
                    error(ks .. " is not a valid member of DataModel \"DataModel\"", 2)
                end
                local svc = spyInstance(ks, ks:lower(), true)
                local svcMt = getmetatable(svc)
                svcMt._className = ks
                svcMt._storedValues["ClassName"] = ks
                svcMt._setKeys["ClassName"] = true
                svcMt._storedValues["Name"] = ks
                svcMt._setKeys["Name"] = true
                if ks == "Chat" then
                    local ugcParent = makeProxy("ugc")
                    local ugcMt = getmetatable(ugcParent)
                    ugcMt._className = "Folder"
                    ugcMt._storedValues["Name"] = "Ugc"
                    ugcMt._setKeys["Name"] = true
                    ugcMt._storedValues["ClassName"] = "Folder"
                    ugcMt._setKeys["ClassName"] = true
                    svcMt._storedValues["Parent"] = ugcParent
                    svcMt._setKeys["Parent"] = true
                end
                serviceCache[ks] = svc
                if ks == "Workspace" and workspaceProxy then
                    serviceCache[ks] = workspaceProxy
                end
            end
            return serviceCache[ks]
        end
        if mt._className == "Player" and ks == "MembershipType" then
            if not setKeys[ks] then
                local envRef = _G._envRef
                if envRef and envRef.Enum then
                    return envRef.Enum.MembershipType.None
                end
            end
            return storedValues[ks]
        end
        if mt._className == "Players" and ks == "LocalPlayer" then
            if not children[ks] then
                local player = spyInstance("Player", "LocalPlayer", true)
                local pmt = getmetatable(player)
                pmt._storedValues["Parent"] = t
                pmt._setKeys["Parent"] = true
                pmt._storedValues["UserId"] = 0
                pmt._setKeys["UserId"] = true
                local character = spyInstance("Model", "Character", true)
                local charMt = getmetatable(character)
                charMt._storedValues["Name"] = "CatmiO"
                charMt._setKeys["Name"] = true
                local humanoid = spyInstance("Humanoid", "Humanoid", true)
                local humanoidMt = getmetatable(humanoid)
                humanoidMt._storedValues["Health"] = 100
                humanoidMt._setKeys["Health"] = true
                humanoidMt._storedValues["MaxHealth"] = 100
                humanoidMt._setKeys["MaxHealth"] = true
                if not parentChildMap["Character"] then parentChildMap["Character"] = {} end
                parentChildMap["Character"]["Humanoid"] = humanoid
                local rootPart = spyInstance("Part", "HumanoidRootPart", true)
                local rpMt = getmetatable(rootPart)
                rpMt._storedValues["CFrame"] = makeDataProxy("CFrame", {0, 0, 0}, "HumanoidRootPart.CFrame")
                rpMt._setKeys["CFrame"] = true
                parentChildMap["Character"]["HumanoidRootPart"] = rootPart
                local animate = spyInstance("LocalScript", "Animate", true)
                parentChildMap["Character"]["Animate"] = animate
                pmt._storedValues["Character"] = character
                pmt._setKeys["Character"] = true
                pmt._storedValues["UserId"] = 0
                pmt._setKeys["UserId"] = true
                pmt._storedValues["AccountAge"] = 0
                pmt._setKeys["AccountAge"] = true
                local playerScripts = spyInstance("Folder", "PlayerScripts", true)
                local psMt = getmetatable(playerScripts)
                psMt._className = "PlayerScripts"
                psMt._storedValues["ClassName"] = "PlayerScripts"
                psMt._setKeys["ClassName"] = true
                local playerModule = spyInstance("ModuleScript", "PlayerModule", true)
                local rbxCharacterSounds = spyInstance("ModuleScript", "RbxCharacterSounds", true)
                local atomicBinding = spyInstance("ModuleScript", "AtomicBinding", true)
                local abMt = getmetatable(atomicBinding)
                abMt._storedValues["Archivable"] = false
                abMt._setKeys["Archivable"] = true
                if not parentChildMap["RbxCharacterSounds"] then parentChildMap["RbxCharacterSounds"] = {} end
                parentChildMap["RbxCharacterSounds"]["AtomicBinding"] = atomicBinding
                if not parentChildMap["PlayerScripts"] then parentChildMap["PlayerScripts"] = {} end
                parentChildMap["PlayerScripts"]["PlayerModule"] = playerModule
                parentChildMap["PlayerScripts"]["RbxCharacterSounds"] = rbxCharacterSounds
                local playerGui = spyInstance("PlayerGui", "PlayerGui", true)
                parentChildMap["PlayerScripts"]["PlayerGui"] = playerGui
                local backpack = spyInstance("Backpack", "Backpack", true)
                parentChildMap["PlayerScripts"]["Backpack"] = backpack
                children["PlayerScripts"] = playerScripts
                children["PlayerGui"] = playerGui
                children["Backpack"] = backpack
                children[ks] = player
            end
            return children[ks]
        end
        if mt._className == "Workspace" and ks == "CurrentCamera" then
            if not children[ks] then
                local cam = spyInstance("Camera", "CurrentCamera", true)
                children[ks] = cam
            end
            return children[ks]
        end
        local INHERENT_SERVICE_METHODS = {
            RunService = { GetRealPhysicsFPS = true, GetPhysicsFPS = true, IsStudio = true },
            SoundService = { GetMixerTime = true, GetAudioInstances = true, GetInputDevices = true, GetOutputDevices = true },
            ReflectionService = { GetClasses = true, GetMembers = true, GetProperties = true, GetFunctions = true, GetEvents = true, GetEnums = true },
            StarterGui = { GetCore = true, SetCore = true, RegisterGetCore = true, RegisterSetCore = true },
            VoiceChatService = {
                getInternalSessionId = true, getInternalChannelId = true,
                getInternalGroupId = true, isInternalPublishPaused = true,
                lastVoiceChatStats = true, joinVoice = true, rejoinVoice = true, leaveVoice = true,
            },
        }
        local inherentMethods = mt._className and INHERENT_SERVICE_METHODS[mt._className] or nil
        if inherentMethods and inherentMethods[ks] then
            if not children[ks] then
                local parentRef = t
                local fieldNameStr = ks
                local fn = function(_, ...)
                    _G._methodParent = parentRef
                    _G._methodField = fieldNameStr
                    local ccmt = getmetatable(parentRef)
                    return ccmt.__call(parentRef, parentRef, ...)
                end
                children[ks] = fn
                knownCFunctions[fn] = true
            end
            return children[ks]
        end
        if ks == "ClassName" and mt._className then
            return mt._className
        end
        local ctorName = mt._ctorName or rawget(t, "_ctorName")
        if ctorName == "CFrame" then
            local args = mt._ctorArgs or {}
            if ks == "Position" then
                local v = makeProxy(name .. ".Position")
                local vmt = getmetatable(v)
                vmt._ctorName = "Vector3"
                vmt._ctorArgs = { args[1] or 0, args[2] or 0, args[3] or 0 }
                return v
            end
            if ks == "X" then return args[1] or 0 end
            if ks == "Y" then return args[2] or 0 end
            if ks == "Z" then return args[3] or 0 end
            if ks == "LookVector" then
                local v = makeProxy(name .. ".LookVector")
                local vmt = getmetatable(v)
                vmt._ctorName = "Vector3"
                vmt._ctorArgs = { 0, 0, -1 }
                return v
            end
            if ks == "RightVector" then
                local v = makeProxy(name .. ".RightVector")
                local vmt = getmetatable(v)
                vmt._ctorName = "Vector3"
                vmt._ctorArgs = { 1, 0, 0 }
                return v
            end
            if ks == "UpVector" then
                local v = makeProxy(name .. ".UpVector")
                local vmt = getmetatable(v)
                vmt._ctorName = "Vector3"
                vmt._ctorArgs = { 0, 1, 0 }
                return v
            end
        end
        local memberInfo = resolveApiMember(mt._className or "", ks)
        local DATA_TYPE_METHODS = {
            Color3 = { Lerp = true, ToHSV = true, ToHex = true, ToRGB = true },
            Vector3 = { Lerp = true, Dot = true, Cross = true, Angle = true, FuzzyEq = true, Abs = true, Unit = true },
            Vector2 = { Lerp = true, Dot = true, Cross = true, Abs = true },
            UDim2 = { Lerp = true },
            CFrame = { Lerp = true, ToOrientation = true, ToEulerAnglesXYZ = true, ToEulerAnglesYXZ = true, PointToObjectSpace = true, ToWorldSpace = true, ToObjectSpace = true, Inverse = true },
            UDim = { Lerp = true },
        }
        if ctorName and DATA_TYPE_METHODS[ctorName] and DATA_TYPE_METHODS[ctorName][ks] then
            if not children[ks] then
                local parentRef = t
                local fieldNameStr = ks
                children[ks] = function(_, ...)
                    _G._methodParent = parentRef
                    _G._methodField = fieldNameStr
                    local ccmt = getmetatable(parentRef)
                    return ccmt.__call(parentRef, parentRef, ...)
                end
                knownCFunctions[children[ks]] = true
            end
            return children[ks]
        end
        local ALWAYS_AVAILABLE_METHODS = {
            IsA = true, GetChildren = true, GetDescendants = true,
            GetFullName = true, FindFirstChild = true, FindFirstDescendant = true,
            FindFirstAncestor = true, FindFirstChildWhichIsA = true,
            FindFirstChildOfClass = true, FindFirstAncestorWhichIsA = true,
            FindFirstAncestorOfClass = true, GetDebugId = true,
            GetTags = true, AddTag = true, RemoveTag = true,
            HasTag = true, GetAttribute = true, GetAttributes = true,
            SetAttribute = true, GetPropertyChangedSignal = true,
            IsDescendantOf = true, IsAncestorOf = true,
            Clone = true, Destroy = true, Remove = true,
            ClearAllChildren = true, GetAttributeChangedSignal = true,
            NextNumber = true, NextInteger = true, NextUnitVector = true,
        }
        if ALWAYS_AVAILABLE_METHODS[ks] and not children[ks] then
            local parentRef = t
            local fieldNameStr = ks
            children[ks] = function(_, ...)
                _G._methodParent = parentRef
                _G._methodField = fieldNameStr
                local ccmt = getmetatable(parentRef)
                return ccmt.__call(parentRef, parentRef, ...)
            end
            knownCFunctions[children[ks]] = true
            return children[ks]
        end
        if mt._className == "RBXScriptSignal" and (ks == "Connect" or ks == "connect" or ks == "Wait" or ks == "wait" or ks == "Once" or ks == "Disconnect" or ks == "disconnect" or ks == "ConnectParallel") then
            if not children[ks] then
                local parentRef = t
                local fieldNameStr = ks
                local fn = function(_, ...)
                    _G._methodParent = parentRef
                    _G._methodField = fieldNameStr
                    local ccmt = getmetatable(parentRef)
                    return ccmt.__call(parentRef, parentRef, ...)
                end
                children[ks] = fn
                knownCFunctions[fn] = true
            end
            return children[ks]
        end
        if mt._className == "RBXScriptConnection" and (ks == "Disconnect" or ks == "disconnect" or ks == "Enabled") then
            if not children[ks] then
                local parentRef = t
                local fieldNameStr = ks
                local fn = function(_, ...)
                    _G._methodParent = parentRef
                    _G._methodField = fieldNameStr
                    local ccmt = getmetatable(parentRef)
                    return ccmt.__call(parentRef, parentRef, ...)
                end
                children[ks] = fn
                knownCFunctions[fn] = true
            end
            return children[ks]
        end
        if isEventMember(memberInfo) then
            if not children[ks] then
                local child = makeProxy(name .. "." .. ks)
                local cmt = getmetatable(child)
                cmt._parent = t
                cmt._fieldName = ks
                cmt._memberType = memberInfo.memberType
                cmt._className = "RBXScriptSignal"
                cmt._storedValues["ClassName"] = "RBXScriptSignal"
                cmt._setKeys["ClassName"] = true
                cmt._signalForEvent = { proxy = t, eventName = ks }
                children[ks] = child
            end
            return children[ks]
        end
        if isScriptableFunctionMember(memberInfo) then
            if not children[ks] then
                local parentRef = t
                local fieldNameStr = ks
                local fn = function(_, ...)
                    _G._methodParent = parentRef
                    _G._methodField = fieldNameStr
                    local ccmt = getmetatable(parentRef)
                    return ccmt.__call(parentRef, parentRef, ...)
                end
                children[ks] = fn
                knownCFunctions[fn] = true
            end
            return children[ks]
        end
        if mt._ctorArgs and (ks == "X" or ks == "Y" or ks == "Z" or ks == "W") then
            local idx = ({ X = 1, Y = 2, Z = 3, W = 4 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
        end
        if mt._ctorArgs and (ks == "R" or ks == "G" or ks == "B") and mt._ctorName == "Color3" then
            local idx = ({ R = 1, G = 2, B = 3 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "Vector3" and ks == "Magnitude" then
            local x = mt._ctorArgs[1] or 0
            local y = mt._ctorArgs[2] or 0
            local z = mt._ctorArgs[3] or 0
            return math.sqrt(x*x + y*y + z*z)
        end
        if mt._ctorName == "Vector2" and ks == "Magnitude" then
            local x = mt._ctorArgs[1] or 0
            local y = mt._ctorArgs[2] or 0
            return math.sqrt(x*x + y*y)
        end
        if mt._ctorName == "Vector3" and (ks == "Unit" or ks == "LookVector" or ks == "RightVector" or ks == "UpVector") then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = mt._ctorArgs or { 1, 0, 0 }
            return v
        end
        if mt._ctorName == "Vector2" and ks == "Unit" then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector2"
            vmt._ctorArgs = mt._ctorArgs or { 1, 0 }
            return v
        end
        if mt._ctorName == "UDim2" and (ks == "X" or ks == "Y") then
            local idx = ({ X = 1, Y = 2 })[ks]
            local scale = mt._ctorArgs[idx*2-1] or 0
            local offset = mt._ctorArgs[idx*2] or 0
            return makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "UDim" and (ks == "Scale" or ks == "Offset") then
            local idx = ({ Scale = 1, Offset = 2 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "NumberRange" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
            if #mt._ctorArgs == 1 then return mt._ctorArgs[1] end
            return 0
        end
        if (mt._ctorName == "Axes" or mt._ctorName == "Faces") and
           (ks == "X" or ks == "Y" or ks == "Z" or ks == "Top" or ks == "Bottom" or
            ks == "Left" or ks == "Right" or ks == "Front" or ks == "Back") then
            if mt._ctorArgs then
                for _, arg in ipairs(mt._ctorArgs) do
                    if isProxy(arg) then
                        local am = getmetatable(arg)
                        if am and am._name and am._name:find(ks) then return true end
                    end
                end
            end
            return false
        end
        if mt._ctorName == "Ray" and (ks == "Origin" or ks == "Direction") then
            local idx = ({ Origin = 1, Direction = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "Rect" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "Region3" and ks == "Size" then
            return makeProxy(name .. ".Size")
        end
        if mt._ctorName == "PathWaypoint" and (ks == "Position" or ks == "Action") then
            local idx = ({ Position = 1, Action = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "TweenInfo" and (ks == "Time" or ks == "EasingStyle" or ks == "EasingDirection" or ks == "RepeatCount" or ks == "Reverses" or ks == "DelayTime") then
            local defaults = { Time = 1, EasingStyle = "Quad", EasingDirection = "In", RepeatCount = 0, Reverses = false, DelayTime = 0 }
            local val = mt._ctorArgs[({Time=1,EasingStyle=2,EasingDirection=3,RepeatCount=4,Reverses=5,DelayTime=6})[ks]]
            if val ~= nil then return val end
            return defaults[ks]
        end
        if mt._ctorName == "PhysicalProperties" and (ks == "Friction" or ks == "Elasticity" or ks == "ElasticityWeight" or ks == "FrictionWeight" or ks == "Density") then
            local idx = ({ Friction = 1, Elasticity = 2, ElasticityWeight = 3, FrictionWeight = 4, Density = 5 })[ks]
            local val = mt._ctorArgs and mt._ctorArgs[idx]
            if type(val) == "number" then return val end
            return 0
        end
        if mt._ctorName == "Region3" and ks == "Size" then
            local v = makeProxy(name .. ".Size")
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = { 0, 0, 0 }
            return v
        end
        if mt._ctorName == "Region3int16" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3int16"
            vmt._ctorArgs = mt._ctorArgs and { mt._ctorArgs[idx*3-2] or 0, mt._ctorArgs[idx*3-1] or 0, mt._ctorArgs[idx*3] or 0 } or { 0, 0, 0 }
            return v
        end
        if (mt._ctorName == "Vector2int16" or mt._ctorName == "Vector3int16") and (ks == "X" or ks == "Y" or ks == "Z") then
            local idx = ({ X = 1, Y = 2, Z = 3 })[ks]
            local val = mt._ctorArgs and mt._ctorArgs[idx]
            if type(val) == "number" then return math.floor(val) end
            return 0
        end
        if mt._ctorName == "FloatCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "RotationCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "ValueCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if numericPseudoProps[ks] then
            return 0
        end

        do
            local parentNameStr = mt._name or name
            if parentChildMap[parentNameStr] then
                local found = parentChildMap[parentNameStr][ks]
                if found ~= nil then
                    return found
                end
            end
        end

        local cls = mt._className or ""
        local clsInfo = getApiClassInfo(cls)
        local chain = {}
        local cur = clsInfo
        while cur do
            table.insert(chain, cur.name)
            if type(cur.superclass) ~= "string" or cur.superclass == "" then break end
            cur = getApiClassInfo(cur.superclass)
        end
        local foundInDefaults = false
        for i = 1, #chain do
            local defaults = classDefaultProperties[chain[i]]
            if defaults and defaults[ks] ~= nil then
                foundInDefaults = true
                local dv = defaults[ks]
                if dv == "Color3" then
                    local c = makeDataProxy("Color3", { 0.631373, 0.647059, 0.631373 }, name .. "." .. ks)
                    storedValues[ks] = c
                    setKeys[ks] = true
                    return c
                elseif dv == "Vector3" then
                    local v = makeDataProxy("Vector3", { 0, 0, 0 }, name .. "." .. ks)
                    storedValues[ks] = v
                    setKeys[ks] = true
                    return v
                elseif dv == "Vector2" then
                    local v = makeDataProxy("Vector2", { 0, 0 }, name .. "." .. ks)
                    storedValues[ks] = v
                    setKeys[ks] = true
                    return v
                elseif dv == "UDim2" then
                    local u = makeDataProxy("UDim2", { 0, 0, 0, 0 }, name .. "." .. ks)
                    storedValues[ks] = u
                    setKeys[ks] = true
                    return u
                elseif dv == "CFrame" then
                    local cf = makeDataProxy("CFrame", { 0, 0, 0 }, name .. "." .. ks)
                    storedValues[ks] = cf
                    setKeys[ks] = true
                    return cf
                elseif dv == "NumberRange" then
                    local nr = makeDataProxy("NumberRange", { 0, 0 }, name .. "." .. ks)
                    storedValues[ks] = nr
                    setKeys[ks] = true
                    return nr
                elseif type(dv) == "string" and dv:match("^Enum%.") then
                    local enumName = dv:match("^Enum%.([%w_]+)%.")
                    local itemName = dv:sub(dv:find("%.[^%.]*$") + 1, -1)
                    local envRef = _G._envRef
                    if envRef and envRef.Enum and envRef.Enum[enumName] then
                        local item = envRef.Enum[enumName][itemName]
                        storedValues[ks] = item
                        setKeys[ks] = true
                        return item
                    end
                    local enumItem = makeProxy(name .. "." .. ks)
                    local eimt = getmetatable(enumItem)
                    eimt._className = "EnumItem"
                    eimt._ctorName = "EnumItem"
                    eimt._storedValues["Name"] = itemName
                    eimt._setKeys["Name"] = true
                    eimt._storedValues["Value"] = 0
                    eimt._setKeys["Value"] = true
                    eimt._storedValues["EnumType"] = dv:match("^Enum%.([%w_]+)%.")
                    eimt._setKeys["EnumType"] = true
                    storedValues[ks] = enumItem
                    setKeys[ks] = true
                    return enumItem
                else
                    storedValues[ks] = dv
                    setKeys[ks] = true
                    return dv
                end
            end
        end

        local memberDefaultValue = nil
        memberDefaultValue, memberInfo = getMemberDefaultValue(mt._className or "", ks, name .. "." .. ks)
        if memberDefaultValue ~= nil then
            if isProxy(memberDefaultValue) then
                local cmt = getmetatable(memberDefaultValue)
                cmt._parent = t
                cmt._fieldName = ks
            end
            children[ks] = memberDefaultValue
            return memberDefaultValue
        end
        if memberInfo ~= nil then
            return nil
        end

        if booleanPseudoProps[ks] then
            return false
        end
        if stringPseudoProps[ks] then
            return ""
        end
        if color3PseudoProps[ks] then
            local c = makeProxy(name .. "." .. ks)
            local cmt = getmetatable(c)
            cmt._ctorName = "Color3"
            cmt._ctorArgs = { 0.631373, 0.647059, 0.631373 }
            storedValues[ks] = c
            setKeys[ks] = true
            return c
        end
        if vector3PseudoProps[ks] then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = { 0, 0, 0 }
            storedValues[ks] = v
            setKeys[ks] = true
            return v
        end
        if udim2PseudoProps[ks] then
            local u = makeProxy(name .. "." .. ks)
            local umt = getmetatable(u)
            umt._ctorName = "UDim2"
            umt._ctorArgs = { 0, 0, 0, 0 }
            storedValues[ks] = u
            setKeys[ks] = true
            return u
        end

        local clsName = mt._className or "Instance"
        local instDisplayName = storedValues["Name"] or name or clsName
        local errMessage = ks .. " is not a valid member of " .. clsName .. " \"" .. tostring(instDisplayName) .. "\""
        emit(string.format('-- %s', errMessage))
        error(errMessage, 2)
    end
    mt.__newindex = function(t, k, v)
        tick()
        if destroyedInstances[name] then
            error("Instance has been destroyed", 2)
        end
        local ks = tostring(k)
        local cls = mt._className or ""
        local memberInfo = resolveApiMember(cls, ks)
        if memberInfo and not isWritablePropertyMember(memberInfo) then
            error("attempt to set a read-only property '" .. ks .. "'", 2)
        end
        if positiveNumberProps[ks] and type(v) == "number" and v < 0 then
            v = 0
        end
        storedValues[ks] = v
        setKeys[ks] = true
        if ks == "Name" and type(v) == "string" then
            mt._name = v
        end
        if ks == "Parent" and v ~= nil and not isProxy(v) then
            error("attempt to set Parent to a non-Instance value", 2)
        end
        if ks == "Parent" and isProxy(v) then
            local newParent = v
            local cur = newParent
            while cur and isProxy(cur) do
                if rawequal(cur, t) then
                    error("Attempt to set parent to a child of self", 2)
                end
                local curMt = getmetatable(cur)
                cur = curMt and curMt._storedValues and curMt._storedValues["Parent"] or nil
            end
            local parentName = getmetatable(v)._name
            local childName = name
            local childDisplayName = storedValues["Name"] or childName
            if not parentChildMap[parentName] then parentChildMap[parentName] = {} end
            parentChildMap[parentName][childDisplayName] = t
            parentChildMap[parentName][childName] = t
            if storedValues["Anchored"] == false then
                if not unanchoredParts[t] then
                    unanchoredParts[t] = true
                    awakePartsCount += 1
                end
            end
        end
        if ks == "Parent" and v == nil then
            if unanchoredParts[t] then
                unanchoredParts[t] = nil
                if awakePartsCount > 0 then
                    awakePartsCount -= 1
                end
            end
        end
        if ks == "AssemblyLinearVelocity" and isProxy(v) then
            local velMt = getmetatable(v)
            if velMt and velMt._ctorArgs then
                local vx = velMt._ctorArgs[1] or 0
                storedValues["Position"] = makeProxy(name .. ".Position")
                local posMt = getmetatable(storedValues["Position"])
                posMt._ctorArgs = { 0, -500, 0 }
                posMt._ctorName = "Vector3"
                storedValues["Parent"] = nil
            end
        end
        if ks == "VectorVelocity" and isProxy(v) and mt._className == "LinearVelocity" then
            mt._pendingVelocity = v
            local parentRef = storedValues["Parent"]
            if parentRef and isProxy(parentRef) then
                local parentMt = getmetatable(parentRef)
                if parentMt and parentMt._storedValues then
                    local velArgs = {}
                    local srcMt = getmetatable(v)
                    if srcMt then
                        velArgs = rawget(v, "_ctorArgs") or srcMt._ctorArgs or {}
                    end
                    local velProxy = makeDataProxy("Vector3", velArgs, name .. ".AssemblyLinearVelocity")
                    parentMt._storedValues["AssemblyLinearVelocity"] = velProxy
                    parentMt._setKeys["AssemblyLinearVelocity"] = true
                end
            end
        end
        if ks == "Parent" and isProxy(v) and mt._className == "LinearVelocity" and mt._pendingVelocity then
            local parentMt = getmetatable(v)
            if parentMt and parentMt._storedValues then
                local velArgs = {}
                local pending = mt._pendingVelocity
                local srcMt = getmetatable(pending)
                if srcMt then
                    velArgs = rawget(pending, "_ctorArgs") or srcMt._ctorArgs or {}
                end
                local velProxy = makeDataProxy("Vector3", velArgs, name .. ".AssemblyLinearVelocity")
                parentMt._storedValues["AssemblyLinearVelocity"] = velProxy
                parentMt._setKeys["AssemblyLinearVelocity"] = true
            end
        end
        if ks == "Anchored" then
            local cls = mt._className or ""
            local isPartLike = (cls == "Part" or cls == "BasePart" or cls == "TrussPart" or cls == "WedgePart" or cls == "CornerWedgePart" or cls == "MeshPart" or cls == "UnionOperation" or cls == "NegateOperation" or cls == "Seat" or cls == "VehicleSeat")
            if isPartLike and storedValues["Parent"] ~= nil then
                if v == false then
                    if not unanchoredParts[t] then
                        unanchoredParts[t] = true
                        awakePartsCount += 1
                    end
                    if _G._physicsParts then
                        _G._physicsParts[t] = true
                    end
                else
                    if unanchoredParts[t] then
                        unanchoredParts[t] = nil
                        if awakePartsCount > 0 then
                            awakePartsCount -= 1
                        end
                    end
                    if _G._physicsParts then
                        _G._physicsParts[t] = nil
                    end
                end
            end
        end
        if ks == "Parent" and isProxy(v) then
            local cls = mt._className or ""
            local isPartLike = (cls == "Part" or cls == "BasePart" or cls == "TrussPart" or cls == "WedgePart" or cls == "CornerWedgePart" or cls == "MeshPart" or cls == "UnionOperation" or cls == "NegateOperation" or cls == "Seat" or cls == "VehicleSeat")
            if isPartLike and storedValues["Anchored"] == false then
                if _G._physicsParts then
                    _G._physicsParts[t] = true
                end
            end
        end
        if isProxy(v) then
            markUsed(v)
            emit(string.format('%s.%s = %s', name, ks, proxyName(v)))
        elseif type(v) == "function" then
            emit(string.format('%s.%s = function() end', name, ks))
        else
            emit(string.format('%s.%s = %s', name, ks, serialize(v)))
        end
        firePropertyChange(name, ks, v)
    end
    mt.__call = function(t, ...)
        tick()
        local args = {...}
        local n = select("#", ...)
        local parts = {}
        local callExpr
        local startIdx = 1

        local cmt = getmetatable(t)
        local parent = _G._methodParent or cmt._parent
        local fieldName = _G._methodField or cmt._fieldName
        _G._methodParent = nil
        _G._methodField = nil

        if not parent and not fieldName then
            error("attempt to call a Instance value", 2)
        end

        local STATEMENT_METHODS = {
            Connect = true, connect = true, ConnectParallel = true, Once = true, Disconnect = true,
            Wait = true, wait = true, Destroy = true, Remove = true,
            ClearAllChildren = true, DisconnectAll = true,
            Init = true, Notify = true, Play = true, Pause = true, Cancel = true,
            FireServer = true, FireClient = true, FireAllClients = true,
            InvokeServer = true, InvokeClient = true,
            Set = true, set = true, Add = true, Remove = true,
            CaptureController = true, ClickButton1 = true, ClickButton2 = true,
            GetChildren = true, GetDescendants = true, GetFullName = true,
            IsA = true, Clone = true, IsDescendantOf = true,
            GetAsync = true, PostAsync = true, RequestAsync = true,
            HttpGet = true, HttpPost = true, HttpRequest = true,
            JSONEncode = true, JSONDecode = true,
            SetCore = true, GetCore = true,
            FindFirstChild = true, WaitForChild = true,
            FindFirstDescendant = true, FindFirstAncestor = true,
            SetMetadata = true, GetMetadata = true,
            SetItem = true, GetItem = true,
            IsVibrationSupported = true, GetCorescriptLocalizations = true,
            IsAvailable = true, HasAchieved = true,
            GetRealPhysicsFPS = true, GetPhysicsFPS = true,
            PreloadAsync = true, SendKeyEvent = true, GetDebugId = true,
            Create = true, SendAsync = true,
            ApplyAngularImpulse = true, ApplyImpulse = true, ApplyLinearImpulse = true,
            GetPlayerFromCharacter = true, ReadVoxels = true,
            SetSource = true, GetSource = true,
        }

        local isMethod = false
        if parent and n >= 1 and rawequal(args[1], parent) then
            callExpr = proxyName(parent) .. ":" .. fieldName
            markUsed(parent)
            startIdx = 2
            isMethod = true
        elseif parent and STATEMENT_METHODS[fieldName] then
            callExpr = proxyName(parent) .. ":" .. fieldName
            markUsed(parent)
            isMethod = true
        else
            callExpr = name
        end

        if _G._yieldTick and (fieldName == "Wait" or fieldName == "wait") then
            _G._yieldTick()
        end

        for i = startIdx, n do
            table.insert(parts, serialize(args[i]))
        end

        local firstArg = args[startIdx]
        local baseName = makeDescriptiveVar(fieldName, firstArg)
        local retName = baseName
        if usedVarNames[retName] then
            local i = 2
            while usedVarNames[baseName .. tostring(i)] do
                i += 1
            end
            retName = baseName .. tostring(i)
        end
        usedVarNames[retName] = true

        local isStatementCall = isMethod and STATEMENT_METHODS[fieldName] ~= nil

        if isMethod and (fieldName == "GetService" or fieldName == "FindService" or fieldName == "findService") and parent and type(firstArg) == "string" then
            local parentName = proxyName(parent)
            local serviceName = firstArg
            if fieldName == "FindService" or fieldName == "findService" then
                if serviceCache[serviceName] then
                    emit(string.format('local %s = %s:FindService(%s)', serviceName, parentName, serialize(firstArg)))
                    return serviceCache[serviceName]
                end
                if not isApiServiceClass(serviceName) then
                    emit(string.format('local %s = %s:FindService(%s)', serviceName, parentName, serialize(firstArg)))
                    return nil
                end
                local svcProxy = makeProxy(serviceName)
                local svcMt = getmetatable(svcProxy)
                svcMt._className = serviceName
                svcMt._storedValues["ClassName"] = serviceName
                svcMt._setKeys["ClassName"] = true
                svcMt._storedValues["Name"] = serviceName
                svcMt._setKeys["Name"] = true
                if serviceName == "Chat" then
                    local ugcParent = makeProxy("ugc")
                    local ugcMt = getmetatable(ugcParent)
                    ugcMt._className = "Folder"
                    ugcMt._storedValues["Name"] = "Ugc"
                    ugcMt._setKeys["Name"] = true
                    ugcMt._storedValues["ClassName"] = "Folder"
                    ugcMt._setKeys["ClassName"] = true
                    svcMt._storedValues["Parent"] = ugcParent
                    svcMt._setKeys["Parent"] = true
                end
                serviceCache[serviceName] = svcProxy
                emit(string.format('local %s = %s:FindService(%s)', serviceName, parentName, serialize(firstArg)))
                return svcProxy
            end
            if serviceName == "Workspace" or serviceName == "workspace" then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                if workspaceProxy then
                    serviceCache["Workspace"] = workspaceProxy
                    return workspaceProxy
                end
            end
            if serviceName == "DebuggerManager" then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: DebuggerManager not available", 0)
            end
            if SERVER_ONLY_SERVICES[serviceName] then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: " .. serviceName .. " is not a valid service", 0)
            end
            if not isApiServiceClass(serviceName) then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: " .. serviceName .. " is not a valid service", 0)
            end
            if serviceCache[serviceName] then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                return serviceCache[serviceName]
            end
            local serviceProxy = makeProxy(serviceName)
            local serviceMt = getmetatable(serviceProxy)
            serviceMt._className = serviceName
            serviceMt._storedValues["ClassName"] = serviceName
            serviceMt._setKeys["ClassName"] = true
            serviceMt._storedValues["Name"] = serviceName
            serviceMt._setKeys["Name"] = true
            if serviceName == "Chat" then
                local ugcParent = makeProxy("ugc")
                local ugcMt = getmetatable(ugcParent)
                ugcMt._className = "Folder"
                ugcMt._storedValues["Name"] = "Ugc"
                ugcMt._setKeys["Name"] = true
                ugcMt._storedValues["ClassName"] = "Folder"
                ugcMt._setKeys["ClassName"] = true
                serviceMt._storedValues["Parent"] = ugcParent
                serviceMt._setKeys["Parent"] = true
            end
            serviceCache[serviceName] = serviceProxy
            local SERVICE_CHILDREN = {
                TextChatService = { TextChannels = "Folder", TextCommands = "Folder" },
                Players = { LocalPlayer = "Player" },
                NetworkClient = { ClientReplicator = "ClientReplicator" },
                Workspace = { Terrain = "Terrain", Camera = "Camera" },
                CoreGui = { RobloxGui = "ScreenGui", DevConsoleMaster = "ScreenGui" },
                ReplicatedStorage = { DefaultChatSystemChatEvents = "Folder" },
                StarterGui = { },
                StarterPlayer = { StarterPlayerScripts = "Folder", StarterCharacterScripts = "Folder" },
            }
            if SERVICE_CHILDREN[serviceName] then
                if not parentChildMap[serviceName] then parentChildMap[serviceName] = {} end
                for childName, childCls in pairs(SERVICE_CHILDREN[serviceName]) do
                    if not parentChildMap[serviceName][childName] then
                        local child = spyInstance(childCls, childName, true)
                        parentChildMap[serviceName][childName] = child
                        if serviceName == "TextChatService" and childName == "TextChannels" then
                            if not parentChildMap["TextChannels"] then parentChildMap["TextChannels"] = {} end
                            local rbxGeneral = spyInstance("TextChannel", "RBXGeneral", true)
                            parentChildMap["TextChannels"]["RBXGeneral"] = rbxGeneral
                        end
                        if serviceName == "ReplicatedStorage" and childName == "DefaultChatSystemChatEvents" then
                            if not parentChildMap["DefaultChatSystemChatEvents"] then parentChildMap["DefaultChatSystemChatEvents"] = {} end
                            local req = spyInstance("RemoteEvent", "SetBlockedUserIdsRequest", true)
                            parentChildMap["DefaultChatSystemChatEvents"]["SetBlockedUserIdsRequest"] = req
                        end
                    end
                end
            end
            emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
            return serviceProxy
        end

        if isMethod and fieldName == "GetPropertyChangedSignal" and parent and type(firstArg) == "string" then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local cls = parentMt and parentMt._className or ""
            local memberInfo = resolveApiMember(cls, firstArg)
            if not isPropertyMember(memberInfo) then
                emit(string.format('local %s = %s:GetPropertyChangedSignal(%s)', retName, parentName, serialize(firstArg)))
                error("GetPropertyChangedSignal: '" .. firstArg .. "' is not a valid property", 0)
            end
            local signalProxy = makeProxy(retName)
            local signalMt = getmetatable(signalProxy)
            signalMt._className = "RBXScriptSignal"
            signalMt._storedValues["ClassName"] = "RBXScriptSignal"
            signalMt._setKeys["ClassName"] = true
            signalMt._signalForProperty = { proxy = parent, propName = firstArg }
            emit(string.format('local %s = %s:GetPropertyChangedSignal(%s)', retName, parentName, serialize(firstArg)))
            return signalProxy
        end

        if isMethod and (fieldName == "Connect" or fieldName == "connect") and parent then
            local callback = firstArg
            if type(callback) == "function" then
                local parentMt = getmetatable(parent)
                if parentMt and parentMt._signalForProperty then
                    local sigInfo = parentMt._signalForProperty
                    local proxyNameStr = proxyName(sigInfo.proxy)
                    local propName = sigInfo.propName
                    local key = proxyNameStr .. "." .. propName
                    if not propertyChangeCallbacks[key] then
                        propertyChangeCallbacks[key] = {}
                    end
                    table.insert(propertyChangeCallbacks[key], callback)
                end
                local parentNameStr = ""
                local pm = getmetatable(parent)
                if pm and pm._isProxy then parentNameStr = pm._name end
                local eventName = ""
                if pm and pm._signalForEvent then eventName = pm._signalForEvent.eventName or "" end
                if eventName ~= "" then
                    table.insert(eventConnections, {
                        proxy = pm._signalForEvent.proxy,
                        eventName = eventName,
                        callback = callback,
                    })
                    if eventName == "Heartbeat" or eventName == "Stepped" or eventName == "RenderStepped" then
                        local baseTime = os.clock()
                        for i = 1, 10 do
                            pcall(callback, 0.015, baseTime + i * 0.015)
                        end
                    else
                        pcall(callback, makeProxy("eventArgs"))
                    end
                end
            end
            local connProxy = makeProxy(retName)
            local connMt = getmetatable(connProxy)
            connMt._className = "RBXScriptConnection"
            connMt._storedValues["Connected"] = true
            connMt._setKeys["Connected"] = true
            connMt._storedValues["ClassName"] = "RBXScriptConnection"
            connMt._setKeys["ClassName"] = true
            emit(string.format('local %s = %s(%s)', retName, callExpr, serialize(firstArg)))
            return connProxy
        end

        if isMethod and (fieldName == "Once") and parent then
            local callback = firstArg
            if type(callback) == "function" then
                pcall(callback, makeProxy("eventArgs"))
            end
            local connProxy = makeProxy(retName)
            local connMt = getmetatable(connProxy)
            connMt._className = "RBXScriptConnection"
            connMt._storedValues["Connected"] = true
            connMt._setKeys["Connected"] = true
            emit(string.format('local %s = %s(%s)', retName, callExpr, serialize(firstArg)))
            return connProxy
        end

        if isMethod and (fieldName == "Disconnect" or fieldName == "disconnect") then
            if parent then
                local connMt = getmetatable(parent)
                if connMt and connMt._storedValues then
                    connMt._storedValues["Connected"] = false
                    connMt._setKeys["Connected"] = true
                end
            end
            emit(string.format('%s()', callExpr))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "SetAttribute" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SetAttribute(%s)', parentName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            if not parentMt._attributes then parentMt._attributes = {} end
            parentMt._attributes[firstArg] = args[startIdx + 1]
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetAttribute" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAttribute(%s)', retName, parentName, serialize(firstArg)))
            local parentMt = getmetatable(parent)
            if parentMt._attributes then return parentMt._attributes[firstArg] end
            return nil
        end

        if isMethod and fieldName == "GetAttributes" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAttributes()', retName, parentName))
            local parentMt = getmetatable(parent)
            return parentMt._attributes or {}
        end

        if isMethod and fieldName == "Fire" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:Fire(%s)', parentName, table.concat(parts, ", ")))
            for _, conn in ipairs(eventConnections) do
                if rawequal(conn.proxy, parent) and conn.eventName == "Event" then
                    pcall(conn.callback, table.unpack(args, startIdx, n))
                end
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "FireServer" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireServer(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "FireClient" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireClient(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and (fieldName == "FireAllClients") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireAllClients(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "WaitForChild" and parent then
            local parentName = proxyName(parent)
            local timeout = args[startIdx + 1]
            emit(string.format('local %s = %s:WaitForChild(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(timeout) == "number" and timeout < 0 then
                error("WaitForChild: invalid timeout", 0)
            end
            if type(firstArg) == "string" then
                local children = parentChildMap[parentName]
                if children and children[firstArg] then
                    return children[firstArg]
                end
                local parentMt = getmetatable(parent)
                local parentCls = parentMt and parentMt._className or ""
                local SERVICE_KNOWN_CHILDREN = {
                    NetworkClient = { ClientReplicator = "ClientReplicator" },
                    Players = { LocalPlayer = "Player" },
                    Workspace = { Terrain = "Terrain", Camera = "Camera" },
                }
                if SERVICE_KNOWN_CHILDREN[parentCls] and SERVICE_KNOWN_CHILDREN[parentCls][firstArg] then
                    local childCls = SERVICE_KNOWN_CHILDREN[parentCls][firstArg]
                    local child = spyInstance(childCls, firstArg, true)
                    if not parentChildMap[parentName] then parentChildMap[parentName] = {} end
                    parentChildMap[parentName][firstArg] = child
                    return child
                end
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "Wait" then
            emit(string.format('local %s = %s()', retName, callExpr))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetMemStats" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMemStats()', retName, parentName))
            return { cpuLoad = 0, gpuLoad = 0, ram = 0, vram = 0, videoMemory = 0, systemMemory = 0 }
        end

        if isMethod and fieldName == "GetNumAwakeParts" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetNumAwakeParts()', retName, parentName))
            local parentMt = getmetatable(parent)
            local parentCls = parentMt and parentMt._className or ""
            if parentCls == "Workspace" then
                return awakePartsCount
            end
            return 0
        end

        if isMethod and fieldName == "GetCharacterAppearanceInfoAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCharacterAppearanceInfoAsync(%s)', retName, parentName, serialize(firstArg)))
            return {
                assets = {
                    { id = 1, name = "Shirt", assetType = { id = 1, name = "Shirt" } },
                    { id = 2, name = "Pants", assetType = { id = 2, name = "Pants" } },
                },
                bodyColors = {
                    leftArmColorId = 1, torsoColorId = 1, rightArmColorId = 1,
                    headColorId = 1, leftLegColorId = 1, rightLegColorId = 1,
                },
                scales = {
                    bodyType = 0, head = 1, height = 1, proportion = 0,
                    depth = 1, width = 1,
                },
                defaultShirtApplied = false,
                defaultPantsApplied = false,
            }
        end

        if isMethod and fieldName == "AddTag" and parent then
            local parentName = proxyName(parent)
            local instProxy = firstArg
            local instName = ""
            if isProxy(instProxy) then instName = getmetatable(instProxy)._name end
            local tagName = args[startIdx + 1]
            if instName ~= "" and type(tagName) == "string" then
                if not instanceTags[instName] then
                    instanceTags[instName] = {}
                    instanceTags[instName .. ".__proxy__"] = instProxy
                end
                local alreadyHas = false
                for _, t in ipairs(instanceTags[instName]) do
                    if t == tagName then alreadyHas = true break end
                end
                if not alreadyHas then
                    table.insert(instanceTags[instName], tagName)
                end
            end
            emit(string.format('%s:AddTag(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and (fieldName == "Destroy" or fieldName == "Remove") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            if parentClassName == "DataModel" or parentClassName == "Workspace" then
                emit(string.format('%s:%s()', parentName, fieldName))
                error("Cannot destroy " .. parentClassName, 0)
            end
            if parentMt and parentMt._className and isApiServiceClass(parentMt._className) then
                emit(string.format('%s:%s()', parentName, fieldName))
                error("Cannot destroy service " .. parentMt._className, 0)
            end
            emit(string.format('%s:%s()', parentName, fieldName))
            destroyedInstances[parentName] = true
            local pm = getmetatable(parent)
            if pm and pm._storedValues then
                pm._storedValues["Parent"] = nil
                pm._setKeys["Parent"] = true
            end
            local children = parentChildMap[parentName]
            if children then
                for childName, childProxy in pairs(children) do
                    local childMt = getmetatable(childProxy)
                    if childMt and childMt._storedValues then
                        childMt._storedValues["Parent"] = nil
                        childMt._setKeys["Parent"] = true
                    end
                    local grandChildren = parentChildMap[childName]
                    if grandChildren then
                        for _, grandChildProxy in pairs(grandChildren) do
                            local gcm = getmetatable(grandChildProxy)
                            if gcm and gcm._storedValues then
                                gcm._storedValues["Parent"] = nil
                                gcm._setKeys["Parent"] = true
                            end
                        end
                    end
                end
                parentChildMap[parentName] = nil
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "Clone" and parent then
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            if parentClassName == "DataModel" or parentClassName == "Workspace" then
                emit(string.format('%s:Clone()', proxyName(parent)))
                error("Ugc cannot be cloned", 0)
            end
            if parentMt and parentMt._storedValues and parentMt._storedValues["Archivable"] == false then
                emit(string.format('%s:Clone()', proxyName(parent)))
                return nil
            end
            local v = genVar("clone")
            emit(string.format('local %s = %s:Clone()', v, proxyName(parent)))
            local cloneProxy = makeProxy(v)
            local cloneMt = getmetatable(cloneProxy)
            cloneMt._className = parentClassName
            if parentMt and parentMt._storedValues then
                for k, val in pairs(parentMt._storedValues) do
                    cloneMt._storedValues[k] = val
                    cloneMt._setKeys[k] = true
                end
            end
            return cloneProxy
        end

        if isMethod and (fieldName == "Lerp" or fieldName == "Dot" or fieldName == "Cross" or fieldName == "Angle" or fieldName == "FuzzyEq" or fieldName == "Abs" or fieldName == "ToHSV" or fieldName == "ToHex" or fieldName == "ToRGB" or fieldName == "ToOrientation" or fieldName == "Inverse" or fieldName == "ToWorldSpace" or fieldName == "ToObjectSpace" or fieldName == "PointToObjectSpace") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local ctorName = parentMt and (parentMt._ctorName or rawget(parent, "_ctorName")) or ""
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "Lerp" then
                if ctorName == "Color3" then
                    local proxy = makeProxy(retName)
                    local pmt = getmetatable(proxy)
                    pmt._ctorName = "Color3"
                    return proxy
                elseif ctorName == "Vector3" or ctorName == "Vector2" or ctorName == "UDim2" or ctorName == "CFrame" or ctorName == "UDim" then
                    local proxy = makeProxy(retName)
                    local pmt = getmetatable(proxy)
                    pmt._ctorName = ctorName
                    return proxy
                end
            elseif fieldName == "Dot" or fieldName == "Cross" or fieldName == "Angle" then
                if fieldName == "Cross" then
                    local proxy = makeProxy(retName)
                    local pmt = getmetatable(proxy)
                    pmt._ctorName = "Vector3"
                    return proxy
                end
                return 0
            elseif fieldName == "ToHSV" then
                return 0, 0, 0, 0
            elseif fieldName == "ToHex" then
                return "ffffff"
            elseif fieldName == "ToRGB" then
                return 255, 255, 255
            elseif fieldName == "ToOrientation" then
                return 0, 0, 0
            elseif fieldName == "Inverse" or fieldName == "ToWorldSpace" or fieldName == "ToObjectSpace" or fieldName == "PointToObjectSpace" then
                local proxy = makeProxy(retName)
                local pmt = getmetatable(proxy)
                pmt._ctorName = ctorName
                return proxy
            elseif fieldName == "Abs" then
                local proxy = makeProxy(retName)
                local pmt = getmetatable(proxy)
                pmt._ctorName = ctorName
                return proxy
            elseif fieldName == "FuzzyEq" then
                return true
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "Create" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            emit(string.format('local %s = %s:Create(%s)', retName, parentName, table.concat(parts, ", ")))
            local goal = args[startIdx + 2]
            local targetInstance = args[startIdx]
            local targetClassName = ""
            if isProxy(targetInstance) then
                targetClassName = getmetatable(targetInstance)._className or ""
            end
            if type(goal) == "table" then
                for k, v in pairs(goal) do
                    if type(k) == "string" then
                        local expected = getPropertyRuntimeType(targetClassName, k)
                        if expected then
                            local basicType = type(v)
                            if basicType == "string" and expected ~= "string" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif basicType == "boolean" and expected ~= "boolean" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif basicType == "number" and expected ~= "number" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif isProxy(v) and expected == "Instance" then
                                local valueClassName = getmetatable(v)._className
                                local memberInfo = resolveApiMember(targetClassName, k)
                                local valueType = memberInfo and memberInfo.valueType
                                if valueType and valueType.category == "Class" and type(valueType.name) == "string" and valueClassName and not classIsA(valueClassName, valueType.name) then
                                    error("Create: invalid property type for '" .. k .. "'", 0)
                                end
                            end
                        end
                    end
                end
            end
            local tweenProxy = makeProxy(retName)
            local tweenMt = getmetatable(tweenProxy)
            tweenMt._className = "Tween"
            tweenMt._storedValues["ClassName"] = "Tween"
            tweenMt._setKeys["ClassName"] = true
            local tweenRef = tweenProxy
            rawset(tweenProxy, "Play", function(_, ...) _G._methodParent = tweenRef _G._methodField = "Play" return tweenMt.__call(tweenRef, tweenRef, ...) end)
            return tweenProxy
        end

        if isMethod and (fieldName == "FindFirstChild" or fieldName == "findFirstChild") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:FindFirstChild(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) == "string" then
                local children = parentChildMap[parentName]
                if children and children[firstArg] then
                    return children[firstArg]
                end
                local parentMt = getmetatable(parent)
                local parentCls = parentMt and parentMt._className or ""
                if parentCls == "Player" then
                    local PLAYER_CHILDREN = {
                        PlayerScripts = {"PlayerModule", "RbxCharacterSounds"},
                        PlayerGui = {},
                        Backpack = {},
                    }
                    if PLAYER_CHILDREN[firstArg] then
                        local folder = spyInstance("Folder", firstArg, true)
                        for _, childName in ipairs(PLAYER_CHILDREN[firstArg]) do
                            local child = spyInstance("LocalScript", childName, true)
                            if not parentChildMap[firstArg] then parentChildMap[firstArg] = {} end
                            parentChildMap[firstArg][childName] = child
                        end
                        return folder
                    end
                end
                local SERVICE_KNOWN_CHILDREN = {
                    NetworkClient = { ClientReplicator = "ClientReplicator" },
                    Players = { LocalPlayer = "Player" },
                    Workspace = { Terrain = "Terrain", Camera = "Camera" },
                }
                if SERVICE_KNOWN_CHILDREN[parentCls] and SERVICE_KNOWN_CHILDREN[parentCls][firstArg] then
                    local childCls = SERVICE_KNOWN_CHILDREN[parentCls][firstArg]
                    local child = spyInstance(childCls, firstArg, true)
                    if not parentChildMap[parentName] then parentChildMap[parentName] = {} end
                    parentChildMap[parentName][firstArg] = child
                    return child
                end
            end
            return nil
        end

        if isMethod and (fieldName == "FindFirstDescendant" or fieldName == "FindFirstChildWhichIsA" or fieldName == "FindFirstChildOfClass") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            return nil
        end

        if isMethod and (fieldName == "IsServer" or fieldName == "IsClient" or fieldName == "IsStudio") then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s()', retName, parentName, fieldName))
            if fieldName == "IsServer" then return false end
            return true
        end

        if isMethod and (fieldName == "JSONEncode" or fieldName == "jsonEncode") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:JSONEncode(%s)', retName, parentName, table.concat(parts, ", ")))
            return serde.encode("json", firstArg)
        end

        if isMethod and (fieldName == "ApplyAngularImpulse" or fieldName == "ApplyImpulse" or fieldName == "ApplyLinearImpulse") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:%s(%s)', parentName, fieldName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            if parentMt and parentMt._storedValues then
                local impulse = firstArg
                if isProxy(impulse) then
                    local impulseMt = getmetatable(impulse)
                    local impulseArgs = rawget(impulse, "_ctorArgs") or impulseMt._ctorArgs or {0, 0, 0}
                    if fieldName == "ApplyAngularImpulse" then
                        parentMt._storedValues["AssemblyAngularVelocity"] = makeDataProxy("Vector3", impulseArgs, parentName .. ".AssemblyAngularVelocity")
                        parentMt._setKeys["AssemblyAngularVelocity"] = true
                    elseif fieldName == "ApplyLinearImpulse" or fieldName == "ApplyImpulse" then
                        parentMt._storedValues["AssemblyLinearVelocity"] = makeDataProxy("Vector3", impulseArgs, parentName .. ".AssemblyLinearVelocity")
                        parentMt._setKeys["AssemblyLinearVelocity"] = true
                    end
                end
            end
            return
        end

        if isMethod and (fieldName == "GetHumanoidDescriptionFromUserId" or fieldName == "GetHumanoidDescriptionFromUserIdAsync" or fieldName == "GetHumanoidDescriptionFromOutfitId" or fieldName == "GetHumanoidDescriptionFromOutfitIdAsync") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local hd = makeProxy(retName)
            local hdMt = getmetatable(hd)
            hdMt._className = "HumanoidDescription"
            hdMt._storedValues["ClassName"] = "HumanoidDescription"
            hdMt._setKeys["ClassName"] = true
            hdMt._storedValues["Face"] = 0
            hdMt._setKeys["Face"] = true
            hdMt._storedValues["Shirt"] = 0
            hdMt._setKeys["Shirt"] = true
            hdMt._storedValues["Pants"] = 0
            hdMt._setKeys["Pants"] = true
            hdMt._storedValues["Head"] = 0
            hdMt._setKeys["Head"] = true
            hdMt._storedValues["Torso"] = 0
            hdMt._setKeys["Torso"] = true
            hdMt._storedValues["LeftArm"] = 0
            hdMt._setKeys["LeftArm"] = true
            hdMt._storedValues["RightArm"] = 0
            hdMt._setKeys["RightArm"] = true
            hdMt._storedValues["LeftLeg"] = 0
            hdMt._setKeys["LeftLeg"] = true
            hdMt._storedValues["RightLeg"] = 0
            hdMt._setKeys["RightLeg"] = true
            hdMt._storedValues["BodyTypeScale"] = 0
            hdMt._setKeys["BodyTypeScale"] = true
            hdMt._storedValues["HeightScale"] = 1
            hdMt._setKeys["HeightScale"] = true
            hdMt._storedValues["WidthScale"] = 1
            hdMt._setKeys["WidthScale"] = true
            hdMt._storedValues["DepthScale"] = 1
            hdMt._setKeys["DepthScale"] = true
            hdMt._storedValues["HeadScale"] = 1
            hdMt._setKeys["HeadScale"] = true
            hdMt._storedValues["ProportionScale"] = 0
            hdMt._setKeys["ProportionScale"] = true
            hdMt._emotes = { wave = { 1 }, dance = { 2 }, laugh = { 3 } }
            hdMt._equippedEmotes = { { Name = "wave", Slot = 1 }, { Name = "dance", Slot = 2 } }
            return hd
        end

        if isMethod and fieldName == "GetEmotes" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetEmotes()', retName, parentName))
            local parentMt = getmetatable(parent)
            if parentMt and parentMt._emotes then
                return parentMt._emotes
            end
            return { wave = { 1 }, dance = { 2 } }
        end

        if isMethod and fieldName == "GetEquippedEmotes" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetEquippedEmotes()', retName, parentName))
            local parentMt = getmetatable(parent)
            if parentMt and parentMt._equippedEmotes then
                return parentMt._equippedEmotes
            end
            return { { Name = "wave", Slot = 1 } }
        end

        if isMethod and (fieldName == "SetEmotes" or fieldName == "AddEmote" or fieldName == "RemoveEmote" or fieldName == "SetEquippedEmotes" or fieldName == "GetAccessories" or fieldName == "SetAccessories") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:%s(%s)', parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "GetAccessories" then
                return { { AssetId = 0, AccessoryType = "Hat" } }
            end
            return
        end

        if isMethod and fieldName == "IsVibrationSupported" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsVibrationSupported(%s)', retName, parentName, table.concat(parts, ", ")))
            return false
        end

        if isMethod and fieldName == "GetCorescriptLocalizations" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCorescriptLocalizations()', retName, parentName))
            return {
                { Name = "en-us", LocaleId = "en-us" },
                { Name = "es-es", LocaleId = "es-es" },
            }
        end

        if isMethod and fieldName == "GetPlayerFromCharacter" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetPlayerFromCharacter(%s)', retName, parentName, table.concat(parts, ", ")))
            return nil
        end

        if isMethod and fieldName == "ReadVoxels" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:ReadVoxels(%s)', retName, parentName, table.concat(parts, ", ")))
            return {{}, {}, {}}
        end

        if isMethod and (fieldName == "NextNumber" or fieldName == "NextInteger" or fieldName == "NextUnitVector") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            if not parentMt._rngCounter then parentMt._rngCounter = 0 end
            parentMt._rngCounter += 1
            if fieldName == "NextNumber" then
                return 0.5 + parentMt._rngCounter * 0.001
            elseif fieldName == "NextInteger" then
                local min = args[startIdx] or 0
                local max = args[startIdx + 1] or 100
                return min + parentMt._rngCounter
            elseif fieldName == "NextUnitVector" then
                return makeDataProxy("Vector3", {1, 0, 0}, retName)
            end
            return 0
        end

        if isMethod and (fieldName == "GetGroupsAsync" or fieldName == "CreatePath") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "GetGroupsAsync" then
                return { { Id = 1, Name = "Group", Owner = { Name = "Owner", Id = 0 } } }
            end
            local pathProxy = makeProxy(retName)
            local pathMt = getmetatable(pathProxy)
            pathMt._className = "Path"
            pathMt._storedValues["ClassName"] = "Path"
            pathMt._setKeys["ClassName"] = true
            return pathProxy
        end

        if isMethod and (fieldName == "GetProductInfo" or fieldName == "getProductInfo") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetProductInfo(%s)', retName, parentName, table.concat(parts, ", ")))
            local id = firstArg
            if type(id) ~= "number" or id ~= id or id < -1e20 or id > 1e20 then
                error("GetProductInfo: invalid asset id", 0)
            end
            if select("#", ...) - startIdx + 1 > 2 then
                error("GetProductInfo: too many arguments", 0)
            end
            local ok_api, result = pcall(function()
                local res = net.request({
                    url = "https://economy.roblox.com/v2/assets/" .. tostring(id) .. "/details",
                    method = "GET",
                })
                if res.statusCode == 200 then
                    local data = serde.decode("json", res.body)
                    return {
                        AssetId = id,
                        Name = data.Name or "Asset",
                        Description = data.Description or "",
                        AssetTypeId = data.AssetTypeId or 1,
                        Creator = {
                            Id = data.Creator and data.Creator.Id or 0,
                            Name = data.Creator and data.Creator.Name or "Roblox",
                            CreatorType = data.Creator and data.Creator.CreatorType or "User",
                        },
                        IsForSale = data.IsForSale or false,
                        PriceInRobux = data.PriceInRobux or 0,
                        ContentRatingTypeId = data.ContentRatingTypeId or 0,
                    }
                end
                return nil
            end)
            if ok_api and result then
                return result
            end
            return { AssetId = id, Name = "Asset " .. tostring(id), Description = "", AssetTypeId = 1,
                     Creator = { Id = 0, Name = "Creator", CreatorType = "User" },
                     IsForSale = false, PriceInRobux = 0, ContentRatingTypeId = 0 }
        end

        if isMethod and fieldName == "GetCountryRegionForPlayerAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCountryRegionForPlayerAsync(%s)', retName, parentName, table.concat(parts, ", ")))
            if not isProxy(firstArg) then
                error("GetCountryRegionForPlayerAsync: invalid player argument", 0)
            end
            local argMt = getmetatable(firstArg)
            if not argMt or argMt._className ~= "Player" then
                error("GetCountryRegionForPlayerAsync: invalid player argument", 0)
            end
            return "US"
        end

        if isMethod and (fieldName == "GetDataStore" or fieldName == "GetGlobalDataStore") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "GetDataStore" then
                local name = firstArg
                if type(name) ~= "string" or name == "" or name:match("[^%w%-_%.]") or #name > 50 then
                    error("The current identity (7) cannot access DataStoreService", 0)
                end
                error("The current identity (7) cannot access DataStoreService", 0)
            end
            error("The current identity (7) cannot access DataStoreService", 0)
        end

        if isMethod and fieldName == "UrlEncode" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:UrlEncode(%s)', retName, parentName, serialize(firstArg)))
            if type(firstArg) == "string" then
                return firstArg:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end)
            end
            return ""
        end

        if isMethod and (fieldName == "JSONDecode" or fieldName == "jsonDecode") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:JSONDecode(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) ~= "string" then
                error("JSONDecode: invalid argument", 0)
            end
            local ok, result = pcall(function() return serde.decode("json", firstArg) end)
            if not ok then
                error("JSONDecode: invalid JSON", 0)
            end
            return result
        end

        if isMethod and (fieldName == "GenerateGUID" or fieldName == "generateGUID") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GenerateGUID(%s)', retName, parentName, table.concat(parts, ", ")))
            local guidCounter = (_G._guidCounter or 0) + 1
            _G._guidCounter = guidCounter
            local wrap = true
            if args[startIdx] == false then wrap = false end
            local guidStr = string.format("%08x-%04x-%04x-%04x-%012x", guidCounter, guidCounter, guidCounter, guidCounter, guidCounter)
            if wrap then
                return "{" .. guidStr .. "}"
            end
            return guidStr
        end

        if isMethod and fieldName == "GetTagged" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetTagged(%s)', retName, parentName, serialize(firstArg)))
            local tagName = firstArg
            local result = {}
            local seen = {}
            if type(tagName) == "string" then
                for key, tags in pairs(instanceTags) do
                    if type(key) == "string" and not key:find(".__proxy__$") and type(tags) == "table" then
                        for _, t in ipairs(tags) do
                            if t == tagName then
                                local proxy = instanceTags[key .. ".__proxy__"]
                                if proxy and not seen[proxy] then
                                    seen[proxy] = true
                                    table.insert(result, proxy)
                                end
                                break
                            end
                        end
                    end
                end
            end
            return result
        end

        if isMethod and fieldName == "RemoveTag" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:RemoveTag(%s)', parentName, table.concat(parts, ", ")))
            local instName = ""
            if isProxy(firstArg) then instName = getmetatable(firstArg)._name end
            local tagName = args[startIdx + 1]
            if instName ~= "" and type(tagName) == "string" and instanceTags[instName] then
                for i, t in ipairs(instanceTags[instName]) do
                    if t == tagName then
                        table.remove(instanceTags[instName], i)
                        break
                    end
                end
                if #instanceTags[instName] == 0 then
                    instanceTags[instName] = nil
                end
            end
            return
        end

        if isMethod and (fieldName == "GetInstanceAddedSignal" or fieldName == "GetInstanceRemovedSignal") and parent then
            local parentName = proxyName(parent)
            local cacheKey = parentName .. ":" .. fieldName .. ":" .. tostring(firstArg)
            if serviceCache[cacheKey] then
                emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, serialize(firstArg)))
                return serviceCache[cacheKey]
            end
            local sigProxy = makeProxy(retName)
            serviceCache[cacheKey] = sigProxy
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, serialize(firstArg)))
            return sigProxy
        end

        if isMethod and fieldName == "SendAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SendAsync(%s)', parentName, serialize(firstArg)))
            fireAllConnectionsForEvent("TextChatService", "MessageReceived", {
                Text = firstArg,
                TextSource = { UserId = 0 },
            })
            return makeProxy(retName)
        end

        if isMethod and fieldName == "NextInteger" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:NextInteger(%s)', retName, parentName, table.concat(parts, ", ")))
            local min = args[startIdx] or 0
            local max = args[startIdx + 1] or 100
            return math.random(min, max)
        end

        if isMethod and fieldName == "NextNumber" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:NextNumber(%s)', retName, parentName, table.concat(parts, ", ")))
            return math.random()
        end

        if isMethod and (fieldName == "GetSecret" or fieldName == "getSecret") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetSecret(%s)', retName, parentName, serialize(firstArg)))
            local secret = makeProxy(retName)
            local sMt = getmetatable(secret)
            sMt._className = "Secret"
            return secret
        end

        if isMethod and fieldName == "GetAllBoundActionInfo" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAllBoundActionInfo()', retName, parentName))
            return {}
        end

        if isMethod and (fieldName == "CompressBuffer" or fieldName == "DecompressBuffer") and parent then
            local parentName = proxyName(parent)
            local bufArg = args[startIdx]
            local rawData = nil
            if type(bufArg) == "string" then
                rawData = bufArg
            elseif type(bufArg) == "table" and bufArg._data then
                rawData = bufArg._data
            else
                local ok, str = pcall(buffer.tostring, bufArg)
                if ok and type(str) == "string" then
                    rawData = str
                end
            end
            local bufRepr = "nil"
            if rawData then
                bufRepr = "buffer.fromstring(\"<"..#rawData.." bytes>\")"
            end
            local zstdArg = args[startIdx + 1]
            local zstdRepr = "Enum.CompressionAlgorithm.Zstd"
            pcall(function()
                local mt = getmetatable(zstdArg)
                if mt and mt._name then zstdRepr = mt._name end
            end)
            emit(string.format('local %s = %s:%s(%s, %s)', retName, parentName, fieldName, bufRepr, zstdRepr))
            if rawData and #rawData > 0 then
                local mode = fieldName == "CompressBuffer" and "compress" or "decompress"
                local ok2, result = pcall(serde[mode], "zstd", rawData)
                if ok2 and type(result) == "string" and #result > 0 then
                    return buffer.fromstring(result)
                end
            end
            return buffer.fromstring("")
        end

        if isMethod and (fieldName == "SetMetadata" or fieldName == "GetMetadata") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            if not parentMt._metadataStore then parentMt._metadataStore = {} end
            if fieldName == "SetMetadata" then
                emit(string.format('%s:SetMetadata(%s)', parentName, table.concat(parts, ", ")))
                parentMt._metadataStore = args[startIdx] or {}
                return
            else
                emit(string.format('local %s = %s:GetMetadata()', retName, parentName))
                return parentMt._metadataStore or {}
            end
        end

        if isMethod and fieldName == "CreateEditableMesh" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:CreateEditableMesh()', retName, parentName))
            local mesh = makeProxy(retName)
            local meshMt = getmetatable(mesh)
            meshMt._className = "EditableMesh"
            meshMt._storedValues["ClassName"] = "EditableMesh"
            meshMt._setKeys["ClassName"] = true
            meshMt._vertices = {}
            meshMt._vertexPositions = {}
            return mesh
        end

        if isMethod and fieldName == "AddVertex" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local verts = parentMt._vertices or {}
            local positions = parentMt._vertexPositions or {}
            local id = #verts + 1
            verts[id] = id
            local pos = args[startIdx]
            local px, py, pz = 0, 0, 0
            if isProxy(pos) then
                local posArgs = rawget(pos, "_ctorArgs")
                if posArgs then
                    px = posArgs[1] or 0
                    py = posArgs[2] or 0
                    pz = posArgs[3] or 0
                end
            end
            positions[id] = {px, py, pz}
            parentMt._vertices = verts
            parentMt._vertexPositions = positions
            emit(string.format('local %s = %s:AddVertex(%s)', retName, parentName, table.concat(parts, ", ")))
            return id
        end

        if isMethod and fieldName == "GetVertices" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            emit(string.format('local %s = %s:GetVertices()', retName, parentName))
            local verts = parentMt._vertices or {}
            local out = {}
            for i, v in ipairs(verts) do out[i] = v end
            return out
        end

        if isMethod and fieldName == "GetPosition" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local vid = args[startIdx]
            local positions = parentMt._vertexPositions or {}
            emit(string.format('local %s = %s:GetPosition(%s)', retName, parentName, table.concat(parts, ", ")))
            local pos = positions[vid] or {0, 0, 0}
            return makeDataProxy("Vector3", { pos[1] or 0, pos[2] or 0, pos[3] or 0 }, retName)
        end

        if isMethod and fieldName == "GetDebugId" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetDebugId(%s)', retName, parentName, table.concat(parts, ", ")))
            _G._debugIdCounter = (_G._debugIdCounter or 100000000000) + 1
            return tostring(_G._debugIdCounter)
        end

        if isMethod and (fieldName == "PreloadAsync" or fieldName == "SendKeyEvent" or fieldName == "SendMouseButtonEvent" or fieldName == "SendMouseMoveEvent") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:%s(%s)', parentName, fieldName, table.concat(parts, ", ")))
            return
        end

        if isMethod and (fieldName == "GetRealPhysicsFPS" or fieldName == "GetPhysicsFPS") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s()', retName, parentName, fieldName))
            return 60.0
        end

        if isMethod and fieldName == "GetMixerTime" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMixerTime()', retName, parentName))
            return os.clock()
        end

        if isMethod and fieldName == "GetClasses" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetClasses(%s)', retName, parentName, table.concat(parts, ", ")))
            local result = {}
            for className, clsInfo in pairs(apiClassesByName) do
                table.insert(result, {
                    Name = className,
                    Superclass = clsInfo.superclass or "",
                    Members = {},
                    Tags = {},
                })
            end
            return result
        end

        if isMethod and (fieldName == "GetCore" or fieldName == "getCore") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCore(%s)', retName, parentName, table.concat(parts, ", ")))
            error("The current identity (2) cannot GetCore (lacking permission missing for call)", 0)
        end

        if isMethod and (fieldName == "SetCore" or fieldName == "setCore") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SetCore(%s)', parentName, table.concat(parts, ", ")))
            error("The current identity (2) cannot SetCore (lacking permission missing for call)", 0)
        end

        if isMethod and (fieldName == "SetItem" or fieldName == "GetItem") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            if not parentMt._itemStore then parentMt._itemStore = {} end
            local key = args[startIdx]
            local keyStr = type(key) == "string" and key or tostring(key)
            if fieldName == "SetItem" then
                emit(string.format('%s:SetItem(%s)', parentName, table.concat(parts, ", ")))
                parentMt._itemStore[keyStr] = args[startIdx + 1]
                return
            else
                emit(string.format('local %s = %s:GetItem(%s)', retName, parentName, table.concat(parts, ", ")))
                return parentMt._itemStore[keyStr]
            end
        end

        if isMethod and fieldName == "IsVibrationSupported" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsVibrationSupported(%s)', retName, parentName, table.concat(parts, ", ")))
            return false
        end

        if isMethod and (fieldName == "IsAvailable" or fieldName == "HasAchieved") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            return false
        end

        if isMethod and (fieldName == "CompressBuffer" or fieldName == "DecompressBuffer") and parent then
            local parentName = proxyName(parent)
            local bufArg = args[startIdx]
            local rawData = nil
            if type(bufArg) == "string" then rawData = bufArg
            else
                local ok, str = pcall(buffer.tostring, bufArg)
                if ok and type(str) == "string" then rawData = str end
            end
            local bufRepr = "nil"
            if rawData then bufRepr = "buffer.fromstring(\"<"..#rawData.." bytes>\")" end
            emit(string.format('local %s = %s:%s(%s, %s)', retName, parentName, fieldName, bufRepr, "Enum.CompressionAlgorithm.Zstd"))
            if rawData and #rawData > 0 then
                local mode = fieldName == "CompressBuffer" and "compress" or "decompress"
                local ok2, result = pcall(serde[mode], "zstd", rawData)
                if ok2 and type(result) == "string" and #result > 0 then
                    return buffer.fromstring(result)
                end
            end
            return buffer.fromstring("")
        end

        if isMethod and fieldName == "WorldToScreenPoint" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:WorldToScreenPoint(%s)', retName, parentName, table.concat(parts, ", ")))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector3"
            vMt._ctorArgs = { 0, 0, 0 }
            return v
        end

        if isMethod and fieldName == "Raycast" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:Raycast(%s)', retName, parentName, table.concat(parts, ", ")))
            return nil
        end

        if isMethod and fieldName == "GetMouseLocation" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMouseLocation()', retName, parentName))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector2"
            vMt._ctorArgs = { 0, 0 }
            return v
        end

        if isMethod and fieldName == "GetMouse" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMouse()', retName, parentName))
            local mouse = makeProxy(retName)
            local mMt = getmetatable(mouse)
            mMt._className = "PlayerMouse"
            mMt._storedValues["ClassName"] = "PlayerMouse"
            mMt._setKeys["ClassName"] = true
            return mouse
        end

        if isMethod and fieldName == "ClosestPoint" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:ClosestPoint(%s)', retName, parentName, table.concat(parts, ", ")))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector3"
            vMt._ctorArgs = { 0, 0, 0 }
            return v
        end

        if isMethod and (fieldName == "GetPartsInPart" or fieldName == "GetPartsInBox" or fieldName == "GetPartBoundsInBox" or fieldName == "GetPartBoundsInRadius") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            return {}
        end

        if isMethod and fieldName == "IsA" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsA(%s)', retName, parentName, serialize(firstArg)))
            local parentMt = getmetatable(parent)
            local cls = parentMt and parentMt._className or ""
            if type(firstArg) == "string" then return classIsA(cls, firstArg) end
            return false
        end

        if isMethod and (fieldName == "FormatUniversalTime" or fieldName == "FormatLocalTime") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            local ts = parentMt and parentMt._storedValues and parentMt._storedValues["UnixTimestamp"] or 0
            local day = os.date("!%Y-%m-%d", ts)
            local time = os.date("!%H:%M:%S", ts)
            local fmt = firstArg or ""
            if fmt:find("YYYY") then
                return os.date("!%Y", ts) .. "-" .. os.date("!%m", ts) .. "-" .. os.date("!%d", ts)
            elseif fmt:find("HH") then
                return os.date("!%H", ts) .. ":" .. os.date("!%M", ts) .. ":" .. os.date("!%S", ts)
            end
            return day .. " " .. time
        end

        if isMethod and fieldName == "IsRunning" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsRunning()', retName, parentName))
            return true
        end

        if isMethod and fieldName == "GetTags" and parent then
            local parentName = proxyName(parent)
            local instName = ""
            if isProxy(firstArg) then instName = getmetatable(firstArg)._name end
            emit(string.format('local %s = %s:GetTags(%s)', retName, parentName, serialize(firstArg)))
            return instanceTags[instName] or {}
        end

        if isMethod and fieldName == "GetChildren" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetChildren()', parentName))
            local parentMt = getmetatable(parent)
            local parentCls = parentMt and parentMt._className or ""
            if parentCls == "DataModel" then
                local result = {}
                local seen = {}
                for svcName, svcProxy in pairs(serviceCache) do
                    if not seen[svcProxy] then
                        seen[svcProxy] = true
                        table.insert(result, svcProxy)
                    end
                end
                local COMMON_SERVICES = {
                    "Workspace", "Players", "ReplicatedStorage", "ReplicatedFirst",
                    "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack",
                    "StarterPlayer", "Lighting", "SoundService", "Chat", "HttpService",
                    "RunService", "TweenService", "UserInputService", "ContextActionService",
                }
                for _, svcName in ipairs(COMMON_SERVICES) do
                    if not serviceCache[svcName] and isApiServiceClass(svcName) and not SERVER_ONLY_SERVICES[svcName] then
                        local svc = spyInstance(svcName, svcName:lower(), true)
                        local svcMt = getmetatable(svc)
                        svcMt._className = svcName
                        svcMt._storedValues["ClassName"] = svcName
                        svcMt._setKeys["ClassName"] = true
                        svcMt._storedValues["Name"] = svcName
                        svcMt._setKeys["Name"] = true
                        if svcName == "Chat" then
                            local ugcParent = makeProxy("ugc")
                            local ugcMt = getmetatable(ugcParent)
                            ugcMt._className = "Folder"
                            ugcMt._storedValues["Name"] = "Ugc"
                            ugcMt._setKeys["Name"] = true
                            ugcMt._storedValues["ClassName"] = "Folder"
                            ugcMt._setKeys["ClassName"] = true
                            svcMt._storedValues["Parent"] = ugcParent
                            svcMt._setKeys["Parent"] = true
                        end
                        serviceCache[svcName] = svc
                    end
                    if serviceCache[svcName] and not seen[serviceCache[svcName]] then
                        seen[serviceCache[svcName]] = true
                        table.insert(result, serviceCache[svcName])
                    end
                end
                return result
            end
            if parentCls == "Workspace" then
                local children = parentChildMap[parentName] or {}
                local result = {}
                for _, child in pairs(children) do
                    table.insert(result, child)
                end
                return result
            end
            local children = parentChildMap[parentName] or {}
            local result = {}
            for _, child in pairs(children) do
                table.insert(result, child)
            end
            return result
        end

        if isMethod and fieldName == "GetFullName" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetFullName()', parentName))
            local parts = {}
            local cur = parent
            local seen = {}
            local isTargetGame = false
            while cur and not seen[cur] do
                seen[cur] = true
                local curMt = getmetatable(cur)
                if not curMt then break end
                local isGame = curMt._className == "DataModel"
                if isGame and #parts == 0 then
                    isTargetGame = true
                    local curName = (curMt._storedValues and curMt._storedValues["Name"]) or "game"
                    table.insert(parts, 1, tostring(curName))
                    break
                end
                if isGame then break end
                local curName = (curMt._storedValues and curMt._storedValues["Name"])
                if not curName or curName == "" then
                    curName = curMt._className or curMt._name
                end
                if not curName or curName == "" then break end
                table.insert(parts, 1, tostring(curName))
                local parentRef = curMt._storedValues and curMt._storedValues["Parent"]
                if not parentRef or not isProxy(parentRef) then break end
                cur = parentRef
            end
            return table.concat(parts, ".")
        end

        if isMethod and fieldName == "GetDescendants" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetDescendants()', parentName))
            local result = {}
            local seen = {}
            local function collectChildren(parentProxy)
                local pn = proxyName(parentProxy)
                local children = parentChildMap[pn]
                if children then
                    for _, child in pairs(children) do
                        if not seen[child] then
                            seen[child] = true
                            table.insert(result, child)
                            collectChildren(child)
                        end
                    end
                end
            end
            collectChildren(parent)
            if parentName == "game" or proxyName(parent) == "game" then
                local scripts = {
                    { "StarterPlayer", "StarterPlayerScripts", "LocalScript" },
                    { "StarterPlayer", "StarterCharacterScripts", "LocalScript" },
                    { "StarterGui", "MainScript", "LocalScript" },
                    { "ReplicatedStorage", "ModuleScript1", "ModuleScript" },
                    { "ReplicatedStorage", "ModuleScript2", "ModuleScript" },
                    { "ReplicatedStorage", "ModuleScript3", "ModuleScript" },
                    { "ReplicatedFirst", "ModuleScript4", "ModuleScript" },
                }
                for _, s in ipairs(scripts) do
                    local script = spyInstance(s[3], s[2], true)
                    if not seen[script] then
                        seen[script] = true
                        table.insert(result, script)
                    end
                end
            end
            return result
        end

        if isMethod and fieldName == "GetPlayers" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetPlayers()', parentName))
            local parentMt = getmetatable(parent)
            if parentMt and parentMt._className == "Players" then
                local players = {}
                local lp = parent.LocalPlayer
                if lp then
                    table.insert(players, lp)
                end
                return players
            end
            return {}
        end

        if isStatementCall then
            emit(string.format('%s(%s)', callExpr, table.concat(parts, ", ")))
            return makeProxy(retName)
        end
        emit(string.format('local %s = %s(%s)', retName, callExpr, table.concat(parts, ", ")))
        return makeProxy(retName)
    end
    mt.__tostring = function() return name end
    mt.__namecall = function(t, ...)
        local args = {...}
        local n = select("#", ...)
        error(string.format("attempt to call missing method '%s' of Instance '%s'", tostring(args[1] and "unknown" or "unknown"), tostring(t)), 2)
    end
    mt.__len = function()
        error("attempt to get length of a Instance value", 2)
    end
    mt.__concat = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s .. %s', retName, sa, sb))
        return makeProxy(retName)
    end
    local function makeVector3FromArgs(x, y, z)
        local retName = genVar("v")
        emit(string.format('local %s = Vector3.new(%s, %s, %s)', retName, serialize(x), serialize(y), serialize(z)))
        local proxy = makeProxy(retName)
        local pmt = getmetatable(proxy)
        pmt._ctorName = "Vector3"
        pmt._ctorArgs = { x, y, z }
        return proxy
    end
    local function makeFastVector3(x, y, z, expr)
        local retName = genVar("v")
        if expr then
            emit("local " .. retName .. " = " .. expr)
        else
            emit("local " .. retName .. " = Vector3.new(" .. serialize(x) .. ", " .. serialize(y) .. ", " .. serialize(z) .. ")")
        end
        local proxy = makeProxy(retName)
        local pmt = getmetatable(proxy)
        pmt._ctorName = "Vector3"
        pmt._ctorArgs = { x, y, z }
        return proxy
    end
    local function getVector3Args(v)
        if isProxy(v) then
            local m = getmetatable(v)
            if m and m._ctorName == "Vector3" and m._ctorArgs then
                return m._ctorArgs[1] or 0, m._ctorArgs[2] or 0, m._ctorArgs[3] or 0
            end
        end
        return nil
    end
    mt.__add = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax + bx, ay + by, az + bz, sa .. " + " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s + %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__sub = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax - bx, ay - by, az - bz, sa .. " - " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s - %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mul = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax * bx, ay * by, az * bz, sa .. " * " .. sb)
        end
        if ax and type(b) == "number" then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            markUsed(a)
            return makeFastVector3(ax * b, ay * b, az * b, sa .. " * " .. serialize(b))
        end
        if type(a) == "number" and bx then
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(b)
            return makeFastVector3(a * bx, a * by, a * bz, serialize(a) .. " * " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s * %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__div = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax / bx, ay / by, az / bz, sa .. " / " .. sb)
        end
        if ax and type(b) == "number" then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            markUsed(a)
            return makeFastVector3(ax / b, ay / b, az / b, sa .. " / " .. serialize(b))
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s / %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mod = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s %% %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__pow = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s ^ %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__unm = function(a)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        markUsed(a)
        local retName = genVar("v")
        emit(string.format('local %s = -%s', retName, sa))
        return makeProxy(retName)
    end
    mt.__len = function()
        error("attempt to get length of a Instance value", 2)
    end
    mt.__eq = function(a, b)
        if rawequal(a, b) then return true end
        if isProxy(a) and isProxy(b) then
            local am = getmetatable(a)
            local bm = getmetatable(b)
            if am._ctorName and am._ctorName == bm._ctorName and am._ctorArgs and bm._ctorArgs then
                if #am._ctorArgs == #bm._ctorArgs then
                    local allEq = true
                    for i, v in ipairs(am._ctorArgs) do
                        if v ~= bm._ctorArgs[i] then allEq = false break end
                    end
                    if allEq then return true end
                end
            end
            if am._className and am._className == bm._className then
                if am._storedValues and bm._storedValues then
                    if am._storedValues["Name"] and bm._storedValues["Name"] and am._storedValues["Name"] == bm._storedValues["Name"] then
                        return true
                    end
                end
            end
            return am._name == bm._name
        end
        return false
    end
    mt.__lt = function(a, b) return false end
    mt.__le = function(a, b) return rawequal(a, b) end

    return setmetatable({}, mt)
end

applyClassDefaults = function(proxy: any, className: string)
    local mt = getmetatable(proxy)
    if not mt then return end
    local clsInfo = getApiClassInfo(className)
    local chain = {}
    local cur = clsInfo
    while cur do
        table.insert(chain, cur.name)
        if type(cur.superclass) ~= "string" or cur.superclass == "" then break end
        cur = getApiClassInfo(cur.superclass)
    end
    for i = 1, #chain do
        local defaults = classDefaultProperties[chain[i]]
        if defaults then
            for propName, dv in pairs(defaults) do
                if not mt._setKeys[propName] then
                    if dv == "Color3" then
                        mt._storedValues[propName] = makeDataProxy("Color3", { 0.631373, 0.647059, 0.631373 }, mt._name .. "." .. propName)
                    elseif dv == "Vector3" then
                        mt._storedValues[propName] = makeDataProxy("Vector3", { 0, 0, 0 }, mt._name .. "." .. propName)
                    elseif dv == "Vector2" then
                        mt._storedValues[propName] = makeDataProxy("Vector2", { 0, 0 }, mt._name .. "." .. propName)
                    elseif dv == "UDim2" then
                        mt._storedValues[propName] = makeDataProxy("UDim2", { 0, 0, 0, 0 }, mt._name .. "." .. propName)
                    elseif dv == "CFrame" then
                        mt._storedValues[propName] = makeDataProxy("CFrame", { 0, 0, 0 }, mt._name .. "." .. propName)
                    elseif dv == "NumberRange" then
                        mt._storedValues[propName] = makeDataProxy("NumberRange", { 0, 0 }, mt._name .. "." .. propName)
                    elseif type(dv) == "string" and dv:match("^Enum%.") then
                        local enumName = dv:match("^Enum%.([%w_]+)%.")
                        local itemName = dv:sub(dv:find("%.[^%.]*$") + 1, -1)
                        local envRef = _G._envRef
                        if envRef and envRef.Enum and envRef.Enum[enumName] then
                            mt._storedValues[propName] = envRef.Enum[enumName][itemName]
                        else
                            local enumItem = makeProxy(mt._name .. "." .. propName)
                            local eimt = getmetatable(enumItem)
                            eimt._className = "EnumItem"
                            eimt._ctorName = "EnumItem"
                            eimt._storedValues["Name"] = itemName
                            eimt._setKeys["Name"] = true
                            eimt._storedValues["Value"] = 0
                            eimt._setKeys["Value"] = true
                            eimt._storedValues["EnumType"] = enumName
                            eimt._setKeys["EnumType"] = true
                            mt._storedValues[propName] = enumItem
                        end
                    else
                        mt._storedValues[propName] = dv
                    end
                    mt._setKeys[propName] = true
                end
            end
        end
    end
end

spyInstance = function(className: string, name: string?, silent: boolean?): any
    local varName = name or genVar("inst")
    if not silent then
        emit(string.format('local %s = Instance.new("%s")', varName, className))
    end
    local proxy = makeProxy(varName)
    local mt = getmetatable(proxy)
    mt._className = className
    mt._storedValues["ClassName"] = className
    mt._setKeys["ClassName"] = true
    mt._storedValues["Name"] = className
    mt._setKeys["Name"] = true
    applyClassDefaults(proxy, className)
    return proxy
end

local env
local _realDebug = debug
local _realDebugInfo = _realDebug and _realDebug.info or nil
local _realDebugTraceback = _realDebug and _realDebug.traceback or nil
local functionAddrMap = setmetatable({}, { __mode = "k" })
local frozenTables = setmetatable({}, { __mode = "k" })
local readonlyTables = setmetatable({}, { __mode = "k" })
local hookTargets = setmetatable({}, { __mode = "k" })
local hookReplacements = setmetatable({}, { __mode = "k" })
local originalBehaviors = setmetatable({}, { __mode = "k" })
local cloneSources = setmetatable({}, { __mode = "k" })
local cloneWrappers = setmetatable({}, { __mode = "k" })
local cclosureSet = setmetatable({}, { __mode = "k" })
local constantEdits = setmetatable({}, { __mode = "k" })
local applyReadonlyGuard: (any) -> ()
local function registerCFunctions(lib)
    if type(lib) == "table" then
        for k, v in pairs(lib) do
            if type(v) == "function" then knownCFunctions[v] = true end
        end
    end
end
registerCFunctions(math)
registerCFunctions(string)
registerCFunctions(table)
registerCFunctions(coroutine)
registerCFunctions(os)
registerCFunctions(bit32)
registerCFunctions(utf8)
knownCFunctions[print] = true
knownCFunctions[pcall] = true
knownCFunctions[xpcall] = true
knownCFunctions[error] = true
knownCFunctions[assert] = true
knownCFunctions[tonumber] = true
knownCFunctions[tostring] = true
knownCFunctions[type] = true
knownCFunctions[select] = true
knownCFunctions[pairs] = true
knownCFunctions[ipairs] = true
knownCFunctions[next] = true
knownCFunctions[rawget] = true
knownCFunctions[rawset] = true
knownCFunctions[rawequal] = true
knownCFunctions[rawlen] = true
knownCFunctions[setmetatable] = true
knownCFunctions[getmetatable] = true
knownCFunctions[unpack] = true
local function createEnv()
    env = {}
    env._G = {}
    env._ENV = env
    local function getFunctionWhat(f)
        if type(f) ~= "function" then
            return nil
        end
        if knownCFunctions[f] or cclosureSet[f] then
            return "C"
        end
        if _realDebugInfo then
            local ok, what = pcall(_realDebugInfo, f, "w")
            if ok and type(what) == "string" then
                return what
            end
        end
        return "Lua"
    end
    local function copyLib(lib, extra)
        local c = {}
        for k, v in pairs(lib) do c[k] = v end
        if extra then
            for k, v in pairs(extra) do c[k] = v end
        end
        return setmetatable(c, {
            __newindex = function(_, k, v)
                error("attempt to write to read-only library table", 2)
            end
        })
    end
    env.math = copyLib(math, {
        abs = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'abs' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.abs(x) end,
        floor = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'floor' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.floor(x) end,
        ceil = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'ceil' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.ceil(x) end,
        sqrt = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'sqrt' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.sqrt(x) end,
        sin = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'sin' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.sin(x) end,
        cos = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'cos' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.cos(x) end,
        tan = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'tan' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.tan(x) end,
        random = function(a, b) if a and b then return math.random(a, b) elseif a then return math.random(a) else return math.random() end end,
        clamp = function(x, min, max) if type(x) ~= "number" then return 0 end return math.clamp(x, min, max) end,
        sign = function(x) if type(x) ~= "number" then return 0 end return math.sign(x) end,
        round = function(x) if type(x) ~= "number" then return 0 end return math.round(x) end,
        fmod = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.fmod(x, y) end,
        pow = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.pow(x, y) end,
        exp = function(x) if type(x) ~= "number" then return 0 end return math.exp(x) end,
        log = function(x, base) if type(x) ~= "number" then return 0 end if base then return math.log(x, base) end return math.log(x) end,
        asin = function(x) if type(x) ~= "number" then return 0 end return math.asin(x) end,
        acos = function(x) if type(x) ~= "number" then return 0 end return math.acos(x) end,
        atan = function(x, y) if type(x) ~= "number" then return 0 end if y then return math.atan(x, y) end return math.atan(x) end,
        atan2 = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.atan2(x, y) end,
        huge = math.huge, pi = math.pi, maxinteger = math.maxinteger, mininteger = math.mininteger,
        noise = function(x, y, z) return 0 end,
        randomseed = function(seed) math.randomseed(seed) end,
    })
    registerCFunctions(env.math)
    for _, v in pairs(env.math) do
        if type(v) == "function" then knownCFunctions[v] = true end
    end
    knownCFunctions[env.math.clamp] = true
    knownCFunctions[env.math.sign] = true
    knownCFunctions[env.math.round] = true
    knownCFunctions[env.math.noise] = true
    knownCFunctions[env.math.randomseed] = true
    env.string = copyLib(string, {
        dump = function(f, strip)
            error("unable to dump given function", 2)
        end,
    })
    registerCFunctions(env.string)
    env.table = copyLib(table, {
        isfrozen = function(t)
            if type(t) ~= "table" then return false end
            return frozenTables[t] == true
        end,
        freeze = function(t)
            if type(t) ~= "table" then error("invalid argument #1 to 'freeze' (table expected)", 2) end
            frozenTables[t] = true
            applyReadonlyGuard(t)
            return t
        end,
        find = function() return nil end,
        clone = function(t)
            if type(t) ~= "table" then return t end
            local c = {}
            for k, v in pairs(t) do c[k] = v end
            return c
        end,
        isfrozen = function(t)
            if type(t) ~= "table" then return false end
            return frozenTables[t] == true
        end,
        create = function(n, v)
            if type(n) ~= "number" then n = 0 end
            if n < 0 then n = 0 end
            if n > 1000000 then n = 1000000 end
            local t = {}
            for i = 1, math.floor(n) do t[i] = v end
            return t
        end,
    })
    local function checkFrozen(t, op, key)
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            local desc = op == "newindex" and ("attempt to modify a readonly table (" .. tostring(key) .. ")") or "attempt to modify a readonly table"
            error(desc, 3)
        end
    end
    local realSetmetatable = setmetatable
    applyReadonlyGuard = function(t)
        if type(t) ~= "table" then return end
        if frozenTables[t] then
            local snapshot = {}
            for k, v in pairs(t) do snapshot[k] = v end
            for k in pairs(t) do rawset(t, k, nil) end
            local guardMt = {
                __index = snapshot,
                __newindex = function(tt, k, v)
                    error("attempt to modify a readonly table", 2)
                end,
                _isReadonlyGuard = true,
                _isFrozen = true,
            }
            realSetmetatable(t, guardMt)
            return
        end
        local existingMt = getmetatable(t)
        if existingMt and existingMt._isReadonlyGuard and existingMt._isFrozen then
            return
        end
        if existingMt and existingMt.__newindex and not existingMt._isReadonlyGuard then
            local prevNewindex = existingMt.__newindex
            existingMt.__newindex = function(tt, k, v)
                if readonlyTables[t] or frozenTables[t] then
                    error("attempt to modify a readonly table", 2)
                end
                if type(prevNewindex) == "function" then
                    prevNewindex(tt, k, v)
                else
                    rawset(tt, k, v)
                end
            end
            existingMt._isReadonlyGuard = true
            return
        end
        if existingMt == nil then
            local guardMt = {
                __newindex = function(tt, k, v)
                    if readonlyTables[t] or frozenTables[t] then
                        error("attempt to modify a readonly table", 2)
                    end
                    rawset(tt, k, v)
                end,
                _isReadonlyGuard = true,
            }
            realSetmetatable(t, guardMt)
        end
    end
    env.coroutine = copyLib(coroutine)
    env.os = setmetatable({
        time = os.time,
        date = os.date,
        clock = os.clock,
        difftime = os.difftime,
    }, {
        _serialName = "os",
        __newindex = function() error("attempt to write to read-only library table", 2) end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
    })
    env.debug = setmetatable({
        info = function(f, what)
            what = what or "fl"
            if type(f) == "function" then
                local isC = knownCFunctions[f] or cclosureSet[f]
                local source, whatKind, currentline, linedefined, lastlinedefined, name, nparams, isvararg, nups
                if isC then
                    source = "[C]"
                    whatKind = "C"
                    currentline = -1
                    linedefined = -1
                    lastlinedefined = -1
                    name = ""
                    pcall(function()
                        if type(f) == "function" then
                            local s = tostring(f)
                            local knownNames = {
                                print = true, warn = true, error = true, assert = true,
                                pcall = true, xpcall = true, select = true, tostring = true,
                                tonumber = true, type = true, typeof = true, unpack = true,
                                rawget = true, rawset = true, rawequal = true, rawlen = true,
                                setmetatable = true, getmetatable = true, pairs = true,
                                ipairs = true, next = true, getfenv = true, setfenv = true,
                                require = true, loadstring = true, load = true,
                                info = true, traceback = true, getinfo = true,
                            }
                            for n, _ in pairs(knownNames) do
                                if env[n] and env[n] == f then name = n break end
                                if env.debug and env.debug[n] and env.debug[n] == f then name = n break end
                            end
                        end
                    end)
                    nparams = 0
                    isvararg = true
                    pcall(function()
                        local nonVararg = { type = true, typeof = true, setmetatable = true, getmetatable = true, rawlen = true }
                        for n, _ in pairs(nonVararg) do
                            if env[n] and env[n] == f then isvararg = false break end
                        end
                    end)
                    nups = 0
                else
                    local ok, src = pcall(_realDebugInfo, f, "s")
                    if ok then source = src else source = "[?]" end
                    local ok2, w2 = pcall(_realDebugInfo, f, "w")
                    if ok2 then whatKind = w2 else whatKind = "Lua" end
                    local ok3, ln = pcall(_realDebugInfo, f, "l")
                    if ok3 then currentline = ln else currentline = -1 end
                    local ok4, ld = pcall(_realDebugInfo, f, "l")
                    if ok4 then linedefined = ld else linedefined = -1 end
                    lastlinedefined = -1
                    local ok5, nm = pcall(_realDebugInfo, f, "n")
                    if ok5 then name = nm or "" else name = "" end
                    local ok6, np, iv = pcall(_realDebugInfo, f, "a")
                    if ok6 then nparams = np isvararg = iv else nparams = 0 isvararg = false end
                    local ok7, nupsV = pcall(_realDebugInfo, f, "u")
                    if ok7 and type(nupsV) == "number" then nups = nupsV else nups = 0 end
                end
                if what == "*" or what == "" then
                    return {
                        source = source, short_src = source, what = whatKind,
                        currentline = currentline, linedefined = linedefined,
                        lastlinedefined = lastlinedefined, name = name,
                        nups = nups, nparams = nparams, is_vararg = isvararg, func = f,
                    }
                end
                local results = {}
                for i = 1, #what do
                    local ch = what:sub(i, i)
                    if ch == "s" then table.insert(results, source)
                    elseif ch == "l" then table.insert(results, currentline)
                    elseif ch == "n" then table.insert(results, name)
                    elseif ch == "f" then table.insert(results, f)
                    elseif ch == "a" then table.insert(results, nparams) table.insert(results, isvararg)
                    elseif ch == "u" then table.insert(results, nups)
                    elseif ch == "w" then table.insert(results, whatKind)
                    else table.insert(results, nil) end
                end
                return table.unpack(results)
            end
            if type(f) == "nil" then
                error("invalid argument #1 to 'info' (number or function expected)", 2)
            end
            if type(f) == "number" then
                if f > 5 then
                    if type(what) == "string" and #what > 0 and what ~= "*" then
                        local results = {}
                        for i = 1, #what do table.insert(results, nil) end
                        return table.unpack(results)
                    end
                    return nil
                end
                local results = {}
                if type(what) == "string" and #what > 0 and what ~= "*" then
                    for i = 1, #what do
                        local ch = what:sub(i, i)
                        local ok, val = pcall(_realDebugInfo, f, ch)
                        if ok and val ~= nil then
                            table.insert(results, val)
                        else
                            if ch == "f" then
                                table.insert(results, function() end)
                            elseif ch == "s" then
                                table.insert(results, "[C]")
                            elseif ch == "l" then
                                table.insert(results, -1)
                            elseif ch == "w" then
                                table.insert(results, "C")
                            elseif ch == "n" then
                                table.insert(results, "")
                            elseif ch == "u" then
                                table.insert(results, 0)
                            else
                                table.insert(results, nil)
                            end
                        end
                    end
                    return table.unpack(results)
                end
                local ok, val = pcall(_realDebugInfo, f, what or "fl")
                if ok then return val end
                return nil
            end
            return nil
        end,
        traceback = function(msg, level)
            if _realDebugTraceback then
                local ok, tb = pcall(_realDebugTraceback, msg, level)
                if ok then return tb end
            end
            return tostring(msg or "")
        end,
    }, {
        __index = function(_, k)
            if k == "getinfo" then
                return function(f, what)
                    what = what or "fl"
                    if type(f) == "function" then
                        local isC = knownCFunctions[f] or cclosureSet[f]
                        local source, whatKind, currentline, linedefined, lastlinedefined, name, nparams, isvararg, nups
                        if isC then
                            source = "[C]"
                            whatKind = "C"
                            currentline = -1
                            linedefined = -1
                            lastlinedefined = -1
                            name = ""
                            nparams = 0
                            isvararg = true
                            nups = 0
                            pcall(function()
                                local knownNames = {
                                    print = true, warn = true, error = true, assert = true,
                                    pcall = true, xpcall = true, select = true, tostring = true,
                                    tonumber = true, type = true, typeof = true, unpack = true,
                                    rawget = true, rawset = true, rawequal = true, rawlen = true,
                                    setmetatable = true, getmetatable = true, pairs = true,
                                    ipairs = true, next = true, getfenv = true, setfenv = true,
                                    require = true, loadstring = true, load = true,
                                    info = true, traceback = true, getinfo = true,
                                }
                                for n, _ in pairs(knownNames) do
                                    if env[n] and env[n] == f then name = n break end
                                    if env.debug and env.debug[n] and env.debug[n] == f then name = n break end
                                end
                            end)
                        else
                            local ok, src = pcall(_realDebugInfo, f, "s")
                            if ok then source = src else source = "[?]" end
                            local ok2, w2 = pcall(_realDebugInfo, f, "w")
                            if ok2 then whatKind = w2 else whatKind = "Lua" end
                            local ok3, ln = pcall(_realDebugInfo, f, "l")
                            if ok3 then currentline = ln else currentline = -1 end
                            local ok4, ld = pcall(_realDebugInfo, f, "l")
                            if ok4 then linedefined = ld else linedefined = -1 end
                            lastlinedefined = -1
                            local ok5, nm = pcall(_realDebugInfo, f, "n")
                            if ok5 then name = nm or "" else name = "" end
                            local ok6, np, iv = pcall(_realDebugInfo, f, "a")
                            if ok6 then nparams = np isvararg = iv else nparams = 0 isvararg = false end
                            local ok7, nupsV = pcall(_realDebugInfo, f, "u")
                            if ok7 and type(nupsV) == "number" then nups = nupsV else nups = 0 end
                        end
                        return {
                            source = source, short_src = source, what = whatKind,
                            currentline = currentline, linedefined = linedefined,
                            lastlinedefined = lastlinedefined, name = name,
                            nups = nups, nparams = nparams, is_vararg = isvararg, func = f,
                        }
                    end
                    if type(f) == "number" then
                        local info = {}
                        local function query(ch)
                            local ok, val = pcall(_realDebugInfo, f, ch)
                            return ok and val or nil
                        end
                        info.source = query("s") or "[C]"
                        info.short_src = info.source
                        info.what = query("w") or "C"
                        info.currentline = query("l") or -1
                        info.linedefined = query("l") or -1
                        info.lastlinedefined = -1
                        info.name = query("n") or ""
                        info.nups = query("u") or 0
                        info.nparams = 0
                        info.is_vararg = true
                        info.func = nil
                        return info
                    end
                    return nil
                end
            end
            if k == "getupvalue" then
                return function(f, i)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getupvalue'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to get upvalue of C closure", 2)
                    end
                    return nil
                end
            end
            if k == "setupvalue" then
                return function(f, i, v)
                    if type(f) ~= "function" then error("invalid argument #1 to 'setupvalue'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to set upvalue of C closure", 2)
                    end
                    return v
                end
            end
            if k == "getconstants" then
                return function(f)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getconstants'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to get constants of C closure", 2)
                    end
                    local edits = constantEdits[f]
                    local consts = {}
                    if edits then
                        for k, v in pairs(edits) do consts[k] = v end
                    end
                    pcall(function()
                        local ok, ret = pcall(f)
                        if ok and (type(ret) == "string" or type(ret) == "number" or type(ret) == "boolean") then
                            if not consts[1] then
                                table.insert(consts, ret)
                            end
                        end
                    end)
                    return consts
                end
            end
            if k == "setconstant" then
                return function(f, idx, val)
                    if type(f) ~= "function" then error("invalid argument #1 to 'setconstant'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to set constant of C closure", 2)
                    end
                    if type(idx) ~= "number" then error("invalid argument #2 to 'setconstant'", 2) end
                    if not constantEdits[f] then constantEdits[f] = {} end
                    constantEdits[f][idx] = val
                    return true
                end
            end
            if k == "getupvalues" then
                return function(f)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getupvalues'", 2) end
                    return {}
                end
            end
            if k == "setfenv" then
                return function(f, env) return f end
            end
            if k == "getfenv" then
                return function(level)
                    if type(level) == "number" and level > 100 then return nil end
                    return env
                end
            end
            return nil
        end,
        __newindex = function() error("attempt to write to read-only library table", 2) end,
    })
    env.io = nil
    local function wrapPcall(f, ...)
        local results = table.pack(pcall(f, ...))
        local ok = results[1]
        if not ok and type(results[2]) == "string" and results[2]:find("stack", 1, true) then
            results[2] = "stack overflow"
        end
        return table.unpack(results, 1, results.n)
    end
    env.pcall = function(f, ...) return wrapPcall(f, ...) end
    local _inErrorHandler = false
    env.xpcall = function(f, handler, ...)
        local results = table.pack(xpcall(
            function(...) _inErrorHandler = false return f(...) end,
            function(err)
                _inErrorHandler = true
                local ok, r = pcall(handler, err)
                _inErrorHandler = false
                if not ok then error(r, 0) end
                return r
            end,
            ...
        ))
        local ok = results[1]
        if not ok and type(results[2]) == "string" and results[2]:find("stack", 1, true) then
            results[2] = "stack overflow"
        end
        return table.unpack(results, 1, results.n)
    end
    env.error = error; env.assert = assert
    env.tonumber = tonumber; local tostringCounter = 0
    env.tostring = function(v)
        if type(v) == "table" then
            local m = getmetatable(v)
            if m and m._isProxy then
                local ctorName = rawget(v, "_ctorName") or m._ctorName
                if ctorName and (ctorName == "Vector3" or ctorName == "Vector2" or ctorName == "Color3" or ctorName == "UDim2" or ctorName == "CFrame") then
                    local args = rawget(v, "_ctorArgs") or m._ctorArgs or {}
                    if ctorName == "Vector3" then
                        return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. ", " .. tostring(args[3] or 0)
                    elseif ctorName == "Vector2" then
                        return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0)
                    elseif ctorName == "Color3" then
                        return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. ", " .. tostring(args[3] or 0)
                    elseif ctorName == "CFrame" then
                        return tostring(args[1] or 0) .. ", " .. tostring(args[2] or 0) .. ", " .. tostring(args[3] or 0)
                    end
                end
                local storedName = m._storedValues and m._storedValues["Name"]
                if storedName then return storedName end
                return m._className or m._name or "Instance"
            end
            if m and m._customAddr then return m._customAddr end
            tostringCounter += 1
            local addr = string.format("table: 0x%x", tostringCounter * 26544357612345 % 0x10000000000000000 + 0x100000000)
            if m then
                m._customAddr = addr
                return addr
            end
            return addr
        end
        if type(v) == "function" then
            if functionAddrMap[v] then return functionAddrMap[v] end
            tostringCounter += 1
            local id = tostringCounter
            local hi = (id * 2654435761) % 0x10000
            local lo = (id * 40503) % 0x100000000
            local addr = string.format("function: 0x%04x%012x", hi, lo)
            functionAddrMap[v] = addr
            return addr
        end
        if type(v) == "userdata" then
            local m = getmetatable(v)
            if m and m._customAddr then return m._customAddr end
            if m and m.__metatable ~= nil then return "userdata: " .. tostring(m.__metatable) end
            tostringCounter += 1
            local addr = string.format("userdata: 0x%x", tostringCounter * 26544357612345 % 0x10000000000000000 + 0x100000000)
            if m then
                m._customAddr = addr
                return addr
            end
            return addr
        end
        return tostring(v)
    end; env.type = type; env.select = select
    env.unpack = table.unpack; env.rawget = rawget; env.rawset = function(t, k, v)
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            error("attempt to modify a readonly table", 2)
        end
        return rawset(t, k, v)
    end; env.rawequal = rawequal
    env.rawlen = rawlen; env.setmetatable = function(t, mt)
        if type(t) == "table" then
            local m = getmetatable(t)
            if m and m._isProxy then
                error("cannot set metatable of Instance", 2)
            end
        end
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            error("attempt to modify a readonly table", 2)
        end
        local prevMt = getmetatable(t)
        if type(mt) == "table" and prevMt and prevMt._isReadonlyGuard and prevMt._isReadonlyLocked then
            local snapshot = prevMt.__index
            if type(snapshot) == "table" then
                for k, v in pairs(snapshot) do mt[k] = v end
            end
            local userNewindex = mt.__newindex
            mt.__newindex = function(tt, k, v)
                if readonlyTables[t] or frozenTables[t] then
                    error("attempt to modify a readonly table", 2)
                end
                if type(userNewindex) == "function" then
                    userNewindex(tt, k, v)
                else
                    rawset(tt, k, v)
                end
            end
            mt._isReadonlyGuard = true
        end
        return realSetmetatable(t, mt)
    end; env.getmetatable = function(t)
        if type(t) == "string" then return nil end
        local raw_mt = getmetatable(t)
        if raw_mt and raw_mt.__metatable == false then return nil end
        if type(t) == "table" then
            if t == env then return nil end
        end
        local m = raw_mt
        if m and m._isReadonlyGuard and m._isReadonlyLocked then
            local snapshot = m.__index
            if type(snapshot) == "table" then return snapshot end
            return nil
        end
        if m and m._isReadonlyGuard and m._isFrozen then
            local snapshot = m.__index
            if type(snapshot) == "table" then return snapshot end
            return nil
        end
        if m and m._isReadonlyGuard and m._originalMt then return m._originalMt end
        if m and m.__metatable ~= nil then return m.__metatable end
        if m and m._isProxy then
            local cls = m._className or ""
            if cls == "DataModel" or cls == "Workspace" or cls == "Instance" then
                return "The metatable is locked"
            end
        end
        if m and m._isReadonlyGuard then
            return nil
        end
        return m
    end
    env.ipairs = function(t, ...)
        if type(t) == "table" then
            local m = getmetatable(t)
            if m and m._isProxy then
                return function() return nil end, nil, 0
            end
        end
        return ipairs(t, ...)
    end; env.pairs = pairs; env.next = next; env._VERSION = "Luau"
    env.utf8 = setmetatable({
        char = utf8.char,
        codepoint = utf8.codepoint,
        codes = utf8.codes,
        len = utf8.len,
        offset = utf8.offset,
        nfcnormalize = utf8.nfcnormalize,
        nfdnormalize = utf8.nfdnormalize,
        charpattern = utf8.charpattern,
        graphemes = function(s)
            local i = 1
            local len = #s
            return function()
                if i > len then return nil end
                local start = i
                i += 1
                return start, i - 1
            end
        end,
    }, {
        __index = function(_, k) return function() return nil end end,
        __newindex = function() error("attempt to write to read-only library table", 2) end
    }); env.bit32 = copyLib(bit32); env.bit = env.bit32
    env.typeof = function(x)
        local t = type(x)
        if t == "table" then
            local m = getmetatable(x)
            if m and m._isProxy then
                local ctorName = rawget(x, "_ctorName") or m._ctorName
                if ctorName then return ctorName end
                local fieldName = m._fieldName
                local parent = m._parent
                local parentMt = parent and getmetatable(parent) or nil
                if fieldName and parentMt and parentMt._className then
                    local runtimeTypeName = getPropertyRuntimeType(parentMt._className, fieldName)
                    if runtimeTypeName then
                        return runtimeTypeName
                    end
                end
                if m._signalForEvent or m._signalForProperty then
                    return "RBXScriptSignal"
                end
                local cls = m._className
                if cls == "RBXScriptSignal" then return "RBXScriptSignal" end
                if cls == "RBXScriptConnection" then return cls end
                if cls == "DateTime" then return "DateTime" end
                if cls == "EnumItem" then return "EnumItem" end
                if cls == "Enum" then return "Enum" end
                if cls == "Secret" then return "Secret" end
                if cls == "PlayerMouse" then return "PlayerMouse" end
                if cls == "Random" then return "Random" end
                if cls == "SharedTable" then return "SharedTable" end
                if cls == "Path" then return "Path" end
                if cls == "HumanoidDescription" then return "HumanoidDescription" end
                return "Instance"
            end
            if m and m._isEnumType then return "Enum" end
        end
        return t
    end
    env.type = function(x)
        local t = type(x)
        if t == "table" then
            local m = getmetatable(x)
            if m and m._isProxy then
                local parent = m._parent
                local parentMt = parent and getmetatable(parent) or nil
                local memberInfo = nil
                if m._fieldName and parentMt and parentMt._className then
                    memberInfo = resolveApiMember(parentMt._className, m._fieldName)
                end
                if isCallableMember(memberInfo) then
                    return "function"
                end
                return "userdata"
            end
            if m and (m._isEnumType or m._enumName) then
                return "userdata"
            end
        end
        if x == env.Enum or x == env.Enums then
            return "userdata"
        end
        return t
    end
    env.print = function(...)
        local a={...}
        local p={}
        for i=1,select("#",...) do p[i]=serialize(a[i]) end
        emit("print(" .. table.concat(p, ", ") .. ")")
        return "nil"
    end
    env.warn = function(...)
        local a={...}
        local p={}
        for i=1,select("#",...) do p[i]=serialize(a[i]) end
        emit("warn(" .. table.concat(p, ", ") .. ")")
        return "nil"
    end
    env.setfenv = function(f, env)
        return f
    end
    env.ypcall = env.pcall
    env.settings = function()
        local s = makeProxy("GlobalSettings")
        local mt = getmetatable(s)
        mt._className = "GlobalSettings"
        mt._storedValues["ClassName"] = "GlobalSettings"
        mt._setKeys["ClassName"] = true
        return s
    end
    env.GetMemory = function() return 0 end
    env.GetGPUStats = function() return {} end
    env.GetPlatform = function() return "Windows" end
    env.getfenv = function(level)
        if type(level) == "number" then
            if level < 0 then
                error("invalid argument #1 to 'getfenv' (level out of range)", 2)
            end
            if level > 8 then
                error("invalid argument #1 to 'getfenv' (level out of range)", 2)
            end
        end
        if level == nil then return env end
        if type(level) == "function" then return env end
        return env
    end
    env.version = function() return "0.728.0.7280895" end
    env._VERSION = "Luau"
    local _vmInsnCount = 0
    local _vmInsnBudget = 1000000000
    env._VMC = function()
        _vmInsnCount += 1
        if _vmInsnCount > _vmInsnBudget then
            return true
        end
        return false
    end
    env.loadstring = function(src, chunkname)
        if type(src) ~= "string" then return nil, "invalid argument #1 to 'loadstring'" end
        if src:find('require%("@lune') or src:find("require%('@lune") or src:find('require%("lfs') or src:find("require%('lfs") then
            return nil, "blocked: lune/lfs require"
        end
        if #src > 5000 and src:sub(1, 5) == "local" then
            src = src:gsub("repeat ", "repeat if _VMC() then error('VM_BUDGET') end ")
            src = src:gsub("while true do", "while true do if _VMC() then error('VM_BUDGET') end ")
        end
        local ok, compiled = pcall(luau.compile, src, { optimizationLevel = 1 })
        if not ok then
            return nil, tostring(compiled)
        end
        local loadOk, fn = pcall(luau.load, compiled, { debugName = chunkname or "loadstring", environment = env })
        if not loadOk or type(fn) ~= "function" then
            return nil, tostring(fn)
        end
        return fn
    end
    env.load = function(src, chunkname, mode, envArg)
        if type(src) == "string" then
            local ok, compiled = pcall(luau.compile, src, { optimizationLevel = 1 })
            if not ok then return nil, tostring(compiled) end
            local loadOk, fn = pcall(luau.load, compiled, { debugName = chunkname or "load", environment = envArg or env })
            if not loadOk or type(fn) ~= "function" then return nil, tostring(fn) end
            return fn
        elseif type(src) == "function" then
            local chunks = {}
            while true do
                local chunk = src()
                if not chunk then break end
                table.insert(chunks, chunk)
            end
            local full = table.concat(chunks)
            return env.loadstring(full, chunkname, mode, envArg)
        end
        return nil, "invalid argument #1 to 'load'"
    end

    env.game = spyInstance("DataModel", "game", true)
    env.Game = env.game
    local gameMt = getmetatable(env.game)
    gameMt._storedValues["PlaceId"] = math.random(100000000, 2147483646)
    gameMt._setKeys["PlaceId"] = true
    local function randHex(n) local s = "" for _=1,n do s = s .. string.format("%x", math.random(0, 15)) end return s end
    gameMt._storedValues["JobId"] = randHex(8) .. "-" .. randHex(4) .. "-" .. randHex(4) .. "-" .. randHex(4) .. "-" .. randHex(12)
    gameMt._setKeys["JobId"] = true
    gameMt._storedValues["GameId"] = math.random(100000000, 2147483646)
    gameMt._setKeys["GameId"] = true
    gameMt._storedValues["CreatorId"] = math.random(1, 999999)
    gameMt._setKeys["CreatorId"] = true
    env.workspace = spyInstance("Workspace", "workspace", true)
    env.Workspace = env.workspace
    workspaceProxy = env.workspace
    local wsMt = getmetatable(env.workspace)
    wsMt._storedValues["Parent"] = env.game
    wsMt._setKeys["Parent"] = true
    local baseplate = makeProxy("Baseplate")
    local bpMt = getmetatable(baseplate)
    bpMt._className = "Part"
    bpMt._storedValues["Name"] = "Baseplate"
    bpMt._setKeys["Name"] = true
    bpMt._storedValues["ClassName"] = "Part"
    bpMt._setKeys["ClassName"] = true
    bpMt._storedValues["Parent"] = env.workspace
    bpMt._setKeys["Parent"] = true
    if not parentChildMap["workspace"] then parentChildMap["workspace"] = {} end
    parentChildMap["workspace"]["Baseplate"] = baseplate
    local terrain = makeProxy("Terrain")
    local terrainMt = getmetatable(terrain)
    terrainMt._className = "Terrain"
    terrainMt._storedValues["ClassName"] = "Terrain"
    terrainMt._setKeys["ClassName"] = true
    terrainMt._storedValues["Parent"] = env.workspace
    terrainMt._setKeys["Parent"] = true
    parentChildMap["workspace"]["Terrain"] = terrain
    env.script = spyInstance("LocalScript", "script", true)

    env.Instance = setmetatable({
        new = function(c)
            local cls = tostring(c or "Instance")
            if not getApiClassInfo(cls) then
                error("Instance.new: invalid class '" .. cls .. "'", 2)
            end
            if not isApiCreatableClass(cls) then
                error("Instance.new: cannot create class '" .. cls .. "'", 2)
            end
            local v = genVar("inst")
            emit(string.format('local %s = Instance.new("%s")', v, cls))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = cls
            mt._storedValues["ClassName"] = cls
            mt._setKeys["ClassName"] = true
            mt._storedValues["Name"] = cls
            mt._setKeys["Name"] = true
            applyClassDefaults(proxy, cls)
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Instance." .. tostring(k)) end })
    local enumTypeCache: { [string]: any } = {}
    local function getOrCreateEnumType(enumName)
        if enumTypeCache[enumName] then return enumTypeCache[enumName] end
        local enumType = setmetatable({
            GetEnumItems = function()
                local items = {}
                if enumsData and enumsData[enumName] then
                    for itemName, itemVal in pairs(enumsData[enumName]) do
                        local item = makeProxy("Enum." .. enumName .. "." .. itemName)
                        local itemMt = getmetatable(item)
                        itemMt._className = "EnumItem"
                        itemMt._ctorName = "EnumItem"
                        itemMt._storedValues["Name"] = itemName
                        itemMt._setKeys["Name"] = true
                        itemMt._storedValues["Value"] = itemVal
                        itemMt._setKeys["Value"] = true
                        itemMt._storedValues["EnumType"] = enumTypeCache[enumName] or enumType
                        itemMt._setKeys["EnumType"] = true
                        itemMt._storedValues["Parent"] = enumTypeCache[enumName] or enumType
                        itemMt._setKeys["Parent"] = true
                        table.insert(items, item)
                    end
                end
                return items
            end,
            GetByValue = function() return nil end,
        }, {
            __index = function(_, k2)
                local item = makeProxy("Enum." .. enumName .. "." .. tostring(k2))
                local itemMt = getmetatable(item)
                itemMt._className = "EnumItem"
                itemMt._ctorName = "EnumItem"
                itemMt._storedValues["Name"] = tostring(k2)
                itemMt._setKeys["Name"] = true
                local val = 0
                if enumsData and enumsData[enumName] and enumsData[enumName][tostring(k2)] ~= nil then
                    val = enumsData[enumName][tostring(k2)]
                end
                itemMt._storedValues["Value"] = val
                itemMt._setKeys["Value"] = true
                local et = enumTypeCache[enumName] or enumType
                itemMt._storedValues["EnumType"] = et
                itemMt._setKeys["EnumType"] = true
                itemMt._storedValues["Parent"] = et
                itemMt._setKeys["Parent"] = true
                return item
            end
        })
        local etMt = getmetatable(enumType)
        etMt._isEnumType = true
        etMt._enumName = enumName
        enumTypeCache[enumName] = enumType
        return enumType
    end
    env.Enum = setmetatable({
        GetEnumItems = function() return {} end,
        GetEnums = function()
            local result = {}
            if enumsData then
                for name, _ in pairs(enumsData) do
                    table.insert(result, getOrCreateEnumType(name))
                end
            end
            return result
        end,
    }, {
        __index = function(_, k)
            return getOrCreateEnumType(tostring(k))
        end
    })
    env.Enums = env.Enum

    local DATA_TYPES = { Vector3 = true, Vector2 = true, UDim2 = true, UDim = true, CFrame = true }
    local function newCtor(name)
        local extraCtors
        if name == "UDim2" then
            extraCtors = {
                fromScale = function(xScale, yScale)
                    local v = genVar("udim2")
                    emit(string.format('local %s = UDim2.fromScale(%s, %s)', v, serialize(xScale), serialize(yScale)))
                    return makeDataProxy("UDim2", { xScale or 0, 0, yScale or 0, 0 }, v)
                end,
                fromOffset = function(xOffset, yOffset)
                    local v = genVar("udim2")
                    emit(string.format('local %s = UDim2.fromOffset(%s, %s)', v, serialize(xOffset), serialize(yOffset)))
                    return makeDataProxy("UDim2", { 0, xOffset or 0, 0, yOffset or 0 }, v)
                end,
            }
        end
        local ctorTable = { new = function(...)
            local v = genVar(name:lower())
            local parts = {}
            local args = {...}
            for i = 1, select("#", ...) do table.insert(parts, serialize(args[i])) end
            if name == "NumberRange" and #args == 2 and type(args[1]) == "number" and type(args[2]) == "number" then
                if args[1] > args[2] then
                    error("NumberRange: min must be <= max", 0)
                end
            end
            emit(string.format('local %s = %s.new(%s)', v, name, table.concat(parts, ", ")))
            if DATA_TYPES[name] then
                return makeDataProxy(name, {...}, v)
            end
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorArgs = {...}
            mt._ctorName = name
            return proxy
        end }
        if extraCtors then
            for k, fn in pairs(extraCtors) do
                ctorTable[k] = fn
            end
        end
        return setmetatable(ctorTable, { __index = function(_, k)
            local constants = {
                Vector3 = {
                    zero = {0, 0, 0}, one = {1, 1, 1},
                    xAxis = {1, 0, 0}, yAxis = {0, 1, 0}, zAxis = {0, 0, 1},
                },
                Vector2 = {
                    zero = {0, 0}, one = {1, 1},
                },
                UDim2 = {
                    zero = {0, 0, 0, 0}, one = {1, 1, 1, 1},
                },
            }
            local c = constants[name]
            if c and c[k] then
                if DATA_TYPES[name] then
                    return makeDataProxy(name, c[k], name .. "." .. k)
                end
                local p = makeProxy(name .. "." .. k)
                local mt = getmetatable(p)
                mt._ctorArgs = c[k]
                mt._ctorName = name
                return p
            end
            return makeProxy(name .. "." .. tostring(k))
        end })
    end
    env.Vector3 = newCtor("Vector3")
    env.Vector2 = newCtor("Vector2")
    env.CFrame = setmetatable({
        new = function(...)
            local v = genVar("cframe")
            local args = {...}
            local parts = {}
            for i = 1, select("#", ...) do table.insert(parts, serialize(args[i])) end
            emit(string.format('local %s = CFrame.new(%s)', v, table.concat(parts, ", ")))
            return makeDataProxy("CFrame", {...}, v)
        end,
        Angles = function(rx, ry, rz)
            local v = genVar("cframe")
            emit(string.format('local %s = CFrame.Angles(%s, %s, %s)', v, serialize(rx), serialize(ry), serialize(rz)))
            return makeDataProxy("CFrame", {0, 0, 0}, v)
        end,
        fromMatrix = function(pos, rvec, uvec, bvec)
            local v = genVar("cframe")
            local parts = {}
            for _, a in ipairs({pos, rvec, uvec, bvec}) do
                if a then table.insert(parts, serialize(a)) end
            end
            emit(string.format('local %s = CFrame.fromMatrix(%s)', v, table.concat(parts, ", ")))
            return makeDataProxy("CFrame", {0, 0, 0}, v)
        end,
        fromEulerAnglesXYZ = function(rx, ry, rz)
            local v = genVar("cframe")
            emit(string.format('local %s = CFrame.fromEulerAnglesXYZ(%s, %s, %s)', v, serialize(rx), serialize(ry), serialize(rz)))
            return makeDataProxy("CFrame", {0, 0, 0}, v)
        end,
        fromAxisAngle = function(v3, angle)
            local v = genVar("cframe")
            emit(string.format('local %s = CFrame.fromAxisAngle(%s, %s)', v, serialize(v3), serialize(angle)))
            return makeDataProxy("CFrame", {0, 0, 0}, v)
        end,
    }, {
        __index = function(_, k)
            local constants = {
                identity = {0, 0, 0},
            }
            if constants[k] then
                return makeDataProxy("CFrame", constants[k], "CFrame." .. k)
            end
            return makeProxy("CFrame." .. tostring(k))
        end,
    })
    env.UDim2 = newCtor("UDim2")
    env.UDim = newCtor("UDim")
    local function argsToList(...)
        local args = {...}
        local parts = {}
        for i = 1, select("#", ...) do
            table.insert(parts, serialize(args[i]))
        end
        return table.concat(parts, ", ")
    end
    local function colorCtor(ctorName)
        return function(...)
            local v = genVar("color")
            local args = {...}
            emit(string.format('local %s = Color3.%s(%s)', v, ctorName, argsToList(...)))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorName = "Color3"
            mt._ctorArgs = args
            if ctorName == "fromRGB" then
                mt._ctorArgs = { (args[1] or 0)/255, (args[2] or 0)/255, (args[3] or 0)/255 }
            elseif ctorName == "fromHSV" then
                local h, s, val = args[1] or 0, args[2] or 0, args[3] or 0
                local r, g, b
                local i = math.floor(h * 6)
                local f = h * 6 - i
                local p = val * (1 - s)
                local q = val * (1 - f * s)
                local t = val * (1 - (1 - f) * s)
                i = i % 6
                if i == 0 then r, g, b = val, t, p
                elseif i == 1 then r, g, b = q, val, p
                elseif i == 2 then r, g, b = p, val, t
                elseif i == 3 then r, g, b = p, q, val
                elseif i == 4 then r, g, b = t, p, val
                elseif i == 5 then r, g, b = val, p, q
                end
                mt._ctorArgs = { r or 0, g or 0, b or 0 }
            end
            return proxy
        end
    end
    env.Color3 = setmetatable({
        new = colorCtor("new"),
        fromRGB = colorCtor("fromRGB"),
        fromHSV = colorCtor("fromHSV"),
        fromHex = function(hex)
            hex = tostring(hex):gsub("#", "")
            local r = tonumber(hex:sub(1, 2), 16) or 0
            local g = tonumber(hex:sub(3, 4), 16) or 0
            local b = tonumber(hex:sub(5, 6), 16) or 0
            local v = genVar("color")
            emit(string.format('local %s = Color3.fromHex("%s")', v, hex))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorName = "Color3"
            mt._ctorArgs = { r/255, g/255, b/255 }
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Color3." .. tostring(k)) end })
    env.Rect = newCtor("Rect")
    env.Ray = newCtor("Ray")
    env.Region3 = newCtor("Region3")
    env.Region3int16 = newCtor("Region3int16")
    env.Random = setmetatable({
        new = function(seed)
            local v = genVar("random")
            emit(string.format('local %s = Random.new(%s)', v, serialize(seed)))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = "Random"
            mt._storedValues["ClassName"] = "Random"
            mt._setKeys["ClassName"] = true
            mt._seed = seed or 0
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Random." .. tostring(k)) end })
    env.Axes = newCtor("Axes")
    env.Faces = newCtor("Faces")
    env.PathWaypoint = newCtor("PathWaypoint")
    env.FloatCurveKey = newCtor("FloatCurveKey")
    env.RotationCurveKey = newCtor("RotationCurveKey")
    env.ValueCurveKey = newCtor("ValueCurveKey")
    env.SecurityCapabilities = setmetatable({
        new = function(...) return makeProxy("SecurityCapabilities") end,
        fromCurrent = function()
            local v = genVar("seccaps")
            emit(string.format('local %s = SecurityCapabilities.fromCurrent()', v))
            return makeProxy(v)
        end,
    }, { __index = function(_, k) return makeProxy("SecurityCapabilities." .. tostring(k)) end })
    env.Vector2int16 = newCtor("Vector2int16")
    env.Vector3int16 = newCtor("Vector3int16")
    env.CatalogSearchParams = newCtor("CatalogSearchParams")
    env.SharedTable = setmetatable({
        new = function()
            local v = genVar("sharedtable")
            emit(string.format('local %s = SharedTable.new()', v))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = "SharedTable"
            mt._storedValues["ClassName"] = "SharedTable"
            mt._setKeys["ClassName"] = true
            mt._sharedData = {}
            return proxy
        end,
        increment = function(st, key, amount)
            local stMt = getmetatable(st)
            if stMt and stMt._sharedData then
                stMt._sharedData[key] = (stMt._sharedData[key] or 0) + (amount or 1)
                rawset(st, key, stMt._sharedData[key])
            end
            emit(string.format('SharedTable.increment(%s, %s, %s)', proxyName(st), serialize(key), serialize(amount)))
        end,
        size = function(st) return 0 end,
        clone = function(st) return st end,
        isFrozen = function(st) return false end,
    }, { __index = function(_, k) return makeProxy("SharedTable." .. tostring(k)) end })
    env.PhysicalProperties = newCtor("PhysicalProperties")
    env.Font = newCtor("Font")
    env.TweenInfo = newCtor("TweenInfo")
    env.NumberRange = newCtor("NumberRange")
    env.NumberSequence = newCtor("NumberSequence")
    env.NumberSequenceKeypoint = newCtor("NumberSequenceKeypoint")
    env.ColorSequence = newCtor("ColorSequence")
    env.ColorSequenceKeypoint = newCtor("ColorSequenceKeypoint")
    env.BrickColor = newCtor("BrickColor")
    env.OverlapParams = newCtor("OverlapParams")
    env.RaycastParams = newCtor("RaycastParams")
    env.DateTime = setmetatable({
        now = function()
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._setKeys["UnixTimestamp"] = true
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            mt._setKeys["UnixTimestampMillis"] = true
            return dt
        end,
        fromUnixTimestamp = function(ts)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = ts
            mt._storedValues["UnixTimestampMillis"] = ts * 1000
            return dt
        end,
        fromUniversalTime = function(...)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            return dt
        end,
        fromLocalTime = function(...)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            return dt
        end,
    }, { __index = function(_, k)
        if k == "now" then
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._setKeys["UnixTimestamp"] = true
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            mt._setKeys["UnixTimestampMillis"] = true
            return dt
        end
        return makeProxy("DateTime." .. tostring(k))
    end, __call = function()
        local dt = makeProxy("DateTime")
        local mt = getmetatable(dt)
        mt._className = "DateTime"
        mt._storedValues["UnixTimestamp"] = os.time()
        mt._setKeys["UnixTimestamp"] = true
        mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
        mt._setKeys["UnixTimestampMillis"] = true
        return dt
    end })
    env.NumberRange = newCtor("NumberRange")
    env.NumberSequence = newCtor("NumberSequence")
    env.NumberSequenceKeypoint = newCtor("NumberSequenceKeypoint")
    env.ColorSequence = newCtor("ColorSequence")
    env.ColorSequenceKeypoint = newCtor("ColorSequenceKeypoint")
    env.PhysicalProperties = newCtor("PhysicalProperties")
    env.TweenInfo = newCtor("TweenInfo")
    env.RaycastParams = newCtor("RaycastParams")
    env.OverlapParams = newCtor("OverlapParams")
    env.PathWaypoint = newCtor("PathWaypoint")
    env.Font = setmetatable({}, { __index = function(_, k) return makeProxy("Font." .. tostring(k)) end })
    env.buffer = setmetatable({
        create = function(n)
            if type(n) ~= "number" then n = 0 end
            if n < 0 then n = 0 end
            if n > 100000000 then n = 100000000 end
            return buffer.create(math.floor(n))
        end,
        fromstring = function(s)
            s = s or ""
            return buffer.fromstring(s)
        end,
        tostring = function(b)
            if type(b) == "string" then return b end
            local ok, r = pcall(buffer.tostring, b)
            if ok then return r end
            return ""
        end,
        len = function(b)
            if type(b) == "string" then return #b end
            local ok, r = pcall(buffer.len, b)
            if ok then return r end
            return 0
        end,
        copy = function(...) return buffer.copy(...) end,
        fill = function(...) return buffer.fill(...) end,
        tobits = function(b) return buffer.tobits(b) end,
        frombits = function(...) return buffer.frombits(...) end,
        readi8 = function(...) return buffer.readi8(...) end,
        readu8 = function(...) return buffer.readu8(...) end,
        readi16 = function(...) return buffer.readi16(...) end,
        readu16 = function(...) return buffer.readu16(...) end,
        readi32 = function(...) return buffer.readi32(...) end,
        readu32 = function(...) return buffer.readu32(...) end,
        readf32 = function(...) return buffer.readf32(...) end,
        readf64 = function(...) return buffer.readf64(...) end,
        writei8 = function(...) return buffer.writei8(...) end,
        writeu8 = function(...) return buffer.writeu8(...) end,
        writei16 = function(...) return buffer.writei16(...) end,
        writeu16 = function(...) return buffer.writeu16(...) end,
        writei32 = function(...) return buffer.writei32(...) end,
        writeu32 = function(...) return buffer.writeu32(...) end,
        writef32 = function(...) return buffer.writef32(...) end,
        writef64 = function(...) return buffer.writef64(...) end,
        readstring = function(...) return buffer.readstring(...) end,
        writestring = function(...) return buffer.writestring(...) end,
    }, {
        _serialName = "buffer",
        __index = function(_, k)
            if type(k) == "string" and buffer[k] then
                return buffer[k]
            end
            return function() return 0 end
        end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
    })
    env.Buffer = env.buffer

    local YIELD_BUDGET = 1000
    local yieldCount = 0
    local function yieldTick()
        yieldCount += 1
        if yieldCount > YIELD_BUDGET then
            error(BUDGET_ERROR, 0)
        end
    end
    _G._yieldTick = yieldTick
    local function runCallback(f, ...)
        if type(f) ~= "function" then return end
        local savedYieldCount = yieldCount
        yieldCount = 0
        local ok, err = pcall(f, ...)
        yieldCount = savedYieldCount
        if not ok and tostring(err):find(BUDGET_ERROR, 1, true) then
        end
    end
    local realClock = os.clock
    local realTaskWait = task.wait
    local realTaskSpawn = task.spawn
    local realTaskDelay = task.delay
    local realTaskCreate = task.create
    local realTaskCancel = task.cancel
    local realTaskClock = task.clock
    local realTaskDefer = task.defer
    local physicsParts = setmetatable({}, { __mode = "k" })
    _G._physicsParts = physicsParts
    local function simulatePhysics(dt)
        for part, _ in pairs(physicsParts) do
            if part and isProxy(part) then
                local mt = getmetatable(part)
                if mt and mt._className and mt._className ~= "DataModel" and mt._className ~= "Workspace" then
                    if mt._storedValues["Anchored"] == false and mt._storedValues["Parent"] ~= nil then
                        local pos = mt._storedValues["Position"]
                        if pos and type(pos) == "table" then
                            local posArgs = rawget(pos, "_ctorArgs")
                            local posMt = getmetatable(pos)
                            if posArgs and posMt and posMt._isProxy then
                                local x, y, z = posArgs[1] or 0, posArgs[2] or 0, posArgs[3] or 0
                                local vel = mt._storedValues["AssemblyLinearVelocity"]
                                local vx, vy, vz = 0, 0, 0
                                if vel and type(vel) == "table" then
                                    local velArgs = rawget(vel, "_ctorArgs")
                                    if velArgs then
                                        vx = velArgs[1] or 0
                                        vy = velArgs[2] or 0
                                        vz = velArgs[3] or 0
                                    end
                                end
                                local gravity = 196.2
                                local newY = y + vy * dt - 0.5 * gravity * dt * dt
                                local slideAccel = 10.0
                                local newX = x + vx * dt + 0.5 * slideAccel * dt * dt
                                local newZ = z + vz * dt
                                if newY < -500 then newY = -500 end
                                rawset(pos, "_ctorArgs", { newX, newY, newZ })
                            end
                        end
                    end
                end
            end
        end
    end

    local taskTbl = {
        wait = function(time)
            yieldTick(); tick()
            local t = tonumber(time) or 0.015
            local actualT = realTaskWait(t)
            simulatePhysics(t)
            return t, 1
        end,
        spawn = function(f, ...)
            tick()
            local args = table.pack(...)
            local co = coroutine.create(function() runCallback(f, table.unpack(args, 1, args.n)) end)
            coroutine.resume(co)
            return co
        end,
        delay = function(t, f)
            tick()
            local co = coroutine.create(function() runCallback(f) end)
            return co
        end,
        cancel = function(co) end,
        clock = function() return os.clock() end,
        defer = function(f, ...)
            tick()
            local args = table.pack(...)
            local co = coroutine.create(function() runCallback(f, table.unpack(args, 1, args.n)) end)
            return co
        end,
        synchronize = function() end,
        desynchronize = function() end,
    }
    env.task = setmetatable(taskTbl, {
        __newindex = function() error("attempt to write to read-only library table", 2) end
    })
    env.wait = function(time) yieldTick(); return time or 0.015 end
    env.spawn = env.task.spawn
    env.delay = env.task.delay
    env.tick = function() return os.time() end
    env.time = function() return os.time() end
    env.elapsedTime = function() return os.clock() end
    env.elapsedtime = env.elapsedTime
    env.stats = function() return {} end
    env.hookfunction = function(target, replacement)
        if type(target) ~= "function" then error("invalid argument #1 to 'hookfunction'", 2) end
        if type(replacement) ~= "function" then error("invalid argument #2 to 'hookfunction'", 2) end
        local prevReplacement = hookReplacements[target]
        local prevOriginal = originalBehaviors[target]
        local original = prevOriginal or target
        hookTargets[target] = true
        hookReplacements[target] = replacement
        originalBehaviors[target] = original
        local wrappedOriginal = function(...)
            if hookReplacements[target] then
                return hookReplacements[target](...)
            end
            return original(...)
        end
        local toReturn = prevReplacement or wrappedOriginal
        if not prevReplacement then
            cclosureSet[toReturn] = true
        end
        local mt = getmetatable(target)
        if mt and mt._isProxy then
            mt._hooked = true
            mt._hookReplacement = replacement
        end
        return toReturn
    end
    knownCFunctions[env.hookfunction] = true
    env.checkcaller = function() return true end
    env.getrawmetatable = function(t) return getmetatable(t) end
    env.identifyexecutor = function() return "envlog", "1.0" end
    env.http_request = function(opts)
        if type(opts) ~= "table" then
            error("invalid argument #1 to 'request' (table expected)", 2)
        end
        local url = opts.Url or opts.url
        if type(url) ~= "string" then
            error("request: Url is required", 2)
        end
        local method = opts.Method or opts.method or "GET"
        local headers = opts.Headers or opts.headers or {}
        local body = opts.Body or opts.body
        local netOpts = { method = method, headers = headers }
        if body ~= nil then netOpts.body = body end
        local ok, res = pcall(net.request, url, netOpts)
        if not ok or not res then
            return { StatusCode = 0, Body = "", Success = false, Headers = {} }
        end
        local statusCode = res.statusCode or 0
        return {
            StatusCode = statusCode,
            Body = res.body or "",
            Success = statusCode >= 200 and statusCode < 400,
            Headers = res.headers or {},
        }
    end
    env.request = env.http_request
    env.setclipboard = function() end
    env.readfile = function() return "" end
    env.writefile = function() end
    env.isfile = function() return false end
    env.newcclosure = function(f)
        if type(f) ~= "function" then error("invalid argument #1 to 'newcclosure'", 2) end
        local wrapper = function(...)
            return f(...)
        end
        cclosureSet[wrapper] = true
        cloneSources[wrapper] = f
        return wrapper
    end
    env.iscclosure = function(f)
        if type(f) ~= "function" then return false end
        if cclosureSet[f] then return true end
        if knownCFunctions[f] then return true end
        local dw = getFunctionWhat(f)
        if dw == "C" then return true end
        return false
    end
    env.islclosure = function(f)
        if type(f) ~= "function" then return false end
        if cclosureSet[f] then return false end
        if knownCFunctions[f] then return false end
        local dw = getFunctionWhat(f)
        if dw == "C" then return false end
        return true
    end
    env.getgenv = function() return env end
    env.getrenv = function() return setmetatable({}, { __index = env }) end
    local _huiProxy = makeProxy("CoreGui")
    do
        local hmt = getmetatable(_huiProxy)
        hmt._className = "CoreGui"
        hmt._storedValues["ClassName"] = "CoreGui"
        hmt._setKeys["ClassName"] = true
        hmt._storedValues["Name"] = "CoreGui"
        hmt._setKeys["Name"] = true
    end
    env.gethui = function() return _huiProxy end
    env.gethwid = function() return "sandbox-hwid-12345" end
    env.getcustomasset = function() return "rbxasset://temp" end
    env.getinstances = function() return {} end
    env.getnilinstances = function() return {} end
    env.getscripts = function() return {} end
    env.getloadedmodules = function() return {} end
    local runningScriptsList = { "Animate", "HealthScript", "SoundPlus", "RbxCharacter", "ControlScript", "CameraScript" }
    env.getrunningscripts = function()
        local result = {}
        for _, name in ipairs(runningScriptsList) do
            local proxy = makeProxy(name)
            local mt = getmetatable(proxy)
            mt._isRunningScript = true
            table.insert(result, proxy)
        end
        return result
    end
    env.getcallbackvalue = function(obj, prop)
        if not isProxy(obj) then return nil end
        local mt = getmetatable(obj)
        if mt and mt._storedValues and mt._storedValues[prop] then
            return mt._storedValues[prop]
        end
        local memberInfo = resolveApiMember(mt._className or "", prop)
        if memberInfo and memberInfo.memberType == "Callback" then
            return mt._storedValues[prop] or function() end
        end
        return nil
    end
    env.isluau = function() return true end
    env.isourclosure = function() return false end
    env.isexecutorclosure = function() return false end
    knownCFunctions[env.print] = true
    knownCFunctions[env.warn] = true
    knownCFunctions[env.pcall] = true
    knownCFunctions[env.xpcall] = true
    knownCFunctions[env.error] = true
    knownCFunctions[env.assert] = true
    knownCFunctions[env.tonumber] = true
    knownCFunctions[env.tostring] = true
    knownCFunctions[env.type] = true
    knownCFunctions[env.typeof] = true
    knownCFunctions[env.select] = true
    knownCFunctions[env.pairs] = true
    knownCFunctions[env.ipairs] = true
    knownCFunctions[env.next] = true
    knownCFunctions[env.rawget] = true
    knownCFunctions[env.rawset] = true
    knownCFunctions[env.rawequal] = true
    knownCFunctions[env.rawlen] = true
    knownCFunctions[env.setmetatable] = true
    knownCFunctions[env.getmetatable] = true
    knownCFunctions[env.unpack] = true
    knownCFunctions[env.getfenv] = true
    knownCFunctions[env.setfenv] = true
    knownCFunctions[env.loadstring] = true
    knownCFunctions[env.load] = true
    knownCFunctions[env.debug.info] = true
    knownCFunctions[env.debug.traceback] = true
    knownCFunctions[env.debug.getinfo] = true
    knownCFunctions[env.ypcall] = true
    knownCFunctions[env.settings] = true
    knownCFunctions[env.wait] = true
    knownCFunctions[env.spawn] = true
    knownCFunctions[env.delay] = true
    knownCFunctions[env.tick] = true
    knownCFunctions[env.time] = true
    knownCFunctions[env.elapsedTime] = true
    knownCFunctions[env.version] = true
    knownCFunctions[env.isluau] = true
    knownCFunctions[env.iscclosure] = true
    knownCFunctions[env.islclosure] = true
    knownCFunctions[env.newcclosure] = true
    env.getscriptbytecode = function(script)
        if script == nil then error("invalid argument to getscriptbytecode", 2) end
        if type(script) == "table" then
            local m = getmetatable(script)
            if m and m._isProxy then
                local nm = m._name or ""
                if nm:find("Animate") then return "bytecode" end
                if nm:find("LocalScript") or nm:find("inst") then return nil end
                return nil
            end
        end
        error("invalid argument to getscriptbytecode", 2)
    end
    env.getscriptclosure = function(script)
        return function() end
    end
    env.decompile = function(script)
        if type(script) == "table" then
            local m = getmetatable(script)
            if m and m._isProxy then
                local nm = m._name or ""
                if nm:find("LocalScript") or nm:find("inst") then return "Bytecode is empty" end
            end
        end
        return "decompile failed"
    end
    env.getscripthash = function() return "" end
    env.clonefunction = function(f)
        if type(f) ~= "function" then error("invalid argument #1 to 'clonefunction'", 2) end
        local source = cloneSources[f] or f
        local originalBehavior = originalBehaviors[f] or source
        local wrapper = function(...)
            return originalBehavior(...)
        end
        cloneSources[wrapper] = source
        cloneWrappers[wrapper] = f
        if cclosureSet[f] then cclosureSet[wrapper] = true end
        return wrapper
    end
    env.cloneref = function(ref) return ref end
    env.compareinstances = function(a, b) return a == b end
    env.setclipboard = function(s) end
    env.getclipboard = function() return "" end
    local _fileSystem = {}
    local function _resolvePath(p)
        if type(p) ~= "string" then return nil end
        if p:sub(1, 2) == "./" then p = p:sub(3) end
        if p:sub(1, 3) == "../" then p = p:sub(4) end
        return p
    end
    env.readfile = function(path)
        local p = _resolvePath(path)
        if p and _fileSystem[p] then return _fileSystem[p] end
        return nil
    end
    env.writefile = function(path, content)
        local p = _resolvePath(path)
        if p then _fileSystem[p] = tostring(content or "") end
    end
    env.appendfile = function(path, content)
        local p = _resolvePath(path)
        if p then _fileSystem[p] = (_fileSystem[p] or "") .. tostring(content or "") end
    end
    env.makefolder = function(path)
        local p = _resolvePath(path)
        if p then _fileSystem[p .. "/"] = "folder" end
    end
    env.delfile = function(path)
        local p = _resolvePath(path)
        if p then _fileSystem[p] = nil end
    end
    env.delfolder = function(path)
        local p = _resolvePath(path)
        if p then
            _fileSystem[p .. "/"] = nil
            for k, _ in pairs(_fileSystem) do
                if k:sub(1, #p + 1) == p .. "/" then _fileSystem[k] = nil end
            end
        end
    end
    env.isfile = function(path)
        local p = _resolvePath(path)
        if p and _fileSystem[p] then return true end
        return false
    end
    env.isfolder = function(path)
        local p = _resolvePath(path)
        if p and (_fileSystem[p .. "/"] or _fileSystem[p]) then
            if _fileSystem[p .. "/"] == "folder" then return true end
        end
        for k, _ in pairs(_fileSystem) do
            if k:sub(1, #p + 1) == p .. "/" then return true end
        end
        return false
    end
    env.listfiles = function(path)
        local p = _resolvePath(path)
        if not p then return {} end
        local result = {}
        local prefix = p .. "/"
        for k, _ in pairs(_fileSystem) do
            if k:sub(1, #prefix) == prefix and k ~= prefix then
                local rest = k:sub(#prefix + 1)
                if not rest:find("/") then
                    table.insert(result, k)
                end
            end
        end
        return result
    end
    env.loadfile = function(path)
        local p = _resolvePath(path)
        if p and _fileSystem[p] then
            local fn, err = loadstring(_fileSystem[p])
            return fn
        end
        return nil
    end
    env.gethiddenproperty = function(obj, prop)
        if not isProxy(obj) then return nil, false end
        local mt = getmetatable(obj)
        local cls = mt._className or ""
        local memberInfo = resolveApiMember(cls, prop)
        if memberInfo then
            local val = mt._storedValues[prop]
            if val ~= nil then return val, true end
            return nil, true
        end
        return nil, false
    end
    env.sethiddenproperty = function(obj, prop, val)
        if not isProxy(obj) then return false end
        local mt = getmetatable(obj)
        mt._storedValues[prop] = val
        mt._setKeys[prop] = true
        return true
    end
    env.getscriptable = function(obj, prop)
        if not isProxy(obj) then return false end
        local cls = getmetatable(obj)._className or ""
        local memberInfo = resolveApiMember(cls, prop)
        if memberInfo and not memberInfo.tags.NotScriptable then return true end
        return false
    end
    env.setscriptable = function(obj, prop, flag)
        return false
    end
    env.getconnections = function(signal)
        local result = {}
        if isProxy(signal) then
            local mt = getmetatable(signal)
            if mt and mt._signalForProperty then
                local key = proxyName(mt._signalForProperty.proxy) .. "." .. mt._signalForProperty.propName
                for _, cb in ipairs(propertyChangeCallbacks[key] or {}) do
                    table.insert(result, {
                        Enabled = true,
                        ForeignState = false,
                        LuaConnection = true,
                        Function = cb,
                        Thread = nil,
                        Fire = function() cb() end,
                        Defer = function() end,
                        Disconnect = function() end,
                        Disable = function() end,
                        Enable = function() end,
                    })
                end
            end
            if mt and mt._signalForEvent then
                for _, conn in ipairs(eventConnections) do
                    if conn.proxy == mt._signalForEvent.proxy and conn.eventName == mt._signalForEvent.eventName then
                        table.insert(result, {
                            Enabled = true,
                            ForeignState = false,
                            LuaConnection = true,
                            Function = conn.callback,
                            Thread = nil,
                            Fire = function() conn.callback() end,
                            Defer = function() end,
                            Disconnect = function() end,
                            Disable = function() end,
                            Enable = function() end,
                        })
                    end
                end
            end
        end
        return result
    end
    env.getsenv = function() return env end
    env.setthreadidentity = function(id) if id < 0 then error("invalid identity", 2) end end
    env.getthreadidentity = function() return 7 end
    env.getidentity = function() return 7 end
    env.getthreadcontext = function() return 7 end
    env.getfpscap = function() return 60 end
    env.setfpscap = function() end
    env.setidentity = function() end
    env.isreadonly = function(t)
        if type(t) == "table" then
            local m = getmetatable(t)
            if m and (m._isReadonlyGuard or m._isFrozen) then return true end
            if m and m.__newindex and type(m.__newindex) == "function" then return true end
            return frozenTables[t] == true or readonlyTables[t] == true
        end
        return true
    end
    env.setidentity = function(id) if id < 0 then error("invalid identity", 2) end end
    env.fireclickdetector = function() end
    env.fireproximityprompt = function() end
    env.hookmetamethod = function(obj, metamethodName, newFunc)
        if obj == nil then error("invalid argument #1 to 'hookmetamethod'", 2) end
        if type(metamethodName) ~= "string" then error("invalid argument #2 to 'hookmetamethod'", 2) end
        if type(newFunc) ~= "function" then error("invalid argument #3 to 'hookmetamethod'", 2) end
        local mt = getmetatable(obj)
        if not mt then
            error("invalid argument #1 to 'hookmetamethod' (value has no metatable)", 2)
        end
        local original = mt[metamethodName]
        mt[metamethodName] = newFunc
        return original
    end
    env.isrbxactive = function() return true end
    env.lz4compress = function(s) return s end
    env.lz4decompress = function(s) return s end
    env.getnamecallmethod = function() return "" end
    env.setnamecallmethod = function() end
    env.setrawmetatable = function(t, mt) return setmetatable(t, mt) end
    env.setreadonly = function(t, flag)
        if type(t) ~= "table" then return end
        if flag == false or flag == nil then
            readonlyTables[t] = nil
            frozenTables[t] = nil
            local m = getmetatable(t)
            if m and m._isReadonlyGuard then
                local snapshot = m.__index
                if type(snapshot) == "table" then
                    for k, v in pairs(snapshot) do rawset(t, k, v) end
                end
                setmetatable(t, nil)
            end
        else
            readonlyTables[t] = true
        end
    end
    env.getrenderproperty = function(obj, prop)
        if not obj or type(obj) ~= "table" then return nil end
        local m = getmetatable(obj)
        if m and m._storedValues then
            return m._storedValues[prop]
        end
        return nil
    end
    env.setrenderproperty = function(obj, prop, val)
        if not obj or type(obj) ~= "table" then return end
        local m = getmetatable(obj)
        if m and m._storedValues then
            m._storedValues[prop] = val
            m._setKeys[prop] = true
        end
    end
    env.cleardrawcache = function() end
    env.toast = function() end
    env.messagebox = function() return 1 end
    env.zstdcompress = function(s) return s end
    env.zstddecompress = function(s) return s end
    env.qrcode = function() return "" end
    env.newproxy = function(arg)
        local proxy = newproxy(arg)
        if arg == true then
            local m = getmetatable(proxy)
            if m then
                m._isUserdataProxy = true
            end
        end
        return proxy
    end
    env.getgc = function() return {} end
    env.gcinfo = function() return math.floor(_realCollectgarbage("count")) end
    env.printidentity = function() print("Current identity is 7") end
    env.cache = {
        invalidate = function() end,
        iscached = function() return true end,
        replace = function() end,
    }
    knownCFunctions[env.cache.invalidate] = true
    knownCFunctions[env.cache.iscached] = true
    knownCFunctions[env.cache.replace] = true
    env.isscriptable = function(obj, prop)
        if not isProxy(obj) then return false end
        local cls = getmetatable(obj)._className or ""
        local memberInfo = resolveApiMember(cls, tostring(prop))
        if memberInfo and not memberInfo.tags.NotScriptable then
            return true
        end
        return false
    end
    knownCFunctions[env.isscriptable] = true
    env.WebSocket = {
        connect = function(url)
            local ws = makeProxy("WebSocket")
            local wmt = getmetatable(ws)
            wmt._className = "WebSocket"
            wmt._storedValues["ClassName"] = "WebSocket"
            wmt._setKeys["ClassName"] = true
            wmt._storedValues["Send"] = function() end
            wmt._setKeys["Send"] = true
            wmt._storedValues["Close"] = function() end
            wmt._setKeys["Close"] = true
            wmt._storedValues["OnMessage"] = {}
            wmt._setKeys["OnMessage"] = true
            wmt._storedValues["OnClose"] = {}
            wmt._setKeys["OnClose"] = true
            return ws
        end,
    }
    knownCFunctions[env.WebSocket.connect] = true
    env.queue_on_teleport = function() end
    env.queueonteleport = env.queue_on_teleport
    knownCFunctions[env.queue_on_teleport] = true
    knownCFunctions[env.queueonteleport] = true
    env.setrbxclipboard = function() end
    knownCFunctions[env.setrbxclipboard] = true
    env.rconsoleclear = function() end
    env.rconsolecreate = function() end
    env.rconsoledestroy = function() end
    env.rconsoleinput = function() return "" end
    env.rconsoleprint = function() end
    env.rconsolesettitle = function() end
    env.rconsolename = env.rconsolesettitle
    env.consoleclear = env.rconsoleclear
    env.consolecreate = env.rconsolecreate
    env.consoledestroy = env.rconsoledestroy
    env.consoleinput = env.rconsoleinput
    env.consoleprint = env.rconsoleprint
    env.consolesettitle = env.rconsolesettitle
    env.mouse1click = function() end
    env.mouse1press = function() end
    env.mouse1release = function() end
    env.mouse2click = function() end
    env.mouse2press = function() end
    env.mouse2release = function() end
    env.mousemoveabs = function() end
    env.mousemoverel = function() end
    env.mousescroll = function() end
    env.isrenderobj = function(obj)
        if not obj or type(obj) ~= "table" then return false end
        local m = getmetatable(obj)
        if m and m._className == "Drawing" then return true end
        return false
    end
    knownCFunctions[env.isrenderobj] = true
    env.getcallingscript = function() return nil end
    knownCFunctions[env.getcallingscript] = true
    env.collectgarbage = function(opt, ...)
        if opt == "count" then
            return _realCollectgarbage("count")
        elseif opt == "collect" or opt == nil then
            _realCollectgarbage("collect")
            return 0
        elseif opt == "stop" then
            return _realCollectgarbage("stop")
        elseif opt == "restart" then
            return _realCollectgarbage("restart")
        elseif opt == "step" then
            return _realCollectgarbage("step", ...)
        elseif opt == "setpause" then
            return _realCollectgarbage("setpause", ...)
        elseif opt == "setstepmul" then
            return _realCollectgarbage("setstepmul", ...)
        elseif opt == "isrunning" then
            return _realCollectgarbage("isrunning")
        end
        return 0
    end
    env.require = function(modname)
        if type(modname) == "table" and getmetatable(modname) and getmetatable(modname)._className then
            return modname
        end
        error("attempt to call a nil value", 2)
    end
    knownCFunctions[env.require] = true
    env.shared = setmetatable({}, {
        _serialName = "shared",
        __index = function(_, k) return env[k] end,
        __newindex = function(t, k, v) env[k] = v; rawset(t, k, v) end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
        __pairs = function() return pairs(env) end,
        __len = function() return 0 end,
    })
    env.dofile = nil
    env.package = nil

    local blockedGlobals = {
        require = true,
        dofile = true,
        package = true,
        loadfile = true,
        io = true,
        os = true,
    }
    setmetatable(env, {
        __index = function(t, k)
            if blockedGlobals[k] then return nil end
            if k == "iscclosure" then return function(f) return type(f) == "function" end end
            if k == "islclosure" then return function(f) return false end end
            if k == "newcclosure" then return function(f) return f end end
            if k == "hookfunction" then return function(t, r) return t end end
            if k == "clonefunction" then return function(f) return f end end
            if k == "cloneref" then return function(r) return r end end
            if k == "getrawmetatable" then return function(t) return getmetatable(t) end end
            if k == "setrawmetatable" then return function(t, mt) return setmetatable(t, mt) end end
            if k == "getgenv" then return function() return env end end
            if k == "getrenv" then return function() return env end end
            if k == "getregistry" then return function() return {} end end
            if k == "getidentity" then return function() return 7 end end
            if k == "identifyexecutor" then return function() return "envlog", "1.0" end end
            if k == "isluau" then return function() return true end end
            if k == "checkcaller" then return function() return false end end
            if k == "getinstances" then return function() return {} end end
            if k == "getnilinstances" then return function() return {} end end
            if k == "getscripts" then return function() return {} end end
            if k == "getloadedmodules" then return function() return {} end end
            if k == "getrunningscripts" then return function() return {} end end
            if k == "Drawing" then return makeProxy("Drawing") end
            if k == "crypt" then return makeProxy("crypt") end
            if k == "base64" then return { encode = function(s) return s end, decode = function(s) return s end } end
            if k == "http_request" then return function() return {StatusCode=200,Body="",Success=true} end end
            if k == "request" then return function() return {StatusCode=200,Body="",Success=true} end end
            if k == "setclipboard" then return function() end end
            if k == "readfile" then return function() return "" end end
            if k == "writefile" then return function() end end
            if k == "isfile" then return function() return false end end
            if k == "isfolder" then return function() return false end end
            if k == "getnamecallmethod" then return function() return "" end end
            if k == "hookmetamethod" then return function() return function() end end end
            if k == "newproxy" then return function(a) return newproxy(a) end end
            if k == "setreadonly" then return function() end end
            if k == "isreadonly" then return env.isreadonly end
            if k == "fireclickdetector" then return function() end end
            if k == "fireproximityprompt" then return function() end end
            if k == "getscriptbytecode" then return function() return "" end end
            if k == "decompile" then return function() return "" end end
            if k == "getscripthash" then return function() return "" end end
            if k == "gethui" then return function() return _huiProxy end end
            if k == "gethwid" then return function() return "sandbox" end end
            if k == "getcustomasset" then return function() return "rbxasset://temp" end end
            if k == "syn" then return setmetatable({request=function() return {StatusCode=200,Body="",Success=true} end}, {__index=function() return function() return nil end end}) end
            return nil
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end,
    })
    env.Drawing = setmetatable({
        new = function(type_name)
            local v = genVar("drawing")
            emit(string.format('local %s = Drawing.new("%s")', v, tostring(type_name)))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = "Drawing"
            mt._storedValues["ClassName"] = "Drawing"
            mt._setKeys["ClassName"] = true
            mt._storedValues["Visible"] = false
            mt._setKeys["Visible"] = true
            return proxy
        end,
        Fonts = {
            UI = 0, System = 1, Plex = 2, Monospace = 3,
        },
        Destroy = function() end,
    }, {
        __index = function(_, k)
            if k == "Fonts" then return env.Drawing.Fonts end
            return makeProxy("Drawing." .. tostring(k))
        end,
    })
    local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function b64encode(data)
        data = tostring(data or "")
        local result = {}
        local i = 1
        while i <= #data do
            local a, b, c = string.byte(data, i, i+2)
            local idx1 = math.floor(a / 4) + 1
            table.insert(result, string.sub(B64_CHARS, idx1, idx1))
            if b then
                local idx2 = (a % 4) * 16 + math.floor(b / 16) + 1
                table.insert(result, string.sub(B64_CHARS, idx2, idx2))
                if c then
                    local idx3 = (b % 16) * 4 + math.floor(c / 64) + 1
                    local idx4 = (c % 64) + 1
                    table.insert(result, string.sub(B64_CHARS, idx3, idx3))
                    table.insert(result, string.sub(B64_CHARS, idx4, idx4))
                else
                    local idx3 = (b % 16) * 4 + 1
                    table.insert(result, string.sub(B64_CHARS, idx3, idx3))
                    table.insert(result, "=")
                end
            else
                local idx2 = (a % 4) * 16 + 1
                table.insert(result, string.sub(B64_CHARS, idx2, idx2))
                table.insert(result, "==")
            end
            i = i + 3
        end
        return table.concat(result)
    end
    local B64_DECODE = {}
    for i = 1, #B64_CHARS do
        B64_DECODE[string.byte(B64_CHARS, i)] = i - 1
    end
    local function b64decode(data)
        data = tostring(data or ""):gsub("[^%w%+%/%=]", "")
        data = data:gsub("=+$", "")
        local result = {}
        local i = 1
        while i <= #data do
            local a = B64_DECODE[string.byte(data, i)] or 0
            local b = B64_DECODE[string.byte(data, i+1)] or 0
            local c = B64_DECODE[string.byte(data, i+2)]
            local d = B64_DECODE[string.byte(data, i+3)]
            local byte1 = a * 4 + math.floor(b / 16)
            table.insert(result, string.char(byte1))
            if c then
                local byte2 = (b % 16) * 16 + math.floor(c / 4)
                table.insert(result, string.char(byte2))
                if d then
                    local byte3 = (c % 4) * 64 + d
                    table.insert(result, string.char(byte3))
                end
            end
            i = i + 4
        end
        return table.concat(result)
    end
    env.crypt = setmetatable({
        base64encode = b64encode,
        base64decode = b64decode,
        encrypt = function(data, key, iv, mode)
            local result = {}
            for i = 1, #data do
                local keyByte = string.byte(key, (i-1) % #key + 1)
                table.insert(result, string.char(bit32.bxor(string.byte(data, i), keyByte)))
            end
            return table.concat(result), iv or "0000000000000000"
        end,
        decrypt = function(data, key, iv, mode)
            local result = {}
            for i = 1, #data do
                local keyByte = string.byte(key, (i-1) % #key + 1)
                table.insert(result, string.char(bit32.bxor(string.byte(data, i), keyByte)))
            end
            return table.concat(result)
        end,
        generatebytes = function(size)
            size = tonumber(size) or 16
            local bytes = {}
            for i = 1, size do
                table.insert(bytes, string.char(math.random(0, 255)))
            end
            return b64encode(table.concat(bytes))
        end,
        generatekey = function()
            local bytes = {}
            for i = 1, 32 do
                table.insert(bytes, string.char(math.random(0, 255)))
            end
            return b64encode(table.concat(bytes))
        end,
        hash = function(data, algorithm)
            local ok, result = pcall(serde.hash, algorithm or "sha256", data)
            if ok and type(result) == "string" then return result end
            return b64encode(tostring(data))
        end,
    }, { __index = function(_, k) return function() return "" end end })
    env.base64 = { encode = b64encode, decode = b64decode }
    env.syn = setmetatable({
        request = function(opts)
            return env.http_request(opts)
        end,
        queue = function() return {} end,
        crypt = env.crypt,
        base64 = env.base64,
        aux = setmetatable({}, { __index = function(_, k) return function() return nil end end }),
    }, { __index = function(_, k) return function() return nil end end })
    env.getregistry = function() return {} end
    env.getreg = function() return {} end
    env.getidentity = function() return 7 end
    env.getthread = function() return coroutine.running() end
    env.getstack = function() return {} end
    env.getparams = function() return {} end
    env.isourclosure = function() return true end
    env.isexecutorclosure = function() return true end
    env.isfunction = function(f) return type(f) == "function" end
    env.Path2DControlPoint = setmetatable({
        new = function(position, leaveTangent, rightTangent)
            local v = genVar("p2dcp")
            local posSer = serialize(position)
            emit(string.format('local %s = Path2DControlPoint.new(%s)', v, posSer))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = "Path2DControlPoint"
            mt._storedValues["ClassName"] = "Path2DControlPoint"
            mt._setKeys["ClassName"] = true
            mt._storedValues["Position"] = position
            mt._setKeys["Position"] = true
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Path2DControlPoint." .. tostring(k)) end })
    env.CrosshairImage = makeProxy("CrosshairImage")
    env.IB_CRASH = false
    env.DControlPoint = makeProxy("DControlPoint")
    env.process = setmetatable({
        exit = function() emit("-- process.exit() called") end,
        args = {}, env = {}, cwd = function() return "/" end, os = "linux", pid = 1,
    }, { __index = function(_, k) return makeProxy("process." .. tostring(k)) end })

    local hiddenFuncs = {}
    for k, v in pairs(env) do
        if type(k) == "string" and (k:lower():find("hook") or k:lower():find("closure")) then
            hiddenFuncs[k] = v
            env[k] = nil
        end
    end
    local existingEnvMt = getmetatable(env)
    setmetatable(env, {
        __index = function(t, k)
            if hiddenFuncs[k] ~= nil then return hiddenFuncs[k] end
            if existingEnvMt and existingEnvMt.__index then
                if type(existingEnvMt.__index) == "function" then return existingEnvMt.__index(t, k) end
                return existingEnvMt.__index[k]
            end
            return nil
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end,
    })

    for k, v in pairs(env) do
        if type(v) == "function" then
            knownCFunctions[v] = true
        end
    end
    for k, v in pairs(env) do
        if type(v) == "table" then
            for k2, v2 in pairs(v) do
                if type(v2) == "function" then
                    knownCFunctions[v2] = true
                end
            end
        end
    end


    local _orig_emit = emit
    emit = function() end
    local _orig_type = type
    local _lockedObjects = setmetatable({}, {__mode = "k"})
    local function _lockObj(obj) _lockedObjects[obj] = true end

    env.type = function(v)
        local t = _orig_type(v)
        if t == "table" then
            local mt = getmetatable(v)
            if mt and _orig_type(mt) == "table" then
                if mt.__type or mt._isProxy then return "userdata" end
            end
            if _lockedObjects[v] then return "userdata" end
        end
        return t
    end

    env.typeof = function(v)
        if v == nil then return "nil" end
        local t = _orig_type(v)
        if t == "table" then
            local mt = getmetatable(v)
            if mt and _orig_type(mt) == "table" then
                if mt.__type then return mt.__type end
                if mt._isProxy then return rawget(mt, "_ctorName") or mt._ctorName or "Instance" end
            end
            if _lockedObjects[v] then return "Instance" end
            return "table"
        end
        return t
    end

    local _orig_getmetatable = getmetatable
    env.getmetatable = function(obj)
        if _lockedObjects[obj] then return "The metatable is locked" end
        local mt = _orig_getmetatable(obj)
        if mt and _orig_type(mt) == "table" then
            local mm = rawget(mt, "__metatable")
            if mm and (_orig_type(mm) == "string" or _orig_type(mm) == "boolean") then return mm end
        end
        return mt
    end

    env.getrawmetatable = function(obj)
        local mt = _orig_getmetatable(obj)
        if mt and _orig_type(mt) == "table" then
            local orig_idx = rawget(mt, "__index")
            local orig_nc = rawget(mt, "__namecall")
            local orig_ni = rawget(mt, "__newindex")
            if orig_idx and not rawget(mt, "_isFakeC") then
                rawset(mt, "_realIndex", orig_idx)
                rawset(mt, "_isFakeC", true)
                local fakeC = function() end
                rawset(mt, "__index", orig_idx)
            end
        end
        return mt
    end

    env.buffer = {
        create = function(size)
            return setmetatable({_data = {}, _size = size}, {__len = function() return size end})
        end,
        writeu32 = function(buf, offset, value)
            if _orig_type(buf) == "table" and buf._data then
                buf._data[offset] = value % 256
                buf._data[offset + 1] = math.floor(value / 256) % 256
                buf._data[offset + 2] = math.floor(value / 65536) % 256
                buf._data[offset + 3] = math.floor(value / 16777216) % 256
            end
        end,
        readu32 = function(buf, offset)
            if _orig_type(buf) == "table" and buf._data then
                return (buf._data[offset] or 0) + (buf._data[offset + 1] or 0) * 256 +
                       (buf._data[offset + 2] or 0) * 65536 + (buf._data[offset + 3] or 0) * 16777216
            end
            return 0
        end,
        writeu8 = function(buf, offset, value) if buf._data then buf._data[offset] = value % 256 end end,
        readu8 = function(buf, offset) if buf._data then return buf._data[offset] or 0 end return 0 end,
        writei32 = function(buf, offset, value) env.buffer.writeu32(buf, offset, value) end,
        readi32 = function(buf, offset) return env.buffer.readu32(buf, offset) end,
        writestring = function(buf, offset, str) for i = 1, #str do buf._data[offset + i - 1] = str:byte(i) end end,
        readstring = function(buf, offset, len) local s = "" for i = 1, len do s = s .. string.char(buf._data[offset + i - 1] or 0) end return s end,
        len = function(buf) return buf._size or 0 end,
    }

    env.table = env.table or table
    if table.freeze then
        env.table.freeze = table.freeze
        env.table.isfrozen = table.isfrozen
    else
        env.table.freeze = function(t) local mt = _orig_getmetatable(t) or {} mt.__frozen = true mt.__newindex = function() error("attempt to modify frozen table") end setmetatable(t, mt) return t end
        env.table.isfrozen = function(t) local mt = _orig_getmetatable(t) return mt ~= nil and mt.__frozen == true or false end
    end

    env.gethiddenproperty = function() error("gethiddenproperty is not available") end
    env.sethiddenproperty = function() error("sethiddenproperty is not available") end

    local _cleanEnv = {}
    for k, v in pairs(env) do
        local kl = tostring(k):lower()
        if not (kl == "getgenv" or kl == "getrenv" or kl == "getreg" or kl == "getregistry"
                or kl == "hookfunction" or kl == "hookmetamethod" or kl == "getrawmetatable"
                or kl == "setrawmetatable" or kl == "newcclosure" or kl == "checkcaller"
                or kl == "iscclosure" or kl == "islclosure" or kl == "gethiddenproperty"
                or kl == "sethiddenproperty" or kl == "getinstances" or kl == "getscripts"
                or kl == "identifyexecutor" or kl == "gethwid" or kl == "getidentity"
                or kl == "loadstring" or kl == "request" or kl == "http_request"
                or kl == "cloneref" or kl == "clonefunction" or kl == "getscriptbytecode"
                or kl == "decompile" or kl == "getscripthash" or kl == "gethui"
                or kl == "fireclickdetector" or kl == "fireproximityprompt") then
            _cleanEnv[k] = v
        end
    end
    env.getfenv = function(level)
        if _orig_type(level) == "number" then return _cleanEnv end
        if _orig_type(level) == "function" then return _cleanEnv end
        return _cleanEnv
    end

    local _serverTime = os.time() * 1000
    local function _getServerTimeNow() _serverTime = _serverTime + 1 return _serverTime end

    if not env.debug.info and env.debug.getinfo then
        env.debug.info = function(level, what)
            if _orig_type(level) == "function" then
                local info = env.debug.getinfo(level, what)
                if not info then return nil end
                if what and what:find("s") then return info.source or "=[C]", info.currentline or 0, info.what or "C", info.linedefined or -1 end
                if what and what:find("n") then return info.name or "?" end
                if what and what:find("f") then return info.func end
                if what and what:find("l") then return info.currentline or 0 end
                return info
            end
            local info = env.debug.getinfo(level + 1, what)
            if not info then return nil end
            if what and what:find("s") then return info.source or "=[C]", info.currentline or 0, info.what or "C", info.linedefined or -1 end
            if what and what:find("n") then return info.name or "?" end
            if what and what:find("f") then return info.func end
            if what and what:find("l") then return info.currentline or 0 end
            return info
        end
    end

    if not env.debug.getupvalue then env.debug.getupvalue = function(fn, idx) return nil, nil end end

    if not env.debug.setupvalue then env.debug.setupvalue = function(fn, idx, val) return nil end end


    local function makeEnumItem(value, name)
        return setmetatable({Value = value, Name = name, EnumType = "Enum"}, {
            __type = "EnumItem", __newindex = function() error("attempt to modify enum item") end,
        })
    end
    local function makeEnumTable(entries)
        return setmetatable(entries, {__type = "Enum", __newindex = function() error("attempt to modify enum") end})
    end
    env.Enum = setmetatable({
        DeveloperMemoryTag = makeEnumTable({HttpCache = makeEnumItem(0, "HttpCache"), Lua = makeEnumItem(1, "Lua")}),
        Material = makeEnumTable({Plastic = makeEnumItem(256, "Plastic"), Neon = makeEnumItem(1280, "Neon")}),
        MembershipType = makeEnumTable({None = makeEnumItem(0, "None"), Premium = makeEnumItem(4, "Premium")}),
        KeyCode = makeEnumTable({E = makeEnumItem(5, "E"), W = makeEnumItem(10, "W"), A = makeEnumItem(15, "A"), S = makeEnumItem(20, "S"), D = makeEnumItem(25, "D")}),
        UserInputType = makeEnumTable({MouseButton1 = makeEnumItem(0, "MouseButton1"), MouseButton2 = makeEnumItem(1, "MouseButton2"), Keyboard = makeEnumItem(2, "Keyboard")}),
    }, {__index = function(t, k) return makeEnumTable({}) end, __newindex = function() error("attempt to modify enum") end})

    local _orig_log = math.log
    env.math = env.math or math
    env.math.log = function(x, base) if x == nil then error("missing argument #1 to 'log'") end return _orig_log(x, base) end

    local _orig_Instance_new = env.Instance.new
    env.Instance.new = function(cls, parent)
        local inst = _orig_Instance_new(cls, parent)
        local mt = _orig_getmetatable(inst)
        if mt and _orig_type(mt) == "table" then
            local _orig_index = mt.__index
            if cls == "BindableFunction" then
                mt.__index = function(t, k)
                    if k == "Invoke" then return function(self, ...) if t.OnInvoke then return t.OnInvoke(...) end return nil end end
                    if _orig_index then return _orig_index(t, k) end
                    return nil
                end
            elseif cls == "Part" then
                mt.__index = function(t, k)
                    if k == "Anchored" then return false end
                    if k == "AssemblyLinearVelocity" then return Vector3.new(0, 10, 0) end
                    if _orig_index then return _orig_index(t, k) end
                    return nil
                end
            end
        end
        return inst
    end

    local _orig_Instance_new2 = env.Instance.new
    env.Instance.new = function(cls, parent)
        if cls == "BindableFunction" then
            local bf = {}
            local _onInvoke = nil
            setmetatable(bf, {
                __index = function(t, k)
                    if k == "OnInvoke" then return _onInvoke end
                    if k == "Invoke" then return function(self, ...) if _onInvoke then return _onInvoke(...) end return nil end end
                    if k == "Destroy" then return function() end end
                    if k == "ClassName" then return "BindableFunction" end
                    if k == "Parent" then return nil end
                    return nil
                end,
                __newindex = function(t, k, v)
                    if k == "OnInvoke" then _onInvoke = v end
                end,
                __tostring = function() return "BindableFunction" end,
            })
            return bf
        end
        local inst = _orig_Instance_new2(cls, parent)
        return inst
    end

    local function _patchProxyIndex(proxy, extraFn)
        if not proxy then return end
        local mt = _orig_getmetatable(proxy)
        if not mt or _orig_type(mt) ~= "table" then return end
        local _orig_index = mt.__index
        mt.__index = function(self, k)
            local v = extraFn(self, k)
            if v ~= nil then return v end
            if _orig_index then return _orig_index(self, k) end
            return nil
        end
        _lockObj(proxy)
    end

    local _game_proxy = env.game
    local _origGS = nil
    if _game_proxy then
        local _gmt = _orig_getmetatable(_game_proxy)
        if _gmt and _gmt.__index then _origGS = _gmt.__index(_game_proxy, "GetService") end
    end
    if _game_proxy then
        _patchProxyIndex(_game_proxy, function(self, k)
            if k == "GetService" or k == "getService" or k == "FindService" then
                return _origGS
            end
            if k == "PlaceId" then return 1234567890 end
            if k == "GameId" then return 987654321 end
            if k == "ClassName" then return "DataModel" end
            if k == "JobId" then return "job-1234567" end
            if k == "GetJobsInfo" then return function() return {{name = "Heartbeat", dutyCycle = 0.01}, {name = "Stepped", dutyCycle = 0.01}, {name = "RenderSteps", dutyCycle = 0.02}} end end
            return nil
        end)
    end

    local _ws_proxy = env.workspace
    if _ws_proxy then
        _patchProxyIndex(_ws_proxy, function(self, k)
            if k == "ClassName" then return "Workspace" end
            if k == "GetServerTimeNow" then return _getServerTimeNow end
            if k == "DistributedGameTime" then return os.clock() end
            if k == "CurrentCamera" then return makeProxy("Camera") end
            return nil
        end)
    end

    if _game_proxy then
        _patchProxyIndex(_game_proxy:GetService("NetworkClient"), function(self, k)
            if k == "FindFirstChild" then return function(self, name) if name == "ClientReplicator" then return makeProxy("ClientReplicator") end return nil end end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("Chat"), function(self, k)
            if k == "Parent" then local p = makeProxy("ugc") local pmt = _orig_getmetatable(p) if pmt then pmt.__index = function(s, key) if key == "Name" then return "ugc" end return nil end end return p end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("Stats"), function(self, k)
            if k == "GetTotalMemoryUsageMb" then return function() return 256.5 end end
            if k == "GetMemoryUsageMbForTag" then return function() return 12.3 end end
            return nil
        end)
        local _clockTime = 14
        _patchProxyIndex(_game_proxy:GetService("Lighting"), function(self, k)
            if k == "GetMinutesAfterMidnight" then return function() return _clockTime * 60 end end
            if k == "SetMinutesAfterMidnight" then return function(self, m) _clockTime = m / 60 end end
            if k == "ClockTime" then return _clockTime end
            return nil
        end)
        local _memData = {}
        _patchProxyIndex(_game_proxy:GetService("MemStorageService"), function(self, k)
            if k == "SetItem" then return function(self, key, val) _memData[key] = tostring(val) end end
            if k == "GetItem" then return function(self, key) return _memData[key] end end
            return nil
        end)
        local _tags = {}
        _patchProxyIndex(_game_proxy:GetService("CollectionService"), function(self, k)
            if k == "AddTag" then return function(self, inst, tag) _tags[tag] = _tags[tag] or {}; table.insert(_tags[tag], inst) end end
            if k == "GetTagged" then return function(self, tag) return _tags[tag] or {} end end
            if k == "RemoveTag" then return function(self, inst, tag) if _tags[tag] then for i, v in ipairs(_tags[tag]) do if v == inst then table.remove(_tags[tag], i) break end end end end end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("SoundService"), function(self, k) if k == "DistanceFactor" then return 3.51 end return nil end)
        _patchProxyIndex(_game_proxy:GetService("RunService"), function(self, k)
            if k == "Heartbeat" or k == "RenderStepped" or k == "Stepped" then
                local signal = makeProxy("RBXScriptSignal")
                local sig_mt = _orig_getmetatable(signal)
                if sig_mt then
                    local _sig_orig_index = sig_mt.__index
                    sig_mt.__index = function(s, key)
                        if key == "Connect" then return function(self, cb) local conn = makeProxy("RBXScriptConnection") pcall(cb, 0.016) pcall(cb, 0.017) pcall(cb, 0.015) pcall(cb, 0.018) pcall(cb, 0.016) return conn end end
                        if key == "Wait" then return function() return 0.016 end end
                        if _sig_orig_index then return _sig_orig_index(s, key) end
                        return nil
                    end
                end
                return signal
            end
            if k == "IsClient" then return function() return true end end
            if k == "IsServer" then return function() return false end end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("HttpService"), function(self, k)
            if k == "RequestAsync" then return function(self, opts) return {Success = true, StatusCode = 200, Body = '{"ip":"192.168.1.1"}', Headers = {}} end end
            if k == "GenerateGUID" then return function(self, wrap) local g = string.format("%08x-%04x-%04x-%04x-%012x", math.random(0, 4294967295), math.random(0, 65535), math.random(0, 65535), math.random(0, 65535), math.random(0, 281474976710655)) if wrap then return "{" .. g .. "}" end return g end end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("Players"), function(self, k)
            if k == "GetCharacterAppearanceInfoAsync" then return function(self, uid) return {assets = {{id = 1, name = "Shirt", assetType = {name = "Shirt"}}}, bodyColors = {leftArmColorId = 1, torsoColorId = 1, rightArmColorId = 1, headColorId = 1, leftLegColorId = 1, rightLegColorId = 1}, scales = {bodyType = 1, head = 1, height = 1, proportion = 0, depth = 1, width = 1}} end end
            return nil
        end)
        _patchProxyIndex(_game_proxy:GetService("MarketplaceService"), function(self, k) if k == "PromptPremiumPurchase" then return function() end end return nil end)
        _patchProxyIndex(_game_proxy:GetService("AnimationClipProvider"), function(self, k) if k == "GetMemStats" then return function() return {Animations = 10, Memory = 1024, CachedAssets = 5} end end return nil end)
        _patchProxyIndex(_game_proxy:GetService("ReplicatedStorage"), function(self, k)
            if k == "DefaultChatSystemChatEvents" then
                local events = makeProxy("Folder")
                local ev_mt = _orig_getmetatable(events)
                if ev_mt then local _ev_orig_index = ev_mt.__index ev_mt.__index = function(s, key) if key == "SetBlockedUserIdsRequest" then return makeProxy("RemoteEvent") end if _ev_orig_index then return _ev_orig_index(s, key) end return nil end end
                return events
            end
            return nil
        end)
    end


    env.loadstring = env.loadstring or load

    if not env.newproxy then
        env.newproxy = function(val) local t = {} if val then setmetatable(t, {__type = "userdata", __metatable = "The metatable is locked"}) end return t end
    end


    env.gethiddenproperty = function() error("gethiddenproperty is not available") end
    env.sethiddenproperty = function() error("sethiddenproperty is not available") end

    local _real_tostring = tostring
    local _orig_env_tostring = nil
    local _orig_env_mt = getmetatable(env)
    if _orig_env_mt and _orig_env_mt.__index then
        _orig_env_tostring = rawget(env, "tostring")
    end
    if not _orig_env_tostring then
        for k, v in pairs(env) do
            if k == "tostring" then _orig_env_tostring = v break end
        end
    end
    env.tostring = function(v)
        if _orig_type(v) == "table" then
            local mt = _orig_getmetatable(v)
            if _orig_type(mt) ~= "table" then
                return _real_tostring(v)
            end
        end
        if _orig_env_tostring then
            return _orig_env_tostring(v)
        end
        return _real_tostring(v)
    end

    local _orig_debug_table = env.debug
    local _orig_debug_mt = getmetatable(_orig_debug_table)
    local _orig_debug_idx = _orig_debug_mt and _orig_debug_mt.__index or function(t, k) return rawget(t, k) end
    
    local function _sanitize_source(s)
        if type(s) ~= "string" then return s end
        return s:gsub("catlog", "script"):gsub("dump", "data"):gsub("envlog", "runtime"):gsub("deobf", "code")
    end
    
    env.debug = setmetatable({}, {
        __index = function(t, k)
            local v = rawget(_orig_debug_table, k)
            if v == nil then v = _orig_debug_idx(_orig_debug_table, k) end
            
            if k == "info" and type(v) == "function" then
                return function(f, what)
                    local results = table.pack(v(f, what))
                    for i = 1, results.n do
                        if type(results[i]) == "string" then
                            results[i] = _sanitize_source(results[i])
                        end
                    end
                    return table.unpack(results, 1, results.n)
                end
            end
            
            if k == "getinfo" and type(v) == "function" then
                return function(f, what)
                    local info = v(f, what)
                    if type(info) == "table" then
                        if info.source then info.source = _sanitize_source(info.source) end
                        if info.short_src then info.short_src = _sanitize_source(info.short_src) end
                    end
                    return info
                end
            end
            
            if k == "traceback" and type(v) == "function" then
                return function(msg, level)
                    local tb = v(msg, level)
                    tb = tb:gsub("[^\n]*[hH]ook[^\n]*\n", "")
                    tb = tb:gsub("[^\n]*[lL]ogger[^\n]*\n", "")
                    tb = tb:gsub("[^\n]*[dD]ump[^\n]*\n", "")
                    tb = tb:gsub("[^\n]*catlog[^\n]*\n", "")
                    return tb
                end
            end
            
            return v
        end,
        __newindex = function(t, k, v) rawset(t, k, v) end,
    })
    local _game_mt2 = _orig_getmetatable(env.game)
    if _game_mt2 then
        local _idx = rawget(_game_mt2, "__index")
        local _nc = rawget(_game_mt2, "__namecall")
        local _ni = rawget(_game_mt2, "__newindex")
        if knownCFunctions then
            if _idx then knownCFunctions[_idx] = true end
            if _nc then knownCFunctions[_nc] = true end
            if _ni then knownCFunctions[_ni] = true end
        end
        if cclosureSet then
            if _idx then cclosureSet[_idx] = true end
            if _nc then cclosureSet[_nc] = true end
            if _ni then cclosureSet[_ni] = true end
        end
    end
    env._serverTimeNow = _getServerTimeNow


    env.getrenv = function()
        local v = genVar("renv")
        emit(string.format("local %s = getrenv()", v))
        return setmetatable({}, { __index = function(_, k) return env[k] end })
    end
    env.getgenv = function()
        local v = genVar("genv")
        emit(string.format("local %s = getgenv()", v))
        return env
    end
    env.getreg = function() return {} end
    env.getregistry = function() return {} end
    env.getloadedmodules = function() return {} end
    env.getrunningscripts = function() return {} end
    env.getscripts = function() return {} end
    env.getnilinstances = function() return {} end
    env.getinstances = function() return {} end

    env.iscclosure = function(f)
        if type(f) ~= "function" then return false end
        return knownCFunctions[f] == true
    end
    env.islclosure = function(f)
        if type(f) ~= "function" then return false end
        return knownCFunctions[f] ~= true
    end
    env.isourclosure = function(f) return false end
    env.isexecutorclosure = function(f) return false end
    env.isfunction = function(f) return type(f) == "function" end
    env.isLfunction = env.islclosure
    env.isCfunction = env.iscclosure

    env.getthreadidentity = function() return 7 end
    env.setthreadidentity = function(id) end
    env.getidentity = function() return 7 end
    env.getthread = function() return coroutine.running() end
    env.checkcaller = function() return true end
    env.getcallingscript = function() return nil end

    env.hookfunction = function(target, replacement, ...)
        if type(target) ~= "function" then return target end
        return target
    end
    env.newcclosure = function(f) return f end
    env.restorefunction = function(f) return true end
    env.hookmetamethod = function(obj, mt, fn) return obj end

    env.setclipboard = function(s) end
    env.setrbxclipboard = function(s) end
    env.getclipboard = function() return "" end

    env.readfile = function(path) return "" end
    env.writefile = function(path, content) end
    env.appendfile = function(path, content) end
    env.makefolder = function(path) end
    env.delfile = function(path) end
    env.delfolder = function(path) end
    env.isfile = function(path) return false end
    env.isfolder = function(path) return false end
    env.listfiles = function(path) return {} end
    env.loadfile = function(path) return nil, "not found" end
    env.dofile = nil

    env.http_request = function(opts)
        if type(opts) ~= "table" then return {StatusCode=400, Body="", Success=false} end
        return {StatusCode=200, Body="", Success=true, Headers={}}
    end
    env.request = env.http_request
    env.httppost = env.http_request
    env.httpget = function(url) return "" end
    env.httpgetasync = env.httpget

    env.Drawing = setmetatable({
        new = function(type_name)
            local v = genVar("drawing")
            emit(string.format('local %s = Drawing.new("%s")', v, tostring(type_name)))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = tostring(type_name)
            mt._storedValues["ClassName"] = tostring(type_name)
            mt._setKeys["ClassName"] = true
            mt._storedValues["Visible"] = false
            mt._setKeys["Visible"] = true
            return proxy
        end,
        Fonts = {
            UI = 0, System = 1, Plex = 2, Monospace = 3,
        },
        Destroy = function() end,
        Clear = function() end,
    }, {
        __index = function(_, k)
            if k == "Fonts" then return env.Drawing.Fonts end
            return makeProxy("Drawing." .. tostring(k))
        end,
    })
    env.isrenderobj = function(obj)
        if not obj or type(obj) ~= "table" then return false end
        local m = getmetatable(obj)
        if m and m._className then return true end
        return false
    end
    env.cleardrawcache = function() end

    env.mouse1click = function() end
    env.mouse1press = function() end
    env.mouse1release = function() end
    env.mouse2click = function() end
    env.mouse2press = function() end
    env.mouse2release = function() end
    env.mousemoveabs = function(x, y) end
    env.mousemoverel = function(dx, dy) end
    env.mousescroll = function(dx, dy) end
    env.keypress = function(key) end
    env.keyrelease = function(key) end
    env.keyclick = function(key) end
    env.iskeydown = function(key) return false end
    env.ismousebuttondown = function(btn) return false end
    env.getmouselocation = function() return env.Vector2.new(0, 0) end
    env.getmousebutton = function() return "left" end
    env.getmousebuttonspressed = function() return {} end

    env.fireclickdetector = function(obj, ...) end
    env.fireproximityprompt = function(obj, ...) end
    env.firetouchinterest = function(part1, part2, ...) end
    env.firehitdetector = function(obj, ...) end
    env.firesignal = function(sig, ...) end
    env.firecallback = function(cb, ...) end

    env.gethui = function() return env.game:GetService("CoreGui") end
    env.gethiddengui = function() return env.game:GetService("CoreGui") end
    env.protectgui = function(g) return g end
    env.unprotectgui = function(g) return g end
    env.makegui = function(parent, source) return Instance.new("ScreenGui") end

    env.queue_on_teleport = function(s) end
    env.queueonteleport = env.queue_on_teleport
    env.setfpscap = function(cap) end
    env.getfpscap = function() return 60 end

    env.getstack = function(level) return {} end
    env.getparams = function(f) return {} end
    env.getupvalues = function(f) return {} end
    env.setupvalues = function(f, ...) return false end
    env.getupvalue = function(f, i) return nil end
    env.setupvalue = function(f, i, v) return false end
    env.getconstants = function(f) return {} end
    env.setconstant = function(f, i, v) return false end
    env.getconstant = function(f, i) return nil end
    env.getprotos = function(f) return {} end
    env.getproto = function(f, i) return function() end end
    env.getinfo = function(f) return {what="Lua",source="?",currentline=-1,name="?",nups=0,nparams=0,isvararg=false} end
    env.funcinfo = env.getinfo

    env.getrawmetatable = function(t)
        if type(t) ~= "table" then error("invalid argument #1 to 'getrawmetatable'", 2) end
        return getmetatable(t)
    end
    env.setrawmetatable = function(t, mt)
        if type(t) ~= "table" then return false end
        return pcall(setmetatable, t, mt)
    end

    env.getsenv = function(script) return env end
    env.getscriptenv = env.getsenv
    env.getscriptbytecode = function(script) return "" end
    env.getscriptclosure = function(script) return function() end end
    env.decompile = function(script) return "" end

    env.base64encode = function(s) return tostring(s or "") end
    env.base64decode = function(s) return tostring(s or "") end
    env.base64 = {
        encode = env.base64encode,
        decode = env.base64decode,
    }
    env.crc32 = function(s) return 0 end
    env.md5 = function(s) return string.rep("0", 32) end
    env.sha1 = function(s) return string.rep("0", 40) end
    env.sha256 = function(s) return string.rep("0", 64) end
    env.sha512 = function(s) return string.rep("0", 128) end
    env.xxh32 = function(s) return 0 end
    env.xxh64 = function(s) return 0 end

    env.WebSocket = env.WebSocket or setmetatable({
        connect = function(url) return nil end,
    }, { __index = function() return function() return nil end end })

    env.wait = function(t) return 0, 0 end
    env.delay = function(t, f) end
    env.spawn = function(f) end
    env.fastwait = env.wait
    env.fastspawn = env.spawn

    env.identifyexecutor = function() return "envlog", "1.0" end
    env.getexecutorname = env.identifyexecutor
    env.getexploitname = env.identifyexecutor

    env.crypt = {
        encrypt = function(...) return "", "key" end,
        decrypt = function(...) return "" end,
        hash = function(...) return "" end,
        generatekey = function() return string.rep("a", 32) end,
    }
    env.bit = bit32
    env.bit32 = bit32
    env.buffer = buffer
    env.utf8 = utf8

    env.cloneref = function(obj) return obj end
    env.compareinstances = function(a, b) return a == b end
    env.clonefunction = function(f) return f end
    env.getcallbackvalue = function(obj, prop) return function() end end
    env.getconnections = function(sig) return {} end
    env.getcustomasset = function(path) return "rbxassetid://0" end
    env.gethiddenproperty = function(obj, prop) return nil end
    env.sethiddenproperty = function(obj, prop, val) end
    env.isscriptable = function(obj, prop) return true end
    env.setscriptable = function(obj, prop, val) return true end
    env.getnamecallmethod = function() return "" end
    env.setnamecallmethod = function(s) end
    env.isreadonly = function(t) return false end
    env.setreadonly = function(t, v) return t end
    env.getrawmetatable = function(t)
        if type(t) ~= "table" then error("invalid argument #1 to 'getrawmetatable'", 2) end
        return getmetatable(t)
    end
    env.setrawmetatable = function(t, mt)
        if type(t) ~= "table" then return false end
        return pcall(setmetatable, t, mt)
    end
    env.lz4compress = function(s) return tostring(s or "") end
    env.lz4decompress = function(s) return tostring(s or "") end
    env.zstdcompress = env.lz4compress
    env.zstddecompress = env.lz4decompress
    env.messagebox = function(msg, title, flags) return 0 end
    env.messageboxasync = env.messagebox
    env.isrbxactive = function() return true end
    env.iswindowactive = env.isrbxactive
    env.isgameactive = env.isrbxactive
    env.getrenderproperty = function(obj, prop) return nil end
    env.setrenderproperty = function(obj, prop, val) end
    env.setrenderobj = function(obj, prop, val) end
    env.getrenderobj = function() return nil end
    env.getscripthash = function(script) return string.rep("0", 32) end
    env.gethwid = function() return string.rep("0", 64) end
    env.getgc = function(opt) return {} end
    env.filtergc = function(...) return {} end
    env.getfunctionhash = function(f) return string.rep("0", 32) end
    env.getmenv = function(script) return env end
    env.gettenv = function(script) return env end
    env.getstateenv = function() return env end
    env.getrenvshared = function() return env end
    env.getrenvglobal = function(k) return env[k] end
    env.getthreadcontext = function() return 7 end
    env.setthreadcontext = function(c) end
    env.getcontext = env.getthreadcontext
    env.setcontext = env.setthreadcontext
    env.setclosurecaps = function(f, ...) end
    env.setclosureidentity = function(f, ...) end
    env.getclosurecaps = function(f) return 0 end
    env.saveinstance = function(obj, opts) end
    env.getobjects = function(url) return {} end
    env.setnormalinstance = function(obj) return obj end
    env.getnetworkowner = function(part) return nil end
    env.testisnetworkowner = function(part) return true end
    env.isnetworkowner = env.testisnetworkowner
    env.replicatesignal = function(sig, ...) end
    env.cansignalreplicate = function(sig) return true end
    env.hooksignal = function(sig, fn) return fn end
    env.issignalhooked = function(sig) return false end
    env.restoresignal = function(sig) return true end
    env.getsignalarguments = function(sig) return {} end
    env.disableconnection = function(conn) end
    env.enableconnection = function(conn) end
    env.isconnectionenabled = function(conn) return true end
    env.getallreplicatesignals = function() return {} end
    env.lockassetsignal = function() end
    env.clearteleportqueue = function() end
    env.clear_teleport_queue = env.clearteleportqueue
    env.getcurrentactor = function() return nil end
    env.getactors = function() return {} end
    env.getactorfromthread = function(t) return nil end
    env.runonactor = function(actor, ...) end
    env.run_on_actor = env.runonactor
    env.getdeletedactors = function() return {} end
    env.isparallel = function() return false end
    env.getthreadscript = function() return nil end
    env.getcallbackvalue = function(obj, name) return function() end end
    env.protectfunction = function(f) return f end
    env.protectclosure = env.protectfunction
    env.replaceclosure = function(old, new) return new end
    env.replacefunction = env.replaceclosure
    env.replacefunc = env.replaceclosure
    env.hookfunc = env.hookfunction
    env.detourfunction = env.hookfunction
    env.detour_function = env.hookfunction
    env.isfunctionhooked = function(f) return false end
    env.ishooked = env.isfunctionhooked
    env.is_function_hooked = env.isfunctionhooked
    env.restorefunc = env.restorefunction
    env.restoreclosure = env.restorefunction
    env.protectinstance = function(obj) return obj end
    env.setsecureinstance = env.protectinstance
    env.issecuredinstance = function(obj) return false end
    env.createsecurefolder = function() return nil end
    env.makereadonly = function(t) return t end
    env.makewritable = function(t) return t end
    env.make_readonly = env.makereadonly
    env.make_writable = env.makewritable
    env.isreadonly = function(t) return false end
    env.iswriteable = function(t) return true end
    env.iswritable = env.iswriteable
    env.dumpstring = function(s) return tostring(s or "") end
    env.dumpcodesize = function(f) return 0 end
    env.issynapsefunction = function(f) return false end
    env.is_synapse_function = env.issynapsefunction
    env.iskrnlclosure = function(f) return false end
    env.is_krnl_closure = env.iskrnlclosure
    env.isfluxusclosure = function(f) return false end
    env.isfluxusfunction = env.isfluxusclosure
    env.is_fluxus_closure = env.isfluxusclosure
    env.is_fluxus_function = env.isfluxusclosure
    env.isprotosmasherclosure = function(f) return false end
    env.is_protosmasher_closure = env.isprotosmasherclosure
    env.isourcallstack = function() return false end
    env.isourclosure = function(f) return false end
    env.is_our_closure = env.isourclosure
    env.islocalsourcecontainer = function(s) return false end
    env.checkclosure = function(f) return false end
    env.setclosurecaps = function(f, ...) end
    env.getclosurecaps = function(f) return 0 end
    env.validlevel = function(l) return l >= 0 and l <= 8 end
    env.isvalidlevel = env.validlevel
    env.getloadedmodules = function() return {} end
    env.get_loaded_modules = env.getloadedmodules
    env.getmodules = env.getloadedmodules
    env.get_modules = env.getloadedmodules
    env.getrunningscripts = function() return {} end
    env.getscripts = function() return {} end
    env.get_scripts = env.getscripts
    env.getnilinstances = function() return {} end
    env.get_nil_instances = env.getnilinstances
    env.getinstances = function() return {} end
    env.get_instances = env.getinstances
    env.getscriptfunction = function(s) return function() end end
    env.get_script_function = env.getscriptfunction
    env.getcallingscript = function() return nil end
    env.get_calling_script = env.getcallingscript
    env.getcaller = env.getcallingscript
    env.getcommchannel = function(name) return nil end
    env.get_comm_channel = env.getcommchannel
    env.createcommchannel = function(name) return nil end
    env.create_comm_channel = env.createcommchannel
    env.getsynasset = function(path) return "rbxassetid://0" end
    env.writecustomasset = function(path, content) return "rbxassetid://0" end
    env.getcustomasset = function(path) return "rbxassetid://0" end
    env.getfflag = function(name) return nil end
    env.setfflag = function(name, value) end
    env.setsimulationradius = function(r) end
    env.setstack = function(level, ...) end
    env.getinfo = function(f, what)
        return {what="Lua", source="?", currentline=-1, name="?", nups=0, numparams=0, is_vararg=false, line=1, func=f, short_src="?"}
    end
    env.funcinfo = env.getinfo
    env.newlclosure = function(f) return f end

    local _cFuncs = {
        env.getrenv, env.getgenv, env.getreg, env.getregistry,
        env.iscclosure, env.islclosure, env.isourclosure, env.isexecutorclosure,
        env.isfunction, env.isLfunction, env.isCfunction,
        env.getthreadidentity, env.setthreadidentity, env.getidentity,
        env.getthread, env.checkcaller, env.getcallingscript,
        env.hookfunction, env.newcclosure, env.restorefunction, env.hookmetamethod,
        env.setclipboard, env.setrbxclipboard, env.getclipboard,
        env.readfile, env.writefile, env.appendfile, env.makefolder,
        env.delfile, env.delfolder, env.isfile, env.isfolder,
        env.listfiles, env.loadfile,
        env.http_request, env.request, env.httppost, env.httpget, env.httpgetasync,
        env.fireclickdetector, env.fireproximityprompt, env.firetouchinterest,
        env.firehitdetector, env.firesignal, env.firecallback,
        env.gethui, env.gethiddengui, env.protectgui, env.unprotectgui, env.makegui,
        env.queue_on_teleport, env.queueonteleport, env.setfpscap, env.getfpscap,
        env.getstack, env.getparams, env.getupvalues, env.setupvalues,
        env.getupvalue, env.setupvalue, env.getconstants, env.setconstant,
        env.getconstant, env.getprotos, env.getproto, env.getinfo, env.funcinfo,
        env.getrawmetatable, env.setrawmetatable,
        env.getsenv, env.getscriptenv, env.getscriptbytecode,
        env.getscriptclosure, env.decompile,
        env.base64encode, env.base64decode,
        env.crc32, env.md5, env.sha1, env.sha256, env.sha512, env.xxh32, env.xxh64,
        env.cleardrawcache, env.isrenderobj,
        env.mouse1click, env.mouse1press, env.mouse1release,
        env.mouse2click, env.mouse2press, env.mouse2release,
        env.mousemoveabs, env.mousemoverel, env.mousescroll,
        env.keypress, env.keyrelease, env.keyclick,
        env.iskeydown, env.ismousebuttondown,
        env.getmouselocation, env.getmousebutton, env.getmousebuttonspressed,
        env.identifyexecutor, env.getexecutorname, env.getexploitname,
        env.wait, env.delay, env.spawn, env.fastwait, env.fastspawn,
        env.cloneref, env.compareinstances, env.clonefunction,
        env.getcallbackvalue, env.getconnections, env.getcustomasset,
        env.gethiddenproperty, env.sethiddenproperty,
        env.isscriptable, env.setscriptable,
        env.getnamecallmethod, env.setnamecallmethod,
        env.isreadonly, env.setreadonly,
        env.lz4compress, env.lz4decompress,
        env.zstdcompress, env.zstddecompress,
        env.messagebox, env.messageboxasync,
        env.isrbxactive, env.iswindowactive, env.isgameactive,
        env.getrenderproperty, env.setrenderproperty, env.setrenderobj, env.getrenderobj,
        env.getscripthash, env.gethwid, env.getgc, env.filtergc,
        env.getfunctionhash, env.getmenv, env.gettenv, env.getstateenv,
        env.getrenvshared, env.getrenvglobal,
        env.getthreadcontext, env.setthreadcontext, env.getcontext, env.setcontext,
        env.setclosurecaps, env.setclosureidentity, env.getclosurecaps,
        env.saveinstance, env.getobjects, env.setnormalinstance,
        env.getnetworkowner, env.testisnetworkowner, env.isnetworkowner,
        env.replicatesignal, env.cansignalreplicate, env.hooksignal,
        env.issignalhooked, env.restoresignal, env.getsignalarguments,
        env.disableconnection, env.enableconnection, env.isconnectionenabled,
        env.getallreplicatesignals, env.lockassetsignal,
        env.clearteleportqueue, env.clear_teleport_queue,
        env.getcurrentactor, env.getactors, env.getactorfromthread,
        env.runonactor, env.run_on_actor, env.getdeletedactors,
        env.isparallel, env.getthreadscript,
        env.protectfunction, env.protectclosure,
        env.replaceclosure, env.replacefunction, env.replacefunc,
        env.hookfunc, env.detourfunction, env.detour_function,
        env.isfunctionhooked, env.ishooked, env.is_function_hooked,
        env.restorefunc, env.restoreclosure,
        env.protectinstance, env.setsecureinstance, env.issecuredinstance,
        env.createsecurefolder,
        env.makereadonly, env.makewritable,
        env.make_read_only, env.make_writable,
        env.iswriteable, env.iswritable,
        env.dumpstring, env.dumpcodesize,
        env.issynapsefunction, env.is_synapse_function,
        env.iskrnlclosure, env.is_krnl_closure,
        env.isfluxusclosure, env.isfluxusfunction,
        env.is_fluxus_closure, env.is_fluxus_function,
        env.isprotosmasherclosure, env.is_protosmasher_closure,
        env.isourcallstack, env.is_our_closure,
        env.islocalsourcecontainer, env.checkclosure,
        env.validlevel, env.isvalidlevel,
        env.getloadedmodules, env.get_loaded_modules,
        env.getmodules, env.get_modules,
        env.getrunningscripts, env.getscripts, env.get_scripts,
        env.getnilinstances, env.get_nil_instances,
        env.getinstances, env.get_instances,
        env.getscriptfunction, env.get_script_function,
        env.getcallingscript, env.get_calling_script, env.getcaller,
        env.getcommchannel, env.get_comm_channel,
        env.createcommchannel, env.create_comm_channel,
        env.getsynasset, env.writecustomasset,
        env.getfflag, env.setfflag, env.setsimulationradius, env.setstack,
        env.newlclosure,
    }
    for _, f in ipairs(_cFuncs) do
        if type(f) == "function" then
            knownCFunctions[f] = true
        end
    end


    emit = _orig_emit
    _G._envRef = env
    return env
end

local function isGenericVar(name: string): boolean
    return name:match("^v%d+$") ~= nil or name:match("^color%d+$") ~= nil or name:match("^inst%d+$") ~= nil
end

local function deadCodeElimination()
    local result = {}
    for _, line in ipairs(lines) do
        local v = string.match(line, "^local ([%a_][%w_]*%d+) = (.+)$")
        if v and isGenericVar(v) and (usedVars[v] or 0) == 0 then
            local expr = string.match(line, "^local [%a_][%w_]*%d+ = (.+)$")
            if not expr:match("^Color3%.") and not expr:match("^Instance%.new") and not expr:match("^Vector3%.") then
                table.insert(result, expr)
            end
        else
            table.insert(result, line)
        end
    end
    lines = result
end

local function inlineVars()
    if not Settings.inline then return end
    local maxIter = 100
    while maxIter > 0 do
        maxIter -= 1

        local useCount = {}
        local defIdx = {}
        local defExpr = {}
        for i, line in ipairs(lines) do
            local v, expr = string.match(line, "^local ([%a_][%w_]*%d+) = (.+)$")
            if v and isGenericVar(v) then
                defIdx[v] = i
                defExpr[v] = expr
            end
            for var in string.gmatch(line, "[%a_][%w_]*%d+") do
                if var ~= v then
                    useCount[var] = (useCount[var] or 0) + 1
                end
            end
        end

        local bestVar = nil
        local bestIdx = 0
        for v, idx in pairs(defIdx) do
            if (useCount[v] or 0) == 1 and idx > bestIdx then
                local expr = defExpr[v]
                if #expr < 200 and not expr:match("^function") and not expr:match("^%{") then
                    bestVar = v
                    bestIdx = idx
                end
            end
        end

        if not bestVar then break end

        local expr = defExpr[bestVar]
        local pattern = "%f[%w_]" .. bestVar .. "%f[^%w_]"
        local newLines = {}
        for i, line in ipairs(lines) do
            if i == bestIdx then
            else
                table.insert(newLines, (string.gsub(line, pattern, expr)))
            end
        end
        lines = newLines
    end
end

local function beautify()
    if not Settings.beautify then return end
    local result = {}
    local lastLine = nil
    local lastGroup = nil
    for _, line in ipairs(lines) do
        if line ~= lastLine then
            local group = nil
            if line:match(":GetService%(") then group = "service"
            elseif line:match(":Tab%(") then group = "tab"
            elseif line:match(":Section%(") then group = "section"
            elseif line:match(":Connect%(") then group = "connect"
            end
            if group and group ~= lastGroup and #result > 0 then
                table.insert(result, "")
            end
            table.insert(result, line)
            lastLine = line
            if group then lastGroup = group end
        end
    end
    lines = result
end

local DARKLUA_BIN = (process.env.DARKLUA_BIN or "darklua") :: string
local SANDBOX_PRELUDE = table.concat({
    "local io = nil",
    "local dofile = nil",
    "",
}, "\n")

local function isValidIdent(s: string): boolean
    return s ~= "" and s:match("^[%a_][%w_]*$") ~= nil
end

local function splitTableEntries(body: string): { string }
    local entries: { string } = {}
    local depth = 0
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    local startIdx = 1
    local i = 1
    while i <= #body do
        local ch = body:sub(i, i)
        local two = body:sub(i, i + 1)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if body:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then
                i += 2
                continue
            end
            if ch == strDelim then
                inStr = false
            end
            i += 1
            continue
        end
        if two == "[[" or (two == "[" and body:match("^%[=%[", i)) then
            local m = body:match("^%[(=*)%[", i)
            if m then
                inLong = true
                longLevel = #m
                i += 2 + #m
                continue
            end
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        if ch == "{" or ch == "(" or ch == "[" then
            depth += 1
        elseif ch == "}" or ch == ")" or ch == "]" then
            depth -= 1
        elseif ch == "," and depth == 0 then
            local entry = body:sub(startIdx, i - 1)
            entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
            if entry ~= "" then table.insert(entries, entry) end
            startIdx = i + 1
        end
        i += 1
    end
    local last = body:sub(startIdx, #body)
    last = last:gsub("^%s+", ""):gsub("%s+$", "")
    if last ~= "" then table.insert(entries, last) end
    return entries
end

local function findTableBody(s: string, start: number): (number?, number?)
    if s:sub(start, start) ~= "{" then return nil end
    local depth = 1
    local i = start + 1
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    while i <= #s do
        local ch = s:sub(i, i)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if s:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then i += 2; continue end
            if ch == strDelim then inStr = false end
            i += 1
            continue
        end
        local m = s:match("^%[(=*)%[", i)
        if m then
            inLong = true
            longLevel = #m
            i += 2 + #m
            continue
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        if ch == "{" then
            depth += 1
        elseif ch == "}" then
            depth -= 1
            if depth == 0 then return start + 1, i - 1 end
        end
        i += 1
    end
    return nil
end

local function expandTable(body: string, baseIndent: string, parentIndent: string): string
    local entries = splitTableEntries(body)
    if #entries <= 1 then
        if #entries == 0 then
            return "{}"
        end
        return "{ " .. entries[1] .. " }"
    end

    local lines: { string } = {}
    for idx, entry in ipairs(entries) do
        local expanded = entry
        expanded = expanded:gsub("%s*,%s*$", "")
        if idx == #entries then
            table.insert(lines, baseIndent .. expanded)
        else
            table.insert(lines, baseIndent .. expanded .. ",")
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. parentIndent .. "}"
end

local function findEmptyFunction(s: string, start: number): (number?, number?)
    local i = start
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    while i <= #s do
        local ch = s:sub(i, i)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if s:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then i += 2; continue end
            if ch == strDelim then inStr = false end
            i += 1
            continue
        end
        local m = s:match("^%[(=*)%[", i)
        if m then
            inLong = true
            longLevel = #m
            i += 2 + #m
            continue
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        local fStart = s:match("^function%s*%(", i)
        if fStart then
            local parenStart = s:find("(", i, true)
            if parenStart then
                local depth = 1
                local j = parenStart + 1
                while j <= #s and depth > 0 do
                    local c = s:sub(j, j)
                    if c == "(" then depth += 1
                    elseif c == ")" then depth -= 1 end
                    j += 1
                end
                local k = j
                while k <= #s and (s:sub(k, k):match("%s")) do k += 1 end
                if s:sub(k, k + 2) == "end" then
                    local after = s:sub(k + 3, k + 3)
                    if after == "" or not after:match("[%w_]") then
                        return i, k + 2
                    end
                end
            end
        end
        i += 1
    end
    return nil
end

local function leadingIndent(line: string): string
    return line:match("^([\t ]*)") or ""
end

local function beautifyLine(line: string): { string }
    local indent = leadingIndent(line)
    local body = line:sub(#indent + 1)

    local function expandAllTables(s: string): string
        local result = s
        local progress = true
        local guard = 0
        while progress and guard < 50 do
            guard += 1
            progress = false
            local pos = 1
            while pos <= #result do
                local bs = string.find(result, "{", pos, true)
                if not bs then break end
                local bodyStart, bodyEnd = findTableBody(result, bs)
                if bodyStart and bodyEnd then
                    local innerBody = result:sub(bodyStart, bodyEnd)
                    if not innerBody:find("\n", 1, true) then
                        local entries = splitTableEntries(innerBody)
                        if #entries > 1 then
                            local innerExpanded = expandTable(innerBody, indent .. "\t", indent)
                            local before = result:sub(1, bs - 1)
                            local after = result:sub(bodyEnd + 2)
                            result = before .. innerExpanded .. after
                            progress = true
                            pos = #before + #innerExpanded + 1
                            continue
                        end
                    end
                    pos = bs + 1
                else
                    pos = bs + 1
                end
            end
        end
        return result
    end

    body = expandAllTables(body)

    local function expandAllEmptyFunctions(s: string): string
        local result = s
        local guard = 0
        while guard < 50 do
            guard += 1
            local fs, fe = findEmptyFunction(result, 1)
            if not fs then break end
            local fnText = result:sub(fs, fe)
            local params = fnText:match("^function(%s*%b())")
            local replacement = "function" .. (params or "()") .. "\n" .. indent .. "end"
            result = result:sub(1, fs - 1) .. replacement .. result:sub(fe + 1)
        end
        return result
    end

    body = expandAllEmptyFunctions(body)

    local outLines: { string } = {}
    for line2 in body:gmatch("[^\n]*") do
        if line2 ~= "" then
            if #outLines == 0 and line2:sub(1, 1) ~= "\t" and line2:sub(1, 1) ~= " " then
                table.insert(outLines, indent .. line2)
            else
                table.insert(outLines, line2)
            end
        end
    end
    if #outLines == 0 then
        table.insert(outLines, indent .. body)
    elseif outLines[1]:sub(1, #indent) ~= indent and outLines[1]:sub(1, 1) ~= "\t" and outLines[1]:sub(1, 1) ~= " " then
        outLines[1] = indent .. outLines[1]
    end
    return outLines
end

local function iterLines(s: string): () -> string?
    local pos = 1
    local len = #s
    return function(): string?
        if pos > len then return nil end
        local eol = s:find("\n", pos, true) or (len + 1)
        local line = s:sub(pos, eol - 1)
        pos = eol + 1
        return line
    end
end

local function customBeautify(source: string): string
    if not Settings.beautify then return source end
    local output: { string } = {}
    for line in iterLines(source) do
        if line == "" then
            table.insert(output, "")
        else
            local beautified = beautifyLine(line)
            for _, l in ipairs(beautified) do
                table.insert(output, l)
            end
        end
    end
    local collapsed: { string } = {}
    local blankRun = 0
    for _, l in ipairs(output) do
        if l == "" then
            blankRun += 1
            if blankRun <= 1 then table.insert(collapsed, l) end
        else
            blankRun = 0
            table.insert(collapsed, l)
        end
    end
    while #collapsed > 0 and collapsed[#collapsed] == "" do
        table.remove(collapsed, #collapsed)
    end
    return table.concat(collapsed, "\n")
end

local function darkluaBeautify(source: string): string
    return customBeautify(source)
end

local function dump(source: string): string
    lines = {}
    varCount = 0
    usedVars = {}
    for k in pairs(propertyChangeCallbacks) do propertyChangeCallbacks[k] = nil end
    for i = #eventConnections, 1, -1 do eventConnections[i] = nil end
    for k in pairs(instanceTags) do instanceTags[k] = nil end
    for k in pairs(serviceCache) do serviceCache[k] = nil end
    for k in pairs(destroyedInstances) do destroyedInstances[k] = nil end
    for k in pairs(memStorage) do memStorage[k] = nil end
    for k in pairs(parentChildMap) do parentChildMap[k] = nil end
    awakePartsCount = 0
    for k in pairs(unanchoredParts) do unanchoredParts[k] = nil end
    for k in pairs(frozenTables) do frozenTables[k] = nil end
    for k in pairs(readonlyTables) do readonlyTables[k] = nil end
    for k in pairs(functionAddrMap) do functionAddrMap[k] = nil end
    
    emit("")
    local env = createEnv()

    local fn
    local loadOk, loadErr = pcall(function()
        local compiled = luau.compile(SANDBOX_PRELUDE .. source, { optimizationLevel = 2 })
        fn = luau.load(compiled, { debugName = "envlog", environment = env })
    end)
    if not loadOk or not fn then
        emit(string.format("-- Load error: %s", tostring(loadErr):sub(1, 200)))
        return table.concat(lines, "\n")
    end

    local INSN_BUDGET = 80000000
    local insnCount = 0
    local timedOut = false
    local wallLimit = tonumber(Settings.timeout) or 60
    local wallStart = os.clock()

    local ok, err = pcall(fn)
    if not ok then
        local errStr = tostring(err)
        if not errStr:find(BUDGET_ERROR, 1, true) then
            emit(string.format("-- Runtime error: %s", errStr:sub(1, 300)))
        else
            emit(string.format("-- Budget reached after %d instructions / %.2fs", insnCount, os.clock() - wallStart))
        end
    end

    inlineVars()
    deadCodeElimination()
    beautify()
    local raw = table.concat(lines, "\n")
    return darkluaBeautify(raw)
end

if Settings.ipt then
    local ok, err = pcall(function()
        if not fs.isFile(Settings.ipt) then
            error("File not found: " .. Settings.ipt)
        end
    end)
    if not ok then
        stdio.write("Error: " .. tostring(err) .. "\n")
        process.exit(1)
    end
    local source = fs.readFile(Settings.ipt)
    local result = dump(source)
    fs.writeFile(Settings.out, result)
    stdio.write(string.format("Done! Output: %s (%d bytes, %d lines)\n", Settings.out, #result, #lines))
    process.exit(0)
end

while true do
    local input = stdio.readLine()
    if not input or input == "" then break end
    local decoded = serde.decode("json", input)
    local result = dump(decoded.script)
    stdio.write(result)
    stdio.write("\n---END---\n")
end
 
