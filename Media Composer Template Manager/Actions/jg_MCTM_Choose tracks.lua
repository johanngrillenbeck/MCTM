local ctx = reaper.ImGui_CreateContext('Track Selector')

local SCRIPT_DIR = nil

local function add_script_dir_to_package_path()
    local info = debug.getinfo(1, 'S')
    if not info or not info.source then return end
    local source = info.source
    local script_dir = source:match("@?(.*[\\/])")
    if not script_dir then return end
    SCRIPT_DIR = script_dir
    local pattern1 = script_dir .. "?.lua;"
    local pattern2 = script_dir .. "?/init.lua;"
    package.path = pattern1 .. pattern2 .. package.path
end
add_script_dir_to_package_path()

local ok, mctm = pcall(require, "jg_MCTM_helper")
if not ok or not mctm then reaper.ShowConsoleMsg("Could not require 'jg_MCTM_helper': " .. tostring(mctm) .. "\n") return end
local selected_groups = {}
local show_window = true  -- Fenster-Status
local last_routing_error_fingerprint = nil

local function trim(s)
    return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or ""
end

local function canonical_name(name)
    return trim(name):lower()
end

-- Track Group detection (supports multi-audio child A tracks)
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

    -- Multi-audio child A tracks are named like: "<child> (<LIB PARENT>)"
    -- Use the inside parentheses as group key only if a matching MIDI base exists.
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

local function isRelevantTrack(track)
    local _, name = reaper.GetTrackName(track)
    local parsed = mctm.parse(name)
    -- relevant if it has an A, M or D prefix
    return mctm.is_audio(parsed) or mctm.is_midi(parsed) or mctm.is_disabled(parsed)
end

local function getTrackNameSafe(track)
    if not track then return "" end
    local _, name = reaper.GetTrackName(track)
    return name or ""
end

local function getTrackNumberSafe(track)
    if not track then return 0 end
    -- IP_TRACKNUMBER: 1-based track index
    local n = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    return tonumber(n) or 0
end

local function parseTrack(track)
    local name = getTrackNameSafe(track)
    local parsed = mctm.parse(name)
    return name, parsed
end

local function isBusTrack(track)
    local _, parsed = parseTrack(track)
    return (not mctm.is_audio(parsed))
        and (not mctm.is_midi(parsed))
        and (not mctm.is_ctrl(parsed))
        and (not mctm.is_disabled(parsed))
end

local function getBusForAudioTrack(audio_track)
    -- Repo convention:
    -- - busses are tracks without A/M/CTRL prefixes
    -- - bus association is inferred by presence of receiving audio from A tracks
    -- Implementation:
    -- - consider any audio send destination bus-track
    -- - also consider folder parent (P_PARTRACK) if it's a bus-track
    -- - if multiple unique bus-tracks found -> error
    if not audio_track then return nil, nil end

    local bus_set = {}
    local function add_bus_candidate(bus_tr)
        if bus_tr and bus_tr ~= 0 and isBusTrack(bus_tr) then
            bus_set[bus_tr] = true
        end
    end

    local nsends = reaper.GetTrackNumSends(audio_track, 0)
    for s = 0, (nsends or 0) - 1 do
        local srcchan = reaper.GetTrackSendInfo_Value(audio_track, 0, s, "I_SRCCHAN")
        -- only consider sends that carry audio
        if srcchan and srcchan ~= -1 then
            local dest = reaper.GetTrackSendInfo_Value(audio_track, 0, s, "P_DESTTRACK")
            add_bus_candidate(dest)
        end
    end

    local parent = reaper.GetMediaTrackInfo_Value(audio_track, "P_PARTRACK")
    add_bus_candidate(parent)

    local bus_list = {}
    for tr,_ in pairs(bus_set) do
        table.insert(bus_list, tr)
    end

    if #bus_list > 1 then
        table.sort(bus_list, function(a, b)
            return getTrackNumberSafe(a) < getTrackNumberSafe(b)
        end)
        local names = {}
        for _,tr in ipairs(bus_list) do
            table.insert(names, getTrackNameSafe(tr))
        end
        local a_name = getTrackNameSafe(audio_track)
        return nil, string.format("Audio track '%s' routes to multiple busses: %s", a_name, table.concat(names, ", "))
    end

    if #bus_list == 1 then
        return bus_list[1], nil
    end

    return nil, nil
end

local function getTrackGroups()
    -- returns:
    -- - ordered list of canonical group keys
    -- - groups map keyed by canonical group name
    local order = {}
    local groups = {}

    local midi_bases = build_midi_base_set()

    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if isRelevantTrack(track) then
            local _, parsed = parseTrack(track)
            if parsed and (mctm.is_audio(parsed) or mctm.is_midi(parsed)) then
                local group_name = group_key_from_parsed(parsed, midi_bases)
                local key = canonical_name(group_name)
                if key ~= "" then
                    local entry = groups[key]
                    if not entry then
                        entry = {
                            key = key,
                            name = group_name,
                            audio_tracks = {},
                            midi_track = nil,
                            disabled = false,
                        }
                        groups[key] = entry
                        table.insert(order, key)
                    end

                    if mctm.is_audio(parsed) then
                        table.insert(entry.audio_tracks, track)
                    end
                    if mctm.is_midi(parsed) then
                        -- Prefer first MIDI track found for this group
                        if not entry.midi_track then entry.midi_track = track end
                    end
                    if mctm.is_disabled(parsed) then entry.disabled = true end
                end
            end
        end
    end

    table.sort(order, function(a, b)
        return (groups[a].name or a):lower() < (groups[b].name or b):lower()
    end)

    return order, groups
end

local function getBusForGroup(group)
    if not group or not group.audio_tracks or #group.audio_tracks == 0 then
        return nil, nil
    end
    local bus = nil
    for _, atr in ipairs(group.audio_tracks) do
        local b, err = getBusForAudioTrack(atr)
        if err then return nil, err end
        if b then
            if not bus then
                bus = b
            elseif bus ~= b then
                local gname = tostring(group.name or group.key)
                return nil, string.format("Group '%s' routes to multiple busses (multi-audio mismatch).", gname)
            end
        end
    end
    return bus, nil
end

local function getDesiredChecked(key, group)
    local v = selected_groups[key]
    if v == nil then
        return not (group and group.disabled)
    end
    return v
end

local function unselectAllTracks()
    -- 40297: Unselect all tracks
    reaper.Main_OnCommand(40297, 0)
end

local function selectTracks(tracks)
    unselectAllTracks()
    for _, tr in ipairs(tracks or {}) do
        if tr then
            reaper.SetTrackSelected(tr, true)
        end
    end
end

local function dofile_in_script_dir(filename)
    if not SCRIPT_DIR then
        return false, "Could not determine SCRIPT_DIR"
    end
    local path = SCRIPT_DIR .. filename
    local ok, err = pcall(dofile, path)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 300, 400, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, 'Track Selector', show_window)
    show_window = open -- Fenster-Flag aktualisieren

    if visible then
        local group_order, group_map = getTrackGroups()

        -- Build bus groups
        local bus_groups = {}
        local bus_order = {}
        local routing_errors = {}

        local function ensure_bus_group(bus_key)
            if not bus_groups[bus_key] then
                bus_groups[bus_key] = { key = bus_key, items = {} }
                table.insert(bus_order, bus_key)
            end
            return bus_groups[bus_key]
        end

        for _, key in ipairs(group_order) do
            local group_entry = group_map[key]
            local bus_track, err = nil, nil
            if group_entry then
                bus_track, err = getBusForGroup(group_entry)
            end

            if err then
                table.insert(routing_errors, err)
            end

            local bus_key
            if bus_track then
                bus_key = "BUS:" .. tostring(bus_track)
                local group = ensure_bus_group(bus_key)
                group.bus_track = bus_track
                group.bus_name = getTrackNameSafe(bus_track)
                group.bus_index = getTrackNumberSafe(bus_track)
                table.insert(group.items, key)
            else
                bus_key = "UNROUTED"
                local group = ensure_bus_group(bus_key)
                group.bus_track = nil
                group.bus_name = "Unrouted"
                group.bus_index = 1e9
                table.insert(group.items, key)
            end
        end

        table.sort(bus_order, function(a, b)
            local ga, gb = bus_groups[a], bus_groups[b]
            local ia, ib = (ga and ga.bus_index) or 1e9, (gb and gb.bus_index) or 1e9
            if ia ~= ib then return ia < ib end
            return (ga.bus_name or a):lower() < (gb.bus_name or b):lower()
        end)

        for _, bus_key in ipairs(bus_order) do
            local group = bus_groups[bus_key]
            if group and group.items then
                table.sort(group.items, function(a, b)
                    local ga, gb = group_map[a], group_map[b]
                    return (ga and ga.name or a):lower() < (gb and gb.name or b):lower()
                end)
            end
        end

        if reaper.ImGui_Button(ctx, "Select All") then
            for _, key in ipairs(group_order) do selected_groups[key] = true end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Deselect All") then
            for _, key in ipairs(group_order) do selected_groups[key] = false end
        end

        reaper.ImGui_SameLine(ctx)

        -- green Apply Selection button
        local apply_clicked = false
        local push_ok = type(reaper.ImGui_PushStyleColor) == "function"
            and type(reaper.ImGui_PopStyleColor) == "function"
            and type(reaper.ImGui_ColorConvertDouble4ToU32) == "function"
            and type(reaper.ImGui_Col_Button) == "function"
            and type(reaper.ImGui_Col_ButtonHovered) == "function"
            and type(reaper.ImGui_Col_ButtonActive) == "function"
        if push_ok then
            local col_btn = reaper.ImGui_ColorConvertDouble4ToU32(0.20, 0.70, 0.20, 1.00)
            local col_hov = reaper.ImGui_ColorConvertDouble4ToU32(0.25, 0.80, 0.25, 1.00)
            local col_act = reaper.ImGui_ColorConvertDouble4ToU32(0.18, 0.60, 0.18, 1.00)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), col_btn)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_hov)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), col_act)
        end
        apply_clicked = reaper.ImGui_Button(ctx, "Apply Selection")
        if push_ok then
            reaper.ImGui_PopStyleColor(ctx, 3)
        end

        reaper.ImGui_Separator(ctx)

        if apply_clicked then
            if #routing_errors > 0 then
                reaper.MB("Routing error(s) detected. Fix routing before applying selection.", "MCTM", 0)
            else
                local to_disable = {}
                local to_enable = {}
                local final_m_selection = {}
                local changed_set = {}
                local changed_tracks = {}

                for _, key in ipairs(group_order) do
                    local grp = group_map[key]
                    local desired = getDesiredChecked(key, grp)

                    if desired and grp and grp.midi_track then
                        table.insert(final_m_selection, grp.midi_track)
                    end

                    if grp then
                        local any_track = grp.midi_track or (grp.audio_tracks and grp.audio_tracks[1])
                        if (not desired) and (not grp.disabled) then
                            if any_track then table.insert(to_disable, any_track) end
                            if any_track and not changed_set[any_track] then changed_set[any_track] = true; table.insert(changed_tracks, any_track) end
                        elseif desired and grp.disabled then
                            if any_track then table.insert(to_enable, any_track) end
                            if any_track and not changed_set[any_track] then changed_set[any_track] = true; table.insert(changed_tracks, any_track) end
                        end
                    end
                end

                local toggle_script = "jg_MCTM_Toggle D Prefix and Visibility for Track Pair.lua"
                local vepro_script = "jg_MCTM_Toggle VEPro Activation depending on D Prefix.lua"

                local failed = false
                local fail_msg = nil

                reaper.Undo_BeginBlock()
                reaper.PreventUIRefresh(1)

                repeat
                    if #to_disable > 0 then
                        selectTracks(to_disable)
                        local ok, err = dofile_in_script_dir(toggle_script)
                        if not ok then
                            failed = true
                            fail_msg = "Failed running: " .. toggle_script .. "\n" .. tostring(err)
                            break
                        end
                    end

                    if #to_enable > 0 then
                        selectTracks(to_enable)
                        local ok, err = dofile_in_script_dir(toggle_script)
                        if not ok then
                            failed = true
                            fail_msg = "Failed running: " .. toggle_script .. "\n" .. tostring(err)
                            break
                        end
                    end

                    -- Update VEPro state for affected instruments (or for current enabled selection if nothing changed)
                    if #changed_tracks > 0 then
                        selectTracks(changed_tracks)
                    else
                        selectTracks(final_m_selection)
                    end

                    do
                        local ok, err = dofile_in_script_dir(vepro_script)
                        if not ok then
                            failed = true
                            fail_msg = "Failed running: " .. vepro_script .. "\n" .. tostring(err)
                            break
                        end
                    end

                    -- Final selection: M tracks for checked instruments
                    selectTracks(final_m_selection)
                until true

                reaper.TrackList_AdjustWindows(false)
                reaper.PreventUIRefresh(-1)
                reaper.Undo_EndBlock(failed and "MCTM Apply Selection (failed)" or "MCTM Apply Selection", -1)

                if failed and fail_msg then
                    reaper.MB(fail_msg, "MCTM", 0)
                end
            end
        end

        if #routing_errors > 0 then
            reaper.ImGui_Text(ctx, "Routing error(s) detected. Fix routing and run again:")
            for _, msg in ipairs(routing_errors) do
                reaper.ImGui_TextWrapped(ctx, msg)
            end

            -- also log to console for copy/paste (but avoid spamming every frame)
            local fingerprint = table.concat(routing_errors, "\n")
            if fingerprint ~= last_routing_error_fingerprint then
                last_routing_error_fingerprint = fingerprint
                reaper.ShowConsoleMsg("\n[MCTM Choose Tracks] Routing error(s):\n")
                for _, msg in ipairs(routing_errors) do
                    reaper.ShowConsoleMsg("- " .. msg .. "\n")
                end
            end
        else
            last_routing_error_fingerprint = nil
            for _, bus_key in ipairs(bus_order) do
                local group = bus_groups[bus_key]
                if group then
                    reaper.ImGui_Text(ctx, group.bus_name or "")
                    if reaper.ImGui_Indent then reaper.ImGui_Indent(ctx, 12) end
                    for _, key in ipairs(group.items or {}) do
                        local grp = group_map[key]
                        local label = ((grp and grp.name) or key) .. "##" .. key
                        local checked = getDesiredChecked(key, grp)
                        local changed, new_state = reaper.ImGui_Checkbox(ctx, label, checked)
                        if changed then
                            selected_groups[key] = new_state
                        end
                    end
                    if reaper.ImGui_Indent then reaper.ImGui_Unindent(ctx, 12) end
                    reaper.ImGui_Separator(ctx)
                end
            end
        end

        reaper.ImGui_End(ctx)
    end

    if show_window then
        reaper.defer(loop)
    end
end

loop()
