-- The client's mirror of the server's scene.
--
-- Nothing here is authoritative. It exists so the HUD, the menus, the fire
-- renderer, and the interaction prompts all read one copy of what dispatch
-- last told us, instead of each keeping their own.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = {}
Fire.Client = Client

local calls, blips = {}, {}
local duty, unit = nil, nil

-- Read-only accessors ------------------------------------------------------

function Client.Calls() return calls end
function Client.Call(id) return calls[id] end
function Client.Duty() return duty end
function Client.Unit() return unit end
function Client.OnDuty() return duty ~= nil end

function Client.Assigned()
    if not duty or not duty.callId then return nil end
    return calls[duty.callId]
end

function Client.Air()
    return duty and duty.air or 0
end

function Client.Department()
    return duty and duty.department or nil
end

function Client.Station()
    return duty and duty.station and Shared.Station(duty.station) or nil
end

-- Whether the server says this firefighter currently has a line off a pump.
function Client.HasLine()
    return duty ~= nil and duty.hose ~= nil
end

function Client.Extinguisher()
    return duty and duty.extinguisher or 0
end

function Client.SortedCalls()
    local list = {}
    for _, call in pairs(calls) do list[#list + 1] = call end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.id < b.id
    end)
    return list
end

-- Nodes ---------------------------------------------------------------------

-- The nearest burning node to a point, used by the hose to decide what a
-- firefighter is actually pointing at.
function Client.NearestNode(coords, range)
    local nearest, nearestCall, nearestDistance
    for _, call in pairs(calls) do
        for _, node in pairs(call.fires or {}) do
            local distance = Shared.Distance(coords, node.coords)
            if distance <= (range or 12.0) and (not nearestDistance or distance < nearestDistance) then
                nearest, nearestCall, nearestDistance = node, call, distance
            end
        end
    end
    return nearest, nearestCall, nearestDistance
end

function Client.NodesNear(coords, range)
    local list = {}
    for _, call in pairs(calls) do
        for _, node in pairs(call.fires or {}) do
            if Shared.Distance(coords, node.coords) <= (range or 20.0) then
                list[#list + 1] = { node = node, call = call }
            end
        end
    end
    return list
end

-- Heat is what damages a firefighter; it comes from the flame, not the node.
function Client.HeatAt(coords)
    local heat, radius = 0, tonumber(((Shared.Settings().fire or {}).heat or {}).radius) or 5.0
    for _, entry in ipairs(Client.NodesNear(coords, radius)) do
        local distance = Shared.Distance(coords, entry.node.coords)
        local falloff = 1.0 - Shared.Clamp(distance / radius, 0, 1)
        heat = heat + (entry.node.intensity or 0) * falloff
    end
    return heat
end

-- Blips ---------------------------------------------------------------------

local function removeBlip(id)
    local blip = blips[id]
    if not blip then return end
    RemoveBlip(blip)
    blips[id] = nil
end

local function refreshBlip(call)
    local callType = Shared.CallType(call.kind) or {}
    local style = callType.blip or {}
    -- A call toned out to us from another department is drawn in that
    -- department's colour, so mutual aid is obvious on the map.
    local department = call.department and Shared.Department(call.department)
    local colour = style.colour or 1
    if department and department.id ~= Client.Department() then colour = department.colour or colour end

    if not blips[call.id] then
        local blip = AddBlipForCoord(call.coords.x, call.coords.y, call.coords.z)
        SetBlipSprite(blip, style.sprite or 436)
        SetBlipColour(blip, colour)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        blips[call.id] = blip
    end

    local blip = blips[call.id]
    SetBlipFlashes(blip, call.state == Fire.CallState.pending)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('%s %s'):format(call.id, call.label))
    EndTextCommandSetBlipName(blip)
end

local function clearBlips()
    for id in pairs(blips) do removeBlip(id) end
end

-- Route the GPS to the call this firefighter is assigned to, and only that one.
local function refreshRoute()
    for id, blip in pairs(blips) do
        SetBlipRoute(blip, duty ~= nil and duty.callId == id)
    end
end

Client.RefreshRoute = refreshRoute

-- Sync ----------------------------------------------------------------------

local function changed(reason, payload)
    TriggerEvent(Bridge.Event('fire:clientUpdated'), reason, payload)
end

local function storeCall(call)
    if not call or not call.id then return end
    calls[call.id] = call
    refreshBlip(call)
    refreshRoute()
    changed('call', call)
end

Client.StoreCall = storeCall

local function dropCall(id, reason)
    calls[id] = nil
    removeBlip(id)
    changed('removed', { id = id, reason = reason })
end

Client.DropCall = dropCall

RegisterNetEvent(Bridge.Event('fire:sync'), function(payload)
    clearBlips()
    calls = {}
    for _, call in ipairs(payload or {}) do storeCall(call) end
end)

RegisterNetEvent(Bridge.Event('fire:call'), storeCall)

RegisterNetEvent(Bridge.Event('fire:callRemoved'), dropCall)

RegisterNetEvent(Bridge.Event('fire:node'), function(callId, node)
    local call = calls[callId]
    if not call or not node or not node.id then return end

    call.fires = call.fires or {}
    if (node.intensity or 0) <= 0 and (node.heat or 0) <= 0 then
        call.fires[node.id] = nil
    else
        call.fires[node.id] = node
    end
    changed('node', { callId = callId, node = node })
end)

RegisterNetEvent(Bridge.Event('fire:victim'), function(callId, victim)
    local call = calls[callId]
    if not call or not victim or not victim.id then return end
    call.victims = call.victims or {}
    call.victims[victim.id] = victim
    changed('victim', { callId = callId, victim = victim })
end)

RegisterNetEvent(Bridge.Event('fire:hazard'), function(callId, hazard)
    local call = calls[callId]
    if not call or not hazard or not hazard.id then return end
    call.hazards = call.hazards or {}
    call.hazards[hazard.id] = hazard
    changed('hazard', { callId = callId, hazard = hazard })
end)

RegisterNetEvent(Bridge.Event('fire:duty'), function(payload)
    duty = payload or nil
    if not duty then
        clearBlips()
        calls = {}
    end
    refreshRoute()
    changed('duty', duty)
end)

RegisterNetEvent(Bridge.Event('fire:unit'), function(payload)
    unit = payload or nil
    changed('unit', unit)
end)

RegisterNetEvent(Bridge.Event('fire:radio'), function(message, kind)
    if not message then return end
    Bridge.Notify(message, kind or 'inform', 7000)
    changed('radio', { message = message, kind = kind })
end)

RegisterNetEvent(Bridge.Event('fire:award'), function(payload)
    changed('award', payload)
end)

-- Clean up the map when the resource stops mid-session.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    clearBlips()
end)
