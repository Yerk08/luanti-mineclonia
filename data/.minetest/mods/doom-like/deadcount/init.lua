-- deadcount: счётчик смертей для онлайн-игроков.
-- Отдельный мод: не зависит от doom-like, rifles и других модов.

local MODNAME = core.get_current_modname()
local STORAGE_KEY = "state"
local storage = core.get_mod_storage()

local state = {
	deaths = {},
	kills = {},
	colors = {},
	mode = "deaths", -- "deaths" | "kills" | "none"
	frozen = false,
	freeze_at = 0,
	unfreeze_at = 0,
	infection = false,
}

local creative_cache = {}
local hud_ids = {}

local PALETTE = {
	red = "#FF5555",
	green = "#55FF55",
	blue = "#5555FF",
	yellow = "#FFFF55",
	orange = "#FFAA00",
	purple = "#AA55FF",
	cyan = "#55FFFF",
	pink = "#FF55FF",
	white = "#FFFFFF",
	gray = "#AAAAAA",
}

local PALETTE_ORDER = {
	"red", "green", "blue", "yellow", "orange",
	"purple", "cyan", "pink", "white", "gray",
}

local HEADER_COLOR = "#FFAA00"
local TIMER_COLOR = "#55FFFF"
local SCHEDULE_COLOR = "#FFFF55"

local function too_dark(hex)
	local r = tonumber(hex:sub(2, 3), 16) / 255
	local g = tonumber(hex:sub(4, 5), 16) / 255
	local b = tonumber(hex:sub(6, 7), 16) / 255
	return (0.299 * r + 0.587 * g + 0.114 * b) < 0.18
end

local function normalize_color(value)
	if type(value) ~= "string" then
		return nil
	end
	local v = value:lower()
	if v == "off" or v == "none" or v == "default" then
		return false
	end
	if PALETTE[v] then
		return PALETTE[v]
	end
	local hex = v:match("^#?(%x%x%x%x%x%x)$")
	if not hex then
		return nil
	end
	local color = "#" .. hex:upper()
	if too_dark(color) then
		return nil
	end
	return color
end

local function color_to_int(hex)
	return tonumber(hex:sub(2), 16) or 0xFFFFFF
end

local function setting_color(name, default)
	local value = core.settings:get(name) or default
	local color = normalize_color(value)
	if type(color) == "string" then
		return color
	end
	return default
end

local function get_int(name, default, min, max)
	local value = tonumber(core.settings:get(name))
	if not value then
		return default
	end
	value = math.floor(value)
	if min and value < min then
		return default
	end
	if max and value > max then
		return default
	end
	return value
end

local function get_float(name, default, min, max)
	local value = tonumber(core.settings:get(name))
	if not value then
		return default
	end
	if min and value < min then
		return default
	end
	if max and value > max then
		return default
	end
	return value
end

local SHOW_HUD = core.settings:get_bool("deadcount_hud", true)
local MAX_ROWS = get_int("deadcount_max_rows", 10, 0, 100)
local NAME_WIDTH = get_int("deadcount_name_width", 18, 8, 32)
local MAP_Y = get_float("deadcount_map_y", 0.30, 0.10, 0.80)
local MARGIN = get_int("deadcount_margin", 8, 0, 100)
local NEUTRAL_COLOR = setting_color("deadcount_neutral_color", "#E0E0E0")
local INFECTED_COLOR = setting_color("deadcount_infected_color", "#55FF55")
local NEUTRAL_INT = color_to_int(NEUTRAL_COLOR)

-- Небольшой API для других модов (hidenicks): цвет команды и нейтральный цвет.
deadcount = deadcount or {}
function deadcount.get_color(name)
	return state.colors[name]
end
function deadcount.get_neutral_color()
	return NEUTRAL_COLOR
end

local function save()
	storage:set_string(STORAGE_KEY, core.serialize(state))
end

local function load_state()
	local raw = storage:get_string(STORAGE_KEY)
	if raw == "" then
		return
	end

	local ok, data = pcall(core.deserialize, raw)
	if not ok or type(data) ~= "table" then
		core.log("warning", "[" .. MODNAME .. "] не удалось прочитать сохранённые данные")
		return
	end

	if type(data.deaths) == "table" then
		for name, count in pairs(data.deaths) do
			if type(name) == "string" and type(count) == "number" and count >= 0 then
				state.deaths[name] = math.floor(count)
			end
		end
	end

	if type(data.kills) == "table" then
		for name, count in pairs(data.kills) do
			if type(name) == "string" and type(count) == "number" and count >= 0 then
				state.kills[name] = math.floor(count)
			end
		end
	end

	if data.mode == "kills" or data.mode == "none" or data.mode == "deaths" then
		state.mode = data.mode
	end

	if type(data.colors) == "table" then
		for name, color in pairs(data.colors) do
			if type(name) == "string" and type(color) == "string" then
				local normalized = normalize_color(color)
				if type(normalized) == "string" then
					state.colors[name] = normalized
				end
			end
		end
	end

	state.frozen = data.frozen == true
	state.infection = data.infection == true
	state.freeze_at = math.max(0, math.floor(tonumber(data.freeze_at) or 0))
	state.unfreeze_at = math.max(0, math.floor(tonumber(data.unfreeze_at) or 0))

	if state.frozen then
		state.freeze_at = 0
	else
		state.unfreeze_at = 0
	end
end

local function format_time(seconds)
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, sec)
	end
	return string.format("%02d:%02d", m, sec)
end

local function update_timers()
	local now = os.time()
	local changed = false

	if not state.frozen and state.freeze_at > 0 and now >= state.freeze_at then
		state.frozen = true
		state.freeze_at = 0
		changed = true
	end

	if state.frozen and state.unfreeze_at > 0 and now >= state.unfreeze_at then
		state.frozen = false
		state.unfreeze_at = 0
		changed = true
	end

	if state.frozen and state.freeze_at > 0 then
		state.freeze_at = 0
		changed = true
	end

	if not state.frozen and state.unfreeze_at > 0 then
		state.unfreeze_at = 0
		changed = true
	end

	if changed then
		save()
	end
	return changed
end

local function has_countdown()
	return state.freeze_at > 0 or state.unfreeze_at > 0
end

local function effective_color(name)
	if state.infection and (state.deaths[name] or 0) > 0 then
		return INFECTED_COLOR
	end
	return state.colors[name] or NEUTRAL_COLOR
end

local function stat_for(name)
	if state.mode == "kills" then
		return state.kills[name] or 0
	end
	return state.deaths[name] or 0
end

local function stat_label()
	if state.mode == "kills" then
		return "Килы"
	elseif state.mode == "none" then
		return "Статистика"
	end
	return "Смерти"
end

-- Команда — это одинаковый явно выбранный цвет. Нейтральные (без цвета)
-- не считаются одной командой: они могут убивать друг друга.
local function same_team(a, b)
	local ca = state.colors[a]
	local cb = state.colors[b]
	return ca ~= nil and cb ~= nil and ca == cb
end

local function player_name_of_object(obj)
	if not obj then
		return nil
	end
	local ok, is_player = pcall(function() return obj:is_player() end)
	if not ok or not is_player then
		return nil
	end
	local ok2, name = pcall(function() return obj:get_player_name() end)
	if ok2 then
		return name
	end
	return nil
end

-- Достаём ник убийцы из reason. В Mineclonia mcl_damage кладёт
-- source/direct в _mcl_reason; для пули есть запасной путь через owner.
local function killer_from_reason(reason)
	if not reason then
		return nil
	end

	local mcl_reason = reason._mcl_reason
	if not mcl_reason and mcl_damage and mcl_damage.from_mt then
		local ok, normalized = pcall(mcl_damage.from_mt, reason)
		if ok then
			mcl_reason = normalized
		end
	end
	if mcl_reason then
		local name = player_name_of_object(mcl_reason.source)
			or player_name_of_object(mcl_reason.direct)
		if name then
			return name
		end
	end

	if reason.type == "punch" and reason.object
			and reason.object.get_luaentity then
		local ok, ent = pcall(function()
			return reason.object:get_luaentity()
		end)
		if ok and ent then
			local name = player_name_of_object(ent._source_object)
			if name then
				return name
			end
			if type(ent.owner) == "string" then
				return ent.owner
			end
		end
	end

	return nil
end

local function is_creative(name)
	local value = creative_cache[name]
	if value == nil then
		value = core.is_creative_enabled(name)
		creative_cache[name] = value
	end
	return value
end

local function update_creative_cache()
	local changed = false
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local creative = core.is_creative_enabled(name)
		if creative_cache[name] ~= creative then
			creative_cache[name] = creative
			changed = true
		end
	end
	return changed
end

local function utf8_len(value)
	local _, count = value:gsub("[^\128-\193]", "")
	return count
end

local function utf8_truncate(value, max)
	local parts = {}
	local count = 0
	for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if count >= max then
			break
		end
		parts[#parts + 1] = char
		count = count + 1
	end
	return table.concat(parts)
end

local function fit_name(name)
	if utf8_len(name) <= NAME_WIDTH then
		return name
	end
	return utf8_truncate(name, NAME_WIDTH - 1) .. "…"
end

local function online_names()
	local names = {}
	for _, player in ipairs(core.get_connected_players()) do
		names[#names + 1] = player:get_player_name()
	end
	table.sort(names, function(a, b)
		local ca = stat_for(a)
		local cb = stat_for(b)
		if ca ~= cb then
			return ca > cb
		end
		return a:lower() < b:lower()
	end)
	return names
end

local function build_compact_header()
	local now = os.time()
	local tags_vis = {}
	local tags_plain = {}

	if state.frozen then
		tags_plain[#tags_plain + 1] = "[F]"
		tags_vis[#tags_vis + 1] = core.colorize(TIMER_COLOR, "[F]")
		if state.unfreeze_at > 0 then
			local text = "[U " .. format_time(state.unfreeze_at - now) .. "]"
			tags_plain[#tags_plain + 1] = text
			tags_vis[#tags_vis + 1] = core.colorize(TIMER_COLOR, text)
		end
	elseif state.freeze_at > 0 then
		local text = "[F " .. format_time(state.freeze_at - now) .. "]"
		tags_plain[#tags_plain + 1] = text
		tags_vis[#tags_vis + 1] = core.colorize(SCHEDULE_COLOR, text)
	end

	if state.infection then
		tags_plain[#tags_plain + 1] = "[Z]"
		tags_vis[#tags_vis + 1] = core.colorize(INFECTED_COLOR, "[Z]")
	end

	local header_plain = stat_label()
	local header_vis = core.colorize(HEADER_COLOR, header_plain)
	if #tags_plain > 0 then
		header_plain = header_plain .. " " .. table.concat(tags_plain, " ")
		header_vis = header_vis .. " " .. table.concat(tags_vis, " ")
	end
	return header_vis, header_plain
end

local function build_chat_header()
	local now = os.time()
	local status = {}

	if state.frozen then
		local text = "заморожено"
		if state.unfreeze_at > 0 then
			text = text .. ", разморозка через " .. format_time(state.unfreeze_at - now)
		end
		status[#status + 1] = text
	elseif state.freeze_at > 0 then
		status[#status + 1] = "заморозка через " .. format_time(state.freeze_at - now)
	end

	if state.infection then
		status[#status + 1] = "заражение"
	end

	local header = stat_label()
	if #status > 0 then
		header = header .. " (" .. table.concat(status, ", ") .. ")"
	end
	return core.colorize(HEADER_COLOR, header .. ":")
end

local function build_rows(limit)
	local names = online_names()
	local total = #names
	local shown = names

	if limit and limit > 0 and total > limit then
		shown = {}
		for i = 1, limit do
			shown[i] = names[i]
		end
	end

	local count_width = 3
	for _, name in ipairs(shown) do
		local digits = #tostring(stat_for(name))
		if digits > count_width then
			count_width = digits
		end
	end

	local visible = {}
	local plain = {}

	for _, name in ipairs(shown) do
		local color = effective_color(name)
		local display = fit_name(name)
		local pad = string.rep(" ", NAME_WIDTH - utf8_len(display))
		local count = stat_for(name)
		local count_str = string.format("%" .. count_width .. "d", count)
		local creative = is_creative(name)
		local flag_plain = creative and "[C]" or "[ ]"
		local flag_vis = creative
			and core.colorize(color, "[C]")
			or core.colorize(NEUTRAL_COLOR, "[ ]")

		local neutral_part = core.colorize(NEUTRAL_COLOR,
			pad .. "  " .. count_str .. "  ")
		visible[#visible + 1] = core.colorize(color, display)
			.. neutral_part .. flag_vis
		plain[#plain + 1] = display .. pad .. "  " .. count_str .. "  " .. flag_plain
	end

	local hidden = total - #shown
	if hidden > 0 then
		local summary = "+" .. hidden .. " ещё"
		visible[#visible + 1] = core.colorize(NEUTRAL_COLOR, summary)
		plain[#plain + 1] = summary
	end

	return visible, plain
end

local function build_hud_text()
	local header_vis, header_plain = build_compact_header()
	local rows_vis, rows_plain = build_rows(MAX_ROWS)
	table.insert(rows_vis, 1, header_vis)
	table.insert(rows_plain, 1, header_plain)
	return table.concat(rows_vis, "\n"), table.concat(rows_plain, "\n")
end

local function build_chat_lines()
	local rows = build_rows(0)
	table.insert(rows, 1, build_chat_header())
	return rows
end

local function remove_hud(player)
	local name = player:get_player_name()
	local ids = hud_ids[name]
	if not ids then
		return
	end
	player:hud_remove(ids.text)
	player:hud_remove(ids.shadow)
	hud_ids[name] = nil
end

-- HUD всегда под картой, без выбора позиции.
local function create_hud(player)
	local base = {
		type = "text",
		position = { x = 1, y = MAP_Y },
		alignment = { x = -1, y = 1 },
		offset = { x = -MARGIN, y = 0 },
		number = NEUTRAL_INT,
		style = 4,
		z_index = 10,
		text = "",
	}
	local shadow = {
		type = "text",
		position = { x = 1, y = MAP_Y },
		alignment = { x = -1, y = 1 },
		offset = { x = -MARGIN + 2, y = 2 },
		number = 0x000000,
		style = 4,
		z_index = 9,
		text = "",
	}
	return {
		text = player:hud_add(base),
		shadow = player:hud_add(shadow),
	}
end

local function update_hud(player, text, shadow_text)
	local name = player:get_player_name()
	local ids = hud_ids[name]
	if not ids then
		ids = create_hud(player)
		hud_ids[name] = ids
	end
	player:hud_change(ids.text, "text", text)
	player:hud_change(ids.shadow, "text", shadow_text)
end

local function refresh_all()
	if not SHOW_HUD or state.mode == "none" then
		for _, player in ipairs(core.get_connected_players()) do
			remove_hud(player)
		end
		return
	end
	update_timers()
	local text, shadow = build_hud_text()
	for _, player in ipairs(core.get_connected_players()) do
		update_hud(player, text, shadow)
	end
end

local function split_args(param)
	local args = {}
	if param then
		for word in param:gmatch("%S+") do
			args[#args + 1] = word
		end
	end
	return args
end

local function send_lines(name, lines)
	for _, line in ipairs(lines) do
		core.chat_send_player(name, line)
	end
end

local function find_key(tbl, name)
	if tbl[name] ~= nil then
		return name
	end
	local lower = name:lower()
	for key in pairs(tbl) do
		if type(key) == "string" and key:lower() == lower then
			return key
		end
	end
	return nil
end

local function find_online_name(name)
	local lower = name:lower()
	for _, player in ipairs(core.get_connected_players()) do
		local player_name = player:get_player_name()
		if player_name:lower() == lower then
			return player_name
		end
	end
	return nil
end

local function resolve_name(name)
	return find_key(state.deaths, name)
		or find_key(state.kills, name)
		or find_key(state.colors, name)
end

local function migrate_player(name)
	local changed = false
	for _, field in ipairs({ "deaths", "kills", "colors" }) do
		local key = find_key(state[field], name)
		if key and key ~= name then
			state[field][name] = state[field][key]
			state[field][key] = nil
			changed = true
		end
	end
	if changed then
		save()
	end
end

local DURATION_UNITS = { s = 1, m = 60, h = 3600, d = 86400 }

local function parse_duration(value)
	if not value then
		return nil
	end
	local number, unit = value:lower():match("^(%d+)%s*([smhd]?)$")
	if not number then
		return nil
	end
	number = tonumber(number)
	if not number or number <= 0 then
		return nil
	end
	return number * DURATION_UNITS[unit ~= "" and unit or "m"]
end

local function admin_help()
	return {
		core.colorize(HEADER_COLOR, "Deadcount — управление:"),
		"  /deadcount mode deaths|kills|none",
		"  /deadcount reset <ник|all>",
		"  /deadcount color <ник> <цвет|off>",
		"  /deadcount infection on|off|status",
		"  /deadcount freeze on|off",
		"  /deadcount freeze in 10m",
		"  /deadcount freeze for 30m",
		"  /deadcount freeze cancel|status",
		"Цвета: /team list. Одинаковый явный цвет — одна команда.",
	}
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	migrate_player(name)
	creative_cache[name] = core.is_creative_enabled(name)
	core.after(0, function()
		if player:is_player() then
			refresh_all()
		end
	end)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	hud_ids[name] = nil
	creative_cache[name] = nil
	core.after(0, refresh_all)
end)

core.register_on_respawnplayer(function(player)
	core.after(0, function()
		if player:is_player() then
			refresh_all()
		end
	end)
end)

core.register_on_dieplayer(function(player, reason)
	update_timers()
	if state.frozen then
		return
	end

	local name = player:get_player_name()
	local old = state.deaths[name] or 0
	state.deaths[name] = old + 1

	local killer = killer_from_reason(reason)
	if killer and killer ~= name and not same_team(killer, name) then
		state.kills[killer] = (state.kills[killer] or 0) + 1
	end

	save()

	if state.infection and old == 0 then
		core.chat_send_player(name, core.colorize(INFECTED_COLOR,
			"[deadcount] Ты заражён! Теперь ты в зелёной команде."))
	end

	refresh_all()
end)

core.register_on_shutdown(function()
	save()
end)

core.register_on_mods_loaded(function()
	if mcl_gamemode and mcl_gamemode.register_on_gamemode_change then
		mcl_gamemode.register_on_gamemode_change(function(player)
			local name = player:get_player_name()
			creative_cache[name] = core.is_creative_enabled(name)
			refresh_all()
		end)
	end
end)

local tick_timer = 0

core.register_globalstep(function(dtime)
	tick_timer = tick_timer + dtime
	if tick_timer < 1 then
		return
	end
	tick_timer = 0

	local timers_changed = update_timers()
	local creative_changed = update_creative_cache()
	if timers_changed or creative_changed or has_countdown() then
		refresh_all()
	end
end)

core.register_chatcommand("deaths", {
	description = "Показать счётчик смертей или килов",
	func = function(name)
		send_lines(name, build_chat_lines())
		return true
	end,
})

core.register_chatcommand("team", {
	description = "Выбрать цвет своего ника",
	params = "[цвет|off|list]",
	func = function(name, param)
		local arg = (param or ""):match("^%s*(.-)%s*$")

		if arg == "" then
			local stored = state.colors[name]
			local lines = {
				"Твой цвет: " .. (stored and core.colorize(stored, stored) or "нейтральный"),
			}
			if state.infection and (state.deaths[name] or 0) > 0 then
				lines[#lines + 1] = core.colorize(INFECTED_COLOR,
					"Сейчас действует заражение — отображаешься зелёным.")
			end
			send_lines(name, lines)
			return true
		end

		if arg:lower() == "list" then
			local lines = { core.colorize(HEADER_COLOR, "Доступные цвета:") }
			for _, color_name in ipairs(PALETTE_ORDER) do
				lines[#lines + 1] = string.format("  %-8s %s", color_name,
					core.colorize(PALETTE[color_name], PALETTE[color_name]))
			end
			lines[#lines + 1] = "Свой цвет: #RRGGBB"
			send_lines(name, lines)
			return true
		end

		local color = normalize_color(arg)
		if color == nil then
			return false, "Неизвестный или слишком тёмный цвет. Список: /team list"
		end

		if color == false then
			state.colors[name] = nil
		else
			state.colors[name] = color
		end
		save()
		refresh_all()

		if state.infection and (state.deaths[name] or 0) > 0 then
			return true, "Цвет сохранён, но пока действует заражение — ты отображаешься зелёным."
		end
		return true, color and ("Твой цвет: " .. color) or "Цвет сброшен на нейтральный."
	end,
})

core.register_chatcommand("deadcount", {
	description = "Управление счётчиком смертей",
	params = "mode deaths|kills|none | reset <ник|all> | color <ник> <цвет|off> | infection on|off|status | freeze ...",
	privs = { server = true },
	func = function(name, param)
		local args = split_args(param)
		local sub = args[1] and args[1]:lower()

		if not sub then
			send_lines(name, admin_help())
			return true
		end

		if sub == "mode" then
			local mode = args[2] and args[2]:lower()
			if not mode or mode == "status" then
				local labels = {deaths = "смерти", kills = "килы", none = "выключен"}
				return true, "Режим показа: " .. (labels[state.mode] or state.mode) .. "."
			end
			if mode ~= "deaths" and mode ~= "kills" and mode ~= "none" then
				return false, "Использование: /deadcount mode deaths|kills|none"
			end
			state.mode = mode
			save()
			refresh_all()
			core.log("action", "[deadcount] " .. name .. " set mode to " .. mode)
			if mode == "none" then
				return true, "Показ HUD выключен. Смерти и килы продолжают считаться."
			elseif mode == "kills" then
				return true, "HUD показывает килы."
			end
			return true, "HUD показывает смерти."
		end

		if sub == "reset" then
			local target = args[2]
			if not target then
				return false, "Укажи ник или all: /deadcount reset <ник|all>"
			end

			if target:lower() == "all" then
				state.deaths = {}
				state.kills = {}
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " reset all stats")
				return true, "Все счётчики смертей и килов сброшены."
			end

			local key = find_online_name(target) or resolve_name(target)
			if not key then
				return false, "Нет записей об игроке " .. target .. "."
			end

			local was_infected = state.infection and (state.deaths[key] or 0) > 0
			state.deaths[key] = 0
			state.kills[key] = 0
			save()
			refresh_all()
			core.log("action", "[deadcount] " .. name .. " reset stats of " .. key)
			return true, "Счётчики смертей и килов игрока " .. key .. " сброшены."
				.. (was_infected and " Заражение снято." or "")

		elseif sub == "color" then
			local target = args[2]
			local color_arg = args[3]
			if not target or not color_arg then
				return false, "Использование: /deadcount color <ник> <цвет|off>"
			end

			local key = find_online_name(target) or resolve_name(target) or target
			local color = normalize_color(color_arg)
			if color == nil then
				return false, "Неизвестный или слишком тёмный цвет. Список: /team list"
			end

			if color == false then
				state.colors[key] = nil
			else
				state.colors[key] = color
			end
			save()
			refresh_all()
			core.log("action", "[deadcount] " .. name .. " set color of " .. key .. " to " .. color_arg)

			local message = color and ("Цвет игрока " .. key .. ": " .. color)
				or ("Цвет игрока " .. key .. " сброшен.")
			if state.infection and (state.deaths[key] or 0) > 0 then
				message = message .. " Сейчас действует заражение — игрок отображается зелёным."
			end
			return true, message

		elseif sub == "infection" then
			local action = args[2]
			if not action or action:lower() == "status" then
				local infected = 0
				for _, player in ipairs(core.get_connected_players()) do
					if (state.deaths[player:get_player_name()] or 0) > 0 then
						infected = infected + 1
					end
				end
				return true, "Режим заражения: "
					.. (state.infection and "включён" or "выключен")
					.. ". Игроков со смертями онлайн: " .. infected .. "."
			end

			action = action:lower()
			if action == "on" then
				if state.infection then
					return true, "Режим заражения уже включён."
				end
				state.infection = true
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " enabled infection mode")
				return true, "Режим заражения включён. Все, у кого есть смерти, стали зелёными."
			elseif action == "off" then
				if not state.infection then
					return true, "Режим заражения уже выключен."
				end
				state.infection = false
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " disabled infection mode")
				return true, "Режим заражения выключен. Игроки вернулись к своим цветам."
			end
			return false, "Использование: /deadcount infection on|off|status"

		elseif sub == "freeze" then
			local action = args[2]
			if not action or action:lower() == "status" then
				local lines = {}
				if state.frozen then
					local text = "Счётчик заморожен."
					if state.unfreeze_at > 0 then
						text = text .. " Разморозка через "
							.. format_time(state.unfreeze_at - os.time()) .. "."
					end
					lines[#lines + 1] = text
				elseif state.freeze_at > 0 then
					lines[#lines + 1] = "Счётчик активен. Заморозка через "
						.. format_time(state.freeze_at - os.time()) .. "."
				else
					lines[#lines + 1] = "Счётчик активен."
				end
				lines[#lines + 1] = "Режим заражения: "
					.. (state.infection and "включён" or "выключен") .. "."
				send_lines(name, lines)
				return true
			end

			action = action:lower()

			if action == "on" then
				if state.frozen and state.unfreeze_at == 0 then
					return true, "Счётчик уже заморожен."
				end
				state.frozen = true
				state.freeze_at = 0
				state.unfreeze_at = 0
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " froze the counter")
				return true, "Счётчик заморожен. Новые смерти не считаются."

			elseif action == "off" then
				if not state.frozen and state.freeze_at == 0 and state.unfreeze_at == 0 then
					return true, "Счётчик уже активен."
				end
				state.frozen = false
				state.freeze_at = 0
				state.unfreeze_at = 0
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " unfroze the counter")
				return true, "Счётчик разморожен. Смерти снова считаются."

			elseif action == "in" then
				if state.frozen then
					return false, "Счётчик уже заморожен. Используй freeze off или freeze for <время>."
				end
				local seconds = parse_duration(args[3])
				if not seconds then
					return false, "Укажи время: 30s, 10m, 2h, 1d."
				end
				state.freeze_at = os.time() + seconds
				state.unfreeze_at = 0
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " scheduled freeze in " .. seconds .. "s")
				return true, "Заморозка через " .. format_time(seconds) .. "."

			elseif action == "for" then
				local seconds = parse_duration(args[3])
				if not seconds then
					return false, "Укажи время: 30s, 10m, 2h, 1d."
				end
				state.frozen = true
				state.freeze_at = 0
				state.unfreeze_at = os.time() + seconds
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " froze the counter for " .. seconds .. "s")
				return true, "Счётчик заморожен на " .. format_time(seconds) .. "."

			elseif action == "cancel" then
				if state.freeze_at == 0 and state.unfreeze_at == 0 then
					return true, "Нет активных таймеров."
				end
				state.freeze_at = 0
				state.unfreeze_at = 0
				save()
				refresh_all()
				core.log("action", "[deadcount] " .. name .. " cancelled freeze timers")
				return true, "Таймеры заморозки отменены. Текущее состояние сохранено."
			end

			return false, "Использование: /deadcount freeze on|off|in <время>|for <время>|cancel|status"
		end

		send_lines(name, admin_help())
		return false, "Неизвестная команда."
	end,
})

load_state()
update_timers()
