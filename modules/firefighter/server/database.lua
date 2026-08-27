-- SQL persistence with a JSON fallback.
--
-- The job runs on servers that have a database and on servers that do not, so
-- this module is the only place that knows which. It detects a driver, creates
-- its tables, and exposes a small async API; everything above it works against
-- an in-memory cache that is written behind, so no gameplay path has to wait
-- on a query.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Database = {}
Fire.Database = Database

local active, migrated = nil, false

local function settings()
    return Shared.Settings().database or {}
end

-- mysql-async has no positional placeholders, so a `?` query is rewritten to
-- named parameters for it. Every query in this job is built here, and none of
-- them contain a literal question mark, so the substitution is safe.
local function named(query, params)
    local index, values = 0, {}
    local converted = query:gsub('%?', function()
        index = index + 1
        local key = ('@p%d'):format(index)
        values[key] = (params or {})[index]
        return key
    end)
    return converted, values
end

local DRIVERS = {
    {
        id = 'oxmysql',
        resource = 'oxmysql',
        query = function(query, params, cb) exports.oxmysql:query(query, params, cb) end,
        execute = function(query, params, cb) exports.oxmysql:update(query, params, cb) end,
        insert = function(query, params, cb) exports.oxmysql:insert(query, params, cb) end
    },
    {
        id = 'mysql-async',
        resource = 'mysql-async',
        query = function(query, params, cb)
            local converted, values = named(query, params)
            exports['mysql-async']:mysql_fetch_all(converted, values, cb)
        end,
        execute = function(query, params, cb)
            local converted, values = named(query, params)
            exports['mysql-async']:mysql_execute(converted, values, cb)
        end,
        insert = function(query, params, cb)
            local converted, values = named(query, params)
            exports['mysql-async']:mysql_insert(converted, values, cb)
        end
    },
    {
        id = 'ghmattimysql',
        resource = 'ghmattimysql',
        query = function(query, params, cb) exports.ghmattimysql:execute(query, params, cb) end,
        execute = function(query, params, cb) exports.ghmattimysql:execute(query, params, cb) end,
        insert = function(query, params, cb) exports.ghmattimysql:execute(query, params, cb) end
    }
}

local function started(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

local function resolve()
    local config = settings()
    if config.enabled == false then return nil end

    local wanted = config.driver
    for _, candidate in ipairs(DRIVERS) do
        if (wanted == nil or wanted == 'auto' or wanted == candidate.id) and started(candidate.resource) then
            return candidate
        end
    end
    return nil
end

function Database.Detect()
    active = resolve()
    return active
end

function Database.Driver()
    return active and active.id or nil
end

function Database.Available()
    return active ~= nil
end

function Database.Table(name)
    return (settings().prefix or 'firefighter_') .. name
end

-- Every call is a no-op that reports failure when no driver is running, so a
-- caller never has to check twice.
local function run(kind, query, params, callback)
    if not active then
        if callback then callback(nil) end
        return false
    end

    local ok, err = pcall(active[kind], query, params or {}, function(result)
        if callback then callback(result) end
    end)
    if not ok then
        Bridge.Print('database %s failed: %s', kind, tostring(err))
        if callback then callback(nil) end
        return false
    end
    return true
end

function Database.Query(query, params, callback) return run('query', query, params, callback) end
function Database.Execute(query, params, callback) return run('execute', query, params, callback) end
function Database.Insert(query, params, callback) return run('insert', query, params, callback) end

function Database.Single(query, params, callback)
    return Database.Query(query, params, function(rows)
        if type(rows) ~= 'table' then return callback(nil) end
        callback(rows[1])
    end)
end

-- Schema -------------------------------------------------------------------

-- Kept in Lua as well as in sql/firefighter.sql so a server that would rather
-- not import anything can leave `database.migrate` on and start.
function Database.Schema()
    local profiles, employment, training, calls =
        Database.Table('profiles'), Database.Table('employment'),
        Database.Table('training'), Database.Table('calls')
    local invoices, reports = Database.Table('invoices'), Database.Table('reports')

    return {
        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `identifier` VARCHAR(64) NOT NULL,
            `name` VARCHAR(64) DEFAULT NULL,
            `department` VARCHAR(32) DEFAULT NULL,
            `xp` INT NOT NULL DEFAULT 0,
            `certifications` LONGTEXT DEFAULT NULL,
            `training` LONGTEXT DEFAULT NULL,
            `stats` LONGTEXT DEFAULT NULL,
            `hired_at` BIGINT DEFAULT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`identifier`),
            KEY `idx_%s_department` (`department`),
            KEY `idx_%s_xp` (`xp`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(profiles, profiles, profiles),

        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(64) NOT NULL,
            `department` VARCHAR(32) NOT NULL,
            `job` VARCHAR(32) DEFAULT NULL,
            `grade` INT NOT NULL DEFAULT 0,
            `rank` VARCHAR(32) DEFAULT NULL,
            `action` VARCHAR(16) NOT NULL,
            `actor` VARCHAR(64) DEFAULT NULL,
            `reason` VARCHAR(190) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_%s_identifier` (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(employment, employment),

        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(64) NOT NULL,
            `course` VARCHAR(32) NOT NULL,
            `certification` VARCHAR(32) NOT NULL,
            `passed` TINYINT(1) NOT NULL DEFAULT 0,
            `score` INT DEFAULT NULL,
            `instructor` VARCHAR(64) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_%s_identifier` (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(training, training),

        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `call_ref` VARCHAR(16) NOT NULL,
            `department` VARCHAR(32) DEFAULT NULL,
            `kind` VARCHAR(32) NOT NULL,
            `location` VARCHAR(190) DEFAULT NULL,
            `priority` TINYINT NOT NULL DEFAULT 3,
            `source` VARCHAR(24) DEFAULT NULL,
            `response_time` INT DEFAULT NULL,
            `duration` INT DEFAULT NULL,
            `extinguished` INT NOT NULL DEFAULT 0,
            `rescued` INT NOT NULL DEFAULT 0,
            `lost` INT NOT NULL DEFAULT 0,
            `payout` INT NOT NULL DEFAULT 0,
            `responders` LONGTEXT DEFAULT NULL,
            `outcome` VARCHAR(64) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_%s_department` (`department`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(calls, calls),

        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `reference` VARCHAR(16) NOT NULL,
            `identifier` VARCHAR(64) NOT NULL,
            `name` VARCHAR(64) DEFAULT NULL,
            `department` VARCHAR(32) DEFAULT NULL,
            `call_ref` VARCHAR(16) DEFAULT NULL,
            `amount` INT NOT NULL DEFAULT 0,
            `paid` TINYINT(1) NOT NULL DEFAULT 0,
            `voided` TINYINT(1) NOT NULL DEFAULT 0,
            `reason` VARCHAR(190) DEFAULT NULL,
            `items` LONGTEXT DEFAULT NULL,
            `raised_by` VARCHAR(64) DEFAULT NULL,
            `settled_at` BIGINT DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `idx_%s_reference` (`reference`),
            KEY `idx_%s_identifier` (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(invoices, invoices, invoices),

        ([[CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `call_ref` VARCHAR(16) NOT NULL,
            `department` VARCHAR(32) DEFAULT NULL,
            `author` VARCHAR(64) NOT NULL,
            `author_name` VARCHAR(64) DEFAULT NULL,
            `kind` VARCHAR(32) DEFAULT NULL,
            `location` VARCHAR(190) DEFAULT NULL,
            `narrative` TEXT,
            `units` LONGTEXT DEFAULT NULL,
            `casualties` INT NOT NULL DEFAULT 0,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_%s_call` (`call_ref`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(reports, reports)
    }
end

function Database.Migrate(callback)
    if not active or migrated then
        if callback then callback(migrated) end
        return migrated
    end

    local statements = Database.Schema()
    local remaining = #statements
    migrated = true

    for _, statement in ipairs(statements) do
        Database.Execute(statement, {}, function()
            remaining = remaining - 1
            if remaining == 0 then
                Bridge.Print('firefighter schema ready on %s', Database.Driver())
                if callback then callback(true) end
            end
        end)
    end
    return true
end

CreateThread(function()
    Bridge.AwaitReady(10000)
    if not Shared.Enabled() then return end

    Database.Detect()
    if not Database.Available() then
        return Bridge.Print('firefighter persistence: no SQL driver detected, using the resource JSON store')
    end

    Bridge.Print('firefighter persistence: %s', Database.Driver())
    if settings().migrate ~= false then Database.Migrate() end
end)
