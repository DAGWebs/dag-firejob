local function player(source) return exports.qbx_core:GetPlayer(source) end

-- Qbox requires ox_inventory, so the framework-native inventory IS
-- ox_inventory here; Config.Inventory = 'framework' is a no-op on this core.
DAG.Framework.RegisterAdapter('qbox', {
    getPlayer = player,
    getIdentifier = function(source) local p = player(source) return p and p.PlayerData.citizenid end,
    getName = function(source)
        local p = player(source) local info = p and p.PlayerData.charinfo
        return info and (('%s %s'):format(info.firstname or '', info.lastname or '')) or GetPlayerName(source)
    end,
    getJob = function(source) local p = player(source) return p and p.PlayerData.job end,
    getMoney = function(source, account)
        local p = player(source)
        return p and p.Functions.GetMoney(account) or nil
    end,
    addMoney = function(source, account, amount, reason)
        local p = player(source)
        return p ~= nil and p.Functions.AddMoney(account, amount, reason) == true
    end,
    removeMoney = function(source, account, amount, reason)
        local p = player(source)
        return p ~= nil and p.Functions.RemoveMoney(account, amount, reason) == true
    end,
    getItemCount = function(source, item, metadata) return exports.ox_inventory:Search(source, 'count', item, metadata) or 0 end,
    addItem = function(source, item, amount, metadata) return exports.ox_inventory:AddItem(source, item, amount, metadata) == true end,
    removeItem = function(source, item, amount, metadata) return exports.ox_inventory:RemoveItem(source, item, amount, metadata) == true end,
    setDuty = function(source, onDuty) exports.qbx_core:SetJobDuty(source, onDuty) return true end,
    setJob = function(source, job, grade) return exports.qbx_core:SetJob(source, job, grade) ~= false end,
    createUseableItem = function(item, callback) exports.qbx_core:CreateUseableItem(item, callback) return true end
})
