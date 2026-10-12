---@param msg string
---@return nil
function ESX.Trace(msg)
    if Config.EnableDebug then
        print(("[^2TRACE^7] %s^7"):format(msg))
    end
end

--- Triggers an event for one or more clients.
---@param eventName string The name of the event to trigger.
---@param playerIds table|number If a number, represents a single player ID. If a table, represents an array of player IDs.
---@param ... any Additional arguments to pass to the event handler.
function ESX.TriggerClientEvent(eventName, playerIds, ...)
    if type(playerIds) == "number" then
        TriggerClientEvent(eventName, playerIds, ...)
        return
    end

    local payload = msgpack.pack_args(...)
    local payloadLength = #payload

    for i = 1, #playerIds do
        TriggerClientEventInternal(eventName, playerIds[i], payload, payloadLength)
    end
end

---@param name string | table
---@param group string | table
---@param cb function
---@param allowConsole? boolean
---@param suggestion? table
function ESX.RegisterCommand(name, group, cb, allowConsole, suggestion)
    if type(name) == "table" then
        for _, v in ipairs(name) do
            ESX.RegisterCommand(v, group, cb, allowConsole, suggestion)
        end
        return
    end

    if Core.RegisteredCommands[name] then
        print(('[^3WARNING^7] Command ^5"%s" ^7already registered, overriding command'):format(name))

        if Core.RegisteredCommands[name].suggestion then
            TriggerClientEvent("chat:removeSuggestion", -1, ("/%s"):format(name))
        end
    end

    if suggestion then
        if not suggestion.arguments then
            suggestion.arguments = {}
        end
        if not suggestion.help then
            suggestion.help = ""
        end

        TriggerClientEvent("chat:addSuggestion", -1, ("/%s"):format(name), suggestion.help, suggestion.arguments)
    end

    Core.RegisteredCommands[name] = { group = group, cb = cb, allowConsole = allowConsole, suggestion = suggestion }

    RegisterCommand(name, function(playerId, args)
        local command = Core.RegisteredCommands[name]

        if not command.allowConsole and playerId == 0 then
            print(("[^3WARNING^7] ^5%s^0"):format(TranslateCap("commanderror_console")))
        else
            local xPlayer, err = ESX.Players[playerId], nil

            if command.suggestion then
                if command.suggestion.validate then
                    if #args ~= #command.suggestion.arguments then
                        err = TranslateCap("commanderror_argumentmismatch", #args, #command.suggestion.arguments)
                    end
                end

                if not err and command.suggestion.arguments then
                    local newArgs = {}

                    for k, v in ipairs(command.suggestion.arguments) do
                        if v.type then
                            if v.type == "number" then
                                local newArg = tonumber(args[k])

                                if newArg then
                                    newArgs[v.name] = newArg
                                else
                                    err = TranslateCap("commanderror_argumentmismatch_number", k)
                                end
                            elseif v.type == "player" or v.type == "playerId" then
                                local targetPlayer = tonumber(args[k])

                                if args[k] == "me" then
                                    targetPlayer = playerId
                                end

                                if targetPlayer then
                                    local xTargetPlayer = ESX.GetPlayerFromId(targetPlayer)

                                    if xTargetPlayer then
                                        if v.type == "player" then
                                            newArgs[v.name] = xTargetPlayer
                                        else
                                            newArgs[v.name] = targetPlayer
                                        end
                                    else
                                        err = TranslateCap("commanderror_invalidplayerid")
                                    end
                                else
                                    err = TranslateCap("commanderror_argumentmismatch_number", k)
                                end
                            elseif v.type == "string" then
                                local newArg = tonumber(args[k])
                                if not newArg then
                                    newArgs[v.name] = args[k]
                                else
                                    err = TranslateCap("commanderror_argumentmismatch_string", k)
                                end
                            elseif v.type == "item" then
                                if ESX.Items[args[k]] then
                                    newArgs[v.name] = args[k]
                                else
                                    err = TranslateCap("commanderror_invaliditem")
                                end
                            elseif v.type == "weapon" then
                                if ESX.GetWeapon(args[k]) then
                                    newArgs[v.name] = string.upper(args[k])
                                else
                                    err = TranslateCap("commanderror_invalidweapon")
                                end
                            elseif v.type == "any" then
                                newArgs[v.name] = args[k]
                            elseif v.type == "merge" then
                                -- OPTIMIZATION: Use table.concat with start index
                                -- Instead of: concat all -> calculate offset -> substring
                                -- Just concat from index k directly
                                newArgs[v.name] = table.concat(args, " ", k)
                            elseif v.type == "coordinate" then
                                local coord = tonumber(args[k]:match("(-?%d+%.?%d*)"))
                                if not coord then
                                    err = TranslateCap("commanderror_argumentmismatch_number", k)
                                else
                                    newArgs[v.name] = coord
                                end
                            end
                        end
                        
                        if ESX.IsFunctionReference(v.Validator?.validate) and not err then
                            local candidate = newArgs[v.name]
                            local ok, res = pcall(v.Validator.validate, candidate)
                            if not ok or res ~= true then
                                err = v.Validator.err or TranslateCap("commanderror_argumentmismatch")
                            end
                        end

                        --backwards compatibility
                        if v.validate ~= nil and not v.validate then
                            err = nil
                        end

                        if err then
                            break
                        end
                    end

                    args = newArgs
                end
            end

            if err then
                if playerId == 0 then
                    print(("[^3WARNING^7] %s^7"):format(err))
                else
                    xPlayer.showNotification(err)
                end
            else
                cb(xPlayer or false, args, function(msg)
                    if playerId == 0 then
                        print(("[^3WARNING^7] %s^7"):format(msg))
                    else
                        xPlayer.showNotification(msg)
                    end
                end)
            end
        end
    end, true)

    if type(group) == "table" then
        for _, v in ipairs(group) do
            ExecuteCommand(("add_ace group.%s command.%s allow"):format(v, name))
        end
    else
        ExecuteCommand(("add_ace group.%s command.%s allow"):format(group, name))
    end
end

local function updateHealthAndArmorInMetadata(xPlayer)
    local ped = GetPlayerPed(xPlayer.source)
    local currentHealth = GetEntityHealth(ped)
    local currentArmor = GetPedArmour(ped)
    local currentPlaytime = xPlayer.getPlayTime()

    local metadata = xPlayer.metadata

    -- A ped already culled on drop (server restart / kick) reports health 0 — persisting
    -- that spawns the character dead on the next login. Same guard as getSaveCoords below.
    if ped == 0 or not DoesEntityExist(ped) then
        metadata.lastPlaytime = currentPlaytime
        return
    end

    if not Config.SaveHealthAndArmor then
        metadata.lastPlaytime = currentPlaytime
        return
    end

    local changed = currentHealth ~= metadata.health or currentArmor ~= metadata.armor

    metadata.health = currentHealth
    metadata.armor = currentArmor
    metadata.lastPlaytime = currentPlaytime

    -- metadata is mutated directly here (setMeta would re-encode on every tick), so the
    -- cached JSON must be invalidated by hand or SavePlayer writes the previous values
    if changed then
        xPlayer._dirty.metadata = true
        xPlayer._cache.metadata = nil
    end
end

-- A dropped/kicked ped is already culled when the save runs, so the guard above bails and
-- SavePlayer writes whatever the last successful refresh left behind. Keep that snapshot
-- fresh in memory (no DB write) so a shutdown never persists more than this much staleness.
CreateThread(function()
    while true do
        Wait(30000)

        for _, xPlayer in pairs(ESX.Players) do
            if xPlayer.spawned then
                updateHealthAndArmorInMetadata(xPlayer)
            end
        end
    end
end)

-- A ped that was never spawned (or already culled on drop) reports ~(0,0,0) — never
-- persist that or every later session spawns the player at map origin
local function getSaveCoords(xPlayer)
    local saveCoords = xPlayer.getCoords(false, true)

    if math.abs(saveCoords.x) < 1.0 and math.abs(saveCoords.y) < 1.0 then
        local loginCoords = xPlayer.coords or {}
        saveCoords = { x = loginCoords.x or 0.0, y = loginCoords.y or 0.0, z = loginCoords.z or 0.0, heading = loginCoords.heading or 0.0 }
    end

    return saveCoords
end

---@param xPlayer table
---@param cb? function
---@return nil
function Core.SavePlayer(xPlayer, cb)
    if not xPlayer.spawned then
        return cb and cb()
    end

    updateHealthAndArmorInMetadata(xPlayer)

    -- OPTIMIZATION: Use cached JSON encoding if data hasn't changed (dirty tracking)
    local cache = xPlayer._cache or {}
    local dirty = xPlayer._dirty or {}

    -- Accounts - only re-encode if dirty
    local accountsJson
    if dirty.accounts or not cache.accounts then
        accountsJson = json.encode(xPlayer.getAccounts(true))
        cache.accounts = accountsJson
        dirty.accounts = false
    else
        accountsJson = cache.accounts
    end

    -- Inventory - only re-encode if dirty
    local inventoryJson
    if dirty.inventory or not cache.inventory then
        inventoryJson = json.encode(xPlayer.getInventory(true))
        cache.inventory = inventoryJson
        dirty.inventory = false
    else
        inventoryJson = cache.inventory
    end

    -- Loadout - only re-encode if dirty
    local loadoutJson
    if dirty.loadout or not cache.loadout then
        loadoutJson = json.encode(xPlayer.getLoadout(true))
        cache.loadout = loadoutJson
        dirty.loadout = false
    else
        loadoutJson = cache.loadout
    end

    -- Metadata - only re-encode if dirty
    local metadataJson
    if dirty.metadata or not cache.metadata then
        metadataJson = json.encode(xPlayer.getMeta())
        cache.metadata = metadataJson
        dirty.metadata = false
    else
        metadataJson = cache.metadata
    end

    -- Position always needs to be fresh
    local positionJson = json.encode(getSaveCoords(xPlayer))

    local parameters <const> = {
        accountsJson,
        xPlayer.job.name,
        xPlayer.job.grade,
        xPlayer.group,
        positionJson,
        inventoryJson,
        loadoutJson,
        metadataJson,
        xPlayer.identifier,
    }

    MySQL.prepare(
        ESX.Q("UPDATE `{users}` SET `accounts` = ?, `job` = ?, `job_grade` = ?, `group` = ?, `position` = ?, `inventory` = ?, `loadout` = ?, `metadata` = ? WHERE `identifier` = ?"),
        parameters,
        function(affectedRows)
            if affectedRows == 1 then
                print(('[^2INFO^7] Saved player ^5"%s^7"'):format(xPlayer.name))
                TriggerEvent("esx:playerSaved", xPlayer.playerId, xPlayer)
            end
            if cb then
                cb()
            end
        end
    )
end

---@param cb? function
---@return nil
function Core.SavePlayers(cb)
    local xPlayers <const> = ESX.Players
    if not next(xPlayers) then
        return
    end

    local startTime <const> = GetGameTimer()
    local parameters = {}

    for _, xPlayer in pairs(ESX.Players) do
        updateHealthAndArmorInMetadata(xPlayer)

        -- OPTIMIZATION: Use cached JSON encoding if data hasn't changed (dirty tracking)
        local cache = xPlayer._cache or {}
        local dirty = xPlayer._dirty or {}

        -- Accounts - only re-encode if dirty
        local accountsJson
        if dirty.accounts or not cache.accounts then
            accountsJson = json.encode(xPlayer.getAccounts(true))
            cache.accounts = accountsJson
            dirty.accounts = false
        else
            accountsJson = cache.accounts
        end

        -- Inventory - only re-encode if dirty
        local inventoryJson
        if dirty.inventory or not cache.inventory then
            inventoryJson = json.encode(xPlayer.getInventory(true))
            cache.inventory = inventoryJson
            dirty.inventory = false
        else
            inventoryJson = cache.inventory
        end

        -- Loadout - only re-encode if dirty
        local loadoutJson
        if dirty.loadout or not cache.loadout then
            loadoutJson = json.encode(xPlayer.getLoadout(true))
            cache.loadout = loadoutJson
            dirty.loadout = false
        else
            loadoutJson = cache.loadout
        end

        -- Metadata - only re-encode if dirty
        local metadataJson
        if dirty.metadata or not cache.metadata then
            metadataJson = json.encode(xPlayer.getMeta())
            cache.metadata = metadataJson
            dirty.metadata = false
        else
            metadataJson = cache.metadata
        end

        -- Position always needs to be fresh
        local positionJson = json.encode(getSaveCoords(xPlayer))

        parameters[#parameters + 1] = {
            accountsJson,
            xPlayer.job.name,
            xPlayer.job.grade,
            xPlayer.group,
            positionJson,
            inventoryJson,
            loadoutJson,
            metadataJson,
            xPlayer.identifier,
        }
    end

    MySQL.prepare(
        ESX.Q("UPDATE `{users}` SET `accounts` = ?, `job` = ?, `job_grade` = ?, `group` = ?, `position` = ?, `inventory` = ?, `loadout` = ?, `metadata` = ? WHERE `identifier` = ?"),
        parameters,
        function(results)
            if not results then
                return
            end

            if type(cb) == "function" then
                return cb()
            end

            print(("[^2INFO^7] Saved ^5%s^7 %s over ^5%s^7 ms"):format(#parameters,
                #parameters > 1 and "players" or "player", GetGameTimer() - startTime))
        end
    )
end

ESX.GetPlayers = GetPlayers

local function checkTable(key, val, xPlayer, xPlayers, minimal)
    for valIndex = 1, #val do
        local value = val[valIndex]
        if not xPlayers[value] then
            xPlayers[value] = {}
        end

        if (key == "job" and xPlayer.job.name == value) or xPlayer[key] == value then
            xPlayers[value][#xPlayers[value] + 1] = (minimal and xPlayer.source or xPlayer)
        end
    end
end

---@param key? string
---@param val? string|table
---@param minimal? boolean
---@return xPlayer[]|number[]|table<any, xPlayer[]>|table<any, number[]>
function ESX.GetExtendedPlayers(key, val, minimal)
    if not key then
        if not minimal then
            return ESX.Table.ToArray(ESX.Players)
        end

        local xPlayers = {}
        local index = 1
        for src, _ in pairs(ESX.Players) do
            xPlayers[index] = src
            index += 1
        end

        return xPlayers
    end

    local xPlayers = {}
    if type(val) == "table" then
        for _, xPlayer in pairs(ESX.Players) do
            checkTable(key, val, xPlayer, xPlayers, minimal)
        end

        return xPlayers
    end

    for _, xPlayer in pairs(ESX.Players) do
        if (key == "job" and xPlayer.job.name == val) or xPlayer[key] == val then
            xPlayers[#xPlayers + 1] = (minimal and xPlayer.source or xPlayer)
        end
    end

    return xPlayers
end

---@param key? string
---@param val? string|table
---@return number | table
function ESX.GetNumPlayers(key, val)
    if not key then
        return #GetPlayers()
    end

    if type(val) == "table" then
        local numPlayers = {}
        if key == "job" then
            for _, v in ipairs(val) do
                numPlayers[v] = (Core.JobsPlayerCount[v] or 0)
            end
            return numPlayers
        end

        local filteredPlayers = ESX.GetExtendedPlayers(key, val)
        for i, v in pairs(filteredPlayers) do
            numPlayers[i] = (#v or 0)
        end
        return numPlayers
    end

    if key == "job" then
        return (Core.JobsPlayerCount[val] or 0)
    end

    return #ESX.GetExtendedPlayers(key, val)
end

local MoneyIconTiers = {
    money = { 500, 1000, 1500, 2000, 3000, 5000, 7000, 7500, 10000, 15000, 20000, 30000, 50000 },
    black_money = { 3000, 5000, 10000 },
}
--- Picks the icon for a money notification. The tier suffixes let an inventory ship
--- several cash images; a pack without them simply has no file at that path.
---@param accountName string
---@param amount number
---@return string? icon
function ESX.GetMoneyIcon(accountName, amount)
    if not Config.ItemIconUrl then
        return nil
    end

    local name = accountName
    local tiers = MoneyIconTiers[accountName]
    if tiers then
        amount = tonumber(amount) or 0
        for i = #tiers, 1, -1 do
            if amount >= tiers[i] then
                name = ('%s_%d'):format(accountName, tiers[i])
                break
            end
        end
    end
    return Config.ItemIconUrl:format(name)
end

---@param source number
---@return xPlayer?
function ESX.GetPlayerFromId(source)
    return ESX.Players[tonumber(source)]
end

---@param identifier string
---@return xPlayer?
function ESX.GetPlayerFromIdentifier(identifier)
    return Core.playersByIdentifier[identifier]
end

---@param identifier string
---@return number playerId
function ESX.GetPlayerIdFromIdentifier(identifier)
    return Core.playersByIdentifier[identifier]?.source
end

---@param source number
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field
function ESX.IsPlayerLoaded(source)
    return ESX.Players[source] ~= nil
end

local devAltSteam = GetConvar("esx_devalt_steam", "")
local devAltDiscord = GetConvar("esx_devalt_discord", "")
local devAltSuffix = GetConvar("esx_devalt_suffix", "_ALT")

local function devAltSlot(playerId)
    if devAltSteam == "" or devAltDiscord == "" or devAltSuffix == "" then
        return nil
    end
    if GetPlayerIdentifierByType(playerId, "steam") ~= devAltSteam then
        return nil
    end
    if GetPlayerIdentifierByType(playerId, "discord") ~= devAltDiscord then
        return nil
    end
    local pattern = devAltSuffix:gsub("%W", "%%%0") .. "(%d*)$"
    local slot = (GetPlayerName(playerId) or ""):match(pattern)
    if not slot then
        return nil
    end
    return "_alt" .. slot
end

---@param playerId number | string
---@return string, number
function ESX.GetIdentifier(playerId)
    local fxDk = GetConvarInt("sv_fxdkMode", 0)
    if fxDk == 1 then
        return "ESX-DEBUG-LICENCE", 0
    end

    playerId = tostring(playerId)

    local identifierType = Config.Identifier
    local identifier = GetPlayerIdentifierByType(playerId, identifierType)

    if not identifier then
        print(("[ESX] ^1GetIdentifier failed: no identifier found for playerId %s with type '%s'^0"):format(playerId, identifierType))
        return nil
    end

    local id = identifier:gsub(("%s:"):format(identifierType), "")
    local slot = devAltSlot(playerId)
    if slot then
        id = id .. slot
    end

    return id
end

---@param model string|number
---@param player number
---@param cb function?
---@return string?
---@diagnostic disable-next-line: duplicate-set-field
function ESX.GetVehicleType(model, player, cb)
    if cb and not ESX.IsFunctionReference(cb) then
        error("Invalid callback function")
    end

    local DEFAULT_VEHICLE_TYPE = "automobile"
    local TIMEOUT_MS = 10000  -- 10 seconds timeout

    local p = not cb and promise.new()
    local resolved = false

    local function resolve(result)
        if resolved then return end
        resolved = true

        -- Use default if result is nil/invalid
        result = result or DEFAULT_VEHICLE_TYPE

        if p then
            p:resolve(result)
        elseif cb then
            cb(result)
        end

        return result
    end

    model = type(model) == "string" and joaat(model) or model

    -- Check cache first
    if Core.vehicleTypesByModel[model] then
        return resolve(Core.vehicleTypesByModel[model])
    end

    -- Validate player exists before triggering callback
    if not player or not GetPlayerName(player) then
        if Config.EnableDebug then
            print(("[^3WARNING^7] GetVehicleType: Invalid player %s, using default type"):format(tostring(player)))
        end
        return resolve(DEFAULT_VEHICLE_TYPE)
    end

    ESX.TriggerClientCallback(player, "esx:GetVehicleType", function(vehicleType)
        if vehicleType then
            Core.vehicleTypesByModel[model] = vehicleType
        end
        resolve(vehicleType)
    end, model)

    if p then
        -- OPTIMIZATION: Add timeout to prevent infinite blocking
        SetTimeout(TIMEOUT_MS, function()
            if not resolved then
                if Config.EnableDebug then
                    print(("[^3WARNING^7] GetVehicleType timeout for model %s, using default type"):format(model))
                end
                -- Cache the default to avoid repeated timeouts for same model
                Core.vehicleTypesByModel[model] = DEFAULT_VEHICLE_TYPE
                resolve(DEFAULT_VEHICLE_TYPE)
            end
        end)

        return Citizen.Await(p)
    end
end

---@param name string
---@param title string
---@param color string
---@param message string
---@return nil
function ESX.DiscordLog(name, title, color, message)
    local webHook = Config.DiscordLogs.Webhooks[name] or Config.DiscordLogs.Webhooks.default
    local embedData = {
        {
            ["title"] = title,
            ["color"] = Config.DiscordLogs.Colors[color] or Config.DiscordLogs.Colors.default,
            ["footer"] = {
                ["text"] = "| ESX Logs | " .. os.date(),
                ["icon_url"] =
                "https://cdn.discordapp.com/attachments/944789399852417096/1020099828266586193/blanc-800x800.png",
            },
            ["description"] = message,
            ["author"] = {
                ["name"] = "ESX Framework",
                ["icon_url"] = "https://cdn.discordapp.com/emojis/939245183621558362.webp?size=128&quality=lossless",
            },
        },
    }
    PerformHttpRequest(
        webHook,
        function()
            return
        end,
        "POST",
        json.encode({
            username = "Logs",
            embeds = embedData,
        }),
        {
            ["Content-Type"] = "application/json",
        }
    )
end

---@param name string
---@param title string
---@param color string
---@param fields table
---@return nil
function ESX.DiscordLogFields(name, title, color, fields)
    for i = 1, #fields do
        local field = fields[i]
        field.value = tostring(field.value)
    end

    local webHook = Config.DiscordLogs.Webhooks[name] or Config.DiscordLogs.Webhooks.default
    local embedData = {
        {
            ["title"] = title,
            ["color"] = Config.DiscordLogs.Colors[color] or Config.DiscordLogs.Colors.default,
            ["footer"] = {
                ["text"] = "| ESX Logs | " .. os.date(),
                ["icon_url"] =
                "https://cdn.discordapp.com/attachments/944789399852417096/1020099828266586193/blanc-800x800.png",
            },
            ["fields"] = fields,
            ["description"] = "",
            ["author"] = {
                ["name"] = "ESX Framework",
                ["icon_url"] = "https://cdn.discordapp.com/emojis/939245183621558362.webp?size=128&quality=lossless",
            },
        },
    }
    PerformHttpRequest(
        webHook,
        function()
            return
        end,
        "POST",
        json.encode({
            username = "Logs",
            embeds = embedData,
        }),
        {
            ["Content-Type"] = "application/json",
        }
    )
end

---@return nil
function ESX.RefreshJobs()
    Core.JobsLoaded = false

    local Jobs = {}
    local jobs = MySQL.query.await(ESX.Q("SELECT * FROM {jobs}"))

    for _, v in ipairs(jobs) do
        Jobs[v.name] = v
        Jobs[v.name].grades = {}
    end

    local jobGrades = MySQL.query.await(ESX.Q("SELECT * FROM {job_grades}"))

    for _, v in ipairs(jobGrades) do
        if Jobs[v.job_name] then
            Jobs[v.job_name].grades[tostring(v.grade)] = v
        else
            print(('[^3WARNING^7] Ignoring job grades for ^5"%s"^0 due to missing job'):format(v.job_name))
        end
    end

    for _, v in pairs(Jobs) do
        if ESX.Table.SizeOf(v.grades) == 0 then
            Jobs[v.name] = nil
            print(('[^3WARNING^7] Ignoring job ^5"%s"^0 due to no job grades found'):format(v.name))
        end
    end

    if not Jobs then
        -- Fallback data, if no jobs exist
        ESX.Jobs["unemployed"] = { name = "unemployed", label = "Unemployed", whitelisted = false, grades = { ["0"] = { grade = 0, name = "unemployed", label = "Unemployed", salary = 200, skin_male = {}, skin_female = {} } } }
    else
        ESX.Jobs = Jobs
    end

    TriggerEvent("esx:jobsRefreshed")
    Core.JobsLoaded = true
end

---@param item string
---@param cb function
---@return nil
function ESX.RegisterUsableItem(item, cb)
    Core.UsableItemsCallbacks[item] = cb
end

---@param source number
---@param item string
---@param ... any
---@return nil
function ESX.UseItem(source, item, ...)
    if ESX.Items[item] then
        local itemCallback = Core.UsableItemsCallbacks[item]

        if itemCallback then
            local success, result = pcall(itemCallback, source, item, ...)

            if not success then
                -- OPTIMIZATION: Notify player about item use failure
                local xPlayer = ESX.GetPlayerFromId(source)
                if xPlayer then
                    xPlayer.showNotification(TranslateCap("use_item_failed") or "~r~Item could not be used")
                end

                if result then
                    print(result)
                else
                    print(('[^3WARNING^7] An error occured when using item ^5"%s"^7! This was not caused by ESX.'):format(item))
                end
                return
            end
        end
    else
        print(('[^3WARNING^7] Item ^5"%s"^7 was used but does not exist!'):format(item))
    end
end

---@param index string
---@param overrides table
---@return nil
function ESX.RegisterPlayerFunctionOverrides(index, overrides)
    Core.PlayerFunctionOverrides[index] = overrides
end

---@param index string
---@return nil
function ESX.SetPlayerFunctionOverride(index)
    if not index or not Core.PlayerFunctionOverrides[index] then
        return print("[^3WARNING^7] No valid index provided.")
    end

    Config.PlayerFunctionOverride = index
end

---@param item string
---@return string?
---@diagnostic disable-next-line: duplicate-set-field
function ESX.GetItemLabel(item)
    if ESX.Items[item] then
        return ESX.Items[item].label
    else
        print(("[^3WARNING^7] Attemting to get invalid Item -> ^5%s^7"):format(item))
    end
end

---@return table
function ESX.GetJobs()
    while not Core.JobsLoaded do
        Citizen.Wait(200)
    end

    return ESX.Jobs
end

---@return table
function ESX.GetItems()
    return ESX.Items
end

---@return table
function ESX.GetUsableItems()
    local Usables = {}
    for k in pairs(Core.UsableItemsCallbacks) do
        Usables[k] = true
    end
    return Usables
end

if not Config.CustomInventory then
    ---@param itemType string
    ---@param name string
    ---@param count integer
    ---@param label string
    ---@param playerId number
    ---@param components? string | table
    ---@param tintIndex? integer
    ---@param coords? table | vector3
    ---@return nil
    function ESX.CreatePickup(itemType, name, count, label, playerId, components, tintIndex, coords)
        local pickupId = (Core.PickupId == 65635 and 0 or Core.PickupId + 1)
        local xPlayer = ESX.Players[playerId]
        coords = ((type(coords) == "vector3" or type(coords) == "vector4") and coords.xyz or xPlayer.getCoords(true))

        Core.Pickups[pickupId] = {
            type = itemType,
            name = name,
            count = count,
            label = label,
            coords = coords,
            createdAt = GetGameTimer()  -- For GC expiration
        }

        if itemType == "item_weapon" then
            Core.Pickups[pickupId].components = components
            Core.Pickups[pickupId].tintIndex = tintIndex
        end

        TriggerClientEvent("esx:createPickup", -1, pickupId, label, coords, itemType, name, components, tintIndex)
        Core.PickupId = pickupId
    end

    -- OPTIMIZATION: Cached sorted inventory template (created once, cloned for each player)
    local cachedInventoryTemplate = nil
    local cachedItemNames = nil  -- Ordered list of item names

    -- Build the cached inventory template (called after items are loaded)
    local function buildInventoryTemplate()
        cachedInventoryTemplate = {}
        cachedItemNames = {}
        local index = 1

        for itemName, itemData in pairs(ESX.Items) do
            cachedInventoryTemplate[index] = {
                name = itemName,
                count = 0,
                label = itemData.label,
                labelEn = itemData.labelEn,
                weight = itemData.weight,
                usable = false,  -- Will be set per-player
                rare = itemData.rare,
                canRemove = itemData.canRemove,
            }
            cachedItemNames[index] = itemName
            index = index + 1
        end

        -- Sort once (O(n log n) done at server start, not per player)
        table.sort(cachedInventoryTemplate, function(a, b)
            return a.label < b.label
        end)

        -- Update cachedItemNames to match sorted order
        for i = 1, #cachedInventoryTemplate do
            cachedItemNames[i] = cachedInventoryTemplate[i].name
        end

        print(("[^2INFO^7] Built inventory template with ^5%d^7 items"):format(#cachedInventoryTemplate))
    end

    -- Create a new inventory for a player by cloning the template
    -- This is O(n) but avoids pairs() iteration and sorting
    function Core.CreateInventoryFromTemplate(minimalInv)
        if not cachedInventoryTemplate then
            return nil
        end

        local inventory = {}
        local weight = 0
        local templateSize = #cachedInventoryTemplate

        for i = 1, templateSize do
            local template = cachedInventoryTemplate[i]
            local itemName = template.name
            local count = minimalInv[itemName] or 0

            inventory[i] = {
                name = itemName,
                count = count,
                label = template.label,
                labelEn = template.labelEn,
                weight = template.weight,
                usable = Core.UsableItemsCallbacks[itemName] ~= nil,
                rare = template.rare,
                canRemove = template.canRemove,
            }

            if count > 0 then
                weight = weight + (template.weight * count)
            end
        end

        return inventory, weight
    end

    local function refreshPlayerInventories()
        local xPlayers = ESX.GetExtendedPlayers()
        for i = 1, #xPlayers do
            local xPlayer = xPlayers[i]
            local minimalInv = xPlayer.getInventory(true)

            for itemName, _ in pairs(minimalInv) do
                if not ESX.Items[itemName] then
                    xPlayer.setInventoryItem(itemName, 0)
                    minimalInv[itemName] = nil
                end
            end

            -- Use cached template if available
            if cachedInventoryTemplate then
                local inventory, weight = Core.CreateInventoryFromTemplate(minimalInv)
                xPlayer.inventory = inventory
                xPlayer.weight = weight
            else
                -- Fallback to old method
                xPlayer.inventory = {}
                local playerInvIndex = 1
                for itemName, itemData in pairs(ESX.Items) do
                    xPlayer.inventory[playerInvIndex] = {
                        name = itemName,
                        count = minimalInv[itemName] or 0,
                        label = itemData.label,
                        labelEn = itemData.labelEn,
                        weight = itemData.weight,
                        usable = Core.UsableItemsCallbacks[itemName] ~= nil,
                        rare = itemData.rare,
                        canRemove = itemData.canRemove,
                    }
                    playerInvIndex = playerInvIndex + 1
                end
            end

            TriggerClientEvent("esx:setInventory", xPlayer.source, xPlayer.inventory)
        end
    end

    ---@return number newItemCount
    function ESX.RefreshItems()
        ESX.Items = {}

        local items = MySQL.query.await(ESX.Q("SELECT * FROM {items}"))
        local itemCount = #items
        for i = 1, itemCount do
            local item = items[i]
            ESX.Items[item.name] = { label = item.label, labelEn = item.label_en, weight = item.weight, rare = item.rare, canRemove = item.can_remove, limit = item.limit }
        end

        -- Build cached template after items are loaded
        buildInventoryTemplate()
        refreshPlayerInventories()

        return itemCount
    end

    ---@param items { name: string, label: string, weight?: number, rare?: boolean, canRemove?: boolean }[]
    function ESX.AddItems(items)
        local toInsert = {}
        local toInsertIndex = 1

        for i = 1, #items do
            local item = items[i]
            local name = item.name
            local label = item.label
            local weight = item.weight or 1
            local rare = item.rare or false
            local canRemove = item.canRemove ~= false
            local limit = item.limit or -1  -- -1 = unlimited

            if type(name) ~= "string" then
                print(("^1[AddItems]^0 Invalid item name: %s"):format(name))
                goto continue
            end

            if ESX.Items[name] then
                goto continue
            end

            if type(label) ~= "string" then
                print(("^1[AddItems]^0 Invalid label for item '%s'"):format(name))
                goto continue
            end

            if type(weight) ~= "number" then
                print(("^1[AddItems]^0 Invalid weight for item '%s'"):format(name))
                goto continue
            end

            if type(rare) ~= "boolean" then
                print(("^1[AddItems]^0 Invalid rare flag for item '%s'"):format(name))
                goto continue
            end

            if type(canRemove) ~= "boolean" then
                print(("^1[AddItems]^0 Invalid canRemove flag for item '%s'"):format(name))
                goto continue
            end

            if type(limit) ~= "number" then
                print(("^1[AddItems]^0 Invalid limit for item '%s'"):format(name))
                goto continue
            end

            toInsert[toInsertIndex] = {
                name = name,
                label = label,
                weight = weight,
                rare = rare,
                canRemove = canRemove,
                limit = limit,
            }
            toInsertIndex += 1

            ::continue::
        end

        if #toInsert > 0 then
            MySQL.prepare.await(
            ESX.Q("INSERT IGNORE INTO `{items}` (`name`, `label`, `weight`, `rare`, `can_remove`, `limit`) VALUES (?, ?, ?, ?, ?, ?)"),
                toInsert)

            for i = 1, #toInsert do
                local row = toInsert[i]
                ESX.Items[row.name] = {
                    label = row.label,
                    weight = row.weight,
                    rare = row.rare,
                    canRemove = row.canRemove,
                    limit = row.limit,
                }
            end

            refreshPlayerInventories()
        end
    end
end

---@param job string
---@param grade string
---@return boolean
function ESX.DoesJobExist(job, grade)
    while not Core.JobsLoaded do
        Citizen.Wait(200)
    end

    return (ESX.Jobs[job] and ESX.Jobs[job].grades[tostring(grade)] ~= nil) or false
end

---@param playerSrc number
---@return boolean
function Core.IsPlayerAdmin(playerSrc)
    if type(playerSrc) ~= "number" then
        return false
    end

    if IsPlayerAceAllowed(playerSrc --[[@as string]], "command") or GetConvar("sv_lan", "") == "true" then
        return true
    end

    local xPlayer = ESX.GetPlayerFromId(playerSrc)
    return xPlayer and Config.AdminGroups[xPlayer.getGroup()] or false
end

-- Generates a unique 9-digit SSN in dashed format (XXX-XX-XXXX).
---@param skipUniqueCheck boolean?
---@return string
function Core.generateSSN(skipUniqueCheck)
    local reservedSSNs = {
        ["078-05-1120"] = true,
        ["219-09-9999"] = true,
        ["123-45-6789"] = true
    }

    while true do
        -- Generate the first part (area number)
        local area = math.random(1, 899)

        -- 666 is never assigned
        if area == 666 then
            goto continue
        end

        -- Generate the second part (group number)
        local group = math.random(1, 99)

        -- Generate the last part (serial number)
        local serial = math.random(1, 9999)

        -- Skip reserved SSN range (987-65-4320..4329)
        if area == 987 and group == 65 and serial >= 4320 and serial <= 4329 then
            goto continue
        end

        local candidate = string.format("%03d-%02d-%04d", area, group, serial)

        if reservedSSNs[candidate] then
            goto continue
        end

        if skipUniqueCheck then
            return candidate
        end

        local exists = MySQL.scalar.await(ESX.Q("SELECT 1 FROM `{users}` WHERE `ssn` = ? LIMIT 1"), { candidate })

        if not exists then
            return candidate
        end

        ::continue::
    end
end

---@param owner string
---@param plate string
---@param coords vector4
---@return CExtendedVehicle?
function ESX.CreateExtendedVehicle(owner, plate, coords)
    return Core.vehicleClass.new(owner, plate, coords)
end

---@param plate string
---@return CExtendedVehicle?
function ESX.GetExtendedVehicleFromPlate(plate)
    return Core.vehicleClass.getFromPlate(plate)
end
