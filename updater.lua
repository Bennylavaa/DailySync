local addonName, addon = ...

local PREFIX        = "DSYNC"
local OWNER         = "Beckylava"
local UPDATE_URL    = "https://www.curseforge.com/wow/addons/dailysync"

addon.updateOwner = OWNER

local localVerNum   = 0
local localVerStr   = ""
local updateShown   = false
local partyVersions = {}
local manualPings   = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function parseVersion(verStr)
    if not verStr then return 0 end
    local major, minor, fix = verStr:match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then return 0 end
    fix = (fix and fix ~= "") and tonumber(fix) or 0
    return (tonumber(major) or 0) * 10000 + (tonumber(minor) or 0) * 100 + fix
end

local function formatVersion(num)
    local major = math.floor(num / 10000)
    local minor = math.floor((num % 10000) / 100)
    local fix   = num % 100
    return major .. "." .. minor .. "." .. fix
end

local function stripRealm(name)
    if name and name:find("-") then
        return name:match("^([^-]+)")
    end
    return name
end

local function dbg(...)
    if addon.DS and addon.DS.debug then
        print("|cFF80FFFFDailySync|r [updater]", ...)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Frame UI labels (owner-only)
-- ─────────────────────────────────────────────────────────────────────────────

local function makeLabel(name, frame, point, relPoint, x, y)
    local label = _G[name]
    if not label then
        label = frame:CreateFontString(name, "OVERLAY", "GameFontNormalSmall")
        label:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        label:SetPoint(point, frame, relPoint, x, y)
    end
    return label
end

local function UpdatePlayerLabel()
    if UnitName("player") ~= OWNER then return end
    local frame = _G["ElvUF_PartyGroup1UnitButton1"] or _G["ElvUF_Player"] or _G["PlayerFrame"]
    if not frame then return end
    local label = makeLabel("DSSyncVersionLabelPlayer", frame, "TOPRIGHT", "TOPRIGHT", 0, 15)
    label:SetText("v" .. formatVersion(localVerNum))
    label:SetTextColor(0.4, 1, 1)
    label:Show()
end

local function UpdatePartyLabels()
    if UnitName("player") ~= OWNER then return end
    for i = 1, GetNumGroupMembers() - 1 do
        local memberName = UnitName("party" .. i)
        local ver = memberName and (partyVersions[memberName] or partyVersions[stripRealm(memberName)])
        if ver then
            local frame = _G["ElvUF_PartyGroup1UnitButton" .. (i + 1)] or _G["PartyMemberFrame" .. i]
            if frame then
                local label = makeLabel("DSSyncVersionLabel" .. i, frame, "TOPRIGHT", "TOPRIGHT", 0, 15)
                label:SetText("v" .. formatVersion(ver))
                label:SetTextColor(0.4, 1, 1)
                label:Show()
            end
        end
    end
end

local function UpdateTargetLabel()
    if UnitName("player") ~= OWNER then return end
    if not UnitExists("target") then
        local label = _G["DSSyncVersionLabelTarget"]
        if label then label:Hide() end
        return
    end
    local targetName = UnitName("target")
    if not targetName then return end
    local ver = partyVersions[targetName] or partyVersions[stripRealm(targetName)]
    if ver then
        local frame = _G["ElvUF_Target"] or _G["TargetFrame"]
        if not frame then return end
        local label = makeLabel("DSSyncVersionLabelTarget", frame, "TOPLEFT", "TOPLEFT", 0, 15)
        label:SetText("v" .. formatVersion(ver))
        label:SetTextColor(0.4, 1, 1)
        label:Show()
    else
        local label = _G["DSSyncVersionLabelTarget"]
        if label then label:Hide() end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Broadcasting
-- ─────────────────────────────────────────────────────────────────────────────

local function BroadcastVersion()
    if localVerNum == 0 then return end
    local msg = "VERSION:" .. localVerNum
    if GetGuildInfo("player") then
        dbg("->", "GUILD", msg)
        C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD")
    end
    if IsInGroup() then
        local ch = IsInRaid() and "RAID" or "PARTY"
        dbg("->", ch, msg)
        C_ChatInfo.SendAddonMessage(PREFIX, msg, ch)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Exposed for DailySync.lua slash handler
-- ─────────────────────────────────────────────────────────────────────────────

function addon.pingPlayer(target)
    local stripped = stripRealm(target)
    manualPings[stripped] = true
    C_ChatInfo.SendAddonMessage(PREFIX, "PING?", "WHISPER", target)
    print("|cFF80FFFFDailySync|r Pinged " .. target .. ".")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Event frame
-- ─────────────────────────────────────────────────────────────────────────────

local updater = CreateFrame("Frame")
updater:RegisterEvent("ADDON_LOADED")
updater:RegisterEvent("CHAT_MSG_ADDON")
updater:RegisterEvent("PLAYER_ENTERING_WORLD")
updater:RegisterEvent("GROUP_JOINED")
updater:RegisterEvent("PLAYER_TARGET_CHANGED")

updater:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then return end
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        localVerStr = addon.version or GetAddOnMetadata(addonName, "Version") or "0"
        localVerNum = parseVersion(localVerStr)
        C_Timer.After(1, UpdatePlayerLabel)

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, UpdatePlayerLabel)
        C_Timer.After(10, BroadcastVersion)

    elseif event == "GROUP_JOINED" then
        BroadcastVersion()
        UpdatePartyLabels()

    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitName("player") == OWNER then
            local targetName = UnitName("target")
            if targetName and UnitIsPlayer("target") then
                C_ChatInfo.SendAddonMessage(PREFIX, "PING?", "WHISPER", targetName)
            end
        end
        UpdateTargetLabel()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...

        if prefix ~= PREFIX then return end

        local v, payload = message:match("^([^:]+):?(.*)")

        if v == "VERSION" then
            local remoteVer = tonumber(payload)
            if not remoteVer then return end
            local stripped = stripRealm(sender)
            dbg("<- VERSION from", sender, "ver", formatVersion(remoteVer))
            partyVersions[stripped] = remoteVer
            if remoteVer > localVerNum and not updateShown then
                print("|cFF80FFFFDailySync|r New version available!")
                print("Current: |cff66ccff" .. formatVersion(localVerNum)
                    .. "|r -> Available: |cff66ccff" .. formatVersion(remoteVer) .. "|r")
                print("|cff66ccff" .. UPDATE_URL .. "|r")
                updateShown = true
            end
            UpdatePartyLabels()
            UpdateTargetLabel()

        elseif v == "PING?" then
            dbg("<- PING? from", sender, "via", channel)
            if channel == "WHISPER" then
                dbg("-> PONG! to", sender)
                C_ChatInfo.SendAddonMessage(PREFIX, "PONG!:" .. localVerStr, "WHISPER", sender)
            else
                BroadcastVersion()
            end

        elseif v == "PONG!" then
            if UnitName("player") ~= OWNER then return end
            local remoteVer = parseVersion(payload)
            local stripped  = stripRealm(sender)
            dbg("<- PONG! from", sender, "ver", formatVersion(remoteVer))
            partyVersions[stripped] = remoteVer
            if manualPings[stripped] then
                print("|cffff8000" .. sender .. "|r - |cff66ccffv" .. formatVersion(remoteVer) .. "|r")
                manualPings[stripped] = nil
            end
            UpdatePartyLabels()
            UpdateTargetLabel()
        end
    end
end)
