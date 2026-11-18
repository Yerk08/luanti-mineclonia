return function(hive)
	local modname = core.get_current_modname()
	local S = core.get_translator(modname)
	local storage = core.get_mod_storage()
	local mob = mcl_mobs.mob_class
	local combat = setmetatable({}, { __mode = "k" })
	local CHECK_SITES = {
		{ 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 },
		{ 3, 3 }, { -3, 3 }, { -3, -3 }, { 3, -3 }, { 0, 0 },
	}
	local WARNING, RADIUS = 1.5, 4.0
	local names = { modname .. ":vespera", modname .. ":kharza" }

	-- Пул случайных эффектов для заклинаний королевы
	local queen_curses = {
		{ "darkness", 1, 4.0 },
		{ "weakness", 1, 5.0 },
		{ "slowness", 2, 4.5 },
		{ "levitation", 1, 1.7 },
		{ "nausea", 1, 5.0 },
		{ "poison", 1, 3.5 },
		{ "mining_fatigue", 2, 6.0 },
	}

	-- Регистрация снаряда кислоты для королев
	local acid_entity = modname .. ":acid_spit"
	core.register_entity(acid_entity, {
		initial_properties = {
			visual = "sprite",
			visual_size = { x = 0.55, y = 0.55 },
			textures = { "mcl_particles_effect.png^[colorize:#7CFF24:220" },
			physical = true,
			collide_with_objects = false,
			collisionbox = { -0.15, -0.15, -0.15, 0.15, 0.15, 0.15 },
			glow = 10,
		},
		_age = 0,
		on_step = function(self, dtime)
			self._age = self._age + dtime
			local pos = self.object:get_pos()
			if not pos or self._age > 3.5 then
				self.object:remove()
				return
			end

			core.add_particle({
				pos = pos,
				velocity = { x = (math.random() - 0.5) * 0.5, y = -0.5, z = (math.random() - 0.5) * 0.5 },
				expirationtime = 0.35,
				size = 2.2,
				glow = 8,
				texture = "mcl_particles_effect.png^[colorize:#7CFF24:200",
			})

			for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.2)) do
				if obj:is_player() and mcl_siege.is_survival_player(obj) then
					mcl_util.deal_damage(obj, 4, {
						type = "magic",
						source = self._shooter,
						direct = self.object,
					})
					mcl_potions.give_effect_by_level("poison", obj, 1, 3.5)
					mcl_potions.give_effect_by_level("slowness", obj, 1, 2.5)
					core.sound_play("default_cool_lava", {
						pos = pos, gain = 0.6, pitch = 1.3, max_hear_distance = 16,
					}, true)
					self.object:remove()
					return
				end
			end

			local node = core.get_node(pos)
			local def = core.registered_nodes[node.name]
			if def and def.walkable then
				core.sound_play("default_cool_lava", {
					pos = pos, gain = 0.5, pitch = 1.5, max_hear_distance = 16,
				}, true)
				self.object:remove()
			end
		end,
	})

	local function spit_acid(self, pos, target_pos)
		local start_pos = vector.offset(pos, 0, 1.0, 0)
		local aim = vector.offset(target_pos, 0, 1.1, 0)
		local dir = vector.direction(start_pos, aim)
		local obj = core.add_entity(vector.add(start_pos, vector.multiply(dir, 1.1)), acid_entity)
		if obj then
			local ent = obj:get_luaentity()
			if ent then
				ent._shooter = self.object
			end
			obj:set_velocity(vector.multiply(dir, 18))
			obj:set_acceleration({ x = 0, y = -6.5, z = 0 })
			core.sound_play("mobs_mc_spider_attack", {
				pos = pos, gain = 0.85, pitch = 1.35, max_hear_distance = 22,
			}, true)
		end
	end

	local function on_spawn(self)
		if not self._siege_queen_id then
			local serial = storage:get_int("queen_serial") + 1
			storage:set_int("queen_serial", serial)
			self._siege_queen_id = tostring(serial)
		end
		-- Скрываем имя над головой, чтобы королева не выдавала себя заранее
		self.nametag = ""
		if self.object then
			self.object:set_nametag_attributes({ text = "" })
		end
		return true
	end

	local function try_found(self, pos)
		if mcl_worlds.pos_to_dimension(pos) ~= "overworld" then
			return
		end
		local origin = vector.round(vector.offset(pos, 0, 0.5, 0))
		if not hive.site_available(origin) then
			return
		end
		for _, offset in ipairs(CHECK_SITES) do
			local candidate = vector.offset(origin, offset[1], 0, offset[2])
			if hive.found(candidate, self.description, self._siege_queen_id) then
				self._siege_heart = candidate
				self:restrict_to(candidate, 26)
				core.sound_play("mobs_mc_spider_attack", {
					pos = candidate, gain = 1, max_hear_distance = 28,
				}, true)
				return
			end
		end
	end

	local function ai_step(self, dtime)
		mob.ai_step(self, dtime)
		if mcl_vars.difficulty == 0 or not self:check_timer("siege_hive", 4) then
			return
		end
		local pos = self.object:get_pos()
		local anchor = self._siege_heart
		if not anchor then
			try_found(self, pos)
		elseif vector.distance(anchor, pos) <= 10 and hive.is_alive(anchor, self._siege_queen_id) then
			self.health = math.min(self.initial_properties.hp_max, self.health + 2)
		end
	end

	-- Магический импульс накладывает 2 случайных эффекта из пула
	local function pulse(self, spell)
		local first = queen_curses[math.random(#queen_curses)]
		local second = queen_curses[math.random(#queen_curses)]
		for _, object in ipairs(core.get_objects_inside_radius(spell.pos, RADIUS)) do
			if object:is_player() and mcl_siege.is_survival_player(object)
				and self:line_of_sight(vector.offset(spell.pos, 0, 0.9, 0), mcl_util.target_eye_pos(object)) then
				if mcl_potions.registered_effects and mcl_potions.registered_effects[first[1]] then
					mcl_potions.give_effect_by_level(first[1], object, first[2], first[3])
				end
				if second ~= first and mcl_potions.registered_effects
					and mcl_potions.registered_effects[second[1]] then
					mcl_potions.give_effect_by_level(second[1], object, second[2], second[3])
				end
				mcl_util.deal_damage(object, 4, { type = "magic", source = self.object, direct = self.object })
			end
		end
	end

	local function attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
		local target = self.attack
		if not target or not target:is_player() or not mcl_siege.is_survival_player(target) then
			combat[self] = nil
			return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
		end
		local state = combat[self]
		if not state or state.target ~= target then
			state = { target = target, cooldown = 3.0, spit_cd = 1.5 }
			combat[self] = state
		end
		state.cooldown = state.cooldown - dtime
		state.spit_cd = state.spit_cd - dtime

		if state.spell then
			local spell = state.spell
			spell.remaining = spell.remaining - dtime
			self:look_at(target_pos)
			if spell.remaining <= 0 then
				pulse(self, spell)
				state.spell = nil
			end
			return
		end

		local distance = vector.distance(pos, target_pos)

		-- Плевок кислотой на средней дистанции (от 3.5 до 16 блоков)
		if state.spit_cd <= 0 and visible and distance >= 3.5 and distance <= 16 then
			state.spit_cd = math.random(3, 5)
			self:look_at(target_pos)
			spit_acid(self, pos, target_pos)
		end

		-- Руническое заклинание со случайными эффектами
		if state.cooldown <= 0 and visible and distance <= 13 then
			state.spell = { pos = target_pos, remaining = WARNING }
			state.cooldown = self.health <= self.initial_properties.hp_max / 2 and 7.5 or 10.5
			self:cancel_navigation()
			self:halt_in_tracks()
			self:look_at(target_pos)
			self:set_animation("stand")
			mcl_siege.rune(target_pos, RADIUS, self._siege_color, WARNING)
			return
		end

		return mob.attack_melee(self, attach_pos, pos, dtime, target_pos, visible)
	end

	local function attack_end(self)
		combat[self] = nil
		return mob.attack_end(self)
	end

	local function on_die(self)
		hive.seal(self._siege_heart, self._siege_queen_id)
	end

	local function target_survival_player(_, _, object)
		return mcl_siege.is_survival_player(object)
	end

	local function register_queen(name, description, color, health, speed, effect)
		mcl_mobs.register_mob(name, {
			description = description,
			type = "monster",
			_spawn_category = "monster",
			hp_min = health,
			hp_max = health,
			xp_min = 36,
			xp_max = 48,
			collisionbox = { -0.8, 0, -0.8, 0.8, 1.35, 0.8 },
			visual = "mesh",
			mesh = "mobs_mc_spider.b3d",
			textures = { { "mobs_mc_spider.png^[colorize:" .. color .. ":115" } },
			visual_size = { x = 1.65, y = 1.65 },
			makes_footstep_sound = true,
			head_eye_height = 0.95,
			can_despawn = false,
			movement_speed = speed,
			damage = 7,
			reach = 2.8,
			view_range = 24,
			tracking_distance = 27,
			attack_type = "melee",
			floats = 1,
			knock_back = false,
			armor = { fleshy = 85, arthropod = 100 },
			sounds = {
				random = "mobs_mc_spider_random",
				death = "mobs_mc_spider_death",
				damage = "mobs_mc_spider_hurt",
				distance = 24,
			},
			animation = {
				stand_start = 20, stand_end = 40, stand_speed = 9,
				walk_start = 0, walk_end = 20, walk_speed = 22,
			},
			drops = {
				{ name = "mcl_core:diamond", min = 2, max = 3, chance = 1 },
				{ name = "mcl_core:emerald", min = 3, max = 5, chance = 1 },
			},
			_siege_pulse_effect = effect,
			_siege_color = color,
			_targeting_rules = {
				mcl_mobs.build_nearest_target_rule("player", target_survival_player, nil, nil, 16),
			},
			ai_functions = { mob.check_attack, mob.return_to_restriction, mob.check_pace },
			on_spawn = on_spawn,
			on_die = on_die,
			ai_step = ai_step,
			attack_melee = attack_melee,
			attack_end = attack_end,
		})
		mcl_mobs.register_egg(name, description, color, "#211324", 0)
	end

	register_queen(names[1], S("Vespera, Queen of Dusk"), "#A751E1", 120, 4.1, "darkness")
	register_queen(names[2], S("Kharza, Queen of Embers"), "#E64D40", 145, 4.55, "weakness")

	local base = mobs_mc.monster_spawner
	local queen_spawner = table.merge(base, {
		name = names[1],
		weight = 22,
		pack_min = 1,
		pack_max = 1,
		biomes = {
			"Plains", "SunflowerPlains", "Savannah", "Meadow", "Desert",
			"SnowyPlains", "Forest", "BirchForest", "SparseJungle", "Taiga", "Swamp",
		},
	})

	function queen_spawner:test_spawn_position(spawn_pos, node_pos, data, cache, spawn_flag)
		return not spawn_flag and hive.natural_ready()
			and mcl_worlds.pos_to_dimension(node_pos) == "overworld"
			and base.test_spawn_position(self, spawn_pos, node_pos, data, cache, spawn_flag)
			and mcl_weather.is_outdoor(node_pos)
			and hive.site_available(node_pos) and hive.can_found(node_pos)
		end
	
	function queen_spawner:spawn(pos)
		local object = core.add_entity(pos, names[math.random(#names)])
		if object and object:is_valid() then
			hive.remember_natural_spawn()
		end
		return object
	end

	mcl_mobs.register_spawner(queen_spawner)
end
