-- What the job looks and sounds like.
--
-- Everything above this file decides what is true; this decides what it feels
-- like. Particle, sound and timecycle names are all configuration, and
-- anything that will not load is skipped rather than erroring, because an
-- asset name that is wrong on one server should cost that server a nice
-- effect and nothing else.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Effects = {}

local columns, aftermath, loaded = {}, {}, {}
local timecycle, breathAt, beatAt, fireAt = nil, 0, 0, 0

Fire.Effects = Effects

local function settings()
    return Shared.Settings().effects or {}
end

local function enabled()
    return Shared.Enabled() and settings().enabled ~= false
end

-- Assets --------------------------------------------------------------------

-- Requesting an asset is asynchronous, so the first call after a fire starts
-- kicks the load and does nothing. The next one draws.
local function asset(name)
    if not name then return false end
    if loaded[name] then return true end
    if HasNamedPtfxAssetLoaded(name) then
        loaded[name] = true
        return true
    end
    RequestNamedPtfxAsset(name)
    return false
end

Effects.Asset = asset

local function burst(dictionary, effect, coords, scale)
    if not effect or not coords or not asset(dictionary) then return false end
    UseParticleFxAssetNextCall(dictionary)
    StartParticleFxNonLoopedAtCoord(effect, coords.x, coords.y, coords.z,
        0.0, 0.0, 0.0, scale or 1.0, false, false, false)
    return true
end

Effects.Burst = burst

local function loop(dictionary, effect, coords, scale)
    if not effect or not coords or not asset(dictionary) then return nil end
    UseParticleFxAssetNextCall(dictionary)
    local handle = StartParticleFxLoopedAtCoord(effect, coords.x, coords.y, coords.z,
        0.0, 0.0, 0.0, scale or 1.0, false, false, false, false)
    if not handle or handle == 0 then return nil end
    return handle
end

Effects.Loop = loop

local function stop(handle)
    if not handle then return end
    StopParticleFxLooped(handle, false)
end

-- Screen --------------------------------------------------------------------

-- One timecycle at a time, and only ever ours: clearing somebody else's is how
-- a fire script ends up fighting a weather resource.
local function setTimecycle(name, strength)
    if timecycle == name then return end

    if timecycle then ClearTimecycleModifier() end
    timecycle = name
    if not name then return end

    SetTimecycleModifier(name)
    if strength then SetTimecycleModifierStrength(strength) end
end

Effects.SetTimecycle = setTimecycle

function Effects.Timecycle()
    return timecycle
end

local function play(sound)
    if not sound or not (settings().sound or {}).enabled then return false end
    if not sound.audioName or not sound.audioRef then return false end

    local ok = pcall(PlaySoundFrontend, -1, sound.audioName, sound.audioRef, true)
    return ok
end

Effects.Play = play

local function playAt(sound, coords)
    if not sound or not coords or not (settings().sound or {}).enabled then return false end
    if not sound.audioName or not sound.audioRef then return false end

    local ok = pcall(PlaySoundFromCoord, -1, sound.audioName, coords.x, coords.y, coords.z,
        sound.audioRef, false, 60, false)
    return ok
end

-- The stream ------------------------------------------------------------------

-- Drawn from the nozzle to whatever the server was told about, so what the
-- firefighter sees is the same thing the server is scoring.
function Effects.Water(node, agent)
    if not enabled() or not node then return false end

    local water = settings().water or {}
    local ped = PlayerPedId()
    local from = Shared.Coords(GetPedBoneCoords(ped, 28422, 0.0, 0.0, 0.0)) or Shared.Coords(GetEntityCoords(ped))
    local to = node.coords
    if not from or not to then return false end

    -- A line of bursts rather than one at each end, so it reads as a stream
    -- and not as two puffs.
    local steps = math.max(2, math.min(8, math.floor(Shared.Distance(from, to) / 1.5)))
    for step = 1, steps do
        local ratio = step / steps
        burst(water.asset, water.stream, {
            x = from.x + (to.x - from.x) * ratio,
            y = from.y + (to.y - from.y) * ratio,
            z = from.z + (to.z - from.z) * ratio + 0.35 * math.sin(ratio * math.pi)
        }, (tonumber(water.scale) or 1.6) * (agent == 'monitor' and 1.6 or 1.0))
    end

    burst(water.asset, water.steam, to, 1.4)
    return true
end

-- Smoke -----------------------------------------------------------------------

-- How much smoke a point is sitting in, 0 to 1. This is what blinds, what
-- drains the cylinder, and what the thermal camera is for.
function Effects.SmokeAt(coords)
    local smoke = settings().smoke or {}
    local radius = tonumber(smoke.radius) or 9.0
    local total = 0

    for _, entry in ipairs(Client.NodesNear(coords, radius)) do
        local distance = Shared.Distance(coords, entry.node.coords)
        local falloff = 1.0 - Shared.Clamp(distance / radius, 0, 1)
        total = total + ((entry.node.intensity or 0) / 100) * falloff
    end
    return Shared.Clamp(total, 0, 1)
end

-- Every burning node gets smoke, and a call that is going well enough gets a
-- column the rest of the city can see.
function Effects.SmokeStep()
    if not enabled() then return 0 end

    local smoke = settings().smoke or {}
    local ped = PlayerPedId()
    local here = Shared.Coords(GetEntityCoords(ped))
    if not here then return 0 end

    local drawn = 0
    for _, entry in ipairs(Client.NodesNear(here, 60.0)) do
        local node = entry.node
        if (node.intensity or 0) > 5 then
            local shown = burst(smoke.asset, smoke.effect, {
                x = node.coords.x, y = node.coords.y, z = node.coords.z + 0.8
            }, (tonumber(smoke.scale) or 2.5) * ((node.intensity or 0) / 100))
            if shown then drawn = drawn + 1 end
        end
    end

    -- The column is per call, not per node, so a big fire reads as one plume.
    for id, call in pairs(Client.Calls()) do
        local severity = tonumber(call.severity) or 0
        if severity >= (tonumber(smoke.columnAt) or 0.45) and Shared.Distance(here, call.coords) < 400.0 then
            if not columns[id] then
                columns[id] = loop(smoke.asset, smoke.column, {
                    x = call.coords.x, y = call.coords.y, z = call.coords.z + 3.0
                }, (tonumber(smoke.columnScale) or 6.0) * severity)
            end
        elseif columns[id] then
            stop(columns[id])
            columns[id] = nil
        end
    end

    for id, handle in pairs(columns) do
        if not Client.Call(id) then
            stop(handle)
            columns[id] = nil
        end
    end

    return drawn
end

-- Vision ------------------------------------------------------------------------

-- What the firefighter can see, and why. Thermal beats smoke, which is the
-- entire reason to carry the camera.
function Effects.VisionStep()
    if not enabled() then return nil end

    local ped = PlayerPedId()
    local here = Shared.Coords(GetEntityCoords(ped))
    if not here or not Client.OnDuty() then
        setTimecycle(nil)
        return nil
    end

    local air = settings().air or {}
    local scba = Shared.Settings().scba or {}
    local ratio = Client.Air() / math.max(1, tonumber(scba.capacity) or 1500)

    -- Out of air is worse than any amount of smoke.
    if ratio <= (tonumber(air.criticalAt) or 0.1) then
        setTimecycle(air.timecycle, 1.0)
        return 'air'
    end

    if Fire.Suppression and Fire.Suppression.Thermal() then
        setTimecycle(nil)
        return 'thermal'
    end

    local density = Effects.SmokeAt(here)
    if density > 0.15 then
        local smoke = settings().smoke or {}
        setTimecycle(smoke.timecycle, (tonumber(smoke.strength) or 0.85) * density)
        return 'smoke'
    end

    local heat = settings().heat or {}
    if Client.HeatAt(here) > 20 then
        setTimecycle(heat.timecycle, 0.6)
        return 'heat'
    end

    setTimecycle(nil)
    return nil
end

-- Sound --------------------------------------------------------------------------

-- Breathing you can hear is what makes an air gauge mean something. It gets
-- faster as the cylinder empties, and the heartbeat starts when it is nearly
-- gone.
function Effects.AudioStep()
    if not enabled() or not Client.OnDuty() then return nil end

    local air = settings().air or {}
    local scba = Shared.Settings().scba or {}
    local ratio = Client.Air() / math.max(1, tonumber(scba.capacity) or 1500)
    local now = GetGameTimer()
    local played

    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    local inSmoke = here and Effects.SmokeAt(here) > 0.1

    if inSmoke and ratio > 0 then
        local breathing = air.breathing or {}
        local interval = (tonumber(breathing.interval) or 3200) * math.max(0.35, ratio)
        if now - breathAt >= interval then
            breathAt = now
            if play(breathing) then played = 'breathing' end
        end
    end

    if ratio <= (tonumber(air.criticalAt) or 0.1) then
        local beat = air.heartbeat or {}
        if now - beatAt >= (tonumber(beat.interval) or 900) then
            beatAt = now
            if play(beat) then played = 'heartbeat' end
        end
    end

    local fire = (settings().sound or {}).fire
    if fire and here then
        local nearest = select(3, Client.NearestNode(here, 12.0))
        if nearest and now - fireAt >= (tonumber(fire.interval) or 4000) then
            fireAt = now
            playAt(fire, here)
        end
    end

    return played
end

-- Aftermath ------------------------------------------------------------------------

-- A building that burned is still smoking when you drive past later, which is
-- the cheapest way to make the world remember what happened in it.
function Effects.Remember(coords, until_)
    local config = settings().aftermath or {}
    if config.enabled == false or not coords then return false end

    aftermath[#aftermath + 1] = {
        coords = Shared.Coords(coords),
        until_ = until_ or (GetGameTimer() + (tonumber(config.duration) or 900000))
    }
    return true
end

function Effects.AftermathStep()
    local config = settings().aftermath or {}
    if config.enabled == false then return 0 end

    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    local now, drawn = GetGameTimer(), 0

    for index = #aftermath, 1, -1 do
        local scene = aftermath[index]
        if now >= scene.until_ then
            table.remove(aftermath, index)
        elseif here and Shared.Distance(here, scene.coords) < 80.0 then
            burst(config.effect and (settings().smoke or {}).asset or nil, config.effect, {
                x = scene.coords.x, y = scene.coords.y, z = scene.coords.z + 0.5
            }, tonumber(config.scale) or 1.2)
            drawn = drawn + 1
        end
    end
    return drawn
end

function Effects.Aftermath()
    return aftermath
end

function Effects.Clear()
    for id, handle in pairs(columns) do
        stop(handle)
        columns[id] = nil
    end
    setTimecycle(nil)
end

-- Wiring ---------------------------------------------------------------------------

-- A call that closes leaves its mark, and a fire that was actually fought
-- leaves a bigger one.
AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason, payload)
    if reason ~= 'removed' or not payload or not payload.coords then return end
    if payload.kind == 'medical' then return end
    Effects.Remember(payload.coords)
end)

RegisterNetEvent(Bridge.Event('fire:call'), function(call)
    if not call or not enabled() then return end
    -- Only the first time a call appears, so a resync is not a klaxon.
    if Client.Call(call.id) then return end
    play((settings().sound or {}).dispatch)
end)

CreateThread(function()
    while true do
        local sleep = 500
        if enabled() and Client.OnDuty() then
            sleep = 350
            Effects.SmokeStep()
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        Effects.VisionStep()
        Wait(400)
    end
end)

CreateThread(function()
    while true do
        Effects.AudioStep()
        Wait(700)
    end
end)

CreateThread(function()
    while true do
        Effects.AftermathStep()
        Wait(1500)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    Effects.Clear()
end)
