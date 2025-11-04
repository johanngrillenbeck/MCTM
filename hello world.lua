-- Demo for jg_MCTM_helper (Media Composer Template Manager)
-- This script demonstrates parsing and finding pairs using the helper in the same folder.

-- Ensure the script directory is on package.path so `require` finds local modules
local function add_script_dir_to_package_path()
	local info = debug.getinfo(1, 'S')
	if not info or not info.source then return end
	local source = info.source
	-- source looks like "@C:/.../hello world.lua" when executed
	local script_dir = source:match("@?(.*[\\/])")
	if not script_dir then return end
	local pattern1 = script_dir .. "?.lua;"
	local pattern2 = script_dir .. "?/init.lua;"
	package.path = pattern1 .. pattern2 .. package.path
end

add_script_dir_to_package_path()

local ok, mctm = pcall(require, "jg_MCTM_helper")
if not ok or not mctm then
	reaper.ShowConsoleMsg("Could not require 'jg_MCTM_helper': " .. tostring(mctm) .. "\n")
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
	"A Oboe",
	"M Oboe",
}

local found = mctm.findPairs(sample)

local function report()
	for key,entry in pairs(found) do
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
