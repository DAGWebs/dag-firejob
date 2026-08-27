local Bridge = DAG.Framework
local function core() return exports[Bridge.resource or 'qb-core']:GetCoreObject() end
local function player(source) return core().Functions.GetPlayer(source) end

Bridge.RegisterAdapter('qb', {
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
    getItemCount = function(source, item)
        local p = player(source)
        local entry = p and p.Functions.GetItemByName(item)
        return entry and entry.amount or 0
    end,
    addItem = function(source, item, amount, metadata) local p = player(source) return p and p.Functions.AddItem(item, amount, false, metadata) or false end,
    removeItem = function(source, item, amount, metadata)
        local p = player(source)
        return p and p.Functions.RemoveItem(item, amount, false, metadata) or false
    end,
    hasPermission = function(source, permission)
        local ok, allowed = pcall(core().Functions.HasPermission, source, permission)
        return ok and allowed == true
    end,
    setDuty = function(source, onDuty) local p = player(source) return p and p.Functions.SetJobDuty(onDuty) or false end,
    createUseableItem = function(item, callback) core().Functions.CreateUseableItem(item, callback) return true end,
    registerCallback = function(name, callback) core().Functions.CreateCallback(name, callback) end
})
