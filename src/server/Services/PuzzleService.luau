--!strict
-- Puzzles (section 12). Shared, server-authoritative state per server: everyone sees the same gates, water, grate
-- and station power (T07), and every puzzle is solvable solo with visual and audible feedback (T06).
-- P01 Inscription alignment (R02 Hall of Plaques): rotate the plaque to match the carving; opens the sealed chapel.
-- P02 Pump routing (R03 Old Pumps): set three valves per the clue plate; drains the cistern (optional treasure).
-- P03 Fuse bridge (R04 Generator Room): trace the dead line to its junction box and fit a fuse. Station power lasts
--     Config.Puzzles.stationPowerSeconds, then trips only when the generator room is empty (a new layout follows).
-- P04 Weight and pulley (R01 Rusted Pulley): load the counterweight, then latch it or hold the lever. The grate to the
--     Pulley Store never closes on or behind anyone, and the inner lever always raises it.
-- P05 Echo sequence (R04 Radio Room): repeat the radio's short/long pattern in PuzzleUI. With station power on, the
--     set plays Elise Renaud's interrupted log and records the station tape (Act II step 5).
-- W05 Sluice gates (R03 Silt Works, for M05): turn three wheels in the clue order; every turn is loud. Drains the
--     corridor to the Overflow Vault; it refloods later only when nobody is in that corridor or the vault.
-- Every timed revert (P02 reflood, P03 trip, P04 drop, W05 reflood) waits until its area holds no player (a player
-- without a character counts at their last grounded spot), no online owner's bag and nothing tagged PocketBlocker
-- (rescue survivors, carried NPCs).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Progress = require(Shared.Logic.Progress)
local Puzzles = require(Shared.Logic.Puzzles)

local PuzzleService = {}
local services: any

local P01 = WorldDefs.Puzzles.P01
local P02 = WorldDefs.Puzzles.P02
local P03 = WorldDefs.Puzzles.P03
local P04 = WorldDefs.Puzzles.P04
local P05 = WorldDefs.Puzzles.P05
local W05 = WorldDefs.Puzzles.W05

local CFG = Config.Puzzles :: any
-- TUNE / PROPOSED. Read from Config.Puzzles when the lead adds them; these are the local fallbacks.
local P04_SLIP_SECONDS: number = CFG.pulleySlipSeconds or 15 -- a full basket alone holds the grate this long
local LEVER_HOLD_SECONDS: number = CFG.pulleyLeverSeconds or 30 -- one lever hold keeps the grate up this long
local SLUICE_LOUDNESS: number = CFG.sluiceLoudness or 3 -- x the Wader's hearing radius (a walking splash is 0.6)
local RADIO_RANGE = 12
local RADIO_ATTEMPT_COOLDOWN = 0.75
local BLOCKER_TAG = "PocketBlocker"
local TAPE_ID = "evidence.station_tape"
local TAPE_CLAIM = "R04.unique.station_tape"
local RADIO_HEARD = "act2.radio_heard"

local folder: Folder
local built: { [string]: boolean } = {}

local p01: Puzzles.P01State
local p02: Puzzles.P02State
local p03: Puzzles.P03State
local p04: Puzzles.P04State
local p05Pattern: string
local w05: Puzzles.W05State

local INK = Color3.fromRGB(36, 34, 30)
local PAPER = Color3.fromRGB(214, 206, 180)
local STEEL = Color3.fromRGB(92, 98, 96)
local RUST = Color3.fromRGB(110, 62, 38)
local WOOD = Color3.fromRGB(92, 70, 48)
local LAMP_OFF = Color3.fromRGB(60, 58, 52)
local LAMP_ON = Color3.fromRGB(255, 222, 170)
local RED = Color3.fromRGB(150, 40, 30)
local GREEN = Color3.fromRGB(70, 170, 90)
local AMBER = Color3.fromRGB(230, 160, 60)

-- Helpers --------------------------------------------------------------------------------------------
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

-- Non-colliding, non-queryable dressing (signs, conduits, lamps).
local function deco(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local p = mk(name, size, cf, color, material)
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
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

-- A flat sign whose Front face looks along `facing` (labels render on the Front face).
local function sign(name: string, size: Vector3, pos: Vector3, facing: Vector3, text: string): (Part, TextLabel)
	local p = deco(name, size, CFrame.lookAt(pos, pos + facing), PAPER, Enum.Material.SmoothPlastic)
	return p, label(p, text, INK, Enum.Font.SpecialElite)
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

local function cueRegion(regionId: string, id: string, pos: Vector3, extra: any?)
	for p, s in services.PlayerService.all() do
		if s.regionId == regionId then
			services.PlayerService.send(p, "cue", { id = id, position = pos, extra = extra })
		end
	end
end

local function notify(player: Player, text: string, kind: string?)
	services.PlayerService.notify(player, text, kind or "info")
end

-- Optional cross-package calls (docs/MILESTONE-3.md section 5): isolated so a missing or failing API in another
-- package never aborts a puzzle outcome that already happened.
local function safeCall(serviceName: string, fnName: string, ...: any)
	local svc = services[serviceName]
	local fn = svc and svc[fnName]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn(string.format("[PuzzleService] %s.%s failed: %s", serviceName, fnName, tostring(err)))
	end
end

-- The acting player is present, up, not carried, and within reach of the thing they work on (server-side checks on
-- top of the prompt's own distance).
local function canAct(player: Player, at: Vector3, range: number): any
	local s = services.PlayerService.get(player)
	if not s or not s.alive or s.vitals.condition == "downed" or s.vitals.condition == "dead" or s.carriedBy then
		return nil
	end
	local pos = services.PlayerService.position(player)
	if not pos or (pos - at).Magnitude > range then
		return nil
	end
	return s
end

local function classRepairMultiplier(s: any): number
	local cls: any = Config.Classes[s.profile.class]
	return (cls and cls.repairTimeMultiplier) or 1
end

-- Occupancy (never change state under a player) -------------------------------------------------------
local function bagPosition(bag: any): Vector3?
	local a = if type(bag) == "table" then bag.anchor else nil
	if type(a) ~= "table" or type(a.anchorId) ~= "string" or type(a.offset) ~= "table" then
		return nil
	end
	local c = WorldDefs.chamber(a.anchorId)
	local o = a.offset
	if not c or type(o.x) ~= "number" or type(o.y) ~= "number" or type(o.z) ~= "number" then
		return nil
	end
	return Vector3.new(c.pos.x + o.x, c.pos.y + o.y, c.pos.z + o.z)
end

local function blockerPosition(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

-- `playersOnly` is for reverts that cannot shut anything in (the P03 lights): bags and tagged blockers do not count.
local function occupied(boxes: { Puzzles.Box }, playersOnly: boolean?): boolean
	local function hit(p: Vector3?): boolean
		return p ~= nil and Puzzles.inAnyBox(boxes, p.X, p.Y, p.Z)
	end
	for player, s in services.PlayerService.all() do
		if hit(services.PlayerService.position(player) or s.lastGrounded) then
			return true
		end
		if playersOnly then
			continue
		end
		local bags = s.profile.bags
		if type(bags) == "table" and (hit(bagPosition(bags.death)) or hit(bagPosition(bags.logout))) then
			return true
		end
	end
	if playersOnly then
		return false
	end
	for _, inst in CollectionService:GetTagged(BLOCKER_TAG) do
		if inst:IsDescendantOf(workspace) and hit(blockerPosition(inst)) then
			return true
		end
	end
	return false
end

-- The two chambers joined by the corridor that carries a gate id.
local function gatedCorridor(gateId: string): (WorldDefs.Chamber, WorldDefs.Chamber)
	for _, cor in WorldDefs.Corridors do
		if cor.gate == gateId then
			return assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to))
		end
	end
	error("no corridor carries gate " .. gateId)
end

-- Span of a straight corridor between the two chambers' interior faces: (centre, length, alongX).
local function corridorSpan(a: WorldDefs.Chamber, b: WorldDefs.Chamber): (Vector3, number, boolean)
	if a.pos.x == b.pos.x then
		local lo, hi = a, b
		if a.pos.z > b.pos.z then
			lo, hi = b, a
		end
		local z0, z1 = lo.pos.z + lo.size.z / 2, hi.pos.z - hi.size.z / 2
		return Vector3.new(a.pos.x, a.pos.y, (z0 + z1) / 2), z1 - z0, false
	end
	local lo, hi = a, b
	if a.pos.x > b.pos.x then
		lo, hi = b, a
	end
	local x0, x1 = lo.pos.x + lo.size.x / 2, hi.pos.x - hi.size.x / 2
	return Vector3.new((x0 + x1) / 2, a.pos.y, a.pos.z), x1 - x0, true
end

-- P01 -------------------------------------------------------------------------------------------------
local plaquePart: BasePart
local plaqueLabel: TextLabel
local gatePart: BasePart

local function buildP01()
	local state = Puzzles.newP01(math.random(0, P01.orientations - 1), P01.orientations)
	p01 = state
	local target = Puzzles.p01Label(state.target, state.orientations)
	-- Carving on the south wall (faces north into the hall) and a worn duplicate on the north wall.
	local carving = mk(
		"P01_Carving",
		Vector3.new(3, 3, 0.2),
		CFrame.new(v(P01.carving) + Vector3.new(0, 5, 0)) * CFrame.Angles(0, math.pi, 0),
		Color3.fromRGB(160, 154, 140),
		Enum.Material.Marble
	)
	carving.CanCollide = false
	label(carving, "⌖\n" .. target, INK)
	local worn = mk(
		"P01_WornCarving",
		Vector3.new(3, 3, 0.2),
		CFrame.new(v(P01.wornCarving) + Vector3.new(0, 5, 0)),
		Color3.fromRGB(150, 146, 134),
		Enum.Material.Marble
	)
	worn.CanCollide = false
	local wl = label(worn, "⌖\n" .. target, INK)
	wl.TextTransparency = 0.45 -- weathered but still legible: duplicate evidence (section 12)
	-- Pedestal + rotatable plaque.
	local base = v(P01.plaque)
	mk(
		"P01_Pedestal",
		Vector3.new(2.4, 3.6, 2.4),
		CFrame.new(base + Vector3.new(0, 1.8, 0)),
		Color3.fromRGB(150, 144, 130),
		Enum.Material.Limestone
	)
	plaquePart = mk(
		"P01_Plaque",
		Vector3.new(2.6, 2.6, 0.3),
		CFrame.new(base + Vector3.new(0, 4.9, 0)) * CFrame.Angles(math.rad(25), 0, 0),
		Color3.fromRGB(176, 150, 96),
		Enum.Material.Metal
	)
	plaqueLabel = label(plaquePart, "⌖\n" .. Puzzles.p01Label(state.orientation, state.orientations), INK)
	-- Gate across the corridor to the sealed chapel.
	local g = v(P01.gate)
	gatePart = mk(
		"P01_Gate",
		Vector3.new(1, WorldDefs.CORRIDOR_HEIGHT, WorldDefs.CORRIDOR_WIDTH),
		CFrame.new(g + Vector3.new(0, WorldDefs.CORRIDOR_HEIGHT / 2, 0)),
		Color3.fromRGB(96, 60, 40),
		Enum.Material.CorrodedMetal
	)
	local gateSign = mk(
		"P01_GateSign",
		Vector3.new(5, 1.2, 0.2),
		CFrame.new(g + Vector3.new(-0.7, 6, 0)) * CFrame.Angles(0, math.pi / 2, 0),
		Color3.fromRGB(150, 146, 136),
		Enum.Material.Marble
	)
	gateSign.CanCollide = false
	label(gateSign, "SCELLÉ — ALIGNER LE RELEVÉ", INK)
	local pp = prompt(plaquePart, "Turn plaque", "Survey plaque")
	pp.Triggered:Connect(function(player)
		if state.solved then
			notify(player, "The plaque is locked in place. The chapel is open.")
			return
		end
		local solved = Puzzles.rotateP01(state)
		plaqueLabel.Text = "⌖\n" .. Puzzles.p01Label(state.orientation, state.orientations)
		cueNear(plaquePart.Position, 40, "plaque_turn", { solved = solved })
		if solved then
			TweenService:Create(
				gatePart,
				TweenInfo.new(2.5, Enum.EasingStyle.Quad),
				{ CFrame = gatePart.CFrame + Vector3.new(0, WorldDefs.CORRIDOR_HEIGHT - 0.5, 0) }
			):Play()
			task.delay(2.5, function()
				gatePart.CanCollide = false
			end)
			cueNear(gatePart.Position, 80, "gate_open")
			services.DiscoveryService.discover(player, "P01.solved", "Inscription aligned — the chapel gate opens")
		end
	end)
end

-- P02 -------------------------------------------------------------------------------------------------
local valveLabels: { TextLabel } = {}
local valveHandles: { BasePart } = {}
local gaugeFill: BasePart
local deepWater: BasePart
local corridorWater: BasePart
local barrier: BasePart
local cisternShallow: BasePart
local drainedAt = 0
local cistern: WorldDefs.Chamber
local p02Boxes: { Puzzles.Box } = {}

local function refreshValves()
	for i, lbl in valveLabels do
		lbl.Text = Puzzles.roman(i) .. "\n" .. (if p02.valves[i] then "OUVERT" else "FERMÉ")
		-- the handle stands upright when shut and lies horizontal when open
		valveHandles[i].Orientation = Vector3.new(if p02.valves[i] then 90 else 0, 0, 0)
	end
	local n = Puzzles.correctCount(p02)
	gaugeFill.Size = Vector3.new(0.3, math.max(0.2, 6 * (1 - n / #p02.valves)), 0.8)
	gaugeFill.CFrame = CFrame.new(v(P02.gauge) + Vector3.new(-0.2, -3 + gaugeFill.Size.Y / 2, 0)) -- room side
end

local function setDrained(drained: boolean)
	local floorY = cistern.pos.y
	local deepH = if drained then 0.01 else 7
	TweenService:Create(deepWater, TweenInfo.new(if drained then 6 else 8), {
		Size = Vector3.new(deepWater.Size.X, deepH, deepWater.Size.Z),
		CFrame = CFrame.new(cistern.pos.x, floorY + deepH / 2, cistern.pos.z),
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
	cistern = assert(WorldDefs.chamber("R03.cistern"), "R03.cistern missing")
	local state = Puzzles.newP02(math.random(1, #Puzzles.P02_SOLUTIONS))
	assert(#state.valves == #P02.valves, "P02 valve count does not match its authored solutions")
	p02 = state
	local wall = Color3.fromRGB(110, 62, 38)
	for i, pos in P02.valves do
		local wheel =
			mk("P02_Valve" .. i, Vector3.new(0.4, 2.6, 2.6), CFrame.new(v(pos)), wall, Enum.Material.CorrodedMetal)
		wheel.Shape = Enum.PartType.Cylinder -- axis along X: the wheel faces into the gallery
		local handle = mk(
			"P02_Handle" .. i,
			Vector3.new(0.3, 2.4, 0.3),
			CFrame.new(v(pos) + Vector3.new(-0.4, 0, 0)),
			Color3.fromRGB(180, 150, 70),
			Enum.Material.Metal
		)
		handle.CanCollide = false
		valveHandles[i] = handle
		local tag = mk(
			"P02_ValveTag" .. i,
			Vector3.new(2.2, 1.4, 0.2),
			CFrame.new(v(pos) + Vector3.new(-0.2, 2.4, 0)) * CFrame.Angles(0, math.pi / 2, 0),
			Color3.fromRGB(150, 146, 136),
			Enum.Material.Metal
		)
		tag.CanCollide = false
		valveLabels[i] = label(tag, "", Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
		local pp = prompt(wheel, "Turn valve " .. Puzzles.roman(i), "Pump valve", 0.6)
		pp.Triggered:Connect(function(player)
			if state.drained then
				-- locked while drained: no misleading "n of 3" caption
				notify(player, "The valves are locked while the cistern is drained. It refloods on its own later.")
				return
			end
			local n, drainedNow = Puzzles.toggleValve(state, i)
			refreshValves()
			cueNear(wheel.Position, 50, "valve_turn", { correct = n, of = #state.valves })
			if drainedNow then
				drainedAt = os.clock()
				setDrained(true)
				cueRegion("R03", "water_drain", v(cistern.pos))
				services.DiscoveryService.discover(player, "P02.solved", "Pumps routed — the cistern drains")
			end
		end)
	end
	local clue = mk(
		"P02_Clue",
		Vector3.new(4.5, 2.4, 0.2),
		CFrame.new(v(P02.clue)) * CFrame.Angles(0, math.pi / 2, 0),
		Color3.fromRGB(150, 146, 136),
		Enum.Material.Metal
	)
	clue.CanCollide = false
	label(clue, Puzzles.p02Clue(state.solution), Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
	-- Gauge: a column of water that falls as more valves are set correctly (visible feedback).
	local gaugeBack = mk(
		"P02_Gauge",
		Vector3.new(0.2, 6.4, 1.2),
		CFrame.new(v(P02.gauge)),
		Color3.fromRGB(200, 196, 180),
		Enum.Material.SmoothPlastic
	)
	gaugeBack.CanCollide = false
	local gl = label(gaugeBack, "NIVEAU", Color3.fromRGB(30, 28, 24))
	gl.TextTransparency = 0.5
	(gl.Parent :: SurfaceGui).Face = Enum.NormalId.Left -- the panel's broad face looks west into the gallery
	gaugeFill = mk(
		"P02_GaugeFill",
		Vector3.new(0.3, 6, 0.8),
		CFrame.new(v(P02.gauge)),
		Color3.fromRGB(50, 90, 110),
		Enum.Material.Neon
	)
	gaugeFill.CanCollide = false
	local lever = mk(
		"P02_Reset",
		Vector3.new(0.6, 2, 0.6),
		CFrame.new(v(P02.reset)),
		Color3.fromRGB(150, 40, 30),
		Enum.Material.Metal
	)
	prompt(lever, "Reset valves", "Pump controls").Triggered:Connect(function()
		if state.drained then
			return -- the drained state holds until the cistern refloods on its own
		end
		Puzzles.resetP02(state)
		refreshValves()
		cueNear(lever.Position, 50, "valve_reset")
	end)
	-- Cistern water: deep until drained. Shallow water appears once drained so the Wader can still hear there.
	deepWater = mk(
		"P02_CisternDeep",
		Vector3.new(cistern.size.x, 7, cistern.size.z),
		CFrame.new(cistern.pos.x, cistern.pos.y + 3.5, cistern.pos.z),
		Color3.fromRGB(30, 50, 52),
		Enum.Material.Glass
	)
	deepWater.Transparency = 0.25
	deepWater.CanCollide = false
	deepWater.CanQuery = false
	cisternShallow = mk(
		"P02_CisternShallow",
		Vector3.new(cistern.size.x, 1.2, cistern.size.z),
		CFrame.new(cistern.pos.x, cistern.pos.y + 0.6, cistern.pos.z),
		Color3.fromRGB(38, 58, 56),
		Enum.Material.Glass
	)
	cisternShallow.CanCollide = false
	cisternShallow.CanQuery = false
	cisternShallow.Transparency = 1
	local b = v(P02.barrier)
	local x1 = cistern.pos.x - cistern.size.x / 2
	corridorWater = mk(
		"P02_CorridorDeep",
		Vector3.new(x1 - b.X, 7, WorldDefs.CORRIDOR_WIDTH),
		CFrame.new((b.X + x1) / 2, b.Y + 3.5, b.Z),
		Color3.fromRGB(30, 50, 52),
		Enum.Material.Glass
	)
	corridorWater.Transparency = 0.3
	corridorWater.CanCollide = false
	corridorWater.CanQuery = false
	barrier = mk(
		"P02_Barrier",
		Vector3.new(1, WorldDefs.CORRIDOR_HEIGHT, WorldDefs.CORRIDOR_WIDTH),
		CFrame.new(b + Vector3.new(-1, WorldDefs.CORRIDOR_HEIGHT / 2, 0)),
		Color3.new(),
		Enum.Material.SmoothPlastic
	)
	barrier.Transparency = 1
	barrier.CanQuery = false
	local warnSign = mk(
		"P02_Sign",
		Vector3.new(6, 1.4, 0.2),
		CFrame.new(b + Vector3.new(-1.6, 4.5, 0)) * CFrame.Angles(0, math.pi / 2, 0),
		Color3.fromRGB(150, 146, 136),
		Enum.Material.Metal
	)
	warnSign.CanCollide = false
	label(warnSign, "TROP PROFOND — VOIR LES POMPES", Color3.fromRGB(30, 28, 24), Enum.Font.SpecialElite)
	-- The cistern refloods only when nobody is inside it or the deep part of its corridor (same box as Milestone 2).
	p02Boxes = {
		{
			min = { x = b.X - 4, y = cistern.pos.y - 4, z = cistern.pos.z - cistern.size.z / 2 - 2 },
			max = {
				x = cistern.pos.x + cistern.size.x / 2 + 2,
				y = cistern.pos.y + 14,
				z = cistern.pos.z + cistern.size.z / 2 + 2,
			},
		},
	}
	refreshValves()
	setDrained(false)
end

local function tickP02(now: number)
	if p02.drained and now - drainedAt > P02.refloodSeconds and not occupied(p02Boxes) then
		Puzzles.resetP02(p02)
		refreshValves()
		setDrained(false)
		cueRegion("R03", "water_rising", v(cistern.pos))
	end
end

-- P03 Fuse bridge -------------------------------------------------------------------------------------
local p03BoxParts: { [string]: BasePart } = {}
local p03BoxLabels: { [string]: TextLabel } = {}
local p03TerminalLabels: { TextLabel } = {}
local p03PlateLabel: TextLabel
local p03Status: BasePart
local p03Conduits: Folder
local p03Boxes: { Puzzles.Box } = {}
local generatorPos: Vector3
local stationLamps: { BasePart } = {}
local radioDialLabel: TextLabel? = nil

local CONDUIT_COLORS = { Color3.fromRGB(120, 60, 50), Color3.fromRGB(70, 90, 110), Color3.fromRGB(110, 100, 60) }

-- Line terminals in a row above the circuit plate, kept between the east wall and the south doorway.
local function terminalPos(line: number): Vector3
	return v(P03.plate) + Vector3.new((line - 2) * 2.9 - 0.6, 2.6, 0)
end

-- Conduits from each box up its wall, along the ceiling to the plate wall, across and down to its line terminal.
-- Rebuilt whenever the layout changes. Each box's run sits at its own height so runs never merge.
local function buildConduits(layout: Puzzles.FuseLayout)
	if p03Conduits then
		p03Conduits:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "P03_Conduits"
	f.Parent = folder
	p03Conduits = f
	local room = assert(WorldDefs.chamber(P03.chamberId))
	local ceiling = room.pos.y + room.size.y
	local northWallZ = room.pos.z + room.size.z / 2 - 0.3 -- conduits run up the north wall behind the boxes
	local boardTop = v(P03.plate).Y + 3.6
	local behindBoard = v(P03.plate).Z - 1 -- and drop behind the switchboard into its top edge
	local function run(name: string, a: Vector3, b: Vector3, color: Color3)
		local d = b - a
		local len = d.Magnitude
		if len < 0.05 then
			return
		end
		local p =
			deco(name, Vector3.new(0.35, 0.35, len + 0.35), CFrame.lookAt((a + b) / 2, b), color, Enum.Material.Metal)
		p.Parent = f
	end
	for i, b in P03.boxes do
		local line = layout.wiring[b.label]
		local color = CONDUIT_COLORS[i] or STEEL
		local y = ceiling - 1 - (i - 1) * 0.8
		local box = v(b.pos)
		local term = terminalPos(line)
		local p0 = Vector3.new(box.X, box.Y, box.Z + 0.5) -- back of the box
		local p1 = Vector3.new(box.X, box.Y, northWallZ)
		local p2 = Vector3.new(box.X, y, northWallZ)
		local p3 = Vector3.new(box.X, y, behindBoard)
		local p4 = Vector3.new(term.X, y, behindBoard)
		local p5 = Vector3.new(term.X, boardTop, behindBoard)
		run("Conduit" .. b.label .. "_0", p0, p1, color)
		run("Conduit" .. b.label .. "_1", p1, p2, color)
		run("Conduit" .. b.label .. "_2", p2, p3, color)
		run("Conduit" .. b.label .. "_3", p3, p4, color)
		run("Conduit" .. b.label .. "_4", p4, p5, color)
	end
end

local function refreshP03()
	local layout = Puzzles.P03_LAYOUTS[p03.layout]
	p03PlateLabel.Text = if p03.powered
		then "CIRCUIT PLATE\nALL LINES LIVE"
		else "CIRCUIT PLATE\n" .. Puzzles.fuseDeadText(layout, "LINE")
	for line, lbl in p03TerminalLabels do
		lbl.Text = Puzzles.fuseTerminalText(layout, line, "LINE")
	end
	for _, b in Puzzles.FUSE_BOXES do
		local lbl = p03BoxLabels[b]
		if lbl then
			lbl.Text = Puzzles.fuseBoxText(layout, b, "BOX")
		end
	end
	p03Status.Color = if p03.powered then GREEN else RED
end

local function setStationPower(on: boolean)
	for _, lamp in stationLamps do
		lamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		lamp.Color = if on then LAMP_ON else LAMP_OFF
		local l = lamp:FindFirstChildOfClass("PointLight")
		if l then
			l.Enabled = on
		end
	end
	if radioDialLabel then
		radioDialLabel.Text = if on then "STATION RADIO\nSTATION POWER ON" else "STATION RADIO\nNO STATION POWER"
	end
	folder:SetAttribute("StationPowered", on)
end

local function spark(at: Vector3)
	local s =
		deco("Spark", Vector3.new(0.5, 0.5, 0.5), CFrame.new(at), Color3.fromRGB(255, 230, 120), Enum.Material.Neon)
	task.delay(0.3, function()
		s:Destroy()
	end)
end

local function fuseAt(player: Player, box: string, boxPart: BasePart)
	local s = canAct(player, boxPart.Position, 12)
	if not s then
		return
	end
	if p03.powered then
		notify(player, "This line is live. The station has power for now.")
		return
	end
	local inv = s.profile.inventory
	local missing =
		Puzzles.fuseMissing(Inventory.count(inv, Puzzles.REPAIR_ROLL), Inventory.count(inv, Puzzles.FUSE_KIT))
	if #missing > 0 then
		notify(player, Puzzles.fuseMissingText(missing), "warn")
		return
	end
	if not services.PlayerService.hold(player, Config.Puzzles.fuseInsertSeconds * classRepairMultiplier(s)) then
		return
	end
	-- Re-validate after the yield: the player may have left or gone down, or someone else restored the line.
	s = canAct(player, boxPart.Position, 12)
	if not s then
		return
	end
	inv = s.profile.inventory
	local result = Puzzles.insertFuse(
		p03,
		box,
		Inventory.count(inv, Puzzles.REPAIR_ROLL),
		Inventory.count(inv, Puzzles.FUSE_KIT),
		Config.Puzzles.fuseWrongBoxSeconds,
		os.clock()
	)
	if result.outcome == "already" then
		notify(player, "Someone restored the line while you worked. Your fuse kit is unused.")
		return
	elseif result.outcome == "missing" then
		notify(player, Puzzles.fuseMissingText(result.missing), "warn")
		return
	elseif result.outcome == "wrong" then
		-- the time cost: working the fuse back out of the wrong box (it is never consumed and never hurts)
		services.PlayerService.hold(player, result.delaySeconds)
		spark(boxPart.Position - Vector3.new(0, 0, 0.8))
		cueNear(boxPart.Position, 30, "fuse_spark")
		notify(
			player,
			string.format(
				"Box %s sparks and spits the fuse back out: it is not on the dead line. Your fuse kit is returned.",
				box
			),
			"warn"
		)
		return
	end
	-- Right box: one fuse kit is used; the repair tool roll is kept.
	Inventory.remove(inv, Puzzles.FUSE_KIT, result.fusesConsumed)
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	refreshP03()
	setStationPower(true)
	cueRegion("R04", "power_restored", generatorPos)
	notify(player, "Power restored. The station lamps are on, and the radio set has power now.")
	services.DiscoveryService.discover(player, "P03.solved", "Fuse bridge — station power restored")
end

local function buildP03()
	local room = assert(WorldDefs.chamber(P03.chamberId), "P03 chamber missing")
	local state = Puzzles.newP03(math.random(1, #Puzzles.P03_LAYOUTS))
	for i, layout in Puzzles.P03_LAYOUTS do
		local ok, why = Puzzles.validLayout(layout)
		assert(ok, string.format("P03 layout %d: %s", i, tostring(why)))
	end
	p03 = state
	generatorPos = v(P03.generator)
	p03Boxes = { Puzzles.chamberBox(room, 0) }
	-- Junction boxes on the north wall, facing into the room (-z), each with a conduit tag above it.
	for _, b in P03.boxes do
		local pos = v(b.pos)
		local boxPart = mk(
			"P03_Box" .. b.label,
			Vector3.new(2.6, 3, 1),
			CFrame.lookAt(pos, pos - Vector3.zAxis),
			STEEL,
			Enum.Material.Metal
		)
		p03BoxParts[b.label] = boxPart
		local _, tagLabel = sign(
			"P03_BoxTag" .. b.label,
			Vector3.new(2.6, 1.4, 0.1),
			pos + Vector3.new(0, 2.4, -0.4),
			-Vector3.zAxis,
			""
		)
		p03BoxLabels[b.label] = tagLabel
		prompt(boxPart, "Fit fuse", "Junction box " .. b.label).Triggered:Connect(function(player)
			fuseAt(player, b.label, boxPart)
		end)
	end
	-- Switchboard on the south side (faces +z): the circuit plate, its line terminals above it and a status lamp. The
	-- conduits from the boxes drop into its top edge above their terminals.
	local plate = v(P03.plate)
	local boardTop = plate.Y + 3.6
	mk(
		"P03_Switchboard",
		Vector3.new(9, boardTop - room.pos.y, 0.5), -- x -78..-69: clear of the south doorway (x -90..-78)
		CFrame.new(plate.X - 0.5, (boardTop + room.pos.y) / 2, plate.Z - 0.4),
		STEEL,
		Enum.Material.Metal
	)
	local _, plateLabel = sign("P03_Plate", Vector3.new(5, 2, 0.2), v(P03.plate), Vector3.zAxis, "")
	p03PlateLabel = plateLabel
	for line = 1, #Puzzles.FUSE_BOXES do
		local _, lbl = sign("P03_Terminal" .. line, Vector3.new(2.8, 1.2, 0.1), terminalPos(line), Vector3.zAxis, "")
		p03TerminalLabels[line] = lbl
	end
	p03Status = deco(
		"P03_Status",
		Vector3.new(0.6, 0.6, 0.3),
		CFrame.new(v(P03.plate) + Vector3.new(3, 0, 0)),
		RED,
		Enum.Material.Neon
	)
	sign(
		"P03_Notice",
		Vector3.new(5, 1.4, 0.1),
		v(P03.plate) + Vector3.new(0, -1.8, 0),
		Vector3.zAxis,
		"Repair tool roll + fuse kit. Trace the dead line to its box."
	)
	-- Station lamps in the survey station's rooms: dark until the line is restored.
	for _, c in WorldDefs.Chambers do
		if c.regionId == "R04" and c.id ~= "R04.collapsed_adit" then
			for _, dx in { -1, 1 } do
				local lamp = deco(
					"StationLamp",
					Vector3.new(0.9, 0.6, 0.9),
					CFrame.new(c.pos.x + dx * c.size.x / 4, c.pos.y + c.size.y - 1.2, c.pos.z),
					LAMP_OFF,
					Enum.Material.SmoothPlastic
				)
				local l = Instance.new("PointLight")
				l.Color = Color3.fromRGB(255, 214, 160)
				l.Range = 20
				l.Brightness = 0.9
				l.Shadows = false
				l.Enabled = false
				l.Parent = lamp
				table.insert(stationLamps, lamp)
			end
		end
	end
	buildConduits(Puzzles.P03_LAYOUTS[state.layout])
	refreshP03()
	setStationPower(false)
end

local function tickP03(now: number)
	if Puzzles.p03ShouldTrip(p03, now, Config.Puzzles.stationPowerSeconds, false) and not occupied(p03Boxes, true) then
		local n = #Puzzles.P03_LAYOUTS
		Puzzles.tripP03(p03, Puzzles.nextLayout(p03.layout, n, math.random(1, math.max(1, n - 1))))
		buildConduits(Puzzles.P03_LAYOUTS[p03.layout])
		refreshP03()
		setStationPower(false)
		cueRegion("R04", "power_tripped", generatorPos)
	end
end

-- P04 Weight and pulley -------------------------------------------------------------------------------
type GratePiece = { part: BasePart, base: CFrame }
local grateParts: { GratePiece } = {}
local grateBlocker: BasePart
local grateGen = 0
local gratePos: Vector3
local p04Boxes: { Puzzles.Box } = {}
local pileStones: { BasePart } = {}
local basketStones: { BasePart } = {}
local basketPart: BasePart
local basketLabel: TextLabel
local latchHandle: BasePart
local latchBase: CFrame
local latchPrompt: ProximityPrompt
local leverHolding: { [Player]: boolean } = {}

local function refreshP04()
	for i, st in pileStones do
		st.Transparency = if i <= p04.required - p04.stones then 0 else 1
	end
	for i, st in basketStones do
		st.Transparency = if i <= p04.stones then 0 else 1
	end
	local state = if p04.latched
		then "LATCHED"
		elseif p04.holders > 0 then "LEVER HELD"
		elseif p04.raised then "RAISED — NOT LATCHED"
		else "DOWN"
	basketLabel.Text = string.format("COUNTERWEIGHT %d / %d\nGRATE: %s", p04.stones, p04.required, state)
	latchHandle.CFrame = latchBase * CFrame.Angles(if p04.latched then math.rad(-60) else math.rad(30), 0, 0)
	latchPrompt.ActionText = if p04.latched then "Release latch" else "Pull latch"
end

local function moveGrate(raised: boolean)
	grateGen += 1
	local gen = grateGen
	local dy = if raised then WorldDefs.CORRIDOR_HEIGHT - 1 else 0
	local t = if raised then 2.5 else 0.8
	for _, g in grateParts do
		TweenService
			:Create(g.part, TweenInfo.new(t, Enum.EasingStyle.Quad), { CFrame = g.base + Vector3.new(0, dy, 0) })
			:Play()
	end
	if raised then
		task.delay(t / 2, function()
			if gen == grateGen then
				grateBlocker.CanCollide = false
			end
		end)
		return
	end
	task.delay(t, function()
		if gen ~= grateGen then
			return
		end
		-- Last check before the grate turns solid: it never closes on anyone, even someone who stepped under it
		-- while it fell. It swings straight back up instead.
		if occupied(p04Boxes) then
			Puzzles.innerLever(p04, os.clock(), P04_SLIP_SECONDS)
			refreshP04()
			moveGrate(true)
			cueNear(gratePos, 60, "grate_rise")
			return
		end
		grateBlocker.CanCollide = true
	end)
end

local function raiseGrate()
	moveGrate(true)
	cueNear(gratePos, 60, "grate_rise")
end

local function loadStone(player: Player)
	local s = canAct(player, basketPart.Position, 10)
	if not s then
		return
	end
	if p04.stones >= p04.required then
		notify(player, "The counterweight basket is full.")
		return
	end
	local n, raisedNow = Puzzles.loadStone(p04, os.clock(), P04_SLIP_SECONDS)
	-- a stone visibly travels from the pile into the basket
	local from = pileStones[1]
	if from then
		local carried = deco("P04_CarriedStone", from.Size, from.CFrame, from.Color, Enum.Material.Slate)
		TweenService:Create(carried, TweenInfo.new(0.8), { CFrame = basketPart.CFrame + Vector3.new(0, 1, 0) }):Play()
		task.delay(0.8, function()
			carried:Destroy()
		end)
	end
	refreshP04()
	cueNear(basketPart.Position, 40, "pulley_creak", { stones = n, of = p04.required })
	if raisedNow then
		raiseGrate()
		notify(
			player,
			"The counterweight lifts the grate. The worn brake will not hold it long on its own: pull the latch to keep it up."
		)
	end
end

local function toggleLatch(player: Player)
	if not canAct(player, latchHandle.Position, 10) then
		return
	end
	local r = Puzzles.toggleLatch(p04, os.clock(), Config.Puzzles.pulleyDropSeconds)
	if r == "not_raised" then
		notify(
			player,
			string.format(
				"The latch only holds a raised grate. Load the counterweight basket (%d/%d), or have someone hold the lever.",
				p04.stones,
				p04.required
			)
		)
		return
	end
	refreshP04()
	cueNear(latchHandle.Position, 40, "pulley_creak")
	if r == "latched" then
		notify(player, "Latched. The grate stays up until someone releases the latch.")
	else
		notify(
			player,
			string.format(
				"Latch released. The grate drops in about %d minutes, and only once nobody is under it or behind it.",
				math.max(1, math.floor(Config.Puzzles.pulleyDropSeconds / 60 + 0.5))
			)
		)
	end
end

-- A party member holds the lever (a cancelable hold: moving away lets go) while the others cross.
local function holdLever(player: Player)
	if leverHolding[player] or not canAct(player, latchHandle.Position, 10) then
		return
	end
	leverHolding[player] = true
	if Puzzles.leverHold(p04) then
		raiseGrate()
	end
	refreshP04()
	notify(
		player,
		string.format(
			"Holding the lever: the grate stays up while you stay here (up to %d s). Others can cross now.",
			LEVER_HOLD_SECONDS
		)
	)
	services.PlayerService.hold(player, LEVER_HOLD_SECONDS)
	leverHolding[player] = nil
	Puzzles.leverRelease(p04, os.clock(), P04_SLIP_SECONDS)
	refreshP04()
end

local function innerLever(player: Player, at: Vector3)
	if not canAct(player, at, 10) then
		return
	end
	if Puzzles.innerLever(p04, os.clock(), Config.Puzzles.pulleyDropSeconds) then
		raiseGrate()
	end
	refreshP04()
	notify(player, "The grate is up. It will not drop while anyone is under it or in here.")
end

local function buildP04()
	local room = assert(WorldDefs.chamber(P04.chamberId), "P04 chamber missing")
	local a, b = gatedCorridor("P04")
	local store = if a.id == P04.chamberId then b else a
	local state = Puzzles.newP04(P04.stonesNeeded)
	p04 = state
	local W, H = WorldDefs.CORRIDOR_WIDTH, WorldDefs.CORRIDOR_HEIGHT
	-- Nobody under the grate (4 studs either side), in the corridor or anywhere in the store.
	p04Boxes = { Puzzles.corridorBox(room, store, W, H, 1, 4), Puzzles.chamberBox(store, 1) }
	-- Stone pile
	local pile = v(P04.stonePile)
	for i = 1, state.required + 2 do
		local ang = i * 2.1
		local stone = mk(
			"P04_PileStone" .. i,
			Vector3.new(1.4, 1, 1.2),
			CFrame.new(
				pile
					+ Vector3.new(
						math.cos(ang) * 1.2,
						0.5 + (if i > state.required then 0 else 0.4),
						math.sin(ang) * 1.2
					)
			) * CFrame.Angles(0, ang, 0),
			Color3.fromRGB(130, 124, 112),
			Enum.Material.Slate
		)
		stone.CanCollide = false
		if i <= state.required then
			table.insert(pileStones, stone)
		end
	end
	sign("P04_PileSign", Vector3.new(3.4, 1, 0.1), pile + Vector3.new(0, 2.6, 0), Vector3.xAxis, "COUNTERWEIGHT STONES")
	-- Counterweight basket under the existing pulley frame
	local basket = v(P04.basket)
	basketPart = mk(
		"P04_Basket",
		Vector3.new(3, 1.4, 3),
		CFrame.new(basket + Vector3.new(0, 1.2, 0)),
		WOOD,
		Enum.Material.WoodPlanks
	)
	deco(
		"P04_BasketRope",
		Vector3.new(0.25, 9.5, 0.25),
		CFrame.new(basket + Vector3.new(0, 6.7, 0)),
		WOOD,
		Enum.Material.Fabric
	)
	for i = 1, state.required do
		local st = deco(
			"P04_BasketStone" .. i,
			Vector3.new(1.1, 0.8, 1),
			CFrame.new(basket + Vector3.new(-0.9 + (i - 1) * 0.9, 2.2, 0)),
			Color3.fromRGB(130, 124, 112),
			Enum.Material.Slate
		)
		st.Transparency = 1
		table.insert(basketStones, st)
	end
	local _, bl =
		sign("P04_BasketTag", Vector3.new(3.4, 1.6, 0.1), basket + Vector3.new(0, 3.6, -1.6), -Vector3.zAxis, "")
	basketLabel = bl
	prompt(basketPart, "Load a stone", "Counterweight basket", 1.5).Triggered:Connect(loadStone)
	-- Latch post: a latch (E) and a lever to hold (F)
	local lp = v(P04.latch)
	mk(
		"P04_LatchPost",
		Vector3.new(0.8, 4, 0.8),
		CFrame.new(lp + Vector3.new(0, 2, 0)),
		RUST,
		Enum.Material.CorrodedMetal
	)
	latchBase = CFrame.new(lp + Vector3.new(0, 3.2, -0.6))
	latchHandle = mk("P04_Latch", Vector3.new(0.4, 0.4, 2.2), latchBase, STEEL, Enum.Material.Metal)
	latchHandle.CanCollide = false
	latchPrompt = prompt(latchHandle, "Pull latch", "Pulley latch", 0.5)
	latchPrompt.Triggered:Connect(toggleLatch)
	local leverPrompt = prompt(latchHandle, "Hold the lever", "Pulley lever (party)", 0.3)
	leverPrompt.KeyboardKeyCode = Enum.KeyCode.F
	leverPrompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	leverPrompt.UIOffset = Vector2.new(0, 60)
	leverPrompt.Triggered:Connect(holdLever)
	-- Grate in the north opening: visible bars move; one invisible blocker carries the collision.
	gratePos = v(P04.grate)
	local barColor = Color3.fromRGB(70, 66, 60)
	local function piece(p: BasePart)
		table.insert(grateParts, { part = p, base = p.CFrame })
	end
	for i = 0, 7 do
		local x = -W / 2 + 0.75 + i * ((W - 1.5) / 7)
		piece(
			deco(
				"P04_GrateBar",
				Vector3.new(0.35, H, 0.35),
				CFrame.new(gratePos + Vector3.new(x, H / 2, 0)),
				barColor,
				Enum.Material.CorrodedMetal
			)
		)
	end
	for _, y in { 1, H / 2, H - 1 } do
		piece(
			deco(
				"P04_GrateRail",
				Vector3.new(W, 0.35, 0.35),
				CFrame.new(gratePos + Vector3.new(0, y, 0)),
				barColor,
				Enum.Material.CorrodedMetal
			)
		)
	end
	grateBlocker = mk(
		"P04_GrateBlocker",
		Vector3.new(W, H, 0.6),
		CFrame.new(gratePos + Vector3.new(0, H / 2, 0)),
		Color3.new(),
		Enum.Material.SmoothPlastic
	)
	grateBlocker.Transparency = 1
	grateBlocker.CanQuery = false
	piece(grateBlocker)
	sign(
		"P04_GrateSign",
		Vector3.new(7, 1.4, 0.1),
		gratePos + Vector3.new(0, H + 1.6, -1.2),
		-Vector3.zAxis,
		"GRATE — COUNTERWEIGHT 3 STONES · LATCH TO HOLD"
	)
	-- Inner lever inside the Pulley Store: always raises the grate
	local ip = v(P04.innerLever)
	local inner = mk(
		"P04_InnerLever",
		Vector3.new(0.6, 3, 0.6),
		CFrame.new(ip + Vector3.new(0, 1.5, 0)),
		Color3.fromRGB(150, 40, 30),
		Enum.Material.Metal
	)
	sign(
		"P04_InnerSign",
		Vector3.new(3.4, 1, 0.1),
		ip + Vector3.new(0, 3.6, 0),
		Vector3.xAxis,
		"INNER RELEASE — OPENS THE GRATE"
	)
	prompt(inner, "Pull inner lever", "Grate release", 0.5).Triggered:Connect(function(player)
		innerLever(player, inner.Position)
	end)
	refreshP04()
end

local function tickP04(now: number)
	-- Timers first; the occupancy scan only runs when the grate would otherwise drop.
	if Puzzles.p04ShouldDrop(p04, now, false) and not occupied(p04Boxes) then
		Puzzles.dropP04(p04)
		refreshP04()
		moveGrate(false)
		cueNear(gratePos, 60, "grate_drop")
	end
end

-- P05 Echo sequence -----------------------------------------------------------------------------------
local radioPos: Vector3
local radioLamp: BasePart
local radioSolved: { [Player]: boolean } = {}
local lastAttempt: { [Player]: number } = {}

local function setRadioLamp(on: boolean)
	radioLamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
	radioLamp.Color = if on then (if PuzzleService.isPowered() then GREEN else AMBER) else LAMP_OFF
end

-- Elise Renaud's interrupted log (story package line), the station tape (unique, protected, once per player) and the
-- Act II fact. Durable: committed before the tape notice.
local function playLog(player: Player)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	safeCall("NpcService", "say", player, "N05", "radio_log")
	local changed = false
	if s.profile.storyStates[RADIO_HEARD] ~= "1" then
		s.profile.storyStates[RADIO_HEARD] = "1"
		changed = true
	end
	local gotTape = false
	if not s.profile.claims[TAPE_CLAIM] then
		local inv = s.profile.inventory
		if Inventory.count(inv, TAPE_ID) >= ItemDefs.require(TAPE_ID).stackLimit then
			notify(player, "No room to carry the station tape. Make room and tune the radio again.", "warn")
		elseif Progress.claim(s.profile.claims, TAPE_CLAIM) then
			Inventory.add(inv, ItemDefs.get, TAPE_ID, 1, "expedition")
			gotTape = true
			changed = true
		end
	end
	if not changed then
		return
	end
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	safeCall("StoryService", "onFact", player)
	task.spawn(function()
		local ok = services.SaveService.commit(player)
		if gotTape then
			notify(
				player,
				if ok
					then "Station tape recorded: Elise Renaud's log. It is a protected story item. Saved."
					else "Station tape recorded: Elise Renaud's log. Saving failed; it will retry.",
				if ok then "info" else "warn"
			)
		end
	end)
end

local function tune(player: Player)
	local s = canAct(player, radioPos, RADIO_RANGE)
	if not s then
		return
	end
	if radioSolved[player] or s.profile.storyStates[RADIO_HEARD] == "1" then
		if PuzzleService.isPowered() then
			playLog(player) -- replays the log; the tape and the fact are granted only once
		else
			notify(player, "The frequency holds, but the set has no power. Restore the generator.")
		end
		return
	end
	services.PlayerService.send(player, "radioPattern", {
		pattern = p05Pattern,
		symbols = Puzzles.echoSymbols(p05Pattern),
		position = radioPos,
		powered = PuzzleService.isPowered(),
	})
	services.PlayerService.send(player, "cue", { id = "radio_tone", position = radioPos })
end

local function radioAttempt(player: Player, input: string)
	if not built.P05 then
		return
	end
	local now = os.clock()
	if now - (lastAttempt[player] or -math.huge) < RADIO_ATTEMPT_COOLDOWN then
		return
	end
	lastAttempt[player] = now
	if not canAct(player, radioPos, RADIO_RANGE) then
		return
	end
	if Puzzles.normalizeEcho(input) == nil then
		return
	end
	if not Puzzles.echoMatches(p05Pattern, input) then
		services.PlayerService.send(player, "cue", { id = "radio_wrong", position = radioPos })
		services.PlayerService.send(player, "radioResult", { ok = false })
		return
	end
	radioSolved[player] = true
	local powered = PuzzleService.isPowered()
	services.PlayerService.send(player, "cue", { id = "radio_locked", position = radioPos })
	services.PlayerService.send(player, "radioResult", { ok = true, powered = powered })
	if powered then
		playLog(player)
	else
		notify(player, "The frequency holds, but the set has no power. Restore the generator.")
	end
end

local function buildP05()
	local list = P05.sequences
	local pick = list[math.random(1, #list)]
	p05Pattern = assert(Puzzles.normalizeEcho(pick), "bad P05 sequence")
	local r = v(P05.radio)
	local room = assert(WorldDefs.chamber(P05.chamberId), "P05 chamber missing")
	-- The set stands against the wall nearest to it and faces into the room.
	local facing = if r.X > room.pos.x then -Vector3.xAxis else Vector3.xAxis
	mk(
		"P05_Desk",
		Vector3.new(2.6, 3, 4.4),
		CFrame.new(r + Vector3.new(0, 1.5, 0) - facing * 0.4),
		WOOD,
		Enum.Material.WoodPlanks
	)
	local set = mk(
		"P05_Radio",
		Vector3.new(3, 1.6, 1.6), -- X runs along the wall (lookAt right vector), Z is the depth
		CFrame.lookAt(r + Vector3.new(0, 3.8, 0), r + Vector3.new(0, 3.8, 0) + facing),
		Color3.fromRGB(70, 66, 58),
		Enum.Material.Metal
	)
	radioPos = set.Position
	local lamp = deco(
		"P05_Lamp",
		Vector3.new(0.6, 0.6, 0.6),
		CFrame.new(radioPos + Vector3.new(0, 1.1, 0) + facing * 0.4),
		LAMP_OFF,
		Enum.Material.SmoothPlastic
	)
	lamp.Shape = Enum.PartType.Ball
	radioLamp = lamp
	local _, dial = sign("P05_Dial", Vector3.new(2.6, 1.2, 0.1), radioPos + facing * 0.9, facing, "")
	radioDialLabel = dial
	sign(
		"P05_Instructions",
		Vector3.new(3.6, 1, 0.1),
		radioPos + Vector3.new(0, 2.4, 0) + facing * 0.5,
		facing,
		"Watch the lamp. Repeat its short and long pulses."
	)
	prompt(set, "Tune the radio", "Station radio").Triggered:Connect(tune)
	setStationPower(PuzzleService.isPowered())
end

-- The set's lamp blinks the rhythm for everyone nearby (shared, visual: never audio-only).
local function blinkOnce()
	local near = false
	for p in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and (pos - radioPos).Magnitude <= 30 then
			near = true
			break
		end
	end
	if not near then
		task.wait(1)
		return
	end
	for _, step in Puzzles.echoTimeline(p05Pattern) do
		setRadioLamp(true)
		task.wait(step.on)
		setRadioLamp(false)
		task.wait(step.off)
	end
	task.wait(2.5)
end

-- W05 Sluice gates ------------------------------------------------------------------------------------
local sluiceLamps: { BasePart } = {}
local sluiceDeep: BasePart
local sluiceWet: BasePart
local sluiceBarriers: { BasePart } = {}
local sluiceCenter: Vector3
local w05Boxes: { Puzzles.Box } = {}

local function refreshSluice()
	local set: { [number]: boolean } = {}
	for i = 1, w05.progress do
		set[w05.order[i]] = true
	end
	for i, lamp in sluiceLamps do
		local on = w05.open or set[i] == true
		lamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		lamp.Color = if on then GREEN else LAMP_OFF
	end
end

local function setSluiceDrained(drained: boolean)
	local h = if drained then 0.01 else 7
	local floorY = sluiceCenter.Y
	TweenService:Create(sluiceDeep, TweenInfo.new(if drained then 6 else 8), {
		Size = Vector3.new(sluiceDeep.Size.X, h, sluiceDeep.Size.Z),
		CFrame = CFrame.new(sluiceCenter.X, floorY + h / 2, sluiceCenter.Z),
	}):Play()
	-- Drained, the passage is a dry silt floor (M05: "expose a dry path"); only the wheels are loud.
	sluiceWet.Transparency = if drained then 0.2 else 1
	for _, b in sluiceBarriers do
		b.CanCollide = not drained
	end
end

local function turnSluice(player: Player, i: number, wheel: BasePart)
	if not canAct(player, wheel.Position, 10) then
		return
	end
	if w05.open then
		notify(player, "The sluice gates are set: the overflow passage is drained.")
		return
	end
	local result, n = Puzzles.turnWheel(w05, i, os.clock())
	TweenService:Create(wheel, TweenInfo.new(0.8), { CFrame = wheel.CFrame * CFrame.Angles(math.pi / 2, 0, 0) }):Play()
	-- Every turn is loud: water surges through the races (draws the Wader if it is around).
	safeCall("CreatureService", "noise", wheel.Position, "splash", SLUICE_LOUDNESS, player)
	cueNear(wheel.Position, 90, "sluice_gate", { n = n, of = #w05.order })
	refreshSluice()
	if result == "reset" then
		cueNear(wheel.Position, 90, "sluice_reset")
	elseif result == "open" then
		setSluiceDrained(true)
		cueRegion("R03", "sluice_open", sluiceCenter)
		services.DiscoveryService.discover(player, "W05.solved", "Sluice gates set — the overflow passage drains")
	end
end

local function buildW05()
	local room = assert(WorldDefs.chamber(W05.chamberId), "W05 chamber missing")
	local orderText = W05.orders[math.random(1, #W05.orders)]
	local state = Puzzles.newW05(orderText, #W05.wheels)
	w05 = state
	local clueA, clueB = Puzzles.w05CluesFor(orderText)
	-- Wheels on the side walls, facing into the room, each with a name tag and an "in order" lamp.
	for i, wp in W05.wheels do
		local pos = v(wp)
		local facing = if pos.X > room.pos.x then -Vector3.xAxis else Vector3.xAxis
		local wheel =
			mk("W05_Wheel" .. i, Vector3.new(0.5, 3.2, 3.2), CFrame.new(pos), RUST, Enum.Material.CorrodedMetal)
		wheel.Shape = Enum.PartType.Cylinder -- axis along X: the wheel faces into the room
		sign(
			"W05_WheelTag" .. i,
			Vector3.new(3, 1.2, 0.1),
			pos + Vector3.new(0, 2.6, 0) + facing * 0.3,
			facing,
			string.format("%s · %s RACE", Puzzles.roman(i), string.upper(Puzzles.wheelName(i)))
		)
		local lamp = deco(
			"W05_Lamp" .. i,
			Vector3.new(0.5, 0.5, 0.5),
			CFrame.new(pos + Vector3.new(0, 3.6, 0) + facing * 0.3),
			LAMP_OFF,
			Enum.Material.SmoothPlastic
		)
		lamp.Shape = Enum.PartType.Ball
		table.insert(sluiceLamps, lamp)
		prompt(
			wheel,
			"Turn sluice wheel",
			string.format("Wheel %s (%s race)", Puzzles.roman(i), Puzzles.wheelName(i)),
			1
		).Triggered:Connect(function(player)
			turnSluice(player, i, wheel)
		end)
	end
	local first = v(W05.wheels[1])
	sign(
		"W05_Sign",
		Vector3.new(6, 2.4, 0.1),
		first + Vector3.new(0, 5.4, 0) + (if first.X > room.pos.x then -Vector3.xAxis else Vector3.xAxis) * 0.3,
		if first.X > room.pos.x then -Vector3.xAxis else Vector3.xAxis,
		"SLUICE GATES — turn all three in the right order. The order is posted at the Old Pumps and in the Drain Gallery."
	)
	-- Clue plates: each names part of the order; together they fix it.
	local texts = {
		"SLUICE ORDER (1 of 2)\n" .. Puzzles.clueText(clueA),
		"SLUICE ORDER (2 of 2)\n" .. Puzzles.clueText(clueB),
	}
	for i, c in W05.clues do
		sign("W05_Clue" .. i, Vector3.new(5, 2.4, 0.1), v(c.pos), v(c.facing), texts[i] or "")
	end
	-- Deep water across the gated corridor, with collidable barriers at both mouths (too deep to wade).
	local a, b = gatedCorridor("W05")
	local center, len, alongX = corridorSpan(a, b)
	local W, H = WorldDefs.CORRIDOR_WIDTH, WorldDefs.CORRIDOR_HEIGHT
	sluiceCenter = center
	local span = if alongX then Vector3.new(len, 7, W) else Vector3.new(W, 7, len)
	sluiceDeep = deco(
		"W05_Deep",
		span,
		CFrame.new(center + Vector3.new(0, 3.5, 0)),
		Color3.fromRGB(30, 50, 52),
		Enum.Material.Glass
	)
	sluiceDeep.Transparency = 0.25
	sluiceWet = deco(
		"W05_WetSilt",
		Vector3.new(span.X, 0.1, span.Z),
		CFrame.new(center + Vector3.new(0, 0.05, 0)),
		Color3.fromRGB(70, 64, 50),
		Enum.Material.Mud
	)
	sluiceWet.Transparency = 1
	local axis = if alongX then Vector3.xAxis else Vector3.zAxis
	for _, sgn in { -1, 1 } do
		local bp = center + axis * sgn * (len / 2 - 1) + Vector3.new(0, H / 2, 0)
		local bar = mk(
			"W05_Barrier",
			if alongX then Vector3.new(1, H, W) else Vector3.new(W, H, 1),
			CFrame.new(bp),
			Color3.new(),
			Enum.Material.SmoothPlastic
		)
		bar.Transparency = 1
		bar.CanQuery = false
		table.insert(sluiceBarriers, bar)
		sign(
			"W05_DeepSign",
			Vector3.new(5, 1.2, 0.1),
			bp + Vector3.new(0, 1, 0) + axis * sgn * 0.7, -- on the outer side, facing whoever approaches
			axis * sgn,
			"TOO DEEP — SET THE SLUICE GATES"
		)
	end
	local vault = if a.id == W05.chamberId then b else a
	w05Boxes = { Puzzles.corridorBox(a, b, W, H, 1, 2), Puzzles.chamberBox(vault, 1) }
	refreshSluice()
	setSluiceDrained(false)
end

local function tickW05(now: number)
	if Puzzles.w05ShouldReflood(w05, now, Config.Puzzles.sluiceRefloodSeconds, false) and not occupied(w05Boxes) then
		Puzzles.refloodW05(w05)
		refreshSluice()
		setSluiceDrained(false)
		cueRegion("R03", "sluice_flood", sluiceCenter)
	end
end

-- Gates API (docs/MILESTONE-3.md section 5) ---------------------------------------------------------------
local GATE_STATE: { [string]: () -> boolean } = {
	P01 = function()
		return p01 ~= nil and p01.solved
	end,
	P02 = function()
		return p02 ~= nil and p02.drained
	end,
	P04 = function()
		return p04 ~= nil and p04.raised
	end,
	W05 = function()
		return w05 ~= nil and w05.open
	end,
}

-- Gate state for mission reachability: puzzle gates count as open only while open. Keys: Puzzles.GATE_IDS.
function PuzzleService.openGates(): { [string]: boolean }
	local out = {}
	for _, id in Puzzles.GATE_IDS do
		local f = GATE_STATE[id]
		out[id] = f ~= nil and f()
	end
	return out
end

function PuzzleService.isGateOpen(gateId: string): boolean
	local f = GATE_STATE[gateId]
	return f ~= nil and f()
end

-- P03: station power is on (shared per server).
function PuzzleService.isPowered(): boolean
	return p03 ~= nil and p03.powered
end

-- P05: this player locked the frequency this server session, or has heard the log before (Act II step 5).
function PuzzleService.radioSolvedBy(player: Player): boolean
	if radioSolved[player] then
		return true
	end
	local s = services and services.PlayerService.get(player)
	return s ~= nil and s.profile.storyStates[RADIO_HEARD] == "1"
end

function PuzzleService.init(s)
	services = s
	-- P05 attempt from PuzzleUI: { input = "SLSS" }. Only a short string of S/L is accepted (validated again inside).
	services.Router.register("radio.attempt", "interact", function(player: Player, payload: any)
		local input = payload.input
		if type(input) == "string" and #input >= 1 and #input <= Puzzles.ECHO_MAX then
			radioAttempt(player, input)
		end
	end)
end

type Builder = { id: string, build: () -> (), tick: ((number) -> ())?, every: number }

function PuzzleService.start()
	folder = Instance.new("Folder")
	folder.Name = "Puzzles"
	folder.Parent = services.WorldBuilder.root()
	-- P03 before P05: the radio reads the station power state.
	local list: { Builder } = {
		{ id = "P01", build = buildP01, tick = nil, every = 0 },
		{ id = "P02", build = buildP02, tick = tickP02, every = 5 },
		{ id = "P03", build = buildP03, tick = tickP03, every = 5 },
		{ id = "P04", build = buildP04, tick = tickP04, every = 1 },
		{ id = "P05", build = buildP05, tick = nil, every = 0 },
		{ id = "W05", build = buildW05, tick = tickW05, every = 5 },
	}
	-- One broken puzzle (bad data, missing chamber) must not stop the others or the server.
	for _, entry in list do
		local ok = xpcall(entry.build, function(err)
			warn(string.format("[PuzzleService] %s failed to build: %s", entry.id, debug.traceback(tostring(err))))
		end)
		built[entry.id] = ok
	end
	Players.PlayerRemoving:Connect(function(player)
		radioSolved[player] = nil
		lastAttempt[player] = nil
	end)
	task.spawn(function()
		local last: { [string]: number } = {}
		while true do
			task.wait(1)
			local now = os.clock()
			for _, entry in list do
				local tick = entry.tick
				if tick and built[entry.id] and now - (last[entry.id] or 0) >= entry.every then
					last[entry.id] = now
					xpcall(tick, function(err)
						warn(string.format("[PuzzleService] %s tick failed: %s", entry.id, tostring(err)))
					end, now)
				end
			end
		end
	end)
	if built.P05 then
		task.spawn(function()
			while true do
				local ok = xpcall(blinkOnce, function(err)
					warn("[PuzzleService] radio lamp failed: " .. tostring(err))
				end)
				if not ok then
					task.wait(5)
				end
			end
		end)
	end
end

return PuzzleService
