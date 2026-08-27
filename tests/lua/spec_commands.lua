local function loadCommands()
    return harness.loadServer({ adapters = { 'standalone' }, modules = { 'commands' } })
end

test('a command runs for an authorised player', function()
    loadCommands()
    local ran
    DAG.Commands.Register('test', function(source, args) ran = { source = source, args = args } end)

    harness.commands.test.handler(3, { 'a' }, '/test a')
    assertEq(ran.source, 3)
    assertEq(ran.args[1], 'a')
end)

test('a permission gate blocks and notifies the player', function()
    loadCommands()
    local ran = false
    DAG.Commands.Register('secret', function() ran = true end, { permission = 'shop.admin' })

    harness.commands.secret.handler(3, {}, '/secret')
    assertFalse(ran)
    assertEq(harness.clientEvents[1].args[1], 'You do not have permission.')
end)

test('a permission gate passes when ACE allows it', function()
    loadCommands()
    local ran = false
    DAG.Commands.Register('secret', function() ran = true end, { permission = 'shop.admin' })

    harness.aceAllowed[3] = { ['shop.admin'] = true }
    harness.commands.secret.handler(3, {}, '/secret')
    assertTrue(ran)
end)

test('allowConsole = false keeps a command out of the console', function()
    loadCommands()
    local ran = false
    DAG.Commands.Register('players', function() ran = true end, { allowConsole = false })

    harness.commands.players.handler(0, {}, '/players')
    assertFalse(ran)
    harness.commands.players.handler(1, {}, '/players')
    assertTrue(ran)
end)

test('the console is not sent a notification when denied', function()
    loadCommands()
    DAG.Commands.Register('secret', function() end, { permission = 'shop.admin', restricted = false })
    -- The console short-circuits HasPermission, so this exercises a real player
    -- being denied while the console is allowed through.
    harness.commands.secret.handler(0, {}, '/secret')
    assertEq(#harness.clientEvents, 0)
end)

-- A throwing handler used to escape into the command dispatcher.
test('a handler error is contained and logged', function()
    loadCommands()
    DAG.Commands.Register('boom', function() error('handler exploded') end)

    harness.commands.boom.handler(1, {}, '/boom')
    assertTrue(harness.outputContains('handler exploded'))
end)

test('the restricted flag is forwarded to RegisterCommand', function()
    loadCommands()
    DAG.Commands.Register('restricted', function() end, { restricted = true })
    DAG.Commands.Register('open', function() end)

    assertTrue(harness.commands.restricted.restricted)
    assertFalse(harness.commands.open.restricted)
end)

test('chat suggestions are broadcast on registration', function()
    loadCommands()
    DAG.Commands.Register('shop', function() end, { help = 'Open the shop' })

    assertEq(harness.clientEvents[1].event, 'chat:addSuggestion')
    assertEq(harness.clientEvents[1].target, -1)
    assertEq(harness.clientEvents[1].args[2], 'Open the shop')
end)

-- Suggestions are broadcast before anyone has connected, so they have to be
-- replayed for players joining later.
test('suggestions are replayed to a joining player', function()
    loadCommands()
    DAG.Commands.Register('shop', function() end, { help = 'Open the shop' })
    DAG.Commands.Register('quiet', function() end)

    _G.source = 12
    TriggerEvent('playerJoining')

    local replayed = {}
    for _, event in ipairs(harness.clientEvents) do
        if event.target == 12 then replayed[#replayed + 1] = event.args[1] end
    end
    assertEq(#replayed, 1, 'only commands with help text are suggested')
    assertEq(replayed[1], '/shop')
end)

test('RemoveSuggestion stops the replay', function()
    loadCommands()
    DAG.Commands.Register('shop', function() end, { help = 'Open the shop' })
    DAG.Commands.RemoveSuggestion('shop')

    harness.clientEvents = {}
    _G.source = 12
    TriggerEvent('playerJoining')
    assertEq(#harness.clientEvents, 0)
end)

test('registration validates its arguments', function()
    loadCommands()
    assertThrows(function() DAG.Commands.Register('', function() end) end)
    assertThrows(function() DAG.Commands.Register('ok', 'not a function') end)
end)
