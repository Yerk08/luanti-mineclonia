-- Doom-like: быстрый игрок, Бабаха, стартовый набор, сытость и больше монстров.
-- Единственное оружие арены — doomlike:babaha. Остальные стволы rifles
-- остаются в коде для совместимости старых предметов, но не крафтятся
-- и спрятаны из креатива.

local MODNAME = core.get_current_modname()
local storage = core.get_mod_storage()
local MOB_CAP_KEY = "mob_cap_multiplier"

-- Бабаха регистрирует предмет, HUD и перезарядку.
dofile(core.get_modpath(MODNAME) .. "/babaha.lua")

local function setting_number(name, default)
	local value = tonumber(core.settings:get(name))
	if value == nil or value <= 0 then
		return default
	end
	return value
end

local SPEED_MULT = setting_number("doomlike_speed_multiplier", 1.6)
local JUMP_MULT = setting_number("doomlike_jump_multiplier", 1.4)
local HUNGER_INTERVAL = 10

local function valid_mob_cap(value)
	value = tonumber(value)
	if not value or value < 0 or value > 10 then
		return nil
	end
	return value
end

local MOB_CAP_DEFAULT = valid_mob_cap(core.settings:get(
	"doomlike_mob_cap_multiplier")) or 1.5
local MOB_CAP_MULT = valid_mob_cap(storage:get_string(MOB_CAP_KEY))
	or MOB_CAP_DEFAULT

local BABAHA = "doomlike:babaha"
local PICKAXE = "mcl_tools:pick_iron"
local TORCH = "mcl_torches:torch"
local SCAFFOLDING = "mcl_bamboo:scaffolding"
local OLD_NIGHT_META = "doomlike_night_vision"
local OLD_NIGHT_DESCRIPTION = "Кольчужная каска с фонариком"

local ARMOR = {
	"mcl_armor:helmet_chain",
	"mcl_armor:chestplate_chain",
	"mcl_armor:leggings_chain",
	"mcl_armor:boots_chain",
}

local KIT_META = "doomlike_kit"

-- Всё, что считается актуальным набором. Старые kit-предметы (Glock,
-- патроны, булыжник, ведро, другие стволы) при входе удаляются.
local KIT_ITEMS = {
	[BABAHA] = true,
	[PICKAXE] = true,
	[TORCH] = true,
	[SCAFFOLDING] = true,
}
for _, item_name in ipairs(ARMOR) do
	KIT_ITEMS[item_name] = true
end

local function is_kit_stack(stack)
	return stack:get_meta():get_int(KIT_META) == 1
end

local function mark_kit(stack)
	if not stack:is_empty() then
		stack:get_meta():set_int(KIT_META, 1)
	end
	return stack
end

local function full_stack(item_name)
	local def = core.registered_items[item_name]
	if not def then
		return ItemStack("")
	end
	return ItemStack(item_name .. " " .. (def.stack_max or 1))
end

local function player_has_item(player, item_name)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand"}) do
		if inv:get_list(listname) and inv:contains_item(listname, item_name) then
			return true
		end
	end
	return false
end

local function player_has_offhand(player, item_name)
	local offhand = player:get_inventory():get_list("offhand")
	return offhand and offhand[1] and offhand[1]:get_name() == item_name
end

local function add_kit_item(player, stack)
	if not stack or stack:is_empty() then
		return
	end
	local inv = player:get_inventory()
	local leftover = inv:add_item("main", stack)
	if not leftover:is_empty() then
		core.add_item(player:get_pos(), leftover)
	end
end

local function cleanup_legacy_kit(player)
	local inv = player:get_inventory()
	if not inv then
		return
	end
	for _, listname in ipairs({"main", "offhand"}) do
		local list = inv:get_list(listname)
		if list then
			for i, stack in ipairs(list) do
				if is_kit_stack(stack) and not KIT_ITEMS[stack:get_name()] then
					inv:set_stack(listname, i, ItemStack(""))
				end
			end
		end
	end
end

local function equip_armor(player)
	if not (mcl_armor and mcl_armor.equip) then
		return
	end

	local inv = player:get_inventory()
	if not inv:get_list("armor") then
		return
	end

	for _, item_name in ipairs(ARMOR) do
		local leftover = mcl_armor.equip(mark_kit(ItemStack(item_name)),
			player, false)
		if leftover and not leftover:is_empty() then
			add_kit_item(player, leftover)
		end
	end
end

local function equip_torch(player)
	local inv = player:get_inventory()
	local offhand = inv:get_list("offhand")
	local torch = full_stack(TORCH)
	if torch:is_empty() then
		return
	end
	mark_kit(torch)
	if offhand then
		local current = offhand[1]
		if not current or current:is_empty() or current:get_name() == TORCH then
			inv:set_stack("offhand", 1, torch)
		end
		-- Левая рука занята другим предметом — не трогаем её.
		return
	end
	-- В этой игре нет слота левой руки — кладём факелы в инвентарь.
	add_kit_item(player, torch)
end

-- Night Vision вынесен в отдельный мод nightvision.
-- Старые каски из предыдущих версий превращаем в обычные кольчужные шлемы.
local function cleanup_old_night_helmets(player)
	local inv = player:get_inventory()
	if not inv then
		return
	end
	for _, listname in ipairs({"main", "offhand", "armor"}) do
		local list = inv:get_list(listname)
		if list then
			for i, stack in ipairs(list) do
				if stack:get_name() == "mcl_armor:helmet_chain"
						and stack:get_meta():get_int(OLD_NIGHT_META) == 1 then
					local meta = stack:get_meta()
					meta:set_int(OLD_NIGHT_META, 0)
					if meta:get_string("description") == OLD_NIGHT_DESCRIPTION then
						meta:set_string("description", "")
					end
					inv:set_stack(listname, i, stack)
				end
			end
		end
	end
end

local function give_kit(player)
	add_kit_item(player, mark_kit(ItemStack(BABAHA)))
	add_kit_item(player, mark_kit(ItemStack(PICKAXE)))
	add_kit_item(player, mark_kit(full_stack(SCAFFOLDING)))

	equip_armor(player)
	equip_torch(player)

	core.chat_send_player(player:get_player_name(),
		core.colorize("#ffaa00",
			"[Doom-like] Бабаха выдана. Перезарядка идёт, пока держишь её в руках."))
end

local function has_any_kit(player)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand", "armor"}) do
		local list = inv:get_list(listname)
		if list then
			for _, stack in ipairs(list) do
				if is_kit_stack(stack) then
					return true
				end
			end
		end
	end
	return false
end

local function ensure_kit(player)
	if not has_any_kit(player) then
		give_kit(player)
		return
	end

	if not player_has_item(player, BABAHA) then
		add_kit_item(player, mark_kit(ItemStack(BABAHA)))
	end
	if not player_has_item(player, PICKAXE) then
		add_kit_item(player, mark_kit(ItemStack(PICKAXE)))
	end
	if not player_has_item(player, SCAFFOLDING) then
		add_kit_item(player, mark_kit(full_stack(SCAFFOLDING)))
	end
	if not player_has_offhand(player, TORCH) then
		equip_torch(player)
	end
end

local function apply_physics(player)
	-- playerphysics умеет складывать множители от разных модов
	-- (зелья, броня и т.п.), поэтому используем его, если он есть.
	if playerphysics and playerphysics.add_physics_factor then
		playerphysics.add_physics_factor(player, "speed",
			"doomlike:speed", SPEED_MULT)
		playerphysics.add_physics_factor(player, "jump",
			"doomlike:jump", JUMP_MULT)
	else
		player:set_physics_override({
			speed = SPEED_MULT,
			jump = JUMP_MULT,
		})
	end
end

local function prepare_player(player)
	cleanup_legacy_kit(player)
	cleanup_old_night_helmets(player)
	apply_physics(player)
	ensure_kit(player)
end

core.register_on_joinplayer(prepare_player)
core.register_on_respawnplayer(prepare_player)

-- Сытость всегда 20: голод не мешает, но еда всё ещё даёт сатурацию.
local hunger_timer = 0

core.register_globalstep(function(dtime)
	hunger_timer = hunger_timer + dtime
	if hunger_timer < HUNGER_INTERVAL then
		return
	end
	hunger_timer = 0

	if not (mcl_hunger and mcl_hunger.get_hunger and mcl_hunger.set_hunger) then
		return
	end

	for _, player in ipairs(core.get_connected_players()) do
		if player:get_hp() > 0 and mcl_hunger.get_hunger(player) < 20 then
			mcl_hunger.set_hunger(player, 20, true)
		end
	end
end)

local base_chunk_cap
local base_min_chunk_cap

local function capture_mob_caps()
	if not (mcl_mobs and mcl_mobs.spawn_categories
			and mcl_mobs.spawn_categories.monster) then
		return false
	end
	local monster = mcl_mobs.spawn_categories.monster
	base_chunk_cap = monster.chunk_mob_cap
	base_min_chunk_cap = monster.min_chunk_mob_cap
	return true
end

local function apply_mob_caps(mult)
	if not base_chunk_cap or not base_min_chunk_cap then
		return false
	end
	local monster = mcl_mobs.spawn_categories.monster
	monster.chunk_mob_cap = math.max(0,
		math.floor(base_chunk_cap * mult + 0.5))
	monster.min_chunk_mob_cap = math.max(0,
		math.floor(base_min_chunk_cap * mult + 0.5))
	return true
end

core.register_chatcommand("mobcap", {
	description = "Множитель лимита монстров (0 — выключить)",
	params = "[0-10]",
	privs = {server = true},
	func = function(name, param)
		local arg = (param or ""):match("^%s*(.-)%s*$")
		if arg == "" or arg:lower() == "status" then
			return true, "Множитель лимита монстров: " .. MOB_CAP_MULT
				.. " (0 — монстры не спавнятся)."
		end
		local value = tonumber(arg)
		if not value or value < 0 or value > 10 then
			return false, "Использование: /mobcap <0-10> (0 — выключить монстров)"
		end
		MOB_CAP_MULT = value
		storage:set_string(MOB_CAP_KEY, tostring(value))
		if not apply_mob_caps(value) then
			return true, "Множитель сохранён: " .. value
				.. ". mcl_mobs ещё не готов; применится при загрузке мира."
		end
		return true, "Множитель лимита монстров: " .. value
			.. " (0 — монстры не спавнятся)."
	end,
})

core.register_on_mods_loaded(function()
	if capture_mob_caps() then
		apply_mob_caps(MOB_CAP_MULT)
	end

	-- Старые стволы оставляем зарегистрированными, чтобы предметы в мирах
	-- не превратились в unknown item, но убираем их из креатива.
	for name, def in pairs(core.registered_items) do
		if name:sub(1, 7) == "rifles:" then
			def.groups = def.groups or {}
			def.groups.not_in_creative_inventory = 1
		end
	end
end)
