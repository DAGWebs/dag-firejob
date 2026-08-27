-- The fire academy.
--
-- A certification is earned rather than waited for: sit the classroom phase,
-- then work a live drill inside a time limit. The drill is a real incident
-- built with the same simulation as a dispatched call, so passing pump
-- operations means actually putting water on fire.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Incident = Fire.Incident
local Database = Fire.Database
local Academy = {}
Fire.Academy = Academy

local enrolments = {}

local function settings()
    return Shared.Settings().academy or {}
end

local function record(identifier, course, passed, score, instructor)
    if not Database.Available() then return end

    local query = ([[INSERT INTO `%s`
        (`identifier`, `course`, `certification`, `passed`, `score`, `instructor`)
        VALUES (?, ?, ?, ?, ?, ?)]]):format(Database.Table('training'))
    Database.Execute(query, {
        identifier, course.id, course.certification, passed and 1 or 0, math.floor(score or 0), instructor
    })
end

function Academy.Enrolment(source)
    return enrolments[source]
end

-- What this firefighter can sit right now, and why not when they cannot.
function Academy.Catalogue(source)
    local profile = State.Profile(source)
    local now = GetGameTimer()
    local retry = tonumber(settings().retryDelay) or 300000
    local list = {}

    for _, course in ipairs(Shared.Courses()) do
        local available, reason = Shared.CourseAvailable(profile, course.id)
        local lastAttempt = (profile and profile.training or {})[course.id]
        if available and lastAttempt and now - lastAttempt < retry then
            available, reason = false, 'cooling_down'
        end

        list[#list + 1] = {
            id = course.id,
            label = course.label,
            description = course.description,
            certification = course.certification,
            cost = tonumber(course.cost) or 0,
            classroom = course.classroom,
            practical = course.practical ~= nil,
            available = available,
            reason = reason,
            cooldown = lastAttempt and math.max(0, retry - (now - lastAttempt)) or 0
        }
    end
    return list
end

-- Enrolment ----------------------------------------------------------------

function Academy.Enrol(source, courseId)
    if settings().enabled == false then return false, 'academy_closed' end
    if enrolments[source] then return false, 'already_enrolled' end

    local course = Shared.Course(courseId)
    if not course then return false, 'unknown_course' end

    local profile = State.Profile(source)
    if not profile then return false, 'unknown_firefighter' end

    local available, reason = Shared.CourseAvailable(profile, courseId)
    if not available then return false, reason end

    local retry = tonumber(settings().retryDelay) or 300000
    local lastAttempt = (profile.training or {})[courseId]
    if lastAttempt and GetGameTimer() - lastAttempt < retry then return false, 'cooling_down' end

    local coords = State.PlayerCoords(source)
    local classroom = Shared.Coords(settings().classroom or settings().coords)
    if not coords or not classroom or Shared.Distance(coords, classroom) > 8.0 then return false, 'not_at_academy' end

    local cost = tonumber(course.cost) or 0
    if cost > 0 then
        if not Bridge.RemoveMoney(source, 'bank', cost, 'firefighter:academy') then
            return false, 'cannot_afford'
        end
        -- Course fees are the department's income, which matters when the
        -- department is the one paying the wages.
        if Fire.Billing then Fire.Billing.Deposit(cost) end
    end

    enrolments[source] = {
        course = course,
        phase = 'classroom',
        startedAt = GetGameTimer(),
        duration = tonumber(course.classroom) or 30000,
        identifier = profile.identifier
    }
    return true, nil, enrolments[source]
end

function Academy.Abandon(source, quiet)
    local enrolment = enrolments[source]
    if not enrolment then return false, 'not_enrolled' end

    enrolments[source] = nil
    if enrolment.callId then
        local call = State.GetCall(enrolment.callId)
        if call then
            State.SyncRemoval(call, 'abandoned')
            State.RemoveCall(call.id)
        end
    end
    if not quiet then Bridge.Notify(source, 'You left the course.', 'inform') end
    return true
end

-- Drills -------------------------------------------------------------------

-- A drill is a real scene: the same nodes, patients, wrecks and spills the
-- dispatcher builds, on the training ground, owned by one trainee.
local function buildDrill(source, course)
    local practical = course.practical or {}
    local ground = Shared.Coords(settings().drill or settings().coords)
    if not ground then return nil, 'no_drill_ground' end

    local id = State.NextCallId()
    local call = {
        id = id,
        kind = 'training',
        label = ('Drill - %s'):format(course.label),
        location = settings().label or 'Fire academy',
        coords = ground,
        radius = 10.0,
        priority = 3,
        state = Fire.CallState.working,
        source = 'academy',
        training = true,
        trainee = source,
        course = course.id,
        spread = false,
        extrication = practical.kind == 'extrication',
        createdAt = GetGameTimer(),
        deadline = GetGameTimer() + (tonumber(practical.timeLimit) or 240000),
        responders = {},
        toned = {},
        fires = {}, victims = {}, hazards = {}, wrecks = {},
        escalations = 0
    }

    local targets = math.max(1, math.floor(tonumber(practical.targets) or 1))
    for index = 1, targets do
        local spot = {
            x = ground.x + math.cos(index * 2.1) * 4.0,
            y = ground.y + math.sin(index * 2.1) * 4.0,
            z = ground.z
        }

        if practical.kind == 'suppression' then
            Incident.NewNode(call, spot, 60)
        elseif practical.kind == 'treatment' then
            Incident.NewVictim(call, spot, {})
        elseif practical.kind == 'containment' then
            call.hazardSequence = (call.hazardSequence or 0) + 1
            call.hazards[('h%d'):format(call.hazardSequence)] = {
                id = ('h%d'):format(call.hazardSequence),
                coords = Shared.Coords(spot),
                progress = 0,
                contained = false,
                label = 'Training spill'
            }
        elseif practical.kind == 'extrication' then
            call.wreckSequence = (call.wreckSequence or 0) + 1
            local wreckId = ('w%d'):format(call.wreckSequence)
            call.wrecks[wreckId] = {
                id = wreckId,
                coords = Shared.Coords(spot),
                heading = 90.0,
                model = 'sultan'
            }
            Incident.NewVictim(call, spot, { trapped = true, staged = true, wreck = wreckId })
        end
    end

    -- The trainee counts as the crew so arrival, the HUD, and the action
    -- distance checks all behave exactly as they do on a real call.
    local duty = State.Duty(source)
    if duty then
        call.responders[duty.identifier] = {
            source = source,
            name = duty.name,
            rank = 'Trainee',
            joinedAt = GetGameTimer(),
            onScene = true,
            arrivedAt = GetGameTimer()
        }
    end

    State.AddCall(call)
    return call
end

function Academy.StartPractical(source)
    local enrolment = enrolments[source]
    if not enrolment then return false, 'not_enrolled' end
    if enrolment.phase ~= 'classroom' then return false, 'wrong_phase' end

    if GetGameTimer() - enrolment.startedAt < enrolment.duration * 0.9 then return false, 'too_fast' end

    local course = enrolment.course
    if not course.practical then return Academy.Pass(source, 100) end

    local call, reason = buildDrill(source, course)
    if not call then return false, reason end

    enrolment.phase = 'practical'
    enrolment.callId = call.id
    enrolment.deadline = call.deadline

    State.SyncCall(call, source)
    Bridge.Notify(source, ('Drill started. You have %s.'):format(
        Shared.FormatDuration(call.deadline - GetGameTimer())), 'inform', 8000)
    return true, nil, call
end

-- Scoring ------------------------------------------------------------------

function Academy.Pass(source, score)
    local enrolment = enrolments[source]
    if not enrolment then return false, 'not_enrolled' end

    local course = enrolment.course
    Academy.Abandon(source, true)

    local profile = State.ProfileFor(enrolment.identifier, Bridge.GetName(source))
    if not profile then return false, 'unknown_firefighter' end

    profile.training[course.id] = GetGameTimer()
    if not Shared.HasCertification(profile, course.certification) then
        profile.certifications[#profile.certifications + 1] = course.certification
    end
    State.SaveProfile(profile)
    record(profile.identifier, course, true, score or 100, 'academy')

    local certification = Shared.Certification(course.certification)
    Bridge.Notify(source, ('Passed %s. You are signed off for %s.'):format(
        course.label, certification and certification.label or course.certification), 'success', 10000)
    TriggerClientEvent(Bridge.Event('fire:training'), source, {
        course = course.id, passed = true, certification = course.certification
    })
    return true, nil, profile
end

function Academy.Fail(source, reason)
    local enrolment = enrolments[source]
    if not enrolment then return false, 'not_enrolled' end

    local course = enrolment.course
    Academy.Abandon(source, true)

    local profile = State.ProfileFor(enrolment.identifier, Bridge.GetName(source))
    if profile then
        profile.training[course.id] = GetGameTimer()
        State.SaveProfile(profile)
        record(profile.identifier, course, false, 0, 'academy')
    end

    Bridge.Notify(source, ('Failed %s: %s. Try again shortly.'):format(course.label, reason or 'out of time'), 'error', 10000)
    TriggerClientEvent(Bridge.Event('fire:training'), source, {
        course = course.id, passed = false, reason = reason
    })
    return true
end

-- Drill scoring runs on its own beat rather than dispatch's, because a drill
-- is finished by the clock as often as by the trainee.
function Academy.Tick()
    local now = GetGameTimer()
    for source, enrolment in pairs(enrolments) do
        if not State.IsOnDuty(source) then
            Academy.Abandon(source, true)
        elseif enrolment.phase == 'practical' then
            local call = State.GetCall(enrolment.callId)
            if not call then
                Academy.Fail(source, 'the drill was lost')
            elseif Incident.IsComplete(call) then
                local spent = now - call.createdAt
                local limit = math.max(1, (call.deadline or now) - call.createdAt)
                Academy.Pass(source, math.floor(Shared.Clamp(100 - (spent / limit) * 40, 60, 100)))
            elseif now >= (enrolment.deadline or now) then
                Academy.Fail(source, 'out of time')
            end
        end
    end
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    while true do
        Wait(2000)
        if Shared.Enabled() and settings().enabled ~= false then
            local ok, err = pcall(Academy.Tick)
            if not ok then Bridge.Print('academy tick failed: %s', tostring(err)) end
        end
    end
end)

AddEventHandler('playerDropped', function()
    Academy.Abandon(source, true)
end)
