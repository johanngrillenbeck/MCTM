--[[
jg_MCTM_VEPro.lua
Deterministic VE Pro channel lookup for MCTM.

Phase 0: read-only. This module resolves a REAPER MIDI track to a VE Pro
instance and channel, but never writes to VE Pro.

The join key is the REAPER MIDI send destination bus, which is the same
number as the VE Pro channel's midiPort. Channel titles are only used for
diagnostics, never for lookup, because titles drift (renames, dropped
library prefixes, SUR/2 suffixes).

Public API:
  V.probe()                    -> info | nil, err
  V.instance_list()            -> array | nil, err
  V.routing_map(instance_id)   -> map | nil, err
  V.resolve(midi_track, base)  -> result | nil, err
  V.read_channel(inst, id)     -> channel | nil, err
  V.set_enabled(inst, id, on)  -> result | nil, err
  V.sync(jobs, opts)           -> report
  V.norm(s)                    -> normalized string
  V.reset_cache()

Errors are tables: { code = "...", message = "...", instance = "...", bus = n }

Requires: jg_MCTM_json (in this folder).
--]]

-- Make sure the JSON helper is findable even if the caller only added Actions/.
do
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if src then
    local dir = src:match("@?(.*[\\/])")
    if dir then
      package.path = dir .. "?.lua;" .. dir .. "?/init.lua;" .. package.path
    end
  end
end

local json = require("jg_MCTM_json")

local M = {}

M.version = "0.1"

local routing_cache = {}
local instance_cache = nil
local instance_cache_err = nil

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truthy(v)
  return v == true or v == 1 or v == "true" or v == "1"
end

local function is_loopback(host)
  host = tostring(host or ""):lower()
  return host == "127.0.0.1"
    or host == "localhost"
    or host == "::1"
    or host == "[::1]"
end

local function default_cli_path()
  local program_data = os.getenv("ProgramData") or "C:\\ProgramData"
  return program_data .. "\\VSL\\Vienna Ensemble Pro\\mcp\\vepro-api-cli.exe"
end

local function get_ext(key, default)
  local value = reaper.GetExtState("MCTM", key)
  if value == nil or value == "" then
    return default
  end
  return value
end

function M.config()
  local port = math.floor(tonumber(get_ext("vepro_port", "7200")) or 7200)
  local timeout_ms = math.floor(tonumber(get_ext("vepro_timeout_ms", "60000")) or 60000)
  return {
    cli = get_ext("vepro_cli", default_cli_path()),
    host = get_ext("vepro_host", "127.0.0.1"),
    port = port,
    timeout_ms = timeout_ms,
    allow_remote = get_ext("vepro_allow_remote", "0") == "1",
  }
end

function M.norm(s)
  if s == nil then
    return ""
  end
  local out = tostring(s):lower()
  out = out:gsub("\194\160", " ") -- UTF-8 non-breaking space
  out = out:gsub("%s+", " ")
  out = out:gsub("^ ", ""):gsub(" $", "")
  return out
end

local function is_guid(s)
  if type(s) ~= "string" then
    return false
  end
  return s:match("^%{%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x%}$") ~= nil
end

local function payload_ping()
  return '{"cmd":"ping"}'
end

local function payload_instance_list()
  return '{"cmd":"instance/list"}'
end

local function payload_routing(instance_id)
  return '{"cmd":"instance/midirouting/summary","instanceId":"' .. instance_id .. '"}'
end

local call_counter = 0

local function temp_base()
  local dir = os.getenv("TEMP") or os.getenv("TMP")
  if not dir or dir == "" then
    dir = (reaper.GetResourcePath() or ".") .. "\\Scripts"
  end
  dir = dir:gsub("[\\/]+$", "")

  call_counter = call_counter + 1
  local nonce = string.format(
    "%d_%d_%d",
    os.time(),
    call_counter,
    math.random(100000, 999999)
  )
  return dir .. "\\jg_MCTM_vepro_" .. nonce
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function remove_file(path)
  pcall(os.remove, path)
end

--- Execute one VE Pro API payload and return the decoded `response` table.
-- `payload` must be a JSON string. MCTM builds payloads from fixed keys and
-- GUIDs only, so titles never pass through the command line.
--
-- The CLI's stdout is redirected to a temp file. REAPER's ExecProcess pipe
-- truncates large responses (observed at exactly 4096/5120 bytes), while the
-- VE Pro routing summary can be 400-700 KB. Reading a file avoids that limit.
function M.api(payload, timeout_ms)
  local cfg = M.config()

  if not cfg.allow_remote and not is_loopback(cfg.host) then
    return nil, {
      code = "REMOTE_HOST",
      message = "Refusing non-loopback VE Pro host '" .. tostring(cfg.host)
        .. "'. Set MCTM/vepro_allow_remote=1 to override.",
    }
  end

  local cli_file = io.open(cfg.cli, "rb")
  if not cli_file then
    return nil, {
      code = "CLI_NOT_FOUND",
      message = "VE Pro API CLI not found: " .. tostring(cfg.cli)
        .. " (override with ExtState MCTM/vepro_cli).",
    }
  end
  cli_file:close()

  local timeout = timeout_ms or cfg.timeout_ms
  local call_timeout
  if timeout and timeout > 0 then
    call_timeout = math.max(1, math.floor(timeout / 1000) - 2)
  else
    call_timeout = 60
  end

  local base = temp_base()
  local json_path = base .. ".json"
  local err_path = base .. ".err"

  local escaped = payload:gsub('"', '\\"')
  local cli_cmd = '"' .. cfg.cli .. '" call --host ' .. cfg.host
    .. ' --port ' .. tostring(cfg.port)
    .. ' --call-timeout ' .. tostring(call_timeout)
    .. ' --payload-json "' .. escaped .. '"'

  local cmd = 'cmd.exe /C "' .. cli_cmd
    .. ' > "' .. json_path .. '" 2> "' .. err_path .. '""'

  local ok, out = pcall(reaper.ExecProcess, cmd, timeout)
  if not ok then
    remove_file(json_path)
    remove_file(err_path)
    return nil, {
      code = "EXEC_FAILED",
      message = "reaper.ExecProcess failed: " .. tostring(out),
      cmd = cmd,
    }
  end

  local exit_code, stdout_text = nil, ""
  if out then
    exit_code, stdout_text = out:match("^(%-?%d+)\r?\n(.*)$")
    exit_code = tonumber(exit_code)
    stdout_text = stdout_text or ""
  end

  local json_text = read_file(json_path)
  local err_text = read_file(err_path)
  remove_file(json_path)
  remove_file(err_path)

  if not json_text or json_text == "" then
    -- If cmd redirection was not honored for some reason, the JSON may still
    -- be in the captured stdout. Try that before giving up.
    local fallback = stdout_text:gsub("^%s+", "")
    if fallback ~= "" and fallback:find("{", 1, true) then
      json_text = fallback
    else
      return nil, {
        code = "NO_OUTPUT",
        message = "VE Pro API CLI produced no JSON (exit code "
          .. tostring(exit_code or "?") .. "). Is VE Pro running and the API enabled?",
        stdout = stdout_text:sub(1, 500),
        stderr = (err_text or ""):sub(1, 500),
        cmd = cmd,
      }
    end
  end

  local text = json_text:gsub("^%s+", "")
  text = text:gsub("^\239\187\191", "")

  if text == "" then
    return nil, {
      code = "EMPTY_OUTPUT",
      message = "VE Pro CLI returned an empty JSON file (exit code "
        .. tostring(exit_code or "?") .. ").",
      stderr = (err_text or ""):sub(1, 500),
      cmd = cmd,
    }
  end

  local doc, json_err = json.decode(text)

  -- Tolerate a warning line printed before the JSON object.
  if not doc then
    local brace = text:find("{", 1, true)
    if brace and brace > 1 then
      doc, json_err = json.decode(text:sub(brace))
    end
  end

  if not doc then
    return nil, {
      code = "BAD_JSON",
      message = "Could not decode VE Pro CLI JSON: " .. tostring(json_err),
      raw = text:sub(1, 500),
      stderr = (err_text or ""):sub(1, 500),
      cmd = cmd,
    }
  end

  local response = doc.response
  if type(response) ~= "table" then
    return nil, {
      code = "NO_RESPONSE",
      message = "VE Pro CLI JSON has no response object.",
      raw = text:sub(1, 500),
    }
  end

  if response.status ~= "success" then
    local detail = response.data and response.data.type or nil
    return nil, {
      code = response.errorCode or "API_ERROR",
      message = response.error or "VE Pro API error.",
      detail = detail,
      response = response,
    }
  end

  return response
end

--- Lightweight preflight: CLI exists, ping succeeds, API version looks right.
function M.probe()
  local cfg = M.config()

  local cli_file = io.open(cfg.cli, "rb")
  if not cli_file then
    return nil, {
      code = "CLI_NOT_FOUND",
      message = "VE Pro API CLI not found: " .. tostring(cfg.cli)
        .. " (override with ExtState MCTM/vepro_cli).",
    }
  end
  cli_file:close()

  local response, err = M.api(payload_ping(), 5000)
  if not response then
    return nil, err
  end

  local version = response.apiVersion
  if version ~= nil and tostring(version) ~= "1" then
    return nil, {
      code = "API_VERSION",
      message = "Unsupported VE Pro API version: " .. tostring(version)
        .. " (MCTM expects version 1).",
    }
  end

  return {
    cli = cfg.cli,
    host = cfg.host,
    port = cfg.port,
    api_version = version and tostring(version) or "unknown",
  }
end

--- Return the raw instance list as an array of { id, name, enabled, ... }.
-- Cached for the duration of one script run: resolving hundreds of tracks must
-- not issue hundreds of instance/list calls.
function M.instance_list()
  if instance_cache then
    return instance_cache
  end
  if instance_cache_err then
    return nil, instance_cache_err
  end

  local response, err = M.api(payload_instance_list(), 10000)
  if not response then
    instance_cache_err = err
    return nil, err
  end

  local data = response.data
  if type(data) ~= "table" then
    instance_cache_err = {
      code = "BAD_DATA",
      message = "instance/list returned no data table.",
    }
    return nil, instance_cache_err
  end

  if data.instances then
    data = data.instances
  end
  if data.id and data.name then
    data = { data }
  end

  instance_cache = data
  return data
end

local function normalize_array(value)
  if type(value) ~= "table" then
    return nil
  end

  if value[1] ~= nil then
    return value
  end

  -- Distinguish an empty array from a single object.
  for key in pairs(value) do
    if type(key) ~= "number" then
      return { value }
    end
  end

  return {}
end

--- Build port -> instrument channel map for one instance.
-- The map is keyed by VE Pro midiPort (1-based). Each entry contains the
-- distinct instrument-bearing channels on that port. The same channel can
-- appear once per MIDI channel in occupiedPairs, so channels are deduped by
-- channelId.
function M.routing_map(instance_id)
  if not is_guid(instance_id) then
    return nil, {
      code = "BAD_INSTANCE_ID",
      message = "Invalid VE Pro instance id: " .. tostring(instance_id),
    }
  end

  local cached = routing_cache[instance_id]
  if cached then
    if cached.err then
      return nil, cached.err
    end
    return cached.map
  end

  local response, err = M.api(payload_routing(instance_id), 30000)
  if not response then
    routing_cache[instance_id] = { err = err }
    return nil, err
  end

  local data = response.data
  local instances = data and data.instances or data
  instances = normalize_array(instances)
  if not instances then
    local e = {
      code = "BAD_DATA",
      message = "instance/midirouting/summary returned no instances.",
    }
    routing_cache[instance_id] = { err = e }
    return nil, e
  end

  local inst = nil
  for _, candidate in ipairs(instances) do
    if candidate.instanceId == instance_id then
      inst = candidate
      break
    end
  end
  inst = inst or instances[1]

  if not inst then
    local e = {
      code = "BAD_DATA",
      message = "No routing data for instance " .. instance_id .. ".",
    }
    routing_cache[instance_id] = { err = e }
    return nil, e
  end

  local pairs_list = normalize_array(inst.occupiedPairs)
  if not pairs_list then
    local e = {
      code = "BAD_DATA",
      message = "Routing summary has no occupiedPairs for " .. tostring(inst.name or instance_id) .. ".",
    }
    routing_cache[instance_id] = { err = e }
    return nil, e
  end

  local map = {}

  for _, pair in ipairs(pairs_list) do
    local port = tonumber(pair.midiPort)
    local midi_channel = tonumber(pair.midiChannel)

    if port then
      local entry = map[port]
      if not entry then
        entry = { by_id = {}, list = {} }
        map[port] = entry
      end

      local channels = normalize_array(pair.channels) or {}
      for _, channel in ipairs(channels) do
        if truthy(channel.hasInstrument) then
          local channel_id = channel.channelId or channel.id
          if channel_id then
            local record = entry.by_id[channel_id]
            if not record then
              record = {
                channel_id = channel_id,
                -- channelAddress may include annotations such as "3[3]".
                -- It is diagnostic only; mutation always uses channelId.
                channel_address = channel.channelAddress,
                title = channel.title or "",
                enabled = truthy(channel.enabled),
                instrument = channel.instrument,
                midi_channels = {},
              }
              entry.by_id[channel_id] = record
              entry.list[#entry.list + 1] = record
            end
            if midi_channel then
              record.midi_channels[midi_channel] = true
            end
          end
        end
      end
    end
  end

  routing_cache[instance_id] = { map = map }
  return map
end

--- Find the MIDI-enabled send from an M track to a CTRL track.
-- Returns { track, name, bus, chan } or nil, err.
function M.resolve_ctrl(midi_track)
  local send_count = reaper.GetTrackNumSends(midi_track, 0) or 0
  local found = {}

  for index = 0, send_count - 1 do
    local dest = reaper.GetTrackSendInfo_Value(midi_track, 0, index, "P_DESTTRACK")
    if dest and dest ~= 0 then
      local _, dest_name = reaper.GetTrackName(dest)
      if dest_name and dest_name:upper():match("^CTRL") then
        local flags = tonumber(reaper.GetTrackSendInfo_Value(midi_track, 0, index, "I_MIDIFLAGS")) or 0
        flags = math.floor(flags)

        local src_chan = flags % 32
        local dst_chan = math.floor(flags / 32) % 32
        local dst_bus = math.floor(flags / 4194304) % 256

        -- Low 5 bits == 31 means MIDI is disabled on this send.
        if src_chan ~= 31 then
          found[#found + 1] = {
            track = dest,
            name = dest_name,
            bus = dst_bus,
            chan = dst_chan,
          }
        end
      end
    end
  end

  if #found == 0 then
    return nil, {
      code = "NO_SEND",
      message = "No MIDI-enabled send to a CTRL track.",
    }
  end

  -- Deduplicate identical destinations; multiple distinct buses are ambiguous.
  local seen = {}
  local unique = {}
  for _, item in ipairs(found) do
    local track_number = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER") or 0
    local key = tostring(track_number) .. "|" .. tostring(item.bus)
    if not seen[key] then
      seen[key] = true
      unique[#unique + 1] = item
    end
  end

  if #unique > 1 then
    local parts = {}
    for _, item in ipairs(unique) do
      parts[#parts + 1] = tostring(item.name) .. " (bus " .. tostring(item.bus) .. ")"
    end
    return nil, {
      code = "AMBIGUOUS_SEND",
      message = "Multiple MIDI sends to CTRL tracks: " .. table.concat(parts, ", "),
    }
  end

  local target = unique[1]
  if target.bus == 0 then
    return nil, {
      code = "BUS_ZERO",
      message = "MIDI send to " .. tostring(target.name)
        .. " uses bus 0 (all buses); set an explicit destination bus.",
    }
  end

  return target
end

local function instance_first_segment(name)
  local first = tostring(name or ""):match("^(.-)%s*%-%s*")
  return first or tostring(name or "")
end

--- Match a CTRL track name to a VE Pro instance.
function M.resolve_instance(ctrl_name)
  local instances, err = M.instance_list()
  if not instances then
    return nil, err
  end

  if #instances == 0 then
    return nil, {
      code = "NO_INSTANCES",
      message = "No VE Pro instances are loaded.",
    }
  end

  local raw = trim(ctrl_name)
  if raw == "" then
    return nil, {
      code = "INSTANCE_NOT_FOUND",
      message = "CTRL track has an empty name.",
    }
  end

  local keys = { raw }
  local first_segment = instance_first_segment(raw)
  if first_segment ~= "" and first_segment ~= raw then
    keys[#keys + 1] = first_segment
  end

  -- Only use the part after CTRL for the conventional "CTRL Name" form.
  -- For "CTRLVE1" the instance name includes CTRL, so "VE1" would be wrong.
  local after_ctrl = raw:match("^CTRL%s+(.+)$")
  if after_ctrl then
    after_ctrl = trim(after_ctrl)
    if after_ctrl ~= "" and after_ctrl ~= raw then
      keys[#keys + 1] = after_ctrl
    end
  end

  local seen_keys = {}
  local unique_keys = {}
  for _, key in ipairs(keys) do
    local lower = key:lower()
    if not seen_keys[lower] then
      seen_keys[lower] = true
      unique_keys[#unique_keys + 1] = key
    end
  end

  for _, key in ipairs(unique_keys) do
    local lower_key = key:lower()
    local matches = {}

    for _, inst in ipairs(instances) do
      local name = trim(inst.name)
      local lower_name = name:lower()
      local first = instance_first_segment(name):lower()

      local exact = lower_name == lower_key
      local prefixed = lower_name:sub(1, #lower_key + 3) == lower_key .. " - "
      local segment = first == lower_key

      if exact or prefixed or segment then
        matches[#matches + 1] = inst
      end
    end

    if #matches == 1 then
      return matches[1]
    elseif #matches > 1 then
      local names = {}
      for _, inst in ipairs(matches) do
        names[#names + 1] = tostring(inst.name)
      end
      return nil, {
        code = "INSTANCE_AMBIGUOUS",
        message = "Multiple VE Pro instances match '" .. key .. "': " .. table.concat(names, ", "),
      }
    end
  end

  local names = {}
  for _, inst in ipairs(instances) do
    names[#names + 1] = tostring(inst.name)
  end
  return nil, {
    code = "INSTANCE_NOT_FOUND",
    message = "No VE Pro instance matches '" .. raw .. "'. Available: " .. table.concat(names, ", "),
  }
end

local function classify_title(base, title)
  if base == "" or title == "" then
    return "EMPTY", "empty track name or channel title"
  end

  if base == title then
    return "MATCH", ""
  end

  -- "SPA1 Woodwinds High" vs "Woodwinds High"
  if #title < #base and base:sub(#base - #title) == " " .. title then
    return "PREFIX-DROPPED", ""
  end

  -- "OTBW Flute 1" vs "OTBW Flute 1 SUR"
  if title:sub(1, #base + 1) == base .. " " then
    return "SUFFIX-ONLY", "resolved channel has an extra suffix"
  end

  return "RENAMED", "title unrelated to track name"
end

--- Resolve one MIDI track to a VE Pro instance and instrument channel.
-- `base_name` is the M track's base name (mctm.parse(name).name).
function M.resolve(midi_track, base_name)
  local ctrl, ctrl_err = M.resolve_ctrl(midi_track)
  if not ctrl then
    return nil, ctrl_err
  end

  local inst, inst_err = M.resolve_instance(ctrl.name)
  if not inst then
    return nil, inst_err
  end

  local map, map_err = M.routing_map(inst.id)
  if not map then
    map_err = map_err or {}
    map_err.instance = inst.name
    map_err.bus = ctrl.bus
    return nil, map_err
  end

  local entry = map[ctrl.bus]
  if not entry or #entry.list == 0 then
    return nil, {
      code = "NO_CHANNEL",
      message = "No instrument-bearing channel on port " .. tostring(ctrl.bus) .. ".",
      instance = inst.name,
      bus = ctrl.bus,
    }
  end

  local candidates = entry.list

  -- If the send targets a specific MIDI channel, use it to disambiguate.
  if #candidates > 1 and ctrl.chan and ctrl.chan > 0 then
    local filtered = {}
    for _, channel in ipairs(candidates) do
      if channel.midi_channels[ctrl.chan] then
        filtered[#filtered + 1] = channel
      end
    end
    if #filtered > 0 then
      candidates = filtered
    end
  end

  -- Last resort: exact normalized title match.
  if #candidates > 1 then
    local normalized_base = M.norm(base_name)
    local by_title = {}
    for _, channel in ipairs(candidates) do
      if M.norm(channel.title) == normalized_base then
        by_title[#by_title + 1] = channel
      end
    end
    if #by_title == 1 then
      candidates = by_title
    end
  end

  if #candidates > 1 then
    local titles = {}
    for _, channel in ipairs(candidates) do
      titles[#titles + 1] = tostring(channel.title) .. " (" .. tostring(channel.channel_id) .. ")"
    end
    return nil, {
      code = "AMBIGUOUS_CHANNEL",
      message = "Multiple instrument channels on port " .. tostring(ctrl.bus) .. ": "
        .. table.concat(titles, ", "),
      instance = inst.name,
      bus = ctrl.bus,
    }
  end

  local channel = candidates[1]
  local confidence, note = classify_title(M.norm(base_name), M.norm(channel.title))

  return {
    instance_id = inst.id,
    instance_name = inst.name,
    instance_enabled = (inst.enabled == nil) or truthy(inst.enabled),
    ctrl_track = ctrl.name,
    bus = ctrl.bus,
    midi_channel = ctrl.chan,
    channel_id = channel.channel_id,
    channel_address = channel.channel_address,
    title = channel.title,
    enabled = channel.enabled,
    confidence = confidence,
    note = note,
  }
end

local write_counter = 0

local function operation_key(channel_id, desired)
  write_counter = write_counter + 1
  return string.format(
    "mctm-%s-%s-%d-%d",
    desired and "enable" or "disable",
    channel_id,
    os.time(),
    write_counter
  )
end

--- Read one channel's current state by channelId.
function M.read_channel(instance_id, channel_id)
  if not is_guid(instance_id) or not is_guid(channel_id) then
    return nil, {
      code = "BAD_ARGUMENT",
      message = "Invalid instance or channel id.",
    }
  end

  local payload = '{"cmd":"instance/channelsummary","instanceId":"' .. instance_id
    .. '","fields":["channelId","channelAddress","title","enabled"],"selector":{"ids":["'
    .. channel_id .. '"]}}'

  local response, err = M.api(payload, 15000)
  if not response then
    return nil, err
  end

  local data = normalize_array(response.data)
  local channel = data and data[1]
  if not channel then
    return nil, {
      code = "CHANNEL_NOT_FOUND",
      message = "Channel not found: " .. tostring(channel_id),
    }
  end

  return {
    channel_id = channel.channelId or channel.id,
    channel_address = channel.channelAddress,
    title = channel.title or "",
    enabled = truthy(channel.enabled),
  }
end

--- Enable or disable one channel and verify the result.
-- desired=true uses channel/forceenable (with a channel/patch fallback).
-- desired=false uses channel/patch with enabled=false.
function M.set_enabled(instance_id, channel_id, desired, opts)
  opts = opts or {}

  if not is_guid(instance_id) or not is_guid(channel_id) then
    return nil, {
      code = "BAD_ARGUMENT",
      message = "Invalid instance or channel id.",
    }
  end

  desired = desired and true or false

  -- Enabling can load a cold instrument; disabling is usually quick.
  local timeout = desired and 180000 or 30000
  local key = operation_key(channel_id, desired)

  local payload
  if desired then
    payload = '{"cmd":"channel/forceenable","instanceId":"' .. instance_id
      .. '","selector":{"ids":["' .. channel_id .. '"]},"idempotencyKey":"' .. key .. '"}'
  else
    payload = '{"cmd":"channel/patch","instanceId":"' .. instance_id
      .. '","selector":{"ids":["' .. channel_id .. '"]},"enabled":false,"idempotencyKey":"'
      .. key .. '"}'
  end

  local response, err = M.api(payload, timeout)

  -- Older/other API builds may not expose forceenable; patch is the fallback.
  if not response and desired and err and err.code == "COMMAND_NOT_SUPPORTED" then
    payload = '{"cmd":"channel/patch","instanceId":"' .. instance_id
      .. '","selector":{"ids":["' .. channel_id .. '"]},"enabled":true,"idempotencyKey":"'
      .. key .. '-patch"}'
    response, err = M.api(payload, timeout)
  end

  if not response then
    return nil, err
  end

  local side_effects = response.data and response.data.sideEffects or nil

  -- forceenable returns one result per selected channel; honor an explicit failure.
  local results = response.data and response.data.results
  if results then
    local list = normalize_array(results) or {}
    local first = list[1]
    if first and first.result and first.result.ok == false then
      return nil, {
        code = "ENABLE_FAILED",
        message = "VE Pro reported that the channel was not enabled.",
        side_effects = side_effects,
        response = response,
      }
    end
  end

  local channel, read_err = M.read_channel(instance_id, channel_id)
  if not channel then
    return nil, read_err
  end

  if channel.enabled ~= desired then
    return nil, {
      code = "VERIFY_FAILED",
      message = "Channel state did not change to " .. tostring(desired) .. ".",
      channel = channel,
      side_effects = side_effects,
    }
  end

  return {
    ok = true,
    enabled = channel.enabled,
    channel = channel,
    side_effects = side_effects,
  }
end

--- Reconcile VE Pro channel state with a list of jobs.
-- jobs: { { midi_track=Track, base_name="...", desired=bool, label="..." } }
-- opts: { dry_run=bool }
function M.sync(jobs, opts)
  opts = opts or {}
  local dry_run = opts.dry_run == true

  local summary = {
    unchanged = 0,
    would_enable = 0,
    would_disable = 0,
    enabled = 0,
    disabled = 0,
    errors = 0,
  }
  local results = {}
  local errors = {}

  -- Read fresh enabled state; routing_map caches the old state after writes.
  M.reset_cache()

  for _, job in ipairs(jobs or {}) do
    local result, resolve_err = M.resolve(job.midi_track, job.base_name)

    if not result then
      summary.errors = summary.errors + 1
      errors[#errors + 1] = {
        label = job.label,
        error = resolve_err,
      }
    else
      local desired = job.desired and true or false
      local record = {
        label = job.label,
        instance_name = result.instance_name,
        instance_id = result.instance_id,
        bus = result.bus,
        channel_id = result.channel_id,
        channel_address = result.channel_address,
        title = result.title,
        before = result.enabled,
        desired = desired,
      }

      if result.enabled == desired then
        record.action = "unchanged"
        summary.unchanged = summary.unchanged + 1
      elseif dry_run then
        record.action = desired and "would_enable" or "would_disable"
        if desired then
          summary.would_enable = summary.would_enable + 1
        else
          summary.would_disable = summary.would_disable + 1
        end
      else
        local write, write_err = M.set_enabled(
          result.instance_id, result.channel_id, desired, opts
        )

        if write then
          record.action = desired and "enabled" or "disabled"
          record.after = write.enabled
          record.side_effects = write.side_effects
          if desired then
            summary.enabled = summary.enabled + 1
          else
            summary.disabled = summary.disabled + 1
          end
        else
          record.action = "error"
          record.error = write_err
          summary.errors = summary.errors + 1
          errors[#errors + 1] = {
            label = job.label,
            error = write_err,
            record = record,
          }
        end
      end

      results[#results + 1] = record
    end
  end

  -- Do not let a later sync in the same script run reuse pre-write state.
  M.reset_cache()

  return {
    dry_run = dry_run,
    summary = summary,
    results = results,
    errors = errors,
  }
end

function M.reset_cache()
  routing_cache = {}
  instance_cache = nil
  instance_cache_err = nil
end

return M
