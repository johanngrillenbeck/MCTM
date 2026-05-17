--[[
ReaScript Name: Route Selected Tracks to CTRL MIDI Buses (ascending)
Author: JG
Version: 1.1
Description: Routes selected tracks MIDI to CTRL tracks in ascending order, disables audio sends
]]


local function add_script_dir_to_package_path()
    local info = debug.getinfo(1, 'S')
    if not info or not info.source then return end
    local source = info.source
    local script_dir = source:match("@?(.*[\\/])")
    if not script_dir then return end
    local pattern1 = script_dir .. "?.lua;"
    local pattern2 = script_dir .. "?/init.lua;"
    package.path = pattern1 .. pattern2 .. package.path
end
add_script_dir_to_package_path()

local ok, mctm = pcall(require, "jg_MCTM_helper")
if not ok or not mctm then reaper.ShowConsoleMsg("Could not require 'jg_MCTM_helper': " .. tostring(mctm) .. "\n") return end

-- Helper function: get all tracks with prefix "CTRL"
function get_ctrl_tracks()
    local ctrl_tracks = {}
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count-1 do
        local tr = reaper.GetTrack(0, i)
        local _, tr_name = reaper.GetTrackName(tr, "")
        local parsed = mctm.parse(tr_name)
        if mctm.is_ctrl(parsed) then
            table.insert(ctrl_tracks, {track=tr, name=tr_name})
        end
    end
    return ctrl_tracks
end

-- Get CTRL tracks
local ctrl_tracks = get_ctrl_tracks()
if #ctrl_tracks == 0 then
    reaper.MB("Keine Tracks mit Prefix 'CTRL' gefunden!", "Fehler", 0)
    return
end

-- Build dropdown menu
local menu = ""
for i, t in ipairs(ctrl_tracks) do
    menu = menu .. t.name
    if i ~= #ctrl_tracks then menu = menu .. "|" end
end

-- Show dropdown as index input and a checkbox-like option (0/1) to delete existing MIDI sends
local prompt = "CTRL Track (dropdown index):,Delete All Midi Sends on selected tracks before creating incremental sends to CTRL? (0=no,1=yes):"
local retval, retvals = reaper.GetUserInputs("Select CTRL Track", 2, prompt, "1,0")
if not retval then return end

local parts = {}
for token in string.gmatch(retvals, "([^,]+)") do table.insert(parts, token) end
local sel_index = tonumber(parts[1])
local delete_midi_sends = tonumber(parts[2]) == 1
if not sel_index or sel_index < 1 or sel_index > #ctrl_tracks then
    reaper.MB("Ungültige Auswahl!", "Fehler", 0)
    return
end

local target_track = ctrl_tracks[sel_index].track

-- Count tracks, throw error if none selected
local sel_track_count = reaper.CountSelectedTracks(0)
if sel_track_count == 0 then
    reaper.MB("Keine Tracks ausgewählt!", "Fehler", 0)
    return
end

-- Main routing loop
-- Use BR_GetSetTrackSendInfo (from SWS/BR) to create MIDI-only sends on ascending busses.
-- Mapping: first selected track -> Bus 1, second -> Bus 2, etc. Always omni-channel (0 = all channels).
-- Audio sends are disabled by setting I_SRCCHAN / I_DSTCHAN = -1.

if type(reaper.BR_GetSetTrackSendInfo) ~= "function" then
    reaper.MB("BR_GetSetTrackSendInfo not found. Please install the SWS/BR extension.", "Fehler", 0)
    return
end

local max_busses = 128 -- maximum MIDI busses per-track (as requested)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Optionally delete existing MIDI sends on each selected track before creating new sends
if delete_midi_sends then
    for i = 0, sel_track_count-1 do
        local src = reaper.GetSelectedTrack(0, i)
        if not src then break end
        local nsends = reaper.GetTrackNumSends(src, 0)
        for s = nsends-1, 0, -1 do
            local midi_srcbus = reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_SRCBUS", false, 0)
            if midi_srcbus and midi_srcbus ~= -1 then
                -- DeleteTrackSend may not be available in some REAPER builds/environments.
                -- Instead of deleting the send, disable its MIDI routing by setting MIDI bus/channel to -1.
                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_SRCBUS", true, -1)
                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_SRCCHAN", true, -1)
                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_DSTBUS", true, -1)
                reaper.BR_GetSetTrackSendInfo(src, 0, s, "I_MIDI_DSTCHAN", true, -1)
            end
        end
    end
end

for i = 0, sel_track_count-1 do
    local src = reaper.GetSelectedTrack(0, i)
    if not src then break end

    local bus_idx = i + 1 -- 1-based destination bus numbering: 1..max_busses
    if bus_idx > max_busses then
        reaper.MB(string.format("Selected track %d requires Bus %d, which exceeds the max of %d busses. Stopping.", i+1, bus_idx, max_busses), "Fehler", 0)
        break
    end

    -- create a track send (source -> target_ctrl). CreateTrackSend returns sendidx (zero-based) or <0 on error
    local sendidx = reaper.CreateTrackSend(src, target_track)
    if sendidx and sendidx >= 0 then
        -- Disable audio send (no audio routing)
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_SRCCHAN", true, -1)
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_DSTCHAN", true, -1)

    -- Set MIDI bus mapping: source bus FIXED to 1 (omni input) -> destination bus ascending (1,2,3...)
    reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_SRCBUS", true, 1)
    reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_DSTBUS", true, bus_idx)

        -- Always omnichannel (0 == all channels)
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_SRCCHAN", true, 0)
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "I_MIDI_DSTCHAN", true, 0)

        -- Safety defaults: unity send volume and unmuted
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "D_VOL", true, 1.0)
        reaper.BR_GetSetTrackSendInfo(src, 0, sendidx, "B_MUTE", true, 0.0)
    else
        reaper.ShowConsoleMsg(string.format("Failed to create send for selected track %d\n", i+1))
    end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Route selected tracks to CTRL MIDI buses (ascending)", -1)
