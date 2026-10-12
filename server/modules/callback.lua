---@diagnostic disable: duplicate-set-field

-- =============================================
-- MARK: Variables
-- =============================================

Callbacks = {}

Callbacks.requests = {}
Callbacks.storage = {}
Callbacks.id = 0
Callbacks.playerRequests = {}  -- OPTIMIZATION: Track player -> requestIds for cleanup on disconnect
Callbacks.CALLBACK_TIMEOUT = 15000  -- 15 seconds timeout for all callbacks
Callbacks.rateLimit = {}
Callbacks.RATE_CAPACITY = 60
Callbacks.RATE_REFILL = 30
Callbacks.WARN_INTERVAL = 5000

-- =============================================
-- MARK: Internal Functions
-- =============================================

function Callbacks:Register(name, resource, cb)
    self.storage[name] = {
        resource = resource,
        cb = cb
    }
end

function Callbacks:Execute(cb, ...)
    local success, errorString = pcall(cb, ...)

    if not success then
        print(("[^1ERROR^7] Failed to execute Callback with RequestId: ^5%s^7"):format(self.currentId))
        print("^3Callback Error:^7 " .. tostring(errorString))  -- just log, don't throw
        self.currentId = nil
        return
    end

    self.currentId = nil
end

function Callbacks:Trigger(player, event, cb, invoker, ...)
    local requestId = self.id
    self.requests[requestId] = {
        await = type(cb) == "boolean",
        cb = cb or promise:new(),
        player = player,
        event = event,
        timestamp = GetGameTimer()
    }
    local callbackData = self.requests[requestId]

    -- OPTIMIZATION: Track which requests belong to which player for cleanup on disconnect
    if not self.playerRequests[player] then
        self.playerRequests[player] = {}
    end
    self.playerRequests[player][requestId] = true

    TriggerClientEvent("esx:triggerClientCallback", player, event, requestId, invoker, ...)

    self.id = self.id + 1

    return callbackData.cb
end

-- OPTIMIZATION: Cleanup function to remove stale/orphaned callbacks
function Callbacks:Cleanup(requestId, reason)
    local request = self.requests[requestId]
    if not request then return end

    -- Remove from player tracking
    if request.player and self.playerRequests[request.player] then
        self.playerRequests[request.player][requestId] = nil
        -- Clean up empty player table
        if not next(self.playerRequests[request.player]) then
            self.playerRequests[request.player] = nil
        end
    end

    -- Remove the request
    self.requests[requestId] = nil

    if Config.EnableDebug then
        print(("[^3WARNING^7] Callback cleanup: requestId %d (%s) - %s"):format(requestId, request.event or "unknown", reason or "unknown"))
    end
end

-- OPTIMIZATION: Cleanup all callbacks for a specific player (called on disconnect)
function Callbacks:CleanupPlayer(player)
    local playerReqs = self.playerRequests[player]
    if not playerReqs then return end

    local count = 0
    for requestId, _ in pairs(playerReqs) do
        local request = self.requests[requestId]
        if request then
            -- Reject promise if it's awaiting
            if request.await and request.cb and request.cb.state == "pending" then
                request.cb:reject("Player disconnected")
            end
            self.requests[requestId] = nil
            count = count + 1
        end
    end

    self.playerRequests[player] = nil

    if count > 0 and Config.EnableDebug then
        print(("[^3WARNING^7] Cleaned up %d orphaned callbacks for player %d"):format(count, player))
    end
end

function Callbacks:TakeToken(player)
    local now = GetGameTimer()
    local bucket = self.rateLimit[player]

    if not bucket then
        bucket = { tokens = self.RATE_CAPACITY, last = now, warned = 0 }
        self.rateLimit[player] = bucket
    end

    local elapsed = now - bucket.last

    if elapsed > 0 then
        bucket.tokens = math.min(self.RATE_CAPACITY, bucket.tokens + (elapsed / 1000) * self.RATE_REFILL)
        bucket.last = now
    end

    if bucket.tokens < 1 then
        return false
    end

    bucket.tokens = bucket.tokens - 1

    return true
end

function Callbacks:Warn(player, message)
    local bucket = self.rateLimit[player]
    local now = GetGameTimer()

    if bucket then
        if (now - (bucket.warned or 0)) < self.WARN_INTERVAL then
            return
        end

        bucket.warned = now
    end

    print(message)
end

function Callbacks:ServerRecieve(player, event, requestId, invoker, ...)
    if not self:TakeToken(player) then
        if Config.EnableDebug then
            self:Warn(player, ("[^3WARNING^7] Server callback rate limit hit by player ^5%s^7"):format(player))
        end

        return
    end

    self.currentId = requestId

    if not self.storage[event] then
        local name = tostring(event):sub(1, 40):gsub("[^%w%._%-:]", "?")

        self:Warn(player, ("[^3WARNING^7] Unknown server callback ^5%s^7 requested by player ^5%s^7"):format(name, player))

        return
    end

    if Core.RestartLock.active and not Core.RestartLock.Allowed(self.storage[event].resource) then
        Core.RestartLock.Notify(player)
        return
    end

    local returnCb = function(...)
        TriggerClientEvent("esx:serverCallback", player, requestId, invoker, ...)
    end
    local callback = self.storage[event].cb

    self:Execute(callback, player, returnCb, ...)
end

function Callbacks:RecieveClient(src, requestId, invoker, ...)
    self.currentId = requestId

    if not self.requests[self.currentId] then
        -- Don't error - could be a late response after timeout/cleanup
        if Config.EnableDebug then
            print(("[^3WARNING^7] Late callback response for requestId %d from %s (already cleaned up)"):format(requestId, invoker))
        end
        return
    end

    local callback = self.requests[self.currentId]

    if tonumber(callback.player) ~= src then
        return
    end

    -- OPTIMIZATION: Use Cleanup to properly remove from all tracking tables
    local player = callback.player
    if player and self.playerRequests[player] then
        self.playerRequests[player][requestId] = nil
        if not next(self.playerRequests[player]) then
            self.playerRequests[player] = nil
        end
    end
    self.requests[requestId] = nil

    if callback.await then
        callback.cb:resolve({ ... })
    else
        self:Execute(callback.cb, ...)
    end
end

-- =============================================
-- MARK: ESX Functions
-- =============================================

---@param player number playerId
---@param eventName string
---@param callback function
---@param ... any
function ESX.TriggerClientCallback(player, eventName, callback, ...)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "Unknown") and invokingResource or "es_extended"

    -- OPTIMIZATION: Capture requestId for timeout cleanup
    local requestId = Callbacks.id
    Callbacks:Trigger(player, eventName, callback, invoker, ...)

    -- OPTIMIZATION: Add timeout for non-await callbacks too (prevents memory leak)
    SetTimeout(Callbacks.CALLBACK_TIMEOUT, function()
        if Callbacks.requests[requestId] then
            Callbacks:Cleanup(requestId, "Callback timeout (TriggerClientCallback)")
        end
    end)
end

---@param player number playerId
---@param eventName string
---@param ... any
---@return ...
function ESX.AwaitClientCallback(player, eventName, ...)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "Unknown") and invokingResource or "es_extended"

    -- OPTIMIZATION: Capture requestId for timeout cleanup
    local requestId = Callbacks.id
    local p = Callbacks:Trigger(player, eventName, false, invoker, ...)
    if not p then return end

    SetTimeout(Callbacks.CALLBACK_TIMEOUT, function()
        if p.state == "pending" then
            p:reject("Server Callback Timed Out")
            -- OPTIMIZATION: Also cleanup the request entry to prevent memory leak
            Callbacks:Cleanup(requestId, "Callback timeout (AwaitClientCallback)")
        end
    end)

    Citizen.Await(p)

    return table.unpack(p.value)
end

---@param eventName string
---@param callback function
---@return nil
function ESX.RegisterServerCallback(eventName, callback)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "Unknown") and invokingResource or "es_extended"

    Callbacks:Register(eventName, invoker, callback)
end

---@param eventName string
---@return boolean
function ESX.DoesServerCallbackExist(eventName)
    return Callbacks.storage[eventName] ~= nil
end

-- =============================================
-- MARK: Events
-- =============================================

RegisterNetEvent("esx:clientCallback", function(requestId, invoker, ...)
    local src = source
    Callbacks:RecieveClient(src, requestId, invoker, ...)
end)

RegisterNetEvent("esx:triggerServerCallback", function(eventName, requestId, invoker, ...)
    local source = source
    Callbacks:ServerRecieve(source, eventName, requestId, invoker, ...)
end)

AddEventHandler("onResourceStop", function(resource)
    for k, v in pairs(Callbacks.storage) do
        if v.resource == resource then
            Callbacks.storage[k] = nil
        end
    end
end)

-- OPTIMIZATION: Cleanup callbacks when player drops to prevent memory leak
AddEventHandler("playerDropped", function()
    local playerId = source
    Callbacks.rateLimit[playerId] = nil
    Callbacks:CleanupPlayer(playerId)
end)

-- GC: Periodic sweep for any stale callbacks that weren't cleaned up by timeout
CreateThread(function()
    local GC_INTERVAL <const> = 5 * 60 * 1000  -- Every 5 minutes
    local STALE_THRESHOLD <const> = Callbacks.CALLBACK_TIMEOUT * 2  -- 2x timeout = definitely stale

    while true do
        Wait(GC_INTERVAL)

        local currentTime = GetGameTimer()
        local staleCount = 0

        for requestId, request in pairs(Callbacks.requests) do
            if request.timestamp and (currentTime - request.timestamp) > STALE_THRESHOLD then
                -- Reject promise if awaiting
                if request.await and request.cb and request.cb.state == "pending" then
                    request.cb:reject("Callback GC sweep - stale request")
                end
                Callbacks:Cleanup(requestId, "GC sweep - stale callback")
                staleCount = staleCount + 1
            end
        end

        -- Reset ID counter if no pending requests (prevents overflow on very long-running servers)
        if not next(Callbacks.requests) then
            Callbacks.id = 0
        end

        if staleCount > 0 and Config.EnableDebug then
            print(("[^3GC^7] Cleaned up ^5%d^7 stale server callbacks"):format(staleCount))
        end
    end
end)
