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

local peds, wrecks, interactions, posed = {}, {}, {}, {}
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
    posed[entryKey] = nil
    if not entity then return end
    if DoesEntityExist(entity) then DeleteEntity(entity) end
    peds[entryKey] = nil
end

-- Wrecks are local scenery, like the patients in them: every responder builds
-- their own copy from the same server record rather than fighting over one
-- networked entity.
local function spawnWreck(callId, wreck)
    local entryKey = key(callId, wreck.id)
    if wrecks[entryKey] then return wrecks[entryKey] end

    local model = GetHashKey(wreck.model or 'sultan')
    if not HasModelLoaded(model) then
        RequestModel(model)
        return nil
    end

    local coords = wreck.coords
    local vehicle = CreateVehicle(model, coords.x, coords.y, coords.z, wreck.heading or 0.0, false, false)
    if not vehicle or vehicle == 0 then return nil end

    SetVehicleOnGroundProperly(vehicle)
    FreezeEntityPosition(vehicle, true)
    SetVehicleEngineHealth(vehicle, 0.0)
    SetVehicleBodyHealth(vehicle, 150.0)
    SetVehicleDeformationFixed(vehicle)
    for window = 0, 3 do SmashVehicleWindow(vehicle, window) end

    wrecks[entryKey] = vehicle
    return vehicle
end

-- The visible result of each extrication stage. Cutting a door off is worth
-- seeing, and it is how a crew knows where the work got to.
local function markStage(callId, victim)
    local vehicle = victim.wreck and wrecks[key(callId, victim.wreck)]
    if not vehicle or not DoesEntityExist(vehicle) then return false end

    local stage = tonumber(victim.stage) or 99
    if stage > 3 then SetVehicleDoorBroken(vehicle, 0, true) end
    if stage > 4 then
        SetVehicleDoorBroken(vehicle, 1, true)
        SetVehicleDoorBroken(vehicle, 4, true)
    end
    return true
end

-- Laying the patient down is a separate step from creating them: the anim
-- dictionary is loaded asynchronously and is almost never ready on the frame
-- the ped appears, so the pose is applied on a later pass instead of being
-- silently skipped.
local function pose(entryKey, entity)
    if posed[entryKey] or carrying == entryKey then return false end
    if not requestAnim(DOWN_DICT) then return false end

    TaskPlayAnim(entity, DOWN_DICT, DOWN_ANIM, 8.0, 0.0, -1, 1, 0.0, false, false, false)
    posed[entryKey] = true
    return true
end

local function spawnVictim(callId, victim)
    local entryKey = key(callId, victim.id)
    if peds[entryKey] then
        pose(entryKey, peds[entryKey])
        return peds[entryKey]
    end

    -- RequestModel is asynchronous. Returning nil here is not a failure: the
    -- reconcile pass below comes back for it once the model has streamed in.
    local model = GetHashKey(victim.model or 'a_m_y_business_01')
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

    peds[entryKey] = entity
    pose(entryKey, entity)
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

local TRIAGE = {
    immediate = '~r~IMMEDIATE~s~',
    delayed = '~y~DELAYED~s~',
    minor = '~g~MINOR~s~',
    expectant = '~c~EXPECTANT~s~'
}

local function triageTag(victim)
    local tag = victim.triage and TRIAGE[victim.triage]
    return tag and (tag .. ' ') or ''
end

local function victimInteraction(call, victim)
    local id = ('%s:victim:%s'):format(Bridge.namespace, key(call.id, victim.id))

    if victim.state == Fire.VictimState.trapped then
        -- A staged extrication names the step the crew is on, so the prompt is
        -- "force the door", not "extricate" five times over.
        local stages = (Shared.Settings().extrication or {}).stages or {}
        local stage = victim.stage and stages[victim.stage]
        return registerInteraction(id, {
            coords = victim.coords,
            label = ('%sPress ~INPUT_CONTEXT~ to %s'):format(triageTag(victim),
                stage and stage.label:lower() or 'extricate the patient'),
            distance = 2.5,
            onSelect = function() beginAction(call.id, 'free', victim.id) end
        })
    end

    if victim.state == Fire.VictimState.freed then
        return registerInteraction(id, {
            coords = victim.coords,
            label = ('%sPress ~INPUT_CONTEXT~ to treat the patient'):format(triageTag(victim)),
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
    local wanted, wantedWrecks = {}, {}

    for callId, call in pairs(Client.Calls()) do
        for _, wreck in pairs(call.wrecks or {}) do
            wantedWrecks[key(callId, wreck.id)] = true
            spawnWreck(callId, wreck)
        end

        for _, victim in pairs(call.victims or {}) do
            local entryKey = key(callId, victim.id)
            local visible = victim.state ~= Fire.VictimState.transported
            if visible then
                wanted[entryKey] = true
                spawnVictim(callId, victim)
            end
            victimInteraction(call, victim)
            markStage(callId, victim)
        end

        for _, hazard in pairs(call.hazards or {}) do
            hazardInteraction(call, hazard)
        end
    end

    for entryKey in pairs(peds) do
        if not wanted[entryKey] and carrying ~= entryKey then removePed(entryKey) end
    end
    for entryKey, vehicle in pairs(wrecks) do
        if not wantedWrecks[entryKey] then
            if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
            wrecks[entryKey] = nil
        end
    end

    -- Anything still missing is waiting on a model or an anim dictionary.
    local pending = 0
    for entryKey in pairs(wanted) do
        if not peds[entryKey] or not posed[entryKey] then pending = pending + 1 end
    end
    for entryKey in pairs(wantedWrecks) do
        if not wrecks[entryKey] then pending = pending + 1 end
    end
    return pending
end

function Rescue.Clear()
    for entryKey in pairs(peds) do removePed(entryKey) end
    posed = {}
    for entryKey, vehicle in pairs(wrecks) do
        if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
        wrecks[entryKey] = nil
    end
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
RegisterNetEvent(Bridge.Event('fire:actionStarted'), function(kind, targetId, duration, label, fastest)
    action = {
        kind = kind,
        targetId = targetId,
        label = label,
        duration = duration,
        -- The floor the server set. Working the job well walks the finish line
        -- down towards it; ignoring the skill check just takes the full time.
        fastest = tonumber(fastest) or duration,
        startedAt = GetGameTimer(),
        origin = Shared.Coords(GetEntityCoords(PlayerPedId()))
    }

    if Fire.Skill and Fire.Skill.Enabled() then Fire.Skill.Begin(duration) end

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
        if Fire.Skill then Fire.Skill.Cancel() end
        ClearPedTasks(PlayerPedId())
        TriggerServerEvent(Bridge.Event('fire:cancelAction'))
        Bridge.Notify('You moved away before the job was done.', 'error')
        return 'cancelled'
    end

    -- How well the check is going decides where between the floor and the full
    -- time this finishes.
    local score = Fire.Skill and Fire.Skill.Enabled() and Fire.Skill.Score() or 0
    local target = action.duration - (action.duration - action.fastest) * score
    if GetGameTimer() - action.startedAt < target then return 'working' end

    action = nil
    if Fire.Skill then Fire.Skill.Finish() end
    ClearPedTasks(PlayerPedId())
    TriggerServerEvent(Bridge.Event('fire:completeAction'))
    return 'complete'
end

function Rescue.ActionProgress()
    if not action then return nil end

    local score = Fire.Skill and Fire.Skill.Enabled() and Fire.Skill.Score() or 0
    local target = action.duration - (action.duration - action.fastest) * score
    return Shared.Clamp((GetGameTimer() - action.startedAt) / math.max(1, target), 0, 1),
        action.label or action.kind
end

-- Threads -------------------------------------------------------------------

CreateThread(function()
    while true do
        Rescue.ActionStep()
        Wait(action and 100 or 500)
    end
end)

-- Scene props are rebuilt from the server's record on every update, but models
-- stream in asynchronously, so a scene that could not be built on the event
-- itself is retried here rather than staying empty until the next one.
CreateThread(function()
    while true do
        local pending = 0
        if Client.OnDuty() then pending = Rescue.Refresh() or 0 end
        Wait(pending > 0 and 500 or 3000)
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
