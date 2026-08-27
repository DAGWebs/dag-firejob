local Bridge = DAG.Framework
local adapters, callbacks, callbackId = {}, {}, 0
local warned = {}

local METHODS = { 'getPlayerData', 'notify', 'triggerCallback' }

function Bridge.RegisterAdapter(name, adapter)
    assert(type(name) == 'string' and type(adapter) == 'table', 'Invalid framework adapter')
    for method in pairs(adapter) do
        assert(type(adapter[method]) == 'function', ('Adapter "%s" method "%s" must be a function'):format(name, method))
    end
    adapters[name] = adapter
end

-- Merges extra methods into an already-registered adapter. This is the
-- supported way to teach the bridge about a fork's APIs (vRP especially)
-- from your own resource, without editing the bundled adapter files.
function Bridge.ExtendAdapter(name, methods)
    assert(type(name) == 'string' and type(methods) == 'table', 'Invalid adapter extension')
    local target = adapters[name]
    assert(target, ('No adapter registered for "%s"'):format(name))
    for method, fn in pairs(methods) do
        assert(type(fn) == 'function', ('Adapter "%s" method "%s" must be a function'):format(name, method))
        target[method] = fn
    end
    return target
end

local function adapter()
    local name = Bridge.Detect()
    return adapters[name], name
end

function Bridge.Supports(method)
    local active = adapter()
    return active ~= nil and type(active[method]) == 'function'
end

function Bridge.MissingCapabilities()
    local missing = {}
    for _, method in ipairs(METHODS) do
        if not Bridge.Supports(method) then missing[#missing + 1] = method end
    end
    return missing
end

local function call(method, ...)
    local active, name = adapter()
    local fn = active and active[method]
    if type(fn) ~= 'function' then
        local key = name .. ':' .. method
        if not warned[key] then
            warned[key] = true
            Bridge.Print("framework '%s' has no client '%s' implementation", name, method)
        end
        return nil
    end
    return fn(...)
end

-- Frameworks without a client player object fall back to the replicated state
-- bag the server-side adapter publishes (see bridge/server/standalone.lua).
function Bridge.GetPlayerData()
    local data = call('getPlayerData')
    if type(data) == 'table' then return data end
    return LocalPlayer.state.dagPlayer or {}
end

-- Returns nil when no job information is available, mirroring the server API.
-- Client-side job checks are convenience only; authorize on the server.
function Bridge.GetJob()
    return Bridge.NormalizeJob(Bridge.GetPlayerData().job)
end

local function chatNotify(message)
    TriggerEvent('chat:addMessage', { args = { 'SYSTEM', message } })
end

function Bridge.Notify(message, kind, duration)
    kind, duration = kind or 'inform', duration or 5000
    if Config.Notify == 'chat' then return chatNotify(message) end

    if (Config.Notify == 'auto' or Config.Notify == 'ox') and GetResourceState('ox_lib') == 'started' then
        return exports.ox_lib:notify({ description = message, type = kind, duration = duration })
    end

    if Bridge.Supports('notify') then return call('notify', message, kind, duration) end
    chatNotify(message)
end

function Bridge.TriggerCallback(name, callback, ...)
    assert(type(name) == 'string' and type(callback) == 'function', 'Invalid callback request')
    if Bridge.Supports('triggerCallback') then return call('triggerCallback', name, callback, ...) end

    callbackId = callbackId + 1
    local pendingId = callbackId
    callbacks[pendingId] = callback
    TriggerServerEvent(Bridge.Event('server:callback'), pendingId, name, ...)

    SetTimeout(Config.CallbackTimeout, function()
        if not callbacks[pendingId] then return end
        callbacks[pendingId] = nil
        callback(nil, 'timeout')
    end)
end

RegisterNetEvent(Bridge.Event('client:callback'), function(id, ...)
    local callback = callbacks[id]
    if not callback then return end
    callbacks[id] = nil
    callback(...)
end)

exports('GetFrameworkBridge', function() return Bridge end)
