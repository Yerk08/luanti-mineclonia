-- Sorting rules and helpers.
--
-- Order follows Mineclonia's own creative inventory tabs (blocks,
-- decoration, redstone, transport, food, tools, combat, mobs, brewing,
-- materials, misc), using the same group tests as
-- mcl_inventory/creative.lua, then item name, then the exact item
-- (wear and metadata), with fuller stacks first. Identical items are
-- merged into full stacks.

local cfg = sharp_inventory.settings

-- mcl_inventory: "main" is 36 slots and the hotbar is its first 9.
-- Slots 1-9 are never read or written by this mod.
local HOTBAR_SIZE = 9
local STORAGE_FIRST = HOTBAR_SIZE + 1
sharp_inventory.STORAGE_FIRST = STORAGE_FIRST

------------------------------------------------------------------------
-- Categories (same tests and order as Mineclonia's creative tabs)
------------------------------------------------------------------------

local function g(def, group)
	return def.groups and (def.groups[group] or 0) ~= 0
end

local function is_tool(def)
	return g(def, "tool") or (def.tool_capabilities and def.tool_capabilities.damage_groups == nil)
end

local function is_weapon_or_armor(def)
	return g(def, "weapon") or g(def, "weapon_ranged") or g(def, "ammo") or g(def, "combat_item")
		or ((g(def, "armor_head") or g(def, "armor_torso") or g(def, "armor_legs")
			or g(def, "armor_feet") or g(def, "horse_armor"))
			and not g(def, "non_combat_armor"))
end

local CATEGORY_TESTS = {
	function(def) return g(def, "building_block") end,                         -- blocks
	function(def) return g(def, "deco_block") end,                             -- deco
	function(def) return def._mcl_redstone or g(def, "redstone_wire") end,     -- redstone
	function(def) return g(def, "transport") end,                              -- rail
	function(def) return (g(def, "food") and not g(def, "brewitem")) or g(def, "eatable") end,
	is_tool,                                                                    -- tools
	is_weapon_or_armor,                                                         -- combat
	function(def) return g(def, "spawn_egg") end,                              -- mobs
	function(def) return g(def, "brewitem") end,                               -- brew
	function(def) return g(def, "craftitem") end,                              -- matr
}
local MISC = #CATEGORY_TESTS + 1
local UNKNOWN = MISC + 1

local category_cache = {}

local function category(name)
	local c = category_cache[name]
	if c then
		return c
	end
	local def = core.registered_items[name]
	c = UNKNOWN
	if def then
		c = MISC
		for i, test in ipairs(CATEGORY_TESTS) do
			if test(def) then
				c = i
				break
			end
		end
	end
	category_cache[name] = c
	return c
end

------------------------------------------------------------------------
-- Sorting
------------------------------------------------------------------------

-- Exact identity of one item: name, wear and metadata, without count.
local function ident(stack)
	return stack:peek_item(1):to_string()
end
sharp_inventory.ident = ident

local function before(a, b)
	if a.cat ~= b.cat then return a.cat < b.cat end
	if a.name ~= b.name then return a.name < b.name end
	if a.wear ~= b.wear then return a.wear < b.wear end -- least worn first
	if a.ident ~= b.ident then return a.ident < b.ident end
	return a.count > b.count
end

-- Sort and merge a list of ItemStacks. Returns a new list of the same
-- length, with empty stacks at the end.
function sharp_inventory.sort_stacks(stacks)
	local entries = {}
	for _, stack in ipairs(stacks) do
		if not stack:is_empty() then
			local name = stack:get_name()
			entries[#entries + 1] = {
				stack = ItemStack(stack),
				name = name,
				cat = category(name),
				ident = ident(stack),
				wear = stack:get_wear(),
				count = stack:get_count(),
			}
		end
	end
	table.sort(entries, before)

	local out, out_ident = {}, {}
	for _, e in ipairs(entries) do
		local rest = e.stack
		local n = #out
		-- Same items are adjacent, so only the last stack can take more.
		if n > 0 and out_ident[n] == e.ident then
			rest = out[n]:add_item(rest)
		end
		if not rest:is_empty() then
			out[n + 1] = rest
			out_ident[n + 1] = e.ident
		end
	end
	for i = #out + 1, #stacks do
		out[i] = ItemStack("")
	end
	return out
end

-- Sort several inventory lists as one (e.g. both halves of a double
-- chest). Each source is { inv = InvRef, list = name, first = n, last = n }.
-- Only slots whose content changes are written. Returns true if any did.
function sharp_inventory.sort_lists(sources)
	local all, slots = {}, {}
	for _, src in ipairs(sources) do
		local list = src.inv:get_list(src.list)
		if list then
			local last = math.min(src.last or #list, #list)
			for i = src.first or 1, last do
				all[#all + 1] = list[i]
				slots[#slots + 1] = { src = src, index = i }
			end
		end
	end
	local sorted = sharp_inventory.sort_stacks(all)
	local changed = false
	for k, slot in ipairs(slots) do
		if sorted[k]:to_string() ~= all[k]:to_string() then
			slot.src.inv:set_stack(slot.src.list, slot.index, sorted[k])
			changed = true
		end
	end
	return changed
end

-- Sort the player's main inventory, never touching the hotbar.
function sharp_inventory.sort_player(player)
	return sharp_inventory.sort_lists({
		{ inv = player:get_inventory(), list = "main", first = STORAGE_FIRST },
	})
end

------------------------------------------------------------------------
-- Moving items in and out of storage (main inventory minus hotbar)
------------------------------------------------------------------------

-- Count items in storage that are exactly like ID.
function sharp_inventory.count_in_storage(inv, id)
	local n = 0
	for i = STORAGE_FIRST, inv:get_size("main") do
		local slot = inv:get_stack("main", i)
		if not slot:is_empty() and ident(slot) == id then
			n = n + slot:get_count()
		end
	end
	return n
end

-- Remove up to COUNT items exactly like ID from storage, taking from the
-- end so the front stays tidy. Returns the number removed.
function sharp_inventory.take_from_storage(inv, id, count)
	local taken = 0
	for i = inv:get_size("main"), STORAGE_FIRST, -1 do
		if taken >= count then
			break
		end
		local slot = inv:get_stack("main", i)
		if not slot:is_empty() and ident(slot) == id then
			taken = taken + slot:take_item(count - taken):get_count()
			inv:set_stack("main", i, slot)
		end
	end
	return taken
end

------------------------------------------------------------------------
-- Auto-sort switches (1.2.0: containers decoupled from the inventory)
--
--   * Inventory switch, per player (player metadata): sorts the player's
--     own inventory. Same key since 1.0.0, so saved choices carry over.
--   * Chests: one setting stored in the chest itself, shared by everyone
--     who opens it. Breaking the chest removes it. (Furnaces have none.)
--   * Shulker boxes and the ender chest: per player (player metadata). A
--     shulker box is picked up and moved, and the ender chest's contents
--     belong to each player.
-- Anything not set yet follows the inventory switch of the player using
-- it, so nobody's behaviour changed when this split was introduced.
------------------------------------------------------------------------

local KEY = "sharp_inventory:autosort" -- player inventory, and the block key
sharp_inventory.SHULKER_KEY = "sharp_inventory:autosort_shulker"
sharp_inventory.ENDER_KEY = "sharp_inventory:autosort_ender"

-- Stored values: "1" on, "0" off, anything else not set (nil).
local function decode(value)
	if value == "1" then
		return true
	elseif value == "0" then
		return false
	end
	return nil
end

local function encode(on)
	return on and "1" or "0"
end

function sharp_inventory.autosort_enabled(player)
	local on = decode(player:get_meta():get_string(KEY))
	if on == nil then
		return cfg.autosort_default
	end
	return on
end

-- Flip the inventory switch and return the new state.
function sharp_inventory.toggle_autosort(player)
	local on = not sharp_inventory.autosort_enabled(player)
	player:get_meta():set_string(KEY, encode(on))
	return on
end

-- Another per-player switch (SHULKER_KEY, ENDER_KEY): true, false or nil.
function sharp_inventory.player_switch(player, key)
	return decode(player:get_meta():get_string(key))
end

function sharp_inventory.set_player_switch(player, key, on)
	player:get_meta():set_string(key, encode(on))
end

-- Its effective state: unset follows the inventory switch.
function sharp_inventory.player_switch_enabled(player, key)
	local on = sharp_inventory.player_switch(player, key)
	if on == nil then
		return sharp_inventory.autosort_enabled(player)
	end
	return on
end

function sharp_inventory.toggle_player_switch(player, key)
	local on = not sharp_inventory.player_switch_enabled(player, key)
	sharp_inventory.set_player_switch(player, key, on)
	return on
end

-- The setting stored in a block (a chest half): true, false or nil.
function sharp_inventory.node_switch(pos)
	return decode(core.get_meta(pos):get_string(KEY))
end

function sharp_inventory.set_node_switch(pos, on)
	core.get_meta(pos):set_string(KEY, encode(on))
end

-- Tooltip text for this mod's buttons. Square brackets are dropped so
-- containers.lua can always find and replace its own elements in stored
-- screens, even with translated text.
function sharp_inventory.tooltip_text(text)
	return core.formspec_escape((text:gsub("[%[%]]", "")))
end

-- An image button with a tooltip.
function sharp_inventory.button(x, y, size, texture, field, tooltip)
	return string.format("image_button[%s,%s;%s,%s;%s;%s;]tooltip[%s;%s]",
		x, y, size, size, texture, field, field, sharp_inventory.tooltip_text(tooltip))
end

-- A switch button. STATE true or false shows the on or off icon; nil
-- shows the neutral icon (not set yet, or a screen shared by everyone
-- that can't show one player's own switch).
function sharp_inventory.switch_button(x, y, size, field, state, tooltip)
	local texture = "sharp_inventory_sort.png"
	if state == true then
		texture = "sharp_inventory_sort_on.png"
	elseif state == false then
		texture = "sharp_inventory_sort_off.png"
	end
	return sharp_inventory.button(x, y, size, texture, field, tooltip)
end

-- The inventory switch, showing PLAYER's state.
function sharp_inventory.toggle_button(x, y, size, player)
	local S = sharp_inventory.S
	local on = sharp_inventory.autosort_enabled(player)
	local tooltip
	if on then
		tooltip = S("Inventory auto-sort is on. Click to turn it off.")
	else
		tooltip = S("Inventory auto-sort is off. Click to turn it on.")
	end
	return sharp_inventory.switch_button(x, y, size, sharp_inventory.FIELD, on, tooltip)
end

-- "Sort now" buttons: one for the player's inventory (never the hotbar),
-- one for the container being viewed.
function sharp_inventory.sort_inv_button(x, y, size)
	return sharp_inventory.button(x, y, size, "sharp_inventory_sortnow.png",
		sharp_inventory.SORT_INV_FIELD, sharp_inventory.S("Sort your inventory now (not the hotbar)"))
end

function sharp_inventory.sort_here_button(x, y, size)
	return sharp_inventory.button(x, y, size, "sharp_inventory_sortnow.png",
		sharp_inventory.SORT_HERE_FIELD, sharp_inventory.S("Sort this container now"))
end
