local Menu = DAG.Menu
local focused = false

-- The bundled NUI menu. Self-contained: no external CDN, no ox_lib, no
-- qb-menu. It is what Config.Menu = 'auto' falls back to, and what
-- Config.Menu = 'nui' selects unconditionally.

local function theme()
    local configured = Config.MenuTheme or {}
    return {
        accent = configured.accent or '#4c8dff',
        width = configured.width or 384,
        position = configured.position or 'right'
    }
end

local function setFocus(enabled)
    if focused == enabled then return end
    focused = enabled
    SetNuiFocus(enabled, enabled)
end

-- Only the fields the front-end reads are sent. Handlers (onSelect, args,
-- event names) stay in Lua: nothing executable crosses into the browser, and
-- selections come back as an index.
local function serialize(options)
    local payload = {}
    for index, option in ipairs(options) do
        payload[index] = {
            title = option.title,
            description = option.description,
            icon = option.icon,
            badge = option.badge,
            badgeTone = option.badgeTone,
            progress = option.progress,
            disabled = option.disabled == true,
            header = option.header == true,
            submenu = option.menu ~= nil
        }
    end
    return payload
end

Menu.RegisterProvider('nui', {
    open = function(view)
        setFocus(true)
        SendNUIMessage({
            action = 'open',
            theme = theme(),
            menu = {
                title = view.title,
                subtitle = view.subtitle,
                breadcrumb = view.breadcrumb,
                canGoBack = view.canGoBack,
                options = serialize(view.options)
            }
        })
    end,
    close = function()
        setFocus(false)
        SendNUIMessage({ action = 'close' })
    end
})

RegisterNUICallback('select', function(data, reply)
    reply({})
    Menu.Select(data and data.index)
end)

RegisterNUICallback('back', function(_, reply)
    reply({})
    Menu.Back()
end)

-- The player dismissed the menu from the UI, so the panel is already hidden;
-- releasing focus and clearing Lua state is all that is left.
RegisterNUICallback('close', function(_, reply)
    reply({})
    setFocus(false)
    Menu.Close()
end)

-- Focus is a global input lock. Never leave it held across a resource restart.
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then setFocus(false) end
end)
