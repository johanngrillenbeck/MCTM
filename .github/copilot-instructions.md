# AI Coding Agent Instructions: MCTM (Reaper Lua Scripts)

This repository contains Lua scripts for REAPER to manage large orchestral templates. The core concept is track "prefixes" embedded in human-readable track labels, used to infer a track's role and state. Scripts operate on strings (labels) or REAPER track objects and follow consistent parsing/formatting rules.

## Architecture Overview
- **Domain**: REAPER track management for orchestral templates.
- **Data model**: Track labels encode state via prefixes, e.g. `A Violin`, `M Violin`, `D M Viola`, `CTRL VEHost`.
- **Core libraries**:
  - `jg_MCTM_Helper.lua` (aliased as `mctm`): parsing, identification, and stable formatting.
    - `parse(label)` → `{ prefixes = {...}, name = "..." }`
    - `is_audio()/is_midi()/is_ctrl()/is_disabled()` → boolean
    - `findPairs(tracks, opts)` → helper for strict 1:1 A/M instruments (legacy/pair-based reasoning)
    - `format_label(prefixes, name)` → string
  - `jg_MCTM_VEPro.lua`: VE Pro API client, channel resolver, enable/disable, and sync.
    - `probe()`, `resolve(midi_track, base_name)`, `read_channel(instance_id, channel_id)`
    - `set_enabled(instance_id, channel_id, desired)`, `sync(jobs, { dry_run = ... })`
  - `jg_MCTM_JSON.lua`: small JSON decoder used by the VE Pro module.
- **Track groups (current model)**: An "instrument" is treated as a *track group*: one MIDI track plus one or more audio return tracks.
  - 1:1 instruments: one `M` + one `A`
  - 1:n instruments (multi-audio returns): one `M` + many `A` (e.g. drum kits)
  - Scripts use a *group key* ("groupKey") to bind all related tracks together.
- **Scripts**: Each `jg_MCTM_*.lua` file performs a specific workflow (choose tracks, build from CSV, toggle visibility/prefixes, send/receive routing, VE Pro sync). Scripts should import helpers with `require`, not `dofile`:
  - `local mctm = require("jg_MCTM_Helper")`
  - `local V = require("jg_MCTM_VEPro")`
- The newer scripts add both their own `Actions/` folder and `../Helpers/` to `package.path`, so the repo layout works directly.
- You can find the Reascript API documentation locally in the file [.github/reascripthelp.html](.github/reascripthelp.html) included in this repository.
- You can find the Reaticulate documentation locally in the file [.github/reabank files _ reaticulate.html](.github/reabank%20files%20_%20reaticulate.html) included in this repository.

## Prefix Conventions
- `A`: audio track
- `M`: MIDI track
- `D`: disabled (ignored by functions unless explicitly included)
- `CTRL`: controller/host track (e.g., VEPro instance)
- `FX`: effects return track (needs audio track return from VEpro Instance but no MIDI)
- Prefixes are recognized as space-separated leading tokens. Example: `D M Viola` → prefixes `{"D","M"}`, name `"Viola"`.
- CTRL tracks never have A, M or D prefixes, since they have a distinct role and can never be disabled.
- FX tracks never have A, M or D prefixes, since they have a distinct role and can never be disabled.
- Canonical instrument identity is derived from the remaining name (lowercased, trimmed).
- Audio Buses are not explicitly prefixed; they are identified by absence of A/M/CTRL and presence of receiving audio from A tracks.

### GroupKey conventions (track groups)
- For most tracks, `groupKey` is the parsed base name (`mctm.parse(name).name`) of the `M` track.
- Multi-audio child audio tracks are named with a parenthesized suffix holding the group identity:
  - MIDI: `M <Library Prefix> <Parent Instrument>`
  - Audio child: `A <Child Track Name> (<Library Prefix> <Parent Instrument>)`
- For an `A` track, if it ends in `(... )` and the content inside parentheses matches an existing MIDI base name in the project, that parenthesized name is used as the `groupKey`.
- Otherwise, the `A` track's own base name is used.

## VE Pro API Integration

MCTM uses the VE Pro 8 local JSON API through `vepro-api-cli.exe`. The old `/Disable` envelope automation has been removed and should not be reintroduced.

### Resolution rules
- Each `M` track has a MIDI send to its `CTRL` track. The send's destination bus is the same number as the VE Pro channel's `midiPort`.
- The `CTRL` track name identifies the instance: `CTRLVE1` matches `CTRLVE1 - OTBW / OTBB / ...`.
- Resolve the instrument-bearing channel on that `midiPort` and mutate it by `channelId`.
- Channel titles are diagnostics only. They may be renamed, drop a library prefix, abbreviate a name, or contain tabs/newlines. Never use title equality as the primary lookup key.
- Nested folder addresses such as `3[3]` mean "child 3 of top-level channel 3". The instrument-bearing child carries the `midiPort`; folder and mic/output siblings do not.
- Addresses are positional and change when children are inserted, reordered, or deleted. `channelId` can change after a VE Pro reload. Resolve fresh each run; do not persist either.

### Read and write rules
- Enable with `channel/forceenable`; disable with `channel/patch` and `enabled=false`.
- `forceenable` un-gates ancestor folders, enables disabled buses on the output chain, and suppresses conflicting sibling instruments. Mic/output children under the same folder are left alone.
- Verify every write by re-reading the channel with `instance/channelsummary` and `selector.ids`.
- Use a unique `idempotencyKey` per write. Do not reuse one key for repeated state changes; the API may dedupe the second write.
- Keep VE Pro writes outside REAPER undo blocks and outside `PreventUIRefresh`.
- Prefer `V.sync(jobs, { dry_run = ... })` over ad-hoc per-channel writes.

### Configuration (ExtState `MCTM` section)
- `vepro_cli`: CLI path. Default `%ProgramData%\VSL\Vienna Ensemble Pro\mcp\vepro-api-cli.exe`.
- `vepro_host`: default `127.0.0.1`. Refuse non-loopback unless `vepro_allow_remote=1`.
- `vepro_port`: default `7200`.
- `vepro_dry_run`: `1` = resolve and report, no writes.
- `vepro_allow_remote`: `1` = allow a non-loopback host. Keep `0` normally.
- `vepro_timeout_ms`: default `60000`.

### Transport note
`reaper.ExecProcess` truncates large stdout at roughly 4–5 KB. The module redirects the CLI's stdout to a temporary file and reads that file. Do not switch back to capturing the routing summary directly through the pipe.

### Actions
- `jg_MCTM_VEPro selftest.lua`: read-only mapping report. Writes `<resource>/Scripts/jg_MCTM_vepro_selftest.tsv`.
- `jg_MCTM_VEPro sync selected.lua`: dry-run plan + confirmation, then sync selected `M` tracks. Writes `<resource>/Scripts/jg_MCTM_vepro_sync_test.tsv`.

## Typical Data Flows
- Collect track labels (from REAPER or provided lists).
- Parse labels with `mctm.parse(label)`; filter via role helpers.
- Build *track groups* using `groupKey` (one `M` plus one-or-many `A` tracks). Use `findPairs` only when strict 1:1 pairing is guaranteed.
- Apply actions: toggle `D` prefix and visibility for *the whole group*, adjust visibility, route send/receive based on role.
- For VE Pro state changes, build `jobs = { { midi_track=..., base_name=..., desired=bool, label=... } }` and call `V.sync(jobs)`.
- Write back labels using `mctm.format_label(prefixes, name)` when renaming.

## Script Patterns & Examples
- **Choosing tracks**: Read all track labels, build instrument *groups* via `groupKey`, present selection UI (ReaImGui in `jg_MCTM_Choose tracks.lua`) and apply selection by toggling groups. Apply builds one VE Pro job per group with an `M` track and calls `V.sync` once for the full checkbox state. The VE Pro call happens after `Undo_EndBlock` and `PreventUIRefresh(-1)`.
- **Building from CSV**: Build track groups from `..._INSTRUMENTS.csv`. Supports continuation rows (rows where the `CTRL` column is empty) to define multi-audio child returns for the most recently-seen parent instrument.
- **Toggle visibility/prefix**: Parse label → modify prefixes (e.g., add/remove `D`) → reformat via `format_label` → set track name. The standalone toggle action then calls `V.sync` for the selected groups. When called from `Choose tracks`, `_G.MCTM_SUPPRESS_VEPRO_SYNC` prevents a per-batch sync, and `_G.MCTM_FORCE_D_STATE` forces the intended target state.
- **VE Pro activation**: Use `V.resolve` / `V.set_enabled` / `V.sync`. Never write `/Disable` envelopes or search envelope names. Enable via `channel/forceenable`, disable via `channel/patch`, and verify by `channelId`.

Example label flow:
```lua
local mctm = require("jg_MCTM_Helper")
local p = mctm.parse("D M Viola")
-- p.prefixes == {"D","M"}, p.name == "Viola"
-- 1:1 instrument (legacy pairing works)
local pairs = mctm.findPairs({"A Viola","M Viola","CTRL VEHost"})
-- pairs["viola"] => {name="Viola", audio="A Viola", midi="M Viola", ctrl=nil, disabled=false}

-- 1:n instrument (multi-audio returns) uses groupKey logic
-- M:  "M LIB Drum"
-- A1: "A Kick (LIB Drum)"
-- A2: "A Snare (LIB Drum)"
local new = mctm.format_label({"M"}, "Viola") -- "M Viola"
```

Example VE Pro sync:
```lua
local V = require("jg_MCTM_VEPro")
local report = V.sync({
  { midi_track = track, base_name = "OTBW Flute 1", desired = true, label = "M OTBW Flute 1" },
}, { dry_run = false })

if report.summary.errors > 0 then
  -- surface report.errors
end
```

## Workflows (REAPER-specific)
### General
- Load scripts via the Action List. Ensure `Helpers/` is on `package.path`; scripts add both `Actions/` and `../Helpers/`.
- CSV-based scripts expect resource files under `Ressources/` (e.g., `jgscoringtest.csv`, `jgscoringtest7stereo.csv`).
- Some routing scripts assume ascending bus numbering and may distinguish audio-only vs MIDI-only busses.
### Instrument Articulations
- Articulations should integrate with the popular Reaticulate extension. We achieve this by adding the required information to the "..._INSTRUMENTS.csv" as well as "..._KEY_SWITCHES.csv" and build our own Reaticulate bank file in "...REATICULATE.reabank", which the user can then import into Reaticulate.

## Project Conventions
- Operate on labels, not arbitrary metadata; avoid assumptions outside prefixes and names.
- Treat `D` as authoritative for ignoring tracks unless an option explicitly includes disabled.
- multi-audio child rows inherit the parent’s “Audio Send To” bus
- Only recognize exact, leading tokens as prefixes; do not parse embedded substrings.
- Prefer group-based reasoning (track groups via `groupKey`) over ad-hoc matching. Use `findPairs` only for strict 1:1 instruments.
- Keep formatting stable via `format_label`; do not introduce punctuation between prefixes and names.
- Resolve VE Pro channels from the MIDI bus each run; do not persist `channelId` or nested addresses.
- Keep VE Pro writes outside REAPER undo blocks and outside `PreventUIRefresh`.
- Use `MCTM,vepro_dry_run=1` for plan-only testing.

## Integration Points
 REAPER API for track enumeration, naming, visibility toggling, routing. Local offline docs: see [.github/reascripthelp.html](.github/reascripthelp.html).
 VEPro (Vienna Ensemble Pro): controlled through the local JSON API. Resolution uses the `M` track's MIDI send bus → VE Pro `midiPort`; instance from the `CTRL` track name; mutation by `channelId`. Enable with `channel/forceenable`, disable with `channel/patch`, and verify with `instance/channelsummary`. Titles are diagnostics only.
 CSV loaders: keep robust to spacing and casing in names; map to `A/M/CTRL` roles using helper functions.
 Dependencies: requires SWS/BR extension (e.g., `BR_GetSetTrackSendInfo`) for MIDI/audio send manipulation used by routing scripts.

 The use of the Reaper API can create conflicts with the integrated Lua Type checker, since the Reaper API is not fully typed. Ignore false positives from the type checker related to Reaper API calls.

 Routing conventions:
   - Audio from `CTRL` to `A` tracks in ascending quad groups: first selected `A` receives source channels 1–4, second 5–8, etc.; each destination is set to 4 channels; sends are created as two stereo pairs per quad; MIDI on these sends is disabled.
     - Reference: [jg_MCTM_Recieve from CTRL - ascending quad audio no midi.lua](jg_MCTM_Recieve%20from%20CTRL%20-%20ascending%20quad%20audio%20no%20midi.lua)
   - Mono and odd VE ranges for `CTRL` → `A`/`FX` routing are supported via the CSV `From VE Audiotrack` field:
     - Single number (e.g. `3`) means mono source channel 3.
     - Odd range (e.g. `1-3`) means stereo `1-2` plus mono `3` (prevents overlapping stereo mappings like `3/4`, `4/5`, ...).
     - Implementation detail (REAPER send encoding): set `I_SRCCHAN` to `(start0 + 1024)` for mono, or `start0` for stereo; keep `I_DSTCHAN` as the destination channel offset (0-based).
   - MIDI from selected tracks to a chosen `CTRL` track on ascending MIDI busses: first selected track → bus 1, second → bus 2, omni channel (0), audio disabled (`I_SRCCHAN`/`I_DSTCHAN = -1`). Optional pre-clean disables existing MIDI routing.
     - Reference: [jg_MCTM_Send to CTRL - ascending MIDI busses no audio.lua](jg_MCTM_Send%20to%20CTRL%20-%20ascending%20MIDI%20busses%20no%20audio.lua)
   - VE Pro activation/deactivation: do not use envelopes. The `M` track's MIDI send destination bus equals the VE Pro channel `midiPort`; the `CTRL` track name selects the instance. Enable with `channel/forceenable`, disable with `channel/patch enabled=false`, and verify by `channelId`. Nested folder addresses such as `3[3]` are positional; the instrument child carries the `midiPort`.
     - Reference: `Helpers/jg_MCTM_VEPro.lua`, `Actions/jg_MCTM_VEPro selftest.lua`, `Actions/jg_MCTM_VEPro sync selected.lua`
- Centralize options (like `include_disabled`) when building UIs for selection or toggling.
 When routing:
   - Always disable MIDI for audio-only sends from `CTRL` to `A` tracks.
   - Always disable audio (`I_SRCCHAN`/`I_DSTCHAN = -1`) for MIDI-only sends to `CTRL`.
   - Ensure source/destination channel counts are set before creating sends (`I_NCHAN`).
   - When creating sends from `A`/`FX` tracks to bus tracks, compute the required channel count from the *VE range length* (end-start+1), not from the absolute channel index.
     - Example: `19-20` routes 1 stereo pair (2 channels); `101-104` routes 2 stereo pairs (4 channels).
   - Use ascending ordering of currently selected tracks to determine bus/channel group assignment.

Keep instructions concise and grounded in these conventions. When in doubt, parse labels and prefer group-based reasoning (`groupKey`) before acting across tracks.
