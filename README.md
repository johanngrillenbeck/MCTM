# Media Composer Template Manager (MCTM)

MCTM is a collection of Reaper scripts designed to make working with large orchestral templates easier.

## Design Philosophy
1. Use CSV files as a single source of truth for template creation.
2. Store track type and status in a prefix that is human readable and can influence script logic. 
3. Be interoperable with other community scripts (e.g. Reaticulate).

### Prefix Overview

- `CTRL`: Track that hosts something like a VEPro instance (VSTi). Routed to and from a CTRL track are tracks with the prefixes
    - `A`: Audio track -> shown only in Mixer by default but can be shown in TCP via script (e.g. when you have bounced MIDI to Audio)
    - `M`: MIDI track -> never shown in Mixer
- `N`: Native track (VSTi hosted on an FX slot in Reaper -> traditional setup without using VEpro)
- `D`: Disabled track (ignored by the MCTM scripts, such as "show all M tracks")
- My CURSE script collection already introduces the following prefixes, which MCTM also relies on:
    - `B`: Bus track (instrument groups for STEM-Export)
    - `FX`: Send FX track (ideally routed to the same Bus as the source track to keep STEM export tidy)

### Why even bother with Prefixes?
- Reaper does not distinguish between track types. In other DAWs, there are "Instrument" tracks (for VSTi), Send FX tracks, Bus tracks, and so on.
- This behavior of Reaper is actually great, because it's flexible. But this script collection was born out of a frustration that arises once you try to pair Reaper (or any DAW for that matter!) with Vienna Ensemble: The track count explodes! For VEpro in Reaper, we need a Midi Track to sequence and at least one return audio track per Instrument.
- So this collection aims to offer smart visibility actions to help you navigate your projects that are based on a template with a humongous track count (I have 800+ tracks).
- For this to work, we need to store the type and status of a track in a format that is both human readable and script-logic-ready. Introducing: Prefixes.
- For VEpro specifically: each virtual instrument exists as a group of tracks: one or more audio tracks and one MIDI track. The `D` prefix tells the system that the user does not need that track pair; display/filter functions ignore such tracks. There is a script that allows you to "disable" a track. This hides it from view and applies the D Prefix.
- Same goes for tracks that the user designates FX Sends and Busses.
- Same goes for the occasional "native" track ("N" prefix: a VSTi where Midi Sequencing and Audio return from the plugin should live on the same track). This allows us e.g. to use the same script to freeze a track for a complex multitrack VEpro Instrument (e.g. Drums with multiple return audio tracks) and a simple VSTi that lives directly on a track. Just one keyboard shortcut to memorize, and it should also handle all types of "multi-selections" so you can freeze tracks in parallel, which Reaper allows to be very fast, because it is able to render in parallel.

# Included scripts
note: for easier reading the `jg_MCTM_` prefix and filename (.lua) are ommited.

## Building your template

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

This script is required for other scripts to work. It is not present in the action list.

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

Update May 2026: Maybe the issue was Reaper's "Flush FX on start", which is activated by default for all VSTis and has to be disabled in each plugin's compatibility options.

### Toggle VEPro Activation depending on D Prefix
Due to VEpro tending to crash when activating many instruments at once via envelopes, I will not develop this further until I have tried VEpro 8.

Update May 2026: Maybe the issue was Reaper's "Flush FX on start", which is activated by default for all VSTis and has to be disabled in each plugin's compatibility options.