local function core() return exports.es_extended:getSharedObject() end

DAG.Framework.RegisterAdapter('esx', {
    getPlayerData = function() return core().GetPlayerData() end,
    notify = function(message) core().ShowNotification(message) end,
    triggerCallback = function(name, callback, ...) core().TriggerServerCallback(name, callback, ...) end
})

RegisterNetEvent('esx:playerLoaded', function(data) TriggerEvent(DAG.Framework.Event('playerLoaded'), data) end)
RegisterNetEvent('esx:onPlayerLogout', function() TriggerEvent(DAG.Framework.Event('playerUnloaded')) end)
RegisterNetEvent('esx:setJob', function(job) TriggerEvent(DAG.Framework.Event('jobUpdated'), job) end)
