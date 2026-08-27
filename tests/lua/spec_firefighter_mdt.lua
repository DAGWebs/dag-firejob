-- The terminal and the billing behind it: what a call is worth, who may raise
-- an invoice, who may settle it, and what filing a report is worth.

local SERVER_FILES = {
    'modules/firefighter/server/database.lua',
    'modules/firefighter/server/editor.lua',
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/departments.lua',
    'modules/firefighter/server/billing.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/academy.lua',
    'modules/firefighter/server/events.lua',
    'modules/firefighter/server/mdt.lua',
    'modules/firefighter/server/api.lua'
}

local function loadServer()
    local dag = harness.loadServer({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' },
        modules = { 'storage', 'commands', 'access', 'repository' },
        files = SERVER_FILES
    })
    local fixed = function(minimum) return math.floor(minimum or 0) end
    DAG.Fire.Incident.random = function(a, b)
        if a == nil then return 0.5 end
        if b == nil then return math.floor(a) end
        return math.floor(a)
    end
    DAG.Fire.Dispatch.random = fixed
    return dag
end

local function place(source, coords)
    harness.identifiers[source] = ('license:%d'):format(source)
    harness.names[source] = ('Person %d'):format(source)
    harness.placePlayer(source, coords or vector3(0.0, 0.0, 0.0))
end

local function onDuty(source, command)
    place(source)
    local station = DAG.Fire.Shared.Stations()[1]
    harness.aceAllowed[source] = {
        ['dag-template.lsfd.duty'] = true,
        ['dag-template.lsfd.command'] = command == true
    }
    DAG.Fire.State.GoOnDuty(source, station)
    local profile = DAG.Fire.State.Profile(source)
    profile.department = 'lsfd'
    DAG.Fire.State.SaveProfile(profile)
    return profile
end

local function netEvent(source, name, ...)
    _G.source = source
    TriggerEvent(DAG.Framework.Event(name), ...)
    _G.source = nil
end

local function callback(name, source, ...)
    local answer
    _G.source = source
    TriggerEvent(DAG.Framework.Event('server:callback'), 1, DAG.Framework.Event(name), ...)
    _G.source = nil

    for _, entry in ipairs(harness.clientEvents) do
        if entry.event == DAG.Framework.Event('client:callback') and entry.target == source then
            answer = entry.args[2]
        end
    end
    return answer
end

-- What a call is worth ------------------------------------------------------

test('an invoice is priced from what actually happened on the call', function()
    loadServer()
    local items, total = DAG.Fire.Billing.Estimate({
        kind = 'structure',
        extinguished = 4,
        rescued = 1,
        transported = 1,
        litres = 500
    })

    -- 250 response + 4x75 fire + 500x0.4 water + 400 EMS + 600 transport.
    assertEq(total, 1750)
    assertEq(#items, 5)
    assertEq(items[1].label, 'Emergency response')
end)

-- Turning out to nothing is not the same bill as a working fire.
test('a false alarm is billed as a false alarm', function()
    loadServer()
    local _, alarm = DAG.Fire.Billing.Estimate({ kind = 'alarm', extinguished = 0 })
    assertEq(alarm, 300)

    local _, real = DAG.Fire.Billing.Estimate({ kind = 'alarm', extinguished = 2 })
    assertEq(real, 400, 'something was burning after all: response plus two fires')
end)

test('tax is applied as its own line', function()
    loadServer()
    Config.Firefighter.billing.tax = 0.1

    local items, total = DAG.Fire.Billing.Estimate({ kind = 'vehicle', extinguished = 2 })
    assertEq(items[#items].label, 'Tax')
    assertEq(total, 440, '400 plus ten per cent')
end)

-- Raising -------------------------------------------------------------------

test('an invoice needs a recipient and something to bill for', function()
    loadServer()
    assertNil(DAG.Fire.Billing.Create({ identifier = 'license:1' }))
    assertNil(DAG.Fire.Billing.Create({ amount = 100 }))
    assertNil(DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 0 }))

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 250, reason = 'Callout' })
    assertEq(invoice.amount, 250)
    assertEq(invoice.reference, 'INV-00001')
    assertFalse(invoice.paid)
end)

test('outstanding invoices are listed and totalled per person', function()
    loadServer()
    DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 250 })
    DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 100 })
    DAG.Fire.Billing.Create({ identifier = 'license:2', amount = 900 })

    assertEq(#DAG.Fire.Billing.Outstanding('license:1'), 2)
    assertEq(DAG.Fire.Billing.OutstandingTotal('license:1'), 350)
    assertEq(#DAG.Fire.Billing.Outstanding(), 3, 'and the whole ledger')
end)

-- Settling ------------------------------------------------------------------

test('paying an invoice takes the money and credits the department', function()
    loadServer()
    place(1)
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 400 })
    assertTrue(DAG.Fire.Billing.Pay(1, invoice.reference))

    assertEq(DAG.Framework.GetMoney(1, 'bank'), 600)
    assertEq(DAG.Fire.Billing.Balance(), 400, 'the fee went to the department')
    assertEq(#DAG.Fire.Billing.Outstanding('license:1'), 0)
end)

test('an invoice can only be paid by the person it was raised against', function()
    loadServer()
    place(1)
    place(2)
    DAG.Framework.AddMoney(2, 'bank', 1000, 'test')

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 400 })
    local ok, reason = DAG.Fire.Billing.Pay(2, invoice.reference)
    assertFalse(ok)
    assertEq(reason, 'not_your_invoice')
    assertEq(DAG.Framework.GetMoney(2, 'bank'), 1000)
end)

test('an invoice nobody can afford stays outstanding', function()
    loadServer()
    place(1)

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 400 })
    local ok, reason = DAG.Fire.Billing.Pay(1, invoice.reference)
    assertFalse(ok)
    assertEq(reason, 'cannot_afford')
    assertEq(#DAG.Fire.Billing.Outstanding('license:1'), 1)
end)

test('paying twice is refused', function()
    loadServer()
    place(1)
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 100 })
    assertTrue(DAG.Fire.Billing.Pay(1, invoice.reference))

    local ok, reason = DAG.Fire.Billing.Pay(1, invoice.reference)
    assertFalse(ok)
    assertEq(reason, 'already_paid')
end)

test('a paid invoice cannot be voided away', function()
    loadServer()
    place(1)
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')

    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 100 })
    DAG.Fire.Billing.Pay(1, invoice.reference)

    local ok, reason = DAG.Fire.Billing.Void(invoice.reference)
    assertFalse(ok)
    assertEq(reason, 'already_paid')
end)

-- Automatic billing ----------------------------------------------------------

-- The one case where the server knows who to bill without being told: the
-- player whose own car caught fire.
test('a player-caused call bills the player who caused it', function()
    loadServer()
    onDuty(1)
    place(2, vector3(500.0, 500.0, 30.0))

    local call = DAG.Fire.Events.VehicleFire(2)
    call.extinguished = 2
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    local invoices = DAG.Fire.Billing.Outstanding('license:2')
    assertEq(#invoices, 1)
    assertEq(invoices[1].callId, call.id)
    assertEq(invoices[1].amount, 400, 'response plus two fires')
end)

test('an ambient call bills nobody automatically', function()
    loadServer()
    onDuty(1)

    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)
    call.fires, call.victims = {}, {}
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    assertEq(#DAG.Fire.Billing.Outstanding(), 0, 'there is no owner to bill')
end)

test('automatic billing can be switched off', function()
    loadServer()
    Config.Firefighter.billing.autoBill.playerCaused = false
    onDuty(1)
    place(2, vector3(500.0, 500.0, 30.0))

    local call = DAG.Fire.Events.VehicleFire(2)
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')
    assertEq(#DAG.Fire.Billing.Outstanding(), 0)
end)

-- The department account -------------------------------------------------------

test('an officer draws on the department account and a firefighter does not', function()
    loadServer()
    onDuty(1, true)
    onDuty(2)
    DAG.Fire.Billing.Deposit(1000)

    netEvent(2, 'mdt:withdraw', 500)
    assertEq(DAG.Fire.Billing.Balance(), 1000, 'not an officer')

    netEvent(1, 'mdt:withdraw', 500)
    assertEq(DAG.Fire.Billing.Balance(), 500)
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 500)
end)

test('the department cannot be overdrawn', function()
    loadServer()
    onDuty(1, true)
    DAG.Fire.Billing.Deposit(100)

    local ok, reason = DAG.Fire.Billing.Withdraw(1, 500, 'test')
    assertFalse(ok)
    assertEq(reason, 'insufficient_funds')
    assertEq(DAG.Fire.Billing.Balance(), 100)
end)

-- Reports ------------------------------------------------------------------------

test('a report needs a narrative worth reading', function()
    loadServer()
    onDuty(1)

    local ok, reason = DAG.Fire.Mdt.FileReport(1, 'FD-0001', 'ok')
    assertFalse(ok)
    assertEq(reason, 'narrative_too_short')
end)

test('filing a report pays a bonus, once per call', function()
    loadServer()
    local profile = onDuty(1)
    local beforeXp = profile.xp

    assertTrue(DAG.Fire.Mdt.FileReport(1, 'FD-0001', 'Single storey, well alight on arrival, two lines in.'))
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 150)
    assertTrue(DAG.Fire.State.ProfileFor('license:1').xp > beforeXp)

    local ok, reason = DAG.Fire.Mdt.FileReport(1, 'FD-0001', 'Trying to claim the bonus a second time.')
    assertFalse(ok)
    assertEq(reason, 'already_filed')
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 150)
end)

test('somebody with no department cannot file against the record', function()
    loadServer()
    place(1)

    local ok, reason = DAG.Fire.Mdt.FileReport(1, 'FD-0001', 'A perfectly good narrative from a stranger.')
    assertFalse(ok)
    assertEq(reason, 'not_employed')
end)

-- A report pulls what it can from the call it is filed against rather than
-- trusting the author to retype it.
test('a report inherits the facts from the call it is about', function()
    loadServer()
    onDuty(1)

    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)
    harness.placePlayer(1, vector3(call.coords.x, call.coords.y, call.coords.z))
    DAG.Fire.Dispatch.Tick()
    call.fires = {}
    for _, victim in pairs(call.victims) do victim.state = 'deceased' end
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    local ok, _, report = DAG.Fire.Mdt.FileReport(1, call.id, 'Fully involved on arrival, one casualty.')
    assertTrue(ok)
    assertEq(report.kind, 'structure')
    assertEq(report.location, call.location)
    assertEq(report.casualties, 1)
    assertEq(#report.units, 1)
end)

-- History and the dashboard --------------------------------------------------------

test('a closed call lands in the history the terminal reads', function()
    loadServer()
    onDuty(1)

    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)
    call.fires, call.victims = {}, {}
    call.extinguished = 3
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    local history
    DAG.Fire.Mdt.History('lsfd', 10, function(list) history = list end)
    assertEq(#history, 1)
    assertEq(history[1].id, call.id)
    assertEq(history[1].extinguished, 3)
    assertEq(history[1].outcome, 'under control')
end)

test('the dashboard is refused to somebody outside the department', function()
    loadServer()
    place(1)

    local answer = callback('mdt:dashboard', 1)
    assertFalse(answer.authorized)
end)

test('the dashboard reports the board, the roster and the books', function()
    loadServer()
    onDuty(1, true)
    DAG.Fire.Billing.Deposit(750)
    DAG.Fire.Billing.Create({ identifier = 'license:9', amount = 200 })
    DAG.Fire.Dispatch.Create('structure')

    local answer = callback('mdt:dashboard', 1)
    assertTrue(answer.authorized)
    assertEq(answer.department, 'lsfd')
    assertEq(#answer.calls, 1)
    assertEq(#answer.roster, 1)
    assertEq(answer.balance, 750)
    assertEq(answer.outstanding, 1)
    assertTrue(answer.canCommand)
end)

-- Billing from the terminal ----------------------------------------------------------

test('a firefighter bills the person standing at the terminal', function()
    loadServer()
    onDuty(1)
    place(2, vector3(2.0, 0.0, 0.0))

    netEvent(1, 'mdt:bill', 2, nil, 500, 'Cutting a car open')

    local invoices = DAG.Fire.Billing.Outstanding('license:2')
    assertEq(#invoices, 1)
    assertEq(invoices[1].amount, 500)
    assertEq(invoices[1].reason, 'Cutting a car open')
    assertEq(invoices[1].raisedBy, 'license:1')
end)

test('billing for a call is priced from the call, not from a typed number', function()
    loadServer()
    onDuty(1)
    place(2, vector3(2.0, 0.0, 0.0))

    local call = DAG.Fire.Dispatch.Create('structure')
    DAG.Fire.Dispatch.Join(1, call.id)
    call.fires, call.victims = {}, {}
    call.extinguished = 4
    DAG.Fire.Dispatch.Resolve(call.id, 'under control')

    netEvent(1, 'mdt:bill', 2, call.id, 999999)

    local invoices = DAG.Fire.Billing.Outstanding('license:2')
    assertEq(#invoices, 1)
    assertEq(invoices[1].amount, 550, 'response plus four fires, not the number typed')
end)

test('somebody off the roster cannot raise an invoice', function()
    loadServer()
    place(1)
    place(2, vector3(2.0, 0.0, 0.0))

    netEvent(1, 'mdt:bill', 2, nil, 500)
    assertEq(#DAG.Fire.Billing.Outstanding(), 0)
end)

test('only an officer voids an invoice', function()
    loadServer()
    onDuty(1)
    onDuty(3, true)
    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:9', amount = 200 })

    netEvent(1, 'mdt:void', invoice.reference)
    assertEq(#DAG.Fire.Billing.Outstanding(), 1, 'a firefighter cannot')

    netEvent(3, 'mdt:void', invoice.reference)
    assertEq(#DAG.Fire.Billing.Outstanding(), 0)
end)

test('a citizen reads and settles their own invoices without being on the roster', function()
    loadServer()
    place(1)
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')
    local invoice = DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 250 })

    local mine = callback('mdt:myInvoices', 1)
    assertEq(#mine, 1)
    assertEq(mine[1].reference, invoice.reference)

    netEvent(1, 'mdt:pay', invoice.reference)
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 750)
end)

-- Providers ----------------------------------------------------------------------

test('with no billing resource running the ledger is the whole story', function()
    loadServer()
    assertNil(DAG.Fire.Billing.Provider())
    assertNil(DAG.Fire.Billing.SocietyProvider())

    -- And an invoice still raises, which is the point of owning the ledger.
    assertTrue(DAG.Fire.Billing.Create({ identifier = 'license:1', amount = 100 }) ~= nil)
end)

test('a billing resource is mirrored into when one is running', function()
    harness.resourceStates['qb-phone'] = 'started'
    loadServer()
    place(2)

    local provider = DAG.Fire.Billing.Provider()
    assertEq(provider.id, 'qb-phone')

    DAG.Fire.Billing.Create({ identifier = 'license:2', amount = 300, target = 2 })
    local mirrored
    for _, entry in ipairs(harness.clientEvents) do
        if entry.event == 'qb-phone:client:AddInvoice' then mirrored = entry end
    end
    assertTrue(mirrored ~= nil, 'the phone was told')
    assertEq(mirrored.args[1].amount, 300)
end)

test('a provider that is not running is not used', function()
    loadServer()
    Config.Firefighter.billing.provider = 'esx_billing'
    assertNil(DAG.Fire.Billing.Provider(), 'esx_billing is not started')
end)
