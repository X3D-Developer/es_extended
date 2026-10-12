fx_version 'cerulean'

game 'gta5'
description 'ESX Legacy core -- X3D build. Modified from esx_core 1.13.4, GPL-3.0. See README.md.'
lua54 'yes'
version '1.13.4-x3d.1'

shared_scripts {
	'locale.lua',

	'shared/config/main.lua',
    'shared/config/weapons.lua',
    'shared/config/adjustments.lua',

    'shared/main.lua',
    'shared/functions.lua',
    'shared/modules/*.lua',
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
    'shared/config/logs.lua',

	'server/common.lua',
	'server/modules/restartlock.lua',
	'server/modules/serverlog.lua',
	'server/modules/callback.lua',
	'server/classes/player.lua',
	'server/classes/vehicle.lua',
	'server/classes/overrides/*.lua',
	'server/functions.lua',
	'server/modules/chatfilter.lua',
	'server/modules/onesync.lua',
	'server/modules/paycheck.lua',

	'server/main.lua',
	'server/modules/commands.lua',

	'server/bridge/**/*.lua',
	'server/modules/npwd.lua',
	'server/modules/createJob.lua',
	'server/migration/**/main.lua',
	'server/migration/main.lua',

	'server/modules/banner.lua',
}

client_scripts {
    'client/main.lua',
	'client/functions.lua',
	'client/modules/wrapper.lua',
	'client/modules/callback.lua',
    'client/modules/adjustments.lua',
	'client/modules/points.lua',

	'client/modules/events.lua',

	'client/modules/actions.lua',
	'client/modules/death.lua',
	'client/modules/npwd.lua',
    'client/modules/interactions.lua',
	'client/modules/scaleform.lua',
	'client/modules/streaming.lua',
	'client/modules/world.lua',
}

ui_page {
	'html/ui.html'
}

files {
	'imports.lua',
	'locales/*.lua',
	'locale.js',
	'html/ui.html',

	'html/css/app.css',

	'html/js/mustache.min.js',
	'html/js/wrapper.js',
	'html/js/app.js',

	'html/fonts/pdown.ttf',
	'html/fonts/bankgothic.ttf',
    "client/imports/*.lua",
}

dependencies {
	'/native:0x6AE51D4B',
    '/native:0xA61C8FC6',
	'oxmysql',
}
