-- Minimal JSON encoder/decoder standing in for the CFX `json` global so the
-- storage module can be exercised outside FiveM. Not a general-purpose codec.
local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(value)
    return '"' .. value:gsub('[%c"\\]', function(char)
        return escapes[char] or ('\\u%04x'):format(char:byte())
    end) .. '"'
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' then return false end
        count = count + 1
    end
    return count == #value
end

local function encodeValue(value)
    local kind = type(value)
    if value == nil then return 'null' end
    if kind == 'boolean' then return tostring(value) end
    if kind == 'number' then
        assert(value == value and value ~= math.huge and value ~= -math.huge, 'cannot encode non-finite number')
        return (value % 1 == 0) and ('%d'):format(value) or tostring(value)
    end
    if kind == 'string' then return encodeString(value) end
    if kind ~= 'table' then error('cannot encode ' .. kind) end

    local parts = {}
    if isArray(value) then
        for _, item in ipairs(value) do parts[#parts + 1] = encodeValue(item) end
        return '[' .. table.concat(parts, ',') .. ']'
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local raw = value[key] == nil and value[tonumber(key)] or value[key]
        parts[#parts + 1] = encodeString(key) .. ':' .. encodeValue(raw)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

function json.encode(value)
    return encodeValue(value)
end

local decodeValue

local function skip(text, pos)
    local _, stop = text:find('^[ \n\r\t]*', pos)
    return stop + 1
end

local function decodeString(text, pos)
    local out, index = {}, pos + 1
    while true do
        local char = text:sub(index, index)
        assert(char ~= '', 'unterminated string')
        if char == '"' then return table.concat(out), index + 1 end
        if char == '\\' then
            local escape = text:sub(index + 1, index + 1)
            local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if escape == 'u' then
                out[#out + 1] = utf8.char(tonumber(text:sub(index + 2, index + 5), 16))
                index = index + 6
            else
                out[#out + 1] = assert(map[escape], 'bad escape')
                index = index + 2
            end
        else
            out[#out + 1] = char
            index = index + 1
        end
    end
end

function decodeValue(text, pos)
    pos = skip(text, pos)
    local char = text:sub(pos, pos)
    assert(char ~= '', 'unexpected end of input')

    if char == '"' then return decodeString(text, pos) end
    if char == '{' then
        local out = {}
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == '}' then return out, pos + 1 end
        while true do
            local key, value
            key, pos = decodeString(text, skip(text, pos))
            pos = skip(text, pos)
            assert(text:sub(pos, pos) == ':', 'expected :')
            value, pos = decodeValue(text, pos + 1)
            out[key] = value
            pos = skip(text, pos)
            local delimiter = text:sub(pos, pos)
            if delimiter == '}' then return out, pos + 1 end
            assert(delimiter == ',', 'expected , or }')
            pos = pos + 1
        end
    end
    if char == '[' then
        local out = {}
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == ']' then return out, pos + 1 end
        while true do
            local value
            value, pos = decodeValue(text, pos)
            out[#out + 1] = value
            pos = skip(text, pos)
            local delimiter = text:sub(pos, pos)
            if delimiter == ']' then return out, pos + 1 end
            assert(delimiter == ',', 'expected , or ]')
            pos = pos + 1
        end
    end
    if text:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
    if text:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
    if text:sub(pos, pos + 3) == 'null' then return nil, pos + 4 end

    local number, stop = text:match('^(%-?%d+%.?%d*[eE]?[-+]?%d*)()', pos)
    assert(number, 'unexpected token at ' .. pos)
    return tonumber(number), stop
end

function json.decode(text)
    assert(type(text) == 'string', 'json.decode expects a string')
    local value = decodeValue(text, 1)
    return value
end

return json
