local Bridge = DAG.Framework

local function core()
    return exports[Bridge.resource or 'qb-core']:GetCoreObject()
end

Bridge.RegisterAdapter('qb', {
    getPlayerData = function() return core().Functions.GetPlayerData() end,
    notify = function(message, kind, duration)
        core().Functions.Notify(message, kind == 'inform' and 'primary' or kind, duration)
    end,
    triggerCallback = function(name, callback, ...) core().Functions.TriggerCallback(name, callback, ...) end
})

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() TriggerEvent(Bridge.Event('playerLoaded'), Bridge.GetPlayerData()) end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function() TriggerEvent(Bridge.Event('playerUnloaded')) end)
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job) TriggerEvent(Bridge.Event('jobUpdated'), job) end)
