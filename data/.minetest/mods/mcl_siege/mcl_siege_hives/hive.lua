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

local CELL_SIZE = 64
local MIN_SPACING = 48
-- Фазы радиуса: 2 -> 4 -> 7 -> 15 -> 20
local PHASE_RADII = { 2, 4, 7, 15}
local MAX_PHASE = #PHASE_RADII
local CARDINAL = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }

local soft_shell_groups = {
	crumbly = 3,
	oddly_breakable_by_hand = 3,
	pickaxey = 1,
	swordy = 1,
	opaque = 1,
	not_in_creative_inventory = 1,
}

-- Экспоненциальное замедление скорости роста по фазам
local function get_step_interval(phase)
	return 1.5 * phase
end

local function get_phase_pause(phase)
	return 3.5 * phase
end

local function cell_key(x, z)
	return ("hive_%d_%d"):format(x, z)
end

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

-- Поиск актуальной позиции сердца (учитывая активный подъём вверх до 16 блоков)
function hive.locate_heart(anchor, id)
	if not anchor or not id then
		return nil
	end
	if living_heart(anchor, id) then
		return anchor
	end
	for dy = 1, 48 do
		local up = vector.offset(anchor, 0, dy, 0)
		if living_heart(up, id) then
			return up
		end
	end
	return nil
end

function hive.seal(pos, id)
	if not pos or not id then
		return
	end
	local actual = hive.locate_heart(pos, id)
	if actual then
		local meta = core.get_meta(actual)
		meta:set_int("sealed", 1)
		core.get_node_timer(actual):stop()
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
	for _, object in ipairs(core.get_objects_inside_radius(pos, radius + 1.4)) do
		if object:is_player() then
			return true
		end
		local ent = object:get_luaentity()
		if ent and ent.is_mob then
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
	if core.is_protected(pos, "") then
		return false
	end
	local node = core.get_node(pos)
	local def = core.registered_nodes[node.name]
	-- Разрешаем ставить в воздух, траву, цветы, снег, листву и любые не-твёрдые или разрушаемые блоки (кроме воды/лавы и нерушимых)
	if not def or node.name == "ignore" or def.liquidtype ~= "none" then
		return false
	end
	if core.get_item_group(node.name, "unbreakable") > 0 or def.can_dig == false then
		return false
	end
	return true
end

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
	if name == HEART then
		local other_meta = core.get_meta(pos)
		local other_id = other_meta:get_string("hive_id")
		if other_id ~= "" then
			storage:set_int("sealed_" .. other_id, 1)
		end
	end
	return true
end

local function is_existing_hive_block(name)
	return name == RIB
		or name == SLIME
		or name == SHELL
		or name == WEB
		or name == TRAP
		or name == ACID
		or name == NEST
		or name == CACHE
end

local function build_micro_cocoon(grid, cx, cy, cz, rx, ry, rz, seed, index)
	local function set_cell(x, y, z, mat)
		if x == 0 and y == 0 and z == 0 then
			return
		end
		grid[x .. ":" .. y .. ":" .. z] = mat
	end

	for dx = -rx, rx do
		for dy = -1, ry do
			for dz = -rz, rz do
				local y_norm = dy < 0 and 1.5 or ry
				local norm = (dx / rx) ^ 2 + (dy / y_norm) ^ 2 + (dz / rz) ^ 2
				local wx, wy, wz = cx + dx, cy + dy, cz + dz
				if norm <= 1.0 then
					if dy == -1 then
						set_cell(wx, wy, wz, SLIME)
					elseif norm >= 0.72 then
						local hash = (wx * 17 + wy * 31 + wz * 13 + seed) % 7
						set_cell(wx, wy, wz, (hash <= 2) and SLIME or RIB)
					else
						if dy >= ry - 1 and (wx + wz + seed) % 3 == 0 then
							set_cell(wx, wy, wz, WEB)
						else
							set_cell(wx, wy, wz, "air")
						end
					end
				end
			end
		end
	end

	for step = -rx - 1, rx + 1 do
		for w = -1, 1 do
			for h = 0, 2 do
				set_cell(cx + step, cy + h, cz + w, "air")
			end
		end
	end
	for step = -rz - 1, rz + 1 do
		for w = -1, 1 do
			for h = 0, 2 do
				set_cell(cx + w, cy + h, cz + step, "air")
			end
		end
	end

	if index % 2 == 1 then
		set_cell(cx + 2, cy, cz + 2, TRAP)
		set_cell(cx - 2, cy, cz - 2, ACID)
		set_cell(cx, cy, cz + 2, WEB)
	else
		set_cell(cx - 2, cy, cz + 2, ACID)
		set_cell(cx + 2, cy, cz - 2, TRAP)
		set_cell(cx + 2, cy, cz, WEB)
	end

	set_cell(cx + 2, cy, cz - 2, NEST)
	if index % 2 == 0 then
		set_cell(cx - 2, cy, cz - 2, CACHE)
	end
end

-- Генератор вытянутого кокона с глубоким дном под активно поднимающимся сердцем
local function generate_cocoon_plan(phase, seed)
	local rx = PHASE_RADII[phase] or 4
	local rz = rx
	local ry = math.floor(rx * 1.45) + 2
	-- Глубокое основание, перекрывающее весь путь подъёма сердца
	local y_depth = math.max(5, math.min(26, math.floor(rx * 0.9) + phase * 3))
	local prev_r = phase > 1 and PHASE_RADII[phase - 1] or 0

	local grid = {}
	local function set_cell(x, y, z, mat)
		if x == 0 and y == 0 and z == 0 then
			return
		end
		grid[x .. ":" .. y .. ":" .. z] = mat
	end

	for dx = -rx - 2, rx + 2 do
		for dy = -y_depth, ry + 2 do
			for dz = -rz - 2, rz + 2 do
				local angle = math.atan2(dz, dx)
				local y_ratio = dy >= 0 and (dy / ry) or (-dy / y_depth)
				local ribs = math.sin(angle * 5 + seed * 0.1) * 0.06
				local waist = (dy >= 0) and (-math.sin(y_ratio * math.pi) * 0.08) or 0
				local spire = (dy > 0 and y_ratio > 0.7) and (math.cos(angle * 3 - y_ratio * 4) * 0.07) or 0
				local warp = 1.0 + ribs + waist + spire

				local eff_rx = rx * warp
				local eff_rz = rz * warp
				local y_scale = dy < 0 and y_depth or ry
				local dist_sq = (dx / eff_rx) ^ 2 + (dy / y_scale) ^ 2 + (dz / eff_rz) ^ 2
				local radial = math.sqrt(dx * dx + dz * dz)

				-- Исключаем весь внутренний объём предыдущей фазы, чтобы не трогать и не чинить старые слои
				local inside_previous = false
				if prev_r > 0 then
					local prev_ry = math.floor(prev_r * 1.45) + 2
					local prev_depth = math.max(5, math.min(16, math.floor(prev_r * 0.65) + (phase - 1) * 2))
					local prev_dy = dy + 2
					local prev_y_scale = prev_dy < 0 and prev_depth or prev_ry
					local safe_prev_r = math.max(1.5, prev_r - 1.5)
					local prev_dist_sq = (dx / safe_prev_r) ^ 2
						+ (prev_dy / prev_y_scale) ^ 2
						+ (dz / safe_prev_r) ^ 2
					if prev_dist_sq < 0.85 then
						inside_previous = true
					end
				end

				if dist_sq <= 1.0 and not inside_previous then
					-- Плотная многослойная стенка толщиной 2-3 блока на любой фазе
					local shell_threshold = rx <= 5 and 0.52 or (rx <= 10 and 0.64 or 0.72)
					local is_shell = dist_sq >= shell_threshold

					if is_shell then
						-- Чередуем хитиновый панцирь, тёмные рёбра и вкрапления живой слизи
						local pattern = math.abs(dx * 7 + dy * 13 + dz * 19 + seed) % 11
						if pattern <= 1 then
							set_cell(dx, dy, dz, SLIME)
						elseif pattern <= 4 then
							set_cell(dx, dy, dz, RIB)
						else
							set_cell(dx, dy, dz, SHELL)
						end
					elseif dy < -1 then
						-- Монолитное глубокое основание под коконом без дыр
						set_cell(dx, dy, dz, (radial <= rx * 0.45) and SLIME or RIB)
					elseif dy == -1 then
						-- Сплошной упругий пол на уровне сердца
						set_cell(dx, dy, dz, (radial <= rx * 0.4) and SLIME or RIB)
					else
						local is_tier_floor = (dy >= 4) and (dy % 4 == 0) and (dy <= ry - 3)
						if is_tier_floor then
							local hole_pattern = math.sin(dx * 0.65 + seed) + math.cos(dz * 0.65 - seed)
							local small_hole = ((dx * 5 + dz * 9 + dy + seed) % 5 == 0)
							if hole_pattern > 0.15 or small_hole then
								set_cell(dx, dy, dz, (small_hole and (dx + dz) % 2 == 0) and WEB or "air")
							else
								set_cell(dx, dy, dz, (radial <= rx * 0.4) and SLIME or RIB)
							end
						elseif dy % 4 == 1 and dy >= 5 then
							local top_hazard = math.abs(dx * 17 + dz * 31 + dy * 7 + seed) % 36
							if top_hazard == 0 then
								set_cell(dx, dy, dz, WEB)
							elseif top_hazard == 1 and rx >= 10 then
								set_cell(dx, dy, dz, TRAP)
							else
								set_cell(dx, dy, dz, "air")
							end
						elseif dy == 0 and radial > 3.0 then
							local hazard_hash = math.abs(dx * 19 + dz * 37 + seed * 7) % 40
							if hazard_hash == 0 or hazard_hash == 1 then
								set_cell(dx, dy, dz, WEB)
							elseif hazard_hash == 2 then
								set_cell(dx, dy, dz, TRAP)
							elseif hazard_hash == 3 then
								set_cell(dx, dy, dz, ACID)
							else
								set_cell(dx, dy, dz, "air")
							end
						else
							local web_hang = (dy >= 2) and (math.abs(dx * 13 + dz * 29 + seed) % 26 == 0)
							set_cell(dx, dy, dz, web_hang and WEB or "air")
						end
					end
				end
			end
		end
	end
	-- Сквозные входы на уровне земли (с учётом того, насколько высоко поднялось сердце)
	local half_w = rx <= 5 and 1 or 2
	local tunnel_y = -math.min((phase - 1) * 2, 6)
	for i, dir in ipairs(CARDINAL) do
		local ux, uz = unpack(dir)
		local px, pz = -uz, ux
		local shift = (i % 2 == 0) and 1 or -1
		for step = math.max(2, prev_r), rx + 2 do
			local bend = (rx >= 10 and step > math.floor(rx * 0.5)) and shift or 0
			local cx = ux * step + px * bend
			local cz = uz * step + pz * bend
			for w = -half_w, half_w do
				local tx = cx + px * w
				local tz = cz + pz * w
				set_cell(tx, tunnel_y - 1, tz, (step <= 4) and SLIME or RIB)
				for h = 0, 3 do
					if math.abs(w) < half_w or h < 3 then
						set_cell(tx, tunnel_y + h, tz, "air")
					end
				end
			end
		end
	end
	if rx >= 13 then
		local r1 = math.floor(rx * 0.58)
		local inner_coords = {
			{ r1, tunnel_y, r1 },
			{ -r1, tunnel_y, r1 },
			{ -r1, tunnel_y, -r1 },
			{ r1, tunnel_y, -r1 },
		}
		for idx, mc in ipairs(inner_coords) do
			local mx, my, mz = unpack(mc)
			build_micro_cocoon(grid, mx, my, mz, 3, 3, 3, seed + idx * 19, idx)
		end
	end
	if rx >= 20 then
		local r2 = math.floor(rx * 0.72)
		local outer_coords = {
			{ r2, tunnel_y, 0 },
			{ -r2, tunnel_y, 0 },
			{ 0, tunnel_y, r2 },
			{ 0, tunnel_y, -r2 },
		}
		for idx, mc in ipairs(outer_coords) do
			local mx, my, mz = unpack(mc)
			build_micro_cocoon(grid, mx, my, mz, 4, 4, 4, seed + idx * 31, idx + 4)
		end
	end
	if rx <= 10 then
		local d = math.max(2, rx - 2)
		set_cell(d, 0, 1, TRAP)
		set_cell(-d, 0, -1, ACID)
		set_cell(1, 0, d, NEST)
		set_cell(-1, 0, -d, CACHE)
		set_cell(2, 0, -2, WEB)
		set_cell(-2, 0, 2, WEB)
	end
	-- Сортировка снизу вверх и от центра наружу
	local list = {}
	for key, mat in pairs(grid) do
		local sx, sy, sz = key:match("^([^:]+):([^:]+):([^:]+)$")
		local x, y, z = tonumber(sx), tonumber(sy), tonumber(sz)
		list[#list + 1] = {
			offset = vector.new(x, y, z),
			mat = mat,
			score = (y * 12) + (x * x + z * z),
		}
	end
	table.sort(list, function(a, b)
		return a.score < b.score
	end)
	return list
end
local plan_cache = {}
local function get_plan(phase, seed)
	local key = phase .. "_" .. seed
	if not plan_cache[key] then
		plan_cache[key] = generate_cocoon_plan(phase, seed)
	end
	return plan_cache[key]
end
function hive.found(pos, name, id)
	if not hive.can_found(pos) or not hive.site_available(pos) then
		return false
	end
	core.set_node(pos, { name = HEART })
	local meta = core.get_meta(pos)
	meta:set_string("hive_id", id)
	meta:set_string("queen_name", name)
	meta:set_int("phase", 1)
	meta:set_int("cursor", 1)
	meta:set_int("ground_y", pos.y)
	meta:set_int("lift_steps", 0)
	meta:set_int("seed", math.random(1, 999))
	meta:set_string("infotext", S("Hive heart of @1", name))
	local x, z = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
	storage:set_string(cell_key(x, z), core.pos_to_string(pos))
	core.get_node_timer(pos):start(get_step_interval(1))
	return true
end
-- Подъём сердца кокона на +1 блок вверх (с сохранением прогресса текущей фазы и возведением слизи под собой)
local function elevate_heart(pos, meta, resume_timer)
	local above = vector.offset(pos, 0, 1, 0)
	if core.is_protected(above, "") or occupied(above, 0.5) then
		return pos
	end
	local node = core.get_node(above)
	local def = core.registered_nodes[node.name]
	if not def or core.get_item_group(node.name, "unbreakable") > 0 or def.can_dig == false then
		return pos
	end
	local id = meta:get_string("hive_id")
	local qname = meta:get_string("queen_name")
	local phase = meta:get_int("phase")
	local cursor = meta:get_int("cursor")
	local seed = meta:get_int("seed")
	local sealed = meta:get_int("sealed")
	local lifts = meta:get_int("lift_steps")
	core.set_node(above, { name = HEART })
	local new_meta = core.get_meta(above)
	new_meta:set_string("hive_id", id)
	new_meta:set_string("queen_name", qname)
	new_meta:set_int("phase", phase)
	new_meta:set_int("cursor", cursor)
	new_meta:set_int("ground_y", meta:get_int("ground_y"))
	new_meta:set_int("seed", seed)
	new_meta:set_int("sealed", sealed)
	new_meta:set_int("lift_steps", lifts + 1)
	new_meta:set_string("infotext", S("Hive heart of @1", qname))
	-- Под сердцем ставим живую слизь (строим основу под собой)
	core.swap_node(pos, { name = SLIME })
	core.get_node_timer(above):start(resume_timer)
	return above
end

-- Эффектное раскрытие созревшего кокона (разворот на 8 лепестков) и выброс огромной орды зомби
local function hatch_cocoon(heart_pos, max_r)
	local y_min = -28 -- Захватываем всё глубокое основание кокона
	local y_max = math.floor(max_r * 1.5) + 6
	local petals = {}

	-- 1. Раскрываем весь кокон целиком от шпиля до самого дна
	for dx = -max_r - 3, max_r + 3 do
		for dy = y_min, y_max do
			for dz = -max_r - 3, max_r + 3 do
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist <= max_r + 4 and dy >= -10 then
					local p = vector.offset(heart_pos, dx, dy, dz)
					local name = core.get_node(p).name
					if is_existing_hive_block(name) and name ~= HEART then
						petals[#petals + 1] = {
							pos = p,
							-- Раскрывается эффектной волной сверху вниз до самого основания
							score = -dy * 15 + dist,
						}
					end
				end
			end
		end
	end

	table.sort(petals, function(a, b)
		return a.score < b.score
	end)

	-- Многослойный оглушительный звук разрыва и пробуждения орды
	if heart_pos then core.sound_play("thunder", { pos = 
        heart_pos, gain = 1.5, pitch = 0.75, 
        max_hear_distance = 200,
    }, true)
    core.after(0.1, function() 
        core.sound_play("mobs_mc_ender_dragon_death", {
            pos = heart_pos, gain = 1.5, pitch = 0.65, 
            max_hear_distance = 200,
        }, true)
    end) core.after(0.2, function() 
        core.sound_play("mobs_mc_slime_big", {
            pos = heart_pos, gain = 1.5, pitch = 0.5, 
            max_hear_distance = 200,
        }, true)
    end) end
	for i = 1, 4 do
		core.after(i * 0.25, function()
			core.sound_play("mobs_mc_zombie_growl", {
				pos = heart_pos,
				gain = 1.4,
				pitch = (65 + i * 10) / 100,
				max_hear_distance = 64,
			}, true)
		end)
	end

	-- Находим ближайшего игрока, чтобы орда сразу бросилась на него
	local nearest_player = nil
	local best_dist = 80
	for _, obj in ipairs(core.get_objects_inside_radius(heart_pos, 80)) do
		if obj:is_player() and mcl_siege.is_survival_player(obj) then
			local d = vector.distance(heart_pos, obj:get_pos())
			if d < best_dist then
				best_dist = d
				nearest_player = obj
			end
		end
	end

	local idx = 1
	local spawned_zombies = 0
	local total_horde = 85 -- Огромная армия из 85 зомби
	local zombie_types = {
		"mobs_mc:zombie",
		"mobs_mc:zombie",
		"mobs_mc:zombie",
		"mobs_mc:husk",
		"mobs_mc:husk",
		"mobs_mc:baby_zombie",
		"mobs_mc:baby_husk",
	}

	local function open_petal_step()
		local removed = 0
		-- Сносим по 220 блоков за кадр для мощного обвала оболочки
		while idx <= #petals and removed < 220 do
			local p = petals[idx].pos
			idx = idx + 1
			local node = core.get_node(p)
			if is_existing_hive_block(node.name) and not core.is_protected(p, "") then
				core.remove_node(p)
				removed = removed + 1
				if removed % 14 == 0 then
					core.add_particlespawner({
						amount = 10,
						time = 0.1,
						minpos = vector.subtract(p, 0.6),
						maxpos = vector.add(p, 0.6),
						minvel = { x = -3.5, y = 1.0, z = -3.5 },
						maxvel = { x = 3.5, y = 4.5, z = 3.5 },
						minacc = { x = 0, y = -9.8, z = 0 },
						maxacc = { x = 0, y = -9.8, z = 0 },
						minexptime = 0.5,
						maxexptime = 1.2,
						minsize = 2.0,
						maxsize = 4.0,
						node = node,
					})
				end
			end
		end

		if removed > 0 then
			core.sound_play("mobs_mc_zombie_door_break", {
				pos = heart_pos,
				gain = 1.1,
				pitch = math.random(65, 95) / 100,
				max_hear_distance = 56,
			}, true)
		end

		-- Выбрасываем по 100 зомби за волну из всего объёма раскрытого бутона
		if spawned_zombies < total_horde then
			for _ = 1, 100 do
				if spawned_zombies >= total_horde then
					break
				end
				local angle = math.random() * math.pi * 2
				local r = math.random(2, math.max(5, max_r - 2))
				local sx = math.floor(math.cos(angle) * r + 0.5)
				local sz = math.floor(math.sin(angle) * r + 0.5)
				for dy = 8, -12, -1 do
					local cell = vector.offset(heart_pos, sx, dy, sz)
					if mcl_siege.standable(cell, 2) and not core.is_protected(cell, "") then
						local kind = zombie_types[math.random(#zombie_types)]
						local obj = core.add_entity(vector.offset(cell, 0, -0.45, 0), kind)
						if obj and obj:is_valid() then
							local out_dir = vector.normalize(vector.new(sx, 0.35, sz))
							obj:set_velocity(vector.multiply(out_dir, 7.5))
							local ent = obj:get_luaentity()
							if ent and nearest_player then
								ent.attack = nearest_player
								ent.state = "attack"
							end
							spawned_zombies = spawned_zombies + 1
							break
						end
					end
				end
			end
		end

		if idx <= #petals or spawned_zombies < total_horde then
			core.after(0.1, open_petal_step)
		end
	end

	core.after(0.1, open_petal_step)
end

-- Пошаговая надстройка нового слоя с активным подъёмом сердца, защитой ландшафта и без регенерации сломанного
local function grow(pos)
	local meta = core.get_meta(pos)
	local id = meta:get_string("hive_id")
	if not living_heart(pos, id) then
		return false
	end

	local any_player = false
	for _, object in ipairs(core.get_objects_inside_radius(pos, 72)) do
		if object:is_player() then
			any_player = true
			break
		end
	end
	if mcl_vars.difficulty == 0 or not any_player or core.is_protected(pos, "") then
		core.get_node_timer(pos):start(1.0)
		return false
	end

	local phase = meta:get_int("phase")
	if phase < 1 then
		phase = 1
	end

	-- Запоминаем уровень земли при старте, чтобы кокон не выкапывал кратер вниз
	local ground_y = meta:get_int("ground_y")
	if ground_y == 0 then
		ground_y = pos.y
		meta:set_int("ground_y", ground_y)
	end

	local seed = meta:get_int("seed")
	local plan = get_plan(phase, seed)
	local cursor = meta:get_int("cursor")
	if cursor < 1 then
		cursor = 1
	end

	-- Активный подъём сердца вверх по мере роста фазы
	local lifts = meta:get_int("lift_steps")
	local target_lifts = math.floor((cursor / math.max(1, #plan)) * 5.5)
	if lifts < target_lifts then
		local moved = elevate_heart(pos, meta, get_step_interval(phase))
		if not vector.equals(moved, pos) then
			return false
		end
	end

	local changed = 0
	local batch_limit = math.max(24, math.floor(140 / phase))
	local checked = 0
	local max_checks = 600
	local prev_r = phase > 1 and PHASE_RADII[phase - 1] or 0

	while cursor <= #plan and changed < batch_limit and checked < max_checks do
		local entry = plan[cursor]
		cursor = cursor + 1
		checked = checked + 1

		local node_pos = vector.add(pos, entry.offset)
		local expected = entry.mat
		local current = core.get_node(node_pos).name

		-- 1. Не трогаем уже существующие блоки улья
		local keep_old_layer = is_existing_hive_block(current)

		-- 2. Не застраиваем заново дыры, пробитые игроком внутри предыдущих слоёв
		local player_cleared = (current == "air")
			and (prev_r > 0)
			and (entry.offset.x ^ 2 + entry.offset.z ^ 2 <= prev_r ^ 2)

		-- 3. Не разрушаем природный грунт ниже основания кокона (чтобы после распада не оставалась яма)
		local cur_def = core.registered_nodes[current]
		local is_natural_ground = (node_pos.y < ground_y) and cur_def and cur_def.walkable

		if
			not keep_old_layer
			and not player_cleared
			and not is_natural_ground
			and current ~= expected
			and can_consume_node(node_pos, pos)
		then
			if
				expected ~= "air"
				and expected ~= WEB
				and expected ~= TRAP
				and expected ~= ACID
				and occupied(node_pos, 0.5)
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
						bmeta:set_int("brood_left", 5 + phase * 2)
						core.get_node_timer(node_pos):start(math.random(10, 18))
					elseif expected == TRAP or expected == ACID then
						core.get_node_timer(node_pos):start(1.2)
					end
				end
			end
			changed = changed + 1
		end
	end

	if cursor <= #plan then
		meta:set_int("cursor", cursor)
		core.get_node_timer(pos):start(get_step_interval(phase))
	else
		core.sound_play("mobs_mc_slime_big", {
			pos = pos,
			gain = 0.85,
			pitch = 0.65,
			max_hear_distance = 36,
		}, true)

		if phase < MAX_PHASE then
			local next_phase = phase + 1
			meta:set_int("phase", next_phase)
			meta:set_int("cursor", 1)
			meta:set_int("lift_steps", 0)
			local pause = get_phase_pause(next_phase)
			local moved_pos = elevate_heart(pos, meta, pause)
			if vector.equals(moved_pos, pos) then
				core.get_node_timer(pos):start(pause)
			end
		else
			meta:set_int("cursor", #plan + 1)
			if meta:get_int("hatched") == 0 then
				meta:set_int("hatched", 1)
				hatch_cocoon(pos, PHASE_RADII[MAX_PHASE] or 20)
			end
		end
	end

	return false
end

local function part_heart(pos)
	local meta = core.get_meta(pos)
	local heart = core.string_to_pos(meta:get_string("heart"))
	if heart and core.get_node(heart).name == "ignore" then
		return nil, true
	end
	local actual = hive.locate_heart(heart, meta:get_string("hive_id"))
	if actual then
		return actual
	end
	return nil, false
end
local function apply_short_effect(player, name, level, duration)
	if not mcl_potions or not mcl_potions.registered_effects or not mcl_potions.registered_effects[name] then
		return
	end
	mcl_potions.give_effect(name, player, level, duration)
end
local function trap_tick(pos)
	local heart, unloaded = part_heart(pos)
	if not heart then
		return unloaded
	end
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") then
		return true
	end
	local target = player_near(pos, 2.2)
	if not target then
		return true
	end
	mcl_siege.rune(pos, 1.3, "#C94CF2", 0.8)
	apply_short_effect(target, "slowness", 2, 3.5)
	apply_short_effect(target, "darkness", 1, 3.0)
	core.get_node_timer(pos):start(7)
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
	local target = player_near(pos, 1.8)
	if not target then
		return true
	end
	apply_short_effect(target, "poison", 1, 3.5)
	mcl_util.deal_damage(target, 2, { type = "magic" })
	core.sound_play("default_cool_lava", {
		pos = pos,
		gain = 0.4,
		pitch = 1.4,
		max_hear_distance = 12,
	}, true)
	core.get_node_timer(pos):start(2.2)
	return false
end
local BROOD = {
	{ 10, "mobs_mc:witch" },
	{ 23, "mobs_mc:skeleton" },
	{ 12, "mobs_mc:creeper" },
}
local function pick_guard()
	local ticket = math.random(100)
	for _, row in ipairs(BROOD) do
		local weight, mob_name = unpack(row)
		ticket = ticket - weight
		if ticket <= 0 then
			return mob_name
		end
	end
	return "mobs_mc:witch"
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
	if mcl_vars.difficulty == 0 or core.is_protected(pos, "") or not player_near(pos, 24) then
		return true
	end
	local guards, monsters = 0, 0
	for _, object in ipairs(core.get_objects_inside_radius(heart, 34)) do
		local entity = object:get_luaentity()
		if entity and entity.is_mob and entity.type == "monster" and not entity.dead then
			monsters = monsters + 1
			guards = guards + (entity._siege_guard and 1 or 0)
			if guards >= 12 or monsters >= 22 then
				return true
			end
		end
	end
	local kind = pick_guard()
	for _, direction in ipairs(CARDINAL) do
		local dx, dz = unpack(direction)
		local cell = vector.offset(pos, dx, 0, dz)
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
local CACHE_LOOT_POOL = {
	-- Гарантированные или частые ценные ресурсы
	{ item = "mcl_core:diamond", min = 2, max = 5, chance = 100 },
	{ item = "mcl_core:emerald", min = 3, max = 8, chance = 90 },
	{ item = "mcl_potions:regeneration_2", min = 1, max = 2, chance = 50 },
	{ item = "mcl_potions:swiftness_2", min = 1, max = 2, chance = 50 },
	
	-- Тематические и боевые трофеи (в духе улья, паутины, яда и осады)
	{ item = "mcl_core:apple_gold", min = 1, max = 2, chance = 45 },
	{ item = "mcl_mobitems:slimeball", min = 6, max = 16, chance = 75 },
	{ item = "mcl_mobitems:string", min = 8, max = 20, chance = 75 },
	
	-- Редкие джекпоты
	{ item = "mcl_nether:netherite_scrap", min = 1, max = 2, chance = 25 },
	{ item = "mcl_mobitems:echo_shard", min = 1, max = 3, chance = 30 },
	{ item = "mcl_totems:totem", min = 1, max = 1, chance = 12 },
}
local function open_cache(pos, node, clicker)
	if not clicker or not clicker:is_player() or core.is_protected(pos, clicker:get_player_name()) then
		return
	end

	if core.get_node(pos).name == CACHE then
		core.remove_node(pos)
	end

	core.sound_play("default_break_glass", { pos = pos, gain = 0.8, pitch = 1.2 }, true)
	core.add_particlespawner({
		amount = 60,
		time = 0.2,
		minpos = vector.subtract(pos, 0.3),
		maxpos = vector.add(pos, 0.3),
		minvel = { x = -2, y = 2, z = -2 },
		maxvel = { x = 2, y = 4, z = 2 },
		minacc = { x = 0, y = -9.8, z = 0 },
		maxacc = { x = 0, y = -9.8, z = 0 },
		minexptime = 0.6,
		maxexptime = 1.2,
		texture = "default_gold_ingot.png",
	})

	local inventory = clicker:get_inventory()
	for _, entry in ipairs(CACHE_LOOT_POOL) do
		if math.random(100) <= entry.chance and core.registered_items[entry.item] then
			local count = math.random(entry.min, entry.max)
			local stack = ItemStack(entry.item .. " " .. count)
			local leftover = inventory:add_item("main", stack)
			if not leftover:is_empty() then
				core.add_item(vector.offset(pos, 0, 0.5, 0), leftover)
			end
		end
	end
end

-- Постепенный распад кокона после уничтожения сердца
local function start_decay(center_pos, max_radius)
	ground_y = ground_y or center_pos.y
	local radius = math.max(max_radius + 6, 26)
	local y_min = -36 -- Захватываем всё глубокое основание кокона ниже поднятого сердца
	local y_max = math.floor(radius * 1.5) + 6
	local targets = {}

	for dx = -radius, radius do
		for dy = y_min, y_max do
			for dz = -radius, radius do
				local p = vector.offset(center_pos, dx, dy, dz)
				local name = core.get_node(p).name
				if is_existing_hive_block(name) then
					targets[#targets + 1] = {
						pos = p,
						dist = dx * dx + dy * dy + dz * dz,
					}
				end
			end
		end
	end

	table.sort(targets, function(a, b)
		return a.dist < b.dist
	end)

	core.sound_play("mobs_mc_ender_dragon_death", {
		pos = center_pos,
		gain = 0.7,
		pitch = 0.75,
		max_hear_distance = 48,
	}, true)

	local idx = 1
	local function decay_step()
		if idx > #targets then
			return
		end
		local removed = 0
		while idx <= #targets and removed < 65 do
			local p = targets[idx].pos
			idx = idx + 1
			local node = core.get_node(p)
						if is_existing_hive_block(node.name) and not core.is_protected(p, "") then
				if p.y <= ground_y - 1 then
					-- Глубоко под землёй возвращаем обычную землю
					core.set_node(p, { name = "mcl_core:dirt" })
				else
					-- Всё, что выше земли, просто исчезает
					core.remove_node(p)
				end
				removed = removed + 1
				if removed % 8 == 0 then
					core.add_particlespawner({
						amount = 5,
						time = 0.1,
						minpos = vector.subtract(p, 0.4),
						maxpos = vector.add(p, 0.4),
						minvel = { x = -1.2, y = -0.5, z = -1.2 },
						maxvel = { x = 1.2, y = 1.2, z = 1.2 },
						minacc = { x = 0, y = -9.8, z = 0 },
						maxacc = { x = 0, y = -9.8, z = 0 },
						minexptime = 0.4,
						maxexptime = 0.9,
						minsize = 1.2,
						maxsize = 2.4,
						node = node,
					})
				end
			end
		end
		if removed > 0 then
			core.sound_play("default_dig_crumbly", {
				pos = targets[math.min(idx, #targets)].pos,
				gain = 0.5,
				pitch = math.random(70, 100) / 100,
				max_hear_distance = 32,
			}, true)
		end
		core.after(0.12, decay_step)
	end

	core.after(0.15, decay_step)
end

core.register_node(HEART, {
	description = S("Hive heart"),
	tiles = { "mcl_core_slime.png^[colorize:#D9385A:95" },
	groups = soft_shell_groups,
	drop = "",
	light_source = 7,
	_mcl_hardness = 0.8,
	_mcl_blast_resistance = 3,
	on_timer = grow,
	after_dig_node = function(pos, oldnode, oldmetadata, digger)
		local fields = oldmetadata and oldmetadata.fields or {}
		local id = fields.hive_id or ""
		if id ~= "" then
			storage:set_int("sealed_" .. id, 1)
		end
		local cx, cz = math.floor(pos.x / CELL_SIZE), math.floor(pos.z / CELL_SIZE)
		storage:set_string(cell_key(cx, cz), "")

		local phase = math.max(1, tonumber(fields.phase) or 1)
		local max_r = PHASE_RADII[phase] or 20
		local ground_y = tonumber(fields.ground_y) or (pos.y - phase * 2)
		start_decay(pos, max_r, ground_y)

		-- Дроп с самого сердца в зависимости от фазы развития улья
		local p = vector.offset(pos, 0, 0.3, 0)
		core.add_item(p, "mcl_mobitems:slimeball " .. (phase * 3))
		core.add_item(p, "mcl_experience:bottle " .. (phase * 2))

		if phase >= 3 then
			core.add_item(p, "mcl_core:diamond " .. (phase - 1))
		end
		if phase >= MAX_PHASE and core.registered_items["mcl_core:apple_gold_enchanted"] then
			-- За победу над максимальным коконом до вылупления орды — супер-приз
			core.add_item(p, "mcl_core:apple_gold_enchanted 1")
		end
	end,
})
core.register_node(SLIME, {
	description = S("Hive living slime"),
	tiles = { "mcl_core_slime.png^[colorize:#289E82:65" },
	groups = {
		crumbly = 3,
		oddly_breakable_by_hand = 3,
		swordy = 3,
		bouncy = 65,
		fall_damage_add_percent = -85,
		not_in_creative_inventory = 1,
	},
	drop = {
	max_items = 1,
	items = {
		{ items = { "mcl_mobitems:slimeball" }, rarity = 4 },
	},
},
	light_source = 3,
	_mcl_hardness = 0.2,
	_mcl_blast_resistance = 1,
})
core.register_node(RIB, {
	description = S("Hive rib"),
	tiles = { "mcl_blackstone_side.png^[colorize:#3A4252:55" },
	groups = soft_shell_groups,
	drop = "",
	_mcl_hardness = 0.25,
	_mcl_blast_resistance = 2,
})
core.register_node(SHELL, {
	description = S("Hive chitin shell"),
	tiles = { "mcl_deepslate.png^[colorize:#1F353D:65" },
	groups = soft_shell_groups,
	drop = "",
	_mcl_hardness = 0.25,
	_mcl_blast_resistance = 2,
})
core.register_node(WEB, {
	description = S("Hive dense web"),
	drawtype = "plantlike",
	tiles = { "mcl_core_web.png" },
	paramtype = "light",
	sunlight_propagates = true,
	walkable = false,
	move_resistance = 7, -- Вязкое замедление как у ванильной паутины, но БЕЗ растекания жидкости
	groups = {
		crumbly = 3,
		oddly_breakable_by_hand = 3,
		swordy = 3,
		sheary = 3,
		dig_by_water = 1,
		not_in_creative_inventory = 1,
	},
	drop = {
	max_items = 1,
	items = {
		{ items = { "mcl_mobitems:string" }, rarity = 2 },
	},
},
	_mcl_hardness = 0.15,
})
core.register_node(TRAP, {
	description = S("Hive snare"),
	drawtype = "nodebox",
	tiles = { "mcl_blackstone_chiseled_polished.png^[colorize:#8C3DD9:85" },
	paramtype = "light",
	node_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, -0.4, 0.5 } },
	walkable = false,
	groups = soft_shell_groups,
	drop = "",
	light_source = 3,
	_mcl_hardness = 0.2,
	on_timer = trap_tick,
})
core.register_node(ACID, {
	description = S("Hive acid pool"),
	drawtype = "nodebox",
	tiles = { "mcl_core_slime.png^[colorize:#7CE81E:110" },
	paramtype = "light",
	node_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, -0.42, 0.5 } },
	walkable = false,
	groups = soft_shell_groups,
	drop = "",
	light_source = 4,
	_mcl_hardness = 0.2,
	on_timer = acid_tick,
})
core.register_node(NEST, {
	description = S("Hive nursery"),
	tiles = { "mob_spawner.png^[colorize:#2E8B75:75" },
	groups = soft_shell_groups,
	drop = {
	max_items = 2,
	items = {
		{ items = { "mcl_experience:bottle 2" }, rarity = 1 },
		{ items = { "mcl_mobitems:spider_eye" }, rarity = 2 },
	},
},
	light_source = 4,
	_mcl_hardness = 0.5,
	on_timer = nest_tick,
})
core.register_node(CACHE, {
	description = S("Sealed hive cache"),
	tiles = { "mcl_blackstone_gilded.png" },
	groups = soft_shell_groups,
	drop = "",
	_mcl_hardness = 0.8,
	on_rightclick = open_cache,
	after_dig_node = function(pos, oldnode, oldmetadata, digger)
		open_cache(pos, oldnode, digger)
	end,
})
return hive
