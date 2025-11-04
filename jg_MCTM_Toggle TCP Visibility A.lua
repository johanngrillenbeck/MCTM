--[[
Reaper Lua Script: Toggle visibility in TCP for tracks starting with "M "
Author: JG with the help of ChatGPT (sry, y'all!)
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

local trackCount = reaper.CountTracks(0)
local anyVisible = false

-- Check if any "A "-track is currently visible
for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    local parsed = mctm.parse(name)
    if mctm.is_audio(parsed) and not mctm.is_disabled(parsed) then
        local visible = reaper.GetMediaTrackInfo_Value(track, "B_SHOWINTCP")
        if visible > 0 then
            anyVisible = true
            break
        end
    end
end

-- When any "A "-track is visible → hide all, else show all
local newState = anyVisible and 0 or 1

for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    local parsed = mctm.parse(name)
    if mctm.is_audio(parsed) then
        if mctm.is_disabled(parsed) then
            -- Disabled tracks must always be hidden in TCP
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        else
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", newState)
        end
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle TCP visibility of 'A ' tracks", -1)

