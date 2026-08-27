-- Incident sources other than the ambient dispatcher.
--
-- What players actually do turns into the same calls the dispatcher invents: a
-- burning car, a wreck at a junction, somebody down in the street, or a member
-- of the public phoning it in. The client reports that something happened; the
-- server decides where it happened, whether it is worth a call, and which
-- department owns it.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Dispatch = Fire.Dispatch
local Events = {}
Fire.Events = Events

local cooldowns = {}

local function settings()
    return Shared.Settings().events or {}
end

local function sourceSettings(name)
    local config = settings()[name]
    if type(config) ~= 'table' then return nil end
    if config.enabled == false then return nil end
    return config
end

local function cooling(source)
    local window = tonumber(settings().cooldown) or 90000
    local last = cooldowns[source]
    if last and GetGameTimer() - last < window then return true end
    cooldowns[source] = GetGameTimer()
    return false
end

-- An incident on top of an open call makes that call worse rather than
-- creating a second one for the same junction.
local function reinforce(call, kind)
    Dispatch.Escalate(call)
    Dispatch.Radio(('%s upgraded - further %s reported'):format(call.id, kind), 'error', call)
    return call
end

-- The one place a player-caused call is created. Coordinates always come from
-- the reporting player's ped, never from the payload.
function Events.Trigger(source, kind, options)
    options = options or {}
    if not Shared.Enabled() then return nil, 'disabled' end
    if not Shared.CallType(kind) then return nil, 'unknown_call_type' end

    local coords = State.PlayerCoords(source)
    if not coords then return nil, 'no_position' end

    if not options.skipCooldown and cooling(source) then return nil, 'cooling_down' end

    local nearby = Dispatch.NearbyCall(coords)
    if nearby then return reinforce(nearby, kind), 'reinforced' end

    local call, reason = Dispatch.Create(kind, {
        coords = coords,
        label = options.label or 'Reported location',
        location = { coords = coords, label = options.label or 'Reported location' },
        source = options.source or 'player',
        reportedBy = Bridge.GetIdentifier(source),
        force = true
    })
    if not call then return nil, reason end

    -- A call nobody is on duty for still goes on the board and waits, which is
    -- the point: the city does not stop having emergencies.
    if State.OnDutyCount(call.department) == 0 then
        Bridge.Notify(source, 'Reported. No units are on duty right now.', 'inform', 6000)
    else
        Bridge.Notify(source, 'Reported. Units are being dispatched.', 'success', 6000)
    end
    return call
end

-- Sources ------------------------------------------------------------------

function Events.VehicleFire(source)
    local config = sourceSettings('vehicleFire')
    if not config then return nil, 'disabled' end
    return Events.Trigger(source, config.kind or 'vehicle', { label = 'Vehicle alight', source = 'vehicle-fire' })
end

function Events.Collision(source, speed)
    local config = sourceSettings('collision')
    if not config then return nil, 'disabled' end

    local impact = tonumber(speed) or 0
    if impact < (tonumber(config.minimumSpeed) or 22.0) then return nil, 'too_light' end

    local call = Events.Trigger(source, config.kind or 'mva', { label = 'Traffic collision', source = 'collision' })
    -- The player is already at the wheel of the wreck, so the scene does not
    -- need a spawned one on top of them.
    if call and call.wrecks and next(call.wrecks) then
        call.wrecks = {}
        for _, victim in pairs(call.victims or {}) do victim.wreck = nil end
        State.SyncCall(call)
    end
    return call
end

function Events.Down(source)
    local config = sourceSettings('playerDown')
    if not config then return nil, 'disabled' end

    local call = Events.Trigger(source, config.kind or 'medical', { label = 'Person down', source = 'player-down' })
    if call and call.victims and next(call.victims) then
        -- The patient is the player: no NPC casualty is spawned for them.
        call.victims = {}
        call.playerPatient = Bridge.GetIdentifier(source)
        State.SyncCall(call)
    end
    return call
end

function Events.Report(source, kind)
    local config = sourceSettings('report')
    if not config then return nil, 'disabled' end

    local allowed = false
    for _, entry in ipairs(config.kinds or {}) do
        if entry == kind then allowed = true break end
    end
    if not allowed then return nil, 'unknown_call_type' end

    return Events.Trigger(source, kind, { label = 'Called in by a member of the public', source = 'report' })
end

-- Net events ---------------------------------------------------------------
--
-- Each of these is a claim, not an instruction: the handler re-derives the
-- position, checks the cooldown, and can refuse outright.

local function on(event, handler)
    RegisterNetEvent(Bridge.Event(event), function(...)
        local playerSource = source
        local ok, err = pcall(handler, playerSource, ...)
        if not ok then Bridge.Print("firefighter event '%s' errored: %s", event, tostring(err)) end
    end)
end

on('fire:vehicleFire', function(playerSource)
    Events.VehicleFire(playerSource)
end)

on('fire:collision', function(playerSource, speed)
    if type(speed) ~= 'number' then return end
    Events.Collision(playerSource, speed)
end)

on('fire:down', function(playerSource)
    Events.Down(playerSource)
end)

on('fire:report', function(playerSource, kind)
    if type(kind) ~= 'string' then return end
    local call, reason = Events.Report(playerSource, kind)
    if not call and reason == 'cooling_down' then
        Bridge.Notify(playerSource, 'You have already called something in recently.', 'error')
    end
end)

AddEventHandler('playerDropped', function()
    cooldowns[source] = nil
end)

Events.Reinforce = reinforce
