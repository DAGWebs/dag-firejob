-- Client-side firefighter behaviour: what the mirror of dispatch does with the
-- events it receives, which client renders the fire, and what the hose is
-- allowed to point at.

local CLIENT_FILES = {
    'modules/firefighter/client/state.lua',
    'modules/firefighter/client/fire.lua',
    'modules/firefighter/client/hose.lua',
    'modules/firefighter/client/rescue.lua',
    'modules/firefighter/client/uniform.lua',
    'modules/firefighter/client/events.lua',
    'modules/firefighter/client/duty.lua',
    'modules/firefighter/client/academy.lua',
    'modules/firefighter/client/hud.lua',
    'modules/firefighter/client/menus.lua'
}

local function loadClient()
    return harness.loadClient({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' },
        modules = { 'menu', 'interactions' },
        files = CLIENT_FILES
    })
end

-- One pass of every registered thread. Loops unwind on their first Wait().
local function runAllThreads()
    for _, thread in ipairs(harness.threads) do harness.runThread(thread, 0) end
end

local function fire(name, ...)
    TriggerEvent(DAG.Framework.Event(name), ...)
end

local function callPayload(overrides)
    local call = {
        id = 'FD-0001',
        kind = 'structure',
        label = 'Structure fire',
        location = 'Grove Street apartments',
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        radius = 9.0,
        priority = 1,
        state = 'working',
        severity = 0.8,
        owner = 1,
        responders = {},
        victims = {},
        hazards = {},
        fires = {
            n1 = { id = 'n1', coords = { x = 2.0, y = 0.0, z = 0.0 }, intensity = 80 },
            n2 = { id = 'n2', coords = { x = 4.0, y = 0.0, z = 0.0 }, intensity = 40 }
        }
    }
    for key, value in pairs(overrides or {}) do call[key] = value end
    return call
end

local function goOnDuty(extra)
    local payload = { station = 'davis', department = 'lsfd', since = 0, air = 1500, extinguisher = 220 }
    for key, value in pairs(extra or {}) do payload[key] = value end
    fire('fire:duty', payload)
end

-- The server is what says a line has been pulled off a pump; the client only
-- draws it, so tests hand the duty payload the same flag the server would.
local function withLine()
    goOnDuty({ hose = { unit = 1, netId = 901 } })
end

-- Mirror --------------------------------------------------------------------

test('a sync replaces the board and puts a blip on every call', function()
    loadClient()
    fire('fire:sync', { callPayload(), callPayload({ id = 'FD-0002' }) })

    assertEq(#DAG.Fire.Client.SortedCalls(), 2)
    assertEq(harness.count(harness.blips), 2)

    fire('fire:sync', { callPayload() })
    assertEq(#DAG.Fire.Client.SortedCalls(), 1)
    assertEq(harness.count(harness.blips), 1, 'the stale blip was removed')
end)

test('a node update that reports nothing left removes the node', function()
    loadClient()
    fire('fire:sync', { callPayload() })

    fire('fire:node', 'FD-0001', { id = 'n1', intensity = 10, heat = 18 })
    assertEq(DAG.Fire.Client.Call('FD-0001').fires.n1.intensity, 10)

    fire('fire:node', 'FD-0001', { id = 'n1', intensity = 0, heat = 0 })
    assertNil(DAG.Fire.Client.Call('FD-0001').fires.n1)
    assertTrue(DAG.Fire.Client.Call('FD-0001').fires.n2 ~= nil, 'the other seat is untouched')
end)

test('clocking off clears the board and the blips', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload() })
    assertTrue(DAG.Fire.Client.OnDuty())

    fire('fire:duty', false)
    assertFalse(DAG.Fire.Client.OnDuty())
    assertEq(#DAG.Fire.Client.SortedCalls(), 0)
    assertEq(harness.count(harness.blips), 0)
end)

test('the assigned call is the only one the GPS routes to', function()
    loadClient()
    fire('fire:sync', { callPayload(), callPayload({ id = 'FD-0002' }) })
    fire('fire:duty', { station = 'davis', since = 0, callId = 'FD-0002', air = 1500 })

    local routed = 0
    for _, blip in pairs(harness.blips) do
        if blip.route then routed = routed + 1 end
    end
    assertEq(routed, 1)
    assertEq(DAG.Fire.Client.Assigned().id, 'FD-0002')
end)

test('heat falls off with distance from the flame', function()
    loadClient()
    fire('fire:sync', { callPayload() })

    local near = DAG.Fire.Client.HeatAt({ x = 2.0, y = 0.0, z = 0.0 })
    local far = DAG.Fire.Client.HeatAt({ x = 2.0, y = 4.0, z = 0.0 })
    assertTrue(near > far)
    assertEq(DAG.Fire.Client.HeatAt({ x = 500.0, y = 0.0, z = 0.0 }), 0)
end)

-- Rendering ------------------------------------------------------------------

test('only the client dispatch named renders the fire', function()
    loadClient()
    goOnDuty()

    fire('fire:sync', { callPayload({ owner = 7 }) })
    DAG.Fire.Suppression.RenderStep()
    assertEq(DAG.Fire.Suppression.RenderedCount(), 0, 'somebody else owns this scene')

    fire('fire:sync', { callPayload({ owner = 1 }) })
    DAG.Fire.Suppression.RenderStep()
    assertEq(DAG.Fire.Suppression.RenderedCount(), 2)
    assertEq(harness.count(harness.scriptFires), 2)
end)

test('a node that goes out takes its script fire with it', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload() })
    DAG.Fire.Suppression.RenderStep()

    fire('fire:node', 'FD-0001', { id = 'n1', intensity = 0, heat = 0 })
    DAG.Fire.Suppression.RenderStep()

    assertEq(DAG.Fire.Suppression.RenderedCount(), 1)
    assertEq(harness.count(harness.scriptFires), 1)
end)

test('going off duty hands every rendered fire back', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload() })
    DAG.Fire.Suppression.RenderStep()
    assertEq(DAG.Fire.Suppression.RenderedCount(), 2)

    fire('fire:duty', false)
    assertEq(DAG.Fire.Suppression.RenderedCount(), 0)
    assertEq(harness.count(harness.scriptFires), 0)
end)

-- Aiming ---------------------------------------------------------------------

test('the hose only reaches a fire that is in front of the firefighter', function()
    loadClient()
    fire('fire:sync', { callPayload() })

    local origin = { x = 0.0, y = 0.0, z = 0.0 }
    local ahead = DAG.Fire.Suppression.Target(origin, { x = 1.0, y = 0.0, z = 0.0 }, 14.0)
    assertEq(ahead.id, 'n1', 'the nearer of the two in front')

    local behind = DAG.Fire.Suppression.Target(origin, { x = -1.0, y = 0.0, z = 0.0 }, 14.0)
    assertNil(behind, 'a fire behind you is not a target')

    local outOfReach = DAG.Fire.Suppression.Target(origin, { x = 1.0, y = 0.0, z = 0.0 }, 1.0)
    assertNil(outOfReach)
end)

test('spraying reports the aimed node to the server at the configured rate', function()
    loadClient()
    withLine()
    fire('fire:sync', { callPayload() })

    DAG.Fire.Suppression.Equip('hose')
    assertEq(DAG.Fire.Suppression.Agent(), 'hose')

    harness.pedShooting = true
    harness.gameTimer = 5000
    local node = DAG.Fire.Suppression.SprayStep()
    assertEq(node.id, 'n1')

    local reports = {}
    for _, entry in ipairs(harness.serverEvents) do
        if entry.event == DAG.Framework.Event('fire:water') then reports[#reports + 1] = entry.args end
    end
    assertEq(#reports, 1)
    assertEq(reports[1][1], 'FD-0001')
    assertEq(reports[1][2], 'n1')
    assertEq(reports[1][4], 'hose')

    assertNil(DAG.Fire.Suppression.SprayStep(), 'the next tick is inside the report interval')
    harness.gameTimer = harness.gameTimer + 500
    assertTrue(DAG.Fire.Suppression.SprayStep() ~= nil)
end)

-- A hose is a line off a pump, not a thing you hold: with no line charged
-- there is nothing to report and the client does not bother the server.
test('a hose with no line charged sprays nothing', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload() })

    DAG.Fire.Suppression.Equip('hose')
    harness.pedShooting = true
    harness.gameTimer = 5000

    assertNil(DAG.Fire.Suppression.SprayStep())
    assertEq(#harness.serverEvents, 1, 'only the request for a line went out')
    assertEq(harness.serverEvents[1].event, DAG.Framework.Event('fire:deployLine'))
end)

test('an extinguisher needs no line at all', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload() })

    DAG.Fire.Suppression.Equip('extinguisher')
    harness.pedShooting = true
    harness.gameTimer = 5000
    assertTrue(DAG.Fire.Suppression.SprayStep() ~= nil)
end)

-- Hose lines ------------------------------------------------------------------

test('the line is laid behind the firefighter as they walk it in', function()
    loadClient()
    withLine()
    harness.playerCoords = vector3(0.0, 0.0, 0.0)
    fire('fire:lineDeployed', { unit = 1, netId = 901 })

    assertTrue(DAG.Fire.Hose.Deployed())
    assertEq(DAG.Fire.Hose.Step(), 0, 'nothing laid until they move')

    harness.playerCoords = vector3(5.0, 0.0, 0.0)
    assertEq(DAG.Fire.Hose.Step(), 1)
    harness.playerCoords = vector3(10.0, 0.0, 0.0)
    assertEq(DAG.Fire.Hose.Step(), 2, 'one length every few metres')
end)

test('the stretch warning tracks the distance back to the pump', function()
    loadClient()
    withLine()
    harness.playerCoords = vector3(0.0, 0.0, 0.0)
    fire('fire:lineDeployed', { unit = 1 })

    assertEq(DAG.Fire.Hose.Stretch(), 0)
    harness.playerCoords = vector3(19.0, 0.0, 0.0)
    assertEq(DAG.Fire.Shared.Round(DAG.Fire.Hose.Stretch(), 1), 0.5)

    harness.playerCoords = vector3(60.0, 0.0, 0.0)
    assertTrue(DAG.Fire.Hose.Stretch() >= 1.0, 'past the end of the line')
end)

test('stowing the line picks every length of it back up', function()
    loadClient()
    withLine()
    harness.playerCoords = vector3(0.0, 0.0, 0.0)
    fire('fire:lineDeployed', { unit = 1 })

    harness.playerCoords = vector3(20.0, 0.0, 0.0)
    DAG.Fire.Hose.Step()
    assertTrue(harness.count(harness.entities) > 0)

    fire('fire:lineStowed')
    assertFalse(DAG.Fire.Hose.Deployed())
    assertEq(harness.count(harness.entities), 0)
end)

-- Uniform ---------------------------------------------------------------------

test('clocking on puts the gear on and clocking off gives the clothes back', function()
    loadClient()
    harness.pedOutfit.components[4] = { 12, 3 }
    harness.pedOutfit.props[0] = { -1, 0 }

    goOnDuty()
    assertEq(DAG.Fire.Uniform.Current(), 'turnout')
    assertEq(harness.pedOutfit.components[4][1], 30, 'wearing the turnout trousers')
    assertEq(harness.pedOutfit.props[0][1], 124, 'and the helmet')

    fire('fire:duty', false)
    assertNil(DAG.Fire.Uniform.Current())
    assertEq(harness.pedOutfit.components[4][1], 12, 'their own clothes are back')
    assertEq(harness.pedOutfit.props[0][1], -1, 'and the helmet is off')
end)

test('a county department wears its own set', function()
    loadClient()
    fire('fire:duty', { station = 'paleto', department = 'bcfd', since = 0, air = 1500 })
    assertEq(harness.pedOutfit.components[4][2], 1, 'the county texture, not the city one')
end)

-- Player-caused incidents -------------------------------------------------------

test('a burning vehicle is reported once, not every tick', function()
    loadClient()
    harness.pedVehicle = 500
    harness.entities[500] = true
    harness.entityOnFire[500] = true

    assertTrue(DAG.Fire.Events.CheckVehicleFire())
    assertEq(#harness.serverEvents, 1)
    assertEq(harness.serverEvents[1].event, DAG.Framework.Event('fire:vehicleFire'))

    assertFalse(DAG.Fire.Events.CheckVehicleFire(), 'still burning, already called in')
    assertEq(#harness.serverEvents, 1)
end)

test('only a real impact counts as a collision', function()
    loadClient()
    harness.pedVehicle = 500
    harness.entities[500] = true
    harness.vehicleSpeed = 30.0
    DAG.Fire.Events.CheckCollision()

    -- Slowing down normally, with nothing hit.
    harness.vehicleSpeed = 28.0
    harness.vehicleCollided = false
    assertFalse(DAG.Fire.Events.CheckCollision())

    harness.vehicleSpeed = 30.0
    DAG.Fire.Events.CheckCollision()
    harness.vehicleSpeed = 2.0
    harness.vehicleCollided = true
    assertTrue(DAG.Fire.Events.CheckCollision())
    assertEq(harness.serverEvents[#harness.serverEvents].event, DAG.Framework.Event('fire:collision'))
end)

-- Academy -----------------------------------------------------------------------

test('the classroom runs down and then hands over to the drill', function()
    loadClient()
    goOnDuty()
    local academy = DAG.Fire.Shared.Settings().academy
    harness.playerCoords = vector3(academy.classroom.x, academy.classroom.y, academy.classroom.z)

    fire('fire:course', { course = 'engine', label = 'Pump operations', phase = 'classroom', duration = 30000 })
    assertEq(DAG.Fire.Academy.Step(), 'studying')
    assertEq(DAG.Fire.Shared.Round(DAG.Fire.Academy.Progress(), 1), 0)

    harness.gameTimer = harness.gameTimer + 30000
    assertEq(DAG.Fire.Academy.Step(), 'ready')
    assertEq(DAG.Fire.Academy.Course().phase, 'ready')
end)

test('walking out of the classroom drops the course', function()
    loadClient()
    goOnDuty()
    local academy = DAG.Fire.Shared.Settings().academy
    harness.playerCoords = vector3(academy.classroom.x, academy.classroom.y, academy.classroom.z)
    fire('fire:course', { course = 'engine', phase = 'classroom', duration = 30000 })

    harness.playerCoords = vector3(academy.classroom.x + 200, academy.classroom.y, academy.classroom.z)
    assertEq(DAG.Fire.Academy.Step(), 'left')
    assertNil(DAG.Fire.Academy.Course())
    assertEq(harness.serverEvents[#harness.serverEvents].event, DAG.Framework.Event('fire:abandonCourse'))
end)

test('nothing is sprayed off duty or with the nozzle stowed', function()
    loadClient()
    fire('fire:sync', { callPayload() })
    harness.pedShooting = true
    harness.gameTimer = 5000

    DAG.Fire.Suppression.Equip('hose')
    assertNil(DAG.Fire.Suppression.SprayStep(), 'off duty')

    goOnDuty()
    DAG.Fire.Suppression.Stow()
    assertNil(DAG.Fire.Suppression.SprayStep(), 'nothing in hand')
    assertNil(harness.weapons[PlayerPedId()])
end)

-- Air and heat ---------------------------------------------------------------

test('air burns faster inside the smoke than outside it', function()
    loadClient()
    goOnDuty()

    harness.playerCoords = vector3(500.0, 0.0, 0.0)
    assertEq(DAG.Fire.Suppression.AirStep(), 1)

    fire('fire:sync', { callPayload() })
    harness.playerCoords = vector3(2.0, 0.0, 0.0)
    assertEq(DAG.Fire.Suppression.AirStep(), 4)
end)

test('spent air is reported to the server in batches, not every tick', function()
    loadClient()
    goOnDuty()
    harness.playerCoords = vector3(500.0, 0.0, 0.0)

    DAG.Fire.Suppression.AirStep()
    assertEq(#harness.serverEvents, 0)

    harness.gameTimer = harness.gameTimer + 4000
    DAG.Fire.Suppression.AirStep()
    assertEq(harness.serverEvents[1].event, DAG.Framework.Event('fire:air'))
    assertEq(harness.serverEvents[1].args[1], 2, 'both ticks were carried over')
end)

test('turnout gear and a charged cylinder cut the heat taken', function()
    loadClient()
    fire('fire:sync', { callPayload() })
    harness.playerCoords = vector3(2.0, 0.0, 0.0)

    local unprotected = DAG.Fire.Suppression.HeatStep()
    goOnDuty()
    harness.entityHealth[PlayerPedId()] = 200
    local protected = DAG.Fire.Suppression.HeatStep()

    assertTrue(unprotected > protected)
    assertEq(harness.entityHealth[PlayerPedId()], 200 - protected)
end)

-- Scene props ----------------------------------------------------------------

test('patients get a ped and a prompt that follows their condition', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload({
        victims = { v1 = { id = 'v1', coords = { x = 1.0, y = 1.0, z = 0.0 }, state = 'trapped', condition = 60 } }
    }) })

    local prefix = DAG.Framework.namespace
    local spawned = harness.count(harness.entities)
    assertEq(spawned, 1, 'a local ped stands in for the patient')

    local prompt = DAG.Interactions.Get(prefix .. ':victim:FD-0001/v1')
    assertTrue(prompt ~= nil)
    assertTrue(prompt.label:find('extricate', 1, true) ~= nil)

    fire('fire:victim', 'FD-0001', { id = 'v1', coords = { x = 1.0, y = 1.0, z = 0.0 }, state = 'freed' })
    assertTrue(DAG.Interactions.Get(prefix .. ':victim:FD-0001/v1').label:find('treat', 1, true) ~= nil)

    fire('fire:victim', 'FD-0001', { id = 'v1', coords = { x = 1.0, y = 1.0, z = 0.0 }, state = 'transported' })
    assertNil(DAG.Interactions.Get(prefix .. ':victim:FD-0001/v1'), 'nothing left to do for them')
    assertEq(harness.count(harness.entities), 0, 'and the ped is cleaned up')
end)

test('an action that the firefighter walks away from is cancelled', function()
    loadClient()
    goOnDuty()
    harness.playerCoords = vector3(0.0, 0.0, 0.0)
    fire('fire:actionStarted', 'free', 'v1', 12000)

    assertEq(DAG.Fire.Rescue.ActionStep(), 'working')

    harness.playerCoords = vector3(50.0, 0.0, 0.0)
    assertEq(DAG.Fire.Rescue.ActionStep(), 'cancelled')
    assertEq(harness.serverEvents[#harness.serverEvents].event, DAG.Framework.Event('fire:cancelAction'))
end)

test('an action that runs its full time reports completion', function()
    loadClient()
    goOnDuty()
    harness.playerCoords = vector3(0.0, 0.0, 0.0)
    fire('fire:actionStarted', 'treat', 'v1', 8000)

    harness.gameTimer = harness.gameTimer + 8000
    assertEq(DAG.Fire.Rescue.ActionStep(), 'complete')
    assertEq(harness.serverEvents[#harness.serverEvents].event, DAG.Framework.Event('fire:completeAction'))
    assertNil(DAG.Fire.Rescue.ActionStep(), 'and it only fires once')
end)

-- Interface ------------------------------------------------------------------

test('the station fixtures and the menu keybind are registered', function()
    loadClient()
    runAllThreads()

    local prefix = DAG.Framework.namespace
    local station = DAG.Fire.Shared.Stations()[1].id
    assertTrue(DAG.Interactions.Get(('%s:duty:%s'):format(prefix, station)) ~= nil)
    assertTrue(DAG.Interactions.Get(('%s:garage:%s'):format(prefix, station)) ~= nil)
    assertTrue(harness.commands[prefix .. ':fdmenu'] ~= nil)
    assertEq(harness.keyMappings[1], prefix .. ':fdmenu')
end)

test('the dispatch board lists every open call with a submenu', function()
    loadClient()
    goOnDuty()
    fire('fire:sync', { callPayload(), callPayload({ id = 'FD-0002', priority = 3 }) })
    DAG.Fire.Menus.Refresh()

    local board = DAG.Menu.Get(DAG.Fire.Duty.MenuId('board'))
    assertTrue(board ~= nil)
    assertEq(#board.options, 3, 'a header and two calls')
    assertEq(board.options[2].title, 'FD-0001  Structure fire', 'priority 1 sorts first')
    assertTrue(DAG.Menu.Get(DAG.Fire.Duty.MenuId('call:FD-0002')) ~= nil)
end)

test('the board says so when there is nothing working', function()
    loadClient()
    DAG.Fire.Menus.Refresh()

    local board = DAG.Menu.Get(DAG.Fire.Duty.MenuId('board'))
    assertEq(#board.options, 2)
    assertTrue(board.options[2].disabled)
end)

test('the objectives line names what is still outstanding', function()
    loadClient()
    local call = callPayload({
        victims = { v1 = { id = 'v1', state = 'trapped' } },
        hazards = { h1 = { id = 'h1', contained = false } }
    })
    assertEq(DAG.Fire.Hud.Objectives(call), '2 seats of fire, 1 patient, 1 release')

    call.fires, call.victims, call.hazards = {}, {}, {}
    assertEq(DAG.Fire.Hud.Objectives(call), 'Scene clear - overhaul and close the call')
end)

test('the HUD only draws for a firefighter on duty', function()
    loadClient()
    assertFalse(DAG.Fire.Hud.Draw())

    goOnDuty()
    assertTrue(DAG.Fire.Hud.Draw())
    assertTrue(#harness.drawnRects > 0)
end)
