-- Authoritative firefighter state.
--
-- Everything the job knows about who is on duty, what is burning, and who is
-- working which call lives in this file. The other server modules mutate it
-- through these accessors so there is exactly one place that decides what a
-- client is allowed to be told.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = {}
Fire.State = State

local roster, calls, units = {}, {}, {}
local sequence = 0

-- Profiles are resource-owned data: XP, signed-off training, and career stats.
-- The framework still owns the job, the grade, and the bank balance.
local profiles = DAG.Repository.Create('firefighter_profiles', {
    validate = function(record)
        if type(record.identifier) ~= 'string' or record.identifier == '' then
            return false, 'A firefighter profile requires an identifier'
        end
        if type(record.xp) ~= 'number' or record.xp < 0 then
            return false, 'A firefighter profile requires a non-negative XP total'
        end
        return true
    end
})

State.profiles = profiles

-- Profiles -----------------------------------------------------------------

function State.ProfileFor(identifier, name)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    return Shared.NormalizeProfile(profiles.get(identifier), identifier, name)
end

function State.Profile(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return nil end
    return State.ProfileFor(identifier, Bridge.GetName(source))
end

function State.SaveProfile(profile)
    if type(profile) ~= 'table' or type(profile.identifier) ~= 'string' then return nil, 'invalid_profile' end
    return profiles.save(profile.identifier, profile)
end

-- Duty roster --------------------------------------------------------------

function State.Duty(source)
    return roster[source]
end

function State.IsOnDuty(source)
    return roster[source] ~= nil
end

function State.GoOnDuty(source, station)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return nil, 'no_identifier' end

    local settings = Shared.Settings()
    roster[source] = {
        source = source,
        identifier = identifier,
        name = Bridge.GetName(source),
        station = station and station.id or nil,
        since = GetGameTimer(),
        callId = nil,
        onScene = false,
        air = tonumber((settings.scba or {}).capacity) or 0,
        extinguisher = tonumber((settings.water or {}).extinguisherCapacity) or 0
    }
    return roster[source]
end

function State.GoOffDuty(source)
    local record = roster[source]
    roster[source] = nil
    return record
end

function State.Roster()
    local list = {}
    for _, record in pairs(roster) do list[#list + 1] = record end
    table.sort(list, function(a, b) return a.since < b.since end)
    return list
end

function State.OnDutyCount()
    local count = 0
    for _ in pairs(roster) do count = count + 1 end
    return count
end

function State.EachOnDuty(handler)
    for source, record in pairs(roster) do handler(source, record) end
end

-- Apparatus ----------------------------------------------------------------

-- One unit per firefighter. The water tank is tracked here rather than on the
-- vehicle so a client cannot report its own tank full.
function State.SetUnit(source, unit)
    units[source] = unit
    return unit
end

function State.Unit(source)
    return units[source]
end

function State.ClearUnit(source)
    local unit = units[source]
    units[source] = nil
    return unit
end

-- Calls --------------------------------------------------------------------

function State.NextCallId()
    sequence = sequence + 1
    return Shared.FormatCallId(sequence), sequence
end

function State.AddCall(call)
    calls[call.id] = call
    return call
end

function State.GetCall(id)
    if type(id) ~= 'string' then return nil end
    return calls[id]
end

function State.RemoveCall(id)
    local call = calls[id]
    calls[id] = nil
    return call
end

function State.Calls()
    return calls
end

function State.ActiveCalls()
    local list = {}
    for _, call in pairs(calls) do
        if call.state ~= Fire.CallState.resolved and call.state ~= Fire.CallState.expired then
            list[#list + 1] = call
        end
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.createdAt < b.createdAt
    end)
    return list
end

function State.ResponderCount(call)
    local count = 0
    for _ in pairs(call.responders or {}) do count = count + 1 end
    return count
end

-- Network payloads ---------------------------------------------------------

-- Only these fields cross to a client. Coordinates become plain tables because
-- the client half of the job re-reads them out of msgpack, and internal
-- bookkeeping (payout accumulators, per-responder water ledgers) stays server
-- side where it cannot be read or replayed.
local function publicNode(node)
    return {
        id = node.id,
        coords = Shared.Coords(node.coords),
        intensity = Shared.Round(node.intensity, 1),
        kind = node.kind,
        scale = node.scale
    }
end

local function publicVictim(victim)
    return {
        id = victim.id,
        coords = Shared.Coords(victim.coords),
        state = victim.state,
        condition = Shared.Round(victim.condition, 0),
        heading = victim.heading,
        trapped = victim.state == Fire.VictimState.trapped
    }
end

local function publicHazard(hazard)
    return {
        id = hazard.id,
        coords = Shared.Coords(hazard.coords),
        progress = Shared.Round(hazard.progress, 0),
        contained = hazard.contained == true,
        label = hazard.label
    }
end

function State.PublicCall(call)
    if not call then return nil end

    local fires, victims, hazards = {}, {}, {}
    for id, node in pairs(call.fires or {}) do fires[id] = publicNode(node) end
    for id, victim in pairs(call.victims or {}) do victims[id] = publicVictim(victim) end
    for id, hazard in pairs(call.hazards or {}) do hazards[id] = publicHazard(hazard) end

    local responders = {}
    for identifier, responder in pairs(call.responders or {}) do
        responders[#responders + 1] = {
            identifier = identifier,
            name = responder.name,
            rank = responder.rank,
            onScene = responder.onScene == true
        }
    end

    return {
        id = call.id,
        kind = call.kind,
        label = call.label,
        location = call.location,
        coords = Shared.Coords(call.coords),
        radius = call.radius,
        priority = call.priority,
        state = call.state,
        createdAt = call.createdAt,
        severity = Shared.Severity(call),
        requiredCertification = call.requiredCertification,
        owner = call.owner,
        fires = fires,
        victims = victims,
        hazards = hazards,
        responders = responders
    }
end

-- Broadcasts ---------------------------------------------------------------

-- On-duty firefighters see dispatch traffic. `broadcastToAll` exists for
-- servers that pipe the feed into a public scanner resource.
function State.Broadcast(event, ...)
    if (Shared.Settings().dispatch or {}).broadcastToAll then
        return TriggerClientEvent(Bridge.Event(event), -1, ...)
    end
    for source in pairs(roster) do
        TriggerClientEvent(Bridge.Event(event), source, ...)
    end
end

-- A whole-call payload is the expensive message in the job, so the simulation
-- tick only sends one when something a client can see has actually moved.
-- Node, victim, and hazard changes have compact events of their own.
function State.SyncCall(call, target)
    local payload = State.PublicCall(call)
    if target then return TriggerClientEvent(Bridge.Event('fire:call'), target, payload) end

    call.dirty = false
    call.syncedState, call.syncedOwner = call.state, call.owner
    State.Broadcast('fire:call', payload)
end

function State.CallNeedsSync(call)
    return call.dirty == true or call.state ~= call.syncedState or call.owner ~= call.syncedOwner
end

function State.SyncRemoval(id, reason)
    State.Broadcast('fire:callRemoved', id, reason)
end

-- Sent when a firefighter clocks on, so a late joiner sees the board rather
-- than waiting for the next incident.
function State.SyncAll(target)
    local payload = {}
    for _, call in ipairs(State.ActiveCalls()) do payload[#payload + 1] = State.PublicCall(call) end
    TriggerClientEvent(Bridge.Event('fire:sync'), target, payload)
end

function State.SyncDuty(source)
    local record = roster[source]
    TriggerClientEvent(Bridge.Event('fire:duty'), source, record and {
        station = record.station,
        since = record.since,
        callId = record.callId,
        air = record.air,
        extinguisher = record.extinguisher
    } or false)
end

function State.SyncUnit(source)
    local unit = units[source]
    TriggerClientEvent(Bridge.Event('fire:unit'), source, unit and {
        id = unit.id,
        label = unit.label,
        netId = unit.netId,
        water = Shared.Round(unit.water, 0),
        capacity = unit.capacity
    } or false)
end

-- Server-side ped coordinates. Every distance check in the job runs against
-- this rather than against a coordinate the client sent, so a client that lies
-- about where it is stops being able to put out fires across the map.
function State.PlayerCoords(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return Shared.Coords(GetEntityCoords(ped))
end

function State.NearCall(source, call, distance)
    local coords = State.PlayerCoords(source)
    if not coords or not call then return false, math.huge end
    local gap = Shared.Distance(coords, call.coords)
    return gap <= (distance or (Shared.Settings().dispatch or {}).onSceneDistance or 90.0), gap
end

-- A single node changing is the most frequent update in the job, so it gets a
-- compact event of its own rather than a whole-call resync.
function State.SyncNode(call, node)
    State.Broadcast('fire:node', call.id, {
        id = node.id,
        intensity = Shared.Round(node.intensity, 1),
        heat = Shared.Round(node.heat, 1),
        coords = Shared.Coords(node.coords),
        kind = node.kind,
        scale = node.scale
    })
end

function State.SyncVictim(call, victim)
    State.Broadcast('fire:victim', call.id, publicVictim(victim))
end

function State.SyncHazard(call, hazard)
    State.Broadcast('fire:hazard', call.id, publicHazard(hazard))
end
