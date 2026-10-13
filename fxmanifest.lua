-- fxmanifest.lua for NPCI Server Resource

fx_version 'cerulean'
game 'gta5'

author 'Original Author & opencode'
description 'Server-side AI NPC system based on the NPCI prototype.'

ui_page 'html/index.html'

files {
    'html/index.html'
}

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/config.lua',
    'server/main.lua',
    'server/sv_setupdatabase.lua',
    'server/phone_bridge.lua'
}

dependencies {
    'es_extended',
    'oxmysql',
    'pma-voice'
}
