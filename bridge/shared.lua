DAG = DAG or {}
DAG.Framework = DAG.Framework or {}

local Bridge = DAG.Framework
Bridge.namespace = GetCurrentResourceName()
Bridge.resourceNames = {
    qbox = { 'qbx_core' },
    qb = { 'qb-core', 'qbus' },
    esx = { 'es_extended' },
    vrp = { 'vrp' },
    ox = { 'ox_core' },
    standalone = {}
}

local function isStarted(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

-- Every resource whose start/stop can change the detection result. Used to
-- invalidate the cache instead of re-probing on every bridge call.
local watched = {}
for _, resources in pairs(Bridge.resourceNames) do
    for _, resource in ipairs(resources) do watched[resource] = true end
end

local function resolve()
    local selected = string.lower(Config.Framework or 'auto')

    if selected ~= 'auto' then
        assert(Bridge.resourceNames[selected], ('Unsupported framework "%s"'):format(selected))
        local candidates = Bridge.resourceNames[selected]
        for _, resource in ipairs(candidates) do
            if isStarted(resource) then return selected, resource end
        end
        return selected, candidates[1]
    end

    for _, framework in ipairs(Config.FrameworkPriority or {}) do
        for _, resource in ipairs(Bridge.resourceNames[framework] or {}) do
            if isStarted(resource) then return framework, resource end
        end
    end

    return 'standalone', nil
end

-- Cached: resolve() probes up to six resources, and Detect() sits on the hot
-- path of every money, item, and job call. The cache is dropped whenever a
-- framework resource starts or stops, so late-started cores are still picked up.
function Bridge.Detect()
    if not Bridge.name then Bridge.name, Bridge.resource = resolve() end
    return Bridge.name
end

function Bridge.Invalidate()
    Bridge.name, Bridge.resource = nil, nil
end

local function onResourceChange(resource)
    if watched[resource] then Bridge.Invalidate() end
end

AddEventHandler('onResourceStart', onResourceChange)
AddEventHandler('onResourceStop', onResourceChange)
AddEventHandler('onClientResourceStart', onResourceChange)
AddEventHandler('onClientResourceStop', onResourceChange)

function Bridge.IsReady()
    local framework = Bridge.Detect()
    return framework == 'standalone' or (Bridge.resource ~= nil and isStarted(Bridge.resource))
end

function Bridge.AwaitReady(timeout)
    local deadline = GetGameTimer() + (timeout or 10000)
    while not Bridge.IsReady() and GetGameTimer() < deadline do
        Bridge.Invalidate()
        Wait(100)
    end
    return Bridge.IsReady()
end

function Bridge.Is(name)
    return Bridge.Detect() == string.lower(name)
end

function Bridge.Event(event)
    return ('%s:dag:%s'):format(Bridge.namespace, event)
end

function Bridge.On(event, handler)
    assert(type(event) == 'string' and type(handler) == 'function', 'Invalid bridge event handler')
    return AddEventHandler(Bridge.Event(event), handler)
end

-- Frameworks disagree on job shape: ESX uses grade/grade_name, QB nests a
-- grade table, Ox Core uses groups. Normalizing here keeps every caller and
-- both sides of the bridge on one contract.
function Bridge.NormalizeJob(job)
    if type(job) ~= 'table' then return nil end
    local grade = job.grade
    if type(grade) == 'table' then grade = grade.level or grade.grade or 0 end
    return {
        name = job.name or 'unemployed',
        label = job.label or job.name or 'Unemployed',
        grade = tonumber(grade) or 0,
        gradeName = job.grade_name or (type(job.grade) == 'table' and job.grade.name) or 'none',
        onDuty = job.onduty ~= false
    }
end

function Bridge.Print(message, ...)
    print(('[%s] %s'):format(Bridge.namespace, select('#', ...) > 0 and message:format(...) or message))
end

function Bridge.Debug(message, ...)
    if not Config.Debug then return end
    Bridge.Print('[%s] %s', Bridge.Detect(), select('#', ...) > 0 and message:format(...) or message)
end

Bridge.Detect()
