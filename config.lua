Config = {}

-- auto selects the first started framework in priority order. You can instead
-- use: qbox, qb, esx, vrp, ox, or standalone.
Config.Framework = 'auto'

Config.FrameworkPriority = { 'qbox', 'qb', 'esx', 'vrp', 'ox', 'standalone' }
Config.Debug = false

-- Prints the active framework and any adapter methods it does not implement
-- when the resource starts. Leave this on: unsupported reads return nil, and
-- the startup line is where you find out which ones before shipping.
Config.ReportCapabilities = true

-- auto prefers ox_inventory/ox_lib when they are started, then falls back to
-- the selected framework. Set either option to 'framework' to disable this.
-- Note: on Qbox and Ox Core the framework-native inventory IS ox_inventory,
-- so 'framework' behaves identically to 'auto' on those cores.
Config.Inventory = 'auto' -- auto, ox, framework
Config.Notify = 'auto' -- auto, ox, framework, chat
-- auto: ox_lib, then qb-menu, then the bundled NUI menu in ui/.
-- Set 'nui' to always use the bundled menu even when ox_lib is installed.
-- 'chat' is a text-only fallback for servers that cannot run NUI.
Config.Menu = 'auto' -- auto, nui, ox, qb, chat

-- Applied to the bundled NUI menu only.
Config.MenuTheme = {
    accent = '#4c8dff',
    width = 384,          -- px
    position = 'right'    -- right, left, center, top
}

-- Name of the chat-fallback selection command, used only when no menu resource
-- is running. Defaults to '<resource-name>:select' so two resources built from
-- this template never register the same command.
Config.ChatSelectCommand = nil

Config.CallbackTimeout = 15000

-- Token bucket applied to the built-in callback transport, per player. Set to
-- false to disable. Frameworks with a native callback transport (QB, ESX) use
-- their own and are unaffected.
Config.CallbackRateLimit = { window = 10000, max = 40 }

Config.InteractionKey = 38 -- INPUT_CONTEXT / E
Config.InteractionDrawDistance = 15.0
Config.InteractionDistance = 2.0

Config.Storage = {
    file = 'data/storage.json',
    saveInterval = 5000 -- clamped to a 1000ms floor
}

-- Ox Core keeps cash as an ox_inventory item; change this if your server
-- renamed it. Other Ox Core accounts are reported as unsupported.
Config.Ox = {
    moneyItem = 'money'
}

-- Used only by the standalone adapter. Replace these hooks with your own
-- persistence/inventory implementation for a production standalone server.
Config.Standalone = {
    startingCash = 0,
    defaultJob = { name = 'unemployed', label = 'Unemployed', grade = 0, gradeName = 'none' }
}

-- Firefighter job (modules/firefighter). Declared here so the job is
-- discoverable from the main config file; the stations, apparatus, call types,
-- ranks, and payouts that fill this table live in modules/firefighter/config.lua
-- because they are long enough to drown everything above.
Config.Firefighter = {}
