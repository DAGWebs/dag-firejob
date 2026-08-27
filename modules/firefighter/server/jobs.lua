-- Where job definitions actually live.
--
-- Every framework keeps them somewhere different, and the job has to read the
-- one in use rather than assume: QBCore and Qbox read shared/jobs.lua, ESX
-- reads the `jobs` and `job_grades` tables, Ox Core has groups instead. A
-- framework the bridge cannot read falls back to what config.lua says, which
-- is also what standalone uses.
--
-- The point of reading it is not decoration: a department pointed at a job the
-- framework has never heard of cannot hire anybody, and it is better to say so
-- at startup than to have the first hire fail silently.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Database = Fire.Database
local Jobs = {}
Fire.Jobs = Jobs

local definitions, loaded, source = {}, false, nil

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

-- Normalizing --------------------------------------------------------------

-- Frameworks disagree about grades the same way they disagree about jobs: QB
-- keys them by string, Qbox by number, ESX by row. One shape out.
local function normalize(name, label, grades)
    local entry = { name = name, label = label or name, grades = {} }

    for key, grade in pairs(grades or {}) do
        local level = tonumber(key) or tonumber(grade.grade) or tonumber(grade.level) or 0
        entry.grades[level] = {
            grade = level,
            name = grade.name or grade.label or tostring(level),
            label = grade.label or grade.name or tostring(level),
            payment = tonumber(grade.payment or grade.salary) or 0
        }
    end
    return entry
end

Jobs.Normalize = normalize

-- Sources ------------------------------------------------------------------

local function fromConfig()
    local entries = {}
    for _, department in ipairs(Shared.Departments()) do
        local grades = {}
        for _, rank in ipairs(Shared.Ranks()) do
            grades[tonumber(rank.grade) or 0] = { grade = rank.grade, name = rank.id, label = rank.label }
        end
        entries[department.job] = normalize(department.job, department.label, grades)
    end
    return entries
end

-- QBCore and Qbox both hold the table in memory, read from shared/jobs.lua.
local function fromQb()
    local core = safe(function() return exports[Bridge.resource or 'qb-core']:GetCoreObject() end)
    local shared = core and core.Shared and core.Shared.Jobs
    if type(shared) ~= 'table' then return nil end

    local entries = {}
    for name, job in pairs(shared) do
        entries[name] = normalize(name, job.label, job.grades)
    end
    return entries
end

local function fromQbox()
    local shared = safe(function() return exports.qbx_core:GetJobs() end)
    if type(shared) ~= 'table' then return nil end

    local entries = {}
    for name, job in pairs(shared) do
        entries[name] = normalize(name, job.label, job.grades)
    end
    return entries
end

-- ESX keeps them in the database, so reading them means a query. Without a SQL
-- driver there is nothing to read and the config is the only answer.
local function fromEsx(callback)
    if not Database.Available() then return callback(nil) end

    Database.Query('SELECT `name`, `label` FROM `jobs`', {}, function(jobRows)
        if type(jobRows) ~= 'table' or #jobRows == 0 then return callback(nil) end

        Database.Query('SELECT `job_name`, `grade`, `name`, `label`, `salary` FROM `job_grades`', {},
            function(gradeRows)
                local entries = {}
                for _, row in ipairs(jobRows) do
                    entries[row.name] = normalize(row.name, row.label, {})
                end
                for _, row in ipairs(gradeRows or {}) do
                    local entry = entries[row.job_name]
                    if entry then
                        local level = tonumber(row.grade) or 0
                        entry.grades[level] = {
                            grade = level,
                            name = row.name,
                            label = row.label or row.name,
                            payment = tonumber(row.salary) or 0
                        }
                    end
                end
                callback(entries)
            end)
    end)
end

-- Ox Core has no jobs at all, only groups. The bridge already maps a hire onto
-- setGroup; this reports the same shape so the rest of the job does not care.
local function fromOx()
    local groups = safe(function() return exports.ox_core:GetGroups() end)
    if type(groups) ~= 'table' then return nil end

    local entries = {}
    for name, group in pairs(groups) do
        local grades = {}
        for level, label in pairs(group.grades or {}) do
            grades[tonumber(level) or 0] = { grade = level, name = label, label = label }
        end
        entries[name] = normalize(name, group.label or name, grades)
    end
    return entries
end

-- Loading -------------------------------------------------------------------

function Jobs.Source()
    return source
end

function Jobs.All()
    return definitions
end

function Jobs.Get(name)
    return definitions[name]
end

function Jobs.Grade(name, level)
    local job = definitions[name]
    if not job then return nil end
    return job.grades[tonumber(level) or 0]
end

-- The framework's own label for a grade, so a promotion says what the
-- framework says rather than what this config guessed.
function Jobs.GradeLabel(name, level, fallback)
    local grade = Jobs.Grade(name, level)
    return grade and grade.label or fallback
end

function Jobs.Load(callback)
    local framework = Bridge.Detect()

    local function finish(entries, from)
        definitions = entries or fromConfig()
        source = entries and from or 'config'
        loaded = true
        if callback then callback(definitions, source) end
    end

    if framework == 'qb' then return finish(fromQb(), 'qb-core/shared/jobs.lua') end
    if framework == 'qbox' then return finish(fromQbox(), 'qbx_core/shared/jobs.lua') end
    if framework == 'ox' then return finish(fromOx(), 'ox_core groups') end
    if framework == 'esx' then
        return fromEsx(function(entries) finish(entries, 'esx jobs table') end)
    end
    return finish(nil, 'config')
end

function Jobs.Loaded()
    return loaded
end

-- Validation -----------------------------------------------------------------

-- Every department needs its job to exist, and every rank needs its grade to
-- exist within it, or hiring and promoting silently do nothing.
function Jobs.Validate()
    local problems = {}

    for _, department in ipairs(Shared.Departments()) do
        local job = definitions[department.job]
        if not job then
            problems[#problems + 1] = ('department %s wants the job "%s", which %s does not define')
                :format(department.id, tostring(department.job), source or 'the framework')
        else
            for _, rank in ipairs(Shared.Ranks()) do
                local level = tonumber(rank.grade) or 0
                if not job.grades[level] then
                    problems[#problems + 1] = ('job "%s" has no grade %d for the %s rank')
                        :format(department.job, level, rank.label or rank.id)
                end
            end
        end
    end

    return problems
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    if not Shared.Enabled() then return end

    -- ESX reads its jobs out of the database, so give the driver a moment to
    -- come up before asking.
    Wait(2000)

    Jobs.Load(function(entries, from)
        local count = 0
        for _ in pairs(entries) do count = count + 1 end
        Bridge.Print('job definitions: %d from %s', count, from)

        if from == 'config' and Bridge.Detect() ~= 'standalone' then
            Bridge.Print('could not read this framework\'s job definitions; falling back to config.lua')
        end

        for _, problem in ipairs(Jobs.Validate()) do Bridge.Print('WARNING: %s', problem) end
    end)
end)
