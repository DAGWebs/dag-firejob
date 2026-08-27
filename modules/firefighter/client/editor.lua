-- The client half of the in-game editor.
--
-- It applies the override document the server sends, rebuilds the fixtures
-- that were built from the old one, and puts the whole thing behind a menu so
-- placing a second bay door is walking there and picking "add here" rather
-- than remembering a command.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Editor = {}
Fire.Editor = Editor

local overrides = {}

local function menuId(name)
    return ('%s:fire:editor:%s'):format(Bridge.namespace, name)
end

function Editor.Overrides()
    return overrides
end

-- Applying the same merge the server ran keeps both sides describing the same
-- station; nothing here decides anything on its own.
function Editor.Apply(payload)
    overrides = type(payload) == 'table' and payload or {}
    Shared.ApplyOverrides(overrides)
    TriggerEvent(Bridge.Event('fire:configChanged'))
    return Config.Firefighter
end

local function act(action, args)
    TriggerServerEvent(Bridge.Event('fire:editor'), action, args or {})
end

Editor.Act = act

RegisterNetEvent(Bridge.Event('fire:config'), function(payload)
    Editor.Apply(payload)
end)

CreateThread(function()
    Wait(1500)
    TriggerServerEvent(Bridge.Event('fire:requestConfig'))
end)

-- Menus ---------------------------------------------------------------------

local KIND_LABELS = {
    duty = 'Duty point',
    locker = 'Locker',
    supply = 'Supply cache',
    garage = 'Bay door',
    office = 'Watch office',
    ret = 'Return point'
}

local function refresh(menu)
    -- Every edit round-trips through the server, so the menu is rebuilt from
    -- the config that comes back rather than from what was just clicked.
    SetTimeout(400, function()
        Editor.Build()
        if menu and DAG.Menu.Current() then DAG.Menu.Open(menu) end
    end)
end

local function pointOptions(station, kind)
    local options = {}
    for index, point in ipairs(Shared.Points(station, kind)) do
        options[#options + 1] = {
            title = ('%s %d'):format(KIND_LABELS[kind] or kind, index),
            description = ('%.1f, %.1f, %.1f'):format(point.x, point.y, point.z),
            icon = 'chevron',
            badge = 'Remove',
            badgeTone = 'danger',
            onSelect = function()
                act('removePoint', { station = station.id, kind = kind, index = index })
                refresh(menuId('station:' .. station.id))
            end
        }
    end
    return options
end

local function stationMenu(station)
    local options = {
        { title = station.label or station.id, header = true },
        {
            title = ('Department: %s'):format(station.department or 'none'),
            description = 'Set with /set fsdepartment',
            icon = 'info',
            disabled = true
        },
        { title = 'Add here', header = true }
    }

    for _, kind in ipairs(Shared.PointKinds) do
        options[#options + 1] = {
            title = ('Add a %s here'):format((KIND_LABELS[kind] or kind):lower()),
            icon = 'check',
            badge = tostring(#Shared.Points(station, kind)),
            onSelect = function()
                act('addPoint', { station = station.id, kind = kind })
                refresh(menuId('station:' .. station.id))
            end
        }
    end

    options[#options + 1] = {
        title = 'Add an apparatus bay here',
        description = 'Uses the way you are facing as the spawn heading',
        icon = 'car',
        badge = tostring(#Shared.SpawnPoints(station)),
        onSelect = function()
            act('addSpawn', { station = station.id })
            refresh(menuId('station:' .. station.id))
        end
    }

    options[#options + 1] = { title = 'Existing points', header = true }
    for _, kind in ipairs(Shared.PointKinds) do
        for _, option in ipairs(pointOptions(station, kind)) do options[#options + 1] = option end
    end

    for index, spawn in ipairs(Shared.SpawnPoints(station)) do
        options[#options + 1] = {
            title = ('Apparatus bay %d'):format(index),
            description = ('%.1f, %.1f, %.1f @ %.0f'):format(
                spawn.coords.x, spawn.coords.y, spawn.coords.z, spawn.heading or 0),
            icon = 'car',
            badge = 'Remove',
            badgeTone = 'danger',
            onSelect = function()
                act('removeSpawn', { station = station.id, index = index })
                refresh(menuId('station:' .. station.id))
            end
        }
    end

    options[#options + 1] = { title = 'Station', header = true }
    options[#options + 1] = {
        title = 'Move the station here',
        description = 'Sets the map position and the blip',
        icon = 'wrench',
        onSelect = function()
            act('setStation', { station = station.id })
            refresh(menuId('station:' .. station.id))
        end
    }
    options[#options + 1] = {
        title = 'Delete this station',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm('Delete this station?', station.label or station.id, function(confirmed)
                if not confirmed then return end
                act('removeStation', { station = station.id })
                refresh(menuId('stations'))
            end)
        end
    }

    DAG.Menu.Register({
        id = menuId('station:' .. station.id),
        title = station.label or station.id,
        subtitle = 'Station layout',
        options = options
    })
    return menuId('station:' .. station.id)
end

local function callMenu(callType)
    local options = { { title = callType.label, header = true } }

    options[#options + 1] = {
        title = 'Add an incident location here',
        icon = 'check',
        badge = tostring(#(callType.locations or {})),
        onSelect = function()
            act('addLocation', { callType = callType.id })
            refresh(menuId('call:' .. callType.id))
        end
    }

    for index, location in ipairs(callType.locations or {}) do
        options[#options + 1] = {
            title = location.label or ('Location %d'):format(index),
            description = ('%.1f, %.1f, %.1f'):format(location.coords.x, location.coords.y, location.coords.z),
            icon = 'info',
            badge = 'Remove',
            badgeTone = 'danger',
            onSelect = function()
                act('removeLocation', { callType = callType.id, index = index })
                refresh(menuId('call:' .. callType.id))
            end
        }
    end

    DAG.Menu.Register({
        id = menuId('call:' .. callType.id),
        title = callType.label,
        subtitle = 'Incident locations',
        options = options
    })
    return menuId('call:' .. callType.id)
end

-- Rebuilds every editor menu from the current config.
function Editor.Build()
    local stations = { { title = 'Stations', header = true } }
    for _, station in ipairs(Shared.Stations()) do
        local points = 0
        for _, kind in ipairs(Shared.PointKinds) do points = points + #Shared.Points(station, kind) end
        stations[#stations + 1] = {
            title = station.label or station.id,
            description = ('%s - %d point(s), %d bay(s)'):format(
                station.department or 'no department', points, #Shared.SpawnPoints(station)),
            icon = 'info',
            menu = stationMenu(station)
        }
    end
    stations[#stations + 1] = { title = 'New', header = true }
    stations[#stations + 1] = {
        title = 'Create a station here',
        description = 'Name it with /set fsstation <id>',
        icon = 'wrench',
        disabled = true
    }
    DAG.Menu.Register({ id = menuId('stations'), title = 'Stations', options = stations })

    local calls = { { title = 'Call types', header = true } }
    for _, callType in ipairs(Shared.CallTypes()) do
        calls[#calls + 1] = {
            title = callType.label,
            description = ('%d location(s)'):format(#(callType.locations or {})),
            icon = 'info',
            menu = callMenu(callType)
        }
    end
    DAG.Menu.Register({ id = menuId('calls'), title = 'Incident locations', options = calls })

    local departments = { { title = 'Departments', header = true } }
    for _, department in ipairs(Shared.Departments()) do
        departments[#departments + 1] = {
            title = department.label or department.id,
            description = ('job %s - %d station(s)'):format(
                department.job or '-', #Shared.StationsFor(department.id)),
            icon = 'user',
            badge = 'Remove',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm('Delete this department?', department.label, function(confirmed)
                    if not confirmed then return end
                    act('removeDepartment', { department = department.id })
                    refresh(menuId('departments'))
                end)
            end
        }
    end
    DAG.Menu.Register({ id = menuId('departments'), title = 'Departments', options = departments })

    DAG.Menu.Register({
        id = menuId('root'),
        title = 'Configuration',
        subtitle = 'Edited in game, saved on the server',
        options = {
            { title = 'Layout', header = true },
            { title = 'Stations', description = 'Duty points, lockers, bay doors', icon = 'info', menu = menuId('stations') },
            { title = 'Departments', icon = 'user', menu = menuId('departments') },
            { title = 'Incident locations', icon = 'car', menu = menuId('calls') },
            { title = 'Everything else', header = true },
            {
                title = 'Settings are edited by command',
                description = '/set fsconfig dispatch.maxActive 5',
                icon = 'info',
                disabled = true
            },
            {
                title = 'Revert every in-game change',
                description = 'Back to what config.lua says',
                icon = 'close',
                badgeTone = 'danger',
                onSelect = function()
                    DAG.Menu.Confirm('Revert every in-game change?', 'This cannot be undone.', function(confirmed)
                        if confirmed then act('reset') end
                    end)
                end
            }
        }
    })

    return menuId('root')
end

function Editor.Open()
    DAG.Menu.Open(Editor.Build())
end

AddEventHandler(Bridge.Event('fire:configChanged'), function()
    Editor.Build()
end)

CreateThread(function()
    if not Shared.Enabled() then return end
    Editor.Build()
end)
