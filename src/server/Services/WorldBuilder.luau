--!strict
-- Builds the Milestone 1 BLOCKOUT for R00 Surface Survey Depot and R01 Old Quarry from primitive parts.
-- This is greybox geometry for testing scale, routes and systems, not production art (section 18 pipeline).
-- Every generated part is tagged BLOCKOUT so it can be replaced by modular kit pieces later.

local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Config = require(Shared.Data.Config)

local WorldBuilder = {}

local W = WorldDefs.CORRIDOR_WIDTH
local H = WorldDefs.CORRIDOR_HEIGHT
local WALL = 2

local root: Folder
local regionFolders: { [string]: Folder } = {}

local STONE = Color3.fromRGB(176, 166, 146)
local STONE_DARK = Color3.fromRGB(120, 112, 98)
local RUST = Color3.fromRGB(110, 62, 38)
local WOOD = Color3.fromRGB(92, 70, 48)

local function v(t: { x: number, y: number, z: number }): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3?, material: Enum.Material?): Part
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

local function deco(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3?, material: Enum.Material?): Part
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

-- Which sides of a chamber have a corridor opening: "N" (+z), "S" (-z), "E" (+x), "W" (-x)
local function openings(chamberId: string): { [string]: boolean }
	local out = {}
	local c = assert(WorldDefs.chamber(chamberId))
	for _, cor in WorldDefs.Corridors do
		local otherId = if cor.from == chamberId then cor.to elseif cor.to == chamberId then cor.from else nil
		if otherId then
			local o = assert(WorldDefs.chamber(otherId))
			if o.pos.x == c.pos.x then
				out[if o.pos.z > c.pos.z then "N" else "S"] = true
			else
				out[if o.pos.x > c.pos.x then "E" else "W"] = true
			end
		end
	end
	if chamberId == "R01.survey_board" then
		out.S = true -- descent ramp arrives from the south
	end
	return out
end

-- A wall along one side, split around a centered opening of width W when open.
local function sideWall(parent: Instance, center: Vector3, length: number, height: number, alongX: boolean, open: boolean)
	local y = center.Y + height / 2
	if not open then
		local size = if alongX then Vector3.new(length, height, WALL) else Vector3.new(WALL, height, length)
		part(parent, "Wall", size, CFrame.new(center.X, y, center.Z))
		return
	end
	local seg = (length - W) / 2
	for _, sgn in { -1, 1 } do
		local off = sgn * (W / 2 + seg / 2)
		local size = if alongX then Vector3.new(seg, height, WALL) else Vector3.new(WALL, height, seg)
		local pos = if alongX then Vector3.new(center.X + off, y, center.Z) else Vector3.new(center.X, y, center.Z + off)
		part(parent, "Wall", size, CFrame.new(pos))
	end
	if height > H then
		local lintelH = height - H
		local size = if alongX then Vector3.new(W, lintelH, WALL) else Vector3.new(WALL, lintelH, W)
		part(parent, "Lintel", size, CFrame.new(center.X, center.Y + H + lintelH / 2, center.Z))
	end
end

local function buildChamber(c: any)
	local f = folder(regionFolders[c.regionId], c.id)
	local p = v(c.pos)
	local s = v(c.size)
	local op = openings(c.id)
	part(f, "Floor", Vector3.new(s.X + WALL * 2, 1, s.Z + WALL * 2), CFrame.new(p.X, p.Y - 0.5, p.Z), STONE_DARK)
	part(f, "Ceiling", Vector3.new(s.X + WALL * 2, 2, s.Z + WALL * 2), CFrame.new(p.X, p.Y + s.Y + 1, p.Z))
	sideWall(f, Vector3.new(p.X, p.Y, p.Z + s.Z / 2 + WALL / 2), s.X + WALL * 2, s.Y, true, op.N == true)
	sideWall(f, Vector3.new(p.X, p.Y, p.Z - s.Z / 2 - WALL / 2), s.X + WALL * 2, s.Y, true, op.S == true)
	sideWall(f, Vector3.new(p.X + s.X / 2 + WALL / 2, p.Y, p.Z), s.Z, s.Y, false, op.E == true)
	sideWall(f, Vector3.new(p.X - s.X / 2 - WALL / 2, p.Y, p.Z), s.Z, s.Y, false, op.W == true)
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

local function buildCorridor(a: any, b: any)
	local f = folder(regionFolders[a.regionId], a.id .. "__" .. b.id)
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
		part(lm, "SplitPier", Vector3.new(4.4, pier.size.y, 8), CFrame.new(pier.pos.x + dx, pier.size.y / 2, pier.pos.z), STONE, Enum.Material.Cobblestone)
	end
	-- Sloped gallery: an inclined ceiling slab and fallen blocks
	local slope = assert(WorldDefs.chamber("R01.sloped_gallery"))
	part(lm, "SlopedSlab", Vector3.new(slope.size.x, 2, slope.size.z * 1.05),
		CFrame.new(slope.pos.x, slope.size.y - 5, slope.pos.z) * CFrame.Angles(math.rad(14), 0, 0), STONE)
	part(lm, "FallenBlock", Vector3.new(5, 3, 4), CFrame.new(slope.pos.x + 7, 1.5, slope.pos.z - 6) * CFrame.Angles(0, 0.4, 0.1), STONE)
	-- Rusted pulley: frame + wheel, with a rope hanging into a shaft mouth in the ceiling
	local pul = assert(WorldDefs.chamber("R01.rusted_pulley"))
	local px, pz = pul.pos.x + 6, pul.pos.z + 4
	part(lm, "PulleyPostA", Vector3.new(1, 14, 1), CFrame.new(px - 3, 7, pz), RUST, Enum.Material.CorrodedMetal)
	part(lm, "PulleyPostB", Vector3.new(1, 14, 1), CFrame.new(px + 3, 7, pz), RUST, Enum.Material.CorrodedMetal)
	part(lm, "PulleyBeam", Vector3.new(7, 1, 1), CFrame.new(px, 14, pz), RUST, Enum.Material.CorrodedMetal)
	local wheel = part(lm, "PulleyWheel", Vector3.new(0.6, 4, 4), CFrame.new(px, 12, pz), RUST, Enum.Material.CorrodedMetal)
	wheel.Shape = Enum.PartType.Cylinder
	deco(lm, "HangingRope", Vector3.new(0.3, 10, 0.3), CFrame.new(px + 1.6, 7, pz), WOOD, Enum.Material.Fabric)
	-- Survey board: numbered survey plaque (R01 orientation landmark)
	local sb = assert(WorldDefs.chamber("R01.survey_board"))
	local board = part(lm, "SurveyBoard", Vector3.new(8, 5, 0.6), CFrame.new(sb.pos.x, 5, sb.pos.z + sb.size.z / 2 - 0.4), WOOD, Enum.Material.WoodPlanks)
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
		part(rubbleFolder, "Rubble" .. i, Vector3.new(rng:NextNumber(1.5, 3.5), rng:NextNumber(0.6, 1.4), rng:NextNumber(1.5, 3.5)),
			CFrame.new(rub.pos.x + sx, 0.4, rub.pos.z + sz) * CFrame.Angles(0, rng:NextNumber(0, 3), 0), STONE_DARK, Enum.Material.Slate)
	end
	local noisy = part(lm, "NoisyFloorVolume", Vector3.new(rub.size.x, 6, rub.size.z + 40), CFrame.new(rub.pos.x, 3, rub.pos.z), STONE)
	noisy.Transparency = 1
	noisy.CanCollide = false
	noisy.CanQuery = false
	CollectionService:AddTag(noisy, "NoisyFloor")
end

local function buildDepot()
	local f = regionFolders.R00
	local d = WorldDefs.Depot
	local cy = d.courtyard.pos.y
	part(f, "Courtyard", Vector3.new(d.courtyard.size.x, 1, d.courtyard.size.z), CFrame.new(0, cy - 0.5, 0), Color3.fromRGB(96, 96, 100), Enum.Material.Cobblestone)
	-- perimeter walls (city noise lives above; Audio cues are listed in docs/AUDIO-CUES.md)
	part(f, "WallS", Vector3.new(70, 16, 2), CFrame.new(0, cy + 8, -31), Color3.fromRGB(150, 140, 125), Enum.Material.Brick)
	part(f, "WallE", Vector3.new(2, 16, 62), CFrame.new(36, cy + 8, 0), Color3.fromRGB(150, 140, 125), Enum.Material.Brick)
	part(f, "WallW", Vector3.new(2, 16, 62), CFrame.new(-36, cy + 8, 0), Color3.fromRGB(150, 140, 125), Enum.Material.Brick)
	part(f, "WallN_W", Vector3.new(29, 16, 2), CFrame.new(-21.5, cy + 8, 31), Color3.fromRGB(150, 140, 125), Enum.Material.Brick)
	part(f, "WallN_E", Vector3.new(29, 16, 2), CFrame.new(21.5, cy + 8, 31), Color3.fromRGB(150, 140, 125), Enum.Material.Brick)
	-- equipment room
	local er = d.equipmentRoom
	local erf = folder(f, "EquipmentRoom")
	part(erf, "Back", Vector3.new(er.size.x, er.size.y, 1), CFrame.new(er.pos.x, cy + er.size.y / 2, er.pos.z - er.size.z / 2), STONE)
	part(erf, "Side", Vector3.new(1, er.size.y, er.size.z), CFrame.new(er.pos.x - er.size.x / 2, cy + er.size.y / 2, er.pos.z), STONE)
	part(erf, "Roof", Vector3.new(er.size.x, 1, er.size.z), CFrame.new(er.pos.x, cy + er.size.y, er.pos.z), Color3.fromRGB(70, 70, 75), Enum.Material.Slate)
	part(erf, "Shelf", Vector3.new(8, 4, 2), CFrame.new(er.pos.x - 3, cy + 2, er.pos.z - er.size.z / 2 + 1.5), WOOD, Enum.Material.WoodPlanks)
	-- mission board
	local mb = part(f, "MissionBoard", Vector3.new(6, 4, 0.5), CFrame.new(v(d.missionBoard)), WOOD, Enum.Material.WoodPlanks)
	mb:SetAttribute("MissionBoard", true)
	CollectionService:AddTag(mb, "MissionBoard")
	-- descent house + ramp
	local top, bot = v(d.ramp.top), v(d.ramp.bottom)
	local hf = folder(f, "DescentHouse")
	part(hf, "HouseW", Vector3.new(2, 14, 24), CFrame.new(-W / 2 - 1, cy + 7, top.Z + 12), STONE_DARK, Enum.Material.Brick)
	part(hf, "HouseE", Vector3.new(2, 14, 24), CFrame.new(W / 2 + 1, cy + 7, top.Z + 12), STONE_DARK, Enum.Material.Brick)
	part(hf, "HouseRoof", Vector3.new(W + 4, 1, 24), CFrame.new(0, cy + 14, top.Z + 12), Color3.fromRGB(70, 70, 75), Enum.Material.Slate)
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

local function buildShelterExterior()
	local s = WorldDefs.Shelters[WorldDefs.StartShelterId]
	local c = assert(WorldDefs.chamber("R01.alcove_exterior"))
	local f = folder(regionFolders.R01, "ShelterExterior_" .. s.id)
	-- The alcove's repairable gate is on the far (east) wall of the exterior chamber.
	local gate = part(f, "AlcoveGate", Vector3.new(1, 9, 8), CFrame.new(c.pos.x + c.size.x / 2 - 0.5, 4.5, c.pos.z), RUST, Enum.Material.CorrodedMetal)
	gate:SetAttribute("ShelterId", s.id)
	CollectionService:AddTag(gate, "ShelterDoor")
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Enter shelter"
	prompt.ObjectText = s.name
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = gate
	local reg = part(f, "RegisterVolume", Vector3.new(c.size.x, 10, c.size.z), CFrame.new(c.pos.x, 5, c.pos.z))
	reg.Transparency = 1
	reg.CanCollide = false
	reg.CanQuery = false
	reg:SetAttribute("ShelterId", s.id)
	CollectionService:AddTag(reg, "ShelterApproach")
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

function WorldBuilder.init()
	root = folder(workspace, "World")
	regionFolders.R00 = folder(root, "R00_SurfaceSurveyDepot")
	regionFolders.R01 = folder(root, "R01_OldQuarry")
	folder(root, "ShelterInteriors")
end

function WorldBuilder.start()
	applyLighting()
	buildDepot()
	for _, c in WorldDefs.Chambers do
		buildChamber(c)
	end
	for _, cor in WorldDefs.Corridors do
		buildCorridor(assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to)))
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
	buildShelterExterior()
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
	return "R01"
end

-- Nearest chamber anchor for durable recovery records (never raw coordinates alone; section 15).
function WorldBuilder.anchorFor(pos: Vector3): (string, Vector3)
	local best, bestD = nil, math.huge
	for _, c in WorldDefs.Chambers do
		local d = (v(c.pos) - pos).Magnitude
		if d < bestD then
			best, bestD = c, d
		end
	end
	local c = assert(best)
	return c.id, pos - v(c.pos)
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
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { root }
	local hit = workspace:Raycast(candidate + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), params)
	if hit and hit.Normal.Y > 0.7 then
		return hit.Position + Vector3.new(0, 0.6, 0)
	end
	return v(c.pos) + Vector3.new(0, 1, 0)
end

return WorldBuilder
