-- The in-game configuration editor.
--
-- Everything in modules/firefighter/config.lua is a baseline. What an admin
-- changes in game is stored as a sparse override document, merged back over
-- that baseline, and pushed to every client, so a station moves, gains a
-- second bay door, or disappears without touching a file or restarting.
--
-- Positions always come from the editing player's own ped. There is no command
-- that takes a coordinate, so there is nothing to mistype and nothing to spoof.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Editor = {}
Fire.Editor = Editor

local COLLECTION = 'firefighter_config'
local DOCUMENT = 'overrides'

local overrides = {}

local function settings()
    return Shared.Settings().editor or {}
end

-- Storage ------------------------------------------------------------------

function Editor.Overrides()
    return overrides
end

function Editor.Load()
    local stored = DAG.Storage.Get(COLLECTION, DOCUMENT)
    overrides = type(stored) == 'table' and stored or {}
    return overrides
end

function Editor.Save()
    DAG.Storage.Set(COLLECTION, DOCUMENT, overrides)
    return true
end

-- Rebuilds the live config and tells every client to do the same. Called after
-- every edit, so nothing is ever half-applied.
function Editor.Apply(broadcast)
    Shared.ApplyOverrides(overrides)
    TriggerEvent(Bridge.Event('fire:configChanged'))
    if broadcast ~= false then
        TriggerClientEvent(Bridge.Event('fire:config'), -1, overrides)
    end
    return Config.Firefighter
end

function Editor.Reset()
    overrides = {}
    Editor.Save()
    return Editor.Apply()
end

-- Document helpers ---------------------------------------------------------

local function bucket(name, id)
    overrides[name] = overrides[name] or {}
    overrides[name][id] = overrides[name][id] or {}
    return overrides[name][id]
end

-- An override list starts from whatever the packaged config had, so adding a
-- second duty point to a bundled station keeps the first one.
local function pointsOf(name, id, kind, packaged)
    local patch = bucket(name, id)
    if patch[kind] == nil then
        local existing = Shared.PointList((packaged or {})[kind])
        patch[kind] = existing
    elseif type(patch[kind]) ~= 'table' then
        patch[kind] = {}
    end
    return patch[kind]
end

local function commit()
    Editor.Save()
    Editor.Apply()
end

-- Mutations ----------------------------------------------------------------

function Editor.SetStation(id, coords, label)
    local packaged = Shared.Station(id)
    local patch = bucket('stations', id)
    patch.removed = nil
    patch.coords = Shared.Coords(coords)
    if label and label ~= '' then patch.label = label end
    if not patch.label and not packaged then patch.label = id end

    if not patch.department and not (packaged and packaged.department) then
        local department = Shared.DepartmentForCoords(coords)
        patch.department = department and department.id or Shared.Settings().fallbackDepartment
    end

    commit()
    return Shared.Station(id)
end

function Editor.AddPoint(stationId, kind, coords)
    local packaged = Shared.Station(stationId)
    if not packaged and not (overrides.stations or {})[stationId] then return nil, 'unknown_station' end

    local list = pointsOf('stations', stationId, kind, packaged)
    list[#list + 1] = Shared.Coords(coords)
    commit()
    return #list
end

function Editor.AddSpawn(stationId, coords, heading)
    local packaged = Shared.Station(stationId)
    if not packaged and not (overrides.stations or {})[stationId] then return nil, 'unknown_station' end

    local patch = bucket('stations', stationId)
    if type(patch.spawn) ~= 'table' or patch.spawn.coords then
        patch.spawn = {}
        for _, entry in ipairs(Shared.SpawnPoints(packaged or {})) do
            patch.spawn[#patch.spawn + 1] = { coords = entry.coords, heading = entry.heading }
        end
    end

    patch.spawn[#patch.spawn + 1] = { coords = Shared.Coords(coords), heading = tonumber(heading) or 0.0 }
    commit()
    return #patch.spawn
end

function Editor.SetStationField(stationId, field, value)
    local packaged = Shared.Station(stationId)
    if not packaged and not (overrides.stations or {})[stationId] then return nil, 'unknown_station' end

    bucket('stations', stationId)[field] = value
    commit()
    return true
end

function Editor.SetDepartment(id, fields)
    local patch = bucket('departments', id)
    patch.removed = nil
    for key, value in pairs(fields or {}) do patch[key] = value end
    if not patch.label and not Shared.Department(id) then patch.label = id end
    if not patch.job and not (Shared.Department(id) or {}).job then patch.job = id end
    commit()
    return Shared.Department(id)
end

function Editor.AddMutualAid(id, other)
    if not Shared.Department(id) then return nil, 'unknown_department' end
    if not Shared.Department(other) then return nil, 'unknown_department' end

    local patch = bucket('departments', id)
    if type(patch.mutualAid) ~= 'table' then
        patch.mutualAid = Shared.DeepCopy((Shared.Department(id) or {}).mutualAid or {})
    end
    for _, entry in ipairs(patch.mutualAid) do
        if entry == other then return nil, 'already_listed' end
    end

    patch.mutualAid[#patch.mutualAid + 1] = other
    commit()
    return #patch.mutualAid
end

function Editor.AddLocation(callTypeId, coords, label)
    local callType = Shared.CallType(callTypeId)
    if not callType then return nil, 'unknown_call_type' end

    local patch = bucket('callTypes', callTypeId)
    if type(patch.locations) ~= 'table' then
        patch.locations = Shared.DeepCopy(callType.locations or {})
    end

    patch.locations[#patch.locations + 1] = {
        coords = Shared.Coords(coords),
        label = label and label ~= '' and label or 'Added in game'
    }
    commit()
    return #patch.locations
end

-- Any scalar in the config, addressed by dotted path. This is what makes the
-- editor cover settings nobody wrote a command for.
function Editor.SetValue(path, value)
    if type(path) ~= 'string' or path == '' then return nil, 'invalid_path' end
    if Shared.GetPath(Shared.defaults, path) == nil and Shared.GetPath(Config.Firefighter, path) == nil then
        return nil, 'unknown_path'
    end

    overrides.values = overrides.values or {}
    overrides.values[path] = value
    commit()
    return value
end

-- Removal ------------------------------------------------------------------

-- Removing a packaged entry leaves a tombstone, because the baseline comes
-- back from config.lua on every start and would otherwise resurrect it.
function Editor.RemoveEntry(list, id)
    local packaged = Shared.FindById(Shared.defaults[list] or {}, id)
    local patch = (overrides[list] or {})[id]
    if not packaged and not patch then return nil, 'not_found' end

    if packaged then
        bucket(list, id).removed = true
    else
        overrides[list][id] = nil
    end
    commit()
    return true
end

function Editor.RemovePoint(stationId, kind, index)
    local packaged = Shared.Station(stationId)
    local list = pointsOf('stations', stationId, kind, packaged)
    local position = tonumber(index)
    if not position or not list[position] then return nil, 'not_found' end

    table.remove(list, position)
    commit()
    return #list
end

function Editor.RemoveSpawn(stationId, index)
    local packaged = Shared.Station(stationId)
    local patch = bucket('stations', stationId)
    if type(patch.spawn) ~= 'table' or patch.spawn.coords then
        patch.spawn = {}
        for _, entry in ipairs(Shared.SpawnPoints(packaged or {})) do
            patch.spawn[#patch.spawn + 1] = { coords = entry.coords, heading = entry.heading }
        end
    end

    local position = tonumber(index)
    if not position or not patch.spawn[position] then return nil, 'not_found' end

    table.remove(patch.spawn, position)
    commit()
    return #patch.spawn
end

function Editor.RemoveLocation(callTypeId, index)
    local callType = Shared.CallType(callTypeId)
    if not callType then return nil, 'unknown_call_type' end

    local patch = bucket('callTypes', callTypeId)
    if type(patch.locations) ~= 'table' then
        patch.locations = Shared.DeepCopy(callType.locations or {})
    end

    local position = tonumber(index)
    if not position or not patch.locations[position] then return nil, 'not_found' end

    table.remove(patch.locations, position)
    commit()
    return #patch.locations
end

function Editor.RemoveValue(path)
    if not (overrides.values or {})[path] then return nil, 'not_found' end
    overrides.values[path] = nil
    commit()
    return true
end

-- Reporting ----------------------------------------------------------------

function Editor.Describe(what, id)
    local lines = {}

    if what == 'stations' or what == nil then
        for _, station in ipairs(Shared.Stations()) do
            local parts = {}
            for _, kind in ipairs(Shared.PointKinds) do
                local count = #Shared.Points(station, kind)
                if count > 0 then parts[#parts + 1] = ('%s x%d'):format(kind, count) end
            end
            parts[#parts + 1] = ('spawn x%d'):format(#Shared.SpawnPoints(station))
            lines[#lines + 1] = ('%s [%s] %s'):format(station.id, station.department or '-', table.concat(parts, ', '))
        end
    end

    if what == 'departments' then
        for _, department in ipairs(Shared.Departments()) do
            lines[#lines + 1] = ('%s job=%s stations=%d'):format(
                department.id, department.job or '-', #Shared.StationsFor(department.id))
        end
    end

    if what == 'calls' then
        for _, callType in ipairs(Shared.CallTypes()) do
            lines[#lines + 1] = ('%s x%d locations'):format(callType.id, #(callType.locations or {}))
        end
    end

    if what == 'config' then
        for path, value in pairs(overrides.values or {}) do
            lines[#lines + 1] = ('%s = %s'):format(path, tostring(value))
        end
        if #lines == 0 then lines[1] = 'no value overrides' end
    end

    -- One station in detail, with the index of every point, because removing
    -- one means naming its number.
    if what == 'station' and id then
        local station = Shared.Station(id)
        if not station then return { ('no station %s'):format(id) } end

        lines[#lines + 1] = ('%s - %s [%s]'):format(station.id, station.label or '?', station.department or '-')
        for _, kind in ipairs(Shared.PointKinds) do
            for index, point in ipairs(Shared.Points(station, kind)) do
                lines[#lines + 1] = ('  %s %d: %.1f %.1f %.1f'):format(kind, index, point.x, point.y, point.z)
            end
        end
        for index, spawn in ipairs(Shared.SpawnPoints(station)) do
            lines[#lines + 1] = ('  spawn %d: %.1f %.1f %.1f @ %.0f'):format(
                index, spawn.coords.x, spawn.coords.y, spawn.coords.z, spawn.heading or 0)
        end
    end

    if #lines == 0 then lines[1] = 'nothing configured' end
    return lines
end

function Editor.Export()
    local ok, encoded = pcall(json.encode, overrides)
    return ok and encoded or '{}'
end

-- Commands -----------------------------------------------------------------

local function position(source)
    if source == 0 then return nil, nil end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil, nil end
    return Shared.Coords(GetEntityCoords(ped)), GetEntityHeading(ped)
end

local function tell(source, message)
    if source == 0 then return Bridge.Print(message) end
    Bridge.Notify(source, message, 'inform', 8000)
end

local function tellAll(source, lines)
    for _, line in ipairs(lines) do tell(source, line) end
end

-- Values typed in chat arrive as strings; a config that wants a number has to
-- get a number, or every comparison against it silently fails.
local function coerce(text)
    if text == nil then return nil end
    if text == 'true' then return true end
    if text == 'false' then return false end
    if text == 'nil' then return nil end
    return tonumber(text) or text
end

Editor.Coerce = coerce

local function rest(args, from)
    local parts = {}
    for index = from, #args do parts[#parts + 1] = args[index] end
    return table.concat(parts, ' ')
end

local POINT_KEYS = {
    fsduty = 'duty',
    fslocker = 'locker',
    fssupply = 'supply',
    fsgarage = 'garage',
    fsoffice = 'office',
    fsreturn = 'ret'
}

local REMOVE_KINDS = {
    duty = 'duty', locker = 'locker', supply = 'supply',
    garage = 'garage', office = 'office', ['return'] = 'ret'
}

local HELP = {
    'fsstation <id> [label]      move or create a station here',
    'fsduty|fslocker|fssupply|fsgarage|fsoffice|fsreturn <station>',
    'fsvehiclespawn <station>    add a bay here, facing the way you are',
    'fsblip <station> <sprite> [colour] [scale]',
    'fsdepartment <station> <departmentId>',
    'fsdept <id> [label] | fsdeptjob <id> <job> | fsdeptzone <id> <radius>',
    'fsdeptaid <id> <otherId> | fsdeptuniform <id> <set>',
    'fscall <callType> [label]   add an incident location here',
    'fsacademy | fsdrill | fshospital',
    'fsconfig <path> <value>     e.g. dispatch.maxActive 5',
    'fslist [stations|station <id>|departments|calls|config]',
    'fsremove <what> <id> [index] | fsreset | fsexport'
}

local handlers = {}

handlers.fsstation = function(source, args, coords)
    local id = args[2]
    if not id then return tell(source, 'usage: fsstation <id> [label]') end
    local station = Editor.SetStation(id, coords, rest(args, 3))
    tell(source, ('station %s set here (%s)'):format(station.id, station.label or id))
end

handlers.fsvehiclespawn = function(source, args, coords, heading)
    local id = args[2]
    if not id then return tell(source, 'usage: fsvehiclespawn <station>') end

    local count, err = Editor.AddSpawn(id, coords, heading)
    if not count then return tell(source, err) end
    tell(source, ('%s now has %d apparatus bay(s)'):format(id, count))
end

handlers.fsblip = function(source, args)
    local id, sprite = args[2], tonumber(args[3])
    if not id or not sprite then return tell(source, 'usage: fsblip <station> <sprite> [colour] [scale]') end

    local ok, err = Editor.SetStationField(id, 'blip', {
        sprite = sprite,
        colour = tonumber(args[4]) or 49,
        scale = tonumber(args[5]) or 0.8
    })
    tell(source, ok and ('blip updated on %s'):format(id) or err)
end

handlers.fsdepartment = function(source, args)
    local id, department = args[2], args[3]
    if not id or not department then return tell(source, 'usage: fsdepartment <station> <departmentId>') end
    if not Shared.Department(department) then return tell(source, 'no such department') end

    local ok, err = Editor.SetStationField(id, 'department', department)
    tell(source, ok and ('%s now belongs to %s'):format(id, department) or err)
end

handlers.fsdept = function(source, args)
    local id = args[2]
    if not id then return tell(source, 'usage: fsdept <id> [label]') end

    local fields = {}
    local label = rest(args, 3)
    if label ~= '' then fields.label = label end
    local department = Editor.SetDepartment(id, fields)
    tell(source, ('department %s set (%s)'):format(department.id, department.label or id))
end

handlers.fsdeptjob = function(source, args)
    local id, job = args[2], args[3]
    if not id or not job then return tell(source, 'usage: fsdeptjob <id> <frameworkJob>') end
    Editor.SetDepartment(id, { job = job })
    tell(source, ('%s now uses the %s job'):format(id, job))
end

handlers.fsdeptzone = function(source, args, coords)
    local id, radius = args[2], tonumber(args[3])
    if not id or not radius then return tell(source, 'usage: fsdeptzone <id> <radius>') end
    Editor.SetDepartment(id, { jurisdiction = { center = coords, radius = radius } })
    tell(source, ('%s covers %.0fm from here'):format(id, radius))
end

handlers.fsdeptaid = function(source, args)
    local id, other = args[2], args[3]
    if not id or not other then return tell(source, 'usage: fsdeptaid <id> <otherId>') end

    local count, err = Editor.AddMutualAid(id, other)
    tell(source, count and ('%s now calls %s for mutual aid'):format(id, other) or err)
end

handlers.fsdeptuniform = function(source, args)
    local id, set = args[2], args[3]
    if not id or not set then return tell(source, 'usage: fsdeptuniform <id> <uniformSet>') end
    Editor.SetDepartment(id, { uniform = set })
    tell(source, ('%s now wears the %s set'):format(id, set))
end

handlers.fscall = function(source, args, coords)
    local id = args[2]
    if not id then return tell(source, 'usage: fscall <callType> [label]') end

    local count, err = Editor.AddLocation(id, coords, rest(args, 3))
    tell(source, count and ('%s now has %d location(s)'):format(id, count) or err)
end

handlers.fsacademy = function(source, _, coords)
    Editor.SetValue('academy.classroom', coords)
    Editor.SetValue('academy.coords', coords)
    tell(source, 'academy classroom set here')
end

handlers.fsdrill = function(source, _, coords)
    Editor.SetValue('academy.drill', coords)
    tell(source, 'academy drill ground set here')
end

handlers.fshospital = function(source, _, coords)
    Editor.SetValue('victims.hospital', coords)
    tell(source, 'hospital handover set here')
end

handlers.fsconfig = function(source, args)
    local path = args[2]
    if not path or args[3] == nil then return tell(source, 'usage: fsconfig <path> <value>') end

    local value, err = Editor.SetValue(path, coerce(rest(args, 3)))
    if value == nil and err then return tell(source, err == 'unknown_path' and 'no such setting' or err) end
    tell(source, ('%s = %s'):format(path, tostring(value)))
end

handlers.fslist = function(source, args)
    tellAll(source, Editor.Describe(args[2] or 'stations', args[3]))
end

handlers.fsexport = function(source)
    Bridge.Print('firefighter overrides: %s', Editor.Export())
    tell(source, 'overrides printed to the server console')
end

handlers.fsreset = function(source)
    Editor.Reset()
    tell(source, 'every in-game change reverted to config.lua')
end

handlers.fsremove = function(source, args)
    local what, id = args[2], args[3]
    if not what then return tell(source, 'usage: fsremove <what> <id> [index]') end

    if what == 'station' then
        local ok, err = Editor.RemoveEntry('stations', id)
        return tell(source, ok and ('station %s removed'):format(id) or err)
    end

    if what == 'dept' or what == 'department' then
        local ok, err = Editor.RemoveEntry('departments', id)
        return tell(source, ok and ('department %s removed'):format(id) or err)
    end

    if what == 'spawn' then
        local count, err = Editor.RemoveSpawn(id, args[4])
        return tell(source, count and ('%s now has %d bay(s)'):format(id, count) or err)
    end

    if what == 'call' then
        local count, err = Editor.RemoveLocation(id, args[4])
        return tell(source, count and ('%s now has %d location(s)'):format(id, count) or err)
    end

    if what == 'config' then
        local ok, err = Editor.RemoveValue(id)
        return tell(source, ok and ('%s back to the packaged default'):format(id) or err)
    end

    local kind = REMOVE_KINDS[what]
    if not kind then return tell(source, 'what: station, dept, duty, locker, supply, garage, office, return, spawn, call, config') end

    local count, err = Editor.RemovePoint(id, kind, args[4])
    tell(source, count and ('%s now has %d %s point(s)'):format(id, count, what) or err)
end

for key, kind in pairs(POINT_KEYS) do
    handlers[key] = function(source, args, coords)
        local id = args[2]
        if not id then return tell(source, ('usage: %s <station>'):format(key)) end

        local count, err = Editor.AddPoint(id, kind, coords)
        tell(source, count and ('%s now has %d %s point(s)'):format(id, count, kind) or err)
    end
end

-- Loaded and applied at file scope rather than on a thread: the rest of the
-- job reads Config.Firefighter from its first frame, and it has to be the
-- edited one by then.
Editor.Load()
Editor.Apply(false)

local command = Shared.Command('editor')

if command then
DAG.Commands.Register(command, function(source, args)
    if settings().enabled == false then return tell(source, 'the in-game editor is switched off') end
    if not DAG.Access.Allowed(source, Shared.Policy(nil, 'admin'), 'admin') then
        return Bridge.Notify(source, 'You are not authorized to do that.', 'error')
    end

    local key = args[1] and args[1]:lower()
    local handler = key and handlers[key]
    if not handler then return tellAll(source, HELP) end

    local coords, heading = position(source)
    if not coords and key ~= 'fslist' and key ~= 'fsexport' and key ~= 'fsreset'
        and key ~= 'fsconfig' and key ~= 'fsremove' then
        return tell(source, 'stand where you want it: this command uses your position')
    end

    handler(source, args, coords, heading)
end, {
    help = 'Configure the firefighter job in game.',
    arguments = { { name = 'key', help = 'fsstation, fsduty, fslist, fsremove...' } }
})
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    if settings().enabled == false or not command then
        return Bridge.Print('firefighter editor disabled by config')
    end
    Bridge.Print('firefighter editor ready: /%s fslist', command)
end)

-- A joining client asks for the current document rather than being pushed one
-- it might miss.
RegisterNetEvent(Bridge.Event('fire:requestConfig'), function()
    TriggerClientEvent(Bridge.Event('fire:config'), source, overrides)
end)

-- The editor menu drives the same functions the commands do, so there is one
-- implementation of every edit and one place the authorization is checked.
local ACTIONS = {
    addPoint = function(_, args, coords)
        return Editor.AddPoint(args.station, args.kind, coords)
    end,
    addSpawn = function(_, args, coords, heading)
        return Editor.AddSpawn(args.station, coords, heading)
    end,
    setStation = function(_, args, coords)
        return Editor.SetStation(args.station, coords, args.label)
    end,
    removePoint = function(_, args) return Editor.RemovePoint(args.station, args.kind, args.index) end,
    removeSpawn = function(_, args) return Editor.RemoveSpawn(args.station, args.index) end,
    removeStation = function(_, args) return Editor.RemoveEntry('stations', args.station) end,
    removeDepartment = function(_, args) return Editor.RemoveEntry('departments', args.department) end,
    addLocation = function(_, args, coords) return Editor.AddLocation(args.callType, coords, args.label) end,
    removeLocation = function(_, args) return Editor.RemoveLocation(args.callType, args.index) end,
    reset = function() return Editor.Reset() end
}

RegisterNetEvent(Bridge.Event('fire:editor'), function(action, args)
    local playerSource = source
    if settings().enabled == false then return end
    if type(action) ~= 'string' or type(args) ~= 'table' then return end
    if not DAG.Access.Allowed(playerSource, Shared.Policy(nil, 'admin'), 'admin') then
        return Bridge.Notify(playerSource, 'You are not authorized to do that.', 'error')
    end

    local handler = ACTIONS[action]
    if not handler then return end

    local coords, heading = position(playerSource)
    local ok, result, err = pcall(handler, playerSource, args, coords, heading)
    if not ok then return Bridge.Print('firefighter editor action failed: %s', tostring(result)) end
    if result == nil then return Bridge.Notify(playerSource, err or 'That did not work.', 'error') end

    Bridge.Notify(playerSource, 'Configuration updated.', 'success', 3000)
end)
