Core.RestartLock = { active = false, locking = false, at = nil, kind = nil }
local RL = Core.RestartLock
local lastNotify = {}
local armToken = 0
local kickToken = 0
local GRACE_MS <const> = 3000

local function kickAt()
    return RL.at and (RL.at - Config.RestartLock.kickSeconds) or nil
end

local function publish()
    GlobalState.esx_restart = RL.at and { at = RL.at, kickAt = kickAt(), kind = RL.kind, lock = RL.locking } or false
end

function RL.KickAll()
    local reason = RL.kind == 'shutdown' and 'เซิร์ฟเวอร์ปิดชั่วคราว กรุณาเข้าใหม่ภายหลัง'
        or 'เซิร์ฟเวอร์กำลังรีสตาร์ท กรุณาเข้าใหม่ในอีกประมาณ 5 นาที'
    local players = GetPlayers()
    for i = 1, #players do
        DropPlayer(players[i], reason)
    end
    print(('[restartlock] kicked %d players before %s'):format(#players, tostring(RL.kind)))
end

local function armKick()
    kickToken = kickToken + 1
    local token = kickToken
    local at = kickAt()
    if not at then return end
    SetTimeout(math.max(0, at - os.time()) * 1000, function()
        if kickToken ~= token or not RL.at then return end
        RL.KickAll()
    end)
end

function RL.Allowed(resource)
    return not RL.active or not resource or resource == 'Unknown' or Config.RestartLock.allow[resource] == true
end

function RL.Notify(src)
    if not src or src <= 0 then return end
    local now = GetGameTimer()
    if (lastNotify[src] or 0) + 3000 > now then return end
    lastNotify[src] = now
    TriggerClientEvent('ESX:Notify', src, 'error', 4000, 'ระบบปิดชั่วคราว รอเซิร์ฟเวอร์รีสตาร์ท', 'ล็อกระบบ')
end

function RL.Schedule(kind, seconds)
    RL.kind = kind
    RL.at = os.time() + math.max(0, math.floor(tonumber(seconds) or 0))
    armKick()
    if not RL.locking and seconds <= Config.RestartLock.seconds then
        RL.Set(true)
    else
        publish()
    end
end

function RL.Clear()
    RL.at, RL.kind = nil, nil
    kickToken = kickToken + 1
    RL.Set(false)
end

function RL.Set(active)
    active = active == true
    local changed = RL.locking ~= active
    RL.locking = active
    armToken = armToken + 1
    if not active then
        RL.active = false
        publish()
        if changed then
            TriggerClientEvent('ESX:Notify', -1, 'success', 6000, 'ปลดล็อกระบบแล้ว เล่นต่อได้ตามปกติ', 'ล็อกระบบ')
        end
        return
    end
    publish()
    if not changed then return end
    TriggerClientEvent('esx:restartLock', -1)
    TriggerClientEvent('ESX:Notify', -1, 'error', 10000,
        'ล็อกระบบซื้อขาย/คราฟต์/กระเป๋าแล้ว ~r~10 นาทีสุดท้าย~s~ ก่อนรีสตาร์ท กรุณาหยุดทำกิจกรรม', 'ล็อกระบบ')
    local token = armToken
    SetTimeout(GRACE_MS, function()
        if armToken ~= token or not RL.locking then return end
        RL.active = true
        Core.SavePlayers()
    end)
end

local GUARDED <const> = {
    'addMoney', 'removeMoney', 'setMoney',
    'addAccountMoney', 'removeAccountMoney', 'setAccountMoney',
    'addInventoryItem', 'removeInventoryItem', 'setInventoryItem',
    'addWeapon', 'removeWeapon', 'addWeaponAmmo', 'removeWeaponAmmo',
    'setMeta', 'clearMeta', 'setJob',
}

function RL.Wrap(xPlayer)
    for i = 1, #GUARDED do
        local name = GUARDED[i]
        local orig = xPlayer[name]
        if orig then
            xPlayer[name] = function(...)
                if RL.active then
                    local res = GetInvokingResource()
                    if not RL.Allowed(res) then
                        RL.Notify(xPlayer.source)
                        error(('[restartlock] %s.%s blocked during restart lock'):format(tostring(res), name), 2)
                    end
                end
                return orig(...)
            end
        end
    end
end

AddEventHandler('txAdmin:events:scheduledRestart', function(data)
    local secs = tonumber(data and data.secondsRemaining) or 0
    RL.Schedule('restart', secs)
    -- 15 s before the restart: last call for anything that must be flushed to the DB
    -- (a garage storing every spawned vehicle, a job saving its state, ...)
    if secs == 60 then
        SetTimeout(45000, function()
            TriggerEvent('esx:restartLockFinalFlush')
        end)
    end
end)

AddEventHandler('playerConnecting', function(_, _, deferrals)
    if not RL.locking or not RL.at then return end
    local minutes = math.max(1, math.ceil((RL.at - os.time()) / 60))
    deferrals.defer()
    Wait(0)
    deferrals.done(('เซิร์ฟเวอร์กำลังจะรีสตาร์ทในอีก %d นาที กรุณาเข้าใหม่หลังรีสตาร์ทเสร็จ'):format(minutes))
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function(data)
    RL.Schedule('shutdown', tonumber(data and data.delay) or 0)
end)

AddEventHandler('txAdmin:events:scheduledRestartSkipped', function()
    RL.Clear()
end)

RegisterCommand('restartlock', function(src, args)
    local a = args[1]
    if a == 'on' then
        local secs = tonumber(args[2])
        if secs or not RL.at then RL.kind, RL.at = 'restart', os.time() + (secs or Config.RestartLock.seconds) end
        armKick()
        RL.Set(true)
    elseif a == 'off' then
        RL.Clear()
    else
        print(('[restartlock] locking=%s active=%s kind=%s at=%s  usage: restartlock on [seconds]|off'):format(tostring(RL.locking), tostring(RL.active), tostring(RL.kind), tostring(RL.at)))
    end
end, true)
