-- The server's edge: every net event a firefighter client can send, the
-- callbacks the menus read, and the commands officers and admins use.
--
-- Handlers here are deliberately thin. They authorize, hand off to the module
-- that owns the rule, and translate the failure code into something a player
-- can read; the rules themselves live in incident.lua and dispatch.lua.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = Fire.Incident
local Dispatch = Fire.Dispatch
local Progression = Fire.Progression

local prefix = Shared.Settings().commandPrefix or Bridge.namespace

Fire.Api = Fire.Api or {}

local REASONS = {
    off_duty = 'You are not on duty.',
    not_certified = 'You are not signed off for that.',
    unknown_call = 'That call is no longer active.',
    call_closed = 'That call has already been closed.',
    unknown_node = 'There is nothing burning there.',
    unknown_target = 'That is no longer there.',
    already_out = 'That is already out.',
    out_of_range = 'You are too far away.',
    left_scene = 'You left before the job was finished.',
    too_fast = 'That was too quick.',
    no_supply = 'No water supply in reach. Park an apparatus closer.',
    no_unit = 'You do not have an apparatus signed out.',
    no_tank = 'That apparatus has no tank.',
    tank_full = 'The tank is already full.',
    apparatus_too_far = 'Park the apparatus at the hydrant.',
    no_hydrant = 'There is no hydrant here.',
    dry = 'You are out of water.',
    already_full = 'That is already full.',
    already_held = 'They already hold that certification.',
    not_signed_off = 'They do not hold that certification.',
    not_trapped = 'They are not trapped.',
    not_ready = 'They have to be freed first.',
    not_treated = 'They have not been treated yet.',
    not_at_hospital = 'Take them to the hospital first.',
    already_contained = 'That has already been contained.',
    unknown_firefighter = 'No record for that firefighter.',
    unknown_certification = 'No such certification.',
    unknown_call_type = 'No such call type.',
    location_busy = 'Something is already burning there.',
    no_location = 'That call type has no locations configured.',
    not_assigned = 'You are not assigned to a call.',
    no_position = 'Your position could not be read.',
    no_effect = 'That had no effect.',
    no_station = 'Stand at a station duty point to clock on.',
    denied = 'You are not a firefighter.',
    already_out_on_a_unit = 'Return your current apparatus first.',
    wrong_vehicle = 'That is not the apparatus you signed out.'
}

local function fail(source, reason)
    Bridge.Notify(source, REASONS[reason] or 'That did not work.', 'error')
    return false
end

local function on(event, handler)
    RegisterNetEvent(Bridge.Event(event), function(...)
        local playerSource = source
        local ok, err = pcall(handler, playerSource, ...)
        if not ok then Bridge.Print("firefighter handler '%s' errored: %s", event, tostring(err)) end
    end)
end

local function policy(name)
    return (Shared.Settings().access or {})[name] or {}
end

-- Duty ---------------------------------------------------------------------

local function nearestDutyPoint(source)
    local coords = State.PlayerCoords(source)
    if not coords then return nil end

    for _, station in ipairs(Shared.Stations()) do
        if Shared.Distance(coords, station.duty or station.coords) <= 4.0 then return station end
    end
    return nil
end

local function goOffDuty(source, quiet)
    local record = State.Duty(source)
    if not record then return false end

    Dispatch.Leave(source, 'quiet')
    Fire.Api.ReturnUnit(source, true)
    State.GoOffDuty(source)

    if Shared.Settings().syncFrameworkDuty ~= false then Bridge.SetDuty(source, false) end
    State.SyncDuty(source)
    State.SyncUnit(source)
    if not quiet then
        Bridge.Notify(source, ('Off duty after %s.'):format(Shared.FormatDuration(GetGameTimer() - record.since)), 'inform')
    end
    return true
end

-- Shared by the net event and the command, because a command handler's source
-- is not the `source` a net event handler sees.
local function toggleDuty(source)
    if not Shared.Enabled() then return end
    if State.IsOnDuty(source) then return goOffDuty(source) end

    if not DAG.Access.Allowed(source, policy('duty'), 'duty') then return fail(source, 'denied') end

    local station = nearestDutyPoint(source)
    if not station then return fail(source, 'no_station') end

    State.GoOnDuty(source, station)
    if Shared.Settings().syncFrameworkDuty ~= false then Bridge.SetDuty(source, true) end

    State.SyncDuty(source)
    State.SyncUnit(source)
    State.SyncAll(source)

    local profile = State.Profile(source)
    Bridge.Notify(source, ('On duty at %s as %s.'):format(station.label, Shared.RankLabel(profile and profile.xp or 0)), 'success')
    Dispatch.Radio(('%s on duty at %s'):format(Bridge.GetName(source), station.label), 'inform')
    return true
end

Fire.Api.ToggleDuty = toggleDuty

on('fire:toggleDuty', toggleDuty)

-- Calls --------------------------------------------------------------------

on('fire:join', function(source, callId)
    if type(callId) ~= 'string' then return end
    local ok, reason, call = Dispatch.Join(source, callId)
    if not ok then return fail(source, reason) end
    Bridge.Notify(source, ('Responding to %s - %s.'):format(call.id, call.location), 'success')
end)

on('fire:leave', function(source)
    local ok, reason = Dispatch.Leave(source)
    if not ok then return fail(source, reason) end
    Bridge.Notify(source, 'Cleared from the call.', 'inform')
end)

-- Suppression --------------------------------------------------------------

on('fire:water', function(source, callId, nodeId, litres, agent)
    if type(callId) ~= 'string' or type(nodeId) ~= 'string' or type(agent) ~= 'string' then return end

    local ok, reason, result = Incident.ApplyWater(source, callId, nodeId, litres, agent)
    if not ok then
        -- Rate and range rejections are the normal case while spraying and
        -- must stay silent; only a supply problem is worth telling them about.
        if reason == 'dry' or reason == 'no_supply' then Bridge.Notify(source, REASONS[reason], 'error', 3000) end
        return
    end

    local call = State.GetCall(callId)
    State.SyncNode(call, result.node)
    if result.extinguished then State.SyncCall(call) end

    if result.supply == 'apparatus' then
        State.SyncUnit(source)
    else
        State.SyncDuty(source)
    end
end)

on('fire:air', function(source, amount)
    Incident.ConsumeAir(source, amount)
end)

-- Timed actions ------------------------------------------------------------

on('fire:beginAction', function(source, callId, kind, targetId)
    if type(callId) ~= 'string' or type(kind) ~= 'string' or type(targetId) ~= 'string' then return end

    local ok, reason, duration = Incident.BeginAction(source, callId, kind, targetId)
    if not ok then return fail(source, reason) end
    TriggerClientEvent(Bridge.Event('fire:actionStarted'), source, kind, targetId, duration)
end)

on('fire:cancelAction', function(source)
    Incident.CancelAction(source)
end)

on('fire:completeAction', function(source)
    local ok, reason, result = Incident.CompleteAction(source)
    if not ok then
        if reason ~= 'no_action' then fail(source, reason) end
        return
    end

    if result.kind == 'contain' then
        State.SyncHazard(result.call, result.target)
        Bridge.Notify(source, 'Release contained.', 'success')
    else
        State.SyncVictim(result.call, result.target)
        Bridge.Notify(source, result.kind == 'free' and 'Patient extricated.' or 'Patient treated.', 'success')
    end
    State.SyncCall(result.call)
end)

on('fire:transport', function(source, callId, victimId)
    if type(callId) ~= 'string' or type(victimId) ~= 'string' then return end

    local ok, reason, victim = Incident.TransportVictim(source, callId, victimId)
    if not ok then return fail(source, reason) end

    local call = State.GetCall(callId)
    State.SyncVictim(call, victim)
    State.SyncCall(call)
    Bridge.Notify(source, 'Patient handed over at the hospital.', 'success')
end)

-- Supply -------------------------------------------------------------------

on('fire:refillTank', function(source, hydrantCoords)
    local ok, reason, water = Incident.RefillApparatus(source, hydrantCoords)
    if not ok then return fail(source, reason) end
    State.SyncUnit(source)
    Bridge.Notify(source, ('Tank at %d litres.'):format(math.floor(water)), 'success', 3000)
end)

on('fire:refillGear', function(source, kind)
    local ok, reason
    if kind == 'air' then
        ok, reason = Incident.RefillAir(source)
    else
        ok, reason = Incident.RefillExtinguisher(source)
    end
    if not ok then return fail(source, reason) end

    State.SyncDuty(source)
    Bridge.Notify(source, kind == 'air' and 'SCBA cylinder replaced.' or 'Extinguisher recharged.', 'success', 3000)
end)

-- Apparatus ----------------------------------------------------------------

on('fire:requestUnit', function(source, apparatusId, stationId)
    if type(apparatusId) ~= 'string' then return end
    if not State.IsOnDuty(source) then return fail(source, 'off_duty') end
    if State.Unit(source) then return fail(source, 'already_out_on_a_unit') end

    local apparatus = Shared.Apparatus(apparatusId)
    local station = Shared.Station(stationId) or Shared.Station(State.Duty(source).station)
    if not apparatus or not station then return fail(source, 'unknown_target') end

    local profile = State.Profile(source)
    if Shared.Settings().enforceCertifications ~= false
        and not Shared.HasCertification(profile, apparatus.certification) then
        return fail(source, 'not_certified')
    end

    local coords = State.PlayerCoords(source)
    if not coords or Shared.Distance(coords, station.garage or station.coords) > 25.0 then
        return fail(source, 'out_of_range')
    end

    -- The client creates the vehicle so this works with or without OneSync
    -- entity ownership; it is registered only after the server has confirmed
    -- the entity it reports back is really the apparatus that was authorized.
    TriggerClientEvent(Bridge.Event('fire:spawnUnit'), source, apparatusId, station.id)
end)

on('fire:unitSpawned', function(source, apparatusId, netId)
    if type(apparatusId) ~= 'string' or type(netId) ~= 'number' then return end
    if not State.IsOnDuty(source) or State.Unit(source) then return end

    local apparatus = Shared.Apparatus(apparatusId)
    if not apparatus then return end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if GetEntityModel(entity) ~= GetHashKey(apparatus.model) then return fail(source, 'wrong_vehicle') end

    State.SetUnit(source, {
        id = apparatus.id,
        label = apparatus.label,
        netId = netId,
        entity = entity,
        capacity = tonumber(apparatus.water) or 0,
        water = tonumber(apparatus.water) or 0,
        coords = Shared.Coords(GetEntityCoords(entity))
    })
    State.SyncUnit(source)
    Bridge.Notify(source, ('%s signed out.'):format(apparatus.label), 'success')
end)

function Fire.Api.ReturnUnit(source, quiet)
    local unit = State.ClearUnit(source)
    if not unit then return false, 'no_unit' end

    if unit.netId then
        local entity = NetworkGetEntityFromNetworkId(unit.netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
    end

    State.SyncUnit(source)
    if not quiet then Bridge.Notify(source, ('%s returned to quarters.'):format(unit.label or 'Apparatus'), 'inform') end
    return true
end

on('fire:returnUnit', function(source)
    local ok, reason = Fire.Api.ReturnUnit(source)
    if not ok then return fail(source, reason) end
end)

-- Callbacks ----------------------------------------------------------------

-- One call for everything a menu needs, so opening the board is a single round
-- trip instead of four.
Bridge.RegisterCallback(Bridge.Event('fire:context'), function(source, reply)
    local profile = State.Profile(source)
    local record = State.Duty(source)
    local unit = State.Unit(source)

    local calls = {}
    for _, call in ipairs(State.ActiveCalls()) do calls[#calls + 1] = State.PublicCall(call) end

    local roster = {}
    for _, entry in ipairs(State.Roster()) do
        roster[#roster + 1] = {
            name = entry.name,
            station = entry.station,
            callId = entry.callId,
            since = GetGameTimer() - entry.since
        }
    end

    local held = {}
    for id in pairs(Shared.HeldCertifications(profile)) do held[#held + 1] = id end
    table.sort(held)

    reply({
        onDuty = record ~= nil,
        station = record and record.station or nil,
        air = record and record.air or 0,
        extinguisher = record and record.extinguisher or 0,
        callId = record and record.callId or nil,
        profile = profile and {
            name = profile.name,
            xp = profile.xp,
            rank = Shared.RankLabel(profile.xp),
            stats = profile.stats
        } or nil,
        certifications = held,
        unit = unit and { id = unit.id, label = unit.label, water = Shared.Round(unit.water, 0), capacity = unit.capacity } or nil,
        calls = calls,
        roster = roster,
        canCommand = DAG.Access.Allowed(source, policy('command'), 'command')
    })
end)

Bridge.RegisterCallback(Bridge.Event('fire:leaderboard'), function(_, reply, limit)
    reply(Progression.Leaderboard(math.min(tonumber(limit) or 10, 25)))
end)

-- Commands -----------------------------------------------------------------

local function requireAccess(source, name)
    if source == 0 then return true end
    if DAG.Access.Allowed(source, policy(name), name) then return true end
    Bridge.Notify(source, REASONS.denied, 'error')
    return false
end

local function report(source, message)
    if source == 0 then return Bridge.Print(message) end
    Bridge.Notify(source, message, 'inform', 8000)
end

DAG.Commands.Register(prefix .. ':duty', function(source)
    toggleDuty(source)
end, { help = 'Clock on or off at a fire station duty point.', allowConsole = false })

DAG.Commands.Register(prefix .. ':roster', function(source)
    local roster = State.Roster()
    if #roster == 0 then return report(source, 'Nobody is on duty.') end

    local lines = {}
    for _, entry in ipairs(roster) do
        lines[#lines + 1] = ('%s (%s%s)'):format(
            entry.name,
            entry.station or 'unassigned',
            entry.callId and (', ' .. entry.callId) or ''
        )
    end
    report(source, ('On duty (%d): %s'):format(#roster, table.concat(lines, ', ')))
end, { help = 'List the firefighters currently on duty.' })

DAG.Commands.Register(prefix .. ':fdcall', function(source, args)
    if not requireAccess(source, 'admin') then return end

    local kind = args[1]
    if not kind or not Shared.CallType(kind) then
        local names = {}
        for _, callType in ipairs(Shared.CallTypes()) do names[#names + 1] = callType.id end
        return report(source, ('Usage: /%s:fdcall <%s> [here]'):format(prefix, table.concat(names, '|')))
    end

    local options = { force = true }
    if args[2] == 'here' and source > 0 then
        local coords = State.PlayerCoords(source)
        if not coords then return report(source, 'Your position could not be read.') end
        options.coords = coords
        options.label = 'Reported location'
    end

    local call, reason = Dispatch.Create(kind, options)
    report(source, call and ('Dispatched %s.'):format(call.id) or ('Could not dispatch: %s'):format(reason))
end, {
    help = 'Dispatch a firefighter call.',
    arguments = { { name = 'type', help = 'Call type id' }, { name = 'here', help = 'Use your position' } }
})

DAG.Commands.Register(prefix .. ':fdclear', function(source, args)
    if not requireAccess(source, 'command') then return end

    local target = args[1]
    if target then
        local ok, reason = Dispatch.Resolve(target, 'cleared by command')
        return report(source, ok and ('Cleared %s.'):format(target) or ('Could not clear: %s'):format(reason))
    end

    local cleared = 0
    for _, call in ipairs(State.ActiveCalls()) do
        if Dispatch.Resolve(call.id, 'cleared by command') then cleared = cleared + 1 end
    end
    report(source, ('Cleared %d call(s).'):format(cleared))
end, { help = 'Clear one call, or every open call.', arguments = { { name = 'callId', help = 'FD-0001' } } })

DAG.Commands.Register(prefix .. ':fdcert', function(source, args)
    if not requireAccess(source, 'command') then return end

    local target, certification = tonumber(args[1]), args[2]
    if not target or not certification then
        return report(source, ('Usage: /%s:fdcert <playerId> <certification>'):format(prefix))
    end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return report(source, 'That player is not connected.') end

    local ok, reason, profile = Progression.GrantCertification(identifier, certification)
    if not ok then return report(source, REASONS[reason] or reason) end

    Bridge.Notify(target, ('You are now signed off for %s.'):format(
        (Shared.Certification(certification) or {}).label or certification), 'success')
    report(source, ('%s signed off for %s.'):format(profile.name or identifier, certification))
end, {
    help = 'Sign a firefighter off for a certification.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'certification', help = 'engine, ladder, ems, rescue, hazmat, command' } }
})

DAG.Commands.Register(prefix .. ':fdxp', function(source, args)
    if not requireAccess(source, 'admin') then return end

    local target, amount = tonumber(args[1]), tonumber(args[2])
    if not target or not amount then return report(source, ('Usage: /%s:fdxp <playerId> <amount>'):format(prefix)) end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return report(source, 'That player is not connected.') end

    local ok, reason, profile = Progression.AwardXp(identifier, amount)
    if not ok then return report(source, REASONS[reason] or reason) end
    report(source, ('%s is now on %d XP (%s).'):format(profile.name or identifier, profile.xp, Shared.RankLabel(profile.xp)))
end, {
    help = 'Adjust a firefighter XP total.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'amount', help = 'XP, may be negative' } }
})

-- Other resources (a scanner, an MDT, a stats site) read the job through this
-- rather than reaching into the module tables.
exports('GetFirefighter', function() return Fire end)

CreateThread(function()
    Bridge.AwaitReady(10000)
    if not Shared.Enabled() then return Bridge.Print('firefighter job disabled by config') end
    Bridge.Print('firefighter job ready: %d stations, %d call types, %d apparatus',
        #Shared.Stations(), #Shared.CallTypes(), #(Shared.Settings().apparatus or {}))
end)
