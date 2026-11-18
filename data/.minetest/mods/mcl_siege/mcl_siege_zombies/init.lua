local mob = mcl_mobs.mob_class
local recent = {}
local reinforcement_after = 0
local progress = setmetatable({}, { __mode = "k" })

-- Настройки агрессии и разрушений
local BREAK_TIME = 2.5      -- Было 6: ломают блоки более чем в 2 раза быстрее
local BREAK_WINDOW = 45     -- Окно сброса лимитов
local LOCAL_LIMIT = 16      -- Было 4: могут разнести целую стену в одном месте
local GLOBAL_LIMIT = 64     -- Было 24: общий лимит разрушений выше
local MAX_BLOCKS_PER_ZOMBIE = 12 -- Было 2: один зомби может пробить целый туннель

local function configure_horde(spawner)
	-- Выравниваем вес со скелетами и криперами (100 вместо 128), чтобы зомби не забивали весь лимит спавна
	spawner.weight = (spawner.biomes[1] == "Desert") and 20 or 100
	spawner.pack_min = 5
	spawner.pack_max = 9
end

mcl_siege.configure_spawns("mobs_mc:zombie", configure_horde)
mcl_siege.configure_spawns("mobs_mc:husk", function(spawner)
	configure_horde(spawner)
	spawner.weight = 80 -- В сумме с пустынными зомби (20) дает те же 100
end)


local function can_break(pos)
	local node = core.get_node(pos)
	if not node or node.name == "air" or node.name == "ignore" then
		return false, nil
	end
	local def = core.registered_nodes[node.name]
	if not def or def.liquidtype ~= "none" or not def.walkable then
		return false, nil
	end
	-- Не ломаем бедрок, барьеры и защищенные территории
	if core.get_item_group(node.name, "unbreakable") > 0 or def.can_dig == false then
		return false, nil
	end
	if core.is_protected(pos, "") then
		return false, nil
	end
	-- Возвращаем true И сам объект node, чтобы избежать краша
	return true, node
end

local function budget_available(pos, now)
	while recent[1] and now - recent[1].time >= BREAK_WINDOW do
		table.remove(recent, 1)
	end
	if #recent >= GLOBAL_LIMIT then
		return false
	end
	local count = 0
	for _, entry in ipairs(recent) do
		if vector.distance(entry.pos, pos) <= 16 then
			count = count + 1
		end
	end
	return count < LOCAL_LIMIT
end

local function find_block(pos, target_pos)
	local dx, dz = target_pos.x - pos.x, target_pos.z - pos.z
	local length = math.sqrt(dx * dx + dz * dz)
	-- Увеличена допустимая разница по высоте (с 1.15 до 2.5), чтобы доставали игроков на возвышенностях
	if length < 0.35 or math.abs(target_pos.y - pos.y) > 2.5 then
		return
	end
	local reach = math.min(length, 1.8) -- Чуть длиннее руки для наглости
	-- Проверяем уровень головы, груди и ног, чтобы пробивать полный проход
	for _, height in ipairs({ 1.45, 0.95, 0.45 }) do
		local start = vector.offset(pos, 0, height, 0)
		local finish = vector.offset(start, dx * reach / length, 0, dz * reach / length)
		for hit in core.raycast(start, finish, false, false) do
			if hit.type == "node" then
				local allowed = can_break(hit.under)
				if allowed then
					return hit.under
				end
				break
			end
		end
	end
end

local function attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	local state = progress[self]
	local target = self.attack
	-- Увеличена дистанция агрессии с 7 до 16 блоков и лимит блоков на одного зомби
	if visible or not target or not target:is_player() or self.jockey_vehicle
		or (self._siege_blocks_broken or 0) >= MAX_BLOCKS_PER_ZOMBIE or vector.distance(pos, target_pos) > 16
		or mcl_vars.difficulty == 0 then
		progress[self] = nil
		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end

	if not state or state.target ~= target then
		state = { target = target, check = 0, elapsed = 0, hit_at = 0 }
		progress[self] = state
	end
	state.check = state.check - dtime
	if state.check <= 0 then
		state.check = 0.25
		local velocity = self.object:get_velocity()
		local moving = velocity.x * velocity.x + velocity.z * velocity.z > 0.5
		local pos_to_break
		-- Начинают ломать сразу, как только замедлились перед препятствием, не дожидаясь конца навигации
		if state.node or not moving then
			pos_to_break = find_block(pos, target_pos)
		end
		local old = state.node
		if not old or not pos_to_break or not vector.equals(old, pos_to_break) then
			state.elapsed = 0
			state.hit_at = 0
		end
		state.node = pos_to_break
	end

	if not state.node then
		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end
	local now = core.get_gametime()
	if not budget_available(state.node, now) then
		progress[self] = nil
		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end

	self:cancel_navigation()
	self:halt_in_tracks()
	self:look_at(target_pos)
	state.elapsed = state.elapsed + math.min(dtime, 0.25)

	if state.elapsed >= state.hit_at then
		state.hit_at = state.elapsed + 0.6 -- Бьют чаще и яростнее
		self:set_animation("punch")
		core.sound_play("mobs_mc_zombie_door_break", {
			pos = state.node, gain = 0.6, max_hear_distance = 24,
		}, true)
		-- Зловещее рычание при атаке укреплений
		if math.random(1, 3) == 1 then
			core.sound_play("mobs_mc_zombie_growl", {
				pos = pos, gain = 0.7, pitch = math.random(80, 110) / 100, max_hear_distance = 24,
			}, true)
		end
		-- Частицы летящих щепок/пыли при ударах
		local node = core.get_node(state.node)
		if node and node.name ~= "air" then
			core.add_particlespawner({
				amount = 8,
				time = 0.1,
				minpos = vector.subtract(state.node, 0.4),
				maxpos = vector.add(state.node, 0.4),
				minvel = { x = -1.5, y = 0.5, z = -1.5 },
				maxvel = { x = 1.5, y = 2.5, z = 1.5 },
				minacc = { x = 0, y = -9.8, z = 0 },
				maxacc = { x = 0, y = -9.8, z = 0 },
				minexptime = 0.3,
				maxexptime = 0.7,
				minsize = 1,
				maxsize = 2.5,
				node = node,
			})
		end
	end

	if state.elapsed >= BREAK_TIME then
		local allowed, node = can_break(state.node)
		local obstruction = allowed and find_block(pos, target_pos)
		if obstruction and vector.equals(obstruction, state.node) and node then
			core.remove_node(state.node)
			recent[#recent + 1] = { pos = state.node, time = now }
			self._siege_blocks_broken = (self._siege_blocks_broken or 0) + 1
			local def = core.registered_nodes[node.name]
			if def and def.sounds and def.sounds.dug then
				core.sound_play(def.sounds.dug, { pos = state.node, gain = 1.0, max_hear_distance = 24 }, true)
			end
			-- Эффектный разлет осколков при полном разрушении блока
			core.add_particlespawner({
				amount = 20,
				time = 0.1,
				minpos = vector.subtract(state.node, 0.5),
				maxpos = vector.add(state.node, 0.5),
				minvel = { x = -2.5, y = 1.0, z = -2.5 },
				maxvel = { x = 2.5, y = 4.0, z = 2.5 },
				minacc = { x = 0, y = -9.8, z = 0 },
				maxacc = { x = 0, y = -9.8, z = 0 },
				minexptime = 0.5,
				maxexptime = 1.2,
				minsize = 1.5,
				maxsize = 3.5,
				node = node,
			})
		end
		progress[self] = nil
		self._gopath_delay = 0
	end
end

local function installed_reinforcement_limit(original)
	return function(self, reason)
		local now = core.get_gametime()
		if now = 18 then -- Было 12: больше подкреплений в орде
					return false
				end
			end
		end
		reinforcement_after = now + 5 -- Было 8: подкрепления приходят чаще
		return true
	end
end

for _, kind in ipairs({ "zombie", "baby_zombie", "husk", "baby_husk" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	local siege_enabled = mobs_mc.is_mob_griefing_enabled("zombie")
		and mobs_mc.is_mob_griefing_enabled(kind)
	local old_ai_step = def.ai_step
	def.ai_step = function(self, dtime)
		self._can_break_doors = false
		self._breaking_door = nil
		return old_ai_step(self, dtime)
	end
	def.can_spawn_reinforcements = installed_reinforcement_limit(def.can_spawn_reinforcements)
	-- Разрешаем крушить блоки не только взрослым, но и мелким зомби (baby_zombie, baby_husk)
	if siege_enabled then
		local rules = table.copy(def._targeting_rules)
		-- Чуют игрока сквозь стены с 24 блоков вместо 12
		rules[2] = mcl_mobs.build_nearest_target_rule("player", nil, nil, nil, 24)
		def._targeting_rules = rules
		def.attack_melee = attack_melee
		local old_attack_end = def.attack_end
		def.attack_end = function(self)
			progress[self] = nil
			return old_attack_end(self)
		end
	end
end

