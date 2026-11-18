local siege = {}
mcl_siege = siege

-- Mineclonia indexes these definitions and calculates total weights at mods_loaded.
function siege.configure_spawns(name, configure)
	for _, spawner in ipairs(mcl_mobs.registered_spawners) do
		if spawner.name == name and #spawner.biomes > 0 then
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

-- Балансировка всех ночных врагов: ровные шансы и спавн группами
local horde_roster = {
	-- Основные отряды (равные веса, чтобы не было перекоса в зомби)
	["mobs_mc:skeleton"]       = { weight = 100, min = 4, max = 8 },
	["mobs_mc:stray"]          = { weight = 90,  min = 4, max = 8 },
	["mobs_mc:bogged"]         = { weight = 90,  min = 4, max = 8 },
	["mobs_mc:spider"]         = { weight = 95,  min = 4, max = 7 },
	["mobs_mc:creeper"]        = { weight = 85,  min = 3, max = 6 },
	["mobs_mc:pillager"]       = { weight = 65,  min = 4, max = 7 },

	-- Элитные враги и «королевы» (ведьмы, эндермены, поборники) — теперь очень часто и группами
	["mobs_mc:witch"]          = { weight = 65,  min = 2, max = 4 },
	["mobs_mc:enderman"]       = { weight = 60,  min = 2, max = 5 },
	["mobs_mc:vindicator"]     = { weight = 50,  min = 2, max = 4 },
	["mobs_mc:evoker"]         = { weight = 35,  min = 1, max = 3 },
	["mobs_mc:phantom"]        = { weight = 60,  min = 3, max = 6 },
}

core.register_on_mods_loaded(function()
	for mob_name, cfg in pairs(horde_roster) do
		siege.configure_spawns(mob_name, function(spawner)
			spawner.weight = cfg.weight
			spawner.pack_min = cfg.min
			spawner.pack_max = cfg.max
		end)
	end

	-- Увеличиваем общий лимит и частоту спавна мобов в Mineclonia, если доступно API
	if mcl_mobs.spawn_setup then
		-- Снижаем кулдаун спавна, чтобы группы появлялись заметно чаще
		if type(mcl_mobs.spawning_interval) == "number" then
			mcl_mobs.spawning_interval = math.min(mcl_mobs.spawning_interval, 5)
		end
	end
end)

