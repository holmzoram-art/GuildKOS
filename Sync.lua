-- The synced guild list: names guild members add in the addon. Every copy of the addon keeps
-- the whole list, and the copies keep each other up to date over hidden guild messages:
--   E1  one entry: name, changedAt, changedBy, removed (1 or 0), reason, addedBy, addedAt.
--       Sent when someone adds or removes a name, and as part of a whole list (below).
--   H1  a checksum of the sender's list, sent a little while after login
--   D1  a checksum; the sender's whole list follows as E1 messages, and then
--   D2  the end of the list
--
-- At login a copy says H1. A copy whose list differs waits a few seconds and sends its whole
-- list (D1, E1 ..., D2), unless another copy with the same list has done so since. The copy that said
-- H1 keeps what is newer, then sends the entries that answer lacked, so both sides end up
-- with everything. Only names that are newer than your own copy's are taken.
--
-- When two copies disagree about a name, the change made last wins: changedAt is the
-- server's clock, the same for everyone. A removed name stays in the list, marked removed,
-- so a copy that was offline and still has it can't bring it back.
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
local HELLO_DELAY = 20       -- seconds after login, so the game has loaded the guild first
local ANSWER_DELAY_MIN = 2   -- seconds a copy whose list differs waits before answering an H1,
local ANSWER_DELAY_MAX = 10  -- so not every copy answers at once
local ANSWER_WAIT = 300      -- seconds after our H1 during which a list counts as its answer
local HASH_START = 5381      -- the djb2 string hash, kept below 2^32 so it stays exact in Lua
local HASH_MODULO = 4294967296

local lastListSent = { at = -math.huge, checksum = nil } -- the last whole list sent by anyone
local helloSentAt = -math.huge
local answer   -- while the answer to our H1 comes in: { sender, versions = { key -> entry } }
local lastSync -- { at = GetServerTime(), from = "Ola" } when a whole list last came in

local function MyFullName()
    return UnitName("player") .. "-" .. ns.OwnRealm()
end

local function IsNewer(incoming, current)
    if not current then return true end
    if incoming.changedAt ~= current.changedAt then return incoming.changedAt > current.changedAt end
    return incoming.changedBy > current.changedBy
end

-- The same list gives the same checksum on every copy: keys are hashed in sorted order.
local function ListChecksum(entries)
    local keys = {}
    for key in pairs(entries) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local hash = HASH_START
    for _, key in ipairs(keys) do
        local entry = entries[key]
        local text = key .. ":" .. tostring(entry.changedAt) .. ":" .. (entry.removed and "1" or "0") .. ";"
        for index = 1, #text do
            hash = (hash * 33 + text:byte(index)) % HASH_MODULO
        end
    end
    -- tostring, not ("%x"):format: the game's Lua formats numbers above 2^31 differently
    -- on different computers.
    return tostring(hash)
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

-- The key and entry an E1 message carries, or nil when it is broken.
local function DecodeEntry(fields)
    local name, realm = ns.SplitName(fields[2] or "")
    local changedAt = tonumber(fields[3])
    local changedBy = ns.Share.CleanText(fields[4])
    if not ns.IsValidName(name) or not changedAt or changedBy == "" then return nil end
    local addedBy = ns.Share.CleanText(fields[7])
    return ns.NameKey(name, realm), {
        name = ns.DisplayName(name, realm),
        changedAt = changedAt,
        changedBy = changedBy,
        removed = fields[5] == "1",
        reason = ns.CleanReason(fields[6]),
        addedBy = addedBy ~= "" and addedBy or nil,
        addedAt = tonumber(fields[8]),
    }
end

local function Merge(key, incoming)
    local entries = ns.SyncedEntries()
    if not entries or not IsNewer(incoming, entries[key]) then return end
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

local function SaveMyChange(key, entry, send)
    ns.SyncedEntries()[key] = entry
    send(EncodeEntry(entry))
    ns:Fire("KOS_LIST_CHANGED")
end

-- `send` is ns.Share.SendNow for one name, or ns.Share.SendBulk for an import.
local function AddName(fullName, reason, send)
    local name, realm = ns.SplitName(fullName or "")
    if not ns.IsValidName(name) then return nil, ns.INVALID_NAME end
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local key = ns.NameKey(name, realm)
    local previous = ns.SyncedEntries()[key]
    local listed = previous and not previous.removed and previous or nil
    local entry = {
        name = ns.DisplayName(name, realm),
        reason = ns.CleanReason(reason) or (listed and listed.reason),
        addedBy = listed and listed.addedBy or MyFullName(),
        addedAt = listed and listed.addedAt or GetServerTime(),
        changedBy = MyFullName(),
        changedAt = NextChangeTime(previous),
        removed = false,
    }
    SaveMyChange(key, entry, send)
    return entry.name
end

-- Both return the name as shown, or nil and why not.
function Sync.Add(fullName, reason)
    return AddName(fullName, reason, ns.Share.SendNow)
end

function Sync.Remove(key)
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local current = ns.SyncedEntries()[key]
    if not current or current.removed then return nil, "Navnet står ikke på guildlista i addonen." end
    SaveMyChange(key, {
        name = current.name,
        changedBy = MyFullName(),
        changedAt = NextChangeTime(current),
        removed = true,
    }, ns.Share.SendNow)
    return current.name
end

-- Adds every { fullName, reason } not already on the synced list (an import). Returns how
-- many were added, or nil and why not.
function Sync.AddMany(items)
    local problem = Sync.WhyCannotEdit()
    if problem then return nil, problem end
    local addedCount = 0
    for _, item in ipairs(items) do
        local current = ns.SyncedEntries()[ns.KeyFromFullName(item.fullName)]
        local isListed = current and not current.removed
        if not isListed and AddName(item.fullName, item.reason, ns.Share.SendBulk) then
            addedCount = addedCount + 1
        end
    end
    return addedCount
end

--------------------------------------------------------------------------------
-- Comparing lists with the guild
--------------------------------------------------------------------------------

-- Asks the guild for their lists. Returns false outside a guild (or before the game says which).
function Sync.SayHello()
    local entries = ns.SyncedEntries()
    if not entries then return false end
    helloSentAt = GetTime()
    answer = nil
    ns.Share.SendNow({ HELLO, ListChecksum(entries) })
    return true
end

function Sync.StatusText()
    if not lastSync then return "Synkes når andre med addonen er pålogget." end
    return ("Sist synket med %s %s."):format(lastSync.from, ns.TimeAgo(lastSync.at))
end

-- Answers an H1 heard at `helloHeardAt`, unless someone with the same list as ours has
-- answered since: the one who asked then has our list already.
local function SendWholeList(helloHeardAt)
    local entries = ns.SyncedEntries()
    if not entries then return end
    local checksum = ListChecksum(entries)
    if lastListSent.checksum == checksum and lastListSent.at >= helloHeardAt then return end
    lastListSent = { at = GetTime(), checksum = checksum }
    ns.Share.SendBulk({ LIST_START, checksum })
    for _, entry in pairs(entries) do
        ns.Share.SendBulk(EncodeEntry(entry))
    end
    ns.Share.SendBulk({ LIST_END })
end

-- After the answer to our H1: send the guild what that answer lacked or had older.
local function SendWhatTheyLack(theirVersions)
    local entries = ns.SyncedEntries()
    if not entries then return end
    for key, entry in pairs(entries) do
        local theirs = theirVersions[key]
        if not theirs or IsNewer(entry, theirs) then ns.Share.SendBulk(EncodeEntry(entry)) end
    end
end

ns.Share.OnMessage(HELLO, function(fields)
    local entries = ns.SyncedEntries()
    if not entries or fields[2] == ListChecksum(entries) then return end
    local helloHeardAt = GetTime()
    C_Timer.After(math.random(ANSWER_DELAY_MIN, ANSWER_DELAY_MAX), function()
        SendWholeList(helloHeardAt)
    end)
end)

ns.Share.OnMessage(LIST_START, function(fields, sender)
    lastListSent = { at = GetTime(), checksum = fields[2] }
    if answer or GetTime() - helloSentAt > ANSWER_WAIT then return end
    answer = { sender = sender, versions = {} }
end)

ns.Share.OnMessage(ENTRY, function(fields, sender)
    local key, incoming = DecodeEntry(fields)
    if not key then return end
    if answer and answer.sender == sender then answer.versions[key] = incoming end
    Merge(key, incoming)
end)

ns.Share.OnMessage(LIST_END, function(_, sender)
    lastSync = { at = GetServerTime(), from = Ambiguate(sender, "guild") }
    ns:Fire("KOS_SYNCED")
    if not (answer and answer.sender == sender) then return end
    local theirVersions = answer.versions
    answer = nil
    helloSentAt = -math.huge
    SendWhatTheyLack(theirVersions)
end)

ns:On("PLAYER_LOGIN", function()
    C_Timer.After(HELLO_DELAY, function()
        -- The game can still be loading guild data; one more try a little later.
        if not Sync.SayHello() then C_Timer.After(HELLO_DELAY, Sync.SayHello) end
    end)
end)
