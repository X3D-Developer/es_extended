Config = {}

local txAdminLocale = GetConvar("txAdmin-locale", "en")
local esxLocale = GetConvar("esx:locale", "invalid")
Config.Locale = (esxLocale ~= "invalid") and esxLocale or (txAdminLocale ~= "custom" and txAdminLocale) or "en"

-- For ox inventory, this will automatically be adjusted, do not change! For other inventories, leave as false unless specifically instructed to change.
Config.CustomInventory = false

-- Database table names. Defaults match a stock ESX database — only change these if
-- your database uses different names (queries are written as `{users}` and resolved here).
Config.Tables = {
    users = 'users',
    items = 'items',
    jobs = 'jobs',
    job_grades = 'job_grades',
    owned_vehicles = 'owned_vehicles',
    server_log = 'esx_server_log',
}

-- Where the money/item toast pulls its icon from. `%s` is the item name.
-- false = no icon (the notification still shows). Auto-detected below when left as nil.
Config.ItemIconUrl = nil

Config.Accounts = {
    bank = {
        label = TranslateCap("account_bank"),
        round = true,
    },
    black_money = {
        label = TranslateCap("account_black_money"),
        round = true,
    },
    money = {
        label = TranslateCap("account_money"),
        round = true,
    },
}

Config.StartingAccountMoney = { bank = 50000 }

Config.StartingInventoryItems = false -- table/false

Config.DefaultSpawns = { -- If you want to have more spawn positions and select them randomly uncomment commented code or add more locations
    { x = 222.2027, y = -864.0162, z = 30.2922, heading = 1.0 },
    --{x = 224.9865, y = -865.0871, z = 30.2922, heading = 1.0},
    --{x = 227.8436, y = -866.0400, z = 30.2922, heading = 1.0},
    --{x = 230.6051, y = -867.1450, z = 30.2922, heading = 1.0},
    --{x = 233.5459, y = -868.2626, z = 30.2922, heading = 1.0}
}

Config.AdminGroups = {
    ["owner"] = true,
    ["admin"] = true,
}

Config.ValidCharacterSets = { -- Only enable additional charsets if your server is multilingual. By default everything is false.
    ['el'] = false, -- Greek
    ['sr'] = false, -- Cyrillic
    ['he'] = false, -- Hebrew
    ['ar'] = false, -- Arabic
    ['zh-cn'] = false -- Chinese, Japanese, Korean
}

Config.EnablePaycheck = true -- enable paycheck
Config.LogPaycheck = false -- Logs paychecks to a nominated Discord channel via webhook (default is false)
Config.EnableSocietyPayouts = false -- pay from the society account that the player is employed at? Requirement: esx_society
Config.MaxWeight = 24 -- the max inventory weight without a backpack
Config.PaycheckInterval = 7 * 60000 -- how often to receive paychecks in milliseconds
Config.SaveDeathStatus = true -- Save the death status of a player (false = never respawn a character dead, but players can then relog to escape being downed)
Config.SaveHealthAndArmor = true -- Persist player health/armor across sessions (false = always spawn at full health, no armor)
Config.SaveInterval = 10 * 60000 -- how often every online player is flushed to the DB in milliseconds (rollback protection)
Config.EnableDebug = false -- Use Debug options?

-- Player data is loaded, then the loading screen fires `esx:playerReadyToSpawn` so the player
-- lands in the world only after they click ENTER WORLD. A loading screen without that handshake
-- never answers, so the player is spawned anyway after this many milliseconds.
-- Keep this well above how long someone might sit reading the loading screen -- it is a rescue
-- for a screen that never answers, not a deadline for the player. 0 = wait forever.
Config.EnterWorldTimeout = 120000

Config.RestartLock = {
    seconds = 600,
    kickSeconds = 120,
    -- Resources still allowed to move money/items during the lock. Add your UI-only and
    -- infrastructure resources here; never add anything that can pay out or hand over items.
    allow = {
        es_extended = true, esx_identity = true, esx_skin = true, skinchanger = true,
        x3d_skin = true, esx_menu_default = true, esx_menu_list = true, esx_menu_dialog = true,
    },
}

Config.DefaultJobDuty = true -- A players default duty status when changing jobs
Config.OffDutyPaycheckMultiplier = 0.5 -- The multiplier for off duty paychecks. 0.5 = 50% of the on duty paycheck

Config.Multichar = GetResourceState("esx_multicharacter") ~= "missing"
Config.Identity = true -- Select a character identity data before they have loaded in (this happens by default with multichar)
Config.DistanceGive = 4.0 -- Max distance when giving items, weapons etc.

Config.AdminLogging = false -- Logs the usage of certain commands by those with group.admin ace permissions (default is false)

-------------------------------------
-- DO NOT CHANGE BELOW THIS LINE !!!
-------------------------------------
if GetResourceState("ox_inventory") ~= "missing" then
    Config.CustomInventory = "ox"
end

if Config.ItemIconUrl == nil then
    if GetResourceState("nc_inventory") ~= "missing" then
        Config.ItemIconUrl = "nui://nc_inventory/html/img/items/%s.png"
    elseif GetResourceState("ox_inventory") ~= "missing" then
        Config.ItemIconUrl = "nui://ox_inventory/web/images/%s.png"
    else
        Config.ItemIconUrl = false
    end
end

Config.EnableDefaultInventory = Config.CustomInventory == false -- Display the default Inventory ( F2 )
Config.Identifier = GetConvar("esx:identifier", "license")