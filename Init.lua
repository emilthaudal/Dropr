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
--       items = {              Top 3 items by DPS gain
--         { id, name, slot, dpsGain, boss, icon },
--         ...
--       }
--     },
--   framePos   = table,        Saved mover position { point, x, y }
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
