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

local function registerStation(station)
    DAG.Interactions.Register({
        id = ('%s:duty:%s'):format(Bridge.namespace, station.id),
        coords = station.duty or station.coords,
        label = 'Press ~INPUT_CONTEXT~ to clock on or off',
        distance = 2.0,
        onSelect = function() TriggerServerEvent(Bridge.Event('fire:toggleDuty')) end
    })

    DAG.Interactions.Register({
        id = ('%s:locker:%s'):format(Bridge.namespace, station.id),
        coords = station.locker or station.coords,
        label = 'Press ~INPUT_CONTEXT~ to open the equipment locker',
        distance = 2.0,
        canInteract = function() return Client.OnDuty() end,
        menu = menuId('locker')
    })

    DAG.Interactions.Register({
        id = ('%s:supply:%s'):format(Bridge.namespace, station.id),
        coords = station.supply or station.coords,
        label = 'Press ~INPUT_CONTEXT~ to restock air and extinguishers',
        distance = 2.0,
        canInteract = function() return Client.OnDuty() end,
        onSelect = function()
            TriggerServerEvent(Bridge.Event('fire:refillGear'), 'air')
            TriggerServerEvent(Bridge.Event('fire:refillGear'), 'extinguisher')
        end
    })

    DAG.Interactions.Register({
        id = ('%s:garage:%s'):format(Bridge.namespace, station.id),
        coords = station.garage or station.coords,
        label = 'Press ~INPUT_CONTEXT~ for the apparatus bay',
        distance = 3.0,
        canInteract = function() return Client.OnDuty() end,
        onSelect = function() Duty.OpenGarage(station.id) end
    })

    if station.office then
        DAG.Interactions.Register({
            id = ('%s:office:%s'):format(Bridge.namespace, station.id),
            coords = station.office,
            label = 'Press ~INPUT_CONTEXT~ for the watch office',
            distance = 2.0,
            canInteract = function() return Client.OnDuty() end,
            onSelect = function()
                if Fire.Menus then Fire.Menus.OpenCommand() end
            end
        })
    end

    if station.ret then
        DAG.Interactions.Register({
            id = ('%s:return:%s'):format(Bridge.namespace, station.id),
            coords = station.ret,
            label = 'Press ~INPUT_CONTEXT~ to return the apparatus',
            distance = 4.0,
            canInteract = function() return Client.Unit() ~= nil end,
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:returnUnit')) end
        })
    end
end

CreateThread(function()
    if not Shared.Enabled() then return end

    for _, station in ipairs(Shared.Stations()) do
        registerStation(station)

        local blip = station.blip
        if blip then
            local handle = AddBlipForCoord(station.coords.x, station.coords.y, station.coords.z)
            SetBlipSprite(handle, blip.sprite or 436)
            SetBlipColour(handle, blip.colour or 49)
            SetBlipScale(handle, blip.scale or 0.8)
            SetBlipAsShortRange(handle, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(station.label)
            EndTextCommandSetBlipName(handle)
        end
    end
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

    local spawn = station.spawn or { coords = station.garage or station.coords, heading = 0.0 }
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
