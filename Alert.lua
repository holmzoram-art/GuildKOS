-- What happens when a listed character shows up: a sound, a red glow pulsing around the edges
-- of the screen, a big line of text, a blinking taskbar icon and a line in chat.
local _, ns = ...

local Alert = {}
ns.Alert = Alert

-- The sounds to choose from. SOUNDKIT holds the game's names for its sounds; the number is
-- the same sound, in case a client lacks the name.
Alert.SOUNDS = {
    { key = "raidwarning", label = "Raid Warning", soundKit = "RAID_WARNING", fallbackID = 8959 },
    { key = "bosswarning", label = "Boss-advarsel", soundKit = "UI_RAID_BOSS_WHISPER_WARNING", fallbackID = 37666 },
    { key = "alarm", label = "Vekkerklokke", soundKit = "ALARM_CLOCK_WARNING_3", fallbackID = 12889 },
    { key = "readycheck", label = "Ready Check", soundKit = "READY_CHECK", fallbackID = 8960 },
}

local FLASH_TEXTURE = "Interface\\FullScreenTextures\\LowHealth" -- the game's red low-health edge glow
local FLASH_PULSES = 3
local FLASH_FADE_IN = 0.15  -- seconds
local FLASH_FADE_OUT = 0.45 -- seconds
local BANNER_HOLD = 3       -- seconds the text stays before it fades
local BANNER_FADE = 1       -- seconds
local BANNER_FONT_SIZE = 30
local BANNER_TOP = -150     -- pixels from the top of the screen
local TEST_KEY = "#test"    -- "#" can't be in a name, so this key never matches a real one

local flash
local banner

function Alert.SoundByKey(soundKey)
    for _, sound in ipairs(Alert.SOUNDS) do
        if sound.key == soundKey then return sound end
    end
    return Alert.SOUNDS[1]
end

function Alert.NextSoundKey(soundKey)
    for index, sound in ipairs(Alert.SOUNDS) do
        if sound.key == soundKey then return Alert.SOUNDS[index % #Alert.SOUNDS + 1].key end
    end
    return Alert.SOUNDS[1].key
end

function Alert.PlaySound(soundKey)
    local sound = Alert.SoundByKey(soundKey)
    local soundKitID = (SOUNDKIT and SOUNDKIT[sound.soundKit]) or sound.fallbackID
    -- The "Master" channel plays even when the game's sound effects are turned off.
    PlaySound(soundKitID, "Master")
end

local function AddFade(animationGroup, fromAlpha, toAlpha, duration, order, startDelay)
    local fade = animationGroup:CreateAnimation("Alpha")
    fade:SetFromAlpha(fromAlpha)
    fade:SetToAlpha(toAlpha)
    fade:SetDuration(duration)
    fade:SetOrder(order)
    if startDelay then fade:SetStartDelay(startDelay) end
end

local function CreateFlash()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetAllPoints(UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:Hide()

    local glow = frame:CreateTexture(nil, "BACKGROUND")
    glow:SetAllPoints()
    if glow:SetTexture(FLASH_TEXTURE) == false then
        glow:SetColorTexture(1, 0, 0, 0.25)
    else
        glow:SetVertexColor(1, 0.1, 0.1)
        glow:SetBlendMode("ADD")
    end

    -- One loop is one pulse (fade in, fade out); it stops after FLASH_PULSES of them.
    local pulse = frame:CreateAnimationGroup()
    pulse:SetLooping("REPEAT")
    AddFade(pulse, 0, 1, FLASH_FADE_IN, 1)
    AddFade(pulse, 1, 0, FLASH_FADE_OUT, 2)
    pulse:SetScript("OnLoop", function()
        frame.pulsesLeft = frame.pulsesLeft - 1
        if frame.pulsesLeft > 0 then return end
        pulse:Stop()
        frame:Hide()
    end)
    frame.pulse = pulse
    return frame
end

local function StartFlash()
    flash = flash or CreateFlash()
    flash.pulsesLeft = FLASH_PULSES
    flash.pulse:Stop()
    flash:Show()
    flash.pulse:Play()
end

local function CreateBanner()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(900, 90)
    frame:SetPoint("TOP", UIParent, "TOP", 0, BANNER_TOP)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.title:SetPoint("TOP")
    frame.title:SetTextColor(1, 0.15, 0.15)
    local fontFile = frame.title:GetFont()
    if fontFile then frame.title:SetFont(fontFile, BANNER_FONT_SIZE, "THICKOUTLINE") end

    frame.detail = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.detail:SetPoint("TOP", frame.title, "BOTTOM", 0, -8)

    frame.fade = frame:CreateAnimationGroup()
    AddFade(frame.fade, 1, 0, BANNER_FADE, 1, BANNER_HOLD)
    frame.fade:SetScript("OnFinished", function() frame:Hide() end)
    return frame
end

-- "Gikk alliance · sett via navneplate": the reason (or which list) and how they were seen.
local function DetailLine(entry, howSeen)
    local why = entry.reason or (entry.inGuildList and "Står på guildlista" or "Står på din liste")
    return ("%s · sett via %s"):format(why, ns.HOW_SEEN_TEXT[howSeen] or howSeen)
end

local function ShowBanner(entry, howSeen)
    banner = banner or CreateBanner()
    banner.title:SetText(("KOS: %s er i nærheten!"):format(entry.name))
    banner.detail:SetText(DetailLine(entry, howSeen))
    banner.fade:Stop()
    banner:Show()
    banner.fade:Play()
end

function Alert.Show(entry, howSeen)
    local settings = ns.settings
    if settings.playSound then Alert.PlaySound(settings.soundKey) end
    if settings.flashScreen then StartFlash() end
    if settings.showBanner then ShowBanner(entry, howSeen) end
    -- Makes the game's taskbar icon blink when the game is in the background.
    if FlashClientIcon then FlashClientIcon() end
    ns:Print(("|cffff5050%s|r er i nærheten! %s"):format(entry.name, DetailLine(entry, howSeen)))
end

-- A made-up sighting, so you can hear the sound and place the "i nærheten" window.
function Alert.Test()
    local entry = { key = TEST_KEY, name = "Testnavn", reason = "Slik ser varselet ut", inPersonalList = true }
    Alert.Show(entry, "test")
    ns.Nearby.Note(entry, "test")
end
