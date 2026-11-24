--[[
Reaper Lua Script: Stable toggle 'D ' prefix and visibility for A/M track groups
Author: JG and ChatGPT
--]]

local function add_script_dir_to_package_path()
    local info = debug.getinfo(1, 'S')
    if not info or not info.source then return end
    local source = info.source
    local script_dir = source:match("@?(.*[\\/])")
    if not script_dir then return end

    -- Repo layout: Actions/ + ../Helpers/. Also tolerate a flat install.
    local roots = {
        script_dir,
        script_dir .. "../Helpers/",
        script_dir .. "Helpers/",
    }
    local parts = {}
    for _, root in ipairs(roots) do
        parts[#parts + 1] = root .. "?.lua;"
        parts[#parts + 1] = root .. "?/init.lua;"
    end
    package.path = table.concat(parts) .. package.path
end
add_script_dir_to_package_path()

local ok, mctm = pcall(require, "jg_MCTM_Helper")
if not ok or not mctm then reaper.ShowConsoleMsg("Could not require 'jg_MCTM_Helper': " .. tostring(mctm) .. "\n") return end

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
local group_midi = {}
for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    local parsed = mctm.parse(name)
    if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
        local gk = group_key_from_parsed(parsed, midi_bases)
        if gk ~= "" and selected_group_keys[gk] then
            tracksToProcess[tr] = true
            if mctm.is_midi(parsed) then
                group_midi[gk] = { track = tr, base_name = parsed.name }
            end
        end
    end
end

-- Bestimme, ob deaktiviert oder reaktiviert werden soll.
-- Choose tracks can force the target state for its batched to_disable/to_enable calls.
local deactivate
if _G.MCTM_FORCE_D_STATE ~= nil then
    deactivate = _G.MCTM_FORCE_D_STATE and true or false
else
    deactivate = false
    for track, _ in pairs(tracksToProcess) do
        local _, name = reaper.GetTrackName(track)
        local parsed = mctm.parse(name)
        if not mctm.is_disabled(parsed) then
            deactivate = true
            break
        end
    end
end

-- Apply toggle (synchronized for the whole track group)
reaper.Undo_BeginBlock()
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

-- Reconcile VE Pro after the REAPER changes, outside the undo block.
-- Choose tracks suppresses this and performs one batched sync for all groups.
if not _G.MCTM_SUPPRESS_VEPRO_SYNC then
    local ok_vepro, V = pcall(require, "jg_MCTM_VEPro")
    if not ok_vepro or not V then
        reaper.ShowConsoleMsg("[MCTM] Could not load jg_MCTM_VEPro: " .. tostring(V) .. "\n")
    else
        V.reset_cache()

        local jobs = {}
        for _, entry in pairs(group_midi) do
            jobs[#jobs + 1] = {
                midi_track = entry.track,
                base_name = entry.base_name,
                desired = not deactivate,
                label = entry.base_name,
            }
        end

        if #jobs > 0 then
            local dry_run = reaper.GetExtState("MCTM", "vepro_dry_run") == "1"
            local report = V.sync(jobs, { dry_run = dry_run })
            local summary = report.summary

            if summary.errors > 0 then
                local lines = {
                    string.format("VE Pro sync reported %d error(s).", summary.errors),
                    "",
                }
                for index = 1, math.min(#report.errors, 8) do
                    local entry = report.errors[index]
                    local err = entry.error or {}
                    lines[#lines + 1] = string.format(
                        "- %s: %s %s",
                        tostring(entry.label),
                        tostring(err.code or "ERROR"),
                        tostring(err.message or "")
                    )
                end
                if #report.errors > 8 then
                    lines[#lines + 1] = "- ..."
                end
                reaper.MB(table.concat(lines, "\n"), "MCTM VE Pro sync", 0)
            elseif dry_run and (summary.would_enable + summary.would_disable) > 0 then
                reaper.MB(
                    string.format(
                        "Dry run: %d channel(s) would be enabled, %d disabled.\nNo VE Pro changes were applied.\n\nClear ExtState MCTM/vepro_dry_run to apply.",
                        summary.would_enable,
                        summary.would_disable
                    ),
                    "MCTM VE Pro sync",
                    0
                )
            end
        end
    end
end

