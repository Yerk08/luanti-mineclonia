-- Survival inventory layout (mcl_inventory/survival.lua, "main" tab).
--
-- Mineclonia draws four buttons in one row at y 4.075. This moves
-- Advancements, Help and Player settings into a column above the offhand
-- slot, mirroring the armor column on the left, and puts the Recipe book
-- beside the Fill Craft Grid button. The freed row then holds the
-- "sort now" button and the auto-sort toggle, right above the main
-- inventory they act on.
--
-- Buttons are found by field name. If any is missing (a Mineclonia update
-- changed the screen), the vanilla layout is kept and a warning logged.

local modname = core.get_current_modname()
local cfg = sharp_inventory.settings

-- Rebuild the open survival screen so the toggle icon updates.
function sharp_inventory.refresh_survival(player)
	if type(mcl_inventory.update_inventory_formspec) == "function" then
		mcl_inventory.update_inventory_formspec(player)
	end
end

if not cfg.relayout then
	return -- The survival screen has no room for the toggle without this.
end

-- Top-left corners of the 1.1-unit buttons (slot position minus 0.05).
local MOVES = {
	__mcl_achievements = { 5.325, 0.325 },
	__mcl_doc = { 5.325, 1.575 },
	__mcl_player_settings = { 5.325, 2.825 },
	__mcl_craftguide = { 10.325, 2.075 },
}
local TOGGLE_X, TOGGLE_Y, TOGGLE_SIZE = 10.325, 4.075, 1.1
local SORT_NOW_X = 9.075 -- Same row, one button to the left of the toggle.

local NUM = "[%d%.%-]+"

-- Returns the moved formspec, or nil if any button was not found once.
local function relayout(formspec)
	local out = formspec
	for field, pos in pairs(MOVES) do
		local n
		out, n = out:gsub("image_button%[" .. NUM .. "," .. NUM
			.. "(;[^;%]]*;[^;%]]*;" .. field .. ";)",
			"image_button[" .. pos[1] .. "," .. pos[2] .. "%1")
		if n ~= 1 then
			return nil
		end
	end
	return out
end

local main_tab
if type(mcl_inventory.registered_survival_inventory_tabs) == "table" then
	for _, def in ipairs(mcl_inventory.registered_survival_inventory_tabs) do
		if def.id == "main" then
			main_tab = def
		end
	end
end
if not main_tab or type(main_tab.build) ~= "function" then
	core.log("warning", "[" .. modname .. "] Survival inventory tab not found;"
		.. " button layout and survival toggle are disabled.")
	return
end

local warned = false
local orig_build = main_tab.build
main_tab.build = function(player)
	local formspec = orig_build(player)
	if type(formspec) ~= "string" then
		return formspec
	end
	local moved = relayout(formspec)
	if not moved then
		if not warned then
			warned = true
			core.log("warning", "[" .. modname .. "] Survival inventory buttons changed;"
				.. " keeping the vanilla layout and leaving out the toggle there.")
		end
		return formspec
	end
	return moved .. sharp_inventory.sort_inv_button(SORT_NOW_X, TOGGLE_Y, TOGGLE_SIZE)
		.. sharp_inventory.toggle_button(TOGGLE_X, TOGGLE_Y, TOGGLE_SIZE, player)
end
