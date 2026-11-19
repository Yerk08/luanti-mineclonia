return function(hive)
	local modname = core.get_current_modname()
	local S = core.get_translator(modname)
	local storage = core.get_mod_storage()
	local mob = mcl_mobs.mob_class
	local combat = setmetatable({}, { __mode = "k" })

	local WARNING, RADIUS = 1.5, 4.0
	local names = { modname .. ":vespera", modname .. ":kharza" }

	local queen_curses = {
		{ "darkness", 1, 4 },
		{ "weakness", 1, 5 },
		{ "fatigue", 2, 5 },
		{ "levitation", 1, 2 },
		{ "nausea", 1, 5 },
		{ "poison", 1, 4 },
		{ "mining_fatigue", 2, 6 },
	}
	local function apply_short_effect(player, name, level, duration)
		if not mcl_potions or not mcl_potions.registered_effects or not mcl_potions.registered_effects[name] then
			return
		end
		local dur = math.ceil(duration)
		pcall(mcl_potions.give_effect_by_level, name, player, math.floor(level), dur)
		core.after(dur, function()
			if player and player:is_valid() and mcl_potions.clear_effect then
				mcl_potions.clear_effect(player, name)
			end
		end)
	end

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
					apply_short_effect(obj, "poison", 1, 3.0)
					apply_short_effect(obj, "slowness", 1, 2.5)

					core.sound_play("default_cool_lava", {
						pos = pos,
						gain = 0.6,
						pitch = 1.3,
						max_hear_distance = 16,
					}, true)
					self.object:remove()
					return
				end
			end

			local node = core.get_node(pos)
			local def = core.registered_nodes[node.name]
			if def and def.walkable then
				core.sound_play("default_cool_lava", {
					pos = pos,
					gain = 0.5,
					pitch = 1.5,
					max_hear_distance = 16,
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
				pos = pos,
				gain = 0.85,
				pitch = 1.35,
				max_hear_distance = 22,
			}, true)
		end
	end

	-- Рывок-отступление для Весперы (уход от игрока + боковой стрейф)
	local function dash_away(self, pos, target_pos)
		local away = vector.direction(target_pos, pos)
		away.y = 0
		if vector.length(away) < 0.01 then
			away = vector.new(1, 0, 0)
		else
			away = vector.normalize(away)
		end
		local side = vector.new(-away.z, 0, away.x)
		local strafe_sign = (math.random(2) == 1) and 1 or -1
		local dir = vector.normalize(vector.add(vector.multiply(away, 1.2), vector.multiply(side, 0.85 * strafe_sign)))

		self.object:set_velocity({
			x = dir.x * 13.5,
			y = 4.2,
			z = dir.z * 13.5,
		})
		core.sound_play("mobs_mc_enderman_teleport_src", {
			pos = pos,
			gain = 0.65,
			pitch = 1.35,
			max_hear_distance = 22,
		}, true)
		core.add_particlespawner({
			amount = 24,
			time = 0.15,
			minpos = vector.subtract(pos, 0.5),
			maxpos = vector.add(pos, 0.8),
			minvel = { x = -2.5, y = 0.5, z = -2.5 },
			maxvel = { x = 2.5, y = 2.5, z = 2.5 },
			minexptime = 0.3,
			maxexptime = 0.6,
			glow = 12,
			texture = "mcl_particles_effect.png^[colorize:#A751E1:220",
		})
	end

	-- Прыжок на игрока для Харзы с ударной волной при приземлении
	local function leap_at_target(self, pos, target_pos)
		local dir = vector.direction(pos, target_pos)
		dir.y = 0
		if vector.length(dir) < 0.01 then
			return
		end
		dir = vector.normalize(dir)
		local dist = math.min(vector.distance(pos, target_pos), 12)
		local h_speed = math.max(9.5, dist * 1.15)

		self.object:set_velocity({
			x = dir.x * h_speed,
			y = 7.2,
			z = dir.z * h_speed,
		})
		self._kharza_leaping = true
		self._kharza_leap_time = 0
		core.sound_play("mobs_mc_spider_attack", {
			pos = pos,
			gain = 1.0,
			pitch = 0.75,
			max_hear_distance = 24,
		}, true)
	end

	local function handle_kharza_landing(self, pos, dtime)
		if not self._kharza_leaping then
			return
		end
		self._kharza_leap_time = (self._kharza_leap_time or 0) + dtime
		local vel = self.object:get_velocity()
		if self._kharza_leap_time > 0.25 and vel and math.abs(vel.y) < 0.2 then
			self._kharza_leaping = false
			-- Ударная волна в радиусе 3.2 блока при приземлении
			core.add_particlespawner({
				amount = 36,
				time = 0.15,
				minpos = vector.offset(pos, -2.5, 0.1, -2.5),
				maxpos = vector.offset(pos, 2.5, 0.6, 2.5),
				minvel = { x = -3.5, y = 1.2, z = -3.5 },
				maxvel = { x = 3.5, y = 3.0, z = 3.5 },
				minexptime = 0.35,
				maxexptime = 0.7,
				glow = 14,
				texture = "mcl_particles_effect.png^[colorize:#E64D40:230",
			})
			core.sound_play("tnt_explode", {
				pos = pos,
				gain = 0.45,
				pitch = 1.35,
				max_hear_distance = 20,
			}, true)
			for _, obj in ipairs(core.get_objects_inside_radius(pos, 3.2)) do
				if obj:is_player() and mcl_siege.is_survival_player(obj) then
					mcl_util.deal_damage(obj, 5, {
						type = "mob",
						source = self.object,
						direct = self.object,
					})
					local push = vector.direction(pos, obj:get_pos())
					push.y = 0.35
					obj:add_velocity(vector.multiply(vector.normalize(push), 7.5))
				end
			end
		elseif self._kharza_leap_time > 2.2 then
			self._kharza_leaping = false
		end
	end

	-- Вызволение королевы, если растущий кокон накрыл её блоками
	local function unstuck_from_blocks(self, pos)
		local check_pos = vector.round(vector.offset(pos, 0, 0.5, 0))
		local node = core.get_node(check_pos)
		local def = core.registered_nodes[node.name]
		if not def or not def.walkable then
			return
		end
		-- Ищем ближайшую свободную клетку по горизонтали или вверх
		for dy = 0, 4 do
			for dx = -2, 2 do
				for dz = -2, 2 do
					local candidate = vector.offset(check_pos, dx, dy, dz)
					if mcl_siege.standable(candidate, 2) then
						self.object:set_pos(vector.offset(candidate, 0, -0.4, 0))
						return
					end
				end
			end
		end
		-- Запасной вариант: возвращаем прямо к сердцу улья
		if self._siege_heart then
			self.object:set_pos(vector.offset(self._siege_heart, 0, 0.6, 0))
		end
	end

	local function try_found(self, pos)
		if mcl_worlds.pos_to_dimension(pos) ~= "overworld" then
			return
		end
		local candidate = vector.round(vector.offset(pos, 0, 0.2, 0))
		if hive.found(candidate, self.description, self._siege_queen_id) then
			self._siege_heart = candidate
			self:restrict_to(candidate, 26)
			core.sound_play("mobs_mc_spider_attack", {
				pos = candidate,
				gain = 1,
				max_hear_distance = 28,
			}, true)
		end
	end

	local function on_spawn(self)
		if not self._siege_queen_id then
			local serial = storage:get_int("queen_serial") + 1
			storage:set_int("queen_serial", serial)
			self._siege_queen_id = tostring(serial)
		end
		self.nametag = ""
		if self.object then
			self.object:set_nametag_attributes({ text = "" })
			local pos = self.object:get_pos()
			if pos and mcl_vars.difficulty ~= 0 and not self._siege_heart then
				try_found(self, pos)
			end
		end
		return true
	end

	local function ai_step(self, dtime)
		mob.ai_step(self, dtime)
		local pos = self.object:get_pos()
		if not pos then
			return
		end
		if self._siege_mobility == "jump" then
			handle_kharza_landing(self, pos, dtime)
		end
		if self:check_timer("siege_unstuck", 1.0) then
			unstuck_from_blocks(self, pos)
		end
		if mcl_vars.difficulty == 0 then
			return
		end

		-- Отсчёт перезарядки перед постройкой нового улья
		if self._rebuild_cd and self._rebuild_cd > 0 then
			self._rebuild_cd = self._rebuild_cd - dtime
			return
		end

		local anchor = self._siege_heart
		if not anchor then
			if self:check_timer("siege_found", 1.0) then
				try_found(self, pos)
			end
			return
		end
		if not self:check_timer("siege_hive", 4) then
			return
		end
		local actual = hive.locate_heart(anchor, self._siege_queen_id)
		if actual then
			self._siege_heart = actual
			if vector.distance(actual, pos) <= 12 then
				self.health = math.min(self.initial_properties.hp_max, self.health + 2)
			end
		else
			-- Улей разрушен: сбрасываем привязку и даём паузу 30 секунд перед постройкой следующего
			self._siege_heart = nil
			self._rebuild_cd = 30
			local serial = storage:get_int("queen_serial") + 1
			storage:set_int("queen_serial", serial)
			self._siege_queen_id = tostring(serial)
		end
	end

	local function pulse(self, spell)
		local first = queen_curses[math.random(#queen_curses)]
		local second = queen_curses[math.random(#queen_curses)]
		local f_name, f_lvl, f_dur = unpack(first)
		local s_name, s_lvl, s_dur = unpack(second)
		for _, object in ipairs(core.get_objects_inside_radius(spell.pos, RADIUS)) do
			if
				object:is_player()
				and mcl_siege.is_survival_player(object)
				and self:line_of_sight(vector.offset(spell.pos, 0, 0.9, 0), mcl_util.target_eye_pos(object))
			then
				apply_short_effect(object, f_name, f_lvl, f_dur)
				if s_name ~= f_name then
					apply_short_effect(object, s_name, s_lvl, s_dur)
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
			state = { target = target, cooldown = 3.0, spit_cd = 1.5, move_cd = 2.0 }
			combat[self] = state
		end
		state.cooldown = state.cooldown - dtime
		state.spit_cd = state.spit_cd - dtime
		state.move_cd = state.move_cd - dtime
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
		local low_hp = self.health <= self.initial_properties.hp_max * 0.5
		-- Веспера: убегает/делает рывок в сторону при сближении или при низком здоровье
		if self._siege_mobility == "run" and state.move_cd <= 0 and visible then
			if distance < (low_hp and 7.5 or 5.0) then
				state.move_cd = low_hp and 2.4 or 3.6
				state.spit_cd = math.min(state.spit_cd, 0.5)
				self:look_at(target_pos)
				dash_away(self, pos, target_pos)
				return
			end
		end
		-- Харза: прыгает на игрока со средней дистанции
		if self._siege_mobility == "jump" and state.move_cd <= 0 and visible then
			if distance >= 4.2 and distance <= 14.0 then
				state.move_cd = low_hp and 3.0 or 4.5
				self:look_at(target_pos)
				leap_at_target(self, pos, target_pos)
				return
			end
		end
		if state.spit_cd <= 0 and visible and distance >= 3.5 and distance <= 16 then
			state.spit_cd = math.random(3, 5)
			self:look_at(target_pos)
			spit_acid(self, pos, target_pos)
		end
		if state.cooldown <= 0 and visible and distance <= 13 then
			state.spell = { pos = target_pos, remaining = WARNING }
			state.cooldown = low_hp and 7.5 or 10.5
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
	local function register_queen(name, description, color, health, speed, effect, mobility)
		mcl_mobs.register_mob(name, {
			description = description,
			type = "monster",
			_spawn_category = "monster",
			hp_min = health,
			hp_max = health,
			xp_min = 36,
			xp_max = 48,
			-- Компактный хитбокс, чтобы королева не застревала в коридорах улья
			collisionbox = { -0.55, 0, -0.55, 0.55, 1.25, 0.55 },
			visual = "mesh",
			mesh = "mobs_mc_spider.b3d",
			textures = { { "mobs_mc_spider.png^[colorize:" .. color .. ":115" } },
			visual_size = { x = 1.65, y = 1.65 },
			makes_footstep_sound = true,
			head_eye_height = 0.95,
			can_despawn = false,
			suffocation = false, -- Отключаем урон и звуки боли от застревания в стенах
			spider_climb = true, -- Умеет карабкаться по стенам улья
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
				stand_start = 20,
				stand_end = 40,
				stand_speed = 9,
				walk_start = 0,
				walk_end = 20,
				walk_speed = 22,
			},
			drops = {
				{ name = "mcl_core:diamond", min = 2, max = 3, chance = 1 },
				{ name = "mcl_core:emerald", min = 3, max = 5, chance = 1 },
			},
			_siege_pulse_effect = effect,
			_siege_color = color,
			_siege_mobility = mobility,
			_targeting_rules = {
				mcl_mobs.build_nearest_target_rule("player", target_survival_player, nil, nil, 16),
			},
			ai_functions = { mob.check_attack, mob.return_to_restriction, mob.check_pace },
			on_spawn = on_spawn,
			on_die = on_die,
			ai_step = ai_step,
			attack_melee = attack_melee,
			attack_end = attack_end,
			receive_damage = function(self, reason, damage)
				-- Полностью игнорируем урон от удушья в блоках (suffocation)
				if reason and reason.type == "suffocation" then
					return 0
				end
				-- Веспера дополнительно уходит рывком при получении урона в ближнем бою
				if self._siege_mobility == "run" and damage > 0 and combat[self] and combat[self].move_cd <= 1.0 then
					local pos = self.object:get_pos()
					local target = combat[self].target
					if pos and target and target:is_valid() then
						combat[self].move_cd = 2.5
						dash_away(self, pos, target:get_pos())
					end
				end
				return mob.receive_damage(self, reason, damage)
			end,
		})
		mcl_mobs.register_egg(name, description, color, "#211324", 0)
	end
	register_queen(names[1], S("Vespera, Queen of Dusk"), "#A751E1", 60, 4.35, "darkness", "run")
	register_queen(names[2], S("Kharza, Queen of Embers"), "#E64D40", 70, 4.55, "weakness", "jump")
	local base = mobs_mc.monster_spawner
	local queen_spawner = table.merge(base, {
		name = names[1],
		weight = 22,
		pack_min = 1,
		pack_max = 1,
		biomes = {
			"Plains",
			"SunflowerPlains",
			"Savannah",
			"Meadow",
			"Desert",
			"SnowyPlains",
			"Forest",
			"BirchForest",
			"SparseJungle",
			"Taiga",
			"Swamp",
		},
	})
	function queen_spawner:test_spawn_position(spawn_pos, node_pos, data, cache, spawn_flag)
		return not spawn_flag
			and hive.natural_ready()
			and mcl_worlds.pos_to_dimension(node_pos) == "overworld"
			and base.test_spawn_position(self, spawn_pos, node_pos, data, cache, spawn_flag)
			and mcl_weather.is_outdoor(node_pos)
			and hive.site_available(node_pos)
			and hive.can_found(node_pos)
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
