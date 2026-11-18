local S = core.get_translator(core.get_current_modname())
local storage = core.get_mod_storage()
local hive = {}
local prefix = "mcl_siege_hives:"
local HEART, RIB, TRAP, NEST, CACHE = prefix .. "heart", prefix .. "rib",
	prefix .. "trap", prefix .. "nest", prefix .. "cache"
local CELL_SIZE = 192
local MIN_SPACING = 256
local GROW_INTERVAL = 12
local CARDINAL = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
local building = {}
local block_groups = { pickaxey = 1, opaque = 1, not_in_creative_inventory = 1 }
local wall_texture = "mcl_blackstone_polished_bricks.png^[colorize:#511734:62"

local function cell_key(x, z)
	return ("hive_%d_%d"):format(x, z)
end

function hive.site_available(pos)
	local x, z = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
	if storage:contains(cell_key(x, z)) then
		return false
	end
	for dx = -2, 2 do
		for dz = -2, 2 do
			local previous = core.string_to_pos(storage:get_string(cell_key(x + dx, z + dz)))
			if previous then
				local px, pz = previous.x - pos.x, previous.z - pos.z
				if px * px + pz * pz < MIN_SPACING * MIN_SPACING then
					return false
				end
			end
		end
	end
	return true
end

function hive.natural_ready()
	return not storage:contains("next_queen") or core.get_gametime() >= storage:get_int("next_queen")
end

function hive.remember_natural_spawn()
	storage:set_int("next_queen", core.get_gametime() + 3600)
end

local function living_heart(pos, id)
	if not pos or core.get_node(pos).name ~= HEART then
		return false
	end
	local meta = core.get_meta(pos)
	return meta:get_string("hive_id") == id and meta:get_int("sealed") == 0
		and not storage:contains("sealed_" .. id)
end

hive.is_alive = living_heart

function hive.seal(pos, id)
	if not pos or not id then
		return
	end
	if living_heart(pos, id) then
		local meta = core.get_meta(pos)
		meta:set_int("sealed", 1)
		core.get_node_timer(pos):stop()
		meta:set_string("infotext", S("Dormant hive heart"))
	end
	storage:set_int("sealed_" .. id, 1)
end

local function player_near(pos, radius)
	for _, object in ipairs(core.get_objects_inside_radius(pos, radius)) do
		if object:is_player() and mcl_siege.is_survival_player(object) then
			return object
		end
	end
end

local function occupied(pos, radius, mobs_too)
	for _, object in ipairs(core.get_objects_inside_radius(vector.offset(pos, 0, -0.6, 0), radius + 1.5)) do
		local entity = object:get_luaentity()
		local obj_pos = object:get_pos()
		if obj_pos and (object:is_player() or (mobs_too and entity and entity.is_mob)) then
			local props = object:get_properties()
			local bounds = props.collisionbox
			if math.abs(obj_pos.x - pos.x) < radius + math.max(-bounds[1], bounds[4])
				and math.abs(obj_pos.z - pos.z) < radius + math.max(-bounds[3], bounds[6])
				and obj_pos.y + bounds[2] < pos.y + radius
				and obj_pos.y + bounds[5] > pos.y - radius then
				return true
			end
		end
	end
	return false
end

local function open(pos)
	local name = core.get_node(pos).name
	local def = core.registered_nodes[name]
	return def and name ~= "ignore" and not def.walkable
		and def.liquidtype == "none" and def.damage_per_second <= 0
end

function hive.can_found(pos)
	if core.get_node(pos).name ~= "air" or not mcl_siege.standable(pos, 3)
		or core.is_protected(pos, "") then
		return false
	end
	for _, direction in ipairs(CARDINAL) do
		local dx, dz = direction[1], direction[2]
		for step = 1, 2 do
			local near = vector.offset(pos, dx * step, 0, dz * step)
			if not open(near) or not open(vector.offset(near, 0, 1, 0))
				or core.is_protected(near, "") then
				return false
			end
		end
	end
	return true
end

function hive.found(pos, name, id)
	if not hive.can_found(pos) or not hive.site_available(pos) or occupied(pos, 0.5, true) then
		return false
	end
	core.set_node(pos, { name = HEART })
	local meta = core.get_meta(pos)
	meta:set_string("hive_id", id)
	meta:set_int("section", 1)
	meta:set_string("infotext", S("Hive heart of @1", name))
	local x, z = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
	storage:set_string(cell_key(x, z), core.pos_to_string(pos))
	core.get_node_timer(pos):start(GROW_INTERVAL)
	return true
end

-- The same plan can resume after any timer tick or server restart.
-- Each room has a three-node entrance and the central room has four exits.
local function make_plan(direction, index)
	local blocks, passages = {}, {}
	local central = not direction
	local dx, dz = 1, 0
	if direction then
		dx, dz = direction[1], direction[2]
	end
	local center = central and 0 or 9
	local function offset(u, y, v)
		return vector.new(dx * u - dz * v, y, dz * u + dx * v)
	end
	local function add(u, y, v, name)
		blocks[#blocks + 1] = { offset(u, y, v), name or RIB }
	end
	local function passage(u, v)
		passages[#passages + 1] = offset(u, 0, v)
	end
	local function wall(u, v)
		for y = 0, 1 do
			add(u, y, v)
		end
		if (u + v) % 2 == 0 then
			add(u, 2, v)
		end
	end

	if not central then
		for u = 4, 5 do
			for v = -2, 2 do
				add(u, -1, v)
				if math.abs(v) == 2 then
					wall(u, v)
				else
					passage(u, v)
				end
			end
		end
	end

	for u = -3, 3 do
		for v = -3, 3 do
			add(center + u, -1, v)
			local edge = math.abs(u) == 3 or math.abs(v) == 3
			local entrance = u == -3 and math.abs(v) <= 1
			if central then
				entrance = math.abs(u) == 3 and math.abs(v) <= 1
					or math.abs(v) == 3 and math.abs(u) <= 1
			end
			if edge and not entrance then
				wall(center + u, v)
			elseif not central or u ~= 0 or v ~= 0 then
				passage(center + u, v)
			end
		end
	end

	if not central then
		add(center - 1, 0, 0, TRAP)
		if index <= 3 then
			add(center + 2, 0, -2, NEST)
		end
		if index % 2 == 0 then
			add(center + 2, 0, 2, CACHE)
		end
	end
	return { blocks = blocks, passages = passages }
end

building[1] = make_plan()
for i, direction in ipairs(CARDINAL) do
	building[i + 1] = make_plan(direction, i)
end

local function passage_ready(heart, plan)
	for _, offset in ipairs(plan.passages) do
		local cell = vector.add(heart, offset)
		local above = vector.offset(cell, 0, 1, 0)
		local floor = vector.offset(cell, 0, -1, 0)
		local floor_name = core.get_node(floor).name
		if not open(cell) or not open(above) or floor_name == "ignore"
			or (floor_name ~= "air" and not mcl_siege.standable(cell, 2))
			or core.is_protected(cell, "") or core.is_protected(above, "")
			or core.is_protected(floor, "") then
			return false
		end
	end
	return true
end

local budget_interval, available_blocks = 0, 24
local function grow(pos)
	if mcl_vars.difficulty == 0 or not player_near(pos, 40) or core.is_protected(pos, "") then
		return true
	end
	local meta = core.get_meta(pos)
	local section = meta:get_int("section")
	local plan = building[section]
	if not plan or not living_heart(pos, meta:get_string("hive_id")) then
		return false
	end
	local now = core.get_gametime()
	if now - budget_interval >= 5 then
		budget_interval, available_blocks = now, 24
	end
	if available_blocks == 0 then
		return true
	end

	local cursor = meta:get_int("cursor")
	if cursor == 0 then
		if not passage_ready(pos, plan) then
			meta:set_int("section", section + 1)
			return section < #building
		end
		cursor = 1
	end

	local placed = 0
	for _ = 1, 24 do
		local entry = plan.blocks[cursor]
		if not entry then
			meta:set_int("section", section + 1)
			meta:set_int("cursor", 0)
			return section < #building
		end
		local node_pos = vector.add(pos, entry[1])
		local expected = entry[2]
		if core.get_node(node_pos).name == "air" and not core.is_protected(node_pos, "") then
			local blocked = occupied(node_pos, 0.5, true)
			if blocked then
				local retries = meta:get_int("blocked_retries") + 1
				meta:set_int("blocked_retries", retries)
				if retries < 4 then
					break
				end
			else
				core.set_node(node_pos, { name = expected })
				placed = placed + 1
				available_blocks = available_blocks - 1
				if expected ~= RIB then
					local block = core.get_meta(node_pos)
					block:set_string("heart", core.pos_to_string(pos))
					block:set_string("hive_id", meta:get_string("hive_id"))
					if expected == NEST then
						block:set_int("brood_left", 7)
						core.get_node_timer(node_pos):start(math.random(22, 36))
					elseif expected == TRAP then
						core.get_node_timer(node_pos):start(1.5)
					end
				end
			end
		end
		if meta:get_int("blocked_retries") ~= 0 then
			meta:set_int("blocked_retries", 0)
		end
		cursor = cursor + 1
		if placed >= 6 or available_blocks <= 0 then
			break
		end
	end
	meta:set_int("cursor", cursor)
	return true
end

local function part_heart(pos)
	local meta = core.get_meta(pos)
	local heart = core.string_to_pos(meta:get_string("heart"))
	if heart and core.get_node(heart).name == "ignore" then
		return nil, true
	end
	if living_heart(heart, meta:get_string("hive_id")) then
		return heart
	end
	return nil, false
end

local function trap_tick(pos)
	local heart, unloaded = part_heart(pos)
	if not heart then
		return unloaded
	end
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") then
		return true
	end
	local target = player_near(pos, 1.8)
	if not target then
		return true
	end
	mcl_siege.rune(pos, 0.8, "#C94CF2", 0.7)
	mcl_potions.give_effect_by_level("slowness", target, 2, 3)
	mcl_potions.give_effect_by_level("darkness", target, 1, 2.5)
	core.get_node_timer(pos):start(11)
	return false
end

local BROOD = {
	{ 64, "mobs_mc:zombie" }, { 20, "mobs_mc:skeleton" },
	{ 6, "mobs_mc:creeper" }, { 2, "mobs_mc:witch" },
}

local function pick_guard()
	local ticket = math.random(92)
	for _, row in ipairs(BROOD) do
		ticket = ticket - row[1]
		if ticket <= 0 then
			return row[2]
		end
	end
end

local function nest_tick(pos)
	local heart, unloaded = part_heart(pos)
	if not heart then
		return unloaded
	end
	local meta = core.get_meta(pos)
	local left = meta:get_int("brood_left")
	if left <= 0 then
		return false
	end
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") or not player_near(pos, 12) then
		return true
	end
	local guards, monsters = 0, 0
	for _, object in ipairs(core.get_objects_inside_radius(heart, 20)) do
		local entity = object:get_luaentity()
		if entity and entity.is_mob and entity.type == "monster" and not entity.dead then
			monsters = monsters + 1
			guards = guards + (entity._siege_guard and 1 or 0)
			if guards >= 6 or monsters >= 13 then
				return true
			end
		end
	end
	local kind = pick_guard()
	for _, direction in ipairs(CARDINAL) do
		local cell = vector.offset(pos, direction[1], 0, direction[2])
		local above = vector.offset(cell, 0, 1, 0)
		if mcl_siege.standable(cell, 2) and not core.is_protected(cell, "")
			and not core.is_protected(above, "") and not occupied(cell, 1.3, true) then
			local object = core.add_entity(vector.offset(cell, 0, -0.5, 0), kind,
				core.serialize({ _siege_guard = true }))
			if object and object:is_valid() then
				meta:set_int("brood_left", left - 1)
				return left > 1
			end
		end
	end
	return true
end

local function open_cache(pos, node, clicker)
	if not clicker or not clicker:is_player() or core.is_protected(pos, clicker:get_player_name()) then
		return
	end
	local heart, unloaded = part_heart(pos)
	if heart or unloaded then
		core.chat_send_player(clicker:get_player_name(), S("The hive heart still seals this cache."))
		return
	end
	core.remove_node(pos)
	local inventory = clicker:get_inventory()
	for _, item in ipairs({ "mcl_core:gold_ingot 4", "mcl_core:diamond 1", "mcl_core:emerald 2" }) do
		local leftover = inventory:add_item("main", item)
		if not leftover:is_empty() then
			core.add_item(vector.offset(pos, 0, 0.5, 0), leftover)
		end
	end
end

core.register_node(RIB, {
	description = S("Hive rib"),
	tiles = { wall_texture },
	groups = block_groups,
	drop = "",
	_mcl_hardness = 1.5,
	_mcl_blast_resistance = 6,
})
core.register_node(HEART, {
	description = S("Hive heart"),
	tiles = { "crimson_hyphae.png^[colorize:#DF1550:72" },
	groups = block_groups,
	drop = "",
	light_source = 5,
	_mcl_hardness = 3,
	_mcl_blast_resistance = 8,
	on_timer = grow,
})
core.register_node(TRAP, {
	description = S("Hive snare"),
	drawtype = "nodebox",
	tiles = { "mcl_blackstone_chiseled_polished.png^[colorize:#D32DD4:100" },
	paramtype = "light",
	node_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, -0.4, 0.5 } },
	walkable = false,
	groups = { pickaxey = 1, not_in_creative_inventory = 1 },
	drop = "",
	light_source = 2,
	_mcl_hardness = 0.8,
	on_timer = trap_tick,
})
core.register_node(NEST, {
	description = S("Hive nursery"),
	tiles = { "mob_spawner.png^[colorize:#CA226B:80" },
	groups = block_groups,
	drop = "",
	light_source = 3,
	_mcl_hardness = 2,
	on_timer = nest_tick,
})
core.register_node(CACHE, {
	description = S("Sealed hive cache"),
	tiles = { "mcl_blackstone_gilded_side.png" },
	groups = block_groups,
	drop = "",
	_mcl_hardness = 2,
	on_rightclick = open_cache,
})

return hive
