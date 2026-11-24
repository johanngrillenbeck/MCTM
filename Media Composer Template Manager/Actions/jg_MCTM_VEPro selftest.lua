--[[
@description MCTM: VE Pro mapping selftest (read only)
@version 0.2
@author Johann Grillenbeck
@about
  Resolves every M track to its VE Pro instance and instrument channel via
  the MIDI send destination bus (the same number as the VE Pro midiPort).

  Read-only:
    - does not modify tracks
    - does not write to VE Pro
    - does not require a track selection

  Prints a report to the REAPER console and writes a TSV file to the REAPER
  resource folder for inspection in a spreadsheet.

  Use this before enabling the write path to verify the bus -> channel mapping
  on the real template.
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

  -- Repo layout: Actions/ + ../Helpers/. Also tolerate a flat install.
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

local ok_mctm, mctm = pcall(require, "jg_MCTM_Helper")
if not ok_mctm then
  reaper.ShowConsoleMsg(
    "Could not require jg_MCTM_Helper: " .. tostring(mctm) .. "\n\npackage.path:\n" .. package.path .. "\n"
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

local function error_detail(err)
  if not err then
    return ""
  end

  local parts = {}
  if err.stderr and err.stderr ~= "" then
    parts[#parts + 1] = "stderr: " .. one_line(err.stderr):sub(1, 300)
  end
  if err.stdout and err.stdout ~= "" then
    parts[#parts + 1] = "stdout: " .. one_line(err.stdout):sub(1, 300)
  end
  if err.raw and err.raw ~= "" then
    parts[#parts + 1] = "raw: " .. one_line(err.raw):sub(1, 300)
  end
  if err.cmd and err.cmd ~= "" then
    parts[#parts + 1] = "cmd: " .. one_line(err.cmd):sub(1, 300)
  end

  if #parts == 0 then
    return ""
  end
  return " [" .. table.concat(parts, "; ") .. "]"
end

local function open_report()
  local resource = tostring(reaper.GetResourcePath() or ""):gsub("[\\/]+$", "")
  local candidates = {
    resource .. "/Scripts/jg_MCTM_vepro_selftest.tsv",
    resource .. "/jg_MCTM_vepro_selftest.tsv",
  }

  for _, path in ipairs(candidates) do
    local file = io.open(path, "w")
    if file then
      return file, path
    end
  end

  return nil, nil
end

reaper.ClearConsole()

local probe, probe_err = V.probe()
if not probe then
  local message = "VE Pro API preflight failed: "
    .. tostring(probe_err and probe_err.message or "unknown error")
  reaper.ShowConsoleMsg(message .. "\n")
  reaper.MB(message, "MCTM VE Pro selftest", 0)
  return
end

local timestamp = os.date("%Y-%m-%d %H:%M:%S")
local lines = {}
local rows = {}
local counts = {}
local state_counts = { OK = 0, MISMATCH = 0 }
local total_midi_tracks = 0

lines[#lines + 1] = "MCTM VE Pro selftest (read only) - " .. timestamp
lines[#lines + 1] = "CLI: " .. probe.cli
lines[#lines + 1] = string.format("API: %s:%d (version %s)", probe.host, probe.port, probe.api_version)
lines[#lines + 1] = string.rep("-", 110)

local started = reaper.time_precise()

for index = 0, reaper.CountTracks(0) - 1 do
  local track = reaper.GetTrack(0, index)
  local _, track_name = reaper.GetTrackName(track)
  local parsed = mctm.parse(track_name)

  if mctm.is_midi(parsed) then
    total_midi_tracks = total_midi_tracks + 1

    local base_name = parsed.name
    local desired = not mctm.is_disabled(parsed)
    local result, err = V.resolve(track, base_name)

    if result then
      local state = (result.enabled == desired) and "OK" or "MISMATCH"
      state_counts[state] = (state_counts[state] or 0) + 1
      counts[result.confidence] = (counts[result.confidence] or 0) + 1

      local note = result.note or ""
      if result.instance_enabled == false then
        note = (note ~= "" and note .. "; " or "") .. "instance disabled"
      end

      lines[#lines + 1] = string.format(
        "[%-14s] %-44s -> %s bus %-3d -> \"%s\" (enabled=%s, desired=%s, %s)%s",
        result.confidence,
        one_line(track_name),
        one_line(result.instance_name),
        result.bus,
        one_line(result.title),
        bool_text(result.enabled),
        bool_text(desired),
        state,
        note ~= "" and ("  [" .. note .. "]") or ""
      )

      rows[#rows + 1] = {
        timestamp,
        result.confidence,
        track_name,
        base_name,
        result.instance_name,
        bool_text(result.instance_enabled),
        result.bus,
        result.midi_channel,
        result.title,
        result.channel_id,
        result.channel_address,
        bool_text(result.enabled),
        bool_text(desired),
        state,
        note,
      }
    else
      local code = (err and err.code) or "ERROR"
      local message = ((err and err.message) or "unknown error") .. error_detail(err)
      counts[code] = (counts[code] or 0) + 1

      lines[#lines + 1] = string.format(
        "[%-14s] %-44s -> %s",
        code,
        one_line(track_name),
        one_line(message)
      )

      rows[#rows + 1] = {
        timestamp,
        code,
        track_name,
        base_name,
        (err and err.instance) or "",
        "",
        (err and err.bus) or "",
        "",
        "",
        "",
        "",
        "",
        bool_text(desired),
        "",
        message,
      }
    end
  end
end

local elapsed = reaper.time_precise() - started

local class_order = {
  "MATCH",
  "PREFIX-DROPPED",
  "SUFFIX-ONLY",
  "RENAMED",
  "EMPTY",
  "NO_SEND",
  "BUS_ZERO",
  "AMBIGUOUS_SEND",
  "INSTANCE_NOT_FOUND",
  "INSTANCE_AMBIGUOUS",
  "NO_INSTANCES",
  "NO_CHANNEL",
  "AMBIGUOUS_CHANNEL",
  "BAD_INSTANCE_ID",
  "BAD_DATA",
  "CLI_NOT_FOUND",
  "REMOTE_HOST",
  "EXEC_FAILED",
  "NO_OUTPUT",
  "BAD_OUTPUT",
  "EMPTY_OUTPUT",
  "BAD_JSON",
  "NO_RESPONSE",
  "API_VERSION",
  "API_ERROR",
}

local printed = {}
local error_count = 0
local success_classes = {
  MATCH = true,
  ["PREFIX-DROPPED"] = true,
  ["SUFFIX-ONLY"] = true,
  RENAMED = true,
}

lines[#lines + 1] = string.rep("-", 110)
lines[#lines + 1] = string.format("Scanned %d M tracks in %.2f s", total_midi_tracks, elapsed)

for _, code in ipairs(class_order) do
  if counts[code] then
    lines[#lines + 1] = string.format("  %-20s %d", code, counts[code])
    printed[code] = true
    if not success_classes[code] then
      error_count = error_count + counts[code]
    end
  end
end

for code, count in pairs(counts) do
  if not printed[code] then
    lines[#lines + 1] = string.format("  %-20s %d", code, count)
    if not success_classes[code] then
      error_count = error_count + count
    end
  end
end

lines[#lines + 1] = string.format(
  "State: OK=%d, MISMATCH=%d",
  state_counts.OK or 0,
  state_counts.MISMATCH or 0
)

local report_file, report_path = open_report()
if report_file then
  report_file:write("\239\187\191") -- UTF-8 BOM for spreadsheet apps
  report_file:write(table.concat({
    "timestamp",
    "class",
    "reaper_track",
    "base",
    "instance",
    "instance_enabled",
    "bus",
    "midi_channel",
    "channel_title",
    "channel_id",
    "channel_address",
    "enabled",
    "desired",
    "state",
    "note",
  }, "\t") .. "\n")

  for _, row in ipairs(rows) do
    local fields = {}
    for field_index = 1, 15 do
      fields[field_index] = tsv_field(row[field_index])
    end
    report_file:write(table.concat(fields, "\t") .. "\n")
  end

  report_file:close()
  lines[#lines + 1] = "Report: " .. report_path
else
  lines[#lines + 1] = "Report: could not write TSV file (check REAPER resource path permissions)"
end

reaper.ShowConsoleMsg(table.concat(lines, "\n") .. "\n")

if error_count > 0 then
  reaper.MB(
    string.format(
      "Scanned %d M tracks.\nErrors: %d\nState mismatches: %d\n\nSee the console and:\n%s",
      total_midi_tracks,
      error_count,
      state_counts.MISMATCH or 0,
      report_path or "(no report file)"
    ),
    "MCTM VE Pro selftest",
    0
  )
end
