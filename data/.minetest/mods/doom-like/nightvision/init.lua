-- nightvision: включаемое ночное зрение по команде.
-- Эффект обновляется раз в секунду, поэтому при выключении он гаснет
-- за пару секунд. Длительное зелье Night Vision не обрезается.

local storage = core.get_mod_storage()
local ALLOWED_KEY = "allowed"
local ENABLED_META = "nightvision_enabled"
local REFRESH_INTERVAL = 1
local EFFECT_TIME = 2

-- Пустая строка или "true" = разрешено. "false" = запрещено всем.
local allowed = storage:get_string(ALLOWED_KEY) ~= "false"
local enabled = {}

-- Кривая освещения: поднимает яркость тёмных уровней (0..15).
-- Это именно то, чего не хватало: mcl_potions меняет только день/ночь
-- и небо, а в пещерах и глубоких шахтах было почти чёрно.
local LIGHT_CURVE = {
	50, 65, 80, 95, 110, 125, 140, 155,
	170, 185, 200, 215, 230, 242, 252, 255,
}
local light_curve_on = {}

local function save_allowed()
	storage:set_string(ALLOWED_KEY, allowed and "true" or "false")
end

local function set_player_enabled(player, value)
	local name = player:get_player_name()
	enabled[name] = value
	player:get_meta():set_int(ENABLED_META, value and 1 or 0)
end

-- Отдельная клиентская кривая света. Меняется только при включении/
-- выключении, потому что статическое освещение дорого пересчитывать.
local function set_light_curve(player, on, force)
	if not (player and player.set_lighting) then
		return
	end
	local name = player:get_player_name()
	if on then
		if light_curve_on[name] and not force then
			return
		end
		local ok = pcall(player.set_lighting, player, {
			static = {light_curve = LIGHT_CURVE},
		})
		if ok then
			light_curve_on[name] = true
		end
	else
		if not light_curve_on[name] then
			return
		end
		pcall(player.set_lighting, player, {
			static = {light_curve = {}},
		})
		light_curve_on[name] = nil
	end
end

local function refresh_effect(player)
	if not (mcl_potions and mcl_potions.give_effect) then
		return
	end
	mcl_potions.give_effect("night_vision", player, 0, EFFECT_TIME, true)
end

local function is_on(name)
	return allowed and enabled[name] == true
end

local function send(name, message)
	core.chat_send_player(name,
		core.colorize("#55FFFF", "[Night Vision] ") .. message)
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	enabled[name] = player:get_meta():get_int(ENABLED_META) == 1
	if is_on(name) then
		core.after(0, function()
			if player:is_player() and is_on(name) and player:get_hp() > 0 then
				refresh_effect(player)
				set_light_curve(player, true)
			end
		end)
	end
end)

core.register_on_respawnplayer(function(player)
	local name = player:get_player_name()
	if is_on(name) then
		core.after(0, function()
			if player:is_player() and is_on(name) and player:get_hp() > 0 then
				refresh_effect(player)
				set_light_curve(player, true, true)
			end
		end)
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	enabled[name] = nil
	light_curve_on[name] = nil
end)

local timer = 0

core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < REFRESH_INTERVAL then
		return
	end
	timer = 0

	if not allowed then
		return
	end

	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if enabled[name] and player:get_hp() > 0 then
			refresh_effect(player)
		end
	end
end)

local function set_allowed(name, value)
	allowed = value
	save_allowed()
	if value then
		for _, player in ipairs(core.get_connected_players()) do
			local pname = player:get_player_name()
			if enabled[pname] and player:get_hp() > 0 then
				refresh_effect(player)
				set_light_curve(player, true)
			end
		end
		send(name, "Разрешено всем.")
	else
		for _, player in ipairs(core.get_connected_players()) do
			set_light_curve(player, false)
		end
		send(name, "Запрещено всем. Зелья Night Vision при этом продолжают работать.")
	end
end

local function nightvision_func(name, param)
	local arg = (param or ""):lower():match("^%s*(.-)%s*$")

	if arg == "allow" or arg == "forbid" then
		if not core.check_player_privs(name, {server = true}) then
			return false, "Только админ может разрешать/запрещать всем."
		end
		set_allowed(name, arg == "allow")
		return true
	end

	if arg == "status" then
		local player = core.get_player_by_name(name)
		local own = player and allowed and enabled[name] == true
		send(name, "Режим: " .. (allowed and "разрешён" or "запрещён")
			.. ". У тебя: " .. (own and "включено" or "выключено") .. ".")
		return true
	end

	if arg ~= "" and arg ~= "on" and arg ~= "off" then
		return false, "Использование: /nightvision [on|off|status], /nightvision allow|forbid"
	end

	local player = core.get_player_by_name(name)
	if not player then
		return false, "Игрок не найден."
	end

	local state
	if arg == "on" then
		state = true
	elseif arg == "off" then
		state = false
	else
		state = not (enabled[name] == true)
	end

	if state and not allowed then
		return false, "Ночное зрение запрещено администратором."
	end

	set_player_enabled(player, state)
	if state then
		refresh_effect(player)
		set_light_curve(player, true)
		send(name, "Включено.")
	else
		-- Не вызываем clear_effect: пусть эффект от команды погаснет
		-- сам за пару секунд. Длительное зелье Night Vision останется.
		-- Кривую света возвращаем сразу, чтобы пещеры снова стали тёмными.
		set_light_curve(player, false)
		send(name, "Выключено.")
	end
	return true
end

core.register_chatcommand("nightvision", {
	description = "Включить/выключить ночное зрение (админ: allow/forbid)",
	params = "[on|off|status|allow|forbid]",
	func = nightvision_func,
})

core.register_chatcommand("nv", {
	description = "То же, что /nightvision",
	params = "[on|off|status|allow|forbid]",
	func = nightvision_func,
})
