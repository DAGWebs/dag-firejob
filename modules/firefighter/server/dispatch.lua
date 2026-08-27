-- Dispatch: where calls come from, who is on them, and when they close.
--
-- The simulation tick lives here too, because growth, arrival detection, and
-- the decision to close a call are the same heartbeat.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = Fire.Incident
local Dispatch = {}
Fire.Dispatch = Dispatch

Dispatch.random = math.random

local function dispatchSettings()
    return Shared.Settings().dispatch or {}
end

-- Radio traffic. One event carries both the toast and the line a client can
-- print into a scanner, so a server can restyle it in one place.
local function radio(message, kind, call)
    State.Broadcast('fire:radio', message, kind or 'inform', call and call.id or nil)
end

Dispatch.Radio = radio

-- Creating calls -----------------------------------------------------------

local function pickLocation(callType)
    local locations = callType.locations or {}
    if #locations == 0 then return nil end
    return locations[Dispatch.random(1, #locations)]
end

-- A location already being worked is skipped, so two simultaneous calls never
-- land on the same building.
local function locationIsFree(coords)
    for _, call in pairs(State.Calls()) do
        if call.state ~= Fire.CallState.resolved and call.state ~= Fire.CallState.expired then
            if Shared.Distance(call.coords, coords) < 60.0 then return false end
        end
    end
    return true
end

function Dispatch.Create(kind, options)
    options = options or {}
    local callType = Shared.CallType(kind)
    if not callType then return nil, 'unknown_call_type' end

    local location = options.location
    if not location then
        location = pickLocation(callType)
        if not location then return nil, 'no_location' end
    end

    local coords = Shared.Coords(options.coords or location.coords)
    if not coords then return nil, 'no_coords' end
    if not options.force and not locationIsFree(coords) then return nil, 'location_busy' end

    local id, sequence = State.NextCallId()
    local call = {
        id = id,
        sequence = sequence,
        kind = callType.id,
        label = callType.label,
        location = options.label or location.label or 'Unknown location',
        coords = coords,
        radius = tonumber(callType.radius) or 8.0,
        priority = tonumber(callType.priority) or 2,
        state = Fire.CallState.pending,
        spread = callType.spread == true,
        requiredCertification = callType.requiredCertification,
        payout = tonumber(callType.payout) or 0,
        xp = tonumber(callType.xp) or 0,
        createdAt = GetGameTimer(),
        responders = {},
        escalations = 0
    }

    Incident.Build(call, callType)
    State.AddCall(call)
    State.SyncCall(call)

    radio(('%s - %s at %s'):format(call.id, call.label, call.location), 'inform', call)
    return call
end

-- Weighted by priority so a working fire is more likely than an alarm, without
-- ever excluding the quieter calls entirely.
function Dispatch.RandomKind()
    local pool = {}
    for _, callType in ipairs(Shared.CallTypes()) do
        if #(callType.locations or {}) > 0 then
            local weight = math.max(1, 4 - (tonumber(callType.priority) or 2))
            for _ = 1, weight do pool[#pool + 1] = callType.id end
        end
    end
    if #pool == 0 then return nil end
    return pool[Dispatch.random(1, #pool)]
end

-- Responders ---------------------------------------------------------------

function Dispatch.Join(source, callId)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = State.GetCall(callId)
    if not call then return false, 'unknown_call' end
    if call.state == Fire.CallState.resolved or call.state == Fire.CallState.expired then return false, 'call_closed' end

    if record.callId and record.callId ~= callId then Dispatch.Leave(source, 'reassigned') end

    local profile = State.Profile(source)
    if call.requiredCertification and Shared.Settings().enforceCertifications ~= false then
        if not Shared.HasCertification(profile, call.requiredCertification) then return false, 'not_certified' end
    end

    call.responders[record.identifier] = {
        source = source,
        name = record.name,
        rank = Shared.RankLabel(profile and profile.xp or 0),
        joinedAt = GetGameTimer(),
        onScene = false
    }
    record.callId = callId

    if call.state == Fire.CallState.pending then call.state = Fire.CallState.assigned end

    State.SyncCall(call)
    State.SyncDuty(source)
    radio(('%s responding to %s'):format(record.name, call.id), 'inform', call)
    return true, nil, call
end

function Dispatch.Leave(source, reason)
    local record = State.Duty(source)
    if not record or not record.callId then return false, 'not_assigned' end

    local call = State.GetCall(record.callId)
    record.callId = nil
    if not call then return true end

    call.responders[record.identifier] = nil
    if call.owner == source then call.owner = nil end

    if State.ResponderCount(call) == 0 and call.state ~= Fire.CallState.resolved then
        call.state = Fire.CallState.pending
    end

    State.SyncCall(call)
    State.SyncDuty(source)
    if reason ~= 'quiet' then
        radio(('%s cleared from %s'):format(record.name, call.id), 'inform', call)
    end
    return true
end

-- Exactly one client renders the fires for a call. Script fires are networked
-- by the engine, so letting every responder start them would stack duplicates
-- on the same node.
local function assignOwner(call)
    if call.owner and State.IsOnDuty(call.owner) then
        local record = State.Duty(call.owner)
        if record and record.callId == call.id then return call.owner end
    end

    for _, responder in pairs(call.responders) do
        if responder.onScene and State.IsOnDuty(responder.source) then
            call.owner = responder.source
            return call.owner
        end
    end

    call.owner = nil
    return nil
end

-- Lifecycle ----------------------------------------------------------------

local function escalate(call)
    call.escalations = call.escalations + 1
    local callType = Shared.CallType(call.kind)
    local config = Shared.Settings().fire or {}

    if Incident.NodeCount(call) < (tonumber(config.maxNodes) or 16) then
        local _, seed = next(call.fires)
        local origin = seed and seed.coords or call.coords
        Incident.NewNode(call, {
            x = origin.x + (Dispatch.random() - 0.5) * call.radius,
            y = origin.y + (Dispatch.random() - 0.5) * call.radius,
            z = origin.z
        }, 45 + call.escalations * 10)
    end

    call.payout = math.floor(call.payout * 1.2)
    call.xp = math.floor(call.xp * 1.15)
    call.escalatedAt = GetGameTimer()

    radio(('%s escalating - %s at %s, still unassigned'):format(
        call.id, (callType and callType.label or call.label), call.location), 'error', call)
    State.SyncCall(call)
end

function Dispatch.Resolve(callId, reason)
    local call = State.GetCall(callId)
    if not call then return false, 'unknown_call' end
    if call.state == Fire.CallState.resolved then return false, 'already_resolved' end

    call.state = Fire.CallState.resolved
    call.resolvedAt = GetGameTimer()

    local awards = Fire.Progression.Award(call, reason)

    for identifier, responder in pairs(call.responders) do
        local record = State.Duty(responder.source)
        if record and record.callId == call.id and record.identifier == identifier then
            record.callId = nil
            State.SyncDuty(responder.source)
        end
    end

    State.SyncCall(call)
    State.SyncRemoval(call.id, reason or 'resolved')
    State.RemoveCall(call.id)

    radio(('%s closed - %s'):format(call.id, reason or 'under control'), 'success', call)
    return true, nil, awards
end

function Dispatch.Expire(callId)
    local call = State.GetCall(callId)
    if not call then return false end

    call.state = Fire.CallState.expired
    for identifier, responder in pairs(call.responders) do
        local record = State.Duty(responder.source)
        if record and record.identifier == identifier then
            record.callId = nil
            State.SyncDuty(responder.source)
        end
    end

    State.SyncRemoval(call.id, 'expired')
    State.RemoveCall(call.id)
    radio(('%s burned out before a unit arrived'):format(call.id), 'error', call)
    return true
end

-- Arrival ------------------------------------------------------------------

local function updateAttendance(call)
    local distance = tonumber(dispatchSettings().onSceneDistance) or 90.0
    local anyOnScene = false

    for identifier, responder in pairs(call.responders) do
        local record = State.Duty(responder.source)
        if not record or record.identifier ~= identifier then
            -- The responder dropped or clocked off; drop them from the call.
            call.responders[identifier] = nil
            call.dirty = true
        else
            local near = State.NearCall(responder.source, call, distance)
            if near and not responder.onScene then
                responder.onScene = true
                responder.arrivedAt = GetGameTimer()
                call.dirty = true
                if not call.firstArrivalAt then
                    call.firstArrivalAt = responder.arrivedAt
                    call.responseTime = call.firstArrivalAt - call.createdAt
                    radio(('%s on scene at %s'):format(responder.name, call.id), 'success', call)
                end
            elseif not near and responder.onScene then
                responder.onScene = false
                call.dirty = true
            end
            anyOnScene = anyOnScene or responder.onScene
        end
    end

    return anyOnScene
end

-- Apparatus positions come from the entity the server itself owns, not from a
-- client report, because the pump's position decides who can draw water.
local function refreshUnits()
    State.EachOnDuty(function(source)
        local unit = State.Unit(source)
        if not unit or not unit.netId then return end
        local entity = NetworkGetEntityFromNetworkId(unit.netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) then
            unit.coords = nil
            return
        end
        unit.coords = Shared.Coords(GetEntityCoords(entity))
    end)
end

Dispatch.RefreshUnits = refreshUnits

-- One simulation step for every open call.
function Dispatch.Tick()
    local now = GetGameTimer()
    local config = dispatchSettings()

    refreshUnits()

    for _, call in ipairs(State.ActiveCalls()) do
        local anyOnScene = updateAttendance(call)
        local responders = State.ResponderCount(call)

        if anyOnScene then
            call.state = Fire.CallState.working
        elseif responders > 0 then
            call.state = Fire.CallState.assigned
        else
            call.state = Fire.CallState.pending
        end

        assignOwner(call)

        local changed = select(1, Incident.Tick(call))
        for _, node in ipairs(changed) do State.SyncNode(call, node) end
        for _, victim in ipairs(Incident.TickVictims(call)) do State.SyncVictim(call, victim) end

        if Incident.IsComplete(call) and (responders > 0 or call.firstArrivalAt) then
            Dispatch.Resolve(call.id, 'under control')
        elseif responders == 0 and now - call.createdAt >= (tonumber(config.expireAfter) or 1200000) then
            Dispatch.Expire(call.id)
        elseif responders == 0
            and now - (call.escalatedAt or call.createdAt) >= (tonumber(config.escalateAfter) or 240000) then
            escalate(call)
        elseif State.CallNeedsSync(call) then
            State.SyncCall(call)
        end
    end
end

-- Threads ------------------------------------------------------------------

local function activeCallCount()
    return #State.ActiveCalls()
end

function Dispatch.ShouldGenerate()
    local config = dispatchSettings()
    if not Shared.Enabled() then return false end
    if State.OnDutyCount() < (tonumber(config.minimumOnDuty) or 1) then return false end
    return activeCallCount() < (tonumber(config.maxActive) or 3)
end

function Dispatch.GenerateOne()
    if not Dispatch.ShouldGenerate() then return nil end
    local kind = Dispatch.RandomKind()
    if not kind then return nil end
    return Dispatch.Create(kind)
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    local interval = tonumber((Shared.Settings().fire or {}).tickInterval) or 2000
    while true do
        Wait(interval)
        if Shared.Enabled() then
            local ok, err = pcall(Dispatch.Tick)
            if not ok then Bridge.Print('dispatch tick failed: %s', tostring(err)) end
        end
    end
end)

CreateThread(function()
    Bridge.AwaitReady(10000)
    while true do
        local config = dispatchSettings()
        local minimum = tonumber((config.interval or {}).min) or 180000
        local maximum = tonumber((config.interval or {}).max) or 420000
        Wait(Dispatch.random(minimum, math.max(minimum, maximum)))

        local ok, err = pcall(Dispatch.GenerateOne)
        if not ok then Bridge.Print('dispatch generator failed: %s', tostring(err)) end
    end
end)

-- A firefighter who disconnects leaves the roster and the call with them.
AddEventHandler('playerDropped', function()
    local dropped = source
    if not State.IsOnDuty(dropped) then return end
    Dispatch.Leave(dropped, 'quiet')
    State.ClearUnit(dropped)
    State.GoOffDuty(dropped)
end)
