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
