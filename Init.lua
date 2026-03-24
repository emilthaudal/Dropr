-- Dropr — Init.lua
-- SavedVariables schema and constants

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

DROPR_OUTDATED_DAYS = 7

DROPR_ADDON_NAME = "Dropr"
DROPR_PRINT_PREFIX = "|cff00ccffDropr|r: "

---Print a message to the default chat frame with the Dropr prefix.
---@param msg string
local function DroprPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage(DROPR_PRINT_PREFIX .. msg)
end

_G.DroprPrint = DroprPrint
