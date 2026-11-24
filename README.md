# Media Composer Template Manager (MCTM)

MCTM is a collection of Reaper scripts designed to make working with large orchestral templates easier. It is tailored to a workflow using Vienna Ensemble Pro (VEpro) as a plugin host, which (without this proposed workflow) leads to a lot of visual clutter in Reaper due to the need of separate tracks to handle MIDI sequencing and audio return.

It is designed to be operated with stereo or four-channel (4.0) instrument-audio, since quad (Left, Right, Surround Left, Surround Right) is my preferred way of delivering a surround sound music mix to a film production.[^1]

## Design Philosophy
1. Use CSV files as a single source of truth for template creation.
2. Store track type and status in a prefix that is human readable and can influence script logic. 
3. Be interoperable with other community scripts (e.g. Reaticulate).

## State of the project

MCTM is currently under active development during my free time inbetween music projects. I actually use it on a daily basis, but I would **not** encourage adoption just yet.
I consider myself still in the research phase for the best way to set certain standards, especially when it comes to the global unified template CSV.
But if you somehow stumbled upon this now, have a read through and please do give me feedback on what you see and on how useful you imagine the functionality to be like.

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

### Why not just use the Track Manager (Ctrl + Shift + M)
- The selection you make in the Track Manager must be applied to the tracks with an additional click that cannot be scripted.
    - The track manager shows any and all tracks in the project, which might be very cluttered
	- Although I coded the scripts to work regardless of which of the track pairs you select, being shown all tracks in the track manager doubles the list of entries to be even more humongous than it already is with a huge temple
	- The custom GUI allows me to introduce usability improvements such as
		- Select all
		- Deselect all
		- Filter by instrument groups or libraries or VST Instances, etc. 
		- Apply certain commands 

## VE Pro integration

MCTM can enable and disable VE Pro channels directly through the VE Pro 8 local API. This replaces the old `/Disable` envelope automation, which was fragile and could crash VE Pro when many instruments were activated at once.

### Requirements

- Vienna Ensemble Pro 8 or newer, with the local API enabled.
- The VE Pro API CLI at `C:\ProgramData\VSL\Vienna Ensemble Pro\mcp\vepro-api-cli.exe`.
- The API reachable on `127.0.0.1:7200`.
- REAPER on Windows. The CLI invocation and default path are Windows-specific.

### How the channel is found

- Each `M` track has a MIDI send to its `CTRL` track. The send's destination bus is the same number as the VE Pro channel's `midiPort`.
- The `CTRL` track name identifies the instance: `CTRLVE1` matches `CTRLVE1 - OTBW / OTBB / ...`.
- MCTM finds the instrument-bearing channel on that `midiPort` and mutates it by `channelId`.
- Channel titles are diagnostics only. They may be renamed, drop a library prefix, abbreviate a name, or contain tabs/newlines.
- Nested folder channels such as `3[3]` are supported. The address means "child 3 of top-level channel 3". The instrument-bearing child carries the `midiPort`; folder and mic/output siblings do not.

### Enable and disable

- **Enable:** `channel/forceenable`. It un-gates ancestor folders, enables disabled buses on the output chain, and suppresses conflicting sibling instruments. Mic/output children under the same folder are left alone.
- **Disable:** `channel/patch` with `enabled=false`.
- Every write is verified by re-reading the channel by `channelId`.

### Configuration

The module reads these REAPER ExtState values from the `MCTM` section:

| Key | Default | Purpose |
|---|---|---|
| `vepro_cli` | `%ProgramData%\VSL\Vienna Ensemble Pro\mcp\vepro-api-cli.exe` | Path to the VE Pro API CLI |
| `vepro_host` | `127.0.0.1` | API host; loopback by default |
| `vepro_port` | `7200` | API port |
| `vepro_dry_run` | `0` | Set to `1` to resolve and report without writing |
| `vepro_allow_remote` | `0` | Allow a non-loopback host when set to `1` |
| `vepro_timeout_ms` | `60000` | Fallback CLI timeout for calls without an explicit timeout |

Reads use short internal timeouts. Enabling a channel uses 180 s and disabling uses 30 s. `vepro_timeout_ms` is the fallback for API calls that do not pass an explicit timeout.

Temporary dry run:

```lua
-- plan only; no VE Pro writes
reaper.SetExtState("MCTM", "vepro_dry_run", "1", true)

-- return to normal
reaper.DeleteExtState("MCTM", "vepro_dry_run", true)
```

### Security

The VE Pro API binds `0.0.0.0` and has no authentication. Keep `vepro_host` on loopback and firewall port `7200`. The module refuses non-loopback hosts unless `vepro_allow_remote=1`.

### Troubleshooting

- **Large responses are truncated through `reaper.ExecProcess`.** REAPER's stdout pipe cuts off large output at roughly 4–5 KB. The module redirects the CLI's stdout to a temporary file and reads that file instead, so the 400–700 KB routing summary is safe.
- **Channel IDs can change after a VE Pro reload.** Never persist a `channelId` across sessions. Resolve fresh from the MIDI bus each run, and use `channelId` only for the current operation.
- **Nested addresses are positional.** `3[3]` changes if you insert, reorder, or delete children of folder `3`. Do not use the address as a persistent identity.
- **`forceenable` reports side effects.** The sync report includes `ungated`, `routed`, and `suppressed` channels. Inspect it if a folder behaves unexpectedly.
- **A large Apply Selection can block REAPER.** Cold instruments may take several seconds to load. Test with a modest selection first.
- **The API is unreachable.** Check that VE Pro is running, the local API is enabled, the CLI path is correct, and port `7200` is reachable. The error message includes the failing command and the CLI's stderr.

## Included scripts

Note: for easier reading the `jg_MCTM_` prefix and `.lua` extension are omitted; headings are based on the script names but shortened where needed.

## Building your template

### Build tracks from CSV
Create project tracks from the CSV template, naming them and setting up MIDI/audio group structure.

### Build Reabank from CSV
Generate a Reaticulate .reabank file from the CSV template for importing articulations and keyswitches.

### Patch Reaticulate Reabank with custom Reabank
Merge the generated Reabank with a custom Reabank file so custom articulations survive regeneration.

## Using your template

### Choose Tracks
Choose your instruments in a more comfortable way compared to the track manager.
Instruments are grouped by Bus they are routed to.
Select the instruments and `apply selection`.

Apply Selection also reconciles the corresponding VE Pro channels:

- checked groups are enabled,
- unchecked groups are disabled,
- already-correct channels are left alone.

The VE Pro work happens after the REAPER undo block and UI freeze, so track changes remain undoable and are not mixed with external state.

### Toggle D Prefix and Visibility for track pair
Best used as a shortcut in your main toolbar to deactivate a track group.
You only have to select one track of the group, it will toggle activation and visibility for all of them.
It also enables or disables the corresponding VE Pro channel for the selected groups.

### Freeze M to A
Freeze the audio track(s) of the selected group(s), mute and lock the MIDI items, hide the `M` track, and show the `A` track in the TCP.

### Unfreeze A and restore M
Reverse the freeze: unfreeze the audio track(s), unmute and unlock the MIDI items, hide the `A` track, and show the `M` track in the TCP.

### Toggle Track Pair Visibility
Toggle TCP visibility for MIDI/audio instrument pair to bring up the one that is currently hidden from the pair or hide the one that is selected.

### Toggle TCP Visibility A
Toggle TCP visibility for all audio (`A`) tracks in the project to quickly declutter the track list.

### Toggle TCP Visibility M
Toggle TCP visibility for all MIDI (`M`) tracks in the project to quickly declutter the track list.

## VE Pro tools

### VEPro selftest
Read-only diagnostic. Scans every `M` track and resolves its VE Pro instance, MIDI bus, instrument channel, title, and enabled state. It reports confidence classes such as `MATCH`, `PREFIX-DROPPED`, `RENAMED`, `NO_SEND`, `NO_CHANNEL`, and `AMBIGUOUS_CHANNEL`.

Use it before trusting a new template or after major VE Pro changes. It writes a TSV to:

`<REAPER resource>\Scripts\jg_MCTM_vepro_selftest.tsv`

### VEPro sync selected
Select one or more `M` tracks. The action shows a dry-run plan, asks for confirmation, then enables channels for `M` tracks and disables channels for `D M` tracks. It writes a TSV to:

`<REAPER resource>\Scripts\jg_MCTM_vepro_sync_test.tsv`

This is also useful as a maintenance action after a crash or a project reload. `Choose Tracks` and the `D` prefix shortcut perform the same sync automatically.

## Routing utilities

### Send to CTRL
Route selected tracks' MIDI to a chosen `CTRL` track on ascending MIDI busses. Audio sends are disabled. Optionally removes existing MIDI sends first.

### Recieve from CTRL
Route audio from a chosen `CTRL` track to the selected `A` tracks in ascending quad groups. Each destination receives four channels; MIDI is disabled on these sends.

## Helper scripts

These scripts are required and are not present in the action list.

### `jg_MCTM_Helper.lua`
Track parsing, identification, and group logic.

Key functions:

- `parse(label)` -> { prefixes = {...}, name = "..." }
- `findPairs(tracks, opts)` -> table with key = canonical name -> { name=..., audio=label?, midi=label?, ctrl=label?, disabled=bool }
- `is_audio(parsed)`, `is_midi(parsed)`, `is_ctrl(parsed)`, `is_disabled(parsed)`
- `format_label(prefixes, name)`

Examples:

1) Parsing:

- `M Violin` -> prefixes = {"M"}, name = "Violin"
- `D M Viola` -> prefixes = {"D","M"}, name = "Viola" (normally ignored)
- `CTRL VEHost` -> prefixes = {"CTRL"}, name = "VEHost"

2) findPairs:
Returns a table that, for each instrument, provides the existing track labels for audio/MIDI/CTRL and indicates whether it is `disabled`.

### `jg_MCTM_VEPro.lua`

VE Pro API client, resolver, and state sync.

Key functions:

- `probe()` -> CLI path, host/port, API version
- `resolve(midi_track, base_name)` -> instance, bus, channel, enabled state
- `read_channel(instance_id, channel_id)` -> current title and enabled state
- `set_enabled(instance_id, channel_id, desired)` -> writes and verifies one channel
- `sync(jobs, { dry_run = true|false })` -> reconciles a list of M-track jobs

Minimal example:

```lua
local V = require("jg_MCTM_VEPro")
local track = reaper.GetSelectedTrack(0, 0)
local _, name = reaper.GetTrackName(track)
local result = V.resolve(track, require("jg_MCTM_Helper").parse(name).name)

if result then
  V.set_enabled(result.instance_id, result.channel_id, true)
end
```

### `jg_MCTM_JSON.lua`
Small dependency-free JSON decoder used by the VE Pro module. It is not an action.

## Migration note

The old `/Disable` envelope scripts were removed:

- `jg_MCTM_Set all CTRL envelopes active.lua`
- `jg_MCTM_Toggle VEPro Activation depending on D Prefix.lua`

If either is still in your REAPER Action List, remove it. The VE Pro API path is deterministic, verifies its writes, and does not rely on plugin parameter envelopes.

[^1]: 4.0 in this case is not to be confused with "Quadraphonic" or "Higher Order Ambisonics". The four channels map exactly to a standard 5.1 surround setup. The center channel is reserved for dialogue, the LFE for, well, Low Frequency Effects. Do note that in a 5.1 setup, the "surrounds" are not behind the listener, but more or less just "next to their ears". True "rears" are only introduced with 7.1. What this means is that you can use what in e.g. Orchestral Tools libraries is literally called "surround" mics perfectly for your surround channels, without switching around the panning or anything. Left is still left, right is still right, it's just that the speakers are placed at a more extreme position.
