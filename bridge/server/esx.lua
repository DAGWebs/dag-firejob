local Bridge = DAG.Framework
local function core() return exports.es_extended:getSharedObject() end
local function player(source) return core().GetPlayerFromId(source) end

-- ESX account mutators return nothing, so success is confirmed by re-reading
-- the balance. Reporting an unverified `true` would make the bridge's transfer
-- compensation unreachable on ESX.
local function balance(p, account)
    if account == 'cash' then return p.getMoney() end
    local value = p.getAccount(account)
    return value and value.money
end

Bridge.RegisterAdapter('esx', {
    getPlayer = player,
    getIdentifier = function(source) local p = player(source) return p and p.identifier end,
    getName = function(source) local p = player(source) return p and p.getName() or GetPlayerName(source) end,
    getJob = function(source) local p = player(source) return p and p.getJob() end,
    getMoney = function(source, account)
        local p = player(source)
        -- nil (not 0) for an unknown account, so RemoveMoney refuses rather
        -- than acting on a balance it could not actually read.
        return p and balance(p, account) or nil
    end,
    addMoney = function(source, account, amount, reason)
        local p = player(source)
        if not p then return false end
        local before = balance(p, account)
        if not before then return false end
        if account == 'cash' then p.addMoney(amount, reason) else p.addAccountMoney(account, amount, reason) end
        return (balance(p, account) or before) > before
    end,
    removeMoney = function(source, account, amount, reason)
        local p = player(source)
        if not p then return false end
        local before = balance(p, account)
        if not before or before < amount then return false end
        if account == 'cash' then p.removeMoney(amount, reason) else p.removeAccountMoney(account, amount, reason) end
        return (balance(p, account) or before) < before
    end,
    getItemCount = function(source, item)
        local p = player(source)
        local entry = p and p.getInventoryItem(item)
        return entry and entry.count or 0
    end,
    addItem = function(source, item, amount)
        local p = player(source)
        if not p then return false end
        p.addInventoryItem(item, amount)
        return true
    end,
    removeItem = function(source, item, amount)
        local p = player(source)
        if not p then return false end
        p.removeInventoryItem(item, amount)
        return true
    end,
    -- ESX groups are a coarse admin ladder, not named permissions. Only claim
    -- a permission when the group actually matches it; ACE handles the rest
    -- (Bridge.HasPermission checks IsPlayerAceAllowed before reaching here).
    hasPermission = function(source, permission)
        local p = player(source)
        if not p then return false end
        local group = p.getGroup()
        if group == 'superadmin' then return true end
        return group ~= nil and group ~= 'user' and permission == group
    end,
    -- ESX job definitions live in the `jobs` and `job_grades` tables. setJob
    -- returns nothing, so the change is confirmed by re-reading the job for
    -- the same reason the account mutators above do.
    setJob = function(source, job, grade)
        local p = player(source)
        if not p then return false end
        p.setJob(job, grade)
        local current = p.getJob()
        return current ~= nil and current.name == job
    end,
    createUseableItem = function(item, callback) core().RegisterUsableItem(item, callback) return true end,
    registerCallback = function(name, callback) core().RegisterServerCallback(name, callback) end
})
