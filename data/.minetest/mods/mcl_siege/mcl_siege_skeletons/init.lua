local mob = mcl_mobs.mob_class
local tactics = setmetatable({}, { __mode = "k" })
local reserve = setmetatable({}, { __mode = "k" })
local formation_index = 0
local ANGLES = { 0, 0.55, -0.55, 1.15, -1.15, 1.85, -1.85, math.pi }

-- Частый спавн крупными стрелковыми отрядами (5-8 особей)
mcl_siege.configure_spawns("mobs_mc:skeleton", function(spawner)
	spawner.weight = spawner.biomes[1] == "SoulSandValley" and 45
		or spawner.biomes[1] == "DeepFrozenOcean" and 20 or 100
	spawner.pack_min, spawner.pack_max = 5, 8
end)

mcl_siege.configure_spawns("mobs_mc:stray", function(spawner)
	spawner.weight = 90
	spawner.pack_min, spawner.pack_max = 5, 8
end)

local function spawn_dash_dust(pos)
	core.add_particlespawner({
		amount = 6,
		time = 0.1,
		minpos = vector.offset(pos, -0.3, 0.05, -0.3),
		maxpos = vector.offset(pos, 0.3, 0.2, 0.3),
		minvel = { x = -0.8, y = 0.4, z = -0.8 },
		maxvel = { x = 0.8, y = 1.2, z = 0.8 },
		minexptime = 0.25,
		maxexptime = 0.5,
		minsize = 1.0,
		maxsize = 2.0,
		texture = "mcl_particles_smoke.png",
	})
end

-- Дополнительный быстрый выстрел через штатный API mcl_bows (без краша raycast)
local function fire_bonus_arrow(self, pos, target_pos)
	local start_pos = vector.offset(pos, 0, 1.45, 0)
	local aim_pos = vector.offset(target_pos, 0, 1.1, 0)
	local dir = vector.direction(start_pos, aim_pos)

	-- Небольшой разброс для подавляющего огня
	dir.x = dir.x + (math.random() - 0.5) * 0.14
	dir.y = dir.y + (math.random() - 0.5) * 0.08 + 0.04
	dir.z = dir.z + (math.random() - 0.5) * 0.14
	dir = vector.normalize(dir)

	if mcl_bows and mcl_bows.shoot_arrow then
		mcl_bows.shoot_arrow("mcl_bows:arrow", start_pos, dir, self.object:get_yaw(), self.object, 0.7, 2)
		core.sound_play("mobs_mc_bow_shoot", {
			pos = pos, gain = 0.7, pitch = math.random(95, 115) / 100, max_hear_distance = 24,
		}, true)
	end
end

local function find_position(self, pos, target_pos, goal, side)
	local origin = vector.round(vector.offset(pos, 0, 0.5, 0))
	local eye = mcl_util.target_eye_pos(self.attack)
	local distance = vector.distance(pos, target_pos)
	local away = math.atan2(pos.z - target_pos.z, pos.x - target_pos.x)
	local base = goal == "retreat" and away or away + side * math.pi / 2
	local best, best_score
	-- Увеличен шаг поиска позиции (5 блоков вместо 4), чтобы быстрее разбегаться по флангам
	for _, angle in ipairs(ANGLES) do
		local heading = base + side * angle
		local x = math.floor(math.cos(heading) * 5 + 0.5)
		local z = math.floor(math.sin(heading) * 5 + 0.5)
		for _, y in ipairs({ 0, 1, -1, 2, -2 }) do
			local candidate = vector.offset(origin, x, y, z)
			if mcl_siege.standable(candidate, 2) then
				local feet = vector.offset(candidate, 0, -0.5, 0)
				local range = vector.distance(feet, target_pos)
				local exposed = self:line_of_sight(vector.offset(feet, 0, 1.6, 0), eye)
				local score
				if goal == "retreat" and range > distance + 1.5 then
					score = range + (exposed and 0 or 4)
				elseif goal == "cover" and not exposed and range >= 5 and range <= 20 then
					score = 16 - math.abs(11 - range) - math.abs(angle)
				elseif goal == "peek" and exposed and range >= 5 and range <= 22 then
					score = 16 - math.abs(11 - range) - math.abs(angle)
				elseif goal == "flank" and exposed and range >= 6 and range <= 18
					and math.abs(angle) < 1.2 then
					score = 16 - math.abs(10 - range) - math.abs(angle)
				end
				if score and (not best_score or score > best_score) then
					best, best_score = feet, score
				end
				break
			end
		end
	end
	return best
end

local function attack_bowshoot(self, attach_pos, pos, dtime, target_pos, visible)
	local target = self.attack
	if not target or not target:is_player() or self.jockey_vehicle then
		return mob.attack_bowshoot(self, attach_pos, pos, dtime, target_pos, visible)
	end

	local state = tactics[self]
	if not state or state.target ~= target then
		formation_index = formation_index % 6 + 1
		state = {
			target = target,
			clock = 0,
			decide = 0.25 + formation_index * 0.15,
			side = formation_index % 2 == 0 and -1 or 1,
			volley_cd = 1.5 + math.random() * 1.5,
		}
		tactics[self] = state
	end
	state.clock = state.clock + dtime
	local distance = vector.distance(pos, target_pos)

	if state.goal then
		if distance > 3.0 and state.clock < state.move_until and not self:navigation_finished() then
			return
		end
		local reached_cover = state.goal == "cover" and not visible
			and vector.distance(pos, state.destination) <= 1.8
		self:cancel_navigation()
		self:halt_in_tracks()
		state.goal = nil
		-- Не засиживаются долго: из укрытия выскакивают уже через 0.45 сек
		state.decide = state.clock + (reached_cover and 0.45 or 0.85)
		if reached_cover then
			state.hold = true
			self:set_animation("stand")
		end
	end

	if state.hold and distance > 5 and state.clock < state.decide then
		return
	end

	-- Быстрые тактические перестроения каждые ~1.4 секунды
	if state.clock >= state.decide or (state.hold and distance <= 5) then
		state.decide = state.clock + 1.4
		local wounded = self.health <= self.object:get_properties().hp_max * 0.4
		local now = core.get_gametime()
		local lease = reserve[target]
		local can_cover = not lease or lease.expires <= now or lease.owner == self.object
		local under_fire = self._siege_under_fire and self._siege_under_fire >= now
		local goal

		if distance < 5.5 or (wounded and distance < 14) then
			goal = "retreat"
		elseif state.hold or not visible then
			goal = "peek"
		elseif can_cover and under_fire then
			goal = "cover"
		elseif distance > 5 and distance <= 18 then
			goal = "flank"
		end
		state.hold = nil

		if goal then
			local destination = find_position(self, pos, target_pos, goal, state.side)
			-- Увеличена скорость рывка (1.65 при отступлении, 1.35 при фланговом маневре)
			if destination and self:gopath(destination, goal == "retreat" and 1.65 or 1.35) then
				self:release_wielditem()
				self.attacking = false
				state.goal = goal
				state.destination = destination
				state.move_until = state.clock + 1.6
				spawn_dash_dust(pos)
				if math.random(1, 2) == 1 then
					core.sound_play("mobs_mc_skeleton_step", {
						pos = pos, gain = 0.65, pitch = math.random(90, 120) / 100, max_hear_distance = 20,
					}, true)
				end
				if goal == "cover" then
					reserve[target] = { owner = self.object, expires = now + 2.5 }
				end
				return
			end
		end
	end

	-- Дополнительный быстрый выстрел на подавление, когда цель в прямой видимости
	if visible and distance >= 7 and distance <= 22 and state.clock >= state.volley_cd then
		state.volley_cd = state.clock + 2.2 + math.random() * 1.4
		fire_bonus_arrow(self, pos, target_pos)
	end

	return mob.attack_bowshoot(self, attach_pos, pos, dtime, target_pos, visible)
end

for _, kind in ipairs({ "skeleton", "stray" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	def.attack_bowshoot = attack_bowshoot
	local rules = table.copy(def._targeting_rules)
	-- Видят и агрятся на игрока с 24 блоков вместо 6
	rules[2] = mcl_mobs.build_nearest_target_rule("player", nil, nil, nil, 24)
	def._targeting_rules = rules
	local old_receive_damage = def.receive_damage
	def.receive_damage = function(self, reason, damage)
		if damage > 0 and reason.source and reason.source:is_player() then
			self._siege_under_fire = core.get_gametime() + 3
		end
		return old_receive_damage(self, reason, damage)
	end
	local old_attack_end = def.attack_end
	def.attack_end = function(self)
		local state = tactics[self]
		if state then
			local lease = reserve[state.target]
			if lease and lease.owner == self.object then
				reserve[state.target] = nil
			end
			if state.goal or state.hold then
				self:cancel_navigation()
				self:halt_in_tracks()
			end
			tactics[self] = nil
		end
		return old_attack_end(self)
	end
end

