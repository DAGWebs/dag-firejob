-- The crew, client side: answering an accountability check, and telling the
-- server when you have gone inside.
--
-- Neither of these decides anything. The server keeps the roster, the roles
-- and the answers; this reports what the client can see and draws the clock.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Crew = {}
Fire.Crew = Crew

local par, interior = nil, false

function Crew.Par()
    return par
end

function Crew.Interior()
    return interior
end

-- Interior is "in the smoke", which is the only definition that matters: it is
-- what makes not answering a PAR check serious, and what a mayday is about.
function Crew.InteriorStep()
    if not Client.OnDuty() or not Fire.Effects then return false end

    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    local inside = here ~= nil and Fire.Effects.SmokeAt(here) > 0.2

    if inside ~= interior then
        interior = inside
        TriggerServerEvent(Bridge.Event('fire:interior'), inside)
    end
    return interior
end

function Crew.Answer()
    if not par then return false end
    par.answered = true
    TriggerServerEvent(Bridge.Event('fire:parAnswer'))
    return true
end

function Crew.Assign(roleId, targetIdentifier)
    TriggerServerEvent(Bridge.Event('fire:assignRole'), roleId, targetIdentifier)
end

function Crew.CallPar()
    TriggerServerEvent(Bridge.Event('fire:par'))
end

-- What is left on the clock, or nil when there is nothing to answer.
function Crew.ParRemaining()
    if not par or par.answered then return nil end

    local left = par.until_ - GetGameTimer()
    if left <= 0 then
        par = nil
        return nil
    end
    return left
end

RegisterNetEvent(Bridge.Event('fire:par'), function(callId, window)
    if not Client.OnDuty() then return end

    par = {
        callId = callId,
        until_ = GetGameTimer() + (tonumber(window) or 30000),
        answered = false
    }

    Bridge.Notify('PAR check: answer now.', 'error', 8000)
    if Fire.Effects then Fire.Effects.Play((Shared.Settings().effects or {}).sound and
        (Shared.Settings().effects.sound or {}).mayday or nil) end
end)

AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    -- Clearing the call clears whatever it was asking of you.
    if reason == 'duty' and not Client.OnDuty() then par, interior = nil, false end
end)

CreateThread(function()
    while true do
        Crew.InteriorStep()
        Wait(1500)
    end
end)

-- Answering is a keypress rather than a menu, because a PAR check is called
-- when there is no time for a menu.
CreateThread(function()
    while true do
        local sleep = 500
        local remaining = Crew.ParRemaining()

        if remaining then
            sleep = 0
            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(
                ('~r~PAR CHECK~s~  press ~INPUT_CONTEXT~ to answer  (%ds)'):format(math.ceil(remaining / 1000)))
            EndTextCommandDisplayHelp(0, false, true, -1)

            if IsControlJustReleased(0, Config.InteractionKey) then Crew.Answer() end
        end

        Wait(sleep)
    end
end)
