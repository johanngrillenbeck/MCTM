-- Demo for mctm.lua (Media Composer Template Manager)
-- This script demonstrates parsing and finding pairs using the library in the same folder.

local ok, mctm = pcall(dofile, "jg_MCTM_helper.lua")
if not ok or not mctm then
	reaper.ShowConsoleMsg("Could not load jg_MCTM_helper.lua (demo). Make sure jg_MCTM_helper.lua is in the same folder.\n")
	return
end

local sample = {
	"M Violin",
	"A Violin",
	"M Viola",
	"A Viola",
	"D M Harp",
	"CTRL VEHost",
	"A Cello",
	"M Cello",
	"A-Oboe",
	"M Oboe",
}

local pairs = mctm.findPairs(sample)

local function report()
	for key,entry in pairs(pairs) do
		local s = string.format("Instrument: '%s' (key='%s')\n  audio: %s\n  midi:  %s\n  ctrl:  %s\n  disabled: %s\n\n",
			entry.name or "(unnamed)", key,
			entry.audio or "-",
			entry.midi or "-",
			entry.ctrl or "-",
			tostring(entry.disabled))
		reaper.ShowConsoleMsg(s)
	end
end

report()
