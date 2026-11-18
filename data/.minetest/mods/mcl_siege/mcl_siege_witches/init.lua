local witch = core.registered_entities["mobs_mc:witch"]
local original_attack = witch.attack_ranged
local rituals = setmetatable({}, { __mode = "k" })
local RADIUS = 4.2
local WARNING = 1.4

-- Пул необычных и фановых эффектов для случайной комбинации
-- Формат: { имя_эффекта, мин_уровень, макс_уровень, мин_сек, макс_сек, цвет_руны }
local chaotic_pool = {
	-- Левитация: мягко подбрасывает в воздух, не убивая падением
	{ "levitation",       1, 2, 1.5, 2.2, "#D64D99" },
	-- Гипер-прыжок: непривычно высоко подкидывает при нажатии пробела
	{ "leaping",          3, 5, 5.0, 8.0, "#4DFF88" },
	-- Бешеная скорость: резко сбивает привычный контроль движения
	{ "swiftness",        3, 4, 4.0, 6.0, "#5CE1E6" },
	-- Тошнота: искажает экран, но не наносит урона
	{ "nausea",           1, 1, 5.0, 8.0, "#6B8E23" },
	-- Слепота: резкое сужение обзора
	{ "blindness",        1, 1, 2.5, 4.0, "#863EF5" },
	-- Сильное замедление (вязкость)
	{ "slowness",         2, 3, 3.5, 5.5, "#5A6C81" },
	-- Усталость: замедляет взмах мечом и копание
	{ "mining_fatigue",   2, 3, 6.0, 9.0, "#A08C5B" },
	-- Слабость
	{ "weakness",         1, 2, 5.0, 8.0, "#484D48" },
	-- Яд (короткий, чтобы пощекотать нервы)
	{ "poison",           1, 1, 2.5, 4.0, "#86D436" },
	-- Голод
	{ "hunger",           2, 3, 6.0, 9.0, "#587653" },
	-- Внезапное ночное зрение или свечение
	{ "glowing",          1, 1, 8.0, 12.0, "#FFF066" },
}

-- Частый спавн ведьм (как вы просили для «королев»)
mcl_siege.configure_spawns("mobs_mc:witch", function(spawner)
	spawner.weight = 55
	spawner.pack_min = 2
	spawner.pack_max = 3
end)

-- Собираем случайный набор из 2-3 неповторяющихся эффектов для каждого ритуала
local function roll_random_curse()
	local indices = {}
	for i = 1, #chaotic_pool do
		indices[i] = i
	end
	-- Перемешиваем пул
	for i = #indices, 2, -1 do
		local j = math.random(i)
		indices[i], indices[j] = indices[j], indices[i]
	end

	local count = math.random(2, 3)
	local chosen_effects = {}
	local rune_color = chaotic_pool[indices[1]][6]

	for i = 1, count do
		local entry = chaotic_pool[indices[i]]
		local name = entry[1]
		-- Проверяем, зарегистрирован ли эффект в текущей версии Mineclonia
		if mcl_potions.registered_effects and mcl_potions.registered_effects[name] then
			local level = math.random(entry[2], entry[3])
			local duration = entry[4] + math.random() * (entry[5] - entry[4])
			chosen_effects[#chosen_effects + 1] = { name, level, duration }
		end
	end

	-- Запасной вариант, если ни один эффект не подошёл
	if #chosen_effects == 0 then
		chosen_effects[1] = { "levitation", 1, 1.8 }
	end

	return {
		color = rune_color,
		effects = chosen_effects,
	}
end

local function cast(self, ritual)
	core.sound_play("mobs_mc_witch_celebrate", {
		pos = ritual.center, gain = 0.8, pitch = math.random(90, 115) / 100, max_hear_distance = 20,
	}, true)

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
	if not target or not target:is_player() or not mcl_siege.is_survival_player(target) then
		rituals[self] = nil
		return original_attack(self, attach_pos, pos, dtime, target_pos, visible)
	end

	local state = rituals[self]
	if not state or state.target ~= target then
		state = { cooldown = math.random(2, 4), target = target }
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
	-- Колдуют чаще и с более дальней дистанции (до 15 блоков)
	if state.cooldown <= 0 and visible and distance >= 2.5 and distance <= 15
		and self:get_wielditem():is_empty() then
		local curse = roll_random_curse()
		state.ritual = { center = target_pos, remaining = WARNING, curse = curse }
		state.cooldown = math.random(6, 10)
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

