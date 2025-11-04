local ctx = reaper.ImGui_CreateContext('Track Selector')
local selected_pairs = {}
local show_window = true  -- Fenster-Status

local function isRelevantTrack(track)
    local _, name = reaper.GetTrackName(track, "")
    return name:match("^%s*[AMD]%s+") ~= nil
end

local function getPairName(track)
    local _, name = reaper.GetTrackName(track, "")
    -- alle führenden Prefixes D/A/M entfernen
    local prefixes = {"D ", "A ", "M "}
    local changed = true
    while changed do
        changed = false
        for _, p in ipairs(prefixes) do
            if name:sub(1, #p) == p then
                name = name:sub(#p + 1)
                changed = true
                break
            end
        end
    end
    return name
end

local function getTrackPairs()
    local pairs = {}
    local seen = {}
    for i = 0, reaper.CountTracks(0)-1 do
        local track = reaper.GetTrack(0, i)
        if isRelevantTrack(track) then
            local pairName = getPairName(track)
            if not seen[pairName] then
                table.insert(pairs, pairName)
                seen[pairName] = true
            end
        end
    end
    return pairs
end

function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 300, 400, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, 'Track Selector', show_window)
    show_window = open -- Fenster-Flag aktualisieren

    if visible then
        local pairs = getTrackPairs()

        if reaper.ImGui_Button(ctx, "Select All") then
            for _, p in ipairs(pairs) do selected_pairs[p] = true end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Deselect All") then
            for _, p in ipairs(pairs) do selected_pairs[p] = false end
        end

        reaper.ImGui_Separator(ctx)

        for _, p in ipairs(pairs) do
            local checked = selected_pairs[p] or false
            local changed, new_state = reaper.ImGui_Checkbox(ctx, p, checked)
            if changed then
                selected_pairs[p] = new_state
            end
        end

        reaper.ImGui_End(ctx)
    end

    if show_window then
        reaper.defer(loop)
    end
end

loop()
