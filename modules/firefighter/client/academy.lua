-- The academy, client side: the classroom, the drill ground, and the progress
-- bar in between. Scoring is entirely the server's; this only shows what phase
-- the trainee is in and lets them start the next one.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Academy = {}
Fire.Academy = Academy

local course = nil

local function settings()
    return Shared.Settings().academy or {}
end

function Academy.Course()
    return course
end

function Academy.Progress()
    if not course or course.phase ~= 'classroom' then return nil end
    return Shared.Clamp((GetGameTimer() - course.startedAt) / math.max(1, course.duration), 0, 1)
end

function Academy.Enrol(courseId)
    TriggerServerEvent(Bridge.Event('fire:enrol'), courseId)
end

function Academy.Abandon()
    TriggerServerEvent(Bridge.Event('fire:abandonCourse'))
    course = nil
end

function Academy.StartPractical()
    TriggerServerEvent(Bridge.Event('fire:startPractical'))
end

-- The classroom is a wait, not a minigame: the trainee has to stay in it, and
-- the server checks the clock again before letting the drill start.
function Academy.Step()
    if not course or course.phase ~= 'classroom' then return nil end

    local ground = Shared.Coords(settings().classroom or settings().coords)
    local here = Shared.Coords(GetEntityCoords(PlayerPedId()))
    if ground and here and Shared.Distance(here, ground) > 12.0 then
        Bridge.Notify('You walked out of the classroom.', 'error')
        Academy.Abandon()
        return 'left'
    end

    if GetGameTimer() - course.startedAt < course.duration then return 'studying' end

    course.phase = 'ready'
    Bridge.Notify('Classroom phase complete. Report to the drill ground.', 'success', 8000)
    return 'ready'
end

RegisterNetEvent(Bridge.Event('fire:course'), function(payload)
    if not payload then return end

    if payload.phase == 'classroom' then
        course = {
            id = payload.course,
            label = payload.label,
            phase = 'classroom',
            duration = tonumber(payload.duration) or 30000,
            startedAt = GetGameTimer()
        }
        Bridge.Notify(('%s: classroom phase started.'):format(payload.label or 'Course'), 'inform', 8000)
    elseif payload.phase == 'practical' and course then
        course.phase = 'practical'
        course.callId = payload.callId
    end
end)

RegisterNetEvent(Bridge.Event('fire:training'), function(result)
    course = nil
    if not result then return end
    TriggerEvent(Bridge.Event('fire:clientUpdated'), 'training', result)
end)

CreateThread(function()
    while true do
        Academy.Step()
        Wait(1000)
    end
end)

-- Fixtures --------------------------------------------------------------------

local fixtures = {}

local function clearFixtures()
    for id in pairs(fixtures) do DAG.Interactions.Remove(id) end
    for _, blip in ipairs(fixtures.blips or {}) do RemoveBlip(blip) end
    fixtures = {}
end

-- Rebuilt on every config change, so moving the academy in game moves the
-- prompts with it.
function Academy.RegisterFixtures()
    clearFixtures()
    if not Shared.Enabled() or settings().enabled == false then return 0 end

    local classroom = Shared.Coords(settings().classroom or settings().coords)
    local drill = Shared.Coords(settings().drill)

    if classroom then
        fixtures[('%s:academy'):format(Bridge.namespace)] = true
        DAG.Interactions.Register({
            id = ('%s:academy'):format(Bridge.namespace),
            coords = classroom,
            label = 'Press ~INPUT_CONTEXT~ for the fire academy',
            distance = 2.5,
            canInteract = function() return Client.OnDuty() end,
            onSelect = function()
                if Fire.Menus then Fire.Menus.OpenAcademy() end
            end
        })
    end

    if drill then
        fixtures[('%s:academy:drill'):format(Bridge.namespace)] = true
        DAG.Interactions.Register({
            id = ('%s:academy:drill'):format(Bridge.namespace),
            coords = drill,
            label = 'Press ~INPUT_CONTEXT~ to start the practical drill',
            distance = 4.0,
            marker = 23,
            canInteract = function() return course ~= nil and course.phase == 'ready' end,
            onSelect = function() Academy.StartPractical() end
        })
    end

    local blip = settings().blip
    if blip and classroom then
        local handle = AddBlipForCoord(classroom.x, classroom.y, classroom.z)
        SetBlipSprite(handle, blip.sprite or 175)
        SetBlipColour(handle, blip.colour or 49)
        SetBlipScale(handle, blip.scale or 0.7)
        SetBlipAsShortRange(handle, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(settings().label or 'Fire academy')
        EndTextCommandSetBlipName(handle)
        fixtures.blips = { handle }
    end

    local count = 0
    for key in pairs(fixtures) do
        if key ~= 'blips' then count = count + 1 end
    end
    return count
end

CreateThread(function()
    Academy.RegisterFixtures()
end)

AddEventHandler(Bridge.Event('fire:configChanged'), function()
    Academy.RegisterFixtures()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Bridge.namespace then return end
    clearFixtures()
end)
