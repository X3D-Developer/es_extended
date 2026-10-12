-- Central audit log: every money/account/item/weapon mutation through the xPlayer
-- API + join/leave/chat/death/tweet -> {server_log} (queryable), with Discord
-- alerts routed to a NAMED webhook per kind. Convars (server_secrets.cfg):
--   set esx_serverlog_webhook           "https://discord.com/api/webhooks/..."   -- fallback
--   set esx_serverlog_webhook_money     "..."   -- per-kind override (money item weapon
--   set esx_serverlog_webhook_admin     "..."      join leave chat death admin screenshot)
--   set esx_serverlog_alert_money 100000
--   set esx_serverlog_alert_item  100
--   set esx_serverlog_bot_name    "ESX Logs"
--   set esx_serverlog_bot_avatar  "https://..."
--   set esx_serverlog_log_ip      1        -- 0 = never store player IPs
Core.ServerLog = {}
local SL = Core.ServerLog

MySQL.ready(function()
    MySQL.query(ESX.Q([[CREATE TABLE IF NOT EXISTS `{server_log}` (
        `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        `ts` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `identifier` VARCHAR(64) NULL,
        `name` VARCHAR(64) NULL,
        `kind` VARCHAR(32) NOT NULL,
        `resource` VARCHAR(64) NULL,
        `data` JSON NULL,
        PRIMARY KEY (`id`),
        KEY `idx_ident_ts` (`identifier`, `ts`),
        KEY `idx_kind_ts` (`kind`, `ts`),
        KEY `idx_ts` (`ts`)
    ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci]]))
end)

-- Resources the audit log ignores completely: cosmetic / world-dressing systems
-- (skins, clothing packs, map + prop resources) that never move money or items.
-- Anything that CAN move money or items stays logged -- a clothing SHOP charges the
-- player, so it belongs in the log even though a clothing PACK does not.
-- Extend without touching code: set esx_serverlog_ignore "res_a,res_b"
local IGNORE_DEFAULT <const> = table.concat({
    'skinchanger', 'esx_skin', 'x3d_skin', 'bob74_ipl',
}, ',')

local ignoreSet, ignoreRaw = {}, nil

---@param resource string?
---@return boolean
function SL.Ignored(resource)
    if type(resource) ~= 'string' then return false end
    local raw = GetConvar('esx_serverlog_ignore', IGNORE_DEFAULT)
    if raw ~= ignoreRaw then
        ignoreRaw, ignoreSet = raw, {}
        for word in raw:gmatch('[^,%s]+') do ignoreSet[word] = true end
    end
    -- `_map$`  -> map packs named like did_new_arena_*_map
    -- `^brofx` -> the brofx MLO packs
    return ignoreSet[resource] == true
        or resource:sub(-4) == '_map'
        or resource:sub(1, 5) == 'brofx'
end

function SL.Write(src, identifier, name, kind, resource, data)
    if SL.Ignored(resource) then return end
    -- ponytail: one async INSERT per event; switch to multi-row batch flush if MySQL ever becomes the bottleneck
    MySQL.insert(ESX.Q('INSERT INTO {server_log} (identifier, name, kind, resource, data) VALUES (?, ?, ?, ?, ?)'), {
        identifier, name, kind, resource, data and json.encode(data) or nil,
    })
end

-- One queue PER webhook URL: Discord's 30 req/min cap is per-webhook, so routing
-- kinds to different channels multiplies the budget instead of sharing one.
local queues = {}

function SL.WebhookFor(key)
    local url = key and GetConvar('esx_serverlog_webhook_' .. key, '') or ''
    if url == '' then url = GetConvar('esx_serverlog_webhook', '') end
    return url
end

function SL.Alert(key, title, color, fields, imageUrl)
    local url = SL.WebhookFor(key)
    if url == '' then return end
    local q = queues[url]
    if not q then
        q = { items = {}, nextAt = 0 }
        queues[url] = q
    end
    if #q.items >= 50 then return end
    q.items[#q.items + 1] = { title = title, color = color, fields = fields, image = imageUrl }
end

local function retryAfterMs(body)
    local ok, decoded = pcall(json.decode, body or '')
    if not ok or type(decoded) ~= 'table' then return 2000 end
    local ra = tonumber(decoded.retry_after)
    if not ra then return 2000 end
    -- Discord sends seconds (float) on v10, milliseconds on older webhook responses
    local ms = ra < 100 and ra * 1000 or ra
    return math.min(math.floor(ms) + 250, 60000)
end

local function flush(url, q)
    local batch = {}
    for i = 1, math.min(#q.items, 10) do batch[i] = q.items[i] end
    for _ = 1, #batch do table.remove(q.items, 1) end

    local embeds = {}
    for i = 1, #batch do
        local a = batch[i]
        embeds[i] = {
            title = a.title,
            color = a.color,
            fields = a.fields,
            image = a.image and { url = a.image } or nil,
            footer = { text = 'ESX server log | ' .. os.date('%Y-%m-%d %H:%M:%S') },
        }
    end

    local avatar = GetConvar('esx_serverlog_bot_avatar', '')
    local payload = json.encode({
        username = GetConvar('esx_serverlog_bot_name', 'ESX Logs'),
        avatar_url = avatar ~= '' and avatar or nil,
        embeds = embeds,
    })

    q.nextAt = GetGameTimer() + 2000

    PerformHttpRequest(url, function(status, body)
        if status ~= 429 then return end
        for i = #batch, 1, -1 do table.insert(q.items, 1, batch[i]) end
        q.nextAt = GetGameTimer() + retryAfterMs(body)
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    while true do
        Wait(1000)
        local now = GetGameTimer()
        for url, q in pairs(queues) do
            if #q.items > 0 and now >= q.nextAt then flush(url, q) end
        end
    end
end)

local function field(label, value)
    return { name = label, value = tostring(value), inline = true }
end

local function maybeAlert(xPlayer, kind, fn, resource, data)
    local isSet = fn:sub(1, 3) == 'set'
    local delta = tonumber(data.delta)
    local threshold = kind == 'money' and tonumber(GetConvar('esx_serverlog_alert_money', '100000'))
        or kind == 'item' and tonumber(GetConvar('esx_serverlog_alert_item', '100'))
        or nil
    local big = threshold and delta and math.abs(delta) >= threshold
    if not isSet and not big then return end
    SL.Alert(
        isSet and 'admin' or kind,
        (isSet and '⚠️ ADMIN SET %s' or '💸 BIG %s MOVE'):format(kind:upper()),
        isSet and 15105570 or 15158332,
        {
            field('Player', ('%s (%s)'):format(xPlayer.getName() or '?', xPlayer.identifier or '?')),
            field('Action', fn),
            field('What', data.account or data.item or data.weapon or '?'),
            field('Delta', delta or '-'),
            field('Before -> After', ('%s -> %s'):format(tostring(data.before), tostring(data.after))),
            field('Resource', resource),
            field('Reason', data.reason or '-'),
        }
    )
end

local function acctMoney(xPlayer, accountName)
    local acc = xPlayer.getAccount(accountName)
    return acc and acc.money or nil
end

local function itemCount(xPlayer, itemName)
    local it = xPlayer.getInventoryItem(itemName)
    return it and it.count or nil
end

local WRAP <const> = {
    { fns = { 'addAccountMoney', 'removeAccountMoney', 'setAccountMoney' }, kind = 'money', get = acctMoney },
    { fns = { 'addInventoryItem', 'removeInventoryItem', 'setInventoryItem' }, kind = 'item', get = itemCount },
    { fns = { 'addWeapon', 'removeWeapon', 'addWeaponAmmo', 'removeWeaponAmmo' }, kind = 'weapon', get = nil },
}

function SL.Wrap(xPlayer)
    for g = 1, #WRAP do
        local grp = WRAP[g]
        for f = 1, #grp.fns do
            local fname = grp.fns[f]
            local orig = xPlayer[fname]
            if orig then
                xPlayer[fname] = function(a1, a2, a3)
                    local resource = GetInvokingResource() or 'es_extended'
                    if SL.Ignored(resource) then return orig(a1, a2, a3) end
                    local before = grp.get and grp.get(xPlayer, a1) or nil
                    orig(a1, a2, a3)
                    local after = grp.get and grp.get(xPlayer, a1) or nil
                    local delta = (before and after) and (after - before) or nil
                    if grp.kind ~= 'weapon' and delta == 0 then return end
                    local data = { fn = fname, before = before, after = after, delta = delta }
                    if grp.kind == 'money' then
                        data.account, data.reason = a1, a3
                    elseif grp.kind == 'item' then
                        data.item = a1
                    else
                        data.weapon, data.ammo = a1, tonumber(a2)
                    end
                    SL.Write(xPlayer.source, xPlayer.identifier, xPlayer.getName(), grp.kind, resource, data)
                    maybeAlert(xPlayer, grp.kind, fname, resource, data)
                end
            end
        end
    end
end

-- The join row is the ONLY place identifiers are captured: one row per session
-- makes `WHERE kind='join' AND data->>'$.steam' = ?` the "who else played on this
-- Steam/IP" lookup, without bloating every other row.
function SL.Identifiers(src)
    local out = {}
    local ids = GetPlayerIdentifiers(src) or {}
    local logIp = GetConvarInt('esx_serverlog_log_ip', 1) == 1
    for i = 1, #ids do
        local k, v = ids[i]:match('^([%w_]+):(.+)$')
        if k and k ~= 'ip' then out[k] = v end
    end
    if logIp then out.ip = GetPlayerEndpoint(src) end
    return out
end

AddEventHandler('esx:playerLoaded', function(src, xPlayer)
    SL.Write(src, xPlayer.identifier, xPlayer.getName(), 'join', 'es_extended', SL.Identifiers(src))
end)

AddEventHandler('esx:playerDropped', function(src, reason)
    local xPlayer = ESX.GetPlayerFromId(src)
    SL.Write(src, xPlayer and xPlayer.identifier, xPlayer and xPlayer.getName(), 'leave', 'es_extended',
        { reason = reason })
end)

-- NOTE: there is deliberately NO `chatMessage` handler here. esx_chat_theme's
-- message hook calls hook.cancel(), and chat/sv_chat.lua returns on
-- `messageCanceled` BEFORE it ever fires `chatMessage` -- such a handler is dead
-- code. Public chat logs from the hook itself (kind `chat`); the real
-- player-to-player text (tweet/sms/darkchat) logs from your phone resource.

local lastDeath = {}

RegisterNetEvent('esx:onPlayerDeath', function(data)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end
    local now = GetGameTimer()
    if (lastDeath[src] or 0) + 2000 > now then return end
    lastDeath[src] = now
    if type(data) ~= 'table' then data = {} end
    local killer = tonumber(data.killerServerId)
    SL.Write(src, xPlayer.identifier, xPlayer.getName(), 'death', 'es_extended', {
        cause = data.deathCause,
        byPlayer = data.killedByPlayer == true,
        killerId = killer,
        killerName = killer and GetPlayerName(killer) or nil,
        distance = tonumber(data.distance),
    })
end)

-- Server-internal write channel for every other resource:
--   TriggerEvent('esx_serverlog:write', src, kind, data, opts)
-- opts.important = true -> also push a Discord embed, for events with no numeric
--                          delta for maybeAlert to threshold on (admin unbind,
--                          ban, gang deposit, banned-word hit, ...)
-- opts.webhook = 'admin'|'money'|...  (defaults to the kind)
-- opts.title / opts.color / opts.image override the embed.
AddEventHandler('esx_serverlog:write', function(src, kind, data, opts)
    if type(kind) ~= 'string' then return end
    local resource = GetInvokingResource() or 'unknown'
    if SL.Ignored(resource) then return end
    src = tonumber(src)
    local xPlayer = src and ESX.GetPlayerFromId(src) or nil
    data = type(data) == 'table' and data or nil
    SL.Write(src, xPlayer and xPlayer.identifier, xPlayer and xPlayer.getName(), kind, resource, data)

    if type(opts) ~= 'table' or not opts.important then return end
    local fields = {
        field('Player', ('%s (%s)'):format(
            (xPlayer and xPlayer.getName()) or (src and GetPlayerName(src)) or '?',
            (xPlayer and xPlayer.identifier) or '?')),
        field('Resource', resource),
    }
    if data then
        local n = 0
        for k, v in pairs(data) do
            n = n + 1
            if n > 6 then break end
            fields[#fields + 1] = field(k, type(v) == 'table' and json.encode(v) or tostring(v))
        end
    end
    SL.Alert(opts.webhook or kind, opts.title or ('[%s]'):format(kind:upper()), opts.color or 3447003, fields,
        opts.image)
end)
