-- Billing.
--
-- No two frameworks agree on what an invoice is: ESX has a billing table, QB
-- has phone invoices, Ox has neither. So the department keeps its own ledger
-- and settles through the bridge's money methods, which every framework has.
-- A billing resource, where one is running, is mirrored into rather than
-- relied on, so the department's books are the same on every server.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Database = Fire.Database
local Billing = {}
Fire.Billing = Billing

local LEDGER = 'firefighter_billing'
local invoices, sequence, balance = {}, 0, 0

local function settings()
    return Shared.Settings().billing or {}
end

local function fees()
    return settings().fees or {}
end

-- Providers ----------------------------------------------------------------

-- A mirror, not a dependency: every provider is best effort, and its failure
-- never stops the invoice being raised in the department's own ledger. The
-- event names are configuration rather than literals, so a fork that renamed
-- one is retargeted in config.lua instead of here.
local function started(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

function Billing.Provider()
    local providers = settings().providers or {}
    local wanted = settings().provider or 'auto'
    if wanted == 'none' or wanted == 'internal' then return nil end

    if wanted ~= 'auto' then
        local provider = providers[wanted]
        if provider and started(provider.resource or wanted) then
            provider.id = wanted
            return provider
        end
        return nil
    end

    for id, provider in pairs(providers) do
        if started(provider.resource or id) then
            provider.id = id
            return provider
        end
    end
    return nil
end

local function mirror(source, invoice)
    local provider = Billing.Provider()
    if not provider or not source then return false end

    local ok, err = pcall(function()
        if provider.clientEvent then
            return TriggerClientEvent(provider.clientEvent, source, {
                sender = invoice.department or 'fire',
                amount = invoice.amount,
                reason = invoice.reason
            })
        end
        if provider.event then
            return TriggerEvent(provider.event, source, provider.society or 'society_fire',
                invoice.reason, invoice.amount)
        end
    end)

    if not ok then Bridge.Print('billing provider failed: %s', tostring(err)) end
    return ok
end

-- Department account -------------------------------------------------------

-- The internal balance is authoritative. A society resource, when one is
-- running, is credited alongside it so the rest of the server sees the money.
local SOCIETY = {
    ['qb-management'] = {
        resource = 'qb-management',
        deposit = function(account, amount)
            exports['qb-management']:AddMoney(account, amount)
        end
    },
    esx_addonaccount = {
        resource = 'esx_addonaccount',
        deposit = function(account, amount)
            local addon = exports.esx_addonaccount:getSharedAccount('society_' .. account)
            if addon then addon.addMoney(amount) end
        end
    }
}

Billing.SocietyProviders = SOCIETY

function Billing.SocietyProvider()
    local society = settings().society or {}
    if society.enabled == false then return nil end

    local wanted = society.provider or 'auto'
    if wanted == 'internal' or wanted == 'none' then return nil end

    if wanted ~= 'auto' then
        local provider = SOCIETY[wanted]
        return provider and started(provider.resource) and provider or nil
    end

    for _, provider in pairs(SOCIETY) do
        if started(provider.resource) then return provider end
    end
    return nil
end

function Billing.Balance()
    return balance
end

local function deposit(amount)
    balance = balance + amount

    local provider = Billing.SocietyProvider()
    if provider then
        local account = (settings().society or {}).account or 'fire'
        local ok, err = pcall(provider.deposit, account, amount)
        if not ok then Bridge.Print('society deposit failed: %s', tostring(err)) end
    end
    return balance
end

Billing.Deposit = deposit

-- Ledger -------------------------------------------------------------------

local function persist()
    DAG.Storage.Set(LEDGER, 'ledger', { sequence = sequence, balance = balance })
end

function Billing.Load()
    local stored = DAG.Storage.Get(LEDGER, 'ledger')
    if type(stored) == 'table' then
        sequence = tonumber(stored.sequence) or 0
        balance = tonumber(stored.balance) or 0
    end

    -- Unpaid invoices are read back from SQL where there is a database; the
    -- JSON store keeps them itself when there is not.
    if not Database.Available() then
        local records = DAG.Storage.All(LEDGER)
        for reference, record in pairs(records) do
            if reference ~= 'ledger' and type(record) == 'table' then invoices[reference] = record end
        end
        return
    end

    local query = ([[SELECT * FROM `%s` WHERE `paid` = 0 AND `voided` = 0]]):format(Database.Table('invoices'))
    Database.Query(query, {}, function(rows)
        for _, row in ipairs(rows or {}) do
            local ok, items = pcall(json.decode, row.items or '[]')
            invoices[row.reference] = {
                reference = row.reference,
                identifier = row.identifier,
                name = row.name,
                department = row.department,
                callId = row.call_ref,
                amount = tonumber(row.amount) or 0,
                reason = row.reason,
                items = ok and items or {},
                raisedBy = row.raised_by,
                paid = false,
                voided = false
            }
        end
    end)
end

local function write(invoice)
    if not Database.Available() then
        DAG.Storage.Set(LEDGER, invoice.reference, invoice)
        return
    end

    local query = ([[INSERT INTO `%s`
        (`reference`, `identifier`, `name`, `department`, `call_ref`, `amount`, `paid`, `voided`,
         `reason`, `items`, `raised_by`, `settled_at`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `paid` = VALUES(`paid`), `voided` = VALUES(`voided`), `settled_at` = VALUES(`settled_at`)]])
        :format(Database.Table('invoices'))

    Database.Execute(query, {
        invoice.reference, invoice.identifier, invoice.name, invoice.department, invoice.callId,
        math.floor(invoice.amount), invoice.paid and 1 or 0, invoice.voided and 1 or 0,
        invoice.reason, json.encode(invoice.items or {}), invoice.raisedBy, invoice.settledAt
    })
end

function Billing.Invoice(reference)
    return invoices[reference]
end

function Billing.Outstanding(identifier)
    local list = {}
    for _, invoice in pairs(invoices) do
        if not invoice.paid and not invoice.voided then
            if not identifier or invoice.identifier == identifier then list[#list + 1] = invoice end
        end
    end
    table.sort(list, function(a, b) return a.reference < b.reference end)
    return list
end

function Billing.OutstandingTotal(identifier)
    local total = 0
    for _, invoice in ipairs(Billing.Outstanding(identifier)) do total = total + invoice.amount end
    return total
end

-- What a call is worth -----------------------------------------------------

-- Built from what actually happened, not from a flat rate: a false alarm and a
-- working fire with two patients are not the same bill.
function Billing.Estimate(call)
    local schedule = fees()
    local items = {}

    local function add(label, amount, count)
        local total = math.floor((tonumber(amount) or 0) * (count or 1) + 0.5)
        if total <= 0 then return end
        items[#items + 1] = { label = label, amount = total }
    end

    if call.kind == 'alarm' and (call.extinguished or 0) == 0 then
        add('False alarm response', schedule.falseAlarm)
    else
        add('Emergency response', schedule.response)
    end

    add('Fire suppression', schedule.perFire, call.extinguished or 0)
    add('Water used', schedule.perLitre, math.floor(call.litres or 0))
    add('Patient treatment', schedule.ems, call.rescued or 0)
    add('Patient transport', schedule.transport, call.transported or 0)
    add('Hazardous material containment', schedule.hazmat, call.contained or 0)
    if call.extrication then add('Extrication', schedule.extrication) end

    local total = 0
    for _, item in ipairs(items) do total = total + item.amount end

    local tax = math.floor(total * (tonumber(settings().tax) or 0) + 0.5)
    if tax > 0 then
        items[#items + 1] = { label = 'Tax', amount = tax }
        total = total + tax
    end

    return items, total
end

-- Raising and settling -----------------------------------------------------

function Billing.Reference()
    sequence = sequence + 1
    persist()
    return ('INV-%05d'):format(sequence)
end

function Billing.Create(options)
    if settings().enabled == false then return nil, 'billing_disabled' end

    local identifier = options.identifier
    if type(identifier) ~= 'string' or identifier == '' then return nil, 'unknown_recipient' end

    local items = options.items
    local amount = tonumber(options.amount)
    if not items or #items == 0 then
        if not amount or amount <= 0 then return nil, 'nothing_to_bill' end
        items = { { label = options.reason or 'Fire department services', amount = math.floor(amount) } }
    end

    local total = 0
    for _, item in ipairs(items) do total = total + (tonumber(item.amount) or 0) end
    total = math.floor(total + 0.5)
    if total <= 0 then return nil, 'nothing_to_bill' end

    local invoice = {
        reference = Billing.Reference(),
        identifier = identifier,
        name = options.name,
        department = options.department,
        callId = options.callId,
        amount = total,
        reason = options.reason or 'Fire department services',
        items = items,
        raisedBy = options.raisedBy,
        paid = false,
        voided = false,
        createdAt = GetGameTimer()
    }

    invoices[invoice.reference] = invoice
    write(invoice)

    if options.target then
        mirror(options.target, invoice)
        Bridge.Notify(options.target, ('Invoice %s from the fire department: %s'):format(
            invoice.reference, Shared.FormatMoney(invoice.amount)), 'inform', 10000)
    end

    return invoice
end

-- Raised automatically when a player's own incident closes, because that is
-- the one case where the server knows who to bill without being told.
function Billing.BillCall(call)
    if settings().enabled == false then return nil end
    if not (settings().autoBill or {}).playerCaused then return nil end

    local identifier = call.playerPatient or call.reportedBy
    if not identifier then return nil end

    local items, total = Billing.Estimate(call)
    if total <= 0 then return nil end

    local target
    for _, playerId in ipairs(GetPlayers()) do
        local other = tonumber(playerId)
        if other and Bridge.GetIdentifier(other) == identifier then target = other end
    end

    return Billing.Create({
        identifier = identifier,
        name = target and Bridge.GetName(target) or nil,
        department = call.department,
        callId = call.id,
        items = items,
        reason = ('%s - %s'):format(call.id, call.label),
        raisedBy = 'automatic',
        target = target
    })
end

function Billing.Pay(source, reference)
    local invoice = invoices[reference]
    if not invoice then return false, 'unknown_invoice' end
    if invoice.paid then return false, 'already_paid' end
    if invoice.voided then return false, 'invoice_voided' end

    local identifier = Bridge.GetIdentifier(source)
    if identifier ~= invoice.identifier then return false, 'not_your_invoice' end

    local account = settings().account or 'bank'
    if not Bridge.RemoveMoney(source, account, invoice.amount, ('firefighter:%s'):format(invoice.reference)) then
        return false, 'cannot_afford'
    end

    invoice.paid = true
    invoice.settledAt = GetGameTimer()
    write(invoice)
    deposit(invoice.amount)
    persist()

    Bridge.Notify(source, ('Invoice %s paid: %s'):format(
        invoice.reference, Shared.FormatMoney(invoice.amount)), 'success')
    return true, nil, invoice
end

function Billing.Void(reference, reason)
    local invoice = invoices[reference]
    if not invoice then return false, 'unknown_invoice' end
    if invoice.paid then return false, 'already_paid' end

    invoice.voided = true
    invoice.reason = reason and ('%s (voided: %s)'):format(invoice.reason, reason) or invoice.reason
    write(invoice)
    invoices[reference] = nil
    return true, nil, invoice
end

-- Paying the department out of its own account: wages, an equipment grant, a
-- payout an officer signs off.
function Billing.Withdraw(source, amount, reason)
    local value = math.floor(tonumber(amount) or 0)
    if value <= 0 then return false, 'invalid_amount' end
    if value > balance then return false, 'insufficient_funds' end

    if not Bridge.AddMoney(source, settings().account or 'bank', value, reason or 'firefighter:withdrawal') then
        return false, 'framework_rejected'
    end

    balance = balance - value
    persist()
    return true, nil, balance
end

Billing.Load()
