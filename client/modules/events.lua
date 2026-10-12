local pickups = {}

RegisterNetEvent("esx:requestModel", function(model)
    ESX.Streaming.RequestModel(model)
end)

-- Fallback spawn position if coords are nil (prevent falling through map)
local DEFAULT_SPAWN = { x = 222.2027, y = -864.0162, z = 30.2922, heading = 1.0 }

-- Helper function to get safe spawn coords (never nil, never limbo-origin garbage)
local function getSafeSpawnCoords(coords)
    if coords and coords.x and coords.y and coords.z
        and not (math.abs(coords.x) < 1.0 and math.abs(coords.y) < 1.0) then
        return coords
    end
    print('[ESX] WARNING: Spawn coords were nil/invalid, using default spawn to prevent falling through map')
    return DEFAULT_SPAWN
end

-- Track if this is a new player who needs to complete registration first
local isNewPlayer = false
local pendingSpawnCoords = nil
local pendingSpawnSkin = nil
local isNewPlayerFirstSkin = false  -- Track if new player needs login reward after first skin

RegisterNetEvent("esx:playerLoaded", function(xPlayer, isNew, skin)
    ESX.PlayerData = xPlayer
    isNewPlayer = isNew

    -- Ensure coords are never nil
    local spawnCoords = getSafeSpawnCoords(ESX.PlayerData.coords)

    if not Config.Multichar then
        if isNew then
            -- NEW PLAYER: Don't spawn yet - wait for registration + skin to complete
            pendingSpawnCoords = spawnCoords
            pendingSpawnSkin = skin
            -- Just trigger loading screen off so identity can show registration
            TriggerEvent("esx:loadingScreenOff")
            return
        else
            -- EXISTING PLAYER: Spawn immediately
            ESX.SpawnPlayer(skin, spawnCoords, function()
                TriggerEvent("esx:onPlayerSpawn")
                TriggerEvent("esx:restoreLoadout")
                TriggerServerEvent("esx:onPlayerSpawn")
                TriggerEvent("esx:loadingScreenOff")
            end)
        end
    end

    while not DoesEntityExist(ESX.PlayerData.ped) do
        Wait(20)
    end

    ESX.PlayerLoaded = true

    local timer = GetGameTimer()
    while not HaveAllStreamingRequestsCompleted(ESX.PlayerData.ped) and (GetGameTimer() - timer) < 2000 do
        Wait(0)
    end

    Adjustments:Load()

    ClearPedTasksImmediately(ESX.PlayerData.ped)

    if not Config.Multichar then
        Core.FreezePlayer(false)
    end

    DoScreenFadeIn(800)

    Actions:Init()
    StartPointsLoop()
    StartServerSyncLoops()
    NetworkSetLocalPlayerSyncLookAt(true)
end)

local isFirstSpawn = true
ESX.SecureNetEvent("esx:onPlayerLogout", function()
    ESX.PlayerLoaded = false
    isFirstSpawn = true
    isNewPlayer = false
    pendingSpawnCoords = nil
    pendingSpawnSkin = nil
    isNewPlayerFirstSkin = false
end)

-- Handle new player registered - spawn first, then open skin menu
-- MUST NOT gate on isNewPlayer: a quit/crash mid-registration leaves the user row
-- created (isNew=false on rejoin) while registration still completes later — the player
-- still needs the spawn + skin-menu flow or they stay stuck in limbo forever.
AddEventHandler("esx:newPlayerRegistered", function()
    print('[es_extended] esx:newPlayerRegistered triggered, isNewPlayer=' .. tostring(isNewPlayer))

    local firstInit = not ESX.PlayerLoaded

    -- Ensure spawn coords are never nil (safety check)
    local spawnCoords = getSafeSpawnCoords(pendingSpawnCoords)

    -- Spawn with default skin first (will be customized in skin menu)
    local defaultSkin = pendingSpawnSkin or { sex = 0 }

    ESX.SpawnPlayer(defaultSkin, spawnCoords, function()
        TriggerEvent("esx:onPlayerSpawn")
        TriggerEvent("esx:restoreLoadout")
        TriggerServerEvent("esx:onPlayerSpawn")

        -- Run initialization
        local timer = GetGameTimer()
        while not HaveAllStreamingRequestsCompleted(ESX.PlayerData.ped) and (GetGameTimer() - timer) < 2000 do
            Wait(0)
        end

        Adjustments:Load()
        ClearPedTasksImmediately(ESX.PlayerData.ped)

        if not Config.Multichar then
            Core.FreezePlayer(false)
        end

        if IsScreenFadedOut() then
            DoScreenFadeIn(500)
        end

        -- PlayerLoaded must be true BEFORE the sync loops start (they exit while not loaded)
        ESX.PlayerLoaded = true
        if firstInit then
            Actions:Init()
            StartPointsLoop()
            StartServerSyncLoops()
            NetworkSetLocalPlayerSyncLookAt(true)
        end

        -- Clear pending state
        isNewPlayer = false
        pendingSpawnCoords = nil
        pendingSpawnSkin = nil

        -- Mark that this new player needs login reward after first skin
        isNewPlayerFirstSkin = true

        -- Now open skin menu (player is spawned and ready)
        TriggerEvent('esx:openSkinMenu', { isNewPlayer = true })
    end)
end)

-- Handle skin saved event - trigger login reward for new players after first skin customization
AddEventHandler("esx:skinSaved", function(skin)
    if isNewPlayerFirstSkin then
        isNewPlayerFirstSkin = false

        -- Trigger server event to give login reward to new player
        TriggerServerEvent('esx_identity:newPlayerFirstLogin')
    end
end)


ESX.SecureNetEvent("esx:setMaxWeight", function(newMaxWeight)
    ESX.SetPlayerData("maxWeight", newMaxWeight)
end)

ESX.SecureNetEvent("esx:setInventory", function(newInventory)
    ESX.SetPlayerData("inventory", newInventory)
end)

-- freemode female peds default to a lower max health than male ones, and a model swap
-- resets max health, so every spawn / skin change re-applies the configured ceiling
local function applyMaxHealth(ped)
    local maxHealth = Config.PlayerMaxHealth
    if not maxHealth or maxHealth <= 0 then
        return
    end

    -- topping a ped that was already at its old ceiling keeps "full" meaning full; a
    -- partially hurt ped is left alone so a wardrobe/model swap can never heal anyone
    local health = GetEntityHealth(ped)
    local wasFull = health >= GetEntityMaxHealth(ped)

    SetEntityMaxHealth(ped, maxHealth)

    if wasFull or health > maxHealth then
        SetEntityHealth(ped, maxHealth)
    end
end

local function onPlayerSpawn()
    ESX.SetPlayerData("ped", PlayerPedId())
    ESX.SetPlayerData("dead", false)
    applyMaxHealth(ESX.PlayerData.ped)
end

AddEventHandler("playerSpawned", onPlayerSpawn)
AddEventHandler("esx:onPlayerSpawn", function()
    onPlayerSpawn()

    if isFirstSpawn then
        isFirstSpawn = false

        if not Config.SaveHealthAndArmor then
            return
        end

        if ESX.PlayerData.metadata.health and (ESX.PlayerData.metadata.health > 0 or Config.SaveDeathStatus) then
            SetEntityHealth(ESX.PlayerData.ped, ESX.PlayerData.metadata.health)
        end

        if ESX.PlayerData.metadata.armor and ESX.PlayerData.metadata.armor > 0 then
            SetPedArmour(ESX.PlayerData.ped, ESX.PlayerData.metadata.armor)
        end
    end
end)

AddEventHandler("esx:onPlayerDeath", function()
    ESX.SetPlayerData("ped", PlayerPedId())
    ESX.SetPlayerData("dead", true)
end)

AddEventHandler("skinchanger:modelLoaded", function()
    while not ESX.PlayerLoaded do
        Wait(100)
    end
    applyMaxHealth(PlayerPedId())
    TriggerEvent("esx:restoreLoadout")
end)

AddEventHandler("esx:restoreLoadout", function()
    ESX.SetPlayerData("ped", PlayerPedId())

    if not Config.CustomInventory then
        local ammoTypes = {}
        RemoveAllPedWeapons(ESX.PlayerData.ped, true)

        for _, v in ipairs(ESX.PlayerData.loadout) do
            local weaponName = v.name
            local weaponHash = joaat(weaponName)

            GiveWeaponToPed(ESX.PlayerData.ped, weaponHash, 0, false, false)
            SetPedWeaponTintIndex(ESX.PlayerData.ped, weaponHash, v.tintIndex)

            local ammoType = GetPedAmmoTypeFromWeapon(ESX.PlayerData.ped, weaponHash)

            for _, v2 in ipairs(v.components) do
                local componentHash = ESX.GetWeaponComponent(weaponName, v2).hash
                GiveWeaponComponentToPed(ESX.PlayerData.ped, weaponHash, componentHash)
            end

            if not ammoTypes[ammoType] then
                AddAmmoToPed(ESX.PlayerData.ped, weaponHash, v.ammo)
                ammoTypes[ammoType] = true
            end
        end
    end
end)

---@diagnostic disable-next-line: param-type-mismatch
AddStateBagChangeHandler("VehicleProperties", nil, function(bagName, _, value)
    -- FIX: Skip if player is not loaded (prevents crash on server shutdown)
    if not ESX.PlayerLoaded then
        return
    end

    if not value then
        return
    end

    bagName = bagName:gsub("entity:", "")
    local netId = tonumber(bagName)
    if not netId then
        error("Tried to set vehicle properties with invalid netId")
        return
    end

    local tries = 0

    while not NetworkDoesEntityExistWithNetworkId(netId) do
        Wait(200)
        tries = tries + 1
        -- FIX: Also check ESX.PlayerLoaded in loop to exit early on shutdown
        if tries > 20 or not ESX.PlayerLoaded then
            if not ESX.PlayerLoaded then
                return -- Silent exit on shutdown
            end
            return error(("Invalid entity - ^5%s^7!"):format(netId))
        end
    end

    -- FIX: Final check before accessing vehicle
    if not ESX.PlayerLoaded then
        return
    end

    local vehicle = NetToVeh(netId)

    if NetworkGetEntityOwner(vehicle) ~= ESX.playerId then
        return
    end

    ESX.Game.SetVehicleProperties(vehicle, value)
end)

ESX.SecureNetEvent("esx:setAccountMoney", function(account)
    -- Guard against race condition when player data not yet loaded
    if not ESX.PlayerData.accounts then
        print('[ESX] Warning: setAccountMoney called before player data loaded, ignoring')
        return
    end

    for i = 1, #ESX.PlayerData.accounts do
        if ESX.PlayerData.accounts[i].name == account.name then
            ESX.PlayerData.accounts[i] = account
            break
        end
    end

    ESX.SetPlayerData("accounts", ESX.PlayerData.accounts)
end)

if not Config.CustomInventory then
    ESX.SecureNetEvent("esx:addInventoryItem", function(item, count, showNotification)
        -- Guard against race condition
        if not ESX.PlayerData.inventory then
            print('[ESX] Warning: addInventoryItem called before player data loaded, ignoring')
            return
        end

        local itemLabel = item
        for k, v in ipairs(ESX.PlayerData.inventory) do
            if v.name == item then
                ESX.UI.ShowInventoryItemNotification(true, v.label, count - v.count, v.name)
                ESX.PlayerData.inventory[k].count = count
                itemLabel = v.label
                break
            end
        end

        if showNotification then
            ESX.UI.ShowInventoryItemNotification(true, itemLabel, count, item)
        end
    end)

    ESX.SecureNetEvent("esx:removeInventoryItem", function(item, count, showNotification)
        -- Guard against race condition
        if not ESX.PlayerData.inventory then
            print('[ESX] Warning: removeInventoryItem called before player data loaded, ignoring')
            return
        end

        local itemLabel = item
        for i = 1, #ESX.PlayerData.inventory do
            if ESX.PlayerData.inventory[i].name == item then
                ESX.UI.ShowInventoryItemNotification(false, ESX.PlayerData.inventory[i].label, ESX.PlayerData.inventory[i].count - count, ESX.PlayerData.inventory[i].name)
                ESX.PlayerData.inventory[i].count = count
                itemLabel = ESX.PlayerData.inventory[i].label
                break
            end
        end

        if showNotification then
            ESX.UI.ShowInventoryItemNotification(false, itemLabel, count, item)
        end
    end)

    ESX.SecureNetEvent("esx:addLoadoutItem", function(weaponName, weaponLabel, ammo)
        -- Guard against race condition
        if not ESX.PlayerData.loadout then
            print('[ESX] Warning: addLoadoutItem called before player data loaded, ignoring')
            return
        end

        table.insert(ESX.PlayerData.loadout, {
            name = weaponName,
            ammo = ammo,
            label = weaponLabel,
            components = {},
            tintIndex = 0,
        })
    end)

    ESX.SecureNetEvent("esx:removeLoadoutItem", function(weaponName, weaponLabel)
        -- Guard against race condition
        if not ESX.PlayerData.loadout then
            print('[ESX] Warning: removeLoadoutItem called before player data loaded, ignoring')
            return
        end

        for i = 1, #ESX.PlayerData.loadout do
            if ESX.PlayerData.loadout[i].name == weaponName then
                table.remove(ESX.PlayerData.loadout, i)
                break
            end
        end
    end)

    RegisterNetEvent("esx:addWeapon", function()
        error("event ^5'esx:addWeapon'^1 Has Been Removed. Please use ^5xPlayer.addWeapon^1 Instead!")
    end)


    RegisterNetEvent("esx:addWeaponComponent", function()
        error("event ^5'esx:addWeaponComponent'^1 Has Been Removed. Please use ^5xPlayer.addWeaponComponent^1 Instead!")
    end)

    RegisterNetEvent("esx:setWeaponAmmo", function()
        error("event ^5'esx:setWeaponAmmo'^1 Has Been Removed. Please use ^5xPlayer.addWeaponAmmo^1 Instead!")
    end)

    ESX.SecureNetEvent("esx:setWeaponTint", function(weapon, weaponTintIndex)
        SetPedWeaponTintIndex(ESX.PlayerData.ped, joaat(weapon), weaponTintIndex)
    end)

    RegisterNetEvent("esx:removeWeapon", function()
        error("event ^5'esx:removeWeapon'^1 Has Been Removed. Please use ^5xPlayer.removeWeapon^1 Instead!")
    end)

    ESX.SecureNetEvent("esx:removeWeaponComponent", function(weapon, weaponComponent)
        local componentHash = ESX.GetWeaponComponent(weapon, weaponComponent).hash
        RemoveWeaponComponentFromPed(ESX.PlayerData.ped, joaat(weapon), componentHash)
    end)
end

ESX.SecureNetEvent("esx:setJob", function(Job)
    ESX.SetPlayerData("job", Job)
end)

ESX.SecureNetEvent("esx:setGroup", function(group)
    ESX.SetPlayerData("group", group)
end)

if not Config.CustomInventory then
    ESX.SecureNetEvent("esx:createPickup", function(pickupId, label, coords, itemType, name, components, tintIndex)
        local function setObjectProperties(object)
            SetEntityAsMissionEntity(object, true, false)
            PlaceObjectOnGroundProperly(object)
            FreezeEntityPosition(object, true)
            SetEntityCollision(object, false, true)

            pickups[pickupId] = {
                obj = object,
                label = label,
                inRange = false,
                coords = coords,
            }
        end

        if itemType == "item_weapon" then
            local weaponHash = joaat(name)
            ESX.Streaming.RequestWeaponAsset(weaponHash)
            local pickupObject = CreateWeaponObject(weaponHash, 50, coords.x, coords.y, coords.z, true, 1.0, 0)
            SetWeaponObjectTintIndex(pickupObject, tintIndex)

            for _, v in ipairs(components) do
                local component = ESX.GetWeaponComponent(name, v)
                if component then
                    GiveWeaponComponentToWeaponObject(pickupObject, component.hash)
                end
            end

            setObjectProperties(pickupObject)
        else
            ESX.Game.SpawnLocalObject("prop_money_bag_01", coords, setObjectProperties)
        end
    end)

    ESX.SecureNetEvent("esx:createMissingPickups", function(missingPickups)
        if not missingPickups or type(missingPickups) ~= "table" then return end

        for pickupId, pickup in pairs(missingPickups) do
            -- OPTIMIZATION: Validate pickup data before creating
            if pickup and pickup.coords and pickup.label then
                TriggerEvent("esx:createPickup", pickupId, pickup.label, vector3(pickup.coords.x, pickup.coords.y, pickup.coords.z - 1.0), pickup.type, pickup.name, pickup.components, pickup.tintIndex)
            end
        end
    end)
end

ESX.SecureNetEvent("esx:registerSuggestions", function(registeredCommands)
    for name, command in pairs(registeredCommands) do
        if command.suggestion then
            TriggerEvent("chat:addSuggestion", ("/%s"):format(name), command.suggestion.help, command.suggestion.arguments)
        end
    end
end)

if not Config.CustomInventory then
    ESX.SecureNetEvent("esx:removePickup", function(pickupId)
        if pickups[pickupId] and pickups[pickupId].obj then
            ESX.Game.DeleteObject(pickups[pickupId].obj)
            pickups[pickupId] = nil
        end
    end)
end

function StartServerSyncLoops()
    if Config.CustomInventory then return end

    local currentWeapon = {
        ---@type number
        ---@diagnostic disable-next-line: assign-type-mismatch
        hash = `WEAPON_UNARMED`,
        ammo = 0,
    }

    local function updateCurrentWeaponAmmo(weaponName)
        local newAmmo = GetAmmoInPedWeapon(ESX.PlayerData.ped, currentWeapon.hash)

        if newAmmo ~= currentWeapon.ammo then
            currentWeapon.ammo = newAmmo
            TriggerServerEvent("esx:updateWeaponAmmo", weaponName, newAmmo)
        end
    end

    CreateThread(function()
        while ESX.PlayerLoaded do
            local ped = ESX.PlayerData.ped

            if DoesEntityExist(ped) then
                currentWeapon.hash = GetSelectedPedWeapon(ped)

                if currentWeapon.hash ~= `WEAPON_UNARMED` then
                    local weaponConfig = ESX.GetWeaponFromHash(currentWeapon.hash)

                    if weaponConfig then
                        currentWeapon.ammo = GetAmmoInPedWeapon(ped, currentWeapon.hash)

                        -- OPTIMIZATION: Added ESX.PlayerLoaded check to inner loop
                        while ESX.PlayerLoaded and DoesEntityExist(ped) and GetSelectedPedWeapon(ped) == currentWeapon.hash do
                            updateCurrentWeaponAmmo(weaponConfig.name)
                            Wait(1000)
                        end

                        if ESX.PlayerLoaded and DoesEntityExist(ped) then
                            updateCurrentWeaponAmmo(weaponConfig.name)
                        end
                    end
                end
            end

            Wait(250)
        end
    end)

    CreateThread(function()
        local PARACHUTE_OPENING <const> = 1
        local PARACHUTE_OPEN <const> = 2

        while ESX.PlayerLoaded do
            local ped = ESX.PlayerData.ped

            if DoesEntityExist(ped) then
                local parachuteState = GetPedParachuteState(ped)

                if parachuteState == PARACHUTE_OPENING or parachuteState == PARACHUTE_OPEN then
                    TriggerServerEvent("esx:updateWeaponAmmo", "GADGET_PARACHUTE", 0)

                    -- OPTIMIZATION: Added ESX.PlayerLoaded and ped check to inner loop
                    while ESX.PlayerLoaded and DoesEntityExist(ped) and GetPedParachuteState(ped) ~= -1 do
                        Wait(1000)
                    end
                end
            end

            Wait(500)
        end
    end)
end

if not Config.CustomInventory then
    -- OPTIMIZATION: Pickup system with reduced O(n) operations
    local nearbyPickups = {}  -- Cache of pickups within range
    local lastPlayerCoords = vector3(0, 0, 0)
    local NEARBY_THRESHOLD_SQ = 25  -- 5^2 - use squared distance for quick check
    local FAR_THRESHOLD_SQ = 2500   -- 50^2 - pickups further than this are ignored in frequent checks

    -- Background thread: Update nearby pickups list (runs less frequently)
    CreateThread(function()
        -- Wait for player to be loaded before starting pickup loop
        while not ESX.PlayerLoaded do
            Wait(1000)
        end

        -- FIX: Check ESX.PlayerLoaded to prevent crash on server shutdown
        while ESX.PlayerLoaded do
            Wait(1000)  -- Update nearby list every second

            -- Double-check after wait (player might have disconnected during wait)
            if not ESX.PlayerLoaded then break end

            if DoesEntityExist(ESX.PlayerData.ped) then
                local playerCoords = GetEntityCoords(ESX.PlayerData.ped)
                local newNearby = {}

                for pickupId, pickup in pairs(pickups) do
                    -- Use squared distance for quick rejection (avoids sqrt)
                    local dx = playerCoords.x - pickup.coords.x
                    local dy = playerCoords.y - pickup.coords.y
                    local dz = playerCoords.z - pickup.coords.z
                    local distSq = dx * dx + dy * dy + dz * dz

                    if distSq < FAR_THRESHOLD_SQ then
                        newNearby[pickupId] = {
                            pickup = pickup,
                            distSq = distSq
                        }
                    elseif pickup.inRange then
                        pickup.inRange = false
                    end
                end

                nearbyPickups = newNearby
                lastPlayerCoords = playerCoords
            end
        end
    end)

    -- Main thread: Handle nearby pickups (runs frequently when pickups are close)
    CreateThread(function()
        -- Wait for player to be loaded before starting pickup loop
        while not ESX.PlayerLoaded do
            Wait(1000)
        end

        -- FIX: Check ESX.PlayerLoaded to prevent crash on server shutdown
        local closestPlayerDistance = -1
        local closestPlayerCheck = 0

        while ESX.PlayerLoaded do
            local Sleep = 500  -- Default sleep when no pickups nearby

            if DoesEntityExist(ESX.PlayerData.ped) then
                -- Only do expensive operations if there are nearby pickups
                if next(nearbyPickups) then
                    local playerCoords = GetEntityCoords(ESX.PlayerData.ped)
                    local closestDistance = -1
                    local hasVeryClose = false

                    -- Only get closest player if we have pickups within interaction range
                    for _, data in pairs(nearbyPickups) do
                        if data.distSq < NEARBY_THRESHOLD_SQ then
                            hasVeryClose = true
                            break
                        end
                    end

                    if hasVeryClose then
                        local now = GetGameTimer()

                        if (now - closestPlayerCheck) >= 250 then
                            closestPlayerCheck = now
                            _, closestPlayerDistance = ESX.Game.GetClosestPlayer(playerCoords)
                        end

                        closestDistance = closestPlayerDistance
                        Sleep = 0  -- Need to check every frame for interaction
                    end

                    for pickupId, data in pairs(nearbyPickups) do
                        local pickup = data.pickup
                        -- Recalculate actual distance for close pickups
                        local distance = #(playerCoords - pickup.coords)

                        if distance < 5 then
                            local label = pickup.label

                            if distance < 1 then
                                if IsControlJustReleased(0, 38) then
                                    if IsPedOnFoot(ESX.PlayerData.ped) and (closestDistance == -1 or closestDistance > 3) and not pickup.inRange then
                                        pickup.inRange = true

                                        local dict, anim = "weapons@first_person@aim_rng@generic@projectile@sticky_bomb@", "plant_floor"
                                        ESX.Streaming.RequestAnimDict(dict)
                                        TaskPlayAnim(ESX.PlayerData.ped, dict, anim, 8.0, 1.0, 1000, 16, 0.0, false, false, false)
                                        RemoveAnimDict(dict)
                                        Wait(1000)

                                        -- Check again after wait
                                        if not ESX.PlayerLoaded then break end

                                        TriggerServerEvent("esx:onPickup", pickupId)
                                        PlaySoundFrontend(-1, "PICK_UP", "HUD_FRONTEND_DEFAULT_SOUNDSET", false)
                                    end
                                end

                                label = ("%s~n~%s"):format(label, TranslateCap("threw_pickup_prompt"))
                            end

                            local textCoords = pickup.coords + vector3(0.0, 0.0, 0.25)
                            ESX.Game.Utils.DrawText3D(textCoords, label, 1.2, 1)
                        elseif pickup.inRange then
                            pickup.inRange = false
                        end
                    end
                end
            else
                Sleep = 1000
            end

            Wait(Sleep)
        end
    end)
end

----- Admin commands from esx_adminplus
RegisterNetEvent("esx:tpm", function()
    local GetEntityCoords = GetEntityCoords
    local GetGroundZFor_3dCoord = GetGroundZFor_3dCoord
    local GetFirstBlipInfoId = GetFirstBlipInfoId
    local DoesBlipExist = DoesBlipExist
    local DoScreenFadeOut = DoScreenFadeOut
    local GetBlipInfoIdCoord = GetBlipInfoIdCoord
    local GetVehiclePedIsIn = GetVehiclePedIsIn

    ESX.TriggerServerCallback("esx:isUserAdmin", function(admin)
        if not admin then
            return
        end
        local blipMarker = GetFirstBlipInfoId(8)
        if not DoesBlipExist(blipMarker) then
            ESX.ShowNotification(TranslateCap("tpm_nowaypoint"), "error")
            return "marker"
        end

        -- Fade screen to hide how clients get teleported.
        DoScreenFadeOut(650)
        while not IsScreenFadedOut() do
            Wait(0)
        end

        local ped, coords = ESX.PlayerData.ped, GetBlipInfoIdCoord(blipMarker)
        local vehicle = GetVehiclePedIsIn(ped, false)
        local oldCoords = GetEntityCoords(ped)

        -- Unpack coords instead of having to unpack them while iterating.
        -- 825.0 seems to be the max a player can reach while 0.0 being the lowest.
        local x, y, groundZ, Z_START = coords["x"], coords["y"], 850.0, 950.0
        local found = false
        FreezeEntityPosition(vehicle > 0 and vehicle or ped, true)

        for i = Z_START, 0, -25.0 do
            local z = i
            if (i % 2) ~= 0 then
                z = Z_START - i
            end

            NewLoadSceneStart(x, y, z, x, y, z, 50.0, 0)
            local curTime = GetGameTimer()
            while IsNetworkLoadingScene() do
                if GetGameTimer() - curTime > 1000 then
                    break
                end
                Wait(0)
            end
            NewLoadSceneStop()
            SetPedCoordsKeepVehicle(ped, x, y, z)

            while not HasCollisionLoadedAroundEntity(ped) do
                RequestCollisionAtCoord(x, y, z)
                if GetGameTimer() - curTime > 1000 then
                    break
                end
                Wait(0)
            end

            -- Get ground coord. As mentioned in the natives, this only works if the client is in render distance.
            found, groundZ = GetGroundZFor_3dCoord(x, y, z, false)
            if found then
                Wait(0)
                SetPedCoordsKeepVehicle(ped, x, y, groundZ)
                break
            end
            Wait(0)
        end

        -- Remove black screen once the loop has ended.
        DoScreenFadeIn(650)
        FreezeEntityPosition(vehicle > 0 and vehicle or ped, false)

        if not found then
            -- If we can't find the coords, set the coords to the old ones.
            -- We don't unpack them before since they aren't in a loop and only called once.
            SetPedCoordsKeepVehicle(ped, oldCoords["x"], oldCoords["y"], oldCoords["z"] - 1.0)
            ESX.ShowNotification(TranslateCap("tpm_success"), "success")
        end

        -- If Z coord was found, set coords in found coords.
        SetPedCoordsKeepVehicle(ped, x, y, groundZ)
        ESX.ShowNotification(TranslateCap("tpm_success"), "success")
    end)
end)

local noclip = false
local noclip_pos = vector3(0, 0, 70)
local heading = 0

local function noclipThread()
    while noclip do
        SetEntityCoordsNoOffset(ESX.PlayerData.ped, noclip_pos.x, noclip_pos.y, noclip_pos.z, false, false, true)

        if IsControlPressed(1, 34) then
            heading = heading + 1.5
            if heading > 360 then
                heading = 0
            end

            SetEntityHeading(ESX.PlayerData.ped, heading)
        end

        if IsControlPressed(1, 9) then
            heading = heading - 1.5
            if heading < 0 then
                heading = 360
            end

            SetEntityHeading(ESX.PlayerData.ped, heading)
        end

        if IsControlPressed(1, 8) then
            noclip_pos = GetOffsetFromEntityInWorldCoords(ESX.PlayerData.ped, 0.0, 1.0, 0.0)
        end

        if IsControlPressed(1, 32) then
            noclip_pos = GetOffsetFromEntityInWorldCoords(ESX.PlayerData.ped, 0.0, -1.0, 0.0)
        end

        if IsControlPressed(1, 27) then
            noclip_pos = GetOffsetFromEntityInWorldCoords(ESX.PlayerData.ped, 0.0, 0.0, 1.0)
        end

        if IsControlPressed(1, 173) then
            noclip_pos = GetOffsetFromEntityInWorldCoords(ESX.PlayerData.ped, 0.0, 0.0, -1.0)
        end
        Wait(0)
    end
end

RegisterNetEvent("esx:noclip", function()
    ESX.TriggerServerCallback("esx:isUserAdmin", function(admin)
        if not admin then
            return
        end

        if not noclip then
            noclip_pos = GetEntityCoords(ESX.PlayerData.ped, false)
            heading = GetEntityHeading(ESX.PlayerData.ped)
        end

        noclip = not noclip
        if noclip then
            CreateThread(noclipThread)
        end

        if noclip then
            ESX.ShowNotification(TranslateCap("noclip_message", Translate("enabled")), "success")
        else
            ESX.ShowNotification(TranslateCap("noclip_message", Translate("disabled")), "error")
        end
    end)
end)

RegisterNetEvent("esx:killPlayer", function()
    SetEntityHealth(ESX.PlayerData.ped, 0)
end)

RegisterNetEvent("esx:repairPedVehicle", function()
    local ped = ESX.PlayerData.ped
    local vehicle = GetVehiclePedIsIn(ped, false)
    SetVehicleEngineHealth(vehicle, 1000)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleFixed(vehicle)
    SetVehicleDirtLevel(vehicle, 0)
end)

RegisterNetEvent("esx:freezePlayer", function(input)
    if input == "freeze" then
        SetEntityCollision(ESX.PlayerData.ped, false, false)
        FreezeEntityPosition(ESX.PlayerData.ped, true)
        SetPlayerInvincible(ESX.playerId, true)
    elseif input == "unfreeze" then
        SetEntityCollision(ESX.PlayerData.ped, true, true)
        FreezeEntityPosition(ESX.PlayerData.ped, false)
        SetPlayerInvincible(ESX.playerId, false)
    end
end)

ESX.RegisterClientCallback("esx:GetVehicleType", function(cb, model)
    cb(ESX.GetVehicleTypeClient(model))
end)

ESX.SecureNetEvent('esx:updatePlayerData', function(key, val)
	ESX.SetPlayerData(key, val)
end)

---@param command string
ESX.SecureNetEvent("esx:executeCommand", function(command)
    ExecuteCommand(command)
end)

AddEventHandler("onResourceStop", function(resource)
    if Core.Events[resource] then
        for i = 1, #Core.Events[resource] do
            RemoveEventHandler(Core.Events[resource][i])
        end
    end
end)

-- FIX: Handle es_extended resource stop (server shutdown) by cleaning up client state
AddEventHandler("onResourceStop", function(resource)
    if resource == GetCurrentResourceName() then
        -- Set player loaded to false to stop all loops
        ESX.PlayerLoaded = false

        if Config.EnableDebug then
            print("[^2INFO^7] es_extended resource stopping, cleaning up client state")
        end
    end
end)

-- FIX: Handle session end (disconnect from server)
-- This catches cases where server shuts down without sending esx:onPlayerLogout
AddEventHandler("onClientResourceStop", function(resource)
    if resource == GetCurrentResourceName() then
        ESX.PlayerLoaded = false
    end
end)
