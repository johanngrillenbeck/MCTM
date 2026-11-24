--[[
jg_MCTM_JSON.lua
Small dependency-free JSON decoder for MCTM.

Only decoding is implemented. MCTM builds VE Pro API payloads from fixed
keys and GUIDs, so an encoder is deliberately not needed here.

API:
  local json = require("jg_MCTM_JSON")
  local value, err = json.decode(text)

Compatible with Lua 5.1+ (no bitwise operators, no goto).
--]]

local M = {}

M.null = setmetatable({}, {
  __tostring = function() return "null" end,
})

local escape_map = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x110000 then
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
  return "?"
end

local function decode_error(pos, msg)
  error({ __json = true, pos = pos, msg = msg }, 0)
end

local function skip_ws(s, pos)
  while true do
    local c = s:sub(pos, pos)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      pos = pos + 1
    else
      return pos
    end
  end
end

local parse_value

local function parse_string(s, pos)
  -- pos points at the opening quote
  local out = {}
  local i = pos + 1
  local start = i

  while true do
    local c = s:sub(i, i)
    if c == "" then
      decode_error(i, "unterminated string")
    elseif c == '"' then
      out[#out + 1] = s:sub(start, i - 1)
      return table.concat(out), i + 1
    elseif c == "\\" then
      out[#out + 1] = s:sub(start, i - 1)
      local e = s:sub(i + 1, i + 1)
      if e == "" then
        decode_error(i, "unterminated escape")
      elseif e == "u" then
        local hex = s:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then
          decode_error(i, "invalid \\u escape")
        end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          -- High surrogate; combine with a following low surrogate if present.
          if s:sub(i, i + 1) == "\\u" then
            local hex2 = s:sub(i + 2, i + 5)
            if hex2:match("^%x%x%x%x$") then
              local cp2 = tonumber(hex2, 16)
              if cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                i = i + 6
              end
            end
          end
        end
        out[#out + 1] = utf8_encode(cp)
      else
        local repl = escape_map[e]
        if not repl then
          decode_error(i, "invalid escape \\" .. e)
        end
        out[#out + 1] = repl
        i = i + 2
      end
      start = i
    else
      i = i + 1
    end
  end
end

local function parse_number(s, pos)
  local start = pos

  if s:sub(pos, pos) == "-" then
    pos = pos + 1
  end

  local int_start = pos
  while s:sub(pos, pos):match("%d") do
    pos = pos + 1
  end
  if pos == int_start then
    decode_error(pos, "invalid number")
  end

  if s:sub(pos, pos) == "." then
    pos = pos + 1
    local frac_start = pos
    while s:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
    if pos == frac_start then
      decode_error(pos, "invalid number")
    end
  end

  local e = s:sub(pos, pos)
  if e == "e" or e == "E" then
    pos = pos + 1
    local sign = s:sub(pos, pos)
    if sign == "+" or sign == "-" then
      pos = pos + 1
    end
    local exp_start = pos
    while s:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
    if pos == exp_start then
      decode_error(pos, "invalid number")
    end
  end

  local num = tonumber(s:sub(start, pos - 1))
  if not num then
    decode_error(start, "invalid number")
  end
  return num, pos
end

local function parse_array(s, pos, depth)
  local arr = {}
  pos = skip_ws(s, pos + 1)

  if s:sub(pos, pos) == "]" then
    return arr, pos + 1
  end

  while true do
    local val, next_pos = parse_value(s, pos, depth + 1)
    arr[#arr + 1] = val
    pos = skip_ws(s, next_pos)

    local c = s:sub(pos, pos)
    if c == "]" then
      return arr, pos + 1
    elseif c ~= "," then
      decode_error(pos, "expected ',' or ']'")
    end
    pos = skip_ws(s, pos + 1)
  end
end

local function parse_object(s, pos, depth)
  local obj = {}
  pos = skip_ws(s, pos + 1)

  if s:sub(pos, pos) == "}" then
    return obj, pos + 1
  end

  while true do
    if s:sub(pos, pos) ~= '"' then
      decode_error(pos, "expected string key")
    end

    local key, next_pos = parse_string(s, pos)
    pos = skip_ws(s, next_pos)

    if s:sub(pos, pos) ~= ":" then
      decode_error(pos, "expected ':'")
    end

    local val, value_pos = parse_value(s, pos + 1, depth + 1)
    obj[key] = val
    pos = skip_ws(s, value_pos)

    local c = s:sub(pos, pos)
    if c == "}" then
      return obj, pos + 1
    elseif c ~= "," then
      decode_error(pos, "expected ',' or '}'")
    end
    pos = skip_ws(s, pos + 1)
  end
end

parse_value = function(s, pos, depth)
  if depth > 200 then
    decode_error(pos, "nesting too deep")
  end

  pos = skip_ws(s, pos)
  local c = s:sub(pos, pos)

  if c == '"' then
    return parse_string(s, pos)
  elseif c == "{" then
    return parse_object(s, pos, depth)
  elseif c == "[" then
    return parse_array(s, pos, depth)
  elseif c == "t" and s:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif c == "f" and s:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif c == "n" and s:sub(pos, pos + 3) == "null" then
    return M.null, pos + 4
  elseif c == "-" or c:match("%d") then
    return parse_number(s, pos)
  elseif c == "" then
    decode_error(pos, "unexpected end of input")
  end

  decode_error(pos, "unexpected character " .. string.format("%q", c))
end

function M.decode(text)
  if type(text) ~= "string" then
    return nil, "JSON input is not a string"
  end

  -- Strip a UTF-8 BOM if the CLI ever emits one.
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end

  local ok, value = pcall(function()
    local val, pos = parse_value(text, 1, 0)
    pos = skip_ws(text, pos)
    if pos <= #text then
      decode_error(pos, "trailing data")
    end
    return val
  end)

  if not ok then
    if type(value) == "table" and value.__json then
      return nil, string.format("JSON error at byte %d: %s", value.pos, value.msg)
    end
    return nil, tostring(value)
  end

  return value, nil
end

return M
