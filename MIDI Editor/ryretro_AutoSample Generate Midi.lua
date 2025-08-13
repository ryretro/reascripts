-- @description AutoSample Chromatic MIDI Clip Generator
-- @version 1.0.0
-- @author ryretro
-- @changelog
--   + Initial release: Generate chromatic MIDI clips with customizable note range, silence (in octaves), note on/off lengths in seconds, velocity, and preview options.
-- @about
--   This script creates a chromatic MIDI clip for autosampling external instruments.
--   Features persistent parameters, double-click preview for note sliders, safe MIDI send to selected track, and ReaImGui UI.
-- @link https://github.com/ryretro/reascripts
-- @provides
--   [main] ryretro_AutoSample Generate Midi.lua
-- @category MIDI Tools

local scriptName = "AutoSample Generate Midi"

--=============================
-- Defaults Table
--=============================
local defaults = {
    startNote = 36,   -- C2
    endNote   = 84,   -- C6
    octSilence = 0,
    noteOnSec = 1.0,
    noteOffSec = 0.5,
    previewEnabled = 0,
    velocity = 100
}

--=============================
-- Persistent State Helpers
--=============================
local function getExtState(key, default)
    local val = reaper.GetExtState(scriptName, key)
    if val == "" then return default end
    return tonumber(val) or val
end

local function setExtState(key, val)
    reaper.SetExtState(scriptName, key, tostring(val), true)
end

--=============================
-- Note Name Conversion
--=============================
local noteNames = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local function noteNumToName(num)
    local name = noteNames[(num % 12) + 1]
    local octave = math.floor(num / 12) - 1
    return string.format("%s%d", name, octave)
end

--=============================
-- Load Saved Parameters
--=============================
local startNote     = getExtState("startNote", defaults.startNote)
local endNote       = getExtState("endNote", defaults.endNote)
local octSilence    = getExtState("octSilence", defaults.octSilence)
local noteOnSec     = getExtState("noteOnSec", defaults.noteOnSec)
local noteOffSec    = getExtState("noteOffSec", defaults.noteOffSec)
local previewEnabled= (getExtState("previewEnabled", defaults.previewEnabled) == 1)
local velocity      = getExtState("velocity", defaults.velocity)

--=============================
-- Preview MIDI
--=============================
local lastPreviewNote = nil
local function sendPreview(note)
    if not previewEnabled then return end
    local selTrack = reaper.GetSelectedTrack(0,0)
    if not selTrack then return end
    if lastPreviewNote == note then return end
    lastPreviewNote = note

    local chan = 0
    local vel = math.max(1, math.min(127, math.floor(velocity + 0.5)))

    reaper.StuffMIDIMessage(0, 0x90 + chan, note, vel)
    reaper.defer(function()
        reaper.StuffMIDIMessage(0, 0x80 + chan, note, 0)
    end)
end

--=============================
-- GUI Setup
--=============================
local ctx = reaper.ImGui_CreateContext(scriptName)
local font = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, font)

local function sliderIntNote(label, value, minVal, maxVal, key)
    local changed, newVal = reaper.ImGui_SliderInt(ctx, label, value, minVal, maxVal)
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        sendPreview(newVal)
    end
    if changed then
        setExtState(key, newVal)
    end
    return changed, newVal
end

local function sliderIntReset(label, value, minVal, maxVal, defaultVal, key)
    local changed, newVal = reaper.ImGui_SliderInt(ctx, label, value, minVal, maxVal)
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        newVal = defaultVal
        changed = true
    end
    if changed then
        setExtState(key, newVal)
    end
    return changed, newVal
end

local function inputDoubleReset(label, value, defaultVal, key)
    local changed, newVal = reaper.ImGui_InputDouble(ctx, label, value, 0.01, 0.1, "%.3f")
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        newVal = defaultVal
        changed = true
    end
    if changed then
        setExtState(key, newVal)
    end
    return changed, newVal
end

--=============================
-- Main Frame
--=============================
function frame()
    -- Start Note
    reaper.ImGui_Text(ctx, "Start Note: " .. noteNumToName(startNote))
    local changed, val = sliderIntNote("##start", startNote, 12, 108, "startNote")
    if changed then
        startNote = val
        if startNote > endNote then endNote = startNote end
    end

    -- End Note
    reaper.ImGui_Text(ctx, "End Note: " .. noteNumToName(endNote))
    changed, val = sliderIntNote("##end", endNote, 12, 108, "endNote")
    if changed then
        endNote = val
        if endNote < startNote then startNote = endNote end
    end

    -- Octaves of Silence
    reaper.ImGui_Text(ctx, "Octaves of Silence: " .. octSilence)
    changed, val = sliderIntReset("##octSil", octSilence, 0, 8, defaults.octSilence, "octSilence")
    if changed then octSilence = val end

    -- Note On Length
    reaper.ImGui_Text(ctx, "Note On (sec):")
    changed, val = inputDoubleReset("##noteOn", noteOnSec, defaults.noteOnSec, "noteOnSec")
    if changed then noteOnSec = math.max(0, val) end

    -- Note Off Length
    reaper.ImGui_Text(ctx, "Note Off (sec):")
    changed, val = inputDoubleReset("##noteOff", noteOffSec, defaults.noteOffSec, "noteOffSec")
    if changed then noteOffSec = math.max(0, val) end

    -- Velocity
    reaper.ImGui_Text(ctx, "Velocity: " .. velocity)
    changed, val = sliderIntReset("##vel", velocity, 1, 127, defaults.velocity, "velocity")
    if changed then velocity = val end

    -- Preview Checkbox
    local prevChanged, prevVal = reaper.ImGui_Checkbox(ctx, "Preview Notes", previewEnabled)
    if prevChanged then
        previewEnabled = prevVal
        setExtState("previewEnabled", previewEnabled and 1 or 0)
    end

    -- Generate Button
    if reaper.ImGui_Button(ctx, "Generate MIDI Clip") then
        reaper.Undo_BeginBlock()
        local proj = 0
        local selTrack = reaper.GetSelectedTrack(proj, 0)
        if selTrack then
            local startPos = 0
            local totalNotes = (endNote - startNote + 1)
            local totalTime = octSilence * 12 * (noteOnSec + noteOffSec) + totalNotes * (noteOnSec + noteOffSec)
            local item = reaper.CreateNewMIDIItemInProj(selTrack, startPos, totalTime)
            local take = reaper.GetActiveTake(item)
            local time = octSilence * 12 * (noteOnSec + noteOffSec)
            for note = startNote, endNote do
                local onPos = time
                local offPos = time + noteOnSec
                reaper.MIDI_InsertNote(take, false, false,
                    reaper.TimeMap2_timeToQN(proj, onPos),
                    reaper.TimeMap2_timeToQN(proj, offPos),
                    0, note, velocity, false)
                time = time + noteOnSec + noteOffSec
            end
            reaper.MIDI_Sort(take)
        end
        reaper.Undo_EndBlock("Generate Chromatic MIDI Clip", -1)
    end
end

--=============================
-- Main Loop
--=============================
function loop()
    reaper.ImGui_PushFont(ctx, font, 0)
    reaper.ImGui_SetNextWindowSize(ctx, 320, 420, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, scriptName, true)
    if visible then
        frame()
        reaper.ImGui_End(ctx)
    end
    reaper.ImGui_PopFont(ctx)
    if open then reaper.defer(loop) end
end

loop()
