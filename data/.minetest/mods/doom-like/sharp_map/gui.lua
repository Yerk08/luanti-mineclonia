-- The map screen: a large map on the left, waypoints in a sidebar.
--
-- Opened with /map, or the map button in Sharp Inventory's survival
-- inventory (only when both mods are installed).
--
-- View: opens centered on the player and follows them. It moves away only
-- when the player selects a waypoint (centers on it), uses the arrow
-- buttons, or clicks a spot on the map (recenters there). Formspecs send no
-- drag or mouse-move events, so click-to-recenter stands in for dragging.
-- "Back to me" returns to following the player; closing the map resets.
--
-- Hover: the map is covered by a grid of invisible buttons. Each has a
-- tooltip (handled by the client, no server traffic) with the biome (see
-- biomes.lua), the coordinates of that spot and the waypoints in it.
--
-- Look: shown with core.show_formspec, so it uses Mineclonia's formspec
-- prepend, and Sharp Inventory's dark theme when that mod is installed.
-- Labels use mcl_formspec.label_color, which Sharp Inventory makes light.
--
-- Sidebar (1.2.0): the pinned waypoint is listed first; with more than one
-- category, each category is a header row ([-] open, [+] collapsed; double
-- click to fold) with its waypoints under it. The arrows beside the list
-- move the selected waypoint (into the next category past the end of one)
-- or the selected category. "+ Category" adds one; selecting a category
-- header shows its own panel (rename, delete, fold). The selection is
-- kept as a reference to the waypoint or category itself, so a death point
-- added while the map is open never shifts it onto another waypoint.
--
-- Layers (1.3.0): a row of controls in the map's top-left corner picks
-- what the map shows: Auto (the surface above ground, the caves around
-- you underground and in the Nether), the surface, or a cave layer. A
-- cave layer is 32 nodes tall: its own 16-node band over the band below,
-- drawn darker, over the surface, drawn much darker. The up and down
-- arrows step 16 nodes; the middle button switches between Auto and the
-- surface. The pictures are layered by the client (texture grouping and
-- [multiply), so each band's tiles are drawn and saved once, like the
-- surface's.
--
-- Security: all screen state lives on the server, per player. Field
-- values are only read as a table event (looked up in the rows this
-- server sent), dropdown indexes checked against their lists, cleaned
-- names, and known button names (icon buttons are checked against the
-- icon list).

local S = sharp_map.S
local F = core.formspec_escape
local cfg = sharp_map.settings
local floor = math.floor
local FORMNAME = "sharp_map:map"
local OPEN_FIELD = "sharp_map_open"

-- Layout, in formspec units. The screen fills the player's window: its
-- size comes from core.get_player_window_information (max_formspec_size,
-- with padding[0,0]), so wide screens get a wider map and short screens a
-- shorter waypoint list. Without that information (old clients) it is
-- 19 x 12. The map is a whole number of units (one hover cell per unit);
-- the space left over is split evenly around the map, sidebar and bottom
-- bar, so the screen is centered.
-- use_layout() sets these for the player being handled; every entry point
-- calls it first (Lua runs one callback at a time).
local SIDE_W = 4.25
local BAR_H = 0.75
local SIDE_FIXED = 5.5 -- height of the editing panel under the waypoint list
-- The list is a table[] (1.2.2): an icon column, then colored text, so
-- categories and waypoints show their own icon and color.
local TABLE_STYLE = "tableoptions[background=#00000040;border=false;highlight=#FFFFFF33;"
	.. "highlight_text=#FFFFFF]"
local MAP_X, MAP_Y, MAP_W, MAP_H, SIDE_X, BAR_Y, FORM_W, FORM_H, FULLSCREEN

local function round3(v)
	return floor(v * 1000 + 0.5) / 1000
end

local function compute_layout(name)
	local info = type(core.get_player_window_information) == "function"
		and core.get_player_window_information(name)
	local mx, my = 19, 12
	local full = false
	if type(info) == "table" and type(info.max_formspec_size) == "table"
			and tonumber(info.max_formspec_size.x) and tonumber(info.max_formspec_size.y) then
		mx, my = info.max_formspec_size.x, info.max_formspec_size.y
		full = true
	end
	local fw = math.max(19, math.min(32, floor(mx * 4) / 4))
	local fh = math.max(10, math.min(18, floor(my * 4) / 4))
	-- At least 0.25 of margin on every side and between the parts.
	local w = floor(fw - 0.75 - SIDE_W)
	local h = floor(fh - 0.75 - BAR_H)
	local x = round3((fw - (w + 0.25 + SIDE_W)) / 2)
	local y = round3((fh - (h + 0.25 + BAR_H)) / 2)
	return {
		fw = fw, fh = fh, full = full, w = w, h = h, x = x, y = y,
		side_x = round3(x + w + 0.25), bar_y = round3(y + h + 0.25),
	}
end

local function use_layout(L)
	MAP_X, MAP_Y, MAP_W, MAP_H = L.x, L.y, L.w, L.h
	SIDE_X, BAR_Y, FORM_W, FORM_H, FULLSCREEN = L.side_x, L.bar_y, L.fw, L.fh, L.full
end

local ZOOMS = { 4, 8, 16, 32, 64 } -- nodes per unit
local DEFAULT_ZOOM = 3
local LIMIT = 31000

local contexts = {} -- player name -> view and sidebar state

local function label_color()
	if core.global_exists("mcl_formspec") and type(mcl_formspec.label_color) == "string" then
		return mcl_formspec.label_color
	end
	return "#313131"
end

local function label(x, y, text)
	return ("label[%s,%s;%s]"):format(x, y, F(core.colorize(label_color(), text)))
end

local function palette_index(color)
	for i, c in ipairs(sharp_map.COLORS) do
		if c[2] == color then
			return i
		end
	end
	return 1
end

local function same_dim(wp, dim)
	return not wp.dim or not dim or wp.dim == dim
end

local function clamp(v)
	return math.max(-LIMIT, math.min(LIMIT, v))
end

-- The view: x0 is the west edge, z1 the north edge, npu nodes per unit.
-- The center (cx, cz) is exactly the middle of the map area, also when the
-- map is an odd number of squares wide or tall (zooms are even numbers of
-- nodes per square, so half the view is always a whole number of nodes).
local function view_of(ctx)
	local npu = ZOOMS[ctx.zoom]
	return {
		npu = npu,
		x0 = ctx.cx - floor(MAP_W * npu / 2),
		z1 = ctx.cz + floor(MAP_H * npu / 2),
		w = MAP_W * npu,
		h = MAP_H * npu,
	}
end

-- Map position -> formspec units inside the map, or nil if outside.
local function to_units(view, x, z)
	local ux = (x - view.x0 + 0.5) / view.npu
	local uy = (view.z1 - z + 0.5) / view.npu
	if ux < 0 or ux >= MAP_W or uy < 0 or uy >= MAP_H then
		return nil, ux, uy
	end
	return ux, uy
end

------------------------------------------------------------------------
-- Building the screen
------------------------------------------------------------------------

-- LAYERS: back to front, { textures, multiply color or nil }.
local function map_image(view, layers)
	local parts = {}
	for _, l in ipairs(layers) do
		local texture = sharp_map.combine(l.textures, view.x0, view.z1, view.w, view.h)
		if texture then
			if l.multiply then
				texture = texture .. "^[multiply:" .. l.multiply
			end
			parts[#parts + 1] = "(" .. texture .. ")"
		end
	end
	if #parts == 0 then
		return ""
	end
	return ("image[%s,%s;%s,%s;%s]"):format(MAP_X, MAP_Y, MAP_W, MAP_H, F(table.concat(parts, "^")))
end

------------------------------------------------------------------------
-- Layers (1.3.0)
------------------------------------------------------------------------

local BAND = 16
local BAND_LIMIT = floor(LIMIT / BAND)

-- The lowest and highest cave layer worth showing in dimension DIM
-- (1.4.4): from the bottom of the dimension to its top, as Mineclonia sets
-- them (mcl_vars.mg_<dim>_min and _max, read when needed; names checked in
-- Chris's API dump). Before, the buttons went on to y -31000 everywhere.
-- A dimension Mineclonia does not describe keeps the old limits.
local DIM_VARS = {
	overworld = { "mg_overworld_min", "mg_overworld_max" },
	nether = { "mg_nether_min", "mg_nether_max" },
	["end"] = { "mg_end_min", "mg_end_max" },
}
local function band_range(dim)
	local names = DIM_VARS[dim]
	local vars = rawget(_G, "mcl_vars")
	if names and type(vars) == "table" then
		local lo, hi = vars[names[1]], vars[names[2]]
		if type(lo) == "number" and type(hi) == "number" and lo < hi then
			-- A layer shows its own band over the band below, so the
			-- lowest one worth showing holds the bottom in its upper half.
			return floor(lo / BAND) + 1, floor(hi / BAND)
		end
	end
	return -BAND_LIMIT, BAND_LIMIT
end
sharp_map.layer_band_range = band_range -- for tests
local SURFACE_DIM = "#4D4D4D"   -- the surface under a cave layer
local LOWER_BAND = "#B3B3B3"    -- the lower band of a cave layer
local LAYER_X, LAYER_Y, LAYER_H = 0.15, 0.15, 0.6
local LAYER_LABEL_W = 3.6
-- Up arrow, label, down arrow, and (1.4.4) a small Auto square.
local LAYER_W = LAYER_H * 3 + LAYER_LABEL_W + 0.15

-- The band a map screen shows, or nil for the surface.
local function shown_band(player, ctx)
	if ctx.layer == "surface" then
		return nil
	elseif type(ctx.layer) == "number" then
		return ctx.layer
	end
	return sharp_map.cave_band(player)
end

local function layer_text(ctx, band)
	local text
	if band then
		text = S("Caves: y @1 to @2", (band - 1) * BAND, band * BAND + BAND - 1)
	elseif ctx.dim == "nether" then
		text = S("Overview")
	else
		text = S("Surface")
	end
	if ctx.layer == nil then
		text = S("@1 (auto)", text)
	end
	return text
end

local function layer_controls(ctx, band)
	if not cfg.caves then
		return ""
	end
	local x, y, h = MAP_X + LAYER_X, MAP_Y + LAYER_Y, LAYER_H
	return table.concat({
		"style[layer_up,layer_down,layer_auto;bgimg=mcl_inventory_button9.png;",
		"bgimg_hovered=mcl_inventory_button9.png;bgimg_pressed=mcl_inventory_button9_pressed.png;",
		"bgimg_middle=2,2;border=false]",
		("image_button[%s,%s;%s,%s;sharp_map_arrow_n.png;layer_up;]"):format(round3(x), round3(y), h, h),
		("button[%s,%s;%s,%s;layer;%s]"):format(round3(x + h + 0.05), round3(y), LAYER_LABEL_W, h,
			F(layer_text(ctx, band))),
		("image_button[%s,%s;%s,%s;sharp_map_arrow_s.png;layer_down;]"):format(
			round3(x + h + LAYER_LABEL_W + 0.1), round3(y), h, h),
		("image_button[%s,%s;%s,%s;sharp_map_layer_auto.png;layer_auto;]"):format(
			round3(x + 2 * h + LAYER_LABEL_W + 0.15), round3(y), h, h),
		"tooltip[layer_auto;", F(S("Automatic: the layer you are in")), "]",
		"tooltip[layer_up;", F(S("Show the cave layer 16 nodes higher")), "]",
		"tooltip[layer_down;", F(S("Show the cave layer 16 nodes lower")), "]",
		"tooltip[layer;", F(S("Switch between automatic (surface above ground, caves below) and the surface")),
		"]",
	})
end

-- Map layers to send for a screen showing BAND (nil = surface) in DIM:
-- { map id, multiply color }, back to front.
local function layer_list(dim, band)
	if not band then
		return { { mid = dim } }
	end
	return {
		{ mid = dim, multiply = SURFACE_DIM },
		{ mid = sharp_map.cave_mid(dim, band - 1), multiply = LOWER_BAND },
		{ mid = sharp_map.cave_mid(dim, band) },
	}
end

-- The player: an arrow pointing where the player looks, in 8 directions
-- (two textures, turned in quarter turns by [transformR; nothing is made
-- per click), or with sharp_map.player_arrow = false the figure that never
-- turns. Off the map it sits at the nearest edge.
local TURNS = { "", "^[transformR270", "^[transformR180", "^[transformR90" } -- clockwise quarters

local function player_texture(player)
	if not cfg.player_arrow then
		return "sharp_map_player.png"
	end
	-- Yaw is counter-clockwise from north; h counts eighths clockwise.
	local h = floor(((-player:get_look_horizontal()) % (2 * math.pi)) / (math.pi / 4) + 0.5) % 8
	local base = h % 2 == 1 and "sharp_map_player_arrow_diag.png" or "sharp_map_player_arrow.png"
	return base .. TURNS[floor(h / 2) + 1]
end
sharp_map.player_map_texture = player_texture

local function player_marker(view, player)
	local pos = player:get_pos()
	local ux, uy = to_units(view, floor(pos.x + 0.5), floor(pos.z + 0.5))
	if not ux then
		local _, rx, ry = to_units(view, floor(pos.x + 0.5), floor(pos.z + 0.5))
		ux = math.max(0.3, math.min(MAP_W - 0.3, rx))
		uy = math.max(0.3, math.min(MAP_H - 0.3, ry))
	end
	return ("image[%s,%s;0.6,0.6;%s]"):format(MAP_X + ux - 0.3, MAP_Y + uy - 0.3, F(player_texture(player)))
end

local function waypoint_markers(view, list, dim, sel)
	local out = {}
	for i, wp in ipairs(list) do
		if (wp.shown or i == sel) and same_dim(wp, dim) then
			local ux, uy = to_units(view, wp.pos.x, wp.pos.z)
			if ux then
				local size = i == sel and 0.6 or 0.45
				if i == sel then
					out[#out + 1] = ("box[%s,%s;0.7,0.7;#FFFFFF80]"):format(MAP_X + ux - 0.35,
						MAP_Y + uy - 0.35)
				end
				out[#out + 1] = ("image[%s,%s;%s,%s;%s]"):format(MAP_X + ux - size / 2,
					MAP_Y + uy - size / 2, size, size, F(sharp_map.icon_texture(wp.icon, wp.color)))
			end
		end
	end
	return table.concat(out)
end

local ARROW_SIZE, ARROW_INSET = 0.75, 0.15

-- Arrow positions, relative to the map's top-left corner.
local function arrow_spots()
	local size, inset = ARROW_SIZE, ARROW_INSET
	local cx, cy = MAP_W / 2 - size / 2, MAP_H / 2 - size / 2
	return {
		pan_n = { cx, inset },
		pan_s = { cx, MAP_H - size - inset },
		pan_w = { inset, cy },
		pan_e = { MAP_W - size - inset, cy },
	}
end

-- Is the hover square at I, J (partly) under an arrow? Those squares are
-- left out, so a click on an arrow can never recenter the map instead.
local function under_arrow(i, j)
	for _, spot in pairs(arrow_spots()) do
		if i < spot[1] + ARROW_SIZE and i + 1 > spot[1] and j < spot[2] + ARROW_SIZE and j + 1 > spot[2] then
			return true
		end
	end
	-- The layer controls in the top-left corner (1.3.0).
	if cfg.caves and i < LAYER_X + LAYER_W and j < LAYER_Y + LAYER_H then
		return true
	end
	return false
end

-- Invisible buttons over the map: hover shows a tooltip, click recenters.
local function hover_grid(view, list, dim, y)
	local in_cell = {}
	for _, wp in ipairs(list) do
		if wp.shown and same_dim(wp, dim) then
			local ux, uy = to_units(view, wp.pos.x, wp.pos.z)
			if ux then
				local key = floor(ux) .. "_" .. floor(uy)
				in_cell[key] = (in_cell[key] and in_cell[key] .. "\n" or "") .. wp.name
			end
		end
	end
	local out = {}
	for i = 0, MAP_W - 1 do
		for j = 0, MAP_H - 1 do
			if not under_arrow(i, j) then
				local name = "c" .. i .. "_" .. j
				local x = view.x0 + floor((i + 0.5) * view.npu)
				local z = view.z1 - floor((j + 0.5) * view.npu)
				local tip = S("X @1, Z @2", x, z)
				local biome = sharp_map.biome_at_spot(dim, x, z, y)
				if biome then
					tip = biome .. "\n" .. tip
				end
				local wps = in_cell[i .. "_" .. j]
				if wps then
					tip = wps .. "\n" .. tip
				end
				out[#out + 1] = ("image_button[%s,%s;1,1;blank.png;%s;]tooltip[%s;%s]"):format(
					MAP_X + i, MAP_Y + j, name, name, F(tip))
			end
		end
	end
	return table.concat(out)
end

local function index_of(t, item)
	if item == nil then
		return nil
	end
	for i, v in ipairs(t) do
		if v == item then
			return i
		end
	end
end

-- One list row as table cells: indent, icon index, color, text. ICONS
-- collects the tinted icon textures used, so each gets one index.
local function list_cells(row, list, cats, dim, icons)
	local function icon_index(icon, color)
		local tex = sharp_map.icon_texture(icon, color)
		if not icons.index[tex] then
			icons[#icons + 1] = tex
			icons.index[tex] = #icons
		end
		return icons.index[tex]
	end
	if row.kind == "cat" then
		local cat = cats[row.index]
		return { "0", tostring(icon_index(cat.icon, cat.color)), ("#%06X"):format(cat.color),
			F((cat.collapsed and "[+] " or "[-] ") .. sharp_map.category_label(cat) .. "  (" .. row.count .. ")") }
	end
	local wp = list[row.index]
	local text = wp.name
	if wp.pinned then
		text = text .. "  " .. S("(pinned)")
	end
	if not same_dim(wp, dim) then
		text = text .. "  " .. S("(other dimension)")
	elseif wp.mode == "hidden" then
		text = text .. "  " .. S("(hidden)")
	elseif wp.mode == "icon" then
		text = text .. "  " .. S("(icon only)")
	end
	return { row.indent and "1" or "0", tostring(icon_index(wp.icon, wp.color)), ("#%06X"):format(wp.color),
		F(text) }
end

-- Icon picker: 7 icons per row, 2 rows visible, the rest reached with the
-- scrollbar on the right or the mouse wheel (a scroll_container clips the
-- grid to the visible rows). Scroll units: 10 per row.
local ICON_SIZE, ICON_STEP, ICONS_PER_ROW, ICON_ROWS_SHOWN = 0.5, 0.55, 7, 2
local SCROLL_PER_ROW = 10

local function icon_rows()
	return math.ceil(#sharp_map.ICONS / ICONS_PER_ROW)
end

local function icon_scroll_max()
	return math.max(0, icon_rows() - ICON_ROWS_SHOWN) * SCROLL_PER_ROW
end

-- Scroll position that shows ICON (used when the picker first opens).
local function scroll_to_icon(icon)
	for i, def in ipairs(sharp_map.ICONS) do
		if def[1] == icon then
			local row = floor((i - 1) / ICONS_PER_ROW)
			return math.min(icon_scroll_max(), row * SCROLL_PER_ROW)
		end
	end
	return 0
end

local function icon_picker(x, y, icon, color, scroll)
	local view_w = ICONS_PER_ROW * ICON_STEP
	local view_h = ICON_ROWS_SHOWN * ICON_STEP
	local page = SCROLL_PER_ROW * ICON_ROWS_SHOWN
	local out = {
		("scrollbaroptions[min=0;max=%d;smallstep=%d;largestep=%d;thumbsize=%d;arrows=hide]"):format(
			icon_scroll_max(), SCROLL_PER_ROW, page, page),
		("scrollbar[%s,%s;0.35,%s;vertical;icon_scroll;%d]"):format(x + view_w + 0.05, y, view_h, scroll),
		("scroll_container[%s,%s;%s,%s;icon_scroll;vertical;%s]"):format(x, y, view_w, view_h,
			ICON_STEP / SCROLL_PER_ROW),
	}
	for i, def in ipairs(sharp_map.ICONS) do
		local ix = ((i - 1) % ICONS_PER_ROW) * ICON_STEP
		local iy = floor((i - 1) / ICONS_PER_ROW) * ICON_STEP
		if def[1] == icon then
			out[#out + 1] = ("box[%s,%s;%s,%s;#FFFFFF60]"):format(ix, iy, ICON_STEP - 0.01, ICON_STEP - 0.01)
		end
		local field = "icon_" .. def[1]
		out[#out + 1] = ("image_button[%s,%s;%s,%s;%s;%s;]tooltip[%s;%s]"):format(ix + 0.025, iy + 0.025,
			ICON_SIZE, ICON_SIZE, F(sharp_map.icon_texture(def[1], color)), field, field, F(def[2]))
	end
	out[#out + 1] = "scroll_container_end[]"
	return table.concat(out)
end

-- Two buttons side by side in width W; either may be nil.
local function button_pair(x, y, w, left, right)
	local half = (w - 0.15) / 2
	local out = {}
	if left then
		out[#out + 1] = ("button[%s,%s;%s,0.65;%s;%s]"):format(x, y, half, left[1], F(left[2]))
	end
	if right then
		out[#out + 1] = ("button[%s,%s;%s,0.65;%s;%s]"):format(round3(x + half + 0.15), y, half, right[1],
			F(right[2]))
	end
	return table.concat(out)
end

local function waypoint_panel(player, ctx, list, cats, x, w, base)
	local sel = ctx.wp and list[index_of(list, ctx.wp)]
	local color_names = {}
	for i, c in ipairs(sharp_map.COLORS) do
		color_names[i] = F(c[1])
	end
	local cat_names = {}
	for i, c in ipairs(cats) do
		cat_names[i] = F(sharp_map.category_label(c))
	end
	local color_idx = ctx.color or (sel and palette_index(sel.color)) or 1
	local icon = ctx.icon or (sel and sel.icon) or "dot"
	local cat_idx = sharp_map.category_index(cats, ctx.cat_pick or (sel and sel.cat)
		or (ctx.last_cat and ctx.last_cat.name) or "") or sharp_map.category_index(cats, "") or 1
	local half = round3((w - 0.15) / 2)
	local fs = {
		label(x, base, S("Name")),
		("field[%s,%s;%s,0.7;name;;%s]"):format(x, base + 0.2, w, F(ctx.name or (sel and sel.name) or "")),
		"field_close_on_enter[name;false]",
		("dropdown[%s,%s;%s,0.7;color;%s;%d;true]"):format(x, base + 1.05, half,
			table.concat(color_names, ","), color_idx),
		("dropdown[%s,%s;%s,0.7;cat;%s;%d;true]"):format(round3(x + half + 0.15), base + 1.05, half,
			table.concat(cat_names, ","), cat_idx),
		"tooltip[cat;" .. F(S("Category")) .. "]",
		icon_picker(x, base + 1.95, icon, sharp_map.COLORS[color_idx][2],
			ctx.icon_scroll or scroll_to_icon(icon)),
	}
	if not sel then
		fs[#fs + 1] = ("button[%s,%s;%s,0.65;add;%s]"):format(x, base + 3.35, w, F(S("Add at my position")))
		return table.concat(fs)
	end
	fs[#fs + 1] = button_pair(x, base + 3.35, w, { "add", S("Add here") }, { "save", S("Save changes") })
	fs[#fs + 1] = "tooltip[add;" .. F(S("Add a new waypoint at your position")) .. "]"
	-- Label mode (cycles on click) and pin.
	fs[#fs + 1] = button_pair(x, base + 4.1, w, { "mode", sharp_map.label_mode_name(sel.mode) },
		{ "pin", sel.pinned and S("Unpin") or S("Pin") })
	fs[#fs + 1] = "tooltip[mode;" .. F(table.concat({
		S("When this waypoint shows its name and distance:"),
		S("Auto: when near, when you look at it, or when pinned"),
		S("Always"),
		S("Icon only: just the icon"),
		S("Hidden: nothing"),
		S("Click to change"),
	}, "\n")) .. "]"
	fs[#fs + 1] = "tooltip[pin;" .. F(S("A pinned waypoint always shows its name and distance.")
		.. "\n" .. S("One waypoint can be pinned at a time; it is listed first.")) .. "]"
	fs[#fs + 1] = button_pair(x, base + 4.85, w,
		sharp_map.can_teleport(player) and { "teleport", S("Teleport") } or nil, { "delete", S("Delete") })
	return table.concat(fs)
end

local function category_panel(ctx, cats, x, w, base)
	local cat = cats[index_of(cats, ctx.catref)]
	local color_names = {}
	for i, c in ipairs(sharp_map.COLORS) do
		color_names[i] = F(c[1])
	end
	local color_idx = ctx.color or palette_index(cat.color)
	local icon = ctx.icon or cat.icon
	local fs = { label(x, base, S("Category")) }
	if cat.name == "" then
		-- General keeps its name; only its look can change.
		fs[#fs + 1] = label(x, base + 0.55, S("General") .. "  " .. S("(new waypoints go here)"))
	else
		fs[#fs + 1] = ("field[%s,%s;%s,0.7;cat_name;;%s]"):format(x, base + 0.2, w,
			F(ctx.cat_name or cat.name))
		fs[#fs + 1] = "field_close_on_enter[cat_name;false]"
	end
	fs[#fs + 1] = ("dropdown[%s,%s;%s,0.7;color;%s;%d;true]"):format(x, base + 1.05, w,
		table.concat(color_names, ","), color_idx)
	fs[#fs + 1] = icon_picker(x, base + 1.95, icon, sharp_map.COLORS[color_idx][2],
		ctx.icon_scroll or scroll_to_icon(icon))
	fs[#fs + 1] = button_pair(x, base + 3.35, w, { "cat_save", S("Save changes") },
		cat.name ~= "" and { "cat_delete", S("Delete category") } or nil)
	fs[#fs + 1] = "tooltip[cat_delete;" .. F(S("Its waypoints are kept: they move to General.")) .. "]"
	fs[#fs + 1] = ("button[%s,%s;%s,0.65;cat_toggle;%s]"):format(x, base + 4.1, w,
		F(cat.collapsed and S("Expand") or S("Collapse")))
	fs[#fs + 1] = label(x, base + 5.05, S("The arrows beside the list move it."))
	return table.concat(fs)
end

local function sidebar(player, ctx, list, dim)
	local cats = sharp_map.get_categories(player)
	if ctx.wp and not index_of(list, ctx.wp) then
		ctx.wp = nil
	end
	if ctx.catref and not index_of(cats, ctx.catref) then
		ctx.catref = nil
	end
	-- Rows are kept (as references) to read the player's clicks against
	-- exactly the list they were shown.
	local rows = sharp_map.list_rows(player)
	local items, selected = {}, 0
	local icons = { index = {} }
	ctx.rows = {}
	for r, row in ipairs(rows) do
		items[r] = table.concat(list_cells(row, list, cats, dim, icons), ",")
		local ref = row.kind == "cat" and cats[row.index] or list[row.index]
		ctx.rows[r] = { kind = row.kind, ref = ref }
		if ref == ctx.wp or ref == ctx.catref then
			selected = r
		end
	end
	-- The sidebar runs from the top of the map to the bottom of the bar.
	-- Its lower part has a fixed height; the waypoint list takes the rest.
	local x, w = SIDE_X, SIDE_W
	local top, base = MAP_Y, round3(BAR_Y + BAR_H - SIDE_FIXED)
	local list_y = round3(top + 0.65)
	local fs = {
		label(x, top + 0.25, S("Waypoints")),
		("button[%s,%s;1.9,0.5;new_cat;%s]"):format(round3(x + w - 1.9), top, F(S("+ Category"))),
		"tooltip[new_cat;" .. F(S("Add a category. Select it in the list to rename it.")) .. "]",
	}
	local image_opts = { "0=blank.png" }
	for i, tex in ipairs(icons) do
		image_opts[#image_opts + 1] = i .. "=" .. F(tex)
	end
	fs[#fs + 1] = TABLE_STYLE
	fs[#fs + 1] = "tablecolumns[indent,width=1;image,align=center,width=1.3," .. table.concat(image_opts, ",")
		.. ";color,span=1;text]"
	fs[#fs + 1] = ("table[%s,%s;%s,%s;list;%s;%d]"):format(x, list_y, round3(w - 0.7),
		math.max(1.3, round3(base - 0.35 - list_y)), table.concat(items, ","), selected)
	local sel = ctx.wp and list[index_of(list, ctx.wp)]
	if (sel and not sel.pinned) or ctx.catref then
		fs[#fs + 1] = "style[move_up,move_down;bgimg=mcl_inventory_button9.png;"
			.. "bgimg_hovered=mcl_inventory_button9.png;bgimg_pressed=mcl_inventory_button9_pressed.png;"
			.. "bgimg_middle=2,2;border=false]"
		fs[#fs + 1] = ("image_button[%s,%s;0.6,0.6;sharp_map_arrow_n.png;move_up;]"):format(
			round3(x + w - 0.6), list_y)
		fs[#fs + 1] = ("image_button[%s,%s;0.6,0.6;sharp_map_arrow_s.png;move_down;]"):format(
			round3(x + w - 0.6), round3(list_y + 0.7))
		fs[#fs + 1] = "tooltip[move_up;" .. F(S("Move up")) .. "]tooltip[move_down;" .. F(S("Move down")) .. "]"
	end
	if ctx.catref then
		fs[#fs + 1] = category_panel(ctx, cats, x, w, base)
	else
		fs[#fs + 1] = waypoint_panel(player, ctx, list, cats, x, w, base)
	end
	return table.concat(fs)
end

-- Pan arrows on the four edges of the map. They use Mineclonia's button
-- look (which Sharp Inventory's theme turns dark), with the mod's arrows.
local ARROWS = {
	{ "pan_n", "n", S("Pan north") },
	{ "pan_s", "s", S("Pan south") },
	{ "pan_w", "w", S("Pan west") },
	{ "pan_e", "e", S("Pan east") },
}

local function edge_arrows()
	local size = ARROW_SIZE
	local at = {}
	for k, spot in pairs(arrow_spots()) do
		at[k] = { MAP_X + spot[1], MAP_Y + spot[2] }
	end
	local fs = {
		"style[pan_n,pan_s,pan_w,pan_e;bgimg=mcl_inventory_button9.png;",
		"bgimg_hovered=mcl_inventory_button9.png;bgimg_pressed=mcl_inventory_button9_pressed.png;",
		"bgimg_middle=2,2;border=false]",
	}
	for _, a in ipairs(ARROWS) do
		local pos = at[a[1]]
		fs[#fs + 1] = ("image_button[%s,%s;%s,%s;sharp_map_arrow_%s.png;%s;]tooltip[%s;%s]"):format(
			round3(pos[1]), round3(pos[2]), size, size, a[2], a[1], a[1], F(a[3]))
	end
	return table.concat(fs)
end

-- Bottom bar: zoom (- [scale] +), Back to me, the map center, and the
-- minimap selector at the right end, under the map's right edge.
local function controls(player, ctx)
	local y, x = BAR_Y, MAP_X
	local mid = y + BAR_H / 2
	local fs = {
		("button[%s,%s;0.75,0.75;zoom_out;-]"):format(x, y),
		("box[%s,%s;2.7,0.75;#00000040]"):format(x + 0.85, y),
		label(x + 1.0, mid, S("1 square = @1 nodes", ZOOMS[ctx.zoom])),
		("button[%s,%s;0.75,0.75;zoom_in;+]"):format(x + 3.65, y),
		("button[%s,%s;2.6,0.75;me;%s]"):format(x + 4.65, y, F(S("Back to me"))),
		label(x + 7.5, mid, S("Center X @1, Z @2", ctx.cx, ctx.cz)),
		"tooltip[zoom_out;", F(S("Zoom out")), "]tooltip[zoom_in;", F(S("Zoom in")), "]",
		"tooltip[me;", F(S("Center the map on you again")), "]",
	}
	if sharp_map.set_minimap_mode then
		-- The choice is remembered for the next session.
		local items, selected = {}, 1
		local current = sharp_map.get_minimap_mode(player)
		for i, mode in ipairs(sharp_map.MINIMAP_MODES) do
			items[i] = F(S("Minimap: @1", sharp_map.minimap_mode_name(mode)))
			if mode == current then
				selected = i
			end
		end
		fs[#fs + 1] = ("dropdown[%s,%s;2.8,0.75;minimap;%s;%d;true]"):format(
			round3(x + MAP_W - 2.8), y, table.concat(items, ","), selected)
	end
	return table.concat(fs)
end

local function build(player, ctx, view, layers)
	local list = sharp_map.get_waypoints(player)
	local pos = player:get_pos()
	return table.concat({
		"formspec_version[4]",
		("size[%g,%g]"):format(FORM_W, FORM_H),
		FULLSCREEN and "padding[0,0]" or "",
		-- The map's hover buttons and the icon picker are this screen's
		-- only image_buttons; give them no frame, whatever style the game
		-- or theme sets.
		"style_type[image_button;bgimg=blank.png;bgimg_hovered=blank.png;",
		"bgimg_pressed=blank.png;border=false]",
		("box[%s,%s;%s,%s;#1A1A1A]"):format(MAP_X, MAP_Y, MAP_W, MAP_H),
		map_image(view, layers),
		hover_grid(view, list, ctx.dim, floor(pos.y + 0.5)),
		edge_arrows(),
		layer_controls(ctx, ctx.band),
		-- Markers last, so they are drawn on top of everything on the map:
		-- an edge arrow must never hide the player or a waypoint.
		waypoint_markers(view, list, ctx.dim, index_of(list, ctx.wp)),
		player_marker(view, player),
		controls(player, ctx),
		sidebar(player, ctx, list, ctx.dim),
		-- Bottom-left corner of the map, clear of the edge arrows.
		(ctx.missing or 0) > 0 and (("box[%s,%s;4.4,0.6;#000000A0]"):format(MAP_X, round3(MAP_Y + MAP_H - 0.6))
			.. label(MAP_X + 0.15, round3(MAP_Y + MAP_H - 0.3), S("Drawing the map... @1 left", ctx.missing))) or "",
	})
end

------------------------------------------------------------------------
-- Showing and refreshing
------------------------------------------------------------------------

function sharp_map.show_gui(name)
	local player = core.get_player_by_name(name)
	if not player then
		return
	end
	local ctx = contexts[name]
	if not ctx then
		ctx = { zoom = DEFAULT_ZOOM, follow = true, token = 0 }
		contexts[name] = ctx
	end
	-- The layout is fixed when the screen is drawn, so clicks are read
	-- against the grid the player actually sees.
	ctx.layout = compute_layout(name)
	use_layout(ctx.layout)
	local pos = player:get_pos()
	ctx.dim = sharp_map.dimension_of(pos)
	if ctx.follow then
		ctx.cx, ctx.cz = floor(pos.x + 0.5), floor(pos.z + 0.5)
	end
	ctx.token = ctx.token + 1
	local token = ctx.token
	local view = view_of(ctx)
	ctx.band = shown_band(player, ctx)
	-- Send any tiles the player does not have yet, then show the screen.
	local tx1, tx2, tz1, tz2 = sharp_map.tile_range(view.x0, view.z1, view.w, view.h)
	-- Pictures still being drawn show up when they are ready: the screen is
	-- shown again then (only for ground with no picture at all, so a map
	-- left open near a player who is exploring is not redrawn on its own).
	-- A cave layer needs three maps (1.3.0); the screen is shown once all
	-- of them have been sent.
	local list = layer_list(ctx.dim, ctx.band)
	local layers, left, missing = {}, #list, 0
	local function more()
		if core.get_player_by_name(name) and contexts[name] == ctx and ctx.token == token then
			sharp_map.show_gui(name)
		end
	end
	for i, l in ipairs(list) do
		sharp_map.prepare_tiles(name, l.mid, tx1, tx2, tz1, tz2,
			function(textures, n_missing)
				layers[i] = { textures = textures, multiply = l.multiply }
				missing = missing + n_missing
				left = left - 1
				if left > 0 then
					return
				end
				local p = core.get_player_by_name(name)
				if p and contexts[name] == ctx and ctx.token == token then
					use_layout(ctx.layout)
					ctx.missing = missing
					core.show_formspec(name, FORMNAME, build(p, ctx, view, layers))
				end
			end, more)
	end
end

------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------

local function read_color(fields)
	local i = tonumber(fields.color)
	if i and sharp_map.COLORS[i] then
		return floor(i)
	end
end

local function clicked_cell(fields)
	for key in pairs(fields) do
		local i, j = tostring(key):match("^c(%d+)_(%d+)$")
		i, j = tonumber(i), tonumber(j)
		if i and j and i < MAP_W and j < MAP_H and not under_arrow(i, j) then
			return i, j
		end
	end
end

local PAN = { pan_w = { -1, 0 }, pan_e = { 1, 0 }, pan_n = { 0, 1 }, pan_s = { 0, -1 } }

-- Map controls. Returns true if the view changed.
local function handle_view(ctx, fields, player)
	local npu = ZOOMS[ctx.zoom]
	for key, dir in pairs(PAN) do
		if fields[key] then
			ctx.follow = false
			ctx.cx = clamp(ctx.cx + dir[1] * floor(MAP_W / 2) * npu)
			ctx.cz = clamp(ctx.cz + dir[2] * floor(MAP_H / 2) * npu)
			return true
		end
	end
	if fields.zoom_in or fields.zoom_out then
		ctx.zoom = math.max(1, math.min(#ZOOMS, ctx.zoom + (fields.zoom_in and -1 or 1)))
		return true
	end
	if fields.me then
		ctx.follow = true
		return true
	end
	if cfg.caves and fields.layer_auto then
		ctx.layer = nil
		return true
	end
	if cfg.caves and (fields.layer_up or fields.layer_down or fields.layer) then
		if fields.layer then
			-- Auto <-> surface.
			ctx.layer = ctx.layer == nil and "surface" or nil
			return true
		end
		local band = player and shown_band(player, ctx)
		if not band then
			-- From the surface down: the band just under the player's feet.
			local y = player and player:get_pos().y or 0
			band = floor((y + 0.5) / BAND) + (fields.layer_down and -1 or 0)
		else
			band = band + (fields.layer_up and 1 or -1)
		end
		local lo, hi = band_range(ctx.dim)
		ctx.layer = math.max(lo, math.min(hi, band))
		return true
	end
	local i, j = clicked_cell(fields)
	if i then
		local view = view_of(ctx)
		ctx.follow = false
		ctx.cx = clamp(view.x0 + floor((i + 0.5) * npu))
		ctx.cz = clamp(view.z1 - floor((j + 0.5) * npu))
		return true
	end
	return false
end

local ACTIONS = { "add", "save", "mode", "pin", "delete", "teleport", "new_cat", "move_up", "move_down",
	"cat_save", "cat_delete", "cat_toggle" }

-- A click in the waypoint list: select (and center on) a waypoint, select
-- a category, or fold a category on a double click.
local function handle_list(player, ctx, event)
	local row = ctx.rows and ctx.rows[event.index]
	if not row then
		return
	end
	ctx.name, ctx.color, ctx.icon, ctx.cat_pick, ctx.cat_name = nil, nil, nil, nil, nil
	ctx.icon_scroll = nil -- scroll the icon picker to the selection's icon
	if row.kind == "cat" then
		local ci = index_of(sharp_map.get_categories(player), row.ref)
		if not ci then
			return
		end
		if event.type == "DCL" then
			sharp_map.toggle_category(player, ci)
		end
		ctx.wp, ctx.catref = nil, row.ref
		return
	end
	if not index_of(sharp_map.get_waypoints(player), row.ref) then
		return
	end
	ctx.wp, ctx.catref = row.ref, nil
	if same_dim(row.ref, ctx.dim) then
		-- Center on it so the player sees where it leads.
		ctx.follow = false
		ctx.cx, ctx.cz = clamp(row.ref.pos.x), clamp(row.ref.pos.z)
	end
end

-- The sidebar's buttons.
local function handle_action(player, ctx, action, fields)
	local name = player:get_player_name()
	local list = sharp_map.get_waypoints(player)
	local cats = sharp_map.get_categories(player)
	local color = ctx.color and sharp_map.COLORS[ctx.color][2]
	local sel = index_of(list, ctx.wp)
	local ci = index_of(cats, ctx.catref)

	if action == "new_cat" then
		local index, err = sharp_map.add_category(player)
		if index then
			ctx.wp, ctx.catref, ctx.cat_name = nil, cats[index], nil
		else
			core.chat_send_player(name, err)
		end
	elseif action == "add" then
		local cat = ctx.cat_pick or (ctx.last_cat and index_of(cats, ctx.last_cat) and ctx.last_cat.name)
		local index, err = sharp_map.add_waypoint(player, fields.name, color, ctx.icon, cat)
		if index then
			list = sharp_map.get_waypoints(player)
			ctx.wp, ctx.catref = list[index], nil
			ctx.last_cat = cats[sharp_map.category_index(cats, list[index].cat)]
			ctx.name, ctx.color, ctx.icon, ctx.cat_pick = nil, nil, nil, nil
		else
			core.chat_send_player(name, err)
		end
	elseif action == "move_up" or action == "move_down" then
		local delta = action == "move_up" and -1 or 1
		if sel then
			sharp_map.move_waypoint(player, sel, delta)
			ctx.cat_pick = nil -- show the category it is in now
		elseif ci then
			sharp_map.move_category(player, ci, delta)
		end
	elseif ci then
		if action == "cat_save" then
			local ok, err = sharp_map.update_category(player, ci, fields.cat_name, color, ctx.icon)
			if err then
				core.chat_send_player(name, err)
			elseif ok then
				ctx.cat_name, ctx.color, ctx.icon = nil, nil, nil
			end
		elseif action == "cat_delete" then
			sharp_map.remove_category(player, ci)
			ctx.catref, ctx.cat_name = nil, nil
		elseif action == "cat_toggle" then
			sharp_map.toggle_category(player, ci)
		end
	elseif not sel then
		return true
	elseif action == "save" then
		sharp_map.update_waypoint(player, sel, fields.name, color, ctx.icon, ctx.cat_pick)
		ctx.name, ctx.color, ctx.icon, ctx.cat_pick = nil, nil, nil, nil
	elseif action == "mode" then
		sharp_map.cycle_label_mode(player, sel)
	elseif action == "pin" then
		sharp_map.toggle_pin(player, sel)
	elseif action == "delete" then
		sharp_map.remove_waypoint(player, sel)
		ctx.wp, ctx.name, ctx.color, ctx.icon, ctx.cat_pick = nil, nil, nil, nil, nil
	elseif action == "teleport" then
		if sharp_map.teleport(player, sel) then
			contexts[name] = nil
			core.close_formspec(name, FORMNAME)
			return true
		end
		core.chat_send_player(name, S("You are not allowed to teleport."))
	end
	sharp_map.show_gui(name)
	return true
end

local function handle_fields(player, formname, fields)
	local name = player:get_player_name()

	-- Map button in the survival inventory (Sharp Inventory layout).
	if formname == "" and fields[OPEN_FIELD] then
		contexts[name] = nil
		sharp_map.show_gui(name)
		return true
	end

	if formname ~= FORMNAME then
		return false
	end
	if cfg.debug then
		local keys = {}
		for k, v in pairs(fields) do
			keys[#keys + 1] = tostring(k) .. "=" .. tostring(v):sub(1, 30)
		end
		table.sort(keys)
		core.log("action", "[sharp_map] " .. name .. " map screen: " .. table.concat(keys, " "))
	end
	local ctx = contexts[name]
	if not ctx then
		return true -- Not opened this session; ignore.
	end
	if fields.quit then
		contexts[name] = nil
		return true
	end
	use_layout(ctx.layout)

	-- Remember where the icon picker is scrolled, so a redraw keeps it.
	if type(fields.icon_scroll) == "string" then
		local ev = core.explode_scrollbar_event(fields.icon_scroll)
		if ev and (ev.type == "CHG" or ev.type == "VAL") and tonumber(ev.value) then
			ctx.icon_scroll = math.max(0, math.min(icon_scroll_max(), floor(ev.value)))
		end
	end

	-- Remember unsaved edits so a redraw keeps them.
	ctx.color = read_color(fields) or ctx.color
	local cats = sharp_map.get_categories(player)
	local ci = tonumber(fields.cat)
	if ci and cats[floor(ci)] then
		ctx.cat_pick = cats[floor(ci)].name
	end
	if type(fields.name) == "string" then
		ctx.name = fields.name:sub(1, 200)
	end
	if type(fields.cat_name) == "string" then
		ctx.cat_name = fields.cat_name:sub(1, 200)
	end

	if handle_view(ctx, fields, player) then
		sharp_map.show_gui(name)
		return true
	end

	-- The minimap dropdown's value comes with every submission; act only
	-- when it differs from the remembered mode.
	local mm = tonumber(fields.minimap)
	local mode = mm and sharp_map.MINIMAP_MODES and sharp_map.MINIMAP_MODES[mm]
	if mode and sharp_map.set_minimap_mode and mode ~= sharp_map.get_minimap_mode(player) then
		local ok, err = sharp_map.set_minimap_mode(player, mode, true)
		if not ok then
			core.chat_send_player(name, err)
			sharp_map.show_gui(name) -- puts the selector back
			return true
		end
	end

	for key in pairs(fields) do
		local icon = tostring(key):match("^icon_([%w_]+)$")
		if icon and sharp_map.is_icon[icon] then
			ctx.icon = icon
			sharp_map.show_gui(name)
			return true
		end
	end

	local action
	for _, key in ipairs(ACTIONS) do
		if fields[key] then
			action = key
			break
		end
	end
	if action then
		return handle_action(player, ctx, action, fields)
	end

	-- No button: a list selection, or only a dropdown or name changed (the
	-- client keeps those; no redraw needed). Buttons are checked first in
	-- case the list's state arrives along with a button press.
	local event = fields.list and core.explode_table_event(fields.list)
	if event and (event.type == "CHG" or event.type == "DCL") then
		event.index = event.row
		handle_list(player, ctx, event)
		sharp_map.show_gui(name)
	end
	return true
end

-- Errors in the map screen are logged with where they happened, and the
-- screen is drawn again, instead of taking the game down; a player sees a
-- short message. (Added in 1.2.0 to track down reports of the map closing.)
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME and formname ~= "" then
		return false
	end
	local u0 = core.get_us_time()
	local ok, result = xpcall(handle_fields, debug.traceback, player, formname, fields)
	sharp_map.slow("map screen click", u0, formname)
	if ok then
		return result
	end
	local name = player:get_player_name()
	core.log("error", "[sharp_map] map screen error for " .. name .. ": " .. tostring(result))
	core.chat_send_player(name, S("Sharp Map hit an error; it is in debug.txt. Please report it."))
	contexts[name] = nil
	return true
end)

core.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)

-- /map always starts a fresh view centered on the player.
function sharp_map.open_map(name)
	contexts[name] = nil
	sharp_map.show_gui(name)
end

------------------------------------------------------------------------
-- Map button in the survival inventory, only with Sharp Inventory.
------------------------------------------------------------------------
-- Sharp Inventory moves the survival screen's buttons into a column and
-- puts its two sort buttons on the row at y 4.075 (x 9.075 and 10.325).
-- The map button takes the next free spot to their left. It is added only
-- when that layout is really there (the "sort now" button is present), so
-- the vanilla screen and Sharp Inventory without this mod are untouched.

if not core.get_modpath("sharp_inventory") or not core.global_exists("sharp_inventory")
		or type(sharp_inventory.button) ~= "function" then
	return
end

local main_tab
if core.global_exists("mcl_inventory")
		and type(mcl_inventory.registered_survival_inventory_tabs) == "table" then
	for _, def in ipairs(mcl_inventory.registered_survival_inventory_tabs) do
		if def.id == "main" then
			main_tab = def
		end
	end
end
if not main_tab or type(main_tab.build) ~= "function" then
	return
end

local MAP_BUTTON_X, MAP_BUTTON_Y, MAP_BUTTON_SIZE = 7.825, 4.075, 1.1
local SORT_MARKER = sharp_inventory.SORT_INV_FIELD or "sharp_inventory_sort_inv"

-- sharp_inventory is loaded first (optional_depends), so this wraps its
-- already-wrapped build function.
local orig_build = main_tab.build
main_tab.build = function(player)
	local formspec = orig_build(player)
	if type(formspec) ~= "string" or not formspec:find(SORT_MARKER, 1, true) then
		return formspec
	end
	return formspec .. sharp_inventory.button(MAP_BUTTON_X, MAP_BUTTON_Y, MAP_BUTTON_SIZE,
		"mcl_maps_map_filled.png", OPEN_FIELD, S("Map"))
end
