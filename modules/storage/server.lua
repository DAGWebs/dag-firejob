DAG.Storage = DAG.Storage or {}
local Storage = DAG.Storage
local Bridge = DAG.Framework
local fileName = Config.Storage.file
local collections, dirty = {}, false

-- Native deep copy. The previous json.encode/json.decode round trip cost two
-- full serializations per read and collapsed empty tables into arrays.
local function clone(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for key, inner in pairs(value) do copy[key] = clone(inner, seen) end
    return copy
end

Storage.Clone = clone

local raw = LoadResourceFile(GetCurrentResourceName(), fileName)
if raw and raw ~= '' then
    local success, decoded = pcall(json.decode, raw)
    if success and type(decoded) == 'table' then
        collections = decoded
    else
        Bridge.Print('ignoring invalid storage JSON in %s; starting empty', fileName)
    end
end

local function collection(name)
    assert(type(name) == 'string' and name ~= '', 'Invalid storage collection')
    collections[name] = collections[name] or {}
    return collections[name]
end

function Storage.Get(name, id)
    return clone(collection(name)[tostring(id)])
end

function Storage.All(name)
    return clone(collection(name))
end

function Storage.Set(name, id, value)
    assert(id ~= nil and type(value) == 'table', 'Invalid storage record')
    local stored = clone(value)
    collection(name)[tostring(id)] = stored
    dirty = true
    TriggerEvent(Bridge.Event('recordUpdated'), name, tostring(id), clone(stored))
    return clone(stored)
end

function Storage.Update(name, id, changes)
    assert(type(changes) == 'table', 'Invalid storage changes')
    local record = Storage.Get(name, id) or {}
    for key, value in pairs(changes) do record[key] = value end
    return Storage.Set(name, id, record)
end

function Storage.Delete(name, id)
    local records, key = collection(name), tostring(id)
    if records[key] == nil then return false end
    records[key] = nil
    dirty = true
    TriggerEvent(Bridge.Event('recordDeleted'), name, key)
    return true
end

function Storage.Find(name, predicate)
    assert(type(predicate) == 'function', 'Invalid storage predicate')
    local results = {}
    for id, value in pairs(collection(name)) do
        local candidate = clone(value)
        if predicate(candidate, id) then results[#results + 1] = candidate end
    end
    return results
end

function Storage.Save(force)
    if not dirty and not force then return true end

    -- A record holding a function, cycle, or userdata would otherwise throw
    -- inside the save thread and silently stop every future write.
    local encoded, err = nil, nil
    local ok, result = pcall(json.encode, collections)
    if ok then encoded = result else err = result end

    if type(encoded) ~= 'string' then
        Bridge.Print('failed to encode storage (%s); write skipped, data kept in memory', tostring(err))
        return false
    end

    local success = SaveResourceFile(GetCurrentResourceName(), fileName, encoded, -1)
    if success then
        dirty = false
    else
        Bridge.Print('failed to write %s; retrying on the next interval', fileName)
    end
    return success == true
end

local interval = tonumber(Config.Storage.saveInterval) or 5000
if interval < 1000 then
    Bridge.Print('Config.Storage.saveInterval raised to 1000ms (was %s)', tostring(Config.Storage.saveInterval))
    interval = 1000
end

CreateThread(function()
    while true do
        Wait(interval)
        Storage.Save()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Storage.Save() end
end)

exports('GetStorage', function() return Storage end)
