-- Dropr — Sync.lua
-- Group sync: broadcasts per-dungeon DPS gain summaries to other Dropr users
-- in the party/raid. Aggregates received data so the main GUI can show avg
-- group gain per dungeon.
--
-- Protocol (addon message, prefix "Dropr"):
--   DROPR_V1:<charName>|<id>:<bestGain>,<id>:<bestGain>,...
--
-- "bestGain" is the highest single-item dpsGain for that dungeon (since a
-- player can only loot one item per dungeon, this is the realistic expected
-- value). The group avg shown in the UI is the mean of each player's bestGain.
--
-- Channel: "PARTY" when in a regular party, "RAID" when in a raid.
-- Messages from self are ignored (realm-suffix-safe comparison).
-- Data from players who leave the group is pruned on GROUP_ROSTER_UPDATE.

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

---Broadcast our dungeon summary to the group.
---@param silent boolean? If true, suppresses the chat confirmation message.
function DroprSync.Broadcast(silent)
    local channel = GetChannel()
    if not channel then return end                    -- not in a group
    if not DroprDB or not DroprDB.dungeons then return end  -- no data to send

    -- Build compact payload: id:bestGain pairs
    -- bestGain = highest single-item dpsGain in that dungeon
    -- (since you can only loot one item per dungeon, this is the expected value)
    local parts = {}
    for id, dungeon in pairs(DroprDB.dungeons) do
        local best = 0
        if dungeon.items then
            for _, item in ipairs(dungeon.items) do
                local g = item.dpsGain or 0
                if g > best then best = g end
            end
        end
        if best > 0 then
            parts[#parts + 1] = id .. ":" .. best
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
    if not silent then
        DroprPrint("Synced your droptimizer data to the group.")
    end
end

-- ---------------------------------------------------------------------------
-- Receive
-- ---------------------------------------------------------------------------

local function OnAddonMessage(_, prefix, message, _, sender)
    if prefix ~= SYNC_PREFIX then return end

    -- Strip realm suffix from both sender and self before comparing
    -- (cross-realm groups append "-RealmName" to sender)
    local senderShort = sender:match("^([^%-]+)") or sender
    local selfShort   = (UnitName("player") or ""):match("^([^%-]+)") or ""
    if senderShort == selfShort then return end

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

    DroprPrint(string.format("Received sync data from %s.", charName))

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

-- Public: get aggregated group summary
-- Returns a list sorted by avgGain descending:
--   { dungeonId, avgGain, playerCount, players[] }
-- Only includes dungeons present in at least one group member's data.
-- avgGain = average of each player's best single-item dpsGain for the dungeon.
-- ---------------------------------------------------------------------------

function DroprSync.GetGroupSummary()
    if not DroprDB or not DroprDB.syncData then return {} end
    if not next(DroprDB.syncData) then return {} end

    -- Accumulate best-item gains per dungeon across all players
    local totals   = {}   -- dungeonId → sum of best gains
    local counts   = {}   -- dungeonId → number of players who have it
    local players  = {}   -- dungeonId → list of char names

    local selfChar  = DroprDB.char or UnitName("player") or "?"
    local selfShort = selfChar:match("^([^%-]+)") or selfChar

    -- Include self
    if DroprDB.dungeons then
        for id, dungeon in pairs(DroprDB.dungeons) do
            local best = 0
            if dungeon.items then
                for _, item in ipairs(dungeon.items) do
                    local g = item.dpsGain or 0
                    if g > best then best = g end
                end
            end
            if best > 0 then
                totals[id]  = (totals[id]  or 0) + best
                counts[id]  = (counts[id]  or 0) + 1
                players[id] = players[id] or {}
                players[id][#players[id] + 1] = selfChar
            end
        end
    end

    -- Include group members — skip anyone whose char name matches self (dedup)
    for _, entry in pairs(DroprDB.syncData) do
        local entryShort = (entry.char or ""):match("^([^%-]+)") or (entry.char or "")
        if entryShort ~= selfShort then
            for id, gain in pairs(entry.dungeons) do
                totals[id]  = (totals[id]  or 0) + gain
                counts[id]  = (counts[id]  or 0) + 1
                players[id] = players[id] or {}
                players[id][#players[id] + 1] = entry.char or "?"
            end
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

-- Public: returns a list of char names (excluding self) who have data for
-- the given dungeonId in their syncData. Used by the zone reminder UI.
function DroprSync.GetMembersForDungeon(dungeonId)
    if not DroprDB or not DroprDB.syncData then return {} end
    local selfChar  = DroprDB.char or UnitName("player") or "?"
    local selfShort = selfChar:match("^([^%-]+)") or selfChar
    local result = {}
    for _, entry in pairs(DroprDB.syncData) do
        local entryShort = (entry.char or ""):match("^([^%-]+)") or (entry.char or "")
        if entryShort ~= selfShort and entry.dungeons and entry.dungeons[dungeonId] then
            result[#result + 1] = entry.char or "?"
        end
    end
    table.sort(result)
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
        -- Re-broadcast our own data so new members get it (silent — automatic)
        DroprSync.Broadcast(true)
        -- Refresh UI if open
        if _G.DroprUI and _G.DroprUI.RefreshMain then
            _G.DroprUI.RefreshMain()
        end
    end
end)

-- Register the addon message prefix — required in modern WoW before messages
-- can be sent or received on this prefix.
C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)
