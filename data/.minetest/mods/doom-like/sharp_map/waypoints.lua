-- Waypoints: a personal list per player, saved in player metadata, shown
-- as on-screen HUD markers (type "waypoint": name, distance and color).
--
-- Each waypoint is plain data: { name, pos = {x, y, z}, color = 0xRRGGBB,
-- icon = icon id, mode = label mode, pinned = true or nil, cat = category
-- name ("" is General), dim = dimension or nil, death = true or nil }.
-- "shown" is derived.
--
-- Categories (1.2.0): each player has an ordered list of categories
-- { name, collapsed, color = 0xRRGGBB, icon = icon id } (color and icon
-- since 1.2.2, shown in the sidebar list), saved beside the waypoints. "" is the General
-- category: it always exists, new waypoints go there unless another is
-- chosen, and deleting any other category moves its waypoints into it.
-- The waypoint list is kept in display order inside each category, so
-- moving a waypoint up or down is a swap in the stored list.
--
-- On screen, a waypoint is its icon, plus its name and distance (the label)
-- when that is wanted. Label modes:
--   auto    icon always; label when near (sharp_map.label_distance), when
--           the player looks at it (sharp_map.look_angle), or when pinned
--   always  icon and label always
--   icon    icon only (label only when pinned)
--   hidden  nothing (unless pinned)
-- One waypoint per player can be pinned: it always shows its label.
--
-- Icons are the mod's own 16x16 textures (textures/sharp_map_icon_*.png):
-- white shapes with a dark outline, tinted with the waypoint's color by
-- ^[multiply, so any icon works with any color.
--
-- Dimensions: Mineclonia's dimensions are stacked at different heights, so
-- a Nether waypoint seen from the Overworld would show a huge distance.
-- mcl_worlds.pos_to_dimension (release 39338) returns "overworld",
-- "nether", "end" or "void"; markers only show in the dimension they were
-- made in. Without mcl_worlds every marker shows.

local S = sharp_map.S
local cfg = sharp_map.settings

local META_KEY = "sharp_map:waypoints"
local CATS_KEY = "sharp_map:categories"
local NAME_MAX = 40 -- bytes
local CAT_NAME_MAX = 24 -- bytes
-- A new category's look: yellow (from the palette below) and a flag.
local CAT_COLOR, CAT_ICON = 0xFFEE55, "flag"
local MAX_CATEGORIES = 20

-- Fixed palette, so formspec input is an index and never a raw color.
sharp_map.COLORS = {
	{ S("White"), 0xFFFFFF },
	{ S("Red"), 0xFF5555 },
	{ S("Orange"), 0xFFAA33 },
	{ S("Yellow"), 0xFFEE55 },
	{ S("Green"), 0x66DD66 },
	{ S("Aqua"), 0x55DDDD },
	{ S("Blue"), 0x6699FF },
	{ S("Purple"), 0xCC77FF },
}
local DEATH_COLOR = 0xFF5555

-- Label modes, in the order the sidebar button cycles through them.
sharp_map.LABEL_MODES = { "auto", "always", "icon", "hidden" }
local MODE_NAMES = { auto = S("Auto"), always = S("Always"), icon = S("Icon only"), hidden = S("Hidden") }
local is_mode = { auto = true, always = true, icon = true, hidden = true }

function sharp_map.label_mode_name(mode)
	return MODE_NAMES[mode] or mode
end

-- Visible at all (on screen, on the map and on the minimap)?
local function update_shown(wp)
	wp.shown = wp.mode ~= "hidden" or wp.pinned == true
end

-- Icon ids, in picker order, with their display names.
sharp_map.ICONS = {
	-- markers
	{ "dot", S("Dot") }, { "home", S("Home") }, { "flag", S("Flag") }, { "star", S("Star") },
	{ "heart", S("Heart") }, { "question", S("Question mark") }, { "key", S("Key") },
	-- tools and combat
	{ "skull", S("Skull") }, { "sword", S("Sword") }, { "axe", S("Axe") }, { "pickaxe", S("Pickaxe") },
	{ "shield", S("Shield") }, { "bow", S("Bow") }, { "chest", S("Chest") },
	-- blocks and places
	{ "bed", S("Bed") }, { "crafting", S("Crafting table") }, { "furnace", S("Furnace") },
	{ "anvil", S("Anvil") }, { "bell", S("Bell") }, { "portal", S("Portal") }, { "eye", S("Eye") },
	{ "diamond", S("Diamond") }, { "ingot", S("Ingot") }, { "torch", S("Torch") }, { "boat", S("Boat") },
	{ "fire", S("Fire") }, { "water", S("Water") }, { "cave", S("Cave") },
	-- nature
	{ "tree", S("Tree") }, { "pine", S("Pine tree") }, { "cactus", S("Cactus") }, { "flower", S("Flower") },
	{ "mushroom", S("Mushroom") }, { "wheat", S("Wheat") }, { "mountain", S("Mountain") },
	-- animals
	{ "pig", S("Pig") }, { "sheep", S("Sheep") }, { "cow", S("Cow") }, { "chicken", S("Chicken") },
	{ "horse", S("Horse") }, { "wolf", S("Wolf") }, { "fish", S("Fish") },
	-- monsters and villagers
	{ "mob", S("Mob") }, { "zombie", S("Zombie") }, { "spider", S("Spider") }, { "slime", S("Slime") },
	{ "enderman", S("Enderman") }, { "villager", S("Villager") }, { "bee", S("Bee") },
}
local is_icon = {}
for _, icon in ipairs(sharp_map.ICONS) do
	is_icon[icon[1]] = true
end
sharp_map.is_icon = is_icon

function sharp_map.icon_texture(icon, color)
	return ("sharp_map_icon_%s.png^[multiply:#%06X"):format(is_icon[icon] and icon or "dot", color)
end

local pos_to_dimension
if core.global_exists("mcl_worlds") and type(mcl_worlds.pos_to_dimension) == "function" then
	pos_to_dimension = mcl_worlds.pos_to_dimension
end

local function dimension_of(pos)
	if pos_to_dimension then
		local ok, dim = pcall(pos_to_dimension, pos)
		if ok and type(dim) == "string" then
			return dim
		end
	end
	return nil
end
sharp_map.dimension_of = dimension_of

local lists = {} -- player name -> list of waypoints
local cat_lists = {} -- player name -> list of categories
local huds = {}  -- player name -> list of HUD ids
local dims = {}  -- player name -> dimension the HUD was built for

------------------------------------------------------------------------
-- Storage
------------------------------------------------------------------------

-- Keep only well-formed entries from stored JSON.
local function clean(list)
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	for _, wp in ipairs(list) do
		if type(wp) == "table" and type(wp.name) == "string" and type(wp.pos) == "table"
				and tonumber(wp.pos.x) and tonumber(wp.pos.y) and tonumber(wp.pos.z) then
			out[#out + 1] = {
				name = wp.name:sub(1, NAME_MAX),
				pos = vector.new(tonumber(wp.pos.x), tonumber(wp.pos.y), tonumber(wp.pos.z)),
				color = tonumber(wp.color) or 0xFFFFFF,
				icon = is_icon[wp.icon] and wp.icon or "dot",
				-- Lists saved before label modes had only shown = true / false.
				mode = is_mode[wp.mode] and wp.mode or (wp.shown == false and "hidden" or "auto"),
				pinned = wp.pinned == true or nil,
				cat = type(wp.cat) == "string" and wp.cat:sub(1, CAT_NAME_MAX) or "",
				dim = type(wp.dim) == "string" and wp.dim or nil,
				death = wp.death == true or nil,
			}
			update_shown(out[#out])
		end
	end
	-- At most one pinned waypoint.
	local seen = false
	for _, wp in ipairs(out) do
		if wp.pinned then
			if seen then
				wp.pinned = nil
				update_shown(wp)
			end
			seen = true
		end
	end
	return out
end

local function load(player)
	local raw = player:get_meta():get_string(META_KEY)
	local list = raw ~= "" and core.parse_json(raw) or nil
	return clean(list)
end

-- Categories from player metadata, made consistent with the waypoints:
-- General ("") always exists, names are unique, and a category a
-- waypoint names but the list lacks is added rather than lost.
local function load_categories(player, list)
	local raw = player:get_meta():get_string(CATS_KEY)
	local stored = raw ~= "" and core.parse_json(raw) or nil
	local out, seen = {}, {}
	if type(stored) == "table" then
		for _, c in ipairs(stored) do
			if type(c) == "table" and type(c.name) == "string" then
				local name = c.name:sub(1, CAT_NAME_MAX)
				if not seen[name] and #out < MAX_CATEGORIES then
					seen[name] = true
					out[#out + 1] = { name = name, collapsed = c.collapsed == true or nil,
						color = tonumber(c.color) or CAT_COLOR,
						icon = sharp_map.is_icon[c.icon] and c.icon or CAT_ICON }
				end
			end
		end
	end
	if not seen[""] then
		seen[""] = true
		table.insert(out, 1, { name = "", color = CAT_COLOR, icon = CAT_ICON })
	end
	for _, wp in ipairs(list) do
		if not seen[wp.cat] then
			if #out < MAX_CATEGORIES then
				seen[wp.cat] = true
				out[#out + 1] = { name = wp.cat, color = CAT_COLOR, icon = CAT_ICON }
			else
				wp.cat = ""
			end
		end
	end
	return out
end

local function save(player)
	local list = lists[player:get_player_name()]
	local plain = {}
	for i, wp in ipairs(list) do
		plain[i] = {
			name = wp.name,
			pos = { x = wp.pos.x, y = wp.pos.y, z = wp.pos.z },
			color = wp.color,
			icon = wp.icon,
			mode = wp.mode,
			pinned = wp.pinned,
			cat = wp.cat ~= "" and wp.cat or nil,
			dim = wp.dim,
			death = wp.death,
		}
	end
	local meta = player:get_meta()
	meta:set_string(META_KEY, #plain > 0 and core.write_json(plain) or "")
	-- Only General, not collapsed: nothing worth storing.
	local cats = cat_lists[player:get_player_name()]
	local plain_cats = {}
	for i, c in ipairs(cats or {}) do
		plain_cats[i] = { name = c.name, collapsed = c.collapsed, color = c.color, icon = c.icon }
	end
	local only = plain_cats[1]
	local trivial = #plain_cats <= 1 and not (only and (only.collapsed or only.color ~= CAT_COLOR
		or only.icon ~= CAT_ICON))
	meta:set_string(CATS_KEY, trivial and "" or core.write_json(plain_cats))
end

function sharp_map.get_waypoints(player)
	local name = player:get_player_name()
	if not lists[name] then
		lists[name] = load(player)
		cat_lists[name] = load_categories(player, lists[name])
	end
	return lists[name]
end

function sharp_map.get_categories(player)
	sharp_map.get_waypoints(player)
	return cat_lists[player:get_player_name()]
end

-- The name a category is shown under.
function sharp_map.category_label(cat)
	return cat.name == "" and S("General") or cat.name
end

local function category_index(cats, name)
	for i, c in ipairs(cats) do
		if c.name == name then
			return i
		end
	end
end
sharp_map.category_index = category_index

-- The rows of the sidebar list, top to bottom: the pinned waypoint first,
-- then each category (a header row, only when there is more than General)
-- with its waypoints unless it is collapsed. Rows are
-- { kind = "wp", index = waypoint index, pinned = true or nil } or
-- { kind = "cat", index = category index, count = waypoints in it }.
function sharp_map.list_rows(player)
	local list = sharp_map.get_waypoints(player)
	local cats = cat_lists[player:get_player_name()]
	local rows = {}
	for i, wp in ipairs(list) do
		if wp.pinned then
			rows[#rows + 1] = { kind = "wp", index = i, pinned = true }
		end
	end
	local headers = #cats > 1
	for ci, cat in ipairs(cats) do
		local members, count = {}, 0
		for i, wp in ipairs(list) do
			if wp.cat == cat.name then
				count = count + 1
				if not wp.pinned then
					members[#members + 1] = i
				end
			end
		end
		if headers then
			rows[#rows + 1] = { kind = "cat", index = ci, count = count }
		end
		if not (headers and cat.collapsed) then
			for _, i in ipairs(members) do
				rows[#rows + 1] = { kind = "wp", index = i, indent = headers }
			end
		end
	end
	return rows
end

------------------------------------------------------------------------
-- HUD markers
------------------------------------------------------------------------

-- Should WP show its label? DIST is its distance, LOOKED whether it is the
-- waypoint the player is looking at.
local function wants_label(wp, dist, looked)
	if wp.pinned or wp.mode == "always" then
		return true
	elseif wp.mode ~= "auto" then
		return false
	end
	return looked or (cfg.label_distance > 0 and dist <= cfg.label_distance)
end

local function label_def(wp)
	return {
		type = "waypoint",
		name = wp.name,
		text = "m",
		precision = 1,
		number = wp.color,
		world_pos = wp.pos,
		z_index = -300,
	}
end

local COS_LOOK = math.cos(math.rad(cfg.look_angle))

-- Add or remove labels as the player moves and looks around. Only the
-- waypoint closest to the crosshair (within look_angle) counts as looked at.
function sharp_map.update_labels(player)
	local entries = huds[player:get_player_name()]
	if not entries or #entries == 0 then
		return
	end
	local props = player:get_properties()
	local eye = vector.add(player:get_pos(), vector.new(0, props.eye_height or 1.47, 0))
	local dir = player:get_look_dir()
	local best, best_dot = nil, cfg.look_angle > 0 and COS_LOOK or 2
	for _, e in ipairs(entries) do
		local d = vector.subtract(e.wp.pos, eye)
		local dist = vector.length(d)
		e.dist = dist
		if e.wp.mode == "auto" and dist > 0 then
			local dot = vector.dot(dir, d) / dist
			if dot >= best_dot then
				best, best_dot = e, dot
			end
		end
	end
	for _, e in ipairs(entries) do
		local want = wants_label(e.wp, e.dist, e == best)
		if want and not e.label then
			e.label = player:hud_add(label_def(e.wp))
		elseif not want and e.label then
			player:hud_remove(e.label)
			e.label = nil
		end
	end
end

function sharp_map.refresh_hud(player)
	local name = player:get_player_name()
	for _, e in ipairs(huds[name] or {}) do
		player:hud_remove(e.icon)
		if e.label then
			player:hud_remove(e.label)
		end
	end
	local entries = {}
	local here = dimension_of(player:get_pos())
	for _, wp in ipairs(sharp_map.get_waypoints(player)) do
		if wp.shown and (not here or not wp.dim or wp.dim == here) then
			-- The icon; the label (name and distance) sits just below it.
			entries[#entries + 1] = {
				wp = wp,
				icon = player:hud_add({
					type = "image_waypoint",
					text = sharp_map.icon_texture(wp.icon, wp.color),
					scale = { x = 2, y = 2 },
					world_pos = wp.pos,
					offset = { x = 0, y = -20 },
					z_index = -300,
				}),
			}
		end
	end
	huds[name] = entries
	dims[name] = here
	sharp_map.update_labels(player)
	if sharp_map.hudmap_waypoints_changed then
		sharp_map.hudmap_waypoints_changed(player)
	end
end

-- Labels follow where the player is and looks: checked 4 times a second.
local label_timer = 0
core.register_globalstep(function(dtime)
	label_timer = label_timer + dtime
	if label_timer < 0.25 then
		return
	end
	label_timer = 0
	for _, player in ipairs(core.get_connected_players()) do
		sharp_map.update_labels(player)
	end
end)

------------------------------------------------------------------------
-- Editing (all input is validated here, never trusted from formspecs)
------------------------------------------------------------------------

-- Trim, drop control characters and cap the length. Returns nil if empty.
function sharp_map.clean_name(text)
	if type(text) ~= "string" then
		return nil
	end
	text = text:gsub("%c", ""):match("^%s*(.-)%s*$")
	if text == "" then
		return nil
	end
	return text:sub(1, NAME_MAX)
end

-- Add a waypoint at the player's feet, in category CAT (a name; General if
-- nil or unknown). Returns the new index, or nil and an error message.
function sharp_map.add_waypoint(player, name, color, icon, cat)
	local list = sharp_map.get_waypoints(player)
	if #list >= cfg.max_waypoints then
		return nil, S("You already have @1 waypoints. Delete one first.", cfg.max_waypoints)
	end
	local cats = cat_lists[player:get_player_name()]
	local ci = category_index(cats, cat or "") or category_index(cats, "")
	local pos = vector.round(player:get_pos())
	list[#list + 1] = {
		name = sharp_map.clean_name(name) or S("Waypoint @1", #list + 1),
		pos = pos,
		color = color or 0xFFFFFF,
		icon = is_icon[icon] and icon or "dot",
		mode = "auto",
		shown = true,
		cat = cats[ci].name,
		dim = dimension_of(pos),
	}
	-- A new waypoint is never hidden inside a collapsed category.
	cats[ci].collapsed = nil
	save(player)
	sharp_map.refresh_hud(player)
	return #list
end

-- Change a waypoint. CAT, if given, moves it to that category (to the end
-- of it). Returns its index afterwards, or nil if there is no such one.
function sharp_map.update_waypoint(player, index, name, color, icon, cat)
	local list = sharp_map.get_waypoints(player)
	local wp = list[index]
	if not wp then
		return nil
	end
	wp.name = sharp_map.clean_name(name) or wp.name
	wp.color = color or wp.color
	wp.icon = is_icon[icon] and icon or wp.icon
	local cats = cat_lists[player:get_player_name()]
	if cat and cat ~= wp.cat and category_index(cats, cat) then
		wp.cat = cat
		table.remove(list, index)
		list[#list + 1] = wp
		index = #list
	end
	save(player)
	sharp_map.refresh_hud(player)
	return index
end

-- Indices of the waypoints in category NAME, in display order.
local function members(list, name)
	local out = {}
	for i, wp in ipairs(list) do
		if wp.cat == name then
			out[#out + 1] = i
		end
	end
	return out
end

-- Move waypoint INDEX one place up (DELTA -1) or down (+1) in its
-- category. Past the top or bottom of a category it moves into the next
-- category, as its last or first waypoint. Returns its new index.
function sharp_map.move_waypoint(player, index, delta)
	local list = sharp_map.get_waypoints(player)
	local wp = list[index]
	if not wp or (delta ~= -1 and delta ~= 1) then
		return index
	end
	local cats = cat_lists[player:get_player_name()]
	local same = members(list, wp.cat)
	local at
	for k, i in ipairs(same) do
		if i == index then
			at = k
		end
	end
	local other = same[at + delta]
	if other then
		list[index], list[other] = list[other], list[index]
		index = other
	else
		local ci = category_index(cats, wp.cat) + delta
		local target = cats[ci]
		if not target then
			return index
		end
		table.remove(list, index)
		wp.cat = target.name
		target.collapsed = nil
		local into = members(list, target.name)
		if delta < 0 then
			-- Last of the category above.
			local after = into[#into]
			index = after and after + 1 or #list + 1
		else
			-- First of the category below.
			index = into[1] or #list + 1
		end
		table.insert(list, index, wp)
	end
	save(player)
	sharp_map.refresh_hud(player)
	return index
end

------------------------------------------------------------------------
-- Categories
------------------------------------------------------------------------

-- Trim and cap a category name. Returns nil if empty.
local function clean_category(text)
	local name = sharp_map.clean_name(text)
	return name and name:sub(1, CAT_NAME_MAX)
end

-- Add a category at the end. Returns its index, or nil and a message.
function sharp_map.add_category(player, name)
	local cats = sharp_map.get_categories(player)
	if #cats >= MAX_CATEGORIES then
		return nil, S("You already have @1 categories.", MAX_CATEGORIES)
	end
	name = clean_category(name)
	if not name then
		local n = #cats
		repeat
			name = S("Category @1", n)
			n = n + 1
		until not category_index(cats, name)
	end
	if category_index(cats, name) or name == S("General") then
		return nil, S("There is already a category called @1.", name)
	end
	cats[#cats + 1] = { name = name, color = CAT_COLOR, icon = CAT_ICON }
	save(player)
	return #cats
end

-- Change a category: NAME (not for General; nil or unchanged keeps it),
-- COLOR and ICON (nil keeps them). Returns true, or false and a message.
function sharp_map.update_category(player, ci, name, color, icon)
	local cats = sharp_map.get_categories(player)
	local cat = cats[ci]
	if not cat then
		return false
	end
	name = cat.name ~= "" and clean_category(name) or nil
	if name and name ~= cat.name then
		if category_index(cats, name) or name == S("General") then
			return false, S("There is already a category called @1.", name)
		end
		for _, wp in ipairs(sharp_map.get_waypoints(player)) do
			if wp.cat == cat.name then
				wp.cat = name
			end
		end
		cat.name = name
	end
	cat.color = color or cat.color
	cat.icon = sharp_map.is_icon[icon] and icon or cat.icon
	save(player)
	return true
end

-- Delete a category. Its waypoints are kept: they move to General.
function sharp_map.remove_category(player, ci)
	local cats = sharp_map.get_categories(player)
	local cat = cats[ci]
	if not cat or cat.name == "" then
		return false
	end
	local list = sharp_map.get_waypoints(player)
	-- Keep their order: they go to the end of General, in the same order.
	local moved = {}
	for i = #list, 1, -1 do
		if list[i].cat == cat.name then
			list[i].cat = ""
			table.insert(moved, 1, table.remove(list, i))
		end
	end
	for _, wp in ipairs(moved) do
		list[#list + 1] = wp
	end
	table.remove(cats, ci)
	save(player)
	sharp_map.refresh_hud(player)
	return true
end

-- Move category CI up (-1) or down (+1). Returns its new index.
function sharp_map.move_category(player, ci, delta)
	local cats = sharp_map.get_categories(player)
	local other = ci + delta
	if not cats[ci] or not cats[other] or (delta ~= -1 and delta ~= 1) then
		return ci
	end
	cats[ci], cats[other] = cats[other], cats[ci]
	save(player)
	return other
end

function sharp_map.toggle_category(player, ci)
	local cat = sharp_map.get_categories(player)[ci]
	if not cat then
		return false
	end
	cat.collapsed = not cat.collapsed or nil
	save(player)
	return true
end

-- Next label mode: auto -> always -> icon only -> hidden -> auto.
function sharp_map.cycle_label_mode(player, index)
	local wp = sharp_map.get_waypoints(player)[index]
	if not wp then
		return false
	end
	local modes = sharp_map.LABEL_MODES
	for i, mode in ipairs(modes) do
		if mode == wp.mode then
			wp.mode = modes[i % #modes + 1]
			break
		end
	end
	update_shown(wp)
	save(player)
	sharp_map.refresh_hud(player)
	return true
end

-- Pin WP (unpinning any other), or unpin it if it is pinned.
function sharp_map.toggle_pin(player, index)
	local list = sharp_map.get_waypoints(player)
	local wp = list[index]
	if not wp then
		return false
	end
	local pin = not wp.pinned
	for _, other in ipairs(list) do
		other.pinned = nil
		update_shown(other)
	end
	wp.pinned = pin or nil
	update_shown(wp)
	save(player)
	sharp_map.refresh_hud(player)
	return true
end

function sharp_map.remove_waypoint(player, index)
	local list = sharp_map.get_waypoints(player)
	if not list[index] then
		return false
	end
	table.remove(list, index)
	save(player)
	sharp_map.refresh_hud(player)
	return true
end

function sharp_map.can_teleport(player)
	if cfg.teleport == "all" then
		return true
	elseif cfg.teleport == "priv" then
		return core.check_player_privs(player, { teleport = true })
	end
	return false
end

function sharp_map.teleport(player, index)
	local wp = sharp_map.get_waypoints(player)[index]
	if not wp or not sharp_map.can_teleport(player) then
		return false
	end
	player:set_pos(wp.pos)
	return true
end

------------------------------------------------------------------------
-- Death waypoint: one per player, replaced on each death.
------------------------------------------------------------------------

if cfg.death_waypoint then
	core.register_on_dieplayer(function(player)
		local list = sharp_map.get_waypoints(player)
		-- The new death point goes where the old one was filed.
		local cat = ""
		for i = #list, 1, -1 do
			if list[i].death then
				cat = list[i].cat
				table.remove(list, i)
			end
		end
		local pos = vector.round(player:get_pos())
		table.insert(list, 1, {
			name = S("Death point"),
			pos = pos,
			color = DEATH_COLOR,
			icon = "skull",
			mode = "auto",
			shown = true,
			cat = cat,
			dim = dimension_of(pos),
			death = true,
		})
		-- The death point may push the list one over the limit; it is
		-- the one waypoint that is always kept.
		save(player)
		sharp_map.refresh_hud(player)
	end)
end

------------------------------------------------------------------------
-- Join, leave, and dimension changes
------------------------------------------------------------------------

core.register_on_joinplayer(function(player)
	sharp_map.refresh_hud(player)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	lists[name], cat_lists[name], huds[name], dims[name] = nil, nil, nil, nil
end)

-- Rebuild markers when a player changes dimension (portals, teleports).
-- mcl_worlds checks every player's dimension once a second and calls
-- registered functions on a change, so no extra loop is needed here.
if pos_to_dimension and type(mcl_worlds.register_on_dimension_change) == "function" then
	mcl_worlds.register_on_dimension_change(function(player)
		sharp_map.refresh_hud(player)
	end)
elseif pos_to_dimension then
	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer < 2 then
			return
		end
		timer = 0
		for _, player in ipairs(core.get_connected_players()) do
			if dimension_of(player:get_pos()) ~= dims[player:get_player_name()] then
				sharp_map.refresh_hud(player)
			end
		end
	end)
end
