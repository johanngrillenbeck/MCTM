--[[
Reaper Lua Script: Stable toggle 'D ' prefix and visibility for A/M track pairs
Author: JG and ChatGPT
--]]

reaper.Undo_BeginBlock()

local mctm = dofile("jg_MCTM_helper.lua")

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

local function findTrackByName(searchName)
    -- finds a track by matching the base instrument name (ignores leading D)
    local searchBase = mctm.parse(searchName).name
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, trName = reaper.GetTrackName(tr, "")
        local parsed = mctm.parse(trName)
        if parsed.name == searchBase then
            return tr
        end
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

