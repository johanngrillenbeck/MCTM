--[[
Reaper Lua Script: Stable toggle 'D ' prefix and visibility for A/M track groups
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

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Build a set of MIDI base names present in the project.
local function build_midi_base_set()
    local set = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(tr)
        local parsed = mctm.parse(name)
        if parsed and mctm.is_midi(parsed) then
            local base = trim(parsed.name)
            if base ~= "" then set[base] = true end
        end
    end
    return set
end

-- Group identity key:
-- - For normal A/M pairs: base name itself
-- - For multi-audio child A tracks: use the trailing parenthesized suffix only if it matches an existing MIDI base
local function group_key_from_parsed(parsed, midi_bases)
    if not parsed then return "" end
    local base = trim(parsed.name)
    if base == "" then return "" end

    if mctm.is_audio(parsed) then
        local inside = base:match("%((.-)%)%s*$")
        if inside then
            inside = trim(inside)
            if inside ~= "" and midi_bases and midi_bases[inside] then
                return inside
            end
        end
    end

    return base
end

-- Collect tracks to process (selected track groups)
local midi_bases = build_midi_base_set()
local selCount = reaper.CountSelectedTracks(0)
local selected_group_keys = {}
for i = 0, selCount - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetTrackName(track)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local gk = group_key_from_parsed(parsed, midi_bases)
        if gk ~= "" then selected_group_keys[gk] = true end
    end
end

local tracksToProcess = {}
for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local gk = group_key_from_parsed(parsed, midi_bases)
        if gk ~= "" and selected_group_keys[gk] then
            tracksToProcess[tr] = true
        end
    end
end

-- Bestimme, ob deaktiviert oder reaktiviert werden soll
local deactivate = false
for track, _ in pairs(tracksToProcess) do
    local _, name = reaper.GetTrackName(track)
    local parsed = mctm.parse(name)
    if not mctm.is_disabled(parsed) then
        deactivate = true
        break
    end
end

-- Apply toggle (synchronized for the whole track group)
for track, _ in pairs(tracksToProcess) do
    local _, name = reaper.GetTrackName(track)
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
reaper.Undo_EndBlock("Toggle 'D ' prefix and visibility (track groups)", -1)

