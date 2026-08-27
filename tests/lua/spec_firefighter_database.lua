-- Persistence: driver detection, the schema, and the write-behind profile
-- cache that keeps every gameplay read synchronous.

local SERVER_FILES = {
    'modules/firefighter/server/database.lua',
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/jobs.lua',
    'modules/firefighter/server/departments.lua',
    'modules/firefighter/server/billing.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/crew.lua',
    'modules/firefighter/server/academy.lua',
    'modules/firefighter/server/events.lua',
    'modules/firefighter/server/mdt.lua',
    'modules/firefighter/server/api.lua'
}

-- A stand-in for oxmysql. Exports are called with `:` so every handler takes
-- the export table as its first argument, exactly as the real one does.
local function stubOxmysql(rows)
    local log = { queries = {}, executes = {}, inserts = {} }
    harness.resourceStates.oxmysql = 'started'
    harness.exportTargets.oxmysql = {
        query = function(_, query, params, callback)
            table.insert(log.queries, { query = query, params = params })
            if callback then callback(rows or {}) end
        end,
        update = function(_, query, params, callback)
            table.insert(log.executes, { query = query, params = params })
            if callback then callback(1) end
        end,
        insert = function(_, query, params, callback)
            table.insert(log.inserts, { query = query, params = params })
            if callback then callback(1) end
        end
    }
    return log
end

local function loadServer()
    return harness.loadServer({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' },
        modules = { 'storage', 'commands', 'access', 'repository' },
        files = SERVER_FILES
    })
end

local function contains(log, needle)
    for _, entry in ipairs(log) do
        if entry.query:find(needle, 1, true) then return entry end
    end
    return nil
end

-- Detection ------------------------------------------------------------------

test('no driver means the JSON store, not a broken job', function()
    loadServer()
    DAG.Fire.Database.Detect()

    assertFalse(DAG.Fire.Database.Available())
    assertNil(DAG.Fire.Database.Driver())

    -- And a query is a no-op that reports failure rather than throwing.
    local answered = 'untouched'
    assertFalse(DAG.Fire.Database.Query('SELECT 1', {}, function(rows) answered = rows end))
    assertNil(answered)
end)

test('oxmysql is detected when it is running', function()
    stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()

    assertTrue(DAG.Fire.Database.Available())
    assertEq(DAG.Fire.Database.Driver(), 'oxmysql')
end)

test('a driver can be pinned in config', function()
    stubOxmysql()
    loadServer()
    Config.Firefighter.database.driver = 'mysql-async'
    DAG.Fire.Database.Detect()

    assertFalse(DAG.Fire.Database.Available(), 'oxmysql is running but was not the one asked for')
end)

test('persistence can be switched off entirely', function()
    stubOxmysql()
    loadServer()
    Config.Firefighter.database.enabled = false
    DAG.Fire.Database.Detect()

    assertFalse(DAG.Fire.Database.Available())
end)

-- Schema ---------------------------------------------------------------------

test('the schema covers every table the job writes to', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()
    DAG.Fire.Database.Migrate()

    assertEq(#log.executes, 6)
    assertTrue(contains(log.executes, 'firefighter_profiles') ~= nil)
    assertTrue(contains(log.executes, 'firefighter_employment') ~= nil)
    assertTrue(contains(log.executes, 'firefighter_training') ~= nil)
    assertTrue(contains(log.executes, 'firefighter_calls') ~= nil)
    assertTrue(contains(log.executes, 'firefighter_invoices') ~= nil)
    assertTrue(contains(log.executes, 'firefighter_reports') ~= nil)
end)

test('the table prefix is respected', function()
    local log = stubOxmysql()
    loadServer()
    Config.Firefighter.database.prefix = 'fd_'
    DAG.Fire.Database.Detect()
    DAG.Fire.Database.Migrate()

    assertEq(DAG.Fire.Database.Table('profiles'), 'fd_profiles')
    assertTrue(contains(log.executes, 'CREATE TABLE IF NOT EXISTS `fd_profiles`') ~= nil)
end)

test('migrating twice does not run the schema twice', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()
    DAG.Fire.Database.Migrate()
    DAG.Fire.Database.Migrate()

    assertEq(#log.executes, 6)
end)

-- Profiles --------------------------------------------------------------------

test('a profile is written behind rather than on the gameplay path', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()

    local profile = DAG.Fire.Shared.NormalizeProfile({ xp = 1200 }, 'license:a', 'Dana Reyes')
    DAG.Fire.State.SaveProfile(profile)
    assertEq(#log.executes, 0, 'nothing hit the database yet')

    assertEq(DAG.Fire.State.FlushProfiles(), 1)
    local write = contains(log.executes, 'INSERT INTO `firefighter_profiles`')
    assertTrue(write ~= nil)
    assertEq(write.params[1], 'license:a')
    assertEq(write.params[4], 1200, 'the XP total')
    assertTrue(write.query:find('ON DUPLICATE KEY UPDATE', 1, true) ~= nil, 'an upsert, not a duplicate row')
end)

test('flushing twice only writes what changed', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()

    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 10 }, 'license:a', 'Dana'))
    DAG.Fire.State.FlushProfiles()
    assertEq(DAG.Fire.State.FlushProfiles(), 0)
    assertEq(#log.executes, 1)
end)

test('a stored row comes back as a complete profile', function()
    stubOxmysql({
        {
            identifier = 'license:a',
            name = 'Dana Reyes',
            department = 'safd',
            xp = 3000,
            certifications = json.encode({ 'ems', 'rescue' }),
            training = json.encode({ ems = 1234 }),
            stats = json.encode({ calls = 12, victimsRescued = 4 }),
            hired_at = 1700000000
        }
    })
    loadServer()
    DAG.Fire.Database.Detect()

    local loaded
    DAG.Fire.State.LoadProfile('license:a', 'Dana Reyes', function(profile) loaded = profile end)

    assertEq(loaded.xp, 3000)
    assertEq(loaded.department, 'safd')
    assertEq(#loaded.certifications, 2)
    assertEq(loaded.stats.calls, 12)
    assertEq(loaded.training.ems, 1234)
    assertEq(DAG.Fire.Shared.RankLabel(loaded.xp), 'Engineer')

    -- And it is cached, so the synchronous read every gameplay path uses hits.
    assertEq(DAG.Fire.State.ProfileFor('license:a').xp, 3000)
end)

test('a firefighter with no row starts a fresh career rather than an error', function()
    stubOxmysql({})
    loadServer()
    DAG.Fire.Database.Detect()

    local loaded
    DAG.Fire.State.LoadProfile('license:new', 'Newcomer', function(profile) loaded = profile end)
    assertEq(loaded.xp, 0)
    assertEq(loaded.identifier, 'license:new')
end)

-- Leaving the cache dirty on disconnect would lose the shift, so dropping a
-- cached profile writes it out first.
test('dropping a cached profile flushes it on the way out', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()

    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 99 }, 'license:a', 'Dana'))
    DAG.Fire.State.DropCachedProfile('license:a')
    assertEq(#log.executes, 1)
end)

test('the leaderboard reads from the database when there is one', function()
    local log = stubOxmysql({
        { identifier = 'license:b', name = 'Blake', xp = 900, stats = json.encode({ calls = 3 }) },
        { identifier = 'license:a', name = 'Ari', xp = 100, stats = json.encode({ calls = 1 }) }
    })
    loadServer()
    DAG.Fire.Database.Detect()

    local board
    DAG.Fire.Progression.Leaderboard(5, function(result) board = result end)

    assertEq(#board, 2)
    assertEq(board[1].name, 'Blake')
    assertTrue(contains(log.queries, 'ORDER BY `xp` DESC') ~= nil)
end)

-- Call log ---------------------------------------------------------------------

test('a closed call is logged with what happened on it', function()
    local log = stubOxmysql()
    loadServer()
    DAG.Fire.Database.Detect()

    harness.identifiers[1] = 'license:1'
    harness.placePlayer(1, vector3(0.0, 0.0, 0.0))
    DAG.Fire.State.GoOnDuty(1, DAG.Fire.Shared.Stations()[1])

    local call = DAG.Fire.Dispatch.Create('alarm', { department = 'lsfd', force = true })
    DAG.Fire.Dispatch.Join(1, call.id)
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    local logged = contains(log.executes, 'INSERT INTO `firefighter_calls`')
    assertTrue(logged ~= nil)
    assertEq(logged.params[1], call.id)
    assertEq(logged.params[2], 'lsfd')
    assertEq(logged.params[3], 'alarm')
end)
