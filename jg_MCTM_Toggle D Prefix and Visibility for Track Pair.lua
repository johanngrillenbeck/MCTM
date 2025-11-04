--[[
Reaper Lua Script: Stable toggle 'D ' prefix and visibility for A/M track pairs
Author: JG and ChatGPT
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
    -- Use helper to strip prefixes and build partner name preserving the A/M token
    local parsed = mctm.parse(name)
    local base = parsed.name
    if base == "" then return nil end
    if mctm.is_audio(parsed) then
        return "M " .. base
    elseif mctm.is_midi(parsed) then
        return "A " .. base
    end
    return nil
end

local function findTrackByName(searchName, excludeTrack)
    -- finds a track by matching the base instrument name (ignores leading D)
    -- excludeTrack: optional Reaper track object to skip (avoid returning the same track)
    local searchBase = mctm.parse(searchName).name
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if excludeTrack and tr == excludeTrack then goto continue end
        local _, trName = reaper.GetTrackName(tr, "")
        local parsed = mctm.parse(trName)
        if parsed.name == searchBase then
            return tr
        end
        ::continue::
    end
    return nil
end

local function hasPrefix(name, prefix)
    return name:sub(1, #prefix) == prefix
end

-- Sammle Tracks zur Verarbeitung (ausgewählte + deren Partner)
local selCount = reaper.CountSelectedTracks(0)
local tracksToProcess = {}

for i = 0, selCount - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    tracksToProcess[track] = true
        local _, name = reaper.GetTrackName(track, "")
        local partnerName = getPartnerName(name)
        if partnerName then
            local partnerTrack = findTrackByName(partnerName, track)
            if partnerTrack then tracksToProcess[partnerTrack] = true end
        end
end

-- Bestimme, ob deaktiviert oder reaktiviert werden soll
local deactivate = false
for track, _ in pairs(tracksToProcess) do
    local _, name = reaper.GetTrackName(track, "")
    local parsed = mctm.parse(name)
    if not mctm.is_disabled(parsed) then
        deactivate = true
        break
    end
end

-- Anwenden des Toggles (synchronisiert für beide Partner)
for track, _ in pairs(tracksToProcess) do
    local _, name = reaper.GetTrackName(track, "")
    local parsed = mctm.parse(name)

    if deactivate then
        -- Add 'D' prefix if not present
        if not mctm.is_disabled(parsed) then
            local newPrefixes = {"D"}
            for _, p in ipairs(parsed.prefixes) do table.insert(newPrefixes, p) end
            local newName = mctm.format_label(newPrefixes, parsed.name)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", newName, true)
        end
        -- Always hide disabled tracks in TCP and Mixer
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
    else
        -- Remove 'D' prefix if present
        if mctm.is_disabled(parsed) then
            local newPrefixes = {}
            for _, p in ipairs(parsed.prefixes) do if p ~= "D" then table.insert(newPrefixes, p) end end
            local newName = mctm.format_label(newPrefixes, parsed.name)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", newName, true)
            parsed = mctm.parse(newName)
        end
        -- Set visibility depending on type
        if mctm.is_midi(parsed) then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
        elseif mctm.is_audio(parsed) then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
        end
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle 'D ' prefix and visibility (stable)", -1)

