-- doomspawn: воздушный спавн в случайном радиусе и короткая неуязвимость.
-- Работает одинаково во всех мирах: без кровати игрок появляется высоко
-- в воздухе в случайной точке и падает вниз, урон от падения отключён.
-- Настройки глобальные для мира и меняются командой /doomspawn.

local storage = core.get_mod_storage()
local RADIUS_KEY = "radius"
local INVULN_KEY = "invuln"
local FALL_KEY = "fall_protect"
local ENABLED_KEY = "enabled"

local function clamp_int(value, min, max, default)
	value = tonumber(value)
	if not value then
		return default
	end
	value = math.floor(value)
	if value < min or value > max then
		return default
	end
	return value
end

local radius = clamp_int(storage:get_string(RADIUS_KEY),
	0, 1000, clamp_int(core.settings:get("doomspawn_radius"), 0, 1000, 50))
local invuln = clamp_int(storage:get_string(INVULN_KEY),
	0, 60, clamp_int(core.settings:get("doomspawn_invuln"), 0, 60, 5))
local fall_protect = clamp_int(storage:get_string(FALL_KEY),
	0, 60, clamp_int(core.settings:get("doomspawn_fall_protection"),
		0, 60, 10))

local enabled
local stored_enabled = storage:get_string(ENABLED_KEY)
if stored_enabled == "" then
	enabled = core.settings:get_bool("doomspawn_enabled", true)
else
	enabled = stored_enabled ~= "false"
end

-- Mineclonia генерирует область спавна по mcl_spawn_radius. Радиус 1000
-- означал бы 2001x2001 блоков на всю высоту, поэтому генерацию ограничиваем.
-- Сам воздушный спавн при этом может быть до 1000.
local function update_spawn_area_radius()
	core.settings:set("mcl_spawn_radius", tostring(math.min(radius, 50)))
end

update_spawn_area_radius()

local shield_until = {}
local fall_shield_until = {}

-- Пока doomspawn включён, убираем штатные колбэки mcl_spawn (respawn)
-- и mcl_biome_dispatch (newplayer): они могут увести игрока в обычную
-- точку или в limbo, а нам нужен только воздушный телепорт. Когда
-- doomspawn выключают, колбэки возвращаются на место.
local mcl_spawn_cb
local biome_newplayer_cb

local function list_contains(list, func)
	for _, f in ipairs(list) do
		if f == func then
			return true
		end
	end
	return false
end

local function set_callback_active(list, func, active)
	if not list or not func then
		return
	end
	if active then
		if not list_contains(list, func) then
			table.insert(list, func)
		end
	else
		for i = #list, 1, -1 do
			if list[i] == func then
				table.remove(list, i)
			end
		end
	end
end

local function set_vanilla_spawn_active(active)
	set_callback_active(core.registered_on_respawnplayers, mcl_spawn_cb, active)
	set_callback_active(core.registered_on_newplayers, biome_newplayer_cb, active)
end

core.register_on_mods_loaded(function()
	if not core.callback_origins then
		return
	end
	for _, f in ipairs(core.registered_on_respawnplayers or {}) do
		local origin = core.callback_origins[f]
		if origin and origin.mod == "mcl_spawn" then
			mcl_spawn_cb = f
			break
		end
	end
	for _, f in ipairs(core.registered_on_newplayers or {}) do
		local origin = core.callback_origins[f]
		if origin and origin.mod == "mcl_biome_dispatch" then
			biome_newplayer_cb = f
			break
		end
	end
	set_vanilla_spawn_active(not enabled or radius <= 0)
end)

local function send(name, message)
	core.chat_send_player(name,
		core.colorize("#55FFFF", "[Doomspawn] ") .. message)
end

local function give_shield(player, announce)
	if invuln <= 0 then
		return
	end
	local name = player:get_player_name()
	shield_until[name] = core.get_gametime() + invuln
	if announce then
		send(name, "Неуязвимость " .. invuln .. " с.")
	end
end

local function get_spawn_center()
	if mcl_biome_dispatch and mcl_biome_dispatch.get_spawn_point_2d then
		local pos = mcl_biome_dispatch.get_spawn_point_2d()
		if pos then
			return pos
		end
	end
	return {x = 0, y = 0, z = 0}
end

-- Телепорт в воздух в случайную точку вокруг мирового спавна.
local function random_air_spawn(player)
	if not player:is_player() or player:get_hp() <= 0 or radius <= 0 then
		return
	end

	local center = get_spawn_center()
	local angle = math.random() * math.pi * 2
	-- sqrt() даёт равномерное распределение по всему кругу.
	local distance = math.sqrt(math.random()) * radius
	local pos = {
		x = math.floor(center.x + math.cos(angle) * distance + 0.5),
		z = math.floor(center.z + math.sin(angle) * distance + 0.5),
		y = ((mcl_vars and mcl_vars.mg_overworld_max_official) or 200) + 8,
	}

	-- Если в этой точке стоит чья-то башня, поднимаемся выше.
	core.load_area(pos, pos)
	local node = core.get_node(pos)
	for _ = 1, 64 do
		if node.name == "air" or node.name == "ignore" then
			break
		end
		pos.y = pos.y + 1
		core.load_area(pos, pos)
		node = core.get_node(pos)
	end

	player:set_pos(pos)

	if fall_protect > 0 then
		local name = player:get_player_name()
		fall_shield_until[name] = core.get_gametime() + fall_protect
		send(name, "Случайный спавн: " .. fall_protect
			.. " с без урона от падения.")
	end
end

local function schedule_air_spawn(player)
	core.after(0, function()
		if player:is_player() and player:get_hp() > 0 then
			random_air_spawn(player)
		end
	end)
end

core.register_on_respawnplayer(function(player)
	if not player:is_player() then
		return false
	end
	if not enabled then
		return false
	end

	-- Кровать/якорь — осознанный выбор игрока, оставляем точку фиксированной.
	local meta = player:get_meta()
	if meta:get_string("mcl_beds:spawn") ~= "" then
		local pos, custom = mcl_spawn.get_player_spawn_pos(player)
		if custom and pos then
			player:set_pos(pos)
			give_shield(player, true)
			return true
		end
	end

	give_shield(player, true)

	if radius <= 0 then
		-- Радиус 0: без разброса, обычный спавн + щит.
		return false
	end

	-- mcl_spawn-колбэк на время включённого doomspawn убран, поэтому
	-- можно телепортировать сразу, не оставляя игрока на шаг в точке смерти.
	random_air_spawn(player)
	return true
end)

-- Новый игрок тоже должен попасть в случайную точку, а не в стандартный спавн.
core.register_on_newplayer(function(player)
	if not enabled or radius <= 0 then
		return
	end
	schedule_air_spawn(player)
end)

core.register_on_joinplayer(function(player)
	if enabled then
		give_shield(player, true)
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	shield_until[name] = nil
	fall_shield_until[name] = nil
end)

mcl_damage.register_modifier(function(obj, damage, reason)
	if not obj:is_player() then
		return damage
	end
	local name = obj:get_player_name()
	local kind = reason and reason.type

	-- The void and /kill must still work.
	if kind == "out_of_world" or kind == "void" then
		return damage
	end

	-- Отдельная защита от падения после воздушного спавна.
	if kind == "fall" then
		local fall_until = fall_shield_until[name]
		if fall_until then
			if core.get_gametime() < fall_until then
				return 0
			end
			fall_shield_until[name] = nil
		end
	end

	local until_time = shield_until[name]
	if not until_time then
		return damage
	end
	if core.get_gametime() >= until_time then
		shield_until[name] = nil
		return damage
	end
	return 0
end)

local function split_args(param)
	local args = {}
	for word in (param or ""):gmatch("%S+") do
		args[#args + 1] = word
	end
	return args
end

local function parse_int(value, min, max)
	local n = tonumber(value)
	if not n then
		return nil
	end
	n = math.floor(n)
	if n < min or n > max then
		return nil
	end
	return n
end

local function set_enabled(name, value)
	enabled = value
	storage:set_string(ENABLED_KEY, value and "true" or "false")
	set_vanilla_spawn_active(not value or radius <= 0)
	if value then
		send(name, "Doomspawn включён.")
	else
		for key in pairs(shield_until) do
			shield_until[key] = nil
		end
		for key in pairs(fall_shield_until) do
			fall_shield_until[key] = nil
		end
		send(name, "Doomspawn выключен: обычный спавн, без щита и воздушного телепорта.")
	end
end

core.register_chatcommand("doomspawn", {
	description = "Настройки воздушного спавна, неуязвимости и защиты от падения",
	params = "status | on | off | radius <0-1000> | invuln <0-60> | fall <0-60>",
	privs = {server = true},
	func = function(name, param)
		local args = split_args(param)
		local sub = args[1] and args[1]:lower()

		if not sub or sub == "status" then
			send(name, "Режим: " .. (enabled and "включён" or "выключен")
				.. ". Радиус: " .. radius .. ". Неуязвимость: "
				.. invuln .. " с. Защита от падения: " .. fall_protect .. " с.")
			send(name, "Область генерации спавна Mineclonia: "
				.. math.min(radius, 50) .. " (воздушный спавн — до "
				.. radius .. ").")
			return true
		elseif sub == "on" or sub == "enable" then
			set_enabled(name, true)
			return true
		elseif sub == "off" or sub == "disable" then
			set_enabled(name, false)
			return true
		elseif sub == "radius" then
			local n = parse_int(args[2], 0, 1000)
			if not n then
				return false, "Радиус: целое число 0-1000 (0 — без разброса)."
			end
			radius = n
			storage:set_string(RADIUS_KEY, tostring(radius))
			update_spawn_area_radius()
			set_vanilla_spawn_active(not enabled or radius <= 0)
			send(name, "Радиус воздушного спавна: " .. radius
				.. ". Область генерации Mineclonia: "
				.. math.min(radius, 50) .. ".")
			return true
		elseif sub == "invuln" then
			local n = parse_int(args[2], 0, 60)
			if not n then
				return false, "Неуязвимость: целое число 0-60 секунд (0 — выключено)."
			end
			invuln = n
			storage:set_string(INVULN_KEY, tostring(invuln))
			if invuln <= 0 then
				for key in pairs(shield_until) do
					shield_until[key] = nil
				end
			end
			send(name, "Неуязвимость после спавна: " .. invuln .. " с.")
			return true
		elseif sub == "fall" then
			local n = parse_int(args[2], 0, 60)
			if not n then
				return false, "Защита от падения: целое число 0-60 секунд (0 — выключено)."
			end
			fall_protect = n
			storage:set_string(FALL_KEY, tostring(fall_protect))
			if fall_protect <= 0 then
				for key in pairs(fall_shield_until) do
					fall_shield_until[key] = nil
				end
			end
			send(name, "Защита от урона падением после воздушного спавна: "
				.. fall_protect .. " с.")
			return true
		end

		return false, "Использование: /doomspawn status | on | off | radius <0-1000> | invuln <0-60> | fall <0-60>"
	end,
})
