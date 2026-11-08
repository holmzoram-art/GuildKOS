-- The /kos chat commands.
local addonName, ns = ...

local HELP_LINES = {
    "/kos: åpne eller lukk vinduet",
    "/kos add Fornavn Etternavn [grunn]: legg til på din egen liste (uten navn: target-en din)",
    "/kos remove Fornavn Etternavn: fjern fra din egen liste",
    "/kos guild add Fornavn Etternavn [grunn]: legg til på guildlista (uten navn: target-en din)",
    "/kos guild remove Fornavn Etternavn: fjern fra guildlista",
    "/kos sync: send hele guildlista til alle med addonen nå",
    "/kos status: guild, lister, synk og hvem addonen hører fra",
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

-- What each kind of addon message is, in /kos status.
local MESSAGE_KIND_TEXT = {
    S1 = "sett",
    K1 = "drap",
    E1 = "listeendring",
    H1 = "synk-spørsmål",
    D1 = "hel liste",
    D2 = "hel liste",
}
local HEARD_SHOWN = 10 -- senders listed in /kos status

local function CountPersonal()
    local personalCount = 0
    for _ in pairs(ns.db.personal) do personalCount = personalCount + 1 end
    return personalCount
end

local function AddonVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMetadata and getMetadata(addonName, "Version") or "?"
end

local function PrintHeardFrom(heard)
    if #heard == 0 then
        print("   Ingen meldinger fra andre med addonen ennå. Er de i samme guild, og pålogget?")
        return
    end
    print("   Hørt fra:")
    for index = 1, math.min(#heard, HEARD_SHOWN) do
        local sender = heard[index]
        local kind = MESSAGE_KIND_TEXT[sender.lastKind] or sender.lastKind or "?"
        print(("      %s: %d meldinger, sist %s %s"):format(Ambiguate(sender.sender, "guild"), sender.count, kind,
            ns.TimeAgo(sender.lastAt)))
    end
end

-- Everything that tells whether the guild list can sync: which guild, how many names, when it
-- last synced, how this copy's own messages go, and whom it has heard from.
local function PrintStatus()
    local guildName = IsInGuild() and ns.Plain(GetGuildInfo("player"))
    local share = ns.Share.Status()
    ns:Print(("Status (versjon %s):"):format(AddonVersion()))
    print("   Guild: " .. (guildName or "ikke i guild (eller ikke lastet ennå)"))
    if guildName then
        local listedCount, removedCount = ns.Sync.Counts()
        print(("   Guildlista: %d navn (%d fjernet). %s"):format(listedCount, removedCount, ns.Sync.StatusText()))
    end
    print(("   Min liste: %d navn"):format(CountPersonal()))
    print(("   Sendt: %d meldinger, siste svar fra spillet: %s. Venter: %d."):format(share.sentCount,
        share.lastSendAnswer or "ingen ennå", share.waitingCount))
    if share.isPrefixRegistered == false then print("   |cffff6060Addon-kanalen er ikke registrert.|r") end
    if share.isLockedDown then print("   Spillet blokkerer addon-meldinger akkurat nå (kamp eller instance).") end
    PrintHeardFrom(share.heard)
end

local function PrintHelp()
    ns:Print("Kommandoer:")
    for _, line in ipairs(HELP_LINES) do
        print("   " .. line)
    end
end

-- The name and reason typed after "add", or your target when nothing is typed.
local function NameAndReason(arguments)
    if arguments ~= "" then return ns.SplitNameAndReason(arguments) end
    local targetName = ns.TargetFullName()
    if not targetName then return nil, nil, "Skriv et navn, eller ta en spiller i target først." end
    return targetName, nil
end

local function RunGuildCommand(arguments)
    local action, rest = FirstWord(arguments)
    action = action:lower()
    if action == "add" then
        local fullName, reason, problem = NameAndReason(rest)
        if not fullName then
            ns:Print(problem)
            return
        end
        local shown, addProblem = ns.Sync.Add(fullName, reason)
        Report(shown, addProblem, "%s er lagt til på guildlista.")
    elseif action == "remove" then
        local shown, problem = ns.Sync.Remove(ns.KeyFromFullName(rest))
        Report(shown, problem, "%s er fjernet fra guildlista.")
    else
        PrintHelp()
    end
end

-- The same as the "Synk nå" button.
local function SyncNow()
    local nameCount, problem = ns.Sync.PushAll()
    if not nameCount then
        ns:Print(problem)
        return
    end
    ns:Print(("Sender guildlista (%d navn) til alle med addonen. De sender tilbake det du mangler.")
        :format(nameCount))
end

local COMMANDS = {
    [""] = function() ns.UI.Toggle() end,
    add = function(arguments)
        local fullName, reason, problem = NameAndReason(arguments)
        if not fullName then
            ns:Print(problem)
            return
        end
        local shown, addProblem = ns.AddPersonal(fullName, reason)
        Report(shown, addProblem, "%s er lagt til på din liste.")
    end,
    remove = function(arguments)
        local shown, problem = ns.RemovePersonal(ns.KeyFromFullName(arguments))
        Report(shown, problem, "%s er fjernet fra din liste.")
    end,
    guild = RunGuildCommand,
    list = PrintList,
    top = PrintTopKillers,
    sync = SyncNow,
    status = PrintStatus,
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
