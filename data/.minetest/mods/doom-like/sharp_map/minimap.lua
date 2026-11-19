-- Minimap mode per player, remembered between sessions, set with the map
-- screen's Minimap selector or /minimap.
--
-- sharp_map.minimap_source:
--   "map" (default): the minimap is drawn from the saved map (hudmap.lua).
--     Luanti's own minimap is given a single "off" mode so the two never
--     overlap; V then only shows a hint.
--   "engine": Luanti's own minimap. player:set_minimap_modes(modes,
--     selected) sets the modes V cycles through and selects one (0-based).
--
-- The server is never told when V is pressed, so the remembered choice is
-- the one made with the selector or /minimap.
--
-- Mineclonia does not restrict the minimap: mcl_maps (release 39338) never
-- calls hud_set_flags or set_minimap_modes. If another mod turns the
-- "minimap" HUD flag off, the minimap stays hidden.

local S = sharp_map.S
local cfg = sharp_map.settings

if not cfg.minimap then
	return
end

local META_KEY = "sharp_map:minimap"
sharp_map.MINIMAP_MODES = { "normal", "wide", "off" }
local INDEX = { normal = 0, wide = 1, off = 2 }
local NAMES = { normal = S("Normal"), wide = S("Wide"), off = S("Off") }

-- Mode labels are shown by the client as plain text, so translate them
-- here into the player's language.
local function translated(name, text)
	local info = core.get_player_information(name)
	return core.get_translated_string(info and info.lang_code or "", text)
end

function sharp_map.minimap_mode_name(mode)
	return NAMES[mode] or mode
end

function sharp_map.get_minimap_mode(player)
	local mode = player:get_meta():get_string(META_KEY)
	if not INDEX[mode] then
		mode = cfg.minimap_on_join and "normal" or "off"
	end
	return mode
end

-- Set PLAYER's minimap to MODE. Returns true, or false and a message.
function sharp_map.set_minimap_mode(player, mode, remember)
	if not INDEX[mode] then
		return false, S("Use normal, wide or off.")
	end
	if remember then
		player:get_meta():set_string(META_KEY, mode)
	end
	local name = player:get_player_name()
	if cfg.minimap_source == "map" then
		player:set_minimap_modes({
			{ type = "off", label = translated(name, S("Minimap: use the map screen or /minimap")) },
		}, 0)
		if sharp_map.hudmap_set_mode then
			sharp_map.hudmap_set_mode(player, mode)
		end
		return true
	end
	player:set_minimap_modes({
		{ type = "surface", size = cfg.minimap_size, label = translated(name, S("Minimap")) },
		{ type = "surface", size = cfg.minimap_wide_size, label = translated(name, S("Minimap, wide view")) },
		{ type = "off", label = translated(name, S("Minimap off")) },
	}, INDEX[mode])
	return true
end

core.register_on_joinplayer(function(player)
	sharp_map.set_minimap_mode(player, sharp_map.get_minimap_mode(player), false)
end)

core.register_chatcommand("minimap", {
	params = "<normal|wide|off>",
	description = S("Set the minimap (normal, wide or off); remembered next time"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, S("You must be in the game to use this.")
		end
		local mode = param:match("^%s*(%a+)%s*$")
		local ok, err = sharp_map.set_minimap_mode(player, mode, true)
		if not ok then
			return false, err
		end
		return true, S("Minimap: @1", sharp_map.minimap_mode_name(mode))
	end,
})
