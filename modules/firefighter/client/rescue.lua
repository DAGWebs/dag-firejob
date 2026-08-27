-- Patients and hazardous materials.
--
-- Victims and spills are server-owned records; the peds and prompts here are
-- local scenery built from them. Nothing a firefighter does to one takes
-- effect until the server has agreed it took long enough and happened close
-- enough, so a desynced ped is cosmetic rather than exploitable.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Rescue = {}
Fire.Rescue = Rescue

local peds, interactions = {}, {}
local carrying, action = nil, nil

local CARRY_DICT = 'missfinale_c2mcs_1'
local CARRY_ANIM = 'fin_c2_mcs_1_camman'
local DOWN_DICT = 'dead'
local DOWN_ANIM = 'dead_a'

local function victimSettings()
    return Shared.Settings().victims or {}
end

local function key(callId, id)
    return ('%s/%s'):format(callId, id)
end

local function requestAnim(dictionary)
    if HasAnimDictLoaded(dictionary) then return true end
    RequestAnimDict(dictionary)
    return false
end

-- Peds ---------------------------------------------------------------------

local function removePed(entryKey)
    local entity = peds[entryKey]
    if not entity then return end
    if DoesEntityExist(entity) then DeleteEntity(entity) end
    peds[entryKey] = nil
end

local function spawnVictim(callId, victim)
    local entryKey = key(callId, victim.id)
    if peds[entryKey] then return peds[entryKey] end

    local model = GetHashKey(victimSettings().model or 'a_m_y_business_01')
    if not HasModelLoaded(model) then
        RequestModel(model)
        return nil
    end

    local coords = victim.coords
    local entity = CreatePed(4, model, coords.x, coords.y, coords.z - 0.9, victim.heading or 0.0, false, false)
    if not entity or entity == 0 then return nil end

    SetEntityInvincible(entity, true)
    SetBlockingOfNonTemporaryEvents(entity, true)
    FreezeEntityPosition(entity, true)
    if requestAnim(DOWN_DICT) then
        TaskPlayAnim(entity, DOWN_DICT, DOWN_ANIM, 8.0, 0.0, -1, 1, 0.0, false, false, false)
    end

    peds[entryKey] = entity
    return entity
end

-- Interactions --------------------------------------------------------------

local function clearInteraction(id)
    if not interactions[id] then return end
    DAG.Interactions.Remove(id)
    interactions[id] = nil
end

local function registerInteraction(id, entry)
    interactions[id] = true
    entry.id = id
    DAG.Interactions.Register(entry)
end

local function beginAction(callId, kind, targetId)
    TriggerServerEvent(Bridge.Event('fire:beginAction'), callId, kind, targetId)
end

local function victimInteraction(call, victim)
    local id = ('%s:victim:%s'):format(Bridge.namespace, key(call.id, victim.id))

    if victim.state == Fire.VictimState.trapped then
        return registerInteraction(id, {
            coords = victim.coords,
            label = 'Press ~INPUT_CONTEXT~ to extricate the patient',
            distance = 2.5,
            onSelect = function() beginAction(call.id, 'free', victim.id) end
        })
    end

    if victim.state == Fire.VictimState.freed then
        return registerInteraction(id, {
            coords = victim.coords,
            label = 'Press ~INPUT_CONTEXT~ to treat the patient',
            distance = 2.5,
            onSelect = function() beginAction(call.id, 'treat', victim.id) end
        })
    end

    if victim.state == Fire.VictimState.treated then
        return registerInteraction(id, {
            coords = victim.coords,
            label = 'Press ~INPUT_CONTEXT~ to carry the patient',
            distance = 2.5,
            canInteract = function() return carrying == nil end,
            onSelect = function() Rescue.Carry(call.id, victim.id) end
        })
    end

    clearInteraction(id)
end

local function hazardInteraction(call, hazard)
    local id = ('%s:hazard:%s'):format(Bridge.namespace, key(call.id, hazard.id))
    if hazard.contained then return clearInteraction(id) end

    registerInteraction(id, {
        coords = hazard.coords,
        label = 'Press ~INPUT_CONTEXT~ to contain the release',
        distance = 2.5,
        marker = 23,
        onSelect = function() beginAction(call.id, 'contain', hazard.id) end
    })
end

-- Rebuilds the local scene for every call this client can see. Called from the
-- sync handler rather than on a timer, so it only runs when something changed.
function Rescue.Refresh()
    local wanted = {}

    for callId, call in pairs(Client.Calls()) do
        for _, victim in pairs(call.victims or {}) do
            local entryKey = key(callId, victim.id)
            local visible = victim.state ~= Fire.VictimState.transported
            if visible then
                wanted[entryKey] = true
                spawnVictim(callId, victim)
            end
            victimInteraction(call, victim)
        end

        for _, hazard in pairs(call.hazards or {}) do
            hazardInteraction(call, hazard)
        end
    end

    for entryKey in pairs(peds) do
        if not wanted[entryKey] and carrying ~= entryKey then removePed(entryKey) end
    end
end

function Rescue.Clear()
    for entryKey in pairs(peds) do removePed(entryKey) end
    for id in pairs(interactions) do clearInteraction(id) end
    carrying = nil
end

-- Carrying ------------------------------------------------------------------

function Rescue.Carry(callId, victimId)
    local entryKey = key(callId, victimId)
    local entity = peds[entryKey]
    if carrying or not entity then return false end

    local player = PlayerPedId()
    FreezeEntityPosition(entity, false)
    AttachEntityToEntity(entity, player, GetPedBoneIndex(player, 24818),
        0.27, 0.15, -0.05, 0.5, 0.5, 0.0, false, false, false, false, 2, true)

    if requestAnim(CARRY_DICT) then
        TaskPlayAnim(player, CARRY_DICT, CARRY_ANIM, 8.0, -8.0, -1, 49, 0.0, false, false, false)
        TaskPlayAnim(entity, CARRY_DICT, CARRY_ANIM, 8.0, -8.0, -1, 49, 0.0, false, false, false)
    end

    carrying = entryKey
    Rescue.carriedCall, Rescue.carriedVictim = callId, victimId
    Bridge.Notify('Carrying the patient. Take them to the hospital.', 'inform')
    return true
end

function Rescue.Drop()
    if not carrying then return false end

    local entity = peds[carrying]
    if entity and DoesEntityExist(entity) then
        DetachEntity(entity, true, true)
        FreezeEntityPosition(entity, true)
    end
    ClearPedTasks(PlayerPedId())

    carrying = nil
    Rescue.carriedCall, Rescue.carriedVictim = nil, nil
    return true
end

function Rescue.HandOver()
    if not carrying then return false end

    local callId, victimId = Rescue.carriedCall, Rescue.carriedVictim
    Rescue.Drop()
    removePed(key(callId, victimId))
    TriggerServerEvent(Bridge.Event('fire:transport'), callId, victimId)
    return true
end

-- Timed actions -------------------------------------------------------------

function Rescue.Action()
    return action
end

-- The server has accepted the start and told us how long it takes. The client
-- runs the clock only to draw the bar; the completion is checked again server
-- side before it counts.
RegisterNetEvent(Bridge.Event('fire:actionStarted'), function(kind, targetId, duration)
    action = {
        kind = kind,
        targetId = targetId,
        duration = duration,
        startedAt = GetGameTimer(),
        origin = Shared.Coords(GetEntityCoords(PlayerPedId()))
    }

    if requestAnim('amb@medic@standing@kneel@base') then
        TaskPlayAnim(PlayerPedId(), 'amb@medic@standing@kneel@base', 'base', 8.0, -8.0, -1, 1, 0.0, false, false, false)
    end
end)

-- One step of the in-progress action. Returns 'working', 'cancelled', or
-- 'complete' so the caller (and a test) can see which branch it took.
function Rescue.ActionStep()
    if not action then return nil end

    local coords = Shared.Coords(GetEntityCoords(PlayerPedId()))
    if not coords or Shared.Distance(coords, action.origin) > 3.0 then
        action = nil
        ClearPedTasks(PlayerPedId())
        TriggerServerEvent(Bridge.Event('fire:cancelAction'))
        Bridge.Notify('You moved away before the job was done.', 'error')
        return 'cancelled'
    end

    if GetGameTimer() - action.startedAt < action.duration then return 'working' end

    action = nil
    ClearPedTasks(PlayerPedId())
    TriggerServerEvent(Bridge.Event('fire:completeAction'))
    return 'complete'
end

function Rescue.ActionProgress()
    if not action then return nil end
    return Shared.Clamp((GetGameTimer() - action.startedAt) / action.duration, 0, 1), action.kind
end

-- Threads -------------------------------------------------------------------

CreateThread(function()
    while true do
        Rescue.ActionStep()
        Wait(action and 100 or 500)
    end
end)

-- The hospital handover point is a fixed interaction, registered once, and
-- only offered while actually carrying somebody.
CreateThread(function()
    local hospital = Shared.Coords(victimSettings().hospital)
    if not hospital then return end

    DAG.Interactions.Register({
        id = ('%s:hospital'):format(Bridge.namespace),
        coords = hospital,
        label = 'Press ~INPUT_CONTEXT~ to hand the patient over',
        distance = 4.0,
        canInteract = function() return carrying ~= nil end,
        onSelect = function() Rescue.HandOver() end
    })
end)

AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    if reason == 'duty' and not Client.OnDuty() then return Rescue.Clear() end
    if reason == 'call' or reason == 'victim' or reason == 'hazard' or reason == 'removed' then
        Rescue.Refresh()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    Rescue.Clear()
end)
