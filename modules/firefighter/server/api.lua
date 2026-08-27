-- The server's edge: every net event a firefighter client can send, the
-- callbacks the menus read, and the commands officers and admins use.
--
-- Handlers here are deliberately thin. They authorize, hand off to the module
-- that owns the rule, and translate the failure code into something a player
-- can read; the rules themselves live in the modules below.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = Fire.Incident
local Dispatch = Fire.Dispatch
local Departments = Fire.Departments
local Progression = Fire.Progression
local Academy = Fire.Academy

Fire.Api = Fire.Api or {}

-- Registering a command the server has switched off is how a job ends up
-- fighting another resource for a name, so a missing name is simply not
-- registered.
local function command(key, handler, options)
    local name = Shared.Command(key)
    if not name then return nil end
    DAG.Commands.Register(name, handler, options)
    return name
end

local REASONS = {
    off_duty = 'You are not on duty.',
    not_certified = 'You are not signed off for that.',
    missing_item = 'You do not have the right equipment in hand.',
    unknown_call = 'That call is no longer active.',
    call_closed = 'That call has already been closed.',
    other_department = 'That call belongs to another department.',
    unknown_node = 'There is nothing burning there.',
    unknown_target = 'That is no longer there.',
    already_out = 'That is already out.',
    out_of_range = 'You are too far away.',
    left_scene = 'You left before the job was finished.',
    too_fast = 'That was too quick.',
    no_supply = 'No water supply in reach. Park an apparatus closer.',
    no_line = 'Pull a hose line off the pump first.',
    line_stretched = 'The line is stretched. Move back towards the pump.',
    already_deployed = 'You already have a line.',
    no_unit = 'You do not have an apparatus signed out.',
    no_tank = 'That apparatus has no tank.',
    tank_full = 'The tank is already full.',
    apparatus_too_far = 'Park the apparatus at the hydrant.',
    no_hydrant = 'There is no hydrant here.',
    already_supplied = 'The pump is already on the hydrant.',
    not_supplied = 'The pump is not on a hydrant.',
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
    unknown_department = 'No such department.',
    unknown_rank = 'No such rank.',
    unknown_course = 'No such course.',
    location_busy = 'Something is already burning there.',
    no_location = 'That call type has no locations configured.',
    not_assigned = 'You are not assigned to a call.',
    not_on_call = 'They are not on this call.',
    unknown_role = 'No such role.',
    role_taken = 'Somebody else already has that role.',
    needs_help = 'That takes two: get somebody else on scene.',
    no_par = 'There is no accountability check running.',
    unknown_chore = 'No such job.',
    already_working = 'You are already doing something.',
    wrong_place = 'Not here. Go to the right part of the station.',
    left_it = 'You wandered off halfway through.',
    not_working = 'You are not doing anything.',
    not_down = 'They are not down.',
    already_down = 'You are already down.',
    already_rescuing = 'Somebody else is already on them.',
    cannot_rescue_yourself = 'You cannot drag yourself out.',
    not_rescuing = 'You are not dragging anybody.',
    too_soon = 'That was called too recently.',
    no_position = 'Your position could not be read.',
    no_effect = 'That had no effect.',
    no_station = 'Stand at a station duty point to clock on.',
    denied = 'You are not authorized to do that.',
    already_out_on_a_unit = 'Return your current apparatus first.',
    wrong_vehicle = 'That is not the apparatus you signed out.',
    already_employed = 'They already work for that department.',
    not_employed = 'They do not work for a department.',
    framework_cannot_hire = 'This framework cannot change jobs; hire them manually.',
    job_not_defined = 'This framework does not define that department job. Check install/.',
    grade_not_defined = 'This framework does not define that grade for the job.',
    framework_rejected = 'The framework refused the job change.',
    already_enrolled = 'You are already on a course.',
    not_enrolled = 'You are not on a course.',
    wrong_phase = 'Finish the classroom first.',
    cooling_down = 'You have to wait before trying that again.',
    rank_too_low = 'Your rank is too low for that course.',
    missing_prerequisite = 'You are missing a prerequisite course.',
    cannot_afford = 'You cannot afford the course fee.',
    not_at_academy = 'You have to be at the academy.',
    academy_closed = 'The academy is closed.',
    no_drill_ground = 'The academy has no drill ground configured.',
    disabled = 'That is switched off on this server.'
}

Fire.Api.Reasons = REASONS

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

-- Equipment ----------------------------------------------------------------

-- Issued kit is handed over at the locker and taken back at the end of the
-- shift, so a firefighter cannot walk off with the department's tools.
local function issueEquipment(source, give)
    if not Incident.ItemsEnforced() then return end
    for _, item in ipairs((Shared.Settings().items or {}).issued or {}) do
        if give then Bridge.AddItem(source, item, 1) else Bridge.RemoveItem(source, item, 1) end
    end
end

-- Duty ---------------------------------------------------------------------

local function nearestDutyPoint(source)
    local coords = State.PlayerCoords(source)
    if not coords then return nil end
    return select(1, Shared.NearestPoint(coords, 'duty', 4.0))
end

local function goOffDuty(source, quiet)
    local record = State.Duty(source)
    if not record then return false end

    Academy.Abandon(source, true)
    Dispatch.Leave(source, 'quiet')
    Fire.Api.ReturnUnit(source, true)
    issueEquipment(source, false)
    State.GoOffDuty(source)
    State.DropCachedProfile(record.identifier)

    if Shared.Settings().syncFrameworkDuty ~= false then Bridge.SetDuty(source, false) end
    State.SyncDuty(source)
    State.SyncUnit(source)
    if not quiet then
        Bridge.Notify(source, ('Off duty after %s.'):format(Shared.FormatDuration(GetGameTimer() - record.since)), 'inform')
    end
    return true
end

Fire.Api.ForceOffDuty = function(source) return goOffDuty(source, true) end

-- Shared by the net event and the command, because a command handler's source
-- is not the `source` a net event handler sees.
local function toggleDuty(source)
    if not Shared.Enabled() then return end
    if State.IsOnDuty(source) then return goOffDuty(source) end

    local station = nearestDutyPoint(source)
    if not station then return fail(source, 'no_station') end
    if not Departments.CanJoin(source, station.department) then return fail(source, 'denied') end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return fail(source, 'unknown_firefighter') end

    -- The record is loaded before the shift starts, so a career is never
    -- overwritten by a default profile that had not arrived yet.
    State.LoadProfile(identifier, Bridge.GetName(source), function(profile)
        if State.IsOnDuty(source) then return end

        State.GoOnDuty(source, station)
        if profile and profile.department ~= station.department then
            profile.department = profile.department or station.department
        end
        if profile then Departments.SyncGrade(source, profile) end

        issueEquipment(source, true)
        if Shared.Settings().syncFrameworkDuty ~= false then Bridge.SetDuty(source, true) end

        State.SyncDuty(source)
        State.SyncUnit(source)
        State.SyncAll(source)

        local department = Shared.Department(station.department)
        Bridge.Notify(source, ('On duty at %s as %s.'):format(
            station.label, Shared.RankLabel(profile and profile.xp or 0)), 'success')
        Dispatch.Radio(('%s on duty at %s (%s)'):format(
            Bridge.GetName(source), station.label, department and department.short or 'FD'), 'inform')
    end)
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
        -- must stay silent; a supply problem is worth telling them about.
        if reason == 'dry' or reason == 'no_supply' or reason == 'no_line'
            or reason == 'line_stretched' or reason == 'missing_item' then
            Bridge.Notify(source, REASONS[reason], 'error', 3000)
        end
        return
    end

    local call = State.GetCall(callId)
    State.SyncNode(call, result.node)
    if result.extinguished then State.SyncCall(call) end

    if result.supply == 'apparatus' then
        State.EachOnDuty(function(other)
            if State.Unit(other) then State.SyncUnit(other) end
        end)
    else
        State.SyncDuty(source)
    end
end)

on('fire:air', function(source, amount)
    Incident.ConsumeAir(source, amount)
end)

-- Hose lines ---------------------------------------------------------------

on('fire:deployLine', function(source, unitSource)
    local ok, reason, line = Incident.DeployLine(source, unitSource)
    if not ok then return fail(source, reason) end
    State.SyncDuty(source)
    TriggerClientEvent(Bridge.Event('fire:lineDeployed'), source, line)
    Bridge.Notify(source, 'Attack line charged.', 'success', 3000)
end)

on('fire:stowLine', function(source)
    local ok, reason = Incident.StowLine(source)
    if not ok then return fail(source, reason) end
    State.SyncDuty(source)
    TriggerClientEvent(Bridge.Event('fire:lineStowed'), source)
end)

on('fire:connectSupply', function(source, hydrantCoords)
    local ok, reason = Incident.ConnectSupply(source, hydrantCoords)
    if not ok then return fail(source, reason) end
    State.SyncUnit(source)
    Bridge.Notify(source, 'Supply line charged from the hydrant.', 'success')
end)

on('fire:disconnectSupply', function(source)
    local ok, reason = Incident.DisconnectSupply(source)
    if not ok then return fail(source, reason) end
    State.SyncUnit(source)
end)

-- Timed actions ------------------------------------------------------------

on('fire:beginAction', function(source, callId, kind, targetId)
    if type(callId) ~= 'string' or type(kind) ~= 'string' or type(targetId) ~= 'string' then return end

    local ok, reason, duration, stage, fastest = Incident.BeginAction(source, callId, kind, targetId)
    if not ok then return fail(source, reason) end
    TriggerClientEvent(Bridge.Event('fire:actionStarted'), source, kind, targetId, duration,
        stage and stage.label or nil, fastest)
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

    -- Finishing a job faster than the clock is worth something, capped so it
    -- is a bonus for working well and not a second wage.
    if (result.saved or 0) > 0 then
        local skill = Shared.Settings().skill or {}
        local bonus = skill.bonus or {}
        local pay = math.floor((tonumber(bonus.pay) or 0) * result.saved)
        if pay > 0 then
            local funded = Fire.Billing.Fund(pay, 'skill')
            if funded > 0 then
                Bridge.AddMoney(source, (Shared.Settings().pay or {}).account or 'bank',
                    funded, 'firefighter:skill')
            end
        end

        local xp = math.floor((tonumber(bonus.xp) or 0) * result.saved)
        if xp > 0 then
            local profile = State.Profile(source)
            if profile then
                profile.xp = profile.xp + xp
                State.SaveProfile(profile)
            end
        end
    end

    if result.kind == 'contain' then
        State.SyncHazard(result.call, result.target)
        Bridge.Notify(source, 'Release contained.', 'success')
    else
        State.SyncVictim(result.call, result.target)
        if result.remaining then
            Bridge.Notify(source, ('%s done. %d step(s) to go.'):format(result.stage, result.remaining), 'inform')
        else
            Bridge.Notify(source, result.kind == 'free' and 'Patient extricated.' or 'Patient treated.', 'success')
        end

        -- Working the worst patient first is the whole point of triage, so it
        -- is the thing that pays.
        if result.triage ~= nil then
            local triage = Shared.Settings().triage or {}
            if result.triage then
                local pay = math.floor(tonumber(triage.orderBonus) or 0)
                if pay > 0 then
                    local funded = Fire.Billing.Fund(pay, 'triage')
                    if funded > 0 then
                        Bridge.AddMoney(source, (Shared.Settings().pay or {}).account or 'bank',
                            funded, 'firefighter:triage')
                    end
                end

                local profile = State.Profile(source)
                if profile then
                    profile.xp = profile.xp + math.floor(tonumber(triage.orderXp) or 0)
                    State.SaveProfile(profile)
                end
                Bridge.Notify(source, 'Correct triage priority.', 'success', 4000)
            else
                Bridge.Notify(source, 'There was somebody worse than them.', 'inform', 5000)
            end
        end
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
    if not coords or select(2, Shared.NearestPointOf(station, coords, 'garage')) > 25.0 then
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

    -- Tooling that lives on the apparatus is handed over with it.
    if Incident.ItemsEnforced() then
        for _, item in ipairs(apparatus.carries or {}) do Bridge.AddItem(source, item, 1) end
    end

    State.SyncUnit(source)
    Bridge.Notify(source, ('%s signed out.'):format(apparatus.label), 'success')
end)

function Fire.Api.ReturnUnit(source, quiet)
    local unit = State.ClearUnit(source)
    if not unit then return false, 'no_unit' end

    Incident.StowLine(source)
    if unit.netId then
        local entity = NetworkGetEntityFromNetworkId(unit.netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
    end

    local apparatus = Shared.Apparatus(unit.id)
    if apparatus and Incident.ItemsEnforced() then
        for _, item in ipairs(apparatus.carries or {}) do Bridge.RemoveItem(source, item, 1) end
    end

    State.SyncUnit(source)
    State.SyncDuty(source)
    if not quiet then Bridge.Notify(source, ('%s returned to quarters.'):format(unit.label or 'Apparatus'), 'inform') end
    return true
end

on('fire:returnUnit', function(source)
    local ok, reason = Fire.Api.ReturnUnit(source)
    if not ok then return fail(source, reason) end
end)

-- Station work -------------------------------------------------------------

on('fire:chore', function(source, choreId)
    if type(choreId) ~= 'string' then return end

    local ok, reason, duration = Fire.Chores.Begin(source, choreId)
    if not ok then return fail(source, reason) end
    TriggerClientEvent(Bridge.Event('fire:choreStarted'), source, choreId, duration)
end)

on('fire:choreDone', function(source)
    local ok, reason, chore = Fire.Chores.Complete(source)
    if not ok then
        if reason ~= 'not_working' then fail(source, reason) end
        return
    end
    Bridge.Notify(source, ('%s done.'):format(chore.label), 'success')
end)

on('fire:choreCancel', function(source)
    Fire.Chores.Cancel(source)
end)

-- Mayday -------------------------------------------------------------------

on('fire:mayday', function(source)
    local ok, reason = Fire.Mayday.Declare(source, 'manual')
    if not ok then return fail(source, reason) end
end)

on('fire:beginRescue', function(source, target)
    if type(target) ~= 'number' then return end

    local ok, reason, duration = Fire.Mayday.BeginRescue(source, target)
    if not ok then return fail(source, reason) end
    TriggerClientEvent(Bridge.Event('fire:rescueStarted'), source, target, duration)
end)

on('fire:completeRescue', function(source)
    local ok, reason = Fire.Mayday.CompleteRescue(source)
    if not ok and reason ~= 'not_rescuing' then fail(source, reason) end
end)

on('fire:cancelRescue', function(source)
    Fire.Mayday.CancelRescue(source)
end)

-- Crew ---------------------------------------------------------------------

on('fire:assignRole', function(source, roleId, targetIdentifier)
    if roleId ~= nil and type(roleId) ~= 'string' then return end
    if targetIdentifier ~= nil and type(targetIdentifier) ~= 'string' then return end

    local ok, reason, role = Fire.Crew.Assign(source, roleId, targetIdentifier)
    if not ok then return fail(source, reason) end

    State.SyncCall(State.GetCall(State.Duty(source).callId))
    Bridge.Notify(source, role and ('Assigned: %s.'):format(role.label) or 'Assignment cleared.', 'inform', 4000)
end)

on('fire:par', function(source)
    local ok, reason = Fire.Crew.CallPar(source)
    if not ok then return fail(source, reason) end
end)

on('fire:parAnswer', function(source)
    local ok, reason = Fire.Crew.Answer(source)
    if not ok then return fail(source, reason) end
    Bridge.Notify(source, 'Accounted for.', 'success', 3000)
end)

-- The client knows whether it is standing in smoke; the server keeps the
-- answer, because it is what a PAR check and a mayday are about.
on('fire:interior', function(source, interior)
    if type(interior) ~= 'boolean' then return end
    Fire.Crew.SetInterior(source, interior)
end)

-- Academy ------------------------------------------------------------------

on('fire:enrol', function(source, courseId)
    if type(courseId) ~= 'string' then return end
    local ok, reason, enrolment = Academy.Enrol(source, courseId)
    if not ok then return fail(source, reason) end

    TriggerClientEvent(Bridge.Event('fire:course'), source, {
        course = enrolment.course.id,
        label = enrolment.course.label,
        phase = 'classroom',
        duration = enrolment.duration
    })
end)

on('fire:startPractical', function(source)
    local ok, reason, call = Academy.StartPractical(source)
    if not ok then return fail(source, reason) end
    if call then
        TriggerClientEvent(Bridge.Event('fire:course'), source, { phase = 'practical', callId = call.id })
    end
end)

on('fire:abandonCourse', function(source)
    Academy.Abandon(source)
end)

-- Command ------------------------------------------------------------------

on('fire:hire', function(source, target, departmentId)
    if type(target) ~= 'number' or type(departmentId) ~= 'string' then return end
    Departments.Hire(source, target, departmentId, function(ok, reason, profile)
        if not ok then return fail(source, reason) end
        Bridge.Notify(source, ('%s hired.'):format(profile.name or 'Firefighter'), 'success')
    end)
end)

on('fire:terminate', function(source, target, reason)
    if type(target) ~= 'number' then return end
    Departments.Terminate(source, target, type(reason) == 'string' and reason or nil, function(ok, failure, profile)
        if not ok then return fail(source, failure) end
        Bridge.Notify(source, ('%s dismissed.'):format(profile.name or 'Firefighter'), 'inform')
    end)
end)

on('fire:setRank', function(source, target, rankId)
    if type(target) ~= 'number' or type(rankId) ~= 'string' then return end
    Departments.SetRank(source, target, rankId, function(ok, reason, profile, rank)
        if not ok then return fail(source, reason) end
        Bridge.Notify(source, ('%s is now a %s.'):format(profile.name or 'Firefighter', rank.label), 'success')
    end)
end)

-- Callbacks ----------------------------------------------------------------

-- One call for everything a menu needs, so opening the board is a single round
-- trip instead of six.
Bridge.RegisterCallback(Bridge.Event('fire:context'), function(source, reply)
    local profile = State.Profile(source)
    local record = State.Duty(source)
    local unit = State.Unit(source)
    local departmentId = record and record.department or (profile and profile.department)

    local calls = {}
    for _, call in ipairs(State.ActiveCalls(departmentId)) do calls[#calls + 1] = State.PublicCall(call) end

    local roster = {}
    for _, entry in ipairs(State.Roster(departmentId)) do
        roster[#roster + 1] = {
            name = entry.name,
            station = entry.station,
            department = entry.department,
            callId = entry.callId,
            since = GetGameTimer() - entry.since
        }
    end

    local held = {}
    for id in pairs(Shared.HeldCertifications(profile)) do held[#held + 1] = id end
    table.sort(held)

    local carried = {}
    if Incident.ItemsEnforced() then
        for role, item in pairs(Shared.Settings().items or {}) do
            if type(item) == 'string' then carried[role] = Bridge.HasItem(source, item, 1) end
        end
    end

    local enrolment = Academy.Enrolment(source)
    reply({
        onDuty = record ~= nil,
        station = record and record.station or nil,
        department = departmentId,
        air = record and record.air or 0,
        extinguisher = record and record.extinguisher or 0,
        callId = record and record.callId or nil,
        hose = record and record.hose or nil,
        profile = profile and {
            name = profile.name,
            xp = profile.xp,
            rank = Shared.RankLabel(profile.xp),
            department = profile.department,
            stats = profile.stats
        } or nil,
        certifications = held,
        items = { enforced = Incident.ItemsEnforced(), carried = carried },
        unit = unit and {
            id = unit.id, label = unit.label, water = Shared.Round(unit.water, 0),
            capacity = unit.capacity, supplied = unit.supplied == true
        } or nil,
        calls = calls,
        roster = roster,
        departments = Departments.Summary(),
        academy = Academy.Catalogue(source),
        crew = (function()
            local call = record and record.callId and State.GetCall(record.callId)
            if not call then return nil end
            return Fire.Crew.Board(call)
        end)(),
        roles = Fire.Crew.Roles(),
        chores = Fire.Chores.Catalogue(source),
        mayday = (function()
            local list = {}
            for downSource, down in pairs(Fire.Mayday.Active()) do
                list[#list + 1] = {
                    source = downSource, name = down.name, reason = down.reason,
                    coords = down.coords, callId = down.callId,
                    remaining = math.max(0, down.window - (GetGameTimer() - down.startedAt))
                }
            end
            return list
        end)(),
        enrolment = enrolment and {
            course = enrolment.course.id,
            label = enrolment.course.label,
            phase = enrolment.phase,
            duration = enrolment.duration,
            startedAt = enrolment.startedAt
        } or nil,
        canCommand = departmentId ~= nil and Departments.CanCommand(source, departmentId) or false,
        canConfigure = (Shared.Settings().editor or {}).enabled ~= false
            and DAG.Access.Allowed(source, Shared.Policy(nil, 'admin'), 'admin')
    })
end)

Bridge.RegisterCallback(Bridge.Event('fire:leaderboard'), function(_, reply, limit)
    Progression.Leaderboard(limit, reply)
end)

-- Who an officer is standing in front of, for the hiring menu.
Bridge.RegisterCallback(Bridge.Event('fire:applicants'), function(source, reply)
    local record = State.Duty(source)
    local profile = State.Profile(source)
    local departmentId = record and record.department or (profile and profile.department)
    if not departmentId or not Departments.CanCommand(source, departmentId) then return reply({}) end
    reply(Departments.Nearby(source, 10.0))
end)

Bridge.RegisterCallback(Bridge.Event('fire:employment'), function(source, reply)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return reply({}) end
    Departments.Employment(identifier, reply)
end)

-- Commands -----------------------------------------------------------------

local function requireAdmin(source)
    if source == 0 or DAG.Access.Allowed(source, Shared.Policy(nil, 'admin'), 'admin') then return true end
    Bridge.Notify(source, REASONS.denied, 'error')
    return false
end

local function report(source, message)
    if source == 0 then return Bridge.Print(message) end
    Bridge.Notify(source, message, 'inform', 8000)
end

command('duty', function(source)
    toggleDuty(source)
end, { help = 'Clock on or off at a fire station duty point.', allowConsole = false })

command('mayday', function(source)
    if source == 0 then return end
    local ok, reason = Fire.Mayday.Declare(source, 'manual')
    if not ok then fail(source, reason) end
end, { help = 'Call a mayday. Somebody has to come and get you.', allowConsole = false })

command('roster', function(source)
    local roster = State.Roster()
    if #roster == 0 then return report(source, 'Nobody is on duty.') end

    local lines = {}
    for _, entry in ipairs(roster) do
        local department = Shared.Department(entry.department)
        lines[#lines + 1] = ('%s [%s]%s'):format(
            entry.name,
            department and department.short or 'FD',
            entry.callId and (' ' .. entry.callId) or ''
        )
    end
    report(source, ('On duty (%d): %s'):format(#roster, table.concat(lines, ', ')))
end, { help = 'List the firefighters currently on duty.' })

command('emergency', function(source, args)
    if source == 0 then return end
    local kind = args[1]
    if not kind then
        local kinds = ((Shared.Settings().events or {}).report or {}).kinds or {}
        return report(source, ('Usage: /%s <%s>'):format(Shared.Command('emergency'), table.concat(kinds, '|')))
    end

    local call, reason = Fire.Events.Report(source, kind)
    if not call then return fail(source, reason) end
end, {
    help = 'Report an emergency at your position.',
    arguments = { { name = 'type', help = 'structure, vehicle, medical, mva, brush' } },
    allowConsole = false
})

command('dispatch', function(source, args)
    if not requireAdmin(source) then return end

    local kind = args[1]
    if not kind or not Shared.CallType(kind) then
        local names = {}
        for _, callType in ipairs(Shared.CallTypes()) do names[#names + 1] = callType.id end
        return report(source, ('Usage: /%s <%s> [here]'):format(Shared.Command('dispatch'), table.concat(names, '|')))
    end

    local options = { force = true, source = 'command' }
    if args[2] == 'here' and source > 0 then
        local coords = State.PlayerCoords(source)
        if not coords then return report(source, 'Your position could not be read.') end
        options.coords = coords
        options.label = 'Reported location'
        options.location = { coords = coords, label = 'Reported location' }
    end

    local call, reason = Dispatch.Create(kind, options)
    report(source, call and ('Dispatched %s.'):format(call.id) or ('Could not dispatch: %s'):format(reason))
end, {
    help = 'Dispatch a firefighter call.',
    arguments = { { name = 'type', help = 'Call type id' }, { name = 'here', help = 'Use your position' } }
})

command('clear', function(source, args)
    local target = args[1]
    if target then
        local call = State.GetCall(target)
        if not call then return report(source, REASONS.unknown_call) end
        if not Departments.CanCommand(source, call.department) then return report(source, REASONS.denied) end

        local ok, reason = Dispatch.Resolve(target, 'cleared by command')
        return report(source, ok and ('Cleared %s.'):format(target) or ('Could not clear: %s'):format(reason))
    end

    if not requireAdmin(source) then return end
    local cleared = 0
    for _, call in ipairs(State.ActiveCalls()) do
        if Dispatch.Resolve(call.id, 'cleared by command') then cleared = cleared + 1 end
    end
    report(source, ('Cleared %d call(s).'):format(cleared))
end, { help = 'Clear one call, or every open call.', arguments = { { name = 'callId', help = 'FD-0001' } } })

command('hire', function(source, args)
    if source == 0 then return end
    local target = tonumber(args[1])
    if not target then return report(source, ('Usage: /%s <playerId> [department]'):format(Shared.Command('hire'))) end

    local profile = State.Profile(source)
    local record = State.Duty(source)
    local departmentId = args[2] or (record and record.department) or (profile and profile.department)
    Departments.Hire(source, target, departmentId, function(ok, reason, hired)
        report(source, ok and ('%s hired.'):format(hired.name or 'Firefighter') or (REASONS[reason] or reason))
    end)
end, {
    help = 'Hire a nearby player into your department.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'department', help = 'lsfd, safd, bcfd' } },
    allowConsole = false
})

command('dismiss', function(source, args)
    if source == 0 then return end
    local target = tonumber(args[1])
    if not target then return report(source, ('Usage: /%s <playerId> [reason]'):format(Shared.Command('dismiss'))) end

    table.remove(args, 1)
    Departments.Terminate(source, target, table.concat(args, ' '), function(ok, reason, profile)
        report(source, ok and ('%s dismissed.'):format(profile.name or 'Firefighter') or (REASONS[reason] or reason))
    end)
end, {
    help = 'Dismiss a firefighter from your department.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'reason', help = 'Optional' } },
    allowConsole = false
})

command('rank', function(source, args)
    if source == 0 then return end
    local target, rankId = tonumber(args[1]), args[2]
    if not target or not rankId then
        local names = {}
        for _, rank in ipairs(Shared.Ranks()) do names[#names + 1] = rank.id end
        return report(source, ('Usage: /%s <playerId> <%s>'):format(Shared.Command('rank'), table.concat(names, '|')))
    end

    Departments.SetRank(source, target, rankId, function(ok, reason, profile, rank)
        report(source, ok and ('%s is now a %s.'):format(profile.name or 'Firefighter', rank.label)
            or (REASONS[reason] or reason))
    end)
end, {
    help = 'Promote or demote a firefighter.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'rank', help = 'Rank id' } },
    allowConsole = false
})

command('certify', function(source, args)
    local target, certification = tonumber(args[1]), args[2]
    if not target or not certification then
        return report(source, ('Usage: /%s <playerId> <certification>'):format(Shared.Command('certify')))
    end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return report(source, 'That player is not connected.') end

    local profile = State.ProfileFor(identifier, Bridge.GetName(target))
    if not Departments.CanCommand(source, profile and profile.department) then
        return report(source, REASONS.denied)
    end

    local ok, reason, updated = Progression.GrantCertification(identifier, certification)
    if not ok then return report(source, REASONS[reason] or reason) end

    Bridge.Notify(target, ('You are now signed off for %s.'):format(
        (Shared.Certification(certification) or {}).label or certification), 'success')
    report(source, ('%s signed off for %s.'):format(updated.name or identifier, certification))
end, {
    help = 'Sign a firefighter off for a certification.',
    arguments = { { name = 'playerId', help = 'Server id' }, { name = 'certification', help = 'engine, ladder, ems, rescue, hazmat, command' } }
})

command('experience', function(source, args)
    if not requireAdmin(source) then return end

    local target, amount = tonumber(args[1]), tonumber(args[2])
    if not target or not amount then return report(source, ('Usage: /%s <playerId> <amount>'):format(Shared.Command('experience'))) end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return report(source, 'That player is not connected.') end

    local ok, reason, profile = Progression.AwardXp(identifier, amount)
    if not ok then return report(source, REASONS[reason] or reason) end
    Departments.SyncGrade(target, profile)
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

    Bridge.Print('firefighter job ready: %d departments, %d stations, %d call types',
        #Shared.Departments(), #Shared.Stations(), #Shared.CallTypes())

    if not Bridge.Supports('setJob') then
        Bridge.Print('this framework cannot change jobs: hiring is disabled, assign the job manually')
    end
end)
