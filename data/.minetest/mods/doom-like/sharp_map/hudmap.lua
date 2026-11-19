-- A minimap drawn from the saved map, in a map frame in the top-right
-- corner (sharp_map.minimap_source = "map", the default).
--
-- Why it is built this way (Luanti keeps every texture a client has
-- received or generated until the session ends; mods cannot free them):
--   * The map is cut into pieces of 16x16 nodes (32x32 in the wide view,
--     at half resolution), each a 16x16 PNG made and sent once per change
--     of that ground (render.lua).
--   * A fixed 9x9 grid of HUD images shows the pieces around the player.
--     Walking only changes HUD offsets; crossing a piece edge changes the
--     texture of one row or column (a grid slot is reused by the piece
--     that moves into it). No texture is ever generated per movement.
--   * HUD images cannot be clipped, so the pieces along the window's edges
--     are cropped to it, the way Luanti masks its own minimap: each edge
--     piece shows only the part inside the window, in steps of 4 map
--     pixels ("[combine" with negative offsets). The slim frame, the same
--     on all four sides, hides the less-than-4-pixel remainder. It is dark
--     when Sharp Inventory's dark theme is on, Mineclonia's light gray
--     otherwise, and sits flush in the top-right corner.
--     Cost: each crop of a piece is a tiny texture the client keeps until
--     the session ends (about 4.5 per node of new ground walked, under 1 KB
--     each); walking over ground already seen reuses them.
--   * Underground the pieces come from the cave layers (1.3.0): the
--     band the player is in, then the band below, the band above and the
--     one below that, over a dimmed surface (render.lua, view_layers), so
--     the passages around the player show whichever way they lead.
--   * The player is an arrow in the center that turns with the player
--     (1.2.0). It is a HUD element of type "compass": the client itself
--     turns it to the camera's heading every frame, the way Luanti's own
--     minimap turns its arrow, so it costs no server work and no network
--     traffic at all. (An arrow made by the server would need a new
--     texture or a HUD change for every turn.) sharp_map.player_arrow =
--     false brings back the figure that never turns.
--
-- Cost: every sharp_map.minimap_update seconds (0.1) for each player with
-- the minimap on, up to 81 HUD offset changes if they moved, plus texture
-- and size changes of the edge pieces whose crop changed. Pieces are drawn
-- through render.lua's piece queue (1.4.1): a few per server step within
-- sharp_map.minimap_budget, nearest first, keeping the old picture up
-- meanwhile, so entering a cave or another layer never stalls the server
-- (it redrew all 81 pieces in one step before, up to 551 ms).

local cfg = sharp_map.settings

if not cfg.minimap or cfg.minimap_source ~= "map" then
	return
end

local floor, abs = math.floor, math.abs
local GRID = 9            -- pieces per side (8 visible + 1 sliding)
local FRAME, HOLE = 140, 128 -- frame textures: 6 px border on every side
local PIECE_PX = 16       -- pixels per piece texture
local CROP_STEP = 4       -- edge pieces are cropped in steps of this many map pixels
local REFRESH = 1         -- seconds between checks for changed pieces

-- Match Sharp Inventory's dark theme when it is installed and on.
local FRAME_TEXTURE = "sharp_map_minimap_frame_light.png"
if core.global_exists("sharp_inventory") and type(sharp_inventory.settings) == "table"
		and sharp_inventory.settings.theme then
	FRAME_TEXTURE = "sharp_map_minimap_frame_dark.png"
end
local EPS = 0.25          -- skip offset changes smaller than this (pixels)


local ARROW = "sharp_map_player_arrow.png"
local ARROW_DIRECTION = cfg.arrow_reverse and 1 or 0

-- Screen geometry for one player, in screen pixels unless named "units".
local function geometry(name)
	local info = type(core.get_player_window_information) == "function"
		and core.get_player_window_information(name)
	local sx, sy, hs = 1920, 1080, 1
	if type(info) == "table" and type(info.size) == "table"
			and tonumber(info.size.x) and tonumber(info.size.y) and info.size.x > 0 and info.size.y > 0 then
		sx, sy = info.size.x, info.size.y
		hs = tonumber(info.real_hud_scaling) or 1
		if hs <= 0 then
			hs = 1
		end
	end
	local short = math.min(sx, sy)
	-- The window is 8 pieces wide. Each map pixel gets a whole number of
	-- screen pixels (1.2.0), so every node is drawn the same size and the
	-- map stays sharp instead of mixing 2- and 3-pixel nodes; the window
	-- is the nearest such size to minimap_screen_percent.
	local per_px = math.max(1, floor(short * cfg.minimap_screen_percent / 100 / (8 * PIECE_PX) + 0.5))
	local piece = per_px * PIECE_PX
	local window = piece * 8
	local frame = window * FRAME / HOLE
	local g = {
		sx = sx, sy = sy, hs = hs,
		piece = piece, window = window, frame = frame,
		icon = math.max(12, floor(window * 0.09 + 0.5)),
		sig = sx .. "x" .. sy .. "@" .. hs,
	}
	-- Center of the window, in HUD units from the top-right screen corner
	-- (the frame sits flush in the corner, the window inside it).
	g.center = { x = -(frame / 2) / hs, y = (frame / 2) / hs }
	return g
end

-- Image scale for a square of PX screen pixels (negative = percent).
local function px_scale(g, px)
	return { x = -(px / g.sx * 100), y = -(px / g.sy * 100) }
end

local state = {} -- player name -> minimap state

local function piece_nodes(mode)
	return mode == "wide" and 32 or 16
end

local function add(player, def)
	def.type = "image"
	def.position = { x = 1, y = 0 }
	return player:hud_add(def)
end

local function remove_all(player, st)
	for _, id in ipairs(st.ids) do
		player:hud_remove(id)
	end
	for _, slot in pairs(st.slots) do
		player:hud_remove(slot.id)
		-- A piece still on its way must not touch this id: Luanti reuses
		-- HUD ids, so it could belong to another element by then.
		slot.dead = true
	end
	for _, w in ipairs(st.wps) do
		player:hud_remove(w.id)
	end
	st.ids, st.slots, st.wps, st.sendq, st.batches = {}, {}, {}, {}, {}
end

-- Show SLOT's current text: its piece, cropped to the window, or nothing.
local function apply(player, st, slot)
	local text = "blank.png"
	if slot.base and slot.w > 0 and slot.h > 0 then
		if slot.cl == 0 and slot.ct == 0 and slot.w == PIECE_PX and slot.h == PIECE_PX then
			text = slot.base
		else
			text = ("[combine:%dx%d:%d,%d=%s"):format(slot.w, slot.h, -slot.cl, -slot.ct, slot.base)
		end
	end
	if text ~= slot.shown then
		slot.shown = text
		player:hud_change(slot.id, "text", text)
	end
end

-- Updates come in batches (1.4.3), so the minimap changes the way it did
-- before 1.4.1: all at once, crisp, never piece by piece. The work behind
-- a batch (drawing pieces, render.lua's queue; sending them, below) is
-- spread over server steps, but nothing of a batch is shown until every
-- piece in it is drawn and has reached the player; then the whole batch
-- is shown in one step. A batch is: everything when the minimap starts;
-- every piece when the view changes (cave layer, cave or surface), which
-- keeps the old view up until the new one is complete (no in-between
-- pictures); the pieces that come into the window as you walk; and the
-- pieces whose ground changed, gathered once a second near you and every
-- CALM seconds farther out (background cave mapping, flowing water...).
-- A piece taken over by a newer batch counts as done in the older one.

local SEND_PER_STEP = 4   -- pictures sent to one player per server step
local CALM = 4            -- seconds between updates of changed far pieces
local GIVE_UP = 10        -- seconds before a stuck batch shows what it has
local now = 0             -- seconds since the server started

local function apply_batch(player, st, b)
	for _, it in ipairs(b.items) do
		local slot = it.slot
		if not slot.dead and slot.item == it and it.done_ok then
			slot.want = it.texture
			slot.base = it.texture or nil
			apply(player, st, slot)
		end
		if slot.item == it then
			slot.item = nil
		end
	end
	st.batches[b] = nil
end

-- Item IT has its picture (OK: drawn and sent, or known to be empty).
local function item_done(player, st, it, ok)
	if it.done then
		return
	end
	it.done, it.done_ok = true, ok ~= false
	local b = it.batch
	b.left = b.left - 1
	if b.left == 0 then
		apply_batch(player, st, b)
	end
end

-- The picture of IT is known: send it if the player does not have it yet.
local function item_texture(player, st, it, texture)
	if it.done then
		return
	end
	it.texture = texture
	local name = player:get_player_name()
	if not texture or sharp_map.media_sent(name, texture) then
		item_done(player, st, it, true)
		return
	end
	local q = st.sendq[texture]
	if not q then
		q = { prio = it.prio, items = {} }
		st.sendq[texture] = q
	elseif it.prio < q.prio then
		q.prio = it.prio
	end
	q.items[#q.items + 1] = it
end

-- Send up to SEND_PER_STEP waiting pictures, most urgent first.
local function send_some(player, st)
	local name = player:get_player_name()
	for _ = 1, SEND_PER_STEP do
		local best, best_q
		for texture, q in pairs(st.sendq) do
			if not best or q.prio < best_q.prio then
				best, best_q = texture, q
			end
		end
		if not best then
			return
		end
		st.sendq[best] = nil
		sharp_map.ensure_media(name, best, function(ok)
			local p = core.get_player_by_name(name)
			if p and state[name] == st then
				for _, it in ipairs(best_q.items) do
					item_done(p, st, it, ok)
				end
			end
		end)
	end
end

-- A new batch, held open (one extra count) while it is being filled, so a
-- piece that is ready at once cannot show it before the rest is in.
local function new_batch(st)
	local b = { items = {}, left = 1, born = now }
	st.batches[b] = true
	return b
end

local function release(player, st, b)
	if b then
		b.left = b.left - 1
		if b.left == 0 then
			apply_batch(player, st, b)
		end
	end
end

-- Put SLOT (now showing ground CX, CZ in its view) into batch B. KEEP:
-- it shows the same ground already (another view, or changed ground), so
-- its picture stays up until the batch is shown; otherwise the old picture
-- (other ground) is taken down now.
local function add_item(player, st, b, slot, keep, prio)
	if slot.item and not slot.item.done then
		item_done(player, st, slot.item, false) -- taken over: done there
	end
	local it = { batch = b, slot = slot, prio = prio }
	slot.item = it
	b.items[#b.items + 1] = it
	b.left = b.left + 1
	if not keep then
		slot.want, slot.base = nil, nil
		apply(player, st, slot)
	end
	local view, cx, cz = slot.dim, slot.cx, slot.cz
	local token = view .. "|" .. cx .. "," .. cz
	local cb
	if slot.waiting ~= token then
		local name = player:get_player_name()
		cb = function(texture)
			if slot.waiting == token then
				slot.waiting = nil
			end
			local cur = slot.item
			local p = core.get_player_by_name(name)
			if p and cur and cur.token == token and cur.texture == nil and state[name] == st then
				item_texture(p, st, cur, texture)
			end
		end
	end
	it.token = token
	-- Up to date: nothing is queued, and CB never runs.
	local texture, fresh = sharp_map.piece_request(view, st.size, cx, cz, prio, cb)
	if fresh then
		item_texture(player, st, it, texture)
	else
		slot.waiting = token
	end
end

-- Keep the queue entry of a slot still waiting for its piece alive.
local function keep_alive(st, slot, prio)
	if slot.item and slot.item.texture == nil then
		sharp_map.piece_request(slot.dim, st.size, slot.cx, slot.cz, prio)
	end
end

-- Show what a batch stuck for GIVE_UP seconds has (a piece that never
-- comes, e.g. a send that failed); the rest comes with later checks.
local function unstick(player, st)
	for b in pairs(st.batches) do
		if now - b.born > GIVE_UP then
			for _, it in ipairs(b.items) do
				if not it.done then
					it.done, it.done_ok = true, false
				end
			end
			apply_batch(player, st, b)
		end
	end
end

-- Waypoint icons on the minimap (rebuilt when the waypoints change).
local function rebuild_waypoints(player, st)
	for _, w in ipairs(st.wps) do
		player:hud_remove(w.id)
	end
	st.wps = {}
	for _, wp in ipairs(sharp_map.get_waypoints(player)) do
		if wp.shown then
			st.wps[#st.wps + 1] = {
				wp = wp,
				id = add(player, {
					text = "blank.png",
					scale = px_scale(st.g, st.g.icon),
					alignment = { x = 0, y = 0 },
					offset = st.g.center,
					z_index = 3,
				}),
			}
		end
	end
	st.wp_dirty = true
end

-- CHECK_PIECES: look for changed ground (once a second); FAR: also far
-- from the middle (every CALM seconds).
local function update(player, st, check_pieces, far)
	local g = st.g
	local pos = player:get_pos()
	local dim = sharp_map.dimension_of(pos)
	-- What the pieces show: the surface, or underground the cave view
	-- around the band of the player's feet (1.3.0). Slots remember it as
	-- their "dim", so switching views loads every piece of the new view.
	local band = sharp_map.cave_band(player)
	local view = band and sharp_map.view_id(dim, band) or dim
	local size = st.size
	local u = g.piece / size / g.hs -- HUD units per node
	local half = 4 * size           -- half the window, in nodes
	local eps = EPS / g.hs
	local cx0, cz0 = floor((pos.x - half) / size), floor((pos.z - half) / size)
	local pcx, pcz = floor(pos.x / size), floor(pos.z / size)

	-- Window edges in node coordinates (a node spans x - 0.5 .. x + 0.5).
	local wl, wr = pos.x - half, pos.x + half
	local wt, wb = pos.z + half, pos.z - half
	local npx = size / PIECE_PX -- nodes per map pixel
	local step = CROP_STEP * npx
	local function crop(over)
		return over > 0 and floor(over / step) * CROP_STEP or 0
	end

	local moved_in, switched, changed -- batches made by this update
	for i = 0, GRID - 1 do
		for j = 0, GRID - 1 do
			local cx, cz = cx0 + i, cz0 + j
			local slot = st.slots[(cx % GRID) + 1 + (cz % GRID) * GRID]
			local ring = math.max(abs(cx - pcx), abs(cz - pcz))
			if slot.cx ~= cx or slot.cz ~= cz then
				-- New ground walked into the window (or the first picture).
				slot.cx, slot.cz, slot.dim = cx, cz, view
				moved_in = moved_in or new_batch(st)
				add_item(player, st, moved_in, slot, false, ring)
			elseif slot.dim ~= view then
				-- Same ground, other view: the old view stays up until the
				-- whole new one is ready.
				slot.dim = view
				switched = switched or new_batch(st)
				add_item(player, st, switched, slot, true, ring)
			elseif check_pieces and slot.item then
				keep_alive(st, slot, ring)
			elseif check_pieces and (far or ring <= 1) then
				-- Changed ground: your own digging is near the middle and
				-- checked every second; farther out, every CALM seconds.
				local texture, fresh = sharp_map.piece_request(view, size, cx, cz, 10 + ring)
				if not fresh or texture ~= slot.want then
					changed = changed or new_batch(st)
					add_item(player, st, changed, slot, true, 10 + ring)
				end
			end
			-- Piece edges, and how many map pixels stick out past the window
			-- on each side (rounded down to the crop step).
			local pl, pt = cx * size - 0.5, cz * size + size - 0.5
			local cl, cr = crop(wl - pl), crop(pl + size - wr)
			local ct, cb = crop(pt - wt), crop(wb - (pt - size))
			local w, h = PIECE_PX - cl - cr, PIECE_PX - ct - cb
			if w ~= slot.w or h ~= slot.h or cl ~= slot.cl or ct ~= slot.ct then
				slot.w, slot.h, slot.cl, slot.ct = w, h, cl, ct
				if w > 0 and h > 0 then
					-- 1 extra screen pixel hides rounding seams between pieces.
					local px = g.piece / PIECE_PX
					player:hud_change(slot.id, "scale", {
						x = -((w * px + 1) / g.sx * 100), y = -((h * px + 1) / g.sy * 100) })
				end
				apply(player, st, slot)
			end
			local ox = g.center.x + (pl + cl * npx - pos.x) * u
			local oy = g.center.y + (pos.z - (pt - ct * npx)) * u
			if not slot.ox or abs(ox - slot.ox) >= eps or abs(oy - slot.oy) >= eps then
				slot.ox, slot.oy = ox, oy
				player:hud_change(slot.id, "offset", { x = ox, y = oy })
			end
		end
	end

	release(player, st, moved_in)
	release(player, st, switched)
	release(player, st, changed)

	-- Waypoint icons: only inside the window and in this dimension.
	local limit = (g.window / 2 - g.icon / 2) / g.hs
	for _, w in ipairs(st.wps) do
		local wp = w.wp
		local dx = (wp.pos.x - pos.x) * u
		local dy = (pos.z - wp.pos.z) * u
		local inside = abs(dx) <= limit and abs(dy) <= limit
			and (not wp.dim or not dim or wp.dim == dim)
		local text = inside and sharp_map.icon_texture(wp.icon, wp.color) or "blank.png"
		if text ~= w.text or st.wp_dirty then
			w.text = text
			player:hud_change(w.id, "text", text)
		end
		if inside and (not w.ox or abs(dx - w.ox) >= eps or abs(dy - w.oy) >= eps) then
			w.ox, w.oy = dx, dy
			player:hud_change(w.id, "offset", { x = g.center.x + dx, y = g.center.y + dy })
		end
	end
	st.wp_dirty = false
end

-- Underground, draw the cave views one layer up and one layer down ahead
-- of time (1.4.1), at the lowest priority and only while little else
-- waits, so that crossing into the next layer usually swaps every piece
-- at once from pictures already drawn. Only the pieces within PREDRAW of
-- the player; each is checked once a second (cheap when drawn already).
local PREDRAW = 3
local function predraw(player, st)
	local band = sharp_map.cave_band(player)
	if not band or sharp_map.piece_queue_size() > 8 then
		return
	end
	local pos = player:get_pos()
	local dim = sharp_map.dimension_of(pos)
	local size = st.size
	local pcx, pcz = floor(pos.x / size), floor(pos.z / size)
	for _, b in ipairs({ band - 1, band + 1 }) do
		local view = sharp_map.view_id(dim, b)
		for i = -PREDRAW, PREDRAW do
			for j = -PREDRAW, PREDRAW do
				sharp_map.piece_predraw(view, size, pcx + i, pcz + j, 20 + math.max(abs(i), abs(j)))
			end
		end
	end
end

local function is_drawn(mode)
	return mode == "normal" or mode == "wide"
end

-- The player marker in the window's center.
local function add_player_marker(player, g, center)
	if cfg.player_arrow then
		return player:hud_add({
			type = "compass",
			position = { x = 1, y = 0 },
			text = ARROW,
			size = { x = g.icon, y = g.icon },
			alignment = { x = 0, y = 0 },
			offset = center,
			direction = ARROW_DIRECTION,
			z_index = 4,
		})
	end
	return add(player, {
		text = "sharp_map_player.png",
		scale = px_scale(g, g.icon),
		alignment = { x = 0, y = 0 },
		offset = center,
		z_index = 4,
	})
end

-- Turn the minimap on in MODE ("normal" or "wide"), or off.
function sharp_map.hudmap_set_mode(player, mode)
	local name = player:get_player_name()
	local st = state[name]
	if not st then
		return
	end
	remove_all(player, st)
	st.mode = mode
	local g = geometry(name)
	st.g = g
	if not is_drawn(mode) then
		return
	end
	st.size = piece_nodes(mode)
	-- Back to front: background, pieces, frame, waypoints, player marker.
	-- The frame hangs from the top-right screen corner; the background
	-- fills the window inside it (unmapped ground is transparent in the
	-- pieces, so it must never show the world behind).
	st.ids[#st.ids + 1] = add(player, {
		text = "sharp_map_minimap_bg.png",
		scale = px_scale(g, g.window + 2),
		alignment = { x = 0, y = 0 },
		offset = g.center,
		z_index = 0,
	})
	for k = 1, GRID * GRID do
		st.slots[k] = {
			id = add(player, {
				text = "blank.png",
				scale = px_scale(g, g.piece + 1), -- 1 px overlap hides rounding seams
				alignment = { x = 1, y = 1 },
				offset = g.center,
				z_index = 1,
			}),
			shown = "blank.png",
			w = PIECE_PX, h = PIECE_PX, cl = 0, ct = 0,
		}
	end
	st.ids[#st.ids + 1] = add(player, {
		text = FRAME_TEXTURE,
		scale = px_scale(g, g.frame),
		alignment = { x = -1, y = 1 },
		offset = { x = 0, y = 0 },
		z_index = 2,
	})
	rebuild_waypoints(player, st)
	st.ids[#st.ids + 1] = add_player_marker(player, g, g.center)
	update(player, st, false)
end

function sharp_map.hudmap_waypoints_changed(player)
	local st = state[player:get_player_name()]
	if st and is_drawn(st.mode) then
		rebuild_waypoints(player, st)
		update(player, st, false)
	end
end

core.register_on_joinplayer(function(player)
	state[player:get_player_name()] = { ids = {}, slots = {}, wps = {}, sendq = {}, batches = {} }
end)

core.register_on_leaveplayer(function(player)
	state[player:get_player_name()] = nil
end)

local timer, refresh_timer, calm_timer = 0, 0, 0
core.register_globalstep(function(dtime)
	now = now + dtime
	timer = timer + dtime
	refresh_timer = refresh_timer + dtime
	calm_timer = calm_timer + dtime
	if dtime <= 0.2 then
		for _, player in ipairs(core.get_connected_players()) do
			local st = state[player:get_player_name()]
			if st and st.sendq and next(st.sendq) then
				local u0 = core.get_us_time()
				send_some(player, st)
				sharp_map.slow("minimap sends", u0, player:get_player_name())
			end
		end
	end
	if timer < cfg.minimap_update then
		return
	end
	timer = 0
	local check = refresh_timer >= REFRESH
	local far = false
	if check then
		refresh_timer = 0
		if calm_timer >= CALM then
			calm_timer, far = 0, true
		end
	end
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local st = state[name]
		if st and st.g and is_drawn(st.mode) then
			if check and geometry(name).sig ~= st.g.sig then
				-- Window resized or HUD scale changed: rebuild at the new size.
				sharp_map.hudmap_set_mode(player, st.mode)
			else
				local u0 = core.get_us_time()
				update(player, st, check, far)
				sharp_map.slow("minimap update", u0, name)
				if check then
					predraw(player, st)
					unstick(player, st)
				end
			end
		end
	end
end)
