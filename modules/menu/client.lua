DAG.Menu = DAG.Menu or {}
local Menu = DAG.Menu
local Bridge = DAG.Framework
local menus, providers = {}, {}
local stack, activeMenu = {}, nil

-- Derived from the resource name so two resources built from this template do
-- not both register the same global command. Override per resource if you want
-- something shorter to type.
local selectCommand = Config.ChatSelectCommand or (Bridge.namespace .. ':select')
Menu.SelectCommand = selectCommand

-- Providers render a normalized menu. Registering one here is all it takes to
-- add a backend; see modules/menu/nui.lua for the bundled implementation.
function Menu.RegisterProvider(name, provider)
    assert(type(name) == 'string' and type(provider) == 'table', 'Invalid menu provider')
    assert(type(provider.open) == 'function', 'A menu provider requires an open function')
    providers[name] = provider
end

function Menu.HasProvider(name)
    return providers[name] ~= nil
end

local function detectProvider()
    if Config.Menu ~= 'auto' then return Config.Menu end
    if GetResourceState('ox_lib') == 'started' then return 'ox' end
    if GetResourceState('qb-menu') == 'started' then return 'qb' end
    -- The bundled NUI menu, not the chat fallback: chat is now opt-in only.
    return 'nui'
end

function Menu.Provider()
    local name = detectProvider()
    if providers[name] then return name end
    return 'chat'
end

local function activeProvider()
    return providers[Menu.Provider()]
end

function Menu.Register(definition)
    assert(type(definition) == 'table' and type(definition.id) == 'string', 'Invalid menu definition')
    assert(type(definition.options) == 'table', 'A menu requires options')
    menus[definition.id] = definition
    return definition.id
end

function Menu.Unregister(id)
    menus[id] = nil
    if activeMenu == id then
        activeMenu = nil
        stack = {}
    end
end

function Menu.Get(id)
    return menus[id]
end

function Menu.Current()
    return activeMenu
end

-- Normalized view handed to a provider. Keeping the shape flat means a
-- provider never has to know about the navigation stack.
local function buildView(menu)
    local trail = {}
    for index = 1, #stack - 1 do
        local parent = menus[stack[index]]
        trail[#trail + 1] = parent and parent.title or stack[index]
    end

    return {
        id = menu.id,
        title = menu.title,
        subtitle = menu.subtitle,
        breadcrumb = #trail > 0 and table.concat(trail, ' / ') or nil,
        canGoBack = #stack > 1,
        options = menu.options
    }
end

local function show(id)
    local menu = menus[id]
    assert(menu, ('Unknown menu "%s"'):format(tostring(id)))
    activeMenu = id

    local provider = activeProvider()
    provider.open(buildView(menu))
    return id
end

-- Entering a menu from outside resets the trail; option.menu navigation
-- pushes onto it so Back has somewhere to return to.
function Menu.Open(id)
    stack = { id }
    return show(id)
end

function Menu.Navigate(id)
    stack[#stack + 1] = id
    return show(id)
end

function Menu.Back()
    if #stack <= 1 then return Menu.Close() end
    stack[#stack] = nil
    return show(stack[#stack])
end

function Menu.Close()
    local provider = activeProvider()
    if provider and provider.close then provider.close() end
    activeMenu = nil
    stack = {}
end

local function selectOption(option)
    if not option or option.disabled or option.header then return end
    if option.menu then return Menu.Navigate(option.menu) end

    if not option.keepOpen then Menu.Close() end
    if option.onSelect then option.onSelect(option.args) end
    if option.event then TriggerEvent(option.event, option.args) end
    if option.serverEvent then TriggerServerEvent(option.serverEvent, option.args) end
end

-- Called by providers with a 1-based index into the active menu's options.
function Menu.Select(index)
    local menu = activeMenu and menus[activeMenu]
    if not menu then return end
    selectOption(menu.options[tonumber(index) or 0])
end

function Menu.Input(title, fields, callback)
    assert(type(fields) == 'table' and type(callback) == 'function', 'Invalid menu input')

    if GetResourceState('ox_lib') == 'started' then
        return callback(exports.ox_lib:inputDialog(title, fields))
    end

    if GetResourceState('qb-input') == 'started' then
        local inputs = {}
        for index, field in ipairs(fields) do
            inputs[index] = {
                text = field.label or field.name,
                name = field.name or tostring(index),
                type = field.type or 'text',
                isRequired = field.required == true,
                default = field.default
            }
        end
        return callback(exports['qb-input']:ShowInput({ header = title, submitText = 'Confirm', inputs = inputs }))
    end

    Bridge.Notify('No supported input provider is running.', 'error')
    callback(nil, 'unsupported')
end

-- The confirmation menu is torn down once answered. Registering a new id per
-- call (previously keyed on GetGameTimer) leaked one menu definition per
-- confirmation for the lifetime of the session.
function Menu.Confirm(title, description, callback)
    assert(type(callback) == 'function', 'Invalid confirmation callback')
    local id = Bridge.Event('menu:confirm')
    local answered = false

    local function answer(confirmed)
        if answered then return end
        answered = true
        Menu.Unregister(id)
        callback(confirmed)
    end

    Menu.Register({
        id = id,
        title = title,
        subtitle = description,
        options = {
            { title = 'Confirm', icon = 'check', badgeTone = 'success', onSelect = function() answer(true) end },
            { title = 'Cancel', icon = 'close', onSelect = function() answer(false) end }
        }
    })
    Menu.Open(id)
    return id
end

-- Providers ---------------------------------------------------------------

Menu.RegisterProvider('ox', {
    open = function(view)
        local options = {}
        for index, option in ipairs(view.options) do
            options[index] = {
                title = option.title,
                description = option.description,
                icon = option.icon,
                disabled = option.disabled or option.header,
                readOnly = option.header,
                metadata = option.badge and { { label = option.badge } } or option.metadata,
                progress = option.progress,
                onSelect = function() Menu.Select(index) end
            }
        end

        exports.ox_lib:registerContext({
            id = view.id,
            title = view.title,
            menu = view.canGoBack and 'back' or nil,
            options = options
        })
        exports.ox_lib:showContext(view.id)
    end,
    close = function() exports.ox_lib:hideContext() end
})

Menu.RegisterProvider('qb', {
    open = function(view)
        local options = { { header = view.title, txt = view.subtitle, isMenuHeader = true } }
        for index, option in ipairs(view.options) do
            options[#options + 1] = {
                header = option.badge and ('%s  [%s]'):format(option.title, option.badge) or option.title,
                txt = option.description,
                disabled = option.disabled,
                isMenuHeader = option.header,
                action = not option.header and function() Menu.Select(index) end or nil
            }
        end
        exports['qb-menu']:openMenu(options)
    end,
    close = function() exports['qb-menu']:closeMenu() end
})

-- Text-only fallback for servers that cannot run NUI at all.
Menu.RegisterProvider('chat', {
    open = function(view)
        TriggerEvent('chat:addMessage', {
            args = { view.title, ('Use /%s <number> to choose:'):format(selectCommand) }
        })
        for index, option in ipairs(view.options) do
            if not option.header then
                local suffix = option.description and (' - ' .. option.description) or ''
                TriggerEvent('chat:addMessage', { args = { tostring(index), option.title .. suffix } })
            end
        end
    end
})

RegisterCommand(selectCommand, function(_, args)
    Menu.Select(args[1])
end, false)

exports('GetMenu', function() return Menu end)
