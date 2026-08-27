-- The skill check.
--
-- Every timed job in this job used to be "stand here for N seconds", which
-- meant the best firefighter on the server and the worst one got identical
-- results. This is the difference between them: a moving cursor and a target
-- zone, hit it and the job goes faster, miss it and it does not.
--
-- The server already set a floor when the job started and will not accept
-- anything under it, so the most a perfect run can do is exactly what a
-- perfect run should do.

local Fire = DAG.Fire
local Shared = Fire.Shared
local Skill = {}
Fire.Skill = Skill

local active = nil

local function settings()
    return Shared.Settings().skill or {}
end

function Skill.Enabled()
    return Shared.Enabled() and settings().enabled ~= false and settings().provider ~= 'none'
end

function Skill.Active()
    return active
end

function Skill.Provider()
    local wanted = settings().provider or 'auto'
    if wanted == 'bundled' then return 'bundled' end
    if wanted == 'ox_lib' then
        return GetResourceState('ox_lib') == 'started' and 'ox_lib' or 'bundled'
    end
    if GetResourceState('ox_lib') == 'started' then return 'ox_lib' end
    return 'bundled'
end

-- The bundled check ---------------------------------------------------------

-- A cursor sweeping a bar with a zone somewhere in it. Deliberately simple:
-- it has to be readable through smoke, at night, in a hurry.
-- The zone is placed from the configured width every time rather than from
-- wherever it happened to be, so it cannot drift.
local function placeZone()
    local window = Shared.Clamp(tonumber(settings().window) or 0.28, 0.05, 0.7)
    local start = 0.1 + math.random() * math.max(0, 0.9 - window - 0.1)
    return { from = start, to = start + window }
end

function Skill.Begin(duration)
    active = {
        startedAt = GetGameTimer(),
        duration = math.max(1200, tonumber(duration) or 3000),
        speed = tonumber(settings().speed) or 1.15,
        zone = placeZone(),
        hits = 0,
        attempts = 0,
        done = false
    }
    return active
end

-- Where the cursor is, 0 to 1, bouncing rather than wrapping so the return
-- sweep is another chance rather than a jump.
function Skill.Cursor()
    if not active then return 0 end

    local elapsed = (GetGameTimer() - active.startedAt) / 1000 * active.speed
    local phase = elapsed % 2
    if phase > 1 then phase = 2 - phase end
    return phase
end

function Skill.InZone()
    local cursor = Skill.Cursor()
    return active ~= nil and cursor >= active.zone.from and cursor <= active.zone.to
end

-- One press. A hit moves the zone so the next one is not free.
function Skill.Press()
    if not active or active.done then return nil end

    active.attempts = active.attempts + 1
    if not Skill.InZone() then return false end

    active.hits = active.hits + 1
    active.zone = placeZone()
    return true
end

-- How well it went, 0 to 1. Nothing pressed is nothing earned rather than a
-- failure: a firefighter who ignores it just works at the normal speed.
function Skill.Score()
    if not active or active.attempts == 0 then return 0 end
    return Shared.Clamp(active.hits / math.max(3, active.attempts), 0, 1)
end

function Skill.Finish()
    local score = Skill.Score()
    active = nil
    return score
end

function Skill.Cancel()
    active = nil
end

-- ox_lib ---------------------------------------------------------------------

-- Where ox_lib is running its skill check is the one players already know, so
-- it is used instead of the bundled one.
function Skill.Run(duration, callback)
    if not Skill.Enabled() then return callback(0) end

    if Skill.Provider() == 'ox_lib' then
        local ok, result = pcall(function()
            return exports.ox_lib:skillCheck({ 'easy', 'medium', 'easy' })
        end)
        return callback(ok and result and 1.0 or 0)
    end

    Skill.Begin(duration)
    -- The bundled check is driven by the action loop that started it, which
    -- calls Finish when the job is done.
    callback(nil)
end

-- Drawing ---------------------------------------------------------------------

function Skill.Draw()
    if not active then return false end

    local width, height = 0.16, 0.014
    local x, y = 0.5 - width / 2, 0.86

    DrawRect(0.5, y + height / 2, width + 0.006, height + 0.006, 15, 18, 24, 200)
    DrawRect(0.5, y + height / 2, width, height, 40, 46, 58, 220)

    local zoneWidth = (active.zone.to - active.zone.from) * width
    DrawRect(x + active.zone.from * width + zoneWidth / 2, y + height / 2, zoneWidth, height, 90, 190, 120, 220)

    local cursor = Skill.Cursor()
    DrawRect(x + cursor * width, y + height / 2, 0.0035, height, 240, 240, 240, 255)
    return true
end

CreateThread(function()
    while true do
        local sleep = 250
        if active then
            sleep = 0
            Skill.Draw()
            if IsControlJustPressed(0, 22) then Skill.Press() end
        end
        Wait(sleep)
    end
end)
