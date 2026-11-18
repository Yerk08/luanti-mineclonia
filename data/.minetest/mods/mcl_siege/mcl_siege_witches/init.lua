local witch = core.registered_entities["mobs_mc:witch"]
local original_attack = witch.attack_ranged
local rituals = setmetatable({}, { __mode = "k" })
local RADIUS = 3.5
local WARNING = 1.65
local curses = {
	{ color = "#863EF5", effects = { { "blindness", 1, 2.5 }, { "slowness", 1, 4 } } },
	{ color = "#86D436", effects = { { "weakness", 1, 6 }, { "poison", 1, 3.5 } } },
	{ color = "#D64D99", effects = { { "levitation", 1, 1.2 }, { "weakness", 1, 4 } } },
}

mcl_siege.configure_spawns("mobs_mc:witch", function(spawner)
	spawner.weight = 4
end)

local function cast(self, ritual)
	for _, player in ipairs(core.get_connected_players()) do
		local pos = player:get_pos()
		if mcl_siege.is_survival_player(player) and vector.distance(pos, ritual.center) <= RADIUS
			and self:line_of_sight(vector.offset(ritual.center, 0, 0.9, 0), mcl_util.target_eye_pos(player)) then
			for _, effect in ipairs(ritual.curse.effects) do
				mcl_potions.give_effect_by_level(effect[1], player, effect[2], effect[3])
			end
		end
	end
end

function witch:attack_ranged(attach_pos, pos, dtime, target_pos, visible)
	local target = self.attack
	if not target:is_player() or not mcl_siege.is_survival_player(target) then
		rituals[self] = nil
		return original_attack(self, attach_pos, pos, dtime, target_pos, visible)
	end
	local state = rituals[self]
	if not state or state.target ~= target then
		state = { cooldown = math.random(3, 6), target = target }
		rituals[self] = state
	end
	state.cooldown = state.cooldown - dtime
	if state.ritual then
		local ritual = state.ritual
		ritual.remaining = ritual.remaining - dtime
		self:look_at(target_pos)
		if ritual.remaining <= 0 then
			cast(self, ritual)
			state.ritual = nil
		end
		return
	end
	local distance = vector.distance(pos, target_pos)
	if state.cooldown <= 0 and visible and distance >= 3 and distance <= 11
		and self:get_wielditem():is_empty() then
		local curse = curses[math.random(#curses)]
		state.ritual = { center = target_pos, remaining = WARNING, curse = curse }
		state.cooldown = math.random(12, 17)
		self:cancel_navigation()
		self:halt_in_tracks()
		self:look_at(target_pos)
		self:set_animation("shoot")
		mcl_siege.rune(target_pos, RADIUS, curse.color, WARNING)
		return
	end
	return original_attack(self, attach_pos, pos, dtime, target_pos, visible)
end

local old_attack_end = witch.attack_end
function witch:attack_end()
	rituals[self] = nil
	return old_attack_end(self)
end
