fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'NOVA Framework'
description 'Advanced synchronized vehicle radio for NOVA, QBCore and ESX'
version '1.8.0'

dependencies {
    'olisound',
    'oxmysql',
    '/onesync'
}

shared_script 'shared/config.lua'
client_scripts { 'client/framework.lua', 'client/main.lua' }
server_scripts { '@oxmysql/lib/MySQL.lua', 'server/character.lua', 'server/framework.lua', 'server/main.lua' }

ui_page 'web/index-162.html'
files {
    'web/index-162.html',
    'web/style-162.css',
    'web/app-162.js'
}
