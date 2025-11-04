# Media Composer Template Manager (MCTM)

Der MCTM ist eine Sammlung von Reaper-Skripten, die das Arbeiten mit großen Orchestertemplates vereinfachen soll.

Design-Philosophie

- Alle Tracks bekommen Prefixe, damit der Status eines Tracks in einem für Menschen lesbaren Format gespeichert ist.
- Weil Reaper nicht zwischen Audio- und MIDI-Tracks unterscheidet, ist es für den User wichtig, auf welchem Track er sich befindet.

Prefix-Übersicht

- `A` : Audiotrack
- `M` : MIDI-Track
- `D` : deaktivierter Track (wird vom System ignoriert)
- `CTRL` : Track, der z. B. eine VEPro-Instanz hostet (VSTi)

Konvention

Jedes virtuelle Instrument tritt nur in einem Track-Paar aus Audio- und MIDI-Track auf. Das Prefix `D` sagt dem System, dass der User das Track-Paar nicht braucht; Funktionen zum Anzeigen/Filtern ignorieren solche Tracks.

Library: `mctm.lua`

Wichtige Funktionen (kurz):

- `parse(label)` -> { prefixes = {...}, name = "..." }
- `findPairs(tracks, opts)` -> table mit key = canonical name -> { name=..., audio=label?, midi=label?, ctrl=label?, disabled=bool }
- `is_audio(parsed)`, `is_midi(parsed)`, `is_ctrl(parsed)`, `is_disabled(parsed)`
- `format_label(prefixes, name)`

Beispiele

1) Parsing:

- `M Violin` -> prefixes = {"M"}, name = "Violin"
- `D M Viola` -> prefixes = {"D","M"}, name = "Viola" (wird normalerweise ignoriert)
- `CTRL VEHost` -> prefixes = {"CTRL"}, name = "VEHost"

2) findPairs:

Gibt eine Tabelle zurück, die zu jedem Instrument die vorhandenen Track-Labels für Audio/MIDI/CTRL liefert und `disabled` angibt.

Wie benutzen

Lege `mctm.lua` in dasselbe Verzeichnis wie deine Skripte. In einem Script kannst du es mit `local mctm = dofile("mctm.lua")` laden (oder `require` verwenden, wenn dein package.path passt).

Beispiel-Demo: `hello world.lua` im selben Ordner zeigt eine kleine Demo.

Weiteres

- Erweiterungen: Funktionen zum Umbenennen, Toggling von Präfixen, oder Reaper-API-Integration (Track-Objekte statt Strings) lassen sich hinzufügen.
- Tests: Kleine Unit-Tests könnten hinzugefügt werden, um Parsing-Edgecases abzudecken (leere Namen, mehrere Bindestriche, Sonderzeichen).

Lizenz

Dieses Repository enthält persönliche Skripte für Reaper. Passe sie nach Bedarf an.
