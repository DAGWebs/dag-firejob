DAG.Framework.RegisterAdapter('qbox', {
    getPlayerData = function() return exports.qbx_core:GetPlayerData() end,
    notify = function(message, kind, duration) exports.qbx_core:Notify(message, kind, duration) end
})

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() TriggerEvent(DAG.Framework.Event('playerLoaded'), DAG.Framework.GetPlayerData()) end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function() TriggerEvent(DAG.Framework.Event('playerUnloaded')) end)
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job) TriggerEvent(DAG.Framework.Event('jobUpdated'), job) end)
