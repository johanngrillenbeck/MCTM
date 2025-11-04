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

-- Hilfsfunktion: Trackname ohne Präfix (A/M/D)
local function getTrackBaseName(trackName)
    return trackName:gsub("^[ADMd ]+ ", "")
end

-- Hilfsfunktion: Envelope-Name ohne Index und /Disable
local function getEnvelopeBaseName(envName)
    local name = envName:match("^%d+%s+(.+)/Disable")
    return name or ""
end

-- Zielwert abhängig vom Track-Prefix
local function getTargetValue(trackName)
    if trackName:match("^D ") then
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
dbg("Ausgewählte Tracks: " .. selTrackCount)

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
    dbg(string.format("Track %d: '%s' → BaseName: '%s', Zielwert: %d", i+1, trackName, baseName, selBaseNames[baseName]))
end

-- Alle CTRL-Tracks durchsuchen
local trackCount = reaper.CountTracks(0)
dbg("Alle Tracks im Projekt: " .. trackCount)

for i = 0, trackCount-1 do
    local ctrlTrack = reaper.GetTrack(0, i)
    local _, ctrlTrackName = reaper.GetTrackName(ctrlTrack)
    if ctrlTrackName:match("^CTRL") then
        dbg("CTRL-Track gefunden: " .. ctrlTrackName)

        local envCount = reaper.CountTrackEnvelopes(ctrlTrack)
        for e = 0, envCount-1 do
            local env = reaper.GetTrackEnvelope(ctrlTrack, e)
            local _, envName = reaper.GetEnvelopeName(env, "")
            
            -- Nur /Disable Envelopes
            if envName:find("/Disable") then
                local envBaseName = getEnvelopeBaseName(envName)
                local targetVal = selBaseNames[envBaseName]
                
                if targetVal ~= nil then
                    dbg(string.format("  Envelope '%s' → BaseName: '%s' | Zielwert: %d", envName, envBaseName, targetVal))
                    -- Punkte löschen und Anfangspunkt setzen
                    reaper.DeleteEnvelopePointRange(env, 0, reaper.GetProjectLength())
                    reaper.InsertEnvelopePoint(env, 0, targetVal, 0, 0, false, true)
                    reaper.Envelope_SortPoints(env)
                    dbg("    Envelope gesetzt.")
                else
                    dbg(string.format("  Envelope '%s' hat keinen passenden Track.", envName))
                end
            end
        end
    end
end

reaper.UpdateArrange()
dbg("Script beendet.")

