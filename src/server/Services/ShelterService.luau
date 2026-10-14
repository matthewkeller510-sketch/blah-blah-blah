--!strict
-- Shelters (section 13; owner rules F10, F11, F13). Public exterior, isolated private interior cells.
-- Each solo player or current party gets its own interior cell at unique far coordinates. Only occupants are
-- teleported there, so collision, AI and sound do not leak between groups. Upgrades are stored per player and
-- the cell shows the party's monotonic union.
-- Milestone 1 limitation: cells rely on distance + streaming to stay unreplicated to non-occupants; a stricter
-- per-player replication boundary (e.g. separate reserved server or per-client visuals) is PLANNED for review.
-- Milestone 3: shelter families decide the interior look (D34); entrance and functional-upgrade visuals are built from
-- the shelter definition (Logic/Shelters slots and visual map) instead of hard-coded ids; S04-style interiors with a
-- station_power upgrade hold the M04 private breaker cabinet (a private P03 layout per cell); station_power is
-- grant-only (never bought from the panel). Occupants are regrouped when parties change so outsiders never share a
-- cell (T11).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Shelters = require(Shared.Logic.Shelters)
local Commerce = require(Shared.Logic.Commerce)
local Vitals = require(Shared.Logic.Vitals)
local Puzzles = require(Shared.Logic.Puzzles)

Commerce.bind(Inventory)

local ShelterService = {}
local services: any

type Cell = {
	key: string,
	index: number,
	shelterId: string,
	model: Model,
	origin: Vector3,
	occupants: { [Player]: boolean },
	-- Players on their way in or out (streaming / teleport in progress). Keeps the cell from being destroyed under
	-- someone who is still standing in it or about to land in it.
	pending: { [Player]: boolean },
	parts: { [string]: BasePart },
	labels: { [string]: TextLabel },
	lastProbe: number,
	breaker: Puzzles.P03State?, -- M04 private breaker layout (shelters with station_power only)
}

local cells: { [string]: Cell } = {}
local nextIndex = 0
local freeIndices: { number } = {}
local entering: { [Player]: boolean } = {}
-- Players whose PlayerRemoving has fired: never placed into a cell again, even if a teleport was mid-stream.
local gone: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local POWER = "station_power"
local ROOM = Vector3.new(Shelters.ROOM.x, Shelters.ROOM.y, Shelters.ROOM.z)
local STONE = Color3.fromRGB(176, 166, 146)
local WOOD = Color3.fromRGB(92, 70, 48)
local RUST = Color3.fromRGB(110, 62, 38)
local STEEL = Color3.fromRGB(92, 98, 96)
local INK = Color3.fromRGB(30, 28, 24)
local LAMP_OFF = Color3.fromRGB(60, 58, 52)
local LAMP_ON = Color3.fromRGB(255, 222, 170)

-- Optional cross-package calls (docs/MILESTONE-3.md section 5). Isolated so a missing or failing API in another
-- package never aborts a registration, a save or a repair here.
local function safeCall(serviceName: string, fnName: string, ...: any)
	local svc = services[serviceName]
	local fn = svc and svc[fnName]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn(string.format("[ShelterService] %s.%s failed: %s", serviceName, fnName, tostring(err)))
	end
end

local function cellKey(player: Player): string
	local pid = services.PartyService.partyIdOf(player)
	return if pid then ("party:" .. pid) else ("solo:" .. player.UserId)
end

local function keyFor(player: Player, shelterId: string): string
	return cellKey(player) .. "@" .. shelterId
end

local function occupantsMap(cell: Cell): { [string]: { [string]: number } }
	local maps = {}
	for p in cell.occupants do
		local s = services.PlayerService.get(p)
		if s then
			table.insert(maps, s.profile.shelterUpgrades)
		end
	end
	-- The cell's key members (party) count even if not currently inside.
	local pid = string.match(cell.key, "^party:(.+)@")
	if pid then
		for _, uid in services.PartyService.memberIdsByParty(pid) or {} do
			local p = Players:GetPlayerByUserId(uid)
			local s = p and services.PlayerService.get(p)
			if s then
				table.insert(maps, s.profile.shelterUpgrades)
			end
		end
	end
	return Shelters.union(maps)
end

local function shelterDef(id: string?): WorldDefs.ShelterDef?
	return if id then WorldDefs.Shelters[id] else nil
end

local function able(s: any): boolean
	return s.alive and s.vitals.condition ~= "downed" and s.vitals.condition ~= "dead" and not s.carriedBy
end

local function mk(
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
	p.Parent = parent
	return p
end

-- Non-colliding, non-queryable dressing.
local function deco(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	material: Enum.Material?
): Part
	local p = mk(parent, name, size, cf, color, material)
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	return p
end

local function label(part: BasePart, text: string, color: Color3?): TextLabel
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.LightInfluence = 0.6
	g.Parent = part
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = Enum.Font.SpecialElite
	t.TextColor3 = color or INK
	t.Text = text
	t.Parent = g
	return t
end

local function prompt(parent: Instance, action: string, object: string, key: string): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = 0.25
	pp.MaxActivationDistance = 9
	pp.RequiresLineOfSight = false
	pp:SetAttribute("ShelterAction", key)
	pp.Parent = parent
	return pp
end

local function show(part: BasePart?, on: boolean)
	if part then
		part.Transparency = if on then 0 else 1
	end
end

type Theme = { wall: Color3, material: Enum.Material, floor: Enum.Material }

local THEMES: { [string]: Theme } = {
	limestone = {
		wall = Color3.fromRGB(176, 166, 146),
		material = Enum.Material.Limestone,
		floor = Enum.Material.Slate,
	},
	office = {
		wall = Color3.fromRGB(150, 140, 120),
		material = Enum.Material.Plaster,
		floor = Enum.Material.WoodPlanks,
	},
	ironwork = {
		wall = Color3.fromRGB(96, 98, 96),
		material = Enum.Material.Concrete,
		floor = Enum.Material.DiamondPlate,
	},
	-- Milestone 3 families (docs/MILESTONE-3.md 4.1)
	survey_station = { -- painted office plaster over a steel floor
		wall = Color3.fromRGB(124, 130, 120),
		material = Enum.Material.Plaster,
		floor = Enum.Material.DiamondPlate,
	},
	stable_stone = { -- pale, sound limestone
		wall = Color3.fromRGB(186, 176, 152),
		material = Enum.Material.Limestone,
		floor = Enum.Material.Slate,
	},
}

-- PROPOSED: a family's look wins over the per-shelter theme, so later shelters of the same family (D34: R08 survey
-- room, R09 return-route chamber) match without new code.
local FAMILY_THEME: { [string]: string } = {
	survey_station_room = "survey_station",
	stable_anchor_chamber = "stable_stone",
}

local function themeOf(def: WorldDefs.ShelterDef): Theme
	return THEMES[FAMILY_THEME[def.family] or def.theme] or THEMES.limestone
end

-- Family dressing (non-colliding): what makes each family's silhouette readable from inside.
local FAMILY_DECOR: { [string]: (Model, Vector3) -> () } = {
	survey_station_room = function(model, origin)
		local hx, hz = ROOM.X / 2, ROOM.Z / 2
		-- steel wainscot along the long walls
		for _, sz in { -1, 1 } do
			deco(
				model,
				"SteelWainscot",
				Vector3.new(ROOM.X, 3, 0.2),
				CFrame.new(origin + Vector3.new(0, 1.5, sz * (hz - 0.1))),
				STEEL,
				Enum.Material.DiamondPlate
			)
		end
		-- filing cabinets by the north wall
		for i = 0, 1 do
			deco(
				model,
				"FilingCabinet",
				Vector3.new(1.6, 4.4, 1.6),
				CFrame.new(origin + Vector3.new(hx - 3.2 + i * 1.8, 2.2, hz - 1)),
				STEEL,
				Enum.Material.Metal
			)
		end
		local map = deco(
			model,
			"StationFieldMap",
			Vector3.new(6, 3, 0.1),
			CFrame.lookAt(origin + Vector3.new(-4, 7, hz - 0.15), origin + Vector3.new(-4, 7, 0)),
			Color3.fromRGB(214, 206, 180),
			Enum.Material.SmoothPlastic
		)
		label(map, "SURVEY STATION 7\nSERVICE OFFICE — FIELD MAP\n(dates disagree)")
	end,
	stable_anchor_chamber = function(model, origin)
		local hz = ROOM.Z / 2
		-- painted survey level line around the room and a benchmark plaque with the anchor symbol
		for _, sz in { -1, 1 } do
			deco(
				model,
				"SurveyLevelLine",
				Vector3.new(ROOM.X, 0.15, 0.05),
				CFrame.new(origin + Vector3.new(0, 6, sz * (hz - 0.05))),
				Color3.fromRGB(150, 40, 30),
				Enum.Material.SmoothPlastic
			)
		end
		local plaque = deco(
			model,
			"AnchorBenchmark",
			Vector3.new(4, 2.4, 0.15),
			CFrame.lookAt(origin + Vector3.new(-4, 7.4, hz - 0.1), origin + Vector3.new(-4, 7.4, 0)),
			Color3.fromRGB(176, 150, 96),
			Enum.Material.Metal
		)
		label(plaque, "● REPÈRE STABLE ●\nsurvey anchor")
		local bolt = deco(
			model,
			"AnchorBolt",
			Vector3.new(0.5, 0.8, 0.8),
			CFrame.new(origin + Vector3.new(-1.2, 7.4, hz - 0.2)),
			Color3.fromRGB(180, 150, 80),
			Enum.Material.Metal
		)
		bolt.Shape = Enum.PartType.Cylinder
	end,
}

-- Entrance frame at a wall slot. Local -Z (LookVector) points into the room.
local function slotFrame(origin: Vector3, slot: Shelters.EntranceSlot): CFrame
	local o = Shelters.slotOffset(slot)
	local inward = if slot.wall == "W"
		then Vector3.xAxis
		elseif slot.wall == "E" then -Vector3.xAxis
		elseif slot.wall == "S" then Vector3.zAxis
		else -Vector3.zAxis
	local p = origin + Vector3.new(o.x, o.y, o.z)
	return CFrame.lookAt(p, p + inward)
end

-- Functional upgrade props, keyed by upgrade id (Shelters.FUNCTIONAL_VISUALS). Built only for the upgrades a shelter
-- defines; toggled from the cell's party union.
type BuildCtx = {
	model: Model,
	origin: Vector3,
	parts: { [string]: BasePart },
	labels: { [string]: TextLabel },
	breaker: Puzzles.P03State?,
}

local function powerLampsOf(cell: Cell): { BasePart }
	local out = {}
	for i = 1, 4 do
		local p = cell.parts["PowerLamp" .. i]
		if p then
			table.insert(out, p)
		end
	end
	return out
end

local FUNCTIONAL_BUILD: { [string]: (BuildCtx) -> () } = {
	workbench = function(c)
		local hz = ROOM.Z / 2
		c.parts.Workbench = mk(
			c.model,
			"Workbench",
			Vector3.new(6, 3, 3),
			CFrame.new(c.origin.X, c.origin.Y + 1.5, c.origin.Z - hz + 2.5),
			WOOD,
			Enum.Material.WoodPlanks
		)
		prompt(c.parts.Workbench, "Craft", "Workbench", "panel")
	end,
	supply_shelves = function(c)
		local hx = ROOM.X / 2
		c.parts.Shelves = mk(
			c.model,
			"Shelves",
			Vector3.new(2, 6, 7),
			CFrame.new(c.origin.X + hx - 1.5, c.origin.Y + 3, c.origin.Z - 4),
			WOOD,
			Enum.Material.WoodPlanks
		)
	end,
	better_lighting = function(_c)
		-- improves the base ceiling lamp, which every interior has
	end,
	station_power = function(c)
		local hx, hz = ROOM.X / 2, ROOM.Z / 2
		-- caged wall lamps on the station supply: dark until the breaker is repaired
		local spots = {
			Vector3.new(-hx + 0.4, 8, 6),
			Vector3.new(hx - 0.4, 8, -2),
			Vector3.new(6, 8, -hz + 0.4),
			Vector3.new(2, 8, hz - 0.4),
		}
		for i, off in spots do
			local lamp = mk(
				c.model,
				"PowerLamp" .. i,
				Vector3.new(0.8, 0.8, 0.8),
				CFrame.new(c.origin + off),
				LAMP_OFF,
				Enum.Material.SmoothPlastic
			)
			lamp.CanCollide = false
			lamp.Transparency = 0
			local l = Instance.new("PointLight")
			l.Color = Color3.fromRGB(255, 214, 160)
			l.Range = 16
			l.Brightness = 1.2
			l.Shadows = false
			l.Enabled = false
			l.Parent = lamp
			c.parts[lamp.Name] = lamp
		end
		-- M04 private breaker cabinet on the south wall, west of the workbench
		local layout = Puzzles.P03_LAYOUTS[if c.breaker then c.breaker.layout else 1]
		local cx = -8
		local cab = mk(
			c.model,
			"BreakerCabinet",
			Vector3.new(7, 5, 1),
			CFrame.new(c.origin + Vector3.new(cx, 2.5, -hz + 0.5)),
			STEEL,
			Enum.Material.Metal
		)
		c.parts.BreakerCabinet = cab
		local status = mk(
			c.model,
			"BreakerStatus",
			Vector3.new(0.6, 0.6, 0.3),
			CFrame.new(c.origin + Vector3.new(cx + 3, 5.3, -hz + 0.5)),
			Color3.fromRGB(150, 40, 30),
			Enum.Material.Neon
		)
		status.CanCollide = false
		c.parts.BreakerStatus = status
		for i, b in Puzzles.FUSE_BOXES do
			local x = cx - 2.2 + (i - 1) * 2.2
			local breaker = mk(
				c.model,
				"Breaker" .. b,
				Vector3.new(1, 1.6, 0.4),
				CFrame.new(c.origin + Vector3.new(x, 2.6, -hz + 1.2)),
				Color3.fromRGB(40, 40, 40),
				Enum.Material.SmoothPlastic
			)
			c.parts["Breaker" .. b] = breaker
			prompt(breaker, "Fit fuse", "Breaker " .. b, "breaker:" .. b)
			local tag = mk(
				c.model,
				"BreakerTag" .. b,
				Vector3.new(1.9, 1.1, 0.1),
				CFrame.lookAt(c.origin + Vector3.new(x, 4.1, -hz + 1.05), c.origin + Vector3.new(x, 4.1, 0)),
				Color3.fromRGB(214, 206, 180),
				Enum.Material.SmoothPlastic
			)
			tag.CanCollide = false
			c.labels["BreakerTag" .. b] = label(tag, Puzzles.fuseBoxText(layout, b, "BREAKER"))
		end
		local card = mk(
			c.model,
			"WiringCard",
			Vector3.new(7, 3.4, 0.1),
			CFrame.lookAt(c.origin + Vector3.new(cx, 7.4, -hz + 0.1), c.origin + Vector3.new(cx, 7.4, 0)),
			Color3.fromRGB(220, 214, 192),
			Enum.Material.SmoothPlastic
		)
		card.CanCollide = false
		c.labels.WiringCard = label(card, Puzzles.fuseCardText(layout, "CIRCUIT"))
	end,
}

local FUNCTIONAL_APPLY: { [string]: (Cell, boolean) -> () } = {
	workbench = function(cell, on)
		local p = cell.parts.Workbench
		if p then
			show(p, on)
			p.CanCollide = on
			local pp = p:FindFirstChildOfClass("ProximityPrompt")
			if pp then
				pp.Enabled = on
			end
		end
	end,
	supply_shelves = function(cell, on)
		local p = cell.parts.Shelves
		if p then
			show(p, on)
			p.CanCollide = on
		end
	end,
	better_lighting = function(cell, on)
		local lamp = cell.parts.Lamp and cell.parts.Lamp:FindFirstChildOfClass("PointLight")
		if lamp then
			lamp.Brightness = if on then 1.6 else 0.5
			lamp.Range = if on then 22 else 12
		end
	end,
	station_power = function(cell, on)
		for _, lamp in powerLampsOf(cell) do
			lamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
			lamp.Color = if on then LAMP_ON else LAMP_OFF
			local l = lamp:FindFirstChildOfClass("PointLight")
			if l then
				l.Enabled = on
			end
		end
		local status = cell.parts.BreakerStatus
		if status then
			status.Color = if on then Color3.fromRGB(70, 170, 90) else Color3.fromRGB(150, 40, 30)
		end
		local card = cell.labels.WiringCard
		if card and cell.breaker then
			local layout = Puzzles.P03_LAYOUTS[cell.breaker.layout]
			card.Text = if on then "WIRING CARD\nSTATION SUPPLY RESTORED" else Puzzles.fuseCardText(layout, "CIRCUIT")
		end
		for _, b in Puzzles.FUSE_BOXES do
			local p = cell.parts["Breaker" .. b]
			local pp = p and p:FindFirstChildOfClass("ProximityPrompt")
			if pp then
				pp.Enabled = not on
			end
		end
	end,
}

-- Entrance and functional visuals from the cell's party union (data-driven; no shelter-specific ids).
local function refreshCellVisuals(cell: Cell)
	local def = shelterDef(cell.shelterId)
	if not def or cell.model.Parent == nil then
		return
	end
	local map = occupantsMap(cell)
	local p = cell.parts
	for i, e in def.entrances do
		local look = Shelters.entranceLook(Shelters.stage(map, def.id, e.requiredUpgrade), e.requiredStage)
		show(p["Ent" .. i .. "Open"], look == "open")
		show(p["Ent" .. i .. "Patched"], look == "patched")
		show(p["Ent" .. i .. "Secured"], look == "secured")
		show(p["Ent" .. i .. "Bar"], look == "secured")
	end
	for id, on in Shelters.functionalVisuals(def, map) do
		local apply = FUNCTIONAL_APPLY[id]
		if apply then
			apply(cell, on)
		end
	end
	cell.model:SetAttribute("Fortification", Shelters.fortification(def, map))
end

local function buildCell(index: number, shelterId: string, key: string): Cell
	local def = assert(shelterDef(shelterId), "unknown shelter " .. shelterId)
	local o = Config.Shelter.interiorCellOrigin
	local origin = Vector3.new(
		o.x + (index % 20) * Config.Shelter.interiorCellSpacing,
		o.y,
		o.z + math.floor(index / 20) * Config.Shelter.interiorCellSpacing
	)
	local model = Instance.new("Model")
	model.Name = "Cell_" .. index
	local theme = themeOf(def)
	local parts: { [string]: BasePart } = {}
	local labels: { [string]: TextLabel } = {}
	local hx, hz = ROOM.X / 2, ROOM.Z / 2
	mk(
		model,
		"Floor",
		Vector3.new(ROOM.X + 4, 1, ROOM.Z + 4),
		CFrame.new(origin + Vector3.new(0, -0.5, 0)),
		Color3.fromRGB(120, 112, 98),
		theme.floor
	)
	mk(
		model,
		"Ceiling",
		Vector3.new(ROOM.X + 4, 2, ROOM.Z + 4),
		CFrame.new(origin + Vector3.new(0, ROOM.Y + 1, 0)),
		theme.wall,
		theme.material
	)
	mk(
		model,
		"WallN",
		Vector3.new(ROOM.X + 4, ROOM.Y, 2),
		CFrame.new(origin + Vector3.new(0, ROOM.Y / 2, hz + 1)),
		theme.wall,
		theme.material
	)
	mk(
		model,
		"WallS",
		Vector3.new(ROOM.X + 4, ROOM.Y, 2),
		CFrame.new(origin + Vector3.new(0, ROOM.Y / 2, -hz - 1)),
		theme.wall,
		theme.material
	)
	mk(
		model,
		"WallE",
		Vector3.new(2, ROOM.Y, ROOM.Z),
		CFrame.new(origin + Vector3.new(hx + 1, ROOM.Y / 2, 0)),
		theme.wall,
		theme.material
	)
	mk(
		model,
		"WallW",
		Vector3.new(2, ROOM.Y, ROOM.Z),
		CFrame.new(origin + Vector3.new(-hx - 1, ROOM.Y / 2, 0)),
		theme.wall,
		theme.material
	)
	local decor = FAMILY_DECOR[def.family]
	if decor then
		decor(model, origin)
	end
	-- Entrances. The physical room is always closed; these visuals show each entrance's fortification state and
	-- where the vulnerabilities are. entrances[i] sits at Shelters.ENTRANCE_SLOTS[i].
	for i in def.entrances do
		local slot = Shelters.ENTRANCE_SLOTS[i]
		if not slot then
			continue -- reported by Shelters.validate at start; the entrance still counts for fortification
		end
		local ef = slotFrame(origin, slot)
		local w = slot.width
		local open = mk(
			model,
			"Ent" .. i .. "Open",
			Vector3.new(w * 0.6, 7, 0.3),
			ef,
			Color3.fromRGB(10, 10, 10),
			Enum.Material.SmoothPlastic
		)
		local patched = mk(
			model,
			"Ent" .. i .. "Patched",
			Vector3.new(w, 8, 0.5),
			ef * CFrame.new(0, 0, -0.3),
			WOOD,
			Enum.Material.WoodPlanks
		)
		local secured = mk(
			model,
			"Ent" .. i .. "Secured",
			Vector3.new(w, 8.5, 0.6),
			ef * CFrame.new(0, 0, -0.5),
			RUST,
			Enum.Material.DiamondPlate
		)
		local bar = mk(
			model,
			"Ent" .. i .. "Bar",
			Vector3.new(w + 2, 0.8, 0.6),
			ef * CFrame.new(0, 0, -1),
			WOOD,
			Enum.Material.Wood
		)
		for _, part in { open, patched, secured, bar } do
			part.CanCollide = false
			parts[part.Name] = part
		end
	end
	-- Furniture and interaction points every shelter has
	local exit = mk(
		model,
		"ExitDoor",
		Vector3.new(1, 8, 5),
		CFrame.new(origin.X - hx + 1.5, origin.Y + 4, origin.Z - 7),
		WOOD,
		Enum.Material.WoodPlanks
	)
	prompt(exit, "Leave shelter", def.name, "exit")
	local storage = mk(
		model,
		"Storage",
		Vector3.new(5, 3, 3),
		CFrame.new(origin.X + hx - 3.5, origin.Y + 1.5, origin.Z - hz + 2.5),
		WOOD,
		Enum.Material.WoodPlanks
	)
	prompt(storage, "Open", "Shelter storage & escrow", "panel")
	local board = mk(
		model,
		"Board",
		Vector3.new(0.4, 4, 6),
		CFrame.new(origin.X + hx - 0.4, origin.Y + 5, origin.Z + 4),
		WOOD,
		Enum.Material.WoodPlanks
	)
	prompt(board, "Open", "Shelter works & missions", "panel")
	mk(
		model,
		"Cot",
		Vector3.new(7, 1.4, 3.5),
		CFrame.new(origin.X - 4, origin.Y + 0.7, origin.Z + hz - 3),
		Color3.fromRGB(90, 96, 80),
		Enum.Material.Fabric
	)
	local lamp = mk(
		model,
		"Lamp",
		Vector3.new(0.8, 1.2, 0.8),
		CFrame.new(origin.X, origin.Y + ROOM.Y - 1, origin.Z),
		Color3.fromRGB(255, 220, 160),
		Enum.Material.Neon
	)
	lamp.CanCollide = false
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 214, 160)
	pl.Shadows = true
	pl.Brightness = 0.5
	pl.Range = 12
	pl.Parent = lamp
	parts.Lamp = lamp
	-- Functional upgrade props for whatever this shelter defines
	local breaker = if def.functionalUpgrades[POWER] then Puzzles.newP03(math.random(1, #Puzzles.P03_LAYOUTS)) else nil
	local ctx: BuildCtx = { model = model, origin = origin, parts = parts, labels = labels, breaker = breaker }
	for id in def.functionalUpgrades do
		local build = FUNCTIONAL_BUILD[id]
		if build then
			build(ctx)
		end
	end
	model.Parent = services.WorldBuilder.root():WaitForChild("ShelterInteriors")
	local cell: Cell = {
		key = key,
		index = index,
		shelterId = shelterId,
		model = model,
		origin = origin,
		occupants = {},
		pending = {},
		parts = parts,
		labels = labels,
		lastProbe = os.clock(),
		breaker = breaker,
	}
	for _, d in model:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d.Triggered:Connect(function(player)
				if not cell.occupants[player] then
					return
				end
				local a = d:GetAttribute("ShelterAction")
				if a == "exit" then
					ShelterService.exit(player)
				elseif a == "panel" then
					ShelterService.pushPanel(player)
				elseif type(a) == "string" and string.sub(a, 1, 8) == "breaker:" then
					ShelterService.fixBreaker(player, string.sub(a, 9))
				end
			end)
		end
	end
	return cell
end

local function getCellByKey(key: string, shelterId: string): Cell
	local c = cells[key]
	if c then
		return c
	end
	local idx = table.remove(freeIndices) or nextIndex
	if idx == nextIndex then
		nextIndex += 1
	end
	local built = buildCell(idx, shelterId, key)
	cells[key] = built
	return built
end

local function getCell(player: Player, shelterId: string): Cell
	return getCellByKey(keyFor(player, shelterId), shelterId)
end

local function releaseIfEmpty(cell: Cell)
	if next(cell.occupants) ~= nil or next(cell.pending) ~= nil or cells[cell.key] ~= cell then
		return
	end
	cells[cell.key] = nil
	table.insert(freeIndices, cell.index)
	cell.model:Destroy()
end

local function cellOf(player: Player): Cell?
	for _, c in cells do
		if c.occupants[player] then
			return c
		end
	end
	return nil
end

-- PROPOSED: stream passes before placement stops waiting for the target to settle (see placeInside).
local PLACE_PASSES = 4

-- The cell that should hold this player now: `cell` while it still carries their current group's key, otherwise that
-- group's cell (built if needed).
local function currentCell(player: Player, cell: Cell): Cell
	local want = keyFor(player, cell.shelterId)
	if cell.key == want and cells[want] == cell then
		return cell
	end
	return getCellByKey(want, cell.shelterId)
end

-- Streams the cell in, then teleports the player into it. Every cell streamed on the way stays reserved (pending)
-- until the player has landed, so none is released under the arriving player (or under one still standing in it
-- during a regroup move). A party change during a stream yield can re-key or replace the target (regroupAll only sees
-- occupants, not pending players), so the player's own cell is re-resolved after every stream and occupancy is
-- committed only to a cell carrying their current key (F11, D68). If the party keeps changing for PLACE_PASSES
-- streams, the player still goes to their current group's cell, without waiting for one more stream.
local function placeInside(player: Player, cell: Cell)
	local reserved: { Cell } = {}
	for _ = 1, PLACE_PASSES do
		cell.pending[player] = true
		table.insert(reserved, cell)
		pcall(function()
			player:RequestStreamAroundAsync(cell.origin, 5)
		end)
		if gone[player] or player.Parent == nil or not services.PlayerService.get(player) then
			break
		end
		local now = currentCell(player, cell)
		if now == cell then
			break
		end
		cell = now
	end
	local function unreserve()
		for _, c in reserved do
			c.pending[player] = nil
		end
		for _, c in reserved do
			releaseIfEmpty(c)
		end
	end
	local r = services.PlayerService.rootPart(player)
	local s = services.PlayerService.get(player)
	if not r or not s or gone[player] or player.Parent == nil or cell.model.Parent == nil then
		unreserve()
		releaseIfEmpty(cell)
		return
	end
	cell = currentCell(player, cell) -- no yield from here to the commit
	local old = cellOf(player)
	if old and old ~= cell then
		old.occupants[player] = nil
		releaseIfEmpty(old)
	end
	local a = Shelters.ARRIVAL
	r.CFrame = CFrame.new(cell.origin + Vector3.new(a.x, a.y, a.z)) * CFrame.Angles(0, -math.pi / 2, 0)
	cell.occupants[player] = true
	s.insideShelterId = cell.shelterId
	s.dirtyState = true
	unreserve()
	refreshCellVisuals(cell)
end

-- Registration + banking for one player arriving inside (section 15: explicit secure-inventory transaction).
-- Returns (banked contents, whether the last shelter changed).
local function register(player: Player, s: any, def: WorldDefs.ShelterDef): ({ [string]: number }, boolean)
	local changedLast = s.profile.lastShelterId ~= def.id
	s.profile.lastShelterId = def.id
	if not s.profile.discoveries["shelter:" .. def.id] then
		services.DiscoveryService.discover(player, "shelter:" .. def.id, def.name)
	end
	local banked = Inventory.bank(s.profile.inventory)
	s.profile.checkpoint = nil
	-- Field experience for registering this shelter, once per player (grantXp is idempotent by key; D37). Skipped
	-- when the profile already records the key as paid, so re-entering never re-calls it.
	local xpKey = "shelter:" .. def.id
	local prog = s.profile.progression
	if not (type(prog) == "table" and type(prog.awarded) == "table" and prog.awarded[xpKey]) then
		safeCall("PlayerService", "grantXp", player, xpKey, Config.Progression.xp.shelter)
	end
	services.SaveService.markDirty(player)
	return banked, changedLast
end

-- Durable save, then the banking notice (never claims "Saved" before the commit returns).
local function announceRegistration(
	player: Player,
	def: WorldDefs.ShelterDef,
	banked: { [string]: number },
	changedLast: boolean
)
	task.spawn(function()
		local ok = services.SaveService.commit(player)
		local n = 0
		for _, c in banked do
			n += c
		end
		if n > 0 then
			services.PlayerService.notify(
				player,
				if ok
					then string.format("Banked %d expedition item(s). Saved.", n)
					else string.format("Banked %d item(s) in this session, but saving failed. It will retry.", n),
				if ok then "info" else "warn"
			)
		elseif changedLast then
			services.PlayerService.notify(player, def.name .. " registered as your last shelter.", "info")
		end
		services.PlayerService.pushInventory(player)
	end)
end

-- Everything an arriving player goes through once the door checks pass.
local function admit(player: Player, s: any, def: WorldDefs.ShelterDef)
	services.PlayerService.unhide(player)
	local banked, changedLast = register(player, s, def)
	-- Carried rescue target / downed teammate come inside too.
	local carrying = s.carrying
	if carrying and carrying.kind == "npc" then
		services.MissionService.deliverToShelter(player, carrying.target)
	elseif carrying and carrying.kind == "player" then
		local t = carrying.target :: Player
		services.PlayerService.dropCarry(player)
		local ts = services.PlayerService.get(t)
		if ts and not ts.insideShelterId then
			if ts.vitals.condition == "downed" then
				Vitals.revive(Config.Health, ts.vitals)
			end
			-- The carried teammate is processed like any entrant: registered, banked and saved (they are inside, so a
			-- later logout creates no bag and their loot must already be banked).
			local tBanked, tChanged = register(t, ts, def)
			safeCall("MissionService", "onShelterReached", t)
			placeInside(t, getCell(player, def.id))
			announceRegistration(t, def, tBanked, tChanged)
			ShelterService.pushPanel(t)
		end
	end
	services.MissionService.onShelterReached(player)
	placeInside(player, getCell(player, def.id))
	announceRegistration(player, def, banked, changedLast)
	safeCall("StoryService", "onFact", player)
	ShelterService.pushPanel(player)
end

function ShelterService.enter(player: Player, shelterId: string)
	local s = services.PlayerService.get(player)
	local def = shelterDef(shelterId)
	if not s or not def or s.insideShelterId or entering[player] then
		return
	end
	local pos = services.PlayerService.position(player)
	local door = services.WorldBuilder.shelterDoor(shelterId)
	if not pos or (pos - door).Magnitude > 22 then
		return
	end
	if s.vitals.condition == "downed" then
		services.PlayerService.notify(player, "You cannot open the gate while down.", "warn")
		return
	end
	if not services.PlayerService.canAct(player) then
		return -- dead (waiting to respawn) or being carried: a carrier brings a teammate in
	end
	-- One entry at a time per player (the stream-in yields); the guard is always cleared, even if a step errors.
	entering[player] = true
	xpcall(admit, function(err)
		warn("[ShelterService] enter failed: " .. debug.traceback(tostring(err)))
	end, player, s, def)
	entering[player] = nil
end

function ShelterService.exit(player: Player)
	local cell = cellOf(player)
	local s = services.PlayerService.get(player)
	if not cell or not s then
		return
	end
	-- A carried teammate is welded to the carrier, so teleporting either root moves both while only the caller leaves
	-- the cell's occupancy: the other would walk the tunnels still flagged as inside. PROPOSED: neither may leave
	-- mid-carry (the carrier sets the teammate down first; they stay inside, flagged correctly), and a downed player
	-- cannot open the door, as on entry.
	if s.carrying and s.carrying.kind == "player" then
		services.PlayerService.notify(
			player,
			"Set your teammate down before you leave. They stay in the shelter, where you can treat them.",
			"warn"
		)
		return
	end
	if not able(s) then -- downed, carried or dead
		services.PlayerService.notify(player, "You cannot open the door while down.", "warn")
		return
	end
	cell.occupants[player] = nil
	cell.pending[player] = true -- still standing in the cell until the teleport lands
	s.insideShelterId = nil
	s.dirtyState = true
	local _, stand = services.WorldBuilder.shelterDoor(cell.shelterId)
	local r = services.PlayerService.rootPart(player)
	if r then
		pcall(function()
			player:RequestStreamAroundAsync(stand.Position, 5)
		end)
		r.CFrame = stand
	end
	cell.pending[player] = nil
	services.PlayerService.send(player, "shelterPanel", { open = false })
	releaseIfEmpty(cell)
end

-- On (re)spawn: resume inside the last shelter if it is a real shelter.
function ShelterService.onSpawn(player: Player)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local old = cellOf(player)
	if old then
		old.occupants[player] = nil
		s.insideShelterId = nil
		releaseIfEmpty(old)
	end
	if shelterDef(s.profile.lastShelterId) then
		placeInside(player, getCell(player, s.profile.lastShelterId))
	end
end

-- T12: a fully secured shelter blocks all creature damage. Unsecured interiors are "relatively safe": only the
-- probe event at an unprotected entrance can hurt someone standing right at it.
function ShelterService.canBeDamaged(player: Player): boolean
	local cell = cellOf(player)
	if not cell then
		return true
	end
	local def = shelterDef(cell.shelterId)
	return def == nil or not Shelters.isSecured(def, occupantsMap(cell))
end

function ShelterService.isInside(player: Player): boolean
	return cellOf(player) ~= nil
end

local function classNames(): { string }
	local out = {}
	for name in Config.Classes :: any do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- quiet: refresh for another occupant (their screen is not opened over whatever they are doing; D88).
function ShelterService.pushPanel(player: Player, quiet: boolean?)
	local s = services.PlayerService.get(player)
	local cell = cellOf(player)
	if not s or not cell then
		return
	end
	local def = shelterDef(cell.shelterId)
	if not def then
		return
	end
	local shared = occupantsMap(cell)
	local own = s.profile.shelterUpgrades
	local ups = {}
	local groups: { [string]: { [string]: any } } = { safety = def.safetyUpgrades, functional = def.functionalUpgrades }
	for kindName, group in groups do
		for id, u in group do
			local cost, nextStage = Shelters.nextCost(def, shared, id)
			-- Grant-only rows (station_power) keep their cost as information but can never be bought here.
			local lockReason = if cost and not Shelters.isPurchasable(def, id) then Shelters.GRANT_ONLY[id] else nil
			table.insert(ups, {
				id = id,
				kind = kindName,
				stage = Shelters.stage(shared, def.id, id),
				ownStage = Shelters.stage(own, def.id, id),
				maxStage = u.maxStage,
				nextStage = nextStage,
				cost = cost,
				affordable = lockReason == nil and cost ~= nil and Inventory.hasAll(s.profile.inventory, cost),
				locked = lockReason ~= nil,
				lockReason = lockReason,
			})
		end
	end
	table.sort(ups, function(a, b)
		return a.id < b.id
	end)
	local atBench = Shelters.stage(shared, def.id, "workbench") >= 1
	local recipes = {}
	for _, r in Commerce.RECIPES do
		local pv = Commerce.preview(s.profile.inventory, ItemDefs.get, r, atBench)
		local out = ItemDefs.get(r.output)
		table.insert(recipes, {
			id = r.id,
			output = if out then out.displayName else r.output,
			outputCount = r.outputCount,
			inputs = r.inputs,
			missing = pv.missing,
			canCraft = pv.canCraft,
			requiresWorkbench = r.requiresWorkbench,
		})
	end
	local entrances = {}
	for _, e in def.entrances do
		table.insert(
			entrances,
			{ id = e.id, protected = Shelters.stage(shared, def.id, e.requiredUpgrade) >= e.requiredStage }
		)
	end
	services.PlayerService.send(player, "shelterPanel", {
		open = true,
		quiet = quiet == true,
		name = def.name,
		fortification = Shelters.fortification(def, shared),
		entrances = entrances,
		upgrades = ups,
		recipes = recipes,
		escrow = s.profile.escrow,
		class = s.profile.class,
		classes = classNames(),
		classCost = Config.ClassChangeCoinCost,
		coins = s.profile.coins,
		passiveCap = Config.Health.passiveRecoveryCapFraction,
	})
end

function ShelterService.upgrade(player: Player, upgradeId: string)
	local s = services.PlayerService.get(player)
	local cell = cellOf(player)
	if not s or not cell or type(upgradeId) ~= "string" then
		return
	end
	local def = shelterDef(cell.shelterId)
	if not def then
		return
	end
	local lockReason = Shelters.GRANT_ONLY[upgradeId]
	if lockReason then
		services.PlayerService.notify(player, lockReason, "info")
		return
	end
	local cost, nextStage = Shelters.purchaseCost(def, occupantsMap(cell), upgradeId)
	if not cost or not nextStage then
		return
	end
	if not Inventory.hasAll(s.profile.inventory, cost) then
		services.PlayerService.notify(player, "Not enough materials.", "warn")
		return
	end
	local cls: any = Config.Classes[s.profile.class]
	local secs = 3 * ((cls and cls.repairTimeMultiplier) or 1)
	if not services.PlayerService.hold(player, secs) then
		return
	end
	-- Re-validate after the hold: the player may have left, or a party member may have built this stage meanwhile
	-- (then nothing is charged).
	if cellOf(player) ~= cell or services.PlayerService.get(player) ~= s then
		return
	end
	local shared = occupantsMap(cell)
	local cost2, stage2 = Shelters.purchaseCost(def, shared, upgradeId)
	if not cost2 or stage2 ~= nextStage then
		services.PlayerService.notify(
			player,
			"That improvement was finished while you worked. Nothing was used.",
			"info"
		)
		ShelterService.pushPanel(player)
		return
	end
	if not Inventory.hasAll(s.profile.inventory, cost2) then
		services.PlayerService.notify(player, "Not enough materials.", "warn")
		return
	end
	for id, n in cost2 do
		Inventory.remove(s.profile.inventory, id, n)
	end
	-- The buyer first inherits the current shared map, then raises one stage (never a sum).
	Shelters.inherit(s.profile.shelterUpgrades, shared)
	Shelters.raise(s.profile.shelterUpgrades, def.id, upgradeId, nextStage)
	services.PartyService.propagateUpgrades(player)
	services.SaveService.markDirty(player)
	task.spawn(services.SaveService.commit, player)
	refreshCellVisuals(cell)
	services.PlayerService.pushInventory(player)
	for p in cell.occupants do
		ShelterService.pushPanel(p, p ~= player)
	end
	if Shelters.isSecured(def, s.profile.shelterUpgrades) then
		services.PlayerService.notify(
			player,
			def.name .. " is fully secured. Creatures cannot enter or harm anyone inside.",
			"info"
		)
	end
	safeCall("StoryService", "onFact", player)
end

function ShelterService.craft(player: Player, recipeId: string)
	local s = services.PlayerService.get(player)
	local cell = cellOf(player)
	local recipe = type(recipeId) == "string" and Commerce.recipe(recipeId) or nil
	if not s or not cell or not recipe then
		return
	end
	local atBench = Shelters.stage(occupantsMap(cell), cell.shelterId, "workbench") >= 1
	local pv = Commerce.preview(s.profile.inventory, ItemDefs.get, recipe, atBench)
	if not pv.canCraft then
		services.PlayerService.notify(player, "Cannot craft that yet.", "warn")
		return
	end
	local cls: any = Config.Classes[s.profile.class]
	local secs = recipe.seconds * ((cls and cls.craftTimeMultiplier) or 1)
	if not services.PlayerService.hold(player, secs) then
		return
	end
	if cellOf(player) ~= cell or services.PlayerService.get(player) ~= s then
		return
	end
	local ok, why = Commerce.craft(s.profile.inventory, ItemDefs.get, recipe, atBench)
	if not ok then
		services.PlayerService.notify(player, "Crafting failed: " .. tostring(why), "warn")
		return
	end
	services.SaveService.markDirty(player)
	task.spawn(services.SaveService.commit, player) -- crafted output is permanent loadout (D19)
	services.PlayerService.pushInventory(player)
	ShelterService.pushPanel(player)
end

function ShelterService.changeClass(player: Player, className: string)
	local s = services.PlayerService.get(player)
	if not s or not cellOf(player) or not Config.Classes[className] or s.profile.class == className then
		return
	end
	if s.profile.coins < Config.ClassChangeCoinCost then
		services.PlayerService.notify(
			player,
			string.format("Changing class costs %d earned coins.", Config.ClassChangeCoinCost),
			"warn"
		)
		return
	end
	s.profile.coins -= Config.ClassChangeCoinCost
	s.profile.class = className
	services.SaveService.markDirty(player)
	task.spawn(services.SaveService.commit, player)
	services.PlayerService.pushInventory(player)
	ShelterService.pushPanel(player)
end

-- M04 private breaker (inside the player's or party's own interior). A private P03 layout per cell: the wiring
-- card names the dead circuit and every terminal's conduit tag; each breaker shows its own tag. Needs a repair tool
-- roll (kept) and uses one fuse kit on the right breaker only. A wrong breaker costs time, never health.
-- Success grants station_power stage 1 to the acting player exactly like a purchase would (inherit the party union,
-- raise, then the existing PartyService.propagateUpgrades path) and records storyStates["M04.Sxx"].
function ShelterService.fixBreaker(player: Player, breakerLabel: string)
	local s = services.PlayerService.get(player)
	local cell = cellOf(player)
	if not s or not cell or not cell.breaker or not able(s) then
		return
	end
	local def = shelterDef(cell.shelterId)
	if not def or not def.functionalUpgrades[POWER] or not table.find(Puzzles.FUSE_BOXES, breakerLabel) then
		return
	end
	if Shelters.stage(occupantsMap(cell), def.id, POWER) >= 1 then
		services.PlayerService.notify(player, "The station supply is already running here.", "info")
		return
	end
	local inv = s.profile.inventory
	local missing =
		Puzzles.fuseMissing(Inventory.count(inv, Puzzles.REPAIR_ROLL), Inventory.count(inv, Puzzles.FUSE_KIT))
	if #missing > 0 then
		services.PlayerService.notify(player, Puzzles.fuseMissingText(missing), "warn")
		return
	end
	local cls: any = Config.Classes[s.profile.class]
	local secs = Config.Puzzles.fuseInsertSeconds * ((cls and cls.repairTimeMultiplier) or 1)
	if not services.PlayerService.hold(player, secs) then
		return
	end
	-- Re-validate after the hold.
	if cellOf(player) ~= cell or services.PlayerService.get(player) ~= s or not cell.breaker then
		return
	end
	if Shelters.stage(occupantsMap(cell), def.id, POWER) >= 1 then
		services.PlayerService.notify(player, "The station supply came back while you worked. Your fuse kit is unused.")
		return
	end
	local result = Puzzles.insertFuse(
		cell.breaker,
		breakerLabel,
		Inventory.count(inv, Puzzles.REPAIR_ROLL),
		Inventory.count(inv, Puzzles.FUSE_KIT),
		Config.Puzzles.fuseWrongBoxSeconds,
		os.clock()
	)
	local part = cell.parts["Breaker" .. breakerLabel]
	local where = if part then part.Position else cell.origin
	if result.outcome == "missing" then
		services.PlayerService.notify(player, Puzzles.fuseMissingText(result.missing), "warn")
		return
	elseif result.outcome == "already" then
		-- the layout was solved but the upgrade is missing (should not happen): re-arm so it can be repaired again
		cell.breaker.powered = false
		return
	elseif result.outcome == "wrong" then
		-- the time cost: pulling the fuse back out of the wrong breaker (cancelling only ends it early)
		services.PlayerService.hold(player, result.delaySeconds)
		services.PlayerService.send(player, "cue", { id = "fuse_spark", position = where })
		services.PlayerService.notify(
			player,
			string.format(
				"Breaker %s sparks and the fuse pops back out: that breaker is not on the dead circuit. Your fuse kit is returned.",
				breakerLabel
			),
			"warn"
		)
		return
	end
	-- Right breaker: one fuse kit is used, the repair tool roll is kept.
	Inventory.remove(inv, Puzzles.FUSE_KIT, result.fusesConsumed)
	Shelters.inherit(s.profile.shelterUpgrades, occupantsMap(cell))
	Shelters.raise(s.profile.shelterUpgrades, def.id, POWER, 1)
	s.profile.storyStates["M04." .. (string.match(def.id, "^(S%d+)") or def.id)] = "1"
	services.PartyService.propagateUpgrades(player)
	services.SaveService.markDirty(player)
	refreshCellVisuals(cell)
	services.PlayerService.pushInventory(player)
	for p in cell.occupants do
		services.PlayerService.send(p, "cue", { id = "power_restored", position = where })
		ShelterService.pushPanel(p, p ~= player)
	end
	safeCall("StoryService", "onFact", player)
	task.spawn(function()
		local ok = services.SaveService.commit(player)
		services.PlayerService.notify(
			player,
			if ok
				then "Station supply restored. The lights hold — this office now has power. Saved."
				else "Station supply restored, but saving failed. It will retry.",
			if ok then "info" else "warn"
		)
	end)
end

-- Party membership changed. Occupants whose group changed are regrouped (Shelters.regroup) so nobody shares a cell
-- with a non-member (F11, T11) and no buyer inherits an outsider's stages (F13). A cell whose own group has gone is
-- re-keyed to its remaining group instead of teleporting anyone; everyone else moves to their group's cell.
local function regroupAll()
	local snapshot = {}
	for _, cell in cells do
		table.insert(snapshot, cell)
	end
	for _, cell in snapshot do
		if cells[cell.key] ~= cell then
			continue
		end
		local keys: { [any]: string } = {}
		for p in cell.occupants do
			if services.PlayerService.get(p) and not gone[p] and p.Parent ~= nil then
				keys[p] = keyFor(p, cell.shelterId)
			end
		end
		local keep, moves = Shelters.regroup(cell.key, keys, function(k)
			return cells[k] ~= nil
		end)
		if keep ~= cell.key then
			cells[cell.key] = nil
			cell.key = keep
			cells[keep] = cell
		end
		for p, k in moves do
			local player = p :: Player
			local target = getCellByKey(k, cell.shelterId)
			cell.occupants[player] = nil
			cell.pending[player] = true -- still standing here until the teleport lands
			target.pending[player] = true -- reserved; placeInside clears it
			task.spawn(function()
				placeInside(player, target) -- may land in another cell if the party changed again meanwhile
				cell.pending[player] = nil
				releaseIfEmpty(cell)
				local now = cellOf(player)
				if now ~= nil and now ~= cell then
					services.PlayerService.notify(
						player,
						"Your group changed: you are now in your own group's shelter.",
						"info"
					)
					ShelterService.pushPanel(player)
				end
			end)
		end
	end
	for _, c in cells do
		refreshCellVisuals(c)
	end
end

-- Called synchronously from PartyService after every membership change: never let a failure here break party flows.
function ShelterService.onPartyChanged()
	xpcall(regroupAll, function(err)
		warn("[ShelterService] regroup failed: " .. debug.traceback(tostring(err)))
	end)
end

local function hookDoor(door: Instance)
	task.spawn(function()
		local pp = door:FindFirstChildOfClass("ProximityPrompt") or door:WaitForChild("ProximityPrompt", 10)
		if not pp or not pp:IsA("ProximityPrompt") or pp:GetAttribute("ShelterHooked") then
			return
		end
		pp:SetAttribute("ShelterHooked", true)
		pp.Triggered:Connect(function(player)
			local id = door:GetAttribute("ShelterId")
			if type(id) == "string" then
				ShelterService.enter(player, id)
			end
		end)
	end)
end

local function probeCell(cell: Cell)
	local def = shelterDef(cell.shelterId)
	if not def or next(cell.occupants) == nil then
		return
	end
	local map = occupantsMap(cell)
	if Shelters.isSecured(def, map) or os.clock() - cell.lastProbe < 60 then
		return
	end
	if math.random() > 0.25 then
		return
	end
	cell.lastProbe = os.clock()
	local spots: { Vector3 } = {}
	for i, e in def.entrances do
		local open = cell.parts["Ent" .. i .. "Open"]
		if open and Shelters.stage(map, def.id, e.requiredUpgrade) < e.requiredStage then
			table.insert(spots, open.Position)
		end
	end
	if #spots == 0 then
		return
	end
	local spot = spots[math.random(1, #spots)]
	for p in cell.occupants do
		services.PlayerService.send(p, "cue", { id = "shelter_probe", position = spot })
	end
	task.delay(2.5, function()
		for p in cell.occupants do
			local pos = services.PlayerService.position(p)
			if pos and (pos - spot).Magnitude < Shelters.PROBE_RADIUS then
				services.PlayerService.damage(p, 8, false, "shelter_probe")
			end
		end
	end)
end

function ShelterService.init(s)
	services = s
end

function ShelterService.start()
	for id, def in WorldDefs.Shelters do
		for _, problem in
			Shelters.validate(def, function(itemId)
				return ItemDefs.get(itemId) ~= nil
			end)
		do
			warn("[ShelterService] " .. problem)
		end
		for upId in def.functionalUpgrades do
			if not FUNCTIONAL_APPLY[upId] then
				warn("[ShelterService] " .. id .. ": no interior visual for " .. upId)
			end
		end
	end
	for _, door in CollectionService:GetTagged("ShelterDoor") do
		hookDoor(door)
	end
	CollectionService:GetInstanceAddedSignal("ShelterDoor"):Connect(hookDoor)
	Players.PlayerRemoving:Connect(function(player)
		gone[player] = true
		entering[player] = nil
		for _, c in table.clone(cells) do
			if c.occupants[player] or c.pending[player] then
				c.occupants[player] = nil
				c.pending[player] = nil
				releaseIfEmpty(c)
			end
		end
	end)
	-- Probe events at unprotected entrances of unsecured cells (section 13: initially relatively safe).
	task.spawn(function()
		while true do
			task.wait(5)
			for _, cell in table.clone(cells) do
				xpcall(probeCell, function(err)
					warn("[ShelterService] probe failed: " .. tostring(err))
				end, cell)
			end
		end
	end)
end

return ShelterService
