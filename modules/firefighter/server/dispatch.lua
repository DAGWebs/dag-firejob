-- Dispatch: where calls come from, which department owns them, who is on them,
-- and when they close.
--
-- The simulation tick lives here too, because growth, arrival detection, and
-- the decision to close a call are the same heartbeat.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = Fire.Incident
local Departments = Fire.Departments
local Database = Fire.Database
local Dispatch = {}
Fire.Dispatch = Dispatch

Dispatch.random = math.random

local function dispatchSettings()
    return Shared.Settings().dispatch or {}
end

-- Radio traffic. One event carries both the toast and the line a client can
-- print into a scanner, so a server can restyle it in one place.
local function radio(message, kind, call)
    if call then return State.BroadcastCall(call, 'fire:radio', message, kind or 'inform', call.id) end
    State.Broadcast('fire:radio', message, kind or 'inform', nil)
end

Dispatch.Radio = radio

-- Creating calls -----------------------------------------------------------

local function pickLocation(callType)
    local locations = callType.locations or {}
    if #locations == 0 then return nil end
    return locations[Dispatch.random(1, #locations)]
end

-- An open call close to the same spot is escalated instead of duplicated, so a
-- pile-up does not become six separate collisions on one junction.
function Dispatch.NearbyCall(coords, distance)
    local reach = tonumber(distance) or tonumber((Shared.Settings().events or {}).dedupeDistance) or 45.0
    for _, call in pairs(State.Calls()) do
        if call.state ~= Fire.CallState.resolved and call.state ~= Fire.CallState.expired then
            if Shared.Distance(call.coords, coords) <= reach then return call end
        end
    end
    return nil
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

    if not options.force then
        local nearby = Dispatch.NearbyCall(coords, options.dedupe)
        if nearby then return nil, 'location_busy', nearby end
    end

    local department = Shared.Department(options.department) or Shared.DepartmentForCoords(coords)
    local id, sequence = State.NextCallId()
    local call = {
        id = id,
        sequence = sequence,
        kind = callType.id,
        label = callType.label,
        location = options.label or location.label or 'Unknown location',
        coords = coords,
        department = department and department.id or nil,
        toned = {},
        radius = tonumber(callType.radius) or 8.0,
        priority = tonumber(callType.priority) or 2,
        state = Fire.CallState.pending,
        source = options.source or 'ambient',
        reportedBy = options.reportedBy,
        spread = callType.spread == true,
        extrication = callType.extrication == true,
        units = callType.units,
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

-- Weighted by the run card, so medicals and collisions come up far more often
-- than a working fire, the way they do on a real one.
function Dispatch.RandomKind()
    local pool = {}
    for _, callType in ipairs(Shared.CallTypes()) do
        if #(callType.locations or {}) > 0 then
            for _ = 1, Shared.CallWeight(callType) do pool[#pool + 1] = callType.id end
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

    -- Another department's call is only answerable once it has been toned out
    -- for mutual aid.
    if call.department and record.department ~= call.department and not (call.toned or {})[record.department] then
        return false, 'other_department'
    end

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

    radio(('%s escalating - %s at %s, still unassigned'):format(call.id, call.label, call.location), 'error', call)
    State.SyncCall(call)
end

Dispatch.Escalate = escalate

local function logCall(call, reason, payout)
    if not Database.Available() or (Shared.Settings().database or {}).logCalls == false then return end

    local responders, lost = {}, 0
    for identifier, responder in pairs(call.responders or {}) do
        responders[#responders + 1] = { identifier = identifier, name = responder.name, onScene = responder.onScene }
    end
    for _, victim in pairs(call.victims or {}) do
        if victim.state == Fire.VictimState.deceased then lost = lost + 1 end
    end

    local query = ([[INSERT INTO `%s`
        (`call_ref`, `department`, `kind`, `location`, `priority`, `source`, `response_time`,
         `duration`, `extinguished`, `rescued`, `lost`, `payout`, `responders`, `outcome`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]]):format(Database.Table('calls'))

    Database.Execute(query, {
        call.id, call.department, call.kind, call.location, call.priority, call.source,
        call.responseTime, (call.resolvedAt or GetGameTimer()) - call.createdAt,
        call.extinguished or 0, (call.rescued or 0) + (call.transported or 0), lost,
        math.floor(payout or 0), json.encode(responders), reason
    })
end

function Dispatch.Resolve(callId, reason)
    local call = State.GetCall(callId)
    if not call then return false, 'unknown_call' end
    if call.state == Fire.CallState.resolved then return false, 'already_resolved' end

    call.state = Fire.CallState.resolved
    call.resolvedAt = GetGameTimer()

    local awards, paid = Fire.Progression.Award(call, reason)

    for identifier, responder in pairs(call.responders) do
        local record = State.Duty(responder.source)
        if record and record.callId == call.id and record.identifier == identifier then
            record.callId = nil
            State.SyncDuty(responder.source)
        end
    end

    State.SyncCall(call)
    State.SyncRemoval(call, reason or 'resolved')
    logCall(call, reason or 'resolved', paid)
    -- Kept in memory as well as in the log, so the terminal has a history on a
    -- server with no database at all.
    if Fire.Mdt and not call.training then Fire.Mdt.Remember(call, reason or 'resolved', paid) end

    -- A player whose own car burned is a billable party the server actually
    -- knows about; everything else is billed by hand from the terminal.
    if Fire.Billing and not call.training then
        local ok, err = pcall(Fire.Billing.BillCall, call)
        if not ok then Bridge.Print('automatic billing failed: %s', tostring(err)) end
    end

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

    State.SyncRemoval(call, 'expired')
    logCall(call, 'expired', 0)
    if Fire.Mdt then Fire.Mdt.Remember(call, 'expired', 0) end
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
-- client report, because the pump's position decides who can draw water and
-- whether the supply line is still connected.
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
        if Incident.CheckSupply(unit) then
            State.SyncUnit(source)
            Bridge.Notify(source, 'The supply line pulled off the hydrant.', 'error', 4000)
        end
    end)
end

Dispatch.RefreshUnits = refreshUnits

-- One simulation step for every open call.
function Dispatch.Tick()
    local now = GetGameTimer()
    local config = dispatchSettings()

    refreshUnits()

    for _, call in ipairs(State.OpenCalls()) do
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

        -- A department with nobody on duty cannot answer its own calls, so
        -- after a while its neighbours are toned out to cover it.
        if Departments.NeedsMutualAid(call, now) and Departments.ToneOut(call) then
            call.mutualAid = true
            call.dirty = true
            radio(('%s requesting mutual aid at %s'):format(call.id, call.location), 'error', call)
        end

        local changed = select(1, Incident.Tick(call))
        for _, node in ipairs(changed) do State.SyncNode(call, node) end
        for _, victim in ipairs(Incident.TickVictims(call)) do State.SyncVictim(call, victim) end

        if call.training then
            -- Academy drills are scored by the academy, not closed by dispatch.
            if State.CallNeedsSync(call) then State.SyncCall(call) end
        elseif Incident.IsComplete(call) and (responders > 0 or call.firstArrivalAt) then
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

function Dispatch.ShouldGenerate()
    if not Shared.Enabled() then return false end
    if (Shared.Settings().events or {}).ambient and (Shared.Settings().events or {}).ambient.enabled == false then
        return false
    end

    local onDuty = State.OnDutyCount()
    if onDuty < (tonumber(dispatchSettings().minimumOnDuty) or 1) then return false end
    return #State.ActiveCalls() < Shared.MaxActiveCalls(onDuty)
end

function Dispatch.GenerateOne()
    if not Dispatch.ShouldGenerate() then return nil end
    local kind = Dispatch.RandomKind()
    if not kind then return nil end
    return Dispatch.Create(kind, { source = 'ambient' })
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

    local record = State.Duty(dropped)
    Dispatch.Leave(dropped, 'quiet')
    State.ClearUnit(dropped)
    State.GoOffDuty(dropped)
    if record then State.DropCachedProfile(record.identifier) end
end)
