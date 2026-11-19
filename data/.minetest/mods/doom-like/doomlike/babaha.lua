-- Бабаха: единственное оружие арены.
-- Прямой снаряд, 40 прямого урона, взрыв силой 4, бесконечные патроны.
-- Перезарядка 3 секунды идёт только пока оружие в руке; переключился —
-- прогресс сбрасывается в ноль.

local ITEM = "doomlike:babaha"
local RELOAD_TIME = tonumber(core.settings:get("doomlike_babaha_reload")) or 3.0
local DAMAGE = math.floor(tonumber(core.settings:get("doomlike_babaha_damage")) or 40)
local SPEED = tonumber(core.settings:get("doomlike_babaha_speed")) or 40
local EXPLOSION_STRENGTH = 4
local HUD_INTERVAL = 1 / 6
local SECTORS = 32
local HUD_READY = "babaha_crosshair.png"
local HUD_RELOAD = "babaha_reload_%02d.png"

if RELOAD_TIME < 0.5 then
	RELOAD_TIME = 3.0
end
if DAMAGE < 1 then
	DAMAGE = 40
end
if SPEED < 10 then
	SPEED = 40
end

-- Состояние перезарядки: needs_reload = оружие разряжено,
-- elapsed = сколько секунд уже идёт перезарядка.
local reload_state = {}
-- HUD каждого игрока: id, последняя текстура, сохранённый флаг прицела.
local hud_state = {}
local hud_accum = 0

local function get_state(player)
	local name = player:get_player_name()
	local state = reload_state[name]
	if not state then
		state = {needs_reload = false, elapsed = 0}
		reload_state[name] = state
	end
	return state
end

local function reset_state(player)
	reload_state[player:get_player_name()] = {
		needs_reload = false,
		elapsed = 0,
	}
end

local function hide_hud(player)
	local name = player:get_player_name()
	local hud = hud_state[name]
	if not hud then
		return
	end
	if hud.id then
		player:hud_remove(hud.id)
	end
	if hud.crosshair_saved ~= nil then
		player:hud_set_flags({crosshair = hud.crosshair_saved})
	end
	hud_state[name] = nil
end

local function ensure_hud(player)
	local name = player:get_player_name()
	local hud = hud_state[name]
	if hud then
		return hud
	end

	local flags = player.hud_get_flags and player:hud_get_flags() or {}
	local id = player:hud_add({
		type = "image",
		position = {x = 0.5, y = 0.5},
		alignment = {x = 0, y = 0},
		offset = {x = 0, y = 0},
		scale = {x = 0.75, y = 0.75},
		text = HUD_READY,
		z_index = 100,
	})
	if not id then
		return nil
	end
	hud = {
		id = id,
		texture = HUD_READY,
		crosshair_saved = flags.crosshair ~= false,
	}
	hud_state[name] = hud
	player:hud_set_flags({crosshair = false})
	return hud
end

local function update_hud(player)
	if not player:is_player() or player:get_hp() <= 0 then
		hide_hud(player)
		return
	end
	if player:get_wielded_item():get_name() ~= ITEM then
		hide_hud(player)
		return
	end

	local hud = ensure_hud(player)
	if not hud then
		return
	end

	local state = get_state(player)
	local texture
	if state.needs_reload then
		local progress = math.max(0, math.min(1, state.elapsed / RELOAD_TIME))
		local index = math.floor(progress * SECTORS + 0.5)
		if index < 0 then
			index = 0
		elseif index > SECTORS then
			index = SECTORS
		end
		texture = string.format(HUD_RELOAD, index)
	else
		texture = HUD_READY
	end

	if texture ~= hud.texture then
		player:hud_change(hud.id, "text", texture)
		hud.texture = texture
	end
end

local function explode_at(pos, source)
	if mcl_explosions and mcl_explosions.explode then
		-- direct не передаём: свой урон от взрыва остаётся.
		-- source — игрок, чтобы deadcount мог засчитать кил.
		mcl_explosions.explode(pos, EXPLOSION_STRENGTH, {drop_chance = 0},
			nil, source)
	end
end

local function add_muzzle_smoke(pos, dir)
	core.add_particle({
		pos = pos,
		velocity = {
			x = dir.x * 3 + (math.random(-10, 10) / 10),
			y = dir.y * 3 + (math.random(-10, 10) / 10),
			z = dir.z * 3 + (math.random(-10, 10) / 10),
		},
		acceleration = {x = dir.x * -3, y = 2, z = dir.z * -3},
		expirationtime = math.random(5, 10) / 10,
		size = 7.5,
		collisiondetection = false,
		vertical = false,
		texture = "rifles_smoke.png",
		glow = 5,
	})
end

local ROCKET_PARTICLES = {
	velocity = {x = 1, y = 1, z = 1},
	acceleration = {x = 1, y = 1, z = 1},
	collisiondetection = true,
	lifetime = 1,
	texture = "rifles_smoke.png",
	minsize = 50,
	maxsize = 75,
	pos_randomness = 50,
	glow = 20,
	gravity = 10,
	amount = {1, 1},
}

local function shoot(itemstack, player)
	local state = get_state(player)
	if state.needs_reload then
		core.sound_play("rifles_empty", {to_player = player:get_player_name()}, true)
		return itemstack
	end

	state.needs_reload = true
	state.elapsed = 0

	local pos = player:get_pos()
	pos.y = pos.y + player:get_properties().eye_height
	local dir = player:get_look_dir()

	core.sound_play("rifles_rocket", {pos = pos, max_hear_distance = 500}, true)
	add_muzzle_smoke(pos, dir)

	local obj = core.add_entity(pos, "rifles:shot_bullet")
	if not obj then
		return itemstack
	end
	local ent = obj:get_luaentity()
	if not ent then
		obj:remove()
		return itemstack
	end

	obj:set_properties({
		textures = {"rifles_rocket_fly.png"},
		visual = "sprite",
		collisionbox = {-0.15, -0.15, -0.15, 0.15, 0.15, 0.15},
		glow = 20,
	})
	ent.owner = player:get_player_name()
	-- Для прямого попадания mcl_damage берёт source из этого поля.
	ent._source_object = player
	ent.damage = {fleshy = DAMAGE, knockback = 25}
	ent.OnCollision = function(owner, bullet, target)
		-- Взрываемся в точке попадания, а не в текущей позиции снаряда:
		-- иначе при попадании в землю/стену взрыв оказывается внутри блока,
		-- и урон по стоящей рядом овце почти полностью гасится укрытием.
		local pos
		if target and target.type == "node" and target.intersection_point then
			pos = vector.copy(target.intersection_point)
			if target.intersection_normal then
				pos = vector.add(pos,
					vector.multiply(target.intersection_normal, 0.2))
			end
		elseif target and target.type == "object" and target.ref then
			pos = vector.add(target.ref:get_pos(), {x = 0, y = 0.5, z = 0})
		elseif bullet and bullet.object then
			pos = bullet.object:get_pos()
		end
		if pos then
			local shooter = core.get_player_by_name(owner)
			explode_at(pos, shooter)
		end
	end
	ent.mobPen = 0
	ent.nodePen = 0
	ent.dps = 0
	ent.bullet_particles = ROCKET_PARTICLES
	ent.size = 0.15
	ent.timer = SPEED / 2000
	ent.wear = 0

	obj:set_velocity(vector.multiply(dir, SPEED))
	-- Прямой полёт: никакой гравитации и разброса.
	obj:set_acceleration({x = 0, y = 0, z = 0})
	obj:set_rotation({
		x = 0,
		y = (math.atan2(dir.z, dir.x) - math.pi) % (math.pi * 2),
		z = math.asin(dir.y),
	})

	update_hud(player)
	return itemstack
end

core.register_tool(ITEM, {
	description = "Бабаха",
	inventory_image = "rifles_m79.png",
	wield_image = "rifles_m79.png",
	wield_scale = {x = 2.0, y = 2.0, z = 2.5},
	stack_max = 1,
	range = 0,
	groups = {crossbow = 5},
	_wield_rotation = vector.new(-80, 45, -80),
	_wield_offset = vector.new(0, 0, 1),
	_wield_scale = vector.multiply({x = 2.0, y = 2.0, z = 2.5}, 0.8),
	on_use = shoot,
	on_secondary_use = function(itemstack)
		return itemstack
	end,
})

core.register_on_joinplayer(function(player)
	reset_state(player)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	reload_state[name] = nil
	hud_state[name] = nil
end)

core.register_on_dieplayer(function(player)
	hide_hud(player)
	reset_state(player)
end)

core.register_on_respawnplayer(function(player)
	hide_hud(player)
	reset_state(player)
end)

core.register_globalstep(function(dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local state = reload_state[name]
		if state and state.needs_reload then
			if player:get_hp() > 0
					and player:get_wielded_item():get_name() == ITEM then
				state.elapsed = state.elapsed + dtime
				if state.elapsed >= RELOAD_TIME then
					state.elapsed = 0
					state.needs_reload = false
				end
			else
				-- Переключился на другой предмет: прогресс сбрасывается,
				-- но оружие остаётся разряженным и потребует полные 3 с.
				state.elapsed = 0
			end
		end
	end

	hud_accum = hud_accum + dtime
	if hud_accum < HUD_INTERVAL then
		return
	end
	hud_accum = 0

	for _, player in ipairs(core.get_connected_players()) do
		update_hud(player)
	end
end)
