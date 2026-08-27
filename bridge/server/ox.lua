local Bridge = DAG.Framework

-- Ox Core's player API moves between releases, so each probe is guarded and
-- an unavailable one degrades to "unsupported" rather than a wrong answer.
local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function player(source)
    return safe(function() return exports.ox_core:GetPlayer(source) end)
end

-- Ox Core models jobs as groups (`{ police = 3 }`). The active group is
-- preferred when the build exposes one; otherwise the highest-grade group is
-- used so grade comparisons stay meaningful.
local function activeGroup(p)
    local active = safe(function() return p.get('activeGroup') end)
    local groups = safe(function() return p.getGroups() end)
    if type(groups) ~= 'table' then return nil end

    if type(active) == 'string' and groups[active] then
        return active, groups[active]
    end

    local bestName, bestGrade
    for name, grade in pairs(groups) do
        grade = tonumber(grade) or 0
        if not bestGrade or grade > bestGrade then bestName, bestGrade = name, grade end
    end
    return bestName, bestGrade
end

local function moneyItem()
    return (Config.Ox and Config.Ox.moneyItem) or 'money'
end

Bridge.RegisterAdapter('ox', {
    getPlayer = player,
    getIdentifier = function(source)
        local p = player(source)
        if not p then return nil end
        return p.charId and tostring(p.charId) or p.stateId or p.identifier
    end,
    getName = function(source)
        local p = player(source)
        if not p then return nil end
        local first, last = safe(function() return p.get('firstName') end), safe(function() return p.get('lastName') end)
        if first or last then return ('%s %s'):format(first or '', last or ''):gsub('^%s+', '') end
        return p.name
    end,
    getJob = function(source)
        local p = player(source)
        if not p then return nil end
        local name, grade = activeGroup(p)
        if not name then return nil end
        return { name = name, label = name, grade = grade or 0, onduty = true }
    end,
    -- Cash lives in ox_inventory as an item. Other accounts are Ox Core's
    -- account system, which this template does not assume; returning nil makes
    -- Bridge.GetMoney report "unknown" instead of a false zero.
    getMoney = function(source, account)
        if account ~= 'cash' and account ~= 'money' then return nil end
        return safe(function() return exports.ox_inventory:Search(source, 'count', moneyItem()) end) or 0
    end,
    addMoney = function(source, account, amount)
        if account ~= 'cash' and account ~= 'money' then return false end
        return safe(function() return exports.ox_inventory:AddItem(source, moneyItem(), amount) end) == true
    end,
    removeMoney = function(source, account, amount)
        if account ~= 'cash' and account ~= 'money' then return false end
        return safe(function() return exports.ox_inventory:RemoveItem(source, moneyItem(), amount) end) == true
    end,
    getItemCount = function(source, item, metadata)
        return safe(function() return exports.ox_inventory:Search(source, 'count', item, metadata) end) or 0
    end,
    addItem = function(source, item, amount, metadata)
        return safe(function() return exports.ox_inventory:AddItem(source, item, amount, metadata) end) == true
    end,
    removeItem = function(source, item, amount, metadata)
        return safe(function() return exports.ox_inventory:RemoveItem(source, item, amount, metadata) end) == true
    end,
    hasPermission = function(source, permission)
        local p = player(source)
        if not p then return false end
        local groups = safe(function() return p.getGroups() end)
        return type(groups) == 'table' and groups[permission] ~= nil
    end,
    setDuty = function(source, onDuty)
        local p = player(source)
        if not p then return false end
        return safe(function() p.set('dagOnDuty', onDuty, true) return true end) == true
    end
})
