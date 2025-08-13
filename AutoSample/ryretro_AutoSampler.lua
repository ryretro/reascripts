-- @description AutoSampler (chromatic) — generate MIDI, record, split & export per note
-- @version 1.0.0
-- @author ryretro
-- @changelog
--   + First release based on AutoSample MIDI generator: records external instrument and exports named WAVs per note.
-- @about
--   Creates a chromatic MIDI pass, records the selected track's audio input, splits by each note window,
--   renames takes to note names, then renders items to audio files (named from take names).
--   Uses seconds for note on/off timing (tempo-independent spacing).

local scriptName = "AutoSampler"

--=============================
-- Defaults / Persisted Params
--=============================
local defaults = {
  startNote = 36,      -- C2
  endNote   = 84,      -- C6
  octSilence = 0,      -- octaves of empty time before first note (12 notes per octave)
  noteOnSec = 1.0,     -- seconds note held
  noteOffSec = 0.5,    -- seconds gap after note
  velocity = 100,      -- 1..127
  previewEnabled = 0,  -- 0/1
  namePrefix = "AutoSample" -- file/take name prefix
}

local function getExt(key, def)
  local v = reaper.GetExtState(scriptName, key)
  if v == "" then return def end
  local num = tonumber(v)
  return num ~= nil and num or v
end

local function setExt(key, v)
  reaper.SetExtState(scriptName, key, tostring(v), true)
end

-- Load state
local startNote      = getExt("startNote", defaults.startNote)
local endNote        = getExt("endNote", defaults.endNote)
local octSilence     = getExt("octSilence", defaults.octSilence)
local noteOnSec      = getExt("noteOnSec", defaults.noteOnSec)
local noteOffSec     = getExt("noteOffSec", defaults.noteOffSec)
local velocity       = getExt("velocity", defaults.velocity)
local previewEnabled = (getExt("previewEnabled", defaults.previewEnabled) == 1)
local namePrefix     = getExt("namePrefix", defaults.namePrefix)

--=============================
-- Note name helpers
--=============================
local noteNames = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local function noteNumToName(num)
  local n = noteNames[(num % 12) + 1]
  local oct = math.floor(num/12) - 1
  return string.format("%s%d", n, oct)
end

--=============================
-- Preview (MIDI to selected track only)
--=============================
local lastPreview = nil
local function previewNote(note)
  if not previewEnabled then return end
  local tr = reaper.GetSelectedTrack(0,0); if not tr then return end
  if lastPreview == note then return end
  lastPreview = note
  local ch = 0
  local vel = math.max(1, math.min(127, math.floor(velocity + 0.5)))
  -- StuffMIDIMessage goes to the Virtual MIDI keyboard/bus. It's fine for quick preview.
  reaper.StuffMIDIMessage(0, 0x90 + ch, note, vel)
  reaper.defer(function() reaper.StuffMIDIMessage(0, 0x80 + ch, note, 0) end)
end

--=============================
-- ImGui setup
--=============================
local ctx = reaper.ImGui_CreateContext(scriptName)
local font = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, font)

local function sliderIntNote(label, value, minVal, maxVal, key)
  local changed, newVal = reaper.ImGui_SliderInt(ctx, label, value, minVal, maxVal)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    previewNote(newVal) -- double-click previews only (does not reset)
  end
  if changed then setExt(key, newVal) end
  return changed, newVal
end

local function sliderIntReset(label, value, minVal, maxVal, def, key)
  local changed, newVal = reaper.ImGui_SliderInt(ctx, label, value, minVal, maxVal)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    newVal, changed = def, true
  end
  if changed then setExt(key, newVal) end
  return changed, newVal
end

local function inputDoubleReset(label, value, def, key)
  local changed, newVal = reaper.ImGui_InputDouble(ctx, label, value, 0.01, 0.1, "%.3f")
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    newVal, changed = def, true
  end
  if changed then setExt(key, newVal) end
  return changed, newVal
end

local function inputTextReset(label, value, def, key)
  local changed, newVal = reaper.ImGui_InputText(ctx, label, value)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    newVal, changed = def, true
  end
  if changed then setExt(key, newVal) end
  return changed, newVal
end

--=============================
-- Timing helpers (seconds→beats/QN)
--=============================
local function SecToBeats(sec)
  local bpm = reaper.Master_GetTempo()
  return sec * (bpm / 60.0)
end

--=============================
-- MIDI generation (same engine as before)
--=============================
local function GenerateChromaticMIDIOnTrack(track, t0_sec, startNote, endNote, octSil, noteOnSec, noteOffSec, velocity)
  local proj = 0
  local onBeats  = SecToBeats(noteOnSec)
  local offBeats = SecToBeats(noteOffSec)
  local totalNotes = (endNote - startNote + 1)
  local preBeats = (octSil * 12) * (onBeats + offBeats)
  local totalBeats = preBeats + totalNotes * (onBeats + offBeats)
  local t1_sec = t0_sec + reaper.TimeMap2_QNToTime(proj, totalBeats)

  local item = reaper.CreateNewMIDIItemInProj(track, t0_sec, t1_sec)
  local take = reaper.GetActiveTake(item)

  local currentQN = preBeats
  for note = startNote, endNote do
    local onPPQ  = reaper.MIDI_GetPPQPosFromProjQN(take, currentQN)
    local offPPQ = reaper.MIDI_GetPPQPosFromProjQN(take, currentQN + onBeats)
    reaper.MIDI_InsertNote(take, false, false, onPPQ, offPPQ, 0, note, math.max(1, math.min(127, velocity)), false)
    currentQN = currentQN + onBeats + offBeats
  end
  reaper.MIDI_Sort(take)
  return item, t1_sec
end

--=============================
-- Recording + split + export
--=============================
local function EnsureNormalRecordMode(track)
  -- leave user input source as-is; just ensure we're not in "time selection auto-punch" etc:
  local recmode = reaper.GetMediaTrackInfo_Value(track, "I_RECMODE")
  if recmode ~= 0 then reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 0) end -- 0 = normal
end

local function StartStopRecordForDuration(totalDurSec)
  reaper.CSurf_OnRecord() -- start rec
  local tStart = reaper.time_precise()
  local function waiter()
    local now = reaper.time_precise()
    if now - tStart >= totalDurSec then
      reaper.CSurf_OnStop()
    else
      reaper.defer(waiter)
    end
  end
  waiter()
end

local function SplitRecordedItemsAtBoundaries(track, t0, starts, ends)
  -- Split the (long) recorded item on this track around each [start, end] segment.
  -- Returns a table of per-note items.
  local items = {}
  -- First, ensure we only operate on items recorded within [t0, last end]
  local lastEnd = ends[#ends]
  local ic = reaper.CountTrackMediaItems(track)
  -- Collect candidate items overlapping our window
  local candidates = {}
  for i=0, ic-1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local pos  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    local itEnd = pos + len
    if itEnd > t0 and pos < lastEnd + 0.001 then
      candidates[#candidates+1] = it
    end
  end
  -- If nothing, bail
  if #candidates == 0 then return items end

  -- We’ll split all candidates at each boundary so every note segment becomes its own item.
  reaper.Main_OnCommand(40757, 0) -- Item: Unselect all items
  for _,it in ipairs(candidates) do reaper.SetMediaItemSelected(it, true) end

  -- Make a set of unique split points
  local points = {}
  for i=1,#starts do
    points[#points+1] = starts[i]
    points[#points+1] = ends[i]
  end
  table.sort(points)

  for _,pt in ipairs(points) do
    reaper.SplitItemsAtTime(track, pt) -- helper we implement next
  end

  -- After splitting, collect the items that lie within each [start,end] window (choose the one overlapping fully)
  reaper.Main_OnCommand(40757, 0) -- unselect
  local ic2 = reaper.CountTrackMediaItems(track)
  for i=1,#starts do
    local s, e = starts[i], ends[i]
    local best = nil
    for j=0, ic2-1 do
      local it = reaper.GetTrackMediaItem(track, j)
      local pos  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local len  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      local itEnd = pos + len
      if math.abs(pos - s) < 0.001 or (pos <= s+0.0005 and itEnd >= e-0.0005) then
        best = it; break
      end
    end
    if best then items[#items+1] = best end
  end
  return items
end

-- We need a robust split helper (works like "Split items at edit cursor" but at arbitrary time)
function reaper.SplitItemsAtTime(track, time)
  -- Select all items on track, split at time with command 40759 ("Split items at time selection") via temp time selection
  local tsStart, tsEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  reaper.GetSet_LoopTimeRange(true, false, time, time, false)
  reaper.Main_OnCommand(40759, 0) -- Item: Split items at time selection
  reaper.GetSet_LoopTimeRange(true, false, tsStart, tsEnd, false) -- restore
end

local function NameItemsAsNotes(items, startNote, namePrefix)
  for idx,it in ipairs(items) do
    local take = reaper.GetActiveTake(it)
    if take then
      local pitch = startNote + (idx-1)
      local nm = string.format("%s_%s", namePrefix, noteNumToName(pitch))
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", nm, true)
    end
  end
end

local function RenderItemsToFiles(items)
  -- Select items, then run native action: "Item: Render items to new files" (41824)
  reaper.Main_OnCommand(40757, 0) -- unselect all
  for _,it in ipairs(items) do reaper.SetMediaItemSelected(it, true) end
  reaper.Main_OnCommand(41824, 0) -- Item: Render items to new files
  reaper.Main_OnCommand(40757, 0) -- unselect all
end

--=============================
-- UI frame
--=============================
local function frame()
  -- Notes
  reaper.ImGui_Text(ctx, "Start Note: " .. noteNumToName(startNote))
  local ch, v = sliderIntNote("##start", startNote, 12, 108, "startNote")
  if ch then startNote = v; if startNote > endNote then endNote = startNote end end

  reaper.ImGui_Text(ctx, "End Note: " .. noteNumToName(endNote))
  ch, v = sliderIntNote("##end", endNote, 12, 108, "endNote")
  if ch then endNote = v; if endNote < startNote then startNote = endNote end end

  reaper.ImGui_Text(ctx, "Octaves of Silence: " .. octSilence)
  ch, v = sliderIntReset("##octSil", octSilence, 0, 8, defaults.octSilence, "octSilence")
  if ch then octSilence = v end

  -- Timing
  reaper.ImGui_Text(ctx, "Note On (sec):")
  ch, v = inputDoubleReset("##noteOn", noteOnSec, defaults.noteOnSec, "noteOnSec")
  if ch then noteOnSec = math.max(0, v) end

  reaper.ImGui_Text(ctx, "Note Off (sec):")
  ch, v = inputDoubleReset("##noteOff", noteOffSec, defaults.noteOffSec, "noteOffSec")
  if ch then noteOffSec = math.max(0, v) end

  -- Velocity
  reaper.ImGui_Text(ctx, "Velocity: " .. velocity)
  ch, v = sliderIntReset("##vel", velocity, 1, 127, defaults.velocity, "velocity")
  if ch then velocity = v end

  -- Prefix
  reaper.ImGui_Text(ctx, "File/Take Name Prefix:")
  ch, v = inputTextReset("##prefix", namePrefix, defaults.namePrefix, "namePrefix")
  if ch then namePrefix = v end

  -- Preview toggle
  local prevChanged, prevVal = reaper.ImGui_Checkbox(ctx, "Preview Notes", previewEnabled)
  if prevChanged then
    previewEnabled = prevVal
    setExt("previewEnabled", previewEnabled and 1 or 0)
  end

  reaper.ImGui_Separator(ctx)

  -- Button: Generate MIDI (only)
  if reaper.ImGui_Button(ctx, "Generate MIDI Only") then
    local tr = reaper.GetSelectedTrack(0,0)
    if not tr then reaper.ShowMessageBox("Select a track first.", "AutoSample", 0) return end
    reaper.Undo_BeginBlock()
    GenerateChromaticMIDIOnTrack(tr, reaper.GetCursorPosition(), startNote, endNote, octSilence, noteOnSec, noteOffSec, velocity)
    reaper.Undo_EndBlock("AutoSample: Generate MIDI", -1)
  end

  reaper.ImGui_SameLine(ctx)
  -- Button: Autosample (record + export)
  if reaper.ImGui_Button(ctx, "Autosample: Record & Export") then
    local tr = reaper.GetSelectedTrack(0,0)
    if not tr then reaper.ShowMessageBox("Select a track set to your instrument’s AUDIO input.\nRoute MIDI from this track to your external instrument.", "AutoSample", 0) return end

    -- Safety checks
    if startNote > endNote then reaper.ShowMessageBox("Start note is above End note.", "AutoSample", 0) return end
    if noteOnSec <= 0 then reaper.ShowMessageBox("Note On must be > 0 sec.", "AutoSample", 0) return end

    reaper.Undo_BeginBlock()

    -- 1) Generate MIDI item on the selected track starting now
    local t0 = reaper.GetCursorPosition()
    local midiItem, t1 = GenerateChromaticMIDIOnTrack(tr, t0, startNote, endNote, octSilence, noteOnSec, noteOffSec, velocity)

    -- 2) Arm and record the track in normal mode
    EnsureNormalRecordMode(tr)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)

    -- 3) Compute per-note windows in seconds for splitting
    local onBeats  = SecToBeats(noteOnSec)
    local offBeats = SecToBeats(noteOffSec)
    local preBeats = (octSilence * 12) * (onBeats + offBeats)

    local starts, ends = {}, {}
    local qn0 = reaper.TimeMap2_timeToQN(0, t0)
    local curQN = qn0 + preBeats
    for n = startNote, endNote do
      local on_t  = reaper.TimeMap2_QNToTime(0, curQN)
      local off_t = reaper.TimeMap2_QNToTime(0, curQN + onBeats)
      starts[#starts+1] = on_t
      ends[#ends+1]   = off_t
      curQN = curQN + onBeats + offBeats
    end

    -- 4) Record for total pass length (t1 - t0)
    StartStopRecordForDuration((t1 - t0) + 0.01)

    -- 5) Split recorded items per note, name takes, render to files
    local items = SplitRecordedItemsAtBoundaries(tr, t0, starts, ends)
    if #items == 0 then
      reaper.ShowMessageBox("No recorded audio found on the selected track during the pass.\nCheck your audio input and try again.", "AutoSample", 0)
    else
      NameItemsAsNotes(items, startNote, namePrefix)
      RenderItemsToFiles(items) -- uses native action 41824 (Item: Render items to new files)
    end

    reaper.Undo_EndBlock("AutoSample: Record & Export", -1)
  end
end

--=============================
-- Main loop
--=============================
local function loop()
  reaper.ImGui_PushFont(ctx, font, 0)
  reaper.ImGui_SetNextWindowSize(ctx, 380, 520, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, scriptName, true)
  if visible then
    frame()
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopFont(ctx)
  if open then reaper.defer(loop) end
end

loop()
