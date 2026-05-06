-- gui.lua  –  DailySync

local addonName, addon = ...
local DS = addon.DS

-- ─────────────────────────────────────────────────────────────────────────────
-- Sizes & colours
-- ─────────────────────────────────────────────────────────────────────────────

local POPUP_W, POPUP_H = 430, 300

local function clr(hex) return "|cFF" .. hex end
local C_TITLE   = clr("80FFFF")   -- cyan  (addon name)
local C_HEADER  = clr("FF8000")   -- orange with outline (section headers)
local C_DUNGEON = clr("FFFF00")   -- yellow (dungeon name row)
local C_LINK    = clr("71D5FF")   -- light blue (quest links)
local C_GREY    = clr("888888")
local C_RESET   = "|r"

local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:13:13:0:0|t"

-- ─────────────────────────────────────────────────────────────────────────────
-- Rotating daily sections
-- ─────────────────────────────────────────────────────────────────────────────

local SECTIONS = {
    { qtype="normal",  header="Daily Dungeon",        isDungeon=true, heroic=false },
    { qtype="heroic",  header="Daily Heroic Dungeon", isDungeon=true, heroic=true  },
    { qtype="cooking", header="Cooking Daily" },
    { qtype="fishing", header="Fishing Daily" },
    { qtype="pvp",     header="PvP Daily"     },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Fixed daily quest data
-- ─────────────────────────────────────────────────────────────────────────────

-- Two tower quests shown side-by-side; faction resolved at runtime
local TOWER_QUESTS = {
    { alliance=10106, horde=10110 },   -- Hellfire Fortifications
    { alliance=11505, horde=11506 },   -- Spirits of Auchindoun
}

local OGRILA_QUESTS   = { 11080, 11051, 11023, 11066 }   -- Relic, Banish, Bomb, Wrangle
local SKYGUARD_QUESTS = { 11085, 11008, 11023, 11066 }  -- Escape, Fires, Bomb, Wrangle

-- ─────────────────────────────────────────────────────────────────────────────
-- Layout constants
-- ─────────────────────────────────────────────────────────────────────────────

local CONTENT_W = POPUP_W - 20       -- 410 px usable width
local HALF_W    = math.floor(CONTENT_W / 2)  -- 172 px  (two-column split)
local ROW_H     = 14
local SUB_GAP   = 4    -- extra vertical gap after a dungeon/column header
local SEC_GAP   = 8    -- gap between sections
local INDENT    = 10   -- quest-link left indent under a header
local START_PAD = 5    -- top padding in scrollable content frame

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function formatReset()
    local t = GetQuestResetTime()
    if not t or t <= 0 then return "?" end
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    return h > 0 and format("%dh %dm", h, m) or format("%dm", m)
end

local function getInstanceName(questID, isHeroic)
    local base = addon.questFallbackNames[questID] or ("Instance #" .. questID)
    return isHeroic and ("Heroic: " .. base) or base
end

-- Returns a light-blue quest hyperlink.
-- Uses GetQuestLink when the quest is in the cache; otherwise constructs a
-- standard |Hquest:ID:70|h link.  TBC's engine can serve full tooltip data for
-- either form via GameTooltip:SetHyperlink even without a cached quest.
local function getQuestLinkText(questID)
    if GetQuestLink then
        local link = GetQuestLink(questID)
        if link then
            local hlink = link:match("(|Hquest:[^|]+|h%[[^%]]*%]|h)")
            if hlink then return C_LINK .. hlink .. C_RESET end
        end
    end
    local name = addon.getQuestName(questID)
    return C_LINK .. string.format("|Hquest:%d:70|h[%s]|h", questID, name) .. C_RESET
end

local function isDone(questID)
    return C_QuestLog
        and C_QuestLog.IsQuestFlaggedCompleted
        and C_QuestLog.IsQuestFlaggedCompleted(questID)
end

-- Quest link + optional tick if completed today
local function questText(questID)
    return getQuestLinkText(questID) .. (isDone(questID) and "  " .. TICK or "")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Popup frame
-- ─────────────────────────────────────────────────────────────────────────────

local BACKDROP_POPUP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local popup = CreateFrame("Frame", "DailySyncPopup", UIParent, "BackdropTemplate")
popup:SetSize(POPUP_W, POPUP_H)
popup:SetFrameStrata("HIGH")
popup:SetMovable(true)
popup:EnableMouse(true)
popup:RegisterForDrag("LeftButton")
popup:SetScript("OnDragStart", popup.StartMoving)
popup:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local pt, _, rpt, x, y = self:GetPoint()
    DailySync_Data.ui.popupPoint    = pt
    DailySync_Data.ui.popupRelPoint = rpt
    DailySync_Data.ui.popupX        = math.floor(x)
    DailySync_Data.ui.popupY        = math.floor(y)
end)
if popup.SetBackdrop then
    popup:SetBackdrop(BACKDROP_POPUP)
    popup:SetBackdropColor(0.05, 0.05, 0.10, 0.96)
end
popup:Hide()

popup:SetScript("OnMouseDown", function(self, btn)
    if btn == "RightButton" then self:Hide() end
end)

-- Title bar (non-scrolling, sits directly on popup)
local popupTitle = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
popupTitle:SetText(C_TITLE .. "DailySync" .. C_RESET)
popupTitle:SetPoint("TOPLEFT", popup, "TOPLEFT", 10, -8)

local popupResetLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
popupResetLabel:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -10, -9)
popupResetLabel:SetJustifyH("RIGHT")

local popupLine = popup:CreateTexture(nil, "ARTWORK")
popupLine:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
popupLine:SetHeight(1)
popupLine:SetPoint("TOPLEFT",  popup, "TOPLEFT",  8, -19)
popupLine:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -8, -19)
popupLine:SetVertexColor(0.4, 0.4, 0.5, 0.8)

-- Daily quest counter (bottom-left)
local popupDailyCount = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
popupDailyCount:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 10, 11)
popupDailyCount:SetJustifyH("LEFT")

-- Daily gold tracker (right of the daily-quest counter)
local popupDailyGold = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
popupDailyGold:SetPoint("LEFT", popupDailyCount, "RIGHT", 12, 0)
popupDailyGold:SetJustifyH("LEFT")

-- Share button (non-scrolling)
local popupShare = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
popupShare:SetSize(80, 18)
popupShare:SetText("Sync")
popupShare:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -8, 7)
local SYNC_COOLDOWN = 10
local lastSyncTime  = 0
popupShare:SetScript("OnClick", function(self)
    local now = time()
    local remaining = SYNC_COOLDOWN - (now - lastSyncTime)
    if remaining > 0 then
        self:SetText(remaining .. "s")
        C_Timer.After(1, function() if self and self.SetText then self:SetText("Sync") end end)
        return
    end
    lastSyncTime = now
    DS:broadcast(true, nil, nil, true)
    addon.sendToCustomChannel()
    self:SetText("Syncing...")
    C_Timer.After(10, function() if self and self.SetText then self:SetText("Sync") end end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- ScrollFrame + content child
-- ─────────────────────────────────────────────────────────────────────────────

local scrollFrame = CreateFrame("ScrollFrame", nil, popup)
scrollFrame:SetPoint("TOPLEFT",     popup, "TOPLEFT",     10, -22)
scrollFrame:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -10,  28)
-- Only EnableMouseWheel here — do NOT set any OnMouseDown/OnMouseUp on scrollFrame.
-- Setting any mouse button script would implicitly enable mouse capture on the
-- scroll frame, swallowing all mouse events and preventing the content child from
-- receiving the hyperlink hover/click events needed to make links interactive.
scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll()
    local max = self:GetVerticalScrollRange()
    self:SetVerticalScroll(math.max(0, math.min(cur - delta * 20, max)))
end)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetWidth(CONTENT_W)
content:SetHeight(400)   -- placeholder; replaced after layout
scrollFrame:SetScrollChild(content)

content:EnableMouse(true)
content:SetHyperlinksEnabled(true)
content:SetScript("OnMouseDown", function(self, btn)
    if btn == "RightButton" then popup:Hide() end
end)
-- Format a copper value as e.g. "11g 99s" with the standard WoW colours.
local function formatGold(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = "|cFFFFD700" .. g .. "g|r" end
    if s > 0 then parts[#parts + 1] = "|cFFC7C7CF" .. s .. "s|r" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = "|cFFEDA55F" .. c .. "c|r" end
    return table.concat(parts, " ")
end

-- Substitute WoW quest text placeholders with the player's values:
--   <name>, <class>, <race>             — character info
--   <him/her>, <he/she>, <lad/lass>, …  — any <male/female> pair, picked by player sex
local function fillPlaceholders(text)
    if not text then return text end
    text = text:gsub("<name>",  UnitName("player")  or "")
    text = text:gsub("<class>", UnitClass("player") or "")
    text = text:gsub("<race>",  UnitRace("player")  or "")
    -- UnitSex returns 2 = male, 3 = female (1 = unknown, fall through to male)
    local female = (UnitSex("player") == 3)
    text = text:gsub("<([^/<>]+)/([^/<>]+)>", function(m, f) return female and f or m end)
    return text
end

-- Format an item entry as "<icon> [Name] x<count>" using its quality colour.
-- Accepts either a plain itemID number, or a {itemID, count} table.
-- Falls back to a plain "[Item #ID]" if the item info isn't cached yet
-- (the next render will pick up the cached value).
local function formatItem(entry)
    local itemID, count
    if type(entry) == "table" then itemID, count = entry[1], entry[2]
    else                            itemID, count = entry, 1 end

    local _, link, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)
    local prefix  = texture and ("|T" .. texture .. ":14:14:0:0|t ") or ""
    local display = link or ("|cFFAAAAAA[Item #" .. itemID .. "]|r")
    local suffix  = (count and count > 1) and (" x" .. count) or ""
    return prefix .. display .. suffix
end

-- Builds a tooltip from our embedded quest data.
-- Returns true if the tooltip was populated, false if the quest isn't in our table.
local function buildRichTooltip(questID)
    local data   = addon.fixedQuestData and addon.fixedQuestData[questID]
    if not data then return false end
    local fNames = addon.factionNames or {}

    local playerFaction = UnitFactionGroup("player")
    local titleText = C_LINK .. data.title .. " (Daily)" .. C_RESET
    if isDone(questID) then titleText = titleText .. "  " .. TICK end
    GameTooltip:AddDoubleLine(titleText, "Level " .. data.level, 1, 1, 1, 1, 0.82, 0)
    GameTooltip:AddLine(fillPlaceholders(data.desc), 1, 1, 1, true)

    if data.objective then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(fillPlaceholders(data.objective), 1, 0.6, 0.6, true)
    end

    if data.longDesc then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(C_HEADER .. "Description" .. C_RESET, 1, 0.82, 0)
        GameTooltip:AddLine(fillPlaceholders(data.longDesc), 1, 1, 1, true)
    end

    if data.prevQuest then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Requires Quest " .. C_LINK .. "[" .. data.prevQuest .. "]" .. C_RESET, 1, 1, 1)
    end

    local hasRep = false
    if data.rep then
        for _, r in ipairs(data.rep) do
            local side = addon.factionSide and addon.factionSide[r[1]]
            if not side or side == playerFaction then hasRep = true; break end
        end
    end
    if data.gold or data.rewardNote or data.rewardItems then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(C_HEADER .. "Rewards" .. C_RESET, 1, 0.82, 0)
        if data.gold then
            GameTooltip:AddLine(formatGold(data.gold), 1, 1, 1)
        end
        if data.rewardNote then
            GameTooltip:AddLine(data.rewardNote, 1, 1, 1, true)
        end
        if data.rewardItems then
            for _, itemID in ipairs(data.rewardItems) do
                GameTooltip:AddLine(formatItem(itemID), 1, 1, 1)
            end
        end
    end
    if hasRep then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(C_HEADER .. "Reputation" .. C_RESET, 1, 0.82, 0)
        for _, r in ipairs(data.rep) do
            local side = addon.factionSide and addon.factionSide[r[1]]
            if not side or side == playerFaction then
                local fname = fNames[r[1]] or ("Faction " .. r[1])
                GameTooltip:AddDoubleLine(fname, "+" .. r[2], 1, 1, 1, 0.1, 1, 0.1)
            end
        end
    end

    return true
end

content:SetScript("OnHyperlinkEnter", function(self, link)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    local questID = tonumber(link:match("^quest:(%d+)"))
    -- 1. Use our embedded rich tooltip for quests in fixedQuestData (fixed dailies with
    --    rep data we control). Must run BEFORE SetHyperlink because the engine returns
    --    NumLines() > 0 even for partial data (name only, no rep), which would short-circuit.
    if questID and buildRichTooltip(questID) then
        GameTooltip:Show()
        return
    end
    -- 2. Try the engine for all other quests (rotating dungeon/heroic/cooking/fishing/pvp).
    GameTooltip:SetHyperlink(link)
    if GameTooltip:NumLines() > 0 then
        GameTooltip:Show()
        return
    end
    -- 3. Absolute fallback — quest not in our table and not in engine cache.
    if questID then
        GameTooltip:AddLine(C_LINK .. "[" .. addon.getQuestName(questID) .. "]" .. C_RESET)
        GameTooltip:AddLine("Daily Quest", 1, 0.82, 0)
    end
    GameTooltip:Show()
end)
content:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
content:SetScript("OnHyperlinkClick", function(self, link, text, button)
    if IsShiftKeyDown() then
        ChatEdit_InsertLink(text)
        return
    end
    local questID = tonumber(link:match("^quest:(%d+)"))
    if questID then
        local numEntries = GetNumQuestLogEntries()
        local i = 1
        while i <= numEntries do
            local _, _, _, isHeader, isCollapsed, _, _, qID = GetQuestLogTitle(i)
            if isHeader and isCollapsed then
                ExpandQuestHeader(i)
                numEntries = GetNumQuestLogEntries()
            elseif qID == questID then
                ShowUIPanel(QuestLogFrame)
                QuestLog_SetSelection(i)
                QuestLog_Update()
                return
            end
            i = i + 1
        end
    end
    SetItemRef(link, text, button)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Font-string factory  (all strings are children of `content`)
--   fixedWidth supplied  → SetWidth used (for multi-column rows)
--   fixedWidth nil       → TOPRIGHT anchor used (full-width rows)
-- ─────────────────────────────────────────────────────────────────────────────

local function makeFS(size, flags, x, y, fixedWidth)
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, flags or "")
    fs:SetJustifyH("LEFT")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    if fixedWidth then
        fs:SetWidth(fixedWidth)
    else
        fs:SetPoint("TOPRIGHT", content, "TOPRIGHT", -5, y)
    end
    return fs
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build layout (curY accumulates downward as negative values)
-- ─────────────────────────────────────────────────────────────────────────────

local curY    = -START_PAD
local uiRefs  = { rotating = {}, towers = {}, ogrila = {}, skyguard = {} }

-- ── Rotating sections ────────────────────────────────────────────────────────
for i, sec in ipairs(SECTIONS) do
    local refs = {}
    refs.header = makeFS(12, "OUTLINE", 0, curY)

    if sec.isDungeon then
        refs.dungeon = makeFS(11, "", INDENT, curY - ROW_H - SUB_GAP)
        refs.detail  = makeFS(11, "", INDENT, curY - ROW_H * 2 - SUB_GAP)
        curY = curY - ROW_H * 3 - SUB_GAP - SEC_GAP
    else
        refs.detail = makeFS(11, "", INDENT, curY - ROW_H)
        curY = curY - ROW_H * 2 - SEC_GAP
    end
    uiRefs.rotating[i] = refs
end

-- ── PvP Towers (two links side-by-side) ──────────────────────────────────────
uiRefs.towers.header = makeFS(12, "OUTLINE", 0, curY)
local tColW = HALF_W - INDENT - 3
for j, _ in ipairs(TOWER_QUESTS) do
    local tx = (j == 1) and INDENT or (HALF_W + INDENT)
    uiRefs.towers[j] = makeFS(11, "", tx, curY - ROW_H, tColW)
end
curY = curY - ROW_H * 2 - SEC_GAP

-- ── Ogri'la / Skyguard (two-column) ──────────────────────────────────────────
local colQW = HALF_W - INDENT - 3
uiRefs.ogrila.header   = makeFS(12, "OUTLINE", 0,      curY, HALF_W - 3)
uiRefs.skyguard.header = makeFS(12, "OUTLINE", HALF_W, curY, HALF_W - 3)

local twoColTopY = curY - ROW_H - SUB_GAP
for j = 1, math.max(#OGRILA_QUESTS, #SKYGUARD_QUESTS) do
    local rowY = twoColTopY - (j - 1) * ROW_H
    if j <= #OGRILA_QUESTS   then uiRefs.ogrila[j]   = makeFS(11, "", INDENT,          rowY, colQW) end
    if j <= #SKYGUARD_QUESTS then uiRefs.skyguard[j]  = makeFS(11, "", HALF_W + INDENT, rowY, colQW) end
end
curY = twoColTopY - math.max(#OGRILA_QUESTS, #SKYGUARD_QUESTS) * ROW_H - SEC_GAP

-- Fix content height now that we know the full extent
content:SetHeight(math.abs(curY) + START_PAD)

-- ─────────────────────────────────────────────────────────────────────────────
-- Refresh
-- ─────────────────────────────────────────────────────────────────────────────

-- Per-category gold for the rotating dailies, used as a fallback for the max
-- when today's specific quest hasn't been synced yet. Per-quest values in
-- fixedQuestData take precedence whenever the day's quest IS known.
local CATEGORY_DAILY_GOLD = {
    normal  = 163900,
    heroic  = 246000,
    cooking = 75900,
    fishing = 0,
    pvp     = 119900,
}

-- Sum gold from the 13 daily slots: 5 rotating + 2 tower (faction-paired) +
-- 6 unique Skyguard/Ogri'la (Bomb/Wrangle appear in both lists but are the
-- same quest, so they only count once).
local function computeDailyGold(d)
    local current, max = 0, 0
    local function questGold(qid)
        local data = addon.fixedQuestData and addon.fixedQuestData[qid]
        return (data and data.gold) or 0
    end
    local function tally(qid, fallback)
        local g = qid and questGold(qid) or 0
        if g == 0 and fallback then g = fallback end
        max = max + g
        if qid and isDone(qid) then current = current + g end
    end

    for _, sec in ipairs(SECTIONS) do
        tally(d[addon.questTypeFields[sec.qtype].name], CATEGORY_DAILY_GOLD[sec.qtype])
    end
    local faction = UnitFactionGroup("player")
    for _, tq in ipairs(TOWER_QUESTS) do
        tally((faction == "Alliance") and tq.alliance or tq.horde)
    end
    local seen = {}
    for _, list in ipairs({ OGRILA_QUESTS, SKYGUARD_QUESTS }) do
        for _, qid in ipairs(list) do
            if not seen[qid] then seen[qid] = true; tally(qid) end
        end
    end
    return current, max
end

local function refreshPopup()
    local d = addon.getData()
    if not d then return end

    popupResetLabel:SetText(clr("FFD100") .. "Reset: " .. formatReset() .. C_RESET)
    local done = (GetDailyQuestsCompleted and GetDailyQuestsCompleted()) or 0
    popupDailyCount:SetText(clr("FFD100") .. "Daily Quests: " .. done .. " / 25" .. C_RESET)
    local cur, max = computeDailyGold(d)
    popupDailyGold:SetText(clr("FFD100") .. "Daily Gold:" .. C_RESET .. " " .. formatGold(cur) .. " / " .. formatGold(max))

    -- Rotating sections
    for i, sec in ipairs(SECTIONS) do
        local refs    = uiRefs.rotating[i]
        local questID = d[addon.questTypeFields[sec.qtype].name]
        refs.header:SetText(C_HEADER .. sec.header .. ":" .. C_RESET)
        if questID then
            if sec.isDungeon then
                refs.dungeon:SetText(C_DUNGEON .. getInstanceName(questID, sec.heroic) .. C_RESET)
            end
            refs.detail:SetText(questText(questID))
        else
            if sec.isDungeon then refs.dungeon:SetText(C_GREY .. "Unknown" .. C_RESET) end
            refs.detail:SetText(C_GREY .. "Unknown" .. C_RESET)
        end
    end

    -- PvP Towers
    uiRefs.towers.header:SetText(C_HEADER .. "PvP Towers:" .. C_RESET)
    local faction = UnitFactionGroup("player")
    for j, tq in ipairs(TOWER_QUESTS) do
        local qid = (faction == "Alliance") and tq.alliance or tq.horde
        uiRefs.towers[j]:SetText(questText(qid))
    end

    -- Ogri'la
    uiRefs.ogrila.header:SetText(C_HEADER .. "Ogri'la:" .. C_RESET)
    for j, qid in ipairs(OGRILA_QUESTS) do
        uiRefs.ogrila[j]:SetText(questText(qid))
    end

    -- Sha'tari Skyguard
    uiRefs.skyguard.header:SetText(C_HEADER .. "Skyguard:" .. C_RESET)
    for j, qid in ipairs(SKYGUARD_QUESTS) do
        uiRefs.skyguard[j]:SetText(questText(qid))
    end
end

local function updateAll()
    if popup:IsShown() then refreshPopup() end
end
addon.guiUpdate = updateAll

local ticker
local function startTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(10, updateAll)
end
local function stopTicker()
    if not popup:IsShown() then
        if ticker then ticker:Cancel(); ticker = nil end
    end
end

popup:HookScript("OnShow", function() refreshPopup(); startTicker() end)
popup:HookScript("OnHide", stopTicker)

-- ─────────────────────────────────────────────────────────────────────────────
-- Toggle
-- ─────────────────────────────────────────────────────────────────────────────

function addon.togglePopup(anchorFrame)
    if popup:IsShown() then
        popup:Hide()
    else
        popup:ClearAllPoints()
        if DailySync_Data.ui.popupPoint then
            popup:SetPoint(DailySync_Data.ui.popupPoint, UIParent,
                           DailySync_Data.ui.popupRelPoint,
                           DailySync_Data.ui.popupX, DailySync_Data.ui.popupY)
        elseif anchorFrame then
            popup:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", -8, -4)
        else
            popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        popup:Show()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Minimap button  (LibDBIcon)
-- ─────────────────────────────────────────────────────────────────────────────

local LDB       = LibStub("LibDataBroker-1.1")
local LibDBIcon = LibStub("LibDBIcon-1.0")

local ldbObject = LDB:NewDataObject("DailySync", {
    type = "launcher",
    icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    OnClick = function(self, button)
        if button == "LeftButton" or button == "RightButton" then
            addon.togglePopup(self)
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine(C_TITLE .. "DailySync" .. C_RESET)
        tooltip:AddLine(" ")
        tooltip:AddLine("Click  toggle daily quests", 1, 1, 1)
        tooltip:AddLine("Drag   reposition button",   1, 1, 1)
    end,
    OnLeave = function() GameTooltip:Hide() end,
})

-- ─────────────────────────────────────────────────────────────────────────────
-- Init
-- ─────────────────────────────────────────────────────────────────────────────

function addon.initUI()
    DailySync_Data.ui = DailySync_Data.ui or {}
    DailySync_Data.ui.mmData = DailySync_Data.ui.mmData or {}
    LibDBIcon:Register("DailySync", ldbObject, DailySync_Data.ui.mmData)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Slash command
-- ─────────────────────────────────────────────────────────────────────────────

local _baseSlash = SlashCmdList["DAILYSYNC"]
SlashCmdList["DAILYSYNC"] = function(cmd)
    local c = strtrim(cmd:lower())
    if c == "" or c == "show" then
        addon.togglePopup()
    else
        _baseSlash(cmd)
    end
end
