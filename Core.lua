-- GuildKOS: the shared namespace, saved settings, game events, character names and the
-- two KOS lists: your own list (saved for every character on the account) and the guild list,
-- which every member's copy of the addon keeps and Sync.lua keeps in step.
local addonName, ns = ...

local CHAT_PREFIX = "|cffff2020KOS|r"
local SECONDS_PER_DAY = 86400
local LAST_SEEN_KEEP_DAYS = 14 -- "last seen" notes older than this are forgotten at login
local MAX_NAME_BYTES = 48      -- a name is at most 12 letters, and a letter is up to 4 bytes in UTF-8
local MAX_REASON_BYTES = 80    -- keeps a shared entry inside one 255-byte addon message

ns.INVALID_NAME = "Ugyldig navn. Skriv fornavn og etternavn, for eksempel «Nektarion Stormhoof», "
    .. "eller en hel guild som «<Guildnavn>»."

-- How a sighting happened, as shown in alerts and chat.
ns.HOW_SEEN_TEXT = {
    nameplate = "navneplate",
    target = "target",
    mouseover = "musepeker",
    focus = "focus",
    groupTarget = "gruppens target",
    targetTarget = "target sitt target",
    plateTarget = "noen i nærheten har ham i target",
    say = "/say",
    yell = "/yell",
    emote = "emote",
    friendZone = "Battle.net-vennelista",
    test = "test",
}

local DEFAULT_SETTINGS = {
    playSound = true,
    soundKey = "raidwarning",
    flashScreen = true,
    showBanner = true,
    showNearbyWindow = true,
    shareSightings = true,   -- tell the guild when you see someone from the guild list
    showGuildReports = true, -- print the guild's sightings and kills in chat
    announceKills = true,    -- say in guild chat when you kill someone from the guild list
    longNameplates = false,  -- show nameplates as far away as the game allows (Detect.lua)
    watchFriends = true,     -- alert when a Battle.net friend on a list is in your zone (Friends.lua)
    addToPersonal = false,   -- the /kos window adds names to your own list instead of the guild's
    alertPause = 60,         -- seconds before the same name can alert again
}

function ns:Print(...)
    print(CHAT_PREFIX, ...)
end

-- The version in GuildKOS.toc, for /kos status and /kos ping.
function ns.Version()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMetadata and getMetadata(addonName, "Version") or "?"
end

local DOWNLOAD_URL = "https://github.com/holmzoram-art/GuildKOS/releases/latest/download/GuildKOS.zip"

-- "1.10.2" -> 1, 10, 2, or nil when it isn't a version.
local function VersionNumbers(version)
    local major, minor, patch = tostring(version or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch) or 0
end

local function IsNewerVersion(version, than)
    local major, minor, patch = VersionNumbers(version)
    local thanMajor, thanMinor, thanPatch = VersionNumbers(than)
    if not (major and thanMajor) then return false end
    if major ~= thanMajor then return major > thanMajor end
    if minor ~= thanMinor then return minor > thanMinor end
    return patch > thanPatch
end

local toldNewerVersion -- the newest version this session has told the player about

-- Another guild member's copy said which version it runs (Sync.lua, Share.lua). When it is
-- newer than this one, the player hears it once, with where to get it.
function ns.NoteVersionHeard(heardVersion, sender)
    if not IsNewerVersion(heardVersion, ns.Version()) then return end
    if toldNewerVersion and not IsNewerVersion(heardVersion, toldNewerVersion) then return end
    -- Rebuilt from its numbers, so text from another player's game is never printed as is.
    local version = ("%d.%d.%d"):format(VersionNumbers(heardVersion))
    toldNewerVersion = version
    ns:Print(("%s har en nyere versjon av GuildKOS (%s, du har %s). Dobbeltklikk Oppdater-GuildKOS.bat "
        .. "i AddOns-mappa, eller last ned fra %s"):format(Ambiguate(sender, "guild"), version, ns.Version(),
        DOWNLOAD_URL))
end

-- "for 5 min siden": how long ago a GetServerTime() moment was.
function ns.TimeAgo(serverTime)
    local seconds = math.max(0, GetServerTime() - (serverTime or 0))
    if seconds < 60 then return "nå nettopp" end
    if seconds < 3600 then return ("for %d min siden"):format(math.floor(seconds / 60)) end
    if seconds < 86400 then return ("for %d t siden"):format(math.floor(seconds / 3600)) end
    return ("for %d d siden"):format(math.floor(seconds / 86400))
end

-- "The Crossroads, The Barrens": the subzone and zone you are in.
function ns.CurrentPlace()
    local zone = GetRealZoneText() or ""
    local subZone = GetSubZoneText() or ""
    if subZone ~= "" and subZone ~= zone then return subZone .. ", " .. zone end
    return zone
end

--------------------------------------------------------------------------------
-- Secret values
--------------------------------------------------------------------------------

-- WoW Forever runs Blizzard's Midnight addon rules. In combat and in some instances the game
-- can hand an addon a value it may not read, such as a unit's name or a chat sender.
-- Comparing one, joining it into text or using it as a table key throws an error, so every
-- game value that could be secret goes through ns.Plain first: the value, or nil if secret.
local IsSecret = issecretvalue or function() return false end

function ns.Plain(value)
    if IsSecret(value) then return nil end
    return value
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- One frame listens for every game event, and ns:On adds a handler. Names that start with
-- "KOS_" are the addon's own messages, sent with ns:Fire and never registered with the game.
local eventFrame = CreateFrame("Frame")
local handlersByEvent = {}

local function IsOwnMessage(eventName)
    return eventName:sub(1, 4) == "KOS_"
end

-- Returns false when this client doesn't have the event (RegisterEvent throws for those).
function ns:On(eventName, handler)
    local handlers = handlersByEvent[eventName]
    if not handlers then
        if not IsOwnMessage(eventName) and not pcall(eventFrame.RegisterEvent, eventFrame, eventName) then
            return false
        end
        handlers = {}
        handlersByEvent[eventName] = handlers
    end
    table.insert(handlers, handler)
    return true
end

function ns:Fire(eventName, ...)
    local handlers = handlersByEvent[eventName]
    if not handlers then return end
    for _, handler in ipairs(handlers) do
        handler(...)
    end
end

eventFrame:SetScript("OnEvent", function(_, eventName, ...)
    ns:Fire(eventName, ...)
end)

--------------------------------------------------------------------------------
-- Character names
--------------------------------------------------------------------------------

-- string.lower only changes A-Z, so "Ærling" and "ærling" would not match. The capitals
-- À-Þ (Æ, Ø and Å among them) are two bytes in UTF-8: 0xC3, then 0x80-0x9E, and each small
-- letter is the same second byte plus 0x20. 0xC3 0x97 is the "×" sign, which has none.
local LATIN_CAPITAL = "\195([\128-\158])"
local MULTIPLY_SIGN = 0x97
local DIVIDE_SIGN = 0xB7
local CASE_STEP = 0x20

local function LowerText(text)
    return (text:lower():gsub(LATIN_CAPITAL, function(secondByte)
        local code = secondByte:byte()
        if code == MULTIPLY_SIGN then return nil end
        return "\195" .. string.char(code + CASE_STEP)
    end))
end

local function UpperFirstLetter(text)
    if text:sub(1, 1) ~= "\195" then
        return text:sub(1, 1):upper() .. text:sub(2)
    end
    local code = text:byte(2)
    if not code or code < 0xA0 or code > 0xBE or code == DIVIDE_SIGN then return text end
    return "\195" .. string.char(code - CASE_STEP) .. text:sub(3)
end

-- WoW Forever gives every character a first and a last name: "Nektarion Stormhoof". A first
-- name alone is not unique. UnitName returns the two as separate values (on other WoW
-- versions the second value is the realm), and chat and addon messages name the sender
-- "First Last". A name saved with only a first name matches every character with that first
-- name; one saved with both matches only that character.

-- Used for the guild's key in the saved data (ns.SyncedEntries).
function ns.OwnRealm()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
    return (realm:gsub("%s", ""))
end

-- "Nektarion Stormhoof" -> "Nektarion", "Stormhoof"; "Nektarion" -> "Nektarion", nil. A
-- "-Realm" ending, which chat senders can carry, is dropped. Three words or more come back
-- whole, and ns.IsValidName turns them down.
function ns.SplitName(fullName)
    local trimmed = (fullName or ""):gsub("%-.*$", ""):match("^%s*(.-)%s*$")
    local firstName, lastName = trimmed:match("^(%S+)%s+(%S+)$")
    if firstName then return firstName, lastName end
    return trimmed, nil
end

-- One name part. Names have no digits, spaces or punctuation. Letters like æ, ø and å are
-- fine: their bytes are above 127, which Lua's %d, %p, %s and %c never match.
function ns.IsValidName(name)
    if type(name) ~= "string" or name == "" or #name > MAX_NAME_BYTES then return false end
    return not name:find("[%d%p%s%c]")
end

-- A first name, and a last name when there is one.
function ns.IsValidFullName(firstName, lastName)
    return ns.IsValidName(firstName) and (lastName == nil or ns.IsValidName(lastName))
end

-- The lookup key for a character: "nektarion stormhoof", or "nektarion" without a last name.
function ns.NameKey(firstName, lastName)
    if not lastName or lastName == "" then return LowerText(firstName) end
    return LowerText(firstName) .. " " .. LowerText(lastName)
end

-- How a name is shown and saved: "nektarion stormhoof" becomes "Nektarion Stormhoof".
function ns.DisplayName(firstName, lastName)
    local shown = UpperFirstLetter(LowerText(firstName))
    if not lastName or lastName == "" then return shown end
    return shown .. " " .. UpperFirstLetter(LowerText(lastName))
end

-- A whole guild on a list is written "<Guild Name>". The brackets keep its key apart from any
-- character's (no name has "<"), and Detect.lua checks the guild of every player it sees.
local MAX_GUILD_NAME_BYTES = 72 -- a guild name is at most 24 letters, up to 3 bytes each in UTF-8

function ns.GuildEntryKey(guildName)
    return "<" .. LowerText(guildName) .. ">"
end

-- The guild name inside "<Guild Name>", or nil when `text` isn't written that way.
local function GuildNameIn(text)
    local guildName = (text or ""):match("^%s*<%s*(.-)%s*>%s*$")
    if not guildName or guildName == "" or #guildName > MAX_GUILD_NAME_BYTES then return nil end
    if guildName:find("[<>|\t%c]") then return nil end
    return guildName
end

-- The key and the shown name for something on a list: a character ("Fornavn Etternavn") or
-- a guild ("<Guildnavn>"). Nil when it is neither.
function ns.ParseListName(text)
    local guildName = GuildNameIn(text)
    if guildName then return ns.GuildEntryKey(guildName), "<" .. guildName .. ">" end
    local firstName, lastName = ns.SplitName(text)
    if not ns.IsValidFullName(firstName, lastName) then return nil end
    return ns.NameKey(firstName, lastName), ns.DisplayName(firstName, lastName)
end

function ns.KeyFromFullName(fullName)
    return ns.ParseListName(fullName) or ns.NameKey(ns.SplitName(fullName))
end

-- A unit's name as "First Last", or nil when the game keeps it secret or doesn't know it.
function ns.FullNameOfUnit(unit)
    local firstName, lastName = UnitName(unit)
    firstName, lastName = ns.Plain(firstName), ns.Plain(lastName)
    if type(firstName) ~= "string" or firstName == "" or firstName == UNKNOWNOBJECT then return nil end
    if type(lastName) ~= "string" or lastName == "" then return firstName end
    return firstName .. " " .. lastName
end

function ns.MyFullName()
    return ns.FullNameOfUnit("player") or UnitName("player")
end

-- Your target's "First Last" when it is a player, or nil.
function ns.TargetFullName()
    if not ns.Plain(UnitIsPlayer("target")) then return nil end
    return ns.FullNameOfUnit("target")
end

-- Whether a sender name ("First Last", maybe with "-Realm") is you. A sender given with only
-- a first name counts as you when the first name matches.
function ns.IsMe(senderName)
    local senderFirst, senderLast = ns.SplitName(senderName)
    local myFirst, myLast = ns.SplitName(ns.MyFullName())
    if LowerText(senderFirst) ~= LowerText(myFirst) then return false end
    return senderLast == nil or myLast == nil or LowerText(senderLast) == LowerText(myLast)
end

-- "Nektarion Stormhoof - gikk alliance" -> "Nektarion Stormhoof", "gikk alliance". The reason
-- comes after " - ", ":" or " – " (an en dash, 3 bytes in UTF-8). Without one, the first two
-- words are the name (first and last name) and the rest is the reason, so "Nektarion
-- Stormhoof gikk alliance" works too; one or two words are the name alone.
local REASON_SEPARATORS = { "%s+%-+%s*", "%s*:%s*", "%s+\226\128\147%s*" }

function ns.SplitNameAndReason(text)
    local trimmed = (text or ""):match("^%s*(.-)%s*$")
    -- "<Guild Name> grunn": the guild is everything up to ">".
    local guildPart, afterGuild = trimmed:match("^(<[^>]*>)%s*(.-)$")
    if guildPart then
        local reason = afterGuild:gsub("^[%-:]+%s*", "")
        return guildPart, reason ~= "" and reason or nil
    end
    for _, separator in ipairs(REASON_SEPARATORS) do
        local name, reason = trimmed:match("^(.-)" .. separator .. "(.*)$")
        if name then return name, reason end
    end
    local firstName, lastName, reason = trimmed:match("^(%S+)%s+(%S+)%s+(.+)$")
    if firstName then return firstName .. " " .. lastName, reason end
    return trimmed, nil
end

--------------------------------------------------------------------------------
-- The lists
--------------------------------------------------------------------------------

-- The guild list of the guild you are in (Sync.lua keeps it in step with the other
-- members), or nil outside a guild and while the game hasn't said which guild yet. Each
-- guild has its own, since your characters can be in different guilds.
-- key -> { name, reason, addedBy, addedAt, changedBy, changedAt, removed }. A removed name
-- stays as removed = true, so an older copy of the list can't bring it back.
function ns.SyncedEntries()
    if not (ns.db and IsInGuild()) then return nil end
    local guildName = ns.Plain(GetGuildInfo("player"))
    if type(guildName) ~= "string" or guildName == "" then return nil end
    local guildKey = guildName .. "-" .. ns.OwnRealm()
    ns.db.syncedByGuild[guildKey] = ns.db.syncedByGuild[guildKey] or {}
    return ns.db.syncedByGuild[guildKey]
end

local function LiveSyncedEntry(key)
    local syncedEntries = ns.SyncedEntries()
    local synced = syncedEntries and syncedEntries[key]
    if synced and not synced.removed then return synced end
    return nil
end

-- What the lists say about one key, or nil when it's on neither:
-- { key, name, reason, addedBy, inGuildList, inPersonalList }. A name on both lists shows
-- your own reason.
function ns.EntryFor(key)
    if not ns.db then return nil end
    local personal = ns.db.personal[key]
    local synced = LiveSyncedEntry(key)
    if not (personal or synced) then return nil end
    return {
        key = key,
        name = (personal and personal.name) or synced.name,
        reason = (personal and personal.reason) or (synced and synced.reason) or nil,
        addedBy = synced and synced.addedBy or nil,
        inGuildList = synced ~= nil,
        inPersonalList = personal ~= nil,
    }
end

-- The entry for a character the game showed us, or nil. The full name is tried first, then
-- the first name alone, which stands for every last name.
function ns.FindEntry(firstName, lastName)
    local fullKey = ns.NameKey(firstName, lastName)
    local firstNameKey = ns.NameKey(firstName)
    return ns.EntryFor(fullKey) or (fullKey ~= firstNameKey and ns.EntryFor(firstNameKey)) or nil
end

-- The first entry whose first name is `firstName`, whatever its last name, or nil. For
-- places that give a first name only, where FindEntry would miss a name saved in full.
function ns.FindEntryByFirstName(firstName)
    local firstNameKey = ns.NameKey(firstName)
    for _, entry in ipairs(ns.AllEntries()) do
        if entry.key == firstNameKey or entry.key:sub(1, #firstNameKey + 1) == firstNameKey .. " " then
            return entry
        end
    end
    return nil
end

-- The entry for a name as a message or the player writes it: "<Guild>" or "First Last".
function ns.FindListEntry(text)
    local guildName = GuildNameIn(text)
    if guildName then return ns.EntryFor(ns.GuildEntryKey(guildName)) end
    local firstName, lastName = ns.SplitName(text)
    if not ns.IsValidFullName(firstName, lastName) then return nil end
    return ns.FindEntry(firstName, lastName)
end

-- The guild entry for a guild name the game gave (GetGuildInfo), or nil.
function ns.FindGuildEntry(guildName)
    if type(guildName) ~= "string" or guildName == "" then return nil end
    return ns.EntryFor(ns.GuildEntryKey(guildName))
end

-- How an entry is shown for one sighting or kill: "Fuma Xxxx <Stormwind Elite>" for a member
-- of a listed guild (`playerName` given), else the entry's own name.
function ns.ShownName(entry, playerName)
    if playerName and playerName ~= "" and entry.key:sub(1, 1) == "<" then
        return playerName .. " " .. entry.name
    end
    return entry.name
end

-- A character seen or killed because their guild is on a list. It shows their own name and
-- the guild's, and is reported by the guild's entry: `key` (the guild) is what "last seen",
-- the alert pause, kill counts and guild reports go by, so a whole guild running past gives
-- one alert, while `nearbyKey` (the character) gives each of them a row in the nearby window.
function ns.GuildMemberEntry(guildEntry, playerFullName)
    return {
        key = guildEntry.key,
        nearbyKey = ns.KeyFromFullName(playerFullName),
        name = playerFullName .. " " .. guildEntry.name,
        listName = guildEntry.name,
        countName = guildEntry.name,
        playerName = playerFullName,
        reason = guildEntry.reason or ("Medlem av " .. guildEntry.name),
        inGuildList = guildEntry.inGuildList,
        inPersonalList = guildEntry.inPersonalList,
    }
end

-- Every entry on either list, sorted by name.
function ns.AllEntries()
    local entries = {}
    if not ns.db then return entries end
    local isAdded = {}
    local function AddKey(key)
        if isAdded[key] then return end
        isAdded[key] = true
        table.insert(entries, ns.EntryFor(key))
    end
    for key in pairs(ns.db.personal) do AddKey(key) end
    for key, synced in pairs(ns.SyncedEntries() or {}) do
        if not synced.removed then AddKey(key) end
    end
    table.sort(entries, function(first, second) return first.key < second.key end)
    return entries
end

-- The first `maxBytes` bytes of a UTF-8 text, without cutting a letter like æ in half: a
-- letter of 2-4 bytes that doesn't fit whole is left out.
local function CutToBytes(text, maxBytes)
    if #text <= maxBytes then return text end
    local cut = text:sub(1, maxBytes)
    local leadPosition = cut:find("[\192-\255][\128-\191]*$")
    if not leadPosition then return cut end
    local lead = cut:byte(leadPosition)
    local letterBytes = (lead >= 240 and 4) or (lead >= 224 and 3) or 2
    if #cut - leadPosition + 1 < letterBytes then return cut:sub(1, leadPosition - 1) end
    return cut
end

-- A reason as it is saved and shared, or nil when empty. "|" starts the game's color and
-- link codes and tabs split addon messages, so both are taken out.
function ns.CleanReason(reason)
    local cleanReason = (reason or ""):gsub("[|\t]", "")
    cleanReason = CutToBytes(cleanReason, MAX_REASON_BYTES):match("^%s*(.-)%s*$")
    if cleanReason == "" then return nil end
    return cleanReason
end

-- Adds a name to your own list. Returns the name as shown, or nil and why not.
function ns.AddPersonal(fullName, reason)
    local key, shown = ns.ParseListName(fullName)
    if not key then return nil, ns.INVALID_NAME end
    ns.db.personal[key] = {
        name = shown,
        reason = ns.CleanReason(reason),
        added = GetServerTime(),
    }
    ns:Fire("KOS_LIST_CHANGED")
    return shown
end

-- Returns the removed name as shown, or nil and why not.
function ns.RemovePersonal(key)
    local personal = ns.db.personal[key]
    if not personal then return nil, "Navnet står ikke på din liste." end
    ns.db.personal[key] = nil
    ns:Fire("KOS_LIST_CHANGED")
    return personal.name
end

-- Remembers where and when a listed character was last seen. `reporter` is the guild member
-- who saw them, or nil when it was you.
function ns.NoteLastSeen(key, place, reporter)
    ns.db.lastSeen[key] = { at = GetServerTime(), place = place, by = reporter }
    ns:Fire("KOS_SEEN", key)
end

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

local function FillDefaults(settings)
    for key, value in pairs(DEFAULT_SETTINGS) do
        if settings[key] == nil then settings[key] = value end
    end
end

-- Names put on your own list the first time this addon loads, so testing can start without
-- adding anyone. They go on your own list, never the guild list, so nothing about them is
-- shared. Taken off with the X like any other name, and not put back after that.
-- STARTER_VERSION 2 has the full name; version 1 put "Nektarion" alone, which is swapped.
local STARTER_NAMES = { "Nektarion Stormhoof" }
local OLD_STARTER_KEYS = { "nektarion" }
local STARTER_REASON = "Test"
local STARTER_VERSION = 2

local function AddStarterNames(db)
    local addedVersion = db.starterNamesVersion or (db.hasStarterNames and 1) or 0
    if addedVersion >= STARTER_VERSION then return end
    db.starterNamesVersion = STARTER_VERSION
    db.hasStarterNames = nil
    local hadOldStarter = false
    for _, oldKey in ipairs(OLD_STARTER_KEYS) do
        local old = db.personal[oldKey]
        if old and old.reason == STARTER_REASON then
            db.personal[oldKey] = nil
            hadOldStarter = true
        end
    end
    -- A version 1 install whose tester already took the old name off doesn't get the new one.
    if addedVersion == 1 and not hadOldStarter then return end
    for _, fullName in ipairs(STARTER_NAMES) do
        local firstName, lastName = ns.SplitName(fullName)
        local key = ns.NameKey(firstName, lastName)
        db.personal[key] = db.personal[key] or {
            name = ns.DisplayName(firstName, lastName),
            reason = STARTER_REASON,
            added = GetServerTime(),
        }
    end
end

local function ForgetOldSightings(lastSeen)
    local oldestKept = GetServerTime() - LAST_SEEN_KEEP_DAYS * SECONDS_PER_DAY
    for key, sighting in pairs(lastSeen) do
        if type(sighting) ~= "table" or (tonumber(sighting.at) or 0) < oldestKept then
            lastSeen[key] = nil
        end
    end
end

-- The game loads SavedVariables just before this addon's ADDON_LOADED, and writes them back
-- to disk only on /reload, logout or exit.
ns:On("ADDON_LOADED", function(loadedName)
    if loadedName ~= addonName then return end
    GuildKOSDB = GuildKOSDB or {}
    local db = GuildKOSDB
    db.personal = db.personal or {}
    db.lastSeen = db.lastSeen or {}
    db.kills = db.kills or {}               -- key -> { count, lastAt, lastBy, lastPlace }
    db.killerCounts = db.killerCounts or {} -- guild member's name -> KOS kills
    db.syncedByGuild = db.syncedByGuild or {} -- "Guild-Realm" -> synced guild list (ns.SyncedEntries)
    db.settings = db.settings or {}
    FillDefaults(db.settings)
    AddStarterNames(db)
    ForgetOldSightings(db.lastSeen)
    ns.db = db
    ns.settings = db.settings
end)
