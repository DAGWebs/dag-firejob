-- Hose lines.
--
-- An attack line is pulled off a pump and walked out: the props are laid
-- behind the firefighter as they move, and the server refuses water once they
-- are past the end of it. A supply line runs hydrant to pump and is what stops
-- the tank going down.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Hose = {}
Fire.Hose = Hose

local attack, supply = nil, nil

local function settings()
    return Shared.Settings().hose or {}
end

local function ped()
    return PlayerPedId()
end

local function coordsOf(entity)
    return Shared.Coords(GetEntityCoords(entity))
end

-- Props ---------------------------------------------------------------------

local function layProp(coords)
    local model = GetHashKey(settings().prop or 'prop_fire_hose')
    if not HasModelLoaded(model) then
        RequestModel(model)
        return nil
    end

    local object = CreateObject(model, coords.x, coords.y, coords.z - 0.95, false, false, false)
    if not object or object == 0 then return nil end

    PlaceObjectOnGroundProperly(object)
    FreezeEntityPosition(object, true)
    SetEntityCollision(object, false, false)
    return object
end

local function clearProps(line)
    for _, object in ipairs(line and line.props or {}) do
        if DoesEntityExist(object) then DeleteEntity(object) end
    end
end

-- Attack line ---------------------------------------------------------------

function Hose.Line()
    return attack
end

function Hose.Deployed()
    return attack ~= nil
end

function Hose.Deploy(unitSource)
    if attack then return false end
    TriggerServerEvent(Bridge.Event('fire:deployLine'), unitSource)
    return true
end

function Hose.Stow()
    if not attack then return false end
    TriggerServerEvent(Bridge.Event('fire:stowLine'))
    return true
end

-- Lays another length of hose when the firefighter has moved far enough from
-- the last one. This is the whole trick: the line is a trail, not a rope.
function Hose.Step()
    if not attack then return 0 end

    local here = coordsOf(ped())
    if not here then return #attack.props end

    local segment = tonumber(settings().segment) or 3.5
    local from = attack.last or attack.origin
    if Shared.Distance(here, from) < segment then return #attack.props end

    local object = layProp(here)
    if object then
        attack.props[#attack.props + 1] = object
        attack.last = here
    end
    return #attack.props
end

-- How far past the end of the line the nozzle is, as a fraction. The HUD warns
-- on it before the server starts refusing water.
function Hose.Stretch()
    if not attack or not attack.origin then return 0 end

    local here = coordsOf(ped())
    if not here then return 0 end

    local length = tonumber(settings().attackLength) or 38.0
    return Shared.Clamp(Shared.Distance(here, attack.origin) / length, 0, 2)
end

RegisterNetEvent(Bridge.Event('fire:lineDeployed'), function(line)
    local unit = Client.Unit()
    local origin = coordsOf(ped())

    -- The line starts at the pump when we can see it, and at our feet when we
    -- cannot, so the stretch warning is never wildly wrong.
    if line and line.netId then
        local entity = NetworkDoesNetworkIdExist(line.netId) and NetworkGetEntityFromNetworkId(line.netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then origin = coordsOf(entity) end
    end

    attack = { props = {}, origin = origin, last = origin, unit = line and line.unit or nil, netId = unit and unit.netId }
    Bridge.Notify('Line charged. Walk it in.', 'success', 4000)
end)

RegisterNetEvent(Bridge.Event('fire:lineStowed'), function()
    clearProps(attack)
    attack = nil
end)

-- Supply line ---------------------------------------------------------------

function Hose.Supplied()
    local unit = Client.Unit()
    return unit ~= nil and unit.supplied == true
end

function Hose.ConnectSupply()
    local unit = Client.Unit()
    if not unit then
        Bridge.Notify('You do not have an apparatus signed out.', 'error')
        return false
    end

    local here = coordsOf(ped())
    local hydrant = here and Fire.Suppression.NearestHydrant(here)
    if not hydrant then
        Bridge.Notify('No hydrant within reach.', 'error')
        return false
    end

    TriggerServerEvent(Bridge.Event('fire:connectSupply'), hydrant)
    supply = { hydrant = hydrant, props = {} }
    return true
end

function Hose.DisconnectSupply()
    clearProps(supply)
    supply = nil
    TriggerServerEvent(Bridge.Event('fire:disconnectSupply'))
    return true
end

-- Lays the supply line between the hydrant and the pump once, when the server
-- confirms the connection.
function Hose.DrawSupply()
    if not supply or #supply.props > 0 or not Hose.Supplied() then return false end

    local unit = Client.Unit()
    local entity = unit and unit.netId and NetworkDoesNetworkIdExist(unit.netId)
        and NetworkGetEntityFromNetworkId(unit.netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end

    local from, to = supply.hydrant, coordsOf(entity)
    local span = Shared.Distance(from, to)
    local segment = tonumber(settings().segment) or 3.5
    local steps = math.max(1, math.floor(span / segment))

    for step = 0, steps do
        local ratio = step / steps
        local object = layProp({
            x = from.x + (to.x - from.x) * ratio,
            y = from.y + (to.y - from.y) * ratio,
            z = from.z + (to.z - from.z) * ratio
        })
        if object then supply.props[#supply.props + 1] = object end
    end
    return true
end

function Hose.Clear()
    clearProps(attack)
    clearProps(supply)
    attack, supply = nil, nil
end

-- Threads --------------------------------------------------------------------

CreateThread(function()
    while true do
        local active = false
        if Client.OnDuty() then
            if attack then
                active = true
                Hose.Step()
            end
            Hose.DrawSupply()
        end
        Wait(active and 250 or 1000)
    end
end)

AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    if reason == 'duty' and not Client.OnDuty() then Hose.Clear() end
    if reason == 'unit' and not Client.Unit() then Hose.Clear() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    Hose.Clear()
end)
