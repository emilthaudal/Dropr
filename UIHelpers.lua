-- Dropr — UIHelpers.lua
-- Native WoW UI helper module replacing AbstractFramework (GPL-3.0).
-- Exposes a DroprUIH global table consumed by UI.lua.

local UIH = {}
_G.DroprUIH = UIH

-- ---------------------------------------------------------------------------
-- Constants / palette
-- ---------------------------------------------------------------------------

local COLORS = {
    white  = { 1,    1,    1,    1 },
    gray   = { 0.65, 0.65, 0.65, 1 },
    accent = { 0.45, 0.45, 0.95, 1 },
    lime   = { 0.55, 1,    0.20, 1 },
    gold   = { 1,    0.82, 0,    1 },
    -- button tints
    green  = { 0.20, 0.75, 0.20, 1 },
    red    = { 0.85, 0.20, 0.20, 1 },
    blue   = { 0.20, 0.50, 0.90, 1 },
}

local BG_DARK    = { 0.08, 0.08, 0.08, 0.95 }  -- window body background
local BG_HEADER  = { 0.12, 0.12, 0.12, 1.00 }  -- header bar background
local BG_ACCENT  = { 0.45, 0.45, 0.95, 1.00 }  -- 2px accent stripe at top
local EDGE_COLOR = { 0.05, 0.05, 0.05, 1.00 }  -- 1px border

local HEADER_H   = 24   -- header bar height in pixels

-- ---------------------------------------------------------------------------
-- Internal: apply a WHITE8x8 backdrop (BackdropTemplate required)
-- ---------------------------------------------------------------------------

local function ApplyBackdrop(frame, bgR, bgG, bgB, bgA, edgeR, edgeG, edgeB, edgeA, edgeSize)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = edgeSize or 1,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(bgR, bgG, bgB, bgA)
    frame:SetBackdropBorderColor(edgeR or 0.05, edgeG or 0.05, edgeB or 0.05, edgeA or 1)
end

-- ---------------------------------------------------------------------------
-- UIH.UIParent — alias
-- ---------------------------------------------------------------------------

UIH.UIParent = UIParent

-- ---------------------------------------------------------------------------
-- UIH.CreateStyledFrame(parent, name, title, w, h)
--   Creates a movable window frame:
--     • Window body (w × h) with dark backdrop + 1px border
--     • 2px accent stripe at very top
--     • HEADER_H px header bar (darker) with title FontString
--     • Header bar is the drag handle
--     • Escape key closes the frame via UISpecialFrames
--   Returns: the body frame (same as the window; header is a child)
-- ---------------------------------------------------------------------------

function UIH.CreateStyledFrame(parent, name, title, w, h)
    -- Outer window frame
    local f = CreateFrame("Frame", name, parent, "BackdropTemplate")
    f:SetSize(w, h)
    ApplyBackdrop(f,
        BG_DARK[1], BG_DARK[2], BG_DARK[3], BG_DARK[4],
        EDGE_COLOR[1], EDGE_COLOR[2], EDGE_COLOR[3], EDGE_COLOR[4]
    )
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)

    -- 2px accent stripe at the very top
    local stripe = f:CreateTexture(nil, "OVERLAY")
    stripe:SetHeight(2)
    stripe:SetColorTexture(BG_ACCENT[1], BG_ACCENT[2], BG_ACCENT[3], BG_ACCENT[4])
    stripe:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
    stripe:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)

    -- Header bar
    local header = CreateFrame("Frame", nil, f, "BackdropTemplate")
    header:SetHeight(HEADER_H)
    header:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, -2)  -- sit below the 2px stripe
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -2)
    ApplyBackdrop(header,
        BG_HEADER[1], BG_HEADER[2], BG_HEADER[3], BG_HEADER[4],
        EDGE_COLOR[1], EDGE_COLOR[2], EDGE_COLOR[3], EDGE_COLOR[4]
    )
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    -- Title label inside header
    local titleFs = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFs:SetPoint("LEFT", header, "LEFT", 8, 0)
    titleFs:SetText(title or "")
    f.titleText = titleFs

    -- Escape closes
    tinsert(UISpecialFrames, name or "")

    f.header = header
    return f
end

-- ---------------------------------------------------------------------------
-- UIH.CreateFontString(parent, template, colorKey)
--   template: "GameFontNormal" | "GameFontHighlightSmall" | "GameFontNormalLarge"
--             (or any stock font template string)
--   colorKey: key into COLORS table, e.g. "white", "gray", "accent", "lime"
-- ---------------------------------------------------------------------------

function UIH.CreateFontString(parent, template, colorKey)
    local tmpl = template
    if not tmpl or tmpl == "" then
        tmpl = "GameFontNormal"
    end
    local fs = parent:CreateFontString(nil, "OVERLAY", tmpl)
    local c = colorKey and COLORS[colorKey]
    if c then
        fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    end
    return fs
end

-- ---------------------------------------------------------------------------
-- UIH.CreateButton(parent, text, w, h, colorKey)
--   colorKey: "green" | "red" | "blue" | "gray"
--   Returns a Button frame with hover and click behaviour.
-- ---------------------------------------------------------------------------

function UIH.CreateButton(parent, text, w, h, colorKey)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 80, h or 24)

    local baseColor = colorKey and COLORS[colorKey] or COLORS.gray
    local r, g, b = baseColor[1], baseColor[2], baseColor[3]

    ApplyBackdrop(btn, r * 0.4, g * 0.4, b * 0.4, 0.9,
        r * 0.7, g * 0.7, b * 0.7, 1)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    fs:SetText(text or "")
    fs:SetTextColor(r, g, b, 1)
    btn:SetFontString(fs)

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(r * 0.65, g * 0.65, b * 0.65, 1)
        self:SetBackdropBorderColor(r, g, b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(r * 0.4, g * 0.4, b * 0.4, 0.9)
        self:SetBackdropBorderColor(r * 0.7, g * 0.7, b * 0.7, 1)
    end)
    btn:SetScript("OnMouseDown", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)

    return btn
end

-- ---------------------------------------------------------------------------
-- UIH.CreateScrollEditBox(parent, w, h)
--   Returns a table with .eb (the inner EditBox) and the outer ScrollFrame as
--   the root frame. The returned table is the outer ScrollFrame; .eb is the
--   inner EditBox, matching the AF.CreateScrollEditBox interface used in UI.lua.
-- ---------------------------------------------------------------------------

function UIH.CreateScrollEditBox(parent, w, h)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(w or 300, h or 120)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetMaxLetters(0)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(w or 300)

    -- UIPanelScrollFrameTemplate uses a ScrollBar that takes ~18px on the right;
    -- make the editbox slightly narrower so text doesn't hide under the bar.
    editBox:SetWidth((w or 300) - 18)

    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnEnterPressed",  function(self) self:Insert("\n") end)
    editBox:SetScript("OnTextChanged", function(self)
        scrollFrame:UpdateScrollChildRect()
    end)

    scrollFrame:SetScrollChild(editBox)

    -- Attach .eb directly to the scrollFrame userdata so callers can do both
    -- scrollEB:SetPoint(...) (native WoW frame call) and scrollEB.eb:GetText().
    -- Returning a plain Lua table with __index=scrollFrame would cause
    -- "Wrong object type for function" because WoW's C API rejects metatables.
    scrollFrame.eb = editBox
    return scrollFrame
end

-- ---------------------------------------------------------------------------
-- UIH.CreateMover(frame, key, label, callback)
--   Makes `frame` draggable via its header child, and calls
--   callback(point, x, y) on DragStop for position persistence.
--   `key` and `label` are unused (kept for API parity with AF.CreateMover).
-- ---------------------------------------------------------------------------

function UIH.CreateMover(frame, key, label, callback)
    -- Use the header child as the drag handle if present; otherwise the frame itself.
    local handle = frame.header or frame
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        if callback then
            local point, _, _, x, y = frame:GetPoint()
            callback(point, x, y)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- UIH.SetPoint(frame, anchor)
--   Thin wrapper: clear all points then SetPoint to the given anchor string.
--   anchor defaults to "CENTER".
-- ---------------------------------------------------------------------------

function UIH.SetPoint(frame, anchor)
    frame:ClearAllPoints()
    frame:SetPoint(anchor or "CENTER", UIParent, anchor or "CENTER", 0, 0)
end

-- ---------------------------------------------------------------------------
-- UIH.ApplyCombatProtection(frame)
--   Disables mouse interaction on the frame while in combat so players
--   cannot accidentally move frames during combat.
-- ---------------------------------------------------------------------------

function UIH.ApplyCombatProtection(frame)
    local protFrame = CreateFrame("Frame")
    protFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    protFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    protFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            frame:EnableMouse(false)
        else
            frame:EnableMouse(true)
        end
    end)
end
