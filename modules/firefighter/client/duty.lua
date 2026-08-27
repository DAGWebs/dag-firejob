-- Station life: the duty point, the locker, the supply cache, the garage, and
-- the hydrant a pump can draw from.
--
-- Every station fixture is a DAG.Interactions entry, so a server that runs a
-- target resource can swap the whole lot out by re-registering them without
-- touching the rest of the job.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Suppression = Fire.Suppression
local Duty = {}
Fire.Duty = Duty

local prefix = Shared.Settings().commandPrefix or Bridge.namespace

local function menuId(name)
    return ('%s:fire:%s'):format(Bridge.namespace, name)
end

Duty.MenuId = menuId

-- Station fixtures ----------------------------------------------------------
--
-- A station's fixtures are lists, not single points: a hall can have two duty
-- boards, three bay doors, and a locker room at each end. Everything is
-- registered from the current config and can be torn down and rebuilt, so the
-- in-game editor takes effect without a restart.

local fixtures, stationBlips = {}, {}

local function register(id, entry)
    entry.id = id
    fixtures[id] = true
    DAG.Interactions.Register(entry)
end

local function fixtureId(kind, stationId, index)
    return ('%s:%s:%s:%d'):format(Bridge.namespace, kind, stationId, index)
end

local function clearFixtures()
    for id in pairs(fixtures) do DAG.Interactions.Remove(id) end
    for _, blip in ipairs(stationBlips) do RemoveBlip(blip) end
    fixtures, stationBlips = {}, {}
end

local function registerStation(station)
    for index, point in ipairs(Shared.Points(station, 'duty')) do
        register(fixtureId('duty', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ to clock on or off',
            distance = 2.0,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:toggleDuty')) end
        })
    end

    for index, point in ipairs(Shared.Points(station, 'locker')) do
        register(fixtureId('locker', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ to open the equipment locker',
            distance = 2.0,
            canInteract = function() return Client.OnDuty() end,
            menu = menuId('locker')
        })
    end

    for index, point in ipairs(Shared.Points(station, 'supply')) do
        register(fixtureId('supply', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ to restock air and extinguishers',
            distance = 2.0,
            canInteract = function() return Client.OnDuty() end,
            onSelect = function()
                TriggerServerEvent(Bridge.Event('fire:refillGear'), 'air')
                TriggerServerEvent(Bridge.Event('fire:refillGear'), 'extinguisher')
            end
        })
    end

    for index, point in ipairs(Shared.Points(station, 'garage')) do
        register(fixtureId('garage', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ for the apparatus bay',
            distance = 3.0,
            canInteract = function() return Client.OnDuty() end,
            onSelect = function() Duty.OpenGarage(station.id) end
        })
    end

    for index, point in ipairs(Shared.Points(station, 'office')) do
        register(fixtureId('office', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ for the watch office',
            distance = 2.0,
            canInteract = function() return Client.OnDuty() end,
            onSelect = function()
                if Fire.Menus then Fire.Menus.OpenCommand() end
            end
        })
    end

    for index, point in ipairs(Shared.Points(station, 'ret')) do
        register(fixtureId('return', station.id, index), {
            coords = point,
            label = 'Press ~INPUT_CONTEXT~ to return the apparatus',
            distance = 4.0,
            canInteract = function() return Client.Unit() ~= nil end,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:returnUnit')) end
        })
    end

    local blip = station.blip
    local coords = Shared.Coords(station.coords)
    if blip and coords then
        local handle = AddBlipForCoord(coords.x, coords.y, coords.z)
        SetBlipSprite(handle, blip.sprite or 436)
        SetBlipColour(handle, blip.colour or 49)
        SetBlipScale(handle, blip.scale or 0.8)
        SetBlipAsShortRange(handle, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(station.label or station.id)
        EndTextCommandSetBlipName(handle)
        stationBlips[#stationBlips + 1] = handle
    end
end

-- Rebuilt from scratch every time, so an edited config never leaves a prompt
-- floating where a bay door used to be.
function Duty.RegisterFixtures()
    clearFixtures()
    if not Shared.Enabled() then return 0 end

    for _, station in ipairs(Shared.Stations()) do registerStation(station) end

    local count = 0
    for _ in pairs(fixtures) do count = count + 1 end
    return count
end

function Duty.Fixtures()
    return fixtures
end

CreateThread(function()
    Duty.RegisterFixtures()
end)

AddEventHandler(Bridge.Event('fire:configChanged'), function()
    Duty.RegisterFixtures()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    clearFixtures()
end)

-- Apparatus -----------------------------------------------------------------

function Duty.OpenGarage(stationId)
    Duty.station = stationId
    DAG.Menu.Open(menuId('garage'))
end

function Duty.RequestUnit(apparatusId, stationId)
    TriggerServerEvent(Bridge.Event('fire:requestUnit'), apparatusId, stationId or Duty.station)
end

-- The server has authorized this apparatus; create it and report the network
-- id back so the tank is registered against an entity the server can see.
RegisterNetEvent(Bridge.Event('fire:spawnUnit'), function(apparatusId, stationId)
    local apparatus = Shared.Apparatus(apparatusId)
    local station = Shared.Station(stationId)
    if not apparatus or not station then return end

    local model = GetHashKey(apparatus.model)
    RequestModel(model)

    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(50) end
    if not HasModelLoaded(model) then
        return Bridge.Notify('That apparatus model failed to load.', 'error')
    end

    -- A station can have several bays; the apparatus comes out of whichever
    -- one the firefighter is standing closest to.
    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    local spawn, spawnDistance
    for _, candidate in ipairs(Shared.SpawnPoints(station)) do
        local distance = here and Shared.Distance(here, candidate.coords) or 0
        if not spawnDistance or distance < spawnDistance then spawn, spawnDistance = candidate, distance end
    end
    if not spawn then return Bridge.Notify('That station has no apparatus bay configured.', 'error') end

    local coords = spawn.coords
    local vehicle = CreateVehicle(model, coords.x, coords.y, coords.z, spawn.heading or 0.0, true, false)
    SetModelAsNoLongerNeeded(model)
    if not vehicle or vehicle == 0 then
        return Bridge.Notify('There was no room to bring the apparatus out.', 'error')
    end

    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleNumberPlateText(vehicle, ('FD%03d'):format(math.random(1, 999)))
    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)

    TriggerServerEvent(Bridge.Event('fire:unitSpawned'), apparatusId, NetworkGetNetworkIdFromEntity(vehicle))
end)

-- Hydrants ------------------------------------------------------------------

-- Drawn as a prompt rather than a registered interaction because hydrants are
-- map props: there is no fixed list of coordinates to register.
function Duty.HydrantStep()
    local unit = Client.Unit()
    if not unit or (unit.capacity or 0) <= 0 then return false end

    local coords = Shared.Coords(GetEntityCoords(PlayerPedId()))
    local hydrant = coords and Suppression.NearestHydrant(coords)
    if not hydrant then return false end

    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName((unit.supplied
        and 'Press ~INPUT_CONTEXT~ to top the tank up (%d/%d litres, on the hydrant)'
        or 'Press ~INPUT_CONTEXT~ to lay a supply line (%d/%d litres)')
        :format(math.floor(unit.water or 0), unit.capacity))
    EndTextCommandDisplayHelp(0, false, true, -1)

    if IsControlJustReleased(0, Config.InteractionKey) then
        -- Connecting the supply line is the better move and the one a crew
        -- should reach for, so it is what the prompt does first.
        if Fire.Hose and not Fire.Hose.Supplied() then
            Fire.Hose.ConnectSupply()
        else
            TriggerServerEvent(Bridge.Event('fire:refillTank'), hydrant)
        end
    end
    return true
end

CreateThread(function()
    while true do
        local active = false
        if Client.OnDuty() then active = Duty.HydrantStep() end
        Wait(active and 0 or 750)
    end
end)

-- Menu entry point ----------------------------------------------------------

RegisterCommand(prefix .. ':fdmenu', function()
    if not Shared.Enabled() then return end
    if Fire.Menus then return Fire.Menus.Open() end
    DAG.Menu.Open(menuId('main'))
end, false)

RegisterKeyMapping(prefix .. ':fdmenu', 'Firefighter menu', 'keyboard', 'F6')

RegisterCommand(prefix .. ':fdhose', function()
    if not Client.OnDuty() then return Bridge.Notify('You are not on duty.', 'error') end
    Suppression.Toggle('hose')
end, false)

RegisterCommand(prefix .. ':fd911', function(_, args)
    Fire.Events.Report(args[1] or 'structure')
end, false)
