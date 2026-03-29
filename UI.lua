-- Dropr — UI.lua
-- Native WoW UI: zone reminder frame, import window, main GUI
-- Uses DroprUIH (UIHelpers.lua) — no AbstractFramework dependency.

local UIH = _G.DroprUIH

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local FRAME_WIDTH  = 320
local LABEL_H      = 30   -- dungeon name + spec label row height in zone reminder
local ROW_HEIGHT   = 46   -- taller rows for better name/source spacing
local ROW_GAP      = 2
local PADDING      = 10
local ICON_SIZE    = 28
local BTN_SIZE     = 22   -- [x] button width

-- NOTE on UIH.CreateStyledFrame layout:
-- The header (24px) is anchored INSIDE the frame body at the top (offset -2 for stripe).
-- Content should be placed with a top offset that clears the header:
--   TOPLEFT offset y = -(HEADER_H + STRIPE_H + PADDING) where HEADER_H=24, STRIPE_H=2
-- We use PADDING (10) below the header; callers must offset by ~36px from frame TOPLEFT.

local IMPORT_W   = 440
local IMPORT_H   = 220   -- body height

local DROPR_SITE_URL = "https://dropr.thaudal.com/"

local MAIN_W     = 480
local MAIN_H     = 520   -- body height
local MAIN_ITEM_H = 44   -- item row height in main GUI scroll view

-- Height consumed by header + stripe inside the frame body
local INNER_TOP  = 28    -- 2px stripe + 24px header + 2px gap

local SLOT_LABELS = {
    head       = "Head",
    neck       = "Neck",
    shoulder   = "Shoulders",
    back       = "Back",
    chest      = "Chest",
    wrist      = "Wrists",
    hands      = "Hands",
    waist      = "Waist",
    legs       = "Legs",
    feet       = "Feet",
    finger1    = "Ring",
    finger2    = "Ring",
    trinket1   = "Trinket",
    trinket2   = "Trinket",
    main_hand  = "Main Hand",
    off_hand   = "Off Hand",
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local DroprUI = {}
_G.DroprUI = DroprUI

-- Zone reminder frame
local frame
local dungeonLabel
local specLabel
local contentFrame
local activeRows = {}
local currentInstanceId

-- Zone reminder frame: grow-only pools to avoid permanent WoW child accumulation.
-- WoW cannot destroy font strings or textures once created; we reuse them instead.
local rowPool = {
    icons    = {},  -- contentFrame:CreateTexture objects
    names    = {},  -- UIH.CreateFontString "white"
    slots    = {},  -- UIH.CreateFontString "gray"
    dpss     = {},  -- UIH.CreateFontString "lime"
    seps     = {},  -- contentFrame:CreateTexture separators
    btns     = {},  -- CreateFrame("Button") [x] buttons
}
-- Pool for the "Also: Player1, Player2" group footer in the zone reminder
local reminderGroupPool = {}  -- UIH.CreateFontString "gray"

-- Import window
local importFrame
local importEditBox

-- Main GUI
local mainFrame

-- Main GUI scroll child: grow-only pools (same reason as zone reminder pools)
-- Populated lazily in RefreshMainFrame.
local mainPool = {
    dnames     = {},   -- UIH.CreateFontString "accent"  (dungeon headers)
    counts     = {},   -- UIH.CreateFontString "gray"    (item count labels)
    icons      = {},   -- sc:CreateTexture
    nameFs     = {},   -- UIH.CreateFontString "white"   (item names)
    slotFs     = {},   -- UIH.CreateFontString "gray"    (slot · boss)
    dpsFs      = {},   -- UIH.CreateFontString "lime"    (dps gain)
    btns       = {},   -- CreateFrame("Button") [x] buttons
    rowSeps    = {},   -- sc:CreateTexture separators
    -- Group sync section pools
    grpTitle   = {},   -- UIH.CreateFontString "accent"  ("Group" heading)
    grpTitleSep= {},   -- sc:CreateTexture heading underline
    grpNames   = {},   -- UIH.CreateFontString "white"   (dungeon name per group row)
    grpAvgs    = {},   -- UIH.CreateFontString "lime"    (avg dps gain)
    grpPlayers = {},   -- UIH.CreateFontString "gray"    (player list)
    grpSeps    = {},   -- sc:CreateTexture row separators
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function FormatDpsGain(gain)
    if gain >= 1000 then
        return string.format("+%.1fk", gain / 1000)
    end
    return string.format("+%d", gain)
end

-- Get or create a pooled object.
-- creator() must return a WoW region/frame object.
local function PoolGet(pool, index, creator)
    if not pool[index] then
        pool[index] = creator()
    end
    return pool[index]
end

-- Hide all pooled objects from index `from` to the end of the pool table.
local function PoolHideFrom(pool, from)
    for i = from, #pool do
        pool[i]:Hide()
    end
end

-- Build a remove [x] button on `parent`.
-- IMPORTANT: CreateFrame("Button") has no implicit font string.
-- SetText() renders nothing unless an explicit font string child is set.
local function MakeRemoveButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(BTN_SIZE, BTN_SIZE)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    b:SetFontString(fs)
    return b
end

local function SetRemoveButtonHandlers(btn, instanceId, item)
    btn:SetText("|cffff4444[x]|r")
    btn:SetScript("OnClick", function()
        if _G.DroprRemoveItem then
            _G.DroprRemoveItem(instanceId, item.id)
        end
    end)
    btn:SetScript("OnEnter", function(self) self:SetText("|cffff6666[x]|r") end)
    btn:SetScript("OnLeave", function(self) self:SetText("|cffff4444[x]|r") end)
end

-- ---------------------------------------------------------------------------
-- Shared row renderer
-- RenderRow draws one item row using a grow-only pool set.
--   poolSet   — table with keys: icons, names, slots, dpss, btns, seps
--   idx       — 1-based pool index for this row
--   parent    — the frame these children live on
--   rowY      — Y offset from parent TOPLEFT (negative = downward)
--   rowW      — available width for name/slot text
--   iconSize  — pixel size of the icon texture
--   rowH      — total row height (used for separator placement)
--   item      — item data table {id, name, slot, ilvl, dpsGain, boss, icon, isCatalyst}
--   instanceId — string key used by DroprRemoveItem
-- Returns a row table with fields: icon, nameText, slotText, dpsText, sep, btn
-- ---------------------------------------------------------------------------
local function RenderRow(poolSet, idx, parent, rowY, rowW, iconSize, rowH, item, instanceId)
    local row = {}

    -- Icon (pooled texture)
    row.icon = PoolGet(poolSet.icons, idx, function()
        local t = parent:CreateTexture(nil, "ARTWORK")
        t:SetSize(iconSize, iconSize)
        return t
    end)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, rowY - 6)
    local iconPath = item.icon and ("Interface\\Icons\\" .. item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
    row.icon:SetTexture(iconPath)
    row.icon:Show()

    -- [x] remove button (pooled), anchored top-right
    row.btn = PoolGet(poolSet.btns, idx, function()
        return MakeRemoveButton(parent)
    end)
    row.btn:ClearAllPoints()
    row.btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PADDING, rowY - 6)
    SetRemoveButtonHandlers(row.btn, instanceId, item)
    row.btn:Show()

    -- Item name + ilvl + catalyst tag (pooled font string)
    local nameStr = item.name or "Unknown"
    if item.ilvl and item.ilvl > 0 then
        nameStr = nameStr .. " |cffaaaaaa(" .. item.ilvl .. ")|r"
    end
    if item.isCatalyst then
        nameStr = nameStr .. " |cffffaa00[C]|r"
    end
    row.nameText = PoolGet(poolSet.names, idx, function()
        local f = UIH.CreateFontString(parent, "GameFontNormal", "white")
        f:SetWidth(rowW)
        f:SetWordWrap(false)
        f:SetNonSpaceWrap(false)
        return f
    end)
    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.nameText:SetText(nameStr)
    row.nameText:Show()

    -- Slot · boss label (pooled font string), anchored below name
    local slotLabel = SLOT_LABELS[item.slot] or item.slot or ""
    row.slotText = PoolGet(poolSet.slots, idx, function()
        local f = UIH.CreateFontString(parent, "GameFontHighlightSmall", "gray")
        f:SetWidth(rowW)
        f:SetWordWrap(false)
        return f
    end)
    row.slotText:ClearAllPoints()
    row.slotText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -3)
    row.slotText:SetText(slotLabel .. " · " .. (item.boss or ""))
    row.slotText:Show()

    -- DPS gain (pooled font string), anchored below [x] button
    row.dpsText = PoolGet(poolSet.dpss, idx, function()
        return UIH.CreateFontString(parent, "GameFontNormal", "lime")
    end)
    row.dpsText:ClearAllPoints()
    row.dpsText:SetPoint("TOPRIGHT", row.btn, "BOTTOMRIGHT", 0, -3)
    row.dpsText:SetText(FormatDpsGain(item.dpsGain or 0))
    row.dpsText:Show()

    -- Row separator (pooled texture)
    row.sep = PoolGet(poolSet.seps, idx, function()
        local t = parent:CreateTexture(nil, "BACKGROUND")
        t:SetHeight(1)
        t:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        return t
    end)
    row.sep:ClearAllPoints()
    row.sep:SetPoint("BOTTOMLEFT",  parent, "TOPLEFT",  PADDING,  rowY - rowH)
    row.sep:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -PADDING, rowY - rowH)
    row.sep:Show()

    return row
end

local function ClearRows()
    for _, row in ipairs(activeRows) do
        row.icon:Hide()
        row.nameText:Hide()
        row.slotText:Hide()
        row.dpsText:Hide()
        if row.sep then row.sep:Hide() end
        if row.btn then row.btn:Hide() end
    end
    activeRows = {}
end

-- ---------------------------------------------------------------------------
-- Import window
-- ---------------------------------------------------------------------------

local function EnsureImportFrame()
    if importFrame then return end
    if not UIH then return end

    importFrame = UIH.CreateStyledFrame(
        UIParent, "DroprImportFrame",
        "|cff00ccffDropr|r — Import",
        IMPORT_W, IMPORT_H
    )
    importFrame:SetFrameLevel(300)
    importFrame:Hide()
    UIH.SetPoint(importFrame, "CENTER")
    UIH.ApplyCombatProtection(importFrame)

    -- Content starts below the header + stripe
    local contentTop = -(INNER_TOP + PADDING)

    -- Site URL label + copyable edit box
    local urlLabel = UIH.CreateFontString(importFrame, "GameFontHighlightSmall", "gray")
    urlLabel:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, contentTop)
    urlLabel:SetText("Get your import string at:")

    local urlBox = CreateFrame("EditBox", nil, importFrame, "InputBoxTemplate")
    urlBox:SetHeight(22)
    urlBox:SetPoint("TOPLEFT",  importFrame, "TOPLEFT",  PADDING + 2, contentTop - 18)
    urlBox:SetPoint("TOPRIGHT", importFrame, "TOPRIGHT", -PADDING - 2, contentTop - 18)
    urlBox:SetText(DROPR_SITE_URL)
    urlBox:SetAutoFocus(false)
    urlBox:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
    end)
    urlBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    urlBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Instruction label
    local hint = UIH.CreateFontString(importFrame, "GameFontHighlightSmall", "gray")
    hint:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, contentTop - 46)
    hint:SetPoint("RIGHT",   importFrame, "RIGHT",   -PADDING, 0)
    hint:SetText("Paste your import string below, then click Confirm.")

    -- Scrollable edit box
    local ebH = IMPORT_H - INNER_TOP - PADDING - 34 - 46 - PADDING
    local scrollEB = UIH.CreateScrollEditBox(importFrame, IMPORT_W - PADDING * 2, ebH)
    scrollEB:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, contentTop - 46 - 16)
    scrollEB:SetPoint("RIGHT",   importFrame, "RIGHT",   -PADDING, 0)
    importEditBox = scrollEB

    -- Confirm button
    local confirmBtn = UIH.CreateButton(importFrame, "Confirm", 100, 24, "green")
    confirmBtn:SetPoint("BOTTOMRIGHT", importFrame, "BOTTOMRIGHT", -PADDING, PADDING)
    confirmBtn:SetScript("OnClick", function()
        local str = scrollEB.eb:GetText()
        str = str:gsub("%s+", "")
        local didImport = str ~= "" and _G.DroprImportData ~= nil
        if didImport then
            _G.DroprImportData(str)
        end
        scrollEB.eb:SetText("")
        importFrame:Hide()
        -- Open the main window after a successful import so the user can
        -- immediately see their freshly loaded dungeon data.
        if didImport and DroprUI.OpenMain then
            DroprUI.OpenMain()
        end
    end)

    -- Cancel button
    local cancelBtn = UIH.CreateButton(importFrame, "Cancel", 80, 24, "red")
    cancelBtn:SetPoint("RIGHT", confirmBtn, "LEFT", -6, 0)
    cancelBtn:SetScript("OnClick", function()
        scrollEB.eb:SetText("")
        importFrame:Hide()
    end)
end

-- ---------------------------------------------------------------------------
-- Main GUI
-- ---------------------------------------------------------------------------

local function BuildMainFrame()
    if mainFrame then return end
    if not UIH then return end

    mainFrame = UIH.CreateStyledFrame(
        UIParent, "DroprMainFrame",
        "|cff00ccffDropr|r",
        MAIN_W, MAIN_H
    )
    mainFrame:SetFrameLevel(200)
    mainFrame:Hide()
    UIH.SetPoint(mainFrame, "CENTER")
    UIH.ApplyCombatProtection(mainFrame)

    -- Mover (uses the header as drag handle, persists position)
    UIH.CreateMover(mainFrame, "DroprMain", "Dropr Main", function(p, x, y)
        DroprDB.mainPos = { p, x, y }
    end)

    -- Top bar: char name · spec · import date (below header)
    local charLabel = UIH.CreateFontString(mainFrame, "GameFontNormal", "accent")
    charLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, -(INNER_TOP + PADDING))
    mainFrame.charLabel = charLabel

    local specLabelMain = UIH.CreateFontString(mainFrame, "GameFontHighlightSmall", "gray")
    specLabelMain:SetPoint("LEFT", charLabel, "RIGHT", 8, 0)
    mainFrame.specLabel = specLabelMain

    local dateLabel = UIH.CreateFontString(mainFrame, "GameFontHighlightSmall", "gray")
    dateLabel:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, -(INNER_TOP + PADDING))
    mainFrame.dateLabel = dateLabel

    -- Separator under top bar
    local topBarSepY = -(INNER_TOP + PADDING + 20)
    local sep = mainFrame:CreateTexture(nil, "BACKGROUND")
    sep:SetHeight(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    sep:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  PADDING,  topBarSepY)
    sep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, topBarSepY)

    -- Bottom button bar
    local importBtn = UIH.CreateButton(mainFrame, "Import", 90, 24, "blue")
    importBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", PADDING, PADDING)
    importBtn:SetScript("OnClick", function()
        mainFrame:Hide()
        DroprUI.OpenImport()
    end)

    local clearBtn = UIH.CreateButton(mainFrame, "Clear", 70, 24, "red")
    clearBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    clearBtn:SetScript("OnClick", function()
        DroprDB.importedAt = nil
        DroprDB.char       = nil
        DroprDB.spec       = nil
        DroprDB.dungeons   = nil
        if _G.DroprUI then _G.DroprUI.Hide() end
        DroprPrint("Droptimizer data cleared.")
        mainFrame:Hide()
    end)

    local closeBtn = UIH.CreateButton(mainFrame, "Close", 70, 24, "gray")
    closeBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -PADDING, PADDING)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    -- Bottom separator above buttons
    local sep2 = mainFrame:CreateTexture(nil, "BACKGROUND")
    sep2:SetHeight(1)
    sep2:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    sep2:SetPoint("BOTTOMLEFT",  mainFrame, "BOTTOMLEFT",  PADDING,  38)
    sep2:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -PADDING, 38)

    -- Scroll area (starts below top bar separator)
    local scrollTop = -(INNER_TOP + PADDING + 22)
    local scrollContainer = CreateFrame("Frame", nil, mainFrame)
    scrollContainer:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     0,  scrollTop)
    scrollContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0,   40)

    local scrollFrame = CreateFrame("ScrollFrame", "DroprMainScroll", scrollContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     scrollContainer, "TOPLEFT",      4,  -2)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", -26,  2)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(MAIN_W - 30)
    scrollFrame:SetScrollChild(scrollChild)
    mainFrame.scrollChild = scrollChild
    mainFrame.scrollFrame = scrollFrame
end

-- RefreshMainFrame rebuilds the dungeon list using grow-only pools.
-- WoW cannot destroy font strings or textures once created, so we reuse them
-- and hide any pool entries beyond what is needed this refresh.
local function RefreshMainFrame()
    if not mainFrame then return end

    -- Update header labels
    if DroprDB.char then
        mainFrame.charLabel:SetText("|cffffd700" .. DroprDB.char .. "|r")
        mainFrame.specLabel:SetText(DroprDB.spec or "")
    else
        mainFrame.charLabel:SetText("|cffaaaaaa(no data imported)|r")
        mainFrame.specLabel:SetText("")
    end

    if DroprDB.importedAt then
        -- Use calendar day boundaries, not elapsed seconds, to avoid off-by-one
        -- when the import happened late one day and the addon is opened early the next.
        local now = date("*t")
        local imp = date("*t", DroprDB.importedAt)
        local ageDays = (now.year * 365 + now.yday) - (imp.year * 365 + imp.yday)
        if ageDays <= 0 then
            mainFrame.dateLabel:SetText("imported today")
        elseif ageDays == 1 then
            mainFrame.dateLabel:SetText("imported yesterday")
        else
            mainFrame.dateLabel:SetText(ageDays .. " days ago")
        end
    else
        mainFrame.dateLabel:SetText("")
    end

    local sc = mainFrame.scrollChild
    local totalH  = 0
    local ROW_W   = MAIN_W - 30 - PADDING * 2 - ICON_SIZE - BTN_SIZE - PADDING * 2 - 6
    local DNAME_H = 24
    local SECTION_GAP = 8

    -- -----------------------------------------------------------------------
    -- Group sync section (shown only when sync data is available)
    -- -----------------------------------------------------------------------
    local GRP_ROW_H = 36   -- height of each group dungeon row
    local pGrpTitle  = 0
    local pGrpTSep   = 0
    local pGrpName   = 0
    local pGrpAvg    = 0
    local pGrpPlayer = 0
    local pGrpSep    = 0

    local groupSummary = (_G.DroprSync and _G.DroprSync.GetGroupSummary()) or {}

    if #groupSummary > 0 then
        -- Section heading: "Group"
        pGrpTitle = pGrpTitle + 1
        local grpHeading = PoolGet(mainPool.grpTitle, pGrpTitle, function()
            return UIH.CreateFontString(sc, "GameFontNormal", "accent")
        end)
        grpHeading:ClearAllPoints()
        grpHeading:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, -(totalH + PADDING))
        grpHeading:SetText("|cff00ccffGroup|r")
        grpHeading:Show()
        totalH = totalH + PADDING + DNAME_H

        -- Thin separator under heading
        pGrpTSep = pGrpTSep + 1
        local grpHSep = PoolGet(mainPool.grpTitleSep, pGrpTSep, function()
            local t = sc:CreateTexture(nil, "BACKGROUND")
            t:SetHeight(1)
            t:SetColorTexture(0.3, 0.3, 0.3, 0.6)
            return t
        end)
        grpHSep:ClearAllPoints()
        grpHSep:SetPoint("TOPLEFT",  sc, "TOPLEFT",  PADDING,  -totalH)
        grpHSep:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, -totalH)
        grpHSep:Show()
        totalH = totalH + 4

        -- One row per dungeon in group summary
        for _, entry in ipairs(groupSummary) do
            local rowY = -(totalH)

            -- Dungeon name
            pGrpName = pGrpName + 1
            local gname = PoolGet(mainPool.grpNames, pGrpName, function()
                local f = UIH.CreateFontString(sc, "GameFontNormal", "white")
                f:SetWidth(ROW_W + ICON_SIZE + 6 - 80)
                f:SetWordWrap(false)
                f:SetNonSpaceWrap(false)
                return f
            end)
            gname:ClearAllPoints()
            gname:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, rowY - 6)
            -- Look up dungeon name: personal data first, then static table, then raw ID
            local dungeonName = (DroprDB.dungeons and DroprDB.dungeons[entry.dungeonId] and
                                 DroprDB.dungeons[entry.dungeonId].name)
                                 or (DROPR_DUNGEON_NAMES and DROPR_DUNGEON_NAMES[entry.dungeonId])
                                 or entry.dungeonId
            gname:SetText(dungeonName)
            gname:Show()

            -- Avg DPS gain (right side)
            pGrpAvg = pGrpAvg + 1
            local gavg = PoolGet(mainPool.grpAvgs, pGrpAvg, function()
                return UIH.CreateFontString(sc, "GameFontNormal", "lime")
            end)
            gavg:ClearAllPoints()
            gavg:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, rowY - 6)
            gavg:SetText("avg " .. FormatDpsGain(entry.avgGain))
            gavg:Show()

            -- Player list (small gray text below dungeon name)
            pGrpPlayer = pGrpPlayer + 1
            local gplayers = PoolGet(mainPool.grpPlayers, pGrpPlayer, function()
                local f = UIH.CreateFontString(sc, "GameFontHighlightSmall", "gray")
                f:SetWidth(ROW_W + ICON_SIZE + 6 - 80)
                f:SetWordWrap(false)
                return f
            end)
            gplayers:ClearAllPoints()
            gplayers:SetPoint("TOPLEFT", gname, "BOTTOMLEFT", 0, -2)
            local playerStr = table.concat(entry.players or {}, ", ")
            if #playerStr > 40 then playerStr = playerStr:sub(1, 37) .. "..." end
            gplayers:SetText("|cffaaaaaa" .. entry.playerCount .. " player" ..
                (entry.playerCount ~= 1 and "s" or "") .. ": " .. playerStr .. "|r")
            gplayers:Show()

            -- Row separator
            pGrpSep = pGrpSep + 1
            local gsep = PoolGet(mainPool.grpSeps, pGrpSep, function()
                local t = sc:CreateTexture(nil, "BACKGROUND")
                t:SetHeight(1)
                t:SetColorTexture(0.25, 0.25, 0.25, 0.5)
                return t
            end)
            gsep:ClearAllPoints()
            gsep:SetPoint("TOPLEFT",  sc, "TOPLEFT",  PADDING,  rowY - GRP_ROW_H)
            gsep:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, rowY - GRP_ROW_H)
            gsep:Show()

            totalH = totalH + GRP_ROW_H
        end

        totalH = totalH + SECTION_GAP
    end

    -- Hide unused group pool slots
    PoolHideFrom(mainPool.grpTitle,    pGrpTitle  + 1)
    PoolHideFrom(mainPool.grpTitleSep, pGrpTSep   + 1)
    PoolHideFrom(mainPool.grpNames,    pGrpName   + 1)
    PoolHideFrom(mainPool.grpAvgs,     pGrpAvg    + 1)
    PoolHideFrom(mainPool.grpPlayers,  pGrpPlayer + 1)
    PoolHideFrom(mainPool.grpSeps,     pGrpSep    + 1)

    -- -----------------------------------------------------------------------
    -- Personal dungeon list
    -- -----------------------------------------------------------------------
    local pDname  = 0
    local pCount  = 0
    local rowIdx  = 0

    if not DroprDB.dungeons then
        PoolHideFrom(mainPool.dnames,  1)
        PoolHideFrom(mainPool.counts,  1)
        PoolHideFrom(mainPool.icons,   1)
        PoolHideFrom(mainPool.nameFs,  1)
        PoolHideFrom(mainPool.slotFs,  1)
        PoolHideFrom(mainPool.dpsFs,   1)
        PoolHideFrom(mainPool.btns,    1)
        PoolHideFrom(mainPool.rowSeps, 1)

        pDname = pDname + 1
        local empty = PoolGet(mainPool.dnames, pDname, function()
            return UIH.CreateFontString(sc, "GameFontHighlightSmall", "gray")
        end)
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, -(totalH + PADDING))
        empty:SetText("No data. Click Import to get started.")
        empty:Show()
        sc:SetHeight(totalH + 60)
        return
    end

    -- Sort dungeons by best item dpsGain descending
    local sorted = {}
    for id, dungeon in pairs(DroprDB.dungeons) do
        sorted[#sorted + 1] = { id = id, dungeon = dungeon }
    end
    table.sort(sorted, function(a, b)
        local aTop = a.dungeon.items and a.dungeon.items[1] and a.dungeon.items[1].dpsGain or 0
        local bTop = b.dungeon.items and b.dungeon.items[1] and b.dungeon.items[1].dpsGain or 0
        return aTop > bTop
    end)

    local mainPoolSet = {
        icons = mainPool.icons,
        names = mainPool.nameFs,
        slots = mainPool.slotFs,
        dpss  = mainPool.dpsFs,
        btns  = mainPool.btns,
        seps  = mainPool.rowSeps,
    }

    for _, entry in ipairs(sorted) do
        local dungeon  = entry.dungeon
        local items    = dungeon.items or {}
        local sectionY = -(totalH)

        -- Dungeon name header (pooled)
        pDname = pDname + 1
        local dname = PoolGet(mainPool.dnames, pDname, function()
            return UIH.CreateFontString(sc, "GameFontNormal", "accent")
        end)
        dname:ClearAllPoints()
        dname:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, sectionY - PADDING)
        dname:SetText("|cffffd700" .. (dungeon.name or "Unknown") .. "|r")
        dname:Show()

        -- Item count label, right-aligned on same Y as dungeon header
        pCount = pCount + 1
        local itemCount = PoolGet(mainPool.counts, pCount, function()
            return UIH.CreateFontString(sc, "GameFontHighlightSmall", "gray")
        end)
        itemCount:ClearAllPoints()
        itemCount:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, sectionY - PADDING)
        itemCount:SetText(#items .. " upgrade" .. (#items ~= 1 and "s" or ""))
        itemCount:Show()

        totalH = totalH + PADDING + DNAME_H

        for _, item in ipairs(items) do
            rowIdx = rowIdx + 1
            local rowY = -(totalH)
            RenderRow(mainPoolSet, rowIdx, sc, rowY, ROW_W, ICON_SIZE, MAIN_ITEM_H, item, entry.id)
            totalH = totalH + MAIN_ITEM_H
        end

        totalH = totalH + SECTION_GAP
    end

    -- Hide any pool entries beyond what was needed this refresh
    PoolHideFrom(mainPool.dnames,  pDname  + 1)
    PoolHideFrom(mainPool.counts,  pCount  + 1)
    PoolHideFrom(mainPool.icons,   rowIdx  + 1)
    PoolHideFrom(mainPool.nameFs,  rowIdx  + 1)
    PoolHideFrom(mainPool.slotFs,  rowIdx  + 1)
    PoolHideFrom(mainPool.dpsFs,   rowIdx  + 1)
    PoolHideFrom(mainPool.btns,    rowIdx  + 1)
    PoolHideFrom(mainPool.rowSeps, rowIdx  + 1)

    sc:SetHeight(totalH + PADDING)
end

-- ---------------------------------------------------------------------------
-- Zone reminder frame bootstrap
-- ---------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return end
    if not UIH then return end

    frame = UIH.CreateStyledFrame(UIParent, "DroprReminderFrame", "|cff00ccffDropr|r", FRAME_WIDTH, 100)
    frame:SetFrameLevel(200)
    frame:Hide()

    -- Dungeon name label (below header)
    dungeonLabel = UIH.CreateFontString(frame, "GameFontNormal", "accent")
    dungeonLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(INNER_TOP + 6))
    dungeonLabel:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)

    -- Spec label (right-aligned on same row as dungeon label)
    specLabel = UIH.CreateFontString(frame, "GameFontHighlightSmall", "gray")
    specLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -(INNER_TOP + 6))

    -- Content frame for item rows, starts below the label row
    contentFrame = CreateFrame("Frame", nil, frame)
    contentFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(INNER_TOP + LABEL_H))
    contentFrame:SetPoint("RIGHT",   frame, "RIGHT",   0, 0)

    -- Mover (persists position)
    UIH.CreateMover(frame, "Dropr", "Dropr Reminder", function(p, x, y)
        DroprDB.framePos = { p, x, y }
    end)

    -- Restore saved position
    if DroprDB.framePos then
        local pos = DroprDB.framePos
        frame:ClearAllPoints()
        frame:SetPoint(pos[1] or "CENTER", UIParent, pos[1] or "CENTER", pos[2] or 0, pos[3] or 0)
    else
        UIH.SetPoint(frame, "CENTER")
    end

    UIH.ApplyCombatProtection(frame)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function DroprUI.ShowDungeon(instanceId)
    EnsureFrame()
    if not frame then return end

    local dungeon = DroprDB.dungeons and DroprDB.dungeons[instanceId]
    if not dungeon or not dungeon.items or #dungeon.items == 0 then
        frame:Hide()
        return
    end

    currentInstanceId = instanceId
    ClearRows()

    dungeonLabel:SetText(dungeon.name or "Unknown Dungeon")
    specLabel:SetText(DroprDB.spec or "")

    local items = dungeon.items
    local n = #items

    -- Width for name/slot text: frame width minus icon, [x] button, padding
    local rowW = FRAME_WIDTH - ICON_SIZE - BTN_SIZE - PADDING * 4 - 6

    for i = 1, n do
        local offsetY = -((i - 1) * (ROW_HEIGHT + ROW_GAP))
        activeRows[i] = RenderRow(rowPool, i, contentFrame, offsetY, rowW, ICON_SIZE, ROW_HEIGHT, items[i], instanceId)
    end

    -- Group member footer: "Group: Player1, Player2" for members who have this dungeon
    local groupMembers = (_G.DroprSync and _G.DroprSync.GetMembersForDungeon(instanceId)) or {}
    local GROUP_FOOTER_H = 0
    if #groupMembers > 0 then
        GROUP_FOOTER_H = 20
        local gf = PoolGet(reminderGroupPool, 1, function()
            local f = UIH.CreateFontString(contentFrame, "GameFontHighlightSmall", "gray")
            f:SetPoint("BOTTOMLEFT", contentFrame, "BOTTOMLEFT", PADDING, PADDING)
            f:SetPoint("RIGHT", contentFrame, "RIGHT", -PADDING, 0)
            f:SetWordWrap(false)
            return f
        end)
        local names = table.concat(groupMembers, ", ")
        if #names > 38 then names = names:sub(1, 35) .. "..." end
        gf:SetText("|cffaaaaaaGroup: " .. names .. "|r")
        gf:Show()
    else
        -- Hide the footer if present
        if reminderGroupPool[1] then reminderGroupPool[1]:Hide() end
    end

    local contentH = n * (ROW_HEIGHT + ROW_GAP) + PADDING + GROUP_FOOTER_H
    local totalH   = INNER_TOP + LABEL_H + contentH

    -- Set height before Show() to avoid the one-frame layout glitch on first open
    frame:SetHeight(totalH)
    contentFrame:SetHeight(contentH)

    frame:Show()
end

function DroprUI.Hide()
    if frame then frame:Hide() end
end

function DroprUI.IsReminderShown()
    return frame ~= nil and frame:IsShown()
end

function DroprUI.Refresh()
    if currentInstanceId then
        DroprUI.ShowDungeon(currentInstanceId)
    end
end

function DroprUI.OpenImport()
    EnsureImportFrame()
    if not importFrame then return end
    importEditBox.eb:SetText("")
    importFrame:Show()
    importEditBox.eb:SetFocus()
end

function DroprUI.OpenMain()
    BuildMainFrame()
    if not mainFrame then return end

    -- Restore saved position
    if DroprDB.mainPos then
        local pos = DroprDB.mainPos
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(pos[1] or "CENTER", UIParent, pos[1] or "CENTER", pos[2] or 0, pos[3] or 0)
    end

    RefreshMainFrame()
    mainFrame:Show()
end

-- Called by Sync.lua when new group data arrives to live-update the open window.
function DroprUI.RefreshMain()
    if mainFrame and mainFrame:IsShown() then
        RefreshMainFrame()
    end
end
