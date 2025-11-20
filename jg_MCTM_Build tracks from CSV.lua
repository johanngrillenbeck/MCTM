--[[
ReaScript Name: jg_MCTM_Build tracks from CSV
Author: JG (assistant)
Description: Create CTRL tracks and A/M track pairs from a CSV template. Sets quad audio receives and MIDI sends according to CSV.
]]

reaper.ClearConsole()
local function dbg(m) reaper.ShowConsoleMsg(tostring(m) .. "\n") end

local function trim(s) if not s then return "" end return (s:gsub('^%s+', ''):gsub('%s+$','')) end

-- prompt for csv
    local ok, input = reaper.GetUserInputs("CSV Path (fallback)", 1, "CSV file full path:", "")
    if not ok then dbg("User cancelled fallback path input.") return end
    csvPath = input
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

-- collect rows and unique CTRL names
local rows = {}
local ctrl_set = {}
local bus_set = {}
dbg("Parsing CSV...")
for idx, line in ipairs(lines) do
    if idx == 1 then goto cont2 end -- skip header
    if line:match("^%s*$") then goto cont2 end
    local fields = split_semicolon(line)
    -- ensure at least 3 columns exist
    local ctrl = trim(fields[1] or "")
    local lib = trim(fields[2] or "")
    local tname = trim(fields[3] or "")
    -- New CSV layout may include an "Audio Send To" column immediately to the right of the track name.
    -- Support both layouts:
    local audio_send_to = ""
    local ve = ""
    local midi_bus = ""
    if #fields >= 6 then
        -- assume: ctrl; lib; name; audio_send_to; ve; midi_bus
        audio_send_to = trim(fields[4] or "")
        ve = trim(fields[5] or "")
        midi_bus = trim(fields[6] or "")
    else
        -- fallback to old layout: ctrl; lib; name; ve; midi_bus
        ve = trim(fields[4] or "")
        midi_bus = trim(fields[5] or "")
    end
    if ctrl ~= "" and (lib ~= "" or tname ~= "") then
        table.insert(rows, {ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus, audio_send_to=audio_send_to})
        if not ctrl_set[ctrl] then ctrl_set[ctrl] = true end
        if audio_send_to and audio_send_to ~= "" then bus_set[audio_send_to] = true end
    end
    ::cont2::
end
dbg("Parsed rows: " .. tostring(#rows))

-- compute per-CTRL required source channels (max channel index needed)
local ctrl_needs = {}
for _, r in ipairs(rows) do
    local ctrl = r.ctrl
    local ve = r.ve or ""
    -- parse range like '1-4' or single number
    local a,b = ve:match("(%d+)%s*-%s*(%d+)")
    local endch = nil
    if a and b then endch = tonumber(b) end
    if not endch then
        local single = ve:match("(%d+)")
        if single then endch = tonumber(single) end
    end
    if endch then
        ctrl_needs[ctrl] = math.max(ctrl_needs[ctrl] or 0, endch)
    else
        -- default to at least 4 channels
        ctrl_needs[ctrl] = math.max(ctrl_needs[ctrl] or 0, 4)
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
-- Preserve CTRL order as encountered in CSV
local ctrl_order = {}
local seen = {}
for _, r in ipairs(rows) do
    if r.ctrl and not seen[r.ctrl] then seen[r.ctrl]=true table.insert(ctrl_order, r.ctrl) end
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
        dbg("  Track count after creation: " .. tostring(reaper.CountTracks(0)))
    else
        dbg("Found existing CTRL track: "..ctrlname)
    end
    ctrl_tracks[ctrlname] = found
end

-- Move CTRL tracks to top of TCP in CSV order
if #ctrl_order > 0 then
    dbg("Reordering CTRL tracks to top...")
    -- move in reverse so final order matches ctrl_order
    for i = #ctrl_order, 1, -1 do
        local cname = ctrl_order[i]
        local tr = ctrl_tracks[cname]
        if tr then
            -- clear selection
            for j = 0, reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,j), false) end
            reaper.SetTrackSelected(tr, true)
            reaper.ReorderSelectedTracks(0, 0)
        end
    end
    reaper.TrackList_AdjustWindows(false)
end

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
            else
                dbg("Found existing Bus track: " .. tostring(bname))
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
for i, r in ipairs(rows) do
    dbg(string.format("Processing row %d: CTRL=%s | Lib=%s | Name=%s | VE=%s | MidiBus=%s", i, tostring(r.ctrl), tostring(r.lib), tostring(r.name), tostring(r.ve), tostring(r.midi_bus)))
    local ctrl = r.ctrl
    local lib = r.lib
    local tname = r.name
    local ve = r.ve
    local midi_bus = tonumber(r.midi_bus) or nil

    if tname == "" then goto skip end

    local base = (lib ~= "" and (lib .. " " .. tname) or tname)

    -- find or create A track (idempotent)
    local A_name = "A " .. base
    local M_name = "M " .. base
    local A = find_track_by_name(A_name)
    if A then
        dbg("  Found existing A track: " .. A_name)
    else
        local idxA = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idxA, true)
        A = reaper.GetTrack(0, idxA)
        reaper.GetSetMediaTrackInfo_String(A, "P_NAME", A_name, true)
        dbg("  Created A track: " .. base .. " A")
    end

    -- find or create M track (idempotent)
    local M = find_track_by_name(M_name)
    if M then
        dbg("  Found existing M track: " .. M_name)
    else
        local idxM = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idxM, true)
        M = reaper.GetTrack(0, idxM)
        reaper.GetSetMediaTrackInfo_String(M, "P_NAME", M_name, true)
        dbg("  Created M track: " .. base .. " M")
    end
    -- disable parent/master send for both tracks (user requested)
    pcall(function() reaper.SetMediaTrackInfo_Value(A, "B_MAINSEND", 0) end)
    pcall(function() reaper.SetMediaTrackInfo_Value(M, "B_MAINSEND", 0) end)

    -- routing: A -> its Audio Bus (if specified)
    local bus_name = r.audio_send_to or ""
    if bus_name ~= "" then
        local bus_tr = bus_tracks[bus_name]
        if not bus_tr then
            dbg("Warning: Audio Bus track not found for name: " .. tostring(bus_name))
        else
            if send_exists_to_dest(A, bus_tr) then
                dbg(string.format("  Audio send already exists from %s to bus %s (skipping)", A_name, bus_name))
            else
                local sidx = reaper.CreateTrackSend(A, bus_tr)
                if sidx and sidx >= 0 then
                    dbg(string.format("  Created audio send from %s to bus %s (sendidx=%d)", A_name, bus_name, sidx))
                    -- ensure it's an audio send (disable MIDI mapping)
                    pcall(function()
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

    -- routing: A receives audio from CTRL (stereo or quad depending on VE range)
    local src_track = ctrl_tracks[ctrl]
    if src_track then
        -- parse ve field like '1-4' -> take first number
        local start_ch = 1
        local a,b = ve:match("(%d+)%s*-%s*(%d+)")
        local end_ch = nil
        if a and b then
            start_ch = tonumber(a) or start_ch
            end_ch = tonumber(b)
        else
            local single = ve:match("(%d+)")
            local single_n = tonumber(single)
            if single_n then start_ch = single_n end
            end_ch = start_ch + 3 -- default quad if unspecified
        end
        local src_start = start_ch - 1 -- zero-based
        local channel_count = math.max(1, (end_ch - start_ch + 1))
        -- ensure destination track has sufficient input channels (use channel_count)
        reaper.SetMediaTrackInfo_Value(A, "I_NCHAN", channel_count)
        dbg(string.format("  A track %s I_NCHAN set to %d (VE %s)", A_name, channel_count, tostring(ve)))

        -- number of stereo pairs to create (each pair = 2 channels)
        local pairs = math.floor(channel_count / 2)
        local has_odd = (channel_count % 2) == 1

        -- prefer checking receives on destination for robustness; fallback to send_exists_to_dest
        if receive_from_src_exists(src_track, A) or send_exists_to_dest(src_track, A) then
            dbg(string.format("    At least one send already exists from CTRL to %s — skipping channel creation to avoid duplicates.", A_name))
        else
            -- create stereo pairs
            for pair = 0, pairs-1 do
                local pair_src = src_start + pair*2
                local pair_dst = pair*2
                local sendidx = reaper.CreateTrackSend(src_track, A)
                if sendidx and sendidx >= 0 then
                    dbg(string.format("    Created stereo send to A: sendidx=%d pair=%d src=%d dst=%d", sendidx, pair, pair_src, pair_dst))
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_SRCCHAN", true, pair_src)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_DSTCHAN", true, pair_dst)
                    pcall(function()
                        reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_SRCCHAN", pair_src)
                        reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_DSTCHAN", pair_dst)
                    end)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_SRCBUS", true, -1)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_DSTBUS", true, -1)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_SRCCHAN", true, -1)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_DSTCHAN", true, -1)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "D_VOL", true, 1.0)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "B_MUTE", true, 0.0)
                end
            end
            -- if odd channel left, create single-channel send for the remaining channel
            if has_odd then
                local last_src = src_start + pairs*2
                local last_dst = pairs*2
                local sendidx = reaper.CreateTrackSend(src_track, A)
                if sendidx and sendidx >= 0 then
                    dbg(string.format("    Created single-channel send to A: sendidx=%d src=%d dst=%d", sendidx, last_src, last_dst))
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_SRCCHAN", true, last_src)
                    reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_DSTCHAN", true, last_dst)
                    pcall(function()
                        reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_SRCCHAN", last_src)
                        reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_DSTCHAN", last_dst)
                    end)
                end
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

    created[#created+1] = {A=A, M=M}

    ::skip::
end

reaper.TrackList_AdjustWindows(false)
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("jg_MCTM: Build tracks from CSV", -1)

dbg("Created "..tostring(#created).." A/M pairs.")
do
    local keys = {}
    for k,_ in pairs(ctrl_tracks) do table.insert(keys, k) end
    table.sort(keys)
    dbg("CTRL tracks present/created: " .. (#keys>0 and table.concat(keys, ", ") or "(none)"))
end
