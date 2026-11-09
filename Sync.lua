-- The guild list: names guild members add in the addon. Every copy of the addon keeps the
-- whole list, and the copies keep each other up to date over hidden guild messages:
--   E1  one entry: name, changedAt, changedBy, removed (1 or 0), reason, addedBy, addedAt.
--       Sent when someone adds or removes a name, and as part of a whole list (below).
--   H1  a checksum of the sender's list and its version, sent a little while after login
--   D1  a whole list follows as E1 messages, and then
--   D2  the end of that list
--
-- At login a copy says H1. A copy whose list differs waits a few seconds and sends its whole
-- list (D1, E1 ..., D2), unless someone has started sending a whole list since that H1.
-- Every copy that hears a whole list to its end then sends only the entries that list lacked
-- or had older, so each difference crosses the guild channel about once. Only entries newer
-- than a copy's own are taken.
--
-- When two copies disagree about a name, the change made last wins: changedAt is the
-- server's clock, the same for everyone. A removed name stays in the list, marked removed,
-- for TOMBSTONE_KEEP_DAYS, so a copy that was offline and still has it can't bring it back.
--
-- Every guild member may change the list. Each entry remembers who added it, and the window
-- shows that next to the name.
local _, ns = ...

local Sync = {}
ns.Sync = Sync

local ENTRY = "E1"
local HELLO = "H1"
local LIST_START = "D1"
local LIST_END = "D2"
local HELLO_DELAY = 20          -- seconds after login, so the game has loaded the guild first
-- A copy whose list differs waits a random time before answering an H1, so the first answer
-- reaches the others before they answer too. The more members online, the wider the spread.
local ANSWER_DELAY_MIN = 2         -- seconds
local ANSWER_DELAY_PER_MEMBER = 0.5 -- seconds of spread for each guild member online
local ANSWER_DELAY_MAX = 30        -- seconds
local GAP_FILL_DELAY_MAX = 3    -- seconds; spreads out the copies sending what a list lacked
local HELLO_RETRY_DELAY = 120   -- seconds; when a list started but never ended, ask once more
local TOMBSTONE_KEEP_DAYS = 180 -- removed names older than this are forgotten
local SECONDS_PER_DAY = 86400
local FUTURE_TOLERANCE = 3600   -- seconds a change may lie ahead of the server clock
local HASH_START = 5381         -- the djb2 string hash, kept below 2^32 so it stays exact in Lua
local HASH_MODULO = 4294967296

local helloSentAt = -math.huge
local helloRound = 0              -- counts our H1s, so an old retry check knows it is old
local hasSaidHello = false        -- said H1 this session (at login, or once the guild was known)
local lastListStartedAt = -math.huge -- GetTime() of the last whole list started, by anyone
local lastListEndedAt = -math.huge   -- GetTime() of the last whole list heard to its end
local listBeingHeard  -- { sender, versions = { key -> entry } } while a whole list comes in
local lastHeard = {}  -- key -> newest version another copy sent, to skip sending it again
local lastSync        -- { at = GetServerTime(), from = "Ola" } when a whole list last came in

local function RandomBetween(low, high)
    return low + math.random() * (high - low)
end

local function IsNewer(incoming, current)
    if not current then return true end
    if incoming.changedAt ~= current.changedAt then return incoming.changedAt > current.changedAt end
    return incoming.changedBy > current.changedBy
end

local function IsForgottenTombstone(entry)
    return entry.removed and entry.changedAt < GetServerTime() - TOMBSTONE_KEEP_DAYS * SECONDS_PER_DAY
end

local function ForgetOldTombstones(entries)
    for key, entry in pairs(entries) do
        if IsForgottenTombstone(entry) then entries[key] = nil end
    end
end

-- One entry's hash. The list's checksum adds these up, so the order entries are stored in
-- doesn't matter and every copy with the same list gets the same number.
local function EntryHash(key, entry)
    local text = table.concat({ key, tostring(entry.changedAt), entry.changedBy, entry.removed and "1" or "0" }, ":")
    local hash = HASH_START
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % HASH_MODULO
    end
    return hash
end

-- tostring, not ("%x"):format: the game's Lua formats numbers above 2^31 differently on
-- different computers.
local function ListChecksum(entries)
    local sum = 0
    for key, entry in pairs(entries) do
        sum = (sum + EntryHash(key, entry)) % HASH_MODULO
    end
    return tostring(sum)
end

local function EncodeEntry(entry)
    return {
        ENTRY,
        entry.name,
        tostring(entry.changedAt),
        entry.changedBy,
        entry.removed and "1" or "0",
        entry.reason or "",
        entry.addedBy or "",
        tostring(entry.addedAt or 0),
    }
end

-- A server time from another copy, or nil when it is broken: a whole number of seconds, not
-- too far in the future. (tonumber also reads "nan" and "inf", which would pin an entry.)
local function ReadTime(text)
    local value = tonumber(text)
    if not value or value % 1 ~= 0 then return nil end
    if value <= 0 or value > GetServerTime() + FUTURE_TOLERANCE then return nil end
    return value
end

-- The key and entry an E1 message carries, or nil when it is broken. The name is a character
-- ("First Last") or a whole guild ("<Guild>").
local function DecodeEntry(fields)
    local key, shown = ns.ParseListName(fields[2])
    local changedAt = ReadTime(fields[3])
    local changedBy = ns.Share.CleanText(fields[4])
    if not key or not changedAt or changedBy == "" then
        return nil
    end
    local addedBy = ns.Share.CleanText(fields[7])
    return key, {
        name = shown,
        changedAt = changedAt,
        changedBy = changedBy,
        removed = fields[5] == "1",
        reason = ns.CleanReason(fields[6]),
        addedBy = addedBy ~= "" and addedBy or nil,
        addedAt = ReadTime(fields[8]),
    }
end

local function Merge(key, incoming)
    local entries = ns.SyncedEntries()
    if not entries or IsForgottenTombstone(incoming) or not IsNewer(incoming, entries[key]) then return end
    entries[key] = incoming
    ns:Fire("KOS_LIST_CHANGED")
end

--------------------------------------------------------------------------------
-- Changes made here
--------------------------------------------------------------------------------

-- Why you can't change the guild list right now, or nil when you can.
function Sync.WhyCannotEdit()
    if not ns.SyncedEntries() then return "Du er ikke med i en guild." end
    return nil
end

-- A change must be newer than the one it replaces, also when both happen in the same second.
local function NextChangeTime(previous)
    local now = GetServerTime()
    if previous and previous.changedAt >= now then return previous.changedAt + 1 end
    return now
end

local function SaveMyChange(key, entry)
    ns.SyncedEntries()[key] = entry
    ns.Share.SendEdit(EncodeEntry(entry))
    ns:Fire("KOS_LIST_CHANGED")
end

-- Returns the name as shown, or nil and why not.
function Sync.Add(fullName, reason)
    local key, shown = ns.ParseListName(fullName)
    if not key then return nil, ns.INVALID_NAME end
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local previous = ns.SyncedEntries()[key]
    local listed = previous and not previous.removed and previous or nil
    local entry = {
        name = shown,
        reason = ns.CleanReason(reason) or (listed and listed.reason),
        addedBy = listed and listed.addedBy or ns.MyFullName(),
        addedAt = listed and listed.addedAt or GetServerTime(),
        changedBy = ns.MyFullName(),
        changedAt = NextChangeTime(previous),
        removed = false,
    }
    SaveMyChange(key, entry)
    return entry.name
end

-- Returns the name as shown, or nil and why not.
function Sync.Remove(key)
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local current = ns.SyncedEntries()[key]
    if not current or current.removed then return nil, "Navnet står ikke på guildlista." end
    SaveMyChange(key, {
        name = current.name,
        changedBy = ns.MyFullName(),
        changedAt = NextChangeTime(current),
        removed = true,
    })
    return current.name
end

-- Adds every { fullName, reason } not already on the guild list (an import). Returns how
-- many were added, or nil and why not.
function Sync.AddMany(items)
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local addedCount = 0
    for _, item in ipairs(items) do
        local current = ns.SyncedEntries()[ns.KeyFromFullName(item.fullName)]
        local isListed = current and not current.removed
        if not isListed and Sync.Add(item.fullName, item.reason) then addedCount = addedCount + 1 end
    end
    return addedCount
end

--------------------------------------------------------------------------------
-- Comparing lists with the guild
--------------------------------------------------------------------------------

function Sync.StatusText()
    if not lastSync then return "Synkes når andre med addonen er pålogget." end
    return ("Sist synket med %s %s."):format(lastSync.from, ns.TimeAgo(lastSync.at))
end

-- For /kos status: names on the guild list, and removed names still remembered.
function Sync.Counts()
    local listedCount, removedCount = 0, 0
    for _, entry in pairs(ns.SyncedEntries() or {}) do
        if entry.removed then
            removedCount = removedCount + 1
        else
            listedCount = listedCount + 1
        end
    end
    return listedCount, removedCount
end

local function SendWholeList()
    local entries = ns.SyncedEntries()
    if not entries then return end
    lastListStartedAt = GetTime()
    local messages = { { LIST_START } }
    for _, entry in pairs(entries) do
        table.insert(messages, EncodeEntry(entry))
    end
    table.insert(messages, { LIST_END })
    ns.Share.SendList(messages)
end

-- "Synk nå": sends your whole guild list to everyone online with the addon. Each copy that
-- hears it to the end sends back what it lacked (see LIST_END below), so both ways are
-- covered. Returns how many names were sent, or nil and why not.
local PUSH_COOLDOWN = 30 -- seconds between two pushes, so the button can't flood the guild
local lastPushAt = -math.huge

function Sync.PushAll()
    local entries = ns.SyncedEntries()
    if not entries then return nil, "Du er ikke med i en guild." end
    local secondsLeft = math.ceil(PUSH_COOLDOWN - (GetTime() - lastPushAt))
    if secondsLeft > 0 then return nil, ("Vent %d sekunder før du synker igjen."):format(secondsLeft) end
    lastPushAt = GetTime()
    ForgetOldTombstones(entries)
    SendWholeList()
    return (Sync.Counts())
end

-- Skips sending an entry when another copy has sent the same version (or a newer one) since.
local function AlreadySentBySomeone(key, entry)
    return function()
        return lastHeard[key] ~= nil and not IsNewer(entry, lastHeard[key])
    end
end

-- After hearing a whole list: send what it lacked or had older.
local function SendWhatTheyLack(theirVersions)
    local entries = ns.SyncedEntries()
    if not entries then return end
    for key, entry in pairs(entries) do
        local theirs = theirVersions[key]
        if not theirs or IsNewer(entry, theirs) then
            ns.Share.SendEdit(EncodeEntry(entry), AlreadySentBySomeone(key, entry))
        end
    end
end

-- A list that started after our H1 but never reached its end (the sender logged out or
-- reloaded): ask once more.
local function AskAgainIfUnfinished(round)
    if round ~= helloRound then return end
    local hasListStarted = lastListStartedAt >= helloSentAt
    local hasListEnded = lastListEndedAt >= helloSentAt
    if hasListStarted and not hasListEnded then Sync.SayHello(true) end
end

-- Asks the guild for their lists. Returns false outside a guild (or before the game says which).
function Sync.SayHello(isRetry)
    local entries = ns.SyncedEntries()
    if not entries then return false end
    ForgetOldTombstones(entries)
    helloSentAt = GetTime()
    helloRound = helloRound + 1
    hasSaidHello = true
    ns.Share.SendNow({ HELLO, ListChecksum(entries), ns.Version() })
    if not isRetry then
        local round = helloRound
        C_Timer.After(HELLO_RETRY_DELAY, function() AskAgainIfUnfinished(round) end)
    end
    return true
end

local function SayHelloOnce()
    if not hasSaidHello then Sync.SayHello() end
end

-- How many guild members are online. GetNumGuildMembers gives (total, online) on older clients
-- and (total, online at max level, online) on newer ones, so the larger of the two is used.
local function OnlineMemberCount()
    local _, second, third = GetNumGuildMembers()
    return math.max(tonumber(ns.Plain(second)) or 0, tonumber(ns.Plain(third)) or 0)
end

local function AnswerDelay()
    local latest = math.min(ANSWER_DELAY_MIN + ANSWER_DELAY_PER_MEMBER * OnlineMemberCount(), ANSWER_DELAY_MAX)
    return RandomBetween(ANSWER_DELAY_MIN, latest)
end

ns.Share.OnMessage(HELLO, function(fields, sender)
    ns.NoteVersionHeard(fields[3], sender)
    local entries = ns.SyncedEntries()
    if not entries or fields[2] == ListChecksum(entries) then return end
    local helloHeardAt = GetTime()
    C_Timer.After(AnswerDelay(), function()
        -- Someone already started a whole list: we send what it lacks when it ends.
        if lastListStartedAt >= helloHeardAt then return end
        SendWholeList()
    end)
end)

ns.Share.OnMessage(LIST_START, function(_, sender)
    lastListStartedAt = GetTime()
    listBeingHeard = { sender = sender, versions = {} }
end)

ns.Share.OnMessage(ENTRY, function(fields, sender)
    local key, incoming = DecodeEntry(fields)
    if not key then return end
    if listBeingHeard and listBeingHeard.sender == sender then listBeingHeard.versions[key] = incoming end
    if not lastHeard[key] or IsNewer(incoming, lastHeard[key]) then lastHeard[key] = incoming end
    Merge(key, incoming)
end)

ns.Share.OnMessage(LIST_END, function(_, sender)
    if not (listBeingHeard and listBeingHeard.sender == sender) then return end
    local theirVersions = listBeingHeard.versions
    listBeingHeard = nil
    lastListEndedAt = GetTime()
    lastSync = { at = GetServerTime(), from = Ambiguate(sender, "guild") }
    ns:Fire("KOS_SYNCED")
    C_Timer.After(RandomBetween(0, GAP_FILL_DELAY_MAX), function() SendWhatTheyLack(theirVersions) end)
end)

-- At login, and when the game first says which guild you are in (it can take a while).
ns:On("PLAYER_LOGIN", function()
    -- Asks the game for the guild roster, so OnlineMemberCount knows who is online.
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    C_Timer.After(HELLO_DELAY, SayHelloOnce)
end)

ns:On("PLAYER_GUILD_UPDATE", function()
    C_Timer.After(HELLO_DELAY, SayHelloOnce)
end)
