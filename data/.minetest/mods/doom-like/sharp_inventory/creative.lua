-- Creative inventory: Sort now, the auto-sort toggle and (with Sharp Map)
-- a Map button on the "Survival Inventory" tab.
--
-- Checked against Mineclonia's mcl_inventory/creative.lua (release 39603):
--   * mcl_inventory.set_creative_formspec builds the whole screen and hands
--     it to mcl_player.set_inventory_formspec, so wrapping that function
--     (as theme.lua already does) catches every creative rebuild.
--   * Only the Survival Inventory tab draws the __switch_stack button;
--     that is how the tab is recognised. The item tabs have no free room
--     (item grid, scrollbar or page buttons).
--   * Everything sits in container[0,1.34] ... container_end[], and
--     Mineclonia appends a page marker after container_end[], so the
--     buttons go just before the last container_end[] and use the
--     container's own coordinates.
--   * The free block lies between the boots/leggings slots (x 7.25-8.25)
--     and Mineclonia's button column (x 11.575). The buttons line up with
--     inventory columns 8 and 9 (as on the survival screen) and with the
--     Recipe book and Help rows of that column (y 0.825 and 2.075).
--
-- Clicks need nothing new: containers.lua handles Sort now and the toggle
-- for formname "" (the toggle's redraw goes through
-- mcl_inventory.update_inventory_formspec, which rebuilds creative on the
-- same tab), and the Map button is handled below.

local S = sharp_inventory.S

local TAB_MARKER = "__switch_stack"
local MAP_FIELD = "sharp_inventory_map"

local SIZE = 1.1
local SORT_NOW_X, TOGGLE_X, ROW_Y = 9.075, 10.325, 2.075
local MAP_X, MAP_Y = 10.325, 0.825

-- Sharp Map is looked up when a screen is built or clicked, after all
-- mods have loaded. It is not an optional dependency: Sharp Map already
-- lists this mod as one, and a dependency in both directions is a loop.
local function map_available()
	return core.global_exists("sharp_map") and type(sharp_map) == "table"
		and type(sharp_map.open_map) == "function"
end

local function add_buttons(formspec, player)
	if type(formspec) ~= "string" or not formspec:find(TAB_MARKER, 1, true)
			or formspec:find(sharp_inventory.SORT_INV_FIELD, 1, true) then
		return formspec
	end
	-- Greedy (.*) stops at the last container_end[].
	local head, tail = formspec:match("^(.*)(container_end%[%].-)$")
	if not head then
		return formspec
	end
	local buttons = sharp_inventory.sort_inv_button(SORT_NOW_X, ROW_Y, SIZE)
		.. sharp_inventory.toggle_button(TOGGLE_X, ROW_Y, SIZE, player)
	if map_available() then
		buttons = buttons .. sharp_inventory.button(MAP_X, MAP_Y, SIZE,
			"mcl_maps_map_filled.png", MAP_FIELD, S("Map"))
	end
	return head .. buttons .. tail
end

local orig_set_inventory_formspec = mcl_player.set_inventory_formspec
function mcl_player.set_inventory_formspec(player, formspec, priority)
	if player and core.is_creative_enabled(player:get_player_name()) then
		formspec = add_buttons(formspec, player)
	end
	return orig_set_inventory_formspec(player, formspec, priority)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "" or not fields[MAP_FIELD] or not map_available() then
		return
	end
	-- Mineclonia's creative handler has already re-shown the inventory for
	-- this click; the map screen is shown after it and comes out on top.
	sharp_map.open_map(player:get_player_name())
	return true
end)
