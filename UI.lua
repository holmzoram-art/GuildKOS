-- The /kos window: add names, see every listed name with how often it was killed and where
-- it was last seen, and choose how alerts look and sound. The small building blocks at the
-- top (UI.CreateText, UI.CreateButton, UI.AddTooltip, the backdrops) are used by
-- ExportImport.lua too.
local _, ns = ...

local UI = {}
ns.UI = UI

local WINDOW_NAME = "GuildKOSWindow" -- a global name, so Escape can close the window
local WINDOW_WIDTH = 420
local WINDOW_HEIGHT = 580
local EDGE = 22 -- space between the window's border and its content
local CONTENT_WIDTH = WINDOW_WIDTH - 2 * EDGE
local LIST_TOP = -178
local LIST_HEIGHT = 200
local LIST_INSET = 6        -- space inside the list's border
local SCROLLBAR_SPACE = 24  -- room for the scroll bar at the list's right
local LIST_WIDTH = CONTENT_WIDTH - 2 * LIST_INSET - SCROLLBAR_SPACE
local ROW_HEIGHT = 32
local OPTIONS_TOP = LIST_TOP - LIST_HEIGHT - 14
local CHECKBOX_SPACING = 24
local ALERT_PAUSES = { 30, 60, 120, 300 } -- seconds, the choices behind the "Nytt varsel" button
local REMOVE_POPUP = "GUILDKOS_REMOVE_FROM_GUILD_LIST"

local GUILD_TAG = "|cff40ff40Guild|r"
local PERSONAL_TAG = "|cff66b3ffMin|r"

UI.WINDOW_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

UI.LIST_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local CHECKBOXES = {
    { key = "playSound", label = "Spill lyd" },
    { key = "flashScreen", label = "Blink rundt skjermkanten" },
    { key = "showBanner", label = "Stor tekst på skjermen" },
    { key = "showNearbyWindow", label = "Vis «KOS i nærheten»-vinduet" },
    { key = "shareSightings", label = "Si fra til guilden",
        tooltip = "Når du ser noen fra guildlista, får guildmedlemmer med addonen beskjed om hvor. "
            .. "Din egen liste deles aldri." },
    { key = "showGuildReports", label = "Vis guildens varsler i chat" },
    { key = "announceKills", label = "Kunngjør drap i guildchat",
        tooltip = "Når du eller gruppa di dreper noen fra guildlista, skriver addonen det i guildchat, "
            .. "med hvor mange ganger de er tatt." },
    { key = "longNameplates", label = "Navneplater på lang avstand",
        tooltip = "Viser navneplater så langt unna som spillet tillater (opptil 60 meter), så varselet "
            .. "kommer tidligere. Avstanden du hadde før, kommer tilbake når du slår det av." },
    { key = "watchFriends", label = "Varsle om Battle.net-venner",
        tooltip = "Står karakteren til en Battle.net-venn på lista, får du varsel når den er i samme sone "
            .. "som deg. Vennelista viser sonen, ikke hvor langt unna." },
}

local window
local rows = {}

--------------------------------------------------------------------------------
-- Small building blocks
--------------------------------------------------------------------------------

-- `getText` is asked for the title and text each time the mouse comes over `frame`.
function UI.AddTooltip(frame, getText)
    frame:SetScript("OnEnter", function(self)
        local title, text = getText()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.CreateText(parent, fontObject, text)
    local fontString = parent:CreateFontString(nil, "OVERLAY", fontObject)
    if text then fontString:SetText(text) end
    return fontString
end

function UI.CreateButton(parent, width, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    -- Lets a greyed-out button still show its tooltip, which says why it is greyed out.
    if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    return button
end

-- A movable window with a title and a close button. Escape closes it too.
function UI.CreateWindow(globalName, width, height, titleText)
    local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetBackdrop(UI.WINDOW_BACKDROP)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    -- Two windows share the DIALOG layer; a top-level one comes in front of the other when
    -- shown or clicked, so the other's buttons don't show (and catch clicks) through it.
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    table.insert(UISpecialFrames, globalName)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    local title = UI.CreateText(frame, "GameFontNormalLarge", titleText)
    title:SetPoint("TOP", 0, -18)
    return frame
end

local function CreateInput(parent, width, labelText)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetSize(width, 22)
    input:SetAutoFocus(false)
    input:SetScript("OnEscapePressed", input.ClearFocus)
    local label = UI.CreateText(input, "GameFontNormalSmall", labelText)
    label:SetPoint("BOTTOMLEFT", input, "TOPLEFT", -4, 2)
    return input
end

local function CreateCheckbox(parent, option)
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetSize(24, 24)
    checkbox.settingKey = option.key
    local label = UI.CreateText(checkbox, "GameFontHighlightSmall", option.label)
    label:SetPoint("LEFT", checkbox, "RIGHT", 2, 1)
    checkbox:SetScript("OnClick", function(self)
        ns.settings[option.key] = self:GetChecked() and true or false
        ns:Fire("KOS_SETTINGS_CHANGED")
    end)
    if option.tooltip then
        UI.AddTooltip(checkbox, function() return option.label, option.tooltip end)
    end
    return checkbox
end

--------------------------------------------------------------------------------
-- Adding and removing names
--------------------------------------------------------------------------------

local function ClearInputs()
    window.nameInput:SetText("")
    window.reasonInput:SetText("")
    window.nameInput:ClearFocus()
    window.reasonInput:ClearFocus()
end

-- Runs `add(name, reason)` with what is typed in, and says how it went.
local function AddFromInputs(add, doneText)
    local shown, problem = add(window.nameInput:GetText(), window.reasonInput:GetText())
    if not shown then
        ns:Print(problem)
        return
    end
    ns:Print(doneText:format(shown))
    ClearInputs()
end

local function AddToPersonalList()
    AddFromInputs(ns.AddPersonal, "%s er lagt til på din liste.")
end

local function AddToGuildList()
    AddFromInputs(ns.Sync.Add, "%s er lagt til på guildlista.")
end

-- The X on a row takes the name off your own list when it is there, otherwise off the
-- guild list.
local function CanRemove(entry)
    return entry.inPersonalList or (entry.inGuildList and ns.Sync.WhyCannotEdit() == nil)
end

local function ReportRemoval(shown, problem)
    if not shown then
        ns:Print(problem)
        return
    end
    ns:Print(("%s er fjernet."):format(shown))
end

-- Taking a name off the guild list takes it off for everyone, so it is asked first.
StaticPopupDialogs[REMOVE_POPUP] = {
    text = "Fjerne %s fra guildlista? Navnet blir borte for alle i guilden.",
    button1 = "Fjern",
    button2 = "Avbryt",
    OnAccept = function(_, key) ReportRemoval(ns.Sync.Remove(key)) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function RemoveEntry(entry)
    if entry.inPersonalList then
        ReportRemoval(ns.RemovePersonal(entry.key))
        return
    end
    StaticPopup_Show(REMOVE_POPUP, entry.name, nil, entry.key)
end

local function RemoveTooltipText(entry)
    if entry.inPersonalList and entry.inGuildList then
        return "Fjern fra din liste", "Navnet står fortsatt på guildlista."
    end
    if entry.inPersonalList then return "Fjern fra din liste" end
    return "Fjern fra guildlista", "Fjerner navnet for hele guilden."
end

--------------------------------------------------------------------------------
-- List rows
--------------------------------------------------------------------------------

local function SourceTag(entry)
    if entry.inGuildList and entry.inPersonalList then return GUILD_TAG .. " + " .. PERSONAL_TAG end
    if entry.inGuildList then return GUILD_TAG end
    return PERSONAL_TAG
end

-- "Drept 3 ganger, sist av Ola for 2 t siden"
local function KillText(entry)
    local record = ns.db.kills[entry.key]
    if not record then return nil end
    local timesText = record.count == 1 and "1 gang" or ("%d ganger"):format(record.count)
    return ("Drept %s, sist av %s %s"):format(timesText, record.lastBy or "?", ns.TimeAgo(record.lastAt))
end

-- "Sist sett for 5 min siden i The Crossroads, The Barrens av Kari"
local function SeenText(entry)
    local sighting = ns.db.lastSeen[entry.key]
    if not sighting then return nil end
    local seenText = "Sist sett " .. ns.TimeAgo(sighting.at)
    if sighting.place and sighting.place ~= "" then seenText = seenText .. " i " .. sighting.place end
    if sighting.by then seenText = seenText .. " av " .. sighting.by end
    return seenText
end

local function OriginText(entry)
    if not (entry.inGuildList and entry.addedBy) then return nil end
    return "Lagt til av " .. Ambiguate(entry.addedBy, "guild")
end

local function AddPart(parts, part)
    if part then table.insert(parts, part) end
end

-- Everything known about a name, one line each, for the row's tooltip.
local function DetailLines(entry)
    local lines = {}
    AddPart(lines, entry.reason and ("Grunn: " .. entry.reason))
    AddPart(lines, KillText(entry))
    AddPart(lines, SeenText(entry))
    AddPart(lines, OriginText(entry))
    if #lines == 0 then return "Ikke sett ennå" end
    return table.concat(lines, "\n")
end

-- The grey line under a name, short enough to fit the row: "Gikk alliance · drept 3x ·
-- sett for 5 min siden". The tooltip has the rest.
local function SummaryText(entry)
    local parts = {}
    AddPart(parts, entry.reason)
    local record = ns.db.kills[entry.key]
    AddPart(parts, record and ("drept %dx"):format(record.count))
    local sighting = ns.db.lastSeen[entry.key]
    AddPart(parts, sighting and ("sett " .. ns.TimeAgo(sighting.at)))
    if #parts == 0 then return "Ikke sett ennå" end
    return table.concat(parts, " · ")
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, window.listContent)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    if index % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.04)
    end

    row.name = UI.CreateText(row, "GameFontNormal")
    row.name:SetPoint("TOPLEFT", 6, -3)
    row.source = UI.CreateText(row, "GameFontHighlightSmall")
    row.source:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.detail = UI.CreateText(row, "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.detail:SetWidth(LIST_WIDTH - 40)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.remove:SetSize(24, 24)
    row.remove:SetPoint("RIGHT", -2, 0)
    row.remove:SetScript("OnClick", function() RemoveEntry(row.entry) end)
    UI.AddTooltip(row.remove, function() return RemoveTooltipText(row.entry) end)

    UI.AddTooltip(row, function() return row.entry.name, DetailLines(row.entry) end)
    return row
end

local function FillRow(row, entry)
    row.entry = entry
    row.name:SetText(entry.name)
    row.source:SetText(SourceTag(entry))
    row.detail:SetText(SummaryText(entry))
    row.remove:SetShown(CanRemove(entry))
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function CreateAddArea(frame)
    frame.nameInput = CreateInput(frame, 150, "Fornavn Etternavn")
    frame.nameInput:SetPoint("TOPLEFT", EDGE + 6, -62)
    frame.nameInput:SetScript("OnEnterPressed", AddToPersonalList)

    frame.reasonInput = CreateInput(frame, CONTENT_WIDTH - 176, "Grunn")
    frame.reasonInput:SetPoint("LEFT", frame.nameInput, "RIGHT", 18, 0)
    frame.reasonInput:SetScript("OnEnterPressed", AddToPersonalList)

    local personalButton = UI.CreateButton(frame, CONTENT_WIDTH / 2 - 4, "Legg til på min liste", AddToPersonalList)
    personalButton:SetPoint("TOPLEFT", EDGE, -94)
    UI.AddTooltip(personalButton, function()
        return "Min liste", "Bare for deg. Gjelder alle karakterene dine på denne kontoen."
    end)

    frame.guildButton = UI.CreateButton(frame, CONTENT_WIDTH / 2 - 4, "Legg til på guildlista", AddToGuildList)
    frame.guildButton:SetPoint("TOPRIGHT", -EDGE, -94)
    UI.AddTooltip(frame.guildButton, function()
        local problem = ns.Sync.WhyCannotEdit()
        local text = "Alle i guilden med addonen får navnet, også de som logger på senere."
        if problem then text = text .. "\n\n|cffff6060" .. problem .. "|r" end
        return "Guildlista", text
    end)
end

local function CreateStatusArea(frame)
    frame.status = UI.CreateText(frame, "GameFontHighlightSmall")
    frame.status:SetPoint("TOPLEFT", EDGE, -124)
    frame.status:SetWidth(CONTENT_WIDTH)
    frame.status:SetJustifyH("LEFT")

    frame.syncStatus = UI.CreateText(frame, "GameFontDisableSmall")
    frame.syncStatus:SetPoint("TOPLEFT", EDGE, -139)
    frame.syncStatus:SetWidth(CONTENT_WIDTH)
    frame.syncStatus:SetJustifyH("LEFT")

    frame.plateWarning = UI.CreateText(frame, "GameFontNormalSmall",
        "|cffff8040Fiendtlige navneplater er av: varselet kommer senere.|r")
    frame.plateWarning:SetPoint("TOPLEFT", EDGE, -156)
    frame.plateButton = UI.CreateButton(frame, 70, "Slå på", ns.TurnOnEnemyNameplates)
    frame.plateButton:SetHeight(18)
    frame.plateButton:SetPoint("TOPRIGHT", -EDGE, -152)
end

local function CreateListArea(frame)
    local listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", EDGE, LIST_TOP)
    listBox:SetSize(CONTENT_WIDTH, LIST_HEIGHT)
    listBox:SetBackdrop(UI.LIST_BACKDROP)
    listBox:SetBackdropColor(0, 0, 0, 0.5)

    local scroll = CreateFrame("ScrollFrame", nil, listBox, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", LIST_INSET, -LIST_INSET)
    scroll:SetPoint("BOTTOMRIGHT", -LIST_INSET - SCROLLBAR_SPACE, LIST_INSET)

    frame.listContent = CreateFrame("Frame", nil, scroll)
    frame.listContent:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(frame.listContent)

    frame.emptyText = UI.CreateText(listBox, "GameFontDisable",
        "Lista er tom.\n\nLegg til navn ovenfor, eller importer\nen liste med «Del lista».")
    frame.emptyText:SetPoint("CENTER")
    frame.emptyText:SetWidth(LIST_WIDTH)
end

local function CycleAlertPause()
    local current = ns.settings.alertPause
    local nextPause = ALERT_PAUSES[1]
    for index, pause in ipairs(ALERT_PAUSES) do
        if pause == current then nextPause = ALERT_PAUSES[index % #ALERT_PAUSES + 1] end
    end
    ns.settings.alertPause = nextPause
    ns:Fire("KOS_SETTINGS_CHANGED")
end

local function CycleSound()
    ns.settings.soundKey = ns.Alert.NextSoundKey(ns.settings.soundKey)
    ns.Alert.PlaySound(ns.settings.soundKey)
    ns:Fire("KOS_SETTINGS_CHANGED")
end

local function CreateOptionsArea(frame)
    local header = UI.CreateText(frame, "GameFontNormal", "Innstillinger")
    header:SetPoint("TOPLEFT", EDGE, OPTIONS_TOP)

    frame.checkboxes = {}
    for index, option in ipairs(CHECKBOXES) do
        local column = (index - 1) % 2
        local line = math.floor((index - 1) / 2)
        local checkbox = CreateCheckbox(frame, option)
        checkbox:SetPoint("TOPLEFT", EDGE + column * (CONTENT_WIDTH / 2), OPTIONS_TOP - 16 - line * CHECKBOX_SPACING)
        table.insert(frame.checkboxes, checkbox)
    end

    local buttonsTop = OPTIONS_TOP - 24 - math.ceil(#CHECKBOXES / 2) * CHECKBOX_SPACING
    frame.soundButton = UI.CreateButton(frame, 124, "", CycleSound)
    frame.soundButton:SetPoint("TOPLEFT", EDGE, buttonsTop)
    UI.AddTooltip(frame.soundButton, function() return "Lyd", "Klikk for neste lyd. Du hører den med en gang." end)

    frame.pauseButton = UI.CreateButton(frame, 112, "", CycleAlertPause)
    frame.pauseButton:SetPoint("LEFT", frame.soundButton, "RIGHT", 6, 0)
    UI.AddTooltip(frame.pauseButton, function()
        return "Nytt varsel", "Hvor lenge samme navn må vente før det kan varsle på nytt. Andre navn varsler som vanlig."
    end)

    local testButton = UI.CreateButton(frame, 46, "Test", ns.Alert.Test)
    testButton:SetPoint("LEFT", frame.pauseButton, "RIGHT", 6, 0)

    local shareButton = UI.CreateButton(frame, CONTENT_WIDTH - 124 - 112 - 46 - 18, "Del lista", ns.ExportImport.Show)
    shareButton:SetPoint("LEFT", testButton, "RIGHT", 6, 0)
    UI.AddTooltip(shareButton, function()
        return "Del lista", "Eksport og import som tekst, for eksempel til og fra Discord."
    end)
end

local function CreateMainWindow()
    local frame = UI.CreateWindow(WINDOW_NAME, WINDOW_WIDTH, WINDOW_HEIGHT, "Guild KOS")
    CreateAddArea(frame)
    CreateStatusArea(frame)
    CreateListArea(frame)
    CreateOptionsArea(frame)
    frame:SetScript("OnShow", function() UI.Refresh() end)
    return frame
end

--------------------------------------------------------------------------------
-- Keeping it current
--------------------------------------------------------------------------------

-- "Guildlista: 14 navn"
local function GuildListStatus()
    if not IsInGuild() then return "Ikke i guild: bare din egen liste brukes." end
    local guildCount = 0
    for _, entry in ipairs(ns.AllEntries()) do
        if entry.inGuildList then guildCount = guildCount + 1 end
    end
    return ("Guildlista: %d navn"):format(guildCount)
end

local function RefreshStatus()
    window.status:SetText(GuildListStatus())
    window.syncStatus:SetText(IsInGuild() and ns.Sync.StatusText() or "")
    window.guildButton:SetEnabled(ns.Sync.WhyCannotEdit() == nil)
    local arePlatesOn = ns.EnemyNameplatesOn()
    window.plateWarning:SetShown(not arePlatesOn)
    window.plateButton:SetShown(not arePlatesOn)
end

local function RefreshList()
    local entries = ns.AllEntries()
    for index, entry in ipairs(entries) do
        rows[index] = rows[index] or CreateRow(index)
        FillRow(rows[index], entry)
        rows[index]:Show()
    end
    for index = #entries + 1, #rows do
        rows[index]:Hide()
    end
    window.listContent:SetHeight(math.max(1, #entries * ROW_HEIGHT))
    window.emptyText:SetShown(#entries == 0)
end

local function RefreshOptions()
    for _, checkbox in ipairs(window.checkboxes) do
        checkbox:SetChecked(ns.settings[checkbox.settingKey])
    end
    window.soundButton:SetText("Lyd: " .. ns.Alert.SoundByKey(ns.settings.soundKey).label)
    window.pauseButton:SetText(("Nytt varsel: %d s"):format(ns.settings.alertPause))
end

function UI.Refresh()
    if not (window and window:IsShown()) then return end
    RefreshStatus()
    RefreshList()
    RefreshOptions()
end

function UI.Toggle()
    window = window or CreateMainWindow()
    if window:IsShown() then
        window:Hide()
        return
    end
    window:Show()
    window:Raise()
end

ns:On("KOS_LIST_CHANGED", UI.Refresh)
ns:On("KOS_SEEN", UI.Refresh)
ns:On("KOS_KILLED", UI.Refresh)
ns:On("KOS_SYNCED", UI.Refresh)
ns:On("KOS_SETTINGS_CHANGED", UI.Refresh)
-- Joining or leaving a guild changes which guild list is shown.
ns:On("PLAYER_GUILD_UPDATE", UI.Refresh)
