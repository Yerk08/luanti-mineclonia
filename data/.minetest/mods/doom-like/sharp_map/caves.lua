-- Cave layers (1.3.0): caves are mapped as players walk through them.
--
-- What is mapped: only places a player could stand in and walk to from
-- where they are. A fill spreads out from the player's feet through
-- standable spots: two open nodes (feet and head) over something to stand
-- on, or water or a ladder to hold on to. From a spot it goes sideways to
-- the same level, one node up (a jump, with room overhead), up to three
-- nodes down (a drop that does not hurt), and straight up or down in water
-- and on ladders and vines. Lava, fire and anything else that hurts is
-- never walked into. Caves behind a wall, below a floor or past a long
-- drop are not mapped until someone gets there: the map never shows what
-- the player could not have seen.
--
-- How it is stored: a reached spot belongs to the band floor(y / 16) of
-- its feet (a band is a mapblock row). Each band is its own map (render.lua,
-- map id sharp_map.cave_mid(dim, band)), with the color of the floor seen
-- from above, its height for relief, and the walls that line the passage
-- (alpha 128, darkened) so tunnels have edges. Where a band has two
-- floors above one another, the higher is kept, as a view from above
-- would show it.
--
-- When a player is underground: more than ENTER_ROOF solid nodes (leaves
-- and logs do not count, so a forest is not a cave) within ROOF_SCAN
-- nodes above the head, and no daylight (light 15 at noon) at the
-- head; back above ground when fewer than LEAVE_ROOF are left or daylight
-- reaches the head. Houses, forests, oceans and ravines stay on the
-- surface view. In the Nether, which has no surface, players are always
-- in the cave view. The view follows the band of the player's feet, and
-- changes only two nodes past a band's edge, so walking up and down a
-- step on the edge does not swap the minimap's pictures back and forth.
--
-- Cost, kept the same way as the rest of the map (render.lua, redraw.lua)
-- and as steady_steps: work is cut small and spread over server steps.
--   * A fill is a job that runs a little each step, at most
--     sharp_map.cave_budget milliseconds (core.get_us_time), at least one
--     small batch so it always moves on, and not at all in a step that
--     already took over 0.2 s (the server is busy).
--   * The world is read one mapblock (16 x 16 x 16 = 4096 nodes) at a
--     time, only the mapblocks the fill actually walks into, each once per
--     job. A tunnel reads a handful; a big cavern a few dozen, spread over
--     as many steps as the budget needs.
--   * One job at a time, players taking turns (first come, first served,
--     one waiting job per player), so several players underground never
--     pile their work into one step.
--   * A player gets a new job only after moving MOVE nodes or a change to
--     the world near the last one, and at most once every
--     sharp_map.cave_interval seconds. Standing still costs nothing.
--   * Writing the result goes under the same budget, PAINT_N spots at a
--     time (1.4.1; one whole band at a time before).
--   * The underground check reads up to ROOF_SCAN nodes every CHECK
--     seconds per player (single node reads, no VoxelManip).
--
-- Background mapping (1.4.0, setting sharp_map.cave_background): caves
-- keep filling out from what is already mapped, a little at a time, the
-- way the surface map fills in around players.
--   * It only grows from mapped caves. When a fill stops at the edge of
--     its box with the way still open (a passage, a jump or a drop that
--     goes on past the edge), that spot is noted as a place to grow from,
--     one note per mapblock and direction (up to SEED_SPOTS spots). A
--     later background fill starts there, from those spots only, and goes
--     on outward with exactly the same walking rules, so it reaches only
--     what a player could walk to from a cave already on the map: never
--     through a wall, never a cave nobody has opened a way into.
--   * Its box is as big as a player's fill, moved so that the noted
--     mapblock sits on the side it came from; it maps new ground instead
--     of going over the old again. Its own edges are noted in turn, so
--     the map grows outward fill by fill. Edges that lead into ground a
--     layer already shows are not noted.
--   * Only near players: a place is used only within
--     sharp_map.cave_background_range nodes of a player in the same
--     dimension (nearest first); the rest wait until someone comes near.
--   * Same cost rules: one background fill at a time, never while a
--     player's fill is waiting, a new one at most every
--     sharp_map.cave_background_interval seconds, run under the same
--     sharp_map.cave_budget per step, one mapblock read at a time,
--     nothing in a busy step. Choosing the next place is its own step.
--   * Each place is used once per session (again only after a change to
--     the world in its mapblock), so the work always comes to an end.
--     Places not used yet are saved in <world>/sharp_map/caves/
--     frontier.txt (about MAX_SEEDS at most; the farthest are dropped
--     first).

local cfg = sharp_map.settings
local floor = math.floor

local BAND = 16
local DROP = 3          -- deepest drop walked down, in nodes
local V_UP, V_DOWN = 12, 12 -- how far up and down a fill reaches from the feet
local MAX_VISITS = 40000
local BATCH = 32        -- spots handled between two looks at the clock
local ROOF_SCAN = 32
local ENTER_ROOF, LEAVE_ROOF = 6, 3
local CHECK = 0.5       -- seconds between underground checks
local MOVE = 3          -- nodes moved before a new fill
local EDGE = 2          -- nodes past a band's edge before the view changes
local WALL_DARK = 0.55  -- walls are drawn this much darker than their node
local DEPTH_LOOK = 8    -- nodes looked down for a floor's color (water depth)
local BUSY = 0.2        -- a step longer than this: do nothing this step
-- Background mapping (1.4.0)
local SEED_SPOTS = 8    -- spots kept per place to grow from
local MAX_EDGES = 96    -- places one fill may note
local MAX_SEEDS = 1024  -- places kept waiting
local SEED_SAVE = 120   -- seconds between saves of the waiting places
local PAINT_N = 96      -- spots painted between two looks at the clock (1.4.1)

if not cfg.caves then
	-- Without cave layers nobody is ever in the cave view.
	function sharp_map.cave_band()
		return nil
	end
	function sharp_map.cave_status()
		return nil
	end
	return
end

local R = sharp_map.render
local enc = R.encode
-- Counts since the server started (tests, and a hint for profiling).
local stats = { jobs = 0, reads = 0, bg_jobs = 0, bg_skipped = 0 }
sharp_map.cave_stats = stats
local schar = string.char

------------------------------------------------------------------------
-- What can be walked through, stood on and held on to
------------------------------------------------------------------------

local walk = {}  -- content id -> true: solid (can be stood on, blocks the way)
local pass = {}  -- content id -> true: open and harmless (air, water, plants...)
local hold = {}  -- content id -> true: can be climbed or swum in
local roof = {}  -- node name -> true: solid and not leaves or logs

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		if name ~= "ignore" then
			local cid = core.get_content_id(name)
			if def.walkable ~= false then
				walk[cid] = true
				if core.get_item_group(name, "leaves") == 0 and core.get_item_group(name, "tree") == 0 then
					roof[name] = true
				end
			elseif (def.damage_per_second or 0) <= 0 then
				pass[cid] = true
				if def.climbable or (def.liquidtype or "none") ~= "none" then
					hold[cid] = true
				end
			end
		end
	end
end)

------------------------------------------------------------------------
-- Reading the world, one mapblock at a time
------------------------------------------------------------------------

-- A number for a node position (y and z within +-32767).
local function pos_key(x, y, z)
	return ((x + 32768) * 65536 + (y + 32768)) * 65536 + (z + 32768)
end

local function key_pos(k)
	local z = k % 65536
	local t = (k - z) / 65536
	local y = t % 65536
	return (t - y) / 65536 - 32768, y - 32768, z - 32768
end

-- The mapblock holding X, Y, Z, read on first use and kept for the job.
local function block(job, x, y, z)
	local bx, by, bz = floor(x / 16), floor(y / 16), floor(z / 16)
	local k = pos_key(bx, by, bz)
	if k == job.last_k then
		return job.last_b
	end
	local b = job.blocks[k]
	if not b then
		local vm = core.get_voxel_manip()
		local p0 = vector.new(bx * 16, by * 16, bz * 16)
		local emin, emax = vm:read_from_map(p0, vector.new(p0.x + 15, p0.y + 15, p0.z + 15))
		b = { data = vm:get_data(), p2 = vm:get_param2_data(),
			area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax }) }
		job.blocks[k] = b
		job.reads = job.reads + 1
		stats.reads = stats.reads + 1
	end
	job.last_k, job.last_b = k, b
	return b
end

local function cid(job, x, y, z)
	local b = block(job, x, y, z)
	return b.data[b.area:index(x, y, z)]
end

local function standable(job, x, y, z)
	local c = cid(job, x, y, z)
	return pass[c] and pass[cid(job, x, y + 1, z)] and (walk[cid(job, x, y - 1, z)] or hold[c]) or false
end

------------------------------------------------------------------------
-- The fill: a job that spreads over server steps
------------------------------------------------------------------------

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function visit(job, x, y, z)
	local k = pos_key(x, y, z)
	if not job.seen[k] and job.tail < MAX_VISITS then
		job.seen[k] = true
		local t = job.tail + 1
		job.tail = t
		job.qx[t], job.qy[t], job.qz[t] = x, y, z
	end
end

-- A fill job in dimension DIM over the box B ({ xmin, xmax, zmin, zmax,
-- ymin, ymax }), in phase PHASE. Places to grow from are noted only while
-- background mapping is on.
local function make_job(dim, b, phase)
	stats.jobs = stats.jobs + 1
	local job = {
		dim = dim, blocks = {}, reads = 0, phase = phase,
		xmin = b.xmin, xmax = b.xmax, zmin = b.zmin, zmax = b.zmax,
		ymin = b.ymin, ymax = b.ymax,
		qx = {}, qy = {}, qz = {}, head = 1, tail = 0, seen = {},
	}
	if cfg.cave_background then
		job.edges, job.edge_list = {}, {}
	end
	-- The box it may read, for noticing changes to the world nearby.
	job.box = { minp = vector.new(job.xmin - 1, job.ymin - DEPTH_LOOK, job.zmin - 1),
		maxp = vector.new(job.xmax + 1, job.ymax + 2, job.zmax + 1) }
	return job
end

-- A new job for a fill from the feet at POS in dimension DIM.
local function new_job(pos, dim)
	local r = cfg.cave_radius
	local fx, fy, fz = floor(pos.x + 0.5), floor(pos.y + 0.5), floor(pos.z + 0.5)
	local job = make_job(dim, { xmin = fx - r, xmax = fx + r, zmin = fz - r, zmax = fz + r,
		ymin = fy - V_DOWN, ymax = fy + V_UP }, "walk")
	-- Start at the feet, or just above or below (slabs, snow, deep water).
	for _, dy in ipairs({ 0, 1, -1 }) do
		if standable(job, fx, fy + dy, fz) then
			visit(job, fx, fy + dy, fz)
			break
		end
	end
	return job
end

-- Directions of the places to grow from: 1 to 4 as DIRS, 5 up, 6 down.
local UP, DOWN = 5, 6

-- The walk could go on from the reached spot X, Y, Z to CX, CY, CZ, which
-- is outside the job's box, going DIR: note it (background mapping).
local function edge(job, x, y, z, cx, cy, cz, dir)
	local key = pos_key(floor(x / 16), floor(y / 16), floor(z / 16)) * 8 + dir
	local e = job.edges[key]
	if not e then
		if #job.edge_list >= MAX_EDGES then
			return
		end
		e = { key = key, spots = {}, cands = {} }
		job.edges[key] = e
		job.edge_list[#job.edge_list + 1] = e
	end
	local n = #e.spots
	local last = e.spots[n]
	if n < SEED_SPOTS and not (last and last[1] == x and last[2] == y and last[3] == z) then
		e.spots[n + 1] = { x, y, z }
		e.cands[n + 1] = { cx, cy, cz }
	end
end

-- Handle up to N spots of the walk, stopping early (after at least one)
-- once the step's time is used (1.4.2): a spot that reaches into mapblocks
-- not yet read can cost a database read each.
local function walk_some(job, n, t0, budget)
	local ymin, ymax = job.ymin, job.ymax
	local edges = job.edges
	local first = true
	while n > 0 and job.head <= job.tail do
		if not first and t0 and core.get_us_time() - t0 >= budget then
			return false
		end
		first = false
		n = n - 1
		local h = job.head
		job.head = h + 1
		local x, y, z = job.qx[h], job.qy[h], job.qz[h]
		for i, d in ipairs(DIRS) do
			local nx, nz = x + d[1], z + d[2]
			if nx >= job.xmin and nx <= job.xmax and nz >= job.zmin and nz <= job.zmax then
				if standable(job, nx, y, nz) then
					visit(job, nx, y, nz)
				elseif y < ymax and pass[cid(job, x, y + 2, z)] and standable(job, nx, y + 1, nz) then
					-- One node up: a jump, with room over the head first.
					visit(job, nx, y + 1, nz)
				elseif pass[cid(job, nx, y, nz)] and pass[cid(job, nx, y + 1, nz)] then
					-- Walk off an edge: the first spot to land on, if the
					-- drop is short enough not to hurt.
					for k = 1, DROP do
						if y - k < ymin then
							-- Still falling at the bottom of the box.
							if edges and pass[cid(job, nx, y - k, nz)] then
								edge(job, x, y, z, nx, y - k, nz, DOWN)
							end
							break
						end
						if not pass[cid(job, nx, y - k, nz)] then
							break
						end
						if standable(job, nx, y - k, nz) then
							visit(job, nx, y - k, nz)
							break
						end
					end
				end
				-- A jump out of the top of the box.
				if edges and y == ymax and pass[cid(job, x, y + 2, z)] and standable(job, nx, y + 1, nz) then
					edge(job, x, y, z, nx, y + 1, nz, UP)
				end
			elseif edges and (standable(job, nx, y, nz) or pass[cid(job, nx, y, nz)]
					and pass[cid(job, nx, y + 1, nz)]
					or pass[cid(job, x, y + 2, z)] and standable(job, nx, y + 1, nz)) then
				-- The way goes on past the side of the box (a step, a drop
				-- or a jump): reads at most one node past the box.
				edge(job, x, y, z, nx, y, nz, i)
			end
		end
		-- Ladders, vines and water: straight up and down.
		if hold[cid(job, x, y, z)] or hold[cid(job, x, y + 1, z)] then
			if y < ymax and standable(job, x, y + 1, z) then
				visit(job, x, y + 1, z)
			elseif edges and y == ymax and standable(job, x, y + 1, z) then
				edge(job, x, y, z, x, y + 1, z, UP)
			end
			if (y > ymin or edges) and hold[cid(job, x, y - 1, z)] and standable(job, x, y - 1, z) then
				if y > ymin then
					visit(job, x, y - 1, z)
				elseif edges then
					edge(job, x, y, z, x, y - 1, z, DOWN)
				end
			end
		end
	end
	return job.head > job.tail
end

-- After the walk: the highest spot reached in each column of each band,
-- and the walls beside reached spots (solid at feet level).
local function sort_out(job)
	local top, walls, bands = {}, {}, {}
	for n = 1, job.tail do
		local x, y, z = job.qx[n], job.qy[n], job.qz[n]
		local b = floor(y / BAND)
		if not top[b] then
			top[b], walls[b] = {}, {}
			bands[#bands + 1] = b
		end
		local k = x .. "," .. z
		local t = top[b][k]
		if not t or y > t[2] then
			top[b][k] = { x, y, z }
		end
		for _, d in ipairs(DIRS) do
			local wx, wz = x + d[1], z + d[2]
			if walk[cid(job, wx, y, wz)] then
				local wk = wx .. "," .. wz
				local w = walls[b][wk]
				if not w or y > w[2] then
					walls[b][wk] = { wx, y, wz }
				end
			end
		end
	end
	job.top, job.walls, job.bands, job.bi = top, walls, bands, 1
	job.phase = "paint"
end

-- The spots of band B to paint, as one list (floors, then walls not over a
-- floor), so painting can be cut into pieces of PAINT_N (1.4.1).
local function paint_list(job, b)
	local out = {}
	for _, c in pairs(job.top[b]) do
		out[#out + 1] = c
	end
	for wk, w in pairs(job.walls[b]) do
		if not job.top[b][wk] then
			out[#out + 1] = { w[1], w[2], w[3], wall = true }
		end
	end
	return out
end

-- render.lua's column_color reads a flat VoxelManip (data[area:index()]);
-- these stand-ins let it read the job's mapblocks instead.
local function color_reader(job)
	local area = { index = function(_, x, y, z) return pos_key(x, y, z) end }
	local data = setmetatable({}, { __index = function(_, k)
		local x, y, z = key_pos(k)
		return cid(job, x, y, z)
	end })
	local param2 = setmetatable({}, { __index = function(_, k)
		local x, y, z = key_pos(k)
		local b = block(job, x, y, z)
		return b.p2[b.area:index(x, y, z)]
	end })
	return data, param2, area
end

-- Write spots FIRST to LAST of the paint list ITEMS of band B into its
-- cave map (the same result as painting the whole band at once: a wall is
-- never in a column that has a floor in this band).
local function paint_part(job, b, items, first, last)
	local mid = sharp_map.cave_mid(job.dim, b)
	local data, param2, area = color_reader(job)
	local list = {}
	for n = first, last do
		local c = items[n]
		local x, y, z = c[1], c[2], c[3]
		if not c.wall then
			-- Keep a higher floor already mapped in this band, unless it is
			-- gone (no longer standable, e.g. dug away).
			-- The stored height is the floor under the feet (feet = height
			-- + 1), but on a ladder, vine or in water it is the feet
			-- themselves; both are tried (1.4.3). Before, only height + 1
			-- was, so on ladders and in water two mappings with different
			-- reach kept painting over each other's spot, and the minimap
			-- redrew with nothing changed in the world.
			local a, oh = R.peek(mid, x, z)
			local keep = false
			if a == 255 and oh then
				for _, fy in ipairs({ oh + 1, oh }) do
					if fy > y and floor(fy / BAND) == b and standable(job, x, fy, z) then
						keep = true
						break
					end
				end
			end
			if not keep then
				local cr, cg, cb, h, g = R.column_color(data, param2, area, x, z, y, y - DEPTH_LOOK)
				if cr then
					list[#list + 1] = { x = x, z = z, h = enc(h), g = enc(g),
						pixel = schar(floor(cr + 0.5), floor(cg + 0.5), floor(cb + 0.5), 255) }
				end
			end
		else
			local a = R.peek(mid, x, z)
			if not a or a == 0 or a == 128 then
				local blk = block(job, x, y, z)
				local idx = blk.area:index(x, y, z)
				local cr, cg, cb = R.node_color(blk.data[idx], blk.p2[idx])
				cr, cg, cb = cr or 110, cg or 110, cb or 110
				list[#list + 1] = { x = x, z = z, h = enc(y + 1), g = enc(y + 1),
					pixel = schar(floor(cr * WALL_DARK + 0.5), floor(cg * WALL_DARK + 0.5),
						floor(cb * WALL_DARK + 0.5), 128) }
			end
		end
	end
	R.write_pixels(mid, list)
end

------------------------------------------------------------------------
-- Places to grow from (background mapping, 1.4.0)
------------------------------------------------------------------------

local seeds, n_seeds = {}, 0 -- key -> { key, dim, cx, cy, cz, spots, cands }
local seeds_dirty, seeds_full = false, false
local done, n_done = {}, 0   -- key -> true: used this session

local function cave_mid_of(dim, y)
	return sharp_map.cave_mid(dim, floor(y / BAND))
end

-- True when a layer already shows a floor for the spot C: its column has
-- a floor at C's height (give or take one node). Another floor higher in
-- the same layer does not count, so a way down a shaft is still followed.
local function mapped(dim, c)
	local a, h = R.peek(cave_mid_of(dim, c[2]), c[1], c[3])
	return a == 255 and h ~= nil and math.abs(h + 1 - c[2]) <= 1
end

-- True when the way from SPOT to C still leads into unmapped ground.
-- Straight up or down a ladder or through water stays in the spot's own
-- column, whose layer already shows the spot itself (a climbable spot is
-- stored at its own height), so such a way always counts as open; each
-- place is used once per session, so this cannot loop.
local function way_open(dim, spot, c)
	if spot[1] == c[1] and spot[3] == c[3] then
		return true
	end
	return not mapped(dim, c)
end

-- The mapblock and direction of a place's key.
local function key_block(key)
	local dir = key % 8
	local bx, by, bz = key_pos((key - dir) / 8)
	return bx, by, bz, dir
end

-- Keep edge E of a fill in DIM as a place to grow from.
local function add_seed(dim, e)
	if done[e.key] then
		return
	end
	local s = seeds[e.key]
	if not s then
		-- Over the cap, room for one more fill's worth is kept: the next
		-- choice of a place drops the farthest, so near ones are not lost.
		if n_seeds >= MAX_SEEDS + MAX_EDGES then
			return
		end
		if n_seeds >= MAX_SEEDS then
			seeds_full = true
		end
		local bx, by, bz = key_block(e.key)
		s = { key = e.key, dim = dim or false, cx = bx * 16 + 8, cy = by * 16 + 8, cz = bz * 16 + 8,
			spots = {}, cands = {} }
		seeds[e.key] = s
		n_seeds = n_seeds + 1
	end
	for i, spot in ipairs(e.spots) do
		if #s.spots >= SEED_SPOTS then
			break
		end
		s.spots[#s.spots + 1] = spot
		s.cands[#s.cands + 1] = e.cands[i]
	end
	seeds_dirty = true
end

local function mark_done(key)
	if n_done >= 200000 then
		done, n_done = {}, 0
	end
	done[key] = true
	n_done = n_done + 1
end

-- The box of a background fill from place KEY: as big as a player's fill,
-- moved so that the place's mapblock is on the side it came from.
local function seed_box(key)
	local bx, by, bz, dir = key_block(key)
	local r = cfg.cave_radius
	local x0, y0, z0 = bx * 16, by * 16, bz * 16
	local b = { xmin = x0 + 8 - r, xmax = x0 + 8 + r, zmin = z0 + 8 - r, zmax = z0 + 8 + r,
		ymin = y0 + 8 - V_DOWN, ymax = y0 + 8 + V_UP }
	if dir == 1 then
		b.xmin, b.xmax = x0, x0 + 2 * r
	elseif dir == 2 then
		b.xmin, b.xmax = x0 + 15 - 2 * r, x0 + 15
	elseif dir == 3 then
		b.zmin, b.zmax = z0, z0 + 2 * r
	elseif dir == 4 then
		b.zmin, b.zmax = z0 + 15 - 2 * r, z0 + 15
	elseif dir == UP then
		b.ymin, b.ymax = y0, y0 + V_UP + V_DOWN
	else
		b.ymin, b.ymax = y0 + 15 - V_UP - V_DOWN, y0 + 15
	end
	return b
end

-- A background fill from place S. It first checks that the way out is
-- still unmapped (a player's fill may have got there meanwhile).
local function seed_job(s)
	local job = make_job(s.dim or nil, seed_box(s.key), "check")
	job.starts, job.cands, job.ci = s.spots, s.cands, 1
	return job
end

-- Work on JOB until BUDGET microseconds are used (at least one batch).
-- Returns true when the job is finished.
local function run_job(job, budget)
	local t0 = core.get_us_time()
	repeat
		local u0 = core.get_us_time()
		local phase = job.phase
		if job.phase == "walk" then
			if walk_some(job, BATCH, t0, budget) then
				sort_out(job)
			end
		elseif job.phase == "paint" then
			local b = job.bands[job.bi]
			if b then
				-- One part of a band at a time (1.4.1): a big cavern's band
				-- used to be painted in one go (up to 38 ms in a step).
				job.items = job.items or paint_list(job, b)
				local first = job.pi or 1
				local last = math.min(#job.items, first + PAINT_N - 1)
				paint_part(job, b, job.items, first, last)
				if last >= #job.items then
					job.bi, job.items, job.pi = job.bi + 1, nil, nil
				else
					job.pi = last + 1
				end
			elseif job.edge_list then
				job.phase, job.ei = "edges", 1
			else
				job.phase = "done"
				return true
			end
		elseif job.phase == "edges" then
			-- One noted edge at a time: keep it if its way leads into
			-- ground no layer shows yet.
			local e = job.edge_list[job.ei]
			if not e then
				job.phase = "done"
				return true
			end
			job.ei = job.ei + 1
			for i, c in ipairs(e.cands) do
				if way_open(job.dim, e.spots[i], c) then
					add_seed(job.dim, e)
					break
				end
			end
		elseif job.phase == "check" then
			local c = job.cands[job.ci]
			if not c then
				-- Every way out is mapped by now: nothing to do.
				stats.bg_skipped = stats.bg_skipped + 1
				job.phase = "done"
				return true
			end
			job.ci = job.ci + 1
			if way_open(job.dim, job.starts[job.ci - 1], c) then
				for _, sp in ipairs(job.starts) do
					if standable(job, sp[1], sp[2], sp[3]) then
						visit(job, sp[1], sp[2], sp[3])
					end
				end
				job.phase = "walk"
			end
		else
			return true
		end
		sharp_map.slow("cave mapping", u0, phase)
	until core.get_us_time() - t0 >= budget
	return false
end

-- A whole fill at once (tests, and nothing in normal play). Returns the
-- number of spots reached and the box it may read.
local function fill(pos, dim)
	local job = new_job(pos, dim)
	while not run_job(job, math.huge) do end
	return job.tail, job.box, job.reads
end
sharp_map.cave_fill = fill -- for tests

------------------------------------------------------------------------
-- Who is underground, and which band they see
------------------------------------------------------------------------

local state = {} -- player name -> { under, band, fx, fy, fz, since, dirty, box }

-- Solid nodes (not leaves or logs) above the head, counted up to ROOF_SCAN
-- nodes; stops at unloaded ground.
local function roof_count(pos)
	local n = 0
	local p = vector.new(floor(pos.x + 0.5), floor(pos.y + 0.5) + 2, floor(pos.z + 0.5))
	for _ = 1, ROOF_SCAN do
		local node = core.get_node_or_nil(p)
		if not node then
			break
		end
		if roof[node.name] then
			n = n + 1
		end
		p.y = p.y + 1
	end
	return n
end

local function check(player, st)
	local pos = player:get_pos()
	local dim = sharp_map.dimension_of(pos)
	local was = st.under
	local under
	if dim == "nether" then
		under = true
	else
		local head = vector.new(pos.x, pos.y + 1.5, pos.z)
		-- Light at noon: 15 only comes from the sky (lamps reach at most
		-- 14), the same test the surface scan uses. (Not get_natural_light:
		-- Mineclonia replaces that one with its own, in mcl_util.)
		local light = core.get_node_light(head, 0.5)
		if light == nil then
			return -- not loaded; keep the current view
		end
		if light >= 15 then
			under = false
		else
			local n = roof_count(pos)
			under = n >= (st.under and LEAVE_ROOF or ENTER_ROOF)
		end
	end
	-- Change views only when two checks in a row agree (1.4.2), so walking
	-- about in a cave mouth, in and out of daylight, does not flip the
	-- minimap back and forth. The Nether and the first check switch at once.
	if under == st.under or st.under == nil or dim == "nether" then
		st.under, st.flip = under, nil
	elseif st.flip == under then
		st.under, st.flip = under, nil
	else
		st.flip = under
	end
	local feet = floor(pos.y + 0.5)
	if not st.band or feet < st.band * BAND - EDGE or feet > st.band * BAND + BAND - 1 + EDGE
			or st.dim ~= dim then
		st.band = floor(feet / BAND)
	end
	st.dim = dim
	if st.under and not was then
		st.dirty = true -- map the cave right away
	end
end

-- The band PLAYER's cave view shows, or nil while on the surface view.
function sharp_map.cave_band(player)
	local st = state[player:get_player_name()]
	if st and st.under then
		return st.band
	end
	return nil
end

core.register_on_joinplayer(function(player)
	state[player:get_player_name()] = { since = 0 }
end)

core.register_on_leaveplayer(function(player)
	state[player:get_player_name()] = nil
end)

-- A change to the world inside a player's last fill box maps it again.
-- (Without this callback, which every supported engine has, caves are
-- still mapped as players move.)
local on_changed = core.register_on_mapblocks_changed or function() end
on_changed(function(modified_blocks)
	for hash in pairs(modified_blocks) do
		local bp = core.get_position_from_hash(hash)
		if n_done > 0 then
			-- A change may open a new way: its places may be used again.
			local k = pos_key(bp.x, bp.y, bp.z) * 8
			for d = 1, 6 do
				done[k + d] = nil
			end
		end
		local x0, y0, z0 = bp.x * 16, bp.y * 16, bp.z * 16
		for _, st in pairs(state) do
			local b = st.box
			if b and x0 <= b.maxp.x and x0 + 15 >= b.minp.x and y0 <= b.maxp.y and y0 + 15 >= b.minp.y
					and z0 <= b.maxp.z and z0 + 15 >= b.minp.z then
				st.dirty = true
			end
		end
	end
end)

local check_timer = 0
local jobs = {}   -- waiting and running fills, first come first served
local budget = cfg.cave_budget * 1000
local bg          -- the running background fill, or nil
local bg_timer = 0

-- Drop the places farthest from every player (in OUT: { seed, distance })
-- until a quarter of the room is free again.
local function trim_seeds(out)
	table.sort(out, function(a, b) return a[2] > b[2] end)
	local i = 1
	while n_seeds > MAX_SEEDS * 3 / 4 and out[i] do
		seeds[out[i][1].key] = nil
		n_seeds = n_seeds - 1
		i = i + 1
	end
	seeds_full, seeds_dirty = false, true
end

-- The waiting place nearest to a player in its dimension, within
-- sharp_map.cave_background_range nodes (in every direction), or nil.
local function pick_seed(players)
	local range = cfg.cave_background_range
	local where = {}
	for i, player in ipairs(players) do
		local pos = player:get_pos()
		where[i] = { dim = sharp_map.dimension_of(pos) or false, x = pos.x, y = pos.y, z = pos.z }
	end
	local best, best_d
	local all = seeds_full and {} or nil
	local abs, max = math.abs, math.max
	for _, s in pairs(seeds) do
		local d = math.huge
		for _, p in ipairs(where) do
			if p.dim == s.dim then
				local dd = max(abs(s.cx - p.x), abs(s.cy - p.y), abs(s.cz - p.z))
				if dd < d then
					d = dd
				end
			end
		end
		if d <= range and (not best_d or d < best_d) then
			best, best_d = s, d
		end
		if all then
			all[#all + 1] = { s, d }
		end
	end
	if all then
		trim_seeds(all)
		if best and not seeds[best.key] then
			best = nil -- dropped (cannot happen while the range is small)
		end
	end
	return best
end

------------------------------------------------------------------------
-- Saving the waiting places between sessions
------------------------------------------------------------------------

local seed_file = R.root .. "/caves/frontier.txt"

local function spots_text(list)
	local out = {}
	for i, p in ipairs(list) do
		out[i] = p[1] .. "," .. p[2] .. "," .. p[3]
	end
	return table.concat(out, ";")
end

local function spots_parse(text)
	local out = {}
	for x, y, z in (text or ""):gmatch("(%-?%d+),(%-?%d+),(%-?%d+)") do
		out[#out + 1] = { tonumber(x), tonumber(y), tonumber(z) }
	end
	return out
end

-- One line per place: key, dimension, spots, ways out (tab-separated).
local function save_seeds()
	if not seeds_dirty then
		return
	end
	seeds_dirty = false
	local lines = {}
	for key, s in pairs(seeds) do
		lines[#lines + 1] = ("%.0f"):format(key) .. "\t" .. (s.dim or "") .. "\t"
			.. spots_text(s.spots) .. "\t" .. spots_text(s.cands)
	end
	core.mkdir(R.root .. "/caves")
	core.safe_file_write(seed_file, table.concat(lines, "\n"))
end

local function load_seeds()
	local f = io.open(seed_file, "r")
	if not f then
		return
	end
	for line in f:lines() do
		local key, dim, sp, ca = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
		key = tonumber(key)
		if key and n_seeds < MAX_SEEDS then
			local spots, cands = spots_parse(sp), spots_parse(ca)
			if #spots > 0 and #spots == #cands then
				add_seed(dim ~= "" and dim or nil, { key = key, spots = spots, cands = cands })
			end
		end
	end
	f:close()
	seeds_dirty = false
end

if cfg.cave_background then
	load_seeds()
	core.register_on_shutdown(function()
		seeds_dirty = true -- also when a regular save was half built
		save_seeds()
	end)
	-- The regular save is built SAVE_PER_STEP places per step and written
	-- at the end (1.4.2; built all in one step it took up to 27 ms).
	local SAVE_PER_STEP = 64
	local save_timer, saving = 0, nil
	core.register_globalstep(function(dtime)
		save_timer = save_timer + dtime
		if not saving then
			if save_timer < SEED_SAVE or not seeds_dirty then
				return
			end
			save_timer = 0
			seeds_dirty = false
			saving = { keys = {}, lines = {}, i = 1 }
			for key in pairs(seeds) do
				saving.keys[#saving.keys + 1] = key
			end
			return
		end
		if dtime > BUSY then
			return
		end
		local u0 = core.get_us_time()
		local last = math.min(#saving.keys, saving.i + SAVE_PER_STEP - 1)
		for i = saving.i, last do
			local key = saving.keys[i]
			local s = seeds[key]
			if s then
				saving.lines[#saving.lines + 1] = ("%.0f"):format(key) .. "\t" .. (s.dim or "") .. "\t"
					.. spots_text(s.spots) .. "\t" .. spots_text(s.cands)
			end
		end
		saving.i = last + 1
		if saving.i > #saving.keys then
			core.mkdir(R.root .. "/caves")
			core.safe_file_write(seed_file, table.concat(saving.lines, "\n"))
			saving = nil
		end
		sharp_map.slow("cave places save", u0)
	end)
end

core.register_globalstep(function(dtime)
	local players = core.get_connected_players()
	for _, player in ipairs(players) do
		local st = state[player:get_player_name()]
		if st then
			st.since = st.since + dtime
		end
	end
	check_timer = check_timer + dtime
	if check_timer >= CHECK then
		check_timer = 0
		for _, player in ipairs(players) do
			local st = state[player:get_player_name()]
			if st then
				check(player, st)
			end
		end
	end
	if not R.ready() then
		return
	end
	-- A new job for each underground player who moved (or whose
	-- surroundings changed) and has none waiting.
	for _, player in ipairs(players) do
		local name = player:get_player_name()
		local st = state[name]
		if st and st.under and not st.job and st.since >= cfg.cave_interval then
			local pos = player:get_pos()
			local fx, fy, fz = floor(pos.x + 0.5), floor(pos.y + 0.5), floor(pos.z + 0.5)
			if st.dirty or not st.fx or math.abs(fx - st.fx) >= MOVE or math.abs(fy - st.fy) >= MOVE
					or math.abs(fz - st.fz) >= MOVE then
				st.fx, st.fy, st.fz = fx, fy, fz
				st.since, st.dirty = 0, false
				-- Only the job's box is set here; its first mapblock is read
				-- when it runs, under the budget.
				local job = { name = name, pos = pos, dim = sharp_map.dimension_of(pos) }
				st.job = job
				jobs[#jobs + 1] = job
			end
		end
	end
	if cfg.cave_background and not bg then
		bg_timer = bg_timer + dtime
	end
	-- Work on the first job, within the budget, unless the server is busy.
	if dtime > BUSY then
		return
	end
	local job = jobs[1]
	if job then
		local st = state[job.name]
		if not st or st.job ~= job then
			table.remove(jobs, 1) -- the player left
			return
		end
		if not job.fill then
			job.fill = new_job(job.pos, job.dim)
			st.box = job.fill.box
		end
		if run_job(job.fill, budget) then
			table.remove(jobs, 1)
			st.job = nil
		end
		return
	end
	-- Background mapping: only when no player's fill is waiting. Choosing
	-- a place takes its own step; the fill runs from the next one.
	if not cfg.cave_background then
		return
	end
	if bg then
		if run_job(bg, budget) then
			bg = nil
		end
	elseif n_seeds > 0 and bg_timer >= cfg.cave_background_interval then
		bg_timer = 0
		local s = pick_seed(players)
		if s then
			seeds[s.key] = nil
			n_seeds = n_seeds - 1
			seeds_dirty = true
			mark_done(s.key)
			stats.bg_jobs = stats.bg_jobs + 1
			bg = seed_job(s)
		end
	end
end)

-- For tests and /map caves: jobs waiting or running.
function sharp_map.cave_jobs()
	return #jobs
end

-- For tests and /map caves: places waiting, and whether a background fill
-- is running.
function sharp_map.cave_seeds()
	return n_seeds, bg ~= nil
end

-- /map caves: what cave mapping is doing, for PLAYER (or nil).
function sharp_map.cave_status(player)
	local S = sharp_map.S
	local lines = {}
	local band = player and sharp_map.cave_band(player)
	if band then
		lines[#lines + 1] = S("You are in the cave view: layer y @1 to @2.", band * BAND, band * BAND + BAND - 1)
	elseif player then
		lines[#lines + 1] = S("You are in the surface view.")
	end
	lines[#lines + 1] = S("Cave fills waiting: @1. Since the server started: @2 fills, @3 mapblocks read.",
		#jobs, stats.jobs, stats.reads)
	if cfg.cave_background then
		lines[#lines + 1] = S("Background cave mapping: @1 places to grow from, @2 fills, @3 already mapped.",
			n_seeds, stats.bg_jobs, stats.bg_skipped)
	else
		lines[#lines + 1] = S("Background cave mapping is off (sharp_map.cave_background).")
	end
	return table.concat(lines, "\n")
end
