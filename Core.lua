-- GuildKOS: the shared namespace, saved settings, game events, character names and the
-- two KOS lists: your own list (saved for every character on the account) and the guild list,
-- which every member's copy of the addon keeps and Sync.lua keeps in step.
local addonName, ns = ...

local CHAT_PREFIX = "|cffff2020KOS|r"
local SECONDS_PER_DAY = 86400
local LAST_SEEN_KEEP_DAYS = 14 -- "last seen" notes older than this are forgotten at login
local MAX_NAME_BYTES = 48      -- a name is at most 12 letters, and a letter is up to 4 bytes in UTF-8
local MAX_REASON_BYTES = 80    -- keeps a shared entry inside one 255-byte addon message

ns.INVALID_NAME = "Ugyldig navn. Skriv bare karakternavnet, uten tall, mellomrom eller tegn."

-- How a sighting happened, as shown in alerts and chat.
ns.HOW_SEEN_TEXT = {
    nameplate = "navneplate",
    target = "target",
    mouseover = "musepeker",
    focus = "focus",
    groupTarget = "gruppens target",
    say = "/say",
    yell = "/yell",
    emote = "emote",
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
    alertPause = 60,         -- seconds before the same name can alert again
}


function ns:Print(...)
    print(CHAT_PREFIX, ...)
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

-- Realms are written without spaces in "Name-Realm" ("Navn-LivingFlame"). Dashes and
-- apostrophes are dropped from the key as well, so every way of writing a realm matches.
local function RealmKeyOf(realm)
    return LowerText((realm:gsub("[%s%-'|]", "")))
end

function ns.OwnRealm()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
    return (realm:gsub("%s", ""))
end

local function OwnRealmKey()
    return RealmKeyOf(ns.OwnRealm())
end

-- Splits "Name" or "Name-Realm" and trims the spaces around it. The realm is nil when absent.
function ns.SplitName(fullName)
    local trimmed = fullName:match("^%s*(.-)%s*$")
    local name, realm = trimmed:match("^([^%-]+)%-(.*)$")
    if not name then return trimmed, nil end
    if realm == "" then realm = nil end
    return name, realm
end

-- Character names have no digits, spaces or punctuation. Letters like æ, ø and å are fine:
-- their bytes are above 127, which Lua's %d, %p, %s and %c never match.
function ns.IsValidName(name)
    if type(name) ~= "string" or name == "" or #name > MAX_NAME_BYTES then return false end
    return not name:find("[%d%p%s%c]")
end

-- The lookup key for a character: the name in small letters, plus "-realm" when the character
-- is from another realm than yours. A name saved without a realm matches it on every realm.
function ns.NameKey(name, realm)
    local nameKey = LowerText(name)
    if not realm or realm == "" then return nameKey end
    local realmKey = RealmKeyOf(realm)
    if realmKey == "" or realmKey == OwnRealmKey() then return nameKey end
    return nameKey .. "-" .. realmKey
end

function ns.KeyFromFullName(fullName)
    return ns.NameKey(ns.SplitName(fullName or ""))
end

-- How a typed name is shown and saved: "forræder" becomes "Forræder", and the realm is kept
-- only when it isn't your own.
function ns.DisplayName(name, realm)
    local shown = UpperFirstLetter(LowerText(name))
    if not realm or RealmKeyOf(realm) == "" or RealmKeyOf(realm) == OwnRealmKey() then return shown end
    return shown .. "-" .. (realm:gsub("[%s|]", ""))
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

-- The entry for a character the game showed us, or nil. A name saved with its realm is
-- tried first, then the name alone, which stands for every realm.
function ns.FindEntry(name, realm)
    local fullKey = ns.NameKey(name, realm)
    local nameOnlyKey = ns.NameKey(name)
    return ns.EntryFor(fullKey) or (fullKey ~= nameOnlyKey and ns.EntryFor(nameOnlyKey)) or nil
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

-- A reason as it is saved and shared, or nil when empty. "|" starts the game's color and
-- link codes and tabs split addon messages, so both are taken out.
function ns.CleanReason(reason)
    local cleanReason = (reason or ""):gsub("[|\t]", ""):match("^%s*(.-)%s*$"):sub(1, MAX_REASON_BYTES)
    if cleanReason == "" then return nil end
    return cleanReason
end

-- Adds a name to your own list. Returns the name as shown, or nil and why not.
function ns.AddPersonal(fullName, reason)
    local name, realm = ns.SplitName(fullName or "")
    if not ns.IsValidName(name) then return nil, ns.INVALID_NAME end
    local shown = ns.DisplayName(name, realm)
    ns.db.personal[ns.NameKey(name, realm)] = {
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
    if not personal then return nil, "Navnet står ikke i din liste." end
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
    ForgetOldSightings(db.lastSeen)
    ns.db = db
    ns.settings = db.settings
end)
