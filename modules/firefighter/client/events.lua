-- Turning what players actually do into calls.
--
-- This half only notices things: a car alight, a heavy impact, somebody down.
-- It reports them and the server decides where they happened, whether they are
-- worth a call, and which department owns it. Nothing here is trusted, which
-- is why none of it sends a coordinate.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Events = {}
Fire.Events = Events

local reported = {}
local lastSpeed, lastVehicle = 0.0, 0

local function settings()
    return Shared.Settings().events or {}
end

local function enabled(name)
    local config = settings()[name]
    return type(config) == 'table' and config.enabled ~= false and config or nil
end

-- A local cooldown as well as the server's, so a burning car does not send a
-- report every tick it is on fire. Nothing reported yet is not the same as
-- reported at time zero, which would swallow everything in the first two
-- minutes of a session.
local function throttle(key, window)
    local now = GetGameTimer()
    local last = reported[key]
    if last and now - last < (window or 60000) then return false end
    reported[key] = now
    return true
end

local function ped()
    return PlayerPedId()
end

-- Detection ------------------------------------------------------------------

function Events.CheckVehicleFire()
    if not enabled('vehicleFire') then return false end

    local player = ped()
    local vehicle = GetVehiclePedIsIn(player, false)
    if not vehicle or vehicle == 0 then
        -- A car the player just got out of still counts while they are next to it.
        vehicle = lastVehicle
    end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local alight = IsEntityOnFire(vehicle) or GetVehicleEngineHealth(vehicle) <= -3999.0
    if not alight then return false end
    if not throttle('vehicle', 120000) then return false end

    TriggerServerEvent(Bridge.Event('fire:vehicleFire'))
    return true
end

-- A collision is a speed the player had a moment ago and does not have now.
function Events.CheckCollision()
    local config = enabled('collision')
    if not config then return false end

    local player = ped()
    local vehicle = GetVehiclePedIsIn(player, false)
    if not vehicle or vehicle == 0 then
        lastSpeed = 0.0
        return false
    end

    local speed = GetEntitySpeed(vehicle)
    local delta = lastSpeed - speed
    lastSpeed, lastVehicle = speed, vehicle

    if delta < (tonumber(config.minimumSpeed) or 22.0) then return false end
    if not HasEntityCollidedWithAnything(vehicle) then return false end
    if not throttle('collision', 120000) then return false end

    TriggerServerEvent(Bridge.Event('fire:collision'), delta)
    return true
end

function Events.CheckDown()
    if not enabled('playerDown') then return false end

    local player = ped()
    if not IsPedDeadOrDying(player, true) then return false end
    if not throttle('down', 300000) then return false end

    TriggerServerEvent(Bridge.Event('fire:down'))
    return true
end

function Events.Report(kind)
    TriggerServerEvent(Bridge.Event('fire:report'), kind)
end

-- Threads ---------------------------------------------------------------------

-- Collision detection needs every frame to see the speed drop; the rest is
-- checked on a slow beat.
CreateThread(function()
    while true do
        if enabled('collision') then Events.CheckCollision() end
        Wait(0)
    end
end)

CreateThread(function()
    while true do
        Events.CheckVehicleFire()
        Events.CheckDown()
        Wait(2000)
    end
end)
