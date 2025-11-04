-- jg_MCTM_helper.lua
-- Helper for Media Composer Template Manager (MCTM)
-- Parses track prefixes and finds audio/midi/ctrl pairs.

local M = {}

local function trim(s)
  return (s and s:gsub("^%s+","":gsub("%s+$",""))) or ""
end

local valid_prefixes = {
  ["A"] = true,
  ["M"] = true,
  ["D"] = true,
  ["CTRL"] = true,
}

-- Parse a track label using space-separated tokens only.
-- Prefix tokens are recognized only when they are exact tokens followed by a space.
-- Example: "M Violin", "D M Viola", "CTRL ViennaHost", "A Cello"
function M.parse_label(label)
  if not label then return {prefixes = {}, name = ""} end
  label = trim(label)
  if label == "" then return {prefixes = {}, name = ""} end

  -- split on spaces only (consecutive spaces are treated as single separators)
  local tokens = {}
  for token in label:gmatch("%S+") do
    table.insert(tokens, token)
  end

  local prefixes = {}
  local i = 1
  while tokens[i] and valid_prefixes[tokens[i]:upper()] do
    table.insert(prefixes, tokens[i]:upper())
    i = i + 1
  end

  -- remainder tokens form the name (joined with single spaces)
  local name_tokens = {}
  while tokens[i] do
    table.insert(name_tokens, tokens[i])
    i = i + 1
  end
  local name = table.concat(name_tokens, " ")
  name = trim(name)

  return {prefixes = prefixes, name = name}
end

function M.has_prefix(parsed, pfx)
  if not parsed or not parsed.prefixes then return false end
  for _,p in ipairs(parsed.prefixes) do
    if p == pfx then return true end
  end
  return false
end

function M.is_disabled(parsed) return M.has_prefix(parsed, "D") end
function M.is_audio(parsed) return M.has_prefix(parsed, "A") end
function M.is_midi(parsed) return M.has_prefix(parsed, "M") end
function M.is_ctrl(parsed) return M.has_prefix(parsed, "CTRL") end

local function canonical(name)
  if not name then return "" end
  return trim(name):lower()
end

-- tracks: array of label strings
-- opts: { include_disabled = false }
function M.find_pairs(tracks, opts)
  opts = opts or {}
  local include_disabled = opts.include_disabled or false

  local byname = {}
  for _,label in ipairs(tracks) do
    local parsed = M.parse_label(label)
    local disabled = M.is_disabled(parsed)
    if not (disabled and not include_disabled) then
      local key = canonical(parsed.name)
      if key == "" then key = canonical(label) end
      local entry = byname[key]
      if not entry then entry = {name = parsed.name, audio = nil, midi = nil, ctrl = nil, disabled = disabled} byname[key] = entry end
      if M.is_audio(parsed) then entry.audio = label end
      if M.is_midi(parsed) then entry.midi = label end
      if M.is_ctrl(parsed) then entry.ctrl = label end
      if disabled then entry.disabled = true end
    end
  end
  return byname
end

function M.format_label(prefixes, name)
  local p = {}
  for _,v in ipairs(prefixes or {}) do table.insert(p, v) end
  local s = table.concat(p, " ")
  if s ~= "" and name and name ~= "" then
    return s .. " " .. name
  elseif s ~= "" then
    return s
  else
    return name or ""
  end
end

M.parse = M.parse_label
M.findPairs = M.find_pairs
M._internal = {valid_prefixes = valid_prefixes}

return M
