-- The in-game configuration editor: the override document, what the commands
-- do to it, removal, and the merge that turns it back into a live config.

local SERVER_FILES = {
    'modules/firefighter/server/database.lua',
    'modules/firefighter/server/editor.lua',
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/jobs.lua',
    'modules/firefighter/server/departments.lua',
    'modules/firefighter/server/billing.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/crew.lua',
    'modules/firefighter/server/mayday.lua',
    'modules/firefighter/server/academy.lua',
    'modules/firefighter/server/events.lua',
    'modules/firefighter/server/mdt.lua',
    'modules/firefighter/server/api.lua'
}

local function loadServer(configure)
    return harness.loadServer({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' },
        modules = { 'storage', 'commands', 'access', 'repository' },
        files = SERVER_FILES,
        configure = configure and function(config)
            configure(config)
            -- Editing the config after it was captured means re-taking the
            -- baseline, exactly as a resource doing this at startup would.
            DAG.Fire.Shared.Rebase()
        end or nil
    })
end

local function admin(source, coords, heading)
    harness.identifiers[source] = ('license:%d'):format(source)
    harness.names[source] = 'Chief'
    harness.aceAllowed[source] = { ['dag-template.admin'] = true }
    local ped = harness.placePlayer(source, coords or vector3(100.0, 200.0, 30.0))
    harness.entityHeadings[ped] = heading or 90.0
    return ped
end

-- Runs the editor command the way a player would type it.
local function set(source, ...)
    local command = harness.commands[DAG.Fire.Shared.Command('editor')]
    command.handler(source, { ... }, '')
end

local function station(id)
    return DAG.Fire.Shared.Station(id)
end

-- The document -----------------------------------------------------------

test('the packaged config is the baseline and is never lost', function()
    loadServer()
    local before = #DAG.Fire.Shared.Stations()

    DAG.Fire.Editor.SetValue('dispatch.maxActive', 7)
    assertEq(Config.Firefighter.dispatch.maxActive, 7)
    assertEq(#DAG.Fire.Shared.Stations(), before, 'everything else survived the merge')

    DAG.Fire.Editor.Reset()
    assertEq(Config.Firefighter.dispatch.maxActive, 2, 'back to what config.lua says')
end)

test('overrides survive a restart', function()
    loadServer()
    DAG.Fire.Editor.SetValue('dispatch.maxActive', 9)
    DAG.Fire.Editor.AddPoint('davis', 'duty', { x = 1.0, y = 2.0, z = 3.0 })

    -- The store is what a restart reads back.
    local stored = DAG.Storage.All('firefighter_config').overrides
    assertEq(stored.values['dispatch.maxActive'], 9)
    assertEq(#stored.stations.davis.duty, 2)
end)

test('a value override only takes a setting that exists', function()
    loadServer()
    local value, err = DAG.Fire.Editor.SetValue('dispatch.notARealSetting', 5)
    assertNil(value)
    assertEq(err, 'unknown_path')
end)

-- Stations ----------------------------------------------------------------

test('a station is created where the admin is standing', function()
    loadServer()
    admin(1, vector3(500.0, 600.0, 40.0))

    set(1, 'fsstation', 'harbour', 'Harbour', 'Station')
    local created = station('harbour')

    assertTrue(created ~= nil)
    assertEq(created.label, 'Harbour Station')
    assertEq(created.coords.x, 500.0)
    assertTrue(created.department ~= nil, 'and it lands in whichever department covers it')
end)

-- The point of the whole exercise: a hall has more than one of everything.
test('a station takes as many of each fixture as you walk to', function()
    loadServer()
    admin(1, vector3(10.0, 0.0, 0.0))
    set(1, 'fsduty', 'davis')

    harness.placePlayer(1, vector3(20.0, 0.0, 0.0))
    set(1, 'fsduty', 'davis')

    local points = DAG.Fire.Shared.Points(station('davis'), 'duty')
    assertEq(#points, 3, 'the packaged one plus the two just placed')
    assertEq(points[2].x, 10.0)
    assertEq(points[3].x, 20.0)
end)

test('every fixture kind can be placed', function()
    loadServer()
    admin(1, vector3(10.0, 0.0, 0.0))

    for _, key in ipairs({ 'fslocker', 'fssupply', 'fsgarage', 'fsoffice', 'fsreturn' }) do
        set(1, key, 'davis')
    end

    local target = station('davis')
    assertEq(#DAG.Fire.Shared.Points(target, 'locker'), 2)
    assertEq(#DAG.Fire.Shared.Points(target, 'supply'), 2)
    assertEq(#DAG.Fire.Shared.Points(target, 'garage'), 2)
    assertEq(#DAG.Fire.Shared.Points(target, 'office'), 2)
    assertEq(#DAG.Fire.Shared.Points(target, 'ret'), 2)
end)

test('an apparatus bay records the direction the admin is facing', function()
    loadServer()
    admin(1, vector3(10.0, 0.0, 0.0), 235.0)
    set(1, 'fsvehiclespawn', 'davis')

    local spawns = DAG.Fire.Shared.SpawnPoints(station('davis'))
    assertEq(#spawns, 2)
    assertEq(spawns[2].heading, 235.0)
    assertEq(spawns[2].coords.x, 10.0)
end)

test('a point can be removed by its number', function()
    loadServer()
    admin(1, vector3(10.0, 0.0, 0.0))
    set(1, 'fsduty', 'davis')
    assertEq(#DAG.Fire.Shared.Points(station('davis'), 'duty'), 2)

    set(1, 'fsremove', 'duty', 'davis', '2')
    local points = DAG.Fire.Shared.Points(station('davis'), 'duty')
    assertEq(#points, 1)
    assertTrue(points[1].x ~= 10.0, 'the right one went')
end)

-- A packaged station comes back from config.lua on every start, so deleting
-- one has to leave a tombstone rather than just dropping the override.
test('a packaged station stays deleted across a reload', function()
    loadServer()
    admin(1)
    set(1, 'fsremove', 'station', 'davis')
    assertNil(station('davis'))

    DAG.Fire.Editor.Apply()
    assertNil(station('davis'), 'still gone after the config was rebuilt')

    local stored = DAG.Storage.All('firefighter_config').overrides
    assertTrue(stored.stations.davis.removed, 'and the tombstone is what does it')
end)

test('a station added in game is deleted outright', function()
    loadServer()
    admin(1)
    set(1, 'fsstation', 'harbour')
    assertTrue(station('harbour') ~= nil)

    set(1, 'fsremove', 'station', 'harbour')
    assertNil(station('harbour'))
    assertNil(DAG.Storage.All('firefighter_config').overrides.stations.harbour)
end)

test('a station can be moved between departments', function()
    loadServer()
    admin(1)
    set(1, 'fsdepartment', 'davis', 'bcfd')
    assertEq(station('davis').department, 'bcfd')

    set(1, 'fsdepartment', 'davis', 'nonsense')
    assertEq(station('davis').department, 'bcfd', 'an unknown department is refused')
end)

-- Departments --------------------------------------------------------------

test('a department can be created, given a job, and given a patch', function()
    loadServer()
    admin(1, vector3(900.0, 900.0, 30.0))

    set(1, 'fsdept', 'lsfd2', 'Second', 'Battalion')
    set(1, 'fsdeptjob', 'lsfd2', 'firejob2')
    set(1, 'fsdeptzone', 'lsfd2', '1500')

    local department = DAG.Fire.Shared.Department('lsfd2')
    assertEq(department.label, 'Second Battalion')
    assertEq(department.job, 'firejob2')
    assertEq(department.jurisdiction.radius, 1500)
    assertEq(DAG.Fire.Shared.DepartmentForCoords({ x = 900.0, y = 900.0, z = 30.0 }).id, 'lsfd2')
end)

test('mutual aid is added between departments and refuses a stranger', function()
    loadServer()
    admin(1)
    set(1, 'fsdeptaid', 'lsfd', 'safd')

    local aid = {}
    for _, entry in ipairs(DAG.Fire.Shared.MutualAid('lsfd')) do aid[entry.id] = true end
    assertTrue(aid.safd)
    assertTrue(aid.bcfd, 'the packaged entry survived')

    local ok = DAG.Fire.Editor.AddMutualAid('lsfd', 'nowhere')
    assertNil(ok)
end)

-- Incident locations --------------------------------------------------------

test('an incident location is added and removed where you stand', function()
    loadServer()
    admin(1, vector3(700.0, 700.0, 25.0))

    local before = #DAG.Fire.Shared.CallType('structure').locations
    set(1, 'fscall', 'structure', 'The', 'old', 'mill')

    local locations = DAG.Fire.Shared.CallType('structure').locations
    assertEq(#locations, before + 1)
    assertEq(locations[#locations].label, 'The old mill')
    assertEq(locations[#locations].coords.x, 700.0)

    set(1, 'fsremove', 'call', 'structure', tostring(#locations))
    assertEq(#DAG.Fire.Shared.CallType('structure').locations, before)
end)

-- The dispatcher has to draw from the edited list, not the packaged one.
test('a call dispatched after an edit uses the new location', function()
    loadServer()
    admin(1, vector3(700.0, 700.0, 25.0))

    -- Leave exactly one location on the type, and make it the new one.
    local packaged = #DAG.Fire.Shared.CallType('vehicle').locations
    for _ = 1, packaged do set(1, 'fsremove', 'call', 'vehicle', '1') end
    set(1, 'fscall', 'vehicle', 'The old mill')

    DAG.Fire.Dispatch.random = function(minimum) return math.floor(minimum or 0) end
    local call = DAG.Fire.Dispatch.Create('vehicle', { force = true })
    assertEq(call.location, 'The old mill')
    assertEq(call.coords.x, 700.0)
end)

-- Settings ------------------------------------------------------------------

test('any setting is reachable by its path, and typed correctly', function()
    loadServer()
    admin(1)

    set(1, 'fsconfig', 'dispatch.maxActive', '6')
    assertEq(Config.Firefighter.dispatch.maxActive, 6, 'a number, not the string "6"')

    set(1, 'fsconfig', 'enforceCertifications', 'false')
    assertFalse(Config.Firefighter.enforceCertifications)

    set(1, 'fsconfig', 'fire.spreadChance', '0.5')
    assertEq(Config.Firefighter.fire.spreadChance, 0.5)
end)

test('a setting reverts to the packaged default when the override is removed', function()
    loadServer()
    admin(1)
    set(1, 'fsconfig', 'dispatch.maxActive', '6')
    set(1, 'fsremove', 'config', 'dispatch.maxActive')

    assertEq(Config.Firefighter.dispatch.maxActive, 2)
end)

test('an edited setting is what the job actually reads', function()
    loadServer()
    admin(1)
    assertEq(DAG.Fire.Shared.MaxActiveCalls(0), 2)

    set(1, 'fsconfig', 'dispatch.maxActive', '6')
    assertEq(DAG.Fire.Shared.MaxActiveCalls(0), 6)
end)

-- Authorization and delivery --------------------------------------------------

test('only an admin can edit the configuration', function()
    loadServer()
    harness.identifiers[2] = 'license:2'
    harness.placePlayer(2, vector3(10.0, 0.0, 0.0))

    set(2, 'fsstation', 'harbour')
    assertNil(station('harbour'))
end)

test('every edit is pushed to the clients', function()
    loadServer()
    admin(1)
    harness.clientEvents = {}
    set(1, 'fsduty', 'davis')

    local pushed
    for _, entry in ipairs(harness.clientEvents) do
        if entry.event == DAG.Framework.Event('fire:config') then pushed = entry end
    end
    assertTrue(pushed ~= nil)
    assertEq(pushed.target, -1, 'to everyone, not just the roster')
    assertEq(#pushed.args[1].stations.davis.duty, 2)
end)

test('a client asking for the document gets the current one', function()
    loadServer()
    admin(1)
    set(1, 'fsconfig', 'dispatch.maxActive', '4')
    harness.clientEvents = {}

    _G.source = 5
    TriggerEvent(DAG.Framework.Event('fire:requestConfig'))
    _G.source = nil

    assertEq(harness.clientEvents[1].target, 5)
    assertEq(harness.clientEvents[1].args[1].values['dispatch.maxActive'], 4)
end)

test('the menu drives the same edits as the commands', function()
    loadServer()
    admin(1, vector3(42.0, 0.0, 0.0))

    _G.source = 1
    TriggerEvent(DAG.Framework.Event('fire:editor'), 'addPoint', { station = 'davis', kind = 'garage' })
    _G.source = nil

    local points = DAG.Fire.Shared.Points(station('davis'), 'garage')
    assertEq(#points, 2)
    assertEq(points[2].x, 42.0)
end)

test('the menu refuses an edit from somebody who is not an admin', function()
    loadServer()
    harness.identifiers[2] = 'license:2'
    harness.placePlayer(2, vector3(42.0, 0.0, 0.0))

    _G.source = 2
    TriggerEvent(DAG.Framework.Event('fire:editor'), 'addPoint', { station = 'davis', kind = 'garage' })
    _G.source = nil

    assertEq(#DAG.Fire.Shared.Points(station('davis'), 'garage'), 1)
end)

test('listing a station names every point with its number', function()
    loadServer()
    admin(1, vector3(10.0, 0.0, 0.0))
    set(1, 'fsduty', 'davis')

    local lines = DAG.Fire.Editor.Describe('station', 'davis')
    local text = table.concat(lines, '\n')
    assertTrue(text:find('duty 1', 1, true) ~= nil)
    assertTrue(text:find('duty 2', 1, true) ~= nil)
    assertTrue(text:find('spawn 1', 1, true) ~= nil)
end)

-- Commands and keys ---------------------------------------------------------

-- A busy server already has something on the obvious names and keys, so every
-- one of them has to be movable or switchable off.
test('a command the server renamed is registered under the new name', function()
    loadServer(function(config) config.Firefighter.commands.editor = 'fdconfig' end)
    assertNil(harness.commands.set, 'the default name was not taken')
    assertTrue(harness.commands.fdconfig ~= nil)
end)

test('a command the server switched off is not registered at all', function()
    loadServer(function(config) config.Firefighter.commands.editor = false end)
    assertNil(harness.commands.set)
    assertNil(DAG.Fire.Shared.Command('editor'))
end)

test('every command the job registers is named in config', function()
    loadServer()
    local Shared = DAG.Fire.Shared

    for _, key in ipairs({ 'duty', 'roster', 'emergency', 'dispatch', 'clear',
        'hire', 'dismiss', 'rank', 'certify', 'experience' }) do
        local name = Shared.Command(key)
        assertTrue(name ~= nil, key .. ' has a name')
        assertTrue(harness.commands[name] ~= nil, key .. ' is registered under it')
    end
end)

test('a keybind is optional and defaults away from the ones servers already use', function()
    loadServer()
    local Shared = DAG.Fire.Shared

    assertEq(Shared.Keybind('menu'), 'F6')
    assertNil(Shared.Keybind('mdt'), 'the terminal ships unbound')

    Config.Firefighter.keybinds.menu = false
    assertNil(Shared.Keybind('menu'))
end)
