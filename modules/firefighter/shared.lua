-- Shared firefighter logic: everything both sides need to agree on, and
-- nothing that touches a native. Keeping the department lookups, the rank
-- table, the suppression arithmetic, and the catalogue helpers here means the
-- client can render an honest preview of a number the server is the one to
-- actually apply.

DAG = DAG or {}
DAG.Fire = DAG.Fire or {}

local Fire = DAG.Fire
local Shared = {}
Fire.Shared = Shared

-- Lifecycle of a call. `pending` is dispatched but unanswered; `assigned` has
-- responders but nobody on scene; `working` has at least one responder within
-- the scene radius; the last two are terminal.
Fire.CallState = {
    pending = 'pending',
    assigned = 'assigned',
    working = 'working',
    resolved = 'resolved',
    expired = 'expired'
}

-- Victims move forward only: trapped -> freed -> treated -> transported, with
-- `deceased` as the one branch off it.
Fire.VictimState = {
    trapped = 'trapped',
    freed = 'freed',
    treated = 'treated',
    transported = 'transported',
    deceased = 'deceased'
}

function Shared.Settings()
    return Config.Firefighter or {}
end

function Shared.Enabled()
    return Shared.Settings().enabled ~= false
end

function Shared.Clamp(value, minimum, maximum)
    if type(value) ~= 'number' or value ~= value then return minimum end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function Shared.Round(value, places)
    local factor = 10 ^ (places or 0)
    return math.floor((tonumber(value) or 0) * factor + 0.5) / factor
end

-- Accepts a vector3 or any table carrying x/y/z, because coordinates arrive
-- from config as vectors and off the network as plain tables.
function Shared.Coords(value)
    if type(value) ~= 'table' then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if not x or not y or not z then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

function Shared.Distance(a, b)
    local first, second = Shared.Coords(a), Shared.Coords(b)
    if not first or not second then return math.huge end
    local dx, dy, dz = first.x - second.x, first.y - second.y, first.z - second.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Catalogue lookups --------------------------------------------------------

local function findById(list, id)
    if id == nil then return nil end
    for _, entry in ipairs(list or {}) do
        if entry.id == id then return entry end
    end
    return nil
end

Shared.FindById = findById

function Shared.CallTypes()
    return Shared.Settings().callTypes or {}
end

function Shared.CallType(id)
    return findById(Shared.CallTypes(), id)
end

function Shared.Stations()
    return Shared.Settings().stations or {}
end

function Shared.Station(id)
    return findById(Shared.Stations(), id)
end

function Shared.Apparatus(id)
    return findById(Shared.Settings().apparatus or {}, id)
end

function Shared.Certification(id)
    return findById(Shared.Settings().certifications or {}, id)
end

function Shared.Courses()
    return (Shared.Settings().academy or {}).courses or {}
end

function Shared.Course(id)
    return findById(Shared.Courses(), id)
end

function Shared.Agent(id)
    local agents = (Shared.Settings().fire or {}).agents or {}
    return agents[id]
end

-- The configured item name for a role ('jaws', 'hose', 'scba'...). Returns nil
-- when the server has not named one, which reads as "no item required".
function Shared.Item(role)
    return (Shared.Settings().items or {})[role]
end

-- Departments --------------------------------------------------------------

function Shared.Departments()
    return Shared.Settings().departments or {}
end

function Shared.Department(id)
    return findById(Shared.Departments(), id)
end

function Shared.StationsFor(departmentId)
    local list = {}
    for _, station in ipairs(Shared.Stations()) do
        if station.department == departmentId then list[#list + 1] = station end
    end
    return list
end

function Shared.DepartmentForStation(stationId)
    local station = Shared.Station(stationId)
    return station and Shared.Department(station.department) or nil
end

-- Which department a set of coordinates belongs to. Jurisdiction circles come
-- first; anything outside every circle falls to whichever department has the
-- nearest station, so a call in the middle of nowhere still gets toned out.
function Shared.DepartmentForCoords(coords)
    local best, bestDistance
    for _, department in ipairs(Shared.Departments()) do
        local zone = department.jurisdiction
        if zone and zone.center then
            local distance = Shared.Distance(coords, zone.center)
            if distance <= (tonumber(zone.radius) or 0) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = department, distance
            end
        end
    end
    if best then return best end

    local nearest, nearestDistance
    for _, station in ipairs(Shared.Stations()) do
        local distance = Shared.Distance(coords, station.coords)
        if not nearestDistance or distance < nearestDistance then
            nearest, nearestDistance = station, distance
        end
    end
    if nearest then return Shared.Department(nearest.department) end
    return Shared.Department(Shared.Settings().fallbackDepartment)
end

function Shared.MutualAid(departmentId)
    local department = Shared.Department(departmentId)
    local list = {}
    for _, id in ipairs(department and department.mutualAid or {}) do
        local other = Shared.Department(id)
        if other then list[#list + 1] = other end
    end
    return list
end

-- A DAG.Access policy for one department and one action. The framework job is
-- the primary grant; the ACE is what makes the job work on a framework that
-- cannot report jobs at all.
function Shared.Policy(departmentId, action)
    local access = Shared.Settings().access or {}
    local rule = access[action] or {}
    local namespace = access.aceNamespace or 'firefighter'

    if action == 'admin' then
        return { ace = rule.ace or (namespace .. '.admin') }
    end

    local department = Shared.Department(departmentId)
    local policy = { ace = rule.ace or (namespace .. '.' .. (departmentId or 'fire') .. '.' .. action) }
    if department and department.job then
        policy.jobs = { [department.job] = tonumber(rule.minimumGrade) or 0 }
    end
    return policy
end

-- Uniforms -----------------------------------------------------------------

function Shared.UniformSet(departmentId, gender, variant)
    local uniforms = Shared.Settings().uniforms or {}
    local department = Shared.Department(departmentId)
    local set = (uniforms.sets or {})[department and department.uniform or departmentId]
    if not set then return nil end

    local bySex = set[gender == 'female' and 'female' or 'male']
    if not bySex then return nil end
    return bySex[variant or 'turnout'], bySex
end

-- Ranks and certifications -------------------------------------------------

function Shared.Ranks()
    return Shared.Settings().ranks or {}
end

-- Ranks are ordered by XP in config, but a server owner reordering them by
-- hand should not silently promote everyone, so the scan does not assume it.
function Shared.RankFor(xp)
    local points = tonumber(xp) or 0
    local best, bestIndex
    for index, rank in ipairs(Shared.Ranks()) do
        local required = tonumber(rank.xp) or 0
        if points >= required and (not best or required >= (tonumber(best.xp) or 0)) then
            best, bestIndex = rank, index
        end
    end
    return best, bestIndex or 0
end

function Shared.NextRank(xp)
    local points = tonumber(xp) or 0
    local upcoming, upcomingRequired
    for _, rank in ipairs(Shared.Ranks()) do
        local required = tonumber(rank.xp) or 0
        if required > points and (not upcomingRequired or required < upcomingRequired) then
            upcoming, upcomingRequired = rank, required
        end
    end
    if not upcoming then return nil, 0 end
    return upcoming, upcomingRequired - points
end

function Shared.RankLabel(xp)
    local rank = Shared.RankFor(xp)
    return rank and rank.label or 'Unranked'
end

-- The framework job grade that goes with a rank, used when hiring and
-- promoting. It has to line up with the grades in your framework's own job
-- definition; see install/jobs/.
function Shared.GradeFor(xp)
    local rank = Shared.RankFor(xp)
    return tonumber(rank and rank.grade) or 0
end

function Shared.PayMultiplier(xp)
    local rank = Shared.RankFor(xp)
    return tonumber(rank and rank.pay) or 1.0
end

-- A certification is held when the rank grants it or it has been earned at the
-- academy or signed off by an officer. Rank grants are cumulative: reaching
-- Captain keeps everything earned below.
function Shared.HeldCertifications(profile)
    local held = {}
    for _, id in ipairs((profile or {}).certifications or {}) do held[id] = true end

    local _, rankIndex = Shared.RankFor((profile or {}).xp or 0)
    for index, rank in ipairs(Shared.Ranks()) do
        if index <= rankIndex then
            for _, id in ipairs(rank.certifications or {}) do held[id] = true end
        end
    end
    return held
end

function Shared.HasCertification(profile, id)
    if not id then return true end
    return Shared.HeldCertifications(profile)[id] == true
end

-- Whether a trainee may sit a course at all: prerequisites, rank floor, and
-- not already holding it.
function Shared.CourseAvailable(profile, courseId)
    local course = Shared.Course(courseId)
    if not course then return false, 'unknown_course' end
    if Shared.HasCertification(profile, course.certification) then return false, 'already_held' end

    local _, rankIndex = Shared.RankFor((profile or {}).xp or 0)
    if rankIndex < (tonumber(course.minimumRank) or 0) + 1 then return false, 'rank_too_low' end

    for _, required in ipairs(course.requires or {}) do
        if not Shared.HasCertification(profile, required) then return false, 'missing_prerequisite' end
    end
    return true
end

-- Suppression --------------------------------------------------------------

-- Litres of water buy intensity points. Returning the litres actually consumed
-- as well as the points removed lets the caller bill a tank for exactly the
-- water that did something, instead of for the whole burst.
function Shared.Suppression(litres, agentId, intensity)
    local settings = Shared.Settings().fire or {}
    local agent = Shared.Agent(agentId)
    if not agent then return 0, 0 end

    local available = math.min(tonumber(litres) or 0, tonumber(settings.maxLitresPerReport) or 90)
    if available <= 0 then return 0, 0 end

    local perPoint = tonumber(settings.litresPerPoint) or 2.0
    if perPoint <= 0 then perPoint = 2.0 end

    local points = (available / perPoint) * (tonumber(agent.multiplier) or 1.0)
    local ceiling = tonumber(intensity) or points
    if points <= ceiling then return Shared.Round(points, 2), Shared.Round(available, 2) end

    -- Overshoot: only bill for the water that had something left to put out.
    local used = (ceiling / (tonumber(agent.multiplier) or 1.0)) * perPoint
    return Shared.Round(ceiling, 2), Shared.Round(math.min(available, used), 2)
end

-- 0 when the scene is out, 1 when every node is at full intensity. Used for
-- the severity label, the dispatch blip, and the payout multiplier.
function Shared.Severity(call)
    local nodes = (call or {}).fires
    if type(nodes) ~= 'table' then return 0 end

    local total, count, maximum = 0, 0, tonumber((Shared.Settings().fire or {}).maxIntensity) or 100
    for _, node in pairs(nodes) do
        count = count + 1
        total = total + Shared.Clamp(tonumber(node.intensity) or 0, 0, maximum)
    end
    if count == 0 then return 0 end
    return Shared.Round(total / (count * maximum), 3)
end

function Shared.SeverityLabel(severity)
    if severity <= 0 then return 'Under control' end
    if severity < 0.25 then return 'Knockdown' end
    if severity < 0.5 then return 'Contained' end
    if severity < 0.75 then return 'Working fire' end
    return 'Fully involved'
end

-- Dispatch load ------------------------------------------------------------

-- How many calls may be open at once. A bigger roster gets a busier city, so
-- eight firefighters are not all standing on the same alarm.
function Shared.MaxActiveCalls(onDuty)
    local dispatch = Shared.Settings().dispatch or {}
    local base = tonumber(dispatch.maxActive) or 2
    local perFirefighter = tonumber(dispatch.perFirefighter) or 1
    local ceiling = tonumber(dispatch.maxActiveCeiling) or 8
    return math.min(ceiling, base + math.max(0, math.floor(onDuty or 0)) * perFirefighter)
end

function Shared.CallWeight(callType)
    if type(callType) ~= 'table' then return 0 end
    local weight = tonumber(callType.weight)
    if weight then return math.max(0, math.floor(weight)) end
    -- No explicit weight: fall back to inverting the priority so a working
    -- fire still comes up more often than an alarm.
    return math.max(1, 4 - (tonumber(callType.priority) or 2))
end

-- Formatting ---------------------------------------------------------------

function Shared.FormatCallId(sequence)
    return ('FD-%04d'):format(tonumber(sequence) or 0)
end

function Shared.FormatDuration(milliseconds)
    local seconds = math.max(0, math.floor((tonumber(milliseconds) or 0) / 1000))
    if seconds < 60 then return ('%ds'):format(seconds) end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return ('%dm %02ds'):format(minutes, seconds % 60) end
    return ('%dh %02dm'):format(math.floor(minutes / 60), minutes % 60)
end

function Shared.FormatMoney(amount)
    local whole = math.floor(math.abs(tonumber(amount) or 0) + 0.5)
    local text = tostring(whole)
    local grouped, replacements = text, 1
    while replacements > 0 do
        grouped, replacements = grouped:gsub('^(%d+)(%d%d%d)', '%1,%2')
    end
    return ('%s$%s'):format((tonumber(amount) or 0) < 0 and '-' or '', grouped)
end

-- Profiles -----------------------------------------------------------------

function Shared.NewProfile(identifier, name)
    return {
        identifier = identifier,
        name = name,
        department = nil,
        xp = 0,
        certifications = {},
        training = {},
        hiredAt = nil,
        stats = {
            calls = 0,
            firesExtinguished = 0,
            victimsRescued = 0,
            victimsLost = 0,
            hazardsContained = 0,
            litresUsed = 0,
            earnings = 0,
            fastestResponse = nil
        }
    }
end

-- A profile can come back from JSON or from a SQL row missing anything that
-- was empty when it was written, and carrying anything an admin typed into it.
function Shared.NormalizeProfile(profile, identifier, name)
    local base = Shared.NewProfile(identifier, name)
    if type(profile) ~= 'table' then return base end

    base.xp = math.max(0, tonumber(profile.xp) or 0)
    base.name = profile.name or name
    base.identifier = profile.identifier or identifier
    base.hiredAt = tonumber(profile.hiredAt) or profile.hiredAt
    if Shared.Department(profile.department) then base.department = profile.department end

    if type(profile.certifications) == 'table' then
        for _, id in ipairs(profile.certifications) do
            if Shared.Certification(id) then base.certifications[#base.certifications + 1] = id end
        end
    end

    if type(profile.training) == 'table' then
        for key, value in pairs(profile.training) do
            if type(value) == 'number' then base.training[key] = value end
        end
    end

    if type(profile.stats) == 'table' then
        for key, value in pairs(base.stats) do
            local stored = profile.stats[key]
            if type(stored) == 'number' then base.stats[key] = stored
            elseif value ~= nil then base.stats[key] = value end
        end
        if type(profile.stats.fastestResponse) == 'number' then
            base.stats.fastestResponse = profile.stats.fastestResponse
        end
    end

    return base
end
