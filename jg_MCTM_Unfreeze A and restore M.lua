--[[
Name: Unfreeze A and restore M
Author: JG
Usage: Select A or M track(s) of a group, launch script.
Action: Unfreeze Audio on A track(s) of the selected group(s), unmute and unlock all of the MIDI Clips, hide A track(s), show M track(s) in TCP.

Logic:
1. Parse selected instrument groups from selection
    - identify A tracks to select
    - store M track objects for step 3
2. Execute Reaper native "Unfreeze" Action with Command ID 41644 on selected A tracks
3. Iterate through all stored M tracks
    - Unmute all items on the track
    - Unlock all items on the track
    - Show track in TCP (for MCP: An M track should never be shown there to begin with, so we can skip hiding it there)
]]

reaper.Undo_BeginBlock()

local function add_script_dir_to_package_path()
    local info = debug.getinfo(1, 'S')
    if not info or not info.source then return end
    local source = info.source
    local script_dir = source:match('@?(.*[\\/])')
    if not script_dir then return end
    local pattern1 = script_dir .. '?.lua;'
    local pattern2 = script_dir .. '?/init.lua;'
    package.path = pattern1 .. pattern2 .. package.path
end
add_script_dir_to_package_path()

local ok, mctm = pcall(require, 'jg_MCTM_helper')
if not ok or not mctm then
    reaper.ShowConsoleMsg('Could not require jg_MCTM_helper.lua\n')
    return
end

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local UNFREEZE_ACTION_ID = 41644

local function build_midi_base_set()
    local set = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(tr)
        local parsed = mctm.parse(name)
        if parsed and mctm.is_midi(parsed) then
            local base = trim(parsed.name)
            if base ~= '' then
                set[base] = true
            end
        end
    end
    return set
end

local function group_key_from_parsed(parsed, midi_bases)
    if not parsed then return '' end
    local base = trim(parsed.name)
    if base == '' then return '' end

    if mctm.is_audio(parsed) then
        local inside = base:match('%((.-)%)%s*$')
        if inside then
            inside = trim(inside)
            if inside ~= '' and midi_bases and midi_bases[inside] then
                return inside
            end
        end
    end

    return base
end

local original_selected = {}
for i = 0, reaper.CountSelectedTracks(0) - 1 do
    table.insert(original_selected, reaper.GetSelectedTrack(0, i))
end

local midi_bases = build_midi_base_set()
local selected_group_keys = {}
for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetTrackName(track)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local key = group_key_from_parsed(parsed, midi_bases)
        if key ~= '' then
            selected_group_keys[key] = true
        end
    end
end

local a_tracks = {}
local m_tracks = {}
for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local key = group_key_from_parsed(parsed, midi_bases)
        if key ~= '' and selected_group_keys[key] then
            if mctm.is_audio(parsed) then
                table.insert(a_tracks, track)
            elseif mctm.is_midi(parsed) then
                table.insert(m_tracks, track)
            end
        end
    end
end

if #a_tracks == 0 then
    reaper.ShowMessageBox('No A tracks found in the selected group(s).', 'Unfreeze A and restore M', 0)
    reaper.Undo_EndBlock('Unfreeze A and restore M', -1)
    return
end

reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
for _, track in ipairs(a_tracks) do
    reaper.SetTrackSelected(track, true)
end

reaper.Main_OnCommand(UNFREEZE_ACTION_ID, 0)

reaper.Main_OnCommand(40297, 0)
for _, track in ipairs(original_selected) do
    if track then
        reaper.SetTrackSelected(track, true)
    end
end

for _, track in ipairs(a_tracks) do
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP', 0)
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 1)
end

for _, track in ipairs(m_tracks) do
    for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if item then
            reaper.SetMediaItemInfo_Value(item, 'B_MUTE', 0)
            reaper.SetMediaItemInfo_Value(item, 'C_LOCK', 0)
        end
    end
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP', 1)
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 0)
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock('Unfreeze A and restore M', -1)
