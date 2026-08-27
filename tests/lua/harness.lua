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
    harness.controlsPressed = {}
    harness.playerCoords = nil
    harness.localEvents = {}
    harness.commands = {}
    harness.waitBudget = nil
    harness.nuiMessages = {}
    harness.nuiCallbacks = {}
    harness.nuiFocus = nil
    -- Entity world used by the firefighter job: peds, vehicles, blips, script
    -- fires, and the weapons/animations a client asks for.
    harness.entities = {}
    harness.entityCoords = {}
    harness.entityModels = {}
    harness.entityHealth = {}
    harness.entityHeadings = {}
    harness.playerPeds = {}
    harness.players = nil
    harness.netIds = {}
    harness.nextEntity = 100
    harness.nextBlip = 1
    harness.nextFire = 1
    harness.blips = {}
    harness.scriptFires = {}
    harness.weapons = {}
    harness.animations = {}
    harness.attachments = {}
    harness.drawnText = {}
    harness.drawnRects = {}
    harness.waypoints = {}
    harness.keyMappings = {}
    harness.pedShooting = false
    harness.forwardVector = { x = 1.0, y = 0.0, z = 0.0 }
    harness.closestObject = nil
    harness.modelsLoaded = true
    harness.animDictsLoaded = true
    harness.ptfxLoaded = true
    harness.particles = {}
    harness.nextParticle = 0
    harness.sounds = {}
    harness.timecycle = nil
    harness.timecycleStrength = nil
    harness.lastPtfxAsset = nil
    -- Ped appearance, vehicle state, and the world signals the firefighter
    -- job's incident detectors read.
    harness.pedOutfit = { components = {}, props = {} }
    harness.pedGender = 'male'
    harness.pedVehicle = 0
    harness.pedDown = false
    harness.ragdolled = false
    harness.camShake = nil
    harness.vehicleSpeed = 0.0
    harness.vehicleCollided = false
    harness.entityOnFire = {}
    harness.engineHealth = 1000.0
    harness.vehicleDamage = {}
    harness.seethrough = false
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
function _G.GetEntityCoords(entity)
    local coords = entity ~= nil and harness.entityCoords[entity]
    if coords then return coords end
    return harness.playerCoords or vector3(0.0, 0.0, 0.0)
end
function _G.DrawMarker(kind, x, y, z)
    table.insert(harness.drawnMarkers, { kind = kind, coords = vector3(x, y, z) })
end
function _G.BeginTextCommandDisplayHelp() end
function _G.AddTextComponentSubstringPlayerName(text) table.insert(harness.helpText, text) end
function _G.EndTextCommandDisplayHelp() end
function _G.IsControlJustReleased(_, key) return harness.controlsReleased[key] == true end
function _G.IsControlJustPressed(_, key) return harness.controlsPressed[key] == true end
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
    -- Shared scripts that sit between the bridge and the modules, matching the
    -- shared_scripts order in fxmanifest.lua.
    for _, file in ipairs(opts.shared or {}) do harness.load(file) end
    -- A last chance to change config before anything reads it, which is what a
    -- server owner editing config.lua actually does.
    if opts.configure then opts.configure(_G.Config) end
    harness.load('bridge/server.lua')
    for _, adapter in ipairs(opts.adapters or { 'standalone' }) do
        harness.load('bridge/server/' .. adapter .. '.lua')
    end
    for _, module in ipairs(opts.modules or {}) do
        harness.load('modules/' .. module .. '/server.lua')
    end
    for _, file in ipairs(opts.files or {}) do
        harness.load(file)
    end
    return _G.DAG
end

function harness.loadClient(opts)
    opts = opts or {}
    harness.loadConfig()
    harness.load('bridge/shared.lua')
    for _, file in ipairs(opts.shared or {}) do harness.load(file) end
    if opts.configure then opts.configure(_G.Config) end
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

-- Entity, blip, fire, and ped natives -------------------------------------
--
-- The firefighter job reads the world through these on both sides: the server
-- checks where a player and their apparatus really are, and the client renders
-- fires, victims, and blips from what dispatch reports.

local function newEntity(model, coords)
    harness.nextEntity = harness.nextEntity + 1
    local entity = harness.nextEntity
    harness.entities[entity] = true
    harness.entityModels[entity] = model
    if coords then harness.entityCoords[entity] = coords end
    return entity
end

harness.newEntity = newEntity

-- Places a player's ped in the world so server-side distance checks resolve.
function harness.placePlayer(playerSource, coords)
    local ped = harness.playerPeds[playerSource]
    if not ped then
        ped = newEntity('player', coords)
        harness.playerPeds[playerSource] = ped
    end
    harness.entityCoords[ped] = coords
    return ped
end

function harness.registerNetworkedEntity(netId, entity)
    harness.netIds[netId] = entity
    return entity
end

function _G.GetPlayerPed(playerSource) return harness.playerPeds[playerSource] or 0 end
-- Server-side player list. Defaults to whoever has been placed in the world.
function _G.GetPlayers()
    if harness.players then
        local list = {}
        for index, playerSource in ipairs(harness.players) do list[index] = tostring(playerSource) end
        return list
    end

    local list = {}
    for playerSource in pairs(harness.playerPeds) do list[#list + 1] = tostring(playerSource) end
    table.sort(list)
    return list
end
function _G.DoesEntityExist(entity) return harness.entities[entity] == true end
function _G.DeleteEntity(entity)
    harness.entities[entity] = nil
    harness.entityCoords[entity] = nil
end
function _G.GetEntityModel(entity) return harness.entityModels[entity] end
function _G.GetEntityHeading(entity) return harness.entityHeadings[entity] or 0.0 end
function _G.GetHashKey(value) return value end
function _G.SetModelAsNoLongerNeeded() end
function _G.RequestModel() end
function _G.HasModelLoaded() return harness.modelsLoaded == true end
function _G.RequestAnimDict() end
function _G.HasAnimDictLoaded() return harness.animDictsLoaded == true end
function _G.RequestNamedPtfxAsset() end
function _G.HasNamedPtfxAssetLoaded() return harness.ptfxLoaded == true end
function _G.UseParticleFxAssetNextCall(asset) harness.lastPtfxAsset = asset end
function _G.StartParticleFxNonLoopedAtCoord(effect, x, y, z, _, _, _, scale)
    table.insert(harness.particles, { effect = effect, coords = vector3(x, y, z), scale = scale, looped = false })
end
function _G.StartParticleFxLoopedAtCoord(effect, x, y, z, _, _, _, scale)
    harness.nextParticle = harness.nextParticle + 1
    table.insert(harness.particles, {
        effect = effect, coords = vector3(x, y, z), scale = scale, looped = true, handle = harness.nextParticle
    })
    return harness.nextParticle
end
function _G.StopParticleFxLooped(handle)
    for index, entry in ipairs(harness.particles) do
        if entry.handle == handle then table.remove(harness.particles, index) return end
    end
end
function _G.SetTimecycleModifier(name) harness.timecycle = name end
function _G.SetTimecycleModifierStrength(strength) harness.timecycleStrength = strength end
function _G.ClearTimecycleModifier() harness.timecycle = nil end
function _G.PlaySoundFrontend(_, name, ref)
    table.insert(harness.sounds, { name = name, ref = ref })
end
function _G.PlaySoundFromCoord(_, name, x, y, z, ref)
    table.insert(harness.sounds, { name = name, ref = ref, coords = vector3(x, y, z) })
end
function _G.GetPedBoneCoords() return harness.playerCoords or vector3(0.0, 0.0, 0.0) end

function _G.NetworkGetEntityFromNetworkId(netId) return harness.netIds[netId] or 0 end
function _G.NetworkGetNetworkIdFromEntity(entity)
    harness.netIds[entity] = entity
    return entity
end

function _G.CreateVehicle(model, x, y, z)
    return newEntity(model, vector3(x, y, z))
end
function _G.CreatePed(_, model, x, y, z)
    return newEntity(model, vector3(x, y, z))
end
function _G.SetVehicleOnGroundProperly() end
function _G.SetVehicleEngineOn() end
function _G.SetVehicleNumberPlateText() end
function _G.SetEntityAsMissionEntity() end
function _G.SetEntityInvincible() end
function _G.SetBlockingOfNonTemporaryEvents() end
function _G.FreezeEntityPosition() end
function _G.TaskWarpPedIntoVehicle() end
function _G.GetPedBoneIndex() return 0 end
function _G.AttachEntityToEntity(entity, target)
    harness.attachments[entity] = target
end
function _G.DetachEntity(entity) harness.attachments[entity] = nil end
function _G.TaskPlayAnim(entity, dictionary, animation)
    table.insert(harness.animations, { entity = entity, dict = dictionary, anim = animation })
end
function _G.ClearPedTasks(entity)
    table.insert(harness.animations, { entity = entity, cleared = true })
end

function _G.GetEntityHealth(entity) return harness.entityHealth[entity] or 200 end
function _G.SetEntityHealth(entity, health) harness.entityHealth[entity] = health end

function _G.GetEntityForwardVector()
    local forward = harness.forwardVector
    return vector3(forward.x, forward.y, forward.z)
end
function _G.IsPedShooting() return harness.pedShooting == true end
function _G.GiveWeaponToPed(ped, weapon) harness.weapons[ped] = weapon end
function _G.RemoveWeaponFromPed(ped) harness.weapons[ped] = nil end
function _G.SetCurrentPedWeapon() end
function _G.GetClosestObjectOfType() return harness.closestObject or 0 end

function _G.StartScriptFire(x, y, z, children)
    local handle = harness.nextFire
    harness.nextFire = harness.nextFire + 1
    harness.scriptFires[handle] = { coords = vector3(x, y, z), children = children }
    return handle
end
function _G.RemoveScriptFire(handle) harness.scriptFires[handle] = nil end

function _G.AddBlipForCoord(x, y, z)
    local handle = harness.nextBlip
    harness.nextBlip = harness.nextBlip + 1
    harness.blips[handle] = { coords = vector3(x, y, z) }
    return handle
end
function _G.RemoveBlip(handle) harness.blips[handle] = nil end
local function blipField(field)
    return function(handle, value)
        if harness.blips[handle] then harness.blips[handle][field] = value end
    end
end
_G.SetBlipSprite = blipField('sprite')
_G.SetBlipColour = blipField('colour')
_G.SetBlipScale = blipField('scale')
_G.SetBlipAsShortRange = blipField('shortRange')
_G.SetBlipFlashes = blipField('flashing')
_G.SetBlipRoute = blipField('route')
function _G.BeginTextCommandSetBlipName() end
function _G.EndTextCommandSetBlipName(handle)
    if harness.blips[handle] then harness.blips[handle].named = true end
end
function _G.SetNewWaypoint(x, y) table.insert(harness.waypoints, { x = x, y = y }) end
function _G.RegisterKeyMapping(command) table.insert(harness.keyMappings, command) end

function _G.SetTextFont() end
function _G.SetTextScale() end
function _G.SetTextColour() end
function _G.SetTextOutline() end
function _G.BeginTextCommandDisplayText() end
function _G.EndTextCommandDisplayText() end
function _G.DrawRect(x, y, width, height)
    table.insert(harness.drawnRects, { x = x, y = y, width = width, height = height })
end

-- Ped appearance ------------------------------------------------------------

function _G.IsPedMale() return harness.pedGender ~= 'female' end
function _G.GetPedDrawableVariation(_, slot) return (harness.pedOutfit.components[slot] or { 0, 0 })[1] end
function _G.GetPedTextureVariation(_, slot) return (harness.pedOutfit.components[slot] or { 0, 0 })[2] end
function _G.SetPedComponentVariation(_, slot, drawable, texture)
    harness.pedOutfit.components[slot] = { drawable, texture }
end
function _G.GetPedPropIndex(_, slot) return (harness.pedOutfit.props[slot] or { -1, 0 })[1] end
function _G.GetPedPropTextureIndex(_, slot) return (harness.pedOutfit.props[slot] or { -1, 0 })[2] end
function _G.SetPedPropIndex(_, slot, drawable, texture)
    harness.pedOutfit.props[slot] = { drawable, texture }
end
function _G.ClearPedProp(_, slot) harness.pedOutfit.props[slot] = { -1, 0 } end
function _G.SetSeethrough(value) harness.seethrough = value == true end

-- Objects, vehicles, and the signals the incident detectors read -------------

function _G.CreateObject(model, x, y, z)
    return newEntity(model, vector3(x, y, z))
end
function _G.PlaceObjectOnGroundProperly() end
function _G.SetEntityCollision() end
function _G.NetworkDoesNetworkIdExist(netId) return harness.netIds[netId] ~= nil end

function _G.GetVehiclePedIsIn() return harness.pedVehicle or 0 end
function _G.IsPedInAnyVehicle() return (harness.pedVehicle or 0) ~= 0 end
function _G.GetEntitySpeed() return harness.vehicleSpeed or 0.0 end
function _G.HasEntityCollidedWithAnything() return harness.vehicleCollided == true end
function _G.IsEntityOnFire(entity) return harness.entityOnFire[entity] == true end
function _G.GetVehicleEngineHealth() return harness.engineHealth or 1000.0 end
function _G.IsPedDeadOrDying() return harness.pedDown == true end
function _G.DisableControlAction() end
function _G.SetPedToRagdoll() harness.ragdolled = true end
function _G.ShakeGameplayCam(name, amount) harness.camShake = { name = name, amount = amount } end

local function damage(field)
    return function(vehicle, index)
        harness.vehicleDamage[vehicle] = harness.vehicleDamage[vehicle] or {}
        local record = harness.vehicleDamage[vehicle]
        record[field] = record[field] or {}
        table.insert(record[field], index or true)
    end
end
_G.SetVehicleDoorBroken = damage('doors')
_G.SmashVehicleWindow = damage('windows')
function _G.SetVehicleBodyHealth() end
function _G.SetVehicleEngineHealth() end
function _G.SetVehicleDeformationFixed() end

-- Counts entries in a harness table keyed by handle rather than by index.
function harness.count(collection)
    local total = 0
    for _ in pairs(collection) do total = total + 1 end
    return total
end

harness.reset()
return harness
