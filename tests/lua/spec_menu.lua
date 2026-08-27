local function loadMenu()
    return harness.loadClient({
        adapters = { 'standalone' },
        modules = { 'menu' },
        files = { 'modules/menu/nui.lua' }
    })
end

local function selectVia(value)
    harness.commands[DAG.Menu.SelectCommand].handler(nil, { value })
end

-- Provider selection ------------------------------------------------------

test('the chat fallback command is namespaced to the resource', function()
    loadMenu()
    assertEq(DAG.Menu.SelectCommand, 'dag-template:select')
    assertTrue(harness.commands['dag-template:select'] ~= nil)
    assertNil(harness.commands.dagselect, 'no global name two resources would fight over')
end)

test('Config.ChatSelectCommand overrides the derived name', function()
    harness.loadConfig()
    Config.ChatSelectCommand = 'pick'
    harness.load('bridge/shared.lua')
    harness.load('bridge/client.lua')
    harness.load('bridge/client/standalone.lua')
    harness.load('modules/menu/client.lua')

    assertEq(DAG.Menu.SelectCommand, 'pick')
    assertTrue(harness.commands.pick ~= nil)
end)

-- The bundled NUI menu is the fallback now; chat is opt-in only.
test('auto falls back to the bundled NUI menu, not chat', function()
    loadMenu()
    assertEq(DAG.Menu.Provider(), 'nui')
end)

test('auto still respects ox_lib and qb-menu when installed', function()
    loadMenu()
    harness.resourceStates['qb-menu'] = 'started'
    assertEq(DAG.Menu.Provider(), 'qb')

    harness.resourceStates['ox_lib'] = 'started'
    assertEq(DAG.Menu.Provider(), 'ox')
end)

test("Config.Menu = 'nui' overrides an installed ox_lib", function()
    loadMenu()
    harness.resourceStates['ox_lib'] = 'started'
    Config.Menu = 'nui'
    assertEq(DAG.Menu.Provider(), 'nui')
end)

test('an explicit chat provider is still available', function()
    loadMenu()
    Config.Menu = 'chat'
    assertEq(DAG.Menu.Provider(), 'chat')
end)

test('an unknown provider name degrades to chat rather than erroring', function()
    loadMenu()
    Config.Menu = 'nonsense'
    assertEq(DAG.Menu.Provider(), 'chat')
end)

test('a provider can be registered by a resource', function()
    loadMenu()
    local opened
    DAG.Menu.RegisterProvider('custom', { open = function(view) opened = view.title end })
    Config.Menu = 'custom'

    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')
    assertEq(opened, 'Shop')
end)

test('a provider must supply an open function', function()
    loadMenu()
    assertThrows(function() DAG.Menu.RegisterProvider('bad', {}) end)
end)

-- NUI provider ------------------------------------------------------------

test('opening a menu sends it to the UI and takes NUI focus', function()
    loadMenu()
    DAG.Menu.Register({
        id = 'shop',
        title = 'General Store',
        subtitle = 'Open 24/7',
        options = { { title = 'Buy water', description = 'Costs $5', icon = 'cash', badge = '$5' } }
    })
    DAG.Menu.Open('shop')

    local message = harness.lastNuiMessage()
    assertEq(message.action, 'open')
    assertEq(message.menu.title, 'General Store')
    assertEq(message.menu.subtitle, 'Open 24/7')
    assertEq(message.menu.options[1].badge, '$5')
    assertEq(message.menu.options[1].icon, 'cash')
    assertTrue(harness.nuiFocus.focus)
    assertTrue(harness.nuiFocus.cursor)
end)

-- Nothing executable may cross into the browser context.
test('handlers and event names are never sent to the UI', function()
    loadMenu()
    DAG.Menu.Register({
        id = 'shop',
        title = 'Shop',
        options = { {
            title = 'Buy',
            onSelect = function() end,
            serverEvent = 'shop:secretInternalEvent',
            args = { token = 'sensitive' }
        } }
    })
    DAG.Menu.Open('shop')

    local option = harness.lastNuiMessage().menu.options[1]
    assertNil(option.onSelect)
    assertNil(option.serverEvent)
    assertNil(option.args)
    assertEq(option.title, 'Buy')
end)

test('a submenu option is flagged so the UI can show a chevron', function()
    loadMenu()
    DAG.Menu.Register({ id = 'sub', title = 'Sub', options = { { title = 'Back' } } })
    DAG.Menu.Register({ id = 'root', title = 'Root', options = {
        { title = 'Open', menu = 'sub' },
        { title = 'Plain' }
    } })
    DAG.Menu.Open('root')

    local options = harness.lastNuiMessage().menu.options
    assertTrue(options[1].submenu)
    assertFalse(options[2].submenu)
end)

test('the configured theme is sent with the menu', function()
    loadMenu()
    Config.MenuTheme = { accent = '#ff0055', width = 420, position = 'center' }
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    local theme = harness.lastNuiMessage().theme
    assertEq(theme.accent, '#ff0055')
    assertEq(theme.width, 420)
    assertEq(theme.position, 'center')
end)

test('the theme falls back to defaults when unconfigured', function()
    loadMenu()
    Config.MenuTheme = nil
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    assertEq(harness.lastNuiMessage().theme.position, 'right')
end)

test('the UI select callback routes to the option handler', function()
    loadMenu()
    local chosen
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Buy', onSelect = function() chosen = 'buy' end }
    } })
    DAG.Menu.Open('shop')

    harness.nuiCallbacks.select({ index = 1 }, function() end)
    assertEq(chosen, 'buy')
end)

test('closing releases NUI focus', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')
    DAG.Menu.Close()

    assertFalse(harness.nuiFocus.focus)
    assertEq(harness.lastNuiMessage().action, 'close')
end)

test('the UI close callback releases focus and clears state', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    harness.nuiCallbacks.close({}, function() end)
    assertFalse(harness.nuiFocus.focus)
    assertNil(DAG.Menu.Current())
end)

-- Focus is a global input lock; leaving it held would freeze the player.
test('stopping the resource releases a held NUI focus', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    TriggerEvent('onClientResourceStop', 'dag-template')
    assertFalse(harness.nuiFocus.focus)
end)

test('stopping another resource does not release focus', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    TriggerEvent('onClientResourceStop', 'some-other-resource')
    assertTrue(harness.nuiFocus.focus)
end)

-- Navigation --------------------------------------------------------------

test('entering a submenu builds a breadcrumb and enables Back', function()
    loadMenu()
    DAG.Menu.Register({ id = 'sub', title = 'Vehicles', options = { { title = 'Store' } } })
    DAG.Menu.Register({ id = 'root', title = 'Garage', options = { { title = 'Vehicles', menu = 'sub' } } })

    DAG.Menu.Open('root')
    assertFalse(harness.lastNuiMessage().menu.canGoBack)

    DAG.Menu.Select(1)
    local message = harness.lastNuiMessage()
    assertEq(message.menu.title, 'Vehicles')
    assertEq(message.menu.breadcrumb, 'Garage')
    assertTrue(message.menu.canGoBack)
end)

test('Back returns to the parent menu', function()
    loadMenu()
    DAG.Menu.Register({ id = 'sub', title = 'Vehicles', options = { { title = 'Store' } } })
    DAG.Menu.Register({ id = 'root', title = 'Garage', options = { { title = 'Vehicles', menu = 'sub' } } })

    DAG.Menu.Open('root')
    DAG.Menu.Select(1)
    DAG.Menu.Back()

    assertEq(DAG.Menu.Current(), 'root')
    assertEq(harness.lastNuiMessage().menu.title, 'Garage')
end)

test('the breadcrumb accumulates across nested levels', function()
    loadMenu()
    DAG.Menu.Register({ id = 'c', title = 'Colours', options = { { title = 'Red' } } })
    DAG.Menu.Register({ id = 'b', title = 'Paint', options = { { title = 'Colours', menu = 'c' } } })
    DAG.Menu.Register({ id = 'a', title = 'Customs', options = { { title = 'Paint', menu = 'b' } } })

    DAG.Menu.Open('a')
    DAG.Menu.Select(1)
    DAG.Menu.Select(1)

    assertEq(harness.lastNuiMessage().menu.breadcrumb, 'Customs / Paint')
end)

test('Back from the root closes the menu', function()
    loadMenu()
    DAG.Menu.Register({ id = 'root', title = 'Garage', options = { { title = 'Store' } } })
    DAG.Menu.Open('root')
    DAG.Menu.Back()

    assertNil(DAG.Menu.Current())
    assertFalse(harness.nuiFocus.focus)
end)

test('the UI back callback navigates up', function()
    loadMenu()
    DAG.Menu.Register({ id = 'sub', title = 'Vehicles', options = { { title = 'Store' } } })
    DAG.Menu.Register({ id = 'root', title = 'Garage', options = { { title = 'Vehicles', menu = 'sub' } } })

    DAG.Menu.Open('root')
    DAG.Menu.Select(1)
    harness.nuiCallbacks.back({}, function() end)

    assertEq(DAG.Menu.Current(), 'root')
end)

test('re-opening a menu from outside resets the trail', function()
    loadMenu()
    DAG.Menu.Register({ id = 'sub', title = 'Vehicles', options = { { title = 'Store' } } })
    DAG.Menu.Register({ id = 'root', title = 'Garage', options = { { title = 'Vehicles', menu = 'sub' } } })

    DAG.Menu.Open('root')
    DAG.Menu.Select(1)
    DAG.Menu.Open('root')

    assertFalse(harness.lastNuiMessage().menu.canGoBack, 'no stale Back into an old trail')
end)

-- Selection semantics -----------------------------------------------------

test('selecting an option closes the menu by default', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')
    DAG.Menu.Select(1)

    assertNil(DAG.Menu.Current())
    assertFalse(harness.nuiFocus.focus)
end)

test('keepOpen leaves the menu on screen', function()
    loadMenu()
    local count = 0
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Buy', keepOpen = true, onSelect = function() count = count + 1 end }
    } })
    DAG.Menu.Open('shop')

    DAG.Menu.Select(1)
    DAG.Menu.Select(1)
    assertEq(count, 2)
    assertEq(DAG.Menu.Current(), 'shop')
end)

test('a disabled option cannot be selected', function()
    loadMenu()
    local chosen = false
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Buy', disabled = true, onSelect = function() chosen = true end }
    } })
    DAG.Menu.Open('shop')
    DAG.Menu.Select(1)

    assertFalse(chosen)
    assertEq(DAG.Menu.Current(), 'shop', 'a rejected selection does not close the menu')
end)

test('a header row is not selectable', function()
    loadMenu()
    local chosen = false
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Section', header = true, onSelect = function() chosen = true end },
        { title = 'Buy' }
    } })
    DAG.Menu.Open('shop')
    DAG.Menu.Select(1)

    assertFalse(chosen)
    assertTrue(harness.lastNuiMessage().menu.options[1].header)
end)

test('an option can trigger a client or server event', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Local', event = 'shop:local', args = { a = 1 } },
        { title = 'Remote', serverEvent = 'shop:remote', args = { b = 2 } }
    } })

    DAG.Menu.Open('shop')
    DAG.Menu.Select(1)
    DAG.Menu.Open('shop')
    DAG.Menu.Select(2)

    local sawLocal = false
    for _, event in ipairs(harness.localEvents) do
        if event.event == 'shop:local' then sawLocal = true end
    end
    assertTrue(sawLocal)
    assertEq(harness.serverEvents[1].event, 'shop:remote')
end)

test('an out-of-range or non-numeric selection is ignored', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')

    DAG.Menu.Select(99)
    DAG.Menu.Select('abc')
    DAG.Menu.Select(nil)
    assertEq(DAG.Menu.Current(), 'shop')
end)

test('selecting with no menu open does nothing', function()
    loadMenu()
    DAG.Menu.Select(1)
    selectVia('1')
end)

test('the chat command still routes selections', function()
    loadMenu()
    Config.Menu = 'chat'
    local chosen
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Buy', onSelect = function() chosen = 'buy' end }
    } })
    DAG.Menu.Open('shop')
    selectVia('1')

    assertEq(chosen, 'buy')
end)

test('the chat fallback lists selectable options and skips headers', function()
    loadMenu()
    Config.Menu = 'chat'
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = {
        { title = 'Section', header = true },
        { title = 'Buy', description = 'Spend money' },
        { title = 'Sell' }
    } })
    DAG.Menu.Open('shop')

    local messages = 0
    for _, event in ipairs(harness.localEvents) do
        if event.event == 'chat:addMessage' then messages = messages + 1 end
    end
    assertEq(messages, 3, 'a header line plus the two selectable options')
end)

-- Definitions and lifecycle ----------------------------------------------

test('opening an unknown menu throws rather than failing silently', function()
    loadMenu()
    assertThrows(function() DAG.Menu.Open('nope') end)
end)

test('a menu definition requires an id and options', function()
    loadMenu()
    assertThrows(function() DAG.Menu.Register({ options = {} }) end)
    assertThrows(function() DAG.Menu.Register({ id = 'a' }) end)
end)

test('Unregister clears the active menu and its trail', function()
    loadMenu()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Menu.Open('shop')
    DAG.Menu.Unregister('shop')

    assertNil(DAG.Menu.Get('shop'))
    assertNil(DAG.Menu.Current())
    DAG.Menu.Select(1)
end)

-- Confirm -----------------------------------------------------------------

test('Confirm cleans up its menu once answered', function()
    loadMenu()
    local answered
    local id = DAG.Menu.Confirm('Delete?', 'Permanent.', function(value) answered = value end)

    assertTrue(DAG.Menu.Get(id) ~= nil, 'registered while open')
    DAG.Menu.Get(id).options[1].onSelect()

    assertTrue(answered)
    assertNil(DAG.Menu.Get(id), 'unregistered after answering')
end)

test('repeated confirmations do not accumulate menus', function()
    loadMenu()
    local ids = {}
    for _ = 1, 5 do
        harness.gameTimer = harness.gameTimer + 100
        local id = DAG.Menu.Confirm('Delete?', nil, function() end)
        ids[id] = true
        DAG.Menu.Get(id).options[2].onSelect()
    end

    local count = 0
    for _ in pairs(ids) do count = count + 1 end
    assertEq(count, 1, 'one stable id, not one per call')
end)

test('Confirm answers exactly once', function()
    loadMenu()
    local calls = 0
    local id = DAG.Menu.Confirm('Delete?', nil, function() calls = calls + 1 end)
    local options = DAG.Menu.Get(id).options

    options[1].onSelect()
    options[1].onSelect()
    options[2].onSelect()
    assertEq(calls, 1)
end)

test('Cancel reports false', function()
    loadMenu()
    local answered = 'unset'
    local id = DAG.Menu.Confirm('Delete?', nil, function(value) answered = value end)
    DAG.Menu.Get(id).options[2].onSelect()
    assertFalse(answered)
end)

test('Confirm shows its description as the menu subtitle', function()
    loadMenu()
    DAG.Menu.Confirm('Delete vehicle?', 'This cannot be undone.', function() end)
    assertEq(harness.lastNuiMessage().menu.subtitle, 'This cannot be undone.')
end)

-- Input -------------------------------------------------------------------

test('Input reports when no provider is available', function()
    loadMenu()
    local values, reason
    DAG.Menu.Input('Label', { { name = 'a' } }, function(value, err) values, reason = value, err end)

    assertNil(values)
    assertEq(reason, 'unsupported')
end)

test('Input maps fields onto the qb-input shape', function()
    loadMenu()
    local received
    harness.resourceStates['qb-input'] = 'started'
    harness.exportTargets['qb-input'] = {
        ShowInput = function(_, payload) received = payload return { a = 'value' } end
    }

    local result
    DAG.Menu.Input('Label', { { name = 'a', label = 'Field A', required = true } }, function(value)
        result = value
    end)

    assertEq(received.header, 'Label')
    assertEq(received.inputs[1].name, 'a')
    assertEq(received.inputs[1].text, 'Field A')
    assertTrue(received.inputs[1].isRequired)
    assertEq(result.a, 'value')
end)
