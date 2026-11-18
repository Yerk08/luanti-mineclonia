local mob = mcl_mobs.mob_class
local recent = {}
local reinforcement_after = 0
local progress = setmetatable({}, { __mode = "k" })
local BREAK_TIME = 6
local BREAK_WINDOW = 60
local LOCAL_LIMIT = 4
local GLOBAL_LIMIT = 24

local function configure_horde(spawner)
	spawner.weight = spawner.biomes[1] == "Desert" and 24 or 128
	spawner.pack_min = 6
	spawner.pack_max = 9
end

mcl_siege.configure_spawns("mobs_mc:zombie", configure_horde)
mcl_siege.configure_spawns("mobs_mc:husk", function(spawner)
	configure_horde(spawner)
	spawner.weight = 104 -- Together with desert zombies, the family still weighs 128.
end)

local function can_break(pos)
	local node = core.get_node(pos)
	local def = core.registered_nodes[node.name]
	local soft = node.name == "mcl_core:dirt" or node.name == "mcl_core:dirt_with_grass"
	local plank = def and def.drawtype == "normal" and core.get_item_group(node.name, "wood") > 0
	return (soft or plank) and not core.is_protected(pos, ""), node
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
	if length < 0.35 or math.abs(target_pos.y - pos.y) > 1.15 then
		return
	end
	local reach = math.min(length, 1.5)
	-- Check the head obstruction first so the zombie can keep its footing.
	for _, height in ipairs({ 1.45, 0.45 }) do
		local start = vector.offset(pos, 0, height, 0)
		local finish = vector.offset(start, dx * reach / length, 0, dz * reach / length)
		for hit in core.raycast(start, finish, false, false) do
			if hit.type == "node" then
				if can_break(hit.under) then
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
	if visible or not target or not target:is_player() or self.jockey_vehicle
		or (self._siege_blocks_broken or 0) >= 2 or vector.distance(pos, target_pos) > 7
		or mcl_vars.difficulty == 0 then
		progress[self] = nil
		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end

	if not state or state.target ~= target then
		state = { target = target, check = 0, elapsed = 0 }
		progress[self] = state
	end
	state.check = state.check - dtime
	if state.check <= 0 then
		state.check = 0.35
		local velocity = self.object:get_velocity()
		local moving = velocity.x * velocity.x + velocity.z * velocity.z > 0.36
		local pos_to_break
		if state.node or (not moving and self:navigation_finished()) then
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
		state.hit_at = state.elapsed + 1
		self:set_animation("punch")
		core.sound_play("mobs_mc_zombie_door_break", {
			pos = state.node, gain = 0.35, max_hear_distance = 14,
		}, true)
	end
	if state.elapsed >= BREAK_TIME then
		local allowed, node = can_break(state.node)
		local obstruction = allowed and find_block(pos, target_pos)
		if obstruction and vector.equals(obstruction, state.node) then
			core.remove_node(state.node)
			recent[#recent + 1] = { pos = state.node, time = now }
			self._siege_blocks_broken = (self._siege_blocks_broken or 0) + 1
			local def = core.registered_nodes[node.name]
			if def.sounds and def.sounds.dug then
				core.sound_play(def.sounds.dug, { pos = state.node }, true)
			end
		end
		progress[self] = nil
		self._gopath_delay = 0
	end
end

local function installed_reinforcement_limit(original)
	return function(self, reason)
		local now = core.get_gametime()
		if now < reinforcement_after or not original(self, reason) then
			return false
		end
		local count = 0
		for _, object in ipairs(core.get_objects_inside_radius(self.object:get_pos(), 24)) do
			local entity = object:get_luaentity()
			if entity and entity.is_mob and entity._reinforcement_type and not entity.dead then
				count = count + 1
				if count >= 12 then
					return false
				end
			end
		end
		reinforcement_after = now + 8
		return true
	end
end

for _, kind in ipairs({ "zombie", "baby_zombie", "husk", "baby_husk" }) do
	local def = core.registered_entities["mobs_mc:" .. kind]
	local siege_enabled = mobs_mc.is_mob_griefing_enabled("zombie")
		and mobs_mc.is_mob_griefing_enabled(kind)
	local old_ai_step = def.ai_step
	def.ai_step = function(self, dtime)
		-- The stock hard-mode door destruction bypasses the breach budget.
		self._can_break_doors = false
		self._breaking_door = nil
		return old_ai_step(self, dtime)
	end
	def.can_spawn_reinforcements = installed_reinforcement_limit(def.can_spawn_reinforcements)
	if siege_enabled and (kind == "zombie" or kind == "husk") then
		local rules = table.copy(def._targeting_rules)
		rules[2] = mcl_mobs.build_nearest_target_rule("player", nil, nil, nil, 12)
		def._targeting_rules = rules
		def.attack_melee = attack_melee
		local old_attack_end = def.attack_end
		def.attack_end = function(self)
			progress[self] = nil
			return old_attack_end(self)
		end
	end
end
