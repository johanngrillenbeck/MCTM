--[[
Reaper Lua Script: Toggle TCP visibility of corresponding "A " / "M " track pairs
Author: JG with help from ChatGPT
--]]

reaper.Undo_BeginBlock()

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

local function getPartnerName(name)
    local parsed = mctm.parse(name)
    local base = parsed.name
    if parsed and mctm.is_audio(parsed) then
        return "M " .. base
    elseif parsed and mctm.is_midi(parsed) then
        return "A " .. base
    end
    return nil
end

-- Alle Tracks erfassen, um schnellen Zugriff zu haben
local trackCount = reaper.CountTracks(0)
local trackMap = {}

for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    trackMap[name] = track
end

-- Für alle ausgewählten Tracks:
local selCount = reaper.CountSelectedTracks(0)
for i = 0, selCount - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    local partnerName = getPartnerName(name)

    if partnerName and trackMap[partnerName] then
        local partner = trackMap[partnerName]
        local visible = reaper.GetMediaTrackInfo_Value(partner, "B_SHOWINTCP")
        local newState = (visible > 0) and 0 or 1
        reaper.SetMediaTrackInfo_Value(partner, "B_SHOWINTCP", newState)
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle TCP visibility of partner tracks", -1)

