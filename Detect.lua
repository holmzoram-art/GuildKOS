-- Finding listed characters near you. WoW Forever doesn't let addons read the combat log
-- (registering COMBAT_LOG_EVENT_UNFILTERED is forbidden there), so the addon looks at what
-- the game does let it see:
--   * nameplates: the earliest warning, but only with enemy nameplates turned on; the
--     "longNameplates" setting shows them as far away as the game allows
--   * your target, mouseover and focus, and what your party or raid targets
--   * whom your target, your focus or a unit with a nameplate has in target
--   * /say, /yell and emotes: the enemy faction's words are garbled, but the name is real
-- Battle.net friends in your zone are in Friends.lua.
-- Player characters' names stay readable in the open world, also in combat. In battlegrounds and
-- arenas the game can keep them secret (see ns.Plain); those sightings are skipped.
local _, ns = ...

local MAX_NAMEPLATES = 40   -- the game numbers nameplate units nameplate1 to nameplate40
local SEEN_NOTE_INTERVAL = 10 -- seconds between two "last seen" notes for the same name
local DISTANCE_CVAR = "nameplateMaxDistance"
local LONG_DISTANCE = "60"  -- yards; the most retail allows, and the game lowers it where less is allowed

local hasGivenNameplateTip = false
local isDistanceWaiting = false -- a nameplate distance change waits for combat to end
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
-- nameplate range doesn't set it off again and again. A sighting that comes with a first name
-- only (a chat sender can) matches a name saved with its last name too.
local function HandleSighting(firstName, lastName, howSeen)
    if not ns.db then return nil end
    local entry
    if lastName then
        entry = ns.FindEntry(firstName, lastName)
    else
        entry = ns.FindEntryByFirstName(firstName)
    end
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
    -- The name goes as it stands on the list, so every copy finds the same entry. Names that
    -- are only on your own list are never shared.
    local shouldShare = entry.inGuildList and ns.settings.shareSightings
    ns.Share.ReportOwnSighting(entry.key, entry.name, place, shouldShare)
    return entry
end

-- On WoW Forever, UnitName gives the first and the last name (see Core.lua).
local function CheckUnit(unit, howSeen)
    if not ns.Plain(UnitIsPlayer(unit)) then return nil end
    local fullName = ns.FullNameOfUnit(unit)
    if not fullName then return nil end
    local firstName, lastName = ns.SplitName(fullName)
    return HandleSighting(firstName, lastName, howSeen)
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

-- The "longNameplates" setting: nameplates as far away as the game allows. The distance the
-- player had before is kept in the saved data and put back when the setting is turned off.
-- The game blocks nameplate settings in combat, so a change then waits for combat to end.
local function ApplyNameplateDistance()
    if not (C_CVar and C_CVar.GetCVar and C_CVar.SetCVar) then return end
    if InCombatLockdown() then
        isDistanceWaiting = true
        return
    end
    isDistanceWaiting = false
    if ns.settings.longNameplates and not ns.db.nameplateDistanceBefore then
        ns.db.nameplateDistanceBefore = C_CVar.GetCVar(DISTANCE_CVAR) or ""
        C_CVar.SetCVar(DISTANCE_CVAR, LONG_DISTANCE)
        ns:Print(("Navneplater vises nå på opptil %s meter."):format(C_CVar.GetCVar(DISTANCE_CVAR) or LONG_DISTANCE))
    elseif not ns.settings.longNameplates and ns.db.nameplateDistanceBefore then
        if ns.db.nameplateDistanceBefore ~= "" then C_CVar.SetCVar(DISTANCE_CVAR, ns.db.nameplateDistanceBefore) end
        ns.db.nameplateDistanceBefore = nil
        ns:Print("Navneplatene har fått tilbake avstanden de hadde før.")
    end
end

-- Whose target to look at when UNIT_TARGET fires for `unit`, and how that sighting is shown;
-- nil for units the addon doesn't follow.
local function TargetSource(unit)
    if IsGroupUnit(unit) then return "groupTarget" end
    if unit == "target" or unit == "focus" then return "targetTarget" end
    if unit:find("^nameplate%d") then return "plateTarget" end
    return nil
end

ns:On("NAME_PLATE_UNIT_ADDED", CheckNameplate)
ns:On("NAME_PLATE_UNIT_REMOVED", function(unit) ns.Nearby.ClearPlate(unit) end)
ns:On("UPDATE_MOUSEOVER_UNIT", function() CheckUnit("mouseover", "mouseover") end)

ns:On("PLAYER_TARGET_CHANGED", function()
    CheckUnit("target", "target")
    CheckUnit("targettarget", "targetTarget")
end)

ns:On("PLAYER_FOCUS_CHANGED", function()
    CheckUnit("focus", "focus")
    CheckUnit("focustarget", "targetTarget")
end)

ns:On("UNIT_TARGET", function(unit)
    unit = ns.Plain(unit)
    if type(unit) ~= "string" then return end
    local howSeen = TargetSource(unit)
    if howSeen then CheckUnit(unit .. "target", howSeen) end
end)

ns:On("KOS_SETTINGS_CHANGED", ApplyNameplateDistance)

ns:On("PLAYER_REGEN_ENABLED", function()
    if isDistanceWaiting then ApplyNameplateDistance() end
end)

for eventName, howSeen in pairs(CHAT_SOURCES) do
    ns:On(eventName, function(_, sender)
        sender = ns.Plain(sender)
        if type(sender) ~= "string" or sender == "" then return end
        local firstName, lastName = ns.SplitName(sender)
        if not ns.IsValidFullName(firstName, lastName) then return end
        HandleSighting(firstName, lastName, howSeen)
    end)
end

ns:On("PLAYER_ENTERING_WORLD", function()
    ns.Nearby.ClearAllPlates()
    C_Timer.After(2, ScanNameplates)
    GiveNameplateTip()
end)

-- A name just added may already be standing in front of you.
ns:On("KOS_LIST_CHANGED", ScanNameplates)
