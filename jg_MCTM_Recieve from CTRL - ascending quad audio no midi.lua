--[[
ReaScript Name: Receive Audio from CTRL (ascending quad)
Author: JG (copied pattern)
Version: 1.0
Description: Creates audio sends from selected CTRL (master) track to selected audio tracks in ascending quad groups.
             Each destination track receives 4 channels (inputs 1-4). The CTRL source provides channels 1-4 to first track,
             5-8 to second, 9-12 to third, etc. MIDI routing is disabled on the sends.
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

-- Helper: find CTRL tracks (same logic as other script)
local function get_ctrl_tracks()
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

-- Ask user to choose CTRL track (source)
local retval, selection = reaper.GetUserInputs("Select CTRL Track", 1, "CTRL Track (dropdown index):", "1")
if not retval then return end

local sel_index = tonumber(selection)
if not sel_index or sel_index < 1 or sel_index > #ctrl_tracks then
    reaper.MB("Ungültige Auswahl!", "Fehler", 0)
    return
end

local src_track = ctrl_tracks[sel_index].track

-- Count destination (selected) tracks
local sel_track_count = reaper.CountSelectedTracks(0)
if sel_track_count == 0 then
    reaper.MB("Keine Tracks ausgewählt! Wähle die Ziel-Audio-Tracks (A Tracks).", "Fehler", 0)
    return
end

-- Ensure BR API exists
if type(reaper.BR_GetSetTrackSendInfo) ~= "function" then
    reaper.MB("BR_GetSetTrackSendInfo not found. Please install the SWS/BR extension.", "Fehler", 0)
    return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- First: set all destination tracks to 4 channels so sends created afterwards will map correctly
for i = 0, sel_track_count-1 do
    local dst = reaper.GetSelectedTrack(0, i)
    if not dst then break end
    reaper.SetMediaTrackInfo_Value(dst, "I_NCHAN", 4)
end
-- Ensure track list/UI state is aware of the channel count changes
reaper.TrackList_AdjustWindows(false)

-- Also ensure the source CTRL track has enough channels to supply all quad groups
local total_src_channels = sel_track_count * 4
reaper.SetMediaTrackInfo_Value(src_track, "I_NCHAN", total_src_channels)
reaper.TrackList_AdjustWindows(false)

for i = 0, sel_track_count-1 do
    local dst = reaper.GetSelectedTrack(0, i)
    if not dst then break end

    -- For nth destination (i starting at 0), source start channel index (0-based) is i*4 -> covers channels (i*4 + 1) .. (i*4 + 4)
    local src_start = i * 4

    -- Create two stereo sends per destination to achieve a quad mapping (Reaper maps stereo pairs by default)
    for pair = 0,1 do
        local pair_src = src_start + pair*2
        local pair_dst = pair*2
        local sendidx = reaper.CreateTrackSend(src_track, dst)
        if sendidx and sendidx >= 0 then
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_SRCCHAN", true, pair_src)
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_DSTCHAN", true, pair_dst)
            -- Also set via core API as fallback
            pcall(function()
                reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_SRCCHAN", pair_src)
                reaper.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_DSTCHAN", pair_dst)
            end)
            -- Disable MIDI on these sends
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_SRCBUS", true, -1)
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_DSTBUS", true, -1)
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_SRCCHAN", true, -1)
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_MIDI_DSTCHAN", true, -1)
            -- Safety defaults
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "D_VOL", true, 1.0)
            reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "B_MUTE", true, 0.0)
            -- Diagnostic: print resulting send mapping for each pair
            local ok_read, r_src, r_dst = pcall(function()
                local a = reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_SRCCHAN", false, 0)
                local b = reaper.BR_GetSetTrackSendInfo(src_track, 0, sendidx, "I_DSTCHAN", false, 0)
                return a, b
            end)
            if ok_read then
                reaper.ShowConsoleMsg(string.format("Send %d.%d -> I_SRCCHAN=%s I_DSTCHAN=%s\n", i+1, pair+1, tostring(r_src), tostring(r_dst)))
            end
        else
            reaper.ShowConsoleMsg(string.format("Failed to create send (pair %d) to selected dest track %d\n", pair+1, i+1))
        end
    end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Receive audio from CTRL as ascending quad sends", -1)
