-- Server-side firefighter behaviour: dispatch lifecycle and jurisdiction, the
-- fire simulation, hose lines, staged extrication, what a client is allowed to
-- ask for, hiring, the academy, and what a closed call pays out.

local SERVER_FILES = {
    'modules/firefighter/server/database.lua',
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/departments.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/academy.lua',
    'modules/firefighter/server/events.lua',
    'modules/firefighter/server/api.lua'
}

-- Every random draw in the job goes through an injectable function so a test
-- can build the same scene twice. 0.5 keeps every `chance` below it true and
-- makes every count land on its minimum.
local function stubRandom(value)
    local roll = value or 0.5
    local fn = function(minimum, maximum)
        if minimum == nil then return roll end
        if maximum == nil then return math.floor(minimum) end
        return math.floor(minimum)
    end
    DAG.Fire.Incident.random = fn
    DAG.Fire.Dispatch.random = fn
end

local function loadServer()
    local dag = harness.loadServer({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' },
        modules = { 'storage', 'commands', 'access', 'repository' },
        files = SERVER_FILES
    })
    stubRandom()
    return dag
end

local function place(source, coords)
    harness.identifiers[source] = ('license:%d'):format(source)
    harness.names[source] = ('Firefighter %d'):format(source)
    harness.placePlayer(source, coords or vector3(0.0, 0.0, 0.0))
end

local function onDuty(source, coords, stationId)
    place(source, coords)
    local station = stationId and DAG.Fire.Shared.Station(stationId) or DAG.Fire.Shared.Stations()[1]
    harness.aceAllowed[source] = { [('dag-template.%s.duty'):format(station.department)] = true }
    DAG.Fire.State.GoOnDuty(source, station)
    return DAG.Fire.State.Duty(source)
end

local function equip(source, ...)
    for _, role in ipairs({ ... }) do
        local item = DAG.Fire.Shared.Item(role)
        if item then DAG.Framework.AddItem(source, item, 1) end
    end
end

local function netEvent(source, name, ...)
    _G.source = source
    TriggerEvent(DAG.Framework.Event(name), ...)
    _G.source = nil
end

local function firstNode(call)
    local id, node = next(call.fires)
    return node, id
end

local function clientEventsFor(event)
    local found = {}
    for _, entry in ipairs(harness.clientEvents) do
        if entry.event == DAG.Framework.Event(event) then found[#found + 1] = entry end
    end
    return found
end

-- Dispatch and jurisdiction -------------------------------------------------

test('a dispatched call arrives with a scene and reaches the roster', function()
    loadServer()
    onDuty(1)

    local call = DAG.Fire.Dispatch.Create('structure')
    assertEq(call.state, 'pending')
    assertEq(call.kind, 'structure')
    assertTrue(DAG.Fire.Incident.NodeCount(call) > 0, 'a structure fire has seats of fire')
    assertEq(#clientEventsFor('fire:call'), 1, 'the on-duty firefighter was told')
end)

test('a call is routed to whichever department covers where it happened', function()
    loadServer()
    local Shared = DAG.Fire.Shared

    assertEq(Shared.DepartmentForCoords({ x = 213.0, y = -900.0, z = 30.0 }).id, 'lsfd')
    assertEq(Shared.DepartmentForCoords({ x = 1900.0, y = 3700.0, z = 32.0 }).id, 'safd')
    assertEq(Shared.DepartmentForCoords({ x = -380.0, y = 6100.0, z = 31.0 }).id, 'bcfd')

    -- Nowhere near any jurisdiction circle: the nearest station takes it.
    local far = Shared.DepartmentForCoords({ x = -3000.0, y = 6500.0, z = 20.0 })
    assertEq(far.id, 'bcfd')
end)

test('another department cannot answer a call until it is toned out', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0), 'davis')

    -- San Andreas County lists Los Santos as mutual aid; until it is toned
    -- out, a city firefighter has no business on a county call.
    local call = DAG.Fire.Dispatch.Create('structure', { department = 'safd', force = true })
    local ok, reason = DAG.Fire.Dispatch.Join(1, call.id)
    assertFalse(ok)
    assertEq(reason, 'other_department')

    DAG.Fire.Departments.ToneOut(call)
    assertTrue(DAG.Fire.Dispatch.Join(1, call.id), 'mutual aid opens it up')
end)

test('a department with nobody on duty gets mutual aid after a while', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0), 'davis')

    local call = DAG.Fire.Dispatch.Create('structure', { department = 'safd', force = true })
    assertFalse(DAG.Fire.Departments.NeedsMutualAid(call, harness.gameTimer))

    harness.gameTimer = harness.gameTimer + 200000
    assertTrue(DAG.Fire.Departments.NeedsMutualAid(call, harness.gameTimer))

    DAG.Fire.Dispatch.Tick()
    assertTrue(call.toned.lsfd, 'the neighbouring department was toned out')
end)

test('two calls are never dispatched to the same address', function()
    loadServer()
    onDuty(1)

    local first = DAG.Fire.Dispatch.Create('structure')
    local second, reason = DAG.Fire.Dispatch.Create('structure')
    assertNil(second)
    assertEq(reason, 'location_busy')
    assertEq(first.state, 'pending')
end)

test('the board scales with the roster', function()
    loadServer()
    local Shared = DAG.Fire.Shared
    assertEq(Shared.MaxActiveCalls(0), 2)
    assertEq(Shared.MaxActiveCalls(3), 5)
    assertEq(Shared.MaxActiveCalls(50), 8, 'capped at the ceiling')
end)

test('the run card is weighted towards medicals', function()
    loadServer()
    local Shared = DAG.Fire.Shared
    assertEq(Shared.CallWeight(Shared.CallType('medical')), 10)
    assertEq(Shared.CallWeight(Shared.CallType('structure')), 6)
    assertEq(Shared.CallWeight(Shared.CallType('water')), 2)
    assertEq(Shared.CallWeight({ priority = 1 }), 3, 'no weight falls back to priority')
end)

test('nothing ambient is generated for an empty roster', function()
    loadServer()
    assertFalse(DAG.Fire.Dispatch.ShouldGenerate())
    onDuty(1)
    assertTrue(DAG.Fire.Dispatch.ShouldGenerate())
end)

test('responding assigns the call and clearing releases it', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')

    assertTrue(DAG.Fire.Dispatch.Join(1, call.id))
    assertEq(call.state, 'assigned')
    assertEq(DAG.Fire.State.Duty(1).callId, call.id)

    assertTrue(DAG.Fire.Dispatch.Leave(1))
    assertEq(call.state, 'pending', 'an abandoned call goes back on the board')
    assertNil(DAG.Fire.State.Duty(1).callId)
end)

test('an off-duty player cannot respond', function()
    loadServer()
    place(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    local ok, reason = DAG.Fire.Dispatch.Join(1, call.id)
    assertFalse(ok)
    assertEq(reason, 'off_duty')
end)

-- Certification gates are the reason a rank and the academy are worth having,
-- so a call that needs one must refuse a firefighter who does not hold it.
test('a call requiring a certification refuses an uncertified responder', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('hazmat', { department = 'lsfd', force = true })

    local ok, reason = DAG.Fire.Dispatch.Join(1, call.id)
    assertFalse(ok)
    assertEq(reason, 'not_certified')

    DAG.Fire.Progression.GrantCertification('license:1', 'hazmat')
    assertTrue(DAG.Fire.Dispatch.Join(1, call.id))
end)

test('arrival is measured from the ped, not from a client report', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0))
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)

    DAG.Fire.Dispatch.Tick()
    assertEq(call.state, 'assigned', 'signed on but nowhere near it')
    assertNil(call.firstArrivalAt)

    harness.placePlayer(1, vector3(call.coords.x, call.coords.y, call.coords.z))
    harness.gameTimer = harness.gameTimer + 5000
    DAG.Fire.Dispatch.Tick()

    assertEq(call.state, 'working')
    assertEq(call.responseTime, 5000)
    assertEq(call.owner, 1, 'the firefighter on scene renders the fire')
end)

-- The whole-call payload is the expensive message in the job. Growth and
-- knockdown ride on the compact node event instead.
test('an unchanged call is not rebroadcast on every simulation tick', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)
    local before = #clientEventsFor('fire:call')

    DAG.Fire.Dispatch.Tick()
    assertEq(#clientEventsFor('fire:call'), before, 'nothing a client can see moved')
    assertTrue(#clientEventsFor('fire:node') > 0, 'the fire still grew')

    harness.placePlayer(1, vector3(call.coords.x, call.coords.y, call.coords.z))
    DAG.Fire.Dispatch.Tick()
    assertTrue(#clientEventsFor('fire:call') > before, 'arriving is worth sending')
end)

test('an unanswered call escalates and then expires', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    local before = DAG.Fire.Incident.NodeCount(call)

    harness.gameTimer = harness.gameTimer + 300000
    DAG.Fire.Dispatch.Tick()
    assertEq(call.escalations, 1)
    assertTrue(DAG.Fire.Incident.NodeCount(call) > before, 'it spread while nobody came')

    harness.gameTimer = harness.gameTimer + 1200000
    DAG.Fire.Dispatch.Tick()
    assertNil(DAG.Fire.State.GetCall(call.id), 'it burned out')
end)

test('a quiet call closes as soon as a unit arrives', function()
    loadServer()
    onDuty(1)

    -- The alarm catalogue entry can dispatch with nothing burning at all.
    local call = DAG.Fire.Dispatch.Create('alarm')
    assertEq(DAG.Fire.Incident.NodeCount(call), 0)

    DAG.Fire.Dispatch.Join(1, call.id)
    harness.placePlayer(1, vector3(call.coords.x, call.coords.y, call.coords.z))
    DAG.Fire.Dispatch.Tick()

    assertNil(DAG.Fire.State.GetCall(call.id), 'resolved on arrival')
    assertNil(DAG.Fire.State.Duty(1).callId)
end)

-- Player-caused incidents ---------------------------------------------------

test('a burning player vehicle becomes a real call', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0))
    place(2, vector3(500.0, 500.0, 30.0))

    local call = DAG.Fire.Events.VehicleFire(2)
    assertTrue(call ~= nil)
    assertEq(call.kind, 'vehicle')
    assertEq(call.source, 'vehicle-fire')
    assertEq(call.coords.x, 500.0, 'the position came from the ped, not the client')
    assertEq(call.reportedBy, 'license:2')
end)

test('a light bump is not a collision call', function()
    loadServer()
    place(2, vector3(500.0, 500.0, 30.0))

    local call, reason = DAG.Fire.Events.Collision(2, 5.0)
    assertNil(call)
    assertEq(reason, 'too_light')

    assertTrue(DAG.Fire.Events.Collision(2, 40.0) ~= nil)
end)

test('a second incident on top of an open call escalates it instead', function()
    loadServer()
    onDuty(1)
    place(2, vector3(500.0, 500.0, 30.0))
    place(3, vector3(510.0, 500.0, 30.0))

    local first = DAG.Fire.Events.VehicleFire(2)
    local before = DAG.Fire.Incident.NodeCount(first)

    local second, reason = DAG.Fire.Events.VehicleFire(3)
    assertEq(second.id, first.id, 'the same call')
    assertEq(reason, 'reinforced')
    assertTrue(DAG.Fire.Incident.NodeCount(first) > before, 'and it got worse')
end)

test('a player cannot spam incidents', function()
    loadServer()
    place(2, vector3(500.0, 500.0, 30.0))
    assertTrue(DAG.Fire.Events.Report(2, 'structure') ~= nil)

    harness.placePlayer(2, vector3(900.0, 900.0, 30.0))
    local call, reason = DAG.Fire.Events.Report(2, 'structure')
    assertNil(call)
    assertEq(reason, 'cooling_down')

    harness.gameTimer = harness.gameTimer + 120000
    assertTrue(DAG.Fire.Events.Report(2, 'structure') ~= nil)
end)

test('the public can only report the call types the server allows', function()
    loadServer()
    place(2, vector3(500.0, 500.0, 30.0))

    local call, reason = DAG.Fire.Events.Report(2, 'hazmat')
    assertNil(call)
    assertEq(reason, 'unknown_call_type')
end)

test('a player-caused call is dispatched even with nobody on duty', function()
    loadServer()
    place(2, vector3(500.0, 500.0, 30.0))

    assertEq(DAG.Fire.State.OnDutyCount(), 0)
    local call = DAG.Fire.Events.VehicleFire(2)
    assertTrue(call ~= nil, 'the city still has emergencies')
    assertEq(call.state, 'pending')
end)

-- Simulation ---------------------------------------------------------------

test('an unworked fire grows and stops at the ceiling', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    local node = firstNode(call)
    node.intensity = 50

    DAG.Fire.Incident.Tick(call)
    assertEq(node.intensity, 52.5)

    node.intensity = 99
    DAG.Fire.Incident.Tick(call)
    assertEq(node.intensity, 100, 'clamped to maxIntensity')
end)

test('a knocked-down node keeps residual heat and can flare back up', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    local node = firstNode(call)
    node.intensity, node.heat = 0, 10

    stubRandom(0.5)
    DAG.Fire.Incident.Tick(call)
    assertEq(node.intensity, 0, 'a 0.5 roll is above the reignite chance')
    assertEq(node.heat, 9, 'heat bleeds off instead')

    stubRandom(0.01)
    DAG.Fire.Incident.Tick(call)
    assertTrue(node.intensity > 0, 'it reignited')
end)

test('a call is only complete when the fires, patients, and spills are all done', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('industrial')

    assertFalse(DAG.Fire.Incident.IsComplete(call))
    call.fires = {}
    assertFalse(DAG.Fire.Incident.IsComplete(call), 'patients are still on scene')

    for _, victim in pairs(call.victims) do victim.state = 'treated' end
    assertFalse(DAG.Fire.Incident.IsComplete(call), 'the release is still running')

    for _, hazard in pairs(call.hazards) do hazard.contained = true end
    assertTrue(DAG.Fire.Incident.IsComplete(call))
end)

test('untreated patients deteriorate and can be lost', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    local _, victim = next(call.victims)
    victim.condition = 4
    victim.state = 'trapped'

    DAG.Fire.Incident.TickVictims(call)
    assertEq(victim.state, 'deceased')
    assertEq(victim.condition, 0)
end)

test('a collision scene comes with wrecks to cut patients out of', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('mva')

    local wrecks = 0
    for _ in pairs(call.wrecks) do wrecks = wrecks + 1 end
    assertTrue(wrecks > 0)

    local _, victim = next(call.victims)
    assertEq(victim.state, 'trapped')
    assertEq(victim.stage, 1, 'staged extrication starts at the first stage')
    assertTrue(victim.wreck ~= nil, 'and they are in one of the wrecks')
end)

-- Water and hose lines ------------------------------------------------------

local function scene(kind)
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create(kind or 'structure', { department = 'lsfd', force = true })
    DAG.Fire.Dispatch.Join(1, call.id)

    local node, nodeId = firstNode(call)
    if node then harness.placePlayer(1, vector3(node.coords.x, node.coords.y, node.coords.z)) end
    return call, node, nodeId
end

local function giveApparatus(source, coords, water)
    DAG.Fire.State.SetUnit(source, {
        id = 'engine',
        label = 'Type 1 Engine',
        netId = 900 + source,
        capacity = 4000,
        water = water or 4000,
        coords = coords
    })
end

test('the nozzle needs the item in hand', function()
    local call, node, nodeId = scene()
    giveApparatus(1, node.coords)

    assertTrue(DAG.Fire.Incident.ItemsEnforced(), 'this framework can report an inventory')
    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose')
    assertFalse(ok)
    assertEq(reason, 'missing_item')
end)

test('a hose line has to be pulled off a pump before it flows', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')

    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose')
    assertFalse(ok)
    assertEq(reason, 'no_line')

    local deployed, failure = DAG.Fire.Incident.DeployLine(1, 1)
    assertFalse(deployed)
    assertEq(failure, 'no_unit', 'and there is no pump to pull it off')

    giveApparatus(1, node.coords)
    assertTrue(DAG.Fire.Incident.DeployLine(1, 1))
    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose'))
end)

-- A crew works off whichever pump is parked at the scene, not only off the one
-- they personally drove there.
test('a firefighter with no apparatus takes a line off the crew pump', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')
    place(2, vector3(node.coords.x, node.coords.y, node.coords.z))
    onDuty(2, vector3(node.coords.x, node.coords.y, node.coords.z))
    equip(2, 'hose')

    -- Only firefighter 1 signed a pump out.
    giveApparatus(1, node.coords)
    assertNil(DAG.Fire.State.Unit(2))

    assertTrue(DAG.Fire.Incident.DeployLine(2))
    assertTrue(DAG.Fire.Incident.ApplyWater(2, call.id, nodeId, 40, 'hose'))
    assertTrue(DAG.Fire.State.Unit(1).water < 4000, 'the water came off the crew pump')
end)

test('a line only reaches as far as it was laid', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')
    giveApparatus(1, node.coords)
    DAG.Fire.Incident.DeployLine(1, 1)

    -- The fire is where the pump is; walk the nozzle past the end of the line.
    node.coords = { x = node.coords.x + 60.0, y = node.coords.y, z = node.coords.z }
    harness.placePlayer(1, vector3(node.coords.x, node.coords.y, node.coords.z))

    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose')
    assertFalse(ok)
    assertEq(reason, 'line_stretched')
end)

test('water knocks the node down and draws the tank down with it', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')
    giveApparatus(1, node.coords)
    DAG.Fire.Incident.DeployLine(1, 1)
    node.intensity = 40

    local ok, _, result = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 22, 'hose')
    assertTrue(ok)
    assertEq(node.intensity, 30, '22 litres at 2.2 litres per point')
    assertEq(DAG.Fire.State.Unit(1).water, 3978)
    assertEq(result.supply, 'apparatus')
end)

-- A pump on a hydrant is drawing, not emptying. This is what a supply line is
-- for, and why driving away from the hydrant matters.
test('a supplied pump does not run its tank down', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')
    giveApparatus(1, node.coords, 500)
    DAG.Fire.Incident.DeployLine(1, 1)

    local hydrant = { x = node.coords.x + 1.0, y = node.coords.y, z = node.coords.z }
    assertTrue(DAG.Fire.Incident.ConnectSupply(1, hydrant))
    assertEq(DAG.Fire.State.Unit(1).water, 4000, 'the tank filled from the hydrant')

    DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 90, 'hose')
    assertEq(DAG.Fire.State.Unit(1).water, 4000, 'and it stays full while it draws')

    -- Driving the pump away pulls the line off the hydrant.
    DAG.Fire.State.Unit(1).coords = { x = node.coords.x + 100.0, y = node.coords.y, z = node.coords.z }
    assertTrue(DAG.Fire.Incident.CheckSupply(DAG.Fire.State.Unit(1)))
    assertFalse(DAG.Fire.State.Unit(1).supplied)
end)

test('a spray report that arrives too soon after the last one is dropped', function()
    local call, node, nodeId = scene()
    equip(1, 'hose')
    giveApparatus(1, node.coords)
    DAG.Fire.Incident.DeployLine(1, 1)

    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 20, 'hose'))
    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 20, 'hose')
    assertFalse(ok)
    assertEq(reason, 'too_fast')

    harness.gameTimer = harness.gameTimer + 500
    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 20, 'hose'))
end)

-- The whole point of checking the ped server-side: spraying a fire across the
-- map has to fail even when the client insists it is standing there.
test('water is refused from outside the agent range', function()
    local call, node, nodeId = scene()
    equip(1, 'extinguisher')
    harness.placePlayer(1, vector3(node.coords.x + 400, node.coords.y, node.coords.z))

    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 18, 'extinguisher')
    assertFalse(ok)
    assertEq(reason, 'out_of_range')
end)

test('a node that goes out is removed and counted', function()
    local call, node, nodeId = scene()
    equip(1, 'extinguisher')
    node.intensity, node.heat = 2, 2

    local ok, _, result = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 90, 'extinguisher')
    assertTrue(ok)
    assertTrue(result.extinguished)
    assertNil(call.fires[nodeId])
    assertEq(call.extinguished, 1)
end)

test('an empty extinguisher stops working', function()
    local call, _, nodeId = scene()
    equip(1, 'extinguisher')
    DAG.Fire.State.Duty(1).extinguisher = 10

    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 10, 'extinguisher'))
    assertEq(DAG.Fire.State.Duty(1).extinguisher, 0)

    harness.gameTimer = harness.gameTimer + 500
    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 10, 'extinguisher')
    assertFalse(ok)
    assertEq(reason, 'dry')
end)

test('a pump only charges next to a hydrant it is actually parked at', function()
    local _, node = scene()
    giveApparatus(1, node.coords, 100)

    local hydrant = { x = node.coords.x + 1.0, y = node.coords.y, z = node.coords.z }
    local ok, _, water = DAG.Fire.Incident.RefillApparatus(1, hydrant)
    assertTrue(ok)
    assertEq(water, 500)

    local far = { x = node.coords.x + 200, y = node.coords.y, z = node.coords.z }
    local refused, reason = DAG.Fire.Incident.RefillApparatus(1, far)
    assertFalse(refused)
    assertEq(reason, 'no_hydrant')
end)

-- Extrication ---------------------------------------------------------------

local function rescueScene()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('mva', { department = 'lsfd', force = true })
    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')
    DAG.Fire.Dispatch.Join(1, call.id)

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))
    return call, victim, victimId
end

test('extrication is refused without the certification', function()
    local call, _, victimId = rescueScene()
    DAG.Fire.Progression.RevokeCertification('license:1', 'rescue')

    local ok, reason = DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    assertFalse(ok)
    assertEq(reason, 'not_certified')
end)

-- The jaws are a tool, not a permission: holding the certification is not the
-- same as having brought the right thing to the wreck.
test('a stage that needs the jaws refuses to start without them', function()
    local call, _, victimId = rescueScene()

    -- Stage one is hands-on and needs nothing.
    local started, _, duration = DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    assertTrue(started)
    assertEq(duration, 6000, 'stabilise the vehicle')
    harness.gameTimer = harness.gameTimer + 10000
    assertTrue(DAG.Fire.Incident.CompleteAction(1))

    -- Stage two wants the halligan.
    local ok, reason = DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    assertFalse(ok)
    assertEq(reason, 'missing_item')

    equip(1, 'halligan')
    assertTrue(DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId))
end)

test('a patient comes out of a wreck one stage at a time', function()
    local call, victim, victimId = rescueScene()
    equip(1, 'halligan', 'jaws')

    local stages = #DAG.Fire.Shared.Settings().extrication.stages
    for step = 1, stages do
        assertEq(victim.stage, step)
        assertTrue(DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId), 'stage ' .. step)
        harness.gameTimer = harness.gameTimer + 20000
        local ok, _, result = DAG.Fire.Incident.CompleteAction(1)
        assertTrue(ok)
        if step < stages then
            assertEq(victim.state, 'trapped', 'still in the car')
            assertEq(result.remaining, stages - step)
        end
    end

    assertEq(victim.state, 'freed')
    assertNil(victim.stage)
end)

test('an action that comes back too early is rejected', function()
    local call, victim, victimId = rescueScene()

    DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    harness.gameTimer = harness.gameTimer + 1000
    local ok, reason = DAG.Fire.Incident.CompleteAction(1)
    assertFalse(ok)
    assertEq(reason, 'too_fast')
    assertEq(victim.state, 'trapped')
end)

test('walking away from a finished action forfeits it', function()
    local call, victim, victimId = rescueScene()

    DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    harness.gameTimer = harness.gameTimer + 20000
    harness.placePlayer(1, vector3(victim.coords.x + 100, victim.coords.y, victim.coords.z))

    local ok, reason = DAG.Fire.Incident.CompleteAction(1)
    assertFalse(ok)
    assertEq(reason, 'left_scene')
end)

test('a patient moves freed, treated, transported and no further', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('medical', { department = 'lsfd', force = true })
    DAG.Fire.Progression.GrantCertification('license:1', 'ems')
    equip(1, 'medbag')

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))
    assertEq(victim.state, 'freed', 'a medical patient is not trapped')

    DAG.Fire.Incident.BeginAction(1, call.id, 'treat', victimId)
    harness.gameTimer = harness.gameTimer + 20000
    assertTrue(DAG.Fire.Incident.CompleteAction(1))
    assertEq(victim.state, 'treated')
    assertEq(call.rescued, 1)

    local refused, reason = DAG.Fire.Incident.TransportVictim(1, call.id, victimId)
    assertFalse(refused, 'the hospital is on the other side of the map')
    assertEq(reason, 'not_at_hospital')

    local hospital = DAG.Fire.Shared.Settings().victims.hospital
    harness.placePlayer(1, vector3(hospital.x, hospital.y, hospital.z))
    assertTrue(DAG.Fire.Incident.TransportVictim(1, call.id, victimId))
    assertEq(victim.state, 'transported')
end)

-- Progression --------------------------------------------------------------

test('a call is worth its payout plus what the crew actually did', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    call.extinguished, call.rescued, call.responseTime = 4, 1, 10000
    call.victims = {}

    -- 900 base + 4 fires at 35 + 1 rescue at 300 + the 200 response bonus.
    assertEq(DAG.Fire.Progression.CallValue(call), 1540)

    call.responseTime = 999999
    assertEq(DAG.Fire.Progression.CallValue(call), 1340, 'a slow turnout loses the bonus')
end)

-- Getting everybody out alive is the difference between a good call and a bad
-- one, so it is worth more than the sum of the rescues on it.
test('bringing every patient out alive pays a clean scene bonus', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    call.extinguished, call.rescued, call.responseTime = 4, 1, 10000

    local clean, lost = DAG.Fire.Progression.CallValue(call)
    assertEq(lost, 0)
    assertEq(clean, 1771, '1540 with the 1.15 clean scene multiplier')

    local _, victim = next(call.victims)
    victim.state = 'deceased'
    local worse, casualties = DAG.Fire.Progression.CallValue(call)
    assertEq(casualties, 1)
    assertEq(worse, 1540, 'the bonus is gone')
end)

test('shares are part flat and part earned, and always add up to the whole', function()
    loadServer()
    local call = { contribution = { ['license:1'] = 300, ['license:2'] = 100 } }
    local attendees = { { identifier = 'license:1' }, { identifier = 'license:2' } }

    local shares = DAG.Fire.Progression.Shares(call, attendees)
    assertEq(DAG.Fire.Shared.Round(shares['license:1'] + shares['license:2'], 6), 1.0)
    assertTrue(shares['license:1'] > shares['license:2'], 'the firefighter who worked it earns more')
    assertTrue(shares['license:2'] >= 0.175, 'and the other one is still paid for turning out')
end)

test('closing a call pays the crew, banks the XP, and keeps the record', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)

    harness.placePlayer(1, vector3(call.coords.x, call.coords.y, call.coords.z))
    harness.gameTimer = harness.gameTimer + 10000
    DAG.Fire.Dispatch.Tick()

    call.fires = {}
    for _, victim in pairs(call.victims) do victim.state = 'treated' end
    call.extinguished, call.rescued = 4, 1

    DAG.Fire.Dispatch.Tick()

    assertNil(DAG.Fire.State.GetCall(call.id), 'the call closed')
    assertTrue(DAG.Framework.GetMoney(1, 'bank') > 0, 'the firefighter was paid')

    local profile = DAG.Fire.State.ProfileFor('license:1')
    assertEq(profile.stats.calls, 1)
    assertTrue(profile.xp > 0)
    assertEq(profile.stats.fastestResponse, 10000)
end)

test('signing on to a call from across the map earns nothing', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0))
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)

    call.fires, call.victims = {}, {}
    local awards, paid = DAG.Fire.Progression.Award(call, 'test')
    assertEq(#awards, 0)
    assertEq(paid, 0)
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 0)
end)

test('the leaderboard ranks by experience', function()
    loadServer()
    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 100 }, 'license:a', 'Ari'))
    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 900 }, 'license:b', 'Blake'))

    local board
    DAG.Fire.Progression.Leaderboard(5, function(result) board = result end)
    assertEq(#board, 2)
    assertEq(board[1].name, 'Blake')
    assertEq(board[1].rank, 'Firefighter')
    assertEq(board[2].name, 'Ari')
end)

-- Departments and hiring ----------------------------------------------------

test('an officer hires a nearby player into their department', function()
    loadServer()
    onDuty(1)
    place(2, vector3(0.0, 0.0, 0.0))
    harness.aceAllowed[1] = { ['dag-template.lsfd.command'] = true }

    local hired
    DAG.Fire.Departments.Hire(1, 2, 'lsfd', function(ok, _, profile) hired = ok and profile end)

    assertTrue(hired ~= nil)
    assertEq(hired.department, 'lsfd')
    assertEq(DAG.Framework.GetJob(2).name, 'lsfd', 'the framework job moved')
    assertEq(DAG.Framework.GetJob(2).grade, 0, 'starting at the bottom')
end)

test('hiring is refused without command authority', function()
    loadServer()
    onDuty(1)
    place(2, vector3(0.0, 0.0, 0.0))

    local reason
    DAG.Fire.Departments.Hire(1, 2, 'lsfd', function(_, failure) reason = failure end)
    assertEq(reason, 'denied')
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
end)

-- Rank is derived from XP everywhere, so a promotion has to move the XP with
-- it or the menus and the framework grade start disagreeing.
test('a promotion raises the XP floor and the framework grade together', function()
    loadServer()
    onDuty(1)
    place(2, vector3(0.0, 0.0, 0.0))
    harness.aceAllowed[1] = { ['dag-template.lsfd.command'] = true }
    DAG.Fire.Departments.Hire(1, 2, 'lsfd', function() end)

    local promoted
    DAG.Fire.Departments.SetRank(1, 2, 'lieutenant', function(ok, _, profile) promoted = ok and profile end)

    assertTrue(promoted ~= nil)
    assertEq(promoted.xp, 6000)
    assertEq(DAG.Fire.Shared.RankFor(promoted.xp).id, 'lieutenant')
    assertEq(DAG.Framework.GetJob(2).grade, 3)

    -- And a demotion drops them back under the threshold rather than leaving
    -- the XP to promote them again on the next call.
    DAG.Fire.Departments.SetRank(1, 2, 'firefighter', function() end)
    assertEq(DAG.Fire.Shared.RankFor(DAG.Fire.State.ProfileFor('license:2').xp).id, 'firefighter')
    assertEq(DAG.Framework.GetJob(2).grade, 1)
end)

test('dismissing a firefighter takes the job and clears their shift', function()
    loadServer()
    onDuty(1)
    onDuty(2, vector3(0.0, 0.0, 0.0))
    harness.aceAllowed[1] = { ['dag-template.lsfd.command'] = true }
    DAG.Fire.Departments.Hire(1, 2, 'lsfd', function() end)

    local ok
    DAG.Fire.Departments.Terminate(1, 2, 'conduct', function(success) ok = success end)
    assertTrue(ok)
    assertFalse(DAG.Fire.State.IsOnDuty(2), 'they were sent home')
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
    assertNil(DAG.Fire.State.ProfileFor('license:2').department)
end)

test('an officer only sees players standing in front of them', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0))
    place(2, vector3(3.0, 0.0, 0.0))
    place(3, vector3(300.0, 0.0, 0.0))
    harness.players = { 1, 2, 3 }

    local nearby = DAG.Fire.Departments.Nearby(1, 10.0)
    assertEq(#nearby, 1)
    assertEq(nearby[1].source, 2)
end)

-- Academy -------------------------------------------------------------------

local function atAcademy(source)
    local academy = DAG.Fire.Shared.Settings().academy
    harness.placePlayer(source, vector3(academy.classroom.x, academy.classroom.y, academy.classroom.z))
end

-- Rank and prerequisites are separate gates: a probationary firefighter is not
-- sitting technical rescue however many courses they have passed.
test('a course refuses a trainee below its rank floor', function()
    loadServer()
    onDuty(1)
    atAcademy(1)
    DAG.Fire.Progression.GrantCertification('license:1', 'ems')

    local ok, reason = DAG.Fire.Academy.Enrol(1, 'rescue')
    assertFalse(ok)
    assertEq(reason, 'rank_too_low')
end)

test('a course refuses a trainee who is missing its prerequisite', function()
    loadServer()
    onDuty(1)
    atAcademy(1)
    DAG.Fire.Progression.AwardXp('license:1', 1000)

    local ok, reason = DAG.Fire.Academy.Enrol(1, 'rescue')
    assertFalse(ok)
    assertEq(reason, 'missing_prerequisite')

    DAG.Fire.Progression.GrantCertification('license:1', 'ems')
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')
    assertTrue(DAG.Fire.Academy.Enrol(1, 'rescue'), 'prerequisite held and the fee paid')
end)

test('a course has to be sat at the academy', function()
    loadServer()
    onDuty(1, vector3(0.0, 0.0, 0.0))

    local ok, reason = DAG.Fire.Academy.Enrol(1, 'ems')
    assertFalse(ok)
    assertEq(reason, 'not_at_academy')
end)

test('the classroom cannot be skipped', function()
    loadServer()
    onDuty(1)
    atAcademy(1)
    DAG.Fire.Academy.Enrol(1, 'engine')

    local ok, reason = DAG.Fire.Academy.StartPractical(1)
    assertFalse(ok)
    assertEq(reason, 'too_fast')

    harness.gameTimer = harness.gameTimer + 40000
    assertTrue(DAG.Fire.Academy.StartPractical(1))
end)

-- The drill is a real scene built by the same simulation as a dispatched call,
-- so passing pump operations means actually putting the fire out.
test('passing the drill signs the trainee off', function()
    loadServer()
    onDuty(1)
    atAcademy(1)
    DAG.Fire.Academy.Enrol(1, 'engine')
    harness.gameTimer = harness.gameTimer + 40000

    local ok, _, call = DAG.Fire.Academy.StartPractical(1)
    assertTrue(ok)
    assertTrue(call.training)
    assertEq(call.trainee, 1)
    assertEq(DAG.Fire.Incident.NodeCount(call), 3, 'three training fires')
    assertEq(#DAG.Fire.State.ActiveCalls(), 0, 'a drill never reaches the board')

    call.fires = {}
    DAG.Fire.Academy.Tick()

    local profile = DAG.Fire.State.ProfileFor('license:1')
    assertTrue(DAG.Fire.Shared.HasCertification(profile, 'engine'))
    assertNil(DAG.Fire.Academy.Enrolment(1))
end)

test('running out of time fails the drill and starts a cooldown', function()
    loadServer()
    onDuty(1)
    atAcademy(1)
    DAG.Fire.Academy.Enrol(1, 'engine')
    harness.gameTimer = harness.gameTimer + 40000
    DAG.Fire.Academy.StartPractical(1)

    harness.gameTimer = harness.gameTimer + 300000
    DAG.Fire.Academy.Tick()

    local profile = DAG.Fire.State.ProfileFor('license:1')
    assertFalse(DAG.Fire.Shared.HasCertification(profile, 'engine'))

    local ok, reason = DAG.Fire.Academy.Enrol(1, 'engine')
    assertFalse(ok)
    assertEq(reason, 'cooling_down')
end)

test('a course fee is taken and a trainee who cannot pay is turned away', function()
    loadServer()
    onDuty(1)
    atAcademy(1)

    local ok, reason = DAG.Fire.Academy.Enrol(1, 'ems')
    assertFalse(ok)
    assertEq(reason, 'cannot_afford')

    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')
    assertTrue(DAG.Fire.Academy.Enrol(1, 'ems'))
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 750, 'the fee was taken')
end)

-- Roster -------------------------------------------------------------------

test('clocking on requires standing at a station and being allowed to', function()
    loadServer()
    place(1, vector3(0.0, 0.0, 0.0))

    netEvent(1, 'fire:toggleDuty')
    assertFalse(DAG.Fire.State.IsOnDuty(1), 'not at a station')

    local station = DAG.Fire.Shared.Stations()[1]
    harness.placePlayer(1, vector3(station.duty.x, station.duty.y, station.duty.z))
    netEvent(1, 'fire:toggleDuty')
    assertFalse(DAG.Fire.State.IsOnDuty(1), 'at a station, but not a firefighter')

    harness.aceAllowed[1] = { ['dag-template.lsfd.duty'] = true }
    netEvent(1, 'fire:toggleDuty')
    assertTrue(DAG.Fire.State.IsOnDuty(1))
    assertEq(DAG.Fire.State.Duty(1).department, 'lsfd')

    netEvent(1, 'fire:toggleDuty')
    assertFalse(DAG.Fire.State.IsOnDuty(1), 'and it toggles back off')
end)

test('a firefighter who disconnects leaves the roster and the call', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)

    _G.source = 1
    TriggerEvent('playerDropped')
    _G.source = nil

    assertFalse(DAG.Fire.State.IsOnDuty(1))
    assertEq(DAG.Fire.State.ResponderCount(call), 0)
end)

test('the call payload never leaks another firefighter payout ledger', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    call.contribution = { ['license:2'] = 500 }

    local payload = DAG.Fire.State.PublicCall(call)
    assertNil(payload.contribution)
    assertNil(payload.payout)
    assertNil(payload.reportedBy)
    assertTrue(payload.severity > 0)
    assertEq(payload.id, call.id)
end)
