--[[
Reaper Lua Script: Stable toggle 'D ' prefix and visibility for A/M track pairs
Author: JG and ChatGPT
--]]

reaper.Undo_BeginBlock()

local function stripDeactivatedPrefix(name)
    -- Entfernt führendes "D " falls vorhanden
    if name:sub(1,2) == "D " then
        return name:sub(3)
    end
    return name
end

local function getPartnerName(name)
    -- Entfernt ggf. D Präfix vor Verarbeitung
    local baseName = stripDeactivatedPrefix(name)
    if baseName:sub(1,2) == "A " then
        return "M " .. baseName:sub(3)
    elseif baseName:sub(1,2) == "M " then
        return "A " .. baseName:sub(3)
    end
    return nil
end

local function hasPrefix(name, prefix)
    return name:sub(1, #prefix) == prefix
end

local function findTrackByName(searchName)
    -- sucht exakt nach Trackname (case-sensitive), ignoriert "D " Präfix beim Vergleich
    local strippedSearch = stripDeactivatedPrefix(searchName)
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, trName = reaper.GetTrackName(tr, "")
        if stripDeactivatedPrefix(trName) == strippedSearch then
            return tr
        end
    end
    return nil
end

-- Sammle Tracks zur Verarbeitung (ausgewählte + deren Partner)
local selCount = reaper.CountSelectedTracks(0)
local tracksToProcess = {}

for i = 0, selCount - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    local partnerName = getPartnerName(name)

    tracksToProcess[track] = name
    if partnerName then
        local partnerTrack = findTrackByName(partnerName)
        if partnerTrack then
            tracksToProcess[partnerTrack] = ({reaper.GetTrackName(partnerTrack, "")})[2]
        end
    end
end

-- Bestimme, ob deaktiviert oder reaktiviert werden soll
local deactivate = false
for track, name in pairs(tracksToProcess) do
    if not hasPrefix(name, "D ") then
        deactivate = true
        break
    end
end

-- Anwenden des Toggles
for track, name in pairs(tracksToProcess) do
    if deactivate then
        -- Add 'D ' prefix wenn nicht vorhanden
        if not hasPrefix(name, "D ") then
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "D " .. name, true)
        end
        -- Verstecken in TCP und MCP
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
    else
        -- Entferne 'D ' prefix falls vorhanden
        if hasPrefix(name, "D ") then
            name = name:sub(3)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
        end
        -- Sichtbarkeit abhängig vom Typ
        if name:sub(1,2) == "M " then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
        elseif name:sub(1,2) == "A " then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
        end
    end
end

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Toggle 'D ' prefix and visibility (stable)", -1)

