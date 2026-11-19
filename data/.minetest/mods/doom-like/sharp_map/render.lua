-- Map tiles: built on the server from the world, a little at a time.
--
-- The client's minimap cannot be read by mods, so the map is drawn here.
-- To stay light:
--   * Only ground near players is scanned: one 16x16 column chunk per
--     player every sharp_map.scan_interval seconds, nearest first.
--   * A chunk is scanned once per session, and again only when one of its
--     mapblocks changes (core.register_on_mapblocks_changed).
--   * Each scan reads a 16 x ~160 x 16 VoxelManip around the player's
--     height; nothing is generated (ungenerated ground reads as "ignore").
--   * Tiles are 128x128 nodes, 1 pixel per node, kept as 128 row strings
--     (64 KiB each). At most CACHE_MAX tiles stay in memory; the rest are
--     saved compressed in <world>/sharp_map/<dimension>/.
--   * A tile becomes a PNG only when someone opens the map over it, and is
--     sent once per version with core.dynamic_add_media (ephemeral). Every
--     PNG gets a name never used before in this session (a running number):
--     a client keeps a texture by name, and the same name cannot be sent
--     twice, so a reused name would show an old picture (1.2.0 fix: a tile
--     dropped from memory and loaded again used to restart at version 1 and
--     reuse its first name, so the map screen showed old or empty ground
--     that the minimap already showed). The
--     map screen is only redrawn when the player clicks something, so the
--     client builds a new map image per click, never continuously.
--
-- Drawing (1.2.0): a tile's picture with relief is drawn once and kept as
-- <tile>.png in the world folder (a saved, finished picture), so opening
-- the map later costs only a file read. It is deleted when the tile
-- changes and drawn again when needed. Drawing is spread over server
-- steps (sharp_map.draw_budget milliseconds per step): a map screen
-- shows at once with what is ready and fills in the rest, and a click
-- draws a changed tile right away only while that fits the budget.
-- redraw.lua uses the same queue to redraw old maps in the background.
--
-- Ground level: the game picks a column's biome at the column's ground
-- (and keeps no biome per chunk for mods to read), so each scan also notes
-- the ground of every column it paints: the first solid, non-liquid node
-- from the top (the sea floor under water). Saved in <tile>.gnd beside
-- the color tile, read back with sharp_map.ground_at() for biome names.
--
-- Colors come from Mineclonia's own mcl_maps/colors.json, read at runtime
-- (not copied): 3064 nodes, some with one color per param2 value for
-- biome-tinted grass and leaves. Blending follows mcl_maps/init.lua.
--
-- Relief (1.2.0, for the look of Luanti's own minimap): a tile keeps each
-- node's plain color and, beside it, its surface height (<tile>.hgt). The
-- shading is worked out only when a picture is made (map screen tile or
-- minimap piece), from the heights of all eight neighbours (a Sobel
-- gradient since 1.2.2, which follows slopes and ridges more finely than
-- the four direct ones), lit from the north-west: slopes facing north-west
-- are brighter, the others darker, so hills read as hills, as on Luanti's
-- minimap. Water is darkened by its depth (surface height minus the
-- ground level kept in <tile>.gnd), so sea floors show their shape. Because it is computed
-- when drawing, it is the same across chunk edges and can be retuned
-- without scanning again. Ground mapped before 1.2.0 has its old shading
-- baked into the color and no height; it is drawn as it was until it is
-- scanned again (the next time someone is near it).
--
-- Surface rule: a column is only updated if the scan starts in open air
-- that is in direct sunlight (1.2.3). Day light 15 comes only from the sky
-- (light sources reach at most 14, core.LIGHT_MAX), so a scan that starts
-- inside a cave (the player 80 nodes below the surface, in a cave system
-- with more caves above) never paints cave floors over the surface map;
-- before 1.2.3 open air alone was enough, and deep caves did. A cliff
-- taller than the scan is skipped the same way. In the Nether, which has a
-- bedrock roof and no sky, the scan starts at the player's head height
-- instead, and the End keeps the open-air rule. The surface map never
-- shows caves.
--
-- Cave layers (1.3.0): caves.lua maps caves into separate maps, one per
-- 16-node height band ("band" = floor(y / 16), the same as a mapblock
-- row), kept beside the surface in <world>/sharp_map/caves/. A cave map
-- is named by its map id dim .. "#c" .. band (see sharp_map.cave_mid);
-- every function here that takes a dimension also takes a map id, so
-- cave maps are saved, drawn, cached and sent exactly like the surface.
-- The minimap's cave view ("#v" ids, sharp_map.view_id) is put together
-- from several bands when its pieces are made (see the end of this file).

local modname = core.get_current_modname()
local cfg = sharp_map.settings

local TILE = 128
local CHUNK = 16
local ROW_BYTES = TILE * 4
local EMPTY_PIXEL = "\0\0\0\0"
local EMPTY_ROW = EMPTY_PIXEL:rep(TILE)
-- Ground level of every column, kept beside the colors: 2 bytes per node
-- (y + 32768, 0 = not known), same rows as the color tile. See ground_at().
local GROUND_BYTES = TILE * 2
local EMPTY_GROUND_ROW = ("\0\0"):rep(TILE)
-- Relief: brightness change per node of height difference between the
-- neighbours on either side, and its limit.
local RELIEF = 8
local RELIEF_MAX = 48
-- Water depth (1.2.2): water darkens by this much per node deeper than
-- DEPTH_MIN, up to DEPTH_MAX, so sea floors and river beds show their shape.
local DEPTH_MIN, DEPTH, DEPTH_MAX = 2, 3, 40
-- Tiles kept in memory (1.3.0: 128, was 64; the cave view reads up to
-- four bands and the surface for each tile it shows).
local CACHE_MAX = 128
local SAVE_INTERVAL = 30

local floor = math.floor
local schar = string.char

local root = core.get_worldpath() .. "/sharp_map"
local media_dir = root .. "/media"
core.mkdir(media_dir)

-- Remove PNGs left from the last session; they are made again on demand.
for _, file in ipairs(core.get_dir_list(media_dir, false) or {}) do
	if file:match("^sharp_map_.*%.png$") then
		os.remove(media_dir .. "/" .. file)
	end
end

------------------------------------------------------------------------
-- Colors (from mcl_maps/colors.json)
------------------------------------------------------------------------

local colors_by_cid = {} -- content id -> {r,g,b,a} or list of them by param2
local is_ground = {}     -- content id -> true for solid, non-liquid nodes
local c_air, c_ignore

local function load_colors()
	local path = core.get_modpath("mcl_maps")
	if not path then
		return nil, "mcl_maps not found"
	end
	local file = io.open(path .. "/colors.json", "r")
	if not file then
		return nil, "mcl_maps/colors.json not readable"
	end
	local data = core.parse_json(file:read("*all"))
	file:close()
	if type(data) ~= "table" then
		return nil, "mcl_maps/colors.json could not be parsed"
	end
	return data
end

core.register_on_mods_loaded(function()
	c_air = core.get_content_id("air")
	c_ignore = core.get_content_id("ignore")
	for name, def in pairs(core.registered_nodes) do
		if name ~= "air" and name ~= "ignore" and def.walkable ~= false
				and (def.liquidtype or "none") == "none" then
			is_ground[core.get_content_id(name)] = true
		end
	end
	local data, err = load_colors()
	if not data then
		core.log("warning", "[" .. modname .. "] " .. err .. "; the map will stay empty.")
		return
	end
	local n = 0
	for name, color in pairs(data) do
		if core.registered_nodes[name] and type(color) == "table" then
			colors_by_cid[core.get_content_id(name)] = color
			n = n + 1
		end
	end
	core.log("action", "[" .. modname .. "] Map colors loaded for " .. n .. " nodes.")
end)

------------------------------------------------------------------------
-- Tile store
------------------------------------------------------------------------

local tiles = {}   -- key -> tile { rows, dirty, ver, png_ver, png, used }
-- Keys with no file on disk (1.3.0), so looking for a band nobody has
-- mapped does not read the disk every time; cleared when a tile is made.
local absent = {}
local n_absent = 0
local n_tiles = 0
local clock = 0
local png_serial = 0 -- running number for PNG names; never reused in a session

-- A dimension or map id as a file-name-safe word. A minus becomes "m"
-- (1.3.0), so band -3 and band 3 never share a name; dimension names have
-- no minus, so surface folders keep their names.
local function safe_dim(dim)
	return (tostring(dim or "world"):gsub("%-", "m"):gsub("[^%w_]", "_"))
end

-- Map ids of cave layers (1.3.0). A cave map: dim .. "#c" .. band. The
-- minimap's cave view centered on a band: dim .. "#v" .. band.
function sharp_map.cave_mid(dim, band)
	return tostring(dim or "world") .. "#c" .. band
end

function sharp_map.view_id(dim, band)
	return tostring(dim or "world") .. "#v" .. band
end

-- The dimension and band of a cave map id, or nil for any other id.
local function parse_cave(mid)
	local d, b = tostring(mid or ""):match("^(.*)#c(%-?%d+)$")
	if d then
		return d, tonumber(b)
	end
end

local function tile_key(dim, tx, tz)
	local d, b = parse_cave(dim)
	if d then
		return "caves/" .. safe_dim(d) .. "_b" .. safe_dim(b) .. "/" .. tx .. "_" .. tz
	end
	return safe_dim(dim) .. "/" .. tx .. "_" .. tz
end

-- The folder a tile key's files go in.
local function key_dir(key)
	return root .. "/" .. key:match("^(.*)/")
end

local function tile_path(key)
	return root .. "/" .. key .. ".bin"
end

local function ground_path(key)
	return root .. "/" .. key .. ".gnd"
end

local function height_path(key)
	return root .. "/" .. key .. ".hgt"
end

-- The finished picture of a tile (with relief), kept between sessions.
local function cache_path(key)
	return root .. "/" .. key .. ".png"
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function save_tile(key, tile)
	if not tile.dirty and not tile.gdirty and not tile.hdirty then
		return
	end
	core.mkdir(key_dir(key))
	if tile.dirty then
		core.safe_file_write(tile_path(key), core.compress(table.concat(tile.rows), "deflate"))
		tile.dirty = false
	end
	if tile.gdirty then
		core.safe_file_write(ground_path(key), core.compress(table.concat(tile.gnd), "deflate"))
		tile.gdirty = false
	end
	if tile.hdirty then
		core.safe_file_write(height_path(key), core.compress(table.concat(tile.hgt), "deflate"))
		tile.hdirty = false
	end
end

-- A 2-byte-per-node layer (ground or height) from disk, as TILE row
-- strings, or all unknown if there is no valid file.
local function read_layer(path)
	local file = io.open(path, "rb")
	if file then
		local ok, raw = pcall(core.decompress, file:read("*all"), "deflate")
		file:close()
		if ok and type(raw) == "string" and #raw == GROUND_BYTES * TILE then
			local out = {}
			for r = 1, TILE do
				out[r] = raw:sub((r - 1) * GROUND_BYTES + 1, r * GROUND_BYTES)
			end
			return out
		end
	end
	local out = {}
	for r = 1, TILE do
		out[r] = EMPTY_GROUND_ROW
	end
	return out
end

local function evict()
	if n_tiles <= CACHE_MAX then
		return
	end
	-- The oldest tile with nothing to save goes first (1.4.2): dropping a
	-- changed one means writing it to disk in the middle of a step.
	local oldest_key, oldest, dirty_key, dirty
	for key, tile in pairs(tiles) do
		if tile.used < clock then
			if tile.dirty or tile.gdirty or tile.hdirty then
				if not dirty or tile.used < dirty.used then
					dirty_key, dirty = key, tile
				end
			elseif not oldest or tile.used < oldest.used then
				oldest_key, oldest = key, tile
			end
		end
	end
	if not oldest then
		oldest_key, oldest = dirty_key, dirty
	end
	if not oldest then
		return
	end
	save_tile(oldest_key, oldest)
	-- Its PNG will be made again, under a new name, if it is needed.
	if oldest.png then
		os.remove(media_dir .. "/" .. oldest.png)
	end
	tiles[oldest_key] = nil
	n_tiles = n_tiles - 1
end

-- Returns the tile, loading it from disk. With CREATE, an empty tile is
-- made if none exists; otherwise nil is returned for unexplored tiles.
local function get_tile(key, create)
	clock = clock + 1
	local tile = tiles[key]
	if not tile and not create and absent[key] then
		return nil
	end
	if not tile then
		local rows
		local file = io.open(tile_path(key), "rb")
		if file then
			local ok, raw = pcall(core.decompress, file:read("*all"), "deflate")
			file:close()
			if ok and type(raw) == "string" and #raw == ROW_BYTES * TILE then
				rows = {}
				for r = 1, TILE do
					rows[r] = raw:sub((r - 1) * ROW_BYTES + 1, r * ROW_BYTES)
				end
			end
		end
		if not rows then
			if not create then
				if n_absent > 50000 then
					absent, n_absent = {}, 0
				end
				absent[key] = true
				n_absent = n_absent + 1
				return nil
			end
			if absent[key] then
				absent[key] = nil
				n_absent = n_absent - 1
			end
			rows = {}
			for r = 1, TILE do
				rows[r] = EMPTY_ROW
			end
		end
		-- Ground levels and surface heights: from <tile>.gnd and <tile>.hgt
		-- if there are any, else all unknown (maps made before these were
		-- kept fill in as they are scanned again).
		local gnd = read_layer(ground_path(key))
		local hgt = read_layer(height_path(key))
		tile = { rows = rows, gnd = gnd, hgt = hgt, dirty = false, gdirty = false, hdirty = false,
			ver = 1, used = clock, cached = file_exists(cache_path(key)) }
		tiles[key] = tile
		n_tiles = n_tiles + 1
		evict()
	end
	tile.used = clock
	return tile
end

-- The ground level the map recorded for the node column at X, Z in
-- dimension DIM, or nil if that ground has not been scanned since ground
-- levels were kept.
function sharp_map.ground_at(dim, x, z)
	local tx, tz = floor(x / TILE), floor(z / TILE)
	local tile = get_tile(tile_key(dim, tx, tz), false)
	if not tile then
		return nil
	end
	local row = tile.gnd[TILE - (z - tz * TILE)]
	local i = (x - tx * TILE) * 2 + 1
	local hi, lo = row:byte(i, i + 1)
	local v = hi * 256 + lo
	if v == 0 then
		return nil
	end
	return v - 32768
end

function sharp_map.save_all()
	for key, tile in pairs(tiles) do
		save_tile(key, tile)
	end
end

core.register_on_shutdown(sharp_map.save_all)

------------------------------------------------------------------------
-- Scanning one 16x16 chunk
------------------------------------------------------------------------

local vm_data, vm_param2, vm_light = {}, {}, {}

-- Dimensions where the surface is the ground under the sky. No
-- dimension (without mcl_worlds) counts as the overworld.
local function has_sky(dim)
	return dim == nil or dim == "overworld" or dim == "world"
end

-- Per-chunk change counters (this session), for the minimap's pieces.
local chunk_ver = {} -- "dim:cx,cz" -> number


-- Front-to-back alpha blending down one column, as in mcl_maps.
-- Returns r, g, b, the shading height and the ground level (the first
-- solid, non-liquid node from the top, which under water is the sea floor;
-- YBOT if there is none in range), or nil if nothing was found.
local function column_color(data, param2, area, x, z, ytop, ybot)
	local r, g, b, alpha, height, ground = 0, 0, 0, 0, nil, nil
	local stopped = ybot
	for y = ytop, ybot, -1 do
		local i = area:index(x, y, z)
		local cid = data[i]
		if cid ~= c_air and cid ~= c_ignore then
			if not ground and is_ground[cid] then
				ground = y
			end
			local color = colors_by_cid[cid]
			if color and type(color[1]) == "table" then
				color = color[param2[i] + 1] or color[1]
			end
			if color then
				local f = (color[4] or 255) / 255 * (1 - alpha)
				r = r + f * color[1]
				g = g + f * color[2]
				b = b + f * color[3]
				alpha = alpha + f
				if alpha > 0.70 and not height then
					height = y
				end
				if alpha >= 0.99 then
					stopped = y
					break
				end
			end
		end
	end
	if alpha <= 0 then
		return nil
	end
	height = height or ybot
	if not ground then
		-- The colors blend to opaque a few nodes below the surface of
		-- water, long before its floor: keep looking down for the ground.
		for y = stopped - 1, ybot, -1 do
			if is_ground[data[area:index(x, y, z)]] then
				ground = y
				break
			end
		end
	end
	return r / alpha, g / alpha, b / alpha, height, ground or ybot
end

local function clamp_byte(v)
	v = floor(v + 0.5)
	return v < 0 and 0 or (v > 255 and 255 or v)
end

-- A ground level as 2 bytes (y + 32768; 0 means not known).
local function encode_ground(y)
	local v = math.max(1, math.min(65535, floor(y) + 32768))
	return schar(floor(v / 256), v % 256)
end

-- Scan the chunk whose lowest corner is (cx0, cz0) for a player at
-- height PY in dimension DIM. Returns true if any pixel changed.
-- YTOP and YBOT, if given, replace the range worked out from PY (the
-- background redraw, which has no player there, passes them). Returns
-- whether any pixel changed, and how many columns passed the surface rule.
local function scan_chunk(dim, cx0, cz0, py, ytop, ybot)
	if not ytop then
		if dim == "nether" then
			ytop, ybot = floor(py) + 1, floor(py) - 48
		else
			ytop, ybot = floor(py) + 80, floor(py) - 80
		end
	end
	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map(vector.new(cx0, ybot, cz0),
		vector.new(cx0 + CHUNK - 1, ytop, cz0 + CHUNK - 1))
	local data = vm:get_data(vm_data)
	local param2 = vm:get_param2_data(vm_param2)
	local light = has_sky(dim) and vm:get_light_data(vm_light)
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })

	local tx, tz = floor(cx0 / TILE), floor(cz0 / TILE)
	local key = tile_key(dim, tx, tz)
	local tile = get_tile(key, true)
	local col0 = cx0 - tx * TILE -- 0-based column of the chunk in the tile

	local changed = false
	local accepted = 0 -- columns that passed the surface rule
	for dz = 0, CHUNK - 1 do
		local z = cz0 + dz
		local row_index = TILE - (z - tz * TILE) -- north at the top
		local row = tile.rows[row_index]
		local grow = tile.gnd[row_index]
		local hrow = tile.hgt[row_index]
		local gparts, hparts = {}, {}
		local parts = {}
		for dx = 0, CHUNK - 1 do
			local x = cx0 + dx
			local px = col0 + dx
			local old = row:sub(px * 4 + 1, px * 4 + 4)
			local pixel = old
			local gold = grow:sub(px * 2 + 1, px * 2 + 2)
			local gnew = gold
			local hold = hrow:sub(px * 2 + 1, px * 2 + 2)
			local hnew = hold
			local ti = area:index(x, ytop, z)
			local top = data[ti]
			-- Open air at the top, and under the sky where there is one
			-- (day light, the low 4 bits of the light value, is 15 only in
			-- sunlight). Unloaded ground ("ignore") keeps the old rule.
			if (top == c_air and (not light or light[ti] % 16 == 15)) or top == c_ignore then
				accepted = accepted + 1
				local r, g, b, height, ground = column_color(data, param2, area, x, z, ytop, ybot)
				if r then
					gnew = encode_ground(ground)
					-- The plain color; relief is added when drawing.
					hnew = encode_ground(height)
					pixel = schar(clamp_byte(r), clamp_byte(g), clamp_byte(b), 255)
				end
			end
			if pixel ~= old then
				changed = true
			end
			if gnew ~= gold then
				tile.gdirty = true
			end
			if hnew ~= hold then
				-- A new height changes the relief of this pixel and its
				-- neighbours, so it counts as a change of the picture.
				tile.hdirty = true
				changed = true
			end
			parts[dx + 1] = pixel
			gparts[dx + 1] = gnew
			hparts[dx + 1] = hnew
		end
		tile.rows[row_index] = row:sub(1, col0 * 4) .. table.concat(parts)
			.. row:sub((col0 + CHUNK) * 4 + 1)
		tile.gnd[row_index] = grow:sub(1, col0 * 2) .. table.concat(gparts)
			.. grow:sub((col0 + CHUNK) * 2 + 1)
		tile.hgt[row_index] = hrow:sub(1, col0 * 2) .. table.concat(hparts)
			.. hrow:sub((col0 + CHUNK) * 2 + 1)
	end
	if changed then
		tile.dirty = true
		tile.ver = tile.ver + (tile.png_ver == tile.ver and 1 or 0)
		-- The saved picture no longer matches.
		if tile.cached then
			os.remove(cache_path(key))
			tile.cached = false
		end
		local ck = safe_dim(dim) .. ":" .. floor(cx0 / CHUNK) .. "," .. floor(cz0 / CHUNK)
		chunk_ver[ck] = (chunk_ver[ck] or 0) + 1
	end
	return changed, accepted
end


------------------------------------------------------------------------
-- Which chunk to scan next
------------------------------------------------------------------------

-- Chunk offsets within the scan radius, nearest first.
local OFFSETS = {}
do
	local r = cfg.scan_radius
	for dx = -r, r do
		for dz = -r, r do
			if dx * dx + dz * dz <= r * r then
				OFFSETS[#OFFSETS + 1] = { dx, dz, dx * dx + dz * dz }
			end
		end
	end
	table.sort(OFFSETS, function(a, b) return a[3] < b[3] end)
end

-- dim .. chunk key -> true once scanned (this session, until changed), or
-- the player's height band if no column passed the surface rule (deep
-- underground): it is tried again from another band, so ground first seen
-- from a cave is still mapped when the player comes up.
local scanned = {}
local BAND = 48
local n_scanned = 0

local function chunk_key(dim, cx, cz)
	return safe_dim(dim) .. ":" .. cx .. "," .. cz
end

-- Forget scanned chunks whose mapblocks changed, so they are scanned again.
if type(core.register_on_mapblocks_changed) == "function" then
	core.register_on_mapblocks_changed(function(modified_blocks)
		for hash in pairs(modified_blocks) do
			local bp = core.get_position_from_hash(hash)
			local dim = sharp_map.dimension_of(vector.new(bp.x * 16, bp.y * 16, bp.z * 16))
			local key = chunk_key(dim, bp.x, bp.z)
			if scanned[key] then
				scanned[key] = nil
				n_scanned = n_scanned - 1
			end
		end
	end)
end

local function scan_near(player)
	local pos = player:get_pos()
	local dim = sharp_map.dimension_of(pos)
	local pcx, pcz = floor(pos.x / CHUNK), floor(pos.z / CHUNK)
	for _, off in ipairs(OFFSETS) do
		local cx, cz = pcx + off[1], pcz + off[2]
		local key = chunk_key(dim, cx, cz)
		local band = floor(pos.y / BAND)
		local seen = scanned[key]
		if seen ~= true and seen ~= band then
			if not seen then
				n_scanned = n_scanned + 1
			end
			if n_scanned > 200000 then
				scanned, n_scanned = {}, 1
			end
			local _, accepted = scan_chunk(dim, cx * CHUNK, cz * CHUNK, pos.y)
			scanned[key] = accepted > 0 or band
			return
		end
	end
end

-- Saving (1.4.1): every SAVE_INTERVAL seconds the changed tiles are listed,
-- then saved one per server step (each is up to three compressed 64 KiB
-- writes), so a save never stalls the server in one go. (Before 1.4.1 all
-- of them were written in one step, which cave mapping made long: up to
-- 175 ms in Chris's profile.) Shutdown still saves everything at once.
local scan_timer, save_timer = 0, 0
local to_save = {}
core.register_globalstep(function(dtime)
	save_timer = save_timer + dtime
	if save_timer >= SAVE_INTERVAL and #to_save == 0 then
		save_timer = 0
		for key, tile in pairs(tiles) do
			if tile.dirty or tile.gdirty or tile.hdirty then
				to_save[#to_save + 1] = key
			end
		end
	end
	local key = table.remove(to_save)
	if key and tiles[key] and dtime <= 0.2 then
		local u0 = core.get_us_time()
		save_tile(key, tiles[key])
		sharp_map.slow("map save", u0, key)
	elseif key and tiles[key] then
		to_save[#to_save + 1] = key -- busy step: try again next step
	end
	scan_timer = scan_timer + dtime
	if scan_timer < cfg.scan_interval or not c_air or next(colors_by_cid) == nil then
		return
	end
	scan_timer = 0
	for _, player in ipairs(core.get_connected_players()) do
		local u0 = core.get_us_time()
		scan_near(player)
		sharp_map.slow("surface scan", u0, player:get_player_name())
	end
end)

------------------------------------------------------------------------
-- Relief: drawing a node's color with light from the north-west
------------------------------------------------------------------------

local byte = string.byte

-- Surface height at row RI (1 = north edge) and column PX (0-based) of
-- TILE, or nil if unknown.
local function height_in(tile, ri, px)
	local hi, lo = byte(tile.hgt[ri], px * 2 + 1, px * 2 + 2)
	local v = hi * 256 + lo
	if v == 0 then
		return nil
	end
	return v
end

-- A drawing context for one tile: the tile, and a lookup of the height
-- at a row and column that may lie just outside it, read from the
-- neighbouring tile only if that one is already in memory (so drawing
-- never loads tiles from disk).
local function draw_ctx(dim, tx, tz, tile)
	local near = {}
	local function neighbour(dx, dz)
		local k = dx .. "," .. dz
		if near[k] == nil then
			near[k] = tiles[tile_key(dim, tx + dx, tz + dz)] or false
		end
		return near[k] or nil
	end
	return {
		tile = tile,
		height = function(ri, px)
			local t, dx, dz = tile, 0, 0
			if px < 0 then
				dx, px = -1, px + TILE
			elseif px >= TILE then
				dx, px = 1, px - TILE
			end
			if ri < 1 then
				dz, ri = 1, ri + TILE -- north is the tile above
			elseif ri > TILE then
				dz, ri = -1, ri - TILE
			end
			if dx ~= 0 or dz ~= 0 then
				t = neighbour(dx, dz)
				if not t then
					return nil
				end
			end
			return height_in(t, ri, px)
		end,
	}
end

-- Brightness change for a node at height H with neighbour heights (an
-- unknown one counts as H) and ground level G (nil if unknown): positive
-- on slopes facing north-west, darker for deep water.
local function shade(h, nw, n, ne, w, e, sw, so, se, g)
	-- Sobel gradient: east minus west, south minus north (north is up).
	local gx = (ne + 2 * e + se) - (nw + 2 * w + sw)
	local gy = (sw + 2 * so + se) - (nw + 2 * n + ne)
	local d = (gx + gy) * RELIEF / 4
	d = d < -RELIEF_MAX and -RELIEF_MAX or (d > RELIEF_MAX and RELIEF_MAX or d)
	if g and h - g >= DEPTH_MIN then
		local deep = (h - g - DEPTH_MIN + 1) * DEPTH
		d = d - (deep > DEPTH_MAX and DEPTH_MAX or deep)
	end
	return d
end

local function ground_in(tile, ri, px)
	local hi, lo = byte(tile.gnd[ri], px * 2 + 1, px * 2 + 2)
	local v = hi * 256 + lo
	if v == 0 then
		return nil
	end
	return v
end

-- Brightness change for the node at RI, PX. 0 where the height is unknown
-- (older ground, whose color already holds its shading).
local function relief(ctx, ri, px)
	local h = height_in(ctx.tile, ri, px)
	if not h then
		return 0
	end
	local H = ctx.height
	return shade(h, H(ri - 1, px - 1) or h, H(ri - 1, px) or h, H(ri - 1, px + 1) or h,
		H(ri, px - 1) or h, H(ri, px + 1) or h,
		H(ri + 1, px - 1) or h, H(ri + 1, px) or h, H(ri + 1, px + 1) or h, ground_in(ctx.tile, ri, px))
end

-- r, g, b of the node at RI, PX with relief, or nil if it is unmapped.
local function shaded(ctx, ri, px)
	local i = px * 4 + 1
	local r, g, b, a = byte(ctx.tile.rows[ri], i, i + 3)
	if a == 0 then
		return nil
	end
	local d = relief(ctx, ri, px)
	return clamp_byte(r + d), clamp_byte(g + d), clamp_byte(b + d)
end

------------------------------------------------------------------------
-- Sending tiles to a player
------------------------------------------------------------------------

local sent = {} -- player name -> { [texture] = true } (sent this session)

core.register_on_leaveplayer(function(player)
	sent[player:get_player_name()] = nil
end)

-- A decoded height, or H if it is unknown (0).
local function or_h(v, h)
	return v ~= 0 and v or h
end

-- The picture of a tile with relief, as PNG data.
local function draw_png(dim, tx, tz, tile)
	-- Heights of the tile and a 1-node border around it, decoded once
	-- (0 = unknown), so each pixel's relief is a few table reads.
	local ctx = draw_ctx(dim, tx, tz, tile)
	local W = TILE + 2
	local hs = {}
	for ri = 0, TILE + 1 do
		local inside = ri >= 1 and ri <= TILE
		local hrow = inside and tile.hgt[ri]
		for px = -1, TILE do
			local v
			if hrow and px >= 0 and px < TILE then
				local hi, lo = byte(hrow, px * 2 + 1, px * 2 + 2)
				v = hi * 256 + lo
			else
				v = ctx.height(ri, px) or 0
			end
			hs[ri * W + px + 2] = v
		end
	end
	local out = {}
	for ri = 1, TILE do
		local row = {}
		local crow = tile.rows[ri]
		for px = 0, TILE - 1 do
			local i = px * 4 + 1
			local r, g, b, a = byte(crow, i, i + 3)
			if a == 0 then
				row[px + 1] = EMPTY_PIXEL
			else
				local k = ri * W + px + 2
				local h = hs[k]
				local d = 0
				if h ~= 0 then
					-- Same rule as relief(): unknown neighbours count as level.
					d = shade(h, or_h(hs[k - W - 1], h), or_h(hs[k - W], h), or_h(hs[k - W + 1], h),
						or_h(hs[k - 1], h), or_h(hs[k + 1], h), or_h(hs[k + W - 1], h), or_h(hs[k + W], h),
						or_h(hs[k + W + 1], h), ground_in(tile, ri, px))
				end
				row[px + 1] = schar(clamp_byte(r + d), clamp_byte(g + d), clamp_byte(b + d), 255)
			end
		end
		out[ri] = table.concat(row)
	end
	return core.encode_png(TILE, TILE, table.concat(out), 6)
end

-- Put PNG data into the media folder under a name never used before, as
-- the tile's current picture.
local function publish(dim, tx, tz, tile, png)
	png_serial = png_serial + 1
	local name = ("sharp_map_%s_%s_%s_%d.png"):format(safe_dim(dim),
		tostring(tx):gsub("%-", "m"), tostring(tz):gsub("%-", "m"), png_serial)
	core.safe_file_write(media_dir .. "/" .. name, png)
	if tile.png then
		os.remove(media_dir .. "/" .. tile.png)
	end
	tile.png, tile.png_ver = name, tile.ver
	return name
end

-- Draw a tile now and save the picture. With PUBLISH, also make it the
-- tile's texture for this session. Returns the texture name or nil.
local function draw_tile(dim, tx, tz, publish_it)
	local key = tile_key(dim, tx, tz)
	local tile = get_tile(key, false)
	if not tile then
		return nil
	end
	local png = draw_png(dim, tx, tz, tile)
	core.mkdir(key_dir(key))
	core.safe_file_write(cache_path(key), png)
	tile.cached = true
	if publish_it then
		return publish(dim, tx, tz, tile, png)
	end
	if tile.png_ver ~= tile.ver then
		-- Its old picture of this session is out of date; the saved one
		-- is used the next time it is shown.
		tile.png_ver = nil
	end
	return nil
end

-- The texture of a tile without drawing anything: the current picture of
-- this session, or the saved one. Returns the name; nil if the tile was
-- never explored; or false and the older picture of this session (if any)
-- when it must be drawn.
local function tile_texture(dim, tx, tz)
	local key = tile_key(dim, tx, tz)
	local tile = get_tile(key, false)
	if not tile then
		return nil
	end
	if tile.png and tile.png_ver == tile.ver then
		return tile.png
	end
	if tile.cached then
		local f = io.open(cache_path(key), "rb")
		local png = f and f:read("*all")
		if f then
			f:close()
		end
		if png and #png > 0 then
			return publish(dim, tx, tz, tile, png)
		end
		tile.cached = false
	end
	return false, tile.png
end

------------------------------------------------------------------------
-- The drawing queue: tiles to draw, a few milliseconds per server step.
------------------------------------------------------------------------

local queue = { {}, {} } -- [1] for map screens, [2] background (redraw.lua)
local queued = {}        -- "dim|tx|tz" -> its entry
local function qkey(dim, tx, tz)
	return safe_dim(dim) .. "|" .. tx .. "|" .. tz
end

-- Ask for a tile to be drawn. ON_DONE(texture or nil) runs once it is,
-- for a map screen (PRIORITY 1, also published) or in the background (2).
local function request_draw(dim, tx, tz, priority, on_done)
	local k = qkey(dim, tx, tz)
	local e = queued[k]
	if not e then
		e = { dim = dim, tx = tx, tz = tz, priority = priority, waiting = {} }
		queued[k] = e
		local q = queue[priority]
		q[#q + 1] = e
	elseif priority < e.priority then
		-- Moved up: the old place is skipped when it comes up.
		e.priority = priority
		local q = queue[priority]
		q[#q + 1] = e
	end
	if on_done then
		e.waiting[#e.waiting + 1] = on_done
	end
end
sharp_map.request_draw = request_draw

local function next_entry()
	for p = 1, 2 do
		local q = queue[p]
		while #q > 0 do
			local e = table.remove(q, 1)
			if queued[qkey(e.dim, e.tx, e.tz)] == e and e.priority == p then
				return e
			end
		end
	end
end

-- Draw from the queue until BUDGET microseconds are used (at least one).
local function run_queue(budget)
	local t0 = core.get_us_time()
	repeat
		local e = next_entry()
		if not e then
			return
		end
		queued[qkey(e.dim, e.tx, e.tz)] = nil
		local texture = draw_tile(e.dim, e.tx, e.tz, e.priority == 1)
		for _, cb in ipairs(e.waiting) do
			cb(texture)
		end
	until core.get_us_time() - t0 >= budget
end

local draw_budget = cfg.draw_budget * 1000
core.register_globalstep(function()
	if next(queued) then
		local u0 = core.get_us_time()
		run_queue(draw_budget)
		sharp_map.slow("map tile drawing", u0)
	end
end)

function sharp_map.draw_queue_size()
	local n = 0
	for _ in pairs(queued) do
		n = n + 1
	end
	return n
end

-- Send TEXTURE (a file in the media folder) to the player once per
-- session, then call DONE(ok). Already sent: DONE runs right away.
local pending_cb = {} -- player name -> texture -> list of callbacks
function sharp_map.ensure_media(name, texture, done)
	local player_sent = sent[name] or {}
	sent[name] = player_sent
	if player_sent[texture] == true then
		return done(true)
	end
	local waiting = pending_cb[name] and pending_cb[name][texture]
	if waiting then
		waiting[#waiting + 1] = done
		return
	end
	pending_cb[name] = pending_cb[name] or {}
	waiting = { done }
	pending_cb[name][texture] = waiting
	local function finish(ok)
		if pending_cb[name] then
			pending_cb[name][texture] = nil
		end
		player_sent[texture] = ok or nil
		for _, cb in ipairs(waiting) do
			cb(ok)
		end
	end
	local ok = core.dynamic_add_media({
		filepath = media_dir .. "/" .. texture,
		to_player = name,
		ephemeral = true,
	}, function() finish(true) end)
	if not ok then
		finish(false)
	end
end

core.register_on_leaveplayer(function(player)
	pending_cb[player:get_player_name()] = nil
end)

-- Send the tiles in the given tx/tz range to the player, then call
-- DONE(textures, missing) with a table tile key "tx,tz" -> texture name and
-- the number of explored tiles that have no picture yet. Tiles that need
-- drawing are drawn at once while that fits the step's budget (the usual
-- click), the others in the following steps; a tile that changed keeps
-- its older picture until then. When the missing ones are drawn (and every
-- 2 seconds while many are), MORE() is called so the screen can be shown
-- again with them.
-- Map screen tiles (1.4.4): preparing them is spread over server steps
-- (sharp_map.draw_budget per step for all screens together, at most
-- PREP_SENDS new pictures sent to a player per step). Before, a click on
-- the map screen loaded, drew and sent every tile of every layer it shows
-- in one step (up to 195 ms in Chris's profile). The open screen keeps
-- its old picture until the new one is ready, as before.
local PREP_SENDS = 6
local prep_jobs = {}

function sharp_map.prepare_tiles(name, dim, tx1, tx2, tz1, tz2, done, more)
	local job = { name = name, dim = dim, tiles = {}, i = 1, textures = {}, pending = 1, missing = 0,
		left = 0, last_more = core.get_us_time(), done = done, more = more }
	for tx = tx1, tx2 do
		for tz = tz1, tz2 do
			job.tiles[#job.tiles + 1] = { tx, tz }
		end
	end
	prep_jobs[#prep_jobs + 1] = job
end

local function prep_finish(job)
	job.pending = job.pending - 1
	if job.pending == 0 then
		job.done(job.textures, job.missing)
	end
end

-- One tile of JOB. Returns false if the player's sends are used up.
local function prep_tile(job, sends, t0)
	local tx, tz = job.tiles[job.i][1], job.tiles[job.i][2]
	local key = tx .. "," .. tz
	local texture, older = tile_texture(job.dim, tx, tz)
	if texture == false and core.get_us_time() - t0 < draw_budget then
		queued[qkey(job.dim, tx, tz)] = nil -- drawn here instead
		texture = draw_tile(job.dim, tx, tz, true)
	end
	local function send(tex)
		if not sharp_map.media_sent(job.name, tex) then
			if (sends[job.name] or 0) >= PREP_SENDS then
				return false
			end
			sends[job.name] = (sends[job.name] or 0) + 1
		end
		job.pending = job.pending + 1
		sharp_map.ensure_media(job.name, tex, function(ok)
			job.textures[key] = ok and tex or nil
			prep_finish(job)
		end)
		return true
	end
	if texture then
		if not send(texture) then
			return false
		end
	elseif texture == false then
		if older then
			if not send(older) then
				return false
			end
			request_draw(job.dim, tx, tz, 1)
		else
			job.missing = job.missing + 1
			job.left = job.left + 1
			request_draw(job.dim, tx, tz, 1, function()
				job.left = job.left - 1
				local now = core.get_us_time()
				if job.more and (job.left == 0 or now - job.last_more > 2000000) then
					job.last_more = now
					job.more()
				end
			end)
		end
	end
	job.i = job.i + 1
	return true
end

core.register_globalstep(function(dtime)
	if not prep_jobs[1] or dtime > 0.2 then
		return
	end
	local t0 = core.get_us_time()
	local sends = {}
	local i = 1
	while prep_jobs[i] do
		local job = prep_jobs[i]
		local u0 = core.get_us_time()
		while job.i <= #job.tiles and core.get_us_time() - t0 < draw_budget do
			if not prep_tile(job, sends, t0) then
				break
			end
		end
		sharp_map.slow("map screen tiles", u0, job.dim)
		if job.i > #job.tiles then
			table.remove(prep_jobs, i)
			prep_finish(job)
		else
			i = i + 1
		end
		if core.get_us_time() - t0 >= draw_budget then
			return
		end
	end
end)

------------------------------------------------------------------------
-- Writing cave maps (1.3.0, for caves.lua)
------------------------------------------------------------------------

-- The stored pixel at node X, Z of map MID: its alpha byte (0 = nothing,
-- 255 = a floor, 128 = a wall) and its height, or nil if the tile does not
-- exist.
local function peek(mid, x, z)
	local tx, tz = floor(x / TILE), floor(z / TILE)
	local tile = get_tile(tile_key(mid, tx, tz), false)
	if not tile then
		return nil
	end
	local ri, px = TILE - (z - tz * TILE), x - tx * TILE
	local a = byte(tile.rows[ri], px * 4 + 4)
	local hi, lo = byte(tile.hgt[ri], px * 2 + 1, px * 2 + 2)
	local h = hi * 256 + lo
	return a, h ~= 0 and h - 32768 or nil
end

-- Write pixels into map MID. LIST holds { x, z, pixel (4 bytes), h, g (2
-- bytes each) }. Rows are rebuilt once each, and only chunks whose pixels
-- really changed count as changed (their minimap pieces are made again),
-- so writing what is already there costs no new pictures. Returns the
-- number of pixels that changed.
local function write_pixels(mid, list)
	local by_tile = {}
	for _, p in ipairs(list) do
		local tx, tz = floor(p.x / TILE), floor(p.z / TILE)
		local key = tile_key(mid, tx, tz)
		local t = by_tile[key]
		if not t then
			t = { tx = tx, tz = tz, rows = {} }
			by_tile[key] = t
		end
		local ri = TILE - (p.z - tz * TILE)
		t.rows[ri] = t.rows[ri] or {}
		t.rows[ri][p.x - tx * TILE] = p
	end
	local n = 0
	for key, t in pairs(by_tile) do
		local tile = get_tile(key, true)
		local touched = {} -- chunk key -> true
		for ri, edits in pairs(t.rows) do
			local crow, hrow, grow = tile.rows[ri], tile.hgt[ri], tile.gnd[ri]
			local cp, hp, gp = {}, {}, {}
			for px = 0, TILE - 1 do
				local e = edits[px]
				local c0 = crow:sub(px * 4 + 1, px * 4 + 4)
				local h0 = hrow:sub(px * 2 + 1, px * 2 + 2)
				local g0 = grow:sub(px * 2 + 1, px * 2 + 2)
				if e and (e.pixel ~= c0 or e.h ~= h0 or e.g ~= g0) then
					cp[px + 1], hp[px + 1], gp[px + 1] = e.pixel, e.h, e.g
					n = n + 1
					local z = (t.tz + 1) * TILE - ri
					touched[floor((t.tx * TILE + px) / CHUNK) .. "," .. floor(z / CHUNK)] = true
				else
					cp[px + 1], hp[px + 1], gp[px + 1] = c0, h0, g0
				end
			end
			tile.rows[ri] = table.concat(cp)
			tile.hgt[ri] = table.concat(hp)
			tile.gnd[ri] = table.concat(gp)
		end
		if next(touched) then
			tile.dirty, tile.hdirty, tile.gdirty = true, true, true
			tile.ver = tile.ver + (tile.png_ver == tile.ver and 1 or 0)
			if tile.cached then
				os.remove(cache_path(key))
				tile.cached = false
			end
			local d = safe_dim(mid)
			for ck in pairs(touched) do
				chunk_ver[d .. ":" .. ck] = (chunk_ver[d .. ":" .. ck] or 0) + 1
			end
		end
	end
	return n
end

-- A node's map color (r, g, b) by content id and param2, or nil.
local function node_color(cid, p2)
	local color = colors_by_cid[cid]
	if color and type(color[1]) == "table" then
		color = color[(p2 or 0) + 1] or color[1]
	end
	if color then
		return color[1], color[2], color[3]
	end
end

-- For redraw.lua and caves.lua: the parts of the map store they work with.
sharp_map.render = {
	root = root,
	TILE = TILE,
	CHUNK = CHUNK,
	get_tile = function(dim, tx, tz) return get_tile(tile_key(dim, tx, tz), false) end,
	scan_chunk = scan_chunk,
	safe_dim = safe_dim,
	-- 1.3.0, for caves.lua:
	column_color = column_color,
	node_color = node_color,
	encode = encode_ground,
	peek = peek,
	write_pixels = write_pixels,
	ready = function() return c_air ~= nil and next(colors_by_cid) ~= nil end,
}

------------------------------------------------------------------------
-- Minimap pieces: small PNGs cut from the tiles
------------------------------------------------------------------------
-- A piece covers SIZE x SIZE nodes (16 or 32) and is always 16x16 pixels;
-- in 32-node pieces each pixel is the average of 2x2 nodes. Each piece is made once per
-- change of its chunks and sent once, so moving the minimap only moves
-- HUD images and never makes the client keep new textures.

local PIECE_PX = 16
local pieces = {} -- piece key -> { ver = signature, name = texture or false }

local function piece_signature(dim, size, cx, cz)
	local d = safe_dim(dim)
	local n = floor(size / CHUNK)
	local sig = 0
	-- The chunks around the piece count too: their heights change the
	-- relief along its edges.
	for i = -1, n do
		for j = -1, n do
			sig = sig + (chunk_ver[d .. ":" .. (cx * n + i) .. "," .. (cz * n + j)] or 0)
		end
	end
	return sig
end

-- The map layers a minimap view is made of, front first: for the surface
-- (a dimension) just that; for a cave view centered on band B (1.3.0),
-- the bands nearest to B and then the surface, dimmed, under them. F is
-- a brightness factor: below 1 darker (deeper bands), above 1 lighter
-- (the band above). Every node shows the first layer that has it, so a
-- tunnel that climbs or drops stays on the minimap, shaded by how far it
-- is above or below.
local VIEW_BANDS = { { 0, 1 }, { -1, 0.78 }, { 1, 1.18 }, { -2, 0.6 } }
local UNDER = 0.3
local function view_layers(view)
	local d, b = tostring(view or ""):match("^(.*)#v(%-?%d+)$")
	if not d then
		return { { mid = view, f = 1 } }
	end
	b = tonumber(b)
	local out = {}
	for i, vb in ipairs(VIEW_BANDS) do
		out[i] = { mid = sharp_map.cave_mid(d, b + vb[1]), f = vb[2] }
	end
	out[#out + 1] = { mid = d, f = UNDER }
	return out
end
sharp_map.view_layers = view_layers

local function tint(c, f)
	if f > 1 then
		return c + (255 - c) * (f - 1)
	end
	return c * f
end

local function piece_key(view, size, cx, cz)
	return safe_dim(view) .. "/" .. size .. "/" .. cx .. "," .. cz
end

-- The current signature of a piece: the change counters of the chunks it
-- is drawn from, in every layer of its view.
local function view_signature(view, size, cx, cz)
	local sig = 0
	for _, l in ipairs(view_layers(view)) do
		sig = sig + piece_signature(l.mid, size, cx, cz)
	end
	return sig
end

-- Draw the piece KEY of VIEW with signature SIG (the expensive part:
-- relief for every pixel of every layer, a PNG written to disk). Returns
-- its texture name, or false if that ground has never been mapped.
local function draw_piece(key, view, size, cx, cz, sig)
	local piece = pieces[key]
	local layers = view_layers(view)
	local x0, z0 = cx * size, cz * size
	local tx, tz = floor(x0 / TILE), floor(z0 / TILE)
	local ctxs = {}
	for _, l in ipairs(layers) do
		local tile = get_tile(tile_key(l.mid, tx, tz), false)
		if tile then
			ctxs[#ctxs + 1] = { ctx = draw_ctx(l.mid, tx, tz, tile), f = l.f }
		end
	end
	local name = false
	if #ctxs > 0 then
		local step = floor(size / PIECE_PX)
		local col0 = x0 - tx * TILE
		local rows, any = {}, false
		for r = 0, PIECE_PX - 1 do
			local z = z0 + size - 1 - r * step -- north at the top
			local ri = TILE - (z - tz * TILE)
			local px = {}
			for c = 0, PIECE_PX - 1 do
				-- Wide view: each map pixel is the average of a 2x2 block of
				-- nodes (mapped ones only, each with its relief), so thin
				-- features such as paths and rivers are not lost.
				local r_, g_, b_, n = 0, 0, 0, 0
				for dr = 0, step - 1 do
					for k = 0, step - 1 do
						for _, l in ipairs(ctxs) do
							local r1, g1, b1 = shaded(l.ctx, ri + dr, col0 + c * step + k)
							if r1 then
								if l.f ~= 1 then
									r1, g1, b1 = tint(r1, l.f), tint(g1, l.f), tint(b1, l.f)
								end
								r_, g_, b_, n = r_ + r1, g_ + g1, b_ + b1, n + 1
								break
							end
						end
					end
				end
				if n > 0 then
					any = true
					px[c + 1] = schar(floor(r_ / n + 0.5), floor(g_ / n + 0.5), floor(b_ / n + 0.5), 255)
				else
					px[c + 1] = EMPTY_PIXEL
				end
			end
			rows[r + 1] = table.concat(px)
		end
		if any then
			name = ("sharp_map_p%d_%s_%s_%s_%d.png"):format(size, safe_dim(view),
				tostring(cx):gsub("%-", "m"), tostring(cz):gsub("%-", "m"), sig)
			core.safe_file_write(media_dir .. "/" .. name,
				core.encode_png(PIECE_PX, PIECE_PX, table.concat(rows), 6))
		end
	end
	if piece and piece.name and piece.name ~= name then
		os.remove(media_dir .. "/" .. piece.name)
	end
	pieces[key] = { ver = sig, name = name, view = view, size = size, cx = cx, cz = cz }
	return name
end

-- Texture name of the piece at piece coordinates CX, CZ of VIEW (a
-- dimension, or a cave view id), or nil if that ground has never been
-- mapped. Draws it at once if needed (tests; the minimap uses
-- sharp_map.piece_request, which spreads drawing over steps).
function sharp_map.piece_texture(view, size, cx, cz)
	local key = piece_key(view, size, cx, cz)
	local sig = view_signature(view, size, cx, cz)
	local piece = pieces[key]
	if piece and piece.ver == sig then
		return piece.name or nil
	end
	return draw_piece(key, view, size, cx, cz, sig) or nil
end

------------------------------------------------------------------------
-- Minimap piece queue (1.4.1)
------------------------------------------------------------------------
-- Drawing a piece costs a few milliseconds (more in a cave view, which
-- has five layers). Before 1.4.1 the minimap drew every piece it needed
-- in the step it needed it: entering a cave or crossing into another
-- 16-node layer redrew all 81 at once (551 ms in Chris's profile), and the
-- minimap froze and then jumped. Now pieces are asked for and drawn a few
-- per step, within sharp_map.minimap_budget milliseconds (at least one
-- per step, none in a step that already took over 0.2 s), most urgent
-- first: PRIORITY is the minimap's (lower first; it puts what is missing
-- before what changed, and what changed before drawing ahead, and the
-- pieces near the player before those at the edge). Until a piece is
-- drawn the minimap keeps showing the picture it has. Entries nobody has
-- asked for again within STALE seconds are dropped (the player moved on).

local STALE = 3
local pq = {}    -- piece key -> entry { view, size, cx, cz, prio, t, cbs }
local n_pq = 0
local pq_clock = 0

-- The piece's texture as it is now (false: no picture) and whether that
-- is up to date. If not, it is queued with PRIORITY, and DONE(texture or
-- false) runs once it is drawn (DONE may be nil).
function sharp_map.piece_request(view, size, cx, cz, priority, done)
	local key = piece_key(view, size, cx, cz)
	local sig = view_signature(view, size, cx, cz)
	local piece = pieces[key]
	if piece and piece.ver == sig then
		return piece.name or false, true
	end
	local e = pq[key]
	if not e then
		e = { view = view, size = size, cx = cx, cz = cz, prio = priority, cbs = {} }
		pq[key] = e
		n_pq = n_pq + 1
	elseif priority < e.prio then
		e.prio = priority
	end
	e.t = pq_clock
	if done then
		e.cbs[#e.cbs + 1] = done
	end
	return piece and piece.name or false, false
end

-- Draw ahead (1.4.2): queue the piece only if it has no picture yet (never
-- drawn, or drawn empty and changed since). A piece with a picture that
-- changed since is left alone: its older picture
-- is good enough to switch to at once, and it is brought up to date when
-- it is actually shown. (1.4.1 kept every drawn-ahead piece up to date,
-- which with background cave mapping meant drawing all the time.)
function sharp_map.piece_predraw(view, size, cx, cz, priority)
	local key = piece_key(view, size, cx, cz)
	local piece = pieces[key]
	if piece and (piece.name or piece.ver == view_signature(view, size, cx, cz)) then
		return -- has a picture, or is still rightly empty
	end
	local e = pq[key]
	if not e then
		pq[key] = { view = view, size = size, cx = cx, cz = cz, prio = priority, cbs = {}, t = pq_clock }
		n_pq = n_pq + 1
	else
		e.t = pq_clock
	end
end

-- True when TEXTURE has already been sent to player NAME this session.
function sharp_map.media_sent(name, texture)
	return sent[name] ~= nil and sent[name][texture] == true
end

-- The first tile a piece is drawn from that is not in memory yet (and not
-- known to be missing), so it can be loaded on its own, as one unit of
-- work (1.4.2): a tile load is a disk read and may mean saving another.
local function tile_to_load(e)
	local tx, tz = floor(e.cx * e.size / TILE), floor(e.cz * e.size / TILE)
	for _, l in ipairs(view_layers(e.view)) do
		local k = tile_key(l.mid, tx, tz)
		if not tiles[k] and not absent[k] then
			return k
		end
	end
end

-- The most urgent entry (dropping stale ones).
local function next_piece()
	local best_key, best
	for key, e in pairs(pq) do
		if pq_clock - e.t > STALE then
			pq[key] = nil
			n_pq = n_pq - 1
		elseif not best or e.prio < best.prio then
			best_key, best = key, e
		end
	end
	return best_key, best
end

local piece_budget = cfg.minimap_budget * 1000
core.register_globalstep(function(dtime)
	pq_clock = pq_clock + dtime
	if n_pq == 0 or dtime > 0.2 then
		return
	end
	local t0 = core.get_us_time()
	repeat
		local key, e = next_piece()
		if not key then
			return
		end
		local load = tile_to_load(e)
		local u0 = core.get_us_time()
		if load then
			get_tile(load, false) -- one tile per unit; the entry stays queued
			sharp_map.slow("minimap tile load", u0, load)
		else
			pq[key] = nil
			n_pq = n_pq - 1
			local sig = view_signature(e.view, e.size, e.cx, e.cz)
			local piece = pieces[key]
			local name
			if piece and piece.ver == sig then
				name = piece.name -- drawn meanwhile
			else
				name = draw_piece(key, e.view, e.size, e.cx, e.cz, sig)
				sharp_map.slow("minimap piece", u0, key)
			end
			for _, cb in ipairs(e.cbs) do
				cb(name)
			end
		end
	until core.get_us_time() - t0 >= piece_budget
end)

------------------------------------------------------------------------
-- Minimap pieces kept between sessions (1.4.3)
------------------------------------------------------------------------
-- At shutdown every piece whose picture is up to date is moved to
-- <world>/sharp_map/pieces/ with a list of what it shows. At the next
-- start they are moved back (under new names, so they never clash with
-- pieces drawn later) and count as up to date until their ground changes:
-- change counters start at 0 in every session, and the map tiles are
-- saved at shutdown, so a picture up to date then is up to date now. The
-- minimap then only has to send them, not draw them, when you join.
-- Pictures from another version of the mod are not kept.

local PIECE_DIR = root .. "/pieces"
local PIECE_LIST = PIECE_DIR .. "/list.txt"
local KEEP_MAX = 8000

local function save_pieces()
	core.mkdir(PIECE_DIR)
	local lines = { "v=" .. sharp_map.version }
	for key, pc in pairs(pieces) do
		if #lines > KEEP_MAX then
			break
		end
		if pc.name and pc.view and pc.ver == view_signature(pc.view, pc.size, pc.cx, pc.cz)
				and os.rename(media_dir .. "/" .. pc.name, PIECE_DIR .. "/" .. pc.name) then
			lines[#lines + 1] = table.concat({ key, pc.view, pc.size, pc.cx, pc.cz, pc.name }, "\t")
		end
	end
	core.safe_file_write(PIECE_LIST, table.concat(lines, "\n"))
end
core.register_on_shutdown(save_pieces)

local LINE = "^([^\t]+)\t([^\t]+)\t(%d+)\t(%-?%d+)\t(%-?%d+)\t([^\t]+)$"
local function load_pieces()
	local f = io.open(PIECE_LIST, "r")
	if not f then
		return
	end
	local ok_version = f:read("*l") == "v=" .. sharp_map.version
	local n = 0
	for line in f:lines() do
		local key, view, size, cx, cz, file = line:match(LINE)
		if key then
			local from = PIECE_DIR .. "/" .. file
			local name = file:gsub("%.png$", "") .. "_r.png"
			if ok_version and os.rename(from, media_dir .. "/" .. name) then
				pieces[key] = { ver = 0, name = name, view = view, size = tonumber(size),
					cx = tonumber(cx), cz = tonumber(cz) }
				n = n + 1
			else
				os.remove(from)
			end
		end
	end
	f:close()
	os.remove(PIECE_LIST)
	if n > 0 then
		core.log("action", "[sharp_map] " .. n .. " minimap pictures kept from the last session")
	end
end
load_pieces()

-- For tests and /map caves: pieces waiting to be drawn.
function sharp_map.piece_queue_size()
	return n_pq
end

sharp_map.TILE = TILE

-- A [combine texture of the tiles in TEXTURES ("tx,tz" -> texture) for a
-- W x H node view whose west edge is X0 and north edge is Z1. Tiles may
-- start left of or above the canvas; [combine crops what falls outside.
function sharp_map.combine(textures, x0, z1, w, h)
	local parts = { ("[combine:%dx%d"):format(w, h) }
	for key, texture in pairs(textures) do
		local tx, tz = key:match("^(%-?%d+),(%-?%d+)$")
		tx, tz = tonumber(tx), tonumber(tz)
		parts[#parts + 1] = (":%d,%d=%s"):format(tx * TILE - x0, z1 - (tz * TILE + TILE - 1), texture)
	end
	if #parts == 1 then
		return nil
	end
	return table.concat(parts)
end

-- Tile index range covering a W x H view with west edge X0, north edge Z1.
function sharp_map.tile_range(x0, z1, w, h)
	return floor(x0 / TILE), floor((x0 + w - 1) / TILE), floor((z1 - h + 1) / TILE), floor(z1 / TILE)
end
