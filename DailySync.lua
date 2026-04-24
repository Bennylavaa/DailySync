-- DailySync.lua
-- Detects today's daily quests and shares them with other players who have this
-- addon installed, using the same "REPUTABLE" addon message prefix.
--
-- Compatible with RepRehabTBCC: when both addons are loaded, DailySync also writes
-- data into Reputable_Data so RepRehabTBCC's UI stays up to date.
--
-- Slash commands:  /dailysync  or  /dsync
--   (no args)  - print current known dailies
--   reset      - clear stored daily data
--   offset N   - set daily-change offset in hours (0 for US, 7 for AEST/Oceanic)
--   debug      - toggle debug output

local addonName, addon = ...

-- Compat shim: GetAddOnMetadata moved to C_AddOns in some client builds
if not GetAddOnMetadata and C_AddOns and C_AddOns.GetAddOnMetadata then
    GetAddOnMetadata = C_AddOns.GetAddOnMetadata
end

local version = GetAddOnMetadata(addonName, "Version") or "2.0-tbca"
addon.version = version
local msgVersion = "2.0-tbc-anniversary"  -- RepRehabTBCC-compatible format (NUMBER > 1.20 required)

local DS = CreateFrame("Frame")
addon.DS = DS   -- expose to gui.lua
DS.server     = GetRealmName()
DS.playerName = UnitName("player")
-- profileKey matches RepRehabTBCC's format used in some sender checks
DS.profileKey = format("%s-%s", DS.playerName, DS.server)
DS.prefixRegistered = false
DS.lastYell   = 0
DS.debug      = false

local PREFIX        = "REPUTABLE"   -- same as RepRehabTBCC for cross-addon compatibility
local YELL_COOLDOWN = 300           -- seconds between yell broadcasts (5 min)

-- ─────────────────────────────────────────────────────────────────────────────
-- Daily quest IDs
-- ─────────────────────────────────────────────────────────────────────────────
local dailyInfo = {
    -- Normal dungeon dailies
    [11500] = { normal  = true },   -- Magisters' Terrace
    [11383] = { normal  = true },   -- Black Morass
    [11376] = { normal  = true },   -- Shadow Labyrinth
    [11364] = { normal  = true },   -- Shattered Halls
    [11387] = { normal  = true },   -- The Mechanar
    [11371] = { normal  = true },   -- The Steamvault
    [11385] = { normal  = true },   -- The Botanica
    [11389] = { normal  = true },   -- The Arcatraz
    -- Heroic dungeon dailies
    [11499] = { heroic  = true },   -- Magisters' Terrace H
    [11388] = { heroic  = true },   -- The Arcatraz H
    [11386] = { heroic  = true },   -- Mechanar H
    [11384] = { heroic  = true },   -- Botanica H
    [11354] = { heroic  = true },   -- Ramparts H
    [11362] = { heroic  = true },   -- Blood Furnace H
    [11363] = { heroic  = true },   -- Shattered Halls H
    [11370] = { heroic  = true },   -- The Steamvault H
    [11368] = { heroic  = true },   -- Slave Pens H
    [11369] = { heroic  = true },   -- The Underbog H
    [11378] = { heroic  = true },   -- Old Hillsbrad H
    [11382] = { heroic  = true },   -- Black Morass H
    [11372] = { heroic  = true },   -- Sethekk Halls H
    [11374] = { heroic  = true },   -- Auchenai Crypts H
    [11373] = { heroic  = true },   -- Mana-Tombs H
    [11375] = { heroic  = true },   -- Shadow Labyrinth  H
    -- Cooking dailies
    [11380] = { cooking = true },
    [11377] = { cooking = true },
    [11381] = { cooking = true },
    [11379] = { cooking = true },
    -- Fishing dailies
    [11665] = { fishing = true },
    [11669] = { fishing = true },
    [11668] = { fishing = true },
    [11666] = { fishing = true },
    [11667] = { fishing = true },
    -- PvP dailies (Alliance and Horde versions paired)
    [11335] = { pvp     = true },   -- AB (Alliance)
    [11339] = { pvp     = true },   -- AB (Horde)
    [11336] = { pvp     = true },   -- AV (Alliance)
    [11340] = { pvp     = true },   -- AV (Horde)
    [11337] = { pvp     = true },   -- EotS (Alliance)
    [11341] = { pvp     = true },   -- EotS (Horde)
    [11338] = { pvp     = true },   -- WSG (Alliance)
    [11342] = { pvp     = true },   -- WSG (Horde)
}

-- Maps quest type flags to saved-variable field names
local questTypeFields = {
    normal  = { name = "dailyNormalDungeon",  resetKey = "dailyNormalDungeonReset"  },
    heroic  = { name = "dailyHeroicDungeon",  resetKey = "dailyHeroicDungeonReset"  },
    cooking = { name = "dailyCookingQuest",   resetKey = "dailyCookingQuestReset"   },
    fishing = { name = "dailyFishingQuest",   resetKey = "dailyFishingQuestReset"   },
    pvp     = { name = "dailyPvPQuest",       resetKey = "dailyPvPQuestReset"       },
}

-- Ordered list used when building / parsing the 10-field addon message payload
local fieldOrder = {
    questTypeFields.normal,
    questTypeFields.heroic,
    questTypeFields.cooking,
    questTypeFields.fishing,
    questTypeFields.pvp,
}

-- Expose shared state for gui.lua (loaded after this file)
addon.questTypeFields = questTypeFields
addon.fieldOrder      = fieldOrder

-- Per-channel dedup state
local channels = {
    GUILD  = { lastMsg = "", lastMsgTime = 0 },
    PARTY  = { lastMsg = "", lastMsgTime = 0 },
    YELL   = { lastMsg = "", lastMsgTime = 0 },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function dbg(...)
    if DS.debug then
        print("|cFF80FFFFDailySync|r [debug]", ...)
    end
end

local function getData()
    return DailySync_Data[DS.server]
end
addon.getData = getData

-- Seconds until the next daily rotation (accounts for per-realm offset)
local function getNextChange()
    local d = getData()
    local offset = d.dailyChangeOffset or 0
    local t = GetQuestResetTime() + 3600 * offset
    if t > 86400 then t = t - 86400 end
    return t
end

-- Clear stored quests if the daily rotation has passed
local function checkReset()
    local d = getData()
    if time() >= (d.dailyChangeTime or 0) then
        dbg("Daily rotation passed – clearing stored quests")
        for _, f in ipairs(fieldOrder) do
            d[f.name]     = nil
            d[f.resetKey] = nil
        end
        -- Schedule next clear at the next rotation
        local nextChange = getNextChange()
        d.dailyChangeTime = time() + nextChange
    end
end

-- True if any daily field is still unknown
local function hasMissingData()
    local d = getData()
    for _, f in ipairs(fieldOrder) do
        if not d[f.name] then return true end
    end
    return false
end

-- Return which quest type this questID belongs to, or nil
local function getQuestType(questID)
    local info = dailyInfo[questID]
    if not info then return nil end
    for qtype in pairs(questTypeFields) do
        if info[qtype] then return qtype end
    end
    return nil
end

-- Build the 12-part colon-delimited message payload
local function buildMessage()
    local d = getData()
    local parts = { "send", msgVersion }
    for _, f in ipairs(fieldOrder) do
        parts[#parts + 1] = d[f.name]     or ""
        parts[#parts + 1] = d[f.resetKey] or ""
    end
    return table.concat(parts, ":")
end
addon.buildMessage = buildMessage

function addon.sendToCustomChannel()
    local num = GetChannelName("DailySync")
    if num and num > 0 then
        ChatThrottleLib:SendChatMessage("BULK", "DailySync", buildMessage(), "CHANNEL", nil, num)
    end
end

-- True if the sender string looks like our own character
local function isSelf(sender)
    if not sender or sender == "" then return false end
    if sender == DS.playerName then return true end
    if sender == DS.profileKey  then return true end
    -- Some client builds send "Name-Realm" even for same-realm; handle both
    -- realm name may differ in spacing/casing so just compare the name part
    local namePart = sender:match("^([^%-]+)")
    return namePart == DS.playerName
end

-- Returns the actual WoW distribution type (and optional channel number) to send on, or nil if not available
local function resolveChannel(ch)
    if UnitInBattleground("player") then return nil end
    if ch == "GUILD" then
        return GetGuildInfo("player") and "GUILD" or nil
    end
    if ch == "PARTY" then
        if not IsInGroup() or GetNumGroupMembers() <= 1 then return nil end
        return IsInRaid() and "RAID" or "PARTY"
    end
    if ch == "YELL" then
        return "YELL"
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Writing received / detected data back into RepRehabTBCC if it is loaded
-- ─────────────────────────────────────────────────────────────────────────────

local function syncToRepRehabTBCC(fieldName, resetKey, questID, timeLeft)
    if not (Reputable_Data
        and Reputable_Data.global
        and Reputable_Data.global.dailyDungeons
        and Reputable_Data.global.dailyDungeons[DS.server]) then
        return
    end
    local rd = Reputable_Data.global.dailyDungeons[DS.server]
    rd[fieldName] = questID
    rd[resetKey]  = timeLeft
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Broadcast
-- ─────────────────────────────────────────────────────────────────────────────
-- all          – true  → send on every available channel
-- only         – "PARTY"/"GUILD"/"YELL" → send on this channel only
-- ignore       – "PARTY"/"GUILD"/"YELL" → send on all channels EXCEPT this one
-- forceRequest – true  → send even when we already have all data
--                        (used when asking others for data we're missing,
--                         or when deliberately spreading our data)
--
-- A channel is selected when:  all  OR  only==ch  OR  (ignore!=nil AND ignore!=ch)

function DS:broadcast(all, only, ignore, forceRequest)
    if not DS.prefixRegistered then return end
    checkReset()

    local nextChange = getNextChange()
    if nextChange < 10 or nextChange > 86390 then return end

    -- Nothing to do unless we have data to share, something is missing, or
    -- we're being asked to respond / re-broadcast
    if not (forceRequest or ignore or hasMissingData()) then return end

    -- Normalise RAID→PARTY (RAID is the actual send channel but we key on PARTY)
    if only   == "RAID" then only   = "PARTY" end
    if ignore == "RAID" then ignore = "PARTY" end

    local message = buildMessage()

    for ch, state in pairs(channels) do
        local shouldSend = all
            or (only   ~= nil and only   == ch)
            or (ignore ~= nil and ignore ~= ch)

        if shouldSend then
            -- Deduplicate: skip if we sent the identical data very recently
            if message ~= state.lastMsg or time() > state.lastMsgTime + 10 then
                local wowCh, wowChNum = resolveChannel(ch)
                if wowCh then
                    local delay = (math.random(500) + 100) / 100
                    state.lastMsg     = message
                    state.lastMsgTime = time() + delay
                    if state.waitTimer then state.waitTimer:Cancel() end
                    state.waitTimer = C_Timer.NewTimer(delay, function()
                        local dist, distNum = resolveChannel(ch)
                        dist    = dist    or wowCh
                        distNum = distNum or wowChNum
                        dbg("->", ch, message)
                        C_ChatInfo.SendAddonMessage(PREFIX, message, dist, distNum)
                    end)
                end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Store a detected or received quest locally (and into RepRehabTBCC if loaded)
-- ─────────────────────────────────────────────────────────────────────────────

local function storeQuest(questType, questID, timeLeft)
    local f = questTypeFields[questType]
    if not f then return end
    local d = getData()
    d[f.name]     = questID
    d[f.resetKey] = timeLeft
    syncToRepRehabTBCC(f.name, f.resetKey, questID, timeLeft)
    dbg("stored", questType, questID, "timeLeft", timeLeft)
    if addon.guiUpdate then addon.guiUpdate() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Receive and parse an incoming REPUTABLE addon message
-- ─────────────────────────────────────────────────────────────────────────────

function DS:receiveMessage(message, channel)
    if not DS.prefixRegistered then return end
    checkReset()

    local nextChange = getNextChange()
    if nextChange < 10 or nextChange > 86390 then return end

    -- Normalise RAID→PARTY for our channel-state table
    if channel == "RAID" then channel = "PARTY" end

    -- Cancel any pending re-broadcast for this channel (the sender beat us to it)
    local state = channels[channel]
    if state and state.waitTimer then
        state.waitTimer:Cancel()
        state.waitTimer = nil
    end

    -- Parse:  action : version : dND : dNDR : dHD : dHDR : dCQ : dCQR : dFQ : dFQR : dPvP : dPvPR
    local action, sentVersion,
          dND, dNDR, dHD, dHDR, dCQ, dCQR, dFQ, dFQR, dPvP, dPvPR =
        strsplit(":", message)

    if action ~= "send" then return end

    local d = getData()
    local offset = d.dailyChangeOffset or 0

    local rawValues = { dND, dNDR, dHD, dHDR, dCQ, dCQR, dFQ, dFQR, dPvP, dPvPR }
    -- pair up: rawValues[2i-1] = questID, rawValues[2i] = timeLeft  for fieldOrder[i]

    local broadcastIgnore = nil   -- we got new data from this channel; relay to others
    local respondTo       = nil   -- they're missing data we have; reply to this channel
    local responseNeeded  = false

    for i, f in ipairs(fieldOrder) do
        local questID  = tonumber(rawValues[2 * i - 1])
        local timeLeft = tonumber(rawValues[2 * i])

        if questID then
            -- Check the data is valid for today's rotation
            local questExpires = timeLeft + 3600 * offset
            if questExpires < 86400 and questExpires >= nextChange then
                -- Accept if we don't have it yet, or this copy has a smaller
                -- (fresher) timeLeft value meaning it was recorded more recently
                local isNew = d[f.name] == nil
                if isNew or (d[f.resetKey] and d[f.resetKey] > timeLeft) then
                    storeQuest(
                        -- reverse-look up the type key from the field entry
                        (function()
                            for t, tf in pairs(questTypeFields) do
                                if tf == f then return t end
                            end
                        end)(),
                        questID, timeLeft
                    )
                    if isNew then broadcastIgnore = channel end
                end
            end
        elseif d[f.name] then
            -- Sender is missing this; we'll reply with our copy
            respondTo    = channel
            responseNeeded = true
        end
    end

    if respondTo or broadcastIgnore then
        DS:broadcast(false, respondTo, broadcastIgnore, responseNeeded)
    end
    if broadcastIgnore and addon.guiUpdate then addon.guiUpdate() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Quest name lookup
-- ─────────────────────────────────────────────────────────────────────────────
-- Fallback names for all daily quest IDs.
-- GetQuestLink / C_QuestLog.GetTitleForQuestID only work when the quest is
-- currently in the player's quest log or has been recently viewed, so we keep
-- a local table to guarantee a readable name in all cases.

local questFallbackNames = {
    -- Normal dungeon dailies (dungeon name)
    [11500] = "Magisters' Terrace",
    [11383] = "Black Morass",
    [11376] = "Shadow Labyrinth",
    [11364] = "Shattered Halls",
    [11387] = "The Mechanar",
    [11371] = "The Steamvault",
    [11385] = "The Botanica",
    [11389] = "The Arcatraz",
    -- Heroic dungeon dailies
    [11499] = "Magisters' Terrace",
    [11388] = "The Arcatraz",
    [11386] = "The Mechanar",
    [11384] = "The Botanica",
    [11354] = "Hellfire Ramparts",
    [11362] = "Blood Furnace",
    [11363] = "Shattered Halls",
    [11370] = "The Steamvault",
    [11368] = "The Slave Pens",
    [11369] = "The Underbog",
    [11378] = "Old Hillsbrad Foothills",
    [11382] = "Black Morass",
    [11372] = "Sethekk Halls",
    [11374] = "Auchenai Crypts",
    [11373] = "Mana-Tombs",
    [11375] = "Shadow Labyrinth",
    -- Cooking dailies
    [11377] = "Revenge is Tasty",
    [11379] = "Super Hot Stew",
    [11380] = "Manalicious",
    [11381] = "Soup for the Soul",
    -- Fishing dailies
    [11665] = "Crocolisks in the City",
    [11666] = "Bait Bandits",
    [11667] = "The One That Got Away",
    [11668] = "Shrimpin' Ain't Easy",
    [11669] = "Felblood Fillet",
    -- PvP tower dailies (faction-paired)
    [10106] = "Hellfire Fortifications",
    [10110] = "Hellfire Fortifications",
    [11505] = "Spirits of Auchindoun",
    [11506] = "Spirits of Auchindoun",
    -- Ogri'la dailies
    [11080] = "The Relic's Emanation",
    [11051] = "Banish More Demons",
    -- Sha'tari Skyguard dailies
    [11008] = "Fires Over Skettis",
    [11085] = "Escape from Skettis",
    [11066] = "Wrangle More Aether Rays!",
    [11023] = "Bomb Them Again!",
    -- PvP dailies (both faction versions share a name)
    [11335] = "Call to Arms: Arathi Basin",
    [11339] = "Call to Arms: Arathi Basin",
    [11336] = "Call to Arms: Alterac Valley",
    [11340] = "Call to Arms: Alterac Valley",
    [11337] = "Call to Arms: Eye of the Storm",
    [11341] = "Call to Arms: Eye of the Storm",
    [11338] = "Call to Arms: Warsong Gulch",
    [11342] = "Call to Arms: Warsong Gulch",
}

-- Returns the best available display name for a questID.
-- Priority: quest log title → quest link parse → hardcoded fallback → "Quest #N"
local function getQuestName(questID)
    -- 1. Try the quest log title API (works when quest is in the log)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local title = C_QuestLog.GetTitleForQuestID(questID)
        if title and title ~= "" then return title end
    end
    -- 2. Try GetQuestLink and parse the name out of the hyperlink
    if GetQuestLink then
        local link = GetQuestLink(questID)
        if link then
            local name = link:match("|h%[(.-)%]")
            if name and name ~= "" then return name end
        end
    end
    -- 3. Actual quest title from our fixed data (heroic/normal quests have the
    --    dungeon name in questFallbackNames, not the real quest title)
    if addon.fixedQuestData and addon.fixedQuestData[questID] then
        return addon.fixedQuestData[questID].title
    end
    -- 4. Dungeon/zone name fallback (last resort)
    return questFallbackNames[questID] or ("Quest #" .. questID)
end
addon.getQuestName        = getQuestName
addon.questFallbackNames  = questFallbackNames  -- raw dungeon/quest names (no API lookup)

-- ─────────────────────────────────────────────────────────────────────────────
-- Fixed daily quest data  (used by gui.lua to build rich tooltips)
-- Fields: title, level, rep = {{factionID,amount},...}, prevQuest, desc
-- ─────────────────────────────────────────────────────────────────────────────

addon.factionNames = {
    [933]  = "The Consortium",
    [935]  = "The Sha'tar",
    [942]  = "Cenarion Expedition",
    [946]  = "Honor Hold",
    [947]  = "Thrallmar",
    [989]  = "Keepers of Time",
    [1011] = "Lower City",
    [1031] = "Sha'tari Skyguard",
    [1038] = "Ogri'la",
    [1077] = "Shattered Sun Offensive",
}

-- Only list faction-exclusive factions; absent key = earnable by both
addon.factionSide = {
    [946] = "Alliance",   -- Honor Hold
    [947] = "Horde",      -- Thrallmar
}

addon.fixedQuestData = {
    [10106] = {
        title = "Hellfire Fortifications", level = 60,
        rep   = {{946, 150}},
        desc  = "Capture the Overlook, the Stadium and Broken Hill, then return to Warrant Officer Tracy Proudwell in Honor Hold in Hellfire Peninsula.",
    },
    [10110] = {
        title = "Hellfire Fortifications", level = 60,
        rep   = {{947, 150}},
        desc  = "Capture the Overlook, the Stadium and Broken Hill, then return to Battlecryer Blackeye in Thrallmar.",
    },
    [11505] = {
        title = "Spirits of Auchindoun", level = 70,
        rep   = {},
        desc  = "Help the Alliance secure a tower in the Bone Wastes.",
    },
    [11506] = {
        title = "Spirits of Auchindoun", level = 70,
        rep   = {},
        desc  = "Help the Horde secure a Spirit Tower in the Bone Wastes.",
    },
    [11008] = {
        title     = "Fires Over Skettis", level = 70,
        rep       = {{1031, 350}},
        prevQuest = "To Skettis!",
        desc      = "Seek out Monstrous Kaliri Eggs on the tops of Skettis dwellings and use the Skyguard Blasting Charges on them.  Return to Sky Sergeant Doryn.",
    },
    [11085] = {
        title     = "Escape from Skettis", level = 70,
        rep       = {{1031, 150}},
        prevQuest = "To Skettis!",
        desc      = "Escort the Skyguard Prisoner to safety and report to Sky Sergeant Doryn.",
    },
    [11023] = {
        title = "Bomb Them Again!", level = 70,
        rep   = {{1038, 500}, {1031, 500}},
        desc  = "Sky Sergeant Vanderlip has tasked you with the bombing of 15 Fel Cannonball Stacks.  Return to her at the Skyguard Outpost atop the Blade's Edge Mountains once you have done so.",
    },
    [11066] = {
        title     = "Wrangle More Aether Rays!", level = 70,
        rep       = {{1031, 350}, {1038, 350}},
        prevQuest = "Wrangle Some Aether Rays!",
        desc      = "Skyguard Khatie has asked you to wrangle 5 Aether Rays.  After you have done so, return them to her at the Skyguard Outpost atop the Blade's Edge Mountains.",
    },
    [11080] = {
        title = "The Relic's Emanation", level = 70,
        rep   = {{1038, 350}},
        desc  = "Chu'a'lor has asked you to return to him at Ogri'la atop the Blade's Edge Mountains after you have gained Apexis Emanations from an Apexis Relic.",
    },
    [11051] = {
        title     = "Banish More Demons", level = 70,
        rep       = {{1038, 350}},
        prevQuest = "Banish the Demons",
        desc      = "Kronk has asked you to use the Banishing Crystal to banish 15 demons at Forge Camp: Wrath or Forge Camp: Terror atop the Blade's Edge Mountains.  Return it to him once you have done so.",
    },
    -- Normal dungeon dailies (Nether-Stalker Mah'duun)
    [11389] = {
        title = "Wanted: Arcatraz Sentinels", level = 70,
        rep   = {{933, 250}, {935, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to dismantle 5 Arcatraz Sentinels. Return to him in Shattrath's Lower City once that has been accomplished in order to collect the bounty.",
    },
    [11364] = {
        title = "Wanted: Shattered Hand Centurions", level = 70,
        rep   = {{933, 350}, {947, 350}, {946, 350}},
        desc  = "Nether-Stalker Mah'duun has tasked you with the deaths of 4 Shattered Hand Centurions. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11371] = {
        title = "Wanted: Coilfang Myrmidons", level = 70,
        rep   = {{933, 250}, {942, 250}},
        desc  = "Nether-Stalker Mah'duun has asked you to slay 14 Coilfang Myrmidons. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11376] = {
        title = "Wanted: Malicious Instructors", level = 70,
        rep   = {{933, 250}, {1011, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to kill 3 Malicious Instructors. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11383] = {
        title = "Wanted: Rift Lords", level = 70,
        rep   = {{933, 250}, {989, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to kill 4 Rift Lords. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11385] = {
        title = "Wanted: Sunseeker Channelers", level = 70,
        rep   = {{933, 250}, {935, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to kill 6 Sunseeker Channelers. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11387] = {
        title = "Wanted: Tempest-Forge Destroyers", level = 70,
        rep   = {{933, 250}, {935, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to destroy 5 Tempest-Forge Destroyers. Return to him in Shattrath's Lower City once they all lie dead in order to collect the bounty.",
    },
    [11500] = {
        title = "Wanted: Sisters of Torment", level = 70,
        rep   = {{933, 250}, {1077, 250}},
        desc  = "Nether-Stalker Mah'duun wants you to slay 4 Sisters of Torment. Return to him in Shattrath's Lower City once you have done so in order to collect the bounty.",
    },
    -- Heroic dungeon dailies (Wind Trader Zhareem)
    [11354] = {
        title = "Wanted: Nazan's Riding Crop", level = 70,
        rep   = {{933, 350}, {947, 350}, {946, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain Nazan's Riding Crop. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11362] = {
        title = "Wanted: Keli'dan's Feathered Stave", level = 70,
        rep   = {{933, 350}, {947, 350}, {946, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain Keli'dan's Feathered Stave. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11363] = {
        title = "Wanted: Bladefist's Seal", level = 70,
        rep   = {{933, 350}, {947, 350}, {946, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain Bladefist's Seal. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11368] = {
        title = "Wanted: The Heart of Quagmirran", level = 70,
        rep   = {{933, 350}, {942, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain The Heart of Quagmirran. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11369] = {
        title = "Wanted: A Black Stalker Egg", level = 70,
        rep   = {{933, 350}, {942, 350}},
        desc  = "Wind Trader Zhareem wants you to obtain a Black Stalker Egg. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11370] = {
        title = "Wanted: The Warlord's Treatise", level = 70,
        rep   = {{933, 350}, {942, 350}},
        desc  = "Wind Trader Zhareem has asked you to acquire The Warlord's Treatise. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11372] = {
        title = "Wanted: The Headfeathers of Ikiss", level = 70,
        rep   = {{933, 350}, {1011, 350}},
        desc  = "Wind Trader Zhareem has asked you to acquire The Headfeathers of Ikiss. Deliver them to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11373] = {
        title = "Wanted: Shaffar's Wondrous Pendant", level = 70,
        rep   = {{933, 500}},
        desc  = "Wind Trader Zhareem wants you to obtain Shaffar's Wondrous Amulet. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11374] = {
        title = "Wanted: The Exarch's Soul Gem", level = 70,
        rep   = {{933, 350}, {1011, 350}},
        desc  = "Wind Trader Zhareem has asked you to recover The Exarch's Soul Gem. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11375] = {
        title = "Wanted: Murmur's Whisper", level = 70,
        rep   = {{933, 350}, {1011, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain Murmur's Whisper. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11378] = {
        title = "Wanted: The Epoch Hunter's Head", level = 70,
        rep   = {{933, 350}, {989, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain the Epoch Hunter's Head. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11382] = {
        title = "Wanted: Aeonus's Hourglass", level = 70,
        rep   = {{933, 350}, {989, 350}},
        desc  = "Wind Trader Zhareem has asked you to acquire Aeonus's Hourglass. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11384] = {
        title = "Wanted: A Warp Splinter Clipping", level = 70,
        rep   = {{933, 350}, {935, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain a Warp Splinter Clipping. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11386] = {
        title = "Wanted: Pathaleon's Projector", level = 70,
        rep   = {{933, 350}, {935, 350}},
        desc  = "Wind Trader Zhareem has asked you to acquire Pathaleon's Projector. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11388] = {
        title = "Wanted: The Scroll of Skyriss", level = 70,
        rep   = {{933, 350}, {935, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain The Scroll of Skyriss. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed on Heroic difficulty.",
    },
    [11499] = {
        title = "Wanted: The Signet Ring of Prince Kael'thas", level = 70,
        rep   = {{1077, 350}, {933, 350}},
        desc  = "Wind Trader Zhareem has asked you to obtain The Signet Ring of Prince Kael'thas. Deliver it to him in Shattrath's Lower City to collect the reward. This quest may only be completed at the Magisters' Terrace on Heroic difficulty.",
    },
    -- Cooking dailies (The Rokk, Lower City)
    [11377] = {
        title = "Revenge is Tasty", level = 70,
        rep   = {},
        desc  = "The Rokk in Lower City has asked you to cook up some Kaliri Stew using his cooking pot. Return to him when it's done.",
    },
    [11379] = {
        title = "Super Hot Stew", level = 70,
        rep   = {},
        desc  = "The Rokk in Lower City has asked you to cook up some Demon Broiled Surprise using his cooking pot, two Mok'Nathal Shortribs and a Crunchy Serpent. Return to him when it's done.",
    },
    [11380] = {
        title = "Manalicious", level = 70,
        rep   = {},
        desc  = "The Rokk in Lower City has asked you collect 15 Mana Berries from the Eco-Domes in Netherstorm.",
    },
    [11381] = {
        title = "Soup for the Soul", level = 70,
        rep   = {},
        desc  = "The Rokk in Lower City has asked you to cook up some Spiritual Soup using his cooking pot. Return to him when it's done.",
    },
    -- Fishing dailies (Old Man Barlo, Silmyr Lake)
    [11665] = {
        title = "Crocolisks in the City", level = 70,
        rep   = {},
        desc  = "Bring a Baby Crocolisk to Old Man Barlo. You can find him fishing northeast of Shattrath City by Silmyr Lake.",
    },
    [11666] = {
        title = "Bait Bandits", level = 70,
        rep   = {},
        desc  = "Bring a Blackfin Darter to Old Man Barlo. You can find him fishing northeast of Shattrath City by Silmyr Lake.",
    },
    [11667] = {
        title = "The One That Got Away", level = 70,
        rep   = {},
        desc  = "Catch the World's Largest Mudfish and bring it to Old Man Barlo. You can find him fishing northeast of Shattrath City by Silmyr Lake.",
    },
    [11668] = {
        title = "Shrimpin' Ain't Easy", level = 70,
        rep   = {},
        desc  = "Bring 10 Giant Freshwater Shrimp to Old Man Barlo. You can find him fishing northeast of Shattrath City by Silmyr Lake.",
    },
    [11669] = {
        title = "Felblood Fillet", level = 70,
        rep   = {},
        desc  = "Bring a Monstrous Felblood Snapper to Old Man Barlo. You can find him fishing northeast of Shattrath City by Silmyr Lake.",
    },
    -- PvP dailies (Alliance)
    [11335] = {
        title = "Call to Arms: Arathi Basin", level = 70,
        rep   = {},
        desc  = "Win an Arathi Basin battleground match and return to an Alliance Brigadier General at any Alliance capital city or Shattrath.",
    },
    [11336] = {
        title = "Call to Arms: Alterac Valley", level = 70,
        rep   = {},
        desc  = "Win an Alterac Valley battleground match and return to an Alliance Brigadier General at any Alliance capital city or Shattrath.",
    },
    [11337] = {
        title = "Call to Arms: Eye of the Storm", level = 70,
        rep   = {},
        desc  = "Win an Eye of the Storm battleground match and return to an Alliance Brigadier General at any Alliance capital city or Shattrath.",
    },
    [11338] = {
        title = "Call to Arms: Warsong Gulch", level = 70,
        rep   = {},
        desc  = "Win a Warsong Gulch battleground match and return to an Alliance Brigadier General at any Alliance capital city or Shattrath.",
    },
    -- PvP dailies (Horde)
    [11339] = {
        title = "Call to Arms: Arathi Basin", level = 70,
        rep   = {},
        desc  = "Win an Arathi Basin battleground match and return to a Horde Warbringer at any Horde capital city or Shattrath.",
    },
    [11340] = {
        title = "Call to Arms: Alterac Valley", level = 70,
        rep   = {},
        desc  = "Win an Alterac Valley battleground match and return to a Horde Warbringer at any Horde capital city or Shattrath.",
    },
    [11341] = {
        title = "Call to Arms: Eye of the Storm", level = 70,
        rep   = {},
        desc  = "Win an Eye of the Storm battleground match and return to a Horde Warbringer at any Horde capital city or Shattrath.",
    },
    [11342] = {
        title = "Call to Arms: Warsong Gulch", level = 70,
        rep   = {},
        desc  = "Win a Warsong Gulch battleground match and return to a Horde Warbringer at any Horde capital city or Shattrath.",
    },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Print known dailies to chat
-- ─────────────────────────────────────────────────────────────────────────────

local function printDailies()
    local d = getData()
    local prefix = "|cFF80FFFFDailySync|r"
    print(prefix .. " Daily quests for " .. DS.server .. ":")
    local labels = {
        normal  = "Normal Dungeon",
        heroic  = "Heroic Dungeon",
        cooking = "Cooking",
        fishing = "Fishing",
        pvp     = "PvP",
    }
    local order = { "normal", "heroic", "cooking", "fishing", "pvp" }
    for _, qtype in ipairs(order) do
        local f = questTypeFields[qtype]
        local questID = d[f.name]
        if questID then
            print("  " .. labels[qtype] .. ": " .. getQuestName(questID))
        else
            print("  " .. labels[qtype] .. ": |cFF808080Unknown|r")
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Event handling
-- ─────────────────────────────────────────────────────────────────────────────

function DS:joinDailySyncChannel()
    local num = GetChannelName("DailySync")
    -- If already joined and not in slot 1, just hide it and we're done
    if num > 1 then
        for i = 1, 10 do
            if _G["ChatFrame" .. i] then
                ChatFrame_RemoveChannel(_G["ChatFrame" .. i], "DailySync")
            end
        end
        return
    end
    -- WoW's chat cache may have auto-rejoined DailySync in slot 1 before General/Trade
    -- loaded. Leave it now and rejoin after a delay so it lands in a later slot.
    if num == 1 then
        LeaveChannelByName("DailySync")
    end
    C_Timer.After(30, function()
        if GetChannelName("DailySync") == 0 then
            JoinChannelByName("DailySync")
            C_Timer.After(1, function()
                for i = 1, 10 do
                    if _G["ChatFrame" .. i] then
                        ChatFrame_RemoveChannel(_G["ChatFrame" .. i], "DailySync")
                    end
                end
            end)
        end
    end)
end

DS:RegisterEvent("ADDON_LOADED")
DS:RegisterEvent("QUEST_ACCEPTED")
DS:RegisterEvent("QUEST_DETAIL")
DS:RegisterEvent("CHAT_MSG_ADDON")
DS:RegisterEvent("CHAT_MSG_CHANNEL")
DS:RegisterEvent("GROUP_JOINED")
DS:RegisterEvent("PLAYER_ENTERING_WORLD")
DS:RegisterEvent("ZONE_CHANGED_NEW_AREA")

DS:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then return end

        -- Initialise saved variables
        DailySync_Data = DailySync_Data or {}
        if not DailySync_Data[DS.server] then
            DailySync_Data[DS.server] = {}
        end
        local d = DailySync_Data[DS.server]
        if not d.dailyChangeOffset then d.dailyChangeOffset = 0 end
        if not d.dailyChangeTime   then d.dailyChangeTime   = 0 end
        DailySync_Data.ui = DailySync_Data.ui or {}
        DailySync_Data.ui.mmData = DailySync_Data.ui.mmData or {}

        DS.prefixRegistered = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if not DS.prefixRegistered then
            print("|cFF80FFFFDailySync|r Warning: could not register addon message prefix.")
        end

        -- After login settles, join the shared channel then broadcast
        C_Timer.After(8, function()
            DS:joinDailySyncChannel()
            checkReset()
            DS:broadcast(true, nil, nil, true)
        end)

        if addon.initUI then addon.initUI() end
        print("|cFF80FFFFDailySync|r v" .. version .. " loaded. Type /dsync for daily info.")

    elseif event == "QUEST_ACCEPTED" then
        -- QUEST_ACCEPTED passes the questID as arg1 in newer clients; fall back to GetQuestID()
        -- Capture only the first vararg to avoid tonumber(value, base) being called
        -- with WoW's additional event arguments interpreted as the numeric base.
        local arg1 = ...
        local questID = tonumber(arg1) or GetQuestID()
        if questID and dailyInfo[questID] then
            local qtype = getQuestType(questID)
            if qtype then
                local resetTime = GetQuestResetTime()
                dbg("detected QUEST_ACCEPTED", qtype, questID)
                storeQuest(qtype, questID, resetTime)
                DS:broadcast(true, nil, nil, true)
            end
        end

    elseif event == "QUEST_DETAIL" then
        local questID = GetQuestID()
        if questID and dailyInfo[questID] then
            local qtype = getQuestType(questID)
            if qtype then
                local resetTime = GetQuestResetTime()
                dbg("detected QUEST_DETAIL", qtype, questID)
                storeQuest(qtype, questID, resetTime)
                DS:broadcast(true, nil, nil, true)
            end
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix ~= PREFIX then return end
        if isSelf(sender) then
            dbg("->", channel, message)
            return
        end
        dbg("<-", channel, sender, message)
        DS:receiveMessage(message, channel)

    elseif event == "CHAT_MSG_CHANNEL" then
        local message, sender, _, _, _, _, _, _, channelBaseName = ...
        if channelBaseName ~= "DailySync" then return end
        if isSelf(sender) then return end
        dbg("<-", "CUSTOM", sender, message)
        DS:receiveMessage(message, "CUSTOM")
        -- Whisper our data back so sender can fill any gaps they're missing
        if DS.prefixRegistered then
            local reply = addon.buildMessage()
            dbg("-> WHISPER", sender, reply)
            C_ChatInfo.SendAddonMessage(PREFIX, reply, "WHISPER", sender)
        end

    elseif event == "GROUP_JOINED" then
        -- Just joined a group; share with / request from party members
        DS:broadcast(false, "PARTY", nil, true)

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(20, function()
            if not IsInInstance() and time() - DS.lastYell > YELL_COOLDOWN then
                DS.lastYell = time()
                DS:broadcast(false, "YELL", nil, true)
            end
        end)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        DS:joinDailySyncChannel()
        if not IsInInstance() and time() - DS.lastYell > YELL_COOLDOWN then
            DS.lastYell = time()
            DS:broadcast(false, "YELL", nil, true)
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Slash commands
-- ─────────────────────────────────────────────────────────────────────────────

SLASH_DAILYSYNC1 = "/dailysync"
SLASH_DAILYSYNC2 = "/dsync"

SlashCmdList["DAILYSYNC"] = function(cmd)
    if not DailySync_Data then
        print("|cFF80FFFFDailySync|r not initialised yet.")
        return
    end

    cmd = strtrim(cmd:lower())

    if cmd == "" or cmd == "show" then
        printDailies()

    elseif cmd == "reset" then
        local d = getData()
        for _, f in ipairs(fieldOrder) do
            d[f.name]     = nil
            d[f.resetKey] = nil
        end
        d.dailyChangeTime = 0
        print("|cFF80FFFFDailySync|r Stored daily data cleared.")

    elseif cmd == "debug" then
        DS.debug = not DS.debug
        print("|cFF80FFFFDailySync|r Debug output " .. (DS.debug and "enabled" or "disabled") .. ".")

    elseif cmd:match("^offset%s+%-?%d+$") then
        local offset = tonumber(cmd:match("%-?%d+"))
        getData().dailyChangeOffset = offset
        print("|cFF80FFFFDailySync|r Daily-change offset set to "
              .. offset .. " hour(s) after quest reset.")
        print("  0 = US realms (dailies change at quest reset)")
        print("  7 = Oceanic/AEST realms")

    elseif cmd:match("^ping%s+%S+") then
        if addon.pingPlayer then
            addon.pingPlayer(cmd:match("^ping%s+(%S+)"))
        end

    else
        print("|cFF80FFFFDailySync|r Commands:")
        print("  /dsync             - show today's known daily quests")
        print("  /dsync reset       - clear stored daily data")
        print("  /dsync offset N    - set daily-change offset in hours (0 = US, 7 = AEST)")
        print("  /dsync debug       - toggle debug output")
        print("  /dsync ping NAME   - check DailySync version of a player")
    end
end
