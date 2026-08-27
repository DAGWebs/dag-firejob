-- Shared firefighter logic: everything both sides need to agree on, and
-- nothing that touches a native. Keeping the rank table, the suppression
-- arithmetic, and the call catalogue lookups here means the client can render
-- an honest preview of a number the server is the one to actually apply.

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

function Shared.Agent(id)
    local agents = (Shared.Settings().fire or {}).agents or {}
    return agents[id]
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

function Shared.PayMultiplier(xp)
    local rank = Shared.RankFor(xp)
    return tonumber(rank and rank.pay) or 1.0
end

-- A certification is held when the rank grants it or an officer signed it off.
-- Rank grants are cumulative: reaching Captain keeps everything earned below.
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
        xp = 0,
        certifications = {},
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

-- Storage round-trips through JSON, so a profile read back can be missing
-- anything that was empty when it was written.
function Shared.NormalizeProfile(profile, identifier, name)
    local base = Shared.NewProfile(identifier, name)
    if type(profile) ~= 'table' then return base end

    base.xp = math.max(0, tonumber(profile.xp) or 0)
    base.name = profile.name or name
    base.identifier = profile.identifier or identifier

    if type(profile.certifications) == 'table' then
        for _, id in ipairs(profile.certifications) do
            if Shared.Certification(id) then base.certifications[#base.certifications + 1] = id end
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
