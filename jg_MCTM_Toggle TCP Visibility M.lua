--[[
Reaper Lua Script: Toggle visibility in TCP for tracks starting with "M "
Author: JG with the help of ChatGPT (sry, y'all!)
--]]

reaper.Undo_BeginBlock()

local trackCount = reaper.CountTracks(0)
local anyVisible = false

-- Erst prüfen, ob mindestens ein "M "-Track gerade sichtbar ist
for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    if name:sub(1, 2) == "M " then
        local visible = reaper.GetMediaTrackInfo_Value(track, "B_SHOWINTCP")
        if visible > 0 then
            anyVisible = true
            break
        end
    end
end

-- Wenn irgendein "M "-Track sichtbar ist → ausblenden, sonst einblenden
local newState = anyVisible and 0 or 1

for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    if name:sub(1, 2) == "M " then
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", newState)
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle TCP visibility of 'M ' tracks", -1)

