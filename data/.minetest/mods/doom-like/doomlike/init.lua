-- Doom-like: быстрый игрок, стартовый набор, выбор оружия и больше монстров.
-- Мод использует предметы rifles, но не изменяет сам мод rifles.

local MODNAME = core.get_current_modname()
local S = core.get_translator(MODNAME)

local function setting_number(name, default)
	local value = tonumber(core.settings:get(name))
	if value == nil or value <= 0 then
		return default
	end
	return value
end

local SPEED_MULT = setting_number("doomlike_speed_multiplier", 1.6)
local JUMP_MULT = setting_number("doomlike_jump_multiplier", 1.4)
local MOB_CAP_MULT = setting_number("doomlike_mob_cap_multiplier", 2.0)
local SHELL_TARGET = setting_number("doomlike_shell_target", 50)
local AMMO_INTERVAL = setting_number("doomlike_ammo_refill_interval", 10)
local HUNGER_INTERVAL = 10

local OLD_GUN = "rifles:remington"
local SHELLS = "rifles:shell"
local GRENADES = "rifles:grenade"
local PICKAXE = "mcl_tools:pick_iron"
local TORCH = "mcl_torches:torch"
local WATER_BUCKET = "mcl_buckets:bucket_water"
local GOLDEN_APPLE = "mcl_core:apple_gold"
local NIGHT_HELMET = "mcl_armor:helmet_chain"
local NIGHT_META = "doomlike_night_vision"
local NIGHT_CHECK_INTERVAL = 1
local NIGHT_EFFECT_TIME = 2

local GLOCK = "rifles:glock17"
local GLOCK_AMMO = "rifles:9mm"
local GLOCK_CLIP = 17
local GLOCK_AMMO_TARGET = 500
local DEFAULT_PRIMARY = "m79"

local PRIMARY_WEAPONS = {
	spas12 = {
		item = "rifles:spas12",
		ammo = SHELLS,
		target = SHELL_TARGET,
		clip = 8,
		label = "SPAS-12",
		desc = "дробовик, 30 урона",
	},
	jackhammer = {
		item = "rifles:jackhammer",
		ammo = SHELLS,
		target = SHELL_TARGET,
		clip = 10,
		label = "Jackhammer",
		desc = "авто-дробовик, 40 урона",
	},
	m79 = {
		item = "rifles:m79",
		ammo = "rifles:40mm",
		target = 25,
		clip = 1,
		label = "M79",
		desc = "гранатомёт, взрыв",
	},
	rpg = {
		item = "rifles:rpg",
		ammo = "rifles:rocket",
		target = 15,
		clip = 1,
		label = "RPG-7",
		desc = "ракетница, взрыв 3",
	},
	ak47 = {
		item = "rifles:ak47",
		ammo = "rifles:762mm",
		target = 250,
		clip = 30,
		label = "AK-47",
		desc = "автомат, 30 патронов",
	},
}

-- Какое оружие пополняет какие патроны.
local AMMO_BY_WEAPON = {}
for _, data in pairs(PRIMARY_WEAPONS) do
	AMMO_BY_WEAPON[data.item] = {ammo = data.ammo, target = data.target}
end
AMMO_BY_WEAPON[GLOCK] = {ammo = GLOCK_AMMO, target = GLOCK_AMMO_TARGET}

local ARMOR = {
	"mcl_armor:helmet_chain",
	"mcl_armor:chestplate_chain",
	"mcl_armor:leggings_chain",
	"mcl_armor:boots_chain",
}

local KIT_ITEMS = {}
local kit_seen = {}
local function add_kit_item(item_name)
	if not kit_seen[item_name] then
		kit_seen[item_name] = true
		table.insert(KIT_ITEMS, item_name)
	end
end

add_kit_item(GLOCK)
add_kit_item(GLOCK_AMMO)
add_kit_item(OLD_GUN)
add_kit_item(SHELLS)
add_kit_item(GRENADES)
add_kit_item(PICKAXE)
add_kit_item(TORCH)
add_kit_item(WATER_BUCKET)
add_kit_item("mcl_buckets:bucket_empty")
add_kit_item(GOLDEN_APPLE)
for _, data in pairs(PRIMARY_WEAPONS) do
	add_kit_item(data.item)
	add_kit_item(data.ammo)
end
for _, item_name in ipairs(ARMOR) do
	add_kit_item(item_name)
end

local KIT_META = "doomlike_kit"
local PRIMARY_META = "doomlike:primary"

local function is_kit_stack(stack)
	return stack:get_meta():get_int(KIT_META) == 1
end

local function mark_kit(stack)
	stack:get_meta():set_int(KIT_META, 1)
	return stack
end

local function full_stack(item_name)
	local def = core.registered_items[item_name]
	local count = def and def.stack_max or 1
	return ItemStack(item_name .. " " .. count)
end

local function make_weapon(item_name, clip_size)
	local weapon = mark_kit(ItemStack(item_name))
	local meta = weapon:get_meta()
	meta:set_int("bullets", clip_size)
	meta:set_string("count_meta", tostring(clip_size))
	return weapon
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

local function player_has_kit_item(player, item_name)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand"}) do
		local list = inv:get_list(listname)
		if list then
			for _, stack in ipairs(list) do
				if stack:get_name() == item_name and is_kit_stack(stack) then
					return true
				end
			end
		end
	end
	return false
end

local function count_item(player, item_name)
	local inv = player:get_inventory()
	local total = 0
	for _, listname in ipairs({"main", "offhand"}) do
		local list = inv:get_list(listname)
		if list then
			for _, stack in ipairs(list) do
				if stack:get_name() == item_name then
					total = total + stack:get_count()
				end
			end
		end
	end
	return total
end

local function add_ammo(player, ammo, amount)
	local inv = player:get_inventory()
	local def = core.registered_items[ammo]
	local per_stack = def and def.stack_max or 1
	while amount > 0 do
		local n = math.min(amount, per_stack)
		inv:add_item("main", mark_kit(ItemStack(ammo .. " " .. n)))
		amount = amount - n
	end
end

local function refill_ammo(player, ammo, target)
	local missing = target - count_item(player, ammo)
	if missing > 0 then
		add_ammo(player, ammo, missing)
	end
end

local function refill_all_ammo(player)
	for weapon, data in pairs(AMMO_BY_WEAPON) do
		if player_has_item(player, weapon) then
			refill_ammo(player, data.ammo, data.target)
		end
	end
end

local function remove_kit_item(player, item_name)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand"}) do
		local list = inv:get_list(listname)
		if list then
			for i, stack in ipairs(list) do
				if stack:get_name() == item_name and is_kit_stack(stack) then
					inv:set_stack(listname, i, ItemStack(""))
				end
			end
		end
	end
end

local function get_primary_key(player)
	local meta = player:get_meta()
	local key = meta:get_string(PRIMARY_META)
	if not PRIMARY_WEAPONS[key] then
		key = DEFAULT_PRIMARY
		meta:set_string(PRIMARY_META, key)
	end
	return key
end

local function give_primary(player, key)
	if not PRIMARY_WEAPONS[key] then
		key = DEFAULT_PRIMARY
	end
	local data = PRIMARY_WEAPONS[key]
	player:get_meta():set_string(PRIMARY_META, key)

	local inv = player:get_inventory()
	local leftover = inv:add_item("main", make_weapon(data.item, data.clip))
	if not leftover:is_empty() then
		core.add_item(player:get_pos(), leftover)
	end
	refill_ammo(player, data.ammo, data.target)
end

local function set_primary_weapon(player, key)
	if not PRIMARY_WEAPONS[key] then
		return
	end

	for _, data in pairs(PRIMARY_WEAPONS) do
		remove_kit_item(player, data.item)
		remove_kit_item(player, data.ammo)
	end

	give_primary(player, key)
	core.chat_send_player(player:get_player_name(),
		core.colorize("#ffaa00", "[Doom-like] Основное оружие: " ..
			PRIMARY_WEAPONS[key].label))
end

local function show_weapon_menu(player)
	local current = PRIMARY_WEAPONS[get_primary_key(player)].label
	local formspec = table.concat({
		"formspec_version[4]",
		"size[8,6.7]",
		"label[0.4,0.3;Выбери основное оружие. Сейчас: " .. current .. "]",
		"button_exit[0.4,0.9;7.2,0.8;weapon_spas12;SPAS-12 — дробовик, 30 урона]",
		"button_exit[0.4,1.9;7.2,0.8;weapon_jackhammer;Jackhammer — авто-дробовик, 40 урона]",
		"button_exit[0.4,2.9;7.2,0.8;weapon_m79;M79 — гранатомёт, взрыв]",
		"button_exit[0.4,3.9;7.2,0.8;weapon_rpg;RPG-7 — ракетница, взрыв 3]",
		"button_exit[0.4,4.9;7.2,0.8;weapon_ak47;AK-47 — автомат, 30 патронов]",
		"label[0.4,5.8;Glock 17 у всех по умолчанию. Патроны пополняются сами.]",
		"label[0.4,6.2;Сменить оружие можно командой /weapon.]",
	})
	core.show_formspec(player:get_player_name(), "doomlike:weapon", formspec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "doomlike:weapon" then
		return
	end
	local choice
	if fields.weapon_spas12 then
		choice = "spas12"
	elseif fields.weapon_jackhammer then
		choice = "jackhammer"
	elseif fields.weapon_m79 then
		choice = "m79"
	elseif fields.weapon_rpg then
		choice = "rpg"
	elseif fields.weapon_ak47 then
		choice = "ak47"
	end
	if choice then
		set_primary_weapon(player, choice)
	end
	return true
end)

core.register_chatcommand("weapon", {
	description = "Выбрать основное оружие",
	func = function(name)
		local player = core.get_player_by_name(name)
		if player then
			show_weapon_menu(player)
		end
		return true
	end,
})

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
			inv:add_item("main", leftover)
		end
	end
end

local function equip_torch(player)
	local inv = player:get_inventory()
	if not inv:get_list("offhand") then
		return
	end
	inv:set_stack("offhand", 1, mark_kit(full_stack(TORCH)))
end

local function has_night_helmet(player)
	local inv = player:get_inventory()
	if not inv or inv:get_size("armor") < 2 then
		return false
	end
	local stack = inv:get_stack("armor", 2)
	return stack:get_name() == NIGHT_HELMET
		and stack:get_meta():get_int(NIGHT_META) == 1
end

local function player_has_night_helmet_item(player)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand", "armor"}) do
		local list = inv:get_list(listname)
		if list then
			for _, stack in ipairs(list) do
				if stack:get_name() == NIGHT_HELMET
						and stack:get_meta():get_int(NIGHT_META) == 1 then
					return true
				end
			end
		end
	end
	return false
end

local function make_night_helmet()
	local stack = mark_kit(ItemStack(NIGHT_HELMET))
	local meta = stack:get_meta()
	meta:set_int(NIGHT_META, 1)
	meta:set_string("description", "Кольчужная каска с фонариком")
	return stack
end

local function ensure_night_helmet(player)
	if player_has_night_helmet_item(player) then
		return
	end
	player:get_inventory():add_item("main", make_night_helmet())
end

local function ensure_water_bucket(player)
	if player_has_kit_item(player, WATER_BUCKET) then
		return
	end
	player:get_inventory():add_item("main", mark_kit(ItemStack(WATER_BUCKET)))
end

local function give_kit(player)
	local inv = player:get_inventory()
	local key = get_primary_key(player)

	inv:add_item("main", make_weapon(GLOCK, GLOCK_CLIP))
	refill_ammo(player, GLOCK_AMMO, GLOCK_AMMO_TARGET)
	give_primary(player, key)

	inv:add_item("main", mark_kit(ItemStack(PICKAXE)))
	inv:add_item("main", mark_kit(ItemStack(WATER_BUCKET)))

	-- 3 гранаты: stack_max = 1, поэтому отдельными стаками.
	for _ = 1, 3 do
		inv:add_item("main", mark_kit(ItemStack(GRENADES)))
	end

	inv:add_item("main", mark_kit(ItemStack(GOLDEN_APPLE .. " 5")))
	inv:add_item("main", make_night_helmet())

	equip_armor(player)
	equip_torch(player)

	core.chat_send_player(player:get_player_name(),
		core.colorize("#ffaa00",
			"[Doom-like] Стартовый набор выдан. Сменить оружие: /weapon"))
end

local function upgrade_old_gun(player)
	local key = get_primary_key(player)
	local data = PRIMARY_WEAPONS[key]
	local inv = player:get_inventory()

	for _, listname in ipairs({"main", "offhand"}) do
		local list = inv:get_list(listname)
		if list then
			for i, stack in ipairs(list) do
				if stack:get_name() == OLD_GUN and is_kit_stack(stack) then
					inv:set_stack(listname, i, make_weapon(data.item, data.clip))
					refill_ammo(player, data.ammo, data.target)
					return true
				end
			end
		end
	end
	return false
end

local function ensure_sidearm(player)
	if player_has_item(player, GLOCK) then
		return
	end
	local inv = player:get_inventory()
	local leftover = inv:add_item("main", make_weapon(GLOCK, GLOCK_CLIP))
	if not leftover:is_empty() then
		core.add_item(player:get_pos(), leftover)
	end
	refill_ammo(player, GLOCK_AMMO, GLOCK_AMMO_TARGET)
end

local function ensure_primary(player)
	local key = get_primary_key(player)
	local data = PRIMARY_WEAPONS[key]
	if player_has_item(player, data.item) then
		return
	end
	if not upgrade_old_gun(player) then
		give_primary(player, key)
	end
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

	ensure_sidearm(player)
	ensure_primary(player)
	ensure_night_helmet(player)
	ensure_water_bucket(player)
	refill_all_ammo(player)
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

core.register_on_joinplayer(function(player)
	apply_physics(player)
	ensure_kit(player)

	local meta = player:get_meta()
	if meta:get_int("doomlike:weapon_menu_shown") ~= 1 then
		meta:set_int("doomlike:weapon_menu_shown", 1)
		core.after(1, function()
			if player:is_player() then
				show_weapon_menu(player)
			end
		end)
	end
end)

core.register_on_respawnplayer(function(player)
	apply_physics(player)
	ensure_kit(player)
end)

-- Патроны пополняются не каждый тик, а раз в 10 секунд.
local ammo_timer = 0

core.register_globalstep(function(dtime)
	ammo_timer = ammo_timer + dtime
	if ammo_timer < AMMO_INTERVAL then
		return
	end
	ammo_timer = 0

	for _, player in ipairs(core.get_connected_players()) do
		refill_all_ammo(player)
	end
end)

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

-- Night Vision от каски с фонариком. Пока каска надета, эффект
-- постоянно продлевается. После снятия он сам гаснет через пару секунд,
-- а более длительное зелье Night Vision при этом не обрезается.
local night_timer = 0

core.register_globalstep(function(dtime)
	night_timer = night_timer + dtime
	if night_timer < NIGHT_CHECK_INTERVAL then
		return
	end
	night_timer = 0

	if not (mcl_potions and mcl_potions.give_effect) then
		return
	end

	for _, player in ipairs(core.get_connected_players()) do
		if has_night_helmet(player) and player:get_hp() > 0 then
			mcl_potions.give_effect("night_vision", player, 0,
				NIGHT_EFFECT_TIME, true)
		end
	end
end)

-- mcl_death_drop при смерти вызывает on_drop у предметов.
-- Пустой ItemStack отменяет выпадение помеченного стартового набора.
local function install_drop_guard()
	for _, item_name in ipairs(KIT_ITEMS) do
		local def = core.registered_items[item_name]
		if def then
			local old_on_drop = def.on_drop
			def.on_drop = function(stack, dropper, pos)
				if is_kit_stack(stack) and dropper and dropper:is_player()
						and dropper:get_hp() <= 0 then
					return ItemStack("")
				end
				if old_on_drop then
					return old_on_drop(stack, dropper, pos)
				end
				return stack
			end
		end
	end
end

-- Страховка для mcl_keepInventory: убираем набор при смерти вручную.
core.register_on_dieplayer(function(player)
	local inv = player:get_inventory()
	local changed = false

	for _, listname in ipairs({"main", "offhand", "armor", "craft"}) do
		local list = inv:get_list(listname)
		if list then
			for i, stack in ipairs(list) do
				if is_kit_stack(stack) then
					inv:set_stack(listname, i, ItemStack(""))
					changed = true
				end
			end
		end
	end

	if changed and mcl_armor and mcl_armor.update then
		mcl_armor.update(player)
	end
end)

local function boost_mob_caps()
	if not (mcl_mobs and mcl_mobs.spawn_categories
			and mcl_mobs.spawn_categories.monster) then
		return
	end

	local monster = mcl_mobs.spawn_categories.monster
	monster.chunk_mob_cap = math.max(1,
		math.floor(monster.chunk_mob_cap * MOB_CAP_MULT + 0.5))
	monster.min_chunk_mob_cap = math.max(1,
		math.floor(monster.min_chunk_mob_cap * MOB_CAP_MULT + 0.5))
end

core.register_on_mods_loaded(function()
	install_drop_guard()
	boost_mob_caps()
end)
