local mob = mcl_mobs.mob_class
local movement = setmetatable({}, { __mode = "k" })

mcl_siege.configure_spawns("mobs_mc:creeper", function(spawner)
	spawner.weight = 12
	spawner.pack_min, spawner.pack_max = 1, 2
end)

local function watched(target, pos)
	local toward = vector.direction(mcl_util.target_eye_pos(target), vector.offset(pos, 0, 0.9, 0))
	return vector.dot(toward, target:get_look_dir()) > 0.72
end

local function flank(self, pos, target_pos)
	local dx, dz = target_pos.x - pos.x, target_pos.z - pos.z
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1 then
		return
	end
	dx, dz = dx / length, dz / length
	local start_side = math.random(2) == 1 and -1 or 1
	local origin = vector.round(vector.offset(pos, 0, 0.5, 0))
	local eye = mcl_util.target_eye_pos(self.attack)
	local open
	for _, side in ipairs({ start_side, -start_side }) do
		local x = math.floor(dx * 2 - dz * side * 4 + 0.5)
		local z = math.floor(dz * 2 + dx * side * 4 + 0.5)
		for _, y in ipairs({ 0, 1, -1 }) do
			local cell = vector.offset(origin, x, y, z)
			if mcl_siege.standable(cell, 2) then
				local feet = vector.offset(cell, 0, -0.5, 0)
				if not self:line_of_sight(vector.offset(feet, 0, 1.2, 0), eye) then
					return feet
				end
				open = open or feet
				break
			end
		end
	end
	return open
end

local function cautious_melee(self, attach_pos, pos, dtime, target_pos, visible)
	local target = self.attack
	if target:is_player() and not self.jockey_vehicle then
		local now = core.get_gametime()
		local state = movement[self]
		if not state or state.target ~= target then
			state = { target = target, retry = now }
			movement[self] = state
		end
		local dist = vector.distance(pos, target_pos)
		if state.moving then
			if now < state.moving and dist > 2.2 and not self:navigation_finished() then
				return
			end
			state.moving = nil
			self:cancel_navigation()
			self:halt_in_tracks()
			self._target_pos = nil
			self._gopath_delay = 0
		elseif now >= state.retry and visible and dist > 3 and dist < 11 then
			state.retry = now + 5
			if watched(target, pos) then
				local destination = flank(self, pos, target_pos)
				if destination and self:gopath(destination, 0.8) then
					state.moving = now + 2
					return
				end
			end
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
		griefing = false,
		fire = false,
	}, self.object, self.object)
	for name, effect in pairs(lingering) do
		mcl_potions.add_lingering_effect(pos, name, effect.duration / 2, effect.level, 2.5)
	end
end

for _, kind in ipairs({ "creeper", "creeper_charged" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	def.attack_melee = cautious_melee
	def.pursuit_bonus = 0.78
	def.creeper_explode = explode
	def.pre_melee_attack = function(self, distance, delay, visible)
		return distance <= 2.2 and mob.pre_melee_attack(self, distance, delay, visible)
	end
	local old_custom = def.do_custom
	def.do_custom = function(self, dtime)
		if self._swell_dir == 1 and self.attack ~= self.object then
			local target = self.attack
			local target_pos = target and target:is_valid() and target:get_pos()
			local pos = self.object:get_pos()
			if not target_pos or vector.distance(pos, target_pos) > 3.4
				or not self:target_visible(pos, target) then
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
