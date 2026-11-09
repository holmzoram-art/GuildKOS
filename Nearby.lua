-- A small window listing the listed characters seen in the last minute, so you can tell who is
-- still around after the first alert. A name whose nameplate is still on screen reads "nå".
-- Drag it with the left mouse button to move it.
local _, ns = ...

local Nearby = {}
ns.Nearby = Nearby

local KEEP_SECONDS = 60     -- a name leaves the window this long after it was last seen
local MAX_ROWS = 6
local ROW_HEIGHT = 16
local WINDOW_WIDTH = 240
local HEADER_HEIGHT = 28
local REFRESH_INTERVAL = 1  -- seconds between updates while the window is shown

local WINDOW_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local sightingsByKey = {} -- key -> { entry, howSeen, seenAt = GetTime() }
local keyByPlate = {}     -- nameplate unit ("nameplate3") -> key, while a listed name's plate is shown
local window

function Nearby.SetPlate(unit, key)
    keyByPlate[unit] = key
end

function Nearby.ClearPlate(unit)
    keyByPlate[unit] = nil
end

-- Loading screens take every nameplate away.
function Nearby.ClearAllPlates()
    wipe(keyByPlate)
end

local function IsOnNameplate(key)
    for _, plateKey in pairs(keyByPlate) do
        if plateKey == key then return true end
    end
    return false
end

local function DropOldSightings(now)
    for key, sighting in pairs(sightingsByKey) do
        if IsOnNameplate(key) then
            sighting.seenAt = now
        elseif now - sighting.seenAt > KEEP_SECONDS then
            sightingsByKey[key] = nil
        end
    end
end

local function SortedSightings()
    local sightings = {}
    for _, sighting in pairs(sightingsByKey) do
        table.insert(sightings, sighting)
    end
    table.sort(sightings, function(first, second) return first.seenAt > second.seenAt end)
    return sightings
end

local function SavePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint()
    ns.db.nearbyPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function PlaceWindow(frame)
    local position = ns.db.nearbyPosition
    frame:ClearAllPoints()
    if position then
        frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    else
        frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -250, -220)
    end
end

local function CreateRow(frame, index)
    local top = -HEADER_HEIGHT - (index - 1) * ROW_HEIGHT
    local row = {}
    row.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 10, top)
    row.name:SetWidth(WINDOW_WIDTH - 70)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.age = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.age:SetPoint("TOPRIGHT", -10, top)
    return row
end

local function CreateWindow()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, HEADER_HEIGHT + MAX_ROWS * ROW_HEIGHT)
    frame:SetBackdrop(WINDOW_BACKDROP)
    frame:SetBackdropColor(0.15, 0, 0, 0.85)
    frame:SetBackdropBorderColor(1, 0.2, 0.2)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    PlaceWindow(frame)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -9)
    title:SetText("|cffff4040KOS i nærheten|r")

    frame.rows = {}
    for index = 1, MAX_ROWS do
        frame.rows[index] = CreateRow(frame, index)
    end

    local secondsSinceRefresh = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        secondsSinceRefresh = secondsSinceRefresh + elapsed
        if secondsSinceRefresh < REFRESH_INTERVAL then return end
        secondsSinceRefresh = 0
        Nearby.Refresh()
    end)
    return frame
end

local function FillRow(row, sighting, now)
    if not sighting then
        row.name:SetText("")
        row.age:SetText("")
        return
    end
    local howSeen = ns.HOW_SEEN_TEXT[sighting.howSeen] or sighting.howSeen
    row.name:SetText(("|cffff5050%s|r |cff999999%s|r"):format(sighting.entry.name, howSeen))
    if IsOnNameplate(sighting.entry.nearbyKey or sighting.entry.key) then
        row.age:SetText("|cffff5050nå|r")
    else
        row.age:SetText(("%d s"):format(now - sighting.seenAt))
    end
end

function Nearby.Refresh()
    local now = GetTime()
    DropOldSightings(now)
    local sightings = SortedSightings()
    if #sightings == 0 or not ns.settings.showNearbyWindow then
        if window then window:Hide() end
        return
    end
    window = window or CreateWindow()
    for index = 1, MAX_ROWS do
        FillRow(window.rows[index], sightings[index], now)
    end
    window:SetHeight(HEADER_HEIGHT + math.min(#sightings, MAX_ROWS) * ROW_HEIGHT + 6)
    window:Show()
end

-- Each character gets a row, also when several match one guild on a list (entry.nearbyKey).
function Nearby.Note(entry, howSeen)
    sightingsByKey[entry.nearbyKey or entry.key] = { entry = entry, howSeen = howSeen, seenAt = GetTime() }
    Nearby.Refresh()
end

-- A name (or guild) taken off the lists leaves the window too.
ns:On("KOS_LIST_CHANGED", function()
    for key, sighting in pairs(sightingsByKey) do
        if not ns.EntryFor(sighting.entry.key) then sightingsByKey[key] = nil end
    end
    Nearby.Refresh()
end)

ns:On("KOS_SETTINGS_CHANGED", Nearby.Refresh)
