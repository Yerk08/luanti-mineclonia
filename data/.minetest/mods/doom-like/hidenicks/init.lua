-- hidenicks: управление никами над головой и командными метками.
-- Режимы:
--   none   — всё стандартно
--   all    — ники видны и подкрашены цветом команды
--   hidden — ники скрыты, меток нет
--   team   — ники скрыты, свои видят waypoint-метки своих через стены

local MODNAME = core.get_current_modname()
local storage = core.get_mod_storage()
local MODE_KEY = "mode"
local VALID_MODES = {none = true, all = true, hidden = true, team = true}
local ALIASES = {
	show = "all",
	hide = "hidden",
	off = "none",
	teams = "team",
}

local mode = storage:get_string(MODE_KEY)
if not VALID_MODES[mode] then
	mode = core.settings:get("hidenicks_mode") or "none"
end
if not VALID_MODES[mode] then
	mode = "none"
end

-- mcl_player каждый шаг выставляет nametag_color под позу (обычный/присед).
-- Пока hidenicks не в none, не даём ему перебивать цвет/прозрачность:
-- убираем nametag_color из таблицы свойств перед передачей в оригинал.
local base_set_properties = mcl_util and mcl_util.set_properties
if base_set_properties then
	mcl_util.set_properties = function(obj, props)
		if mode ~= "none" and props and props.nametag_color
				and obj and obj:is_player() then
			props = table.copy(props)
			props.nametag_color = nil
		end
		return base_set_properties(obj, props)
	end
end

local MARKER_INTERVAL = 0.2
local NATIVE_INTERVAL = 0.2

local hud_ids = {} -- observer name -> {target name = hud id}
local marker_timer = 0
local color_timer = 0

local function send(name, message)
	core.chat_send_player(name,
		core.colorize("#55FFFF", "[Hidenicks] ") .. message)
end

local function team_color(name)
	if deadcount and deadcount.get_color then
		return deadcount.get_color(name)
	end
	return nil
end

local function neutral_color()
	if deadcount and deadcount.get_neutral_color then
		return deadcount.get_neutral_color()
	end
	return "#FFFFFF"
end

local function hex_to_rgb(hex, alpha)
	hex = type(hex) == "string" and hex or "#FFFFFF"
	local r = tonumber(hex:sub(2, 3), 16) or 255
	local g = tonumber(hex:sub(4, 5), 16) or 255
	local b = tonumber(hex:sub(6, 7), 16) or 255
	return {r = r, g = g, b = b, a = alpha or 255}
end

local function hex_to_int(hex)
	hex = type(hex) == "string" and hex or "#FFFFFF"
	local r = tonumber(hex:sub(2, 3), 16) or 255
	local g = tonumber(hex:sub(4, 5), 16) or 255
	local b = tonumber(hex:sub(6, 7), 16) or 255
	return r * 65536 + g * 256 + b
end

local function is_sneaking(player)
	local control = player.get_player_control and player:get_player_control()
	return control and control.sneak == true
end

local function same_color(a, b)
	return a and b and a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a
end

local function apply_native_nick(player)
	if not (player and player.set_nametag_attributes) then
		return
	end
	local name = player:get_player_name()
	local alpha = is_sneaking(player) and 0 or 225
	local color
	if mode == "hidden" or mode == "team" then
		color = {r = 255, g = 255, b = 255, a = 0}
	elseif mode == "all" then
		color = hex_to_rgb(team_color(name) or neutral_color(), alpha)
	else
		-- Как в Mineclonia: обычный ник 225, при приседании 0.
		color = {r = 225, g = 225, b = 225, a = alpha}
	end

	local current = player.get_nametag_attributes
		and player:get_nametag_attributes()
	if current and same_color(current.color, color) then
		return
	end
	player:set_nametag_attributes({color = color})
end

local function clear_markers(player)
	local name = player:get_player_name()
	local markers = hud_ids[name]
	if not markers then
		return
	end
	for _, id in pairs(markers) do
		player:hud_remove(id)
	end
	hud_ids[name] = nil
end

local function clear_all_markers()
	for _, player in ipairs(core.get_connected_players()) do
		clear_markers(player)
	end
	hud_ids = {}
end

local function update_markers()
	if mode ~= "team" then
		return
	end

	local players = core.get_connected_players()
	for _, observer in ipairs(players) do
		local oname = observer:get_player_name()
		local ocolor = team_color(oname)
		local wanted = {}

		if ocolor and observer:get_hp() > 0 then
			for _, target in ipairs(players) do
				local tname = target:get_player_name()
				if tname ~= oname and target:get_hp() > 0
						and team_color(tname) == ocolor then
					wanted[tname] = target
				end
			end
		end

		local markers = hud_ids[oname] or {}

		for tname, id in pairs(markers) do
			if not wanted[tname] then
				observer:hud_remove(id)
				markers[tname] = nil
			end
		end

		for tname, target in pairs(wanted) do
			local pos = target:get_pos()
			if pos then
				local waypoint_pos = {x = pos.x, y = pos.y + 2.0, z = pos.z}
				local id = markers[tname]
				if id then
					observer:hud_change(id, "world_pos", waypoint_pos)
					observer:hud_change(id, "number", hex_to_int(ocolor))
				else
					id = observer:hud_add({
						type = "waypoint",
						name = tname,
						world_pos = waypoint_pos,
						number = hex_to_int(ocolor),
						precision = 0,
						text = "",
						offset = {x = 0, y = -20},
						alignment = {x = 0, y = 0},
						z_index = 100,
					})
					if id then
						markers[tname] = id
					end
				end
			end
		end

		if next(markers) then
			hud_ids[oname] = markers
		else
			hud_ids[oname] = nil
		end
	end
end

local function set_mode(new_mode)
	if not VALID_MODES[new_mode] then
		return false
	end
	mode = new_mode
	storage:set_string(MODE_KEY, mode)

	for _, player in ipairs(core.get_connected_players()) do
		apply_native_nick(player)
	end

	if mode == "team" then
		update_markers()
	else
		clear_all_markers()
	end

	marker_timer = 0
	color_timer = 0
	return true
end

core.register_on_joinplayer(function(player)
	apply_native_nick(player)
	if mode == "team" then
		update_markers()
	end
end)

core.register_on_respawnplayer(function(player)
	apply_native_nick(player)
	if mode == "team" then
		core.after(0, update_markers)
	end
end)

core.register_on_dieplayer(function(player)
	clear_markers(player)
	if mode == "team" then
		core.after(0, update_markers)
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	clear_markers(player)
	hud_ids[name] = nil

	-- Убираем метки на ушедшего у остальных наблюдателей.
	for _, observer in ipairs(core.get_connected_players()) do
		local markers = hud_ids[observer:get_player_name()]
		if markers and markers[name] then
			observer:hud_remove(markers[name])
			markers[name] = nil
		end
	end
end)

core.register_globalstep(function(dtime)
	if mode == "team" then
		marker_timer = marker_timer + dtime
		if marker_timer >= MARKER_INTERVAL then
			marker_timer = 0
			update_markers()
			-- mcl_player меняет nametag_color при смене позы (присед/плавание),
			-- поэтому раз в 0.2 с возвращаем скрытие.
			for _, player in ipairs(core.get_connected_players()) do
				apply_native_nick(player)
			end
		end
	elseif mode == "all" or mode == "hidden" then
		-- В all/hidden HUD-меток нет; только поддерживаем цвет/скрытие
		-- нативного ника, если mcl_player перезаписал его при смене позы.
		color_timer = color_timer + dtime
		if color_timer >= NATIVE_INTERVAL then
			color_timer = 0
			for _, player in ipairs(core.get_connected_players()) do
				apply_native_nick(player)
			end
		end
	end
end)

core.register_chatcommand("hidenicks", {
	description = "Управление никами над головой",
	params = "none|all|hidden|team|status",
	privs = {server = true},
	func = function(name, param)
		local arg = (param or ""):lower():match("^%s*(.-)%s*$")
		arg = ALIASES[arg] or arg

		if arg == "" or arg == "status" then
			local labels = {
				none = "стандартные ники",
				all = "ники видны и подкрашены",
				hidden = "ники скрыты, меток нет",
				team = "ники скрыты, свои видят метки своих",
			}
			return true, "Режим: " .. (labels[mode] or mode) .. "."
		end

		if not VALID_MODES[arg] then
			return false, "Использование: /hidenicks none|all|hidden|team|status"
		end

		set_mode(arg)
		local messages = {
			none = "Стандартные ники.",
			all = "Ники видны и подкрашены по командам.",
			hidden = "Ники над головой скрыты, меток нет.",
			team = "Ники скрыты. Свои видят метки своих через стены.",
		}
		return true, messages[arg]
	end,
})
