local Bridge = DAG.Framework
local adapters, registeredCallbacks = {}, {}
local warned = {}

-- Methods a framework adapter may implement. An adapter that omits one is
-- reported as not supporting it; the bridge never substitutes a made-up value.
local METHODS = {
    'getPlayer', 'getIdentifier', 'getName', 'getJob', 'getMoney', 'addMoney',
    'removeMoney', 'getItemCount', 'addItem', 'removeItem', 'hasPermission',
    'setDuty', 'createUseableItem', 'registerCallback'
}

local function finiteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function positiveAmount(value)
    return finiteNumber(value) and value > 0
end

local function positiveInteger(value)
    return positiveAmount(value) and value % 1 == 0
end

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

-- Returns the adapter methods the active framework does NOT implement, so a
-- resource can fail loudly at startup instead of mid-transaction.
function Bridge.MissingCapabilities()
    local missing = {}
    for _, method in ipairs(METHODS) do
        if not Bridge.Supports(method) then missing[#missing + 1] = method end
    end
    return missing
end

-- Calls an adapter method, or returns nil (once-per-method warning) when the
-- active framework has no implementation for it.
local function call(method, ...)
    local active, name = adapter()
    local fn = active and active[method]
    if type(fn) ~= 'function' then
        local key = name .. ':' .. method
        if not warned[key] then
            warned[key] = true
            Bridge.Print("framework '%s' has no '%s' implementation; callers receive nil/false", name, method)
        end
        return nil
    end
    return fn(...)
end

function Bridge.GetPlayer(source) return call('getPlayer', source) end

-- Identity always resolves: the engine provides a usable fallback on every
-- framework, so these two are the only methods with a built-in default.
function Bridge.GetIdentifier(source)
    return call('getIdentifier', source)
        or GetPlayerIdentifierByType(source, 'license')
        or GetPlayerIdentifiers(source)[1]
end

function Bridge.GetName(source)
    return call('getName', source) or GetPlayerName(source)
end

-- Returns nil when the framework cannot report jobs. Callers gating on a job
-- must treat nil as "deny", not as "unemployed".
function Bridge.GetJob(source)
    return Bridge.NormalizeJob(call('getJob', source))
end

-- Returns nil when the framework has no money implementation.
function Bridge.GetMoney(source, account)
    local balance = call('getMoney', source, account or 'cash')
    return finiteNumber(balance) and balance or nil
end

function Bridge.AddMoney(source, account, amount, reason)
    if not positiveAmount(amount) then return false end
    return call('addMoney', source, account or 'cash', amount, reason) == true
end

function Bridge.RemoveMoney(source, account, amount, reason)
    account = account or 'cash'
    if not positiveAmount(amount) then return false end
    local balance = Bridge.GetMoney(source, account)
    if not balance or balance < amount then return false end
    return call('removeMoney', source, account, amount, reason) == true
end

-- Best-effort framework transfer with compensation. This is convenient for
-- ordinary gameplay, but it is not a substitute for a database transaction:
-- the refund itself can fail, which is why it is logged rather than swallowed.
function Bridge.TransferMoney(fromSource, toSource, account, amount, reason)
    if fromSource == toSource then return false, 'same_player' end
    if not Bridge.RemoveMoney(fromSource, account, amount, reason) then return false, 'insufficient_funds' end
    if Bridge.AddMoney(toSource, account, amount, reason) then return true end

    if not Bridge.AddMoney(fromSource, account, amount, ('rollback:%s'):format(reason or 'transfer')) then
        Bridge.Print('CRITICAL: failed to refund %s %s to %s after a failed transfer', amount, account, tostring(fromSource))
        return false, 'refund_failed'
    end
    return false, 'recipient_failed'
end

local function useOxInventory()
    return Config.Inventory ~= 'framework' and GetResourceState('ox_inventory') == 'started'
end

-- 'ox' when item calls are routed to ox_inventory directly, otherwise
-- 'framework'. Note that on Qbox and Ox Core the framework-native inventory
-- IS ox_inventory, so both values behave identically there.
function Bridge.InventoryProvider()
    return useOxInventory() and 'ox' or 'framework'
end

function Bridge.GetItemCount(source, item, metadata)
    if type(item) ~= 'string' then return 0 end
    if useOxInventory() then return exports.ox_inventory:Search(source, 'count', item, metadata) or 0 end
    local count = call('getItemCount', source, item, metadata)
    return finiteNumber(count) and count or 0
end

function Bridge.HasItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    return Bridge.GetItemCount(source, item, metadata) >= amount
end

function Bridge.AddItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    if useOxInventory() then return exports.ox_inventory:AddItem(source, item, amount, metadata) == true end
    return call('addItem', source, item, amount, metadata) == true
end

function Bridge.RemoveItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    -- Single count lookup shared by the guard and the ox path below.
    if Bridge.GetItemCount(source, item, metadata) < amount then return false end
    if useOxInventory() then return exports.ox_inventory:RemoveItem(source, item, amount, metadata) == true end
    return call('removeItem', source, item, amount, metadata) == true
end

function Bridge.Notify(source, message, kind, duration)
    TriggerClientEvent(Bridge.Event('client:notify'), source, message, kind, duration)
end

function Bridge.HasPermission(source, permission)
    permission = permission or 'dag.admin'
    if source == 0 then return true end
    if IsPlayerAceAllowed(source, permission) then return true end
    return call('hasPermission', source, permission) == true
end

function Bridge.SetDuty(source, onDuty)
    if type(onDuty) ~= 'boolean' then return false end
    return call('setDuty', source, onDuty) == true
end

function Bridge.CreateUseableItem(item, callback)
    assert(type(item) == 'string' and type(callback) == 'function', 'Invalid useable item')
    return call('createUseableItem', item, callback) == true
end

function Bridge.RegisterCallback(name, callback)
    assert(type(name) == 'string' and type(callback) == 'function', 'Invalid callback registration')
    if Bridge.Supports('registerCallback') then return call('registerCallback', name, callback) end
    registeredCallbacks[name] = callback
end

-- Per-source token bucket for the built-in callback transport. Without this a
-- single client can drive unbounded server work by spamming one net event.
local buckets = {}
local function rateLimited(playerSource)
    local limit = Config.CallbackRateLimit
    if not limit or not positiveInteger(limit.max) then return false end

    local now = GetGameTimer()
    local bucket = buckets[playerSource]
    if not bucket or now - bucket.start >= limit.window then
        buckets[playerSource] = { start = now, count = 1 }
        return false
    end

    bucket.count = bucket.count + 1
    if bucket.count <= limit.max then return false end
    if bucket.count == limit.max + 1 then
        Bridge.Debug('rate limited callback flood from %s', tostring(playerSource))
    end
    return true
end

AddEventHandler('playerDropped', function()
    buckets[source] = nil
end)

RegisterNetEvent(Bridge.Event('server:callback'), function(id, name, ...)
    local playerSource = source
    -- Everything below the transport is client-controlled and must be validated.
    if type(id) ~= 'number' or type(name) ~= 'string' then return end
    if rateLimited(playerSource) then return end

    local callback = registeredCallbacks[name]
    if not callback then
        return TriggerClientEvent(Bridge.Event('client:callback'), playerSource, id, nil, 'unknown_callback')
    end

    local answered = false
    local function reply(...)
        if answered then return end
        answered = true
        TriggerClientEvent(Bridge.Event('client:callback'), playerSource, id, ...)
    end

    local ok, err = pcall(callback, playerSource, reply, ...)
    if not ok then
        Bridge.Print("callback '%s' errored: %s", name, tostring(err))
        reply(nil, 'error')
    end
end)

exports('GetFrameworkBridge', function() return Bridge end)
