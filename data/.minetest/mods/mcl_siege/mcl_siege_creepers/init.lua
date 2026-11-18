local mob = mcl_mobs.mob_class
local movement = setmetatable({}, { __mode = "k" })

-- Редкие одиночки: никаких массовых взрывов, только внезапные засады
mcl_siege.configure_spawns("mobs_mc:creeper", function(spawner)
	spawner.weight = 14
	spawner.pack_min, spawner.pack_max = 1, 1
end)

-- Проверяем, смотрит ли игрок в сторону крипера (широкий угол обзора)
local function watched(target, pos)
	local eye = mcl_util.target_eye_pos(target)
	local toward = vector.direction(eye, vector.offset(pos, 0, 1.0, 0))
	return vector.dot(toward, target:get_look_dir()) > 0.45
end

-- Поиск укрытия вне прямой видимости игрока или вне его конуса взгляда
local function find_hiding_spot(self, pos, target)
	local target_pos = target:get_pos()
	local eye = mcl_util.target_eye_pos(target)
	local away_angle = math.atan2(pos.z - target_pos.z, pos.x - target_pos.x)
	local origin = vector.round(vector.offset(pos, 0, 0.5, 0))
	local best, best_score

	for _, dist in ipairs({ 5, 8 }) do
		for _, offset in ipairs({ 0, 0.6, -0.6, 1.2, -1.2, 1.8, -1.8 }) do
			local angle = away_angle + offset
			local x = math.floor(math.cos(angle) * dist + 0.5)
			local z = math.floor(math.sin(angle) * dist + 0.5)
			for _, y in ipairs({ 0, 1, -1, 2, -2 }) do
				local cell = vector.offset(origin, x, y, z)
				if mcl_siege.standable(cell, 2) then
					local feet = vector.offset(cell, 0, -0.5, 0)
					local hidden = not self:line_of_sight(vector.offset(feet, 0, 1.3, 0), eye)
					local out_of_sight = not watched(target, feet)
					local range = vector.distance(feet, target_pos)
					local score = range
						+ (hidden and 15 or 0)
						+ (out_of_sight and 8 or 0)
					if not best_score or score > best_score then
						best, best_score = feet, score
					end
					break
				end
			end
		end
	end
	return best
end

local function stealth_melee(self, attach_pos, pos, dtime, target_pos, visible)
	local target = self.attack
	if not target or not target:is_player() or self.jockey_vehicle then
		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end

	local now = core.get_gametime()
	local state = movement[self]
	if not state or state.target ~= target then
		state = { target = target, retry = 0, mode = "stalk" }
		movement[self] = state
	end

	local dist = vector.distance(pos, target_pos)
	local seen = visible and watched(target, pos)

	-- 1. Игрок заметил крипера: отменяем атаку/шипение и срочно прячемся
	if seen and dist > 1.8 then
		if self._swell_dir == 1 then
			self._swell_dir = -1
		end
		if state.mode ~= "hide" or now >= state.retry then
			state.mode = "hide"
			state.retry = now + 1.5
			local hide_pos = find_hiding_spot(self, pos, target)
			if hide_pos and self:gopath(hide_pos, 1.55) then
				state.moving_until = now + 2.5
				return
			end
		end
		if state.moving_until and now < state.moving_until and not self:navigation_finished() then
			return
		end
		-- Если бежать некуда, замираем на месте в надежде остаться незамеченным
		self:cancel_navigation()
		self:halt_in_tracks()
		return
	end

	-- 2. Игрок отвернулся: стремительный бесшумный рывок со спины
	if not seen then
		state.mode = "ambush"
		if dist > 2.0 and dist <= 18 then
			if now >= state.retry or self:navigation_finished() then
				state.retry = now + 0.6
				-- Бежим прямо за спину игроку на высокой скорости (1.65)
				local look = target:get_look_dir()
				local behind = vector.offset(target_pos, -look.x * 1.1, 0, -look.z * 1.1)
				self:gopath(behind, 1.65)
			end
			return
		end
	end

	return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
end

local function explode(self, pos, strength)
	local lingering = {}
	for name, effect in pairs(mcl_potions.all_effects(self.object)) do
		lingering[name] = { duration = effect.dur, level = mcl_potions.get_effect_level(self.object, name) }
	end
	self:safe_remove()
	mcl_explosions.explode(pos, math.min(strength, 4), {
		griefing = true,
		fire = true,
	}, self.object, self.object)

	-- Эффект внезапного шока: кратковременная дезориентация игроков рядом со взрывом
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 5)) do
		if obj:is_player() and mcl_potions.give_effect then
			mcl_potions.give_effect("blindness", obj, 1, 2)
		end
	end

	for name, effect in pairs(lingering) do
		mcl_potions.add_lingering_effect(pos, name, effect.duration / 2, effect.level, 2.5)
	end
end

for _, kind in ipairs({ "creeper", "creeper_charged" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	def.attack_melee = stealth_melee
	def.pursuit_bonus = 1.25
	def.creeper_explode = explode

	-- Выслеживают игрока издалека (с 22 блоков)
	local rules = table.copy(def._targeting_rules)
	rules[2] = mcl_mobs.build_nearest_target_rule("player", nil, nil, nil, 22)
	def._targeting_rules = rules

	-- Начинают шипеть только вплотную со спины или в самый последний момент
	def.pre_melee_attack = function(self, distance, delay, visible)
		local target = self.attack
		local pos = self.object:get_pos()
		if target and target:is_player() and pos and watched(target, pos) and distance > 1.8 then
			return false
		end
		return distance <= 2.3 and mob.pre_melee_attack(self, distance, delay, visible)
	end

	local old_custom = def.do_custom
	def.do_custom = function(self, dtime)
		if self._swell_dir == 1 and self.attack ~= self.object then
			local target = self.attack
			local target_pos = target and target:is_valid() and target:get_pos()
			local pos = self.object:get_pos()
			-- Если игрок успел отбежать или вовремя обернулся на дистанции > 2.2, крипер сбрасывает взрыв и отступает
			if not target_pos or vector.distance(pos, target_pos) > 3.2
				or (target:is_player() and watched(target, pos) and vector.distance(pos, target_pos) > 2.2) then
				self._swell_dir = -1
			end
		end
		return old_custom(self, dtime)
	end

	local old_attack_end = def.attack_end
	def.attack_end = function(self)
		movement[self] = nil
		return old_attack_end(self)
	end
end

