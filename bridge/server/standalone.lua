local Bridge = DAG.Framework
local players = {}

local function defaultJob()
    -- Copied per player: sharing the Config table would make one SetDuty call
    -- change every player's duty state.
    local template = Config.Standalone.defaultJob or {}
    return {
        name = template.name or 'unemployed',
        label = template.label or 'Unemployed',
        grade = template.grade or 0,
        grade_name = template.gradeName or template.grade_name or 'none',
        onduty = template.onduty ~= false
    }
end

-- Publishes the in-memory player to a replicated state bag so the standalone
-- client adapter reports the same job the server is enforcing.
local function publish(source)
    local record = players[source]
    if not record or source == 0 then return end
    local handle = Player(source)
    if not handle or not handle.state then return end
    handle.state:set('dagPlayer', { job = record.job, money = record.money }, true)
end

local function player(source)
    if not players[source] then
        players[source] = {
            source = source,
            money = { cash = Config.Standalone.startingCash or 0, bank = 0 },
            job = defaultJob(),
            inventory = {}
        }
        publish(source)
    end
    return players[source]
end

Bridge.RegisterAdapter('standalone', {
    getPlayer = player,
    getJob = function(source) return player(source).job end,
    getMoney = function(source, account) return player(source).money[account] or 0 end,
    addMoney = function(source, account, amount)
        local p = player(source)
        p.money[account] = (p.money[account] or 0) + amount
        publish(source)
        return true
    end,
    removeMoney = function(source, account, amount)
        local p = player(source)
        local current = p.money[account] or 0
        if current < amount then return false end
        p.money[account] = current - amount
        publish(source)
        return true
    end,
    getItemCount = function(source, item) return player(source).inventory[item] or 0 end,
    addItem = function(source, item, amount)
        local p = player(source)
        p.inventory[item] = (p.inventory[item] or 0) + amount
        return true
    end,
    removeItem = function(source, item, amount)
        local p = player(source)
        local current = p.inventory[item] or 0
        if current < amount then return false end
        p.inventory[item] = current - amount
        return true
    end,
    setJob = function(source, job, grade)
        local p = player(source)
        p.job.name = job
        p.job.label = job
        p.job.grade = grade
        publish(source)
        return true
    end,
    setDuty = function(source, onDuty)
        player(source).job.onduty = onDuty
        publish(source)
        return true
    end
})

AddEventHandler('playerDropped', function()
    players[source] = nil
end)

-- Exposed so a standalone server can wire real persistence in without editing
-- the adapter: replace or wrap these from your own resource code.
Bridge.Standalone = {
    players = players,
    publish = publish,
    reset = function(source) players[source] = nil end
}
