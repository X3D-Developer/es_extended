-- Boot banner + `esxstats` snapshot.
-- Prints once boot has settled (no new resource started for SETTLE_MS), so the
-- resource counts are final. Numbers here are the baseline to compare against
-- after any perf change — keep the fields stable.

local SETTLE_MS <const> = 3000
local bootAt = GetGameTimer()
local lastStart = GetGameTimer()

AddEventHandler('onServerResourceStart', function()
    lastStart = GetGameTimer()
end)

local function resourceCounts()
    local total, started = GetNumResources(), 0
    for i = 0, total - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceState(name) == 'started' then
            started = started + 1
        end
    end
    return started, total
end

local function onesyncMode()
    if GetConvar('onesync_enableInfinity', 'false') == 'true' then
        return 'Infinity'
    end
    if GetConvar('onesync', 'off') ~= 'off' then
        return 'Legacy'
    end
    return 'off'
end

local function dbPing()
    local t = GetGameTimer()
    local ok = pcall(function() return MySQL.scalar.await('SELECT 1') end)
    return ok and (GetGameTimer() - t) or -1
end

local function hhmm(ms)
    local s = math.floor(ms / 1000)
    return ('%dh %02dm'):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

local function snapshot(tag)
    local started, total = resourceCounts()
    local ping = dbPing()
    local players = #GetPlayers()
    local slots = GetConvarInt('sv_maxclients', 0)

    local lines = {
        '^5=========================================================^7',
        ('^5  [ESX]^7  %s'):format(GetConvar('sv_projectName', 'FiveM')),
        '^5---------------------------------------------------------^7',
        ('  Resources   %d started / %d total'):format(started, total),
        ('  Players     %d / %d slots'):format(players, slots),
        ('  OneSync     %s%s'):format(onesyncMode(),
            GetConvar('onesync_population', 'false') == 'true' and ' + population' or ''),
        ('  Database    %s'):format(ping >= 0 and (ping .. ' ms') or 'UNREACHABLE'),
        ('  Framework   ESX %s'):format(GetResourceMetadata('es_extended', 'version', 0) or '?'),
    }

    if tag == 'boot' then
        lines[#lines + 1] = ('  Boot        %.1f s'):format(bootAt > 0 and (GetGameTimer() / 1000) or 0)
    else
        lines[#lines + 1] = ('  Uptime      %s'):format(hhmm(GetGameTimer()))
    end

    lines[#lines + 1] = '^5---------------------------------------------------------^7'
    lines[#lines + 1] = '^3  Modified build of ESX Legacy es_extended (GPL-3.0) - see README.md^7'
    lines[#lines + 1] = '^5=========================================================^7'
    print('\n' .. table.concat(lines, '\n'))
end

CreateThread(function()
    while GetGameTimer() - lastStart < SETTLE_MS do
        Wait(1000)
    end
    snapshot('boot')
end)

RegisterCommand('esxstats', function(src)
    if src ~= 0 then
        local xPlayer = ESX and ESX.GetPlayerFromId(src)
        local group = xPlayer and xPlayer.getGroup() or 'user'
        if group ~= 'admin' and group ~= 'superadmin' and group ~= 'owner' then return end
    end
    snapshot('live')
end, false)
