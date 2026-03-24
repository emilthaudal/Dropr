-- Dropr — UI.lua
-- AbstractFramework-based UI: zone reminder frame, import window, main GUI

---@type AbstractFramework
local AF = _G.AbstractFramework

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

-- NOTE on AF.CreateHeaderedFrame layout:
-- The header (20px) is anchored ABOVE the frame body, not inside it.
-- So f:TOPLEFT is the true top of the content area.
-- Use PADDING offset from TOPLEFT for content spacing.

local IMPORT_W   = 440
local IMPORT_H   = 190   -- body height (header is above this)

local MAIN_W     = 480
local MAIN_H     = 520   -- body height
local MAIN_ITEM_H = 44   -- item row height in main GUI scroll view

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
    names    = {},  -- AF.CreateFontString "white"
    slots    = {},  -- AF.CreateFontString "gray"
    dpss     = {},  -- AF.CreateFontString "lime"
    seps     = {},  -- contentFrame:CreateTexture separators
    btns     = {},  -- CreateFrame("Button") [x] buttons
}

-- Import window
local importFrame
local importEditBox

-- Main GUI
local mainFrame

-- Main GUI scroll child: grow-only pools (same reason as zone reminder pools)
-- Populated lazily in RefreshMainFrame.
local mainPool = {
    dnames     = {},   -- AF.CreateFontString "accent"  (dungeon headers)
    counts     = {},   -- AF.CreateFontString "gray"    (item count labels)
    icons      = {},   -- sc:CreateTexture
    nameFs     = {},   -- AF.CreateFontString "white"   (item names)
    slotFs     = {},   -- AF.CreateFontString "gray"    (slot · boss)
    dpsFs      = {},   -- AF.CreateFontString "lime"    (dps gain)
    btns       = {},   -- CreateFrame("Button") [x] buttons
    rowSeps    = {},   -- sc:CreateTexture separators
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
        local f = AF.CreateFontString(parent, "", "white")
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
        local f = AF.CreateFontString(parent, "", "gray")
        f:SetWidth(rowW)
        f:SetWordWrap(false)
        return f
    end)
    row.slotText:ClearAllPoints()
    row.slotText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -3)
    row.slotText:SetText(slotLabel .. " · " .. (item.boss or ""))
    row.slotText:Show()

    -- DPS gain (pooled font string), vertically centred on the row
    row.dpsText = PoolGet(poolSet.dpss, idx, function()
        return AF.CreateFontString(parent, "", "lime")
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
    if not AF then return end

    importFrame = AF.CreateHeaderedFrame(
        AF.UIParent, "DroprImportFrame",
        "|cff00ccffDropr|r — Import",
        IMPORT_W, IMPORT_H
    )
    importFrame:SetFrameLevel(300)
    importFrame:SetTitleJustify("LEFT")
    importFrame:Hide()
    AF.SetPoint(importFrame, "CENTER")
    AF.ApplyCombatProtectionToFrame(importFrame)

    -- Instruction label
    local hint = AF.CreateFontString(importFrame, "", "gray")
    hint:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, -PADDING)
    hint:SetPoint("RIGHT",   importFrame, "RIGHT",   -PADDING, 0)
    hint:SetText("Paste your import string from dropr-web, then click Confirm.")

    -- Scrollable edit box
    local ebH = IMPORT_H - 32 - 34 - PADDING
    local scrollEB = AF.CreateScrollEditBox(importFrame, nil, nil, IMPORT_W - PADDING * 2, ebH)
    scrollEB:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, -32)
    scrollEB:SetPoint("RIGHT",   importFrame, "RIGHT",   -PADDING, 0)
    importEditBox = scrollEB

    -- Confirm button
    local confirmBtn = AF.CreateButton(importFrame, "Confirm", "green", 100, 24)
    confirmBtn:SetPoint("BOTTOMRIGHT", importFrame, "BOTTOMRIGHT", -PADDING, PADDING)
    confirmBtn:SetScript("OnClick", function()
        local str = scrollEB.eb:GetText()
        str = str:gsub("%s+", "")
        if str ~= "" and _G.DroprImportData then
            _G.DroprImportData(str)
        end
        scrollEB.eb:SetText("")
        importFrame:Hide()
    end)

    -- Cancel button
    local cancelBtn = AF.CreateButton(importFrame, "Cancel", "red", 80, 24)
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
    if not AF then return end

    mainFrame = AF.CreateHeaderedFrame(
        AF.UIParent, "DroprMainFrame",
        "|cff00ccffDropr|r",
        MAIN_W, MAIN_H
    )
    mainFrame:SetFrameLevel(200)
    mainFrame:SetTitleJustify("LEFT")
    mainFrame:Hide()
    AF.SetPoint(mainFrame, "CENTER")
    AF.ApplyCombatProtectionToFrame(mainFrame)

    -- Mover
    AF.CreateMover(mainFrame, "DroprMain", "Dropr Main", function(p, x, y)
        DroprDB.mainPos = { p, x, y }
    end)

    -- Top bar: char name · spec · import date
    local charLabel = AF.CreateFontString(mainFrame, "", "accent")
    charLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", PADDING, -PADDING)
    mainFrame.charLabel = charLabel

    local specLabelMain = AF.CreateFontString(mainFrame, "", "gray")
    specLabelMain:SetPoint("LEFT", charLabel, "RIGHT", 8, 0)
    mainFrame.specLabel = specLabelMain

    local dateLabel = AF.CreateFontString(mainFrame, "", "gray")
    dateLabel:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, -PADDING)
    mainFrame.dateLabel = dateLabel

    -- Separator under top bar
    local sep = mainFrame:CreateTexture(nil, "BACKGROUND")
    sep:SetHeight(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    sep:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  PADDING,  -30)
    sep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PADDING, -30)

    -- Bottom button bar
    local importBtn = AF.CreateButton(mainFrame, "Import", "blue", 90, 24)
    importBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", PADDING, PADDING)
    importBtn:SetScript("OnClick", function()
        mainFrame:Hide()
        DroprUI.OpenImport()
    end)

    local clearBtn = AF.CreateButton(mainFrame, "Clear", "red", 70, 24)
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

    local closeBtn = AF.CreateButton(mainFrame, "Close", "gray", 70, 24)
    closeBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -PADDING, PADDING)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    -- Bottom separator above buttons
    local sep2 = mainFrame:CreateTexture(nil, "BACKGROUND")
    sep2:SetHeight(1)
    sep2:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    sep2:SetPoint("BOTTOMLEFT",  mainFrame, "BOTTOMLEFT",  PADDING,  38)
    sep2:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -PADDING, 38)

    -- Scroll area
    local scrollContainer = CreateFrame("Frame", nil, mainFrame)
    scrollContainer:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     0,  -34)
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
        local ageDays = math.floor((time() - DroprDB.importedAt) / 86400)
        if ageDays == 0 then
            mainFrame.dateLabel:SetText("imported today")
        elseif ageDays == 1 then
            mainFrame.dateLabel:SetText("1 day ago")
        else
            mainFrame.dateLabel:SetText(ageDays .. " days ago")
        end
    else
        mainFrame.dateLabel:SetText("")
    end

    local sc = mainFrame.scrollChild
    -- Pool counters
    local pDname  = 0
    local pCount  = 0
    local pRowSep = 0  -- section-header separators (different from item row seps)

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
            return AF.CreateFontString(sc, "", "gray")
        end)
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, -PADDING)
        empty:SetText("No data. Click Import to get started.")
        empty:Show()
        sc:SetHeight(60)
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

    -- Width available for name/slot text: full row minus icon, [x] button, padding
    local ROW_W   = MAIN_W - 30 - PADDING * 2 - ICON_SIZE - BTN_SIZE - PADDING * 2 - 6
    local DNAME_H = 24
    local SECTION_GAP = 8

    -- Item row pool index (shared across all dungeons in this refresh)
    local rowIdx  = 0
    local totalH  = 0

    for _, entry in ipairs(sorted) do
        local dungeon  = entry.dungeon
        local items    = dungeon.items or {}
        local sectionY = -(totalH)

        -- Dungeon name header (pooled)
        pDname = pDname + 1
        local dname = PoolGet(mainPool.dnames, pDname, function()
            return AF.CreateFontString(sc, "", "accent")
        end)
        dname:ClearAllPoints()
        dname:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, sectionY - PADDING)
        dname:SetText("|cffffd700" .. (dungeon.name or "Unknown") .. "|r")
        dname:Show()

        -- Item count label, right-aligned on same Y as dungeon header
        pCount = pCount + 1
        local itemCount = PoolGet(mainPool.counts, pCount, function()
            return AF.CreateFontString(sc, "", "gray")
        end)
        itemCount:ClearAllPoints()
        itemCount:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, sectionY - PADDING)
        itemCount:SetText(#items .. " upgrade" .. (#items ~= 1 and "s" or ""))
        itemCount:Show()

        totalH = totalH + PADDING + DNAME_H

        -- Render each item row using the shared RenderRow function.
        -- RenderRow uses per-pool-key sub-pools from mainPool; we pass a poolSet
        -- that maps the generic keys (icons/names/slots/dpss/btns/seps) to mainPool's tables.
        local mainPoolSet = {
            icons = mainPool.icons,
            names = mainPool.nameFs,
            slots = mainPool.slotFs,
            dpss  = mainPool.dpsFs,
            btns  = mainPool.btns,
            seps  = mainPool.rowSeps,
        }

        for _, item in ipairs(items) do
            rowIdx = rowIdx + 1
            local rowY = -(totalH)
            local row = RenderRow(mainPoolSet, rowIdx, sc, rowY, ROW_W, ICON_SIZE, MAIN_ITEM_H, item, entry.id)
            -- RenderRow returns a row table but we don't need to cache it here;
            -- the pool handles reuse.
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
    if not AF then return end

    frame = AF.CreateHeaderedFrame(AF.UIParent, "DroprReminderFrame", "|cff00ccffDropr|r", FRAME_WIDTH, 100)
    frame:SetFrameLevel(200)
    frame:SetTitleJustify("LEFT")
    frame:Hide()

    -- Dungeon name label
    dungeonLabel = AF.CreateFontString(frame, "", "accent")
    dungeonLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -6)
    dungeonLabel:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)

    -- Spec label (right-aligned, overlaps dungeon label but aligned to right edge)
    specLabel = AF.CreateFontString(frame, "", "gray")
    specLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -6)

    -- Content frame for item rows, starts below the label row
    contentFrame = CreateFrame("Frame", nil, frame)
    contentFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -LABEL_H)
    contentFrame:SetPoint("RIGHT",   frame, "RIGHT",   0, 0)

    -- Mover
    AF.CreateMover(frame, "Dropr", "Dropr Reminder", function(p, x, y)
        DroprDB.framePos = { p, x, y }
    end)

    -- Restore saved position
    if DroprDB.framePos then
        local pos = DroprDB.framePos
        frame:ClearAllPoints()
        frame:SetPoint(pos[1] or "CENTER", UIParent, pos[1] or "CENTER", pos[2] or 0, pos[3] or 0)
    else
        AF.SetPoint(frame, "CENTER")
    end

    AF.ApplyCombatProtectionToFrame(frame)
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

    local contentH = n * (ROW_HEIGHT + ROW_GAP) + PADDING
    local totalH   = LABEL_H + contentH
    frame:SetHeight(totalH)
    contentFrame:SetHeight(contentH)

    for i = 1, n do
        local offsetY = -((i - 1) * (ROW_HEIGHT + ROW_GAP))
        activeRows[i] = RenderRow(rowPool, i, contentFrame, offsetY, rowW, ICON_SIZE, ROW_HEIGHT, items[i], instanceId)
    end

    frame:Show()
end

function DroprUI.Hide()
    if frame then frame:Hide() end
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
