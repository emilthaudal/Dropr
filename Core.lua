-- Dropr — Core.lua
-- Import parsing, slash commands, event registration

-- NOTE: _G.json is NOT captured at load time — rxi/json.lua may not be
-- registered yet. Always look it up lazily inside functions that need it.

-- ---------------------------------------------------------------------------
-- WoW instanceID → Raidbots instanceId mapping
-- WoW's GetInstanceInfo() returns WoW-native zone IDs which differ from
-- Raidbots' own instanceId system used in the import payload.
-- Run `/run print(select(8, GetInstanceInfo()))` in-game to find new IDs.
-- ---------------------------------------------------------------------------

DROPR_INSTANCE_MAP = {
    -- Current M+ pool (Midnight Season 1)
    [2526] = "1201",  -- Algeth'ar Academy
    [658]  = "278",   -- Pit of Saron
    [1753] = "945",   -- Seat of the Triumvirate
    [1209] = "476",   -- Skyreach
    -- New Midnight dungeons — WoW IDs TBD in-game; add as discovered:
    -- [????] = "1299",  -- Windrunner Spire
    -- [????] = "1300",  -- Magisters' Terrace
    -- [????] = "1315",  -- Maisara Caverns
    -- [????] = "1316",  -- Nexus-Point Xenas
    -- [????] = "1311",  -- Den of Nalorakk
    -- [????] = "1313",  -- Voidscar Arena
    -- [????] = "1309",  -- The Blinding Vale
}

-- ---------------------------------------------------------------------------
-- Base64 decode (WoW has no native base64; minimal RFC4648 implementation)
-- ---------------------------------------------------------------------------

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---@param data string Base64-encoded string
---@return string decoded
local function Base64Decode(data)
    data = data:gsub("[^" .. b64chars .. "=]", "")
    local result = {}
    local pattern = "([" .. b64chars .. "=]?)([" .. b64chars .. "=]?)([" .. b64chars .. "=]?)([" .. b64chars .. "=]?)"
    for c1, c2, c3, c4 in data:gmatch(pattern) do
        if c1 == "" then break end
        local n1 = b64chars:find(c1, 1, true) or 65
        local n2 = b64chars:find(c2, 1, true) or 65
        local n3 = (c3 == "=" or c3 == "") and 65 or (b64chars:find(c3, 1, true) or 65)
        local n4 = (c4 == "=" or c4 == "") and 65 or (b64chars:find(c4, 1, true) or 65)
        n1, n2, n3, n4 = n1 - 1, n2 - 1, n3 - 1, n4 - 1
        local b1 = ((n1 * 4) + math.floor(n2 / 16)) % 256
        local b2 = ((n2 * 16) + math.floor(n3 / 4)) % 256
        local b3 = ((n3 * 64) + n4) % 256
        result[#result + 1] = string.char(b1)
        if c3 ~= "=" then result[#result + 1] = string.char(b2) end
        if c4 ~= "=" then result[#result + 1] = string.char(b3) end
    end
    return table.concat(result)
end

-- ---------------------------------------------------------------------------
-- Import logic
-- ---------------------------------------------------------------------------

---Parse and store a base64-encoded JSON import string.
---@param str string
local function ImportData(str)
    if not str or str == "" then
        DroprPrint("Usage: /dropr import <string>")
        return
    end

    local json = _G.json
    if not json then
        DroprPrint("Import failed: json library not loaded.")
        return
    end

    local ok, decoded = pcall(Base64Decode, str)
    if not ok or not decoded then
        DroprPrint("Import failed: could not base64-decode the string.")
        return
    end

    local parseOk, data = pcall(json.decode, decoded)
    if not parseOk or type(data) ~= "table" then
        DroprPrint("Import failed: could not parse JSON. Regenerate the import string from the web tool.")
        return
    end

    if not data.dungeons or not data.char then
        DroprPrint("Import failed: invalid data format.")
        return
    end

    -- Store to SavedVariables
    DroprDB.importedAt = data.importedAt or time()
    DroprDB.char       = data.char
    DroprDB.spec       = data.spec
    DroprDB.dungeons   = data.dungeons

    local dungeonCount = 0
    for _ in pairs(data.dungeons) do dungeonCount = dungeonCount + 1 end

    DroprPrint(string.format(
        "Imported droptimizer for %s (%s) — %d dungeon(s) loaded.",
        data.char, data.spec or "unknown spec", dungeonCount
    ))

    -- Refresh UI if it exists
    if _G.DroprUI and _G.DroprUI.Refresh then
        _G.DroprUI.Refresh()
    end
    -- Broadcast updated data to group
    if _G.DroprSync then _G.DroprSync.Broadcast() end
end

-- Expose ImportData as a global so UI.lua's Confirm button can call it
_G.DroprImportData = ImportData

-- ---------------------------------------------------------------------------
-- Remove item
-- ---------------------------------------------------------------------------

---Remove a single item from a dungeon's list in DroprDB.
---Called by the UI × buttons. Exposed as a global so UI.lua can reference it.
---@param instanceId string
---@param itemId number
function DroprRemoveItem(instanceId, itemId)
    if not DroprDB.dungeons then return end
    local dungeon = DroprDB.dungeons[instanceId]
    if not dungeon or not dungeon.items then return end

    local removedName
    for i = #dungeon.items, 1, -1 do
        if dungeon.items[i].id == itemId then
            removedName = dungeon.items[i].name
            table.remove(dungeon.items, i)
            break
        end
    end

    if not removedName then return end

    -- Remove dungeon entry entirely if no items remain
    if #dungeon.items == 0 then
        DroprDB.dungeons[instanceId] = nil
    end

    DroprPrint(string.format("Removed %s from %s.", removedName, dungeon.name or instanceId))

    -- Refresh UI
    if _G.DroprUI then
        if DroprDB.dungeons and DroprDB.dungeons[instanceId] then
            _G.DroprUI.ShowDungeon(instanceId)
        else
            _G.DroprUI.Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Stale check
-- ---------------------------------------------------------------------------

local function CheckStale()
    if not DroprDB.importedAt then return end
    local ageSeconds = time() - DroprDB.importedAt
    local ageDays = math.floor(ageSeconds / 86400)
    if ageDays >= DROPR_OUTDATED_DAYS then
        -- Defer to next frame so AF is fully ready
        C_Timer.After(3, function()
            if _G.AbstractFramework and _G.AbstractFramework.ShowNotificationPopup then
                local AF = _G.AbstractFramework
                AF.ShowNotificationPopup(
                    string.format(
                        "|cff00ccffDropr|r: Droptimizer data is |cffff4444%d day(s) old|r.\nRe-import from the web tool for fresh recommendations.",
                        ageDays
                    ),
                    12
                )
            else
                DroprPrint(string.format("Your droptimizer data is %d day(s) old. Consider re-importing.", ageDays))
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Zone detection
-- ---------------------------------------------------------------------------

---Returns the Raidbots instanceId string if the player is inside a tracked
---dungeon, or nil if not. Translates WoW's native instanceID via DROPR_INSTANCE_MAP.
---@return string|nil raidbotsInstanceId
local function GetCurrentDungeonId()
    if not DroprDB.dungeons then return nil end
    local _, _, _, _, _, _, _, wowInstanceId = GetInstanceInfo()
    if not wowInstanceId or wowInstanceId == 0 then return nil end

    -- Translate WoW instanceID → Raidbots instanceId key
    local key = DROPR_INSTANCE_MAP[wowInstanceId]
    -- Fallback: try raw tostring in case it was stored directly (future-proof)
    if not key then key = tostring(wowInstanceId) end

    if DroprDB.dungeons[key] then
        return key
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Event frame
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == DROPR_ADDON_NAME then
            DroprDB = DroprDB or {}
            -- Verify json library loaded correctly. If not, the vendored
            -- Libs/json.lua/json.lua is missing or stale in the WoW AddOns folder.
            if not _G.json then
                C_Timer.After(2, function()
                    DroprPrint("|cffff4444WARNING:|r json library not found. Import will fail.")
                    DroprPrint("Reinstall the addon — ensure the Libs/ folder is present.")
                end)
            end
            CheckStale()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Defer by one frame — GetInstanceInfo() may return 0 immediately on
        -- login/reload even when the player is already inside a dungeon.
        C_Timer.After(0, function()
            local dungeonId = GetCurrentDungeonId()
            if _G.DroprUI then
                if dungeonId then
                    _G.DroprUI.ShowDungeon(dungeonId)
                else
                    _G.DroprUI.Hide()
                end
            end
            -- Broadcast our data to any group members who also have Dropr
            if _G.DroprSync then _G.DroprSync.Broadcast() end
        end)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        local dungeonId = GetCurrentDungeonId()
        if _G.DroprUI then
            if dungeonId then
                _G.DroprUI.ShowDungeon(dungeonId)
            else
                _G.DroprUI.Hide()
            end
        end
        if _G.DroprSync then _G.DroprSync.Broadcast() end
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_DROPR1 = "/dropr"

SlashCmdList["DROPR"] = function(msg)
    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" then
        -- No subcommand: open the main GUI
        if _G.DroprUI and _G.DroprUI.OpenMain then
            _G.DroprUI.OpenMain()
        end

    elseif cmd == "import" then
        if rest and rest ~= "" then
            -- Direct inline import (scripting / macro use)
            ImportData(rest)
        else
            -- No argument: open the paste window
            if _G.DroprUI and _G.DroprUI.OpenImport then
                _G.DroprUI.OpenImport()
            else
                DroprPrint("UI not ready. Try again after fully loading.")
            end
        end

    elseif cmd == "clear" then
        DroprDB.importedAt = nil
        DroprDB.char       = nil
        DroprDB.spec       = nil
        DroprDB.dungeons   = nil
        if _G.DroprUI then _G.DroprUI.Hide() end
        DroprPrint("Droptimizer data cleared.")

    elseif cmd == "show" then
        if not DroprDB.dungeons then
            DroprPrint("No data imported. Use /dropr import <string>.")
            return
        end
        local dungeonId = GetCurrentDungeonId()
        if _G.DroprUI then
            if dungeonId then
                _G.DroprUI.ShowDungeon(dungeonId)
            else
                -- Fallback: show dungeon with highest top-item dpsGain
                local bestId, bestGain
                for k, v in pairs(DroprDB.dungeons) do
                    local gain = v.items and v.items[1] and v.items[1].dpsGain or 0
                    if not bestGain or gain > bestGain then
                        bestId, bestGain = k, gain
                    end
                end
                if bestId then _G.DroprUI.ShowDungeon(bestId) end
            end
        end

    elseif cmd == "sync" then
        if _G.DroprSync then
            _G.DroprSync.Broadcast()
            DroprPrint("Droptimizer data broadcast to group.")
        else
            DroprPrint("Sync module not loaded.")
        end

    else
        DroprPrint("Commands:")
        DroprPrint("  /dropr                  — Open main GUI")
        DroprPrint("  /dropr import           — Open import window")
        DroprPrint("  /dropr show             — Show the zone reminder frame")
        DroprPrint("  /dropr sync             — Broadcast your data to group")
        DroprPrint("  /dropr clear            — Clear imported data")
        DroprPrint("Tip: Click the [x] button on any item row to remove it.")
    end
end
