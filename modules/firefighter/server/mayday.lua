-- Mayday.
--
-- The most dramatic thing that can happen on a fireground is that one of the
-- crew stops being able to get themselves out, and until now this job had no
-- way for it to happen. A firefighter who runs out of air in the smoke, takes
-- too much heat, or calls it themselves goes down: the department is told, a
-- blip drops on them, and somebody has to reach them and drag them out before
-- the clock runs down.
--
-- This is also what makes the air gauge matter. Running out is not an
-- inconvenience if it is the thing that puts you on the floor.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Mayday = {}
Fire.Mayday = Mayday

local active = {}

local function settings()
    return Shared.Settings().mayday or {}
end

function Mayday.Enabled()
    return Shared.Enabled() and settings().enabled ~= false
end

function Mayday.Active()
    return active
end

function Mayday.Of(source)
    return active[source]
end

function Mayday.Count()
    local count = 0
    for _ in pairs(active) do count = count + 1 end
    return count
end

-- Going down ------------------------------------------------------------------

local REASONS = {
    air = 'out of air',
    heat = 'overcome by heat',
    unaccounted = 'not answering a PAR check',
    manual = 'calling a mayday'
}

function Mayday.Declare(source, reason)
    if not Mayday.Enabled() then return false, 'disabled' end
    if active[source] then return false, 'already_down' end

    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local coords = State.PlayerCoords(source)
    if not coords then return false, 'no_position' end

    local call = record.callId and State.GetCall(record.callId)
    local down = {
        source = source,
        identifier = record.identifier,
        name = record.name,
        department = record.department,
        callId = call and call.id or nil,
        reason = reason or 'manual',
        coords = coords,
        startedAt = GetGameTimer(),
        window = tonumber(settings().window) or 120000
    }
    active[source] = down

    -- Everybody hears a mayday, not just the crew on that call: it is the one
    -- thing worth pulling units off other work for.
    State.Broadcast('fire:mayday', {
        source = source,
        name = down.name,
        reason = REASONS[down.reason] or down.reason,
        coords = down.coords,
        callId = down.callId,
        window = down.window
    })

    Fire.Dispatch.Radio(('MAYDAY MAYDAY - %s is down, %s'):format(
        down.name, REASONS[down.reason] or down.reason), 'error', call)
    Bridge.Notify(source, 'You are down. Hold on.', 'error', 10000)
    return true, nil, down
end

-- Checked from the simulation tick and from whatever else can see a
-- firefighter in trouble. Deliberately cheap: it runs on everybody on duty.
function Mayday.Check(source, reason)
    if not Mayday.Enabled() or active[source] then return false end

    local record = State.Duty(source)
    if not record then return false end

    if reason then return select(1, Mayday.Declare(source, reason)) end

    -- Out of air while inside is the classic one.
    if (record.air or 0) <= 0 then
        local call = record.callId and State.GetCall(record.callId)
        local responder = call and call.responders[record.identifier]
        if responder and responder.interior then
            return select(1, Mayday.Declare(source, 'air'))
        end
    end

    -- Hurt badly enough that they are not walking out on their own.
    local ped = GetPlayerPed(source)
    if ped and ped ~= 0 then
        local health = GetEntityHealth(ped)
        if health > 0 and health <= (tonumber(settings().healthAt) or 120) then
            return select(1, Mayday.Declare(source, 'heat'))
        end
    end

    return false
end

-- Getting them out --------------------------------------------------------------

function Mayday.Rescuer(source)
    for _, down in pairs(active) do
        if down.rescuer == source then return down end
    end
    return nil
end

function Mayday.BeginRescue(source, targetSource)
    local down = active[targetSource]
    if not down then return false, 'not_down' end
    if down.rescuer and down.rescuer ~= source then return false, 'already_rescuing' end
    if source == targetSource then return false, 'cannot_rescue_yourself' end

    local record = State.Duty(source)
    if not record then return false, 'off_duty' end

    local coords = State.PlayerCoords(source)
    local reach = tonumber(settings().dragDistance) or 2.5
    if not coords or Shared.Distance(coords, down.coords) > reach + 1.5 then return false, 'out_of_range' end

    down.rescuer = source
    down.rescueStartedAt = GetGameTimer()
    return true, nil, tonumber(settings().dragTime) or 6000
end

function Mayday.CompleteRescue(source)
    local down = Mayday.Rescuer(source)
    if not down then return false, 'not_rescuing' end

    local elapsed = GetGameTimer() - (down.rescueStartedAt or 0)
    if elapsed < (tonumber(settings().dragTime) or 6000) * 0.9 then return false, 'too_fast' end

    local coords = State.PlayerCoords(source)
    if not coords then return false, 'no_position' end

    -- Out means away from what put them down. Anywhere the smoke is not.
    Mayday.Clear(down.source, 'rescued', source)
    return true, nil, down
end

function Mayday.CancelRescue(source)
    local down = Mayday.Rescuer(source)
    if not down then return false end
    down.rescuer, down.rescueStartedAt = nil, nil
    return true
end

-- Clearing ----------------------------------------------------------------------

function Mayday.Clear(source, outcome, rescuer)
    local down = active[source]
    if not down then return false end
    active[source] = nil

    State.Broadcast('fire:maydayCleared', source, outcome)

    if outcome == 'rescued' then
        local record = State.Duty(source)
        if record then
            -- Air back in the cylinder: they were carried out to the truck.
            record.air = tonumber((Shared.Settings().scba or {}).capacity) or 0
            State.SyncDuty(source)
        end

        Bridge.Notify(source, 'You were dragged out. Take a minute.', 'success', 8000)
        Fire.Dispatch.Radio(('%s is out and accounted for'):format(down.name), 'success')

        if rescuer then
            local reward = settings().reward or {}
            local pay = math.floor(tonumber(reward.pay) or 0)
            if pay > 0 then
                local funded = Fire.Billing and Fire.Billing.Fund(pay, 'mayday rescue') or pay
                if funded > 0 then
                    Bridge.AddMoney(rescuer, (Shared.Settings().pay or {}).account or 'bank',
                        funded, 'firefighter:mayday')
                end
            end

            local profile = State.Profile(rescuer)
            if profile then
                profile.xp = profile.xp + math.floor(tonumber(reward.xp) or 0)
                profile.stats.maydaysAnswered = (profile.stats.maydaysAnswered or 0) + 1
                State.SaveProfile(profile)
            end
            Bridge.Notify(rescuer, ('You got %s out.'):format(down.name), 'success', 8000)
        end
        return true
    end

    if outcome == 'expired' then
        Bridge.Notify(source, 'Nobody reached you in time.', 'error', 10000)
        Fire.Dispatch.Radio(('%s was not reached in time'):format(down.name), 'error')

        -- The framework owns dying. This puts them on the floor and says so;
        -- what a downed player means is the server's business, not this job's.
        TriggerClientEvent(Bridge.Event('fire:maydayLost'), source)
    end
    return true
end

-- The clock --------------------------------------------------------------------

function Mayday.Tick()
    if not Mayday.Enabled() then return 0 end

    local now = GetGameTimer()
    local running = 0

    for source, down in pairs(active) do
        -- Somebody who clocked off or dropped is no longer down, they are gone.
        if not State.IsOnDuty(source) then
            active[source] = nil
        else
            running = running + 1

            -- A rescuer who wandered off loses the attempt.
            if down.rescuer then
                local coords = State.PlayerCoords(down.rescuer)
                local reach = (tonumber(settings().dragDistance) or 2.5) + 2.0
                if not coords or Shared.Distance(coords, down.coords) > reach then
                    down.rescuer, down.rescueStartedAt = nil, nil
                end
            end

            if now - down.startedAt >= down.window then
                Mayday.Clear(source, 'expired')
            end
        end
    end

    -- Everybody on duty is checked, because the thing that puts you down is
    -- not always on your own call.
    State.EachOnDuty(function(source)
        if not active[source] then Mayday.Check(source) end
    end)

    return running
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    while true do
        Wait(2000)
        if Mayday.Enabled() then
            local ok, err = pcall(Mayday.Tick)
            if not ok then Bridge.Print('mayday tick failed: %s', tostring(err)) end
        end
    end
end)

AddEventHandler('playerDropped', function()
    active[source] = nil
end)
