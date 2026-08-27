-- The mobile data terminal.
--
-- Everything a firefighter needs off the truck: the board, the call history,
-- the reports filed against those calls, personnel records, a citizen lookup,
-- and the billing ledger. Every endpoint checks duty and department the same
-- way the rest of the job does; a terminal is a view, not a way round the
-- authorization.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Database = Fire.Database
local Departments = Fire.Departments
local Billing = Fire.Billing
local Mdt = {}
Fire.Mdt = Mdt

local reports = {}

local function settings()
    return Shared.Settings().mdt or {}
end

local function pageSize()
    return math.floor(Shared.Clamp(tonumber(settings().pageSize) or 10, 1, 50))
end

-- Whoever is asking has to be on the roster; a terminal is department kit.
local function terminalUser(source)
    local record = State.Duty(source)
    local profile = State.Profile(source)
    local department = record and record.department or (profile and profile.department)
    if not department then return nil end
    return department, profile, record
end

Mdt.User = terminalUser

-- Reports -------------------------------------------------------------------

local function reportKey(callId)
    return tostring(callId)
end

function Mdt.Report(callId)
    return reports[reportKey(callId)]
end

function Mdt.LoadReports(callId, callback)
    if not Database.Available() then
        local list = {}
        for _, report in pairs(reports) do
            if not callId or report.callId == callId then list[#list + 1] = report end
        end
        return callback(list)
    end

    local query = ([[SELECT * FROM `%s` %s ORDER BY `id` DESC LIMIT %d]]):format(
        Database.Table('reports'),
        callId and 'WHERE `call_ref` = ?' or '',
        pageSize()
    )
    Database.Query(query, callId and { callId } or {}, function(rows)
        local list = {}
        for _, row in ipairs(rows or {}) do
            local ok, units = pcall(json.decode, row.units or '[]')
            list[#list + 1] = {
                callId = row.call_ref,
                department = row.department,
                author = row.author,
                authorName = row.author_name,
                kind = row.kind,
                location = row.location,
                narrative = row.narrative,
                units = ok and units or {},
                casualties = tonumber(row.casualties) or 0,
                createdAt = row.created_at
            }
        end
        callback(list)
    end)
end

-- Filing a report is worth something, or nobody ever files one. It is paid
-- once per call: the second firefighter to write one is writing it for the
-- record, not for the money.
function Mdt.FileReport(source, callId, narrative)
    local department, profile = terminalUser(source)
    if not department then return false, 'not_employed' end
    if type(callId) ~= 'string' or callId == '' then return false, 'unknown_call' end
    if type(narrative) ~= 'string' or #narrative < 10 then return false, 'narrative_too_short' end

    local key = reportKey(callId)
    if reports[key] then return false, 'already_filed' end

    local report = {
        callId = callId,
        department = department,
        author = profile and profile.identifier or Bridge.GetIdentifier(source),
        authorName = Bridge.GetName(source),
        narrative = narrative:sub(1, 2000),
        units = {},
        casualties = 0,
        createdAt = GetGameTimer()
    }

    local logged = Mdt.history[callId]
    if logged then
        report.kind = logged.kind
        report.location = logged.location
        report.casualties = logged.lost or 0
        for _, responder in ipairs(logged.responders or {}) do report.units[#report.units + 1] = responder.name end
    end

    reports[key] = report

    if Database.Available() then
        local query = ([[INSERT INTO `%s`
            (`call_ref`, `department`, `author`, `author_name`, `kind`, `location`, `narrative`, `units`, `casualties`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]]):format(Database.Table('reports'))
        Database.Execute(query, {
            report.callId, report.department, report.author, report.authorName,
            report.kind, report.location, report.narrative, json.encode(report.units), report.casualties
        })
    end

    local bonus = settings().reportBonus or {}
    if profile and (tonumber(bonus.xp) or 0) > 0 then
        profile.xp = profile.xp + math.floor(bonus.xp)
        State.SaveProfile(profile)
    end
    if (tonumber(bonus.pay) or 0) > 0 then
        local funded = Billing.Fund(math.floor(bonus.pay), 'report bonus')
        if funded > 0 then
            Bridge.AddMoney(source, (Shared.Settings().pay or {}).account or 'bank',
                funded, 'firefighter:report')
        end
    end

    return true, nil, report
end

-- Call history ---------------------------------------------------------------

-- Calls closed this session are kept in memory so the terminal has a history
-- on a server with no database at all.
Mdt.history = {}

local function remember(call, reason, payout)
    local responders = {}
    for identifier, responder in pairs(call.responders or {}) do
        responders[#responders + 1] = { identifier = identifier, name = responder.name }
    end

    local lost = 0
    for _, victim in pairs(call.victims or {}) do
        if victim.state == Fire.VictimState.deceased then lost = lost + 1 end
    end

    Mdt.history[call.id] = {
        id = call.id,
        kind = call.kind,
        label = call.label,
        location = call.location,
        department = call.department,
        source = call.source,
        priority = call.priority,
        responseTime = call.responseTime,
        duration = (call.resolvedAt or GetGameTimer()) - call.createdAt,
        extinguished = call.extinguished or 0,
        rescued = (call.rescued or 0) + (call.transported or 0),
        lost = lost,
        payout = math.floor(payout or 0),
        outcome = reason,
        responders = responders,
        closedAt = GetGameTimer()
    }
end

Mdt.Remember = remember

function Mdt.History(department, limit, callback)
    local capped = math.floor(Shared.Clamp(tonumber(limit) or pageSize(), 1, 50))

    if not Database.Available() then
        local list = {}
        for _, entry in pairs(Mdt.history) do
            if not department or entry.department == department then list[#list + 1] = entry end
        end
        table.sort(list, function(a, b) return (a.closedAt or 0) > (b.closedAt or 0) end)

        local page = {}
        for index = 1, math.min(#list, capped) do page[index] = list[index] end
        return callback(page)
    end

    local query = ([[SELECT * FROM `%s` %s ORDER BY `id` DESC LIMIT %d]]):format(
        Database.Table('calls'),
        department and 'WHERE `department` = ?' or '',
        capped
    )
    Database.Query(query, department and { department } or {}, function(rows)
        local list = {}
        for _, row in ipairs(rows or {}) do
            local ok, responders = pcall(json.decode, row.responders or '[]')
            list[#list + 1] = {
                id = row.call_ref,
                kind = row.kind,
                label = (Shared.CallType(row.kind) or {}).label or row.kind,
                location = row.location,
                department = row.department,
                source = row.source,
                priority = tonumber(row.priority),
                responseTime = tonumber(row.response_time),
                duration = tonumber(row.duration),
                extinguished = tonumber(row.extinguished) or 0,
                rescued = tonumber(row.rescued) or 0,
                lost = tonumber(row.lost) or 0,
                payout = tonumber(row.payout) or 0,
                outcome = row.outcome,
                responders = ok and responders or {},
                createdAt = row.created_at
            }
        end
        callback(list)
    end)
end

-- Personnel and citizens -------------------------------------------------------

function Mdt.Personnel(department, callback)
    State.Leaderboard(50, function(profiles)
        local list = {}
        for _, profile in ipairs(profiles or {}) do
            if not department or profile.department == department then
                list[#list + 1] = {
                    identifier = profile.identifier,
                    name = profile.name,
                    rank = Shared.RankLabel(profile.xp),
                    xp = profile.xp,
                    department = profile.department,
                    certifications = profile.certifications,
                    stats = profile.stats,
                    onDuty = false
                }
            end
        end

        local onDuty = {}
        for _, record in ipairs(State.Roster(department)) do onDuty[record.identifier] = true end
        for _, entry in ipairs(list) do entry.onDuty = onDuty[entry.identifier] == true end

        table.sort(list, function(a, b) return (a.xp or 0) > (b.xp or 0) end)
        callback(list)
    end)
end

-- Who is standing in front of the terminal, so a bill can be raised against a
-- real person rather than a typed-in name.
function Mdt.Citizens(source)
    local list = {}
    for _, entry in ipairs(Departments.Nearby(source, 12.0)) do
        entry.outstanding = Billing.OutstandingTotal(entry.identifier)
        list[#list + 1] = entry
    end
    return list
end

function Mdt.Citizen(identifier, callback)
    local invoices = {}
    for _, invoice in ipairs(Billing.Outstanding(identifier)) do invoices[#invoices + 1] = invoice end

    Mdt.LoadReports(nil, function(filed)
        local seen = {}
        for _, report in ipairs(filed) do seen[report.callId] = report end
        callback({
            identifier = identifier,
            invoices = invoices,
            outstanding = Billing.OutstandingTotal(identifier),
            reports = seen
        })
    end)
end

-- Endpoints --------------------------------------------------------------------

local function on(event, handler)
    RegisterNetEvent(Bridge.Event(event), function(...)
        local playerSource = source
        local ok, err = pcall(handler, playerSource, ...)
        if not ok then Bridge.Print("mdt handler '%s' errored: %s", event, tostring(err)) end
    end)
end

Bridge.RegisterCallback(Bridge.Event('mdt:dashboard'), function(source, reply)
    local department, profile, record = terminalUser(source)
    if not department then return reply({ authorized = false }) end

    local calls = {}
    for _, call in ipairs(State.ActiveCalls(department)) do
        calls[#calls + 1] = {
            id = call.id,
            label = call.label,
            location = call.location,
            state = call.state,
            priority = call.priority,
            severity = Shared.Severity(call),
            responders = State.ResponderCount(call)
        }
    end

    local roster = {}
    for _, entry in ipairs(State.Roster(department)) do
        roster[#roster + 1] = { name = entry.name, station = entry.station, callId = entry.callId }
    end

    Mdt.History(department, pageSize(), function(history)
        reply({
            authorized = true,
            department = department,
            departmentLabel = (Shared.Department(department) or {}).label,
            rank = profile and Shared.RankLabel(profile.xp) or nil,
            name = profile and profile.name or Bridge.GetName(source),
            onDuty = record ~= nil,
            calls = calls,
            roster = roster,
            history = history,
            unfiled = (function()
                local count = 0
                for _, entry in ipairs(history) do
                    if not reports[reportKey(entry.id)] then count = count + 1 end
                end
                return count
            end)(),
            balance = Billing.Balance(),
            outstanding = #Billing.Outstanding(),
            canCommand = Departments.CanCommand(source, department)
        })
    end)
end)

Bridge.RegisterCallback(Bridge.Event('mdt:history'), function(source, reply, limit)
    local department = terminalUser(source)
    if not department then return reply({}) end
    Mdt.History(department, limit, reply)
end)

Bridge.RegisterCallback(Bridge.Event('mdt:reports'), function(source, reply, callId)
    local department = terminalUser(source)
    if not department then return reply({}) end
    Mdt.LoadReports(type(callId) == 'string' and callId or nil, reply)
end)

Bridge.RegisterCallback(Bridge.Event('mdt:personnel'), function(source, reply)
    local department = terminalUser(source)
    if not department then return reply({}) end
    Mdt.Personnel(department, reply)
end)

Bridge.RegisterCallback(Bridge.Event('mdt:citizens'), function(source, reply)
    local department = terminalUser(source)
    if not department then return reply({}) end
    reply(Mdt.Citizens(source))
end)

Bridge.RegisterCallback(Bridge.Event('mdt:invoices'), function(source, reply, identifier)
    local department = terminalUser(source)
    if not department then return reply({}) end
    reply(Billing.Outstanding(type(identifier) == 'string' and identifier or nil))
end)

-- A citizen reads and settles their own invoices without being on the roster.
Bridge.RegisterCallback(Bridge.Event('mdt:myInvoices'), function(source, reply)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return reply({}) end
    reply(Billing.Outstanding(identifier))
end)

on('mdt:file', function(source, callId, narrative)
    local ok, reason, report = Mdt.FileReport(source, callId, narrative)
    if not ok then
        return Bridge.Notify(source, Fire.Api.Reasons[reason] or 'That report was not accepted.', 'error')
    end
    Bridge.Notify(source, ('Report filed for %s.'):format(report.callId), 'success')
end)

on('mdt:bill', function(source, target, callId, amount, reason)
    local department, _, record = terminalUser(source)
    if not department then return end
    if record == nil then return Bridge.Notify(source, 'You are not on duty.', 'error') end
    if type(target) ~= 'number' then return end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return Bridge.Notify(source, 'That player is not connected.', 'error') end

    -- Billing from a call uses what the call actually cost; a manual invoice
    -- takes the amount an officer typed.
    local items, total
    local logged = type(callId) == 'string' and Mdt.history[callId]
    if logged then
        items, total = Billing.Estimate({
            kind = logged.kind,
            extinguished = logged.extinguished,
            rescued = logged.rescued,
            litres = 0,
            extrication = logged.kind == 'mva'
        })
    end

    local invoice, failure = Billing.Create({
        identifier = identifier,
        name = Bridge.GetName(target),
        department = department,
        callId = logged and logged.id or nil,
        items = items,
        amount = not items and math.floor(tonumber(amount) or 0) or nil,
        reason = type(reason) == 'string' and reason:sub(1, 120)
            or (logged and ('%s - %s'):format(logged.id, logged.label) or 'Fire department services'),
        raisedBy = Bridge.GetIdentifier(source),
        target = target
    })

    if not invoice then
        return Bridge.Notify(source, failure == 'nothing_to_bill' and 'There is nothing to bill for.'
            or 'That invoice could not be raised.', 'error')
    end

    Bridge.Notify(source, ('Invoice %s raised for %s.'):format(
        invoice.reference, Shared.FormatMoney(invoice.amount)), 'success')
    if total then Bridge.Debug('billed %s for %d', identifier, total) end
end)

on('mdt:void', function(source, reference)
    local department = terminalUser(source)
    if not department or not Departments.CanCommand(source, department) then
        return Bridge.Notify(source, 'You are not authorized to do that.', 'error')
    end
    if type(reference) ~= 'string' then return end

    local ok, failure, invoice = Billing.Void(reference, 'voided by an officer')
    if not ok then return Bridge.Notify(source, failure == 'already_paid' and 'That invoice is already paid.'
        or 'No such invoice.', 'error') end
    Bridge.Notify(source, ('Invoice %s voided.'):format(invoice.reference), 'inform')
end)

on('mdt:pay', function(source, reference)
    if type(reference) ~= 'string' then return end
    local ok, failure = Billing.Pay(source, reference)
    if ok then return end

    local messages = {
        cannot_afford = 'You cannot afford that.',
        not_your_invoice = 'That is not your invoice.',
        already_paid = 'That invoice is already paid.',
        unknown_invoice = 'No such invoice.'
    }
    Bridge.Notify(source, messages[failure] or 'That payment did not go through.', 'error')
end)

on('mdt:withdraw', function(source, amount)
    local department = terminalUser(source)
    if not department or not Departments.CanCommand(source, department) then
        return Bridge.Notify(source, 'You are not authorized to do that.', 'error')
    end

    local ok, failure, remaining = Billing.Withdraw(source, amount, 'firefighter:department')
    if not ok then
        local messages = {
            insufficient_funds = 'The department account does not have that much.',
            invalid_amount = 'That is not an amount.'
        }
        return Bridge.Notify(source, messages[failure] or 'That withdrawal failed.', 'error')
    end
    Bridge.Notify(source, ('Withdrawn. The department account holds %s.'):format(
        Shared.FormatMoney(remaining)), 'success')
end)

CreateThread(function()
    Bridge.AwaitReady(10000)
    if settings().enabled == false then return end
    -- Which of these is in play decides whether the split and the department
    -- account mean anything, so it is said out loud rather than assumed.
    Bridge.Print('billing: settled by %s, delivered through %s, society %s, wages from %s',
        Billing.Settlement(),
        (Billing.Provider() or {}).id or 'the terminal',
        (Billing.SocietyProvider() or {}).resource or 'the internal ledger',
        Billing.Funding())

    local split = Shared.Settings().billing.split or {}
    if Billing.Settlement() == 'framework'
        and ((tonumber(split.author) or 0) > 0 or (tonumber(split.crew) or 0) > 0) then
        Bridge.Print('WARNING: billing.split is set but the framework is collecting, so it decides '
            .. 'where the money goes. Set billing.settlement = "department" for the split to apply.')
    end
end)
