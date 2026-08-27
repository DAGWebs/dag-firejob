-- Mayday, client side: the blip that drops on a downed firefighter, the prompt
-- to get to them, and the drag itself.
--
-- The server decides who is down and whether they were reached in time. This
-- draws it and asks.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Mayday = {}
Fire.Mayday = Mayday

local down, blips, rescue = {}, {}, nil

local function settings()
    return Shared.Settings().mayday or {}
end

function Mayday.Down()
    return down
end

function Mayday.Rescue()
    return rescue
end

function Mayday.IsDown()
    local me = GetPlayerServerId(PlayerId())
    return down[me] ~= nil
end

local function dropBlip(source, entry)
    if blips[source] then return blips[source] end

    local blip = AddBlipForCoord(entry.coords.x, entry.coords.y, entry.coords.z)
    SetBlipSprite(blip, 303)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 1.2)
    SetBlipFlashes(blip, true)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('MAYDAY - %s'):format(entry.name or 'firefighter'))
    EndTextCommandSetBlipName(blip)

    blips[source] = blip
    return blip
end

local function clearBlip(source)
    if not blips[source] then return end
    RemoveBlip(blips[source])
    blips[source] = nil
end

-- What is left on the clock for whoever is down, or nil when nobody is.
function Mayday.Remaining(source)
    local entry = down[source]
    if not entry then return nil end
    return math.max(0, entry.until_ - GetGameTimer())
end

function Mayday.Nearest(coords)
    local nearest, nearestSource, nearestDistance
    for source, entry in pairs(down) do
        local distance = Shared.Distance(coords, entry.coords)
        if not nearestDistance or distance < nearestDistance then
            nearest, nearestSource, nearestDistance = entry, source, distance
        end
    end
    return nearest, nearestSource, nearestDistance
end

function Mayday.Call()
    TriggerServerEvent(Bridge.Event('fire:mayday'))
end

-- Getting to them ---------------------------------------------------------------

-- The prompt only appears for somebody who can actually do something about it:
-- on duty, close enough, and not the one on the floor.
function Mayday.Step()
    if not Client.OnDuty() or Mayday.IsDown() then return nil end

    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    if not here then return nil end

    if rescue then
        local elapsed = GetGameTimer() - rescue.startedAt
        if Shared.Distance(here, rescue.coords) > (tonumber(settings().dragDistance) or 2.5) + 2.0 then
            rescue = nil
            TriggerServerEvent(Bridge.Event('fire:cancelRescue'))
            Bridge.Notify('You lost them.', 'error')
            return 'lost'
        end

        if elapsed >= rescue.duration then
            rescue = nil
            ClearPedTasks(PlayerPedId())
            TriggerServerEvent(Bridge.Event('fire:completeRescue'))
            return 'complete'
        end
        return 'dragging'
    end

    local entry, source, distance = Mayday.Nearest(here)
    if not entry or distance > (tonumber(settings().dragDistance) or 2.5) then return nil end

    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(('Press ~INPUT_CONTEXT~ to drag ~r~%s~s~ out'):format(entry.name or 'them'))
    EndTextCommandDisplayHelp(0, false, true, -1)

    if IsControlJustReleased(0, Config.InteractionKey) then
        TriggerServerEvent(Bridge.Event('fire:beginRescue'), source)
    end
    return 'prompt'
end

function Mayday.Progress()
    if not rescue then return nil end
    return Shared.Clamp((GetGameTimer() - rescue.startedAt) / math.max(1, rescue.duration), 0, 1)
end

-- Events -----------------------------------------------------------------------

RegisterNetEvent(Bridge.Event('fire:mayday'), function(payload)
    if not payload or not payload.source then return end

    down[payload.source] = {
        name = payload.name,
        reason = payload.reason,
        coords = Shared.Coords(payload.coords),
        callId = payload.callId,
        until_ = GetGameTimer() + (tonumber(payload.window) or 120000)
    }
    dropBlip(payload.source, down[payload.source])

    Bridge.Notify(('MAYDAY: %s is down, %s.'):format(payload.name or 'a firefighter',
        payload.reason or 'unknown'), 'error', 12000)

    if Fire.Effects then
        Fire.Effects.Play(((Shared.Settings().effects or {}).sound or {}).mayday)
    end

    -- A mayday is the one thing worth routing to, so it takes the waypoint.
    local entry = down[payload.source]
    if entry.coords and GetPlayerServerId(PlayerId()) ~= payload.source then
        SetNewWaypoint(entry.coords.x, entry.coords.y)
    end
end)

RegisterNetEvent(Bridge.Event('fire:maydayCleared'), function(source, outcome)
    down[source] = nil
    clearBlip(source)
    if rescue and rescue.source == source then rescue = nil end
    if outcome == 'rescued' then Bridge.Notify('Mayday resolved.', 'success', 6000) end
end)

RegisterNetEvent(Bridge.Event('fire:rescueStarted'), function(target, duration)
    local entry = down[target]
    if not entry then return end

    rescue = {
        source = target,
        coords = entry.coords,
        startedAt = GetGameTimer(),
        duration = tonumber(duration) or 6000
    }

    if HasAnimDictLoaded('missfinale_c2mcs_1') then
        TaskPlayAnim(PlayerPedId(), 'missfinale_c2mcs_1', 'fin_c2_mcs_1_camman',
            8.0, -8.0, -1, 49, 0.0, false, false, false)
    else
        RequestAnimDict('missfinale_c2mcs_1')
    end
end)

-- Being the one on the floor: held down, and told how long is left.
RegisterNetEvent(Bridge.Event('fire:maydayLost'), function()
    Bridge.Notify('You did not make it out.', 'error', 12000)
    local ped = PlayerPedId()
    SetEntityHealth(ped, 1)
end)

AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    if reason ~= 'duty' or Client.OnDuty() then return end
    for source in pairs(blips) do clearBlip(source) end
    down, rescue = {}, nil
end)

CreateThread(function()
    while true do
        local state = Mayday.Step()
        Wait(state and 0 or 500)
    end
end)

-- Somebody on the floor cannot walk it off.
CreateThread(function()
    while true do
        local sleep = 750
        if Mayday.IsDown() then
            sleep = 0
            DisableControlAction(0, 21, true)
            DisableControlAction(0, 22, true)
            DisableControlAction(0, 24, true)
            SetPedToRagdoll(PlayerPedId(), 2000, 2000, 0, false, false, false)
        end
        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    for source in pairs(blips) do clearBlip(source) end
end)
