-- Battle.net friends on the KOS lists. Players who left for the other faction are often still
-- on someone's Battle.net friends list, and that list shows which zone their character is in.
-- When one of them is in the same zone as you, you get an alert, once per zone. The list says
-- the zone, not how far away, so this is a heads-up rather than "nearby".
-- Only the character's name and zone are read. Nothing about friends is shared with the guild.
local _, ns = ...

local SCAN_INTERVAL = 30   -- seconds between two looks at the friends list
local CHANGE_DELAY = 2     -- seconds; many friend updates in a row lead to one look
local WOW_CLIENT = BNET_CLIENT_WOW or "WoW"

local zoneAlertedByKey = {} -- key -> the zone we last alerted about that name in
local isScanWaiting = false

-- The list entry for a friend's character, or nil. The friends list may give the first name
-- only; then any entry with that first name counts.
local function EntryForCharacter(characterName)
    local firstName, lastName = ns.SplitName(characterName)
    if not ns.IsValidFullName(firstName, lastName) then return nil end
    if lastName then return ns.FindEntry(firstName, lastName) end
    return ns.FindEntryByFirstName(firstName)
end

-- A game account of a friend that is a WoW character in `myZone` and on a list: alerts once
-- for that zone, and marks the name as still in the zone in `inZoneNow`.
local function CheckGameAccount(account, myZone, inZoneNow)
    if not (account and account.isOnline and account.clientProgram == WOW_CLIENT) then return end
    if account.wowProjectID and WOW_PROJECT_ID and account.wowProjectID ~= WOW_PROJECT_ID then return end
    local characterName, areaName = ns.Plain(account.characterName), ns.Plain(account.areaName)
    if type(characterName) ~= "string" or areaName ~= myZone then return end
    local entry = EntryForCharacter(characterName)
    if not entry then return end
    inZoneNow[entry.key] = true
    if zoneAlertedByKey[entry.key] == myZone then return end
    zoneAlertedByKey[entry.key] = myZone
    ns.NoteLastSeen(entry.key, areaName, nil)
    ns.Alert.Show(entry, "friendZone")
end

local function ScanFriends()
    isScanWaiting = false
    if not (ns.db and ns.settings.watchFriends) then return end
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts) then return end
    local myZone = GetRealZoneText()
    if not myZone or myZone == "" then return end
    local inZoneNow = {}
    local friendCount = BNGetNumFriends() or 0
    for friendIndex = 1, friendCount do
        for accountIndex = 1, C_BattleNet.GetFriendNumGameAccounts(friendIndex) or 0 do
            CheckGameAccount(C_BattleNet.GetFriendGameAccountInfo(friendIndex, accountIndex), myZone, inZoneNow)
        end
    end
    -- A name that left the zone can alert again when it comes back.
    for key in pairs(zoneAlertedByKey) do
        if not inZoneNow[key] then zoneAlertedByKey[key] = nil end
    end
end

local function ScanSoon()
    if isScanWaiting then return end
    isScanWaiting = true
    C_Timer.After(CHANGE_DELAY, ScanFriends)
end

ns:On("PLAYER_LOGIN", function()
    C_Timer.NewTicker(SCAN_INTERVAL, ScanFriends)
    ScanSoon()
end)

ns:On("BN_FRIEND_INFO_CHANGED", ScanSoon)
ns:On("BN_FRIEND_ACCOUNT_ONLINE", ScanSoon)
ns:On("ZONE_CHANGED_NEW_AREA", ScanSoon)
ns:On("KOS_LIST_CHANGED", ScanSoon)
ns:On("KOS_SETTINGS_CHANGED", ScanSoon)
