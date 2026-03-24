-- Dropr — Sync.lua
-- Group sync: broadcasts per-dungeon DPS gain summaries to other Dropr users
-- in the party/raid. Aggregates received data so the main GUI can show avg
-- group gain per dungeon.
--
-- Protocol (addon message, prefix "Dropr"):
--   DROPR_V1:<charName>|<id>:<totalGain>,<id>:<totalGain>,...
--
-- "totalGain" is the sum of dpsGain for all items in that dungeon (a rough
-- proxy for how much the dungeon is worth to this player). Sorted descending
-- by the sender, but we re-sort on receipt.
--
-- Channel: "PARTY" when in a regular party, "RAID" when in a raid.
-- Messages from self are ignored. Data from players who leave the group is
-- pruned on GROUP_ROSTER_UPDATE.

local SYNC_PREFIX  = "Dropr"
local SYNC_VERSION = "DROPR_V1"

-- DroprSync is the public API table read by UI.lua.
local DroprSync = {}
_G.DroprSync = DroprSync

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function IsInAnyGroup()
    return IsInGroup() or IsInRaid()
end

local function GetChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Returns a set of current group member names (excluding self).
local function GetGroupMembers()
    local members = {}
    local self = UnitName("player")
    local n = GetNumGroupMembers()
    for i = 1, n do
        local unit = (IsInRaid() and "raid" or "party") .. i
        local name = UnitName(unit)
        if name and name ~= self then
            members[name] = true
        end
    end
    return members
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------

-- Broadcast our dungeon summary to the group.
-- Called on zone-in and GROUP_ROSTER_UPDATE (if we have data).
function DroprSync.Broadcast()
    local channel = GetChannel()
    if not channel then return end                    -- not in a group
    if not DroprDB or not DroprDB.dungeons then return end  -- no data to send

    -- Build compact payload: id:totalGain pairs
    local parts = {}
    for id, dungeon in pairs(DroprDB.dungeons) do
        local total = 0
        if dungeon.items then
            for _, item in ipairs(dungeon.items) do
                total = total + (item.dpsGain or 0)
            end
        end
        if total > 0 then
            parts[#parts + 1] = id .. ":" .. total
        end
    end

    if #parts == 0 then return end

    local charName = DroprDB.char or UnitName("player") or "Unknown"
    local payload  = SYNC_VERSION .. ":" .. charName .. "|" .. table.concat(parts, ",")

    -- payload should stay well under 255 bytes (8 dungeons × ~12 chars ≈ 120 bytes)
    if #payload > 250 then
        -- Truncate gracefully — keep as many dungeons as fit
        payload = payload:sub(1, 250)
    end

    C_ChatInfo.SendAddonMessage(SYNC_PREFIX, payload, channel)
end

-- ---------------------------------------------------------------------------
-- Receive
-- ---------------------------------------------------------------------------

local function OnAddonMessage(_, prefix, message, _, sender)
    if prefix ~= SYNC_PREFIX then return end

    -- Ignore our own messages
    local selfName = UnitName("player")
    if sender == selfName then return end
    -- Strip realm suffix if present (cross-realm groups)
    local senderShort = sender:match("^([^%-]+)") or sender

    -- Parse: DROPR_V1:<charName>|<id>:<gain>,...
    local version, rest = message:match("^([^:]+):(.+)$")
    if version ~= SYNC_VERSION then return end

    local charName, dungeonStr = rest:match("^([^|]+)|(.+)$")
    if not charName or not dungeonStr then return end

    local dungeons = {}
    for id, gain in dungeonStr:gmatch("([^,]+):([^,]+)") do
        local g = tonumber(gain)
        if id and g then
            dungeons[id] = g
        end
    end

    if not next(dungeons) then return end

    -- Store under the sender's short name
    DroprDB.syncData = DroprDB.syncData or {}
    DroprDB.syncData[senderShort] = {
        char       = charName,
        dungeons   = dungeons,
        receivedAt = time(),
    }

    -- Refresh the main GUI if it's open
    if _G.DroprUI and _G.DroprUI.RefreshMain then
        _G.DroprUI.RefreshMain()
    end
end

-- ---------------------------------------------------------------------------
-- Prune stale data when group roster changes
-- ---------------------------------------------------------------------------

local function PruneSyncData()
    if not DroprDB or not DroprDB.syncData then return end
    local members = GetGroupMembers()
    for name in pairs(DroprDB.syncData) do
        if not members[name] then
            DroprDB.syncData[name] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public: get aggregated group summary
-- Returns a list sorted by avgGain descending:
--   { dungeonId, avgGain, playerCount, players[] }
-- Only includes dungeons present in at least one group member's data.
-- ---------------------------------------------------------------------------

function DroprSync.GetGroupSummary()
    if not DroprDB or not DroprDB.syncData then return {} end
    if not next(DroprDB.syncData) then return {} end

    -- Accumulate totals per dungeon across all senders
    local totals   = {}   -- dungeonId → sum of gains
    local counts   = {}   -- dungeonId → number of players who have it
    local players  = {}   -- dungeonId → list of char names

    -- Also include self if we have data
    if DroprDB.dungeons then
        local selfChar = DroprDB.char or UnitName("player") or "?"
        for id, dungeon in pairs(DroprDB.dungeons) do
            local total = 0
            if dungeon.items then
                for _, item in ipairs(dungeon.items) do
                    total = total + (item.dpsGain or 0)
                end
            end
            if total > 0 then
                totals[id]  = (totals[id]  or 0) + total
                counts[id]  = (counts[id]  or 0) + 1
                players[id] = players[id] or {}
                players[id][#players[id] + 1] = selfChar
            end
        end
    end

    for _, entry in pairs(DroprDB.syncData) do
        for id, gain in pairs(entry.dungeons) do
            totals[id]  = (totals[id]  or 0) + gain
            counts[id]  = (counts[id]  or 0) + 1
            players[id] = players[id] or {}
            players[id][#players[id] + 1] = entry.char or "?"
        end
    end

    -- Build sorted result
    local result = {}
    for id, total in pairs(totals) do
        local n = counts[id]
        result[#result + 1] = {
            dungeonId    = id,
            avgGain      = math.floor(total / n),
            playerCount  = n,
            players      = players[id],
        }
    end
    table.sort(result, function(a, b) return a.avgGain > b.avgGain end)

    return result
end

-- ---------------------------------------------------------------------------
-- Event frame
-- ---------------------------------------------------------------------------

local syncFrame = CreateFrame("Frame")
syncFrame:RegisterEvent("CHAT_MSG_ADDON")
syncFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
-- PLAYER_ENTERING_WORLD broadcast is triggered from Core.lua via DroprSync.Broadcast()

syncFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(_, ...)

    elseif event == "GROUP_ROSTER_UPDATE" then
        PruneSyncData()
        -- Re-broadcast our own data so new members get it
        DroprSync.Broadcast()
        -- Refresh UI if open
        if _G.DroprUI and _G.DroprUI.RefreshMain then
            _G.DroprUI.RefreshMain()
        end
    end
end)

-- Register the addon message prefix — required in modern WoW before messages
-- can be sent or received on this prefix.
C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)
