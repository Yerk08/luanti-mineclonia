-- Redrawing maps made by an older version (1.2.0).
--
-- Ground mapped before 1.2.0 has its old shading baked into its colors and
-- no surface heights, so it cannot show the new relief until it is scanned
-- again. This redraws it in the background, a little at a time, even where
-- nobody goes:
--   * After an update that changes how maps are drawn (RENDER_VERSION), a
--     redraw of every saved tile starts by itself (setting
--     sharp_map.redraw_on_update). /map redraw all starts one by hand.
--   * One tile at a time, nearest to a player first; inside it, one 16x16
--     chunk after another (only chunks that were mapped), read again from
--     the world with the same scan as exploring, then its finished picture
--     is drawn and saved (render.lua), so opening the map later is quick.
--   * At most sharp_map.redraw_budget milliseconds per server step (at
--     least one chunk), and nothing in a step that already took over
--     0.2 s, so it backs off when the server is busy.
--   * Progress is kept in mod storage per tile, so a redraw carries on
--     after a restart where it stopped.
--
-- The height range read for a chunk comes from the ground levels the map
-- kept (since 1.1.1), starting no lower than y 176 in the overworld.
-- Overworld ground mapped before that has none: a wide band (y -48 to
-- 176) is read instead; a column whose top is not open air in sunlight
-- there (a taller mountain) keeps its old look, as do Nether and End
-- chunks without ground levels.

local S = sharp_map.S
local cfg = sharp_map.settings
local R = sharp_map.render
local TILE, CHUNK = R.TILE, R.CHUNK
local PER_SIDE = TILE / CHUNK -- chunks per tile side
local floor = math.floor

-- 1: before 1.2.0; 2: plain colors, heights, relief; 3: (1.2.3) the
-- surface needs sunlight, which also repairs surface maps that deep caves
-- had painted over, so after updating everything is read again once.
local RENDER_VERSION = 3
-- How saved pictures look: 1 = 1.2.1 (four-neighbour relief); 2 = 1.2.2
-- (eight neighbours, water depth). A newer look only needs the pictures
-- drawn again from the saved data, not the world read again.
local PICTURE_VERSION = 2
local NEAR_TILES = 2     -- /map redraw near: tiles around the player
local storage = core.get_mod_storage()

-- The job: { tiles = list of {dim, tx, tz, key}, pass = number or nil
-- (a stored pass, for a full redraw), total, done, current, chunk }.
local job

local function list_tiles()
	local out = {}
	for _, dim in ipairs(core.get_dir_list(R.root, true) or {}) do
		if dim ~= "media" then
			for _, file in ipairs(core.get_dir_list(R.root .. "/" .. dim, false) or {}) do
				local tx, tz = file:match("^(%-?%d+)_(%-?%d+)%.bin$")
				if tx then
					tx, tz = tonumber(tx), tonumber(tz)
					out[#out + 1] = { dim = dim, tx = tx, tz = tz, key = dim .. "/" .. tx .. "_" .. tz }
				end
			end
		end
	end
	return out
end

-- Start a redraw of every saved tile not yet done in the stored pass
-- (NEW_PASS: a fresh pass, so all of them).
local function start_all(new_pass)
	local pass = storage:get_int("redraw_pass")
	if new_pass then
		pass = pass + 1
		storage:set_int("redraw_pass", pass)
	end
	storage:set_int("redraw_active", 1)
	local tiles = {}
	for _, t in ipairs(list_tiles()) do
		if storage:get_int("t:" .. t.key) ~= pass then
			tiles[#tiles + 1] = t
		else
			-- Done, but its picture may not have been saved before a
			-- restart: draw it in the background if it is missing.
			local f = io.open(R.root .. "/" .. t.key .. ".png", "rb")
			if f then
				f:close()
			else
				sharp_map.request_draw(t.dim, t.tx, t.tz, 2)
			end
		end
	end
	job = { tiles = tiles, pass = pass, total = #tiles, done = 0 }
	core.log("action", "[sharp_map] redrawing " .. #tiles .. " map tiles in the background")
	return #tiles
end

-- Redraw the tiles around POS (not stored; added to any running redraw).
local function start_near(pos)
	local tx0, tz0 = floor(pos.x / TILE), floor(pos.z / TILE)
	local dim = R.safe_dim(sharp_map.dimension_of(pos))
	local list = {}
	for tx = tx0 - NEAR_TILES, tx0 + NEAR_TILES do
		for tz = tz0 - NEAR_TILES, tz0 + NEAR_TILES do
			if R.get_tile(dim, tx, tz) then
				list[#list + 1] = { dim = dim, tx = tx, tz = tz, key = dim .. "/" .. tx .. "_" .. tz, near = true }
			end
		end
	end
	if job then
		-- Ahead of the rest of the running redraw.
		for i = #list, 1, -1 do
			table.insert(job.tiles, 1, list[i])
		end
		job.total = job.total + #list
	else
		job = { tiles = list, total = #list, done = 0 }
	end
	return #list
end

-- The waiting tile nearest to a connected player, taken from the list.
local function take_nearest()
	local players = core.get_connected_players()
	if #players == 0 or #job.tiles <= 1 then
		return table.remove(job.tiles, 1)
	end
	local best, best_d
	for i, t in ipairs(job.tiles) do
		if t.near then
			best = i
			break
		end
		local cx, cz = (t.tx + 0.5) * TILE, (t.tz + 0.5) * TILE
		for _, p in ipairs(players) do
			local pos = p:get_pos()
			local d = (pos.x - cx) ^ 2 + (pos.z - cz) ^ 2
			if not best_d or d < best_d then
				best, best_d = i, d
			end
		end
	end
	return table.remove(job.tiles, best)
end

-- The y range to read for chunk (I, J) of tile T, or nil to leave it.
local function chunk_range(t, tile, i, j)
	local any = false
	local lo, hi
	for dz = 0, CHUNK - 1 do
		local ri = TILE - (j * CHUNK + dz)
		local row, grow = tile.rows[ri], tile.gnd[ri]
		for dx = 0, CHUNK - 1 do
			local px = i * CHUNK + dx
			if row:byte(px * 4 + 4) ~= 0 then
				any = true
				local a, b = grow:byte(px * 2 + 1, px * 2 + 2)
				local v = a * 256 + b
				if v ~= 0 then
					v = v - 32768
					lo = (not lo or v < lo) and v or lo
					hi = (not hi or v > hi) and v or hi
				end
			end
		end
	end
	if not any then
		return nil
	end
	if not hi then
		if t.dim == "overworld" or t.dim == "world" then
			return 176, -48
		end
		return nil
	end
	if t.dim == "nether" then
		return hi + 3, math.max(lo, hi - 60) - 4
	end
	-- Trees and buildings stand above the ground: start well above it. In
	-- the overworld start no lower than y 176 either, so ground that a cave
	-- once replaced (its kept level is the cave floor) is read again from
	-- the sky down and gets its surface back.
	local top = hi + 64
	if t.dim == "overworld" or t.dim == "world" then
		top = math.max(top, 176)
	end
	return top, math.max(lo - 8, top - 240)
end

local function finish_tile(t)
	if job.pass and not t.near then
		storage:set_int("t:" .. t.key, job.pass)
	end
	job.done = job.done + 1
	-- Draw and save its finished picture, after map screens' own needs.
	sharp_map.request_draw(t.dim, t.tx, t.tz, 2)
end

-- Do one chunk of work. Returns false when the job is finished.
local function step_job()
	local t = job.current
	if not t then
		t = take_nearest()
		if not t then
			if job.pass then
				storage:set_int("redraw_active", 0)
			end
			core.log("action", "[sharp_map] map redraw finished (" .. job.done .. " tiles)")
			job = nil
			return false
		end
		job.current, job.chunk = t, 0
	end
	local tile = R.get_tile(t.dim, t.tx, t.tz)
	while tile and job.chunk < PER_SIDE * PER_SIDE do
		local c = job.chunk
		job.chunk = c + 1
		local i, j = c % PER_SIDE, floor(c / PER_SIDE)
		local ytop, ybot = chunk_range(t, tile, i, j)
		if ytop then
			R.scan_chunk(t.dim, t.tx * TILE + i * CHUNK, t.tz * TILE + j * CHUNK, ytop, ytop, ybot)
			return true -- one read of the world per call
		end
	end
	finish_tile(t)
	job.current = nil
	return true
end

local budget = cfg.redraw_budget * 1000
core.register_globalstep(function(dtime)
	if not job or dtime > 0.2 then
		return
	end
	local t0 = core.get_us_time()
	repeat
		if not step_job() then
			return
		end
	until core.get_us_time() - t0 >= budget
end)

-- Saved pictures in an older look: delete them, and (unless a redraw is
-- running, which draws each tile's picture when it is done) draw them all
-- again in the background, nearest first as they are asked for.
local function renew_pictures()
	if storage:get_int("picture_version") >= PICTURE_VERSION then
		return nil
	end
	storage:set_int("picture_version", PICTURE_VERSION)
	local tiles = list_tiles()
	for _, t in ipairs(tiles) do
		os.remove(R.root .. "/" .. t.key .. ".png")
	end
	return tiles
end

-- Start by itself after an update, or carry on after a restart.
core.register_on_mods_loaded(function()
	local repaint = renew_pictures()
	if storage:get_int("render_version") < RENDER_VERSION then
		storage:set_int("render_version", RENDER_VERSION)
		if cfg.redraw_on_update then
			start_all(true)
		end
	elseif storage:get_int("redraw_active") == 1 then
		start_all(false)
	end
	if repaint and not job then
		for _, t in ipairs(repaint) do
			sharp_map.request_draw(t.dim, t.tx, t.tz, 2)
		end
		core.log("action", "[sharp_map] drawing " .. #repaint .. " map pictures again in the background")
	end
end)

function sharp_map.redraw_status()
	if not job then
		return nil
	end
	return job.done, job.total
end

-- /map redraw [near|all|stop|status]: handled by the /map command.
function sharp_map.redraw_command(name, what)
	what = what ~= "" and what or "near"
	local admin = core.check_player_privs(name, { server = true })
	if what == "status" then
		if not job then
			return true, S("No map redraw is running.")
		end
		return true, S("Map redraw: @1 of @2 tiles done.", job.done, job.total)
	elseif what == "near" then
		local player = core.get_player_by_name(name)
		if not player then
			return false, S("You must be in the game to use this.")
		end
		local n = start_near(player:get_pos())
		return true, S("Redrawing @1 map tiles around you, a little at a time.", n)
	elseif what == "all" or what == "stop" then
		if not admin then
			return false, S("You need the server privilege for this.")
		end
		if what == "stop" then
			job = nil
			storage:set_int("redraw_active", 0)
			return true, S("Map redraw stopped. /map redraw all starts it again from the beginning.")
		end
		local n = start_all(true)
		return true, S("Redrawing all @1 saved map tiles in the background, a little at a time.", n)
	end
	return false, S("Use /map redraw near, all, stop or status.")
end
