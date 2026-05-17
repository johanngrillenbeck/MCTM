--[[
Reaper Lua Script: Toggle TCP visibility of corresponding A/M track groups
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

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

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

local midi_bases = build_midi_base_set()
local selCount = reaper.CountSelectedTracks(0)
local groups = {}

for i = 0, selCount - 1 do
    local tr = reaper.GetSelectedTrack(0, i)
        local _, name = reaper.GetTrackName(tr)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local gk = group_key_from_parsed(parsed, midi_bases)
        if gk ~= "" then
            if not groups[gk] then groups[gk] = {hasA=false, hasM=false, A={}, M={}} end
            if mctm.is_audio(parsed) then groups[gk].hasA = true end
            if mctm.is_midi(parsed) then groups[gk].hasM = true end
        end
    end
end

-- Collect group members (A/M) for each group key.
for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local gk = group_key_from_parsed(parsed, midi_bases)
        local g = groups[gk]
        if g then
            if mctm.is_audio(parsed) then table.insert(g.A, tr) end
            if mctm.is_midi(parsed) then table.insert(g.M, tr) end
        end
    end
end

-- Apply behavior:
-- - Selecting M toggles TCP visibility of ALL A tracks in group.
-- - Selecting any A toggles TCP visibility of the group's M track.
for _, g in pairs(groups) do
    if g.hasM then
        if #g.A > 0 then
            local visible = reaper.GetMediaTrackInfo_Value(g.A[1], "B_SHOWINTCP")
            local newState = (visible > 0) and 0 or 1
            for _, atr in ipairs(g.A) do
                reaper.SetMediaTrackInfo_Value(atr, "B_SHOWINTCP", newState)
            end
        end
    elseif g.hasA then
        if #g.M > 0 then
            local visible = reaper.GetMediaTrackInfo_Value(g.M[1], "B_SHOWINTCP")
            local newState = (visible > 0) and 0 or 1
            for _, mtr in ipairs(g.M) do
                reaper.SetMediaTrackInfo_Value(mtr, "B_SHOWINTCP", newState)
            end
        end
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle TCP visibility of track group", -1)

