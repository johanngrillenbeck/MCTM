--[[
@description jg_MCTM_Set all CTRL Envelopes Active
@version 1.0
@about
  Activates (envelope "Active" checkbox) all envelopes on CTRL tracks whose envelope name contains "disable".
  Keeps envelopes hidden and unarmed (VISIBLE=0, SHOWLANE=0, ARM=0).
  Creates the FX parameter envelopes only for parameters containing "disable".

  Implementation notes:
  - Enumerates existing track envelopes via CountTrackEnvelopes/GetTrackEnvelope.
  - Uses GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true).
--]]

reaper.ClearConsole()

local function get_envelope_name(env)
  -- GetEnvelopeName may return its result in different positions depending on build; handle gracefully
  local n1, n2 = reaper.GetEnvelopeName(env)
  if type(n1) == "string" then return n1 end
  if type(n2) == "string" then return n2 end
  return ""
end

local function activate_env_keep_hidden(env)
  -- Use string attributes (documented): ACTIVE / VISIBLE / ARM / SHOWLANE
  -- We change ACTIVE, and force VISIBLE/SHOWLANE off to keep UI unchanged.
  -- Also force ARM off to avoid accidental automation recording.
  local ok, cur_active = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
  local was_active = ok and cur_active == "1"

  reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
  reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "0", true)
  reaper.GetSetEnvelopeInfo_String(env, "SHOWLANE", "0", true)
  reaper.GetSetEnvelopeInfo_String(env, "ARM", "0", true)

  return not was_active
end

local function is_ctrl_track(track)
  local _, name = reaper.GetTrackName(track)
  return type(name) == "string" and name:match("^CTRL") ~= nil
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local changed_tracks = 0
local changed_envs = 0
local found_ctrl_tracks = 0
local touched_ctrl_tracks = 0
local found_disable_params = 0
local touched_envs = 0
local disarmed_envs = 0

local track_count = reaper.CountTracks(0)
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  if track and is_ctrl_track(track) then
    found_ctrl_tracks = found_ctrl_tracks + 1
    local track_changed = false
    local track_touched = false

    -- Scan regular track FX chain for parameters named like "Disable".
    -- Then create/unbypass that parameter envelope (only for those params) and activate it.
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx = 0, fx_count - 1 do
      local param_count = reaper.TrackFX_GetNumParams(track, fx)
      for p = 0, param_count - 1 do
        local ok, param_name = reaper.TrackFX_GetParamName(track, fx, p)
        if ok and type(param_name) == "string" and param_name:lower():find("disable", 1, true) then
          found_disable_params = found_disable_params + 1

          -- create=true: if envelope exists but bypassed, it will be unbypassed; if it doesn't exist, it will be created.
          local env = reaper.GetFXEnvelope(track, fx, p, true)
          if env then
            touched_envs = touched_envs + 1
            track_touched = true
            if activate_env_keep_hidden(env) then
              changed_envs = changed_envs + 1
              track_changed = true
            else
              -- Even if it was already active, still keep it hidden.
              reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "0", true)
              reaper.GetSetEnvelopeInfo_String(env, "SHOWLANE", "0", true)
              reaper.GetSetEnvelopeInfo_String(env, "ARM", "0", true)
            end
            disarmed_envs = disarmed_envs + 1
          end
        end
      end
    end

    if track_touched then
      touched_ctrl_tracks = touched_ctrl_tracks + 1
    end
    if track_changed then
      changed_tracks = changed_tracks + 1
    end
  end
end

reaper.TrackList_AdjustWindows(true)
reaper.UpdateArrange()

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock(string.format("MCTM: activate CTRL Disable envelopes (%d tracks, %d envelopes)", changed_tracks, changed_envs), -1)

reaper.ShowConsoleMsg(string.format(
  "CTRL tracks found: %d\nCTRL tracks touched: %d\nDisable params found: %d\nEnvelopes touched: %d\nEnvelopes forced unarmed: %d\nEnvelopes newly activated (ACTIVE 0->1): %d\nCTRL tracks newly activated: %d\n",
  found_ctrl_tracks,
  touched_ctrl_tracks,
  found_disable_params,
  touched_envs,
  disarmed_envs,
  changed_envs,
  changed_tracks
))
