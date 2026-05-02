--[[
ReaScript Name: jg_MCTM_Patch Reaticulate Reabank with custom Reabank
Author: JG
Description:
  Patches a Reaticulate system .reabank file with articulations from a generated .reabank file.

  Matching is done by the (g=, n=) pair on the //! g="..." n="..." line.

  Rules:
  - For each bank found in BOTH files (exact g+n match): keep the system file's //! g=.../n=...
    and //! id=... lines verbatim, replace the Bank + articulation lines with the generated version.
  - For unmatched generated banks: look for a secondary match within the same group (same g=,
    different n=). Each candidate pair is confirmed by the user interactively.
    On confirmation: the system bank's //! id=... is preserved; its g/n header and body are
    replaced with the generated version (renaming the bank while keeping its existing ID).
  - Banks present only in the system file (no match at all): left entirely unchanged.
  - Banks present only in the generated file (no match at all): appended at the end.
  - A .bak backup of the system file is created before any changes are written.
]]

reaper.ClearConsole()
local function log(msg) reaper.ShowConsoleMsg(tostring(msg) .. "\n") end

-- ---------------------------------------------------------------------------
-- File I/O helpers
-- ---------------------------------------------------------------------------

local function read_lines(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local lines = {}
  for ln in f:lines() do table.insert(lines, ln) end
  f:close()
  return lines
end

local function write_lines(path, lines)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  for _, ln in ipairs(lines) do
    f:write(ln .. "\n")
  end
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Parsing helpers
-- ---------------------------------------------------------------------------

-- Extract g= and n= string values from a //! g="..." n="..." line.
local function parse_gn(line)
  local g = line:match('g="([^"]*)"')
  local n = line:match('n="([^"]*)"')
  return g, n
end

local function gn_key(g, n)
  return (g or "") .. "|" .. (n or "")
end

-- Strip a leading "Ch. nn " prefix from an n= value (used for auto-matching
-- when Ch. numbers are added to a generated file after the system file was built).
local function strip_ch_prefix(n)
  if not n then return "" end
  return n:gsub("^%[Ch%. %d+%]%s*", "")
end

-- ---------------------------------------------------------------------------
-- Parse the generated reabank file
-- ---------------------------------------------------------------------------
-- Returns:
--   banks  : { [key] = { g=, n=, header=line, body={lines} } }
--   order  : list of keys in file order (for appending new banks in order)
local function parse_generated(lines)
  local banks, order = {}, {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local g, n = parse_gn(line)
    if g and n then
      local key = gn_key(g, n)
      local body = {}
      i = i + 1
      -- Collect body lines until the next //! g=... n=... line or EOF
      while i <= #lines do
        local l = lines[i]
        if parse_gn(l) then break end
        table.insert(body, l)
        i = i + 1
      end
      -- Trim trailing blank lines so we can add exactly one blank line separator ourselves
      while #body > 0 and body[#body]:match("^%s*$") do
        table.remove(body)
      end
      if not banks[key] then
        banks[key] = { g = g, n = n, header = line, body = body }
        table.insert(order, key)
      else
        log("WARNING: duplicate bank in generated file ignored: g=\"" .. g .. "\" n=\"" .. n .. "\"")
      end
    else
      i = i + 1
    end
  end
  return banks, order
end

-- ---------------------------------------------------------------------------
-- Parse system banks (for secondary matching)
-- ---------------------------------------------------------------------------
-- Returns:
--   by_gn : { [gn_key] = { g=, n=, key= } }              — fast exact lookup
--   by_g  : { [g] = list of { g=, n=, key= } }            — same-group lookup
local function parse_system_banks(lines)
  local by_gn = {}
  local by_g  = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local g, n = parse_gn(line)
    if g and n then
      local key = gn_key(g, n)
      local entry = { g = g, n = n, key = key }
      by_gn[key] = entry
      if not by_g[g] then by_g[g] = {} end
      table.insert(by_g[g], entry)
    end
    i = i + 1
  end
  return by_gn, by_g
end

-- ---------------------------------------------------------------------------
-- Patch system file
-- ---------------------------------------------------------------------------
-- secondary_matches: { [sys_gn_key] = { gen_bank = <bank>, gen_key = <string> } }
--   When a sys bank's key is found here, its g/n header + body are replaced with
--   the matched generated bank while preserving the original //! id=... line.
local function patch_system(sys_lines, gen_banks, gen_order, secondary_matches)
  secondary_matches = secondary_matches or {}
  local out = {}
  local used_keys = {}   -- tracks gen bank keys that have been consumed
  local i = 1

  while i <= #sys_lines do
    local line = sys_lines[i]
    local g, n = parse_gn(line)

    if not (g and n) then
      -- Not a bank header — emit as-is
      table.insert(out, line)
      i = i + 1
    else
      -- ---- Start of a bank block ----
      local key = gn_key(g, n)

      -- 1) The g/n header line
      local gn_line = line
      i = i + 1

      -- 2) Collect any lines between g/n and the id= line (there should be none in
      --    a well-formed file, but be safe) plus the id= line itself.
      local pre_id = {}   -- lines between g/n and id (usually empty)
      local id_line = nil
      while i <= #sys_lines do
        local l = sys_lines[i]
        if l:match("^//! id=") then
          id_line = l
          i = i + 1
          break
        elseif parse_gn(l) then
          break  -- next bank started without an id line
        else
          table.insert(pre_id, l)
          i = i + 1
        end
      end

      -- 3) Collect the original body (Bank line + articulations + trailing blank)
      local original_body = {}
      while i <= #sys_lines do
        local l = sys_lines[i]
        if parse_gn(l) then break end
        table.insert(original_body, l)
        i = i + 1
      end

      -- ---- Emit this block ----
      local gen = gen_banks[key]
      local sec = secondary_matches[key]

      if gen then
        -- Exact match: keep system g/n header + id, replace body with generated
        used_keys[key] = true
        table.insert(out, gn_line)
        for _, l in ipairs(pre_id) do table.insert(out, l) end
        if id_line then table.insert(out, id_line) end
        for _, l in ipairs(gen.body) do
          table.insert(out, l)
        end
        table.insert(out, "")  -- blank line separator
      elseif sec then
        -- Secondary match: use generated g/n header, keep system id, use generated body
        used_keys[sec.gen_key] = true
        log("Secondary match applied: sys n=\"" .. n .. "\" → gen n=\"" .. sec.gen_bank.n .. "\" (g=\"" .. g .. "\")")
        table.insert(out, sec.gen_bank.header)  -- generated g/n header (new name)
        for _, l in ipairs(pre_id) do table.insert(out, l) end
        if id_line then table.insert(out, id_line) end
        for _, l in ipairs(sec.gen_bank.body) do
          table.insert(out, l)
        end
        table.insert(out, "")  -- blank line separator
      else
        -- No match at all — keep original block unchanged
        log("No match in generated file for: g=\"" .. g .. "\" n=\"" .. n .. "\" — left unchanged")
        table.insert(out, gn_line)
        for _, l in ipairs(pre_id) do table.insert(out, l) end
        if id_line then table.insert(out, id_line) end
        for _, l in ipairs(original_body) do
          table.insert(out, l)
        end
      end
    end
  end

  -- Append generated banks with no match (exact or secondary)
  local appended = 0
  for _, key in ipairs(gen_order) do
    if not used_keys[key] then
      local bank = gen_banks[key]
      log("New bank appended: g=\"" .. bank.g .. "\" n=\"" .. bank.n .. "\"")
      table.insert(out, "")
      table.insert(out, bank.header)
      for _, l in ipairs(bank.body) do
        table.insert(out, l)
      end
      table.insert(out, "")
      appended = appended + 1
    end
  end

  return out, appended
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

-- Prompt for the generated reabank file
local ok_gen, gen_path = reaper.GetUserFileNameForRead("", "Select generated .reabank file", "reabank")
if not ok_gen or not gen_path or gen_path == "" then
  log("Cancelled.")
  return
end

-- Prompt for the system Reaticulate.reabank to patch
local ok_sys, sys_path = reaper.GetUserFileNameForRead("", "Select system Reaticulate.reabank to patch", "reabank")
if not ok_sys or not sys_path or sys_path == "" then
  log("Cancelled.")
  return
end

-- Read both files
local gen_lines, err1 = read_lines(gen_path)
if not gen_lines then
  reaper.MB("Error reading generated file:\n" .. tostring(err1), "Error", 0); return
end

local sys_lines, err2 = read_lines(sys_path)
if not sys_lines then
  reaper.MB("Error reading system file:\n" .. tostring(err2), "Error", 0); return
end

-- Parse generated file
local gen_banks, gen_order = parse_generated(gen_lines)
log("Parsed " .. #gen_order .. " bank(s) from generated file.")

-- Parse system banks for secondary (same-group, renamed) matching
local sys_by_gn, sys_by_g = parse_system_banks(sys_lines)

-- Collect generated banks that have no exact (g+n) match in the system file
local unmatched_gen_keys = {}
for _, key in ipairs(gen_order) do
  if not sys_by_gn[key] then
    table.insert(unmatched_gen_keys, key)
  end
end

-- For each unmatched generated bank, search the same group in the system file for a
-- candidate with a different n=, then ask the user to confirm each pair individually.
local secondary_matches = {}   -- { [sys_gn_key] = { gen_bank=, gen_key= } }
local used_sys_keys    = {}   -- sys keys already claimed by a confirmed secondary match
local secondary_count  = 0

if #unmatched_gen_keys > 0 then
  log("\nChecking " .. #unmatched_gen_keys .. " unmatched generated bank(s) for same-group secondary matches...")
end

for _, gen_key in ipairs(unmatched_gen_keys) do
  local gen_bank = gen_banks[gen_key]
  local g = gen_bank.g

  -- Auto-match: if the generated n= has a "Ch. nn " prefix, try matching the
  -- stripped name against the system file. No user confirmation needed since
  -- this is a deterministic rename (adding channel numbering after the fact).
  local auto_matched = false
  local stripped_n = strip_ch_prefix(gen_bank.n)
  if stripped_n ~= gen_bank.n then
    local stripped_key = gn_key(g, stripped_n)
    local sys_entry = sys_by_gn[stripped_key]
    if sys_entry and not used_sys_keys[stripped_key] and not gen_banks[stripped_key] then
      secondary_matches[stripped_key] = { gen_bank = gen_bank, gen_key = gen_key }
      used_sys_keys[stripped_key] = true
      secondary_count = secondary_count + 1
      log("Ch. prefix auto-match: sys n=\"" .. stripped_n .. "\" → gen n=\"" .. gen_bank.n .. "\" (g=\"" .. g .. "\")")
      auto_matched = true
    end
  end

  if not auto_matched then
  local candidates = sys_by_g[g]
  if candidates then
    for _, sys_entry in ipairs(candidates) do
      -- Skip: same name (would be an exact match), already confirmed for another gen bank,
      -- or the sys bank already has its own exact match in the generated file.
      if sys_entry.n ~= gen_bank.n
        and not used_sys_keys[sys_entry.key]
        and not gen_banks[sys_entry.key]
      then
        local msg = string.format(
          'Secondary match candidate within group g="%s":\n\n'
          .. '  Generated bank:  n="%s"\n'
          .. '  System bank:     n="%s"\n\n'
          .. 'Accept? The system bank will be renamed to the generated\n'
          .. 'name and its articulations replaced. Its existing ID is preserved.',
          g, gen_bank.n, sys_entry.n
        )
        -- MB_YESNO = 4; IDYES = 6
        local result = reaper.MB(msg, "Confirm secondary match", 4)
        if result == 6 then
          secondary_matches[sys_entry.key] = { gen_bank = gen_bank, gen_key = gen_key }
          used_sys_keys[sys_entry.key] = true
          secondary_count = secondary_count + 1
          break  -- this gen bank is now matched; stop looking for more candidates
        end
      end
    end
  end
  end -- if not auto_matched
end

if secondary_count > 0 then
  log(secondary_count .. " secondary match(es) confirmed by user.")
end

-- Create backup before touching the system file
local bak_path = sys_path .. ".bak"
local bak_ok, bak_err = write_lines(bak_path, sys_lines)
if not bak_ok then
  reaper.MB("Failed to create backup:\n" .. tostring(bak_err), "Error", 0); return
end
log("Backup created: " .. bak_path)

-- Patch and write result
local patched, appended = patch_system(sys_lines, gen_banks, gen_order, secondary_matches)
local write_ok, write_err = write_lines(sys_path, patched)
if not write_ok then
  reaper.MB("Failed to write patched file:\n" .. tostring(write_err), "Error", 0); return
end

local msg = "Reabank patched successfully!\n\nPatched: " .. sys_path .. "\nBackup:  " .. bak_path
if secondary_count > 0 then
  msg = msg .. "\n\n" .. secondary_count .. " bank(s) renamed via secondary (same-group) match (see console)."
end
if appended > 0 then
  msg = msg .. "\n\n" .. appended .. " new bank(s) appended (see console for details)."
end
log("Done. Patching complete.")
reaper.MB(msg, "Patch complete", 0)
