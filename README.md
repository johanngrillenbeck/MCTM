# Media Composer Template Manager (MCTM)

MCTM is a collection of Reaper scripts designed to make working with large orchestral templates easier.

## Design Philosophy

### Instruments
- Reaper does not distinguish between Audio and MIDI tracks. We need a Midi Track and Audio Track(s) per Instrument, so:
- Every track gets *prefixes* (A and M) so the status of a track is stored in a human-readable format.

Each virtual instrument exists as a pairing of tracks: one or more audio tracks and one MIDI track. The `D` prefix tells the system that the user does not need that track pair; display/filter functions ignore such tracks. There is a script that allows you to "disable" a track. This hides it from view and applies the D Prefix.

### FX and Bus Tracks
- Same goes for tracks that the user designates FX Sends and Busses. 

### Prefix Overview

- `A` : Audio track -> shown only in Mixer by default but can be shown in TCP via script (e.g. when you have bounced MIDI to Audio)
- `M` : MIDI track -> never shown in Mixer
- `D` : Disabled track (ignored by the system)
- `CTRL` : Track that hosts something like a VEPro instance (VSTi)


# Included scripts
note: for easier reading the `jg_MCTM_` prefix and filename (.lua) are ommited.

## Building your template

### Recieve from CTRL - ascending quad audio no midi
Route audio from a selected CTRL track into selected audio tracks using ascending quad channel groups; does not route MIDI.

### Send to CTRL - ascending MIDI busses no audio
Route MIDI from selected tracks into a selected CTRL track using ascending MIDI busses; audio routing is disabled.

### Build tracks from CSV
Create project tracks from the CSV template, naming them and setting up MIDI/audio group structure.

### Build Reabank from CSV
Generate a Reaticulate .reabank file from the CSV template for importing articulations and keyswitches.

## Using your template

### Choose Tracks
Choose your instruments in a more comfortable way compared to the track manager.
Instruments are grouped by Bus they are routed to.
Select the instruments and `apply selection`.

### Toggle D Prefix and Visibility for track pair
Best used as a shortcut in your main toolbar to deactivate a track group.
You only have to select one track of the group, it will toggle activation and visibility for all of them.

### Toggle Track Pair Visibility
Toggle TCP visibility for MIDI/audio instrument pair to bring up the one that is currently hidden from the pair or hide the one that is selected.

### Toggle TCP Visibility A
Toggle TCP visibility for all audio (`A`) tracks in the project to quickly declutter the track list.

### Toggle TCP Visibility M
Toggle TCP visibility for all MIDI (`M`) tracks in the project to quickly declutter the track list.

## Helper script

This script is required for other scripts to work. You would not execute it from Reaper directly.

Key functions (brief):

- `parse(label)` -> { prefixes = {...}, name = "..." }
- `findPairs(tracks, opts)` -> table with key = canonical name -> { name=..., audio=label?, midi=label?, ctrl=label?, disabled=bool }
- `is_audio(parsed)`, `is_midi(parsed)`, `is_ctrl(parsed)`, `is_disabled(parsed)`
- `format_label(prefixes, name)`

Examples

1) Parsing:

- `M Violin` -> prefixes = {"M"}, name = "Violin"
- `D M Viola` -> prefixes = {"D","M"}, name = "Viola" (normally ignored)
- `CTRL VEHost` -> prefixes = {"CTRL"}, name = "VEHost"

2) findPairs:
Returns a table that, for each instrument, provides the existing track labels for audio/MIDI/CTRL and indicates whether it is `disabled`.

## currently defunct

### Set all CTRL Envelopes Active
Due to VEpro tending to crash when activating many instruments at once via envelopes, I will not develop this further until I have tried VEpro 8.

### Toggle VEPro Activation depending on D Prefix
Due to VEpro tending to crash when activating many instruments at once via envelopes, I will not develop this further until I have tried VEpro 8.