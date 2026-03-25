-- Dropr — Init.lua
-- SavedVariablesPerCharacter schema and constants
-- DroprDB is stored per-character (SavedVariablesPerCharacter in .toc).
-- Each character gets its own independent wishlist.

-- DroprDB schema:
-- {
--   importedAt = number,       Unix timestamp of last import
--   char       = string,       Character name
--   spec       = string,       Spec name the droptimizer was run for
--   dungeons   = table,        Keyed by instanceId (string)
--     ["1315"] = {
--       name  = string,        Dungeon display name
--       items = {              All items with >=100 DPS gain, sorted by dpsGain desc
--         { id, name, slot, ilvl, dpsGain, boss, icon, isCatalyst },
--         ...
--       }
--     },
--   framePos   = table,        Saved mover position { point, x, y }
--   mainPos    = table,        Saved main GUI mover position { point, x, y }
--   syncData   = table,        Keyed by player short name (no realm)
--     ["Jetskis"] = {
--       char       = string,   Character name as reported by sender
--       dungeons   = table,    { [dungeonId] = totalDpsGain }
--       receivedAt = number,   Unix timestamp of last receipt
--     },
-- }

DroprDB = DroprDB or {}

-- Static dungeon name lookup keyed by Raidbots instanceId (string).
-- Used as a fallback when a dungeon appears in the group sync summary but
-- the local player has no personal import data for it (so DroprDB.dungeons
-- won't have a name for it). Keep in sync with DROPR_INSTANCE_MAP in Core.lua.
DROPR_DUNGEON_NAMES = {
    -- Legacy dungeons (Midnight S1 pool)
    ["278"]  = "Pit of Saron",
    ["476"]  = "Skyreach",
    ["945"]  = "Seat of the Triumvirate",
    ["1201"] = "Algeth'ar Academy",
    -- Midnight dungeons
    ["1299"] = "Windrunner's Spire",
    ["1300"] = "Magisters' Terrace",
    ["1315"] = "Maisara Caverns",
    ["1316"] = "Nexus-Point Xenas",
}

DROPR_OUTDATED_DAYS = 7

DROPR_ADDON_NAME = "Dropr"
DROPR_PRINT_PREFIX = "|cff00ccffDropr|r: "

---Print a message to the default chat frame with the Dropr prefix.
---@param msg string
local function DroprPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage(DROPR_PRINT_PREFIX .. msg)
end

_G.DroprPrint = DroprPrint
