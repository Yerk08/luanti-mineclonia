-- sharp_inventory: a dark, sharp theme and automatic sorting for
-- Mineclonia's own inventory screens. It restyles and rearranges what
-- Mineclonia already draws instead of replacing the inventory.

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

-- The mod's one global: a namespace table shared by its files.
sharp_inventory = {
	S = core.get_translator(modname),
	-- Formspec field names of this mod's buttons. All start with
	-- "sharp_inventory_" so stored screens can be cleaned up reliably.
	FIELD = "sharp_inventory_sort",           -- inventory auto-sort switch
	BOX_FIELD = "sharp_inventory_sort_box",   -- this container's switch
	SORT_INV_FIELD = "sharp_inventory_sort_inv",   -- sort my inventory now
	SORT_HERE_FIELD = "sharp_inventory_sort_here", -- sort this container now
}

-- Accept "#RRGGBB" only; anything else falls back to the default (which
-- may be nil, meaning "not set").
local function color_setting(key, default)
	local value = core.settings:get(key)
	if value and value:match("^#%x%x%x%x%x%x$") then
		return value:upper()
	end
	if value and value ~= "" then
		core.log("warning", "[" .. modname .. "] " .. key .. " = '" .. value
			.. "' is not a #RRGGBB color; using " .. (default or "none") .. ".")
	end
	return default
end

sharp_inventory.settings = {
	theme = core.settings:get_bool("sharp_inventory.theme", true),
	shade = color_setting("sharp_inventory.shade", nil), -- optional tint
	text_color = color_setting("sharp_inventory.text_color", "#E0E0E0"),
	relayout = core.settings:get_bool("sharp_inventory.relayout", true),
	autosort_default = core.settings:get_bool("sharp_inventory.autosort_default", false),
	autosort_interval = math.max(0.5,
		tonumber(core.settings:get("sharp_inventory.autosort_interval")) or 2),
	update_stored = core.settings:get_bool("sharp_inventory.update_stored_formspecs", true),
}

dofile(modpath .. "/theme.lua")
dofile(modpath .. "/sort.lua")
dofile(modpath .. "/survival.lua")
dofile(modpath .. "/containers.lua")
dofile(modpath .. "/creative.lua")
