-- Turnout gear.
--
-- Applied natively so the job works on a server with no clothing resource at
-- all, and the civilian outfit is always cached first: a firefighter who
-- clocks off, crashes, or is dismissed gets their own clothes back rather than
-- being left in a helmet.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Uniform = {}
Fire.Uniform = Uniform

-- The component and prop slots the job touches. Only these are cached and
-- restored, so a uniform never overwrites something it did not set.
local COMPONENTS = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
local PROPS = { 0, 1, 2, 6, 7 }

local civilian, applied = nil, nil

local function settings()
    return Shared.Settings().uniforms or {}
end

local function ped()
    return PlayerPedId()
end

function Uniform.Gender()
    return IsPedMale(ped()) and 'male' or 'female'
end

local function capture()
    local player = ped()
    local outfit = { components = {}, props = {} }

    for _, slot in ipairs(COMPONENTS) do
        outfit.components[slot] = {
            GetPedDrawableVariation(player, slot),
            GetPedTextureVariation(player, slot)
        }
    end
    for _, slot in ipairs(PROPS) do
        outfit.props[slot] = { GetPedPropIndex(player, slot), GetPedPropTextureIndex(player, slot) }
    end
    return outfit
end

local function wear(outfit)
    if type(outfit) ~= 'table' then return false end
    local player = ped()

    for slot, entry in pairs(outfit.components or {}) do
        SetPedComponentVariation(player, tonumber(slot), tonumber(entry[1]) or 0, tonumber(entry[2]) or 0, 0)
    end
    for slot, entry in pairs(outfit.props or {}) do
        local drawable = tonumber(entry[1]) or -1
        if drawable < 0 then
            ClearPedProp(player, tonumber(slot))
        else
            SetPedPropIndex(player, tonumber(slot), drawable, tonumber(entry[2]) or 0, true)
        end
    end
    return true
end

Uniform.Wear = wear

function Uniform.Current()
    return applied
end

function Uniform.Variants(departmentId)
    local _, sets = Shared.UniformSet(departmentId, Uniform.Gender())
    local list = {}
    for id in pairs(sets or {}) do list[#list + 1] = id end
    table.sort(list)
    return list
end

-- Puts a set on, remembering what was underneath the first time.
function Uniform.Apply(departmentId, variant)
    if settings().provider == 'none' then return false end

    local set = Shared.UniformSet(departmentId, Uniform.Gender(), variant or 'turnout')
    if not set then return false end

    if not civilian then civilian = capture() end
    wear(set)
    applied = variant or 'turnout'
    return true
end

function Uniform.Restore()
    if not civilian then return false end
    wear(civilian)
    civilian, applied = nil, nil
    return true
end

-- Clocking on puts the gear on; clocking off, being dismissed, or the resource
-- stopping puts the civilian clothes back.
AddEventHandler(Bridge.Event('fire:clientUpdated'), function(reason)
    if reason ~= 'duty' then return end

    local duty = Client.Duty()
    if duty then
        if not applied then Uniform.Apply(duty.department, 'turnout') end
    else
        Uniform.Restore()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    Uniform.Restore()
end)
