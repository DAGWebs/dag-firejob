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
