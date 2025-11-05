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
dbg("Parsing CSV...")
for idx, line in ipairs(lines) do
    if idx == 1 then goto cont2 end -- skip header
    if line:match("^%s*$") then goto cont2 end
    local fields = split_semicolon(line)
    -- ensure at least 3 columns exist
    local ctrl = trim(fields[1] or "")
    local lib = trim(fields[2] or "")
    local tname = trim(fields[3] or "")
    local ve = trim(fields[4] or "")
    local midi_bus = trim(fields[5] or "")
    if ctrl ~= "" and (lib ~= "" or tname ~= "") then
        table.insert(rows, {ctrl=ctrl, lib=lib, name=tname, ve=ve, midi_bus=midi_bus})
        if not ctrl_set[ctrl] then ctrl_set[ctrl] = true end
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
for ctrlname,_ in pairs(ctrl_set) do
    dbg("Looking for CTRL: " .. tostring(ctrlname))
    local before_count = reaper.CountTracks(0)
    dbg("  Track count before search: " .. tostring(before_count))
    -- search existing
    local found = nil
    for i = 0, reaper.CountTracks(0)-1 do
        local tr = reaper.GetTrack(0,i)
        local ok, tname = reaper.GetTrackName(tr)
        if type(tname) ~= "string" then tname = "" end
        if tname and tname:match("^"..ctrlname) then found = tr break end
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

-- create A and M track pairs (append at end) and set routing
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local created = {}
for i, r in ipairs(rows) do
    dbg(string.format("Processing row %d: CTRL=%s | Lib=%s | Name=%s | VE=%s | MidiBus=%s", i, tostring(r.ctrl), tostring(r.lib), tostring(r.name), tostring(r.ve), tostring(r.midi_bus)))
    local ctrl = r.ctrl
    local lib = r.lib
    local tname = r.name
    local ve = r.ve
    local midi_bus = tonumber(r.midi_bus) or nil

    if tname == "" then goto skip end

    local base = (lib ~= "" and (lib .. " " .. tname) or tname)

    -- create A track
    local idxA = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idxA, true)
    local A = reaper.GetTrack(0, idxA)
    reaper.GetSetMediaTrackInfo_String(A, "P_NAME", "A " .. base, true)
    -- ensure 4 channels
    reaper.SetMediaTrackInfo_Value(A, "I_NCHAN", 4)
    dbg("  Created A track: " .. base .. " A (I_NCHAN=4)")

    -- create M track
    local idxM = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idxM, true)
    local M = reaper.GetTrack(0, idxM)
    reaper.GetSetMediaTrackInfo_String(M, "P_NAME", "M " .. base, true)
    dbg("  Created M track: " .. base .. " M")

    -- routing: A receives quad audio from CTRL
    local src_track = ctrl_tracks[ctrl]
    if src_track then
        -- parse ve field like '1-4' -> take first number
        local start_ch = 1
    local s = ve:match("(%d+)%s*-%s*%d+")
    if s then start_ch = tonumber(s) or start_ch end
        local src_start = start_ch - 1 -- zero-based
        -- create two stereo sends (pair 0 and 1)
        for pair = 0,1 do
            local pair_src = src_start + pair*2
            local pair_dst = pair*2
            local sendidx = reaper.CreateTrackSend(src_track, A)
            if sendidx and sendidx >= 0 then
                dbg(string.format("    Created send to A: sendidx=%d pair=%d src=%d dst=%d", sendidx, pair, pair_src, pair_dst))
                -- set audio mapping
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
    else
        dbg("Warning: CTRL track not found for " .. ctrl)
    end

    -- routing: M sends MIDI to CTRL
    if src_track then
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
