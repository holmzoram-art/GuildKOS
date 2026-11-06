-- Kills of listed characters. When you, or someone in your group, land the killing blow on a
-- name from the guild list, the guild hears it in guild chat:
--     [KOS] Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap.
-- Every copy of the addon counts how many times each name has been killed, and how many KOS
-- kills each guild member has. Kills of names that are only on your own list are counted for
-- that name, but never told to anyone and never added to anyone's KOS kills.
--
-- WoW Forever has no combat log for addons. PARTY_KILL takes its place: it fires when you or
-- a party member lands a killing blow, with the GUIDs of both. The game keeps the identity of
-- player characters readable in the open world. In battlegrounds and arenas the GUIDs can be
-- secret (see ns.Plain), and those kills aren't counted.
local _, ns = ...

local Kills = {}
ns.Kills = Kills

local GUILD_CHAT_TAG = "[KOS] "
local STAND_IN_FIRST = 1.5        -- seconds before the first stand-in tells a group member's kill
local STAND_IN_STEP = 1.5         -- seconds more for each stand-in ahead of you in the order
local SAME_KILL_SECONDS = 30      -- reports of one name's death this close together are one kill
local MAX_REPORTED_COUNT = 100000 -- a count from another copy above this is ignored

local lastKillAt = {}  -- key -> GetTime() of the last kill counted for that name
local lastToldAt = {}  -- key -> GetTime() when guild chat last said that name was killed

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

-- The units of your group: "player" and "party1".."party4", or "raid1".."raid40" in a raid.
local function GroupUnits()
    local units = { "player" }
    local unitPrefix, memberCount = "party", GetNumSubgroupMembers()
    if IsInRaid() then unitPrefix, memberCount = "raid", GetNumGroupMembers() end
    for index = 1, memberCount do
        table.insert(units, unitPrefix .. index)
    end
    return units
end

-- The group member whose pet has this GUID, or nil.
local function GroupPetOwner(petGUID)
    for _, unit in ipairs(GroupUnits()) do
        if ns.Plain(UnitGUID(unit .. "pet")) == petGUID then return ns.Plain(UnitName(unit)) end
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

-- A count from another copy: a whole number from 0 to MAX_REPORTED_COUNT, else 0. (tonumber
-- also reads "nan" and "inf", which would otherwise spread to every copy.)
local function ReadCount(text)
    local count = tonumber(text)
    if not count or count % 1 ~= 0 or count < 0 or count > MAX_REPORTED_COUNT then return 0 end
    return count
end

-- Counts one kill of `key`. The reported counts are the totals the copy that told us had, so
-- a copy that was offline for earlier kills catches up. Only guild-list kills count towards
-- the killer's KOS kills. Returns the name's new total, or nil when this kill was already
-- counted (two copies told the guild about it).
local function CountKill(key, killerName, place, isGuildKill, reportedCount, reportedKillerCount)
    local now = GetTime()
    if lastKillAt[key] and now - lastKillAt[key] < SAME_KILL_SECONDS then return nil end
    lastKillAt[key] = now

    local record = ns.db.kills[key] or { count = 0 }
    record.count = math.max(record.count + 1, ReadCount(reportedCount))
    record.lastAt = GetServerTime()
    record.lastBy = killerName
    record.lastPlace = place
    ns.db.kills[key] = record

    if isGuildKill then
        local killerCount = (ns.db.killerCounts[killerName] or 0) + 1
        ns.db.killerCounts[killerName] = math.max(killerCount, ReadCount(reportedKillerCount))
    end
    ns:Fire("KOS_KILLED", key)
    return record.count
end

local function TimesText(count)
    if count == 1 then return "1 gang" end
    return ("%d ganger"):format(count)
end

-- "Ola drepte Forræder i Ashenvale! Forræder er tatt 3 ganger. Ola har 5 KOS-drap." The last
-- sentence is left out when `killerCount` is nil (a name on your own list only).
function Kills.Text(victimName, killerName, place, count, killerCount)
    local placeText = place ~= "" and (" i " .. place) or ""
    local text = ("%s drepte %s%s! %s er tatt %s."):format(killerName, victimName, placeText, victimName,
        TimesText(count))
    if not killerCount then return text end
    return text .. (" %s har %d KOS-drap."):format(killerName, killerCount)
end

-- Guild chat can't carry color codes, so the line goes as plain text. Returns whether it went.
local function PostInGuildChat(text)
    if not IsInGuild() or ns.Share.IsChatLockedDown() then return false end
    local sendChatMessage = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    return (pcall(sendChatMessage, GUILD_CHAT_TAG .. text, "GUILD"))
end

-- Counts a kill this copy saw and, for a guild-list name, tells the guild about it.
local function TellKill(entry, killerName, victimName, victimRealm)
    local place = ns.CurrentPlace()
    local count = CountKill(entry.key, killerName, place, entry.inGuildList)
    if not count then return end
    ns.NoteLastSeen(entry.key, place, killerName)
    if not entry.inGuildList then
        ns:Print(Kills.Text(entry.name, killerName, place, count))
        return
    end
    local killerCount = ns.db.killerCounts[killerName]
    local text = Kills.Text(entry.name, killerName, place, count, killerCount)
    local isPosted = ns.settings.announceKills and PostInGuildChat(text) or false
    if not isPosted then ns:Print(text) end
    ns.Share.AnnounceKill(victimName, victimRealm, killerName, place, count, killerCount, isPosted)
end

-- Your place in the stand-in order: the group members in your guild, minus the killer, sorted
-- by name. Every copy works out the same order, so the first in it tells the kill, and the
-- others hear it (K1 or guild chat) before their turn comes.
local function StandInRank(killerName)
    local names = {}
    local isAdded = {}
    for _, unit in ipairs(GroupUnits()) do
        local name = ns.Plain(UnitName(unit))
        local isGuildMember = unit == "player" or ns.Plain(UnitIsInMyGuild(unit)) == true
        if name and name ~= killerName and not isAdded[name] and isGuildMember then
            isAdded[name] = true
            table.insert(names, name)
        end
    end
    table.sort(names)
    local myName = UnitName("player")
    for rank, name in ipairs(names) do
        if name == myName then return rank - 1 end
    end
    return 0
end

local function WasToldRecently(key)
    return lastToldAt[key] ~= nil and GetTime() - lastToldAt[key] < SAME_KILL_SECONDS
end

-- A group member's kill: their own copy of the addon tells the guild if they have one. If
-- nobody has when this copy's turn comes, this copy does.
local function TellKillLater(entry, killerName, victimName, victimRealm)
    local delay = STAND_IN_FIRST + StandInRank(killerName) * STAND_IN_STEP
    C_Timer.After(delay, function()
        if WasToldRecently(entry.key) then return end
        TellKill(entry, killerName, victimName, victimRealm)
    end)
end

-- A kill another guild member's copy told us about (see Share.lua).
function Kills.TakeReport(entry, killerName, place, reportedCount, reportedKillerCount, wasPostedInChat)
    local count = CountKill(entry.key, killerName, place, true, reportedCount, reportedKillerCount)
    if not count then return end
    ns.NoteLastSeen(entry.key, place, killerName)
    if wasPostedInChat or not ns.settings.showGuildReports then return end
    ns:Print(Kills.Text(entry.name, killerName, place, count, ns.db.killerCounts[killerName]))
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

-- "[KOS] Ola drepte Forræder ...": a kill someone already told in guild chat. A stand-in
-- waiting to tell the same kill stays quiet.
ns:On("CHAT_MSG_GUILD", function(text)
    text = ns.Plain(text)
    if type(text) ~= "string" or text:sub(1, #GUILD_CHAT_TAG) ~= GUILD_CHAT_TAG then return end
    local victimName = text:match(" drepte ([^%s!]+)")
    if victimName then lastToldAt[ns.KeyFromFullName(victimName)] = GetTime() end
end)
