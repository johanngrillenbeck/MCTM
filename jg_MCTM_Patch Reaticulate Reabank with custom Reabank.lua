--[[
ReaScript Name: jg_MCTM_Patch Reaticulate Reabank with custom Reabank
Author: JG
Description:
  Patches a Reaticulate system .reabank file with articulations from a generated .reabank file.

  Matching is done by the (g=, n=) pair on the //! g="..." n="..." line.

  Rules:
  - For each bank found in BOTH files: keep the system file's //! g=.../n=... and //! id=... lines
    verbatim, replace the Bank + articulation lines with the generated version.
  - Banks present only in the system file: left entirely unchanged.
  - Banks present only in the generated file: appended at the end (without an id line;
    Reaticulate will assign one on next load).
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
-- Patch system file
-- ---------------------------------------------------------------------------
local function patch_system(sys_lines, gen_banks, gen_order)
  local out = {}
  local used_keys = {}
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
      table.insert(out, gn_line)
      for _, l in ipairs(pre_id) do table.insert(out, l) end
      if id_line then table.insert(out, id_line) end

      local gen = gen_banks[key]
      if gen then
        -- Replace body with generated content
        used_keys[key] = true
        for _, l in ipairs(gen.body) do
          table.insert(out, l)
        end
        table.insert(out, "")  -- blank line separator
      else
        -- No match — keep original body unchanged
        log("No match in generated file for: g=\"" .. g .. "\" n=\"" .. n .. "\" — left unchanged")
        for _, l in ipairs(original_body) do
          table.insert(out, l)
        end
      end
    end
  end

  -- Append banks from the generated file that were not present in the system file
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

-- Create backup before touching the system file
local bak_path = sys_path .. ".bak"
local bak_ok, bak_err = write_lines(bak_path, sys_lines)
if not bak_ok then
  reaper.MB("Failed to create backup:\n" .. tostring(bak_err), "Error", 0); return
end
log("Backup created: " .. bak_path)

-- Patch and write result
local patched, appended = patch_system(sys_lines, gen_banks, gen_order)
local write_ok, write_err = write_lines(sys_path, patched)
if not write_ok then
  reaper.MB("Failed to write patched file:\n" .. tostring(write_err), "Error", 0); return
end

local msg = "Reabank patched successfully!\n\nPatched: " .. sys_path .. "\nBackup:  " .. bak_path
if appended > 0 then
  msg = msg .. "\n\n" .. appended .. " new bank(s) appended (see console for details)."
end
log("Done. Patching complete.")
reaper.MB(msg, "Patch complete", 0)
