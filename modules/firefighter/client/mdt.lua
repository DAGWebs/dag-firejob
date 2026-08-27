-- The terminal.
--
-- Rendered through DAG.Menu like the rest of the job, so it works on ox_lib,
-- qb-menu, the bundled NUI interface, or the chat fallback without knowing
-- which is running. Nothing here decides anything: every screen is drawn from
-- what the server answered, and every action is a request it can refuse.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Mdt = {}
Fire.Mdt = Mdt

local dashboard = {}

local function settings()
    return Shared.Settings().mdt or {}
end

local function menuId(name)
    return ('%s:fire:mdt:%s'):format(Bridge.namespace, name)
end

local function ask(name, callback, ...)
    Bridge.TriggerCallback(Bridge.Event(name), function(result, err)
        if err or result == nil then
            return Bridge.Notify('The terminal did not answer.', 'error')
        end
        callback(result)
    end, ...)
end

local function act(event, ...)
    TriggerServerEvent(Bridge.Event(event), ...)
end

-- Refreshing after an edit means asking the server again rather than guessing
-- what it did with the request.
local function refresh(open)
    SetTimeout(500, function()
        Mdt.Open(open)
    end)
end

-- Screens ---------------------------------------------------------------------

local function callHistoryMenu(entry)
    local filed = dashboard.filed and dashboard.filed[entry.id]
    local options = {
        { title = ('%s %s'):format(entry.id, entry.label or entry.kind), header = true },
        { title = entry.location or 'Unknown location', icon = 'info', disabled = true },
        {
            title = 'Outcome',
            description = entry.outcome or 'closed',
            badge = entry.lost and entry.lost > 0 and ('%d lost'):format(entry.lost) or 'All out',
            badgeTone = (entry.lost or 0) > 0 and 'danger' or 'success',
            disabled = true
        },
        {
            title = 'Response',
            badge = entry.responseTime and Shared.FormatDuration(entry.responseTime) or 'no arrival',
            disabled = true
        },
        {
            title = 'Worked',
            description = ('%d fire(s) out, %d patient(s)'):format(entry.extinguished or 0, entry.rescued or 0),
            badge = Shared.FormatDuration(entry.duration or 0),
            disabled = true
        },
        { title = 'Actions', header = true }
    }

    options[#options + 1] = {
        title = filed and 'Report already filed' or 'File the incident report',
        description = filed and filed.authorName or 'Writes the narrative into the record',
        icon = 'wrench',
        disabled = filed ~= nil,
        onSelect = function() Mdt.FileReport(entry) end
    }

    options[#options + 1] = {
        title = 'Bill somebody for this call',
        description = 'Pick whoever is standing at the terminal',
        icon = 'cash',
        onSelect = function() Mdt.OpenBilling(entry.id) end
    }

    local id = menuId('call:' .. entry.id)
    DAG.Menu.Register({ id = id, title = entry.id, subtitle = entry.location, options = options })
    return id
end

function Mdt.FileReport(entry)
    DAG.Menu.Input(('Incident report - %s'):format(entry.id), {
        { name = 'narrative', label = 'What happened', type = 'text', required = true }
    }, function(values, err)
        if err or type(values) ~= 'table' then return end

        local narrative = values.narrative or values[1]
        if type(narrative) ~= 'string' or #narrative < 10 then
            return Bridge.Notify('A report needs more than that.', 'error')
        end

        act('mdt:file', entry.id, narrative)
        refresh(menuId('history'))
    end)
end

function Mdt.OpenHistory()
    ask('mdt:history', function(history)
        local options = { { title = 'Recent calls', header = true } }
        for _, entry in ipairs(history) do
            options[#options + 1] = {
                title = ('%s  %s'):format(entry.id, entry.label or entry.kind),
                description = ('%s - %s'):format(entry.location or 'Unknown', entry.outcome or 'closed'),
                icon = 'info',
                badge = (dashboard.filed or {})[entry.id] and 'Filed' or 'No report',
                badgeTone = (dashboard.filed or {})[entry.id] and 'success' or 'danger',
                menu = callHistoryMenu(entry)
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'No calls on record yet', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('history'), title = 'Call history', options = options })
        DAG.Menu.Navigate(menuId('history'))
    end, settings().pageSize or 10)
end

function Mdt.OpenReports()
    ask('mdt:reports', function(list)
        local options = { { title = 'Filed reports', header = true } }
        for _, report in ipairs(list) do
            options[#options + 1] = {
                title = ('%s - %s'):format(report.callId, report.kind or 'incident'),
                description = report.narrative,
                icon = 'info',
                badge = report.authorName,
                disabled = true
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'Nothing filed yet', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('reports'), title = 'Incident reports', options = options })
        DAG.Menu.Navigate(menuId('reports'))
    end)
end

function Mdt.OpenPersonnel()
    ask('mdt:personnel', function(list)
        local options = { { title = 'Personnel', header = true } }
        for _, person in ipairs(list) do
            options[#options + 1] = {
                title = person.name or 'Unknown',
                description = ('%s - %d call(s), %d rescue(s)'):format(
                    person.rank or 'Unranked',
                    (person.stats or {}).calls or 0,
                    (person.stats or {}).victimsRescued or 0
                ),
                icon = 'user',
                badge = person.onDuty and 'On duty' or ('%d XP'):format(person.xp or 0),
                badgeTone = person.onDuty and 'success' or nil,
                disabled = true
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'No personnel records', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('personnel'), title = 'Personnel', options = options })
        DAG.Menu.Navigate(menuId('personnel'))
    end)
end

-- Billing -----------------------------------------------------------------------

local function billingMenuFor(citizen, callId)
    local options = {
        { title = citizen.name or 'Unknown', header = true },
        {
            title = 'Outstanding',
            badge = Shared.FormatMoney(citizen.outstanding or 0),
            badgeTone = (citizen.outstanding or 0) > 0 and 'danger' or 'success',
            disabled = true
        },
        { title = 'Raise an invoice', header = true }
    }

    if callId then
        options[#options + 1] = {
            title = ('Bill for %s'):format(callId),
            description = 'Priced from what the call actually cost',
            icon = 'cash',
            onSelect = function()
                act('mdt:bill', citizen.source, callId)
                refresh(menuId('billing'))
            end
        }
    end

    options[#options + 1] = {
        title = 'Bill an amount',
        description = 'For anything the schedule does not cover',
        icon = 'cash',
        onSelect = function()
            DAG.Menu.Input(('Invoice %s'):format(citizen.name or ''), {
                { name = 'amount', label = 'Amount', type = 'number', required = true },
                { name = 'reason', label = 'Reason', type = 'text' }
            }, function(values, err)
                if err or type(values) ~= 'table' then return end
                local amount = tonumber(values.amount or values[1])
                if not amount or amount <= 0 then return Bridge.Notify('That is not an amount.', 'error') end

                act('mdt:bill', citizen.source, nil, amount, values.reason or values[2])
                refresh(menuId('billing'))
            end)
        end
    }

    local id = menuId('citizen:' .. citizen.source)
    DAG.Menu.Register({ id = id, title = citizen.name or 'Citizen', options = options })
    return id
end

function Mdt.OpenBilling(callId)
    ask('mdt:citizens', function(citizens)
        local options = { { title = 'People at the terminal', header = true } }
        for _, citizen in ipairs(citizens) do
            options[#options + 1] = {
                title = citizen.name or 'Unknown',
                description = citizen.jobLabel or citizen.job or 'Civilian',
                icon = 'user',
                badge = (citizen.outstanding or 0) > 0 and Shared.FormatMoney(citizen.outstanding) or nil,
                badgeTone = 'danger',
                menu = billingMenuFor(citizen, callId)
            }
        end
        if #options == 1 then
            options[#options + 1] = {
                title = 'Nobody is standing here',
                description = 'Bring them to the terminal to bill them.',
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Ledger', header = true }
        options[#options + 1] = {
            title = 'Outstanding invoices',
            icon = 'cash',
            onSelect = function() Mdt.OpenLedger() end
        }

        DAG.Menu.Register({ id = menuId('billing'), title = 'Billing', options = options })
        DAG.Menu.Navigate(menuId('billing'))
    end)
end

function Mdt.OpenLedger()
    ask('mdt:invoices', function(list)
        local options = { { title = 'Unpaid', header = true } }
        for _, invoice in ipairs(list) do
            options[#options + 1] = {
                title = ('%s  %s'):format(invoice.reference, Shared.FormatMoney(invoice.amount)),
                description = ('%s - %s'):format(invoice.name or invoice.identifier, invoice.reason or ''),
                icon = 'cash',
                badge = dashboard.canCommand and 'Void' or nil,
                badgeTone = 'danger',
                disabled = not dashboard.canCommand,
                onSelect = function()
                    DAG.Menu.Confirm('Void this invoice?', invoice.reference, function(confirmed)
                        if not confirmed then return end
                        act('mdt:void', invoice.reference)
                        refresh(menuId('ledger'))
                    end)
                end
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'Nothing outstanding', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('ledger'), title = 'Invoice ledger', options = options })
        DAG.Menu.Navigate(menuId('ledger'))
    end)
end

function Mdt.OpenAccount()
    local options = {
        { title = 'Department account', header = true },
        {
            title = 'Balance',
            badge = Shared.FormatMoney(dashboard.balance or 0),
            badgeTone = 'success',
            disabled = true
        }
    }

    if dashboard.canCommand then
        options[#options + 1] = {
            title = 'Withdraw',
            description = 'Moves money from the department to you',
            icon = 'cash',
            onSelect = function()
                DAG.Menu.Input('Withdraw from the department', {
                    { name = 'amount', label = 'Amount', type = 'number', required = true }
                }, function(values, err)
                    if err or type(values) ~= 'table' then return end
                    act('mdt:withdraw', tonumber(values.amount or values[1]))
                    refresh(menuId('root'))
                end)
            end
        }
    end

    DAG.Menu.Register({ id = menuId('account'), title = 'Finances', options = options })
    DAG.Menu.Navigate(menuId('account'))
end

-- Citizens read and settle their own invoices from the same terminal, without
-- being on anybody's roster.
function Mdt.OpenMyInvoices()
    ask('mdt:myInvoices', function(list)
        local options = { { title = 'Your invoices', header = true } }
        for _, invoice in ipairs(list) do
            options[#options + 1] = {
                title = ('%s  %s'):format(invoice.reference, Shared.FormatMoney(invoice.amount)),
                description = invoice.reason,
                icon = 'cash',
                badge = 'Pay',
                badgeTone = 'accent',
                onSelect = function()
                    DAG.Menu.Confirm('Pay this invoice?', Shared.FormatMoney(invoice.amount), function(confirmed)
                        if confirmed then act('mdt:pay', invoice.reference) end
                    end)
                end
            }
        end
        if #options == 1 then
            options[#options + 1] = { title = 'You owe the fire department nothing', disabled = true }
        end

        DAG.Menu.Register({ id = menuId('mine'), title = 'Fire department invoices', options = options })
        DAG.Menu.Open(menuId('mine'))
    end)
end

-- Root --------------------------------------------------------------------------

function Mdt.Build(data)
    dashboard = data or {}
    dashboard.filed = dashboard.filed or {}

    local options = {
        { title = dashboard.departmentLabel or 'Fire department', header = true },
        {
            title = dashboard.name or 'Terminal',
            description = ('%s%s'):format(dashboard.rank or 'Unranked',
                dashboard.onDuty and ' - on duty' or ' - off duty'),
            icon = 'user',
            disabled = true
        },
        { title = 'Operations', header = true },
        {
            title = 'Active calls',
            description = 'What the department is working right now',
            icon = 'info',
            badge = tostring(#(dashboard.calls or {})),
            menu = menuId('active')
        },
        {
            title = 'Call history',
            icon = 'info',
            badge = dashboard.unfiled and dashboard.unfiled > 0 and ('%d unfiled'):format(dashboard.unfiled) or nil,
            badgeTone = 'danger',
            onSelect = function() Mdt.OpenHistory() end
        },
        { title = 'Incident reports', icon = 'info', onSelect = function() Mdt.OpenReports() end },
        { title = 'Records', header = true },
        { title = 'Personnel', icon = 'user', onSelect = function() Mdt.OpenPersonnel() end },
        {
            title = 'Billing',
            description = 'Raise and settle invoices',
            icon = 'cash',
            badge = dashboard.outstanding and dashboard.outstanding > 0
                and ('%d unpaid'):format(dashboard.outstanding) or nil,
            onSelect = function() Mdt.OpenBilling() end
        },
        {
            title = 'Finances',
            icon = 'cash',
            badge = Shared.FormatMoney(dashboard.balance or 0),
            onSelect = function() Mdt.OpenAccount() end
        }
    }

    local active = { { title = 'Working', header = true } }
    for _, call in ipairs(dashboard.calls or {}) do
        active[#active + 1] = {
            title = ('%s  %s'):format(call.id, call.label),
            description = ('%s - %d responder(s)'):format(call.location or '', call.responders or 0),
            icon = 'info',
            badge = call.state,
            progress = math.floor((tonumber(call.severity) or 0) * 100),
            onSelect = function() TriggerServerEvent(Bridge.Event('fire:join'), call.id) end
        }
    end
    if #active == 1 then active[#active + 1] = { title = 'The board is clear', disabled = true } end
    DAG.Menu.Register({ id = menuId('active'), title = 'Active calls', options = active })

    DAG.Menu.Register({
        id = menuId('root'),
        title = 'Mobile data terminal',
        subtitle = dashboard.departmentLabel,
        options = options
    })
    return menuId('root')
end

function Mdt.Open(target)
    ask('mdt:dashboard', function(data)
        if not data.authorized then
            -- Not a firefighter: the terminal is still where a citizen settles
            -- what the department billed them.
            return Mdt.OpenMyInvoices()
        end

        -- Which calls already have a report is worth knowing before the list
        -- is drawn, so the badge is right the first time.
        Bridge.TriggerCallback(Bridge.Event('mdt:reports'), function(filed)
            local seen = {}
            for _, report in ipairs(type(filed) == 'table' and filed or {}) do seen[report.callId] = report end
            data.filed = seen

            local root = Mdt.Build(data)
            DAG.Menu.Open(target or root)
        end)
    end)
end

if Fire.Duty then
    Fire.Duty.BindCommand('mdt', 'Fire department terminal', function()
        if not Shared.Enabled() or settings().enabled == false then return end
        Mdt.Open()
    end)
end

-- The watch office is a terminal, and so is the seat of any apparatus.
CreateThread(function()
    if not Shared.Enabled() or settings().enabled == false then return end

    while true do
        local sleep = 1000
        if Client.OnDuty() and IsPedInAnyVehicle(PlayerPedId(), false) and Client.Unit() then
            sleep = 0
            if IsControlJustReleased(0, 244) then Mdt.Open() end
        end
        Wait(sleep)
    end
end)
