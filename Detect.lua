-- Finding listed characters near you. WoW Forever doesn't let addons read the combat log
-- (registering COMBAT_LOG_EVENT_UNFILTERED is forbidden there), so the addon looks at what
-- the game does let it see:
--   * nameplates: the earliest warning, but only with enemy nameplates turned on
--   * your target, mouseover and focus, and what your party or raid targets
--   * /say, /yell and emotes: the enemy faction's words are garbled, but the name is real
-- Player characters' names stay readable in the open world, also in combat. In battlegrounds and
-- arenas the game can keep them secret (see ns.Plain); those sightings are skipped.
local _, ns = ...

local MAX_NAMEPLATES = 40   -- the game numbers nameplate units nameplate1 to nameplate40
local SEEN_NOTE_INTERVAL = 10 -- seconds between two "last seen" notes for the same name

local hasGivenNameplateTip = false
local lastAlertAt = {}  -- key -> GetTime() of that name's last alert
local lastNotedAt = {}  -- key -> GetTime() of that name's last "last seen" note

local CHAT_SOURCES = {
    CHAT_MSG_SAY = "say",
    CHAT_MSG_YELL = "yell",
    CHAT_MSG_EMOTE = "emote",
    CHAT_MSG_TEXT_EMOTE = "emote",
}

-- Every sighting comes through here. Returns the entry when the name is listed. "Last seen"
-- is noted at most every SEEN_NOTE_INTERVAL seconds. The alert, and telling the guild, waits
-- alertPause seconds between two for the same name, so someone running in and out of
-- nameplate range doesn't set it off again and again.
local function HandleSighting(name, realm, howSeen)
    if not ns.db then return nil end
    local entry = ns.FindEntry(name, realm)
    if not entry then return nil end
    ns.Nearby.Note(entry, howSeen)
    local now = GetTime()
    local place = ns.CurrentPlace()
    if not lastNotedAt[entry.key] or now - lastNotedAt[entry.key] >= SEEN_NOTE_INTERVAL then
        lastNotedAt[entry.key] = now
        ns.NoteLastSeen(entry.key, place, nil)
    end
    if lastAlertAt[entry.key] and now - lastAlertAt[entry.key] < ns.settings.alertPause then return entry end
    lastAlertAt[entry.key] = now
    ns.Alert.Show(entry, howSeen)
    if entry.inGuildList and ns.settings.shareSightings then
        ns.Share.AnnounceSighting(name, realm, place)
    end
    return entry
end

local function CheckUnit(unit, howSeen)
    if not ns.Plain(UnitIsPlayer(unit)) then return nil end
    local name, realm = UnitName(unit)
    name, realm = ns.Plain(name), ns.Plain(realm)
    if not name or name == "" or name == UNKNOWNOBJECT then return nil end
    return HandleSighting(name, realm, howSeen)
end

local function CheckNameplate(unit)
    local entry = CheckUnit(unit, "nameplate")
    if entry then ns.Nearby.SetPlate(unit, entry.key) end
end

-- Looks at every nameplate on screen now. The unit names are tried directly, since the field
-- that holds a nameplate frame's unit has changed name between game versions.
local function ScanNameplates()
    for index = 1, MAX_NAMEPLATES do
        local unit = "nameplate" .. index
        if UnitExists(unit) then CheckNameplate(unit) end
    end
end

local function IsGroupUnit(unit)
    return unit:find("^party%d") ~= nil or unit:find("^raid%d") ~= nil
end

function ns.EnemyNameplatesOn()
    if not (C_CVar and C_CVar.GetCVarBool) then return true end
    return C_CVar.GetCVarBool("nameplateShowEnemies") == true
end

-- The game blocks nameplate settings in combat, so the player is told to try again after.
function ns.TurnOnEnemyNameplates()
    if InCombatLockdown() then
        ns:Print("Navneplater kan ikke endres i kamp. Prøv igjen etterpå.")
        return
    end
    C_CVar.SetCVar("nameplateShowEnemies", "1")
    ns:Print("Fiendtlige navneplater er slått på.")
    ns:Fire("KOS_SETTINGS_CHANGED")
end

local function GiveNameplateTip()
    if hasGivenNameplateTip or ns.EnemyNameplatesOn() then return end
    hasGivenNameplateTip = true
    ns:Print("Fiendtlige navneplater er av, så varselet kommer senere. Skriv /kos plates for å slå dem på.")
end

ns:On("NAME_PLATE_UNIT_ADDED", CheckNameplate)
ns:On("NAME_PLATE_UNIT_REMOVED", function(unit) ns.Nearby.ClearPlate(unit) end)
ns:On("PLAYER_TARGET_CHANGED", function() CheckUnit("target", "target") end)
ns:On("UPDATE_MOUSEOVER_UNIT", function() CheckUnit("mouseover", "mouseover") end)
ns:On("PLAYER_FOCUS_CHANGED", function() CheckUnit("focus", "focus") end)

ns:On("UNIT_TARGET", function(unit)
    unit = ns.Plain(unit)
    if type(unit) ~= "string" or not IsGroupUnit(unit) then return end
    CheckUnit(unit .. "target", "groupTarget")
end)

for eventName, howSeen in pairs(CHAT_SOURCES) do
    ns:On(eventName, function(_, sender)
        sender = ns.Plain(sender)
        if type(sender) ~= "string" or sender == "" then return end
        local name, realm = ns.SplitName(sender)
        HandleSighting(name, realm, howSeen)
    end)
end

ns:On("PLAYER_ENTERING_WORLD", function()
    ns.Nearby.ClearAllPlates()
    C_Timer.After(2, ScanNameplates)
    GiveNameplateTip()
end)

-- A name just added may already be standing in front of you.
ns:On("KOS_LIST_CHANGED", ScanNameplates)
