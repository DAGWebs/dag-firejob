local function loadClient(adapters)
    return harness.loadClient({ adapters = adapters or { 'standalone' } })
end

test('the standalone client reads the replicated state bag', function()
    loadClient()
    _G.LocalPlayer.state.dagPlayer = { job = { name = 'miner', label = 'Miner', grade = 3 } }

    local job = DAG.Framework.GetJob()
    assertEq(job.name, 'miner')
    assertEq(job.grade, 3)
end)

-- Regression: the client default pointed at a state key nothing ever wrote, so
-- a client-side job check silently failed on standalone.
test('the client job matches what the server replicates', function()
    harness.reset()
    harness.loadServer({ adapters = { 'standalone' } })
    Config.Standalone.defaultJob = { name = 'mechanic', label = 'Mechanic', grade = 1 }
    DAG.Framework.Standalone.reset(1)
    DAG.Framework.GetJob(1)
    local replicated = harness.stateBags[1].dagPlayer

    harness.reset()
    loadClient()
    _G.LocalPlayer.state.dagPlayer = replicated

    assertEq(DAG.Framework.GetJob().name, 'mechanic')
end)

test('GetJob returns nil when nothing has published player data', function()
    loadClient()
    assertNil(DAG.Framework.GetJob())
end)

test('a state bag update raises the normalized lifecycle events', function()
    loadClient()
    local loaded, job
    DAG.Framework.On('playerLoaded', function(data) loaded = data end)
    DAG.Framework.On('jobUpdated', function(value) job = value end)

    TriggerEvent('statebag:dagPlayer', 'player:1', nil, { job = { name = 'ems' } })
    assertEq(loaded.job.name, 'ems')
    assertEq(job.name, 'ems')
end)

test('a state bag update for another player is ignored', function()
    loadClient()
    local fired = false
    DAG.Framework.On('playerLoaded', function() fired = true end)

    TriggerEvent('statebag:dagPlayer', 'player:99', nil, { job = { name = 'ems' } })
    assertFalse(fired)
end)

test('notifications prefer ox_lib when it is running', function()
    loadClient()
    local sent
    harness.resourceStates['ox_lib'] = 'started'
    harness.exportTargets.ox_lib = { notify = function(_, payload) sent = payload end }

    DAG.Framework.Notify('Hello', 'success', 2500)
    assertEq(sent.description, 'Hello')
    assertEq(sent.type, 'success')
    assertEq(sent.duration, 2500)
end)

test("Config.Notify = 'chat' bypasses every provider", function()
    loadClient()
    harness.resourceStates['ox_lib'] = 'started'
    Config.Notify = 'chat'

    DAG.Framework.Notify('Hello')
    assertEq(harness.localEvents[#harness.localEvents].event, 'chat:addMessage')
end)

test('notifications fall back to chat when the adapter has none', function()
    loadClient()
    DAG.Framework.Notify('Hello')
    assertEq(harness.localEvents[#harness.localEvents].event, 'chat:addMessage')
end)

test('the callback transport sends a request and resolves the reply', function()
    loadClient()
    local result
    DAG.Framework.TriggerCallback('getData', function(value) result = value end, 'arg')

    local request = harness.serverEvents[1]
    assertEq(request.event, DAG.Framework.Event('server:callback'))
    assertEq(request.args[2], 'getData')
    assertEq(request.args[3], 'arg')

    TriggerEvent(DAG.Framework.Event('client:callback'), request.args[1], 'payload')
    assertEq(result, 'payload')
end)

test('a callback times out with a reason', function()
    loadClient()
    local result, reason = 'unset', nil
    DAG.Framework.TriggerCallback('getData', function(value, err) result, reason = value, err end)

    harness.flushTimers()
    assertNil(result)
    assertEq(reason, 'timeout')
end)

test('a reply after the timeout is discarded', function()
    loadClient()
    local calls = 0
    DAG.Framework.TriggerCallback('getData', function() calls = calls + 1 end)

    harness.flushTimers()
    TriggerEvent(DAG.Framework.Event('client:callback'), 1, 'late')
    assertEq(calls, 1)
end)

test('the timeout does not fire after a reply arrives', function()
    loadClient()
    local calls = 0
    DAG.Framework.TriggerCallback('getData', function() calls = calls + 1 end)

    TriggerEvent(DAG.Framework.Event('client:callback'), 1, 'payload')
    harness.flushTimers()
    assertEq(calls, 1)
end)

test('a native framework callback transport is used when present', function()
    loadClient()
    local used
    DAG.Framework.RegisterAdapter('standalone', {
        triggerCallback = function(name) used = name end
    })

    DAG.Framework.TriggerCallback('getData', function() end)
    assertEq(used, 'getData')
    assertEq(#harness.serverEvents, 0, 'the built-in transport is not used')
end)

test('callback registration validates its arguments', function()
    loadClient()
    assertThrows(function() DAG.Framework.TriggerCallback(nil, function() end) end)
    assertThrows(function() DAG.Framework.TriggerCallback('name', 'not a function') end)
end)
