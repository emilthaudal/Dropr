-- Dropr — UI.lua
-- AbstractFramework-based reminder frame with dynamic item rows

---@type AbstractFramework
local AF = _G.AbstractFramework

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local FRAME_WIDTH  = 320
local HEADER_H     = 46   -- AF headered frame header area
local LABEL_H      = 22   -- dungeon name label area below header
local ROW_HEIGHT   = 38
local ROW_GAP      = 2
local PADDING      = 10
local ICON_SIZE    = 28
local BTN_SIZE     = 16   -- × button

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

local frame
local dungeonLabel
local specLabel
local contentFrame
local activeRows = {}         -- currently displayed row widgets
local currentInstanceId       -- track which dungeon is shown

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function FormatDpsGain(gain)
    if gain >= 1000 then
        return string.format("+%.1fk", gain / 1000)
    end
    return string.format("+%d", gain)
end

---Hide and recycle all active rows.
local function ClearRows()
    for _, row in ipairs(activeRows) do
        row.icon:Hide()
        row.nameText:Hide()
        row.slotText:Hide()
        row.dpsText:Hide()
        row.bossText:Hide()
        if row.sep then row.sep:Hide() end
        if row.btn then row.btn:Hide() end
    end
    activeRows = {}
end

---Create one item row inside contentFrame at vertical offset `offsetY` (negative = down).
---@param index     number   1-based row index (for vertical offset calculation)
---@param item      table    DroprItem-shaped table
---@param instanceId string
---@return table row widget table
local function CreateRow(index, item, instanceId)
    local offsetY = -((index - 1) * (ROW_HEIGHT + ROW_GAP))
    local row = {}

    -- Icon
    row.icon = contentFrame:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", PADDING, offsetY - 5)
    local iconPath = item.icon and ("Interface\\Icons\\" .. item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
    row.icon:SetTexture(iconPath)

    -- × remove button (top-right of row)
    row.btn = CreateFrame("Button", nil, contentFrame)
    row.btn:SetSize(BTN_SIZE, BTN_SIZE)
    row.btn:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", -PADDING, offsetY - 5)
    row.btn:SetNormalFontObject(GameFontNormalSmall)
    row.btn:SetText("|cffff4444×|r")
    row.btn:SetScript("OnClick", function()
        if _G.DroprRemoveItem then
            _G.DroprRemoveItem(instanceId, item.id)
        end
    end)
    row.btn:SetScript("OnEnter", function(self)
        self:SetText("|cffff6666×|r")
    end)
    row.btn:SetScript("OnLeave", function(self)
        self:SetText("|cffff4444×|r")
    end)

    -- Item name (between icon and button)
    local nameWidth = FRAME_WIDTH - ICON_SIZE - BTN_SIZE - PADDING * 4
    row.nameText = AF.CreateFontString(contentFrame, "", "white")
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -2)
    row.nameText:SetWidth(nameWidth)
    row.nameText:SetWordWrap(false)
    row.nameText:SetNonSpaceWrap(false)
    row.nameText:SetText(item.name or "Unknown")

    -- Slot · Boss (second line)
    row.slotText = AF.CreateFontString(contentFrame, "", "gray")
    row.slotText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 4)
    row.slotText:SetWidth(nameWidth)
    row.slotText:SetWordWrap(false)
    local slotLabel = SLOT_LABELS[item.slot] or item.slot or ""
    row.slotText:SetText(string.format("%s · %s", slotLabel, item.boss or ""))

    -- DPS gain (right side, vertically centred in row)
    row.dpsText = AF.CreateFontString(contentFrame, "", "lime")
    row.dpsText:SetPoint("TOPRIGHT", row.btn, "BOTTOMRIGHT", 0, -2)
    row.dpsText:SetText(FormatDpsGain(item.dpsGain or 0))

    -- Separator below row
    row.sep = contentFrame:CreateTexture(nil, "BACKGROUND")
    row.sep:SetHeight(1)
    row.sep:SetColorTexture(0.3, 0.3, 0.3, 0.5)
    row.sep:SetPoint("BOTTOMLEFT", contentFrame, "TOPLEFT", PADDING, offsetY - ROW_HEIGHT)
    row.sep:SetPoint("BOTTOMRIGHT", contentFrame, "TOPRIGHT", -PADDING, offsetY - ROW_HEIGHT)

    return row
end

-- ---------------------------------------------------------------------------
-- Frame bootstrap (deferred until AF is available)
-- ---------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return end
    if not AF then return end

    -- Start with a small frame; height is set dynamically in ShowDungeon
    frame = AF.CreateHeaderedFrame(AF.UIParent, "DroprReminderFrame", "|cff00ccffDropr|r", FRAME_WIDTH, 100)
    frame:SetFrameLevel(200)
    frame:SetTitleJustify("LEFT")
    frame:Hide()

    -- Dungeon name label (top of content, below header)
    dungeonLabel = AF.CreateFontString(frame, "", "accent")
    dungeonLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -8)
    dungeonLabel:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)

    -- Spec label (right-aligned beside dungeon name)
    specLabel = AF.CreateFontString(frame, "", "gray")
    specLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -8)

    -- Content frame for item rows
    contentFrame = CreateFrame("Frame", nil, frame)
    contentFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(HEADER_H + LABEL_H))
    contentFrame:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

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

---Show the reminder frame populated with all items for the given dungeon.
---@param instanceId string
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

    -- Resize frame to fit all rows
    local contentH = n * (ROW_HEIGHT + ROW_GAP) + PADDING
    local totalH   = HEADER_H + LABEL_H + contentH
    frame:SetHeight(totalH)
    contentFrame:SetHeight(contentH)

    for i = 1, n do
        activeRows[i] = CreateRow(i, items[i], instanceId)
    end

    frame:Show()
end

---Hide the reminder frame.
function DroprUI.Hide()
    if frame then
        frame:Hide()
    end
end

---Refresh the frame with current dungeon data (called after import or remove).
function DroprUI.Refresh()
    if not frame then return end
    if currentInstanceId then
        DroprUI.ShowDungeon(currentInstanceId)
    end
end
