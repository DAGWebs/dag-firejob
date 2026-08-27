-- Fire rendering, suppression input, heat, and SCBA air.
--
-- The thread bodies here are deliberately thin: each one loops over a named
-- step function so the behaviour can be exercised without a game running.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Suppression = {}
Fire.Suppression = Suppression

local EXTINGUISHER = 'WEAPON_FIREEXTINGUISHER'
local handles, activeAgent, lastReport = {}, nil, 0
local lastAirReport, airReported = 0, 0

local function fireSettings()
    return Shared.Settings().fire or {}
end

local function ped()
    return PlayerPedId()
end

local function myServerId()
    return GetPlayerServerId(PlayerId())
end

-- Rendering ----------------------------------------------------------------

-- Script fires are networked by the engine, so exactly one client renders each
-- call. The server names that client; everyone else just sees the result.
local function ownedCalls()
    local mine, id = {}, myServerId()
    for _, call in pairs(Client.Calls()) do
        if call.owner == id then mine[call.id] = call end
    end
    return mine
end

local function key(callId, nodeId)
    return ('%s/%s'):format(callId, nodeId)
end

local function extinguish(handleKey)
    local handle = handles[handleKey]
    if not handle then return end
    RemoveScriptFire(handle)
    handles[handleKey] = nil
end

-- Reconciles the fires this client owns with the nodes the server reports.
function Suppression.RenderStep()
    local mine = ownedCalls()
    local wanted = {}

    for callId, call in pairs(mine) do
        for nodeId, node in pairs(call.fires or {}) do
            local handleKey = key(callId, nodeId)
            wanted[handleKey] = true
            if not handles[handleKey] and (node.intensity or 0) > 0 then
                local coords = node.coords
                -- maxChildren scales with intensity so a fully involved room
                -- looks like one, and a smouldering node does not.
                local children = math.max(1, math.floor((node.intensity or 0) / 20))
                handles[handleKey] = StartScriptFire(coords.x, coords.y, coords.z, children, false)
            end
        end
    end

    for handleKey in pairs(handles) do
        if not wanted[handleKey] then extinguish(handleKey) end
    end
end

function Suppression.ClearRendered()
    for handleKey in pairs(handles) do extinguish(handleKey) end
end

function Suppression.RenderedCount()
    local count = 0
    for _ in pairs(handles) do count = count + 1 end
    return count
end

-- Gear ---------------------------------------------------------------------

-- Which nozzle is in the firefighter's hands. The agent decides reach, flow,
-- and which supply the server bills.
function Suppression.Agent()
    return activeAgent
end

function Suppression.Equip(agent)
    local definition = Shared.Agent(agent)
    if not definition then return false end
    activeAgent = agent

    -- A hose is not a thing you hold, it is a line you pull off a pump. The
    -- server decides whether there is one to pull.
    if definition.needsLine and Fire.Hose and not Fire.Hose.Deployed() then
        Fire.Hose.Deploy()
    end

    local player = ped()
    GiveWeaponToPed(player, GetHashKey(EXTINGUISHER), 4000, false, true)
    SetCurrentPedWeapon(player, GetHashKey(EXTINGUISHER), true)
    return true
end

function Suppression.Stow()
    local definition = activeAgent and Shared.Agent(activeAgent)
    activeAgent = nil

    if definition and definition.needsLine and Fire.Hose and Fire.Hose.Deployed() then
        Fire.Hose.Stow()
    end
    RemoveWeaponFromPed(ped(), GetHashKey(EXTINGUISHER))
    return true
end

function Suppression.Toggle(agent)
    if activeAgent == agent then return Suppression.Stow() end
    return Suppression.Equip(agent)
end

-- Thermal imaging. Cheap to implement, and the only way to find a patient in a
-- room full of smoke.
local thermal = false

function Suppression.Thermal()
    return thermal
end

function Suppression.ToggleThermal()
    thermal = not thermal
    SetSeethrough(thermal)
    return thermal
end

-- Aiming -------------------------------------------------------------------

-- A node counts as targeted when it is in range and roughly in front of the
-- firefighter. A cone beats a raycast here: fire particles do not have a
-- collider worth hitting, and a wide cone is what a hose stream behaves like.
function Suppression.Target(origin, forward, range)
    local best, bestCall, bestScore
    for _, entry in ipairs(Client.NodesNear(origin, range)) do
        local node = entry.node
        local dx, dy = node.coords.x - origin.x, node.coords.y - origin.y
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0.01 then
            local dot = (dx / length) * forward.x + (dy / length) * forward.y
            -- cos(50 degrees); wide enough to be usable, narrow enough that a
            -- firefighter cannot spray a fire behind them.
            if dot >= 0.64 then
                local score = dot - (length / range) * 0.35
                if not bestScore or score > bestScore then
                    best, bestCall, bestScore = node, entry.call, score
                end
            end
        end
    end
    return best, bestCall
end

-- Suppression --------------------------------------------------------------

local function forwardVector(entity)
    local vector = GetEntityForwardVector(entity)
    return { x = vector.x, y = vector.y, z = vector.z }
end

-- One spray tick. Returns the node that was reported so a test (or the HUD)
-- can see what happened.
function Suppression.SprayStep()
    if not activeAgent or not Client.OnDuty() then return nil end

    -- Nothing to report when the line has not been charged yet; the server
    -- would refuse it anyway.
    local definition = Shared.Agent(activeAgent)
    if definition and definition.needsLine and not Client.HasLine() then return nil end

    local player = ped()
    if not IsPedShooting(player) then return nil end

    local now = GetGameTimer()
    local interval = tonumber(fireSettings().reportInterval) or 400
    if now - lastReport < interval then return nil end

    local agent = Shared.Agent(activeAgent)
    if not agent then return nil end

    local origin = Shared.Coords(GetEntityCoords(player))
    local node, call = Suppression.Target(origin, forwardVector(player), tonumber(agent.range) or 12.0)
    if not node or not call then return nil end

    lastReport = now
    local litres = (tonumber(agent.flow) or 40) * (interval / 1000)
    TriggerServerEvent(Bridge.Event('fire:water'), call.id, node.id, litres, activeAgent)

    -- Local feedback only: the server decides what the water actually did.
    Suppression.Steam(node)
    return node, call
end

function Suppression.Steam(node)
    if not node or not node.coords then return end
    if not HasNamedPtfxAssetLoaded('core') then
        RequestNamedPtfxAsset('core')
        return
    end
    UseParticleFxAssetNextCall('core')
    StartParticleFxNonLoopedAtCoord('ent_amb_steam_ground', node.coords.x, node.coords.y, node.coords.z + 0.4,
        0.0, 0.0, 0.0, 1.4, false, false, false)
end

-- Heat and air -------------------------------------------------------------

-- Turnout gear and a charged cylinder are the difference between working a
-- room and being carried out of it.
function Suppression.Protection()
    local heat = (fireSettings().heat or {})
    if Client.OnDuty() and Client.Air() > 0 then return tonumber(heat.gearMultiplier) or 0.3 end
    return 1.0
end

function Suppression.HeatStep()
    local player = ped()
    local coords = Shared.Coords(GetEntityCoords(player))
    if not coords then return 0 end

    local heat = Client.HeatAt(coords)
    if heat <= 0 then return 0 end

    local config = (fireSettings().heat or {})
    local damage = math.floor((tonumber(config.damage) or 6) * Suppression.Protection() * math.min(2.0, heat / 60))
    if damage <= 0 then return 0 end

    SetEntityHealth(player, math.max(0, GetEntityHealth(player) - damage))
    return damage
end

-- Air is spent locally because only the client knows what the firefighter is
-- standing in; the server keeps the authoritative figure and is told in
-- batches rather than every tick.
function Suppression.AirStep()
    if not Client.OnDuty() then return 0 end

    local scba = Shared.Settings().scba or {}
    local coords = Shared.Coords(GetEntityCoords(ped()))
    local inSmoke = #Client.NodesNear(coords, tonumber(scba.smokeRadius) or 8.0) > 0
    local drain = inSmoke and (tonumber(scba.drainInSmoke) or 4) or (tonumber(scba.drain) or 1)

    airReported = airReported + drain

    local now = GetGameTimer()
    if now - lastAirReport >= 3000 and airReported > 0 then
        TriggerServerEvent(Bridge.Event('fire:air'), airReported)
        lastAirReport, airReported = now, 0
    end

    local air = Client.Air()
    if inSmoke and air > 0 and air <= (tonumber(scba.warnAt) or 300) then
        Bridge.Notify('Low air. Leave the structure.', 'error', 4000)
    end
    return drain
end

-- Hydrants -----------------------------------------------------------------

function Suppression.NearestHydrant(coords)
    local water = Shared.Settings().water or {}
    local reach = tonumber(water.hydrantDistance) or 4.0

    for _, model in ipairs(water.hydrantModels or {}) do
        local object = GetClosestObjectOfType(coords.x, coords.y, coords.z, reach, GetHashKey(model), false, false, false)
        if object and object ~= 0 then
            return Shared.Coords(GetEntityCoords(object)), object
        end
    end
    return nil
end

-- Threads ------------------------------------------------------------------

CreateThread(function()
    while true do
        if Client.OnDuty() then Suppression.RenderStep() end
        Wait(1500)
    end
end)

CreateThread(function()
    while true do
        local sleep = 500
        if Client.OnDuty() and activeAgent then
            sleep = 0
            Suppression.SprayStep()
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    local heat = (fireSettings().heat or {})
    while true do
        if Client.OnDuty() then Suppression.HeatStep() end
        Wait(tonumber(heat.interval) or 1500)
    end
end)

CreateThread(function()
    while true do
        Suppression.AirStep()
        Wait(1000)
    end
end)

-- Going off duty puts every fire this client was rendering back in the
-- server's hands rather than leaving orphaned handles burning.
AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    if reason ~= 'duty' or Client.OnDuty() then return end
    Suppression.ClearRendered()
    Suppression.Stow()
    if thermal then Suppression.ToggleThermal() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    Suppression.ClearRendered()
end)
