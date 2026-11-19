-- Container screens: theme, switches and auto-sort.
--
-- Two kinds of screens (checked against mcl_chests and mcl_furnaces):
--   * Chests, double chests and the ender chest are opened with
--     core.show_formspec() (form names "mcl_chests:..."). They are built
--     per player. A chest's switch is stored in the chest (both halves of
--     a double chest) and shared by everyone; the ender chest's switch is
--     per player. The chest is sorted just before its screen appears.
--   * Furnaces (and anything else in the "furnace" groups: blast
--     furnaces, smokers, kilns...) and shulker boxes keep their screen in
--     node metadata, shared by all players. Furnaces have no auto-sort
--     switch (1.2.1); they get a Top off button that refills fuel and
--     input, and their output is never taken. Shulker boxes use each
--     player's own shulker switch and are sorted when closed. The shared
--     screen can't show one player's switch, so opening the box (its
--     on_rightclick) or clicking the switch shows that player their own
--     copy of the box's screen, with the real icon;
--     every click and the close on that copy are passed on to the box's
--     own on_receive_fields, as if the shared screen had sent them.
-- The player's main inventory (never the hotbar) follows the inventory
-- switch only: sorted whenever a screen closes, and every few seconds
-- while no screen is in use.

local modname = core.get_current_modname()
local S = sharp_inventory.S
local cfg = sharp_inventory.settings
local FIELD = sharp_inventory.FIELD
local BOX_FIELD = sharp_inventory.BOX_FIELD
local SHULKER_KEY = sharp_inventory.SHULKER_KEY
local ENDER_KEY = sharp_inventory.ENDER_KEY
local SORT_INV = sharp_inventory.SORT_INV_FIELD
local SORT_HERE = sharp_inventory.SORT_HERE_FIELD
local theme = sharp_inventory.theme

-- Only these show_formspec screens get a toggle and sorting.
local CONTAINER_FORM_PREFIXES = { "mcl_chests:" }

-- Players are left alone this long after touching an inventory, so items
-- never move while someone is arranging them.
local QUIET_US = 4 * 1000000

local open_containers = {} -- player name -> { formname, formspec, lists }
local open_shulkers = {}   -- player name -> pos of the box on their own copy
local SHULKER_FORM = "sharp_inventory:shulker"
local last_activity = {}   -- player name -> core.get_us_time()

local function touch(name)
	last_activity[name] = core.get_us_time()
end

local function update_comparators(pos)
	if core.global_exists("mcl_redstone") and type(mcl_redstone.update_comparators) == "function" then
		mcl_redstone.update_comparators(pos)
	end
end

local function say(player, text)
	core.chat_send_player(player:get_player_name(), text)
end

-- Players may only change a block's setting where they may build.
local function allowed(pos, player)
	local name = player:get_player_name()
	if core.is_protected(pos, name) then
		core.record_protection_violation(pos, name)
		return false
	end
	return true
end

------------------------------------------------------------------------
-- Chests and ender chest (core.show_formspec)
------------------------------------------------------------------------

local function is_container_form(formname)
	if type(formname) ~= "string" then
		return false
	end
	for _, prefix in ipairs(CONTAINER_FORM_PREFIXES) do
		if formname:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- Read which container lists a chest screen shows, in display order.
local function find_lists(formspec)
	local lists, seen = {}, {}
	local N = "(%-?[%d%.]+)"
	for x, y, z in formspec:gmatch("list%[nodemeta:" .. N .. "," .. N .. "," .. N .. ";main;") do
		local key = x .. "," .. y .. "," .. z
		if not seen[key] then
			seen[key] = true
			lists[#lists + 1] = { pos = vector.new(tonumber(x), tonumber(y), tonumber(z)) }
		end
	end
	if formspec:find("list[current_player;enderchest;", 1, true) then
		lists[#lists + 1] = { ender = true }
	end
	return #lists > 0 and lists or nil
end

local function sort_chest(player, lists)
	local name = player:get_player_name()
	local sources = {}
	for _, l in ipairs(lists) do
		if l.ender then
			sources[#sources + 1] = { inv = player:get_inventory(), list = "enderchest" }
		else
			if core.is_protected(l.pos, name) then
				return
			end
			sources[#sources + 1] = { inv = core.get_meta(l.pos):get_inventory(), list = "main" }
		end
	end
	if sharp_inventory.sort_lists(sources) then
		for _, l in ipairs(lists) do
			if l.pos then
				update_comparators(l.pos)
			end
		end
	end
end

-- The setting of an open chest screen: the first half that has one, or
-- the player's ender chest switch. nil means not set.
local function chest_switch(player, lists)
	for _, l in ipairs(lists) do
		local on
		if l.ender then
			on = sharp_inventory.player_switch(player, ENDER_KEY)
		else
			on = sharp_inventory.node_switch(l.pos)
		end
		if on ~= nil then
			return on
		end
	end
	return nil
end

local function chest_enabled(player, lists)
	local on = chest_switch(player, lists)
	if on == nil then
		return sharp_inventory.autosort_enabled(player)
	end
	return on
end

-- Flip the setting of an open chest screen; both halves of a double chest
-- get the same value. Returns the new state, or nil if protected.
local function toggle_chest(player, lists)
	for _, l in ipairs(lists) do
		if l.pos and not allowed(l.pos, player) then
			return nil
		end
	end
	local on = not chest_enabled(player, lists)
	for _, l in ipairs(lists) do
		if l.ender then
			sharp_inventory.set_player_switch(player, ENDER_KEY, on)
		else
			sharp_inventory.set_node_switch(l.pos, on)
		end
	end
	return on
end

local function chest_toggle_button(x, y, size, player, lists)
	local state = chest_switch(player, lists)
	local tooltip
	if state == true then
		tooltip = S("This container: auto-sort is on. Click to turn it off.")
	elseif state == false then
		tooltip = S("This container: auto-sort is off. Click to turn it on.")
	else
		tooltip = S("This container follows your inventory auto-sort switch. Click to set it on its own.")
	end
	return sharp_inventory.switch_button(x, y, size, BOX_FIELD, state, tooltip)
end

-- Chest screens are 11.75 wide; the toggle sits in the top-right corner,
-- level with the chest's name label.
local CHEST_TOGGLE_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE = 10.825, 0.1, 0.55
-- The container's "sort now" button sits just left of the toggle.
local CHEST_SORT_X = CHEST_TOGGLE_X - 0.65

-- Mineclonia draws the player's storage rows (main slots 10-36, never the
-- hotbar) on chests, furnaces and other screens the same way:
-- list[current_player;main;X,Y;9,3;9]. Its "sort now" button goes just
-- above the list's right end, level with the "Inventory" label.
local STORAGE_LIST = "list%[current_player;main;([%d%.]+),([%d%.]+);9,3;9%]"
local LIST_WIDTH = 11 -- 9 slots of 1 unit with 0.25 spacing

local function inv_sort_button(formspec)
	local x, y = formspec:match(STORAGE_LIST)
	if not x then
		return ""
	end
	return sharp_inventory.sort_inv_button(tonumber(x) + LIST_WIDTH - 0.55, tonumber(y) - 0.65, 0.55)
end

-- Every show_formspec screen is themed here (this catches screens built
-- once at load time, such as the ender chest). Any screen showing the
-- player's storage rows (chests, crafting stations...) gets an inventory
-- "sort now" button. Container screens also get sorted and receive their
-- own "sort now" button and the toggle.
local orig_show_formspec = core.show_formspec
function core.show_formspec(playername, formname, formspec)
	formspec = theme(formspec)
	open_containers[playername] = nil
	open_shulkers[playername] = nil
	if type(formspec) ~= "string" then
		return orig_show_formspec(playername, formname, formspec)
	end
	local extra = ""
	if not formspec:find(SORT_INV, 1, true) then
		extra = inv_sort_button(formspec)
	end
	if is_container_form(formname) then
		local lists = find_lists(formspec)
		local player = lists and core.get_player_by_name(playername)
		if player then
			open_containers[playername] = { formname = formname, formspec = formspec, lists = lists }
			if chest_enabled(player, lists) then
				sort_chest(player, lists)
			end
			extra = extra .. sharp_inventory.sort_here_button(CHEST_SORT_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE)
				.. chest_toggle_button(CHEST_TOGGLE_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE, player, lists)
		end
	end
	return orig_show_formspec(playername, formname, formspec .. extra)
end

------------------------------------------------------------------------
-- Furnaces and shulker boxes (formspec in node metadata)
------------------------------------------------------------------------

local function kind_of(def)
	local groups = def and def.groups or {}
	if (groups.furnace or 0) ~= 0 or (groups.furnace_active or 0) ~= 0 then
		return "furnace"
	elseif (groups.shulker_box or 0) ~= 0 then
		return "shulker"
	end
end

local TOPOFF_FIELD = "sharp_inventory_topoff"

local NODE_BUTTONS = {
	-- Top off: left of the input/fire/fuel column it fills.
	furnace = function()
		return sharp_inventory.button(2, 2, 1, "sharp_inventory_topoff.png", TOPOFF_FIELD,
			S("Top off fuel and input with more of the same from your inventory"))
	end,
	-- Shulker boxes use the chest layout. The stored screen is shared, so
	-- its switch shows the neutral icon.
	shulker = function()
		return sharp_inventory.sort_here_button(CHEST_SORT_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE)
			.. sharp_inventory.switch_button(CHEST_TOGGLE_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE, BOX_FIELD, nil,
				S("Your shulker box auto-sort switch. When on, boxes are sorted when you close them."))
	end,
}

-- A shulker box switch showing PLAYER's own state.
local function shulker_toggle_button(player)
	local on = sharp_inventory.player_switch_enabled(player, SHULKER_KEY)
	local tooltip
	if on then
		tooltip = S("Your shulker box auto-sort is on. Click to turn it off.")
	else
		tooltip = S("Your shulker box auto-sort is off. Click to turn it on.")
	end
	return sharp_inventory.switch_button(CHEST_TOGGLE_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE,
		BOX_FIELD, on, tooltip)
end

-- Every element this mod has ever added to a stored screen: an
-- image_button with a sharp_inventory_* field, followed by its tooltip.
local OWN_ELEMENTS = "image_button%[[^%]]*;sharp_inventory_[%w_]+;%]tooltip%[sharp_inventory_[%w_]+;[^%]]*%]"

-- Theme the stored screen and (re)add this mod's buttons. Removing the old
-- ones first keeps screens current when buttons or tooltips change.
-- Idempotent, and only writes metadata when something changed.
local function refresh_node(pos, kind)
	local meta = core.get_meta(pos)
	if kind == "furnace" and meta:get_string("sharp_inventory:autosort") ~= "" then
		-- Furnace switch from the 1.2.0 test build; furnaces have none now.
		meta:set_string("sharp_inventory:autosort", "")
	end
	local formspec = meta:get_string("formspec")
	if formspec == "" then
		return
	end
	local base = theme(formspec):gsub(OWN_ELEMENTS, "")
	local new = base .. NODE_BUTTONS[kind](pos) .. inv_sort_button(base)
	if new ~= formspec then
		meta:set_string("formspec", new)
	end
end

-- Top up LISTNAME (fuel or src) with more of what is already in it. An
-- empty slot is never filled, so nothing valuable gets burned by surprise.
local function top_up(pos, def, ninv, pinv, listname, player)
	local slot = ninv:get_stack(listname, 1)
	if slot:is_empty() then
		return
	end
	local id = sharp_inventory.ident(slot)
	local want = math.min(slot:get_free_space(), sharp_inventory.count_in_storage(pinv, id))
	if want <= 0 then
		return
	end
	local offer = ItemStack(slot)
	offer:set_count(want)
	if def.allow_metadata_inventory_put then
		local allowed = def.allow_metadata_inventory_put(pos, listname, 1, ItemStack(offer), player)
		if allowed ~= -1 then
			want = math.min(want, allowed or 0)
		end
	end
	if want <= 0 then
		return
	end
	local got = sharp_inventory.take_from_storage(pinv, id, want)
	if got <= 0 then
		return
	end
	local added = ItemStack(offer)
	added:set_count(got)
	slot:add_item(added)
	ninv:set_stack(listname, 1, slot)
	if def.on_metadata_inventory_put then
		def.on_metadata_inventory_put(pos, listname, 1, added, player)
	end
end

-- Only touch a node the player may use, and that is still what we hooked.
local function usable_def(pos, kind, player)
	if core.is_protected(pos, player:get_player_name()) then
		return nil
	end
	local def = core.registered_nodes[core.get_node(pos).name]
	if def and kind_of(def) == kind then
		return def
	end
end

-- Top-off button. The output is never taken: collecting it by hand is
-- part of the reward of smelting.
local function top_off(pos, player)
	local def = usable_def(pos, "furnace", player)
	if not def then
		return
	end
	local ninv = core.get_meta(pos):get_inventory()
	local pinv = player:get_inventory()
	top_up(pos, def, ninv, pinv, "fuel", player)
	top_up(pos, def, ninv, pinv, "src", player)
end

local function sort_shulker(pos, player)
	if not usable_def(pos, "shulker", player) then
		return
	end
	local ninv = core.get_meta(pos):get_inventory()
	if sharp_inventory.sort_lists({ { inv = ninv, list = "main" } }) then
		update_comparators(pos)
	end
end

-- Show PLAYER their own copy of a shulker box's stored screen, with their
-- own switch. "context" lists become "nodemeta:x,y,z" so the copy shows
-- the same box; the box's inventory callbacks still apply to it.
local function show_own_shulker(pos, player)
	local formspec = core.get_meta(pos):get_string("formspec")
	if formspec == "" then
		return
	end
	local loc = "nodemeta:" .. pos.x .. "," .. pos.y .. "," .. pos.z
	local base = formspec:gsub(OWN_ELEMENTS, "")
	base = base:gsub("(list%[)context;", "%1" .. loc .. ";"):gsub("(listring%[)context;", "%1" .. loc .. ";")
	local name = player:get_player_name()
	core.show_formspec(name, SHULKER_FORM, base
		.. sharp_inventory.sort_here_button(CHEST_SORT_X, CHEST_TOGGLE_Y, CHEST_TOGGLE_SIZE)
		.. shulker_toggle_button(player))
	-- After show_formspec, which clears this player's open screens.
	open_shulkers[name] = vector.new(pos.x, pos.y, pos.z)
end

local function on_node_fields(pos, kind, fields, sender)
	if not sender or not sender:is_player() then
		return
	end
	touch(sender:get_player_name())
	if kind == "furnace" and fields[TOPOFF_FIELD] then
		top_off(pos, sender)
		return
	elseif fields[SORT_INV] then
		sharp_inventory.sort_player(sender)
		return
	elseif kind == "shulker" and fields[SORT_HERE] then
		sort_shulker(pos, sender)
		return
	end
	-- FIELD: the 1.1.0 toggle, still on screens stored before 1.2.0 when
	-- update_stored_formspecs is off. Furnaces have no switch any more, so
	-- a click from an old furnace screen does nothing.
	if fields[BOX_FIELD] or fields[FIELD] then
		if kind == "shulker" then
			local on = sharp_inventory.toggle_player_switch(sender, SHULKER_KEY)
			say(sender, on and S("Shulker box auto-sort turned on.")
				or S("Shulker box auto-sort turned off."))
			if on then
				sort_shulker(pos, sender)
			end
			show_own_shulker(pos, sender) -- redraws the icon and tooltip
		end
		return
	end
	if fields.quit then
		if kind == "shulker" and sharp_inventory.player_switch_enabled(sender, SHULKER_KEY) then
			sort_shulker(pos, sender)
		end
		-- The inventory switch: sorted whenever a screen closes.
		if sharp_inventory.autosort_enabled(sender) then
			sharp_inventory.sort_player(sender)
		end
	end
end

-- Wrap a callback so the stored screen is refreshed after it ran.
local function then_refresh(orig, kind)
	return function(pos, ...)
		local result = orig(pos, ...)
		refresh_node(pos, kind)
		return result -- on_timer's return value restarts the timer.
	end
end

-- Done after all mods loaded, so smokers, blast furnaces and anything
-- else in these groups is included, whichever mod registers them.
core.register_on_mods_loaded(function()
	local targets = {}
	for name, def in pairs(core.registered_nodes) do
		local kind = kind_of(def)
		if kind then
			targets[name] = kind
		end
	end
	local count = 0
	for name, kind in pairs(targets) do
		local def = core.registered_nodes[name]
		local redef = {}
		for _, cb in ipairs({ "on_construct", "after_place_node", "on_timer" }) do
			if def[cb] then
				redef[cb] = then_refresh(def[cb], kind)
			end
		end
		if kind == "shulker" then
			-- Opening a box: the game shows the shared stored screen and
			-- still runs on_rightclick on the server (Mineclonia's opening
			-- animation relies on it). Replace the shared screen with the
			-- player's own copy, so the switch shows their state at once.
			local orig_rightclick = def.on_rightclick
			redef.on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
				local result = itemstack
				if orig_rightclick then
					result = orig_rightclick(pos, node, clicker, itemstack, pointed_thing)
				end
				-- Only if the box is still there after Mineclonia's handler.
				local now = core.registered_nodes[core.get_node(pos).name]
				if clicker and clicker:is_player() and kind_of(now) == "shulker" then
					show_own_shulker(pos, clicker)
				end
				return result
			end
		end
		local orig_fields = def.on_receive_fields
		redef.on_receive_fields = function(pos, formname, fields, sender)
			if orig_fields then
				orig_fields(pos, formname, fields, sender)
			end
			on_node_fields(pos, kind, fields, sender)
		end
		core.override_item(name, redef)
		count = count + 1
	end
	core.log("action", "[" .. modname .. "] Added buttons to " .. count
		.. " furnace and shulker box nodes.")
end)

-- Update screens already stored in the world as their blocks load.
if cfg.update_stored then
	core.register_lbm({
		label = "Theme stored furnace and shulker box screens",
		name = modname .. ":update_stored_formspecs",
		nodenames = { "group:furnace", "group:furnace_active", "group:shulker_box" },
		run_at_every_load = true,
		action = function(pos, node)
			local kind = kind_of(core.registered_nodes[node.name])
			if kind then
				refresh_node(pos, kind)
			end
		end,
	})
end

------------------------------------------------------------------------
-- Fields from show_formspec screens and the player inventory
------------------------------------------------------------------------

core.register_on_player_inventory_action(function(player)
	touch(player:get_player_name())
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	local name = player:get_player_name()
	touch(name)

	-- A player's own copy of a shulker box screen: pass everything on to
	-- the box, as the shared screen would have. The position comes from
	-- the server's own record, never from the client.
	if formname == SHULKER_FORM then
		local pos = open_shulkers[name]
		if fields.quit then
			open_shulkers[name] = nil
		end
		if pos then
			local def = core.registered_nodes[core.get_node(pos).name]
			if def and kind_of(def) == "shulker" and def.on_receive_fields then
				def.on_receive_fields(pos, "", fields, player)
			end
		end
		return true
	end

	local open = open_containers[name]

	-- "Sort now" buttons work whether auto-sort is on or off. Sorting the
	-- player's own storage rows is harmless from any screen.
	if fields[SORT_INV] then
		sharp_inventory.sort_player(player)
		return
	elseif fields[SORT_HERE] then
		if open and open.formname == formname then
			sort_chest(player, open.lists)
		end
		return
	end

	if fields[FIELD] then
		-- The inventory switch (survival and creative inventory): sort now
		-- if turned on, then redraw the icon.
		if sharp_inventory.toggle_autosort(player) then
			sharp_inventory.sort_player(player)
		end
		if formname == "" then
			sharp_inventory.refresh_survival(player)
		end
		return
	end

	if fields[BOX_FIELD] then
		-- A chest or ender chest switch. Re-showing the same screen sorts
		-- the chest if it is now on and redraws the icon.
		if open and open.formname == formname then
			local on = toggle_chest(player, open.lists)
			if on ~= nil then
				say(player, on and S("Auto-sort for this container turned on.")
					or S("Auto-sort for this container turned off."))
				core.show_formspec(name, open.formname, open.formspec)
			end
		end
		return
	end

	if fields.quit then
		-- Any screen closing means no chest screen is open any more (one
		-- can also vanish via core.close_formspec without a quit).
		open_containers[name] = nil
		if sharp_inventory.autosort_enabled(player) then
			sharp_inventory.sort_player(player)
		end
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	open_containers[name] = nil
	open_shulkers[name] = nil
	last_activity[name] = nil
end)

------------------------------------------------------------------------
-- Periodic sort of the player inventory while no screen is in use
------------------------------------------------------------------------

-- Picks up items gathered while walking around. A sorted inventory sorts
-- to itself, so this only moves anything after the contents changed.
local timer = 0
core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < cfg.autosort_interval then
		return
	end
	timer = 0
	local now = core.get_us_time()
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if not open_containers[name]
				and now - (last_activity[name] or 0) >= QUIET_US
				and sharp_inventory.autosort_enabled(player) then
			sharp_inventory.sort_player(player)
		end
	end
end)
