--[[
@description MCTM: Sync selected M tracks to VE Pro (Phase 1 test)
@version 0.1
@author Johann Grillenbeck
@about
  Resolves selected M tracks to their VE Pro channels and reconciles the
  channel enabled state with the M track's D prefix:

    M ...    -> enable
    D M ...  -> disable

  Shows a dry-run plan first and asks before writing. Set ExtState
  MCTM/vepro_dry_run=1 to report without asking or writing.

  Enabling a cold instrument can take several seconds; REAPER waits.
  This action does not change tracks, routing, or the REAPER project.
--]]

local function add_paths()
  local info = debug.getinfo(1, "S")
  local source = info and info.source
  if not source then
    return
  end

  local dir = source:match("@?(.*[\\/])")
  if not dir then
    return
  end

  local roots = {
    dir,
    dir .. "../Helpers/",
    dir .. "Helpers/",
  }

  local parts = {}
  for _, root in ipairs(roots) do
    parts[#parts + 1] = root .. "?.lua;"
    parts[#parts + 1] = root .. "?/init.lua;"
  end

  package.path = table.concat(parts) .. package.path
end

add_paths()

local ok_mctm, mctm = pcall(require, "jg_MCTM_helper")
if not ok_mctm then
  reaper.ShowConsoleMsg(
    "Could not require jg_MCTM_helper: " .. tostring(mctm) .. "\n\npackage.path:\n" .. package.path .. "\n"
  )
  return
end

local ok_vepro, V = pcall(require, "jg_MCTM_VEPro")
if not ok_vepro then
  reaper.ShowConsoleMsg(
    "Could not require jg_MCTM_VEPro: " .. tostring(V) .. "\n\npackage.path:\n" .. package.path .. "\n"
  )
  return
end

V.reset_cache()

local function to_text(value)
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function one_line(value)
  return (to_text(value):gsub("[\r\n\t]+", " "))
end

local function bool_text(value)
  return value and "true" or "false"
end

local function tsv_field(value)
  return (to_text(value):gsub("[\t\r\n]+", " "))
end

local function side_effect_note(side_effects)
  if type(side_effects) ~= "table" then
    return ""
  end

  local parts = {}
  for _, key in ipairs({ "ungated", "routed", "suppressed" }) do
    local list = side_effects[key]
    if type(list) == "table" and #list > 0 then
      local names = {}
      for _, item in ipairs(list) do
        names[#names + 1] = tostring(item.channelAddress or item.title or "?")
      end
      parts[#parts + 1] = key .. "=[" .. table.concat(names, ", ") .. "]"
    end
  end

  if #parts == 0 then
    return ""
  end
  return "  [side effects: " .. table.concat(parts, "; ") .. "]"
end

local function open_report()
  local resource = tostring(reaper.GetResourcePath() or ""):gsub("[\\/]+$", "")
  local candidates = {
    resource .. "/Scripts/jg_MCTM_vepro_sync_test.tsv",
    resource .. "/jg_MCTM_vepro_sync_test.tsv",
  }

  for _, path in ipairs(candidates) do
    local file = io.open(path, "w")
    if file then
      return file, path
    end
  end

  return nil, nil
end

local jobs = {}
for index = 0, reaper.CountSelectedTracks(0) - 1 do
  local track = reaper.GetSelectedTrack(0, index)
  local _, track_name = reaper.GetTrackName(track)
  local parsed = mctm.parse(track_name)

  if mctm.is_midi(parsed) then
    jobs[#jobs + 1] = {
      midi_track = track,
      base_name = parsed.name,
      desired = not mctm.is_disabled(parsed),
      label = track_name,
    }
  end
end

if #jobs == 0 then
  reaper.MB(
    "Select one or more M tracks first.\n\nA tracks are ignored; select the M track (or the group including it).",
    "MCTM VE Pro sync",
    0
  )
  return
end

local plan = V.sync(jobs, { dry_run = true })
local plan_summary = plan.summary
local resolvable = #jobs - plan_summary.errors

local force_dry_run = reaper.GetExtState("MCTM", "vepro_dry_run") == "1"
local report = plan

if not force_dry_run and resolvable > 0 then
  local answer = reaper.MB(
    string.format(
      "Selected M tracks: %d\n\nEnable: %d\nDisable: %d\nUnchanged: %d\nResolve errors: %d\n\nApply these changes now?\nVE Pro may take a few seconds per instrument.",
      #jobs,
      plan_summary.would_enable,
      plan_summary.would_disable,
      plan_summary.unchanged,
      plan_summary.errors
    ),
    "MCTM VE Pro sync",
    4
  )

  if answer == 6 then
    report = V.sync(jobs, { dry_run = false })
  end
end

local summary = report.summary
local timestamp = os.date("%Y-%m-%d %H:%M:%S")
local lines = {}

lines[#lines + 1] = "MCTM VE Pro sync - " .. timestamp
lines[#lines + 1] = string.format(
  "Selected M tracks: %d | mode: %s",
  #jobs,
  report.dry_run and "dry run" or "applied"
)
lines[#lines + 1] = string.rep("-", 110)

for _, record in ipairs(report.results) do
  local action = (record.action:upper():gsub("_", " "))
  local note = ""

  if record.action == "error" and record.error then
    note = "  [" .. tostring(record.error.code) .. ": " .. one_line(record.error.message) .. "]"
  elseif record.side_effects then
    note = side_effect_note(record.side_effects)
  end

  lines[#lines + 1] = string.format(
    "[%-14s] %-44s -> %s bus %-3d -> \"%s\" (%s -> %s)%s",
    action,
    one_line(record.label),
    one_line(record.instance_name),
    record.bus,
    one_line(record.title),
    bool_text(record.before),
    bool_text(record.after or record.desired),
    note
  )
end

for _, entry in ipairs(report.errors) do
  if not entry.record then
    lines[#lines + 1] = string.format(
      "[%-14s] %-44s -> %s: %s",
      "ERROR",
      one_line(entry.label),
      tostring(entry.error and entry.error.code or "ERROR"),
      one_line(entry.error and entry.error.message or "unknown error")
    )
  end
end

lines[#lines + 1] = string.rep("-", 110)
lines[#lines + 1] = string.format(
  "Enabled=%d Disabled=%d Unchanged=%d WouldEnable=%d WouldDisable=%d Errors=%d",
  summary.enabled,
  summary.disabled,
  summary.unchanged,
  summary.would_enable,
  summary.would_disable,
  summary.errors
)

local report_file, report_path = open_report()
if report_file then
  report_file:write("\239\187\191")
  report_file:write(table.concat({
    "timestamp",
    "action",
    "label",
    "instance",
    "bus",
    "channel_address",
    "channel_id",
    "title",
    "before",
    "desired",
    "after",
    "note",
  }, "\t") .. "\n")

  for _, record in ipairs(report.results) do
    local note = ""
    if record.action == "error" and record.error then
      note = tostring(record.error.code) .. ": " .. tostring(record.error.message)
    elseif record.side_effects then
      note = side_effect_note(record.side_effects)
    end

    report_file:write(table.concat({
      timestamp,
      record.action,
      tsv_field(record.label),
      tsv_field(record.instance_name),
      tostring(record.bus),
      tsv_field(record.channel_address),
      record.channel_id,
      tsv_field(record.title),
      bool_text(record.before),
      bool_text(record.desired),
      bool_text(record.after),
      tsv_field(note),
    }, "\t") .. "\n")
  end

  report_file:close()
  lines[#lines + 1] = "Report: " .. report_path
else
  lines[#lines + 1] = "Report: could not write TSV file (check REAPER resource path permissions)"
end

reaper.ShowConsoleMsg(table.concat(lines, "\n") .. "\n")

reaper.MB(
  string.format(
    "%s\n\nEnabled: %d\nDisabled: %d\nUnchanged: %d\nErrors: %d\n\nReport:\n%s",
    report.dry_run and "Dry run - no changes applied." or "VE Pro sync complete.",
    summary.enabled,
    summary.disabled,
    summary.unchanged,
    summary.errors,
    report_path or "(no report file)"
  ),
  "MCTM VE Pro sync",
  0
)
