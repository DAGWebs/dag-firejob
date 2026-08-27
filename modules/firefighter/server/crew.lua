-- Working a call as a crew rather than as several people who happen to be
-- standing near each other.
--
-- Two things live here. Roles, which say who is doing what and let an officer
-- run a board; and assistance, which makes every timed job faster the more
-- hands are on it. Assistance is always on, because rewarding teamwork is
-- better than requiring it. Hard requirements are opt-in for servers with the
-- roster to support them.

local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Crew = {}
Fire.Crew = Crew

local function settings()
    return Shared.Settings().crew or {}
end

function Crew.Enabled()
    return Shared.Enabled() and settings().enabled ~= false
end

function Crew.Roles()
    return settings().roles or {}
end

function Crew.Role(id)
    return Shared.FindById(Crew.Roles(), id)
end

-- Assignment ----------------------------------------------------------------

-- Who is doing what, on the call rather than on the person: a firefighter who
-- clears and picks up another job starts fresh.
function Crew.Assignments(call)
    return call and call.crew or {}
end

function Crew.RoleOf(call, identifier)
    return (call and call.crew or {})[identifier]
end

function Crew.Holder(call, roleId)
    for identifier, assigned in pairs(call.crew or {}) do
        if assigned == roleId then return identifier end
    end
    return nil
end

function Crew.Assign(source, roleId, targetIdentifier)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = record.callId and State.GetCall(record.callId)
    if not call then return false, 'not_assigned' end

    local identifier = targetIdentifier or record.identifier
    -- Assigning somebody else is what command is for.
    if identifier ~= record.identifier then
        local mine = Crew.RoleOf(call, record.identifier)
        if mine ~= 'command' and not Fire.Departments.CanCommand(source, call.department) then
            return false, 'denied'
        end
    end

    if not call.responders[identifier] then return false, 'not_on_call' end

    call.crew = call.crew or {}
    if roleId == nil or roleId == false then
        call.crew[identifier] = nil
        call.dirty = true
        return true, nil, nil
    end

    local role = Crew.Role(roleId)
    if not role then return false, 'unknown_role' end

    if role.certification and Shared.Settings().enforceCertifications ~= false then
        local responder = call.responders[identifier]
        local profile = State.ProfileFor(identifier, responder and responder.name)
        if not Shared.HasCertification(profile, role.certification) then return false, 'not_certified' end
    end

    -- One nozzle, one pump, one incident commander. Everything else can be
    -- doubled up.
    if role.exclusive then
        local holder = Crew.Holder(call, roleId)
        if holder and holder ~= identifier then return false, 'role_taken' end
    end

    call.crew[identifier] = roleId
    call.dirty = true
    return true, nil, role
end

function Crew.Clear(call, identifier)
    if not call or not call.crew then return false end
    call.crew[identifier] = nil
    return true
end

-- Assistance ------------------------------------------------------------------

-- Everybody on scene who is not the one doing the job counts as a pair of
-- hands. This is deliberately generous: the point is that turning up to help
-- is always worth something.
function Crew.HandsOn(call, identifier)
    local hands = 0
    for holder, responder in pairs(call.responders or {}) do
        if holder ~= identifier and responder.onScene then hands = hands + 1 end
    end
    return hands
end

-- What a timed job costs with this many people on it. Never below the floor,
-- so a full crew is fast but not instant.
function Crew.Duration(call, identifier, duration)
    local base = tonumber(duration) or 0
    if not Crew.Enabled() or not call then return base, 0 end

    local hands = Crew.HandsOn(call, identifier)
    if hands <= 0 then return base, 0 end

    local bonus = tonumber(settings().assistBonus) or 0.25
    local floor = Shared.Clamp(tonumber(settings().assistFloor) or 0.5, 0.1, 1.0)
    local scale = math.max(floor, 1.0 - bonus * hands)
    return math.floor(base * scale), hands
end

-- Jobs a server can decide genuinely need two people. Off by default: a
-- two-firefighter server should still be able to play.
function Crew.Requires(job)
    if not Crew.Enabled() or not settings().enforce then return false end
    for _, entry in ipairs(settings().requiresTwo or {}) do
        if entry == job then return true end
    end
    return false
end

function Crew.HasHands(call, identifier, job)
    if not Crew.Requires(job) then return true end
    return Crew.HandsOn(call, identifier) > 0
end

-- Accountability -----------------------------------------------------------------

-- Command calls it, everybody answers, and whoever does not is where the
-- search starts. This is the mechanic that makes an incident commander a real
-- job rather than a title.
function Crew.CallPar(source)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = record.callId and State.GetCall(record.callId)
    if not call then return false, 'not_assigned' end

    local mine = Crew.RoleOf(call, record.identifier)
    if mine ~= 'command' and not Fire.Departments.CanCommand(source, call.department) then
        return false, 'denied'
    end

    local par = settings().par or {}
    local now = GetGameTimer()
    if call.par and now - call.par.startedAt < (tonumber(par.cooldown) or 60000) then
        return false, 'too_soon'
    end

    call.par = {
        startedAt = now,
        window = tonumber(par.window) or 30000,
        calledBy = record.identifier,
        answered = {}
    }
    call.dirty = true

    State.BroadcastCall(call, 'fire:par', call.id, call.par.window)
    Fire.Dispatch.Radio(('%s - personnel accountability report, all units answer'):format(call.id), 'error', call)
    return true, nil, call.par
end

function Crew.Answer(source)
    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local call = record.callId and State.GetCall(record.callId)
    if not call or not call.par then return false, 'no_par' end

    call.par.answered[record.identifier] = GetGameTimer()
    call.dirty = true
    return true, nil, call.par
end

-- Who did not answer. Anybody on that list who is also in the fire is the
-- reason PAR checks exist.
function Crew.Unaccounted(call)
    if not call or not call.par then return {} end

    local missing = {}
    for identifier, responder in pairs(call.responders or {}) do
        if responder.onScene and not call.par.answered[identifier] then
            missing[#missing + 1] = { identifier = identifier, name = responder.name, source = responder.source }
        end
    end
    table.sort(missing, function(a, b) return (a.name or '') < (b.name or '') end)
    return missing
end

function Crew.ResolvePar(call)
    if not call or not call.par or call.par.resolved then return nil end
    if GetGameTimer() - call.par.startedAt < call.par.window then return nil end

    call.par.resolved = true
    local missing = Crew.Unaccounted(call)
    call.dirty = true

    if #missing == 0 then
        Fire.Dispatch.Radio(('%s - PAR complete, all units accounted for'):format(call.id), 'success', call)
        return missing
    end

    local names = {}
    for _, entry in ipairs(missing) do names[#names + 1] = entry.name or entry.identifier end
    Fire.Dispatch.Radio(('%s - PAR incomplete, no answer from %s'):format(
        call.id, table.concat(names, ', ')), 'error', call)

    -- Somebody who did not answer while standing in it has a problem, and this
    -- is how the crew finds out about it.
    for _, entry in ipairs(missing) do
        if Fire.Mayday and entry.source then Fire.Mayday.Check(entry.source, 'unaccounted') end
    end
    return missing
end

-- The board -------------------------------------------------------------------------

function Crew.Board(call)
    if not call then return nil end

    local board = { callId = call.id, roles = {}, unassigned = {}, par = nil }
    for identifier, responder in pairs(call.responders or {}) do
        local roleId = (call.crew or {})[identifier]
        local entry = {
            identifier = identifier,
            name = responder.name,
            onScene = responder.onScene == true,
            interior = responder.interior == true,
            role = roleId,
            roleLabel = roleId and (Crew.Role(roleId) or {}).label or nil
        }
        if roleId then board.roles[#board.roles + 1] = entry else board.unassigned[#board.unassigned + 1] = entry end
    end

    table.sort(board.roles, function(a, b) return (a.role or '') < (b.role or '') end)
    table.sort(board.unassigned, function(a, b) return (a.name or '') < (b.name or '') end)

    if call.par then
        board.par = {
            startedAt = call.par.startedAt,
            window = call.par.window,
            resolved = call.par.resolved == true,
            answered = 0,
            missing = #Crew.Unaccounted(call)
        }
        for _ in pairs(call.par.answered) do board.par.answered = board.par.answered + 1 end
    end
    return board
end

-- Interior tracking is what a PAR check is actually about: standing in the
-- smoke is what makes not answering serious.
function Crew.SetInterior(source, interior)
    local record = State.Duty(source)
    if not record then return false end

    local call = record.callId and State.GetCall(record.callId)
    if not call then return false end

    local responder = call.responders[record.identifier]
    if not responder then return false end
    if responder.interior == interior then return true end

    responder.interior = interior == true
    call.dirty = true
    return true
end

function Crew.Interior(call)
    local inside = {}
    for identifier, responder in pairs(call.responders or {}) do
        if responder.interior then inside[#inside + 1] = { identifier = identifier, name = responder.name } end
    end
    return inside
end
