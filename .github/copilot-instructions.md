# AI Coding Agent Instructions: MCTM (Reaper Lua Scripts)

This repository contains Lua scripts for REAPER to manage large orchestral templates. The core concept is track "prefixes" embedded in human-readable track labels, used to infer a track's role and state. Scripts operate on strings (labels) or REAPER track objects and follow consistent parsing/formatting rules.

## Architecture Overview
- **Domain**: REAPER track management for orchestral templates.
- **Data model**: Track labels encode state via prefixes, e.g. `A Violin`, `M Violin`, `D M Viola`, `CTRL VEHost`.
- **Core library**: See `jg_MCTM_helper.lua` (aliased as `mctm`). Provides parsing, identification, and stable formatting.
  - `parse(label)` → `{ prefixes = {...}, name = "..." }`
  - `is_audio()/is_midi()/is_ctrl()/is_disabled()` → boolean
  - `findPairs(tracks, opts)` → helper for strict 1:1 A/M instruments (legacy/pair-based reasoning)
  - `format_label(prefixes, name)` → string
- **Track groups (current model)**: An "instrument" is treated as a *track group*: one MIDI track plus one or more audio return tracks.
  - 1:1 instruments: one `M` + one `A`
  - 1:n instruments (multi-audio returns): one `M` + many `A` (e.g. drum kits)
  - Scripts use a *group key* ("groupKey") to bind all related tracks together.
- **Scripts**: Each `jg_MCTM_*.lua` file performs a specific workflow (choose tracks, build from CSV, toggle visibility/prefixes, send/receive routing, VEPro activation). Most scripts should import the helper: `local mctm = dofile("jg_MCTM_helper.lua")`.
- you can find the Reascript API documentation locally in the file [.github/reascripthelp.html](.github/reascripthelp.html) included in this repository.
- you can find the Reaticulate documentation locally in the file [.github/reabank files _ reaticulate.html](.github/reabank%20files%20_%20reaticulate.html) included in this repository.

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

## Typical Data Flows
- Collect track labels (from REAPER or provided lists).
- Parse labels with `mctm.parse(label)`; filter via role helpers.
- Build *track groups* using `groupKey` (one `M` plus one-or-many `A` tracks). Use `findPairs` only when strict 1:1 pairing is guaranteed.
- Apply actions: toggle `D` prefix and visibility for *the whole group*, adjust visibility, route send/receive based on role.
- Write back labels using `mctm.format_label(prefixes, name)` when renaming.

## Script Patterns & Examples
- **Choosing tracks**: Read all track labels, build instrument *groups* via `groupKey`, present selection UI (ReaImGui in `jg_MCTM_Choose Tracks.lua`) and apply selection by toggling groups and updating VEPro activation.
- **Building from CSV**: Build track groups from `..._INSTRUMENTS.csv`. Supports continuation rows (rows where the `CTRL` column is empty) to define multi-audio child returns for the most recently-seen parent instrument.
- **Toggle visibility/prefix**: Parse label → modify prefixes (e.g., add/remove `D`) → reformat via `format_label` → set track name.
- **VEPro activation**: Use `CTRL` identification to activate/deactivate instances based on matching `D` state in the group (if any track in the group has `D`, the group is treated as disabled).

Example label flow:
```lua
local mctm = dofile("jg_MCTM_helper.lua")
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

## Workflows (REAPER-specific)
### General
- Load scripts via REAPER Action List; ensure they run with access to `jg_MCTM_helper.lua` in the same folder.
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

## Integration Points
 REAPER API for track enumeration, naming, visibility toggling, routing. Local offline docs: see [.github/reascripthelp.html](.github/reascripthelp.html).
 VEPro (Vienna Ensemble Pro): controlled via `CTRL` tracks; activation state mirrors group `D` state and is written via `/Disable` envelopes.
 CSV loaders: keep robust to spacing and casing in names; map to `A/M/CTRL` roles using helper functions.
 Dependencies: requires SWS/BR extension (e.g., `BR_GetSetTrackSendInfo`) for MIDI/audio send manipulation used by routing scripts.

 The use of the Reaper API can create conflicts with the integrated Lua Type checker, since the Reaper API is not fully typed. Ignore false positives from the type checker related to Reaper API calls.

 Routing conventions:
   - Audio from `CTRL` to `A` tracks in ascending quad groups: first selected `A` receives source channels 1–4, second 5–8, etc.; each destination is set to 4 channels; sends are created as two stereo pairs per quad; MIDI on these sends is disabled.
     - Reference: [jg_MCTM_Recieve from CTRL - ascending quad audio no midi.lua](jg_MCTM_Recieve%20from%20CTRL%20-%20ascending%20quad%20audio%20no%20midi.lua)
   - MIDI from selected tracks to a chosen `CTRL` track on ascending MIDI busses: first selected track → bus 1, second → bus 2, omni channel (0), audio disabled (`I_SRCCHAN`/`I_DSTCHAN = -1`). Optional pre-clean disables existing MIDI routing.
     - Reference: [jg_MCTM_Send to CTRL - ascending MIDI busses no audio.lua](jg_MCTM_Send%20to%20CTRL%20-%20ascending%20MIDI%20busses%20no%20audio.lua)
   - VEPro activation/deactivation via `CTRL` track envelopes named like `"<Index> <Instrument> /Disable"`: if any track in the group has `D`, set target value 1 (deactivate); otherwise 0 (activate). Points are inserted and sorted to create short ramps.
     - Reference: [jg_MCTM_Toggle VEPro Activation depending on D Prefix.lua](jg_MCTM_Toggle%20VEPro%20Activation%20depending%20on%20D%20Prefix.lua)
- Centralize options (like `include_disabled`) when building UIs for selection or toggling.
 When routing:
   - Always disable MIDI for audio-only sends from `CTRL` to `A` tracks.
   - Always disable audio (`I_SRCCHAN`/`I_DSTCHAN = -1`) for MIDI-only sends to `CTRL`.
   - Ensure source/destination channel counts are set before creating sends (`I_NCHAN`).
   - When creating sends from `A`/`FX` tracks to bus tracks, compute the required channel count from the *VE range length* (end-start+1), not from the absolute channel index.
     - Example: `19-20` routes 1 stereo pair (2 channels); `101-104` routes 2 stereo pairs (4 channels).
   - Use ascending ordering of currently selected tracks to determine bus/channel group assignment.

Keep instructions concise and grounded in these conventions. When in doubt, parse labels and prefer group-based reasoning (`groupKey`) before acting across tracks.