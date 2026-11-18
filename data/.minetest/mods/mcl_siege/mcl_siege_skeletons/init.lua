local mob = mcl_mobs.mob_class
local tactics = setmetatable({}, { __mode = "k" })
local reserve = setmetatable({}, { __mode = "k" })
local formation_index = 0
local ANGLES = { 0, 0.65, -0.65, 1.35, -1.35, 2.1, -2.1, math.pi }

mcl_siege.configure_spawns("mobs_mc:skeleton", function(spawner)
	spawner.weight = spawner.biomes[1] == "SoulSandValley" and 20
		or spawner.biomes[1] == "DeepFrozenOcean" and 8 or 40
	spawner.pack_min, spawner.pack_max = 2, 3
end)
mcl_siege.configure_spawns("mobs_mc:stray", function(spawner)
	spawner.weight = 32
	spawner.pack_min, spawner.pack_max = 2, 3
end)

local function find_position(self, pos, target_pos, goal, side)
	local origin = vector.round(vector.offset(pos, 0, 0.5, 0))
	local eye = mcl_util.target_eye_pos(self.attack)
	local distance = vector.distance(pos, target_pos)
	local away = math.atan2(pos.z - target_pos.z, pos.x - target_pos.x)
	local base = goal == "retreat" and away or away + side * math.pi / 2
	local best, best_score
	for _, angle in ipairs(ANGLES) do
		local heading = base + side * angle
		local x = math.floor(math.cos(heading) * 4 + 0.5)
		local z = math.floor(math.sin(heading) * 4 + 0.5)
		for _, y in ipairs({ 0, 1, -1 }) do
			local candidate = vector.offset(origin, x, y, z)
			if mcl_siege.standable(candidate, 2) then
				local feet = vector.offset(candidate, 0, -0.5, 0)
				local range = vector.distance(feet, target_pos)
				local exposed = self:line_of_sight(vector.offset(feet, 0, 1.6, 0), eye)
				local score
				if goal == "retreat" and range > distance + 1.2 then
					score = range + (exposed and 0 or 3)
				elseif goal == "cover" and not exposed and range >= 4 and range <= 15 then
					score = 12 - math.abs(9 - range) - math.abs(angle)
				elseif goal == "peek" and exposed and range >= 4 and range <= 15 then
					score = 12 - math.abs(8 - range) - math.abs(angle)
				elseif goal == "flank" and exposed and range >= 5 and range <= 13
					and math.abs(angle) < 1 then
					score = 12 - math.abs(8 - range) - math.abs(angle)
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
	if not target:is_player() or self.jockey_vehicle then
		return mob.attack_bowshoot(self, attach_pos, pos, dtime, target_pos, visible)
	end

	local state = tactics[self]
	if not state or state.target ~= target then
		formation_index = formation_index % 4 + 1
		state = {
			target = target, clock = 0, decide = 0.45 + formation_index * 0.27,
			side = formation_index % 2 == 0 and -1 or 1,
		}
		tactics[self] = state
	end
	state.clock = state.clock + dtime
	local distance = vector.distance(pos, target_pos)
	if state.goal then
		if distance > 2.5 and state.clock < state.move_until and not self:navigation_finished() then
			return
		end
		local reached_cover = state.goal == "cover" and not visible
			and vector.distance(pos, state.destination) <= 1.5
		self:cancel_navigation()
		self:halt_in_tracks()
		state.goal = nil
		state.decide = state.clock + (reached_cover and 1.1 or 1.65)
		if reached_cover then
			state.hold = true
			self:set_animation("stand")
		end
	end
	if state.hold and distance > 4 and state.clock < state.decide then
		return
	end

	if state.clock >= state.decide or (state.hold and distance <= 4) then
		state.decide = state.clock + 2.7
		local wounded = self.health <= self.object:get_properties().hp_max * 0.35
		local now = core.get_gametime()
		local lease = reserve[target]
		local can_cover = not lease or lease.expires <= now or lease.owner == self.object
		local under_fire = self._siege_under_fire and self._siege_under_fire >= now
		local goal
		if distance < 4 or (wounded and distance < 12) then
			goal = "retreat"
		elseif state.hold or not visible then
			goal = "peek"
		elseif can_cover and (under_fire or distance < 8) then
			goal = "cover"
		elseif distance > 4 and distance <= 13 and not can_cover then
			goal = "flank"
		end
		state.hold = nil

		if goal then
			local destination = find_position(self, pos, target_pos, goal, state.side)
			if destination and self:gopath(destination, goal == "retreat" and 1.35 or 1.05) then
				self:release_wielditem()
				self.attacking = false
				state.goal = goal
				state.destination = destination
				state.move_until = state.clock + 2.4
				if goal == "cover" then
					reserve[target] = { owner = self.object, expires = now + 5 }
				end
				return
			end
		end
	end
	return mob.attack_bowshoot(self, attach_pos, pos, dtime, target_pos, visible)
end

for _, kind in ipairs({ "skeleton", "stray" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	def.attack_bowshoot = attack_bowshoot
	local rules = table.copy(def._targeting_rules)
	rules[2] = mcl_mobs.build_nearest_target_rule("player", nil, nil, nil, 6)
	def._targeting_rules = rules
	local old_receive_damage = def.receive_damage
	def.receive_damage = function(self, reason, damage)
		if damage > 0 and reason.source and reason.source:is_player() then
			self._siege_under_fire = core.get_gametime() + 5
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
