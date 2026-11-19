local siege = {}
mcl_siege = siege

function siege.configure_spawns(name, configure)
	if not (mcl_mobs and mcl_mobs.registered_spawners) then
		return
	end
	for _, spawner in ipairs(mcl_mobs.registered_spawners) do
		if spawner.name == name then
			configure(spawner)
		end
	end
end

function siege.standable(pos, height)
	local floor_pos = vector.offset(pos, 0, -1, 0)
	local floor = core.get_node(floor_pos)
	local def = core.registered_nodes[floor.name]
	if not def or not def.walkable or def.damage_per_second > 0
		or core.get_item_group(floor.name, "opaque") == 0 then
		return false
	end
	for y = 0, height - 1 do
		local name = core.get_node(vector.offset(pos, 0, y, 0)).name
		local space = core.registered_nodes[name]
		if not space or name == "ignore" or space.walkable
			or space.liquidtype ~= "none" or space.damage_per_second > 0 then
			return false
		end
	end
	return true
end

function siege.is_survival_player(player)
	local name = player:get_player_name()
	return player:get_hp() > 0 and not core.is_creative_enabled(name)
		and not core.check_player_privs(name, { spectator = true })
end

function siege.rune(pos, radius, color, duration)
	local texture = "mcl_particles_effect.png^[multiply:" .. color
	for i = 0, 11 do
		local angle = i * math.pi / 6
		core.add_particle({
			pos = vector.offset(pos, radius * math.cos(angle), 0.2, radius * math.sin(angle)),
			velocity = vector.new(0, 0.18, 0),
			expirationtime = duration,
			size = 3,
			glow = 10,
			texture = texture,
		})
	end
	core.sound_play("mobs_mc_enderman_teleport_src", {
		pos = pos, gain = 0.5, max_hear_distance = 16,
	}, true)
end

-- Крупные отряды и высокий вес спавна для всех врагов
local horde_roster = {
	["mobs_mc:zombie"]     = { weight = 500, min = 3, max = 10 },
	["mobs_mc:husk"]       = { weight = 400, min = 3, max = 10 },
	["mobs_mc:skeleton"]   = { weight = 130, min = 4, max = 9 },
	["mobs_mc:stray"]      = { weight = 120, min = 4, max = 9 },
	["mobs_mc:bogged"]     = { weight = 120, min = 4, max = 9 },
	["mobs_mc:spider"]     = { weight = 130, min = 4, max = 8 },
	["mobs_mc:pillager"]   = { weight = 80,  min = 4, max = 8 },
	["mobs_mc:enderman"]   = { weight = 55,  min = 2, max = 4 },
	["mobs_mc:vindicator"] = { weight = 55,  min = 3, max = 6 },
	["mobs_mc:evoker"]     = { weight = 30,  min = 1, max = 3 },
	["mobs_mc:phantom"]    = { weight = 70,  min = 3, max = 6 },
}

-- Применяем сразу при загрузке файла (до индексации весов в mcl_mobs)
for mob_name, cfg in pairs(horde_roster) do
	siege.configure_spawns(mob_name, function(spawner)
		spawner.weight = cfg.weight
		spawner.pack_min = cfg.min
		spawner.pack_max = cfg.max
	end)
end

-- Корректируем актуальные лимиты категории monster в Mineclonia
core.register_on_mods_loaded(function()
	if mcl_mobs and mcl_mobs.spawn_categories
			and mcl_mobs.spawn_categories.monster then
		local monster = mcl_mobs.spawn_categories.monster
		monster.chunk_mob_cap = math.max(monster.chunk_mob_cap or 70, 140)
		monster.min_chunk_mob_cap = math.max(monster.min_chunk_mob_cap or 10, 25)
	end
end)
