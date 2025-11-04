--[[
ReaScript Name: Route Selected Tracks to CTRL MIDI Buses (ascending)
Author: ChatGPT
Version: 1.1
Description: Routes selected tracks MIDI to CTRL tracks in ascending order, disables audio sends
]]

-- Helper function: get all tracks with prefix "CTRL"
local mctm = dofile("jg_MCTM_helper.lua")

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

-- Show dropdown as index input
local retval, selection = reaper.GetUserInputs("Select CTRL Track", 1, "CTRL Track (dropdown index):", "1")
if not retval then return end

local sel_index = tonumber(selection)
if not sel_index or sel_index < 1 or sel_index > #ctrl_tracks then
    reaper.MB("Ungültige Auswahl!", "Fehler", 0)
    return
end

local target_track = ctrl_tracks[sel_index].track

-- Main routing loop
local sel_track_count = reaper.CountSelectedTracks(0)
if sel_track_count == 0 then
    reaper.MB("Keine Tracks ausgewählt!", "Fehler", 0)
    return
end

reaper.Undo_BeginBlock()
for i = 0, sel_track_count-1 do
    local tr = reaper.GetSelectedTrack(0, i)

    -- Disable master send
    reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)

    -- Remove existing sends to the target track
    local send_count = reaper.GetTrackNumSends(tr, 0) -- 0 = hardware/track sends
    for s = send_count-1, 0, -1 do
        local send_target = reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SENDTARGET")
        if send_target == target_track then
            reaper.RemoveTrackSend(tr, 0, s)
        end
    end

    -- Add MIDI send to target track
    local send_index = reaper.CreateTrackSend(tr, target_track)
    -- Set omni MIDI (no channel filter)
    reaper.SetTrackSendInfo_Value(tr, 0, send_index, "I_MIDIFLAGS", 0)  -- 0 = omni
end
reaper.Undo_EndBlock("Route selected tracks to CTRL MIDI buses", -1)

