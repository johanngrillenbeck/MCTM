--[[
@description jg_MCTM_Deactivate in VEPro via VST Instance Track Envelope (Final Corrected)
@version 3.0
@about
  Setzt den VEPro "/Disable" Envelope für ausgewählte Tracks direkt.
  Behandelt Track-Paare korrekt (D priorisiert) und durchsucht alle CTRL-Tracks.
  Debug-Messages zeigen nur relevante Envelopes.
--]]

reaper.ClearConsole()
local function dbg(msg)
    reaper.ShowConsoleMsg(msg .. "\n")
end

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

-- Hilfsfunktion: Trackname ohne Präfix (A/M/D)
local function getTrackBaseName(trackName)
    return mctm.parse(trackName).name
end

-- Hilfsfunktion: Envelope-Name ohne Index und /Disable
local function trim(s)
    return (s:gsub("^%s+",""):gsub("%s+$",""))
end

local function getEnvelopeBaseName(envName)
    if not envName then return "" end
    -- Try to capture after a leading index (e.g. '1 Name / Disable'), allowing spaces around '/'
    local name = envName:match("^%d+%s*(.-)%s*/%s*Disable")
    if not name then
        -- Fallback: capture anything before '/Disable'
        name = envName:match("(.-)%s*/%s*Disable")
    end
    if name then
        return trim(name)
    end
    return ""
end

-- Zielwert abhängig vom Track-Prefix
-- Zielwert abhängig vom Track-Prefix
local function getTargetValue(trackName)
    local parsed = mctm.parse(trackName)
    if mctm.is_disabled(parsed) then
        return 1
    else
        return 0
    end
end

-- Prüfen, ob Tracks ausgewählt sind
local selTrackCount = reaper.CountSelectedTracks(0)
if selTrackCount == 0 then
    reaper.ShowMessageBox("Keine Tracks ausgewählt!", "Fehler", 0)
    return
end
-- dbg("Ausgewählte Tracks: " .. selTrackCount)

-- Track-Paar-Handling: Basisname → Zielwert (D priorisiert)
local selBaseNames = {}
for i = 0, selTrackCount-1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, trackName = reaper.GetTrackName(track)
    local baseName = getTrackBaseName(trackName)
    local targetVal = getTargetValue(trackName)

    if selBaseNames[baseName] == nil then
        selBaseNames[baseName] = targetVal
    else
        -- D Tracks priorisieren
        if targetVal == 1 then selBaseNames[baseName] = 1 end
    end
    -- dbg(string.format("Track %d: '%s' → BaseName: '%s', Zielwert: %d", i+1, trackName, baseName, selBaseNames[baseName]))
end

-- Alle CTRL-Tracks durchsuchen
local trackCount = reaper.CountTracks(0)
-- dbg("Alle Tracks im Projekt: " .. trackCount)

for i = 0, trackCount-1 do
    local ctrlTrack = reaper.GetTrack(0, i)
    local _, ctrlTrackName = reaper.GetTrackName(ctrlTrack)
    if ctrlTrackName:match("^CTRL") then
        -- dbg("CTRL-Track gefunden: " .. ctrlTrackName)

        local envCount = reaper.CountTrackEnvelopes(ctrlTrack)
        for e = 0, envCount-1 do
            local env = reaper.GetTrackEnvelope(ctrlTrack, e)
            -- GetEnvelopeName may return its result in different positions depending on build; handle gracefully
            local n1, n2 = reaper.GetEnvelopeName(env)
            local envName = ""
            if type(n1) == "string" then envName = n1
            elseif type(n2) == "string" then envName = n2 end
            
            -- Nur /Disable Envelopes
            if envName:find("/Disable") then
                local envBaseName = getEnvelopeBaseName(envName)
                local targetVal = selBaseNames[envBaseName]
                
                if targetVal ~= nil then
                    -- dbg(string.format("  Envelope '%s' → BaseName: '%s' | Zielwert: %d", envName, envBaseName, targetVal))
                    -- Punkte löschen und Dreieck-/Ramp-Punkte innerhalb der ersten Sekunde setzen
                    reaper.DeleteEnvelopePointRange(env, 0, reaper.GetProjectLength())
                    if targetVal == 1 then
                        -- Deactivate: ramp up from 0 -> 0.75 -> 1 over 0..0.5..1s
                        reaper.InsertEnvelopePoint(env, 0.0, 0.0, 0, 0, false, true)
                        reaper.InsertEnvelopePoint(env, 0.5, 0.75, 0, 0, false, true)
                        reaper.InsertEnvelopePoint(env, 1.0, 1.0, 0, 0, false, true)
                    else
                        -- Activate: small bump 0 -> 0.25 -> 0 over 0..0.5..1s
                        reaper.InsertEnvelopePoint(env, 0.0, 0.0, 0, 0, false, true)
                        reaper.InsertEnvelopePoint(env, 0.5, 0.25, 0, 0, false, true)
                        reaper.InsertEnvelopePoint(env, 1.0, 0.0, 0, 0, false, true)
                    end
                    reaper.Envelope_SortPoints(env)
                    -- dbg("    Envelope gesetzt (triangle ramp).")
                else
                    -- dbg(string.format("  Envelope '%s' hat keinen passenden Track.", envName))
                end
            end
        end
    end
end

reaper.UpdateArrange()
-- dbg("Script beendet.")

