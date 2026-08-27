std = 'lua54'
max_line_length = 160

-- Files are concatenated into one Lua state by the FiveM runtime, so the
-- template's own globals are shared on purpose.
globals = {
    'DAG',
    'Config',
    'exports',
}

read_globals = {
    -- CFX runtime
    'AddEventHandler', 'AddStateBagChangeHandler', 'CreateThread', 'Citizen',
    'GetCurrentResourceName', 'GetGameTimer', 'GetResourceState', 'LoadResourceFile',
    'RegisterCommand', 'RegisterNetEvent', 'RemoveStateBagChangeHandler',
    'SaveResourceFile', 'SetTimeout', 'TriggerClientEvent', 'TriggerEvent',
    'TriggerServerEvent', 'Wait', 'json', 'msgpack', 'promise', 'source',
    -- server
    'GetPlayerIdentifierByType', 'GetPlayerIdentifiers', 'GetPlayerName',
    'GetPlayers', 'IsPlayerAceAllowed', 'Player', 'DropPlayer',
    -- client
    'AddTextComponentSubstringPlayerName', 'BeginTextCommandDisplayHelp',
    'DrawMarker', 'EndTextCommandDisplayHelp', 'GetEntityCoords',
    'RegisterNUICallback', 'SendNUIMessage', 'SetNuiFocus',
    'GetPlayerServerId', 'IsControlJustReleased', 'LocalPlayer', 'PlayerId',
    'PlayerPedId', 'vector3',
    -- server-side entity access, used by the firefighter job to check where a
    -- player and their apparatus really are before trusting a request
    'GetPlayerPed', 'NetworkGetEntityFromNetworkId', 'DoesEntityExist',
    'GetEntityModel', 'DeleteEntity', 'GetHashKey', 'GetEntityHeading',
    -- client natives used by the firefighter job
    'AddBlipForCoord', 'AttachEntityToEntity', 'BeginTextCommandDisplayText',
    'BeginTextCommandSetBlipName', 'ClearPedTasks', 'CreatePed', 'CreateVehicle',
    'DetachEntity', 'DrawRect', 'EndTextCommandDisplayText',
    'EndTextCommandSetBlipName', 'FreezeEntityPosition', 'GetClosestObjectOfType',
    'GetEntityForwardVector', 'GetEntityHealth', 'GetPedBoneIndex',
    'GiveWeaponToPed', 'HasAnimDictLoaded', 'HasModelLoaded',
    'HasNamedPtfxAssetLoaded', 'IsPedShooting', 'NetworkGetNetworkIdFromEntity',
    'RegisterKeyMapping', 'RemoveBlip', 'RemoveScriptFire', 'RemoveWeaponFromPed',
    'RequestAnimDict', 'RequestModel', 'RequestNamedPtfxAsset',
    'SetBlipAsShortRange', 'SetBlipColour', 'SetBlipFlashes', 'SetBlipRoute',
    'SetBlipScale', 'SetBlipSprite', 'SetBlockingOfNonTemporaryEvents',
    'SetCurrentPedWeapon', 'SetEntityAsMissionEntity', 'SetEntityHealth',
    'SetEntityInvincible', 'SetModelAsNoLongerNeeded', 'SetNewWaypoint',
    'SetTextColour', 'SetTextFont', 'SetTextOutline', 'SetTextScale',
    'SetVehicleEngineOn', 'SetVehicleNumberPlateText', 'SetVehicleOnGroundProperly',
    'StartParticleFxNonLoopedAtCoord', 'StartScriptFire', 'TaskPlayAnim',
    'TaskWarpPedIntoVehicle', 'UseParticleFxAssetNextCall',
    -- hose lines, uniforms, wrecks, and the player-incident detectors
    'ClearPedProp', 'CreateObject', 'GetEntitySpeed', 'GetPedDrawableVariation',
    'GetPedPropIndex', 'GetPedPropTextureIndex', 'GetPedTextureVariation',
    'GetVehicleEngineHealth', 'GetVehiclePedIsIn', 'HasEntityCollidedWithAnything',
    'IsEntityOnFire', 'IsPedDeadOrDying', 'IsPedInAnyVehicle', 'IsPedMale',
    'NetworkDoesNetworkIdExist',
    'PlaceObjectOnGroundProperly', 'SetEntityCollision', 'SetPedComponentVariation',
    'SetPedPropIndex', 'SetSeethrough', 'SetVehicleBodyHealth',
    'SetVehicleDeformationFixed', 'SetVehicleDoorBroken', 'SetVehicleEngineHealth',
    'SmashVehicleWindow',
    -- the sensory layer: particles, timecycles, sound
    'ClearTimecycleModifier', 'SetTimecycleModifier', 'SetTimecycleModifierStrength',
    'PlaySoundFrontend', 'PlaySoundFromCoord', 'GetPedBoneCoords',
    'StartParticleFxLoopedAtCoord', 'StopParticleFxLooped',
    'DisableControlAction', 'SetPedToRagdoll',
}

exclude_files = { 'tests/lua/vendor/**' }

files['fxmanifest.lua'] = {
    globals = {
        'author', 'client_script', 'client_scripts', 'dependencies', 'dependency',
        'description', 'files', 'fx_version', 'game', 'lua54', 'provide',
        'server_script', 'server_scripts', 'shared_script', 'shared_scripts',
        'ui_page', 'version',
    },
}

files['tests/lua/**'] = {
    globals = { 'harness' },
    read_globals = {
        'test',
        'assertDeepEq', 'assertEq', 'assertFalse', 'assertNil', 'assertThrows', 'assertTrue',
    },
}
