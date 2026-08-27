local Bridge = DAG.Framework

Bridge.RegisterAdapter('ox', {
    getPlayerData = function()
        local ok, data = pcall(function() return exports.ox_core:GetPlayerData() end)
        return ok and data or nil
    end
})

-- ox_lib is the notification provider on Ox Core; Bridge.Notify already routes
-- through it, so no adapter-level notify is registered here.
RegisterNetEvent('ox:playerLoaded', function(data) TriggerEvent(Bridge.Event('playerLoaded'), data) end)
RegisterNetEvent('ox:playerLogout', function() TriggerEvent(Bridge.Event('playerUnloaded')) end)
RegisterNetEvent('ox:setGroup', function(name, grade)
    TriggerEvent(Bridge.Event('jobUpdated'), { name = name, label = name, grade = grade })
end)
