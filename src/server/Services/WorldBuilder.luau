--!strict
-- Builds the BLOCKOUT for every region in WorldDefs (R00 depot through R05 Shifting Crossroads) from primitive parts,
-- and the active version of each variable pocket on request from PocketService (buildPocket / destroyPocket).
-- This is greybox geometry for testing scale, routes and systems, not production art (section 18 pipeline).
-- Every generated part is tagged BLOCKOUT so it can be replaced by modular kit pieces later; pocket parts are also
-- tagged PocketGeometry and live in a version folder with PocketId / PocketVersion attributes.
-- Interactive props belong to other services (puzzles, missions, story); the set-pieces here are decor only.

local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Config = require(Shared.Data.Config)
local Pockets = require(Shared.Logic.Pockets)
Pockets.bind(WorldDefs)

local WorldBuilder = {}

local W = WorldDefs.CORRIDOR_WIDTH
local H = WorldDefs.CORRIDOR_HEIGHT
local WALL = 2

local root: Folder
local regionFolders: { [string]: Folder } = {}
local pocketFolders: { [string]: Folder } = {}

local STONE = Color3.fromRGB(176, 166, 146)
local STONE_DARK = Color3.fromRGB(120, 112, 98)
local RUST = Color3.fromRGB(110, 62, 38)
local WOOD = Color3.fromRGB(92, 70, 48)
local BONE = Color3.fromRGB(214, 202, 176)
local WET = Color3.fromRGB(96, 98, 92)
local WATER = Color3.fromRGB(38, 58, 56)

local function v(t: { x: number, y: number, z: number }): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color or STONE
	p.Material = material or Enum.Material.Limestone
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	CollectionService:AddTag(p, "BLOCKOUT")
	return p
end

local function deco(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	material: Enum.Material?
): Part
	local p = part(parent, name, size, cf, color, material)
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	return p
end

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- Water rules (generalised from the Milestone 2 R03-only checks): chambers in a flooded region carry shallow water
-- unless flagged `dry`; PuzzleService owns the cistern's water; gated corridors get none (their puzzle builds the
-- deep barrier). PROPOSED: the long silent route to the Overflow Vault (M05) starts dry at the Silt Works' south
-- door, reached over stepping stones.
local WET_REGIONS: { [string]: boolean } = { R03 = true }
local PUZZLE_WATER: { [string]: boolean } = { ["R03.cistern"] = true }
local DRY_CORRIDORS: { [string]: boolean } = { ["R03.silt_loop|R03.drain_gallery"] = true }

local function chamberWet(c: any): boolean
	return WET_REGIONS[c.regionId] == true and not c.dry and not PUZZLE_WATER[c.id]
end

local function corridorWet(cor: any, a: any, b: any): boolean
	return cor.gate == nil
		and cor.pocket == nil
		and a.pos.y == b.pos.y
		and WET_REGIONS[a.regionId] == true
		and WET_REGIONS[b.regionId] == true
		and not (a.dry and b.dry)
		and not DRY_CORRIDORS[cor.from .. "|" .. cor.to]
		and not DRY_CORRIDORS[cor.to .. "|" .. cor.from]
end

-- The side of chamber `c` that faces chamber `o` along their shared axis: "N" (+z), "S" (-z), "E" (+x), "W" (-x)
local function sideToward(c: any, o: any): string
	if o.pos.x == c.pos.x then
		return if o.pos.z > c.pos.z then "N" else "S"
	end
	return if o.pos.x > c.pos.x then "E" else "W"
end

-- Which sides of a chamber have a corridor opening. Pocket corridors count: PocketService builds the passage, but
-- the static mouth doorway is always open (entry/exit contract).
local function openings(chamberId: string): { [string]: boolean }
	local out = {}
	local c = assert(WorldDefs.chamber(chamberId))
	for _, cor in WorldDefs.Corridors do
		local otherId = if cor.from == chamberId then cor.to elseif cor.to == chamberId then cor.from else nil
		if otherId then
			out[sideToward(c, assert(WorldDefs.chamber(otherId)))] = true
		end
	end
	if chamberId == "R01.survey_board" then
		out.S = true -- descent ramp arrives from the south
	end
	return out
end

-- A gap in a wall: `c` is its centre measured along the wall from the wall's centre, `w` its width.
type Gap = { c: number, w: number }

-- Door gaps per side: one centred corridor-width doorway per open side, except a pocket mouth with several doors
-- (PK3's Room of Three Doors), which gets one DOOR_WIDTH gap at each authored position.
local function doorGaps(c: any): { [string]: { Gap } }
	local out: { [string]: { Gap } } = {}
	for side, open in openings(c.id) do
		if open then
			out[side] = { { c = 0, w = W } }
		end
	end
	for _, pk in WorldDefs.Pockets do
		if pk.doors and pk.from == c.id then
			local side = sideToward(c, assert(WorldDefs.chamber(pk.to)))
			local gaps: { Gap } = {}
			for _, d in pk.doors do
				local along = if side == "N" or side == "S" then d - c.pos.x else d - c.pos.z
				table.insert(gaps, { c = along, w = Pockets.DOOR_WIDTH })
			end
			out[side] = gaps
		end
	end
	return out
end

-- A wall along one side, split around its door gaps, with a lintel above each gap when the room is taller than a
-- corridor.
local function sideWall(
	parent: Instance,
	center: Vector3,
	length: number,
	height: number,
	alongX: boolean,
	gaps: { Gap }?
)
	local y = center.Y + height / 2
	local function segment(a: number, b: number)
		if b - a < 0.05 then
			return
		end
		local mid = (a + b) / 2
		local size = if alongX then Vector3.new(b - a, height, WALL) else Vector3.new(WALL, height, b - a)
		local pos = if alongX
			then Vector3.new(center.X + mid, y, center.Z)
			else Vector3.new(center.X, y, center.Z + mid)
		part(parent, "Wall", size, CFrame.new(pos))
	end
	local list: { Gap } = if gaps then table.clone(gaps) else {}
	table.sort(list, function(a: Gap, b: Gap)
		return a.c < b.c
	end)
	local cursor = -length / 2
	for _, g in list do
		segment(cursor, g.c - g.w / 2)
		cursor = g.c + g.w / 2
		if height > H then
			local lintelH = height - H
			local size = if alongX then Vector3.new(g.w, lintelH, WALL) else Vector3.new(WALL, lintelH, g.w)
			local pos = if alongX
				then Vector3.new(center.X + g.c, center.Y + H + lintelH / 2, center.Z)
				else Vector3.new(center.X, center.Y + H + lintelH / 2, center.Z + g.c)
			part(parent, "Lintel", size, CFrame.new(pos))
		end
	end
	segment(cursor, length / 2)
end

local function buildChamber(c: any)
	local f = folder(WorldBuilder.folder(c.regionId), c.id)
	local p = v(c.pos)
	local s = v(c.size)
	local gaps = doorGaps(c)
	part(f, "Floor", Vector3.new(s.X + WALL * 2, 1, s.Z + WALL * 2), CFrame.new(p.X, p.Y - 0.5, p.Z), STONE_DARK)
	part(f, "Ceiling", Vector3.new(s.X + WALL * 2, 2, s.Z + WALL * 2), CFrame.new(p.X, p.Y + s.Y + 1, p.Z))
	sideWall(f, Vector3.new(p.X, p.Y, p.Z + s.Z / 2 + WALL / 2), s.X + WALL * 2, s.Y, true, gaps.N)
	sideWall(f, Vector3.new(p.X, p.Y, p.Z - s.Z / 2 - WALL / 2), s.X + WALL * 2, s.Y, true, gaps.S)
	sideWall(f, Vector3.new(p.X + s.X / 2 + WALL / 2, p.Y, p.Z), s.Z, s.Y, false, gaps.E)
	sideWall(f, Vector3.new(p.X - s.X / 2 - WALL / 2, p.Y, p.Z), s.Z, s.Y, false, gaps.W)
	-- Discovery volume (non-colliding, invisible)
	local vol = part(f, "DiscoveryVolume", s, CFrame.new(p.X, p.Y + s.Y / 2, p.Z))
	vol.Transparency = 1
	vol.CanCollide = false
	vol.CanQuery = false
	vol:SetAttribute("ChamberId", c.id)
	vol:SetAttribute("RegionId", c.regionId)
	CollectionService:AddTag(vol, "DiscoveryVolume")
	return f
end

-- A corridor joining chambers at different heights: a straight sloped gallery with treads.
local function buildSlopedCorridor(f: Folder, a: any, b: any)
	local alongZ = a.pos.x == b.pos.x
	local lo, hi
	if alongZ then
		lo, hi = if a.pos.z < b.pos.z then a else b, if a.pos.z < b.pos.z then b else a
	else
		lo, hi = if a.pos.x < b.pos.x then a else b, if a.pos.x < b.pos.x then b else a
	end
	local s0, s1
	if alongZ then
		s0 = Vector3.new(lo.pos.x, lo.pos.y, lo.pos.z + lo.size.z / 2 + WALL)
		s1 = Vector3.new(hi.pos.x, hi.pos.y, hi.pos.z - hi.size.z / 2 - WALL)
	else
		s0 = Vector3.new(lo.pos.x + lo.size.x / 2 + WALL, lo.pos.y, lo.pos.z)
		s1 = Vector3.new(hi.pos.x - hi.size.x / 2 - WALL, hi.pos.y, hi.pos.z)
	end
	local len = (s1 - s0).Magnitude
	local look = CFrame.lookAt((s0 + s1) / 2, s1)
	local wet = WET_REGIONS[a.regionId] == true and WET_REGIONS[b.regionId] == true
	part(
		f,
		"Floor",
		Vector3.new(W + WALL * 2, 1, len + 2),
		look * CFrame.new(0, -0.5, 0),
		if wet then WET else STONE_DARK,
		Enum.Material.Slate
	)
	part(f, "Ceiling", Vector3.new(W + WALL * 2, 2, len + 2), look * CFrame.new(0, H + 1, 0), STONE)
	part(f, "WallA", Vector3.new(WALL, H + 2, len + 2), look * CFrame.new(W / 2 + WALL / 2, H / 2, 0), STONE)
	part(f, "WallB", Vector3.new(WALL, H + 2, len + 2), look * CFrame.new(-W / 2 - WALL / 2, H / 2, 0), STONE)
	for i = 1, math.floor(len / 4) - 1 do
		deco(f, "Tread", Vector3.new(W - 1, 0.25, 0.4), look * CFrame.new(0, 0.1, -len / 2 + i * 4), STONE)
	end
end

local function buildCorridor(a: any, b: any)
	local f = folder(WorldBuilder.folder(a.regionId), a.id .. "__" .. b.id)
	if a.pos.y ~= b.pos.y then
		buildSlopedCorridor(f, a, b)
		return f
	end
	local alongZ = a.pos.x == b.pos.x
	local p0, p1
	if alongZ then
		local lo, hi = if a.pos.z < b.pos.z then a else b, if a.pos.z < b.pos.z then b else a
		p0 = lo.pos.z + lo.size.z / 2 + WALL
		p1 = hi.pos.z - hi.size.z / 2 - WALL
		local len = p1 - p0
		local cz = (p0 + p1) / 2
		local x, y = a.pos.x, a.pos.y
		part(f, "Floor", Vector3.new(W + WALL * 2, 1, len), CFrame.new(x, y - 0.5, cz), STONE_DARK)
		part(f, "Ceiling", Vector3.new(W + WALL * 2, 2, len), CFrame.new(x, y + H + 1, cz))
		part(f, "WallE", Vector3.new(WALL, H, len), CFrame.new(x + W / 2 + WALL / 2, y + H / 2, cz))
		part(f, "WallW", Vector3.new(WALL, H, len), CFrame.new(x - W / 2 - WALL / 2, y + H / 2, cz))
		-- chisel-mark rhythm so long straights are readable in the dark
		for zz = p0 + 8, p1 - 8, 16 do
			deco(f, "Rib", Vector3.new(W + 1, 0.6, 1.2), CFrame.new(x, y + H - 0.3, zz), STONE_DARK)
		end
	else
		local lo, hi = if a.pos.x < b.pos.x then a else b, if a.pos.x < b.pos.x then b else a
		p0 = lo.pos.x + lo.size.x / 2 + WALL
		p1 = hi.pos.x - hi.size.x / 2 - WALL
		local len = p1 - p0
		local cx = (p0 + p1) / 2
		local z, y = a.pos.z, a.pos.y
		part(f, "Floor", Vector3.new(len, 1, W + WALL * 2), CFrame.new(cx, y - 0.5, z), STONE_DARK)
		part(f, "Ceiling", Vector3.new(len, 2, W + WALL * 2), CFrame.new(cx, y + H + 1, z))
		part(f, "WallN", Vector3.new(len, H, WALL), CFrame.new(cx, y + H / 2, z + W / 2 + WALL / 2))
		part(f, "WallS", Vector3.new(len, H, WALL), CFrame.new(cx, y + H / 2, z - W / 2 - WALL / 2))
		for xx = p0 + 8, p1 - 8, 16 do
			deco(f, "Rib", Vector3.new(1.2, 0.6, W + 1), CFrame.new(xx, y + H - 0.3, z), STONE_DARK)
		end
	end
	return f
end

local function buildLandmarks()
	local r01 = regionFolders.R01
	local lm = folder(r01, "Landmarks")
	-- Split pier: a dry-stacked pier split by a vertical crack
	local pier = assert(WorldDefs.chamber("R01.split_pier"))
	for _, dx in { -2.6, 2.6 } do
		part(
			lm,
			"SplitPier",
			Vector3.new(4.4, pier.size.y, 8),
			CFrame.new(pier.pos.x + dx, pier.size.y / 2, pier.pos.z),
			STONE,
			Enum.Material.Cobblestone
		)
	end
	-- Sloped gallery: an inclined ceiling slab and fallen blocks
	local slope = assert(WorldDefs.chamber("R01.sloped_gallery"))
	part(
		lm,
		"SlopedSlab",
		Vector3.new(slope.size.x, 2, slope.size.z * 1.05),
		CFrame.new(slope.pos.x, slope.size.y - 5, slope.pos.z) * CFrame.Angles(math.rad(14), 0, 0),
		STONE
	)
	part(
		lm,
		"FallenBlock",
		Vector3.new(5, 3, 4),
		CFrame.new(slope.pos.x + 7, 1.5, slope.pos.z - 6) * CFrame.Angles(0, 0.4, 0.1),
		STONE
	)
	-- Rusted pulley: frame + wheel, with a rope hanging into a shaft mouth in the ceiling
	local pul = assert(WorldDefs.chamber("R01.rusted_pulley"))
	local px, pz = pul.pos.x + 6, pul.pos.z + 4
	part(lm, "PulleyPostA", Vector3.new(1, 14, 1), CFrame.new(px - 3, 7, pz), RUST, Enum.Material.CorrodedMetal)
	part(lm, "PulleyPostB", Vector3.new(1, 14, 1), CFrame.new(px + 3, 7, pz), RUST, Enum.Material.CorrodedMetal)
	part(lm, "PulleyBeam", Vector3.new(7, 1, 1), CFrame.new(px, 14, pz), RUST, Enum.Material.CorrodedMetal)
	local wheel =
		part(lm, "PulleyWheel", Vector3.new(0.6, 4, 4), CFrame.new(px, 12, pz), RUST, Enum.Material.CorrodedMetal)
	wheel.Shape = Enum.PartType.Cylinder
	deco(lm, "HangingRope", Vector3.new(0.3, 10, 0.3), CFrame.new(px + 1.6, 7, pz), WOOD, Enum.Material.Fabric)
	-- Survey board: numbered survey plaque (R01 orientation landmark)
	local sb = assert(WorldDefs.chamber("R01.survey_board"))
	local board = part(
		lm,
		"SurveyBoard",
		Vector3.new(8, 5, 0.6),
		CFrame.new(sb.pos.x, 5, sb.pos.z + sb.size.z / 2 - 0.4),
		WOOD,
		Enum.Material.WoodPlanks
	)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 1
	gui.Parent = board
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = Enum.Font.SpecialElite
	t.TextColor3 = Color3.fromRGB(230, 222, 200)
	t.Text = "GALERIE 14\nN ▲ PILIER FENDU\nE ▶ ABRI"
	t.Parent = gui
	-- Rubble: noisy footing tagged for creature hearing (section 10: Scrabbler searches noisy rubble routes)
	local rub = assert(WorldDefs.chamber("R01.rubble_room"))
	local rubbleFolder = folder(lm, "Rubble")
	local rng = Random.new(1401)
	for i = 1, 16 do
		local sx, sz = rng:NextNumber(-12, 12), rng:NextNumber(-10, 10)
		part(
			rubbleFolder,
			"Rubble" .. i,
			Vector3.new(rng:NextNumber(1.5, 3.5), rng:NextNumber(0.6, 1.4), rng:NextNumber(1.5, 3.5)),
			CFrame.new(rub.pos.x + sx, 0.4, rub.pos.z + sz) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
			STONE_DARK,
			Enum.Material.Slate
		)
	end
	local noisy = part(
		lm,
		"NoisyFloorVolume",
		Vector3.new(rub.size.x, 6, rub.size.z + 40),
		CFrame.new(rub.pos.x, 3, rub.pos.z),
		STONE
	)
	noisy.Transparency = 1
	noisy.CanCollide = false
	noisy.CanQuery = false
	CollectionService:AddTag(noisy, "NoisyFloor")
end

-- Ossuary inserts: authored panels of arranged bone, never wall-to-wall skull wallpaper (section 04, R02).
local function boneInsert(parent: Instance, center: Vector3, facing: Vector3, width: number)
	local cf = CFrame.lookAt(center, center + facing)
	part(parent, "OssuaryInsert", Vector3.new(width, 5, 0.8), cf * CFrame.new(0, 0, 0.4), BONE, Enum.Material.Pebble)
	local cols = math.max(3, math.floor(width / 1.6))
	for row = 0, 1 do
		for col = 0, cols - 1 do
			local x = -width / 2 + 0.8 + col * ((width - 1.6) / (cols - 1))
			local skull = deco(
				parent,
				"Skull",
				Vector3.new(1.1, 1.1, 1.1),
				cf * CFrame.new(x, -1 + row * 2.2, -0.2),
				BONE,
				Enum.Material.SmoothPlastic
			)
			skull.Shape = Enum.PartType.Ball
		end
	end
	deco(
		parent,
		"Femurs",
		Vector3.new(width, 0.5, 0.5),
		cf * CFrame.new(0, 0.1, -0.1),
		BONE,
		Enum.Material.SmoothPlastic
	)
end

local function plaque(parent: Instance, cf: CFrame, text: string, size: Vector2?)
	local sz = size or Vector2.new(3.2, 1.6)
	local p =
		part(parent, "Plaque", Vector3.new(sz.X, sz.Y, 0.25), cf, Color3.fromRGB(150, 146, 136), Enum.Material.Marble)
	p.CanCollide = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 1
	gui.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = Enum.Font.Antique
	t.TextColor3 = Color3.fromRGB(40, 38, 34)
	t.Text = text
	t.Parent = gui
	return p
end

local function buildOssuary()
	local f = folder(regionFolders.R02, "Landmarks")
	-- Bone Gate: two bone-faced piers flanking the way north
	local bg = assert(WorldDefs.chamber("R02.bone_gate"))
	local y0 = bg.pos.y
	for _, dx in { -9, 9 } do
		local pier = part(
			f,
			"BoneGatePier",
			Vector3.new(4, 12, 4),
			CFrame.new(bg.pos.x + dx, y0 + 6, bg.pos.z + 10),
			BONE,
			Enum.Material.Pebble
		)
		pier.Name = "BoneGatePier"
	end
	part(
		f,
		"BoneGateLintel",
		Vector3.new(22, 2, 4),
		CFrame.new(bg.pos.x, y0 + 12, bg.pos.z + 10),
		BONE,
		Enum.Material.Pebble
	)
	plaque(f, CFrame.new(bg.pos.x, y0 + 9, bg.pos.z + 7.8), "OSSUAIRE — SECTEUR NORD", Vector2.new(8, 1.4))
	boneInsert(f, Vector3.new(bg.pos.x - 13.6, y0 + 3.5, bg.pos.z - 10), Vector3.new(1, 0, 0), 6)
	-- Hall of Plaques: numbered plaques in rows (histories identify places; one row is the P01 clue context)
	local ph = assert(WorldDefs.chamber("R02.plaque_hall"))
	local yh = ph.pos.y
	for i = 0, 3 do
		plaque(
			f,
			CFrame.new(ph.pos.x + 14.6, yh + 4 + (i % 2) * 2, ph.pos.z - 16 + i * 2.4)
				* CFrame.Angles(0, math.pi / 2, 0),
			string.format("GALERIE %d\nRELEVÉ %d", 31 + i, 1786 + i * 3)
		)
	end
	for i = 0, 3 do
		plaque(
			f,
			CFrame.new(ph.pos.x - 14.6, yh + 4 + (i % 2) * 2, ph.pos.z + 9 + i * 2.4)
				* CFrame.Angles(0, -math.pi / 2, 0),
			string.format("SECTEUR %s", string.char(65 + i))
		)
	end
	-- inserts avoid the doorways and the P01 carvings (south-west and north-east)
	boneInsert(f, Vector3.new(ph.pos.x - 10, yh + 3.5, ph.pos.z + 19.4), Vector3.new(0, 0, -1), 7)
	boneInsert(f, Vector3.new(ph.pos.x + 10, yh + 3.5, ph.pos.z - 19.4), Vector3.new(0, 0, 1), 7)
	-- Lantern Crypt: empty lamp niches
	local lc = assert(WorldDefs.chamber("R02.lantern_crypt"))
	for i = -1, 1 do
		local nx = lc.pos.x - 12.4
		deco(
			f,
			"LampNiche",
			Vector3.new(0.4, 2, 1.6),
			CFrame.new(nx, lc.pos.y + 5, lc.pos.z + i * 6),
			Color3.fromRGB(14, 12, 10),
			Enum.Material.SmoothPlastic
		)
		part(f, "NicheSill", Vector3.new(1, 0.3, 2.2), CFrame.new(nx + 0.3, lc.pos.y + 4, lc.pos.z + i * 6), STONE)
	end
	boneInsert(f, Vector3.new(lc.pos.x, lc.pos.y + 3.5, lc.pos.z + 12.4), Vector3.new(0, 0, -1), 10)
	-- Sealed Chapel: altar and a tarnished cross-free reliquary shelf (neutral, fictional)
	local ch = assert(WorldDefs.chamber("R02.sealed_chapel"))
	part(
		f,
		"Altar",
		Vector3.new(6, 3, 3),
		CFrame.new(ch.pos.x, ch.pos.y + 1.5, ch.pos.z + 8),
		STONE,
		Enum.Material.Marble
	)
	plaque(f, CFrame.new(ch.pos.x, ch.pos.y + 6, ch.pos.z + 11.6), "RELEVÉ SCELLÉ — ÉQUIPE 7", Vector2.new(6, 1.4))
	-- Long Ossuary: inserts along both walls
	local lo = assert(WorldDefs.chamber("R02.ossuary_long"))
	boneInsert(f, Vector3.new(lo.pos.x - 11.6, lo.pos.y + 3.5, lo.pos.z - 4), Vector3.new(1, 0, 0), 8)
	boneInsert(f, Vector3.new(lo.pos.x + 11.6, lo.pos.y + 3.5, lo.pos.z + 4), Vector3.new(-1, 0, 0), 8)
end

local function waterVolume(parent: Instance, center: Vector3, size: Vector3)
	-- Shallow water: non-colliding, unqueryable volume whose top is 1.2 studs above the floor.
	local w = part(
		parent,
		"ShallowWater",
		Vector3.new(size.X, 1.2, size.Z),
		CFrame.new(center.X, center.Y + 0.6, center.Z),
		WATER,
		Enum.Material.Glass
	)
	w.Transparency = 0.35
	w.Reflectance = 0.15
	w.CanCollide = false
	w.CanQuery = false
	w.CastShadow = false
	CollectionService:AddTag(w, "ShallowWater")
	return w
end

local function stone(parent: Instance, x: number, y: number, z: number)
	-- Stepping stone: dry footing above the water line (silent to water-sensitive hearing).
	part(
		parent,
		"SteppingStone",
		Vector3.new(3.2, 1.7, 3.2),
		CFrame.new(x, y + 0.85, z) * CFrame.Angles(0, math.rad((x * 37 + z) % 40), 0),
		WET,
		Enum.Material.Slate
	)
end

local function buildWaterworks()
	local f = folder(WorldBuilder.folder("R03"), "Landmarks")
	for _, c in WorldDefs.Chambers do
		if chamberWet(c) then
			waterVolume(f, v(c.pos), Vector3.new(c.size.x, 0, c.size.z))
		end
		if WET_REGIONS[c.regionId] then
			-- silt lines: old water marks painted along each wall
			local silt = Color3.fromRGB(70, 64, 50)
			local y = c.pos.y + 2.6
			deco(
				f,
				"SiltLine",
				Vector3.new(c.size.x, 0.25, 0.1),
				CFrame.new(c.pos.x, y, c.pos.z + c.size.z / 2 - 0.05),
				silt,
				Enum.Material.Mud
			)
			deco(
				f,
				"SiltLine",
				Vector3.new(c.size.x, 0.25, 0.1),
				CFrame.new(c.pos.x, y, c.pos.z - c.size.z / 2 + 0.05),
				silt,
				Enum.Material.Mud
			)
			deco(
				f,
				"SiltLine",
				Vector3.new(0.1, 0.25, c.size.z),
				CFrame.new(c.pos.x + c.size.x / 2 - 0.05, y, c.pos.z),
				silt,
				Enum.Material.Mud
			)
			deco(
				f,
				"SiltLine",
				Vector3.new(0.1, 0.25, c.size.z),
				CFrame.new(c.pos.x - c.size.x / 2 + 0.05, y, c.pos.z),
				silt,
				Enum.Material.Mud
			)
		end
	end
	for _, cor in WorldDefs.Corridors do
		local a, b = assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to))
		if corridorWet(cor, a, b) then
			-- exact corridor span between the two chamber walls
			if a.pos.x == b.pos.x then
				local lo, hi = if a.pos.z < b.pos.z then a else b, if a.pos.z < b.pos.z then b else a
				local z0, z1 = lo.pos.z + lo.size.z / 2, hi.pos.z - hi.size.z / 2
				waterVolume(f, Vector3.new(a.pos.x, a.pos.y, (z0 + z1) / 2), Vector3.new(W, 0, z1 - z0))
			else
				local lo, hi = if a.pos.x < b.pos.x then a else b, if a.pos.x < b.pos.x then b else a
				local x0, x1 = lo.pos.x + lo.size.x / 2, hi.pos.x - hi.size.x / 2
				waterVolume(f, Vector3.new((x0 + x1) / 2, a.pos.y, a.pos.z), Vector3.new(x1 - x0, 0, W))
			end
		end
	end
	-- Stepping-stone routes: slow, dry, silent alternatives across the sluice and the silt works.
	local sl = assert(WorldDefs.chamber("R03.sluice"))
	for _, o in { { 0, -14 }, { -2, -9 }, { -5, -5 }, { -9, -1 }, { -12, 0 } } do
		stone(f, sl.pos.x + o[1], sl.pos.y, sl.pos.z + o[2])
	end
	local si = assert(WorldDefs.chamber("R03.silt_loop"))
	-- east door to the north door (pump platform), and east door to the south door (the dry route, M05)
	for _, o in { { 10, 0 }, { 7, 3 }, { 3, 6 }, { 0, 10 }, { 7, -3 }, { 3, -6 }, { 0, -10 } } do
		stone(f, si.pos.x + o[1], si.pos.y, si.pos.z + o[2])
	end
	-- Old pumps: large housings and pipes in the dry gallery
	local pg = assert(WorldDefs.chamber("R03.pump_gallery"))
	for i = -1, 1, 2 do
		local housing = part(
			f,
			"PumpHousing",
			Vector3.new(6, 5, 5),
			CFrame.new(pg.pos.x + i * 8, pg.pos.y + 2.5, pg.pos.z + 8),
			RUST,
			Enum.Material.CorrodedMetal
		)
		housing.Shape = Enum.PartType.Cylinder
		part(
			f,
			"PumpPipe",
			Vector3.new(1.4, 12, 1.4),
			CFrame.new(pg.pos.x + i * 8, pg.pos.y + 9, pg.pos.z + 8),
			RUST,
			Enum.Material.CorrodedMetal
		)
	end
	for i = 0, 2 do
		deco(
			f,
			"WallPipe",
			Vector3.new(1, 1, 30),
			CFrame.new(pg.pos.x + 15.3, pg.pos.y + 9 + i * 1.6, pg.pos.z),
			RUST,
			Enum.Material.CorrodedMetal
		)
	end
	-- Pump platform: a raised iron deck (the shelter exterior is literally above the water)
	local pp = assert(WorldDefs.chamber("R03.pump_platform"))
	part(
		f,
		"PlatformGrate",
		Vector3.new(pp.size.x - 2, 0.4, pp.size.z - 2),
		CFrame.new(pp.pos.x, pp.pos.y + 0.2, pp.pos.z),
		Color3.fromRGB(70, 70, 72),
		Enum.Material.DiamondPlate
	)
end

-- Hiding niches (F07): a shallow framed recess against a wall. Players step in via a prompt.
local function buildHidingSpots()
	local f = folder(root, "HidingSpots")
	for _, hs in WorldDefs.HidingSpots do
		local base = v(hs.pos)
		local facing = v(hs.facing).Unit
		local side = Vector3.new(-facing.Z, 0, facing.X)
		local cf = CFrame.lookAt(base, base + facing)
		for _, sgn in { -1, 1 } do
			part(
				f,
				"NichePillar",
				Vector3.new(1, 8, 2.6),
				CFrame.new(base + side * sgn * 2.4 + facing * 1.3 + Vector3.new(0, 4, 0)) * (cf - cf.Position),
				STONE_DARK,
				Enum.Material.Cobblestone
			)
		end
		part(
			f,
			"NicheLintel",
			Vector3.new(5.8, 1, 2.6),
			CFrame.new(base + facing * 1.3 + Vector3.new(0, 8.5, 0)) * (cf - cf.Position),
			STONE_DARK,
			Enum.Material.Cobblestone
		)
		local anchor = part(
			f,
			"HideAnchor",
			Vector3.new(3, 6, 1),
			CFrame.new(base + facing * 1.6 + Vector3.new(0, 3, 0)) * (cf - cf.Position)
		)
		anchor.Transparency = 1
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor:SetAttribute("HidingSpotId", hs.id)
		CollectionService:AddTag(anchor, "HidingSpot")
	end
end

local SIDE_OFFSETS = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
}

-- World position of a shelter's exterior door and the CFrame where players stand when stepping outside.
function WorldBuilder.shelterDoor(shelterId: string): (Vector3, CFrame)
	local s = WorldDefs.Shelters[shelterId]
	local c = assert(WorldDefs.chamber(s.exteriorChamberId))
	local dir = SIDE_OFFSETS[s.doorSide]
	local half = if dir.X ~= 0 then c.size.x / 2 else c.size.z / 2
	local door = v(c.pos) + dir * (half - 0.5) + Vector3.new(0, 4.5, 0)
	local stand = v(c.pos) + dir * (half - 5) + Vector3.new(0, 3, 0)
	return door, CFrame.lookAt(stand, stand - dir)
end

local function buildShelterExteriors()
	for id, s in WorldDefs.Shelters do
		local c = assert(WorldDefs.chamber(s.exteriorChamberId))
		local f = folder(WorldBuilder.folder(s.regionId), "ShelterExterior_" .. id)
		local doorPos = WorldBuilder.shelterDoor(id)
		local dir = SIDE_OFFSETS[s.doorSide]
		local size = if dir.X ~= 0 then Vector3.new(1, 9, 8) else Vector3.new(8, 9, 1)
		local color = if s.theme == "office"
			then WOOD
			elseif s.theme == "ironwork" then Color3.fromRGB(70, 70, 72)
			else RUST
		local door = part(
			f,
			"ShelterDoor",
			size,
			CFrame.new(doorPos),
			color,
			if s.theme == "office" then Enum.Material.WoodPlanks else Enum.Material.CorrodedMetal
		)
		door:SetAttribute("ShelterId", id)
		CollectionService:AddTag(door, "ShelterDoor")
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Enter shelter"
		prompt.ObjectText = s.name
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = door
		local reg =
			part(f, "RegisterVolume", Vector3.new(c.size.x, 10, c.size.z), CFrame.new(c.pos.x, c.pos.y + 5, c.pos.z))
		reg.Transparency = 1
		reg.CanCollide = false
		reg.CanQuery = false
		reg:SetAttribute("ShelterId", id)
		CollectionService:AddTag(reg, "ShelterApproach")
	end
end

local function buildDepot()
	local f = regionFolders.R00
	local d = WorldDefs.Depot
	local cy = d.courtyard.pos.y
	part(
		f,
		"Courtyard",
		Vector3.new(d.courtyard.size.x, 1, d.courtyard.size.z),
		CFrame.new(0, cy - 0.5, 0),
		Color3.fromRGB(96, 96, 100),
		Enum.Material.Cobblestone
	)
	-- perimeter walls (city noise lives above; Audio cues are listed in docs/AUDIO-CUES.md)
	part(
		f,
		"WallS",
		Vector3.new(70, 16, 2),
		CFrame.new(0, cy + 8, -31),
		Color3.fromRGB(150, 140, 125),
		Enum.Material.Brick
	)
	part(
		f,
		"WallE",
		Vector3.new(2, 16, 62),
		CFrame.new(36, cy + 8, 0),
		Color3.fromRGB(150, 140, 125),
		Enum.Material.Brick
	)
	part(
		f,
		"WallW",
		Vector3.new(2, 16, 62),
		CFrame.new(-36, cy + 8, 0),
		Color3.fromRGB(150, 140, 125),
		Enum.Material.Brick
	)
	part(
		f,
		"WallN_W",
		Vector3.new(29, 16, 2),
		CFrame.new(-21.5, cy + 8, 31),
		Color3.fromRGB(150, 140, 125),
		Enum.Material.Brick
	)
	part(
		f,
		"WallN_E",
		Vector3.new(29, 16, 2),
		CFrame.new(21.5, cy + 8, 31),
		Color3.fromRGB(150, 140, 125),
		Enum.Material.Brick
	)
	-- equipment room
	local er = d.equipmentRoom
	local erf = folder(f, "EquipmentRoom")
	part(
		erf,
		"Back",
		Vector3.new(er.size.x, er.size.y, 1),
		CFrame.new(er.pos.x, cy + er.size.y / 2, er.pos.z - er.size.z / 2),
		STONE
	)
	part(
		erf,
		"Side",
		Vector3.new(1, er.size.y, er.size.z),
		CFrame.new(er.pos.x - er.size.x / 2, cy + er.size.y / 2, er.pos.z),
		STONE
	)
	part(
		erf,
		"Roof",
		Vector3.new(er.size.x, 1, er.size.z),
		CFrame.new(er.pos.x, cy + er.size.y, er.pos.z),
		Color3.fromRGB(70, 70, 75),
		Enum.Material.Slate
	)
	part(
		erf,
		"Shelf",
		Vector3.new(8, 4, 2),
		CFrame.new(er.pos.x - 3, cy + 2, er.pos.z - er.size.z / 2 + 1.5),
		WOOD,
		Enum.Material.WoodPlanks
	)
	-- mission board
	local mb =
		part(f, "MissionBoard", Vector3.new(6, 4, 0.5), CFrame.new(v(d.missionBoard)), WOOD, Enum.Material.WoodPlanks)
	mb:SetAttribute("MissionBoard", true)
	CollectionService:AddTag(mb, "MissionBoard")
	-- descent house + ramp
	local top, bot = v(d.ramp.top), v(d.ramp.bottom)
	local hf = folder(f, "DescentHouse")
	part(
		hf,
		"HouseW",
		Vector3.new(2, 14, 24),
		CFrame.new(-W / 2 - 1, cy + 7, top.Z + 12),
		STONE_DARK,
		Enum.Material.Brick
	)
	part(
		hf,
		"HouseE",
		Vector3.new(2, 14, 24),
		CFrame.new(W / 2 + 1, cy + 7, top.Z + 12),
		STONE_DARK,
		Enum.Material.Brick
	)
	part(
		hf,
		"HouseRoof",
		Vector3.new(W + 4, 1, 24),
		CFrame.new(0, cy + 14, top.Z + 12),
		Color3.fromRGB(70, 70, 75),
		Enum.Material.Slate
	)
	local rf = folder(regionFolders.R01, "DescentRamp")
	local delta = bot - top
	local len = delta.Magnitude
	local mid = (top + bot) / 2
	local look = CFrame.lookAt(mid, bot)
	part(rf, "RampFloor", Vector3.new(W, 1, len), look * CFrame.new(0, -0.5, 0), STONE_DARK, Enum.Material.Slate)
	part(rf, "RampCeiling", Vector3.new(W + 4, 2, len), look * CFrame.new(0, H + 1, 0), STONE)
	part(rf, "RampWallE", Vector3.new(WALL, H + 2, len), look * CFrame.new(W / 2 + 1, H / 2, 0), STONE)
	part(rf, "RampWallW", Vector3.new(WALL, H + 2, len), look * CFrame.new(-W / 2 - 1, H / 2, 0), STONE)
	-- step treads for grip / readable slope
	for i = 1, math.floor(len / 4) do
		deco(rf, "Tread", Vector3.new(W - 1, 0.25, 0.4), look * CFrame.new(0, 0.1, -len / 2 + i * 4), STONE)
	end
	local rv = part(rf, "DescentVolume", Vector3.new(W, H, len), look * CFrame.new(0, H / 2, 0))
	rv.Transparency = 1
	rv.CanCollide = false
	rv.CanQuery = false
	rv:SetAttribute("ChamberId", "R00.descent_ramp")
	rv:SetAttribute("RegionId", "R00")
	CollectionService:AddTag(rv, "DiscoveryVolume")
	for _, id in { "R00.mission_board", "R00.equipment_room" } do
		local pos = if id == "R00.mission_board" then v(d.missionBoard) else Vector3.new(er.pos.x, cy + 4, er.pos.z)
		local dv = part(f, "Volume_" .. id, Vector3.new(16, 10, 16), CFrame.new(pos))
		dv.Transparency = 1
		dv.CanCollide = false
		dv.CanQuery = false
		dv:SetAttribute("ChamberId", id)
		dv:SetAttribute("RegionId", "R00")
		CollectionService:AddTag(dv, "DiscoveryVolume")
	end
	-- spawn
	local sp = Instance.new("SpawnLocation")
	sp.Name = "DepotSpawn"
	sp.Anchored = true
	sp.Size = Vector3.new(6, 1, 6)
	sp.CFrame = CFrame.new(v(d.spawn) - Vector3.new(0, 2.5, 0))
	sp.Transparency = 1
	sp.CanCollide = false
	sp.Neutral = true
	sp.Parent = f
end

local function applyLighting()
	Lighting.Ambient = Color3.fromRGB(6, 6, 8) -- enclosed tunnels: faint, never solid black
	Lighting.OutdoorAmbient = Color3.fromRGB(70, 72, 80)
	Lighting.Brightness = 1
	Lighting.ClockTime = 18.6
	Lighting.FogColor = Color3.fromRGB(10, 10, 12)
	Lighting.EnvironmentDiffuseScale = 0.15
	Lighting.EnvironmentSpecularScale = 0.2
	pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	local atm = Instance.new("Atmosphere")
	atm.Density = 0.32
	atm.Haze = 1.4
	atm.Color = Color3.fromRGB(150, 150, 160)
	atm.Decay = Color3.fromRGB(80, 80, 90)
	atm.Parent = Lighting
end

-- Milestone 3 set-pieces (decor only; interactive props belong to the puzzle, story and mission services) --------

local PAPER = Color3.fromRGB(196, 186, 160)
local METAL = Color3.fromRGB(88, 90, 92)
local PLAQUE_COLOR = Color3.fromRGB(150, 146, 136)
local SHIFT_COLOR = Color3.fromRGB(214, 160, 70)

local function facingCF(pos: Vector3, dir: Vector3): CFrame
	return CFrame.lookAt(pos, pos + dir)
end

-- A survey desk at floor point `base`, its front facing `front`. Every desk carries the same instrument and lamp
-- (section 04, R04: familiar equipment appearing in incompatible decades); `label` is its date plaque.
local function surveyDesk(parent: Instance, base: Vector3, width: number, depth: number, front: Vector3, label: string?)
	local alongX = math.abs(front.Z) > math.abs(front.X)
	local sx, sz = if alongX then width else depth, if alongX then depth else width
	part(
		parent,
		"DeskTop",
		Vector3.new(sx, 0.3, sz),
		CFrame.new(base + Vector3.new(0, 2.6, 0)),
		WOOD,
		Enum.Material.WoodPlanks
	)
	for _, ax in { -1, 1 } do
		for _, az in { -1, 1 } do
			deco(
				parent,
				"DeskLeg",
				Vector3.new(0.25, 2.45, 0.25),
				CFrame.new(base + Vector3.new(ax * (sx / 2 - 0.3), 1.225, az * (sz / 2 - 0.3))),
				WOOD,
				Enum.Material.Wood
			)
		end
	end
	local side = Vector3.new(-front.Z, 0, front.X)
	deco(
		parent,
		"SurveyInstrument",
		Vector3.new(1.2, 0.9, 1.2),
		CFrame.new(base + side * (width / 4) + Vector3.new(0, 3.2, 0)),
		METAL,
		Enum.Material.Metal
	)
	deco(
		parent,
		"InstrumentDial",
		Vector3.new(0.6, 0.6, 0.6),
		CFrame.new(base + side * (width / 4) + front * 0.55 + Vector3.new(0, 3.25, 0)),
		PAPER,
		Enum.Material.SmoothPlastic
	).Shape =
		Enum.PartType.Ball
	deco(
		parent,
		"DeskLamp",
		Vector3.new(0.5, 1.2, 0.5),
		CFrame.new(base - side * (width / 4) + Vector3.new(0, 3.35, 0)),
		RUST,
		Enum.Material.Metal
	)
	if label then
		plaque(
			parent,
			facingCF(base + Vector3.new(0, 2.1, 0) + front * (depth / 2 + 0.14), front),
			label,
			Vector2.new(1.8, 0.6)
		)
	end
end

-- A rack against a wall at floor point `base` (its back on the wall), `length` along the wall, facing `front`.
-- Rows of identical items with one dated plaque per row.
local function wallRack(
	parent: Instance,
	name: string,
	base: Vector3,
	length: number,
	front: Vector3,
	itemColor: Color3,
	dates: { string }
)
	local side = Vector3.new(-front.Z, 0, front.X)
	local alongX = math.abs(side.X) > 0.5
	local size = if alongX then Vector3.new(length, 6, 1.2) else Vector3.new(1.2, 6, length)
	part(parent, name, size, CFrame.new(base + front * 0.6 + Vector3.new(0, 3, 0)), RUST, Enum.Material.CorrodedMetal)
	for row = 1, 3 do
		local y = row * 1.8
		local shelfSize = if alongX then Vector3.new(length, 0.2, 1) else Vector3.new(1, 0.2, length)
		deco(parent, name .. "Shelf", shelfSize, CFrame.new(base + front * 1.7 + Vector3.new(0, y, 0)), WOOD)
		local n = math.max(1, math.floor((length - 1) / 1.4))
		for i = 1, n do
			local along = -length / 2 + 0.7 + (i - 1) * ((length - 1.4) / math.max(1, n - 1))
			deco(
				parent,
				name .. "Item",
				Vector3.new(0.6, 0.9, 0.6),
				CFrame.new(base + front * 1.7 + side * along + Vector3.new(0, y + 0.55, 0)),
				itemColor,
				Enum.Material.SmoothPlastic
			)
		end
		local date = dates[(row - 1) % #dates + 1]
		plaque(
			parent,
			facingCF(base + front * 2.25 + side * (length / 2 - 1) + Vector3.new(0, y - 0.25, 0), front),
			date,
			Vector2.new(1.4, 0.45)
		)
	end
end

-- A low heap of collidable rubble and a fallen roof slab against one wall of a dead end.
local function rubbleHeap(parent: Instance, c: any, seed: number, towardX: number)
	local rng = Random.new(seed)
	local hx, hz = c.size.x / 2, c.size.z / 2
	for i = 1, 14 do
		local x = c.pos.x + towardX * rng:NextNumber(hx * 0.65, hx - 1.5)
		local z = c.pos.z + rng:NextNumber(-hz + 1.5, hz - 1.5)
		part(
			parent,
			"Rubble" .. i,
			Vector3.new(rng:NextNumber(1.5, 3.5), rng:NextNumber(0.6, 1.4), rng:NextNumber(1.5, 3.5)),
			CFrame.new(x, c.pos.y + 0.4, z) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
			STONE_DARK,
			Enum.Material.Slate
		)
	end
	-- a roof slab leaning on the far wall, its low edge toward the room
	part(
		parent,
		"FallenRoof",
		Vector3.new(5, 2, c.size.z - 2),
		CFrame.new(c.pos.x + towardX * (hx - 2.5), c.pos.y + 2.2, c.pos.z) * CFrame.Angles(0, 0, towardX * math.rad(28)),
		STONE,
		Enum.Material.Slate
	)
end

local function cable(parent: Instance, a: Vector3, b: Vector3)
	local len = (b - a).Magnitude
	if len < 0.5 then
		return
	end
	local mid = (a + b) / 2
	-- a cylinder's axis is its X axis; a vertical run is rotated directly (lookAt with a vertical direction and the
	-- default up vector is degenerate)
	local cf = if math.abs((b - a).Unit.Y) > 0.99
		then CFrame.new(mid) * CFrame.Angles(0, 0, math.rad(90))
		else CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0)
	local c = deco(parent, "Cable", Vector3.new(len, 0.25, 0.25), cf, Color3.fromRGB(30, 30, 30), Enum.Material.Rubber)
	c.Shape = Enum.PartType.Cylinder
end

local function buildSurveyStation()
	local f = folder(WorldBuilder.folder("R04"), "Landmarks")
	-- Station Hall: desks whose dates disagree on identical equipment, medical shelves, a battery rack, a field map
	local hall = assert(WorldDefs.chamber("R04.station_hall"))
	local hp, hy = v(hall.pos), hall.pos.y
	-- the cache desk ("under the desk with three calendars that disagree", M02 cache.station sits beneath it)
	surveyDesk(f, Vector3.new(hp.X - 9, hy, hp.Z - 13), 6, 3, Vector3.new(0, 0, 1), "RELEVÉ — ÉQUIPE 7")
	for i, year in { "1898", "1961", "1987" } do
		plaque(
			f,
			facingCF(Vector3.new(hp.X - 11 + (i - 1) * 2, hy + 3.3, hp.Z - 14.2), Vector3.new(0, 0, 1)),
			"CALENDRIER\n" .. year,
			Vector2.new(1.3, 1.1)
		)
	end
	surveyDesk(f, Vector3.new(hp.X + 9, hy, hp.Z + 8), 4, 3, Vector3.new(0, 0, -1), "RELEVÉ 1961")
	surveyDesk(f, Vector3.new(hp.X + 12, hy, hp.Z + 15), 8, 2, Vector3.new(0, 0, -1), "RELEVÉ 1987")
	-- medical shelves on the south wall, east of the doorway (the medical_shelves scavenging site stands in front)
	wallRack(
		f,
		"MedicalShelves",
		Vector3.new(hp.X + 10.5, hy, hp.Z - hall.size.z / 2),
		7,
		Vector3.new(0, 0, 1),
		Color3.fromRGB(220, 216, 204),
		{ "+ MÉDICAL 1961", "+ MÉDICAL 1898", "+ MÉDICAL 1987" }
	)
	wallRack(
		f,
		"BatteryRack",
		Vector3.new(hp.X + hall.size.x / 2, hy, hp.Z + 9.75),
		6.5,
		Vector3.new(-1, 0, 0),
		Color3.fromRGB(70, 66, 52),
		{ "PILES 1898", "PILES 1987", "PILES 1961" }
	)
	plaque(
		f,
		facingCF(Vector3.new(hp.X - 9, hy + 6, hp.Z + hall.size.z / 2 - 0.15), Vector3.new(0, 0, -1)),
		"CARTE DE TERRAIN\nGALERIES 14–31\nLEVÉ 1898 / 1987",
		Vector2.new(5, 3)
	).Name =
		"FieldMap"
	for _, dz in { -8, 8 } do
		cable(
			f,
			Vector3.new(hp.X - hall.size.x / 2, hy + 13.4, hp.Z + dz),
			Vector3.new(hp.X + hall.size.x / 2, hy + 13.4, hp.Z + dz)
		)
	end

	-- Battery Store: dated battery racks (Wick Moth zone)
	local bs = assert(WorldDefs.chamber("R04.battery_store"))
	local bp = v(bs.pos)
	wallRack(
		f,
		"BatteryRack",
		Vector3.new(bp.X - 7, bs.pos.y, bp.Z - bs.size.z / 2),
		10,
		Vector3.new(0, 0, 1),
		Color3.fromRGB(70, 66, 52),
		{ "PILES 1961", "PILES 1898", "PILES 1987" }
	)
	wallRack(
		f,
		"BatteryRack",
		Vector3.new(bp.X + bs.size.x / 2, bs.pos.y, bp.Z + 9),
		5,
		Vector3.new(-1, 0, 0),
		Color3.fromRGB(70, 66, 52),
		{ "PILES 1987" }
	)

	-- Collapsed Adit: the Borrowed Miner's misleading dead end
	rubbleHeap(f, assert(WorldDefs.chamber("R04.collapsed_adit")), 4101, -1)

	-- Radio Room: dated station plate (the radio itself is P05, built by PuzzleService)
	local rr = assert(WorldDefs.chamber("R04.radio_room"))
	plaque(
		f,
		facingCF(Vector3.new(rr.pos.x, rr.pos.y + 7, rr.pos.z - rr.size.z / 2 + 0.15), Vector3.new(0, 0, 1)),
		"STATION D'ÉCOUTE — 1961",
		Vector2.new(5, 1.2)
	)

	-- Generator Room: housing around the P03 generator point; the north wall (P03 boxes) stays clear
	local gr = assert(WorldDefs.chamber("R04.generator_room"))
	local gen = WorldDefs.Puzzles.P03.generator
	local gp = Vector3.new(gen.x, gr.pos.y, gen.z)
	part(
		f,
		"GeneratorHousing",
		Vector3.new(8, 5, 6),
		CFrame.new(gp + Vector3.new(0, 2.5, 0)),
		RUST,
		Enum.Material.CorrodedMetal
	)
	part(
		f,
		"GeneratorExhaust",
		Vector3.new(1.2, gr.size.y - 5, 1.2),
		CFrame.new(gp + Vector3.new(2.5, 5 + (gr.size.y - 5) / 2, -1.5)),
		RUST,
		Enum.Material.CorrodedMetal
	)
	for i, o in { Vector3.new(-6.5, 0, -4), Vector3.new(-6.5, 0, -1.4) } do
		local drum = part(
			f,
			"FuelDrum" .. i,
			Vector3.new(3, 2.2, 2.2),
			CFrame.new(gp + o + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(90, 40, 30),
			Enum.Material.CorrodedMetal
		)
		drum.Shape = Enum.PartType.Cylinder
	end
	-- cable runs along the ceiling to the east and west doorways
	local cy = gr.pos.y + gr.size.y - 0.5
	cable(f, gp + Vector3.new(0, 5, 0), Vector3.new(gp.X, cy, gp.Z))
	cable(f, Vector3.new(gr.pos.x - gr.size.x / 2, cy, gp.Z), Vector3.new(gr.pos.x + gr.size.x / 2, cy, gp.Z))

	-- Map Room: field maps that disagree; the area round the story package's map table is left free
	local mr = assert(WorldDefs.chamber("R04.map_room"))
	local mp, my = v(mr.pos), mr.pos.y
	local ex = mp.X + mr.size.x / 2 - 0.15
	plaque(
		f,
		facingCF(Vector3.new(ex, my + 6, mp.Z - 8), Vector3.new(-1, 0, 0)),
		"LEVÉ 1898\nGALERIE 51 — 58 m",
		Vector2.new(4.5, 3)
	).Name =
		"FieldMap"
	plaque(
		f,
		facingCF(Vector3.new(ex, my + 6, mp.Z - 2.5), Vector3.new(-1, 0, 0)),
		"LEVÉ 1987\nGALERIE 51 — 112 m",
		Vector2.new(4.5, 3)
	).Name =
		"FieldMap"
	-- "the map that shows a street where no street can be" (M02 cache.maproom lies below it)
	plaque(
		f,
		facingCF(Vector3.new(mp.X - 10, my + 6, mp.Z + mr.size.z / 2 - 0.15), Vector3.new(0, 0, -1)),
		"PLAN — RUE DES CARRIERS\n(aucune rue ici)",
		Vector2.new(5, 3)
	).Name =
		"FieldMap"
	-- decorative surround of the map table spot (about 14, -64, 1024): a worn floor mat and a hanging lamp, no
	-- collision, so the story package's interactive table can stand there
	deco(
		f,
		"MapTableMat",
		Vector3.new(10, 0.1, 8),
		CFrame.new(14, my + 0.05, 1024),
		Color3.fromRGB(70, 56, 40),
		Enum.Material.Fabric
	)
	local hang =
		deco(f, "MapTableLamp", Vector3.new(1, 0.8, 1), CFrame.new(14, my + 11, 1024), RUST, Enum.Material.Metal)
	local lamp = Instance.new("PointLight")
	lamp.Range = 14
	lamp.Brightness = 0.6
	lamp.Color = Color3.fromRGB(255, 214, 160)
	lamp.Parent = hang
	cable(f, Vector3.new(14, my + 11.4, 1024), Vector3.new(14, my + mr.size.y, 1024))

	-- Service Office exterior (S04): a dated door plate
	local so = assert(WorldDefs.chamber("R04.service_office"))
	plaque(
		f,
		facingCF(Vector3.new(so.pos.x, so.pos.y + 6, so.pos.z + so.size.z / 2 - 0.15), Vector3.new(0, 0, -1)),
		"BUREAU DE SERVICE — 1961",
		Vector2.new(5, 1.2)
	)
end

local function buildCrossroads()
	local f = folder(WorldBuilder.folder("R05"), "Landmarks")
	-- Survey anchor plaques (section 04: stable anchor rooms with recognizable survey anchors)
	local anchors = {
		{ id = "R05.south_anchor", wall = "E", along = 4, name = "ANCRE SUD" },
		{ id = "R05.west_anchor", wall = "N", along = -6, name = "ANCRE OUEST" },
		{ id = "R05.center_anchor", wall = "N", along = -10, name = "CROISEMENT MESURÉ" },
		{ id = "R05.east_anchor", wall = "E", along = 4, name = "ANCRE EST" },
	}
	for _, a in anchors do
		local c = assert(WorldDefs.chamber(a.id))
		local pos, dir
		if a.wall == "E" then
			pos = Vector3.new(c.pos.x + c.size.x / 2 - 0.15, c.pos.y + 6, c.pos.z + a.along)
			dir = Vector3.new(-1, 0, 0)
		else
			pos = Vector3.new(c.pos.x + a.along, c.pos.y + 6, c.pos.z + c.size.z / 2 - 0.15)
			dir = Vector3.new(0, 0, -1)
		end
		local p = plaque(
			f,
			facingCF(pos, dir),
			Pockets.ANCHOR_SYMBOLS[a.id] .. "\nREPÈRE — " .. a.name,
			Vector2.new(3, 2.4)
		)
		p.Name = "AnchorPlaque"
		p:SetAttribute("AnchorSymbol", Pockets.ANCHOR_SYMBOLS[a.id])
	end
	-- Numbered threshold plates at every pocket mouth; they glow while a change is telegraphed
	for id, pk in WorldDefs.Pockets do
		for _, t in Pockets.thresholds(pk) do
			local pos = Vector3.new(t.pos.x, t.pos.y, t.pos.z)
			local p = plaque(f, facingCF(pos, Vector3.new(t.normal.x, 0, t.normal.z)), t.text, Vector2.new(2.6, 1))
			p.Name = "ThresholdPlate"
			p:SetAttribute("PocketId", id)
			p:SetAttribute("Shifting", false)
			CollectionService:AddTag(p, "PocketThreshold")
		end
	end
	-- P06: the raised observation step on the south side of the Room of Three Doors, and its hint plate
	local room = assert(WorldDefs.chamber("R05.doorway_room"))
	local step = WorldDefs.Puzzles.P06.observationStep
	part(
		f,
		"ObservationStep",
		Vector3.new(8, 1, 6),
		CFrame.new(step.x, room.pos.y + 0.5, step.z),
		STONE_DARK,
		Enum.Material.Cobblestone
	)
	plaque(
		f,
		facingCF(Vector3.new(step.x, room.pos.y + 5, room.pos.z - room.size.z / 2 + 0.15), Vector3.new(0, 0, 1)),
		"POSTE D'OBSERVATION\nThe stable door bears the Crossing's mark "
			.. Pockets.STABLE_SYMBOL
			.. "\nand its lamp never flickers.",
		Vector2.new(6, 2.2)
	).Name =
		"ObservationPlate"
end

local function buildMilestone3Extras()
	-- R01 Collapsed Drift: the Borrowed Miner's dead end east of the East Workings
	local r01 = folder(WorldBuilder.folder("R01"), "Milestone3")
	rubbleHeap(r01, assert(WorldDefs.chamber("R01.collapsed_drift")), 1801, 1)
	-- R03 Vault Stair: a disused stair climbing into the west wall
	local r03 = folder(WorldBuilder.folder("R03"), "Milestone3")
	local vs = assert(WorldDefs.chamber("R03.vault_stair"))
	for i = 1, 6 do
		part(
			r03,
			"VaultStep" .. i,
			Vector3.new(6, i, 2),
			CFrame.new(vs.pos.x - vs.size.x / 2 + 3, vs.pos.y + i / 2, vs.pos.z - vs.size.z / 2 + 1 + i * 2),
			STONE,
			Enum.Material.Cobblestone
		)
	end
	-- R03 Overflow Vault: storage racks on the west and north walls
	local ov = assert(WorldDefs.chamber("R03.overflow_vault"))
	wallRack(
		r03,
		"VaultRack",
		Vector3.new(ov.pos.x - ov.size.x / 2, ov.pos.y, ov.pos.z - 4),
		12,
		Vector3.new(1, 0, 0),
		Color3.fromRGB(110, 96, 70),
		{ "CAISSE 7", "CAISSE 9", "CAISSE 12" }
	)
	wallRack(
		r03,
		"VaultRack",
		Vector3.new(ov.pos.x, ov.pos.y, ov.pos.z + ov.size.z / 2),
		8,
		Vector3.new(0, 0, -1),
		Color3.fromRGB(110, 96, 70),
		{ "CAISSE 14" }
	)
	-- R03 Drain Gallery: floor drain grates (dry route)
	local dg = assert(WorldDefs.chamber("R03.drain_gallery"))
	for _, dz in { -5, 5 } do
		deco(
			r03,
			"DrainGrate",
			Vector3.new(3, 0.1, 3),
			CFrame.new(dg.pos.x, dg.pos.y + 0.05, dg.pos.z + dz),
			Color3.fromRGB(60, 60, 62),
			Enum.Material.DiamondPlate
		)
	end
end

-- Variable pockets: the active version's geometry (PocketService decides when) -----------------------------

-- Discovery id and notebook label of a pocket's passage (one per pocket, shared by every version).
function WorldBuilder.pocketDiscoveryId(pocketId: string): string
	local pk = WorldDefs.Pockets[pocketId]
	return (if pk then pk.regionId else "R05") .. ".passage_" .. string.lower(pocketId)
end

function WorldBuilder.destroyPocket(pocketId: string)
	local f = pocketFolders[pocketId]
	if f then
		pocketFolders[pocketId] = nil
		f:Destroy()
	end
end

-- Builds one version of a pocket inside its bounds and returns its folder (attributes PocketId, PocketVersion).
-- The new version is assembled completely before the old one is removed, so an error can never leave the mouths
-- opening onto empty space. The caller (PocketService) guarantees the pocket is empty; nothing here checks players.
function WorldBuilder.buildPocket(pocketId: string, version: string): Folder
	local def = assert(WorldDefs.Pockets[pocketId], "unknown pocket " .. pocketId)
	local plan = Pockets.plan(def, version)
	local f = Instance.new("Folder")
	f.Name = "Pocket_" .. pocketId .. "_" .. version
	f:SetAttribute("PocketId", pocketId)
	f:SetAttribute("PocketVersion", version)
	local y = plan.floorY
	local function center(b: Pockets.Box, height: number): CFrame
		return CFrame.new((b.x0 + b.x1) / 2, height, (b.z0 + b.z1) / 2)
	end
	for _, b in plan.floors do
		local w, d = b.x1 - b.x0, b.z1 - b.z0
		part(f, "Floor", Vector3.new(w, 1, d), center(b, y - 0.5), STONE_DARK)
		part(f, "Ceiling", Vector3.new(w, 2, d), center(b, y + H + 1))
	end
	for _, b in plan.walls do
		part(f, "Wall", Vector3.new(b.x1 - b.x0, H, b.z1 - b.z0), center(b, y + H / 2))
	end
	local LOW = Pockets.LOW_CEILING
	for _, b in plan.lows do
		local w, d = b.x1 - b.x0, b.z1 - b.z0
		part(f, "LowCeiling", Vector3.new(w, H - LOW, d), center(b, y + LOW + (H - LOW) / 2), STONE_DARK)
		-- timber props under the low ceiling, across the narrow dimension
		local alongX = w > d
		local len = if alongX then w else d
		for t = 4, len - 4, 6 do
			local cf = if alongX
				then CFrame.new(b.x0 + t, y + LOW - 0.3, (b.z0 + b.z1) / 2)
				else CFrame.new((b.x0 + b.x1) / 2, y + LOW - 0.3, b.z0 + t)
			local size = if alongX then Vector3.new(0.8, 0.6, d) else Vector3.new(w, 0.6, 0.8)
			deco(f, "Prop", size, cf, WOOD, Enum.Material.Wood)
		end
	end
	-- numbered plate: the same number and "measured" length on every version
	local pl = plan.plate
	plaque(
		f,
		facingCF(Vector3.new(pl.pos.x, pl.pos.y, pl.pos.z), Vector3.new(pl.normal.x, pl.normal.y, pl.normal.z)),
		pl.text,
		Vector2.new(3.6, 1)
	).Name =
		"PassagePlate"
	-- one discovery per pocket, whatever the version (DiscoveryService picks up volumes added at runtime). One volume
	-- per walkable rectangle (clipped to the build area like the grid), never the whole area box: pocket bounds may
	-- overlap (PK1/PK2), and this pocket's volume must not cover another pocket's walkable floor.
	local a = plan.area.box
	for _, wb in plan.walk do
		local x0, x1 = math.max(wb.x0, a.x0), math.min(wb.x1, a.x1)
		local z0, z1 = math.max(wb.z0, a.z0), math.min(wb.z1, a.z1)
		if x1 > x0 and z1 > z0 then
			local vol = part(
				f,
				"DiscoveryVolume",
				Vector3.new(x1 - x0, H, z1 - z0),
				CFrame.new((x0 + x1) / 2, y + H / 2, (z0 + z1) / 2)
			)
			vol.Transparency = 1
			vol.CanCollide = false
			vol.CanQuery = false
			vol:SetAttribute("ChamberId", WorldBuilder.pocketDiscoveryId(pocketId))
			vol:SetAttribute("RegionId", def.regionId)
			vol:SetAttribute("DiscoveryLabel", Pockets.LABELS[pocketId] or pocketId)
			CollectionService:AddTag(vol, "DiscoveryVolume")
		end
	end
	-- P06: survey symbols above each door and a lamp; the client (PocketFX) flickers the false doors' lamps in one
	-- shared rhythm, the stable door's lamp stays steady
	if plan.doors then
		for _, d in plan.doors do
			local into = Vector3.new(0, 0, -1)
			local sym = plaque(f, facingCF(Vector3.new(d.x, y + 12.5, d.z - 0.15), into), d.symbol, Vector2.new(2, 1.6))
			sym.Name = "DoorSymbol"
			local lamp = part(
				f,
				"P06Lamp",
				Vector3.new(0.9, 0.9, 0.5),
				CFrame.new(d.x, y + 14.3, d.z - 0.35),
				Color3.fromRGB(255, 214, 150),
				Enum.Material.Neon
			)
			lamp.CanCollide = false
			lamp.CanQuery = false
			lamp:SetAttribute("Stable", d.stable)
			lamp:SetAttribute("PocketId", pocketId)
			local light = Instance.new("PointLight")
			light.Range = 10
			light.Brightness = 1.2
			light.Color = Color3.fromRGB(255, 214, 150)
			light.Parent = lamp
			CollectionService:AddTag(lamp, "P06Lamp")
		end
	end
	for _, d in f:GetDescendants() do
		if d:IsA("BasePart") then
			CollectionService:AddTag(d, "PocketGeometry")
		end
	end
	-- swap in one step: the old version goes and the whole new one appears in the same frame
	WorldBuilder.destroyPocket(pocketId)
	f.Parent = WorldBuilder.folder(def.regionId)
	pocketFolders[pocketId] = f
	return f
end

-- Telegraph look of a pocket's threshold plates: a steady amber glow while a change is pending (no flashing; the
-- client may add a flicker and dust that respect reduceFlashes).
function WorldBuilder.setThresholdShifting(pocketId: string, shifting: boolean)
	for _, inst in CollectionService:GetTagged("PocketThreshold") do
		if inst:IsA("BasePart") and inst:GetAttribute("PocketId") == pocketId then
			inst:SetAttribute("Shifting", shifting)
			inst.Material = if shifting then Enum.Material.Neon else Enum.Material.Marble
			inst.Color = if shifting then SHIFT_COLOR else PLAQUE_COLOR
		end
	end
end

function WorldBuilder.init()
	root = folder(workspace, "World")
	-- One folder per WorldDefs region (e.g. "R04_AbandonedSurveyStation"): a region added to the data can never
	-- parent its geometry to nil.
	for _, r in WorldDefs.Regions do
		regionFolders[r.id] = folder(root, r.id .. "_" .. (string.gsub(r.name, "[^%w]", "")))
	end
	folder(root, "ShelterInteriors")
end

function WorldBuilder.start()
	applyLighting()
	buildDepot()
	for _, c in WorldDefs.Chambers do
		buildChamber(c)
	end
	for _, cor in WorldDefs.Corridors do
		-- pocket corridors are built (and rebuilt) by PocketService through buildPocket
		if cor.pocket == nil then
			buildCorridor(assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to)))
		end
	end
	-- Ramp mouth into the survey-board chamber's south opening
	local sb = assert(WorldDefs.chamber("R01.survey_board"))
	local bot = v(WorldDefs.Depot.ramp.bottom)
	local gap = (sb.pos.z - sb.size.z / 2 - WALL) - bot.Z
	if gap > 0 then
		local f = folder(regionFolders.R01, "RampMouth")
		local cz = bot.Z + gap / 2
		part(f, "Floor", Vector3.new(W + 4, 1, gap + 2), CFrame.new(0, -0.5, cz), STONE_DARK)
		part(f, "Ceiling", Vector3.new(W + 4, 2, gap + 2), CFrame.new(0, H + 1, cz))
	end
	buildLandmarks()
	buildOssuary()
	buildWaterworks()
	buildSurveyStation()
	buildCrossroads()
	buildMilestone3Extras()
	buildHidingSpots()
	buildShelterExteriors()
end

function WorldBuilder.folder(regionId: string): Folder
	return regionFolders[regionId] or root
end

function WorldBuilder.root(): Folder
	return root
end

-- Region lookup by position. Interior cells live far from the playable map.
function WorldBuilder.regionAt(pos: Vector3): string
	local o = Config.Shelter.interiorCellOrigin
	if pos.X >= o.x - 50 and pos.Z >= o.z - 50 then
		return "SHELTER_INTERIOR"
	end
	if pos.Y > 40 then
		return "R00"
	end
	local c = WorldBuilder.nearestChamber(pos)
	return c.regionId
end

-- Nearest chamber; height differences weigh triple so stacked regions never confuse each other.
function WorldBuilder.nearestChamber(pos: Vector3): any
	local best, bestD = nil, math.huge
	for _, c in WorldDefs.Chambers do
		local d = Vector3.new(c.pos.x - pos.X, (c.pos.y + 3 - pos.Y) * 3, c.pos.z - pos.Z).Magnitude
		if d < bestD then
			best, bestD = c, d
		end
	end
	return assert(best, "no chambers defined")
end

-- Nearest chamber anchor for durable recovery records (never raw coordinates alone; section 15).
-- Returns (anchorId, offset, regionId).
function WorldBuilder.anchorFor(pos: Vector3): (string, Vector3, string)
	local c = WorldBuilder.nearestChamber(pos)
	return c.id, pos - v(c.pos), c.regionId
end

-- True when a world position's feet are inside shallow water (used for splash hearing).
function WorldBuilder.inWater(feet: Vector3): boolean
	for _, w in CollectionService:GetTagged("ShallowWater") do
		local rel = (w :: BasePart).CFrame:PointToObjectSpace(feet)
		local h = (w :: BasePart).Size / 2
		if math.abs(rel.X) <= h.X and math.abs(rel.Z) <= h.Z and rel.Y <= h.Y and rel.Y >= -h.Y - 0.6 then
			return true
		end
	end
	return false
end

-- Rebuilds a valid grounded position from an anchor. Falls back to the chamber centre when the offset is no
-- longer valid (never under the floor or inside removed geometry).
function WorldBuilder.resolveAnchor(anchorId: string, offset: Vector3): Vector3
	local c = WorldDefs.chamber(anchorId)
	if not c then
		local def = WorldDefs.chamber("R01.survey_board")
		return v((assert(def)).pos) + Vector3.new(0, 1, 0)
	end
	local candidate = v(c.pos) + offset
	-- Region geometry only: never land a bag on a pickup crate, a puzzle prop or a shelter interior.
	local include: { Instance } = {}
	for _, f in regionFolders do
		table.insert(include, f)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	local hit = workspace:Raycast(candidate + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), params)
	if hit and hit.Normal.Y > 0.7 then
		return hit.Position + Vector3.new(0, 0.6, 0)
	end
	return v(c.pos) + Vector3.new(0, 1, 0)
end

return WorldBuilder
