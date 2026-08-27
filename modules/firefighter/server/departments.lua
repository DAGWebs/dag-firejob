-- Departments: who works for whom, and the paperwork behind it.
--
-- The framework owns the job itself. This module decides who is allowed to
-- move somebody between jobs, keeps the employment history, and keeps a
-- firefighter's framework grade lined up with the rank their record says they
-- hold. Rank is derived from XP everywhere in the job, so a promotion raises
-- the XP floor rather than inventing a second source of truth.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Database = Fire.Database
local Departments = {}
Fire.Departments = Departments

local function log(identifier, departmentId, action, actor, detail)
    if not Database.Available() or (Shared.Settings().database or {}).logCalls == false then return end

    local department = Shared.Department(departmentId)
    local query = ([[INSERT INTO `%s`
        (`identifier`, `department`, `job`, `grade`, `rank`, `action`, `actor`, `reason`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)]]):format(Database.Table('employment'))

    Database.Execute(query, {
        identifier,
        departmentId,
        department and department.job or nil,
        math.floor((detail or {}).grade or 0),
        (detail or {}).rank,
        action,
        actor,
        (detail or {}).reason
    })
end

Departments.Log = log

function Departments.CanCommand(source, departmentId)
    if source == 0 then return true end
    if DAG.Access.Allowed(source, Shared.Policy(nil, 'admin'), 'admin') then return true end
    return DAG.Access.Allowed(source, Shared.Policy(departmentId, 'command'), 'command')
end

function Departments.CanJoin(source, departmentId)
    if source == 0 then return true end
    if DAG.Access.Allowed(source, Shared.Policy(nil, 'admin'), 'admin') then return true end
    return DAG.Access.Allowed(source, Shared.Policy(departmentId, 'duty'), 'duty')
end

-- Players an officer can act on: online, close enough to be standing in front
-- of them, and not the officer themselves.
function Departments.Nearby(source, radius)
    local origin = State.PlayerCoords(source)
    if not origin then return {} end

    local reach = tonumber(radius) or 8.0
    local list = {}
    for _, playerId in ipairs(GetPlayers()) do
        local other = tonumber(playerId)
        if other and other ~= source then
            local coords = State.PlayerCoords(other)
            if coords and Shared.Distance(origin, coords) <= reach then
                local job = Bridge.GetJob(other)
                list[#list + 1] = {
                    source = other,
                    name = Bridge.GetName(other),
                    identifier = Bridge.GetIdentifier(other),
                    job = job and job.name or nil,
                    jobLabel = job and job.label or nil
                }
            end
        end
    end

    table.sort(list, function(a, b) return (a.name or '') < (b.name or '') end)
    return list
end

-- Hiring -------------------------------------------------------------------

function Departments.Hire(actor, target, departmentId, callback)
    local department = Shared.Department(departmentId)
    if not department then return callback(false, 'unknown_department') end
    if not Departments.CanCommand(actor, departmentId) then return callback(false, 'denied') end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return callback(false, 'unknown_firefighter') end

    if not Bridge.Supports('setJob') then return callback(false, 'framework_cannot_hire') end

    State.LoadProfile(identifier, Bridge.GetName(target), function(profile)
        if not profile then return callback(false, 'unknown_firefighter') end
        if profile.department == departmentId then return callback(false, 'already_employed') end

        local grade = Shared.GradeFor(profile.xp)
        if not Bridge.SetJob(target, department.job, grade) then
            return callback(false, 'framework_rejected')
        end

        profile.department = departmentId
        profile.hiredAt = profile.hiredAt or os.time()
        State.SaveProfile(profile)
        log(identifier, departmentId, 'hire', Bridge.GetIdentifier(actor), {
            grade = grade,
            rank = (Shared.RankFor(profile.xp) or {}).id
        })

        Bridge.Notify(target, ('You have been hired by the %s.'):format(department.label), 'success', 8000)
        callback(true, nil, profile)
    end)
end

function Departments.Terminate(actor, target, reason, callback)
    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return callback(false, 'unknown_firefighter') end

    local profile = State.ProfileFor(identifier, Bridge.GetName(target))
    local departmentId = profile and profile.department
    if not departmentId then return callback(false, 'not_employed') end
    if not Departments.CanCommand(actor, departmentId) then return callback(false, 'denied') end

    -- Clocking them off first means the roster, their call, and their
    -- apparatus are all released before the job goes away.
    if State.IsOnDuty(target) then Fire.Api.ForceOffDuty(target) end

    if Bridge.Supports('setJob') and not Bridge.SetJob(target, 'unemployed', 0) then
        return callback(false, 'framework_rejected')
    end

    profile.department = nil
    State.SaveProfile(profile)
    log(identifier, departmentId, 'terminate', Bridge.GetIdentifier(actor), { reason = reason })

    Bridge.Notify(target, 'Your employment with the department has ended.', 'error', 8000)
    callback(true, nil, profile)
end

-- Rank ---------------------------------------------------------------------

-- Promotion raises the XP floor to the rank's threshold; demotion drops it
-- just below the rank above. Rank stays a function of XP, so the menus, the
-- pay multiplier and the framework grade can never disagree.
function Departments.SetRank(actor, target, rankId, callback)
    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return callback(false, 'unknown_firefighter') end

    local profile = State.ProfileFor(identifier, Bridge.GetName(target))
    local departmentId = profile and profile.department
    if not departmentId then return callback(false, 'not_employed') end
    if not Departments.CanCommand(actor, departmentId) then return callback(false, 'denied') end

    local rank, rankIndex = nil, nil
    for index, entry in ipairs(Shared.Ranks()) do
        if entry.id == rankId then rank, rankIndex = entry, index end
    end
    if not rank then return callback(false, 'unknown_rank') end

    local floor = tonumber(rank.xp) or 0
    local ceiling = math.huge
    local above = Shared.Ranks()[rankIndex + 1]
    if above then ceiling = (tonumber(above.xp) or 0) - 1 end

    profile.xp = math.floor(Shared.Clamp(profile.xp, floor, ceiling))
    State.SaveProfile(profile)

    local department = Shared.Department(departmentId)
    local grade = tonumber(rank.grade) or 0
    if department and Bridge.Supports('setJob') then Bridge.SetJob(target, department.job, grade) end

    log(identifier, departmentId, 'rank', Bridge.GetIdentifier(actor), { grade = grade, rank = rank.id })
    Bridge.Notify(target, ('You are now a %s.'):format(rank.label), 'inform', 8000)
    callback(true, nil, profile, rank)
end

-- Keeps the framework grade in step after XP earned on a call pushes somebody
-- over a rank threshold.
function Departments.SyncGrade(source, profile)
    local department = profile and Shared.Department(profile.department)
    if not department or not Bridge.Supports('setJob') then return false end

    local job = Bridge.GetJob(source)
    local grade = Shared.GradeFor(profile.xp)
    if job and job.name == department.job and job.grade == grade then return false end
    return Bridge.SetJob(source, department.job, grade)
end

-- Reporting ----------------------------------------------------------------

function Departments.Employment(identifier, callback)
    if not Database.Available() then return callback({}) end

    local query = ([[SELECT * FROM `%s` WHERE `identifier` = ? ORDER BY `id` DESC LIMIT 25]])
        :format(Database.Table('employment'))
    Database.Query(query, { identifier }, function(rows) callback(rows or {}) end)
end

function Departments.Summary()
    local summary = {}
    for _, department in ipairs(Shared.Departments()) do
        local onDuty = State.OnDutyCount(department.id)
        summary[#summary + 1] = {
            id = department.id,
            label = department.label,
            short = department.short,
            onDuty = onDuty,
            calls = #State.ActiveCalls(department.id),
            stations = #Shared.StationsFor(department.id)
        }
    end
    return summary
end

-- Mutual aid ---------------------------------------------------------------

-- A department with nobody on duty cannot answer its own calls, so after
-- `mutualAidAfter` the call is toned out to its neighbours as well.
function Departments.ToneOut(call)
    if not call.department then return false end
    call.toned = call.toned or {}

    local aided = false
    for _, other in ipairs(Shared.MutualAid(call.department)) do
        if not call.toned[other.id] then
            call.toned[other.id] = true
            aided = true
        end
    end
    return aided
end

function Departments.NeedsMutualAid(call, now)
    if not call.department or call.mutualAid then return false end
    if State.OnDutyCount(call.department) > 0 then return false end

    local after = tonumber((Shared.Settings().dispatch or {}).mutualAidAfter) or 120000
    return (now - call.createdAt) >= after
end
