ESX.Players = {}
ESX.Jobs = {}
ESX.Items = {}
Core = {}
Core.JobsPlayerCount = {}
Core.UsableItemsCallbacks = {}
Core.RegisteredCommands = {}
Core.Pickups = {}
Core.PickupId = 0
Core.PICKUP_EXPIRE_TIME = 30 * 60 * 1000  -- 30 minutes in milliseconds
Core.PlayerFunctionOverrides = {}
Core.DatabaseConnected = false
Core.playersByIdentifier = {}
Core.JobsLoaded = false

---@type table<string, CVehicleData>
Core.vehicles = {}
Core.vehicleTypesByModel = {}

RegisterNetEvent("esx:onPlayerSpawn", function()
    local xPlayer = ESX.Players[source]

    if not xPlayer then
        return
    end

    xPlayer.spawned = true
end)

if Config.CustomInventory then
    SetConvarReplicated("inventory:framework", "esx")
    SetConvarReplicated("inventory:weight", tostring(Config.MaxWeight * 1000))
end

local function StartDBSync()
    CreateThread(function()
        local interval <const> = Config.SaveInterval or (10 * 60 * 1000)
        while true do
            Wait(interval)
            Core.SavePlayers()
        end
    end)
end

-- GC: Cleanup expired pickups to prevent memory leaks
local function StartPickupCleanup()
    if Config.CustomInventory then return end

    CreateThread(function()
        local cleanupInterval <const> = 5 * 60 * 1000  -- Check every 5 minutes
        while true do
            Wait(cleanupInterval)

            local currentTime = GetGameTimer()
            local expiredCount = 0

            for pickupId, pickup in pairs(Core.Pickups) do
                -- Check if pickup has expired (createdAt may be nil for old pickups)
                if pickup.createdAt and (currentTime - pickup.createdAt) > Core.PICKUP_EXPIRE_TIME then
                    Core.Pickups[pickupId] = nil
                    TriggerClientEvent("esx:removePickup", -1, pickupId)
                    expiredCount = expiredCount + 1
                end
            end

            if expiredCount > 0 and Config.EnableDebug then
                print(("[^3GC^7] Cleaned up ^5%d^7 expired pickups"):format(expiredCount))
            end
        end
    end)
end

MySQL.ready(function()
    Core.DatabaseConnected = true

    if not Config.CustomInventory then
        -- Boot race guard: on a cold start the MySQL container can still be running
        -- its init/seed scripts when oxmysql first connects, so the very first
        -- SELECT * FROM {items} can come back empty. RefreshItems() used to run
        -- exactly once here, so an empty first read left ESX.Items empty for the
        -- whole session and forced a manual `refreshitems`. Retry until the catalog
        -- actually loads. Runs in its own thread so it never blocks boot.
        CreateThread(function()
            local n = ESX.RefreshItems()
            local tries = 0
            while (not n or n == 0) and tries < 60 do
                Wait(2000)
                n = ESX.RefreshItems()
                tries = tries + 1
            end
            if n and n > 0 then
                print(("[^2INFO^7] ESX.Items catalog loaded: ^5%d^7 items"):format(n))
            else
                print(ESX.Q("[^1ERROR^7] ESX.Items still empty after retries — check {items} / DB connection"))
            end
        end)
    end

    ESX.RefreshJobs()

    print(("[^2INFO^7] ESX ^5Legacy %s^0 initialized!"):format(GetResourceMetadata(GetCurrentResourceName(), "version", 0)))

    StartDBSync()
    StartPickupCleanup()  -- GC: Start pickup expiration cleanup
    if Config.EnablePaycheck then
        StartPayCheck()
    end
end)

RegisterNetEvent("esx:clientLog", function(msg)
    if Config.EnableDebug then
        print(("[^2TRACE^7] %s^7"):format(msg))
    end
end)

GlobalState.playerCount = 0
