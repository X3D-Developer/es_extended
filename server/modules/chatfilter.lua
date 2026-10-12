-- Banned-word filter shared by every text surface (public chat hook, phone
-- tweets/SMS/darkchat). SERVER-ONLY on purpose: shipping the list in a
-- shared_script would hand every player the exact evasion table (Critical Rule
-- section 22.7).
--
--   local ok, word = ESX.CheckBannedWords(text)
--   if not ok then ESX.PunishBannedWord(src, word, 'tweet', text) return end
--
-- Convars: esx_chatfilter_enabled 1 | esx_chatfilter_kick_strikes 3

local WORDS <const> = {
    -- ซื้อขายเงิน / RMT / สแกม (สำคัญกว่าคำหยาบสำหรับเซิร์ฟ RP)
    'ขายเงินเกม', 'รับซื้อเงินเกม', 'ขายไอดี', 'รับเติมเงิน', 'เติมเงินราคาถูก',
    'ขายบอท', 'ขายเมนู', 'ขายเชต', 'ขายสคริป', 'โกงเงิน',
    'sellmoney', 'buymoney', 'cheatmenu', 'moneyhack', 'sellaccount',
    -- คำหยาบรุนแรง / เหยียด
    'ควย', 'เหี้ย', 'สัตว์ตีน', 'แม่ง', 'อีดอก', 'กระหรี่',
    'nigger', 'faggot', 'retard',
}

local EXEMPT_GROUPS <const> = { admin = true, superadmin = true, mod = true }

local strikes = {}

-- Cheap evasion folding. `strip` kills spacing and punctuation ("f.u.c.k",
-- "s e l l m o n e y"); `collapse` also squashes repeats ("selllmoney").
-- collapse is byte-wise, so it is only used to build ASCII needles -- running it
-- over a Thai needle would eat UTF-8 continuation bytes and match nonsense.
-- ponytail: no leetspeak map (0->o, 3->e). Add one only if evasion shows up in
-- the chatfilter log; every substitution table is a false-positive generator.
local function strip(s)
    -- explicit ASCII ranges, NOT %s/%p: the C locale FiveM runs under classifies
    -- UTF-8 continuation bytes as punctuation, so %p shreds every Thai word
    return (s:lower():gsub('[\1-\47\58-\64\91-\96\123-\127]', ''))
end

-- Lua patterns cannot quantify a back-reference ("(.)%1+" silently matches
-- nothing), so squash runs by hand.
local function collapse(s)
    local out, prev = {}, nil
    for i = 1, #s do
        local c = s:sub(i, i)
        if c ~= prev then out[#out + 1] = c end
        prev = c
    end
    return table.concat(out)
end

local NEEDLES <const> = (function()
    local t = {}
    for i = 1, #WORDS do
        local s = strip(WORDS[i])
        local ascii = not WORDS[i]:find('[\128-\255]')
        t[i] = { strip = s, collapse = ascii and collapse(s) or nil }
    end
    return t
end)()

---@param text string
---@return boolean ok, string? word
function ESX.CheckBannedWords(text)
    if GetConvarInt('esx_chatfilter_enabled', 1) ~= 1 then return true end
    if type(text) ~= 'string' or text == '' then return true end
    local raw = text:lower()
    local stripped = strip(text)
    local collapsed = collapse(stripped)
    for i = 1, #WORDS do
        local n = NEEDLES[i]
        if raw:find(WORDS[i], 1, true)
            or (#n.strip > 3 and stripped:find(n.strip, 1, true))
            or (n.collapse and #n.collapse > 3 and collapsed:find(n.collapse, 1, true))
        then
            return false, WORDS[i]
        end
    end
    return true
end

---Log the hit, count a strike, kick past the threshold. Returns the strike count.
---@param src number
---@param word string
---@param context string  'chat' | 'tweet' | 'sms' | 'darkchat'
---@param text string?
function ESX.PunishBannedWord(src, word, context, text)
    src = tonumber(src)
    if not src then return 0 end
    local xPlayer = ESX.GetPlayerFromId(src)
    local key = xPlayer and xPlayer.identifier or ('src:' .. src)

    if xPlayer and EXEMPT_GROUPS[xPlayer.getGroup()] then return 0 end

    local n = (strikes[key] or 0) + 1
    strikes[key] = n
    local limit = GetConvarInt('esx_chatfilter_kick_strikes', 3)

    TriggerEvent('esx_serverlog:write', src, 'chatfilter', {
        word = word,
        context = context,
        strike = n,
        limit = limit,
        text = type(text) == 'string' and text:sub(1, 300) or nil,
    }, { important = true, webhook = 'chat', title = 'BANNED WORD', color = 15158332 })

    if n >= limit then
        strikes[key] = nil
        DropPlayer(src, ('ใช้คำที่ไม่อนุญาต %d ครั้ง — ถูกเตะออกจากเซิร์ฟเวอร์'):format(n))
    end
    return n
end

AddEventHandler('esx:playerDropped', function(src)
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end
    -- keep the strike count across a rage-quit-and-rejoin within the session
    if (strikes[xPlayer.identifier] or 0) <= 0 then strikes[xPlayer.identifier] = nil end
end)
