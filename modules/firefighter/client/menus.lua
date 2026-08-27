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
local context = { certifications = {}, items = { carried = {} }, academy = {}, departments = {} }

local function certified(id)
    if not id then return true end
    for _, held in ipairs(context.certifications or {}) do
        if held == id then return true end
    end
    return false
end

local function carrying(role)
    local items = context.items or {}
    if not items.enforced then return true end
    return (items.carried or {})[role] == true
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
    local department = Shared.Department(call.department)
    local mine = call.department == nil or call.department == Client.Department()

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
            {
                title = department and department.label or 'Unassigned',
                description = mine and 'Your department' or 'Mutual aid',
                icon = 'user',
                badgeTone = mine and 'success' or 'accent',
                badge = department and department.short or nil,
                disabled = true
            },
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

local function agentOption(id, title, description, role)
    local active = Suppression.Agent() == id
    local held = role == nil or carrying(role)
    return {
        title = title,
        description = description,
        icon = 'box',
        disabled = not held,
        badge = active and 'In hand' or (not held and 'Not carried' or nil),
        badgeTone = active and 'success' or 'danger',
        onSelect = function() Suppression.Toggle(id) end
    }
end

local function lockerOptions()
    local scba = Shared.Settings().scba or {}
    local water = Shared.Settings().water or {}
    local air = Client.Air()
    local charge = Client.Extinguisher()
    local line = Fire.Hose and Fire.Hose.Deployed()

    return {
        { title = 'Nozzles', header = true },
        agentOption('hose', 'Hose line', 'Full flow. Pulls a line off a pump parked nearby.', 'hose'),
        agentOption('extinguisher', 'Extinguisher', 'Short reach, carried on you.', 'extinguisher'),
        agentOption('monitor', 'Deck monitor', 'Long reach and high flow, straight off the pump.'),
        {
            title = line and 'Stow the line' or 'Stow equipment',
            icon = 'close',
            onSelect = function() Suppression.Stow() end
        },
        { title = 'Tools', header = true },
        {
            title = 'Thermal imaging camera',
            description = 'See through smoke to find patients.',
            icon = 'info',
            disabled = not carrying('thermal'),
            badge = Suppression.Thermal() and 'On' or (carrying('thermal') and 'Off' or 'Not carried'),
            badgeTone = Suppression.Thermal() and 'success' or nil,
            keepOpen = true,
            onSelect = function() Suppression.ToggleThermal() end
        },
        {
            title = 'Jaws of life',
            description = 'Carried for extrication work.',
            icon = 'wrench',
            badge = carrying('jaws') and 'Carried' or 'Not carried',
            badgeTone = carrying('jaws') and 'success' or 'danger',
            disabled = true
        },
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
        if unit.capacity > 0 then
            options[#options + 1] = {
                title = unit.supplied and 'Break the supply line' or 'Lay a supply line',
                description = 'Puts the pump on a hydrant so the tank stops going down',
                icon = 'wrench',
                badge = unit.supplied and 'On the hydrant' or nil,
                badgeTone = 'success',
                onSelect = function()
                    if not Fire.Hose then return end
                    if unit.supplied then return Fire.Hose.DisconnectSupply() end
                    Fire.Hose.ConnectSupply()
                end
            }
        end
    end

    return options
end

-- Main ----------------------------------------------------------------------

local function mainOptions()
    local call = Client.Assigned()
    local profile = context.profile
    local onDuty = Client.OnDuty()
    local department = Shared.Department(Client.Department() or (profile and profile.department))

    local options = {
        { title = department and department.label or 'Fire and Rescue', header = true },
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
        local badge, tone = severityBadge(call)
        options[#options + 1] = {
            title = ('Current call - %s'):format(call.id),
            description = call.location,
            icon = 'chevron',
            badge = badge,
            badgeTone = tone,
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
        title = 'Fire academy',
        description = 'Sit a course and earn a certification',
        icon = 'user',
        onSelect = function() Menus.OpenAcademy() end
    }
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
    options[#options + 1] = {
        title = 'Departments',
        description = 'Who is covering what',
        icon = 'info',
        menu = menuId('departments')
    }

    if context.canCommand then
        options[#options + 1] = { title = 'Command', header = true }
        options[#options + 1] = {
            title = 'Watch office',
            description = 'Hire, promote, and dismiss',
            icon = 'lock',
            onSelect = function() Menus.OpenCommand() end
        }
    end

    options[#options + 1] = { title = 'Duty', header = true }
    options[#options + 1] = {
        title = onDuty and 'Clock off' or 'Clock on',
        description = 'You have to be standing at a station duty point',
        icon = 'lock',
        onSelect = function() TriggerServerEvent(Bridge.Event('fire:toggleDuty')) end
    }

    return options
end

local function departmentOptions()
    local options = { { title = 'Departments', header = true } }
    for _, department in ipairs(context.departments or {}) do
        options[#options + 1] = {
            title = department.label,
            description = ('%d station(s), %d on duty'):format(department.stations or 0, department.onDuty or 0),
            icon = 'info',
            badge = ('%d call(s)'):format(department.calls or 0),
            badgeTone = (department.onDuty or 0) > 0 and 'success' or 'danger',
            disabled = true
        }
    end
    if #options == 1 then
        options[#options + 1] = { title = 'No departments configured', disabled = true }
    end
    return options
end

-- Async menus ---------------------------------------------------------------

local COURSE_REASONS = {
    already_held = 'Already signed off',
    rank_too_low = 'Rank too low',
    missing_prerequisite = 'Prerequisite missing',
    cooling_down = 'Cooling down'
}

function Menus.OpenAcademy()
    Menus.Sync(function(result)
        local options = { { title = 'Courses', header = true } }

        for _, course in ipairs(result.academy or {}) do
            local badge = course.available and (course.cost > 0 and Shared.FormatMoney(course.cost) or 'Open')
                or (COURSE_REASONS[course.reason] or 'Unavailable')
            options[#options + 1] = {
                title = course.label,
                description = course.description,
                icon = 'user',
                disabled = not course.available,
                badge = badge,
                badgeTone = course.available and 'success' or 'danger',
                onSelect = function() Fire.Academy.Enrol(course.id) end
            }
        end

        local enrolment = result.enrolment
        if enrolment then
            options[#options + 1] = { title = 'In progress', header = true }
            options[#options + 1] = {
                title = enrolment.label or enrolment.course,
                description = ('Phase: %s'):format(enrolment.phase),
                badge = 'Enrolled',
                badgeTone = 'accent',
                disabled = true
            }
            options[#options + 1] = {
                title = 'Leave the course',
                icon = 'close',
                onSelect = function() Fire.Academy.Abandon() end
            }
        end

        DAG.Menu.Register({
            id = menuId('academy'),
            title = (Shared.Settings().academy or {}).label or 'Fire academy',
            subtitle = 'Training and certification',
            options = options
        })
        DAG.Menu.Navigate(menuId('academy'))
    end)
end

local function rankMenuFor(applicant)
    local options = { { title = 'Set rank', header = true } }
    for _, rank in ipairs(Shared.Ranks()) do
        options[#options + 1] = {
            title = rank.label,
            description = ('Grade %d, %d XP'):format(rank.grade or 0, rank.xp or 0),
            icon = 'user',
            onSelect = function()
                TriggerServerEvent(Bridge.Event('fire:setRank'), applicant.source, rank.id)
            end
        }
    end

    local id = menuId('rank:' .. applicant.source)
    DAG.Menu.Register({ id = id, title = applicant.name or 'Firefighter', options = options })
    return id
end

local function applicantMenuFor(applicant, departmentId)
    local id = menuId('applicant:' .. applicant.source)
    DAG.Menu.Register({
        id = id,
        title = applicant.name or 'Firefighter',
        subtitle = applicant.jobLabel or applicant.job or 'Unemployed',
        options = {
            { title = 'Employment', header = true },
            {
                title = 'Hire into the department',
                icon = 'check',
                onSelect = function()
                    TriggerServerEvent(Bridge.Event('fire:hire'), applicant.source, departmentId)
                end
            },
            { title = 'Set rank', icon = 'user', menu = rankMenuFor(applicant) },
            {
                title = 'Dismiss',
                icon = 'close',
                onSelect = function()
                    DAG.Menu.Confirm('Dismiss this firefighter?', applicant.name, function(confirmed)
                        if confirmed then TriggerServerEvent(Bridge.Event('fire:terminate'), applicant.source) end
                    end)
                end
            }
        }
    })
    return id
end

function Menus.OpenCommand()
    Bridge.TriggerCallback(Bridge.Event('fire:applicants'), function(result, err)
        if err or type(result) ~= 'table' then
            return Bridge.Notify('The watch office did not answer.', 'error')
        end

        local departmentId = Client.Department() or (context.profile and context.profile.department)
        local options = { { title = 'People in front of you', header = true } }

        for _, applicant in ipairs(result) do
            options[#options + 1] = {
                title = applicant.name or 'Unknown',
                description = applicant.jobLabel or applicant.job or 'Unemployed',
                icon = 'user',
                menu = applicantMenuFor(applicant, departmentId)
            }
        end
        if #options == 1 then
            options[#options + 1] = {
                title = 'Nobody is standing here',
                description = 'Stand in front of the person you want to hire.',
                disabled = true
            }
        end

        DAG.Menu.Register({
            id = menuId('command'),
            title = 'Watch office',
            subtitle = 'Hiring and personnel',
            options = options
        })
        DAG.Menu.Navigate(menuId('command'))
    end)
end

function Menus.OpenProfile()
    Menus.Sync(function(result)
        local profile = result.profile
        if not profile then return Bridge.Notify('No personnel record found.', 'error') end

        local stats = profile.stats or {}
        local upcoming, remaining = Shared.NextRank(profile.xp or 0)
        local department = Shared.Department(profile.department)
        local options = {
            { title = 'Record', header = true },
            {
                title = profile.rank or 'Unranked',
                description = ('%d XP - %s'):format(profile.xp or 0, department and department.label or 'Unaffiliated'),
                icon = 'user',
                disabled = true
            }
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
            local department = Shared.Department(entry.department)
            options[#options + 1] = {
                title = ('%d. %s'):format(index, entry.name),
                description = ('%s%s - %d calls, %d rescues'):format(
                    entry.rank,
                    department and (' (' .. department.short .. ')') or '',
                    entry.calls, entry.rescues
                ),
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
    local department = Shared.Department(Client.Department())
    DAG.Menu.Register({
        id = menuId('main'),
        title = department and department.label or 'Fire and Rescue',
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
    DAG.Menu.Register({
        id = menuId('departments'),
        title = 'Departments',
        options = departmentOptions()
    })
end

Menus.MainMenu = menuId('main')

-- Opening the root menu is worth a round trip, so the record and the roster on
-- it are current rather than whatever was cached last time.
function Menus.Open()
    Menus.Refresh()
    DAG.Menu.Open(Menus.MainMenu)
    Menus.Sync()
end

AddEventHandler(Bridge.Event('fire:clientUpdated'), function()
    Menus.Refresh()
end)

CreateThread(function()
    if not Shared.Enabled() then return end
    Menus.Refresh()
    Wait(2500)
    Menus.Sync()
end)
