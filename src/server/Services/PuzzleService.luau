--!strict
-- Puzzles (section 12). Shared, server-authoritative state per server: everyone sees the same gate and water
-- level (T07), and every puzzle is solvable solo with visual and audible feedback (T06).
-- P01 Inscription alignment (R02 Hall of Plaques): rotate the plaque to match the carving; opens the sealed chapel.
-- P02 Pump routing (R03 Old Pumps): set three valves per the clue plate; drains the cistern (optional treasure).

local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Puzzles = require(Shared.Logic.Puzzles)

local PuzzleService = {}
local services: any

local P01 = WorldDefs.Puzzles.P01
local P02 = WorldDefs.Puzzles.P02

local p01: Puzzles.P01State
local p02: Puzzles.P02State
local folder: Folder

local plaquePart: BasePart
local plaqueLabel: TextLabel
local gatePart: BasePart
local valveLabels: { TextLabel } = {}
local valveHandles: { BasePart } = {}
local gaugeFill: BasePart
local deepWater: BasePart
local corridorWater: BasePart
local barrier: BasePart
local cisternShallow: BasePart
local drainedAt = 0

local function v(t): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

local function mk(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Parent = folder
	return p
end

local function label(part: BasePart, text: string, color: Color3, font: Enum.Font?): TextLabel
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.LightInfluence = 0.8
	g.Parent = part
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = font or Enum.Font.Antique
	t.TextColor3 = color
	t.Text = text
	t.Parent = g
	return t
end

local function prompt(parent: Instance, action: string, object: string, hold: number?): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = hold or 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = parent
	return pp
end

local function cueNear(pos: Vector3, radius: number, id: string, extra: any?)
	for p in services.PlayerService.all() do
		local pp = services.PlayerService.position(p)
		if pp and (pp - pos).Magnitude <= radius then
			services.PlayerService.send(p, "cue", { id = id, position = pos, extra = extra })
		end
	end
end

-- P01 -------------------------------------------------------------------------------------------------
local INK = Color3.fromRGB(36, 34, 30)

local function buildP01()
	p01 = Puzzles.newP01(math.random(0, P01.orientations - 1), P01.orientations)
	local target = Puzzles.ARROWS[p01.target + 1]
	-- Carving on the south wall (faces north into the hall) and a worn duplicate on the north wall.
	local carving = mk("P01_Carving", Vector3.new(3, 3, 0.2), CFrame.new(v(P01.carving) + Vector3.new(0, 5, 0)) * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(160, 154, 140), Enum.Material.Marble)
	carving.CanCollide = false
	label(carving, "⌖\n" .. target, INK)
	local worn = mk("P01_WornCarving", Vector3.new(3, 3, 0.2), CFrame.new(v(P01.wornCarving) + Vector3.new(0, 5, 0)), Color3.fromRGB(150, 146, 134), Enum.Material.Marble)
	worn.CanCollide = false
	local wl = label(worn, "⌖\n" .. target, INK)
	wl.TextTransparency = 0.45 -- weathered but still legible: duplicate evidence (section 12)
	-- Pedestal + rotatable plaque.
	local base = v(P01.plaque)
	mk("P01_Pedestal", Vector3.new(2.4, 3.6, 2.4), CFrame.new(base + Vector3.new(0, 1.8, 0)), Color3.fromRGB(150, 144, 130), Enum.Material.Limestone)
	plaquePart = mk("P01_Plaque", Vector3.new(2.6, 2.6, 0.3), CFrame.new(base + Vector3.new(0, 4.9, 0)) * CFrame.Angles(math.rad(25), 0, 0), Color3.fromRGB(176, 150, 96), Enum.Material.Metal)
	plaqueLabel = label(plaquePart, "⌖\n" .. Puzzles.ARROWS[p01.orientation + 1], INK)
	-- Gate across the corridor to the sealed chapel.
	local g = v(P01.gate)
	gatePart = mk("P01_Gate", Vector3.new(1, WorldDefs.CORRIDOR_HEIGHT, WorldDefs.CORRIDOR_WIDTH), CFrame.new(g + Vector3.new(0, WorldDefs.CORRIDOR_HEIGHT / 2, 0)), Color3.fromRGB(96, 60, 40), Enum.Material.CorrodedMetal)
	local sign = mk("P01_GateSign", Vector3.new(5, 1.2, 0.2), CFrame.new(g + Vector3.new(-0.7, 6, 0)) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(150, 146, 136), Enum.Material.Marble)
	sign.CanCollide = false
	label(sign, "SCELLÉ — ALIGNER LE RELEVÉ", INK)
	local pp = prompt(plaquePart, "Turn plaque", "Survey plaque")
	pp.Triggered:Connect(function(player)
		if p01.solved then
			services.PlayerService.notify(player, "The plaque is locked in place. The chapel is open.", "info")
			return
		end
		local solved = Puzzles.rotateP01(p01)
		plaqueLabel.Text = "⌖\n" .. Puzzles.ARROWS[p01.orientation + 1]
		cueNear(plaquePart.Position, 40, "plaque_turn", { solved = solved })
		if solved then
			TweenService:Create(gatePart, TweenInfo.new(2.5, Enum.EasingStyle.Quad), { CFrame = gatePart.CFrame + Vector3.new(0, WorldDefs.CORRIDOR_HEIGHT - 0.5, 0) }):Play()
			task.delay(2.5, function()
				gatePart.CanCollide = false
			end)
			cueNear(gatePart.Position, 80, "gate_open")
			services.DiscoveryService.discover(player, "P01.solved", "Inscription aligned — the chapel gate opens")
		end
	end)
end

-- P02 -------------------------------------------------------------------------------------------------
local NUMERALS = { "I", "II", "III" }
local CISTERN = assert(WorldDefs.chamber("R03.cistern"))

local function refreshValves()
	for i, lbl in valveLabels do
		lbl.Text = NUMERALS[i] .. "\n" .. (if p02.valves[i] then "OUVERT" else "FERMÉ")
		-- the handle stands upright when shut and lies horizontal when open
		valveHandles[i].Orientation = Vector3.new(if p02.valves[i] then 90 else 0, 0, 0)
	end
	local n = Puzzles.correctCount(p02)
	gaugeFill.Size = Vector3.new(0.3, math.max(0.2, 6 * (1 - n / 3)), 0.8)
	gaugeFill.CFrame = CFrame.new(v(P02.gauge) + Vector3.new(-0.2, -3 + gaugeFill.Size.Y / 2, 0)) -- room side of the panel
end

local function setDrained(drained: boolean)
	local floorY = CISTERN.pos.y
	local deepH = if drained then 0.01 else 7
	TweenService:Create(deepWater, TweenInfo.new(if drained then 6 else 8), {
		Size = Vector3.new(deepWater.Size.X, deepH, deepWater.Size.Z),
		CFrame = CFrame.new(CISTERN.pos.x, floorY + deepH / 2, CISTERN.pos.z),
	}):Play()
	TweenService:Create(corridorWater, TweenInfo.new(if drained then 6 else 8), {
		Transparency = if drained then 1 else 0.3,
	}):Play()
	barrier.CanCollide = not drained
	cisternShallow.Transparency = if drained then 0.35 else 1
	if drained then
		CollectionService:AddTag(cisternShallow, "ShallowWater")
	else
		CollectionService:RemoveTag(cisternShallow, "ShallowWater")
	end
end

local function buildP02()
	p02 = Puzzles.newP02(math.random(1, #Puzzles.P02_SOLUTIONS))
	local wall = Color3.fromRGB(110, 62, 38)
	for i, pos in P02.valves do
		local wheel = mk("P02_Valve" .. i, Vector3.new(0.4, 2.6, 2.6), CFrame.new(v(pos)), wall, Enum.Material.CorrodedMetal)
		wheel.Shape = Enum.PartType.Cylinder -- axis along X: the wheel faces into the gallery
		local handle = mk("P02_Handle" .. i, Vector3.new(0.3, 2.4, 0.3), CFrame.new(v(pos) + Vector3.new(-0.4, 0, 0)), Color3.fromRGB(180, 150, 70), Enum.Material.Metal)
		handle.CanCollide = false
		valveHandles[i] = handle
		local tag = mk("P02_ValveTag" .. i, Vector3.new(2.2, 1.4, 0.2), CFrame.new(v(pos) + Vector3.new(-0.2, 2.4, 0)) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(150, 146, 136), Enum.Material.Metal)
		tag.CanCollide = false
		valveLabels[i] = label(tag, "", Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
		local pp = prompt(wheel, "Turn valve " .. NUMERALS[i], "Pump valve", 0.6)
		pp.Triggered:Connect(function(player)
			local n, drainedNow = Puzzles.toggleValve(p02, i)
			refreshValves()
			cueNear(wheel.Position, 50, "valve_turn", { correct = n, of = 3 })
			if drainedNow then
				drainedAt = os.clock()
				setDrained(true)
				for p in services.PlayerService.all() do
					local s = services.PlayerService.get(p)
					if s and s.regionId == "R03" then
						services.PlayerService.send(p, "cue", { id = "water_drain", position = v(CISTERN.pos) })
					end
				end
				services.DiscoveryService.discover(player, "P02.solved", "Pumps routed — the cistern drains")
			end
		end)
	end
	local clue = mk("P02_Clue", Vector3.new(4.5, 2.4, 0.2), CFrame.new(v(P02.clue)) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(150, 146, 136), Enum.Material.Metal)
	clue.CanCollide = false
	label(clue, Puzzles.p02Clue(p02.solution), Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
	-- Gauge: a column of water that falls as more valves are set correctly (visible feedback).
	local gaugeBack = mk("P02_Gauge", Vector3.new(0.2, 6.4, 1.2), CFrame.new(v(P02.gauge)), Color3.fromRGB(200, 196, 180), Enum.Material.SmoothPlastic)
	gaugeBack.CanCollide = false
	local gl = label(gaugeBack, "NIVEAU", Color3.fromRGB(30, 28, 24))
	gl.TextTransparency = 0.5
	;(gl.Parent :: SurfaceGui).Face = Enum.NormalId.Left -- the panel's broad face looks west into the gallery
	gaugeFill = mk("P02_GaugeFill", Vector3.new(0.3, 6, 0.8), CFrame.new(v(P02.gauge)), Color3.fromRGB(50, 90, 110), Enum.Material.Neon)
	gaugeFill.CanCollide = false
	local lever = mk("P02_Reset", Vector3.new(0.6, 2, 0.6), CFrame.new(v(P02.reset)), Color3.fromRGB(150, 40, 30), Enum.Material.Metal)
	prompt(lever, "Reset valves", "Pump controls").Triggered:Connect(function()
		if p02.drained then
			return -- the drained state holds until the cistern refloods on its own
		end
		Puzzles.resetP02(p02)
		refreshValves()
		cueNear(lever.Position, 50, "valve_reset")
	end)
	-- Cistern water: deep until drained. Shallow water appears once drained so the Wader can still hear there.
	deepWater = mk("P02_CisternDeep", Vector3.new(CISTERN.size.x, 7, CISTERN.size.z), CFrame.new(CISTERN.pos.x, CISTERN.pos.y + 3.5, CISTERN.pos.z), Color3.fromRGB(30, 50, 52), Enum.Material.Glass)
	deepWater.Transparency = 0.25
	deepWater.CanCollide = false
	deepWater.CanQuery = false
	cisternShallow = mk("P02_CisternShallow", Vector3.new(CISTERN.size.x, 1.2, CISTERN.size.z), CFrame.new(CISTERN.pos.x, CISTERN.pos.y + 0.6, CISTERN.pos.z), Color3.fromRGB(38, 58, 56), Enum.Material.Glass)
	cisternShallow.CanCollide = false
	cisternShallow.CanQuery = false
	cisternShallow.Transparency = 1
	local b = v(P02.barrier)
	local x1 = CISTERN.pos.x - CISTERN.size.x / 2
	corridorWater = mk("P02_CorridorDeep", Vector3.new(x1 - b.X, 7, WorldDefs.CORRIDOR_WIDTH), CFrame.new((b.X + x1) / 2, b.Y + 3.5, b.Z), Color3.fromRGB(30, 50, 52), Enum.Material.Glass)
	corridorWater.Transparency = 0.3
	corridorWater.CanCollide = false
	corridorWater.CanQuery = false
	barrier = mk("P02_Barrier", Vector3.new(1, WorldDefs.CORRIDOR_HEIGHT, WorldDefs.CORRIDOR_WIDTH), CFrame.new(b + Vector3.new(-1, WorldDefs.CORRIDOR_HEIGHT / 2, 0)), Color3.new(), Enum.Material.SmoothPlastic)
	barrier.Transparency = 1
	barrier.CanQuery = false
	local warnSign = mk("P02_Sign", Vector3.new(6, 1.4, 0.2), CFrame.new(b + Vector3.new(-1.6, 4.5, 0)) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(150, 146, 136), Enum.Material.Metal)
	warnSign.CanCollide = false
	label(warnSign, "TROP PROFOND — VOIR LES POMPES", Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
	refreshValves()
	setDrained(false)
end

-- The cistern refloods only when nobody is inside it or its corridor (never replaces state under a player).
local function cisternOccupied(): boolean
	for p in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and pos.X > (P02.barrier.x - 4) and pos.X < CISTERN.pos.x + CISTERN.size.x / 2 + 2
			and math.abs(pos.Z - CISTERN.pos.z) < CISTERN.size.z / 2 + 2 and pos.Y < CISTERN.pos.y + 14 and pos.Y > CISTERN.pos.y - 4 then
			return true
		end
	end
	return false
end

-- Gate state for mission reachability: puzzle gates count as open only once solved.
function PuzzleService.openGates(): { [string]: boolean }
	return { P01 = p01 ~= nil and p01.solved, P02 = p02 ~= nil and p02.drained }
end

function PuzzleService.init(s)
	services = s
end

function PuzzleService.start()
	folder = Instance.new("Folder")
	folder.Name = "Puzzles"
	folder.Parent = services.WorldBuilder.root()
	buildP01()
	buildP02()
	task.spawn(function()
		while true do
			task.wait(5)
			if p02.drained and os.clock() - drainedAt > P02.refloodSeconds and not cisternOccupied() then
				Puzzles.resetP02(p02)
				refreshValves()
				setDrained(false)
				for p in services.PlayerService.all() do
					local s = services.PlayerService.get(p)
					if s and s.regionId == "R03" then
						services.PlayerService.send(p, "cue", { id = "water_rising", position = v(CISTERN.pos) })
					end
				end
			end
		end
	end)
end

return PuzzleService
