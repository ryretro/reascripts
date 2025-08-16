--[[
@description Create sampled notes from selected MIDI item (modern autosampler, per-track folder + note filename)
@author Poul Høi (original), updated by ChatGPT and me
@version 1.1.0
@changelog
  + Correct render path handling: directory = <Project>/<TrackName>, filename pattern = <NoteName>
  + Safe fallback for note names (no GetNoteNameEx required)
  + Uses MIDI API for transposition (no SWS/FNG required)
  + Sets time selection to item before each render
--]]

-- Instructions
-- Create midi track, create midi clip with base note to start from and desired note length and clip length
-- Select the midi clip, run the script

-- USER CONFIG
local maxOcts = 12
local emptyNameWarning = true
local promptForSettings = true

local scriptName = "Create sampled notes from selected MIDI item (updated)"

------------------------------------------------
-- helpers
------------------------------------------------
local function msg(s)
  reaper.ShowMessageBox(tostring(s), scriptName, 0)
end

-- Safe note name (falls back if GetNoteNameEx unavailable)
local function safeGetNoteName(pitch)
  if reaper.GetNoteNameEx then
    return reaper.GetNoteNameEx(0, pitch, 0) -- returns "C#3", etc.
  end
  local names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  local note = names[(pitch % 12) + 1]
  local octave = math.floor(pitch / 12) - 1
  return note .. tostring(octave)
end

local function transposeTake(take, semitones)
  if not take or not reaper.TakeIsMIDI(take) then return end
  local _, notecnt, _, _ = reaper.MIDI_CountEvts(take)
  for i = 0, notecnt-1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    pitch = math.min(127, math.max(0, pitch + semitones))
    reaper.MIDI_SetNote(take, i, sel, muted, startppq, endppq, chan, pitch, vel, true)
  end
  reaper.MIDI_Sort(take)
end

local function setRenderSettings()
  -- Master mix, Time selection bounds, Stereo, 48k, WAV
  reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', 2, true)
  reaper.GetSetProjectInfo(0, 'RENDER_SRATE', 48000, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', "wav", true)
end

local function setTimeSelection(start_pos, end_pos)
  reaper.GetSet_LoopTimeRange2(0, true, false, start_pos, end_pos, false)
end

------------------------------------------------
-- main
------------------------------------------------
local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    msg("Select a MIDI item first.")
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    msg("Selected item is not MIDI.")
    return
  end

  -- Ensure the track has a name (used as folder name)
  local tr = reaper.GetMediaItem_Track(item)
  local _, trName = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if trName == "" and emptyNameWarning then
    local ok, newName = reaper.GetUserInputs("Set track name", 1, "New track name:", "SampledInstrument")
    if ok then
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", newName, true)
      trName = newName
    end
  end
  if trName == "" then trName = "Track" end

  if promptForSettings then
    local prompt = reaper.ShowMessageBox("Use script-defined render settings?\nOtherwise your current render settings are used.", scriptName, 4)
    if prompt == 6 then setRenderSettings() end
  end

  local ok, inputs = reaper.GetUserInputs(
    "Sampling settings", 2,
    "No. of octaves up (1-" .. maxOcts .. "),No. of samples per octave (1-12)",
    "4,4"
  )
  if not ok then return end

  local octs, sampsPerOct = inputs:match("([^,]+),([^,]+)")
  octs, sampsPerOct = tonumber(octs), tonumber(sampsPerOct)
  if not octs or not sampsPerOct or octs < 1 or octs > maxOcts or sampsPerOct < 1 or sampsPerOct > 12 then
    msg("Invalid values.")
    return
  end

  local transp = math.floor(12 / sampsPerOct)
  local samps = octs * sampsPerOct

  -- Base render directory = <ProjectPath>/<TrackName>
  local proj_path = reaper.GetProjectPathEx(0, "")
  local render_dir = proj_path .. "/" .. trName
  reaper.GetSetProjectInfo_String(0, 'RENDER_FILE', render_dir, true) -- DIRECTORY ONLY

  reaper.Undo_BeginBlock()

  for i = 1, samps do
    -- transpose up
    transposeTake(take, transp)

    -- get note name from first note (fallback if no notes)
    local _, noteCount, _, _ = reaper.MIDI_CountEvts(take)
    local noteName = "Sample_" .. i
    if noteCount > 0 then
      local _, _, _, _, _, _, pitch, _ = reaper.MIDI_GetNote(take, 0)
      if pitch then
        noteName = safeGetNoteName(pitch)
        reaper.GetSetMediaItemInfo_String(item, "P_NAME", noteName, true)
      end
    end

    -- region spanning the item (helpful for organizing)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local rgnStart, rgnEnd = pos, pos + len
    reaper.AddProjectMarker2(0, true, rgnStart, rgnEnd, noteName, -1, 0)

    -- set time selection to item (bounds = time selection)
    setTimeSelection(rgnStart, rgnEnd)

    -- FILE NAME pattern = noteName (no extension here)
    -- This makes the output: <ProjectPath>/<TrackName>/<NoteName>.wav
    reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', noteName, true)

    -- render using most recent settings
    reaper.Main_OnCommand(42230, 0)
  end

  -- reset pitch after we're done
  transposeTake(take, -samps * transp)

  reaper.Undo_EndBlock(scriptName, -1)
end

------------------------------------------------
-- run
------------------------------------------------
reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
