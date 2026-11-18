-- Light Works: a held torch or lantern lights the world around you.
--
-- No light nodes are placed. A torch lights a block face by raising the light value
-- (param1) of the air in front of it, and that is exactly what this mod writes, straight
-- into the map with a VoxelManip. Before a cell is changed its real value is saved, and
-- it is put back exactly when the light moves on. When a block is dug or placed next to
-- painted light, the engine relights the cells around it from the paint as if it were real;
-- in the same server step this mod puts the real light back around the change, repairs the
-- changed map block(s) with core.fix_light and paints the light again (1.0.1). Other changes
-- under the paint (pistons, water) mark the map block "dirty"; it is repaired with
-- core.fix_light once no light is near it.
--
-- Seamless movement (0.4.0): one light source at the holder's exact position, not at a
-- cell. Every face gets the light level of its distance from that point (along open
-- paths, like the engine's spreading), rounded to a whole level. Moving never makes the
-- light jump from cell to cell, and crossing a cell corner is not a special case. A face
-- changes by at most one level per server step, and a flicker guard (five layers, see
-- guard_levels) keeps faces still at level boundaries. While the holder is stopped no face
-- gets dimmer.
--
-- Cost rules: positions are checked every server step and the light follows every step
-- while the holder moves (max_rate is only a ceiling for very short server steps); only the
-- map blocks with a face that changed level are read and written; node data is cached per
-- map block, so an update reads only light values.

local S = core.get_translator("light_works")

light_works = {}
local M = light_works

local floor, abs, max, min = math.floor, math.abs, math.max, math.min

-- Settings ---------------------------------------------------------------------------------

local settings = core.settings
local function num(key, default, lo, hi)
	local v = tonumber(settings:get("light_works." .. key)) or default
	if v < lo then v = lo elseif v > hi then v = hi end
	return v
end

local ENABLED = settings:get_bool("light_works.enabled", true)
local OFFHAND = settings:get_bool("light_works.offhand", true)
local ARMOR = settings:get_bool("light_works.armor", true)
local GLOWING_ITEMS = settings:get_bool("light_works.glowing_items", true)
local MIN_INTERVAL = 1 / num("max_rate", 15, 1, 30)
local EDGE_TOLERANCE = floor(num("edge_tolerance", 0, 0, 4))
local MIN_LIGHT = floor(num("min_light", 1, 1, 14))

local ITEM_CHECK = 0.25 -- how often held items and the light already there are looked at
local UPDATES_PER_STEP = 2 -- light moves per server step, at most (others wait a step)
local CATCH_UP = 4 -- the source moved further than this (a teleport): faces are set at once
local HYSTERESIS_Y = 0.8 -- the hand must be this far past a cell edge up or down before its
-- height changes: a jump (about 1.25 nodes) moves nothing
-- Flicker guard
local DEADBAND = 0.1 -- 1: no update until the position moved this far (nodes)
local MARGIN = 0.2 -- 2: a face changes only this far (in levels) past a rounding boundary
local REVERSE_HOLD = 0.25 -- 3: seconds before a face may change back the other way
-- 4: at most one level per face per update (in guard_levels)
local STOP_SPEED = 0.5 -- 5: slower than this (nodes a second) is stopped: no face dims
local SMOOTH_TIME = 0.15 -- the smoothed position eases onto the real one over this time
local SNAP_DISTANCE = 2 -- further off than this (a teleport) the smoothed position snaps
local SETTLE_AFTER = 1.5 -- seconds with nothing written before waiting edge changes are
local HAND_HEIGHT = 1.2 -- the light sits at hand height above the feet
local CACHE_AGE = 2 -- seconds a map block's cached node data is trusted
local REPAIRS_PER_STEP = 2
local SAVE_INTERVAL = 5
local NEAR_MARGIN = 24 -- a dirty block is repaired only this far beyond a light's reach

local FIX_REACH = 2 -- a repair after a dig or placement grows at most this many map blocks
-- from the changed one (to blocks where the engine's relight changed painted cells)

M.version = "1.0.1"

-- Keys -------------------------------------------------------------------------------------
-- Own key formats (not the engine's hash), exact in doubles and in Lua 5.3 integers.

local OFF = 32768
local function key_of(x, y, z)
	return (z + OFF) * 4294967296 + (y + OFF) * 65536 + (x + OFF)
end
local function key_xyz(k)
	local x = k % 65536
	local r = (k - x) / 65536
	local y = r % 65536
	local z = floor((r - y) / 65536)
	return floor(x) - OFF, floor(y) - OFF, z - OFF
end

local BOFF = 4096
local function bkey_of(bx, by, bz)
	return (bz + BOFF) * 67108864 + (by + BOFF) * 8192 + (bx + BOFF)
end
local function bkey_xyz(b)
	local x = b % 8192
	local r = (b - x) / 8192
	local y = r % 8192
	local z = floor((r - y) / 8192)
	return floor(x) - BOFF, floor(y) - BOFF, z - BOFF
end
local function bkey_of_key(k)
	local x, y, z = key_xyz(k)
	return bkey_of(floor(x / 16), floor(y / 16), floor(z / 16))
end

-- State ------------------------------------------------------------------------------------

local orig = {} -- key -> param1 before this mod changed it
local wrote = {} -- key -> param1 this mod wrote
local wlvl = {} -- key -> light level this mod painted there
local pend = {} -- key -> true: a faint change that is waiting
local bkeys = {} -- bkey -> {key = true}: tracked cells per map block
local dirty = {} -- bkey -> true: the engine relit this block while it was painted
local cache = {} -- bkey -> {data = content ids (4096), t = seconds}
local emitters = {} -- id -> {hand, src, px, pz, level, field, flips, last, force, catching}
local holders = {} -- player name -> {level, t}: held light, refreshed every ITEM_CHECK
local smooth = {} -- player name -> {x, z, t}: smoothed position (sideways)
local debug_players = {} -- name -> totals for the current second
local passable = {} -- content id -> true for nodes whose param1 holds light
local storage = core.get_mod_storage()
local storage_changed = false
local recovery = {} -- map blocks left painted by a crash, repaired before anything else
local failed = false
local last_change = 0 -- when light was last written or a change was put off (seconds)

local function now_s()
	return core.get_us_time() / 1000000
end

local function track(k, base, value, lvl)
	if not orig[k] then
		local bk = bkey_of_key(k)
		local set = bkeys[bk]
		if not set then
			set = {}
			bkeys[bk] = set
			storage_changed = true
		end
		set[k] = true
		orig[k] = base
	end
	wrote[k] = value
	wlvl[k] = lvl
end

local function untrack(k)
	if not orig[k] then return end
	orig[k], wrote[k], wlvl[k] = nil, nil, nil
	local bk = bkey_of_key(k)
	local set = bkeys[bk]
	if set then
		set[k] = nil
		if next(set) == nil then
			bkeys[bk] = nil
			storage_changed = true
		end
	end
end

-- A torch raises both light banks (day and night) to at least its level.
local function combine(v, l)
	local day = v % 16
	local night = floor(v / 16)
	if l > day then day = l end
	if l > night then night = l end
	return floor(day + night * 16)
end

local function level_at(k)
	local best = 0
	for _, e in pairs(emitters) do
		local f = e.field
		if f then
			local l = f[k]
			if l and l > best then best = l end
		end
	end
	return best
end

-- Node data cache --------------------------------------------------------------------------

local function block_data(bk, now)
	local c = cache[bk]
	if c and now - c.t < CACHE_AGE then return c.data end
	local bx, by, bz = bkey_xyz(bk)
	local pmin = {x = bx * 16, y = by * 16, z = bz * 16}
	local vm = core.get_voxel_manip()
	vm:read_from_map(pmin, {x = pmin.x + 15, y = pmin.y + 15, z = pmin.z + 15})
	local data = vm:get_data(c and c.data) -- reuse the old table: less garbage to collect
	if vm.close then vm:close() end
	if c then c.t = now else cache[bk] = {data = data, t = now} end
	return data
end

-- Content id at a node, through the cache. `memo` (bkey -> data) speeds up one search.
local function cid_at(x, y, z, now, memo)
	local bx, by, bz = floor(x / 16), floor(y / 16), floor(z / 16)
	local bk = bkey_of(bx, by, bz)
	local d = memo[bk]
	if not d then
		d = block_data(bk, now)
		memo[bk] = d
	end
	return d[(z - bz * 16) * 256 + (y - by * 16) * 16 + (x - bx * 16) + 1]
end

local function prune_cache(now)
	for bk, c in pairs(cache) do
		if now - c.t >= CACHE_AGE * 2 then cache[bk] = nil end
	end
end

-- Writing light ----------------------------------------------------------------------------

local light_buf = {}

-- Bring the given cells to the light they should have now, one map block at a time.
-- A block is written only when it has a real change (or is being left, or force is set);
-- otherwise its changes wait in `pend`. Bookkeeping always matches what is in the map.
-- The node data read here refreshes the cache, and a cell that no longer holds light is
-- never written.
local function apply(keys, stats, force)
	local by_block = {}
	for k in pairs(keys) do
		local bk = bkey_of_key(k)
		local list = by_block[bk]
		if not list then
			list = {}
			by_block[bk] = list
		end
		list[#list + 1] = k
	end
	local now = now_s()
	for bk, list in pairs(by_block) do
		local bx, by, bz = bkey_xyz(bk)
		local pmin = {x = bx * 16, y = by * 16, z = bz * 16}
		local pmax = {x = pmin.x + 15, y = pmin.y + 15, z = pmin.z + 15}
		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map(pmin, pmax)
		local c = cache[bk]
		local data = vm:get_data(c and c.data)
		if c then c.t = now else cache[bk] = {data = data, t = now} end
		local light = vm:get_light_data(light_buf)
		local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
		local ci, ck, cv, cb, cl = {}, {}, {}, {}, {}
		local significant, leaving = false, true
		for _, k in ipairs(list) do
			local x, y, z = key_xyz(k)
			local i = area:index(x, y, z)
			local cur = light[i]
			if not passable[data[i]] then
				-- The node changed and holds no light now (a piston, a falling block): leave
				-- its param1 alone and repair the block later.
				if orig[k] then
					untrack(k)
					dirty[bk] = true
					storage_changed = true
					stats.external = stats.external + 1
				end
				pend[k] = nil
			else
				if wrote[k] and cur ~= wrote[k] then
					-- The engine changed this cell while it was painted: stop tracking it and
					-- repair the block with fix_light once no light is near.
					untrack(k)
					dirty[bk] = true
					storage_changed = true
					stats.external = stats.external + 1
				end
				local base = orig[k] or cur
				local lvl = level_at(k)
				local want = lvl > 0 and combine(base, lvl) or base
				if want ~= cur then
					local n = #ci + 1
					ci[n], ck[n], cv[n], cb[n], cl[n] = i, k, want, base, lvl
					local old = wlvl[k] or 0
					if lvl ~= old and (lvl > EDGE_TOLERANCE or old > EDGE_TOLERANCE) then
						significant = true
					end
					if lvl > 0 then leaving = false end
				else
					pend[k] = nil
					if want == base then untrack(k) else track(k, base, want, lvl) end
				end
			end
		end
		if #ci > 0 then
			if force or significant or leaving then
				for n = 1, #ci do
					local k = ck[n]
					light[ci[n]] = cv[n]
					pend[k] = nil
					if cv[n] == cb[n] then untrack(k) else track(k, cb[n], cv[n], cl[n]) end
				end
				vm:set_light_data(light)
				vm:write_to_map(false)
				stats.blocks = stats.blocks + 1
			else
				for n = 1, #ci do pend[ck[n]] = true end
				stats.waiting = stats.waiting + #ci
			end
			last_change = now
		end
		if vm.close then vm:close() end
	end
end

local function new_stats()
	return {blocks = 0, waiting = 0, external = 0, cells = 0}
end

-- Spreading light --------------------------------------------------------------------------

local DX = {1, -1, 0, 0, 0, 0}
local DY = {0, 0, 1, -1, 0, 0}
local DZ = {0, 0, 0, 0, 1, -1}

local function round(v)
	return floor(v + 0.5)
end

local function manhattan(a, b)
	return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)
end

local function open_at(p, now, memo)
	return passable[cid_at(p.x, p.y, p.z, now, memo)] == true
end

-- The cell the light starts from: the hand's cell (held back by the hysteresis), else the
-- real hand cell (after stepping up onto a ledge the held-back cell can be inside the step),
-- else the one below it (crawling). nil when the hand is in solid rock.
local function find_base(hand, raw, now, memo)
	if open_at(hand, now, memo) then return hand end
	if open_at(raw, now, memo) then return raw end
	local below = {x = raw.x, y = raw.y - 1, z = raw.z}
	if open_at(below, now, memo) then return below end
	return nil
end

-- The light a torch of level L at src would give, as key -> level, spread the way the
-- engine spreads it: one level less per step, only through cells that hold light.
local function compute_field(src, L, now, memo)
	local field = {}
	local k0 = key_of(src.x, src.y, src.z)
	local seen = {[k0] = true}
	local qk, qx, qy, qz, ql = {k0}, {src.x}, {src.y}, {src.z}, {L}
	local h, t = 1, 1
	while h <= t do
		local k, x, y, z, l = qk[h], qx[h], qy[h], qz[h], ql[h]
		h = h + 1
		field[k] = l
		if l > 1 then
			local nl = l - 1
			for d = 1, 6 do
				local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
				local nk = key_of(nx, ny, nz)
				if not seen[nk] then
					seen[nk] = true
					if passable[cid_at(nx, ny, nz, now, memo)] then
						t = t + 1
						qk[t], qx[t], qy[t], qz[t], ql[t] = nk, nx, ny, nz, nl
					end
				end
			end
		end
	end
	return field
end

-- The exact light a torch of level L at the point (px, src.y, pz) would give, as key ->
-- level (not rounded). Distances are counted along open paths from src (the cell holding
-- the point), then corrected sideways for where in that cell the point is; in the open this
-- is the exact distance from the point. One ring further than whole levels reach, because
-- the correction can bring a cell up to one node nearer.
local function compute_exact(src, px, pz, L, now, memo)
	local exact = {}
	local k0 = key_of(src.x, src.y, src.z)
	local seen = {[k0] = true}
	local qk, qx, qy, qz, qg = {k0}, {src.x}, {src.y}, {src.z}, {0}
	local h, t = 1, 1
	while h <= t do
		local k, x, y, z, g = qk[h], qx[h], qy[h], qz[h], qg[h]
		h = h + 1
		local d = g + abs(x - px) - abs(x - src.x) + abs(z - pz) - abs(z - src.z)
		local v = L - d
		if v > 0 then exact[k] = v end
		if g < L then
			for n = 1, 6 do
				local nx, ny, nz = x + DX[n], y + DY[n], z + DZ[n]
				local nk = key_of(nx, ny, nz)
				if not seen[nk] then
					seen[nk] = true
					if passable[cid_at(nx, ny, nz, now, memo)] then
						t = t + 1
						qk[t], qx[t], qy[t], qz[t], qg[t] = nk, nx, ny, nz, g + 1
					end
				end
			end
		end
	end
	return exact
end

-- The flicker guard. From the faces' current levels (old) and their exact values, the new
-- levels. Layer 2: a face moves to a new level only when its exact value is MARGIN past the
-- rounding boundary. Layer 3: a face that just changed does not change back the other way
-- for REVERSE_HOLD seconds. Layer 4: one level per update at most. Layer 5: while stopped,
-- no face starts to dim. (Layer 1, the dead band, is in update_player.) With direct set (first light,
-- a new item, a teleport) the faces take their rounded values at once.
-- Returns the new levels, the new flip times and whether some face is still catching up.
local function guard_levels(old, exact, flips, L, now, still, direct, last)
	local new, nflips, catching = {}, {}, false
	local function one(k)
		local cur = old[k] or 0
		local v = exact[k] or 0
		local lvl = cur
		if direct then
			lvl = max(0, min(L, round(v)))
		else
			local want = cur
			if v > cur + 0.5 + MARGIN then
				want = min(L, round(v))
			elseif v < cur - 0.5 - MARGIN then
				want = max(0, round(v))
			end
			if want > cur then lvl = cur + 1 elseif want < cur then lvl = cur - 1 end
			local f = flips[k]
			-- Stopped: no face starts to dim. One that was already dimming at the last
			-- update (the holder moved away from it) finishes, one level per update.
			local going_down = f and f.dir < 0 and f.t == last
			if lvl < cur and still and not going_down then lvl = cur end
			if lvl ~= cur and f and f.dir ~= lvl - cur and now - f.t < REVERSE_HOLD then
				lvl = cur
				catching = true -- held back for a moment: look again next update
			end
			if want ~= lvl and not (want < cur and still and not going_down) then catching = true end
		end
		if lvl ~= cur then
			nflips[k] = {dir = lvl - cur, t = now}
		elseif flips[k] and now - flips[k].t < REVERSE_HOLD then
			nflips[k] = flips[k]
		end
		if lvl > 0 then new[k] = lvl end
	end
	for k in pairs(old) do one(k) end
	for k in pairs(exact) do if old[k] == nil then one(k) end end
	return new, nflips, catching
end

-- Emitters ---------------------------------------------------------------------------------

local function collect(e, newfield)
	local keys = {}
	if e and e.field then
		for k in pairs(e.field) do keys[k] = true end
	end
	if newfield then
		for k in pairs(newfield) do keys[k] = true end
	end
	for k in pairs(pend) do keys[k] = true end
	return keys
end

local function stop_emitter(id, stats)
	local e = emitters[id]
	if not e then return end
	local keys = collect(e, nil)
	emitters[id] = nil
	apply(keys, stats, next(emitters) == nil)
end

-- Paint emitter `id` with its light centred on src.
local function paint_at(id, e, src, level, now, memo, stats)
	local field = compute_field(src, level, now, memo)
	local keys = collect(emitters[id], field)
	emitters[id] = e
	e.src, e.level, e.field, e.last, e.force = src, level, field, now, false
	for _ in pairs(field) do stats.cells = stats.cells + 1 end
	apply(keys, stats, false)
	-- The map changed under the light (seen while writing; the cache is fresh now): spread
	-- it again at the next update.
	if stats.external > 0 then e.force = true end
end

-- Paint a holder's light: one source at the point (px, base.y, pz). Only map blocks with a
-- face whose level changed are touched (all of them after an outside change).
local function paint_player(id, e, base, px, pz, L, now, memo, stats, still, direct)
	local exact = compute_exact(base, px, pz, L, now, memo)
	local old = e.field or {}
	local new, flips, catching = guard_levels(old, exact, e.flips or {}, L, now, still, direct, e.last)
	local keys = {}
	if e.force then
		for k in pairs(old) do keys[k] = true end
		for k in pairs(new) do keys[k] = true end
	else
		for k, l in pairs(old) do if new[k] ~= l then keys[k] = true end end
		for k in pairs(new) do if old[k] == nil then keys[k] = true end end
	end
	for k in pairs(pend) do keys[k] = true end
	emitters[id] = e
	e.src, e.px, e.pz, e.level, e.field, e.flips = base, px, pz, L, new, flips
	e.last, e.force, e.catching = now, false, catching
	for _ in pairs(new) do stats.cells = stats.cells + 1 end
	if next(keys) then apply(keys, stats, false) end
	if stats.external > 0 then e.force = true end
end

local function stop_all()
	local stats = new_stats()
	local keys = {}
	for k in pairs(orig) do keys[k] = true end
	for k in pairs(pend) do keys[k] = true end
	emitters = {}
	apply(keys, stats, true)
	return stats
end

-- Repairs ----------------------------------------------------------------------------------

local function block_near_light(bx, by, bz)
	local cx, cy, cz = bx * 16 + 8, by * 16 + 8, bz * 16 + 8
	for _, e in pairs(emitters) do
		local s = e.src
		if s and max(abs(cx - s.x), abs(cy - s.y), abs(cz - s.z)) <= e.level + NEAR_MARGIN then
			return true
		end
	end
	return false
end

local function repair_block(bk)
	local bx, by, bz = bkey_xyz(bk)
	local pmin = {x = bx * 16, y = by * 16, z = bz * 16}
	local set = bkeys[bk]
	if set then
		local list = {}
		for k in pairs(set) do list[#list + 1] = k end
		for _, k in ipairs(list) do
			untrack(k)
			pend[k] = nil
		end
	end
	core.fix_light(pmin, {x = pmin.x + 15, y = pmin.y + 15, z = pmin.z + 15})
	dirty[bk] = nil
	storage_changed = true
end

local function repair_dirty(limit)
	local n = 0
	for bk in pairs(dirty) do
		if n >= limit then return n end
		local bx, by, bz = bkey_xyz(bk)
		if not block_near_light(bx, by, bz) then
			repair_block(bk)
			n = n + 1
		end
	end
	return n
end

local function save()
	local list = {}
	for bk in pairs(bkeys) do list[#list + 1] = string.format("%d", bk) end
	for bk in pairs(dirty) do
		if not bkeys[bk] then list[#list + 1] = string.format("%d", bk) end
	end
	storage:set_string("blocks", table.concat(list, ","))
	storage_changed = false
end

do -- blocks a crash left painted: fix_light them before any light is painted again
	for s in storage:get_string("blocks"):gmatch("%d+") do
		recovery[#recovery + 1] = tonumber(s)
	end
end

-- Errors -----------------------------------------------------------------------------------

-- Run f; on an error stop the mod and put every light back. Used for the globalstep and for
-- the dig and place callbacks (they write to the map too since 1.0.1).
local function guarded(f)
	if failed then return end
	local ok, err = xpcall(f, debug.traceback)
	if not ok then
		failed = true
		core.log("error", "[light_works] Stopped after an error; lights are being restored. "
			.. tostring(err))
		pcall(stop_all)
		pcall(save)
	end
end

-- Node changes inside painted light --------------------------------------------------------
-- When a block is dug or placed, the engine relights the cells around it at once and reads
-- this mod's paint as if it were real light. Left alone, that copy of the paint is later
-- taken for the real light and stays (1.0.0: a dug tunnel stayed lit until the torch was put
-- away). So, in the same server step: the real light is put back in the blocks around the
-- change, core.fix_light recomputes the changed block(s), and the lights are painted again.
-- (Engine behaviour as remembered, not read in its source: a dig or placement relights at
-- once, before the callbacks; fix_light repairs block by block and reads the light of the
-- cells next to each block.)

-- Put back the real light of the painted cells in the map blocks of `set` and stop tracking
-- them. A cell the engine changed (or that no longer holds light) keeps what the engine wrote,
-- and its block goes into `changed`. Returns how many cells were tracked there.
local function unpaint(set, changed, now)
	local count = 0
	for bk in pairs(set) do
		local cells = bkeys[bk]
		if cells then
			local list = {}
			for k in pairs(cells) do list[#list + 1] = k end
			count = count + #list
			local bx, by, bz = bkey_xyz(bk)
			local pmin = {x = bx * 16, y = by * 16, z = bz * 16}
			local vm = core.get_voxel_manip()
			local emin, emax = vm:read_from_map(pmin, {x = pmin.x + 15, y = pmin.y + 15, z = pmin.z + 15})
			local c = cache[bk]
			local data = vm:get_data(c and c.data)
			if c then c.t = now else cache[bk] = {data = data, t = now} end
			local light = vm:get_light_data(light_buf)
			local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
			local write = false
			for _, k in ipairs(list) do
				local x, y, z = key_xyz(k)
				local i = area:index(x, y, z)
				if passable[data[i]] and light[i] == wrote[k] then
					light[i] = orig[k]
					write = true
				else
					changed[bk] = true
				end
				untrack(k)
				pend[k] = nil
			end
			if write then
				vm:set_light_data(light)
				vm:write_to_map(false)
			end
			if vm.close then vm:close() end
		end
	end
	return count
end

local function node_changed(pos, node)
	local x, y, z = round(pos.x), round(pos.y), round(pos.z)
	local k = key_of(x, y, z)
	local bx, by, bz = floor(x / 16), floor(y / 16), floor(z / 16)
	cache[bkey_of(bx, by, bz)] = nil
	local now = now_s()
	local memo = {}
	-- Lights whose field touches the cell spread again (a passage opened, a wall placed).
	local again = {}
	for id, e in pairs(emitters) do
		local f = e.field
		if f and (f[k] or f[k + 1] or f[k - 1] or f[k + 65536] or f[k - 65536]
				or f[k + 4294967296] or f[k - 4294967296]) then
			e.force = true
			again[id] = true
		end
	end
	-- The engine's relight read paint only if a cell next to this one was painted. A light
	-- source dug or placed changes real light up to a map block away.
	local def = node and core.registered_nodes[node.name]
	local source = def ~= nil and (tonumber(def.light_source) or 0) > 0
	local near_paint, open_next = false, false
	for d = 1, 6 do
		local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
		if orig[key_of(nx, ny, nz)] then
			near_paint = true
		elseif passable[cid_at(nx, ny, nz, now, memo)] then
			open_next = true
		end
	end
	if not near_paint and not source then return end
	-- The map blocks to repair, as a box: the cell's own block. (The engine's repair also clears
	-- and spreads light across the block's borders, as far as known.) One block all round when
	-- a light source came or went, or when the opened cell lets the copied paint run on into
	-- cells this mod never painted (a cave broken into): a safety margin in case the engine's
	-- repair stays inside its box.
	local lo, hi
	if source or (open_next and passable[cid_at(x, y, z, now, memo)]) then
		lo = {x = bx - 1, y = by - 1, z = bz - 1}
		hi = {x = bx + 1, y = by + 1, z = bz + 1}
	else
		lo = {x = bx, y = by, z = bz}
		hi = {x = bx, y = by, z = bz}
	end
	-- Unpaint the box and one block all round it (fix_light reads the light next to what it
	-- repairs). Where the engine changed painted cells, grow the box to that block (up to
	-- FIX_REACH blocks from the changed one) and unpaint around it as well.
	local done, changed, cells = {}, {}, 0
	while true do
		local ring = {}
		for ox = lo.x - 1, hi.x + 1 do
			for oy = lo.y - 1, hi.y + 1 do
				for oz = lo.z - 1, hi.z + 1 do
					local b = bkey_of(ox, oy, oz)
					if not done[b] then
						done[b] = true
						ring[b] = true
					end
				end
			end
		end
		cells = cells + unpaint(ring, changed, now)
		local grew = false
		for b in pairs(changed) do
			local cx, cy, cz = bkey_xyz(b)
			local outside = cx < lo.x or cx > hi.x or cy < lo.y or cy > hi.y or cz < lo.z or cz > hi.z
			if outside and abs(cx - bx) <= FIX_REACH and abs(cy - by) <= FIX_REACH
					and abs(cz - bz) <= FIX_REACH then
				lo.x, lo.y, lo.z = min(lo.x, cx), min(lo.y, cy), min(lo.z, cz)
				hi.x, hi.y, hi.z = max(hi.x, cx), max(hi.y, cy), max(hi.z, cz)
				grew = true
			end
		end
		if not grew then break end
	end
	-- A light source far from any paint: the engine's own relight is right.
	if cells == 0 then return end
	core.fix_light({x = lo.x * 16, y = lo.y * 16, z = lo.z * 16},
		{x = hi.x * 16 + 15, y = hi.y * 16 + 15, z = hi.z * 16 + 15})
	for ox = lo.x, hi.x do
		for oy = lo.y, hi.y do
			for oz = lo.z, hi.z do dirty[bkey_of(ox, oy, oz)] = nil end
		end
	end
	-- Changed blocks past the reach: the old way, repaired once no light is near.
	for b in pairs(changed) do
		local cx, cy, cz = bkey_xyz(b)
		if cx < lo.x or cx > hi.x or cy < lo.y or cy > hi.y or cz < lo.z or cz > hi.z then
			dirty[b] = true
		end
	end
	storage_changed = true
	-- Paint every light with cells in the unpainted blocks again now, in this server step, so
	-- the area is never seen without its light. Faces take their levels at once (as after any
	-- change in the map).
	for id, e in pairs(emitters) do
		local hit = again[id]
		if not hit and e.field then
			for fk in pairs(e.field) do
				if done[bkey_of_key(fk)] then
					hit = true
					break
				end
			end
		end
		if hit then
			e.force = true
			if e.px then
				paint_player(id, e, e.src, e.px, e.pz, e.level, now, memo, new_stats(), true, true)
			else
				paint_at(id, e, e.src, e.level, now, memo, new_stats())
			end
		end
	end
end

-- dignode passes the old node, placenode the new one: either way the node that came or went.
core.register_on_dignode(function(pos, oldnode)
	guarded(function() node_changed(pos, oldnode) end)
end)
core.register_on_placenode(function(pos, newnode)
	guarded(function() node_changed(pos, newnode) end)
end)

-- Held lights ------------------------------------------------------------------------------

-- Light sources --------------------------------------------------------------------------

-- Lights for items that cannot carry a light_source of their own (light_works.register_light).
local item_levels = {}
-- A few vanilla items glow when held (light_works.glowing_items, on by default; many
-- dynamic-light mods do this, Minecraft itself does not).
local GLOWING = {
	["mcl_buckets:bucket_lava"] = 14,
	["mcl_mobitems:blaze_rod"] = 10,
	["mcl_nether:glowstone_dust"] = 8,
	["mcl_mobitems:magma_cream"] = 8,
}
local light_cache = {} -- item name -> level (definitions do not change after loading)

-- The light an item gives: a registered level, else the larger of its own light_source
-- (any item, so lanterns, torches and a future glowing armor piece or tool all count) and
-- its light_works_glow group.
local function item_light(stack)
	if not stack or stack:is_empty() then return 0 end
	local name = stack:get_name()
	local l = light_cache[name]
	if l then return l end
	l = item_levels[name]
	if not l then
		local def = core.registered_items[name]
		l = def and tonumber(def.light_source) or 0
		local g = core.get_item_group(name, "light_works_glow")
		if g > l then l = g end
		if GLOWING_ITEMS and GLOWING[name] and GLOWING[name] > l then l = GLOWING[name] end
	end
	l = max(0, min(core.LIGHT_MAX, floor(l)))
	light_cache[name] = l
	return l
end

local has_offhand = core.get_modpath("mcl_offhand") ~= nil
local has_armor = core.get_modpath("mcl_armor") ~= nil

-- Where a player's light can come from. Each source gives an ItemStack or a list of them;
-- the brightest item of all of them sets the light. Other mods add theirs with
-- light_works.register_source.
local sources = {
	function(player) return player:get_wielded_item() end,
}
if OFFHAND and has_offhand then
	sources[#sources + 1] = function(player)
		-- Mineclonia internal (HUD/mcl_offhand/init.lua): returns the offhand ItemStack.
		local api = rawget(_G, "mcl_offhand")
		if api and api.get_offhand then return api.get_offhand(player) end
	end
end
if ARMOR and has_armor then
	sources[#sources + 1] = function(player)
		-- Mineclonia keeps worn armor in the player's "armor" list: 2 head, 3 torso, 4 legs,
		-- 5 feet (1 only passes an item on to its slot). ITEMS/mcl_armor/player.lua, api.lua.
		local inv = player:get_inventory()
		if not inv or inv:get_size("armor") < 5 then return nil end
		return {inv:get_stack("armor", 2), inv:get_stack("armor", 3),
			inv:get_stack("armor", 4), inv:get_stack("armor", 5)}
	end
end

local function source_light(r)
	if type(r) ~= "table" and type(r) ~= "userdata" then return 0 end
	if r.get_name then return item_light(r) end
	local best = 0
	for _, stack in ipairs(r) do
		if stack and stack.get_name then
			local l = item_light(stack)
			if l > best then best = l end
		end
	end
	return best
end

local warned = {} -- source index -> true once its failure was logged

local function held_light(player)
	local l = 0
	for i, fn in ipairs(sources) do
		-- Guarded, so a broken source (another mod's, or a changed Mineclonia internal)
		-- cannot stop the light.
		local ok, r = pcall(fn, player)
		if ok then
			local sl = source_light(r)
			if sl > l then l = sl end
		elseif not warned[i] then
			warned[i] = true -- once per source, not every check
			core.log("warning", "[light_works] A light source failed: " .. tostring(r))
		end
	end
	if l < MIN_LIGHT then return 0 end
	return l
end

-- Light already at the hand, without this mod's own paint.
local function real_light(p)
	local k = key_of(p.x, p.y, p.z)
	local v = orig[k]
	if not v then return core.get_node_light(p) or 0 end
	local t = core.get_timeofday() or 0.5
	if t > 0.25 and t < 0.75 then return v % 16 end
	return floor(v / 16)
end

-- The position the light follows (layer 5 of the flicker guard: steady input). Player
-- positions reach the server unevenly (a step with no news, then half a node at once);
-- this one is predicted from the velocity every step and eased onto the real position, so
-- it advances evenly. Sideways only: up and down uses the held height below.
local function smooth_pos(name, pos, vel, now)
	local s = smooth[name]
	if not s or now - s.t > 1 then
		smooth[name] = {x = pos.x, z = pos.z, t = now}
		return pos.x, pos.z
	end
	local dt = now - s.t
	s.t = now
	local px, pz = s.x, s.z
	if vel then px, pz = px + vel.x * dt, pz + vel.z * dt end
	local dx, dz = pos.x - px, pos.z - pz
	if abs(dx) > SNAP_DISTANCE or abs(dz) > SNAP_DISTANCE then
		s.x, s.z = pos.x, pos.z
		return pos.x, pos.z
	end
	local a = dt >= SMOOTH_TIME and 1 or dt / SMOOTH_TIME
	s.x, s.z = px + dx * a, pz + dz * a
	return s.x, s.z
end

-- The hand's cell. Its height is held (hysteresis) so a jump does not move the light up and
-- down; sideways it is simply the cell holding the point (the light is continuous there).
local function hand_cell(e, px, y, pz)
	local hy = y + HAND_HEIGHT
	local c = e and e.hand
	local cy = round(hy)
	if c and abs(hy - c.y) <= 0.5 + HYSTERESIS_Y then cy = c.y end
	local r = {x = round(px), y = round(hy), z = round(pz)}
	return {x = r.x, y = cy, z = r.z}, r
end

local function note_debug(name, level, stats, us)
	local d = debug_players[name]
	if not d then return end
	d.moves = d.moves + 1
	d.blocks = d.blocks + stats.blocks
	d.waiting = d.waiting + stats.waiting
	if us > d.worst then d.worst = us end
	d.level = level
end

local function send_debug(now)
	for name, d in pairs(debug_players) do
		if now - d.t >= 1 then
			if d.moves > 0 then
				core.chat_send_player(name, S(
					"Light @1: @2 moves, @3 map blocks redrawn, @4 waiting, worst @5 ms (last second).",
					tostring(d.level), tostring(d.moves), tostring(d.blocks), tostring(d.waiting),
					string.format("%.1f", d.worst / 1000)))
			end
			d.t, d.moves, d.blocks, d.waiting, d.worst = now, 0, 0, 0, 0
		end
	end
end

-- Main loop --------------------------------------------------------------------------------

local save_timer, prune_timer = 0, 0
local rr = 0 -- round-robin start, so no player waits behind the others every step

local function update_player(player, now, memo)
	local name = player:get_player_name()
	local id = "player:" .. name
	local e = emitters[id]
	local pos = player:get_pos()
	local vel = player:get_velocity()
	local px, pz = smooth_pos(name, pos, vel, now)
	local hand, raw = hand_cell(e, px, pos.y, pz)
	local h = holders[name]
	if not h or now - h.t >= ITEM_CHECK then
		local L = 0
		if ENABLED and player:get_hp() > 0 then L = held_light(player) end
		-- already this bright where the hand is: no need for our light
		h = {level = L, t = now, bright = L > 0 and real_light(hand) >= L}
		holders[name] = h
	end
	local L = h.level
	if L == 0 or h.bright then
		if e then
			local t0 = core.get_us_time()
			local stats = new_stats()
			stop_emitter(id, stats)
			note_debug(name, 0, stats, core.get_us_time() - t0)
		end
		return 0
	end
	local base = find_base(hand, raw, now, memo)
	if not base then
		if e then stop_emitter(id, new_stats()) end
		return 0
	end
	-- Stopped: hardly any speed and the real position (not the smoothed one, which may still
	-- be settling) has not moved since the last update. Pushed or carried counts as moving.
	local still = (not vel or vel.x * vel.x + vel.z * vel.z < STOP_SPEED * STOP_SPEED)
		and not (e and abs(pos.x - e.rx) + abs(pos.z - e.rz) >= DEADBAND)
	if not e then
		e = {hand = hand, rx = pos.x, rz = pos.z}
		local t0 = core.get_us_time()
		local stats = new_stats()
		paint_player(id, e, base, px, pz, L, now, memo, stats, still, true)
		note_debug(name, L, stats, core.get_us_time() - t0)
		return 1
	end
	e.hand = hand
	-- Layer 1 of the flicker guard: nothing happens until the holder moved DEADBAND (or a
	-- face is still catching up, the map changed, or the held item changed).
	local moved = abs(px - e.px) + abs(pz - e.pz) >= DEADBAND or base.y ~= e.src.y
	if not (moved or e.catching or e.force or e.level ~= L) then return 0 end
	if now - e.last < MIN_INTERVAL then return 0 end
	-- A new item, a teleport or a change in the map (a wall placed, a passage dug) sets the
	-- faces at once, the way the engine relights around a real torch.
	local direct = e.level ~= L or manhattan(base, e.src) > CATCH_UP or e.force
	local t0 = core.get_us_time()
	local stats = new_stats()
	e.rx, e.rz = pos.x, pos.z
	paint_player(id, e, base, px, pz, L, now, memo, stats, still, direct)
	note_debug(name, L, stats, core.get_us_time() - t0)
	return 1
end

local function step(dtime)
	if #recovery > 0 then
		for _ = 1, REPAIRS_PER_STEP do
			local bk = table.remove(recovery)
			if not bk then break end
			local bx, by, bz = bkey_xyz(bk)
			local pmin = {x = bx * 16, y = by * 16, z = bz * 16}
			core.fix_light(pmin, {x = pmin.x + 15, y = pmin.y + 15, z = pmin.z + 15})
			storage_changed = true
		end
		if #recovery == 0 then
			core.log("action", "[light_works] Repaired map blocks left lit by an earlier crash.")
		end
		return
	end

	local now = now_s()
	save_timer = save_timer + dtime
	if save_timer >= SAVE_INTERVAL then
		save_timer = 0
		if storage_changed then save() end
	end
	prune_timer = prune_timer + dtime
	if prune_timer >= CACHE_AGE then
		prune_timer = 0
		prune_cache(now)
	end

	local memo = {}
	local moves = 0
	local players = core.get_connected_players()
	local n = #players
	rr = rr + 1
	for j = 1, n do
		local player = players[(rr + j) % n + 1]
		local e = emitters["player:" .. player:get_player_name()]
		if moves < UPDATES_PER_STEP or not e then
			moves = moves + update_player(player, now, memo)
		end
	end
	-- Nothing written for a while (everyone standing still): write the faint changes that
	-- were waiting, so the light is exact.
	if next(pend) and now - last_change >= SETTLE_AFTER then
		apply(collect(nil, nil), new_stats(), true)
	end
	repair_dirty(REPAIRS_PER_STEP)
	send_debug(now)
end

core.register_globalstep(function(dtime)
	guarded(function() step(dtime) end)
end)

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		if def.paramtype == "light" then passable[core.get_content_id(name)] = true end
	end
	passable[core.CONTENT_IGNORE] = nil
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	debug_players[name] = nil
	holders[name] = nil
	smooth[name] = nil
	if failed then return end
	stop_emitter("player:" .. name, new_stats())
end)

core.register_on_shutdown(function()
	if failed then return end
	stop_all()
	for bk in pairs(dirty) do repair_block(bk) end
	save()
end)

-- API (for later items: flares, dropped lanterns, helmets) ---------------------------------

-- Light at pos with the given level (1-14) under the name id; level 0 or nil removes it.
-- A moved light jumps to its new place (no gliding), at most `max_rate` times a second.
function M.set_light(id, pos, level)
	assert(type(id) == "string" and not id:find("^player:"), "light_works: bad light id")
	local stats = new_stats()
	if not level or level <= 0 then
		stop_emitter(id, stats)
		return stats
	end
	level = min(core.LIGHT_MAX, floor(level))
	local p = {x = round(pos.x), y = round(pos.y), z = round(pos.z)}
	local e = emitters[id]
	local now = now_s()
	if e and e.level == level and not e.force and manhattan(e.src, p) == 0 then
		return stats
	end
	if e and now - e.last < MIN_INTERVAL then return stats end
	local memo = {}
	if not open_at(p, now, memo) then
		stop_emitter(id, stats)
		return stats
	end
	paint_at(id, e or {}, p, level, now, memo, stats)
	return stats
end

-- An item gives this light when held or worn (1-14), for items that cannot carry a
-- light_source of their own. Call while loading.
function M.register_light(name, level)
	assert(type(name) == "string" and type(level) == "number", "light_works: bad register_light")
	item_levels[name] = max(0, min(core.LIGHT_MAX, floor(level)))
	light_cache[name] = nil
end

-- Another place a player's light can come from (a backpack slot, a trinket, an
-- enchantment): fn(player) returns an ItemStack, a list of ItemStacks or nil. The brightest
-- item of all sources sets the light.
function M.register_source(fn)
	assert(type(fn) == "function", "light_works: bad register_source")
	sources[#sources + 1] = fn
end

function M.status()
	local lights, cells, blocks, waiting, repairs = 0, 0, 0, 0, 0
	for _ in pairs(emitters) do lights = lights + 1 end
	for _ in pairs(orig) do cells = cells + 1 end
	for _ in pairs(bkeys) do blocks = blocks + 1 end
	for _ in pairs(pend) do waiting = waiting + 1 end
	for _ in pairs(dirty) do repairs = repairs + 1 end
	return {lights = lights, cells = cells, blocks = blocks, waiting = waiting, repairs = repairs}
end

-- Chat command -----------------------------------------------------------------------------

core.register_chatcommand("light_works", {
	params = "[debug]",
	description = S("Show what Light Works is doing; \"debug\" reports the light's work each second."),
	func = function(name, param)
		if param == "debug" then
			if debug_players[name] then
				debug_players[name] = nil
				return true, S("Light Works debug lines off.")
			end
			debug_players[name] = {t = now_s(), moves = 0, blocks = 0, waiting = 0, worst = 0, level = 0}
			return true, S("Light Works debug lines on.")
		end
		local s = M.status()
		if failed then return true, S("Light Works stopped after an error; see debug.txt.") end
		return true, S("Light Works: @1 lights, @2 lit cells in @3 map blocks, @4 waiting, @5 to repair.",
			tostring(s.lights), tostring(s.cells), tostring(s.blocks), tostring(s.waiting),
			tostring(s.repairs))
	end,
})

-- For the tests.
M._internal = {
	key_of = key_of, key_xyz = key_xyz, bkey_of = bkey_of, bkey_xyz = bkey_xyz, combine = combine,
	orig = function() return orig end, pend = function() return pend end,
	dirty = function() return dirty end, emitters = function() return emitters end,
	cache = function() return cache end, step = step,
}
