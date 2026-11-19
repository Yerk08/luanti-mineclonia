-- Dark theme. Mineclonia's GUI textures are swapped for this mod's own
-- original dark textures (textures/sharp_inventory_*.png, CC0), and its
-- dark label/text colors become light. Optionally the textures get a tint
-- (setting sharp_inventory.shade).
--
-- Where the look comes from (checked against Mineclonia's source):
--   * mcl_init: mcl_vars.gui_slots, gui_nonbg (button styles and
--     textcolor=#323232), gui_bg_img (panel background). The prepend mod
--     (mcl_formspec_prepend) reads these when each player joins.
--   * mcl_formspec: label_color = "#313131" and the item slot helpers,
--     which draw mcl_formspec_itemslot.png.
--   * Some screens are built once when their mod loads (the ender chest)
--     or stored in node metadata (furnaces, shulker boxes), and the
--     creative inventory writes its background texture literally. Those
--     strings are passed through theme() where they are shown or stored.

local cfg = sharp_inventory.settings

-- Mineclonia's original dark text colors.
local OLD_LABEL_COLOR = "#313131" -- mcl_formspec.label_color
local OLD_TEXT_COLOR = "#323232"  -- textcolor in mcl_vars.gui_nonbg

-- Mineclonia texture -> this mod's replacement. Each replacement keeps the
-- 9-slice border its original is drawn with (panel 7, model backdrop 2,
-- buttons 2), so the elements using them need no other change.
local REPLACE = {
	["mcl_formspec_itemslot.png"] = "sharp_inventory_slot.png",
	["mcl_base_textures_background9.png"] = "sharp_inventory_panel.png",
	["mcl_inventory_button9.png"] = "sharp_inventory_button.png",
	["mcl_inventory_button9_pressed.png"] = "sharp_inventory_button_pressed.png",
	["mcl_inventory_background9.png"] = "sharp_inventory_model_bg.png",
	["crafting_creative_trash.png"] = "sharp_inventory_trash.png",
	["crafting_creative_active.png"] = "sharp_inventory_tab_active.png",
	["crafting_creative_inactive.png"] = "sharp_inventory_tab_inactive.png",
	["crafting_creative_active_down.png"] = "sharp_inventory_tab_active_down.png",
	["crafting_creative_inactive_down.png"] = "sharp_inventory_tab_inactive_down.png",
}
local OWN = {}
for _, own in pairs(REPLACE) do
	OWN[own] = true
end

local TINT = cfg.shade and ("^[multiply:" .. cfg.shade) or ""

-- Escape Lua pattern characters so a literal string can be matched.
local function literal(s)
	return (s:gsub("%p", "%%%0"))
end

local label_from = literal("\27(c@" .. OLD_LABEL_COLOR .. ")")
local label_to = "\27(c@" .. cfg.text_color .. ")"
local text_from = literal("textcolor=" .. OLD_TEXT_COLOR)
local text_to = "textcolor=" .. cfg.text_color

-- Theme a formspec string. Safe to run more than once on the same string.
local function theme(formspec)
	if not cfg.theme or type(formspec) ~= "string" or formspec == "" then
		return formspec
	end
	-- Drop any ^[multiply:#RRGGBB right after a texture we handle. Older
	-- versions of this mod darkened Mineclonia's textures that way, and
	-- screens stored in the world may still carry it; our own textures
	-- get the current tint re-applied below.
	local out = formspec:gsub("([%w_]+%.png)%^%[multiply:#%x%x%x%x%x%x", function(texture)
		if REPLACE[texture] or OWN[texture] then
			return texture
		end
		-- Returning nothing keeps the original text.
	end)
	out = out:gsub("[%w_]+%.png", function(texture)
		local own = REPLACE[texture] or (OWN[texture] and texture)
		if own then
			return own .. TINT
		end
	end)
	out = out:gsub(label_from, label_to)
	out = out:gsub(text_from, text_to)
	return out
end

sharp_inventory.theme = theme

if not cfg.theme then
	return
end

-- 1) Sources read at runtime: patched once here, before any player joins.
mcl_formspec.label_color = cfg.text_color

-- A white hover at 47% is glaring on a dark slot; soften it.
local function soften_hover(s)
	return (s:gsub(literal("listcolors[#9990;#FFF7;"), "listcolors[#9990;#FFF4;"))
end
mcl_vars.gui_slots = soften_hover(theme(mcl_vars.gui_slots))
mcl_vars.gui_nonbg = soften_hover(theme(mcl_vars.gui_nonbg))
mcl_vars.gui_bg_img = theme(mcl_vars.gui_bg_img)

-- 2) Slot helpers: every screen built with them gets our slots,
-- including custom slot textures such as the creative trash slot.
local orig_slot_bg = mcl_formspec.get_itemslot_bg
function mcl_formspec.get_itemslot_bg(...)
	return theme(orig_slot_bg(...))
end

local orig_slot_bg_v4 = mcl_formspec.get_itemslot_bg_v4
function mcl_formspec.get_itemslot_bg_v4(...)
	return theme(orig_slot_bg_v4(...))
end

-- 3) Player inventory (survival and creative) goes through this one
-- function. Creative writes its background texture literally and uses
-- no_prepend[], so it needs theme() here.
local orig_set_inventory_formspec = mcl_player.set_inventory_formspec
function mcl_player.set_inventory_formspec(player, formspec, priority)
	return orig_set_inventory_formspec(player, theme(formspec), priority)
end
