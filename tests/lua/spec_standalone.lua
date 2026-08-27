local function loadStandalone()
    return harness.loadServer({ adapters = { 'standalone' } })
end

-- Regression: the adapter used to hand every player the same Config table, so
-- putting one player on duty put the whole server on duty.
test('players do not share a job table', function()
    loadStandalone()
    DAG.Framework.SetDuty(1, true)
    DAG.Framework.SetDuty(2, false)

    assertTrue(DAG.Framework.GetJob(1).onDuty)
    assertFalse(DAG.Framework.GetJob(2).onDuty)
end)

test('the config default job is never mutated', function()
    loadStandalone()
    Config.Standalone.defaultJob.onduty = nil
    DAG.Framework.SetDuty(1, false)

    assertNil(Config.Standalone.defaultJob.onduty, 'config template untouched')
    assertTrue(DAG.Framework.GetJob(2).onDuty, 'a fresh player still defaults to on duty')
end)

test('job values come from the configured default', function()
    harness.loadConfig()
    Config.Standalone.defaultJob = { name = 'miner', label = 'Miner', grade = 2, gradeName = 'foreman' }
    harness.load('bridge/shared.lua')
    harness.load('bridge/server.lua')
    harness.load('bridge/server/standalone.lua')

    local job = DAG.Framework.GetJob(1)
    assertEq(job.name, 'miner')
    assertEq(job.grade, 2)
    assertEq(job.gradeName, 'foreman')
end)

test('player state is replicated for the client adapter to read', function()
    loadStandalone()
    DAG.Framework.SetDuty(4, false)

    local bag = harness.stateBags[4].dagPlayer
    assertEq(bag.job.name, 'unemployed')
    assertFalse(bag.job.onduty)
end)

test('money changes are replicated', function()
    loadStandalone()
    DAG.Framework.AddMoney(2, 'cash', 75)
    assertEq(harness.stateBags[2].dagPlayer.money.cash, 75)
end)

test('the standalone adapter refuses to overdraw', function()
    loadStandalone()
    DAG.Framework.AddMoney(1, 'cash', 50)
    assertFalse(DAG.Framework.RemoveMoney(1, 'cash', 51))
    assertEq(DAG.Framework.GetMoney(1, 'cash'), 50)
end)

test('the standalone adapter refuses to remove items a player lacks', function()
    loadStandalone()
    DAG.Framework.AddItem(1, 'water', 1)
    assertFalse(DAG.Framework.RemoveItem(1, 'water', 2))
    assertEq(DAG.Framework.GetItemCount(1, 'water'), 1)
end)

test('dropping a player clears their in-memory record', function()
    loadStandalone()
    DAG.Framework.AddMoney(9, 'cash', 500)
    assertEq(DAG.Framework.GetMoney(9, 'cash'), 500)

    _G.source = 9
    TriggerEvent('playerDropped')
    assertEq(DAG.Framework.GetMoney(9, 'cash'), 0, 'a reconnecting slot starts fresh')
end)

test('the standalone hook table is exposed for real persistence', function()
    loadStandalone()
    assertTrue(type(DAG.Framework.Standalone.reset) == 'function')
    DAG.Framework.AddMoney(3, 'cash', 10)
    DAG.Framework.Standalone.reset(3)
    assertEq(DAG.Framework.GetMoney(3, 'cash'), 0)
end)
