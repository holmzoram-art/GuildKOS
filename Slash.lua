-- The /kos chat commands.
local _, ns = ...

local HELP_LINES = {
    "/kos: åpne eller lukk vinduet",
    "/kos add Navn [grunn]: legg til i din egen liste",
    "/kos remove Navn: fjern fra din egen liste",
    "/kos guild add Navn [grunn]: legg til på guildlista",
    "/kos guild remove Navn: fjern fra guildlista",
    "/kos export eller /kos import: del lista som tekst",
    "/kos sync: sammenlign lista med guilden nå",
    "/kos list: skriv hele lista i chat",
    "/kos top: hvem i guilden har flest KOS-drap",
    "/kos plates: slå på fiendtlige navneplater",
    "/kos test: test varselet",
}

-- "add Navn grunn her" -> "add", "Navn grunn her"
local function FirstWord(text)
    local word, rest = text:match("^%s*(%S*)%s*(.-)%s*$")
    return word or "", rest or ""
end

-- Prints `doneText` with the name, or why it didn't work.
local function Report(shown, problem, doneText)
    if not shown then
        ns:Print(problem)
        return
    end
    ns:Print(doneText:format(shown))
end

local function PrintList()
    local entries = ns.AllEntries()
    if #entries == 0 then
        ns:Print("Lista er tom.")
        return
    end
    ns:Print(("%d navn på lista:"):format(#entries))
    for _, entry in ipairs(entries) do
        local listName = entry.inGuildList and "guild" or "min"
        local record = ns.db.kills[entry.key]
        local killText = record and (", drept %dx"):format(record.count) or ""
        local reason = entry.reason and (": " .. entry.reason) or ""
        print(("   %s (%s%s)%s"):format(entry.name, listName, killText, reason))
    end
end

local TOP_KILLERS_SHOWN = 10

local function PrintTopKillers()
    local killers = ns.Kills.TopKillers(TOP_KILLERS_SHOWN)
    if #killers == 0 then
        ns:Print("Ingen KOS-drap ennå.")
        return
    end
    ns:Print("Flest KOS-drap:")
    for place, killer in ipairs(killers) do
        print(("   %d. %s: %d"):format(place, killer.name, killer.count))
    end
end

local function PrintHelp()
    ns:Print("Kommandoer:")
    for _, line in ipairs(HELP_LINES) do
        print("   " .. line)
    end
end

local function RunGuildCommand(arguments)
    local action, rest = FirstWord(arguments)
    action = action:lower()
    if action == "add" then
        local fullName, reason = FirstWord(rest)
        local shown, problem = ns.Sync.Add(fullName, reason)
        Report(shown, problem, "%s er lagt til på guildlista.")
    elseif action == "remove" then
        local shown, problem = ns.Sync.Remove(ns.KeyFromFullName(rest))
        Report(shown, problem, "%s er fjernet fra guildlista.")
    else
        PrintHelp()
    end
end

local function StartSync()
    if ns.Sync.SayHello() then
        ns:Print("Sammenligner lista med guilden. Det kan ta litt tid hvis den er lang.")
    else
        ns:Print("Du er ikke med i en guild, eller spillet har ikke lastet guilden ennå.")
    end
end

local COMMANDS = {
    [""] = function() ns.UI.Toggle() end,
    add = function(arguments)
        local fullName, reason = FirstWord(arguments)
        local shown, problem = ns.AddPersonal(fullName, reason)
        Report(shown, problem, "%s er lagt til i din liste.")
    end,
    remove = function(arguments)
        local shown, problem = ns.RemovePersonal(ns.KeyFromFullName(arguments))
        Report(shown, problem, "%s er fjernet fra din liste.")
    end,
    guild = RunGuildCommand,
    list = PrintList,
    top = PrintTopKillers,
    export = function() ns.ExportImport.Toggle() end,
    import = function() ns.ExportImport.Toggle() end,
    sync = StartSync,
    plates = function() ns.TurnOnEnemyNameplates() end,
    test = function() ns.Alert.Test() end,
    help = PrintHelp,
}

SLASH_GUILDKOS1 = "/kos"
SLASH_GUILDKOS2 = "/guildkos"
SlashCmdList.GUILDKOS = function(message)
    local command, arguments = FirstWord(message or "")
    local run = COMMANDS[command:lower()] or PrintHelp
    run(arguments)
end
