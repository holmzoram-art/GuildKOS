-- A window for moving the KOS list in and out of the game as plain text: copy it to Discord
-- as a backup or to share it, and paste a list back in. One name per line (first and last
-- name, or only the first), with an optional reason after " - " or ":" (ns.SplitNameAndReason):
--     Nektarion Stormhoof - Gikk alliance
--     Sviker
-- Empty lines and lines that start with "#" are skipped.
local _, ns = ...

local ExportImport = {}
ns.ExportImport = ExportImport

local WINDOW_NAME = "GuildKOSShareWindow" -- a global name, so Escape can close the window
local WINDOW_WIDTH = 440
local WINDOW_HEIGHT = 420
local EDGE = 22
local CONTENT_WIDTH = WINDOW_WIDTH - 2 * EDGE
local HELP_TOP = -46
local TEXT_BOTTOM = 52 -- room for the buttons under the text box
local TEXT_INSET = 8
local SCROLLBAR_SPACE = 24

local HELP_TEXT = "Eksport: Teksten er allerede markert. Trykk Ctrl+C og lim den inn der du vil, "
    .. "for eksempel på Discord.\n"
    .. "Import: Lim inn en liste med Ctrl+V, ett navn per linje, og trykk «Til guildlista» "
    .. "eller «Til min liste»."

local window

local function ExportText()
    local lines = { ("# Guild KOS, eksportert %s"):format(date("%d.%m.%Y")) }
    for _, entry in ipairs(ns.AllEntries()) do
        if entry.reason then
            table.insert(lines, entry.name .. " - " .. entry.reason)
        else
            table.insert(lines, entry.name)
        end
    end
    return table.concat(lines, "\n")
end

-- Adds the name on one pasted line to `items` as { fullName, reason }.
local function ReadLine(line, items)
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == "" or trimmed:sub(1, 1) == "#" then return end
    local fullName, reason = ns.SplitNameAndReason(trimmed)
    table.insert(items, { fullName = fullName, reason = reason })
end

local function ReadPastedText(text)
    local items = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        ReadLine(line, items)
    end
    return items
end

-- Names already on your list keep their reason.
local function AddToPersonalList(items)
    local addedCount = 0
    for _, item in ipairs(items) do
        local isListed = ns.db.personal[ns.KeyFromFullName(item.fullName)] ~= nil
        if not isListed and ns.AddPersonal(item.fullName, item.reason) then addedCount = addedCount + 1 end
    end
    return addedCount
end

local function Import(addItems, listName)
    local items = ReadPastedText(window.editBox:GetText())
    if #items == 0 then
        ns:Print("Fant ingen navn å importere. Lim inn lista først.")
        return
    end
    local addedCount, problem = addItems(items)
    if not addedCount then
        ns:Print(problem)
        return
    end
    local message = ("%d av %d navn er lagt til på %s."):format(addedCount, #items, listName)
    if addedCount < #items then message = message .. " Resten sto der fra før eller var ugyldige." end
    ns:Print(message)
end

-- The cursor goes to the top first, so a long list opens at its first names.
local function ShowExport()
    window.editBox:SetText(ExportText())
    window.editBox:SetCursorPosition(0)
    window.editBox:SetFocus()
    window.editBox:HighlightText()
end

local function CreateTextArea(frame, help)
    local textBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    textBox:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -8)
    textBox:SetPoint("BOTTOMRIGHT", -EDGE, TEXT_BOTTOM)
    textBox:SetBackdrop(ns.UI.LIST_BACKDROP)
    textBox:SetBackdropColor(0, 0, 0, 0.6)

    local scroll = CreateFrame("ScrollFrame", nil, textBox, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", TEXT_INSET, -TEXT_INSET)
    scroll:SetPoint("BOTTOMRIGHT", -TEXT_INSET - SCROLLBAR_SPACE, TEXT_INSET)

    -- A multi-line edit box grows with its text; the scroll frame scrolls over it.
    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    -- No length limit: an edit box made in code may otherwise stop at 255 bytes.
    editBox:SetMaxLetters(0)
    if editBox.SetMaxBytes then editBox:SetMaxBytes(0) end
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(CONTENT_WIDTH - 2 * TEXT_INSET - SCROLLBAR_SPACE)
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    -- The game's own helpers keep the cursor in view while typing, where this client has them.
    if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then
        editBox:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
        editBox:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, scroll) end)
    end
    scroll:SetScrollChild(editBox)

    -- A click anywhere in the box puts the cursor in it, not only on the lines of text.
    textBox:EnableMouse(true)
    textBox:SetScript("OnMouseDown", function() editBox:SetFocus() end)
    frame.editBox = editBox
end

local function CreateButtons(frame)
    local buttonWidth = (CONTENT_WIDTH - 12) / 3
    local exportButton = ns.UI.CreateButton(frame, buttonWidth, "Vis lista", ShowExport)
    exportButton:SetPoint("BOTTOMLEFT", EDGE, 20)
    ns.UI.AddTooltip(exportButton, function()
        return "Vis lista", "Fyller boksen med hele lista (guildlista og din egen), klar til å kopiere."
    end)

    local guildButton = ns.UI.CreateButton(frame, buttonWidth, "Til guildlista", function()
        Import(ns.Sync.AddMany, "guildlista")
    end)
    guildButton:SetPoint("LEFT", exportButton, "RIGHT", 6, 0)
    ns.UI.AddTooltip(guildButton, function()
        local problem = ns.Sync.WhyCannotEdit()
        local text = "Legger navnene i boksen på guildlista, for hele guilden."
        if problem then text = text .. "\n\n|cffff6060" .. problem .. "|r" end
        return "Importer til guildlista", text
    end)

    local personalButton = ns.UI.CreateButton(frame, buttonWidth, "Til min liste", function()
        Import(AddToPersonalList, "din liste")
    end)
    personalButton:SetPoint("LEFT", guildButton, "RIGHT", 6, 0)
    ns.UI.AddTooltip(personalButton, function()
        return "Importer til min liste", "Legger navnene i boksen på din egen liste. Bare du ser dem."
    end)
end

local function CreateShareWindow()
    local frame = ns.UI.CreateWindow(WINDOW_NAME, WINDOW_WIDTH, WINDOW_HEIGHT, "Del KOS-lista")
    local help = ns.UI.CreateText(frame, "GameFontHighlightSmall", HELP_TEXT)
    help:SetPoint("TOPLEFT", EDGE, HELP_TOP)
    help:SetWidth(CONTENT_WIDTH)
    help:SetJustifyH("LEFT")
    CreateTextArea(frame, help)
    CreateButtons(frame)
    frame:SetScript("OnShow", ShowExport)
    return frame
end

-- Opens the window, in front of the /kos window. Escape or the X closes it.
function ExportImport.Show()
    window = window or CreateShareWindow()
    window:Show()
    window:Raise()
end
