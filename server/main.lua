SetMapName("San Andreas")
SetGameType("ESX Legacy")

-- OPTIMIZATION: GlobalState update batching system
-- Reduces network traffic by batching multiple updates together
local GlobalStateBatch = {
    pending = {},
    timer = nil,
    BATCH_DELAY = 200  -- ms to wait before applying batched updates
}

-- Queue a GlobalState update (will be applied after delay)
local function queueGlobalStateUpdate(key, value)
    GlobalStateBatch.pending[key] = value

    -- Start timer if not already running
    if not GlobalStateBatch.timer then
        GlobalStateBatch.timer = true
        SetTimeout(GlobalStateBatch.BATCH_DELAY, function()
            -- Apply all pending updates at once
            for k, v in pairs(GlobalStateBatch.pending) do
                GlobalState[k] = v
            end
            GlobalStateBatch.pending = {}
            GlobalStateBatch.timer = nil
        end)
    end
end

-- For critical updates that need immediate sync (like playerCount)
local function immediateGlobalStateUpdate(key, value)
    GlobalState[key] = value
end

-- OPTIMIZATION: Flush pending GlobalState updates (called before resource stop)
local function flushGlobalStateBatch()
    if next(GlobalStateBatch.pending) then
        for k, v in pairs(GlobalStateBatch.pending) do
            GlobalState[k] = v
        end
        GlobalStateBatch.pending = {}
        GlobalStateBatch.timer = nil
        if Config.EnableDebug then
            print("[^2INFO^7] Flushed pending GlobalState batch updates")
        end
    end
end

-- Ensure pending updates are applied before resource stops
AddEventHandler("onResourceStop", function(resourceName)
    if resourceName == GetCurrentResourceName() then
        flushGlobalStateBatch()
    end
end)

local oneSyncState = GetConvar("onesync", "off")
local newPlayer = ESX.Q("INSERT INTO `{users}` SET `accounts` = ?, `identifier` = ?, `ssn` = ?, `group` = ?")
local loadPlayer = "SELECT `accounts`, `ssn`, `job`, `job_grade`, `group`, `position`, `inventory`, `skin`, `loadout`, `metadata`"

if Config.Multichar then
    newPlayer = newPlayer .. ", `firstname` = ?, `lastname` = ?, `dateofbirth` = ?, `sex` = ?, `height` = ?"
end

if Config.StartingInventoryItems then
    newPlayer = newPlayer .. ", `inventory` = ?"
end

if Config.Multichar or Config.Identity then
    loadPlayer = loadPlayer .. ", `firstname`, `lastname`, `dateofbirth`, `sex`, `height`"
end

loadPlayer = loadPlayer .. ESX.Q(" FROM `{users}` WHERE identifier = ?")

local function createESXPlayer(identifier, playerId, data)
    local accounts = {}

    for account, money in pairs(Config.StartingAccountMoney) do
        accounts[account] = money
    end

    local defaultGroup = "user"
    if Core.IsPlayerAdmin(playerId) then
        print(("[^2INFO^0] Player ^5%s^0 Has been granted admin permissions via ^5Ace Perms^7."):format(playerId))
        defaultGroup = "admin"
    end
    local parameters = Config.Multichar and
        { json.encode(accounts), identifier, Core.generateSSN(), defaultGroup, data.firstname, data.lastname, data.dateofbirth, data.sex, data.height }
        or { json.encode(accounts), identifier, Core.generateSSN(), defaultGroup }

    if Config.StartingInventoryItems then
        table.insert(parameters, json.encode(Config.StartingInventoryItems))
    end

    MySQL.prepare(newPlayer, parameters, function()
        loadESXPlayer(identifier, playerId, true)
    end)
end


local loading = {}
local useCooldown = {}

local function onPlayerJoined(playerId)
    local identifier = ESX.GetIdentifier(playerId)
    if not identifier then
        return DropPlayer(playerId, "there was an error loading your character!\nError code: identifier-missing-ingame\n\nThe cause of this error is not known, your identifier could not be found. Please come back later or report this problem to the server administration team.")
    end

    if ESX.GetPlayerFromIdentifier(identifier) then
        DropPlayer(
            playerId,
            ("there was an error loading your character!\nError code: identifier-active-ingame\n\nThis error is caused by a player on this server who has the same identifier as you have. Make sure you are not playing on the same Rockstar account.\n\nYour Rockstar identifier: %s"):format(
                identifier
            )
        )
    else
        local result = MySQL.scalar.await(ESX.Q("SELECT 1 FROM {users} WHERE identifier = ?"), { identifier })
        if result then
            loadESXPlayer(identifier, playerId, false)
        else
            createESXPlayer(identifier, playerId)
        end
    end
end

---@param playerId number
---@param reason string
---@param cb function?
local function onPlayerDropped(playerId, reason, cb)
    local p = not cb and promise:new()
    local function resolve()
        if cb then
            return cb()
        elseif(p) then
            return p:resolve()
        end
    end

    -- Clean up pending spawn if player disconnected before ENTER WORLD
    if Core.PendingSpawns and Core.PendingSpawns[playerId] then
        Core.PendingSpawns[playerId] = nil
    end

    local xPlayer = ESX.GetPlayerFromId(playerId)
    if not xPlayer then
        return resolve()
    end

    TriggerEvent("esx:playerDropped", playerId, reason)
    local job = xPlayer.getJob().name
    local currentJob = Core.JobsPlayerCount[job]
    Core.JobsPlayerCount[job] = ((currentJob and currentJob > 0) and currentJob or 1) - 1

    -- Use batched update for job counts (less critical)
    queueGlobalStateUpdate(("%s:count"):format(job), Core.JobsPlayerCount[job])

    Core.SavePlayer(xPlayer, function()
        -- Use immediate update for player count (critical for server browser)
        immediateGlobalStateUpdate("playerCount", GlobalState["playerCount"] - 1)
        ESX.Players[playerId] = nil
        Core.playersByIdentifier[xPlayer.identifier] = nil

        resolve()
    end)

    if p then
        return Citizen.Await(p)
    end
end
AddEventHandler("esx:onPlayerDropped", onPlayerDropped)


if Config.Multichar then
    AddEventHandler("esx:onPlayerJoined", function(src, char, data)
        while not next(ESX.Jobs) do
            Wait(50)
        end

        if not ESX.Players[src] then
            local identifier = char .. ":" .. ESX.GetIdentifier(src)
            if data then
                createESXPlayer(identifier, src, data)
            else
                loadESXPlayer(identifier, src, false)
            end
        end
    end)
else
    RegisterNetEvent("esx:onPlayerJoined", function()
        local _source = source
        while not next(ESX.Jobs) do
            Wait(50)
        end

        if loading[_source] or ESX.Players[_source] then
            return
        end

        loading[_source] = true
        local ok, err = pcall(onPlayerJoined, _source)
        loading[_source] = nil

        if not ok then
            print(("[^1ERROR^7] esx:onPlayerJoined failed for ^5%s^7: %s"):format(_source, err))
        end
    end)
end

if not Config.Multichar then
    AddEventHandler("playerConnecting", function(_, _, deferrals)
        local playerId = source
        deferrals.defer()
        Wait(0) -- Required
        local identifier
        local correctLicense, _ = pcall(function ()
            identifier = ESX.GetIdentifier(playerId)
        end)

        -- luacheck: ignore
        if not SetEntityOrphanMode then
            return deferrals.done(("[ESX] ESX Requires a minimum Artifact version of 10188, Please update your server."))
        end

        if oneSyncState == "off" or oneSyncState == "legacy" then
            return deferrals.done(("[ESX] ESX Requires Onesync Infinity to work. This server currently has Onesync set to: %s"):format(oneSyncState))
        end

        if not Core.DatabaseConnected then
            return deferrals.done("[ESX] OxMySQL Was Unable To Connect to your database. Please make sure it is turned on and correctly configured in your server.cfg")
        end

        if not identifier or not correctLicense then
            if GetResourceState("esx_identity") ~= "started" then
                return deferrals.done("[ESX] There was an error loading your character!\nError code: identifier-missing\n\nThe cause of this error is not known, your identifier could not be found. Please come back later or report this problem to the server administration team.")
            end
        end

        local xPlayer = ESX.GetPlayerFromIdentifier(identifier)

        if not xPlayer then
            return deferrals.done()
        end

        if GetPlayerPing(xPlayer.source --[[@as string]]) > 0 then
            return deferrals.done(
                ("[ESX] There was an error loading your character!\nError code: identifier-active\n\nThis error is caused by a player on this server who has the same identifier as you have. Make sure you are not playing on the same account.\n\nYour identifier: %s"):format(identifier)
            )
        end

        deferrals.update(("[ESX] Cleaning stale player entry..."):format(identifier))
        onPlayerDropped(xPlayer.source, "esx_stale_player_obj")
        deferrals.done()
    end)
end

function loadESXPlayer(identifier, playerId, isNew)
    local userData = {
        accounts = {},
        inventory = {},
        loadout = {},
        weight = 0,
        name = GetPlayerName(playerId),
        identifier = identifier,
        firstName = "John",
        lastName = "Doe",
        dateofbirth = "01/01/2000",
        height = 120,
        dead = false,
    }

    local result = MySQL.prepare.await(loadPlayer, { identifier })

    -- Accounts
    local accounts = result.accounts
    accounts = (accounts and accounts ~= "") and json.decode(accounts) or {}

    for account, data in pairs(Config.Accounts) do
        data.round = data.round or data.round == nil

        local index = #userData.accounts + 1
        userData.accounts[index] = {
            name = account,
            money = accounts[account] or Config.StartingAccountMoney[account] or 0,
            label = data.label,
            round = data.round,
            index = index,
        }
    end

    -- SSN
    userData.ssn = result.ssn

    -- Job
    local job, grade = result.job, tostring(result.job_grade)

    if not ESX.DoesJobExist(job, grade) then
        print(("[^3WARNING^7] Ignoring invalid job for ^5%s^7 [job: ^5%s^7, grade: ^5%s^7]"):format(identifier, job, grade))
        job, grade = "unemployed", "0"
    end

    local jobObject, gradeObject = ESX.Jobs[job], ESX.Jobs[job].grades[grade]

    userData.job = {
        id = jobObject.id,
        name = jobObject.name,
        label = jobObject.label,

        grade = tonumber(grade),
        grade_name = gradeObject.name,
        grade_label = gradeObject.label,
        grade_salary = gradeObject.salary,

        skin_male = gradeObject.skin_male and json.decode(gradeObject.skin_male) or {},
        skin_female = gradeObject.skin_female and json.decode(gradeObject.skin_female) or {},
    }

    -- Inventory
    if not Config.CustomInventory then
        local minimalInventory = (result.inventory and result.inventory ~= "") and json.decode(result.inventory) or {}

        -- OPTIMIZATION: Use cached template if available (avoids O(n log n) sort per player)
        if Core.CreateInventoryFromTemplate then
            local inventory, weight = Core.CreateInventoryFromTemplate(minimalInventory)
            if inventory then
                userData.inventory = inventory
                userData.weight = weight
            else
                -- Fallback if template not ready yet
                for name, item in pairs(ESX.Items) do
                    local count = minimalInventory[name] or 0
                    userData.weight = userData.weight + (count * item.weight)

                    userData.inventory[#userData.inventory + 1] = {
                        name = name,
                        count = count,
                        label = item.label,
                        weight = item.weight,
                        usable = Core.UsableItemsCallbacks[name] ~= nil,
                        rare = item.rare,
                        canRemove = item.canRemove,
                    }
                end
                table.sort(userData.inventory, function(a, b)
                    return a.label < b.label
                end)
            end
        else
            -- Original method
            for name, item in pairs(ESX.Items) do
                local count = minimalInventory[name] or 0
                userData.weight = userData.weight + (count * item.weight)

                userData.inventory[#userData.inventory + 1] = {
                    name = name,
                    count = count,
                    label = item.label,
                    weight = item.weight,
                    usable = Core.UsableItemsCallbacks[name] ~= nil,
                    rare = item.rare,
                    canRemove = item.canRemove,
                }
            end
            table.sort(userData.inventory, function(a, b)
                return a.label < b.label
            end)
        end
    elseif result.inventory and result.inventory ~= "" then
        userData.inventory = json.decode(result.inventory)
    end

    -- Group
    if result.group then
        if result.group == "superadmin" then
            userData.group = "admin"
            print("[^3WARNING^7] ^5Superadmin^7 detected, setting group to ^5admin^7")
        else
            userData.group = result.group
        end
    else
        userData.group = "user"
    end

    -- Loadout
    if not Config.CustomInventory then
        if result.loadout and result.loadout ~= "" then

            local loadout = json.decode(result.loadout)
            for name, weapon in pairs(loadout) do
                local label = ESX.GetWeaponLabel(name)

                if label then
                    userData.loadout[#userData.loadout + 1] = {
                        name = name,
                        ammo = weapon.ammo,
                        label = label,
                        components = weapon.components or {},
                        tintIndex = weapon.tintIndex or 0,
                    }
                end
            end
        end
    end

    -- Position (with safety check to prevent nil coords)
    local decodedPosition = result.position and json.decode(result.position) or nil
    if decodedPosition and decodedPosition.x and decodedPosition.y and decodedPosition.z
        and not (math.abs(decodedPosition.x) < 1.0 and math.abs(decodedPosition.y) < 1.0) then
        userData.coords = decodedPosition
    else
        -- New players get NewPlayerSpawn, existing players get DefaultSpawns
        if isNew and Config.NewPlayerSpawn then
            userData.coords = Config.NewPlayerSpawn
            print(('[^2INFO^0] New player ^5%s^0 spawning at NewPlayerSpawn location'):format(playerId))
        else
            userData.coords = Config.DefaultSpawns[ESX.Math.Random(1, #Config.DefaultSpawns)]
            print(('[^3WARNING^0] Player ^5%s^0 had nil/invalid position, using default spawn'):format(playerId))
        end
    end

    -- Skin
    userData.skin = (result.skin and result.skin ~= "") and json.decode(result.skin) or { sex = userData.sex == "f" and 1 or 0 }

    -- Metadata
    userData.metadata = (result.metadata and result.metadata ~= "") and json.decode(result.metadata) or {}

    -- xPlayer Creation
    local xPlayer = CreateExtendedPlayer(playerId, identifier, userData.ssn, userData.group, userData.accounts, userData.inventory, userData.weight, userData.job, userData.loadout, GetPlayerName(playerId), userData.coords, userData.metadata)

    -- Use immediate update for player count (critical for server browser)
    immediateGlobalStateUpdate("playerCount", GlobalState["playerCount"] + 1)
    ESX.Players[playerId] = xPlayer
    Core.playersByIdentifier[identifier] = xPlayer

    -- Identity
    if result.firstname and result.firstname ~= "" then
        userData.firstName = result.firstname
        userData.lastName = result.lastname

        local name = ("%s %s"):format(result.firstname, result.lastname)
        userData.name = name

        xPlayer.set("firstName", result.firstname)
        xPlayer.set("lastName", result.lastname)
        xPlayer.setName(name)

        if result.dateofbirth then
            userData.dateofbirth = result.dateofbirth
            xPlayer.set("dateofbirth", result.dateofbirth)
        end
        if result.sex then
            userData.sex = result.sex
            xPlayer.set("sex", result.sex)
        end
        if result.height then
            userData.height = result.height
            xPlayer.set("height", result.height)
        end
    end

    -- Store pending spawn data - wait for player to click ENTER WORLD
    Core.PendingSpawns = Core.PendingSpawns or {}
    Core.PendingSpawns[playerId] = {
        xPlayer = xPlayer,
        userData = userData,
        isNew = isNew
    }

    print(('[^2INFO^0] Player ^5"%s"^0 data loaded, waiting for ENTER WORLD. ID: ^5%s^7'):format(xPlayer.getName(), playerId))

    -- Tell client that data is ready - loading screen can now show ENTER WORLD button
    TriggerClientEvent('esx:playerDataReady', playerId)

    -- A loading screen that does not implement the ENTER WORLD handshake never answers, which
    -- would leave the player parked here forever. Spawn them anyway once the timeout passes.
    if Config.EnterWorldTimeout > 0 then
        SetTimeout(Config.EnterWorldTimeout, function()
            if Core.PendingSpawns[playerId] then
                print(('[^3WARNING^0] Player ^5%s^0 never confirmed ENTER WORLD, spawning after timeout'):format(playerId))
                Core.EnterWorld(playerId)
                -- The loading screen is still up waiting for a click. Tell it to take itself
                -- down now, or the player clicks ENTER WORLD on a world they are already in and
                -- the screen fades out with nothing left to fade it back in.
                TriggerClientEvent('esx:spawnedWithoutEnterWorld', playerId)
            end
        end)
    end
end

--- Releases a player parked in Core.PendingSpawns into the world.
---@param playerId number
function Core.EnterWorld(playerId)
    local pending = Core.PendingSpawns and Core.PendingSpawns[playerId]

    if not pending then
        return
    end

    local xPlayer = pending.xPlayer
    local userData = pending.userData
    local isNew = pending.isNew

    -- Clear pending data
    Core.PendingSpawns[playerId] = nil

    -- Now trigger playerLoaded events
    TriggerEvent("esx:playerLoaded", playerId, xPlayer, isNew)

    userData.money = xPlayer.getMoney()
    userData.maxWeight = xPlayer.getMaxWeight()
    userData.variables = xPlayer.variables or {}

    xPlayer.triggerEvent("esx:playerLoaded", userData, isNew, userData.skin)

    if not Config.CustomInventory then
        xPlayer.triggerEvent("esx:createMissingPickups", Core.Pickups)
    elseif setPlayerInventory then
        setPlayerInventory(playerId, xPlayer, userData.inventory, isNew)
    end

    xPlayer.triggerEvent("esx:registerSuggestions", Core.RegisteredCommands)
    print(('[^2INFO^0] Player ^5"%s"^0 has entered the world. ID: ^5%s^7'):format(xPlayer.getName(), playerId))
end

-- Player clicked ENTER WORLD - spawn them now
RegisterNetEvent('esx:playerReadyToSpawn', function()
    local playerId = source

    if not (Core.PendingSpawns and Core.PendingSpawns[playerId]) then
        -- Already in the world (the timeout beat the click). The loading screen fades the
        -- screen out on its way down, so without this the player is left on a black screen.
        TriggerClientEvent('esx:spawnedWithoutEnterWorld', playerId)
        return
    end

    Core.EnterWorld(playerId)
end)

AddEventHandler("chatMessage", function(playerId, _, message)
    local xPlayer = ESX.GetPlayerFromId(playerId)
    if xPlayer and message:sub(1, 1) == "/" and playerId > 0 then
        CancelEvent()
        local commandName = message:sub(1):gmatch("%w+")()
        xPlayer.showNotification(TranslateCap("commanderror_invalidcommand", commandName))
    end
end)

---@param reason string
AddEventHandler("playerDropped", function(reason)
    local playerId = source --[[@as number]]
    loading[playerId] = nil

    local prefix = ("%s:"):format(playerId)
    for key in pairs(useCooldown) do
        if key:sub(1, #prefix) == prefix then
            useCooldown[key] = nil
        end
    end

    onPlayerDropped(playerId, reason)
end)

AddEventHandler("esx:playerLoaded", function(_, xPlayer, isNew)
    local job = xPlayer.getJob().name
    local jobKey = ("%s:count"):format(job)

    Core.JobsPlayerCount[job] = (Core.JobsPlayerCount[job] or 0) + 1
    -- Use batched update for job counts (less critical, reduces network traffic)
    queueGlobalStateUpdate(jobKey, Core.JobsPlayerCount[job])
    if isNew then
        Player(xPlayer.source).state:set('isNew', true, false)
    end
end)

AddEventHandler("esx:setJob", function(_, job, lastJob)
    local lastJobKey = ("%s:count"):format(lastJob.name)
    local jobKey = ("%s:count"):format(job.name)
    local currentLastJob = Core.JobsPlayerCount[lastJob.name]

    Core.JobsPlayerCount[lastJob.name] = ((currentLastJob and currentLastJob > 0) and currentLastJob or 1) - 1
    Core.JobsPlayerCount[job.name] = (Core.JobsPlayerCount[job.name] or 0) + 1

    -- Use batched updates for job counts (reduces network traffic when many players change jobs)
    queueGlobalStateUpdate(lastJobKey, Core.JobsPlayerCount[lastJob.name])
    queueGlobalStateUpdate(jobKey, Core.JobsPlayerCount[job.name])
end)

AddEventHandler("esx:playerLogout", function(playerId, cb)
    onPlayerDropped(playerId, "esx_player_logout", cb)
    TriggerClientEvent("esx:onPlayerLogout", playerId)
end)

if not Config.CustomInventory then
    RegisterNetEvent("esx:updateWeaponAmmo", function(weaponName, ammoCount)
        local xPlayer = ESX.GetPlayerFromId(source)

        if xPlayer then
            ammoCount = tonumber(ammoCount)
            if not ammoCount then return end
            -- Never trust a raw client ammo value — clamp non-negative + sane ceiling (anti infinite-ammo)
            ammoCount = math.max(0, math.min(math.floor(ammoCount), 9999))
            xPlayer.updateWeaponAmmo(weaponName, ammoCount)
        end
    end)

    RegisterNetEvent("esx:giveInventoryItem", function(target, itemType, itemName, itemCount)
        local playerId = source
        local sourceXPlayer = ESX.GetPlayerFromId(playerId)
        local targetXPlayer = ESX.GetPlayerFromId(target)

        if not sourceXPlayer or not targetXPlayer then
            print(("[^3WARNING^7] Player Detected Cheating: ^5%s^7"):format(GetPlayerName(playerId)))
            return
        end

        -- OPTIMIZATION: Validate peds exist before distance calculation
        local sourcePed = GetPlayerPed(playerId)
        local targetPed = GetPlayerPed(target)
        if not sourcePed or sourcePed == 0 or not targetPed or targetPed == 0 then
            return
        end

        local sourceCoords = GetEntityCoords(sourcePed)
        local targetCoords = GetEntityCoords(targetPed)
        local distance = #(sourceCoords - targetCoords)

        if distance > Config.DistanceGive then
            print(("[^3WARNING^7] Player Detected Cheating: ^5%s^7"):format(GetPlayerName(playerId)))
            return
        end

        if itemType == "item_standard" then
            local sourceItem = sourceXPlayer.getInventoryItem(itemName)

            if not sourceItem then
                return
            end

            if itemCount < 1 or sourceItem.count < itemCount then
                return sourceXPlayer.showNotification(TranslateCap("imp_invalid_quantity"))
            end

            if not targetXPlayer.canCarryItem(itemName, itemCount) then
                return sourceXPlayer.showNotification(TranslateCap("ex_inv_lim", targetXPlayer.name))
            end

            sourceXPlayer.removeInventoryItem(itemName, itemCount)
            targetXPlayer.addInventoryItem(itemName, itemCount)

            sourceXPlayer.showNotification(TranslateCap("gave_item", itemCount, sourceItem.label, targetXPlayer.name))
            targetXPlayer.showNotification(TranslateCap("received_item", itemCount, sourceItem.label, sourceXPlayer.name))
        elseif itemType == "item_account" then
            local sourceAccount = sourceXPlayer.getAccount(itemName)
            if not sourceAccount then
                return sourceXPlayer.showNotification(TranslateCap("imp_invalid_type"))
            end
            if itemCount < 1 or sourceAccount.money < itemCount then
                return sourceXPlayer.showNotification(TranslateCap("imp_invalid_amount"))
            end

            sourceXPlayer.removeAccountMoney(itemName, itemCount, "Gave to " .. targetXPlayer.name)
            targetXPlayer.addAccountMoney(itemName, itemCount, "Received from " .. sourceXPlayer.name)

            local accountLabel = Config.Accounts[itemName] and Config.Accounts[itemName].label or itemName
            sourceXPlayer.showNotification(TranslateCap("gave_account_money", ESX.Math.GroupDigits(itemCount), accountLabel, targetXPlayer.name))
            targetXPlayer.showNotification(TranslateCap("received_account_money", ESX.Math.GroupDigits(itemCount), accountLabel, sourceXPlayer.name))
        elseif itemType == "item_weapon" then
            if not sourceXPlayer.hasWeapon(itemName) then
                return
            end

            local weaponLabel = ESX.GetWeaponLabel(itemName)
            if targetXPlayer.hasWeapon(itemName) then
                sourceXPlayer.showNotification(TranslateCap("gave_weapon_hasalready", targetXPlayer.name, weaponLabel))
                targetXPlayer.showNotification(TranslateCap("received_weapon_hasalready", sourceXPlayer.name, weaponLabel))
                return
            end

            local _, weapon = sourceXPlayer.getWeapon(itemName)
            if not weapon then
                return
            end

            local _, weaponObject = ESX.GetWeapon(itemName)
            itemCount = weapon.ammo
            local weaponComponents = ESX.Table.Clone(weapon.components)
            local weaponTint = weapon.tintIndex

            if weaponTint then
                targetXPlayer.setWeaponTint(itemName, weaponTint)
            end

            if weaponComponents then
                for _, v in pairs(weaponComponents) do
                    targetXPlayer.addWeaponComponent(itemName, v)
                end
            end

            sourceXPlayer.removeWeapon(itemName)
            targetXPlayer.addWeapon(itemName, itemCount)

            if weaponObject.ammo and itemCount > 0 then
                local ammoLabel = weaponObject.ammo.label
                sourceXPlayer.showNotification(TranslateCap("gave_weapon_withammo", weaponLabel, itemCount, ammoLabel, targetXPlayer.name))
                targetXPlayer.showNotification(TranslateCap("received_weapon_withammo", weaponLabel, itemCount, ammoLabel, sourceXPlayer.name))
            else
                sourceXPlayer.showNotification(TranslateCap("gave_weapon", weaponLabel, targetXPlayer.name))
                targetXPlayer.showNotification(TranslateCap("received_weapon", weaponLabel, sourceXPlayer.name))
            end
        elseif itemType == "item_ammo" then
            if type(itemCount) ~= "number" or itemCount < 1 then
                return
            end

            if not sourceXPlayer.hasWeapon(itemName) then
                return
            end

            local _, weapon = sourceXPlayer.getWeapon(itemName)
            if not weapon then
                return
            end

            if not targetXPlayer.hasWeapon(itemName) then
                sourceXPlayer.showNotification(TranslateCap("gave_weapon_noweapon", targetXPlayer.name))
                targetXPlayer.showNotification(TranslateCap("received_weapon_noweapon", sourceXPlayer.name, weapon.label))
                return
            end

            local _, weaponObject = ESX.GetWeapon(itemName)

            if not weaponObject.ammo then return end

            local ammoLabel = weaponObject.ammo.label
            if weapon.ammo >= itemCount then
                sourceXPlayer.removeWeaponAmmo(itemName, itemCount)
                targetXPlayer.addWeaponAmmo(itemName, itemCount)

                sourceXPlayer.showNotification(TranslateCap("gave_weapon_ammo", itemCount, ammoLabel, weapon.label, targetXPlayer.name))
                targetXPlayer.showNotification(TranslateCap("received_weapon_ammo", itemCount, ammoLabel, weapon.label, sourceXPlayer.name))
            end
        end
    end)

    RegisterNetEvent("esx:removeInventoryItem", function(itemType, itemName, itemCount)
        local playerId = source
        local xPlayer = ESX.GetPlayerFromId(playerId)

        if not xPlayer then
            return
        end

        if itemType == "item_standard" then
            if not itemCount or itemCount < 1 then
                return xPlayer.showNotification(TranslateCap("imp_invalid_quantity"))
            end

            local xItem = xPlayer.getInventoryItem(itemName)
            if not xItem then
                return
            end

            if itemCount > xItem.count or xItem.count < 1 then
                return xPlayer.showNotification(TranslateCap("imp_invalid_quantity"))
            end

            xPlayer.removeInventoryItem(itemName, itemCount)
            local pickupLabel = ("%s [%s]"):format(xItem.label, itemCount)
            ESX.CreatePickup("item_standard", itemName, itemCount, pickupLabel, playerId)
            xPlayer.showNotification(TranslateCap("threw_standard", itemCount, xItem.label))
        elseif itemType == "item_account" then
            if itemCount == nil or itemCount < 1 then
                return xPlayer.showNotification(TranslateCap("imp_invalid_amount"))
            end

            local account = xPlayer.getAccount(itemName)
            if not account then
                return
            end

            if itemCount > account.money or account.money < 1 then
                return xPlayer.showNotification(TranslateCap("imp_invalid_amount"))
            end

            xPlayer.removeAccountMoney(itemName, itemCount, "Threw away")
            local pickupLabel = ("%s [%s]"):format(account.label, TranslateCap("locale_currency", ESX.Math.GroupDigits(itemCount)))
            ESX.CreatePickup("item_account", itemName, itemCount, pickupLabel, playerId)
            xPlayer.showNotification(TranslateCap("threw_account", ESX.Math.GroupDigits(itemCount), string.lower(account.label)))
        elseif itemType == "item_weapon" then
            itemName = string.upper(itemName)

            if not xPlayer.hasWeapon(itemName) then return end

            local _, weapon = xPlayer.getWeapon(itemName)
            if not weapon then
                return
            end

            local _, weaponObject = ESX.GetWeapon(itemName)
            -- luacheck: ignore weaponPickupLabel
            local weaponPickupLabel = ""
            local components = ESX.Table.Clone(weapon.components)
            xPlayer.removeWeapon(itemName)

            if weaponObject.ammo and weapon.ammo > 0 then
                local ammoLabel = weaponObject.ammo.label
                weaponPickupLabel = ("%s [%s %s]"):format(weapon.label, weapon.ammo, ammoLabel)
                xPlayer.showNotification(TranslateCap("threw_weapon_ammo", weapon.label, weapon.ammo, ammoLabel))
            else
                weaponPickupLabel = ("%s"):format(weapon.label)
                xPlayer.showNotification(TranslateCap("threw_weapon", weapon.label))
            end

            ESX.CreatePickup("item_weapon", itemName, weapon.ammo, weaponPickupLabel, playerId, components, weapon.tintIndex)
        end
    end)

    RegisterNetEvent("esx:useItem", function(itemName)
        local source = source

        if type(itemName) ~= "string" then
            return
        end

        local xPlayer = ESX.GetPlayerFromId(source)
        if not xPlayer then
            if Config.EnableDebug then
                print('^3[ESX Debug]^7 esx:useItem - xPlayer not found for source: ' .. tostring(source))
            end
            return
        end

        local item = xPlayer.getInventoryItem(itemName)
        if not item or item.count < 1 then
            if Config.EnableDebug then
                print('^3[ESX Debug]^7 esx:useItem - item not found or count < 1')
            end
            return xPlayer.showNotification(TranslateCap("act_imp"))
        end

        local cooldownKey = ("%s:%s"):format(source, itemName)
        local now = GetGameTimer()

        if useCooldown[cooldownKey] and (now - useCooldown[cooldownKey]) < 300 then
            return
        end

        useCooldown[cooldownKey] = now

        if item.limit and item.limit ~= -1 and item.count > item.limit then
            if Config.EnableDebug then
                print('^3[ESX Debug]^7 esx:useItem - item count exceeds limit')
            end
            return xPlayer.showNotification(TranslateCap("act_imp"))
        end

        if Config.EnableDebug then
            print('^3[ESX Debug]^7 esx:useItem called for item: ' .. itemName)
        end
        ESX.UseItem(source, itemName)
    end)

    RegisterNetEvent("esx:onPickup", function(pickupId)
        local pickup, xPlayer, success = Core.Pickups[pickupId], ESX.GetPlayerFromId(source)

        if not xPlayer then
            return
        end

        if not pickup then return end

        local playerPickupDistance = #(pickup.coords - xPlayer.getCoords(true))
        if playerPickupDistance > 5.0 then
            print(("[^3WARNING^7] Player Detected Cheating (Out of range pickup): ^5%s^7"):format(xPlayer.getIdentifier()))
            return
        end

        if pickup.type == "item_standard" then
            if not xPlayer.canCarryItem(pickup.name, pickup.count) then
                return xPlayer.showNotification(TranslateCap("threw_cannot_pickup"))
            end

            xPlayer.addInventoryItem(pickup.name, pickup.count)
            success = true
        elseif pickup.type == "item_account" then
            success = true
            xPlayer.addAccountMoney(pickup.name, pickup.count, "Picked up")
        elseif pickup.type == "item_weapon" then
            if xPlayer.hasWeapon(pickup.name) then
                return xPlayer.showNotification(TranslateCap("threw_weapon_already"))
            end

            success = true
            xPlayer.addWeapon(pickup.name, pickup.count)
            xPlayer.setWeaponTint(pickup.name, pickup.tintIndex)

            for _, v in ipairs(pickup.components) do
                xPlayer.addWeaponComponent(pickup.name, v)
            end
        end

        if success then
            Core.Pickups[pickupId] = nil
            TriggerClientEvent("esx:removePickup", -1, pickupId)
        end
    end)
end

ESX.RegisterServerCallback("esx:getPlayerData", function(source, cb)
    local xPlayer = ESX.GetPlayerFromId(source)

    if not xPlayer then
        return
    end

    cb({
        identifier = xPlayer.identifier,
        accounts = xPlayer.getAccounts(),
        inventory = xPlayer.getInventory(),
        job = xPlayer.getJob(),
        loadout = xPlayer.getLoadout(),
        money = xPlayer.getMoney(),
        position = xPlayer.getCoords(true),
        metadata = xPlayer.getMeta(),
    })
end)

ESX.RegisterServerCallback("esx:isUserAdmin", function(source, cb)
    cb(Core.IsPlayerAdmin(source))
end)

ESX.RegisterServerCallback("esx:getGameBuild", function(_, cb)
    cb(tonumber(GetConvar("sv_enforceGameBuild", "1604")))
end)

ESX.RegisterServerCallback("esx:getPlayerNames", function(source, cb, players)
    if type(players) ~= "table" then
        return cb({})
    end

    players[source] = nil

    local names = {}
    local count = 0

    for playerId, _ in pairs(players) do
        count = count + 1

        if count > 64 then
            break
        end

        local xPlayer = ESX.GetPlayerFromId(playerId)

        if xPlayer then
            names[playerId] = xPlayer.getName()
        end
    end

    cb(names)
end)

AddEventHandler("txAdmin:events:scheduledRestart", function(eventData)
    if eventData.secondsRemaining == 60 then
        CreateThread(function()
            Wait(50000)
            Core.SavePlayers()
        end)
    end
end)

AddEventHandler("txAdmin:events:serverShuttingDown", function()
    Core.SavePlayers()
end)

local DoNotUse = {
    ["essentialmode"] = true,
    ["es_admin2"] = true,
    ["basic-gamemode"] = true,
    ["mapmanager"] = true,
    ["fivem-map-skater"] = true,
    ["fivem-map-hipster"] = true,
    ["qb-core"] = true,
    ["default_spawnpoint"] = true,
}

AddEventHandler("onResourceStart", function(key)
    if DoNotUse[string.lower(key)] then
        while GetResourceState(key) ~= "started" do
            Wait(0)
        end

        StopResource(key)
        error(("WE STOPPED A RESOURCE THAT WILL BREAK ^1ESX^1, PLEASE REMOVE ^5%s^1"):format(key))
    end
    -- luacheck: ignore
    if not SetEntityOrphanMode then
        CreateThread(function()
            while true do
                error("ESX Requires a minimum Artifact version of 10188, Please update your server.")
                Wait(60 * 1000)
            end
        end)
    end
end)

for key in pairs(DoNotUse) do
    if GetResourceState(key) == "started" or GetResourceState(key) == "starting" then
        StopResource(key)
        error(("WE STOPPED A RESOURCE THAT WILL BREAK ^1ESX^1, PLEASE REMOVE ^5%s^1"):format(key))
    end
end
