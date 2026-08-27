-- The physical side of an incident: what is burning, who is trapped, what has
-- spilled, and what a firefighter is allowed to do about it.
--
-- The client renders this and asks for changes; nothing here trusts a
-- coordinate, a duration, or a water volume that arrived over the network.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = {}
Fire.Incident = Incident

-- Injectable so the simulation can be driven deterministically under test.
Incident.random = math.random

local function settings()
    return Shared.Settings().fire or {}
end

local function chance(probability)
    return Incident.random() < (tonumber(probability) or 0)
end

local function between(minimum, maximum)
    minimum, maximum = tonumber(minimum) or 0, tonumber(maximum) or 0
    if maximum <= minimum then return minimum end
    return minimum + Incident.random() * (maximum - minimum)
end

local function countBetween(range)
    if type(range) ~= 'table' then return 0 end
    local minimum, maximum = math.floor(tonumber(range.min) or 0), math.floor(tonumber(range.max) or 0)
    if maximum <= minimum then return minimum end
    return Incident.random(minimum, maximum)
end

local function offset(coords, radius)
    local angle = Incident.random() * math.pi * 2
    local distance = math.sqrt(Incident.random()) * radius
    return {
        x = coords.x + math.cos(angle) * distance,
        y = coords.y + math.sin(angle) * distance,
        z = coords.z
    }
end

-- Scene construction -------------------------------------------------------

local function newNode(call, coords, intensity)
    call.nodeSequence = (call.nodeSequence or 0) + 1
    local id = ('n%d'):format(call.nodeSequence)
    local node = {
        id = id,
        coords = Shared.Coords(coords),
        intensity = Shared.Clamp(intensity, 1, tonumber(settings().maxIntensity) or 100),
        heat = tonumber(settings().residualHeat) or 18,
        kind = call.kind,
        -- Cosmetic only: the client picks a fire size from it.
        scale = Shared.Round(between(0.7, 1.4), 2)
    }
    call.fires[id] = node
    return node
end

Incident.NewNode = newNode

local function newVictim(call, coords, trapped)
    call.victimSequence = (call.victimSequence or 0) + 1
    local id = ('v%d'):format(call.victimSequence)
    call.victims[id] = {
        id = id,
        coords = Shared.Coords(coords),
        heading = Shared.Round(Incident.random() * 360.0, 1),
        state = trapped and Fire.VictimState.trapped or Fire.VictimState.freed,
        condition = Shared.Round(between(45, 95), 0),
        carriedBy = nil
    }
    return call.victims[id]
end

local function newHazard(call, coords)
    call.hazardSequence = (call.hazardSequence or 0) + 1
    local id = ('h%d'):format(call.hazardSequence)
    call.hazards[id] = {
        id = id,
        coords = Shared.Coords(coords),
        progress = 0,
        contained = false,
        label = 'Chemical release'
    }
    return call.hazards[id]
end

-- Populates a freshly dispatched call from its catalogue entry.
function Incident.Build(call, callType)
    call.fires, call.victims, call.hazards = {}, {}, {}
    local radius = tonumber(call.radius) or 8.0

    local fires = callType.fires or {}
    for _ = 1, countBetween(fires) do
        newNode(call, offset(call.coords, radius), between((fires.intensity or {}).min or 40, (fires.intensity or {}).max or 80))
    end

    local victims = callType.victims or {}
    if victims.chance and chance(victims.chance) then
        for _ = 1, math.max(1, countBetween(victims)) do
            newVictim(call, offset(call.coords, radius * 0.6), victims.trapped == true)
        end
    end

    local hazards = callType.hazards or {}
    if hazards.chance and chance(hazards.chance) then
        for _ = 1, math.max(1, countBetween(hazards)) do
            newHazard(call, offset(call.coords, radius * 0.5))
        end
    end

    return call
end

-- Simulation ---------------------------------------------------------------

local function burningNodes(call)
    local list = {}
    for _, node in pairs(call.fires or {}) do
        if node.intensity > 0 then list[#list + 1] = node end
    end
    return list
end

local function nodeCount(call)
    local count = 0
    for _ in pairs(call.fires or {}) do count = count + 1 end
    return count
end

Incident.NodeCount = nodeCount

-- One simulation step for one call. Returns the nodes that changed so the
-- caller can decide how much of it to put on the wire.
function Incident.Tick(call)
    local config = settings()
    local changed, spawned = {}, nil
    local maximum = tonumber(config.maxIntensity) or 100
    local growth = tonumber(config.growth) or 2.5

    for _, node in pairs(call.fires or {}) do
        local before = node.intensity

        if node.intensity > 0 then
            if node.intensity < maximum then
                node.intensity = Shared.Clamp(node.intensity + growth, 0, maximum)
            end
            node.heat = tonumber(config.residualHeat) or 18
        elseif node.heat > 0 then
            -- Overhaul: a node that was knocked down but still has heat in it
            -- can flare back up until the crew works it all the way out.
            node.heat = math.max(0, node.heat - 1)
            if chance(config.reigniteChance) then
                node.intensity = Shared.Clamp(between(8, 25), 0, maximum)
            end
        end

        if node.intensity ~= before then changed[#changed + 1] = node end
    end

    -- Spread is capped per tick: one new seat of fire, from one node that is
    -- well alight, and never past the call radius or the node ceiling.
    if call.spread and nodeCount(call) < (tonumber(config.maxNodes) or 16) then
        local candidates = {}
        for _, node in ipairs(burningNodes(call)) do
            if node.intensity >= (tonumber(config.spreadThreshold) or 70) then candidates[#candidates + 1] = node end
        end
        if #candidates > 0 and chance(config.spreadChance) then
            local parent = candidates[Incident.random(1, #candidates)]
            local target = offset(parent.coords, tonumber(config.spreadRadius) or 7.0)
            if Shared.Distance(target, call.coords) <= (tonumber(call.radius) or 8.0) * 1.6 then
                spawned = newNode(call, target, between(15, 35))
                changed[#changed + 1] = spawned
            end
        end
    end

    return changed, spawned
end

-- Victims deteriorate while they are still in it. A crew that stops the fire
-- but leaves the patients on the lawn still loses them.
function Incident.TickVictims(call)
    local changed = {}
    local severity = Shared.Severity(call)
    local rates = (Shared.Settings().victims or {}).deterioration or {}

    for _, victim in pairs(call.victims or {}) do
        local untreated = victim.state == Fire.VictimState.trapped or victim.state == Fire.VictimState.freed
        if untreated and victim.condition > 0 then
            local rate = victim.state == Fire.VictimState.trapped
                and (tonumber(rates.trapped) or 3.0)
                or (tonumber(rates.freed) or 1.5)
            victim.condition = Shared.Round(math.max(0, victim.condition - rate * (0.5 + severity)), 0)
            if victim.condition <= 0 then victim.state = Fire.VictimState.deceased end
            changed[#changed + 1] = victim
        end
    end

    return changed
end

-- Completion ---------------------------------------------------------------

function Incident.FiresOut(call)
    for _, node in pairs(call.fires or {}) do
        if node.intensity > 0 or node.heat > 0 then return false end
    end
    return true
end

function Incident.VictimsHandled(call)
    for _, victim in pairs(call.victims or {}) do
        if victim.state ~= Fire.VictimState.treated
            and victim.state ~= Fire.VictimState.transported
            and victim.state ~= Fire.VictimState.deceased then
            return false
        end
    end
    return true
end

function Incident.HazardsContained(call)
    for _, hazard in pairs(call.hazards or {}) do
        if not hazard.contained then return false end
    end
    return true
end

function Incident.IsComplete(call)
    return Incident.FiresOut(call) and Incident.VictimsHandled(call) and Incident.HazardsContained(call)
end

-- Water --------------------------------------------------------------------

-- Where this firefighter's water is coming from. A personal extinguisher is
-- their own; a hose or a deck monitor draws from an apparatus they are
-- standing next to, which is what makes parking the engine matter.
function Incident.SupplyFor(source, agentId, coords)
    local record = State.Duty(source)
    if not record then return nil, 'off_duty' end

    if agentId == 'extinguisher' then
        return { kind = 'extinguisher', available = record.extinguisher or 0 }, nil
    end

    local reach = tonumber((Shared.Settings().water or {}).apparatusDistance) or 8.0
    local best, bestDistance
    State.EachOnDuty(function(other)
        local unit = State.Unit(other)
        if not unit or not unit.coords or (unit.water or 0) <= 0 then return end
        local gap = Shared.Distance(coords, unit.coords)
        if gap <= reach and (not bestDistance or gap < bestDistance) then
            best, bestDistance = { kind = 'apparatus', unit = unit, available = unit.water }, gap
        end
    end)

    if not best then return nil, 'no_supply' end
    return best, nil
end

local function drawSupply(source, supply, litres)
    if supply.kind == 'extinguisher' then
        local record = State.Duty(source)
        record.extinguisher = math.max(0, (record.extinguisher or 0) - litres)
        return record.extinguisher
    end
    supply.unit.water = math.max(0, (supply.unit.water or 0) - litres)
    return supply.unit.water
end

-- Applies one client water report. Everything about it is checked: duty, call
-- membership, the node, the agent, the player's real distance to the fire, the
-- report rate, and whether there is any water left to spray.
function Incident.ApplyWater(source, callId, nodeId, litres, agentId)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = State.GetCall(callId)
    if not call or call.state == Fire.CallState.resolved or call.state == Fire.CallState.expired then
        return false, 'unknown_call'
    end

    local node = (call.fires or {})[nodeId]
    if not node then return false, 'unknown_node' end
    if node.intensity <= 0 and node.heat <= 0 then return false, 'already_out' end

    local agent = Shared.Agent(agentId)
    if not agent then return false, 'unknown_agent' end

    local now = GetGameTimer()
    local minimumGap = (tonumber(settings().reportInterval) or 400) * 0.6
    if record.lastWaterAt and now - record.lastWaterAt < minimumGap then return false, 'too_fast' end

    local coords = State.PlayerCoords(source)
    if not coords then return false, 'no_position' end
    if Shared.Distance(coords, node.coords) > (tonumber(agent.range) or 10.0) + 2.0 then return false, 'out_of_range' end

    local supply, supplyError = Incident.SupplyFor(source, agentId, coords)
    if not supply then return false, supplyError end
    if supply.available <= 0 then return false, 'dry' end

    local requested = math.min(tonumber(litres) or 0, supply.available)
    local points, used = Shared.Suppression(requested, agentId, node.intensity + node.heat)
    if points <= 0 then return false, 'no_effect' end

    record.lastWaterAt = now
    call.litres = (call.litres or 0) + used
    call.contribution = call.contribution or {}
    call.contribution[record.identifier] = (call.contribution[record.identifier] or 0) + used

    -- Flame first, then the residual heat underneath it.
    local toFlame = math.min(points, node.intensity)
    node.intensity = Shared.Round(math.max(0, node.intensity - toFlame), 2)
    local remaining = points - toFlame
    if remaining > 0 then node.heat = Shared.Round(math.max(0, node.heat - remaining), 2) end

    local left = drawSupply(source, supply, used)
    local extinguished = node.intensity <= 0 and node.heat <= 0
    if extinguished then
        call.extinguished = (call.extinguished or 0) + 1
        call.fires[nodeId] = nil
    end

    return true, nil, {
        node = node,
        extinguished = extinguished,
        litres = used,
        supply = supply.kind,
        remaining = left
    }
end

-- Timed actions ------------------------------------------------------------

-- Extrication, treatment, and containment are all "stand here and work for N
-- seconds". The client runs the progress bar, but the server records the start
-- and refuses a completion that came back too early or from too far away.
local ACTIONS = {
    free = { certification = 'rescue', duration = function(s) return (s.victims or {}).extricationTime or 12000 end },
    treat = { certification = 'ems', duration = function(s) return (s.victims or {}).treatmentTime or 8000 end },
    contain = { certification = 'hazmat', duration = function(s) return (s.hazards or {}).containmentTime or 15000 end }
}

Incident.Actions = ACTIONS

local function certified(source, action)
    if not action.certification then return true end
    if Shared.Settings().enforceCertifications == false then return true end
    return Shared.HasCertification(State.Profile(source), action.certification)
end

local function targetFor(call, kind, targetId)
    if kind == 'contain' then return (call.hazards or {})[targetId] end
    return (call.victims or {})[targetId]
end

function Incident.BeginAction(source, callId, kind, targetId)
    local action = ACTIONS[kind]
    if not action then return false, 'unknown_action' end

    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = State.GetCall(callId)
    if not call then return false, 'unknown_call' end

    local target = targetFor(call, kind, targetId)
    if not target then return false, 'unknown_target' end
    if not certified(source, action) then return false, 'not_certified' end

    if kind == 'free' and target.state ~= Fire.VictimState.trapped then return false, 'not_trapped' end
    if kind == 'treat' and target.state ~= Fire.VictimState.freed then return false, 'not_ready' end
    if kind == 'contain' and target.contained then return false, 'already_contained' end

    local coords = State.PlayerCoords(source)
    local reach = tonumber((Shared.Settings().dispatch or {}).actionDistance) or 12.0
    if not coords or Shared.Distance(coords, target.coords) > reach then return false, 'out_of_range' end

    local duration = tonumber(action.duration(Shared.Settings())) or 10000
    record.action = {
        kind = kind,
        callId = callId,
        targetId = targetId,
        startedAt = GetGameTimer(),
        duration = duration
    }
    return true, nil, duration
end

function Incident.CancelAction(source)
    local record = State.Duty(source)
    if not record then return false end
    record.action = nil
    return true
end

function Incident.CompleteAction(source)
    local record = State.Duty(source)
    if not record or not record.action then return false, 'no_action' end

    local pending = record.action
    record.action = nil

    -- A 10% tolerance absorbs client tick jitter without letting a client
    -- claim a fifteen second job took two.
    if GetGameTimer() - pending.startedAt < pending.duration * 0.9 then return false, 'too_fast' end

    local call = State.GetCall(pending.callId)
    if not call then return false, 'unknown_call' end

    local target = targetFor(call, pending.kind, pending.targetId)
    if not target then return false, 'unknown_target' end

    local coords = State.PlayerCoords(source)
    local reach = tonumber((Shared.Settings().dispatch or {}).actionDistance) or 12.0
    if not coords or Shared.Distance(coords, target.coords) > reach then return false, 'left_scene' end

    if pending.kind == 'free' then
        target.state = Fire.VictimState.freed
    elseif pending.kind == 'treat' then
        target.state = Fire.VictimState.treated
        target.condition = math.max(target.condition, 55)
        call.rescued = (call.rescued or 0) + 1
    elseif pending.kind == 'contain' then
        target.contained = true
        target.progress = 100
        call.contained = (call.contained or 0) + 1
    end

    target.workedBy = record.identifier
    return true, nil, { kind = pending.kind, call = call, target = target }
end

-- Transport ----------------------------------------------------------------

-- Handing a treated patient over at the hospital. Worth a bonus, and the only
-- way a call closes with nobody left on the lawn.
function Incident.TransportVictim(source, callId, victimId)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = State.GetCall(callId)
    if not call then return false, 'unknown_call' end

    local victim = (call.victims or {})[victimId]
    if not victim then return false, 'unknown_victim' end
    if victim.state ~= Fire.VictimState.treated then return false, 'not_treated' end

    local coords = State.PlayerCoords(source)
    local hospital = Shared.Coords((Shared.Settings().victims or {}).hospital)
    if not coords or not hospital or Shared.Distance(coords, hospital) > 25.0 then return false, 'not_at_hospital' end

    victim.state = Fire.VictimState.transported
    victim.coords = hospital
    call.transported = (call.transported or 0) + 1
    return true, nil, victim
end

-- Supply refills -----------------------------------------------------------

-- Hydrant coordinates come from the client because the props are map objects
-- the server cannot enumerate. The lie is bounded: the server still checks the
-- player and their apparatus are really standing where they claim the hydrant
-- is, so the worst a forged hydrant buys is water at the truck's own position.
function Incident.RefillApparatus(source, hydrantCoords)
    local unit = State.Unit(source)
    if not unit then return false, 'no_unit' end
    if (unit.capacity or 0) <= 0 then return false, 'no_tank' end
    if (unit.water or 0) >= unit.capacity then return false, 'tank_full' end

    local coords = State.PlayerCoords(source)
    local hydrant = Shared.Coords(hydrantCoords)
    local water = Shared.Settings().water or {}
    if not coords or not hydrant then return false, 'no_position' end
    if Shared.Distance(coords, hydrant) > (tonumber(water.hydrantDistance) or 4.0) + 2.0 then return false, 'no_hydrant' end
    if not unit.coords or Shared.Distance(unit.coords, hydrant) > (tonumber(water.apparatusDistance) or 8.0) + 4.0 then
        return false, 'apparatus_too_far'
    end

    local rate = tonumber(water.refillRate) or 400
    unit.water = math.min(unit.capacity, (unit.water or 0) + rate)
    return true, nil, unit.water
end

function Incident.RefillExtinguisher(source)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local capacity = tonumber((Shared.Settings().water or {}).extinguisherCapacity) or 220
    if (record.extinguisher or 0) >= capacity then return false, 'already_full' end

    local coords = State.PlayerCoords(source)
    local station = record.station and Shared.Station(record.station)
    local nearStation = station and coords and Shared.Distance(coords, station.supply or station.coords) <= 6.0
    local supply = coords and select(1, Incident.SupplyFor(source, 'hose', coords))
    if not nearStation and not (supply and supply.kind == 'apparatus') then return false, 'no_supply' end

    record.extinguisher = capacity
    return true, nil, capacity
end

function Incident.RefillAir(source)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local scba = Shared.Settings().scba or {}
    local capacity = tonumber(scba.capacity) or 1500
    if (record.air or 0) >= capacity then return false, 'already_full' end

    local coords = State.PlayerCoords(source)
    local station = record.station and Shared.Station(record.station)
    local nearStation = station and coords and Shared.Distance(coords, station.supply or station.coords) <= 6.0
    local supply = coords and select(1, Incident.SupplyFor(source, 'hose', coords))
    if not nearStation and not supply then return false, 'no_supply' end

    record.air = capacity
    return true, nil, capacity
end

-- Air is spent on the client (it knows what the firefighter is standing in),
-- but the server keeps the authoritative figure so a refill cannot be forged.
function Incident.ConsumeAir(source, amount)
    local record = State.Duty(source)
    if not record then return nil end

    local scba = Shared.Settings().scba or {}
    local maximum = (tonumber(scba.drainInSmoke) or 4) * 3
    record.air = math.max(0, (record.air or 0) - Shared.Clamp(tonumber(amount) or 0, 0, maximum))
    return record.air
end

Bridge.Debug('firefighter incident module loaded')
