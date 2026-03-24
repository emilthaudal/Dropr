-- Dropr — UI.lua
-- AbstractFramework-based UI: zone reminder frame, import window, main GUI

---@type AbstractFramework
local AF = _G.AbstractFramework

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local FRAME_WIDTH  = 320
local LABEL_H      = 22   -- dungeon name label row
local ROW_HEIGHT   = 38
local ROW_GAP      = 2
local PADDING      = 10
local ICON_SIZE    = 28
local BTN_SIZE     = 16   -- × button

-- NOTE on AF.CreateHeaderedFrame layout:
-- The header (20px) is anchored ABOVE the frame body, not inside it.
-- So f:TOPLEFT is the true top of the content area.
-- Use PADDING offset from TOPLEFT for content spacing.

local IMPORT_W   = 440
local IMPORT_H   = 190   -- body height (header is above this)

local MAIN_W     = 480
local MAIN_H     = 520   -- body height

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
    btns     = {},  -- CreateFrame("Button") × buttons
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

-- Build or reuse a pooled row at `index` for the zone reminder frame.
-- Uses grow-only pools so we never create unbounded permanent WoW children.
local function CreateRow(index, item, instanceId)
    local offsetY = -((index - 1) * (ROW_HEIGHT + ROW_GAP))
    local row = {}

    -- Icon (pooled texture)
    row.icon = PoolGet(rowPool.icons, index, function()
        local t = contentFrame:CreateTexture(nil, "ARTWORK")
        t:SetSize(ICON_SIZE, ICON_SIZE)
        return t
    end)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", PADDING, offsetY - 5)
    local iconPath = item.icon and ("Interface\\Icons\\" .. item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
    row.icon:SetTexture(iconPath)
    row.icon:Show()

    -- × remove button (pooled)
    -- IMPORTANT: CreateFrame("Button") has no implicit font string.
    -- SetText() renders nothing unless an explicit font string child is set.
    row.btn = PoolGet(rowPool.btns, index, function()
        local b = CreateFrame("Button", nil, contentFrame)
        b:SetSize(BTN_SIZE, BTN_SIZE)
        -- Create the required font string child for SetText to work
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        b:SetFontString(fs)
        return b
    end)
    row.btn:ClearAllPoints()
    row.btn:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", -PADDING, offsetY - 5)
    row.btn:SetText("|cffff4444\xC3\x97|r")
    -- Re-bind the click handler so it closes over the current item/instanceId
    row.btn:SetScript("OnClick", function()
        if _G.DroprRemoveItem then
            _G.DroprRemoveItem(instanceId, item.id)
        end
    end)
    row.btn:SetScript("OnEnter", function(self) self:SetText("|cffff6666\xC3\x97|r") end)
    row.btn:SetScript("OnLeave", function(self) self:SetText("|cffff4444\xC3\x97|r") end)
    row.btn:Show()

    -- Item name (pooled font string)
    local nameWidth = FRAME_WIDTH - ICON_SIZE - BTN_SIZE - PADDING * 4
    local nameStr = item.name or "Unknown"
    if item.ilvl and item.ilvl > 0 then
        nameStr = nameStr .. " |cffaaaaaa(" .. item.ilvl .. ")|r"
    end
    if item.isCatalyst then
        nameStr = nameStr .. " |cffffaa00[C]|r"
    end
    row.nameText = PoolGet(rowPool.names, index, function()
        local f = AF.CreateFontString(contentFrame, "", "white")
        f:SetWidth(nameWidth)
        f:SetWordWrap(false)
        f:SetNonSpaceWrap(false)
        return f
    end)
    row.nameText:ClearAllPoints()
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.nameText:SetText(nameStr)
    row.nameText:Show()

    -- Slot · boss label (pooled font string)
    local slotLabel = SLOT_LABELS[item.slot] or item.slot or ""
    row.slotText = PoolGet(rowPool.slots, index, function()
        local f = AF.CreateFontString(contentFrame, "", "gray")
        f:SetWidth(nameWidth)
        f:SetWordWrap(false)
        return f
    end)
    row.slotText:ClearAllPoints()
    row.slotText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 4)
    row.slotText:SetText(string.format("%s · %s", slotLabel, item.boss or ""))
    row.slotText:Show()

    -- DPS gain (pooled font string)
    row.dpsText = PoolGet(rowPool.dpss, index, function()
        return AF.CreateFontString(contentFrame, "", "lime")
    end)
    row.dpsText:ClearAllPoints()
    row.dpsText:SetPoint("TOPRIGHT", row.btn, "BOTTOMRIGHT", 0, -2)
    row.dpsText:SetText(FormatDpsGain(item.dpsGain or 0))
    row.dpsText:Show()

    -- Row separator (pooled texture)
    row.sep = PoolGet(rowPool.seps, index, function()
        local t = contentFrame:CreateTexture(nil, "BACKGROUND")
        t:SetHeight(1)
        t:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        return t
    end)
    row.sep:ClearAllPoints()
    row.sep:SetPoint("BOTTOMLEFT",  contentFrame, "TOPLEFT",  PADDING,  offsetY - ROW_HEIGHT)
    row.sep:SetPoint("BOTTOMRIGHT", contentFrame, "TOPRIGHT", -PADDING, offsetY - ROW_HEIGHT)
    row.sep:Show()

    return row
end

-- ---------------------------------------------------------------------------
-- Import window
-- ---------------------------------------------------------------------------

local function EnsureImportFrame()
    if importFrame then return end
    if not AF then return end

    importFrame = AF.CreateHeaderedFrame(
        AF.UIParent, "DroprImportFrame",
        "|cff00ccffDropr|r \xe2\x80\x94 Import",
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

    -- Scrollable edit box — fixed height, scrolls internally
    -- Height: frame body minus hint row (32px) minus button row (34px) minus padding
    local ebH = IMPORT_H - 32 - 34 - PADDING
    local scrollEB = AF.CreateScrollEditBox(importFrame, nil, nil, IMPORT_W - PADDING * 2, ebH)
    scrollEB:SetPoint("TOPLEFT", importFrame, "TOPLEFT", PADDING, -32)
    scrollEB:SetPoint("RIGHT",   importFrame, "RIGHT",   -PADDING, 0)
    -- .eb is the inner AF_EditBox; use it for GetText/SetText/SetFocus
    importEditBox = scrollEB

    -- Confirm button
    local confirmBtn = AF.CreateButton(importFrame, "Confirm", "green", 100, 24)
    confirmBtn:SetPoint("BOTTOMRIGHT", importFrame, "BOTTOMRIGHT", -PADDING, PADDING)
    confirmBtn:SetScript("OnClick", function()
        local str = scrollEB.eb:GetText()
        str = str:gsub("%s+", "")   -- strip any accidental whitespace/newlines
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

    -- Mover so the window can be repositioned
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

    -- Scroll area for dungeon list
    -- Content area: top of frame body + header row (32px) to above button bar (38px)
    local scrollContainer = CreateFrame("Frame", nil, mainFrame)
    scrollContainer:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     0,       -34)
    scrollContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0,        40)

    local scrollFrame = CreateFrame("ScrollFrame", "DroprMainScroll", scrollContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     scrollContainer, "TOPLEFT",     4,  -2)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", -26, 2)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(MAIN_W - 30)
    scrollFrame:SetScrollChild(scrollChild)
    mainFrame.scrollChild = scrollChild
    mainFrame.scrollFrame = scrollFrame
end

-- RefreshMainFrame rebuilds the dungeon list using grow-only pools.
-- WoW cannot destroy font strings or textures once created, so we reuse them
-- (update text/texture, reposition) and hide any pool entries beyond what is needed.
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

    -- Counters into each pool — we reuse pool[i] if it exists, create if not
    local pDname  = 0
    local pCount  = 0
    local pIcon   = 0
    local pNameF  = 0
    local pSlotF  = 0
    local pDpsF   = 0
    local pRowSep = 0

    if not DroprDB.dungeons then
        -- Hide every pooled object and show an empty-state message
        PoolHideFrom(mainPool.dnames,  1)
        PoolHideFrom(mainPool.counts,  1)
        PoolHideFrom(mainPool.icons,   1)
        PoolHideFrom(mainPool.nameFs,  1)
        PoolHideFrom(mainPool.slotFs,  1)
        PoolHideFrom(mainPool.dpsFs,   1)
        PoolHideFrom(mainPool.rowSeps, 1)

        -- Reuse or create a single "no data" label
        pDname = pDname + 1
        local empty = PoolGet(mainPool.dnames, pDname, function()
            local f = AF.CreateFontString(sc, "", "gray")
            return f
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

    local ROW_W       = MAIN_W - 30 - PADDING * 2
    local DNAME_H     = 24
    local ITEM_H      = 40   -- enough room for two text lines + icon
    local SECTION_GAP = 8
    local totalH      = 0

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

        -- Item count label (pooled) — anchor TOPRIGHT of scroll child, vertically aligned with dname
        pCount = pCount + 1
        local itemCount = PoolGet(mainPool.counts, pCount, function()
            return AF.CreateFontString(sc, "", "gray")
        end)
        itemCount:ClearAllPoints()
        itemCount:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, sectionY - PADDING)
        itemCount:SetText(#items .. " upgrade" .. (#items ~= 1 and "s" or ""))
        itemCount:Show()

        totalH = totalH + PADDING + DNAME_H

        for _, item in ipairs(items) do
            local rowY = -(totalH)

            -- Icon (pooled)
            pIcon = pIcon + 1
            local icon = PoolGet(mainPool.icons, pIcon, function()
                local t = sc:CreateTexture(nil, "ARTWORK")
                t:SetSize(22, 22)
                return t
            end)
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING, rowY - 5)
            local iconPath = item.icon and ("Interface\\Icons\\" .. item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
            icon:SetTexture(iconPath)
            icon:Show()

            -- Name + ilvl (pooled)
            local nameStr = item.name or "Unknown"
            if item.ilvl and item.ilvl > 0 then
                nameStr = nameStr .. " |cffaaaaaa(" .. item.ilvl .. ")|r"
            end
            if item.isCatalyst then
                nameStr = nameStr .. " |cffffaa00[C]|r"
            end
            pNameF = pNameF + 1
            local nameF = PoolGet(mainPool.nameFs, pNameF, function()
                local f = AF.CreateFontString(sc, "", "white")
                f:SetWidth(ROW_W - 90)
                f:SetWordWrap(false)
                f:SetNonSpaceWrap(false)
                return f
            end)
            nameF:ClearAllPoints()
            nameF:SetPoint("TOPLEFT", sc, "TOPLEFT", PADDING + 26, rowY - 4)
            nameF:SetText(nameStr)
            nameF:Show()

            -- Slot · Boss — anchor to nameF bottom for correct vertical placement (dr-six)
            local slotLabel = SLOT_LABELS[item.slot] or item.slot or ""
            pSlotF = pSlotF + 1
            local slotF = PoolGet(mainPool.slotFs, pSlotF, function()
                local f = AF.CreateFontString(sc, "", "gray")
                f:SetWidth(ROW_W - 90)
                f:SetWordWrap(false)
                return f
            end)
            slotF:ClearAllPoints()
            slotF:SetPoint("TOPLEFT", nameF, "BOTTOMLEFT", 0, -2)
            slotF:SetText(slotLabel .. " \xC2\xB7 " .. (item.boss or ""))
            slotF:Show()

            -- DPS gain — vertically centred in the row (dr-six)
            pDpsF = pDpsF + 1
            local dpsF = PoolGet(mainPool.dpsFs, pDpsF, function()
                return AF.CreateFontString(sc, "", "lime")
            end)
            dpsF:ClearAllPoints()
            dpsF:SetPoint("RIGHT", sc, "RIGHT",   -PADDING, 0)
            dpsF:SetPoint("TOP",   sc, "TOPLEFT",  0,       rowY - 4)
            dpsF:SetText(FormatDpsGain(item.dpsGain or 0))
            dpsF:Show()

            -- Row separator (pooled)
            pRowSep = pRowSep + 1
            local rowSep = PoolGet(mainPool.rowSeps, pRowSep, function()
                local t = sc:CreateTexture(nil, "BACKGROUND")
                t:SetHeight(1)
                t:SetColorTexture(0.25, 0.25, 0.25, 0.5)
                return t
            end)
            rowSep:ClearAllPoints()
            rowSep:SetPoint("TOPLEFT",  sc, "TOPLEFT",  PADDING,  rowY - ITEM_H)
            rowSep:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PADDING, rowY - ITEM_H)
            rowSep:Show()

            totalH = totalH + ITEM_H
        end

        totalH = totalH + SECTION_GAP
    end

    -- Hide any pool entries beyond what was needed this refresh
    PoolHideFrom(mainPool.dnames,  pDname  + 1)
    PoolHideFrom(mainPool.counts,  pCount  + 1)
    PoolHideFrom(mainPool.icons,   pIcon   + 1)
    PoolHideFrom(mainPool.nameFs,  pNameF  + 1)
    PoolHideFrom(mainPool.slotFs,  pSlotF  + 1)
    PoolHideFrom(mainPool.dpsFs,   pDpsF   + 1)
    PoolHideFrom(mainPool.rowSeps, pRowSep + 1)

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

    -- Spec label (right-aligned)
    specLabel = AF.CreateFontString(frame, "", "gray")
    specLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -6)

    -- Content frame for item rows
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

    local contentH = n * (ROW_HEIGHT + ROW_GAP) + PADDING
    local totalH   = LABEL_H + contentH
    frame:SetHeight(totalH)
    contentFrame:SetHeight(contentH)

    for i = 1, n do
        activeRows[i] = CreateRow(i, items[i], instanceId)
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
    -- Use .eb to access the inner edit box (dr-qn8)
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
