-- Client-side firefighter behaviour: what the mirror of dispatch does with the
-- events it receives, which client renders the fire, and what the hose is
-- allowed to point at.

local CLIENT_FILES = {
    'modules/firefighter/client/state.lua',
    'modules/firefighter/client/fire.lua',
    'modules/firefighter/client/rescue.lua',
    'modules/firefighter/client/duty.lua',
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

local function goOnDuty()
    fire('fire:duty', { station = 'davis', since = 0, air = 1500, extinguisher = 220 })
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
    goOnDuty()
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
