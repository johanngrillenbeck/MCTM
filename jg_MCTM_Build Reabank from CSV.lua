--[[
ReaScript Name: jg_MCTM_Build Reabank from CSV
Author: JG (assistant)
Description: Build a Reaticulate .reabank file from INSTRUMENTS and KEY_SWITCHES CSVs.
Notes:
- One Bank per Instrument (`Library Prefix` + `Track Name`).
- Within a Bank, create two groups if present: g=channels (MIDI channel routing via Patch entries) and g=keyswitches (note outputs from KEY_SWITCHES).
- Skip instruments without multi-channel routing and without keyswitches.
]]

-- Console helpers
reaper.ClearConsole()
local function log(msg) reaper.ShowConsoleMsg(tostring(msg) .. "\n") end
local function trim(s)
  if not s then return "" end
  local r = s:gsub("^%s+", "")
  r = r:gsub("%s+$", "")
  return r
end

-- CSV parsing: semicolon separated, supports quoted fields with embedded semicolons
local function split_semicolon_quoted(line)
  local out, cur, inq = {}, "", false
  local i = 1
  while i <= #line do
    local c = line:sub(i,i)
    if c == '"' then
      local nxt = line:sub(i+1,i+1)
      if inq and nxt == '"' then
        cur = cur .. '"'
        i = i + 1
      else
        inq = not inq
      end
    elseif c == ';' and not inq then
      out[#out+1] = trim(cur); cur = ""
    else
      cur = cur .. c
    end
    i = i + 1
  end
  out[#out+1] = trim(cur)
  return out
end

-- Prompt helpers
local function prompt_file(title, ext)
  local ok, path = reaper.GetUserFileNameForRead("", title, ext)
  if not ok or not path or path == "" then return nil end
  return path
end

local function confirm_overwrite(path)
  local msg = "Overwrite reabank file?\nAll contents in '" .. tostring(path) .. "' will be replaced."
  local rv = reaper.MB(msg, "Confirm overwrite", 4) -- 6=yes/no? Using 4=OK/Cancel; treat OK as proceed
  return rv == 1 or rv == 6 -- OK or Yes
end

-- Read CSV to lines
local function read_lines(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local lines = {}
  for ln in f:lines() do table.insert(lines, ln) end
  f:close()
  return lines
end

-- Parse INSTRUMENTS: returns instruments map keyed by instrument key
-- Instrument key: Library Prefix + Track Name
-- Each instrument entry: { lib_prefix, track_name, patches = { {patch, midi_channel} ... }, keyswitch_id = number|nil }
local function parse_instruments(lines)
  if not lines or #lines == 0 then return {} end
  -- Header indices by name
  local header = split_semicolon_quoted(lines[1] or "")
  local idx = {}
  for i, h in ipairs(header) do idx[h] = i end

  local I_CTRL = idx["CTRL"] or 1
  local I_LIB = idx["Library Prefix"] or 2
  local I_NAME = idx["Track Name"] or 3
  local I_MIDI_CH = idx["Midi Channel"] or 7
  local I_PATCH = idx["Patch"] or 8
  local I_KEY_BOOL = idx["Key Sw bool"] or 10
  local I_KEY_ID = idx["Key Sw ID"] or 11

  local instruments = {}
  local order = {}
  local current_key = nil
  local current_ctrl = ""
  local current_lib = ""
  local current_name = ""

  for r = 2, #lines do
    local cols = split_semicolon_quoted(lines[r])
    -- read columns safely
    local ctrl = trim(cols[I_CTRL] or "")
    local lib = trim(cols[I_LIB] or "")
    local name = trim(cols[I_NAME] or "")
    local midi_ch = tonumber(trim(cols[I_MIDI_CH] or ""))
    local patch = trim(cols[I_PATCH] or "")
    local key_bool = trim(cols[I_KEY_BOOL] or "")
    local key_id = trim(cols[I_KEY_ID] or "")

    local is_new_instrument = (name ~= "")
    if is_new_instrument then
      current_ctrl = ctrl
      current_lib = lib
      current_name = name
      current_key = (lib ~= "" and (lib .. " - " .. name)) or name
      if current_key ~= "" then
        if not instruments[current_key] then
          instruments[current_key] = { lib_prefix = lib, track_name = name, ctrl = ctrl, patches = {}, keyswitch_id = nil }
          order[#order+1] = current_key
        end
      end
    end

    -- Continuation rows: name empty, inherit current instrument context
    local target_key = current_key
    if target_key and target_key ~= "" then
      -- Patches: if patch present and midi_ch present, add
      if patch ~= "" and midi_ch then
        table.insert(instruments[target_key].patches, { patch = patch, midi_channel = midi_ch })
      end
      -- Keyswitch: if key_bool truthy ("1", "true"), capture keyswitch_id on the first encounter
      if key_bool == "1" or key_bool:lower() == "true" then
        local idn = tonumber(key_id)
        if idn then instruments[target_key].keyswitch_id = instruments[target_key].keyswitch_id or idn end
      end
    end
  end

  return instruments, order
end

-- Parse KEY_SWITCHES: returns map by ID -> array of switch rows
-- Each row: { id, name, note, icon, color, program }
local function parse_keyswitches(lines)
  if not lines or #lines == 0 then return {} end
  local header = split_semicolon_quoted(lines[1] or "")
  local idx = {}
  for i, h in ipairs(header) do idx[h] = i end

  local I_ID = idx["ID"] or 1
  local I_NAME = idx["Articulation Name"] or 2
  local I_NOTE = idx["Note"] or 3
  local I_ICON = idx["Icon"] or 4
  local I_COLOR = idx["Color"] or 5
  local I_PROG = idx["Program Number"] or idx["Programm Number"] or 6

  local map = {}
  for r = 2, #lines do
    local cols = split_semicolon_quoted(lines[r])
    local id = tonumber(trim(cols[I_ID] or ""))
    local name = trim(cols[I_NAME] or "")
    local note = tonumber(trim(cols[I_NOTE] or ""))
    local icon = trim(cols[I_ICON] or "")
    local color = trim(cols[I_COLOR] or "")
    local program = tonumber(trim(cols[I_PROG] or ""))
    if id and name ~= "" then
      map[id] = map[id] or {}
      table.insert(map[id], { id = id, name = name, note = note, icon = icon, color = color, program = program })
    end
  end
  return map
end

-- Build reabank text for one instrument
local function build_banks_for_instrument(inst, ks_map)
  local lib = trim(inst.lib_prefix)
  local name = trim(inst.track_name)
  if name == "" then return {} end

  -- Determine features
  local channels = {}
  for _, p in ipairs(inst.patches or {}) do channels[p.midi_channel] = true end
  local channel_list = {}
  for ch,_ in pairs(channels) do table.insert(channel_list, ch) end
  table.sort(channel_list)
  local has_multi_channel = (#channel_list > 1)

  local ks_rows = nil
  if inst.keyswitch_id then ks_rows = ks_map[inst.keyswitch_id] end
  local has_keyswitches = ks_rows and #ks_rows > 0

  local banks = {}

  -- Case 1: Multi-patch + keyswitches => one bank per patch, keyswitches only
  if has_multi_channel and has_keyswitches then
    -- keep CSV order for patches
    for _, p in ipairs(inst.patches) do
      local patch_name = trim(p.patch)
      local ch = tonumber(p.midi_channel)
      local group_label = (lib ~= "" and name ~= "" and (lib .. " / " .. name)) or (name ~= "" and name or lib)
      local bank_header_name = (lib ~= "" and name ~= "" and patch_name ~= "" and (lib .. " - " .. name .. " - " .. patch_name))
                              or (patch_name ~= "" and patch_name or ((lib ~= "" and (lib .. " - " .. name)) or name))

      local buf = {}
      buf[#buf+1] = ("//! g=\"%s\" n=\"%s\""):format(group_label or "", patch_name)
      buf[#buf+1] = ("Bank * * %s"):format(bank_header_name)

      -- keyswitch programs only, keep CSV order
      local used_prog = {}
      local next_prog = 1
      for _, row in ipairs(ks_rows) do
        local prog = tonumber(row.program)
        if not prog or used_prog[prog] then
          -- assign next free program number incrementally
          while used_prog[next_prog] do next_prog = next_prog + 1 end
          prog = next_prog
          used_prog[prog] = true
          next_prog = next_prog + 1
        else
          used_prog[prog] = true
        end
        local aname = trim(row.name)
        local icon = trim(row.icon or "")
        local color = trim(row.color or "")
        -- annotation before program
        local ann = "//! g=2"
        if icon ~= "" then ann = ann .. " i=" .. icon end
        if color ~= "" then ann = ann .. " c=" .. color end
        buf[#buf+1] = ann
        if row.note and tonumber(row.note) then
          -- rely on GUI routing (or use current routed channel)
          buf[#buf+1] = ("//! o=-note:%d"):format(tonumber(row.note))
        end
        buf[#buf+1] = ("%d %s"):format(prog, aname ~= "" and aname or ("KS " .. tostring(prog)))
      end

      banks[#banks+1] = table.concat(buf, "\n") .. "\n\n"
    end
    return banks
  end

  -- Case 2: Multi-patch + no keyswitches => single bank with channel routing
  if has_multi_channel and not has_keyswitches then
    local bank_header_name = (lib ~= "" and (lib .. " - " .. name)) or name
    local buf = {}
    buf[#buf+1] = ("//! g=\"%s\" n=\"%s\""):format(lib, name)
    buf[#buf+1] = ("Bank * * %s"):format(bank_header_name)
    for _, p in ipairs(inst.patches) do
      local ch = tonumber(p.midi_channel)
      local pname = trim(p.patch)
      local prog = ch
      buf[#buf+1] = "//! g=1"
      buf[#buf+1] = ("//! o=@%d"):format(ch)
      buf[#buf+1] = ("%d %s"):format(prog, pname ~= "" and pname or ("Channel " .. tostring(ch)))
    end
    banks[#banks+1] = table.concat(buf, "\n") .. "\n\n"
    return banks
  end

  -- Case 3: Single patch + keyswitches => single bank with keyswitches only
  if (not has_multi_channel) and has_keyswitches then
    local bank_header_name = (lib ~= "" and (lib .. " - " .. name)) or name
    local buf = {}
    buf[#buf+1] = ("//! g=\"%s\" n=\"%s\""):format(lib, name)
    buf[#buf+1] = ("Bank * * %s"):format(bank_header_name)
    local used_prog = {}
    local next_prog = 1
    for _, row in ipairs(ks_rows) do
      local prog = tonumber(row.program)
      if not prog or used_prog[prog] then
        while used_prog[next_prog] do next_prog = next_prog + 1 end
        prog = next_prog
        used_prog[prog] = true
        next_prog = next_prog + 1
      else
        used_prog[prog] = true
      end
      local aname = trim(row.name)
      local icon = trim(row.icon or "")
      local color = trim(row.color or "")
      local ann = "//! g=2"
      if icon ~= "" then ann = ann .. " i=" .. icon end
      if color ~= "" then ann = ann .. " c=" .. color end
      buf[#buf+1] = ann
      if row.note and tonumber(row.note) then
        buf[#buf+1] = ("//! o=-note:%d"):format(tonumber(row.note))
      end
      buf[#buf+1] = ("%d %s"):format(prog, aname ~= "" and aname or ("KS " .. tostring(prog)))
    end
    banks[#banks+1] = table.concat(buf, "\n") .. "\n\n"
    return banks
  end

  -- Case 4: Single patch + no keyswitches => skip
  return banks
end

-- Main
local instruments_csv = prompt_file("Choose INSTRUMENTS CSV", "csv")
if not instruments_csv then log("Cancelled: INSTRUMENTS CSV path required.") return end
local keyswitches_csv = prompt_file("Choose KEY_SWITCHES CSV", "csv")
if not keyswitches_csv then log("Cancelled: KEY_SWITCHES CSV path required.") return end

local output_path = prompt_file("Choose target .reabank file (will overwrite)", "reabank")
if not output_path then log("Cancelled: .reabank path required.") return end

if not confirm_overwrite(output_path) then log("Aborted: overwrite not confirmed.") return end

local instr_lines, err1 = read_lines(instruments_csv)
if not instr_lines then reaper.MB("Failed to read INSTRUMENTS CSV: "..tostring(err1), "Error", 0) return end
local ks_lines, err2 = read_lines(keyswitches_csv)
if not ks_lines then reaper.MB("Failed to read KEY_SWITCHES CSV: "..tostring(err2), "Error", 0) return end

local instruments, instrument_order = parse_instruments(instr_lines)
local ks_map = parse_keyswitches(ks_lines)

-- Build reabank content
local outbuf = {}
local skipped = 0
for _, key in ipairs(instrument_order) do
  local inst = instruments[key]
  local banks = build_banks_for_instrument(inst, ks_map)
  if banks and #banks > 0 then
    for _, btxt in ipairs(banks) do outbuf[#outbuf+1] = btxt end
  else
    skipped = skipped + 1
  end
end

-- Write
local wf, werr = io.open(output_path, "w")
if not wf then reaper.MB("Failed to write reabank: "..tostring(werr), "Error", 0) return end
wf:write(table.concat(outbuf, ""))
wf:close()

log("Reabank written: " .. output_path)
log("Banks generated: " .. tostring(#outbuf) .. ", skipped: " .. tostring(skipped))
