local S = core.get_translator(core.get_current_modname())
local storage = core.get_mod_storage()
local hive = {}
local prefix = "mcl_siege_hives:"
local HEART = prefix .. "heart"
local RIB = prefix .. "rib"
local SLIME = prefix .. "slime"
local SHELL = prefix .. "shell"
local WEB = prefix .. "web"
local TRAP = prefix .. "trap"
local ACID = prefix .. "acid"
local NEST = prefix .. "nest"
local CACHE = prefix .. "cache"

local CELL_SIZE = 96
local MIN_SPACING = 96
local MAX_PHASE = 4
local STEP_INTERVAL = 0.08 -- Быстрая анимация перестройки по блокам
local PHASE_PAUSE = 18 -- Пауза между циклами роста/перестройки
local CARDINAL = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }

local block_groups = { pickaxey = 1, opaque = 1, not_in_creative_inventory = 1 }
local HIVE_NODES = {
	[RIB] = true,
	[SLIME] = true,
	[SHELL] = true,
	[WEB] = true,
	[TRAP] = true,
	[ACID] = true,
	[NEST] = true,
	[CACHE] = true,
}

local function cell_key(x, z)
	return ("hive_%d_%d"):format(x, z)
end

-- Разрешаем ставить коконы чаще и ближе друг к другу (чтобы они могли сливаться)
function hive.site_available(pos)
	local x, z = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
	if storage:contains(cell_key(x, z)) then
		return false
	end
	for dx = -1, 1 do
		for dz = -1, 1 do
			local previous = core.string_to_pos(storage:get_string(cell_key(x + dx, z + dz)))
			if previous then
				local px, pz = previous.x - pos.x, previous.z - pos.z
				if px * px + pz * pz < (MIN_SPACING * 0.7) ^ 2 then
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
	-- Королевы и их коконы появляются заметно чаще (раз в 8 минут вместо часа)
	storage:set_int("next_queen", core.get_gametime() + 480)
end

local function living_heart(pos, id)
	if not pos or core.get_node(pos).name ~= HEART then
		return false
	end
	local meta = core.get_meta(pos)
	return meta:get_string("hive_id") == id and meta:get_int("sealed") == 0 and not storage:contains("sealed_" .. id)
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

local function occupied(pos, radius)
	for _, object in ipairs(core.get_objects_inside_radius(pos, radius + 1.2)) do
		if object:is_player() then
			return true
		end
	end
	return false
end

local function open(pos)
	local name = core.get_node(pos).name
	local def = core.registered_nodes[name]
	return def and name ~= "ignore" and not def.walkable and def.liquidtype == "none" and def.damage_per_second <= 0
end

function hive.can_found(pos)
	if core.get_node(pos).name ~= "air" or not mcl_siege.standable(pos, 3) or core.is_protected(pos, "") then
		return false
	end
	for _, direction in ipairs(CARDINAL) do
		local near = vector.offset(pos, direction[1], 0, direction[2])
		if not open(near) or core.is_protected(near, "") then
			return false
		end
	end
	return true
end

-- Можно ли поглотить/разрушить блок при росте кокона
local function can_consume_node(pos, heart_pos)
	if vector.equals(pos, heart_pos) then
		return false
	end
	local node = core.get_node(pos)
	local name = node.name
	if name == "ignore" or core.is_protected(pos, "") then
		return false
	end
	local def = core.registered_nodes[name]
	if not def or core.get_item_group(name, "unbreakable") > 0 or def.can_dig == false then
		return false
	end
	-- Если поглощаем сердце чужого улья — запечатываем его (слияние коконов)
	if name == HEART then
		local other_meta = core.get_meta(pos)
		local other_id = other_meta:get_string("hive_id")
		if other_id ~= "" then
			storage:set_int("sealed_" .. other_id, 1)
		end
	end
	return true
end

-- Генератор микро-кокона внутри основного улья
local function build_micro_cocoon(grid, cx, cy, cz, rx, ry, rz, seed, index)
	local function set_cell(x, y, z, mat)
		local key = x .. ":" .. y .. ":" .. z
		if grid[key] ~= HEART then
			grid[key] = mat
		end
	end

	for dx = -rx, rx do
		for dy = -ry, ry do
			for dz = -rz, rz do
				local norm = (dx / rx) ^ 2 + (dy / ry) ^ 2 + (dz / rz) ^ 2
				local wx, wy, wz = cx + dx, cy + dy, cz + dz
				if norm <= 1.0 then
					if norm >= 0.68 then
						-- Оболочка микро-кокона: смесь слизи и хитина с зазубринами
						local hash = (wx * 17 + wy * 31 + wz * 13 + seed) % 7
						local mat = (hash <= 2) and SLIME or RIB
						set_cell(wx, wy, wz, mat)
					else
						-- Полость внутри микро-кокона
						set_cell(wx, wy, wz, "air")
					end
				end
			end
		end
	end

	-- Пробиваем 2 входа в микро-кокон, чтобы в нём можно было петлять
	for step = -rx - 1, rx + 1 do
		set_cell(cx + step, cy, cz, "air")
		set_cell(cx + step, cy + 1, cz, "air")
	end
	for step = -rz - 1, rz + 1 do
		set_cell(cx, cy, cz + step, "air")
		set_cell(cx, cy + 1, cz + step, "air")
	end

	-- Пол микро-кокона и испытания внутри
	set_cell(cx, cy - 1, cz, SLIME)
	if index % 2 == 1 then
		set_cell(cx, cy, cz, TRAP)
		set_cell(cx + 1, cy, cz + 1, ACID)
	else
		set_cell(cx, cy, cz, ACID)
		set_cell(cx - 1, cy, cz - 1, WEB)
	end

	if index <= 3 then
		set_cell(cx + 1, cy, cz - 1, NEST)
	end
	if index == 2 or index == 4 then
		set_cell(cx - 1, cy, cz + 1, CACHE)
	end
end

-- Генератор большого многослойного кокона с лабиринтом и микро-коконами для заданной фазы (1..MAX_PHASE)
local function generate_cocoon_plan(phase, seed)
	local rx = 6 + phase * 2 -- От 8 до 14 блоков по X
	local rz = 6 + phase * 2 -- От 8 до 14 блоков по Z
	local ry = 4 + phase -- От 5 до 8 блоков по Y (ограниченный размер)
	local grid = {}

	local function set_cell(x, y, z, mat)
		if x == 0 and y == 0 and z == 0 then
			return
		end
		grid[x .. ":" .. y .. ":" .. z] = mat
	end

	-- 1. Внешний купол кокона и слоистая структура (слизь у ядра, хитин в центре, панцирь снаружи)
	for dx = -rx, rx do
		for dy = -2, ry do
			for dz = -rz, rz do
				local y_scale = dy < 0 and 2.5 or ry
				local dist_sq = (dx / rx) ^ 2 + (dy / y_scale) ^ 2 + (dz / rz) ^ 2
				local radial = math.sqrt(dx * dx + dy * dy + dz * dz)

				if dist_sq <= 1.0 then
					if dist_sq >= 0.78 then
						-- Внешняя броня кокона с редкими «порами» паутины
						local pore = ((dx * 7 + dy * 13 + dz * 19 + seed) % 11 == 0)
						set_cell(dx, dy, dz, pore and WEB or SHELL)
					elseif radial <= 3.6 then
						-- Ближе к центру (ядру) — живая пульсирующая слизь
						if radial <= 2.2 and dy >= 0 then
							set_cell(dx, dy, dz, "air")
						else
							set_cell(dx, dy, dz, SLIME)
						end
					else
						-- Внутренний объём: запутанный лабиринт из перегородок и паутины
						if dy == -1 then
							set_cell(dx, dy, dz, (radial < 5.5) and SLIME or RIB)
						elseif dy >= 0 and dy <= 2 then
							local maze_wall = (
								(math.abs(dx) % 3 == 0 and math.abs(dz) % 2 == 1)
								or (math.abs(dz) % 3 == 0 and math.abs(dx) % 2 == 1)
							)
							local doorway = ((dx + dz + seed) % 4 == 0)
							if maze_wall and not doorway then
								set_cell(dx, dy, dz, (radial < 5.5) and SLIME or RIB)
							else
								local web_chance = ((dx * 5 + dz * 9 + dy * 3 + seed) % 13 == 0)
								set_cell(dx, dy, dz, web_chance and WEB or "air")
							end
						else
							-- Свод потолка с висящей паутиной
							local hang = ((dx * 3 + dz * 7 + seed) % 9 == 0)
							set_cell(dx, dy, dz, hang and WEB or "air")
						end
					end
				end
			end
		end
	end

	-- 2. Четыре главных запутанных туннеля-входа с изгибами (чтобы игрок легко плутал)
	for i, dir in ipairs(CARDINAL) do
		local ux, uz = dir[1], dir[2]
		local px, pz = -uz, ux
		local shift = (i % 2 == 0) and 1 or -1
		for step = 2, rx + 1 do
			local bend = (step > 5) and shift or 0
			local cx = ux * step + px * bend
			local cz = uz * step + pz * bend
			for w = -1, 1 do
				local tx = cx + px * w
				local tz = cz + pz * w
				set_cell(tx, -1, tz, (step <= 4) and SLIME or RIB)
				set_cell(tx, 0, tz, "air")
				set_cell(tx, 1, tz, "air")
				if w == 0 then
					set_cell(tx, 2, tz, "air")
				end
			end
		end
	end

	-- 3. Внутренние микро-коконы с испытаниями (начиная со 2-й фазы роста)
	if phase >= 2 then
		local offset = math.floor(rx * 0.52)
		local micro_coords = {
			{ offset, 0, offset },
			{ -offset, 0, offset },
			{ -offset, 0, -offset },
			{ offset, 0, -offset },
		}
		for idx, mc in ipairs(micro_coords) do
			build_micro_cocoon(grid, mc[1], mc[2], mc[3], 3, 2, 3, seed + idx * 19, idx)
		end
	else
		-- В первой фазе ставим базовые испытания вокруг центрального зала
		set_cell(3, 0, 0, TRAP)
		set_cell(-3, 0, 0, ACID)
		set_cell(0, 0, 3, NEST)
		set_cell(0, 0, -3, CACHE)
	end

	-- 4. Сортируем блоки по расстоянию от ядра (от центра наружу) для плавной анимации роста
	local list = {}
	for key, mat in pairs(grid) do
		local sx, sy, sz = key:match("^([^:]+):([^:]+):([^:]+)$")
		local x, y, z = tonumber(sx), tonumber(sy), tonumber(sz)
		list[#list + 1] = {
			offset = vector.new(x, y, z),
			mat = mat,
			dist = x * x + y * y * 2 + z * z,
		}
	end
	table.sort(list, function(a, b)
		return a.dist < b.dist
	end)
	return list
end

-- Кэшируем планы по фазам и сиду
local plan_cache = {}
local function get_plan(phase, seed)
	local key = phase .. "_" .. seed
	if not plan_cache[key] then
		plan_cache[key] = generate_cocoon_plan(phase, seed)
	end
	return plan_cache[key]
end

function hive.found(pos, name, id)
	if not hive.can_found(pos) or not hive.site_available(pos) or occupied(pos, 1.0) then
		return false
	end
	core.set_node(pos, { name = HEART })
	local meta = core.get_meta(pos)
	meta:set_string("hive_id", id)
	meta:set_int("phase", 1)
	meta:set_int("cursor", 1)
	meta:set_int("seed", math.random(1, 999))
	meta:set_string("infotext", S("Hive heart of @1", name))
	local x, z = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
	storage:set_string(cell_key(x, z), core.pos_to_string(pos))
	core.get_node_timer(pos):start(STEP_INTERVAL)
	return true
end
-- Пошаговая циклическая перестройка кокона (анимация роста и поглощения)
local function grow(pos)
	local meta = core.get_meta(pos)
	local id = meta:get_string("hive_id")
	if not living_heart(pos, id) then
		return false
	end
	if mcl_vars.difficulty == 0 or not player_near(pos, 48) or core.is_protected(pos, "") then
		core.get_node_timer(pos):start(2.0)
		return false
	end
	local phase = meta:get_int("phase")
	if phase < 1 then
		phase = 1
	end
	local seed = meta:get_int("seed")
	local plan = get_plan(phase, seed)
	local cursor = meta:get_int("cursor")
	if cursor < 1 then
		cursor = 1
	end
	-- За один кадр анимации обновляем до 28 блоков, чтобы перестройка шла быстро и зрелищно
	local changed = 0
	local batch_limit = 28
	while cursor <= #plan and changed < batch_limit do
		local entry = plan[cursor]
		cursor = cursor + 1
		local node_pos = vector.add(pos, entry.offset)
		local expected = entry.mat
		local current = core.get_node(node_pos).name
		if current ~= expected and can_consume_node(node_pos, pos) then
			-- Не замуровываем игрока внутрь твёрдого блока
			if
				expected ~= "air"
				and expected ~= WEB
				and expected ~= TRAP
				and expected ~= ACID
				and occupied(node_pos, 0.4)
			then
				core.set_node(node_pos, { name = "air" })
			else
				core.set_node(node_pos, { name = expected })
				if
					expected ~= "air"
					and expected ~= RIB
					and expected ~= SLIME
					and expected ~= SHELL
					and expected ~= WEB
				then
					local bmeta = core.get_meta(node_pos)
					bmeta:set_string("heart", core.pos_to_string(pos))
					bmeta:set_string("hive_id", id)
					if expected == NEST then
						bmeta:set_int("brood_left", 6 + phase * 2)
						core.get_node_timer(node_pos):start(math.random(14, 24))
					elseif expected == TRAP or expected == ACID then
						core.get_node_timer(node_pos):start(1.2)
					end
				end
			end
			changed = changed + 1
		end
	end
	if cursor <= #plan then
		-- Продолжаем быструю анимацию перестройки текущей фазы
		meta:set_int("cursor", cursor)
		core.get_node_timer(pos):start(STEP_INTERVAL)
	else
		-- Фаза завершена: звук пульсации улья и подготовка к следующему циклу роста
		core.sound_play("mobs_mc_slime_big", {
			pos = pos,
			gain = 0.7,
			pitch = 0.65,
			max_hear_distance = 28,
		}, true)
		local next_phase = phase < MAX_PHASE and (phase + 1) or MAX_PHASE
		-- На максимальной фазе кокон периодически перестраивает внутренний лабиринт (меняя seed)
		if phase >= MAX_PHASE then
			meta:set_int("seed", (seed + 37) % 999 + 1)
		end
		meta:set_int("phase", next_phase)
		meta:set_int("cursor", 1)
		core.get_node_timer(pos):start(PHASE_PAUSE)
	end
	return false
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
	local target = player_near(pos, 2.0)
	if not target then
		return true
	end
	mcl_siege.rune(pos, 1.1, "#C94CF2", 0.8)
	mcl_potions.give_effect_by_level("slowness", target, 2, 3.5)
	mcl_potions.give_effect_by_level("darkness", target, 1, 3)
	core.get_node_timer(pos):start(8)
	return false
end
local function acid_tick(pos)
	local heart, unloaded = part_heart(pos)
	if not heart then
		return unloaded
	end
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") then
		return true
	end
	local target = player_near(pos, 1.6)
	if not target then
		return true
	end
	mcl_potions.give_effect_by_level("poison", target, 1, 3)
	mcl_util.deal_damage(target, 2, { type = "magic" })
	core.sound_play("default_cool_lava", {
		pos = pos,
		gain = 0.4,
		pitch = 1.4,
		max_hear_distance = 12,
	}, true)
	core.get_node_timer(pos):start(2.5)
	return false
end
local BROOD = {
	{ 45, "mobs_mc:spider" },
	{ 30, "mobs_mc:cave_spider" },
	{ 15, "mobs_mc:skeleton" },
	{ 10, "mobs_mc:witch" },
}
local function pick_guard()
	local ticket = math.random(100)
	for _, row in ipairs(BROOD) do
		ticket = ticket - row[1]
		if ticket <= 0 then
			return row[2]
		end
	end
	return "mobs_mc:spider"
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
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") or not player_near(pos, 16) then
		return true
	end
	local guards, monsters = 0, 0
	for _, object in ipairs(core.get_objects_inside_radius(heart, 24)) do
		local entity = object:get_luaentity()
		if entity and entity.is_mob and entity.type == "monster" and not entity.dead then
			monsters = monsters + 1
			guards = guards + (entity._siege_guard and 1 or 0)
			if guards >= 9 or monsters >= 16 then
				return true
			end
		end
	end
	local kind = pick_guard()
	for _, direction in ipairs(CARDINAL) do
		local cell = vector.offset(pos, direction[1], 0, direction[2])
		local above = vector.offset(cell, 0, 1, 0)
		if
			mcl_siege.standable(cell, 2)
			and not core.is_protected(cell, "")
			and not core.is_protected(above, "")
			and not occupied(cell, 1.0)
		then
			local object =
				core.add_entity(vector.offset(cell, 0, -0.5, 0), kind, core.serialize({ _siege_guard = true }))
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
	for _, item in ipairs({
		"mcl_core:gold_ingot 6",
		"mcl_core:diamond 2",
		"mcl_core:emerald 4",
	}) do
		local leftover = inventory:add_item("main", item)
		if not leftover:is_empty() then
			core.add_item(vector.offset(pos, 0, 0.5, 0), leftover)
		end
	end
end
-- Материалы кокона:
-- 1. Ядро улья (как было)
core.register_node(HEART, {
	description = S("Hive heart"),
	tiles = { "crimson_hyphae.png^[colorize:#DF1550:72" },
	groups = block_groups,
	drop = "",
	light_source = 6,
	_mcl_hardness = 3,
	_mcl_blast_resistance = 8,
	on_timer = grow,
})
-- 2. Внутренняя пульсирующая слизь вокруг ядра
core.register_node(SLIME, {
	description = S("Hive living slime"),
	tiles = { "mcl_core_slime.png^[colorize:#7C1E5E:95" },
	groups = { oddly_breakable_by_hand = 1, bouncy = 60, fall_damage_add_percent = -80, not_in_creative_inventory = 1 },
	drop = "",
	light_source = 3,
	_mcl_hardness = 0.6,
	_mcl_blast_resistance = 4,
})
-- 3. Средние хитиновые рёбра (как было)
core.register_node(RIB, {
	description = S("Hive rib"),
	tiles = { "mcl_blackstone_polished_bricks.png^[colorize:#511734:62" },
	groups = block_groups,
	drop = "",
	_mcl_hardness = 1.5,
	_mcl_blast_resistance = 6,
})
-- 4. Внешний твёрдый панцирь кокона
core.register_node(SHELL, {
	description = S("Hive chitin shell"),
	tiles = { "mcl_blackstone_gilded_side.png^[colorize:#2E0C24:110" },
	groups = { pickaxey = 2, opaque = 1, not_in_creative_inventory = 1 },
	drop = "",
	_mcl_hardness = 2.5,
	_mcl_blast_resistance = 9,
})
-- 5. Вязкая паутина кокона
core.register_node(WEB, {
	description = S("Hive dense web"),
	drawtype = "plantlike",
	tiles = { "mcl_core_web.png^[colorize:#B85CD6:80" },
	paramtype = "light",
	walkable = false,
	liquidtype = "source",
	liquid_alternative_flowing = WEB,
	liquid_alternative_source = WEB,
	liquid_viscosity = 14,
	liquid_range = 0,
	drowning = 0,
	groups = { swordy = 1, sheary = 1, dig_by_water = 1, not_in_creative_inventory = 1 },
	drop = "",
	_mcl_hardness = 0.8,
})
-- 6. Руническая ловушка-испытание
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
-- 7. Кислотная железа-ловушка
core.register_node(ACID, {
	description = S("Hive acid pool"),
	drawtype = "nodebox",
	tiles = { "mcl_core_slime.png^[colorize:#68E81E:130" },
	paramtype = "light",
	node_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, -0.42, 0.5 } },
	walkable = false,
	groups = { pickaxey = 1, not_in_creative_inventory = 1 },
	drop = "",
	light_source = 4,
	_mcl_hardness = 0.7,
	on_timer = acid_tick,
})
-- 8. Инкубатор охраны
core.register_node(NEST, {
	description = S("Hive nursery"),
	tiles = { "mob_spawner.png^[colorize:#CA226B:80" },
	groups = block_groups,
	drop = "",
	light_source = 3,
	_mcl_hardness = 2,
	on_timer = nest_tick,
})
-- 9. Запечатанная сокровищница
core.register_node(CACHE, {
	description = S("Sealed hive cache"),
	tiles = { "mcl_blackstone_gilded_side.png" },
	groups = block_groups,
	drop = "",
	_mcl_hardness = 2,
	on_rightclick = open_cache,
})
return hive
