-- Kills of listed characters. When you, or someone in your group, land the killing blow on a
-- name from the guild list, the guild hears it in guild chat:
--     [KOS] Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap.
-- Every copy of the addon counts how many times each name has been killed, and by whom.
-- Kills of names that are only on your own list are counted too, but never told to anyone.
--
-- WoW Forever has no combat log for addons. PARTY_KILL takes its place: it fires when you or
-- a party member lands a killing blow, with the GUIDs of both. The game keeps the identity of
-- player characters readable in the open world. In battlegrounds and arenas the GUIDs can be
-- secret (see ns.Plain), and those kills aren't counted.
local _, ns = ...

local Kills = {}
ns.Kills = Kills

local GUILD_CHAT_TAG = "[KOS] "
local STAND_IN_DELAY_MIN = 2 -- seconds; a group member's kill is told for them after this wait,
local STAND_IN_DELAY_MAX = 5 -- unless their own copy of the addon got there first
local SAME_KILL_SECONDS = 30 -- reports of one name's death this close together are one kill

local lastKillAt = {} -- key -> GetTime() of the last kill counted for that name

-- A player character's name and realm (nil for your own realm) from a GUID, or nil when the
-- GUID is secret, isn't a player's, or the game doesn't know that player.
local function PlayerNameFromGUID(guid)
    guid = ns.Plain(guid)
    if type(guid) ~= "string" or not guid:find("^Player%-") then return nil end
    local ok, _, _, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
    name, realm = ns.Plain(name), ns.Plain(realm)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    if realm == "" then realm = nil end
    return name, realm
end

-- The group member whose pet has this GUID, or nil.
local function GroupPetOwner(petGUID)
    local unitPrefix, memberCount = "party", GetNumSubgroupMembers()
    if IsInRaid() then unitPrefix, memberCount = "raid", GetNumGroupMembers() end
    for index = 1, memberCount do
        local member = unitPrefix .. index
        if ns.Plain(UnitGUID(member .. "pet")) == petGUID then return ns.Plain(UnitName(member)) end
    end
    return nil
end

-- Who gets the kill, and whether that's you. A pet's killing blow counts for its owner.
local function KillerFromGUID(attackerGUID)
    local guid = ns.Plain(attackerGUID)
    if type(guid) ~= "string" then return nil end
    if guid == UnitGUID("player") or guid == UnitGUID("pet") then return UnitName("player"), true end
    local killerName = PlayerNameFromGUID(guid)
    if killerName then return killerName, false end
    return GroupPetOwner(guid), false
end

-- Counts one kill of `key`. The reported counts are the totals the copy that told us had, so
-- a copy that was offline for earlier kills catches up. Returns the name's new total, or nil
-- when this kill was already counted (two copies told the guild about it).
local function CountKill(key, killerName, place, reportedCount, reportedKillerCount)
    local now = GetTime()
    if lastKillAt[key] and now - lastKillAt[key] < SAME_KILL_SECONDS then return nil end
    lastKillAt[key] = now

    local record = ns.db.kills[key] or { count = 0 }
    record.count = math.max(record.count + 1, tonumber(reportedCount) or 0)
    record.lastAt = GetServerTime()
    record.lastBy = killerName
    record.lastPlace = place
    ns.db.kills[key] = record

    local killerCount = (ns.db.killerCounts[killerName] or 0) + 1
    ns.db.killerCounts[killerName] = math.max(killerCount, tonumber(reportedKillerCount) or 0)
    ns:Fire("KOS_KILLED", key)
    return record.count
end

local function TimesText(count)
    if count == 1 then return "1 gang" end
    return ("%d ganger"):format(count)
end

-- "Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap."
function Kills.Text(victimName, killerName, place, count)
    local placeText = place ~= "" and (" i " .. place) or ""
    return ("%s drepte %s%s! %s er tatt %s. %s har %d KOS-drap."):format(
        killerName, victimName, placeText, victimName, TimesText(count),
        killerName, ns.db.killerCounts[killerName] or 1)
end

-- Guild chat can't carry color codes, so the line goes as plain text. Returns whether it went.
local function PostInGuildChat(text)
    if not IsInGuild() or ns.Share.IsChatLockedDown() then return false end
    local sendChatMessage = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    return (pcall(sendChatMessage, GUILD_CHAT_TAG .. text, "GUILD"))
end

-- Counts a kill this copy saw and tells the guild about it.
local function TellKill(entry, killerName, victimName, victimRealm)
    local place = ns.CurrentPlace()
    local count = CountKill(entry.key, killerName, place)
    if not count then return end
    ns.NoteLastSeen(entry.key, place, killerName)
    local text = Kills.Text(entry.name, killerName, place, count)
    if not entry.inGuildList then
        ns:Print(text)
        return
    end
    local isPosted = ns.settings.announceKills and PostInGuildChat(text) or false
    if not isPosted then ns:Print(text) end
    ns.Share.AnnounceKill(victimName, victimRealm, killerName, place, count, ns.db.killerCounts[killerName], isPosted)
end

-- A group member's kill: their copy of the addon tells the guild if they have one. If nobody
-- has after a few seconds, this copy does (CountKill skips it when someone did).
local function TellKillLater(entry, killerName, victimName, victimRealm)
    C_Timer.After(math.random(STAND_IN_DELAY_MIN, STAND_IN_DELAY_MAX), function()
        TellKill(entry, killerName, victimName, victimRealm)
    end)
end

-- A kill another guild member's copy told us about (see Share.lua).
function Kills.TakeReport(entry, killerName, place, reportedCount, reportedKillerCount, wasPostedInChat)
    local count = CountKill(entry.key, killerName, place, reportedCount, reportedKillerCount)
    if not count then return end
    ns.NoteLastSeen(entry.key, place, killerName)
    if wasPostedInChat or not ns.settings.showGuildReports then return end
    ns:Print(Kills.Text(entry.name, killerName, place, count))
end

-- The guild members with the most KOS kills: { { name, count }, ... }, most first.
function Kills.TopKillers(limit)
    local killers = {}
    for killerName, count in pairs(ns.db.killerCounts) do
        table.insert(killers, { name = killerName, count = count })
    end
    table.sort(killers, function(first, second)
        if first.count ~= second.count then return first.count > second.count end
        return first.name < second.name
    end)
    for index = #killers, limit + 1, -1 do
        killers[index] = nil
    end
    return killers
end

ns:On("PARTY_KILL", function(attackerGUID, targetGUID)
    if not ns.db then return end
    local victimName, victimRealm = PlayerNameFromGUID(targetGUID)
    if not victimName then return end
    local entry = ns.FindEntry(victimName, victimRealm)
    if not entry then return end
    local killerName, isMyKill = KillerFromGUID(attackerGUID)
    if not killerName then return end
    if isMyKill then
        TellKill(entry, killerName, victimName, victimRealm)
    else
        TellKillLater(entry, killerName, victimName, victimRealm)
    end
end)
