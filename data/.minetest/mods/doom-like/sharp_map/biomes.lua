-- Biome names for the map's hover tooltips.
--
-- Mineclonia worlds come in two kinds (checked against mcl_levelgen's
-- init.lua and API.txt, mcl_biome_dispatch's init.lua and API.txt, and
-- mcl_worlds, release 39338):
--   * Made with a built-in Luanti mapgen (v7, valleys, ...). mcl_levelgen
--     runs in "ersatz" mode and only adds structures; the engine biomes
--     registered by mcl_biomes are the real ones, so core.get_biome_data
--     is right.
--   * Made with Mineclonia's own level generator (mapgen "singlenode").
--     It chooses biomes itself, so the engine's biome data would not match
--     the world. mcl_biome_dispatch is Mineclonia's documented layer for
--     this: get_biome_name_nosample(pos) returns a name in an undefined
--     format (nil where nothing has been generated yet), which may only be
--     compared through make_biome_test. So each known biome id gets a test,
--     and the first test that matches gives the display name.
--
-- mcl_biomes names engine biomes with internal ids such as
-- "ExtremeHills+_snowtop". The parts of one biome are folded together and
-- shown under the name of the new-style biome that mcl_biome_dispatch's
-- engine_aliases table files each engine base under (so ExtremeHills+ is a
-- Windswept Hills, SavannaM a Savanna, BirchForestM a Birch Forest). The
-- parts mcl_biome_dispatch lists are _shore, _beach, _ocean, _deep_ocean,
-- _sandlevel, _snowtop, _beach_water, _underground and _deep_underground.

local S = sharp_map.S

-- The biome name for a spot of the map: asked at the spot's own ground
-- (recorded by the map scan, see render.lua), because that is where the game
-- decides a column's biome. Where no ground was recorded yet, FALLBACK_Y is
-- used. Looked up when called, so it follows whichever biome_at is set below.
function sharp_map.biome_at_spot(dim, x, z, fallback_y)
	local y = sharp_map.ground_at and sharp_map.ground_at(dim, x, z) or fallback_y
	return sharp_map.biome_at(vector.new(x, y, z))
end

local levelgen = rawget(_G, "mcl_levelgen")
local dispatch = rawget(_G, "mcl_biome_dispatch")

-- Only a singlenode world can be running Mineclonia's own generator, so
-- every other map generator (v7, valleys, ...) always takes the engine path
-- below, exactly as before the level generator support was added.
local singlenode = core.get_mapgen_setting("mg_name") == "singlenode"

local use_levelgen = singlenode and levelgen ~= nil and levelgen.levelgen_enabled
	and dispatch ~= nil
	and type(dispatch.get_biome_name_nosample) == "function"
	and type(dispatch.make_biome_test) == "function"

if not use_levelgen and (singlenode
		or type(core.get_biome_data) ~= "function"
		or type(core.get_biome_name) ~= "function") then
	sharp_map.biome_at = function() return nil end
	return
end

local NAMES = {
	flat = S("Superflat"),
	Plains = S("Plains"),
	SunflowerPlains = S("Sunflower Plains"),
	IcePlains = S("Snowy Plains"),
	IcePlainsSpikes = S("Ice Spikes"),
	Meadow = S("Meadow"),
	CherryGrove = S("Cherry Grove"),
	Grove = S("Grove"),
	SnowySlopes = S("Snowy Slopes"),
	FrozenPeaks = S("Frozen Peaks"),
	JaggedPeaks = S("Jagged Peaks"),
	StonyPeaks = S("Stony Peaks"),
	Forest = S("Forest"),
	FlowerForest = S("Flower Forest"),
	BirchForest = S("Birch Forest"),
	BirchForestM = S("Birch Forest"),
	RoofedForest = S("Dark Forest"),
	PaleGarden = S("Pale Garden"),
	Taiga = S("Taiga"),
	ColdTaiga = S("Snowy Taiga"),
	MegaTaiga = S("Old Growth Pine Taiga"),
	MegaSpruceTaiga = S("Old Growth Spruce Taiga"),
	ExtremeHills = S("Windswept Hills"),
	ExtremeHillsM = S("Windswept Gravelly Hills"),
	["ExtremeHills+"] = S("Windswept Hills"),
	StoneBeach = S("Stony Shore"),
	Desert = S("Desert"),
	Mesa = S("Badlands"),
	MesaBryce = S("Eroded Badlands"),
	MesaPlateauF = S("Wooded Badlands"),
	MesaPlateauFM = S("Wooded Badlands"),
	Savanna = S("Savanna"),
	SavannaM = S("Savanna"),
	Jungle = S("Jungle"),
	JungleM = S("Jungle"),
	BambooJungle = S("Bamboo Jungle"),
	JungleEdge = S("Sparse Jungle"),
	JungleEdgeM = S("Sparse Jungle"),
	Swampland = S("Swamp"),
	MangroveSwamp = S("Mangrove Swamp"),
	MushroomIsland = S("Mushroom Fields"),
	MushroomIslandShore = S("Mushroom Fields"),
	DeepDark = S("Deep Dark"),
	LushCaves = S("Lush Caves"),
	DripstoneCave = S("Dripstone Caves"),
	Nether = S("Nether Wastes"),
	CrimsonForest = S("Crimson Forest"),
	WarpedForest = S("Warped Forest"),
	SoulsandValley = S("Soul Sand Valley"),
	BasaltDelta = S("Basalt Deltas"),
	End = S("The End"),
	EndBarrens = S("End Barrens"),
	EndBorder = S("The End"),
	EndHighlands = S("End Highlands"),
	EndIsland = S("The End"),
	EndMidlands = S("End Midlands"),
	EndSmallIslands = S("Small End Islands"),
}

-- Biomes of Mineclonia's own level generator. The ids are the ones
-- mcl_biome_dispatch's API.txt lists as valid for make_biome_test.
local LEVELGEN = {
	{ "Plains", S("Plains") },
	{ "SunflowerPlains", S("Sunflower Plains") },
	{ "SnowyPlains", S("Snowy Plains") },
	{ "IceSpikes", S("Ice Spikes") },
	{ "Meadow", S("Meadow") },
	{ "CherryGrove", S("Cherry Grove") },
	{ "Grove", S("Grove") },
	{ "SnowySlopes", S("Snowy Slopes") },
	{ "FrozenPeaks", S("Frozen Peaks") },
	{ "JaggedPeaks", S("Jagged Peaks") },
	{ "StonyPeaks", S("Stony Peaks") },
	{ "Forest", S("Forest") },
	{ "FlowerForest", S("Flower Forest") },
	{ "BirchForest", S("Birch Forest") },
	{ "OldGrowthBirchForest", S("Old Growth Birch Forest") },
	{ "DarkForest", S("Dark Forest") },
	{ "Taiga", S("Taiga") },
	{ "SnowyTaiga", S("Snowy Taiga") },
	{ "OldGrowthPineTaiga", S("Old Growth Pine Taiga") },
	{ "OldGrowthSpruceTaiga", S("Old Growth Spruce Taiga") },
	{ "WindsweptHills", S("Windswept Hills") },
	{ "WindsweptGravellyHills", S("Windswept Gravelly Hills") },
	{ "WindsweptForest", S("Windswept Forest") },
	{ "StonyShore", S("Stony Shore") },
	{ "Desert", S("Desert") },
	{ "Mesa", S("Badlands") },
	{ "ErodedMesa", S("Eroded Badlands") },
	{ "WoodedMesa", S("Wooded Badlands") },
	{ "Savannah", S("Savanna") },
	{ "SavannahPlateau", S("Savanna Plateau") },
	{ "WindsweptSavannah", S("Windswept Savanna") },
	{ "Jungle", S("Jungle") },
	{ "BambooJungle", S("Bamboo Jungle") },
	{ "SparseJungle", S("Sparse Jungle") },
	{ "Swamp", S("Swamp") },
	{ "MangroveSwamp", S("Mangrove Swamp") },
	{ "MushroomIslands", S("Mushroom Fields") },
	{ "Beach", S("Beach") },
	{ "SnowyBeach", S("Snowy Beach") },
	{ "River", S("River") },
	{ "FrozenRiver", S("Frozen River") },
	{ "Ocean", S("Ocean") },
	{ "ColdOcean", S("Cold Ocean") },
	{ "FrozenOcean", S("Frozen Ocean") },
	{ "LukewarmOcean", S("Lukewarm Ocean") },
	{ "WarmOcean", S("Warm Ocean") },
	{ "DeepOcean", S("Deep Ocean") },
	{ "DeepColdOcean", S("Deep Cold Ocean") },
	{ "DeepFrozenOcean", S("Deep Frozen Ocean") },
	{ "DeepLukewarmOcean", S("Deep Lukewarm Ocean") },
	{ "DeepDark", S("Deep Dark") },
	{ "LushCaves", S("Lush Caves") },
	{ "DripstoneCaves", S("Dripstone Caves") },
	{ "NetherWastes", S("Nether Wastes") },
	{ "CrimsonForest", S("Crimson Forest") },
	{ "WarpedForest", S("Warped Forest") },
	{ "SoulSandValley", S("Soul Sand Valley") },
	{ "BasaltDeltas", S("Basalt Deltas") },
	{ "TheEnd", S("The End") },
	{ "EndBarrens", S("End Barrens") },
	{ "EndHighlands", S("End Highlands") },
	{ "EndMidlands", S("End Midlands") },
	{ "SmallEndIslands", S("Small End Islands") },
	{ "TheVoid", S("The Void") },
}

if use_levelgen then
	-- Tests are built on the first lookup, after every mod has loaded, so
	-- all level generator biomes are registered by then. An id the
	-- generator refuses is skipped rather than allowed to crash the map.
	local tests
	local names = {} -- name from the dispatcher -> display name, or false

	local function build_tests()
		tests = {}
		for _, entry in ipairs(LEVELGEN) do
			local ok, test = pcall(dispatch.make_biome_test, { entry[1] })
			if ok and type(test) == "function" then
				tests[#tests + 1] = { test, entry[2] }
			end
		end
	end

	local function display_name(raw)
		local name = names[raw]
		if name ~= nil then
			return name or nil
		end
		if not tests then
			build_tests()
		end
		for _, pair in ipairs(tests) do
			if pair[1](raw) then
				name = pair[2]
				break
			end
		end
		if not name and type(raw) == "string" and raw:find("^[%a_]+$") then
			-- A biome from another mod: split CamelCase as a fallback.
			name = (raw:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"))
			name = name:match("^%s*(.-)%s*$")
			if name == "" then
				name = nil
			end
		end
		names[raw] = name or false
		return name
	end

	-- Where nothing has been generated yet the dispatcher gives nil, so
	-- hovering over unexplored ground shows coordinates only.
	function sharp_map.biome_at(pos)
		local ok, raw = pcall(dispatch.get_biome_name_nosample, pos)
		if not ok or raw == nil or raw == false then
			return nil
		end
		local ok2, name = pcall(display_name, raw)
		if ok2 and name and name ~= "" then
			return name
		end
		return nil
	end
	return
end

-- Suffixes mcl_biomes uses for parts of one biome.
-- deep_ocean was seen in game ("Savanna_deep_ocean"); the other three come
-- from reading mcl_biomes. Any other suffix containing "ocean" is treated
-- as ocean below, so a part not listed here never shows as a land biome.
local PARTS = {
	ocean = S("Ocean"),
	deep_ocean = S("Deep Ocean"),
	beach = S("Beach"),
	beach_water = S("Beach"),
	shore = S("Shore"),
}

local cache = {} -- biome id -> display name

local function display_name(id)
	local name = cache[id]
	if name then
		return name
	end
	local raw = core.get_biome_name(id) or ""
	local base, suffix = raw:match("^(.-)_(.+)$")
	if not base or not NAMES[base] then
		base, suffix = raw, nil
	end
	if suffix and PARTS[suffix] then
		name = PARTS[suffix]
	elseif suffix and suffix:find("ocean", 1, true) then
		name = suffix:find("deep", 1, true) and PARTS.deep_ocean or PARTS.ocean
	else
		-- Unknown biome (another mod): split CamelCase as a fallback.
		name = NAMES[base] or (base:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"))
	end
	cache[id] = name
	return name
end

function sharp_map.biome_at(pos)
	local data = core.get_biome_data(pos)
	if not data or not data.biome then
		return nil
	end
	local name = display_name(data.biome)
	return name ~= "" and name or nil
end
