-- Authoritative firefighter state.
--
-- Everything the job knows about who is on duty, what is burning, and who is
-- working which call lives in this file. The other server modules mutate it
-- through these accessors so there is exactly one place that decides what a
-- client is allowed to be told.
--
-- Profiles are cached here and written behind: reads stay synchronous for
-- every gameplay path, and the SQL round trip happens on the flush thread.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Database = Fire.Database
local State = {}
Fire.State = State

local roster, calls, units = {}, {}, {}
local cache, dirty = {}, {}
local sequence = 0

-- The JSON store is the fallback when no SQL driver is running, and it is also
-- what the template's own repository tests exercise.
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

local function decode(value)
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' or value == '' then return nil end
    local ok, decoded = pcall(json.decode, value)
    return ok and decoded or nil
end

local function fromRow(row, identifier, name)
    if type(row) ~= 'table' then return nil end
    return Shared.NormalizeProfile({
        identifier = row.identifier or identifier,
        name = row.name or name,
        department = row.department,
        xp = tonumber(row.xp) or 0,
        certifications = decode(row.certifications) or {},
        training = decode(row.training) or {},
        stats = decode(row.stats) or {},
        hiredAt = tonumber(row.hired_at)
    }, identifier, name)
end

function State.CacheProfile(profile)
    if type(profile) ~= 'table' or type(profile.identifier) ~= 'string' then return nil end
    cache[profile.identifier] = profile
    return profile
end

-- Synchronous read. After a firefighter has clocked on their profile is always
-- cached, so every gameplay path can rely on this.
function State.ProfileFor(identifier, name)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    if cache[identifier] then return cache[identifier] end

    if not Database.Available() then
        return State.CacheProfile(Shared.NormalizeProfile(profiles.get(identifier), identifier, name))
    end
    -- No cached row and SQL owns the data: hand back a default rather than a
    -- stale one, and let LoadProfile fill it in.
    return Shared.NormalizeProfile(nil, identifier, name)
end

function State.Profile(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return nil end
    return State.ProfileFor(identifier, Bridge.GetName(source))
end

-- Async load. Used before anything that would write a profile, so a firefighter
-- never clocks on against an empty record and overwrites their career.
function State.LoadProfile(identifier, name, callback)
    if type(identifier) ~= 'string' or identifier == '' then
        if callback then callback(nil) end
        return
    end

    if not Database.Available() then
        local profile = State.CacheProfile(Shared.NormalizeProfile(profiles.get(identifier), identifier, name))
        if callback then callback(profile) end
        return
    end

    local query = ('SELECT * FROM `%s` WHERE `identifier` = ? LIMIT 1'):format(Database.Table('profiles'))
    Database.Single(query, { identifier }, function(row)
        local profile = fromRow(row, identifier, name) or Shared.NormalizeProfile(nil, identifier, name)
        State.CacheProfile(profile)
        if callback then callback(profile) end
    end)
end

function State.SaveProfile(profile)
    if type(profile) ~= 'table' or type(profile.identifier) ~= 'string' then return nil, 'invalid_profile' end
    State.CacheProfile(profile)

    if not Database.Available() then
        return profiles.save(profile.identifier, profile)
    end

    dirty[profile.identifier] = true
    return profile
end

local function writeProfile(profile)
    local query = ([[INSERT INTO `%s`
        (`identifier`, `name`, `department`, `xp`, `certifications`, `training`, `stats`, `hired_at`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `name` = VALUES(`name`), `department` = VALUES(`department`), `xp` = VALUES(`xp`),
            `certifications` = VALUES(`certifications`), `training` = VALUES(`training`),
            `stats` = VALUES(`stats`), `hired_at` = VALUES(`hired_at`)]]):format(Database.Table('profiles'))

    Database.Execute(query, {
        profile.identifier,
        profile.name,
        profile.department,
        math.floor(profile.xp or 0),
        json.encode(profile.certifications or {}),
        json.encode(profile.training or {}),
        json.encode(profile.stats or {}),
        profile.hiredAt
    })
end

function State.FlushProfiles()
    local written = 0
    for identifier in pairs(dirty) do
        local profile = cache[identifier]
        dirty[identifier] = nil
        if profile then
            writeProfile(profile)
            written = written + 1
        end
    end
    return written
end

function State.DropCachedProfile(identifier)
    if dirty[identifier] and cache[identifier] then
        writeProfile(cache[identifier])
        dirty[identifier] = nil
    end
    cache[identifier] = nil
end

-- Ordered by experience. Reads straight from SQL when it owns the data so the
-- board covers everyone who ever served, not just who is cached.
function State.Leaderboard(limit, callback)
    local capped = math.floor(Shared.Clamp(tonumber(limit) or 10, 1, 50))

    if not Database.Available() then
        local list = {}
        for identifier, record in pairs(profiles.all()) do
            list[#list + 1] = Shared.NormalizeProfile(record, identifier, record.name)
        end
        return callback(list, capped)
    end

    local query = ('SELECT * FROM `%s` ORDER BY `xp` DESC LIMIT %d'):format(Database.Table('profiles'), capped)
    Database.Query(query, {}, function(rows)
        local list = {}
        for _, row in ipairs(rows or {}) do
            list[#list + 1] = fromRow(row, row.identifier, row.name)
        end
        callback(list, capped)
    end)
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
    local department = station and Shared.Department(station.department)
    roster[source] = {
        source = source,
        identifier = identifier,
        name = Bridge.GetName(source),
        station = station and station.id or nil,
        department = department and department.id or nil,
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

function State.Roster(departmentId)
    local list = {}
    for _, record in pairs(roster) do
        if not departmentId or record.department == departmentId then list[#list + 1] = record end
    end
    table.sort(list, function(a, b) return a.since < b.since end)
    return list
end

function State.OnDutyCount(departmentId)
    local count = 0
    for _, record in pairs(roster) do
        if not departmentId or record.department == departmentId then count = count + 1 end
    end
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

local function isOpen(call)
    return call.state ~= Fire.CallState.resolved and call.state ~= Fire.CallState.expired
end

-- Everything the simulation has to step, training drills included.
function State.OpenCalls()
    local list = {}
    for _, call in pairs(calls) do
        if isOpen(call) then list[#list + 1] = call end
    end
    table.sort(list, function(a, b) return a.createdAt < b.createdAt end)
    return list
end

-- The dispatch board. Academy drills belong to one trainee and never appear on
-- it, whoever is on duty.
function State.ActiveCalls(departmentId)
    local list = {}
    for _, call in pairs(calls) do
        local open = isOpen(call) and not call.training
        if open and (not departmentId or call.department == departmentId or call.toned[departmentId]) then
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
        model = victim.model,
        wreck = victim.wreck,
        stage = victim.stage,
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
        department = call.department,
        coords = Shared.Coords(call.coords),
        radius = call.radius,
        priority = call.priority,
        state = call.state,
        source = call.source,
        createdAt = call.createdAt,
        severity = Shared.Severity(call),
        requiredCertification = call.requiredCertification,
        extrication = call.extrication,
        units = call.units,
        wrecks = call.wrecks,
        owner = call.owner,
        fires = fires,
        victims = victims,
        hazards = hazards,
        responders = responders
    }
end

-- Broadcasts ---------------------------------------------------------------

-- Department traffic. A call belongs to one department and is heard by its
-- on-duty members, plus any department it has been toned out to for mutual
-- aid. `broadcastToAll` exists for servers that pipe the feed into a public
-- scanner resource.
function State.Broadcast(event, ...)
    if (Shared.Settings().dispatch or {}).broadcastToAll then
        return TriggerClientEvent(Bridge.Event(event), -1, ...)
    end
    for source in pairs(roster) do
        TriggerClientEvent(Bridge.Event(event), source, ...)
    end
end

function State.BroadcastCall(call, event, ...)
    -- A drill is one trainee's business; nobody else hears it.
    if call.trainee then
        return TriggerClientEvent(Bridge.Event(event), call.trainee, ...)
    end
    if (Shared.Settings().dispatch or {}).broadcastToAll then
        return TriggerClientEvent(Bridge.Event(event), -1, ...)
    end

    for source, record in pairs(roster) do
        local hears = call.department == nil
            or record.department == call.department
            or (call.toned and call.toned[record.department])
        if hears then TriggerClientEvent(Bridge.Event(event), source, ...) end
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
    State.BroadcastCall(call, 'fire:call', payload)
end

function State.CallNeedsSync(call)
    return call.dirty == true or call.state ~= call.syncedState or call.owner ~= call.syncedOwner
end

function State.SyncRemoval(call, reason)
    State.BroadcastCall(call, 'fire:callRemoved', call.id, reason)
end

-- Sent when a firefighter clocks on, so a late joiner sees the board rather
-- than waiting for the next incident.
function State.SyncAll(target)
    local record = roster[target]
    local payload = {}
    for _, call in ipairs(State.ActiveCalls(record and record.department)) do
        payload[#payload + 1] = State.PublicCall(call)
    end
    TriggerClientEvent(Bridge.Event('fire:sync'), target, payload)
end

function State.SyncDuty(source)
    local record = roster[source]
    TriggerClientEvent(Bridge.Event('fire:duty'), source, record and {
        station = record.station,
        department = record.department,
        since = record.since,
        callId = record.callId,
        air = record.air,
        extinguisher = record.extinguisher,
        hose = record.hose
    } or false)
end

function State.SyncUnit(source)
    local unit = units[source]
    TriggerClientEvent(Bridge.Event('fire:unit'), source, unit and {
        id = unit.id,
        label = unit.label,
        netId = unit.netId,
        water = Shared.Round(unit.water, 0),
        capacity = unit.capacity,
        supplied = unit.supplied == true
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
    State.BroadcastCall(call, 'fire:node', call.id, {
        id = node.id,
        intensity = Shared.Round(node.intensity, 1),
        heat = Shared.Round(node.heat, 1),
        coords = Shared.Coords(node.coords),
        kind = node.kind,
        scale = node.scale
    })
end

function State.SyncVictim(call, victim)
    State.BroadcastCall(call, 'fire:victim', call.id, publicVictim(victim))
end

function State.SyncHazard(call, hazard)
    State.BroadcastCall(call, 'fire:hazard', call.id, publicHazard(hazard))
end

-- Write-behind. Profiles are flushed on a timer and on resource stop so a
-- restart mid-shift does not lose a call's worth of experience.
CreateThread(function()
    Bridge.AwaitReady(10000)
    local interval = math.max(5000, tonumber((Shared.Settings().database or {}).flushInterval) or 20000)
    while true do
        Wait(interval)
        if Database.Available() then State.FlushProfiles() end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    if Database.Available() then State.FlushProfiles() end
end)
