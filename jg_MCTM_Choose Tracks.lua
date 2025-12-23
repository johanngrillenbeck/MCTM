local ctx = reaper.ImGui_CreateContext('Track Selector')

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
local selected_pairs = {}
local show_window = true  -- Fenster-Status
local last_routing_error_fingerprint = nil

local function trim(s)
    return (s and s:gsub("^%s+", ""):gsub("%s+$", "")) or ""
end

local function canonical_name(name)
    return trim(name):lower()
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

local function getTrackPairs()
    -- returns:
    -- - ordered list of canonical keys
    -- - pairs map keyed by canonical instrument name
    local order = {}
    local pairs = {}

    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if isRelevantTrack(track) then
            local _, parsed = parseTrack(track)
            local key = canonical_name(parsed.name)
            if key ~= "" then
                local entry = pairs[key]
                if not entry then
                    entry = {
                        key = key,
                        name = parsed.name,
                        audio_track = nil,
                        midi_track = nil,
                    }
                    pairs[key] = entry
                    table.insert(order, key)
                end
                if mctm.is_audio(parsed) then entry.audio_track = track end
                if mctm.is_midi(parsed) then entry.midi_track = track end
            end
        end
    end

    table.sort(order, function(a, b)
        return (pairs[a].name or a):lower() < (pairs[b].name or b):lower()
    end)

    return order, pairs
end

function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 300, 400, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, 'Track Selector', show_window)
    show_window = open -- Fenster-Flag aktualisieren

    if visible then
        local pair_order, pair_map = getTrackPairs()

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

        for _, key in ipairs(pair_order) do
            local pair = pair_map[key]
            local bus_track, err = nil, nil
            if pair and pair.audio_track then
                bus_track, err = getBusForAudioTrack(pair.audio_track)
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
                    local pa, pb = pair_map[a], pair_map[b]
                    return (pa and pa.name or a):lower() < (pb and pb.name or b):lower()
                end)
            end
        end

        if reaper.ImGui_Button(ctx, "Select All") then
            for _, key in ipairs(pair_order) do selected_pairs[key] = true end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Deselect All") then
            for _, key in ipairs(pair_order) do selected_pairs[key] = false end
        end

        reaper.ImGui_Separator(ctx)

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
                        local pair = pair_map[key]
                        local label = ((pair and pair.name) or key) .. "##" .. key
                        local checked = selected_pairs[key] or false
                        local changed, new_state = reaper.ImGui_Checkbox(ctx, label, checked)
                        if changed then
                            selected_pairs[key] = new_state
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
