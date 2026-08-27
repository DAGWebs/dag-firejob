-- A small FiveM runtime stub. It defines the natives the template touches so
-- the real resource files can be loaded and exercised in plain Lua 5.4.
local harness = {}

local ROOT = (arg and arg[0] or ''):match('^(.*)tests[/\\]lua[/\\]') or './'
harness.root = ROOT

local function path(relative) return ROOT .. relative end

harness.resourceName = 'dag-template'

function harness.reset()
    harness.resourceStates = {}
    harness.files = {}
    harness.savedFiles = {}
    harness.handlers = {}
    harness.netEvents = {}
    harness.clientEvents = {}
    harness.serverEvents = {}
    harness.threads = {}
    harness.timers = {}
    harness.stateBags = {}
    harness.exportsRegistered = {}
    harness.exportTargets = {}
    harness.aceAllowed = {}
    harness.identifiers = {}
    harness.names = {}
    harness.output = {}
    harness.gameTimer = 0
    harness.drawnMarkers = {}
    harness.helpText = {}
    harness.controlsReleased = {}
    harness.playerCoords = nil
    harness.localEvents = {}
    harness.commands = {}
    harness.waitBudget = nil
    harness.nuiMessages = {}
    harness.nuiCallbacks = {}
    harness.nuiFocus = nil
    _G.LocalPlayer = { state = {} }

    _G.DAG = nil
    _G.Config = nil
    _G.source = nil
end

-- vector3 with the subtraction/length semantics the interaction loop relies on.
local vectorMeta = {}
vectorMeta.__index = vectorMeta
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vectorMeta)
end
vectorMeta.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
vectorMeta.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

function _G.vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vectorMeta)
end
harness.vectorMeta = vectorMeta

_G.json = dofile(path('tests/lua/json.lua'))

function _G.GetCurrentResourceName() return harness.resourceName end
function _G.GetResourceState(resource) return harness.resourceStates[resource] or 'missing' end
function _G.GetGameTimer() return harness.gameTimer end

harness.STOP = '__harness_stop__'

-- Resource threads are `while true` loops. A wait budget lets a test run an
-- exact number of iterations and then unwind via a sentinel error.
function _G.Wait(ms)
    harness.gameTimer = harness.gameTimer + (ms or 0)
    if not harness.waitBudget then return end
    if harness.waitBudget <= 0 then error(harness.STOP, 0) end
    harness.waitBudget = harness.waitBudget - 1
end

-- Runs a thread body until it has called Wait() `allowedWaits` times, then
-- unwinds. `0` means "run one pass of a loop that waits at the end"; `1` means
-- "run one pass of a loop that waits at the top".
function harness.runThread(fn, allowedWaits)
    harness.waitBudget = allowedWaits or 0
    local ok, err = pcall(fn)
    harness.waitBudget = nil
    harness.nuiMessages = {}
    harness.nuiCallbacks = {}
    harness.nuiFocus = nil
    if not ok and err ~= harness.STOP then error(err, 0) end
end

function _G.CreateThread(fn) harness.threads[#harness.threads + 1] = fn end
function _G.SetTimeout(ms, fn) harness.timers[#harness.timers + 1] = { at = harness.gameTimer + ms, fn = fn } end

function _G.AddEventHandler(event, handler)
    harness.handlers[event] = harness.handlers[event] or {}
    table.insert(harness.handlers[event], handler)
    return { event = event, handler = handler }
end

function _G.RegisterNetEvent(event, handler)
    harness.netEvents[event] = true
    if handler then return AddEventHandler(event, handler) end
end

function _G.TriggerEvent(event, ...)
    table.insert(harness.localEvents, { event = event, args = table.pack(...) })
    for _, handler in ipairs(harness.handlers[event] or {}) do handler(...) end
end

function _G.TriggerClientEvent(event, target, ...)
    table.insert(harness.clientEvents, { event = event, target = target, args = table.pack(...) })
end

function _G.TriggerServerEvent(event, ...)
    table.insert(harness.serverEvents, { event = event, args = table.pack(...) })
end

function _G.RegisterCommand(name, handler, restricted)
    harness.commands = harness.commands or {}
    harness.commands[name] = { handler = handler, restricted = restricted }
end

function _G.LoadResourceFile(_, file) return harness.files[file] end
function _G.SaveResourceFile(_, file, data)
    harness.savedFiles[file] = data
    return true
end

function _G.print(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
    table.insert(harness.output, table.concat(parts, '\t'))
end

-- Server player natives
function _G.GetPlayerIdentifierByType(playerSource) return harness.identifiers[playerSource] end
function _G.GetPlayerIdentifiers(playerSource)
    local id = harness.identifiers[playerSource]
    return id and { id } or {}
end
function _G.GetPlayerName(playerSource) return harness.names[playerSource] or ('Player' .. tostring(playerSource)) end
function _G.IsPlayerAceAllowed(playerSource, permission)
    local allowed = harness.aceAllowed[playerSource]
    return allowed ~= nil and (allowed == true or allowed[permission] == true)
end

function _G.Player(playerSource)
    harness.stateBags[playerSource] = harness.stateBags[playerSource] or {}
    local bag = harness.stateBags[playerSource]
    return {
        state = setmetatable({}, {
            __index = function(_, key)
                if key == 'set' then
                    return function(_, name, value) bag[name] = value end
                end
                return bag[key]
            end
        })
    }
end

-- Client player natives
_G.LocalPlayer = { state = {} }
function _G.PlayerId() return 1 end
function _G.GetPlayerServerId() return 1 end
function _G.PlayerPedId() return 1 end
function _G.GetEntityCoords() return harness.playerCoords or vector3(0.0, 0.0, 0.0) end
function _G.DrawMarker(kind, x, y, z)
    table.insert(harness.drawnMarkers, { kind = kind, coords = vector3(x, y, z) })
end
function _G.BeginTextCommandDisplayHelp() end
function _G.AddTextComponentSubstringPlayerName(text) table.insert(harness.helpText, text) end
function _G.EndTextCommandDisplayHelp() end
function _G.IsControlJustReleased(_, key) return harness.controlsReleased[key] == true end
function _G.SendNUIMessage(payload)
    table.insert(harness.nuiMessages, payload)
end

function _G.RegisterNUICallback(name, handler)
    harness.nuiCallbacks[name] = handler
end

function _G.SetNuiFocus(hasFocus, hasCursor)
    harness.nuiFocus = { focus = hasFocus, cursor = hasCursor }
end

function _G.AddStateBagChangeHandler(key, _, handler)
    harness.handlers['statebag:' .. key] = harness.handlers['statebag:' .. key] or {}
    table.insert(harness.handlers['statebag:' .. key], handler)
end

_G.exports = setmetatable({}, {
    __call = function(_, name, fn) harness.exportsRegistered[name] = fn end,
    __index = function(_, resource)
        local target = harness.exportTargets[resource]
        if not target then error(('No stub export target for "%s"'):format(resource), 2) end
        return target
    end
})

-- Runs every thread body once. Loops in resource code use `while true`, so
-- threads under test are written to break out via a harness flag.
function harness.runThreads()
    for _, fn in ipairs(harness.threads) do fn() end
end

function harness.flushTimers(untilTime)
    untilTime = untilTime or math.huge
    local pending = harness.timers
    harness.timers = {}
    for _, timer in ipairs(pending) do
        if timer.at <= untilTime then timer.fn() else table.insert(harness.timers, timer) end
    end
end

function harness.load(relative)
    local chunk, err = loadfile(path(relative))
    assert(chunk, err)
    return chunk()
end

function harness.loadConfig()
    harness.load('config.lua')
    return _G.Config
end

function harness.loadServer(opts)
    opts = opts or {}
    harness.loadConfig()
    harness.load('bridge/shared.lua')
    harness.load('bridge/server.lua')
    for _, adapter in ipairs(opts.adapters or { 'standalone' }) do
        harness.load('bridge/server/' .. adapter .. '.lua')
    end
    for _, module in ipairs(opts.modules or {}) do
        harness.load('modules/' .. module .. '/server.lua')
    end
    return _G.DAG
end

function harness.loadClient(opts)
    opts = opts or {}
    harness.loadConfig()
    harness.load('bridge/shared.lua')
    harness.load('bridge/client.lua')
    for _, adapter in ipairs(opts.adapters or { 'standalone' }) do
        harness.load('bridge/client/' .. adapter .. '.lua')
    end
    for _, module in ipairs(opts.modules or {}) do
        harness.load('modules/' .. module .. '/client.lua')
    end
    for _, file in ipairs(opts.files or {}) do
        harness.load(file)
    end
    return _G.DAG
end

function harness.lastNuiMessage()
    return harness.nuiMessages[#harness.nuiMessages]
end

function harness.outputContains(needle)
    for _, line in ipairs(harness.output) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

harness.reset()
return harness
