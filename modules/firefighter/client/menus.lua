-- Every firefighter menu, expressed as DAG.Menu definitions so the same code
-- renders through ox_lib, qb-menu, the bundled NUI interface, or the chat
-- fallback without knowing which one is running.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Duty = Fire.Duty
local Suppression = Fire.Suppression
local Menus = {}
Fire.Menus = Menus

local menuId = Duty.MenuId
local context = { certifications = {} }

local function certified(id)
    if not id then return true end
    for _, held in ipairs(context.certifications or {}) do
        if held == id then return true end
    end
    return false
end

-- Pulls the server's view of this firefighter once and hands it to whatever
-- wanted it, rather than every menu asking for its own copy.
function Menus.Sync(callback)
    Bridge.TriggerCallback(Bridge.Event('fire:context'), function(result, err)
        if err or type(result) ~= 'table' then
            Bridge.Notify('The department database did not answer.', 'error')
            return
        end
        context = result
        Menus.Refresh()
        if callback then callback(result) end
    end)
end

local function severityBadge(call)
    local severity = tonumber(call.severity) or 0
    if severity >= 0.75 then return 'Fully involved', 'danger' end
    if severity >= 0.4 then return 'Working', 'danger' end
    if severity > 0 then return 'Knockdown', 'accent' end
    return 'Clear', 'success'
end

local function waypointTo(call)
    SetNewWaypoint(call.coords.x, call.coords.y)
    Bridge.Notify(('Waypoint set to %s.'):format(call.id), 'inform', 4000)
end

-- Dispatch board ------------------------------------------------------------

local function callSubmenu(call)
    local badge, tone = severityBadge(call)
    DAG.Menu.Register({
        id = menuId('call:' .. call.id),
        title = ('%s %s'):format(call.id, call.label),
        subtitle = call.location,
        options = {
            { title = 'Status', header = true },
            { title = badge, description = ('Priority %d - %s'):format(call.priority or 3, call.state or 'pending'),
              badge = ('%d%%'):format(math.floor((tonumber(call.severity) or 0) * 100)),
              badgeTone = tone, progress = math.floor((tonumber(call.severity) or 0) * 100), disabled = true },
            { title = Fire.Hud.Objectives(call) or 'Nothing outstanding', icon = 'info', disabled = true },
            { title = 'Actions', header = true },
            {
                title = 'Respond',
                description = 'Sign on to this call',
                icon = 'check',
                badge = call.requiredCertification and (certified(call.requiredCertification) and 'Certified' or 'Not certified') or nil,
                badgeTone = call.requiredCertification and (certified(call.requiredCertification) and 'success' or 'danger') or nil,
                onSelect = function() TriggerServerEvent(Bridge.Event('fire:join'), call.id) end
            },
            {
                title = 'Set waypoint',
                icon = 'car',
                keepOpen = true,
                onSelect = function() waypointTo(call) end
            }
        }
    })
    return menuId('call:' .. call.id)
end

local function boardOptions()
    local options = { { title = 'Open calls', header = true } }
    local calls = Client.SortedCalls()

    if #calls == 0 then
        options[#options + 1] = { title = 'Nothing working', description = 'The board is clear.', disabled = true }
        return options
    end

    for _, call in ipairs(calls) do
        local badge, tone = severityBadge(call)
        options[#options + 1] = {
            title = ('%s  %s'):format(call.id, call.label),
            description = ('%s - %d responder(s)'):format(call.location or 'Unknown', #(call.responders or {})),
            icon = 'info',
            badge = badge,
            badgeTone = tone,
            progress = math.floor((tonumber(call.severity) or 0) * 100),
            menu = callSubmenu(call)
        }
    end
    return options
end

-- Locker --------------------------------------------------------------------

local function agentOption(id, title, description)
    local active = Suppression.Agent() == id
    return {
        title = title,
        description = description,
        icon = 'box',
        badge = active and 'In hand' or nil,
        badgeTone = 'success',
        onSelect = function() Suppression.Toggle(id) end
    }
end

local function lockerOptions()
    local scba = Shared.Settings().scba or {}
    local water = Shared.Settings().water or {}
    local air = Client.Air()
    local charge = Client.Extinguisher()

    return {
        { title = 'Nozzles', header = true },
        agentOption('hose', 'Hose line', 'Full flow. Draws from an apparatus parked nearby.'),
        agentOption('extinguisher', 'Extinguisher', 'Short reach, carried on you.'),
        agentOption('monitor', 'Deck monitor', 'Long reach and high flow, straight off the pump.'),
        { title = 'Stow equipment', icon = 'close', onSelect = function() Suppression.Stow() end },
        { title = 'Supply', header = true },
        {
            title = 'Replace SCBA cylinder',
            icon = 'check',
            badge = ('%d%%'):format(math.floor(air / math.max(1, tonumber(scba.capacity) or 1500) * 100)),
            progress = math.floor(air / math.max(1, tonumber(scba.capacity) or 1500) * 100),
            keepOpen = true,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:refillGear'), 'air') end
        },
        {
            title = 'Recharge extinguisher',
            icon = 'check',
            badge = ('%d%%'):format(math.floor(charge / math.max(1, tonumber(water.extinguisherCapacity) or 220) * 100)),
            progress = math.floor(charge / math.max(1, tonumber(water.extinguisherCapacity) or 220) * 100),
            keepOpen = true,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:refillGear'), 'extinguisher') end
        }
    }
end

-- Garage --------------------------------------------------------------------

local function garageOptions()
    local unit = Client.Unit()
    local options = { { title = 'Apparatus', header = true } }

    for _, apparatus in ipairs(Shared.Settings().apparatus or {}) do
        local allowed = certified(apparatus.certification)
        options[#options + 1] = {
            title = apparatus.label,
            description = apparatus.description,
            icon = 'car',
            disabled = not allowed or unit ~= nil,
            badge = not allowed and 'Not certified'
                or (apparatus.water > 0 and ('%dL'):format(apparatus.water) or 'No tank'),
            badgeTone = allowed and 'accent' or 'danger',
            onSelect = function() Duty.RequestUnit(apparatus.id) end
        }
    end

    if unit then
        options[#options + 1] = { title = 'Signed out', header = true }
        options[#options + 1] = {
            title = ('Return %s'):format(unit.label or 'apparatus'),
            icon = 'back',
            badge = unit.capacity > 0 and ('%d/%dL'):format(unit.water or 0, unit.capacity) or nil,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:returnUnit')) end
        }
    end

    return options
end

-- Main ----------------------------------------------------------------------

local function mainOptions()
    local call = Client.Assigned()
    local profile = context.profile
    local onDuty = Client.OnDuty()

    local options = {
        { title = 'Los Santos Fire Department', header = true },
        {
            title = profile and profile.name or 'Personnel',
            description = profile and ('%s - %d XP'):format(profile.rank or 'Unranked', profile.xp or 0)
                or 'Clock on to load your record',
            icon = 'user',
            badge = onDuty and 'On duty' or 'Off duty',
            badgeTone = onDuty and 'success' or nil,
            disabled = true
        },
        { title = 'Operations', header = true },
        {
            title = 'Dispatch board',
            description = 'Everything the department is working',
            icon = 'info',
            badge = tostring(#Client.SortedCalls()),
            menu = menuId('board')
        }
    }

    if call then
        options[#options + 1] = {
            title = ('Current call - %s'):format(call.id),
            description = call.location,
            icon = 'chevron',
            badge = select(1, severityBadge(call)),
            badgeTone = select(2, severityBadge(call)),
            menu = menuId('call:' .. call.id)
        }
        options[#options + 1] = {
            title = 'Clear from the call',
            icon = 'close',
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:leave')) end
        }
    end

    options[#options + 1] = { title = 'Station', header = true }
    options[#options + 1] = { title = 'Equipment locker', icon = 'box', menu = menuId('locker') }
    options[#options + 1] = { title = 'Apparatus bay', icon = 'car', menu = menuId('garage') }
    options[#options + 1] = {
        title = 'Personnel file',
        icon = 'user',
        onSelect = function() Menus.OpenProfile() end
    }
    options[#options + 1] = {
        title = 'Duty roster',
        icon = 'user',
        onSelect = function() Menus.OpenRoster() end
    }
    options[#options + 1] = {
        title = 'Department leaderboard',
        icon = 'cash',
        onSelect = function() Menus.OpenLeaderboard() end
    }

    options[#options + 1] = { title = 'Duty', header = true }
    options[#options + 1] = {
        title = onDuty and 'Clock off' or 'Clock on',
        description = 'You have to be standing at a station duty point',
        icon = 'lock',
        onSelect = function() TriggerServerEvent(Bridge.Event('fire:toggleDuty')) end
    }

    return options
end

-- Async menus ---------------------------------------------------------------

function Menus.OpenProfile()
    Menus.Sync(function(result)
        local profile = result.profile
        if not profile then return Bridge.Notify('No personnel record found.', 'error') end

        local stats = profile.stats or {}
        local upcoming, remaining = Shared.NextRank(profile.xp or 0)
        local options = {
            { title = 'Record', header = true },
            { title = profile.rank or 'Unranked', description = ('%d XP'):format(profile.xp or 0), icon = 'user', disabled = true }
        }

        if upcoming then
            local floor = Shared.RankFor(profile.xp or 0)
            local span = math.max(1, (tonumber(upcoming.xp) or 0) - (tonumber(floor and floor.xp) or 0))
            options[#options + 1] = {
                title = ('Next: %s'):format(upcoming.label),
                description = ('%d XP to go'):format(remaining),
                progress = math.floor(Shared.Clamp((span - remaining) / span, 0, 1) * 100),
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Career', header = true }
        options[#options + 1] = { title = 'Calls worked', badge = tostring(stats.calls or 0), disabled = true }
        options[#options + 1] = { title = 'Fires extinguished', badge = tostring(stats.firesExtinguished or 0), disabled = true }
        options[#options + 1] = { title = 'Patients rescued', badge = tostring(stats.victimsRescued or 0), disabled = true }
        options[#options + 1] = { title = 'Releases contained', badge = tostring(stats.hazardsContained or 0), disabled = true }
        options[#options + 1] = { title = 'Water used', badge = ('%dL'):format(stats.litresUsed or 0), disabled = true }
        options[#options + 1] = { title = 'Career earnings', badge = Shared.FormatMoney(stats.earnings or 0), disabled = true }
        if stats.fastestResponse then
            options[#options + 1] = {
                title = 'Fastest response',
                badge = Shared.FormatDuration(stats.fastestResponse),
                badgeTone = 'success',
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Training', header = true }
        for _, certification in ipairs(Shared.Settings().certifications or {}) do
            options[#options + 1] = {
                title = certification.label,
                description = certification.description,
                badge = certified(certification.id) and 'Signed off' or 'Not held',
                badgeTone = certified(certification.id) and 'success' or 'danger',
                disabled = true
            }
        end

        DAG.Menu.Register({ id = menuId('profile'), title = 'Personnel file', subtitle = profile.name, options = options })
        DAG.Menu.Navigate(menuId('profile'))
    end)
end

function Menus.OpenRoster()
    Menus.Sync(function(result)
        local options = { { title = 'On duty', header = true } }
        for _, entry in ipairs(result.roster or {}) do
            options[#options + 1] = {
                title = entry.name or 'Unknown',
                description = ('%s - %s'):format(
                    entry.station and (Shared.Station(entry.station) or {}).label or 'Unassigned',
                    entry.callId or 'available'
                ),
                icon = 'user',
                badge = Shared.FormatDuration(entry.since or 0),
                disabled = true
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'Nobody is on duty', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('roster'), title = 'Duty roster', options = options })
        DAG.Menu.Navigate(menuId('roster'))
    end)
end

function Menus.OpenLeaderboard()
    Bridge.TriggerCallback(Bridge.Event('fire:leaderboard'), function(result, err)
        if err or type(result) ~= 'table' then
            return Bridge.Notify('The department database did not answer.', 'error')
        end

        local options = { { title = 'Most experienced', header = true } }
        for index, entry in ipairs(result) do
            options[#options + 1] = {
                title = ('%d. %s'):format(index, entry.name),
                description = ('%s - %d calls, %d rescues'):format(entry.rank, entry.calls, entry.rescues),
                badge = tostring(entry.xp),
                badgeTone = index == 1 and 'success' or 'accent',
                disabled = true
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'No records yet', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('leaderboard'), title = 'Department leaderboard', options = options })
        DAG.Menu.Navigate(menuId('leaderboard'))
    end, 10)
end

-- Registration --------------------------------------------------------------

-- Menus are re-registered rather than mutated: DAG.Menu keys on the id, so
-- registering the same id again is the supported way to refresh a live board.
function Menus.Refresh()
    DAG.Menu.Register({
        id = menuId('main'),
        title = 'Los Santos Fire Department',
        subtitle = Client.OnDuty() and 'On duty' or 'Off duty',
        options = mainOptions()
    })
    DAG.Menu.Register({
        id = menuId('board'),
        title = 'Dispatch board',
        subtitle = 'Live incidents',
        options = boardOptions()
    })
    DAG.Menu.Register({
        id = menuId('locker'),
        title = 'Equipment locker',
        options = lockerOptions()
    })
    DAG.Menu.Register({
        id = menuId('garage'),
        title = 'Apparatus bay',
        options = garageOptions()
    })
end

AddEventHandler(Bridge.Event('fire:clientUpdated'), function()
    Menus.Refresh()
end)

Menus.MainMenu = menuId('main')

-- Opening the root menu is worth a round trip, so the record and the roster on
-- it are current rather than whatever was cached last time.
function Menus.Open()
    Menus.Refresh()
    DAG.Menu.Open(Menus.MainMenu)
    Menus.Sync()
end

CreateThread(function()
    if not Shared.Enabled() then return end
    Menus.Refresh()
    Wait(2500)
    Menus.Sync()
end)
