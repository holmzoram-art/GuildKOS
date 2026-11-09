-- Hidden addon messages between guild members who have the addon, on the guild channel.
-- A message is fields joined by tabs, and the first field says what it is:
--   S1  name, place                          someone from the guild list was seen there
--   K1  name, killer, place, kills of that name, the killer's KOS kills, 1 or 0
--                                            someone from the guild list was killed; the last
--                                            field is 1 when guild chat already said so
--   E1, H1, D1, D2                           the guild list (Sync.lua)
-- Only the guild list is ever shared. Your own list stays on your computer.
--
-- The game lets an addon send about one message a second, so messages wait in three queues,
-- sent in this order:
--   urgent  sightings and kills; old news soon, so beyond URGENT_MAX they are dropped
--   edits   list changes; these are never dropped, also while the game blocks addon messages
--   list    a whole list for Sync.lua; a new whole list replaces the one still waiting
local _, ns = ...

local Share = {}
ns.Share = Share

local PREFIX = "GuildKOS"
local SIGHTING = "S1"
local KILL = "K1"
local FIELD_SEPARATOR = "\t"
local SEND_GAP = 1           -- seconds between messages
local LOCKDOWN_RETRY = 5     -- seconds before trying again while the game blocks addon messages
local THROTTLE_RETRY = 10    -- seconds to wait after the game says we send too fast
local URGENT_MAX = 10        -- sightings and kills waiting to go
local EDITS_MAX = 2000       -- list changes waiting to go (an import of a very long list)
local MAX_MESSAGE_BYTES = 255 -- the game's limit for one addon message
local REPORT_PAUSE = 600     -- seconds; a name is reported to (and shown from) the guild once in this time
local MAX_PLACE_BYTES = 100  -- keeps a message well under MAX_MESSAGE_BYTES

-- Each waiting message is { text, skipIf }; skipIf, when there, is asked just before sending
-- and drops the message when it returns true (someone else already sent the same thing).
local urgentOutbox = {}
local editOutbox = {}
local listOutbox = {}
local OUTBOXES = { urgentOutbox, editOutbox, listOutbox }

local isSending = false
local lastReportAt = {}    -- key -> GetTime() the name was last reported: by you, or heard from the guild
local handlersByKind = {}  -- "S1" -> function(fields, sender)

-- For /kos status: who this copy has heard from, and how its own sending goes.
local heardFrom = {}       -- sender -> { count, lastAt = GetServerTime(), lastKind = "E1" }
local sentCount = 0
local lastSendAnswer       -- the game's answer to our last message: "Success", a throttle, an error

-- Whether the game blocks addon messages right now (boss fights, some instances). Only a
-- plain true counts; a check that is missing or errors doesn't block anything.
local LOCKDOWN_CHECKS = { "InChatMessagingLockdown", "AreOutgoingAddonChatMessagesRestricted" }

function Share.IsChatLockedDown()
    for _, checkName in ipairs(LOCKDOWN_CHECKS) do
        local check = C_ChatInfo[checkName]
        if check then
            local ok, isRestricted = pcall(check)
            if ok and isRestricted == true then return true end
        end
    end
    return false
end

-- The name of the game's answer to a SendAddonMessage call: a name from
-- Enum.SendAddonMessageResult ("Success", "AddonMessageThrottle", ...), "Success"/"Failed" on
-- clients that answer true or false, or "Error" when the call threw.
local function SendAnswerName(ok, result)
    if not ok then return "Error" end
    if type(result) == "boolean" then return result and "Success" or "Failed" end
    if type(result) == "number" and Enum and Enum.SendAddonMessageResult then
        for name, value in pairs(Enum.SendAddonMessageResult) do
            if value == result then return name end
        end
    end
    return "Success"
end

-- An answer whose name mentions throttling means "too fast, try again later".
local function IsThrottled(answerName)
    return answerName:find("Throttle") ~= nil
end

local function FirstWaitingOutbox()
    for _, outbox in ipairs(OUTBOXES) do
        if outbox[1] then return outbox end
    end
    return nil
end

local function DropEverything()
    for _, outbox in ipairs(OUTBOXES) do
        wipe(outbox)
    end
end

-- Sends the first waiting message, then waits SEND_GAP before the next. While the game blocks
-- addon messages or says we send too fast, the message stays first in line and is tried again.
local function SendNext()
    local outbox = FirstWaitingOutbox()
    if not outbox then
        isSending = false
        return
    end
    if not IsInGuild() then
        DropEverything()
        isSending = false
        return
    end
    local message = outbox[1]
    if message.skipIf and message.skipIf() then
        table.remove(outbox, 1)
        return SendNext()
    end
    if Share.IsChatLockedDown() then
        C_Timer.After(LOCKDOWN_RETRY, SendNext)
        return
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message.text, "GUILD")
    lastSendAnswer = SendAnswerName(ok, result)
    if IsThrottled(lastSendAnswer) then
        C_Timer.After(THROTTLE_RETRY, SendNext)
        return
    end
    sentCount = sentCount + 1
    table.remove(outbox, 1)
    C_Timer.After(SEND_GAP, SendNext)
end

local function StartSending()
    if isSending then return end
    isSending = true
    SendNext()
end

-- The message for a list of string fields, or nil when it would be longer than the game takes.
local function MessageFor(fields, skipIf)
    local text = table.concat(fields, FIELD_SEPARATOR)
    if #text > MAX_MESSAGE_BYTES then return nil end
    return { text = text, skipIf = skipIf }
end

local function Queue(outbox, maxWaiting, message, atFront)
    if not (IsInGuild() and message) or #outbox >= maxWaiting then return end
    table.insert(outbox, atFront and 1 or #outbox + 1, message)
    StartSending()
end

-- A sighting: dropped when the urgent queue is full.
function Share.SendNow(fields)
    Queue(urgentOutbox, URGENT_MAX, MessageFor(fields))
end

-- A kill: goes first, so group members waiting to stand in hear it in time.
function Share.SendFirst(fields)
    Queue(urgentOutbox, URGENT_MAX, MessageFor(fields), true)
end

-- A change to the guild list. `skipIf` (optional) is asked just before sending.
function Share.SendEdit(fields, skipIf)
    Queue(editOutbox, EDITS_MAX, MessageFor(fields, skipIf))
end

-- A whole list (a list of field lists). Replaces the whole list still waiting, if any.
function Share.SendList(messagesFields)
    if not IsInGuild() then return end
    wipe(listOutbox)
    for _, fields in ipairs(messagesFields) do
        local message = MessageFor(fields)
        if message then table.insert(listOutbox, message) end
    end
    StartSending()
end

-- Text from another player's game: "|" could start color or link codes, and a tab would split
-- the message, so both are removed.
function Share.CleanText(text)
    return ((text or ""):gsub("[|\t]", ""))
end

-- `handler(fields, sender)` runs for each message whose first field is `kind`. `sender` is
-- the name of the guild member who sent it ("First Last" on WoW Forever).
function Share.OnMessage(kind, handler)
    handlersByKind[kind] = handler
end

local function SplitFields(text)
    local fields = {}
    for field in (text .. FIELD_SEPARATOR):gmatch("(.-)" .. FIELD_SEPARATOR) do
        table.insert(fields, field)
    end
    return fields
end

-- The guild-list entry a message names, or nil when the name isn't on our guild list.
local function GuildEntryFor(listName)
    local entry = ns.FindListEntry(listName)
    if not (entry and entry.inGuildList) then return nil end
    return entry
end

--------------------------------------------------------------------------------
-- Sightings and kills
--------------------------------------------------------------------------------

-- No spam: the guild hears about a name at most once per REPORT_PAUSE, whoever sees it. A
-- report heard from the guild, or your own alert, starts that time again.
local function WasReportedRecently(key)
    return lastReportAt[key] ~= nil and GetTime() - lastReportAt[key] < REPORT_PAUSE
end

-- Your own alert for a listed name. Tells the guild when `shouldShare` is set and the guild
-- hasn't heard about the name lately, and keeps the guild's reports of it quiet for a while,
-- since you know already. Names go as "First Last" (or just "First").
-- `listName` is the name as it stands on the list ("First Last" or "<Guild>"); for a member
-- of a listed guild, `playerName` is who it was, so the guild sees that too.
function Share.ReportOwnSighting(key, listName, place, shouldShare, playerName)
    local wasReported = WasReportedRecently(key)
    lastReportAt[key] = GetTime()
    if not shouldShare or wasReported then return end
    Share.SendNow({ SIGHTING, listName, (place or ""):sub(1, MAX_PLACE_BYTES), playerName or "" })
end

function Share.AnnounceKill(listName, killerName, place, count, killerCount, isPostedInChat, playerName)
    Share.SendFirst({
        KILL,
        listName,
        killerName,
        (place or ""):sub(1, MAX_PLACE_BYTES),
        tostring(count),
        tostring(killerCount or 0),
        isPostedInChat and "1" or "0",
        playerName or "",
    })
end

Share.OnMessage(SIGHTING, function(fields, sender)
    local entry = GuildEntryFor(fields[2])
    if not entry then return end
    local reporter = Ambiguate(sender, "guild")
    local place = Share.CleanText(fields[3])
    ns.NoteLastSeen(entry.key, place, reporter)
    local wasReported = WasReportedRecently(entry.key)
    lastReportAt[entry.key] = GetTime()
    if wasReported or not ns.settings.showGuildReports then return end
    local shown = ns.ShownName(entry, Share.CleanText(fields[4]))
    ns:Print(("|cffff5050%s|r sett av %s: %s"):format(shown, reporter, place ~= "" and place or "?"))
end)

Share.OnMessage(KILL, function(fields)
    local entry = GuildEntryFor(fields[2])
    local killerName = Share.CleanText(fields[3])
    if not entry or not ns.IsValidFullName(ns.SplitName(killerName)) then return end
    ns.Kills.TakeReport(entry, killerName, Share.CleanText(fields[4]), fields[5], fields[6], fields[7] == "1",
        Share.CleanText(fields[8]))
end)

ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    prefix, text, channel, sender = ns.Plain(prefix), ns.Plain(text), ns.Plain(channel), ns.Plain(sender)
    if prefix ~= PREFIX or channel ~= "GUILD" or type(text) ~= "string" or type(sender) ~= "string" then return end
    -- Our own messages come back to us too. On WoW Forever the sender reads "First Last".
    if ns.IsMe(sender) then return end
    local fields = SplitFields(text)
    local heard = heardFrom[sender] or { count = 0 }
    heard.count = heard.count + 1
    heard.lastAt = GetServerTime()
    heard.lastKind = fields[1]
    heardFrom[sender] = heard
    local handler = handlersByKind[fields[1]]
    if handler then handler(fields, sender) end
end)

ns:On("PLAYER_LOGIN", function()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end)

-- What /kos status shows about messages:
-- { heard = { { sender, count, lastAt, lastKind }, ... } (most recent first), sentCount,
--   lastSendAnswer, waitingCount, isLockedDown, isPrefixRegistered }
function Share.Status()
    local heard = {}
    for sender, record in pairs(heardFrom) do
        table.insert(heard, { sender = sender, count = record.count, lastAt = record.lastAt, lastKind = record.lastKind })
    end
    table.sort(heard, function(first, second) return first.lastAt > second.lastAt end)
    local isRegistered = C_ChatInfo.IsAddonMessagePrefixRegistered
        and C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)
    return {
        heard = heard,
        sentCount = sentCount,
        lastSendAnswer = lastSendAnswer,
        waitingCount = #urgentOutbox + #editOutbox + #listOutbox,
        isLockedDown = Share.IsChatLockedDown(),
        isPrefixRegistered = isRegistered,
    }
end
