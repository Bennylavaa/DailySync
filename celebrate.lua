local addonName, addon = ...

local ROTATING = { "normal", "heroic", "cooking", "fishing", "pvp" }

local TOWER_QUESTS = {
    { alliance = 10106, horde = 10110 },   -- Hellfire Fortifications
    { alliance = 11505, horde = 11506 },   -- Spirits of Auchindoun
}

-- Ogri'la (11080, 11051, 11023, 11066) + Skyguard (11085, 11008, 11023, 11066).
-- 11023 (Bomb) and 11066 (Wrangle) appear in both lists but only count once.
local OGRILA_SKYGUARD = { 11080, 11051, 11023, 11066, 11085, 11008 }

local TOTAL_SLOTS = #ROTATING + #TOWER_QUESTS + #OGRILA_SKYGUARD   -- 13

local function isDone(qid)
    return qid and C_QuestLog
        and C_QuestLog.IsQuestFlaggedCompleted
        and C_QuestLog.IsQuestFlaggedCompleted(qid)
end

local function countCompletedSlots()
    local d = addon.getData and addon.getData()
    if not d then return 0 end
    local count = 0
    for _, qtype in ipairs(ROTATING) do
        local f = addon.questTypeFields[qtype]
        if isDone(d[f.name]) then count = count + 1 end
    end
    local faction = UnitFactionGroup("player")
    for _, tq in ipairs(TOWER_QUESTS) do
        if isDone((faction == "Alliance") and tq.alliance or tq.horde) then
            count = count + 1
        end
    end
    for _, qid in ipairs(OGRILA_SKYGUARD) do
        if isDone(qid) then count = count + 1 end
    end
    return count
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Overlay frame
-- ─────────────────────────────────────────────────────────────────────────────

local STANDARD = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function setSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a)
    else tex:SetTexture(r, g, b, a) end
end

local BANNER_W, BANNER_H = 700, 130

-- Master frame owns the lifecycle (Show/Hide cascades to children, OnUpdate
-- drives spawning + auto-dismiss). It's just a logical container, no visuals.
local celebration = CreateFrame("Frame", "DailySyncCelebrate", UIParent)
celebration:SetAllPoints(UIParent)
celebration:Hide()

-- Lower-strata fullscreen layer that hosts all explosion frames. Lives BELOW
-- the banner in z-order so fireworks never obscure the banner text.
local fireworks_layer = CreateFrame("Frame", nil, celebration)
fireworks_layer:SetFrameStrata("MEDIUM")
fireworks_layer:SetAllPoints(UIParent)

-- Banner sits at DIALOG strata so its text always reads cleanly on top of
-- whatever fireworks are bursting behind it.
local banner = CreateFrame("Button", nil, celebration)
banner:SetFrameStrata("DIALOG")
banner:SetSize(BANNER_W, BANNER_H)
banner:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
banner:EnableMouse(true)

banner.bg = banner:CreateTexture(nil, "BACKGROUND")
setSolid(banner.bg, 0, 0, 0, 0.85)
banner.bg:SetAllPoints()

banner.top = banner:CreateTexture(nil, "BORDER")
setSolid(banner.top, 1, 0.82, 0.2, 0.9)
banner.top:SetHeight(2)
banner.top:SetPoint("TOPLEFT")
banner.top:SetPoint("TOPRIGHT")

banner.bot = banner:CreateTexture(nil, "BORDER")
setSolid(banner.bot, 1, 0.82, 0.2, 0.9)
banner.bot:SetHeight(2)
banner.bot:SetPoint("BOTTOMLEFT")
banner.bot:SetPoint("BOTTOMRIGHT")

banner.stext = banner:CreateFontString(nil, "OVERLAY", "GameFontWhite")
banner.stext:SetFont(STANDARD, 13, "OUTLINE")
banner.stext:SetPoint("TOP", banner, "TOP", 0, -8)
banner.stext:SetText("|cFF80FFFFDailySync|r")

banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontWhite")
banner.text:SetFont(STANDARD, 32, "OUTLINE")
banner.text:SetPoint("TOP", banner, "TOP", 0, -26)
banner.text:SetText("Congratulations!")
banner.text:SetTextColor(1, 0.85, 0.2, 1)

banner.text2 = banner:CreateFontString(nil, "OVERLAY", "GameFontWhite")
banner.text2:SetFont(STANDARD, 22, "OUTLINE")
banner.text2:SetPoint("TOP", banner, "TOP", 0, -68)
banner.text2:SetText("All Dailies Complete!")
banner.text2:SetTextColor(0.6, 1, 0.8, 1)

banner.dtext = banner:CreateFontString(nil, "OVERLAY", "GameFontWhite")
banner.dtext:SetFont(STANDARD, 11, "OUTLINE")
banner.dtext:SetPoint("BOTTOM", banner, "BOTTOM", 0, 6)
banner.dtext:SetText("|cFF888888<Click to dismiss>|r")

banner:SetScript("OnClick", function() celebration:Hide() end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Explosion pool (expand + fade)
-- ─────────────────────────────────────────────────────────────────────────────

local function expandAndFade(self)
    local fps = (60 / math.max(GetFramerate(), 1))
    self:SetWidth(self:GetWidth() + fps)
    self:SetHeight(self:GetHeight() + fps)
    local a = self:GetAlpha() - fps * 0.01
    if a <= 0 then
        self:SetAlpha(0)
        self.free = true
        self:Hide()
    else
        self:SetAlpha(a)
    end
end

local explosions = {}
local function GetExplosion()
    for _, frame in ipairs(explosions) do
        if frame.free then
            frame.free = nil
            return frame
        end
    end
    local frame = CreateFrame("Frame", nil, fireworks_layer)
    frame:SetFrameStrata("MEDIUM")
    frame:SetScript("OnUpdate", expandAndFade)
    frame.tex = frame:CreateTexture(nil, "OVERLAY")
    frame.tex:SetAllPoints()
    table.insert(explosions, frame)
    return frame
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Random fireworks while shown
-- ─────────────────────────────────────────────────────────────────────────────

celebration:SetScript("OnShow", function(self)
    self.tick      = GetTime() + 0.2
    self.autoHide  = GetTime() + 15
end)

celebration:SetScript("OnUpdate", function(self)
    -- Auto-dismiss after a while so it never blocks gameplay
    if self.autoHide and GetTime() > self.autoHide then
        self:Hide()
        return
    end

    -- Small per-frame jitter on the headline so it twinkles
    local r, g, b = banner.text:GetTextColor()
    banner.text:SetTextColor(
        math.max(0.7, math.min(1.0, r + (math.random() - 0.5) / 12)),
        math.max(0.6, math.min(1.0, g + (math.random() - 0.5) / 12)),
        math.max(0.0, math.min(0.5, b + (math.random() - 0.5) / 12)),
        1
    )

    if (self.tick or 0) > GetTime() then return end
    self.tick = GetTime() + math.max(0.1, math.random() * 0.4)

    -- Spawn fireworks anywhere across the full screen (anchored to the
    -- fullscreen fireworks_layer's CENTER so coords run +/- half-screen)
    local width  = math.floor(GetScreenWidth()  / 2)
    local height = math.floor(GetScreenHeight() / 2)
    local x = math.random(-width,  width)
    local y = math.random(-height, height)

    -- White flash core
    local core = GetExplosion()
    core:ClearAllPoints()
    core:SetPoint("CENTER", fireworks_layer, "CENTER", x, y)
    core:SetWidth(25); core:SetHeight(25)
    setSolid(core.tex, 1, 1, 1, 0.5)
    core:SetAlpha(1)
    core:Show()

    -- Colored confetti specks around the core
    for i = 1, math.random(15, 25) do
        local p = GetExplosion()
        p:ClearAllPoints()
        p:SetPoint("CENTER", fireworks_layer, "CENTER",
                   x + (math.random(0, 100) - 50),
                   y + (math.random(0, 100) - 50))
        p:SetWidth(3); p:SetHeight(3)
        setSolid(p.tex, math.random(), math.random(), math.random(), 1)
        p:SetAlpha(1)
        p:Show()
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-cycle guard so we only celebrate once per daily reset
-- ─────────────────────────────────────────────────────────────────────────────

local function alreadyCelebratedThisCycle()
    local d = addon.getData and addon.getData()
    if not d then return true end
    return d.celebratedUntil and time() < d.celebratedUntil
end

local function markCelebrated()
    local d = addon.getData and addon.getData()
    if not d then return end
    -- Guard expires at the next daily rotation (same timestamp the addon
    -- already uses for clearing rotating quest data).
    d.celebratedUntil = d.dailyChangeTime or (time() + 86400)
end

local function trigger()
    pcall(PlaySound, 888)         -- LevelUp soundkit (vanilla→retail)
    pcall(PlaySound, 12891)       -- RaidWarning fanfare
    celebration:Show()
    markCelebrated()
end

function addon.checkAllDailiesComplete()
    if alreadyCelebratedThisCycle() then return end
    if countCompletedSlots() >= TOTAL_SLOTS then trigger() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Slash command extensions (chained on top of gui.lua's interceptor)
-- ─────────────────────────────────────────────────────────────────────────────

local _baseSlash = SlashCmdList["DAILYSYNC"]
SlashCmdList["DAILYSYNC"] = function(cmd)
    local c = strtrim(cmd:lower())
    if c == "celebrate" then
        trigger()
    elseif c == "celebrate reset" or c == "celebratereset" then
        local d = addon.getData and addon.getData()
        if d then d.celebratedUntil = nil end
        print("|cFF80FFFFDailySync|r Celebration guard cleared. The next 13/13 will fire again.")
    elseif c == "celebrate status" then
        local cur = countCompletedSlots()
        print(string.format("|cFF80FFFFDailySync|r %d/%d daily slots complete.", cur, TOTAL_SLOTS))
        if alreadyCelebratedThisCycle() then
            print("  (already celebrated this cycle)")
        end
    else
        _baseSlash(cmd)
    end
end
