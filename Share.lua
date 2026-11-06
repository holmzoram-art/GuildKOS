-- Hidden addon messages between guild members who have the addon, on the guild channel.
-- A message is fields joined by tabs, and the first field says what it is:
--   S1  Name-Realm, place                    someone from the guild list was seen there
--   K1  Name-Realm, killer, place, kills of that name, the killer's KOS kills, 1 or 0
--                                            someone from the guild list was killed; the last
--                                            field is 1 when guild chat already said so
--   E1, H1, D1, D2                           the synced guild list (Sync.lua)
-- Only the guild list is ever shared. Your own list stays on your computer.
local _, ns = ...

local Share = {}
ns.Share = Share

local PREFIX = "GuildKOS"
local SIGHTING = "S1"
local KILL = "K1"
local FIELD_SEPARATOR = "\t"
local SEND_GAP = 1          -- seconds between messages; the game lets an addon send about one a second
local URGENT_MAX = 10       -- sightings, kills and edits waiting to go; more than that are dropped
local BULK_MAX = 600        -- synced-list messages waiting to go
local REPORT_PAUSE = 120    -- seconds before the same name's guild report shows again
local MAX_PLACE_BYTES = 100 -- keeps a message well under the game's 255-byte limit

-- Urgent messages go before bulk ones, so a sighting isn't stuck behind a whole list.
local urgentOutbox = {}
local bulkOutbox = {}
local isSending = false
local lastReportAt = {}    -- key -> GetTime() of the last guild report printed for it
local handlersByKind = {}  -- "S1" -> function(fields, sender)

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

-- Sends the next waiting message, then waits SEND_GAP before the one after. A message the
-- game won't take right now is dropped: the list is compared again at the next login.
local function SendNext()
    local text = table.remove(urgentOutbox, 1) or table.remove(bulkOutbox, 1)
    if not text then
        isSending = false
        return
    end
    if IsInGuild() and not Share.IsChatLockedDown() then
        pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "GUILD")
    end
    C_Timer.After(SEND_GAP, SendNext)
end

local function Queue(outbox, maxWaiting, text)
    if not IsInGuild() or #outbox >= maxWaiting then return end
    table.insert(outbox, text)
    if isSending then return end
    isSending = true
    SendNext()
end

-- `fields` is a list of strings; they are joined with tabs into one message.
function Share.SendNow(fields)
    Queue(urgentOutbox, URGENT_MAX, table.concat(fields, FIELD_SEPARATOR))
end

function Share.SendBulk(fields)
    Queue(bulkOutbox, BULK_MAX, table.concat(fields, FIELD_SEPARATOR))
end

-- Text from another player's game: "|" could start color or link codes, and a tab would split
-- the message, so both are removed.
function Share.CleanText(text)
    return ((text or ""):gsub("[|\t]", ""))
end

-- `handler(fields, sender)` runs for each message whose first field is `kind`. `sender` is
-- the "Name-Realm" of the guild member who sent it.
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
local function GuildEntryFor(fullName)
    local name, realm = ns.SplitName(fullName or "")
    if not ns.IsValidName(name) then return nil end
    local entry = ns.FindEntry(name, realm)
    if not (entry and entry.inGuildList) then return nil end
    return entry
end

--------------------------------------------------------------------------------
-- Sightings and kills
--------------------------------------------------------------------------------

function Share.AnnounceSighting(name, realm, place)
    local fullName = name .. "-" .. (realm or ns.OwnRealm())
    Share.SendNow({ SIGHTING, fullName, (place or ""):sub(1, MAX_PLACE_BYTES) })
end

function Share.AnnounceKill(victimName, victimRealm, killerName, place, count, killerCount, isPostedInChat)
    Share.SendNow({
        KILL,
        victimName .. "-" .. (victimRealm or ns.OwnRealm()),
        killerName,
        (place or ""):sub(1, MAX_PLACE_BYTES),
        tostring(count),
        tostring(killerCount or 0),
        isPostedInChat and "1" or "0",
    })
end

Share.OnMessage(SIGHTING, function(fields, sender)
    local entry = GuildEntryFor(fields[2])
    if not entry then return end
    local reporter = Ambiguate(sender, "guild")
    local place = Share.CleanText(fields[3])
    ns.NoteLastSeen(entry.key, place, reporter)
    if not ns.settings.showGuildReports then return end
    local now = GetTime()
    if lastReportAt[entry.key] and now - lastReportAt[entry.key] < REPORT_PAUSE then return end
    lastReportAt[entry.key] = now
    ns:Print(("|cffff5050%s|r sett av %s: %s"):format(entry.name, reporter, place ~= "" and place or "?"))
end)

Share.OnMessage(KILL, function(fields)
    local entry = GuildEntryFor(fields[2])
    local killerName = Share.CleanText(fields[3])
    if not entry or not ns.IsValidName(killerName) then return end
    ns.Kills.TakeReport(entry, killerName, Share.CleanText(fields[4]), fields[5], fields[6], fields[7] == "1")
end)

ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    prefix, text, sender = ns.Plain(prefix), ns.Plain(text), ns.Plain(sender)
    if prefix ~= PREFIX or channel ~= "GUILD" or type(text) ~= "string" or type(sender) ~= "string" then return end
    if Ambiguate(sender, "none") == UnitName("player") then return end
    local fields = SplitFields(text)
    local handler = handlersByKind[fields[1]]
    if handler then handler(fields, sender) end
end)

ns:On("PLAYER_LOGIN", function()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end)
