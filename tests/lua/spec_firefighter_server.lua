-- Server-side firefighter behaviour: dispatch lifecycle, the fire simulation,
-- what a client is allowed to ask for, and what a closed call pays out.

local SERVER_FILES = {
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/api.lua'
}

-- Every random draw in the job goes through an injectable function so a test
-- can build the same scene twice. 0.5 keeps every `chance` below it true.
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

local function onDuty(source, coords)
    place(source, coords)
    harness.aceAllowed[source] = { ['dag-template.fire.duty'] = true }
    DAG.Fire.State.GoOnDuty(source, DAG.Fire.Shared.Stations()[1])
    return DAG.Fire.State.Duty(source)
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

-- Dispatch -----------------------------------------------------------------

test('a dispatched call arrives with a scene and reaches the roster', function()
    loadServer()
    onDuty(1)

    local call = DAG.Fire.Dispatch.Create('structure')
    assertEq(call.state, 'pending')
    assertEq(call.kind, 'structure')
    assertTrue(DAG.Fire.Incident.NodeCount(call) > 0, 'a structure fire has seats of fire')
    assertEq(#clientEventsFor('fire:call'), 1, 'the on-duty firefighter was told')
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

test('nothing is generated for an empty roster', function()
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

-- Certification gates are the reason a rank is worth having, so a call that
-- needs one must refuse a firefighter who does not hold it.
test('a call requiring a certification refuses an uncertified responder', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('hazmat')

    local ok, reason = DAG.Fire.Dispatch.Join(1, call.id)
    assertFalse(ok)
    assertEq(reason, 'not_certified')

    DAG.Fire.Progression.GrantCertification('license:1', 'hazmat')
    assertTrue(DAG.Fire.Dispatch.Join(1, call.id))
end)

test('arrival is measured from the ped, not from a client report', function()
    loadServer()
    local call

    onDuty(1, vector3(0.0, 0.0, 0.0))
    call = DAG.Fire.Dispatch.Create('structure')
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

-- Water --------------------------------------------------------------------

local function scene()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)

    local node, nodeId = firstNode(call)
    harness.placePlayer(1, vector3(node.coords.x, node.coords.y, node.coords.z))
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

test('water needs a supply within reach of the pump', function()
    local call, node, nodeId = scene()

    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose')
    assertFalse(ok)
    assertEq(reason, 'no_supply')

    giveApparatus(1, node.coords)
    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose'))
end)

test('water knocks the node down and draws the tank down with it', function()
    local call, node, nodeId = scene()
    giveApparatus(1, node.coords)
    node.intensity = 40

    local ok, _, result = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 22, 'hose')
    assertTrue(ok)
    assertEq(node.intensity, 30, '22 litres at 2.2 litres per point')
    assertEq(DAG.Fire.State.Unit(1).water, 3978)
    assertEq(result.supply, 'apparatus')
end)

test('a spray report that arrives too soon after the last one is dropped', function()
    local call, node, nodeId = scene()
    giveApparatus(1, node.coords)

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
    giveApparatus(1, node.coords)
    harness.placePlayer(1, vector3(node.coords.x + 400, node.coords.y, node.coords.z))

    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 60, 'hose')
    assertFalse(ok)
    assertEq(reason, 'out_of_range')
end)

test('a node that goes out is removed and counted', function()
    local call, node, nodeId = scene()
    giveApparatus(1, node.coords)
    node.intensity, node.heat = 2, 2

    local ok, _, result = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 90, 'hose')
    assertTrue(ok)
    assertTrue(result.extinguished)
    assertNil(call.fires[nodeId])
    assertEq(call.extinguished, 1)
end)

test('an empty extinguisher stops working', function()
    local call, _, nodeId = scene()
    DAG.Fire.State.Duty(1).extinguisher = 10

    assertTrue(DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 10, 'extinguisher'))
    assertEq(DAG.Fire.State.Duty(1).extinguisher, 0)

    harness.gameTimer = harness.gameTimer + 500
    local ok, reason = DAG.Fire.Incident.ApplyWater(1, call.id, nodeId, 10, 'extinguisher')
    assertFalse(ok)
    assertEq(reason, 'dry')
end)

test('a pump only charges next to a hydrant it is actually parked at', function()
    local call, node = scene()
    assertTrue(call ~= nil)
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

-- Timed actions ------------------------------------------------------------

test('extrication is refused without the certification and accepted with it', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('rescue')
    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')
    DAG.Fire.Dispatch.Join(1, call.id)

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))

    DAG.Fire.Progression.RevokeCertification('license:1', 'rescue')
    local ok, reason = DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    assertFalse(ok)
    assertEq(reason, 'not_certified')

    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')
    local started, _, duration = DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    assertTrue(started)
    assertEq(duration, 12000)
end)

test('an action that comes back too early is rejected', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('rescue')
    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))
    DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)

    harness.gameTimer = harness.gameTimer + 1000
    local ok, reason = DAG.Fire.Incident.CompleteAction(1)
    assertFalse(ok)
    assertEq(reason, 'too_fast')
    assertEq(victim.state, 'trapped')
end)

test('walking away from a finished action forfeits it', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('rescue')
    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))
    DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)

    harness.gameTimer = harness.gameTimer + 20000
    harness.placePlayer(1, vector3(victim.coords.x + 100, victim.coords.y, victim.coords.z))
    local ok, reason = DAG.Fire.Incident.CompleteAction(1)
    assertFalse(ok)
    assertEq(reason, 'left_scene')
end)

test('a patient moves trapped, freed, treated, transported and no further', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('rescue')
    DAG.Fire.Progression.GrantCertification('license:1', 'rescue')
    DAG.Fire.Progression.GrantCertification('license:1', 'ems')

    local victimId, victim = next(call.victims)
    harness.placePlayer(1, vector3(victim.coords.x, victim.coords.y, victim.coords.z))

    DAG.Fire.Incident.BeginAction(1, call.id, 'free', victimId)
    harness.gameTimer = harness.gameTimer + 20000
    assertTrue(DAG.Fire.Incident.CompleteAction(1))
    assertEq(victim.state, 'freed')

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
    local call = {
        contribution = { ['license:1'] = 300, ['license:2'] = 100 }
    }
    local attendees = {
        { identifier = 'license:1' },
        { identifier = 'license:2' }
    }

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
    local awards = DAG.Fire.Progression.Award(call, 'test')
    assertEq(#awards, 0)
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 0)
end)

test('the leaderboard ranks by experience', function()
    loadServer()
    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 100 }, 'license:a', 'Ari'))
    DAG.Fire.State.SaveProfile(DAG.Fire.Shared.NormalizeProfile({ xp = 900 }, 'license:b', 'Blake'))

    local board = DAG.Fire.Progression.Leaderboard(5)
    assertEq(#board, 2)
    assertEq(board[1].name, 'Blake')
    assertEq(board[1].rank, 'Firefighter')
    assertEq(board[2].name, 'Ari')
end)

-- Roster -------------------------------------------------------------------

test('clocking on requires standing at a station and being allowed to', function()
    loadServer()
    place(1, vector3(0.0, 0.0, 0.0))

    netEvent(1, 'fire:toggleDuty')
    assertFalse(DAG.Fire.State.IsOnDuty(1), 'no permission, no duty')

    harness.aceAllowed[1] = { ['dag-template.fire.duty'] = true }
    netEvent(1, 'fire:toggleDuty')
    assertFalse(DAG.Fire.State.IsOnDuty(1), 'permission is not a duty point')

    local station = DAG.Fire.Shared.Stations()[1]
    harness.placePlayer(1, vector3(station.duty.x, station.duty.y, station.duty.z))
    netEvent(1, 'fire:toggleDuty')
    assertTrue(DAG.Fire.State.IsOnDuty(1))

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

test('the context callback never leaks another firefighter payout ledger', function()
    loadServer()
    onDuty(1)
    local call = DAG.Fire.Dispatch.Create('structure')
    call.contribution = { ['license:2'] = 500 }

    local payload = DAG.Fire.State.PublicCall(call)
    assertNil(payload.contribution)
    assertNil(payload.payout)
    assertTrue(payload.severity > 0)
    assertEq(payload.id, call.id)
end)
