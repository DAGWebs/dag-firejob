fx_version 'cerulean'
game 'gta5'

author 'DAG'
description 'Framework-agnostic FiveM resource template with a full firefighter job'
version '1.2.0'

lua54 'yes'

shared_scripts {
    'config.lua',
    'bridge/shared.lua',
    'modules/firefighter/config.lua',
    'modules/firefighter/shared.lua'
}

client_scripts {
    'bridge/client.lua',
    'bridge/client/*.lua',
    'modules/menu/client.lua',
    'modules/menu/nui.lua',
    'modules/interactions/client.lua',
    'modules/firefighter/client/editor.lua',
    'modules/firefighter/client/state.lua',
    'modules/firefighter/client/fire.lua',
    'modules/firefighter/client/effects.lua',
    'modules/firefighter/client/hose.lua',
    'modules/firefighter/client/crew.lua',
    'modules/firefighter/client/mayday.lua',
    'modules/firefighter/client/rescue.lua',
    'modules/firefighter/client/uniform.lua',
    'modules/firefighter/client/events.lua',
    'modules/firefighter/client/duty.lua',
    'modules/firefighter/client/academy.lua',
    'modules/firefighter/client/mdt.lua',
    'modules/firefighter/client/hud.lua',
    'modules/firefighter/client/menus.lua',
    'client/main.lua'
}

ui_page 'ui/index.html'

files {
    'ui/index.html',
    'ui/style.css',
    'ui/app.js'
}

server_scripts {
    'bridge/server.lua',
    'bridge/server/*.lua',
    'modules/storage/server.lua',
    'modules/commands/server.lua',
    'modules/access/server.lua',
    'modules/repository/server.lua',
    'modules/firefighter/server/database.lua',
    'modules/firefighter/server/editor.lua',
    'modules/firefighter/server/state.lua',
    'modules/firefighter/server/incident.lua',
    'modules/firefighter/server/progression.lua',
    'modules/firefighter/server/jobs.lua',
    'modules/firefighter/server/departments.lua',
    'modules/firefighter/server/billing.lua',
    'modules/firefighter/server/dispatch.lua',
    'modules/firefighter/server/crew.lua',
    'modules/firefighter/server/mayday.lua',
    'modules/firefighter/server/academy.lua',
    'modules/firefighter/server/events.lua',
    'modules/firefighter/server/mdt.lua',
    'modules/firefighter/server/api.lua',
    'server/main.lua'
}
