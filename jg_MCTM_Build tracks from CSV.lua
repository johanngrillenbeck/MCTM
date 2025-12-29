--[[
ReaScript Name: jg_MCTM_Build tracks from CSV
Author: JG (assistant)
Description: Create CTRL tracks and A/M track pairs from a CSV template. Sets quad audio receives and MIDI sends according to CSV.
]]

reaper.ClearConsole()
local function dbg(m) reaper.ShowConsoleMsg(tostring(m) .. "\n") end

local function trim(s) if not s then return "" end return (s:gsub('^%s+', ''):gsub('%s+$','')) end

-- Color helpers and presets (self-contained)
local function hex_to_rgb(hex)
    if not hex then return nil end
    local h = tostring(hex):gsub("^#", "")
    if #h == 3 then
        h = h:sub(1,1)..h:sub(1,1)..h:sub(2,2)..h:sub(2,2)..h:sub(3,3)..h:sub(3,3)
    end
    if #h ~= 6 then return nil end
    local r = tonumber(h:sub(1,2), 16)
    local g = tonumber(h:sub(3,4), 16)
    local b = tonumber(h:sub(5,6), 16)
    if not (r and g and b) then return nil end
    return r, g, b
end

local COLOR_PRESETS = {
    ctrl = "#a1a1a1",
    bus  = "#906BFA",
    fx = "#faf06b",
}

-- Master/project channel format: buses inherit this by default.
-- Use 4-channel (quad) layout as default.
local MASTER_NCHANNELS = 4

local function native_from_hex(hex)
    local r,g,b = hex_to_rgb(hex)
    return (r and reaper.ColorToNative(r,g,b)) or nil
end

local COLORS = {
    ctrl = native_from_hex(COLOR_PRESETS.ctrl),
    bus  = native_from_hex(COLOR_PRESETS.bus),
    fx   = native_from_hex(COLOR_PRESETS.fx),
    hex  = COLOR_PRESETS,
}
local function set_track_color(tr, nativeColor)
    if tr and nativeColor then pcall(function() reaper.SetTrackColor(tr, nativeColor) end) end
end

-- use system file picker (preferred) to choose CSV
local function prompt_file(title, ext)
    local ok, path = reaper.GetUserFileNameForRead("", title or "Choose file", ext or "csv")
    if not ok or not path or path == "" then
        dbg("User cancelled CSV file selection.")
        return nil
    end
    return path
end

local csvPath = prompt_file("Choose CSV file", "csv")
if not csvPath then return end
dbg("CSV path: " .. tostring(csvPath))
    
-- normalize path variable for io.open (tooling types may expect string)
local csvPathStr = csvPath
if type(csvPathStr) ~= "string" then csvPathStr = tostring(csvPathStr) end

-- read file
local f, err = io.open(csvPathStr, "r")
if not f then reaper.MB("Could not open CSV: "..tostring(err), "Error", 0) return end
local lines = {}
dbg("Reading lines from CSV...")
for line in f:lines() do table.insert(lines, line) end
f:close()
dbg("Read " .. tostring(#lines) .. " lines from CSV")

-- parse semicolon-separated, simple parser
local function split_semicolon(s)
    local out = {}
    local cur = ""
    local inquote = false
    for i = 1, #s do
        local c = s:sub(i,i)
        if c == '"' then inquote = not inquote
        elseif c == ';' and not inquote then
            table.insert(out, trim(cur))
            cur = ""
        else cur = cur .. c end
    end
    table.insert(out, trim(cur))
    return out
end

-- collect raw CSV rows (including continuation rows where CTRL is empty)
-- and then post-process into actionable entries.
local raw_rows = {}
dbg("Parsing CSV...")
for idx, line in ipairs(lines) do
    if idx == 1 then goto cont2 end -- skip header
    if line:match("^%s*$") then goto cont2 end
    local fields = split_semicolon(line)

    -- New CSV layout (current):
    -- CTRL; Library Prefix; Track Name; Audio Send To; From VE Audiotrack; Midi Bus; Midi Channel; Patch; Player/Instrument; Key Sw ID
    local ctrl = trim(fields[1] or "")
    local lib = trim(fields[2] or "")
    local tname = trim(fields[3] or "")
    local audio_send_to = trim(fields[4] or "")
    local ve = trim(fields[5] or "")
    local midi_bus = trim(fields[6] or "")
    local midi_chan = trim(fields[7] or "")
    local patch = trim(fields[8] or "")

    -- Back-compat for older layouts with fewer columns.
    if #fields < 8 then
        -- fallback: ctrl; lib; name; ve; midi_bus
        audio_send_to = trim(fields[4] or "")
        ve = trim(fields[5] or "")
        midi_bus = trim(fields[6] or "")
        midi_chan = trim(fields[7] or "")
        patch = trim(fields[8] or "")
        if #fields <= 6 then
            -- older: ctrl; lib; name; ve; midi_bus
            audio_send_to = ""
            ve = trim(fields[4] or "")
            midi_bus = trim(fields[5] or "")
            midi_chan = ""
            patch = ""
        end
    end

    table.insert(raw_rows, {
        ctrl = ctrl,
        lib = lib,
        name = tname,
        audio_send_to = audio_send_to,
        ve = ve,
        midi_bus = midi_bus,
        midi_chan = midi_chan,
        patch = patch,
    })

    ::cont2::
end
dbg("Parsed CSV lines (raw rows): " .. tostring(#raw_rows))

-- Post-process into entries.
-- Types:
--  - pair: normal 1:1 (A+M)
--  - fx: FX return (FX only)
--  - multi_audio_parent: creates M only (VE = 0)
--  - multi_audio_child: creates A only (child return)
local rows = {}
local ctrl_set = {}
local bus_set = {}

-- For ordering: keep instrument items in CSV order.
local instrument_items = {}

local function is_zero_ve(ve)
    ve = trim(ve or "")
    if ve == "" then return false end
    return ve == "0" or ve == "0-0"
end

-- Parse VE string range "a-b" or single "n".
local function parse_ve_range(ve)
    ve = trim(ve or "")
    local a,b = ve:match("(%d+)%s*-%s*(%d+)")
    if a and b then
        return tonumber(a), tonumber(b)
    end
    local single = ve:match("^%s*(%d+)%s*$")
    if single then
        local n = tonumber(single)
        return n, n
    end
    return nil, nil
end

-- Like parse_ve_range(), but uses a default channel span when VE is missing/invalid.
-- default_span is channel count (e.g. 4 for quad, 2 for stereo). Starts at channel 1.
local function parse_ve_range_with_default(ve, default_span)
    local a, b = parse_ve_range(ve)
    if a and b then return a, b end
    local span = tonumber(default_span) or 4
    if span < 1 then span = 1 end
    return 1, span
end

local function ve_channel_count(start_ch, end_ch)
    start_ch = tonumber(start_ch) or 1
    end_ch = tonumber(end_ch) or start_ch
    if end_ch < start_ch then start_ch, end_ch = end_ch, start_ch end
    return math.max(1, (end_ch - start_ch + 1))
end

local function ctrl_srcchan_value(src_start_zero_based, is_mono)
    local base = tonumber(src_start_zero_based) or 0
    if is_mono then
        -- I_SRCCHAN mono encoding: (srcchan>>10)==1
        return base + 1024
    end
    return base
end

-- Returns list of segments that cover a VE range.
-- Each segment maps either a stereo pair (2ch) or a mono channel (1ch, for odd/mono ranges).
-- Segment fields:
--   src_start0 : source channel offset (0-based)
--   dst_start0 : destination channel offset (0-based, in stereo-pair steps)
--   is_mono    : true if this segment is mono
local function ve_segments(start_ch, end_ch)
    local count = ve_channel_count(start_ch, end_ch)
    local src_start0 = (tonumber(start_ch) or 1) - 1

    local segments = {}
    local pairs = math.floor(count / 2)
    local has_odd = (count % 2) == 1

    for pair = 0, pairs - 1 do
        table.insert(segments, {
            src_start0 = src_start0 + pair * 2,
            dst_start0 = pair * 2,
            is_mono = false,
        })
    end
    if has_odd then
        table.insert(segments, {
            src_start0 = src_start0 + pairs * 2,
            dst_start0 = pairs * 2,
            is_mono = true,
        })
    end
    return segments, count, pairs, has_odd
end

local function required_dst_nchan_for_segments(pairs, has_odd)
    local n = (tonumber(pairs) or 0) * 2
    if has_odd then n = n + 2 end
    if n < 2 then n = 2 end
    return n
end

-- How many audio channels does this instrument return, based on VE range length.
-- Example: "19-20" -> 2, "101-104" -> 4.
-- For bus sends, we cap to MASTER_NCHANNELS (busses are typically 4ch).
local function channel_count_from_ve_for_bus(ve)
    local a, b = parse_ve_range(ve)
    if a and b then
        local n = math.max(1, (b - a + 1))
        if n > MASTER_NCHANNELS then n = MASTER_NCHANNELS end
        return n
    end
    return MASTER_NCHANNELS
end

local current_parent = nil
for _, rr in ipairs(raw_rows) do
    local ctrl = trim(rr.ctrl or "")
    local lib = trim(rr.lib or "")
    local tname = trim(rr.name or "")
    local audio_send_to = trim(rr.audio_send_to or "")
    local ve = trim(rr.ve or "")
    local midi_bus = trim(rr.midi_bus or "")
    local midi_chan = trim(rr.midi_chan or "")
    local patch = trim(rr.patch or "")

    local is_fx = (tostring(lib or ""):upper() == "FX")

    -- Start row: CTRL present
    if ctrl ~= "" then
        if not ctrl_set[ctrl] then ctrl_set[ctrl] = true end

        if is_fx then
            table.insert(rows, {type="fx", ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus, midi_chan=midi_chan, audio_send_to=audio_send_to})
            if audio_send_to ~= "" then bus_set[audio_send_to] = true end
            current_parent = nil
        else
            -- multi-audio parent row: VE=0 => M-only instrument, children define audio returns
            if tname ~= "" and is_zero_ve(ve) then
                current_parent = {
                    ctrl = ctrl,
                    lib = lib,
                    name = tname,
                    midi_bus = midi_bus,
                    midi_chan = midi_chan,
                    -- For multi-audio instruments, parent Audio Send To is authoritative.
                    bus = audio_send_to,
                }
                table.insert(rows, {type="multi_audio_parent", ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus, midi_chan=midi_chan, audio_send_to=audio_send_to, parent=current_parent})
                table.insert(instrument_items, {kind="multi_audio", parent=current_parent, children={}})
                if audio_send_to ~= "" then bus_set[audio_send_to] = true end
            else
                current_parent = nil
                -- normal instrument pair row
                if tname ~= "" then
                    table.insert(rows, {type="pair", ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus, midi_chan=midi_chan, audio_send_to=audio_send_to})
                    if audio_send_to ~= "" then bus_set[audio_send_to] = true end
                    table.insert(instrument_items, {kind="pair", ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus, audio_send_to=audio_send_to})
                end
            end
        end
    else
        -- Continuation row: CTRL empty
        if current_parent and tname ~= "" then
            -- Multi-audio child return row
            table.insert(rows, {
                type = "multi_audio_child",
                ctrl = current_parent.ctrl,
                lib = current_parent.lib,
                name = tname,
                ve = ve,
                midi_bus = midi_bus,
                midi_chan = midi_chan,
                -- Child audio returns inherit bus from parent instrument row.
                audio_send_to = current_parent.bus or "",
                parent_name = current_parent.name,
                parent_lib = current_parent.lib,
            })

            -- Update ordering child list
            local last_item = instrument_items[#instrument_items]
            if last_item and last_item.kind == "multi_audio" and last_item.parent == current_parent then
                table.insert(last_item.children, {name=tname, ve=ve})
            end

            if (current_parent.bus or "") ~= "" then bus_set[current_parent.bus] = true end
        else
            -- Likely a multi-MIDI articulation row (Track Name empty) or noise; ignore for track building.
        end
    end
end
dbg("Built actionable entries: " .. tostring(#rows))

-- Prompt for Colors & Order CSV before creating any tracks (optional)
local color_map = {}
local default_color_hex = nil
local positions_entries = {}
do
    local colorsPath = prompt_file("Choose Colors and Order CSV (optional)", "csv")
    if colorsPath and colorsPath ~= "" then
        local cf, cerr = io.open(colorsPath, "r")
        if cf then
            local clines = {}
            for line in cf:lines() do table.insert(clines, line) end
            cf:close()
            for idx, line in ipairs(clines) do
                if idx == 1 then goto contcol end -- skip header
                if line:match("^%s*$") then goto contcol end
                local fields = split_semicolon(line)
                local bus = trim(fields[1] or "")
                local pos = trim(fields[2] or "")
                local hex = trim(fields[3] or "")
                if bus ~= "" then
                    local key = bus:lower():gsub("^%s+", ""):gsub("%s+$", "")
                    if hex ~= "" then color_map[key] = hex end
                    if key == "default" and hex ~= "" then default_color_hex = hex end
                    local pnum = tonumber(pos)
                    if pnum then
                        table.insert(positions_entries, {bus = bus, pos = pnum})
                    end
                end
                ::contcol::
            end
            local _count = 0
            for _k,_v in pairs(color_map) do _count = _count + 1 end
            dbg("Parsed Colors CSV entries: " .. tostring(_count))
        else
            dbg("Could not open Colors CSV: " .. tostring(cerr))
        end
    else
        dbg("No Colors CSV selected; instrument coloring will be skipped or use defaults.")
    end
end

-- compute per-CTRL required source channels (max channel index needed)
-- based on all entries that actually reference VE audio channels.
local ctrl_needs = {}
for _, r in ipairs(rows) do
    local ctrl = r.ctrl
    local ve = r.ve or ""
    if ctrl and ctrl ~= "" and not is_zero_ve(ve) then
        local _a, endch = parse_ve_range(ve)
        if endch then
            ctrl_needs[ctrl] = math.max(ctrl_needs[ctrl] or 0, endch)
        else
            -- default to at least 4 channels
            ctrl_needs[ctrl] = math.max(ctrl_needs[ctrl] or 0, 4)
        end
    end
end
do
    local tmp = {}
    for k,v in pairs(ctrl_needs) do table.insert(tmp, k .. ":" .. tostring(v)) end
    table.sort(tmp)
    dbg("CTRL channel needs: " .. (#tmp>0 and table.concat(tmp, ", ") or "(none)"))
end

-- find or create CTRL tracks
local ctrl_tracks = {}
dbg("Preparing to find/create CTRL tracks...")
do
    local tmp = {}
    for k,_ in pairs(ctrl_set) do table.insert(tmp, k) end
    table.sort(tmp)
    dbg("CTRL candidates: " .. (#tmp>0 and table.concat(tmp, ", ") or "(none)"))
end
-- Preserve CTRL order as encountered in CSV (raw rows)
local ctrl_order = {}
local seen = {}
for _, r in ipairs(raw_rows) do
    local c = trim(r.ctrl or "")
    if c ~= "" and not seen[c] then
        seen[c]=true
        table.insert(ctrl_order, c)
    end
end

for _, ctrlname in ipairs(ctrl_order) do
    dbg("Looking for CTRL: " .. tostring(ctrlname))
    local before_count = reaper.CountTracks(0)
    dbg("  Track count before search: " .. tostring(before_count))
    -- search existing (exact name or prefix)
    local found = nil
    for i = 0, reaper.CountTracks(0)-1 do
        local tr = reaper.GetTrack(0,i)
        local ok, tname = reaper.GetTrackName(tr)
        if type(tname) ~= "string" then tname = "" end
        if tname and (tname == ctrlname or tname:match("^"..ctrlname)) then found = tr break end
    end
    if not found then
        dbg("CTRL not found, creating: " .. tostring(ctrlname))
        local idx = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idx, true)
        found = reaper.GetTrack(0, idx)
        reaper.GetSetMediaTrackInfo_String(found, "P_NAME", ctrlname, true)
        dbg("Created CTRL track: "..ctrlname)
        -- set required source channels if known
        local need = ctrl_needs[ctrlname]
        if need and tonumber(need) then
            reaper.SetMediaTrackInfo_Value(found, "I_NCHAN", need)
            dbg("  Set CTRL I_NCHAN = " .. tostring(need))
            reaper.TrackList_AdjustWindows(false)
        end
        -- disable master/parent send for CTRL tracks (we route only to A tracks)
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_MAINSEND", 0) end)
        -- show only in TCP, hide in MCP (Mixer)
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINTCP", 1) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINMIXER", 0) end)
        -- apply CTRL color
        set_track_color(found, COLORS.ctrl)
        dbg("  Track count after creation: " .. tostring(reaper.CountTracks(0)))
    else
        dbg("Found existing CTRL track: "..ctrlname)
        -- ensure CTRL color and disable master send; ensure visibility: TCP visible, MCP hidden
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_MAINSEND", 0) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINTCP", 1) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINMIXER", 0) end)
        set_track_color(found, COLORS.ctrl)
    end
    ctrl_tracks[ctrlname] = found
end

-- Do not reorder CTRL tracks here.
-- A final ordering pass at the end will place CTRL tracks last.

    -- Create / find all Audio Bus tracks (batch) so we don't check per-row repeatedly
    local bus_tracks = {}
    do
        local bus_order = {}
        for k,_ in pairs(bus_set) do table.insert(bus_order, k) end
        table.sort(bus_order)
        if #bus_order > 0 then dbg("Preparing to find/create Audio Bus tracks: " .. table.concat(bus_order, ", ")) end
        for _, bname in ipairs(bus_order) do
            dbg("Looking for Bus: " .. tostring(bname))
            local found = nil
            for i = 0, reaper.CountTracks(0)-1 do
                local tr = reaper.GetTrack(0,i)
                local ok, tname = reaper.GetTrackName(tr)
                if type(tname) ~= "string" then tname = "" end
                if tname == bname then found = tr break end
            end
            if not found then
                dbg("Bus not found, creating: " .. tostring(bname))
                local idx = reaper.CountTracks(0)
                reaper.InsertTrackAtIndex(idx, true)
                found = reaper.GetTrack(0, idx)
                reaper.GetSetMediaTrackInfo_String(found, "P_NAME", bname, true)
                dbg(" Created Bus track: " .. tostring(bname))
                -- show only in MCP (mixer), hide in TCP
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINTCP", 0) end)
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINMIXER", 1) end)
                -- ensure bus channel count inherits MASTER setting
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "I_NCHAN", MASTER_NCHANNELS) end)
                set_track_color(found, COLORS.bus)
            else
                dbg("Found existing Bus track: " .. tostring(bname))
                -- ensure bus visibility: MCP visible, TCP hidden
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINTCP", 0) end)
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "B_SHOWINMIXER", 1) end)
                -- ensure bus channel count inherits MASTER setting (idempotent)
                pcall(function() reaper.SetMediaTrackInfo_Value(found, "I_NCHAN", MASTER_NCHANNELS) end)
                set_track_color(found, COLORS.bus)
            end
            bus_tracks[bname] = found
        end
    end

-- create A and M track pairs (append at end) and set routing
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local created = {}
-- helpers
local function find_track_by_name(name)
    for i = 0, reaper.CountTracks(0)-1 do
        local tr = reaper.GetTrack(0,i)
        local ok, tname = reaper.GetTrackName(tr)
        if type(tname) ~= "string" then tname = "" end
        if tname == name then return tr end
    end
    return nil
end

local function send_has_dest_and_chans(src, dest, src_chan, dst_chan)
    local ns = reaper.GetTrackNumSends(src, 0)
    -- precompute dest name for comparison
    local dest_name = nil
    pcall(function() local ok, n = reaper.GetTrackName(dest) if ok then dest_name = n end end)

    for s = 0, ns-1 do
        -- get the destination reported by BR
        local ok, dst = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "P_DESTTRACK", false, 0)
        if not ok or not dst then goto continue_send end

        -- determine if this send points to our dest (compare name)
        local same = false
        local okn, n = pcall(reaper.GetTrackName, dst)
        if okn and n and dest_name and n == dest_name then same = true end

        if same then
            -- try to read channel mapping via BR
            local ok1, vsrc = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "I_SRCCHAN", false, 0)
            local ok2, vdst = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "I_DSTCHAN", false, 0)
            local vsrcn = (ok1 and tonumber(vsrc)) or nil
            local vdstn = (ok2 and tonumber(vdst)) or nil

            -- exact match
            if vsrcn and vdstn and vsrcn == tonumber(src_chan) and vdstn == tonumber(dst_chan) then return true end

            -- lenient pair-match: if existing send covers either channel of the stereo pair, treat as present
            if vsrcn and vdstn then
                if (vsrcn == tonumber(src_chan) or vsrcn == tonumber(src_chan)+1) and (vdstn == tonumber(dst_chan) or vdstn == tonumber(dst_chan)+1) then
                    return true
                end
            end

            -- fallback: try core API to get numeric channel values
            local okf, fsrc = pcall(reaper.GetTrackSendInfo_Value, src, 0, s, "I_SRCCHAN")
            local okg2, fdst = pcall(reaper.GetTrackSendInfo_Value, src, 0, s, "I_DSTCHAN")
            local fsrcn = (okf and tonumber(fsrc)) or nil
            local fdstn = (okg2 and tonumber(fdst)) or nil
            if fsrcn and fdstn then
                if fsrcn == tonumber(src_chan) and fdstn == tonumber(dst_chan) then return true end
                if (fsrcn == tonumber(src_chan) or fsrcn == tonumber(src_chan)+1) and (fdstn == tonumber(dst_chan) or fdstn == tonumber(dst_chan)+1) then return true end
            end
        end
        ::continue_send::
    end

    return false
end

local function send_has_midi(src, dest, midi_dstbus)
    local ns = reaper.GetTrackNumSends(src, 0)
    -- precompute dest name
    local dest_name = nil
    pcall(function() local ok, n = reaper.GetTrackName(dest) if ok then dest_name = n end end)
    for s = 0, ns-1 do
        local ok, dst = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "P_DESTTRACK", false, 0)
        if ok then
            local okn, n = pcall(reaper.GetTrackName, dst)
            if okn and n and dest_name and n == dest_name then
                local okm, mb = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "I_MIDI_DSTBUS", false, 0)
                if okm and tonumber(mb) == tonumber(midi_dstbus) then return true end
                -- fallback to core API
                local okf, fmb = pcall(reaper.GetTrackSendInfo_Value, src, 0, s, "I_MIDI_DSTBUS")
                if okf and tonumber(fmb) == tonumber(midi_dstbus) then return true end
            end
        end
    end
    return false
end

-- check if a send exists from src track to dest track (any audio send)
local function send_exists_to_dest(src, dest)
    local ns = reaper.GetTrackNumSends(src, 0)
    -- compare by name for robustness
    local dest_name = nil
    pcall(function() local ok, n = reaper.GetTrackName(dest) if ok then dest_name = n end end)
    for s = 0, ns-1 do
        local ok, dst = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "P_DESTTRACK", false, 0)
        if ok and dst then
            local okn, n = pcall(reaper.GetTrackName, dst)
            if okn and n and dest_name and n == dest_name then return true end
        end
    end
    return false
end

-- check if dest track has any receives from src track (more robust in some hosts)
local function receive_from_src_exists(src, dest)
    local rcount = reaper.GetTrackNumSends(dest, -1)
    if rcount == 0 then return false end
    local ok_srcname, src_name = pcall(function() local ok2, tn = reaper.GetTrackName(src) if ok2 then return tn end end)
    if not ok_srcname or not src_name then src_name = "" end
    for i = 0, rcount-1 do
        local ok, sptr = pcall(reaper.BR_GetSetTrackSendInfo, dest, -1, i, "P_SRCTRACK", false, 0)
        if ok and sptr then
            local okn, n = pcall(function() local ok2, tn = reaper.GetTrackName(sptr) if ok2 then return tn end end)
            if okn and n and src_name ~= "" and n == src_name then return true end
        end
    end
    return false
end

local function get_send_mapping(src, sendidx)
    local vsrc = nil
    local vdst = nil
    do
        local ok1, a = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, sendidx, "I_SRCCHAN", false, 0)
        local ok2, b = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, sendidx, "I_DSTCHAN", false, 0)
        if ok1 then vsrc = tonumber(a) end
        if ok2 then vdst = tonumber(b) end
    end
    if vsrc == nil or vdst == nil then
        local ok1, a = pcall(reaper.GetTrackSendInfo_Value, src, 0, sendidx, "I_SRCCHAN")
        local ok2, b = pcall(reaper.GetTrackSendInfo_Value, src, 0, sendidx, "I_DSTCHAN")
        if ok1 then vsrc = tonumber(a) end
        if ok2 then vdst = tonumber(b) end
    end
    return vsrc, vdst
end

-- Ensure a send exists from src->dest with the desired mapping.
-- If desired is mono and an existing send matches but is stereo, upgrade it to mono.
local function ensure_audio_send(src, dest, desired_srcchan, desired_dstchan)
    local desired_src_val = tonumber(desired_srcchan) or 0
    local desired_dst_val = tonumber(desired_dstchan) or 0
    local ns = reaper.GetTrackNumSends(src, 0)
    local dest_name = nil
    pcall(function() local ok, n = reaper.GetTrackName(dest) if ok then dest_name = n end end)
    if not dest_name then dest_name = "" end

    for s = 0, (ns or 0) - 1 do
        local ok, dst = pcall(reaper.BR_GetSetTrackSendInfo, src, 0, s, "P_DESTTRACK", false, 0)
        if ok and dst then
            local okn, n = pcall(reaper.GetTrackName, dst)
            if okn and n and n == dest_name then
                local vsrc, vdst = get_send_mapping(src, s)
                if vsrc ~= nil and vdst ~= nil then
                    if vsrc == desired_src_val and vdst == desired_dst_val then
                        return true, false
                    end

                    -- If mono is desired, and existing mapping is stereo at same start/dst, upgrade to mono.
                    local desired_mono = desired_src_val >= 1024
                    if desired_mono then
                        local desired_start0 = desired_src_val - 1024
                        local existing_is_stereo = ((math.floor((tonumber(vsrc) or 0) / 1024)) == 0)
                        if existing_is_stereo and tonumber(vsrc) == desired_start0 and tonumber(vdst) == desired_dst_val then
                            pcall(function()
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_SRCCHAN", true, desired_src_val)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_DSTCHAN", true, desired_dst_val)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_SRCBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_DSTBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_SRCCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_DSTCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "D_VOL", true, 1.0)
                                reaper.BR_GetSetTrackSendInfo(src, 0, s, "B_MUTE", true, 0.0)
                            end)
                            return true, true
                        end
                    end
                end
            end
        end
    end

    local sendidx = reaper.CreateTrackSend(src, dest)
    if sendidx and sendidx >= 0 then
        pcall(function()
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_SRCCHAN", true, desired_src_val)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_DSTCHAN", true, desired_dst_val)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_SRCBUS", true, -1)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_DSTBUS", true, -1)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_SRCCHAN", true, -1)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_DSTCHAN", true, -1)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "D_VOL", true, 1.0)
            reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "B_MUTE", true, 0.0)
        end)
        return true, true
    end

    return false, false
end
for i, r in ipairs(rows) do
    dbg(string.format("Processing entry %d: Type=%s | CTRL=%s | Lib=%s | Name=%s | VE=%s | MidiBus=%s | Bus=%s", i, tostring(r.type), tostring(r.ctrl), tostring(r.lib), tostring(r.name), tostring(r.ve), tostring(r.midi_bus), tostring(r.audio_send_to)))
    local ctrl = tostring(r.ctrl or "")
    local lib = tostring(r.lib or "")
    local tname = tostring(r.name or "")
    local ve = tostring(r.ve or "")
    local midi_bus = tonumber(r.midi_bus) or nil

    if tname == "" then goto skip end

    local is_fx = (tostring(lib or ""):upper() == "FX")

    -- FX return tracks: create only an FX track (no MIDI track), and route like an A track.
    -- CSV uses Library Prefix = "FX" only as a marker; the created track prefix is always "FX".
    if is_fx then
        local FX_name = "FX " .. tname
        local FX = find_track_by_name(FX_name)
        local createdFX = false
        if FX then
            dbg("  Found existing FX track: " .. FX_name)
        else
            local idxFX = reaper.CountTracks(0)
            reaper.InsertTrackAtIndex(idxFX, true)
            FX = reaper.GetTrack(0, idxFX)
            reaper.GetSetMediaTrackInfo_String(FX, "P_NAME", FX_name, true)
            createdFX = true
            dbg("  Created FX track: " .. FX_name)
            -- FX returns are mix tracks: show in MCP, hide in TCP
            pcall(function() reaper.SetMediaTrackInfo_Value(FX, "B_SHOWINTCP", 0) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(FX, "B_SHOWINMIXER", 1) end)
        end

        -- apply FX color preset (idempotent)
        set_track_color(FX, COLORS.fx)

        -- routing: FX -> its Audio Bus (if specified). If bus missing/unspecified, allow master send.
        local bus_name = r.audio_send_to or ""
        local bus_tr = (bus_name ~= "" and bus_tracks[bus_name]) or nil
        if bus_tr and bus_name ~= "" then
            pcall(function() reaper.SetMediaTrackInfo_Value(FX, "B_MAINSEND", 0) end)
            -- create stereo send pairs from FX -> Bus mapping 1/2->1/2, 3/4->3/4, etc.
            -- IMPORTANT: VE strings like "19-20" are absolute channel numbers; we need the range length.
            local channel_count = channel_count_from_ve_for_bus(ve)

            local pairs = math.floor(channel_count / 2)
            local has_odd = (channel_count % 2) == 1
            for pair = 0, pairs-1 do
                local pair_src = pair * 2
                local pair_dst = pair * 2
                if send_has_dest_and_chans(FX, bus_tr, pair_src, pair_dst) then
                    dbg(string.format("  Audio send pair already exists from %s to bus %s (pair src=%d)", FX_name, bus_name, pair_src))
                else
                    local sidx = reaper.CreateTrackSend(FX, bus_tr)
                    if sidx and sidx >= 0 then
                        dbg(string.format("  Created audio send from %s to bus %s (sendidx=%d pair_src=%d)", FX_name, bus_name, sidx, pair_src))
                        pcall(function()
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_SRCCHAN", true, pair_src)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_DSTCHAN", true, pair_dst)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "D_VOL", true, 1.0)
                            reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "B_MUTE", true, 0.0)
                        end)
                    end
                end
            end
            if has_odd then
                local last_src = pairs * 2
                local last_dst = pairs * 2
                if last_src < MASTER_NCHANNELS then
                    if not send_has_dest_and_chans(FX, bus_tr, last_src, last_dst) then
                        local sidx = reaper.CreateTrackSend(FX, bus_tr)
                        if sidx and sidx >= 0 then
                            dbg(string.format("  Created single-channel audio send from %s to bus %s (sendidx=%d src=%d)", FX_name, bus_name, sidx, last_src))
                            pcall(function()
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_SRCCHAN", true, last_src)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_DSTCHAN", true, last_dst)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "D_VOL", true, 1.0)
                                reaper.BR_GetSetTrackSendInfo(FX, 0, sidx, "B_MUTE", true, 0.0)
                            end)
                        end
                    else
                        dbg(string.format("  Single-channel audio send already exists from %s to bus %s (src=%d)", FX_name, bus_name, last_src))
                    end
                else
                    dbg(string.format("  Skipping leftover single channel %d — exceeds MASTER_NCHANNELS (%d)", last_src, MASTER_NCHANNELS))
                end
            end
        else
            -- If no bus exists (or none specified), let FX flow to master.
            pcall(function() reaper.SetMediaTrackInfo_Value(FX, "B_MAINSEND", 1) end)
        end

        if createdFX then dbg(string.format("Applied FX preset color %s to %s", tostring(COLOR_PRESETS.fx), FX_name)) end

        -- routing: FX receives audio from CTRL (stereo/quad/etc depending on VE range)
        local src_track = ctrl_tracks[ctrl]
        if src_track then
            local start_ch, end_ch = parse_ve_range_with_default(ve, 4)
            local segments, _count, pairs, has_odd = ve_segments(start_ch, end_ch)
            local dest_nchan = required_dst_nchan_for_segments(pairs, has_odd)
            reaper.SetMediaTrackInfo_Value(FX, "I_NCHAN", dest_nchan)
            dbg(string.format("  FX track %s I_NCHAN set to %d (VE %s)", FX_name, dest_nchan, tostring(ve)))

            for idx, seg in ipairs(segments) do
                local desired_src = ctrl_srcchan_value(seg.src_start0, seg.is_mono)
                local desired_dst = seg.dst_start0
                local ok_send, changed = ensure_audio_send(src_track, FX, desired_src, desired_dst)
                if ok_send then
                    dbg(string.format("    Ensured %s send to FX: seg=%d src=%d%s dst=%d%s", seg.is_mono and "mono" or "stereo", idx, seg.src_start0, seg.is_mono and "(mono)" or "", seg.dst_start0, changed and " (created/updated)" or ""))
                else
                    dbg(string.format("    Warning: failed ensuring send to FX for seg=%d", idx))
                end
            end
        else
            dbg("Warning: CTRL track not found for " .. tostring(ctrl))
        end

        created[#created+1] = {A=FX, M=nil, kind="fx"}
        goto skip
    end

    -- Multi-audio parent: create M only, no A receives.
    if r.type == "multi_audio_parent" then
        local base = (lib ~= "" and (lib .. " " .. tname) or tname)
        local M_name = "M " .. base
        local M = find_track_by_name(M_name) or find_track_by_name("D " .. M_name)
        local createdM = false
        if M then
            dbg("  Found existing M track (multi-audio parent): " .. M_name)
        else
            local idxM = reaper.CountTracks(0)
            reaper.InsertTrackAtIndex(idxM, true)
            M = reaper.GetTrack(0, idxM)
            reaper.GetSetMediaTrackInfo_String(M, "P_NAME", M_name, true)
            createdM = true
            dbg("  Created M track (multi-audio parent): " .. M_name)
        end

        -- disable parent/master send for MIDI track
        pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_MAINSEND", 0) end)

        if createdM then
            local newMname = "D " .. M_name
            pcall(function() reaper.GetSetMediaTrackInfo_String(M, "P_NAME", newMname, true) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_SHOWINTCP", 0) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_SHOWINMIXER", 0) end)
            dbg("  Set newly created M parent track to deactivated and hidden: " .. newMname)
        end

        -- Optional: apply color based on parent bus
        do
            local bus_name = (r.parent and r.parent.bus) or (r.audio_send_to or "")
            local bus_key = (bus_name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            local assigned_hex = nil
            if bus_key ~= "" then assigned_hex = color_map[bus_key] end
            if not assigned_hex then assigned_hex = default_color_hex end
            local native_color = (assigned_hex and native_from_hex(assigned_hex)) or nil
            if native_color and createdM then
                set_track_color(M, native_color)
                dbg(string.format("Applied color %s to %s (multi-audio parent bus hint=%s)", tostring(assigned_hex), M_name, tostring(bus_name)))
            end
        end

        -- routing: M sends MIDI to CTRL (bus only; channel remains 0 as per existing behavior)
        local src_track = ctrl_tracks[ctrl]
        if src_track then
            if receive_from_src_exists(M, src_track) or (midi_bus and send_has_midi(M, src_track, midi_bus)) then
                dbg(string.format("    MIDI send already exists from M parent to CTRL bus=%s (skipping)", tostring(midi_bus)))
            else
                local sendidx = reaper.CreateTrackSend(M, src_track)
                if sendidx and sendidx >= 0 then
                    dbg(string.format("    Created MIDI send from M parent to CTRL: sendidx=%d", sendidx))
                    -- disable audio
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_SRCCHAN", true, -1)
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_DSTCHAN", true, -1)
                    -- midi mapping: source bus fixed to 1, destination from csv if present
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_SRCBUS", true, 1)
                    if midi_bus then reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_DSTBUS", true, midi_bus) end
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_SRCCHAN", true, 0)
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_DSTCHAN", true, 0)
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "D_VOL", true, 1.0)
                    reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "B_MUTE", true, 0.0)
                end
            end
        else
            dbg("Warning: CTRL track not found for " .. tostring(ctrl))
        end

        created[#created+1] = {A=nil, M=M, kind="multi_audio_parent"}
        goto skip
    end

    -- Multi-audio child: create A only, receives audio from CTRL, optionally sends to bus.
    if r.type == "multi_audio_child" then
        local parent_label = tostring(r.parent_lib or "") .. " " .. tostring(r.parent_name or "")
        parent_label = trim(parent_label)
        local A_display = string.format("%s (%s)", tname, parent_label)
        local A_name = "A " .. A_display

        local A = find_track_by_name(A_name) or find_track_by_name("D " .. A_name)
        local createdA = false
        if A then
            dbg("  Found existing multi-audio A track: " .. A_name)
        else
            local idxA = reaper.CountTracks(0)
            reaper.InsertTrackAtIndex(idxA, true)
            A = reaper.GetTrack(0, idxA)
            reaper.GetSetMediaTrackInfo_String(A, "P_NAME", A_name, true)
            createdA = true
            dbg("  Created multi-audio A track: " .. A_name)
        end

        -- disable parent/master send for A track
        pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_MAINSEND", 0) end)

        if createdA then
            local newAname = "D " .. A_name
            pcall(function() reaper.GetSetMediaTrackInfo_String(A, "P_NAME", newAname, true) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_SHOWINTCP", 0) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_SHOWINMIXER", 0) end)
            dbg("  Set newly created multi-audio A track to deactivated and hidden: " .. newAname)
        end

        -- routing: A -> its Audio Bus (multi-audio instruments always use parent bus; blank means: do not create any sends)
        local bus_name = r.audio_send_to or ""
        if bus_name ~= "" then
            local bus_tr = bus_tracks[bus_name]
            if not bus_tr then
                dbg("Warning: Audio Bus track not found for name: " .. tostring(bus_name))
            else
                -- IMPORTANT: VE strings like "19-20" are absolute channel numbers; we need the range length.
                local channel_count = channel_count_from_ve_for_bus(ve)

                local pairs = math.floor(channel_count / 2)
                local has_odd = (channel_count % 2) == 1
                for pair = 0, pairs-1 do
                    local pair_src = pair * 2
                    local pair_dst = pair * 2
                    if send_has_dest_and_chans(A, bus_tr, pair_src, pair_dst) then
                        dbg(string.format("  Audio send pair already exists from %s to bus %s (pair src=%d)", A_name, bus_name, pair_src))
                    else
                        local sidx = reaper.CreateTrackSend(A, bus_tr)
                        if sidx and sidx >= 0 then
                            dbg(string.format("  Created audio send from %s to bus %s (sendidx=%d pair_src=%d)", A_name, bus_name, sidx, pair_src))
                            pcall(function()
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_SRCCHAN", true, pair_src)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_DSTCHAN", true, pair_dst)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "D_VOL", true, 1.0)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "B_MUTE", true, 0.0)
                            end)
                        end
                    end
                end
                if has_odd then
                    local last_src = pairs * 2
                    local last_dst = pairs * 2
                    if last_src < MASTER_NCHANNELS then
                        if not send_has_dest_and_chans(A, bus_tr, last_src, last_dst) then
                            local sidx = reaper.CreateTrackSend(A, bus_tr)
                            if sidx and sidx >= 0 then
                                dbg(string.format("  Created single-channel audio send from %s to bus %s (sendidx=%d src=%d)", A_name, bus_name, sidx, last_src))
                                pcall(function()
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_SRCCHAN", true, last_src)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_DSTCHAN", true, last_dst)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "D_VOL", true, 1.0)
                                    reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "B_MUTE", true, 0.0)
                                end)
                            end
                        end
                    end
                end
            end
        end

        -- Apply coloring for this A track based on its bus (only if newly created)
        do
            local bus_key = (bus_name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            local assigned_hex = nil
            if bus_key ~= "" then assigned_hex = color_map[bus_key] end
            if not assigned_hex then assigned_hex = default_color_hex end
            local native_color = (assigned_hex and native_from_hex(assigned_hex)) or nil
            if native_color and createdA then
                set_track_color(A, native_color)
                dbg(string.format("Applied color %s to %s (bus=%s)", tostring(assigned_hex), A_name, tostring(bus_name)))
            end
        end

        -- routing: A receives audio from CTRL based on VE range
        local src_track = ctrl_tracks[ctrl]
        if src_track then
            local start_ch, end_ch = parse_ve_range_with_default(ve, 2)
            local segments, _count, pairs, has_odd = ve_segments(start_ch, end_ch)
            local dest_nchan = required_dst_nchan_for_segments(pairs, has_odd)
            reaper.SetMediaTrackInfo_Value(A, "I_NCHAN", dest_nchan)
            dbg(string.format("  Multi-audio A track %s I_NCHAN set to %d (VE %s)", A_name, dest_nchan, tostring(ve)))

            for idx, seg in ipairs(segments) do
                local desired_src = ctrl_srcchan_value(seg.src_start0, seg.is_mono)
                local desired_dst = seg.dst_start0
                local ok_send, changed = ensure_audio_send(src_track, A, desired_src, desired_dst)
                if ok_send then
                    dbg(string.format("    Ensured %s send to multi-audio A: seg=%d src=%d%s dst=%d%s", seg.is_mono and "mono" or "stereo", idx, seg.src_start0, seg.is_mono and "(mono)" or "", seg.dst_start0, changed and " (created/updated)" or ""))
                else
                    dbg(string.format("    Warning: failed ensuring send to multi-audio A for seg=%d", idx))
                end
            end
        else
            dbg("Warning: CTRL track not found for " .. tostring(ctrl))
        end

        created[#created+1] = {A=A, M=nil, kind="multi_audio_child"}
        goto skip
    end

    local base = (lib ~= "" and (lib .. " " .. tname) or tname)

    -- find or create A track (idempotent)
    local A_name = "A " .. base
    local M_name = "M " .. base
    local A = find_track_by_name(A_name) or find_track_by_name("D " .. A_name)
    local createdA = false
    if A then
        dbg("  Found existing A track: " .. A_name)
    else
        local idxA = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idxA, true)
        A = reaper.GetTrack(0, idxA)
        reaper.GetSetMediaTrackInfo_String(A, "P_NAME", A_name, true)
        createdA = true
        dbg("  Created A track: " .. base .. " A")
    end

    -- find or create M track (idempotent)
    local M = find_track_by_name(M_name) or find_track_by_name("D " .. M_name)
    local createdM = false
    if M then
        dbg("  Found existing M track: " .. M_name)
    else
        local idxM = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idxM, true)
        M = reaper.GetTrack(0, idxM)
        reaper.GetSetMediaTrackInfo_String(M, "P_NAME", M_name, true)
        createdM = true
        dbg("  Created M track: " .. base .. " M")
    end
    -- disable parent/master send for both tracks (user requested)
    pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_MAINSEND", 0) end)
    pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_MAINSEND", 0) end)

    -- If tracks were just created, mark them deactivated (add 'D' prefix)
    -- and hide them in TCP and MCP per template convention.
    if createdA then
        local newAname = "D " .. A_name
        pcall(function() reaper.GetSetMediaTrackInfo_String(A, "P_NAME", newAname, true) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_SHOWINTCP", 0) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_SHOWINMIXER", 0) end)
        dbg("  Set newly created A track to deactivated and hidden: " .. newAname)
        -- color will be applied after routing is processed (see below)
    end
    if createdM then
        local newMname = "D " .. M_name
        pcall(function() reaper.GetSetMediaTrackInfo_String(M, "P_NAME", newMname, true) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_SHOWINTCP", 0) end)
        pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_SHOWINMIXER", 0) end)
        dbg("  Set newly created M track to deactivated and hidden: " .. newMname)
        -- color will be applied after routing is processed (see below)
    end

    -- routing: A -> its Audio Bus (if specified)
    local bus_name = r.audio_send_to or ""
    if bus_name ~= "" then
        local bus_tr = bus_tracks[bus_name]
        if not bus_tr then
            dbg("Warning: Audio Bus track not found for name: " .. tostring(bus_name))
        else
            -- create stereo send pairs from A -> Bus mapping 1/2->1/2, 3/4->3/4, etc.
            -- IMPORTANT: VE strings like "19-20" are absolute channel numbers; we need the range length.
            local channel_count = channel_count_from_ve_for_bus(ve)

            local pairs = math.floor(channel_count / 2)
            local has_odd = (channel_count % 2) == 1

            for pair = 0, pairs-1 do
                local pair_src = pair * 2
                local pair_dst = pair * 2
                if send_has_dest_and_chans(A, bus_tr, pair_src, pair_dst) then
                    dbg(string.format("  Audio send pair already exists from %s to bus %s (pair src=%d)", A_name, bus_name, pair_src))
                else
                    local sidx = reaper.CreateTrackSend(A, bus_tr)
                    if sidx and sidx >= 0 then
                        dbg(string.format("  Created audio send from %s to bus %s (sendidx=%d pair_src=%d)", A_name, bus_name, sidx, pair_src))
                        pcall(function()
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_SRCCHAN", true, pair_src)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_DSTCHAN", true, pair_dst)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "D_VOL", true, 1.0)
                            reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "B_MUTE", true, 0.0)
                        end)
                    end
                end
            end
            -- handle any odd leftover single channel
            if has_odd then
                local last_src = pairs * 2
                local last_dst = pairs * 2
                -- ensure leftover channel doesn't exceed MASTER_NCHANNELS-1
                if last_src < MASTER_NCHANNELS then
                    if not send_has_dest_and_chans(A, bus_tr, last_src, last_dst) then
                        local sidx = reaper.CreateTrackSend(A, bus_tr)
                        if sidx and sidx >= 0 then
                            dbg(string.format("  Created single-channel audio send from %s to bus %s (sendidx=%d src=%d)", A_name, bus_name, sidx, last_src))
                            pcall(function()
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_SRCCHAN", true, last_src)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_DSTCHAN", true, last_dst)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTBUS", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_SRCCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "I_MIDI_DSTCHAN", true, -1)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "D_VOL", true, 1.0)
                                reaper.BR_GetSetTrackSendInfo(A, 0, sidx, "B_MUTE", true, 0.0)
                            end)
                        end
                    else
                        dbg(string.format("  Single-channel audio send already exists from %s to bus %s (src=%d)", A_name, bus_name, last_src))
                    end
                else
                    dbg(string.format("  Skipping leftover single channel %d — exceeds MASTER_NCHANNELS (%d)", last_src, MASTER_NCHANNELS))
                end
            end
        end
    end
    -- Apply coloring for this A/M pair based on the audio bus routing (only for newly created tracks)
    do
        local bus_key = (bus_name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        local assigned_hex = nil
        if bus_key ~= "" then assigned_hex = color_map[bus_key] end
        if not assigned_hex then assigned_hex = default_color_hex end
        local native_color = (assigned_hex and native_from_hex(assigned_hex)) or nil
        if native_color then
            if createdA then set_track_color(A, native_color) dbg(string.format("Applied color %s to %s (bus=%s)", tostring(assigned_hex), A_name, tostring(bus_name))) end
            if createdM then set_track_color(M, native_color) dbg(string.format("Applied color %s to %s (bus=%s)", tostring(assigned_hex), M_name, tostring(bus_name))) end
        end
    end
    -- routing: A receives audio from CTRL (stereo or quad depending on VE range)
    local src_track = ctrl_tracks[ctrl]
    if src_track then
        local start_ch, end_ch = parse_ve_range_with_default(ve, 4)
        local segments, _count, pairs, has_odd = ve_segments(start_ch, end_ch)
        local dest_nchan = required_dst_nchan_for_segments(pairs, has_odd)
        reaper.SetMediaTrackInfo_Value(A, "I_NCHAN", dest_nchan)
        dbg(string.format("  A track %s I_NCHAN set to %d (VE %s)", A_name, dest_nchan, tostring(ve)))

        for idx, seg in ipairs(segments) do
            local desired_src = ctrl_srcchan_value(seg.src_start0, seg.is_mono)
            local desired_dst = seg.dst_start0
            local ok_send, changed = ensure_audio_send(src_track, A, desired_src, desired_dst)
            if ok_send then
                dbg(string.format("    Ensured %s send to A: seg=%d src=%d%s dst=%d%s", seg.is_mono and "mono" or "stereo", idx, seg.src_start0, seg.is_mono and "(mono)" or "", seg.dst_start0, changed and " (created/updated)" or ""))
            else
                dbg(string.format("    Warning: failed ensuring send to A for seg=%d", idx))
            end
        end
    else
        dbg("Warning: CTRL track not found for " .. ctrl)
    end

    -- routing: M sends MIDI to CTRL
    if src_track then
        if receive_from_src_exists(M, src_track) or (midi_bus and send_has_midi(M, src_track, midi_bus)) then
            dbg(string.format("    MIDI send already exists from M to CTRL bus=%s (skipping)", tostring(midi_bus)))
        else
            local sendidx = reaper.CreateTrackSend(M, src_track)
            if sendidx and sendidx >= 0 then
                dbg(string.format("    Created MIDI send from M to CTRL: sendidx=%d", sendidx))
                -- disable audio
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_SRCCHAN", true, -1)
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_DSTCHAN", true, -1)
                -- midi mapping: source bus fixed to 1, destination from csv if present
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_SRCBUS", true, 1)
                if midi_bus then reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_DSTBUS", true, midi_bus) end
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_SRCCHAN", true, 0)
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "I_MIDI_DSTCHAN", true, 0)
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "D_VOL", true, 1.0)
                reaper.BR_GetSetTrackSendInfo(M, 0, sendidx, "B_MUTE", true, 0.0)
            end
        end
    end

    created[#created+1] = {A=A, M=M, kind="pair"}

    ::skip::
end

reaper.TrackList_AdjustWindows(false)

-- Final ordering pass: Instruments (incl. multi-audio groups) -> FX -> Busses -> CTRL
do
    -- Build a map of bus -> position (exact matching) and a lookup for DEFAULT.
    -- If no positions CSV was provided, fall back to deterministic ordering.
    local pos_map = {}
    local ordered_buses = {}
    if #positions_entries > 0 then
        table.sort(positions_entries, function(a,b) return a.pos < b.pos end)
        for _, e in ipairs(positions_entries) do
            pos_map[e.bus] = e.pos
            table.insert(ordered_buses, e.bus)
        end
    else
        -- fallback: order buses alphabetically by name
        for bname,_ in pairs(bus_tracks) do table.insert(ordered_buses, bname) end
        table.sort(ordered_buses)
    end
    local default_pos = pos_map["DEFAULT"]

    -- 1) Reorder instruments to the top.
    -- Normal A/M pairs are bucketed by bus order.
    -- Multi-audio groups are kept together as a block (A returns first, then parent M),
    -- and bucketed by the first child bus if any, otherwise DEFAULT/NO_BUS.
    do
        local buckets = {}
        for _, bname in ipairs(ordered_buses) do buckets[bname] = {} end

        for _, item in ipairs(instrument_items) do
            if item.kind == "pair" then
                local base = (item.lib ~= "" and (item.lib .. " " .. item.name) or item.name)
                local A_name = "A " .. base
                local D_A_name = "D " .. A_name
                local M_name = "M " .. base
                local D_M_name = "D " .. M_name
                local A_tr = find_track_by_name(A_name) or find_track_by_name(D_A_name)
                local M_tr = find_track_by_name(M_name) or find_track_by_name(D_M_name)
                if A_tr then
                    local bus = item.audio_send_to or ""
                    local target_bus = nil
                    if bus == "" then
                        if default_pos then target_bus = "DEFAULT" end
                    else
                        if pos_map[bus] then target_bus = bus
                        else
                            if default_pos then target_bus = "DEFAULT" end
                        end
                    end

                    if not target_bus then
                        target_bus = ordered_buses[1]
                        if not target_bus then
                            target_bus = "__NO_BUS__"
                            if not buckets[target_bus] then table.insert(ordered_buses, target_bus) buckets[target_bus] = {} end
                        end
                    end

                    if not buckets[target_bus] then buckets[target_bus] = {} end
                    table.insert(buckets[target_bus], {kind="pair", A=A_tr, M=M_tr, bus=target_bus})
                end
            elseif item.kind == "multi_audio" then
                local parent = item.parent
                if parent then
                    local parent_base = (parent.lib ~= "" and (parent.lib .. " " .. parent.name) or parent.name)
                    local M_name = "M " .. parent_base
                    local D_M_name = "D " .. M_name
                    local M_tr = find_track_by_name(M_name) or find_track_by_name(D_M_name)

                    local tracks = {}
                    -- child A returns first
                    for _, ch in ipairs(item.children or {}) do
                        local plabel = trim(tostring(parent.lib or "") .. " " .. tostring(parent.name or ""))
                        local A_display = string.format("%s (%s)", tostring(ch.name or ""), plabel)
                        local A_name = "A " .. A_display
                        local D_A_name = "D " .. A_name
                        local A_tr = find_track_by_name(A_name) or find_track_by_name(D_A_name)
                        if A_tr then table.insert(tracks, A_tr) end
                    end
                    if M_tr then table.insert(tracks, M_tr) end

                    if #tracks > 0 then
                        local bus = tostring(parent.bus or "")
                        local target_bus = nil
                        if bus == "" then
                            if default_pos then target_bus = "DEFAULT" end
                        else
                            if pos_map[bus] then target_bus = bus
                            else
                                if default_pos then target_bus = "DEFAULT" end
                            end
                        end
                        if not target_bus then
                            target_bus = ordered_buses[1]
                            if not target_bus then
                                target_bus = "__NO_BUS__"
                                if not buckets[target_bus] then table.insert(ordered_buses, target_bus) buckets[target_bus] = {} end
                            end
                        end

                        if not buckets[target_bus] then buckets[target_bus] = {} end
                        table.insert(buckets[target_bus], {kind="multi_audio", tracks=tracks, bus=target_bus})
                    end
                end
            end
        end

        local final_pairs = {}
        for _, bname in ipairs(ordered_buses) do
            local bucket = buckets[bname]
            if bucket then
                for _, p in ipairs(bucket) do table.insert(final_pairs, p) end
            end
        end

        local insert_index = 0
        local instrument_track_count = 0
        for i = #final_pairs, 1, -1 do
            local p = final_pairs[i]
            if p and p.kind == "pair" and p.A then
                for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
                reaper.SetTrackSelected(p.A, true)
                if p.M then reaper.SetTrackSelected(p.M, true) end
                reaper.ReorderSelectedTracks(insert_index, 0)
                instrument_track_count = instrument_track_count + 1
                if p.M then instrument_track_count = instrument_track_count + 1 end
            elseif p and p.kind == "multi_audio" and p.tracks then
                -- Move each track individually (reverse) to guarantee stable internal order.
                for k = #p.tracks, 1, -1 do
                    local tr = p.tracks[k]
                    if tr then
                        for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
                        reaper.SetTrackSelected(tr, true)
                        reaper.ReorderSelectedTracks(insert_index, 0)
                        instrument_track_count = instrument_track_count + 1
                    end
                end
            end
        end

        -- 2) Reorder FX tracks after instruments.
        local fx_by_ctrl = {}
        local fx_ctrls = {}
        local fx_track_count = 0
        for _, r in ipairs(rows) do
            local is_fx = (tostring(r.lib or ""):upper() == "FX")
            if is_fx then
                local fx_name = "FX " .. tostring(r.name or "")
                local fx_tr = find_track_by_name(fx_name)
                if fx_tr then
                    local c = tostring(r.ctrl or "")
                    if not fx_by_ctrl[c] then fx_by_ctrl[c] = {} table.insert(fx_ctrls, c) end
                    table.insert(fx_by_ctrl[c], fx_tr)
                end
            end
        end

        local function ctrl_sort_key(ctrlname)
            local n = tonumber((tostring(ctrlname or ""):match("(%d+)$")))
            if n then return n end
            return 999999
        end

        table.sort(fx_ctrls, function(a,b)
            local ka, kb = ctrl_sort_key(a), ctrl_sort_key(b)
            if ka ~= kb then return ka < kb end
            return tostring(a) < tostring(b)
        end)

        local final_fx = {}
        for _, c in ipairs(fx_ctrls) do
            local list = fx_by_ctrl[c]
            if list then
                for _, tr in ipairs(list) do
                    table.insert(final_fx, tr)
                end
            end
        end

        local fx_insert_index = instrument_track_count
        for i = #final_fx, 1, -1 do
            local tr = final_fx[i]
            if tr then
                for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
                reaper.SetTrackSelected(tr, true)
                reaper.ReorderSelectedTracks(fx_insert_index, 0)
                fx_track_count = fx_track_count + 1
            end
        end

        -- 3) Reorder Bus tracks after instruments + FX.
        local bus_insert_index = instrument_track_count + fx_track_count
        if #ordered_buses > 0 then
            for i = #ordered_buses, 1, -1 do
                local bname = ordered_buses[i]
                if bname and bname ~= "DEFAULT" and bname ~= "__NO_BUS__" then
                    local tr = find_track_by_name(bname)
                    if tr then
                        for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
                        reaper.SetTrackSelected(tr, true)
                        reaper.ReorderSelectedTracks(bus_insert_index, 0)
                    end
                end
            end
        end

        -- 4) Reorder CTRL tracks to the bottom in CSV order.
        if #ctrl_order > 0 then
            for i = #ctrl_order, 1, -1 do
                local cname = ctrl_order[i]
                local tr = ctrl_tracks[cname]
                if tr then
                    for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
                    reaper.SetTrackSelected(tr, true)
                    reaper.ReorderSelectedTracks(-1, 0)
                end
            end
        end
    end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("jg_MCTM: Build tracks from CSV", -1)

do
    local pair_count = 0
    local fx_count = 0
    local multi_audio_parent_count = 0
    local multi_audio_child_count = 0
    for _, entry in ipairs(created) do
        if entry and entry.A and entry.M then
            pair_count = pair_count + 1
        elseif entry and entry.kind == "fx" then
            fx_count = fx_count + 1
        elseif entry and entry.kind == "multi_audio_parent" then
            multi_audio_parent_count = multi_audio_parent_count + 1
        elseif entry and entry.kind == "multi_audio_child" then
            multi_audio_child_count = multi_audio_child_count + 1
        end
    end
    dbg(string.format("Created %d A/M pairs, %d multi-audio parents, %d multi-audio child A tracks, and %d FX tracks.", pair_count, multi_audio_parent_count, multi_audio_child_count, fx_count))
end
do
    local keys = {}
    for k,_ in pairs(ctrl_tracks) do table.insert(keys, k) end
    table.sort(keys)
    dbg("CTRL tracks present/created: " .. (#keys>0 and table.concat(keys, ", ") or "(none)"))
end
