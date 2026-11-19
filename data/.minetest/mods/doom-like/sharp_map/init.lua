-- sharp_map: an always-on minimap and named waypoints for Mineclonia.
--
-- /map (or the map button in Sharp Inventory) opens a full map centered
-- on the player, with the player's named waypoints, in categories, in a
-- sidebar. The minimap is drawn from the same saved map (or, by setting,
-- Luanti's own minimap is used), with each player's chosen mode remembered.
-- Underground (and always in the Nether) both show the caves the player
-- has walked through, one 16-node layer at a time (caves.lua, 1.3.0), and
-- the caves keep filling out from there in the background (1.4.0).

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

local function int_setting(key, default, min, max)
	local value = tonumber(core.settings:get(key))
	if not value then
		return default
	end
	return math.max(min, math.min(max, math.floor(value)))
end

local minimap_source = core.settings:get("sharp_map.minimap_source") or "map"
if minimap_source ~= "map" and minimap_source ~= "engine" then
	minimap_source = "map"
end

local teleport = core.settings:get("sharp_map.teleport") or "priv"
if teleport ~= "priv" and teleport ~= "all" and teleport ~= "off" then
	core.log("warning", "[" .. modname .. "] sharp_map.teleport = '" .. teleport
		.. "' is not priv, all or off; using priv.")
	teleport = "priv"
end

-- The mod's one global: a namespace table shared by its files.
sharp_map = {
	version = "1.4.4",
	S = core.get_translator(modname),
	settings = {
		minimap = core.settings:get_bool("sharp_map.minimap", true),
		minimap_on_join = core.settings:get_bool("sharp_map.minimap_on_join", true),
		minimap_source = minimap_source, -- "map" or "engine"
		minimap_screen_percent = int_setting("sharp_map.minimap_screen_percent", 25, 10, 50),
		player_arrow = core.settings:get_bool("sharp_map.player_arrow", true),
		arrow_reverse = core.settings:get_bool("sharp_map.arrow_reverse", false),
		debug = core.settings:get_bool("sharp_map.debug", false),
		minimap_update = math.max(0.05, math.min(1,
			tonumber(core.settings:get("sharp_map.minimap_update")) or 0.1)),
		minimap_size = int_setting("sharp_map.minimap_size", 128, 32, 512),
		minimap_wide_size = int_setting("sharp_map.minimap_wide_size", 256, 32, 512),
		max_waypoints = int_setting("sharp_map.max_waypoints", 50, 1, 200),
		death_waypoint = core.settings:get_bool("sharp_map.death_waypoint", true),
		label_distance = int_setting("sharp_map.label_distance", 100, 0, 1000),
		look_angle = int_setting("sharp_map.look_angle", 6, 0, 30),
		teleport = teleport, -- "priv", "all" or "off"
		scan_interval = math.max(0.05, math.min(5,
			tonumber(core.settings:get("sharp_map.scan_interval")) or 0.25)),
		scan_radius = int_setting("sharp_map.scan_radius", 8, 2, 16),
		draw_budget = int_setting("sharp_map.draw_budget", 6, 1, 50),
		minimap_budget = int_setting("sharp_map.minimap_budget", 3, 1, 50),
		redraw_budget = int_setting("sharp_map.redraw_budget", 3, 1, 50),
		redraw_on_update = core.settings:get_bool("sharp_map.redraw_on_update", true),
		-- Cave layers (1.3.0, caves.lua).
		caves = core.settings:get_bool("sharp_map.caves", true),
		cave_radius = int_setting("sharp_map.cave_radius", 20, 8, 40),
		cave_interval = math.max(0.25, math.min(5,
			tonumber(core.settings:get("sharp_map.cave_interval")) or 1)),
		cave_budget = int_setting("sharp_map.cave_budget", 3, 1, 50),
		-- Slow-step log (1.4.4): off unless asked for.
		debug_slow = core.settings:get_bool("sharp_map.debug_slow", false),
		debug_slow_ms = int_setting("sharp_map.debug_slow_ms", 20, 1, 1000),
		-- Background cave mapping (1.4.0, caves.lua).
		cave_background = core.settings:get_bool("sharp_map.cave_background", true),
		cave_background_range = int_setting("sharp_map.cave_background_range", 64, 16, 160),
		cave_background_interval = math.max(0.1, math.min(10,
			tonumber(core.settings:get("sharp_map.cave_background_interval")) or 0.5)),
	},
}

core.log("action", "[" .. modname .. "] version " .. sharp_map.version)

-- Slow-step log (1.4.4, setting sharp_map.debug_slow): one line in
-- debug.txt for any single piece of Sharp Map's work that took longer than
-- sharp_map.debug_slow_ms milliseconds, saying what it was, with the Lua
-- memory in use (a jump there points at Lua's own memory clean-up rather
-- than at Sharp Map). Callers pass the start time from core.get_us_time()
-- and, separately, any detail, so nothing is built unless it is logged.
do
	local cfg = sharp_map.settings
	local slow_us = cfg.debug_slow_ms * 1000
	function sharp_map.slow(what, t0, detail)
		if not cfg.debug_slow then
			return
		end
		local us = core.get_us_time() - t0
		if us >= slow_us then
			core.log("warning", ("[sharp_map] slow: %s%s took %.1f ms (Lua memory %.0f MB)"):format(
				what, detail and (" " .. tostring(detail)) or "", us / 1000, collectgarbage("count") / 1024))
		end
	end
end

dofile(modpath .. "/waypoints.lua")
dofile(modpath .. "/render.lua")
dofile(modpath .. "/redraw.lua")
dofile(modpath .. "/caves.lua")
dofile(modpath .. "/biomes.lua")
dofile(modpath .. "/hudmap.lua")
dofile(modpath .. "/minimap.lua")
dofile(modpath .. "/gui.lua")

core.register_chatcommand("map", {
	params = "[redraw [near|all|stop|status] | caves]",
	description = sharp_map.S("Open the map, redraw saved maps with the current look, or show cave mapping"),
	func = function(name, param)
		local what = (param or ""):match("^%s*redraw%s*(%a*)%s*$")
		if what then
			return sharp_map.redraw_command(name, what)
		end
		if (param or ""):match("^%s*caves%s*$") then
			local text = sharp_map.cave_status(core.get_player_by_name(name))
			if not text then
				return true, sharp_map.S("Cave layers are off (sharp_map.caves).")
			end
			return true, text
		end
		if not core.get_player_by_name(name) then
			return false, sharp_map.S("You must be in the game to use this.")
		end
		sharp_map.open_map(name)
		return true
	end,
})
