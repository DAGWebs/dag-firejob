-- Station life.
--
-- The job is mostly waiting, and until now waiting was nothing at all. These
-- are the small jobs that fill a quiet shift: check the apparatus, test the
-- hose, count the equipment, clean the place. Each pays a little, each is on a
-- cooldown so it is something to do rather than a way to farm, and each has to
-- be done at the fixture it is about.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Chores = {}
Fire.Chores = Chores

local done = {}

local function settings()
    return Shared.Settings().chores or {}
end

function Chores.Enabled()
    return Shared.Enabled() and settings().enabled ~= false
end

function Chores.List()
    return settings().list or {}
end

function Chores.Get(id)
    return Shared.FindById(Chores.List(), id)
end

local function key(identifier, choreId)
    return ('%s/%s'):format(identifier, choreId)
end

function Chores.LastDone(identifier, choreId)
    return done[key(identifier, choreId)]
end

function Chores.Available(identifier, choreId)
    local chore = Chores.Get(choreId)
    if not chore then return false, 'unknown_chore' end

    local last = Chores.LastDone(identifier, choreId)
    if last and GetGameTimer() - last < (tonumber(settings().cooldown) or 1800000) then
        return false, 'cooling_down'
    end
    return true
end

-- What this firefighter could be doing right now, and how long until the rest
-- come back round.
function Chores.Catalogue(source)
    local record = State.Duty(source)
    local identifier = record and record.identifier
    local now = GetGameTimer()
    local cooldown = tonumber(settings().cooldown) or 1800000
    local list = {}

    for _, chore in ipairs(Chores.List()) do
        local last = identifier and Chores.LastDone(identifier, chore.id)
        list[#list + 1] = {
            id = chore.id,
            label = chore.label,
            point = chore.point,
            time = chore.time,
            pay = chore.pay,
            available = last == nil or (now - last) >= cooldown,
            cooldown = last and math.max(0, cooldown - (now - last)) or 0
        }
    end
    return list
end

-- Doing one -------------------------------------------------------------------

function Chores.Begin(source, choreId)
    if not Chores.Enabled() then return false, 'disabled' end

    local record = State.Duty(source)
    if not record then return false, 'off_duty' end
    if record.chore then return false, 'already_working' end

    local chore = Chores.Get(choreId)
    if not chore then return false, 'unknown_chore' end

    local available, reason = Chores.Available(record.identifier, choreId)
    if not available then return false, reason end

    -- It has to be done at the thing it is about, which is also what stops it
    -- being done from the sofa.
    local station = record.station and Shared.Station(record.station)
    local coords = State.PlayerCoords(source)
    if not station or not coords then return false, 'no_station' end
    if select(2, Shared.NearestPointOf(station, coords, chore.point or 'garage')) > 6.0 then
        return false, 'wrong_place'
    end

    record.chore = {
        id = chore.id,
        startedAt = GetGameTimer(),
        duration = tonumber(chore.time) or 10000
    }
    return true, nil, record.chore.duration
end

function Chores.Cancel(source)
    local record = State.Duty(source)
    if not record then return false end
    record.chore = nil
    return true
end

function Chores.Complete(source)
    local record = State.Duty(source)
    if not record or not record.chore then return false, 'not_working' end

    local pending = record.chore
    record.chore = nil

    if GetGameTimer() - pending.startedAt < pending.duration * 0.9 then return false, 'too_fast' end

    local chore = Chores.Get(pending.id)
    if not chore then return false, 'unknown_chore' end

    local coords = State.PlayerCoords(source)
    local station = record.station and Shared.Station(record.station)
    if not station or not coords then return false, 'no_station' end
    if select(2, Shared.NearestPointOf(station, coords, chore.point or 'garage')) > 8.0 then
        return false, 'left_it'
    end

    done[key(record.identifier, chore.id)] = GetGameTimer()

    local pay = math.floor(tonumber(chore.pay) or 0)
    if pay > 0 then
        local funded = Fire.Billing and Fire.Billing.Fund(pay, 'station work') or pay
        if funded > 0 then
            Bridge.AddMoney(source, (Shared.Settings().pay or {}).account or 'bank',
                funded, 'firefighter:chore')
        end
    end

    local profile = State.Profile(source)
    if profile then
        profile.xp = profile.xp + math.floor(tonumber(chore.xp) or 0)
        profile.stats.chores = (profile.stats.chores or 0) + 1
        State.SaveProfile(profile)
    end

    return true, nil, chore
end
