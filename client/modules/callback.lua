---@diagnostic disable: duplicate-set-field

-- =============================================
-- MARK: Variables
-- =============================================

Callbacks = {}

Callbacks.requests = {}
Callbacks.storage = {}
Callbacks.id = 0
Callbacks.CALLBACK_TIMEOUT = 15000  -- 15 seconds timeout

-- =============================================
-- MARK: Internal Functions
-- =============================================


function Callbacks:Register(name, resource, cb)
    self.storage[name] = {
        resource = resource,
        cb = cb
    }
end

function Callbacks:Execute(cb, id, ...)
    local success, errorString = pcall(cb, ...)

    if not success then
        print(("[^1ERROR^7] Failed to execute Callback with RequestId: ^5%s^7"):format(id))
        print(("[^1ERROR^7] %s"):format(errorString))
    end
end

function Callbacks:Trigger(event, cb, invoker, ...)
    local requestId = self.id
    self.requests[requestId] = {
        await = type(cb) == "boolean",
        cb = cb or promise:new(),
        event = event,
        timestamp = GetGameTimer()
    }
    local callbackData = self.requests[requestId]

    TriggerServerEvent("esx:triggerServerCallback", event, requestId, invoker, ...)

    self.id = self.id + 1

    return callbackData.cb, requestId
end

-- OPTIMIZATION: Cleanup function to remove stale callbacks
function Callbacks:Cleanup(requestId, reason)
    if not self.requests[requestId] then return end

    if Config.EnableDebug then
        local request = self.requests[requestId]
        print(("[^3WARNING^7] Client callback cleanup: requestId %d (%s) - %s"):format(requestId, request.event or "unknown", reason or "unknown"))
    end

    self.requests[requestId] = nil
end

function Callbacks:ServerRecieve(requestId, invoker, ...)
    if not self.requests[requestId] then
        -- Don't error - could be a late response after timeout/cleanup
        if Config.EnableDebug then
            print(("[^3WARNING^7] Late callback response for requestId %d from %s (already cleaned up)"):format(requestId, invoker))
        end
        return
    end

    local callback = self.requests[requestId]

    self.requests[requestId] = nil

    if callback.await then
        callback.cb:resolve({ ... })
    else
        self:Execute(callback.cb, requestId, ...)
    end
end

function Callbacks:ClientRecieve(eventName, requestId, invoker, ...)
    if not self.storage[eventName] then
        return error(("Client Callback with requestId ^5%s^1 Was Called by ^5%s^1 but does not exist."):format(eventName, invoker))
    end

    local returnCb = function(...)
        TriggerServerEvent("esx:clientCallback", requestId, invoker, ...)
    end
    local callback = self.storage[eventName].cb

    self:Execute(callback, requestId, returnCb, ...)
end

-- =============================================
-- MARK: ESX Functions
-- =============================================

---@param eventName string
---@param callback function
---@param ... any
---@return nil
function ESX.TriggerServerCallback(eventName, callback, ...)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "unknown") and invokingResource or "es_extended"

    local _, requestId = Callbacks:Trigger(eventName, callback, invoker, ...)

    -- OPTIMIZATION: Add timeout cleanup for non-await callbacks (prevents memory leak)
    SetTimeout(Callbacks.CALLBACK_TIMEOUT, function()
        if Callbacks.requests[requestId] then
            Callbacks:Cleanup(requestId, "Callback timeout (TriggerServerCallback)")
        end
    end)
end

---@param eventName string
---@param ... any
---@return ...
function ESX.AwaitServerCallback(eventName, ...)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "unknown") and invokingResource or "es_extended"

    local p, requestId = Callbacks:Trigger(eventName, false, invoker, ...)
    if not p then return end

    -- OPTIMIZATION: Timeout with proper cleanup to prevent memory leak
    SetTimeout(Callbacks.CALLBACK_TIMEOUT, function()
        if p.state == "pending" then
            p:reject("Server Callback Timed Out")
            Callbacks:Cleanup(requestId, "Callback timeout (AwaitServerCallback)")
        end
    end)

    Citizen.Await(p)

    return table.unpack(p.value)
end

function ESX.RegisterClientCallback(eventName, callback)
    local invokingResource = GetInvokingResource()
    local invoker = (invokingResource and invokingResource ~= "unknown") and invokingResource or "es_extended"

    Callbacks:Register(eventName, invoker, callback)
end

---@param eventName string
---@return boolean
function ESX.DoesClientCallbackExist(eventName)
    return Callbacks.storage[eventName] ~= nil
end

-- =============================================
-- MARK: Events
-- =============================================

ESX.SecureNetEvent("esx:serverCallback", function(...)
    Callbacks:ServerRecieve(...)
end)

ESX.SecureNetEvent("esx:triggerClientCallback", function(...)
    Callbacks:ClientRecieve(...)
end)

AddEventHandler("onResourceStop", function(resource)
    for k, v in pairs(Callbacks.storage) do
        if v.resource == resource then
            Callbacks.storage[k] = nil
        end
    end
end)

-- FIX: Cleanup all pending callbacks when player logs out (prevents crash on server shutdown)
AddEventHandler("esx:onPlayerLogout", function()
    -- Reject all pending promises and clear callbacks
    for requestId, request in pairs(Callbacks.requests) do
        if request.await and request.cb and request.cb.state == "pending" then
            request.cb:reject("Player logged out")
        end
        Callbacks:Cleanup(requestId, "Player logout cleanup")
    end

    -- Reset callback ID counter
    Callbacks.id = 0

    if Config.EnableDebug then
        print("[^2INFO^7] Cleaned up all pending client callbacks on player logout")
    end
end)

-- GC: Periodic sweep for any stale callbacks that weren't cleaned up by timeout
CreateThread(function()
    local GC_INTERVAL <const> = 5 * 60 * 1000  -- Every 5 minutes
    local STALE_THRESHOLD <const> = Callbacks.CALLBACK_TIMEOUT * 2  -- 2x timeout = definitely stale

    -- Wait for player to be loaded before starting GC loop
    while not ESX.PlayerLoaded do
        Wait(1000)
    end

    -- FIX: Check ESX.PlayerLoaded to prevent crash on server shutdown
    while ESX.PlayerLoaded do
        Wait(GC_INTERVAL)

        -- Double-check after wait (player might have disconnected during wait)
        if not ESX.PlayerLoaded then break end

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
            print(("[^3GC^7] Cleaned up ^5%d^7 stale client callbacks"):format(staleCount))
        end
    end
end)
