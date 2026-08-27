local Bridge = DAG.Framework

-- Standalone has no framework client object; the server adapter replicates
-- player state into the `dagPlayer` state bag, which is what this reads.
Bridge.RegisterAdapter('standalone', {
    getPlayerData = function() return LocalPlayer.state.dagPlayer or {} end
})

AddStateBagChangeHandler('dagPlayer', nil, function(bagName, _, value)
    if bagName ~= ('player:%s'):format(GetPlayerServerId(PlayerId())) then return end
    TriggerEvent(Bridge.Event('playerLoaded'), value)
    if value and value.job then TriggerEvent(Bridge.Event('jobUpdated'), value.job) end
end)
