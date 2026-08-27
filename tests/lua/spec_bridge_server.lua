local function loadBridge(adapters)
    return harness.loadServer({ adapters = adapters or {} })
end

test('detection honours an explicit Config.Framework', function()
    harness.loadConfig()
    Config.Framework = 'esx'
    harness.load('bridge/shared.lua')
    assertEq(DAG.Framework.Detect(), 'esx')
end)

test('detection follows priority order when multiple cores are started', function()
    harness.resourceStates['es_extended'] = 'started'
    harness.resourceStates['qbx_core'] = 'started'
    loadBridge()
    assertEq(DAG.Framework.Detect(), 'qbox', 'qbox outranks esx in the default priority')
end)

test('detection falls back to standalone with no core running', function()
    loadBridge()
    assertEq(DAG.Framework.Detect(), 'standalone')
end)

test('detection is cached and invalidated when a core starts', function()
    loadBridge()
    assertEq(DAG.Framework.Detect(), 'standalone')

    harness.resourceStates['qb-core'] = 'started'
    assertEq(DAG.Framework.Detect(), 'standalone', 'cached until a watched resource changes state')

    TriggerEvent('onResourceStart', 'qb-core')
    assertEq(DAG.Framework.Detect(), 'qb', 'a late-started core is picked up after invalidation')
end)

test('an unrelated resource starting does not invalidate the cache', function()
    loadBridge()
    DAG.Framework.Detect()
    harness.resourceStates['qb-core'] = 'started'
    TriggerEvent('onResourceStart', 'some-map-resource')
    assertEq(DAG.Framework.Detect(), 'standalone')
end)

test('events are namespaced by resource name', function()
    loadBridge()
    assertEq(DAG.Framework.Event('ping'), 'dag-template:dag:ping')
end)

-- The core regression this rewrite exists for: an adapter that cannot report a
-- job must yield nil, not a plausible "unemployed" that a gate might match.
test('an unsupported read returns nil rather than a fabricated value', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})

    assertNil(DAG.Framework.GetJob(1), 'GetJob')
    assertNil(DAG.Framework.GetMoney(1, 'bank'), 'GetMoney')
    assertFalse(DAG.Framework.Supports('getJob'))
    assertTrue(harness.outputContains("has no 'getJob' implementation"))
end)

test('unsupported writes return false', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})
    assertFalse(DAG.Framework.AddMoney(1, 'cash', 10))
    assertFalse(DAG.Framework.RemoveMoney(1, 'cash', 10))
    assertFalse(DAG.Framework.SetDuty(1, true))
    assertFalse(DAG.Framework.CreateUseableItem('water', function() end))
end)

test('the unsupported warning is printed once per method', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})
    for _ = 1, 5 do DAG.Framework.GetJob(1) end

    local count = 0
    for _, line in ipairs(harness.output) do
        if line:find("has no 'getJob'", 1, true) then count = count + 1 end
    end
    assertEq(count, 1)
end)

test('MissingCapabilities lists exactly the unimplemented methods', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', { getJob = function() return { name = 'ems' } end })

    local missing = {}
    for _, method in ipairs(DAG.Framework.MissingCapabilities()) do missing[method] = true end
    assertNil(missing.getJob)
    assertTrue(missing.getMoney == true)
end)

test('identity resolves even when the adapter cannot provide it', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})
    harness.identifiers[7] = 'license:abc'
    harness.names[7] = 'Jean Vale'

    assertEq(DAG.Framework.GetIdentifier(7), 'license:abc')
    assertEq(DAG.Framework.GetName(7), 'Jean Vale')
end)

test('ExtendAdapter adds a capability to a registered adapter', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})
    assertFalse(DAG.Framework.Supports('getMoney'))

    DAG.Framework.ExtendAdapter('standalone', { getMoney = function() return 250 end })
    assertTrue(DAG.Framework.Supports('getMoney'))
    assertEq(DAG.Framework.GetMoney(1, 'cash'), 250)
end)

test('ExtendAdapter rejects non-function members and unknown adapters', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {})
    assertThrows(function() DAG.Framework.ExtendAdapter('standalone', { getMoney = 5 }) end)
    assertThrows(function() DAG.Framework.ExtendAdapter('nope', { getMoney = function() end }) end)
end)

test('NormalizeJob flattens the QB nested grade table', function()
    loadBridge()
    local job = DAG.Framework.NormalizeJob({
        name = 'police', label = 'Police', grade = { level = 3, name = 'sergeant' }, onduty = false
    })
    assertEq(job.grade, 3)
    assertEq(job.gradeName, 'sergeant')
    assertFalse(job.onDuty)
end)

test('NormalizeJob returns nil for a non-table job', function()
    loadBridge()
    assertNil(DAG.Framework.NormalizeJob(nil))
    assertNil(DAG.Framework.NormalizeJob('police'))
end)

local function economyAdapter(state)
    return {
        getMoney = function(_, account) return state[account] end,
        addMoney = function(playerSource, account, amount)
            if state.failFor == playerSource then return false end
            state[account] = state[account] + amount
            return true
        end,
        removeMoney = function(_, account, amount)
            state[account] = state[account] - amount
            return true
        end
    }
end

test('money mutations reject non-positive and non-finite amounts', function()
    loadBridge()
    local state = { cash = 100 }
    DAG.Framework.RegisterAdapter('standalone', economyAdapter(state))

    assertFalse(DAG.Framework.AddMoney(1, 'cash', 0))
    assertFalse(DAG.Framework.AddMoney(1, 'cash', -5))
    assertFalse(DAG.Framework.AddMoney(1, 'cash', 0 / 0))
    assertFalse(DAG.Framework.AddMoney(1, 'cash', math.huge))
    assertFalse(DAG.Framework.AddMoney(1, 'cash', 'ten'))
    assertEq(state.cash, 100, 'balance untouched')
end)

test('RemoveMoney refuses to overdraw', function()
    loadBridge()
    local state = { cash = 40 }
    DAG.Framework.RegisterAdapter('standalone', economyAdapter(state))

    assertFalse(DAG.Framework.RemoveMoney(1, 'cash', 41))
    assertEq(state.cash, 40)
    assertTrue(DAG.Framework.RemoveMoney(1, 'cash', 40))
    assertEq(state.cash, 0)
end)

test('RemoveMoney refuses when the balance is unknown', function()
    loadBridge()
    DAG.Framework.RegisterAdapter('standalone', {
        removeMoney = function() return true end
    })
    assertFalse(DAG.Framework.RemoveMoney(1, 'bank', 10), 'no getMoney means no verifiable balance')
end)

test('TransferMoney refunds the sender when the recipient credit fails', function()
    loadBridge()
    -- The refund path must be reachable: an adapter reporting an unverified
    -- `true` for addMoney was what previously made this dead code on ESX.
    local state = { bank = 500, failFor = 2 }
    DAG.Framework.RegisterAdapter('standalone', economyAdapter(state))

    local moved, reason = DAG.Framework.TransferMoney(1, 2, 'bank', 100, 'test')
    assertFalse(moved)
    assertEq(reason, 'recipient_failed')
    assertEq(state.bank, 500, 'the sender was made whole again')
end)

test('TransferMoney reports refund_failed loudly when compensation fails', function()
    loadBridge()
    local state = { bank = 500 }
    DAG.Framework.RegisterAdapter('standalone', {
        getMoney = function(_, account) return state[account] end,
        addMoney = function() return false end,
        removeMoney = function(_, account, amount) state[account] = state[account] - amount return true end
    })

    local moved, reason = DAG.Framework.TransferMoney(1, 2, 'bank', 100, 'test')
    assertFalse(moved)
    assertEq(reason, 'refund_failed')
    assertTrue(harness.outputContains('CRITICAL'))
end)

test('TransferMoney rejects a self transfer', function()
    loadBridge()
    local moved, reason = DAG.Framework.TransferMoney(1, 1, 'bank', 10, 'test')
    assertFalse(moved)
    assertEq(reason, 'same_player')
end)

test('item amounts must be positive integers', function()
    loadBridge()
    local inventory = { water = 5 }
    DAG.Framework.RegisterAdapter('standalone', {
        getItemCount = function(_, item) return inventory[item] or 0 end,
        addItem = function(_, item, amount) inventory[item] = (inventory[item] or 0) + amount return true end,
        removeItem = function(_, item, amount) inventory[item] = inventory[item] - amount return true end
    })

    assertFalse(DAG.Framework.AddItem(1, 'water', 0.5), 'fractional')
    assertFalse(DAG.Framework.AddItem(1, 'water', -1), 'negative')
    assertFalse(DAG.Framework.AddItem(1, 'water', 0), 'zero')
    assertFalse(DAG.Framework.AddItem(1, 42, 1), 'non-string item')
    assertEq(inventory.water, 5)

    assertTrue(DAG.Framework.AddItem(1, 'water', 2))
    assertEq(inventory.water, 7)
end)

test('RemoveItem refuses to take more than the player holds', function()
    loadBridge()
    local inventory = { water = 2 }
    DAG.Framework.RegisterAdapter('standalone', {
        getItemCount = function(_, item) return inventory[item] or 0 end,
        removeItem = function(_, item, amount) inventory[item] = inventory[item] - amount return true end
    })

    assertFalse(DAG.Framework.RemoveItem(1, 'water', 3))
    assertEq(inventory.water, 2)
    assertTrue(DAG.Framework.RemoveItem(1, 'water', 2))
    assertEq(inventory.water, 0)
end)

test('ox_inventory takes over item calls when it is started', function()
    loadBridge()
    local searched
    harness.resourceStates['ox_inventory'] = 'started'
    harness.exportTargets.ox_inventory = {
        Search = function(_, _, _, item) searched = item return 3 end,
        AddItem = function() return true end,
        RemoveItem = function() return true end
    }

    assertEq(DAG.Framework.InventoryProvider(), 'ox')
    assertEq(DAG.Framework.GetItemCount(1, 'bandage'), 3)
    assertEq(searched, 'bandage')
end)

test("Config.Inventory = 'framework' keeps item calls on the adapter", function()
    loadBridge()
    harness.resourceStates['ox_inventory'] = 'started'
    Config.Inventory = 'framework'
    DAG.Framework.RegisterAdapter('standalone', { getItemCount = function() return 9 end })

    assertEq(DAG.Framework.InventoryProvider(), 'framework')
    assertEq(DAG.Framework.GetItemCount(1, 'bandage'), 9)
end)

test('HasPermission grants the console, honours ACE, then asks the adapter', function()
    loadBridge()
    local asked
    DAG.Framework.RegisterAdapter('standalone', {
        hasPermission = function(_, permission) asked = permission return permission == 'shop.manage' end
    })

    assertTrue(DAG.Framework.HasPermission(0, 'anything'), 'console')

    harness.aceAllowed[3] = { ['dag.admin'] = true }
    assertTrue(DAG.Framework.HasPermission(3, 'dag.admin'), 'ace')

    assertTrue(DAG.Framework.HasPermission(4, 'shop.manage'), 'adapter')
    assertEq(asked, 'shop.manage', 'the requested permission is forwarded, not discarded')
    assertFalse(DAG.Framework.HasPermission(4, 'shop.delete'))
end)

local function callbackEvent()
    return harness.handlers[DAG.Framework.Event('server:callback')][1]
end

test('the callback transport replies to an unknown callback name', function()
    loadBridge()
    _G.source = 5
    callbackEvent()(1, 'nope')
    assertEq(harness.clientEvents[1].args[3], 'unknown_callback')
end)

test('the callback transport ignores malformed client input', function()
    loadBridge()
    _G.source = 5
    callbackEvent()({}, 'name')
    callbackEvent()(1, 42)
    assertEq(#harness.clientEvents, 0)
end)

test('a callback replies at most once', function()
    loadBridge()
    DAG.Framework.RegisterCallback('twice', function(_, reply)
        reply('first')
        reply('second')
    end)

    _G.source = 5
    callbackEvent()(1, 'twice')
    assertEq(#harness.clientEvents, 1)
    assertEq(harness.clientEvents[1].args[2], 'first')
end)

test('an erroring callback still answers the client', function()
    loadBridge()
    DAG.Framework.RegisterCallback('boom', function() error('kaboom') end)

    _G.source = 5
    callbackEvent()(1, 'boom')
    assertEq(harness.clientEvents[1].args[3], 'error')
    assertTrue(harness.outputContains('kaboom'))
end)

test('the callback transport rate limits a flooding client', function()
    loadBridge()
    Config.CallbackRateLimit = { window = 10000, max = 3 }
    DAG.Framework.RegisterCallback('ping', function(_, reply) reply('pong') end)

    _G.source = 5
    local handler = callbackEvent()
    for id = 1, 10 do handler(id, 'ping') end
    assertEq(#harness.clientEvents, 3, 'only the allowance is served')
end)

test('the rate limit window resets', function()
    loadBridge()
    Config.CallbackRateLimit = { window = 1000, max = 2 }
    DAG.Framework.RegisterCallback('ping', function(_, reply) reply('pong') end)

    _G.source = 5
    local handler = callbackEvent()
    handler(1, 'ping')
    handler(2, 'ping')
    handler(3, 'ping')
    assertEq(#harness.clientEvents, 2)

    harness.gameTimer = harness.gameTimer + 1500
    handler(4, 'ping')
    assertEq(#harness.clientEvents, 3)
end)

test('rate limiting is per player', function()
    loadBridge()
    Config.CallbackRateLimit = { window = 10000, max = 1 }
    DAG.Framework.RegisterCallback('ping', function(_, reply) reply('pong') end)
    local handler = callbackEvent()

    _G.source = 5
    handler(1, 'ping')
    handler(2, 'ping')
    _G.source = 6
    handler(3, 'ping')
    assertEq(#harness.clientEvents, 2)
end)

test('a native framework callback transport bypasses the built-in one', function()
    loadBridge()
    local registered
    DAG.Framework.RegisterAdapter('standalone', {
        registerCallback = function(name) registered = name end
    })
    DAG.Framework.RegisterCallback('native', function() end)
    assertEq(registered, 'native')

    _G.source = 5
    callbackEvent()(1, 'native')
    assertEq(harness.clientEvents[1].args[3], 'unknown_callback', 'not stored in the built-in registry')
end)
