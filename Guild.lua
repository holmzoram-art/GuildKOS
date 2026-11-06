-- What the addon reads from the guild itself. Guild Info is the text officers edit in the
-- game's guild window, and it can hold two kinds of lines for this addon:
--     KOS: Forræder, Sviker-Firemaw, Judas
--     KOS-rank: 3
-- Names on KOS lines are on the guild list for everyone with the addon, next to the names in
-- the synced list (Sync.lua), so officers can add names without the addon. A KOS-rank line
-- lets only guild ranks 1 to 3 (1 is the Guild Master) change the synced list; without one,
-- every member may. The addon never writes to Guild Info.
local _, ns = ...

local Guild = {}
ns.Guild = Guild

local KOS_LINE = "^%s*[Kk][Oo][Ss]%s*:(.*)$"                       -- captures what follows "KOS:"
local RANK_LINE = "^%s*[Kk][Oo][Ss]%-[Rr][Aa][Nn][Kk]%s*:%s*(%d+)" -- captures the number
local NAME_PATTERN = "[^,;%s]+"            -- names are split by commas, semicolons or spaces
local ROSTER_REFRESH_INTERVAL = 300        -- seconds between roster requests, to catch edits

-- Guild Info arrives with the guild roster, a while after login.
local hasGuildInfo = false
local editRankLimit         -- the number on a KOS-rank line, or nil
local rankByMember = {}     -- "Name-Realm" -> rank number (1 is the Guild Master)

function Guild.RequestRoster()
    if not IsInGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

function Guild.HasGuildInfo()
    return hasGuildInfo
end

function Guild.EditRankLimit()
    return editRankLimit
end

-- A member's rank number, or nil when they aren't in the roster (or it hasn't come yet).
function Guild.RankNumberOf(fullName)
    return rankByMember[fullName]
end

function Guild.MyRankNumber()
    local _, _, rankIndex = GetGuildInfo("player")
    rankIndex = ns.Plain(rankIndex)
    if type(rankIndex) ~= "number" then return nil end
    return rankIndex + 1
end

local function CurrentInfoText()
    local infoText = ns.Plain(GetGuildInfoText and GetGuildInfoText())
    if type(infoText) ~= "string" then return "" end
    return infoText
end

local function AddNamesFromLine(names, namesText)
    for token in namesText:gmatch(NAME_PATTERN) do
        local name, realm = ns.SplitName(token)
        if ns.IsValidName(name) then
            names[ns.NameKey(name, realm)] = ns.DisplayName(name, realm)
        end
    end
end

-- The names on the KOS lines (key -> shown name) and the number on a KOS-rank line, if any.
local function ParseGuildInfo(infoText)
    local names = {}
    local rankLimit
    for line in (infoText .. "\n"):gmatch("(.-)\n") do
        local namesText = line:match(KOS_LINE)
        if namesText then AddNamesFromLine(names, namesText) end
        rankLimit = tonumber(line:match(RANK_LINE)) or rankLimit
    end
    return names, rankLimit
end

local function SameNames(first, second)
    for key, shown in pairs(first) do
        if second[key] ~= shown then return false end
    end
    for key in pairs(second) do
        if first[key] == nil then return false end
    end
    return true
end

local function UseGuildInfo(names, rankLimit)
    if SameNames(names, ns.guildInfoNames) and rankLimit == editRankLimit then return end
    ns.guildInfoNames = names
    editRankLimit = rankLimit
    ns:Fire("KOS_LIST_CHANGED")
end

local function ReadRoster()
    wipe(rankByMember)
    for index = 1, GetNumGuildMembers() do
        local fullName, _, rankIndex = GetGuildRosterInfo(index)
        fullName, rankIndex = ns.Plain(fullName), ns.Plain(rankIndex)
        if type(fullName) == "string" and type(rankIndex) == "number" then
            rankByMember[fullName] = rankIndex + 1
        end
    end
end

local function ReadGuild()
    if not IsInGuild() then
        hasGuildInfo = false
        wipe(rankByMember)
        UseGuildInfo({}, nil)
        return
    end
    -- No members yet means the roster, and the Guild Info that comes with it, isn't here yet.
    if (GetNumGuildMembers() or 0) == 0 then return end
    hasGuildInfo = true
    ReadRoster()
    UseGuildInfo(ParseGuildInfo(CurrentInfoText()))
end

ns:On("PLAYER_LOGIN", function()
    Guild.RequestRoster()
    C_Timer.NewTicker(ROSTER_REFRESH_INTERVAL, Guild.RequestRoster)
end)

ns:On("GUILD_ROSTER_UPDATE", ReadGuild)

-- Joining or leaving a guild.
ns:On("PLAYER_GUILD_UPDATE", function()
    ReadGuild()
    Guild.RequestRoster()
end)
