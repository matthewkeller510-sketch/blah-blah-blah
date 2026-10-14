--!strict
-- Shelters (section 13; owner rules F10, F11, F13). Public exterior, isolated private interior cells.
-- Each solo player or current party gets its own interior cell at unique far coordinates. Only occupants are
-- teleported there, so collision, AI and sound do not leak between groups. Upgrades are stored per player and
-- the cell shows the party's monotonic union.
-- Milestone 1 limitation: cells rely on distance + streaming to stay unreplicated to non-occupants; a stricter
-- per-player replication boundary (e.g. separate reserved server or per-client visuals) is PLANNED for review.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Shelters = require(Shared.Logic.Shelters)
local Commerce = require(Shared.Logic.Commerce)
local Vitals = require(Shared.Logic.Vitals)

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
	parts: { [string]: BasePart },
	lastProbe: number,
}

local cells: { [string]: Cell } = {}
local nextIndex = 0
local freeIndices: { number } = {}

local ROOM = Vector3.new(28, 12, 22)
local STONE = Color3.fromRGB(176, 166, 146)
local WOOD = Color3.fromRGB(92, 70, 48)
local RUST = Color3.fromRGB(110, 62, 38)

local function cellKey(player: Player): string
	local pid = services.PartyService.partyIdOf(player)
	return if pid then ("party:" .. pid) else ("solo:" .. player.UserId)
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
	local pid = string.match(cell.key, "^party:(.+)$")
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

local function shelterDef(id: string)
	return WorldDefs.Shelters[id]
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

local THEMES = {
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
}

-- Entrance visuals per stage: 0 = open vulnerability, partial = patched boards, >= required = solid and barred.
local function refreshCellVisuals(cell: Cell)
	local def = shelterDef(cell.shelterId)
	local map = occupantsMap(cell)
	local p = cell.parts
	for i, e in def.entrances do
		local st = Shelters.stage(map, def.id, e.requiredUpgrade)
		p["Ent" .. i .. "Open"].Transparency = if st == 0 then 0 else 1
		p["Ent" .. i .. "Patched"].Transparency = if st > 0 and st < e.requiredStage then 0 else 1
		p["Ent" .. i .. "Secured"].Transparency = if st >= e.requiredStage then 0 else 1
		p["Ent" .. i .. "Bar"].Transparency = if st >= e.requiredStage then 0 else 1
	end
	local bench = Shelters.stage(map, def.id, "workbench") >= 1
	p.Workbench.Transparency = if bench then 0 else 1
	p.Workbench.CanCollide = bench
	local shelves = Shelters.stage(map, def.id, "supply_shelves") >= 1
	p.Shelves.Transparency = if shelves then 0 else 1
	p.Shelves.CanCollide = shelves
	local lamp = p.Lamp:FindFirstChildOfClass("PointLight")
	if lamp then
		local better = Shelters.stage(map, def.id, "better_lighting") >= 1
		lamp.Brightness = if better then 1.6 else 0.5
		lamp.Range = if better then 22 else 12
	end
	cell.model:SetAttribute("Fortification", Shelters.fortification(def, map))
end

local function buildCell(index: number, shelterId: string, key: string): Cell
	local o = Config.Shelter.interiorCellOrigin
	local origin = Vector3.new(
		o.x + (index % 20) * Config.Shelter.interiorCellSpacing,
		o.y,
		o.z + math.floor(index / 20) * Config.Shelter.interiorCellSpacing
	)
	local model = Instance.new("Model")
	model.Name = "Cell_" .. index
	local def = shelterDef(shelterId)
	local theme = THEMES[def.theme] or THEMES.limestone
	local parts: { [string]: BasePart } = {}
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
	-- Entrances. The physical room is always closed; these visuals show each entrance's fortification state and
	-- where the vulnerabilities are. Entrance 1 is on the west wall, entrance 2 on the north wall.
	local entranceFrames = {
		CFrame.new(origin.X - hx + 0.6, origin.Y + 4.5, origin.Z) * CFrame.Angles(0, -math.pi / 2, 0), -- local -Z points into the room
		CFrame.new(origin.X + 6, origin.Y + 4, origin.Z + hz - 0.4),
	}
	for i, ef in entranceFrames do
		local w = if i == 1 then 8 else 4
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
	-- Furniture and interaction points
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
	parts.Workbench = mk(
		model,
		"Workbench",
		Vector3.new(6, 3, 3),
		CFrame.new(origin.X, origin.Y + 1.5, origin.Z - hz + 2.5),
		WOOD,
		Enum.Material.WoodPlanks
	)
	prompt(parts.Workbench, "Craft", "Workbench", "panel")
	parts.Shelves = mk(
		model,
		"Shelves",
		Vector3.new(2, 6, 7),
		CFrame.new(origin.X + hx - 1.5, origin.Y + 3, origin.Z - 4),
		WOOD,
		Enum.Material.WoodPlanks
	)
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
	pl.Parent = lamp
	parts.Lamp = lamp
	model.Parent = services.WorldBuilder.root():WaitForChild("ShelterInteriors")
	local cell: Cell = {
		key = key,
		index = index,
		shelterId = shelterId,
		model = model,
		origin = origin,
		occupants = {},
		parts = parts,
		lastProbe = os.clock(),
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
				end
			end)
		end
	end
	return cell
end

local function getCell(player: Player, shelterId: string): Cell
	local key = cellKey(player) .. "@" .. shelterId
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

local function releaseIfEmpty(cell: Cell)
	if next(cell.occupants) == nil then
		cells[cell.key] = nil
		table.insert(freeIndices, cell.index)
		cell.model:Destroy()
	end
end

local function cellOf(player: Player): Cell?
	for _, c in cells do
		if c.occupants[player] then
			return c
		end
	end
	return nil
end

local function placeInside(player: Player, cell: Cell)
	local r = services.PlayerService.rootPart(player)
	if not r then
		return
	end
	pcall(function()
		player:RequestStreamAroundAsync(cell.origin, 5)
	end)
	r.CFrame = CFrame.new(cell.origin + Vector3.new(-ROOM.X / 2 + 5, 3, 0)) * CFrame.Angles(0, -math.pi / 2, 0)
	cell.occupants[player] = true
	local s = services.PlayerService.get(player)
	if s then
		s.insideShelterId = cell.shelterId
		s.dirtyState = true
	end
	refreshCellVisuals(cell)
end

-- Registration + banking happen on entry (section 15: explicit secure-inventory transaction).
function ShelterService.enter(player: Player, shelterId: string)
	local s = services.PlayerService.get(player)
	local def = shelterDef(shelterId)
	if not s or not def or s.insideShelterId then
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
	services.PlayerService.unhide(player)
	local firstTime = s.profile.lastShelterId ~= shelterId
	s.profile.lastShelterId = shelterId
	if not s.profile.discoveries["shelter:" .. shelterId] then
		services.DiscoveryService.discover(player, "shelter:" .. shelterId, def.name)
	end
	local banked = Inventory.bank(s.profile.inventory)
	s.profile.checkpoint = nil
	-- Carried rescue target / downed teammate come inside too.
	local carrying = s.carrying
	if carrying and carrying.kind == "npc" then
		services.MissionService.deliverToShelter(player, carrying.target)
	elseif carrying and carrying.kind == "player" then
		local t = carrying.target :: Player
		services.PlayerService.dropCarry(player)
		local ts = services.PlayerService.get(t)
		if ts and ts.vitals.condition == "downed" then
			Vitals.revive(Config.Health, ts.vitals)
		end
		local cell = getCell(player, shelterId)
		placeInside(t, cell)
	end
	services.MissionService.onShelterReached(player)
	local cell = getCell(player, shelterId)
	placeInside(player, cell)
	services.SaveService.markDirty(player)
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
		elseif firstTime then
			services.PlayerService.notify(player, def.name .. " registered as your last shelter.", "info")
		end
		services.PlayerService.pushInventory(player)
	end)
	ShelterService.pushPanel(player)
end

function ShelterService.exit(player: Player)
	local cell = cellOf(player)
	local s = services.PlayerService.get(player)
	if not cell or not s then
		return
	end
	cell.occupants[player] = nil
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
		releaseIfEmpty(old)
		s.insideShelterId = nil
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
	return not Shelters.isSecured(def, occupantsMap(cell))
end

function ShelterService.isInside(player: Player): boolean
	return cellOf(player) ~= nil
end

function ShelterService.pushPanel(player: Player)
	local s = services.PlayerService.get(player)
	local cell = cellOf(player)
	if not s or not cell then
		return
	end
	local def = shelterDef(cell.shelterId)
	local shared = occupantsMap(cell)
	local own = s.profile.shelterUpgrades
	local ups = {}
	local groups: { [string]: { [string]: any } } = { safety = def.safetyUpgrades, functional = def.functionalUpgrades }
	for kindName, group in groups do
		for id, u in group do
			local cost, nextStage = Shelters.nextCost(def, shared, id)
			table.insert(ups, {
				id = id,
				kind = kindName,
				stage = Shelters.stage(shared, def.id, id),
				ownStage = Shelters.stage(own, def.id, id),
				maxStage = u.maxStage,
				nextStage = nextStage,
				cost = cost,
				affordable = cost ~= nil and Inventory.hasAll(s.profile.inventory, cost),
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
		table.insert(recipes, {
			id = r.id,
			output = (ItemDefs.get(r.output) :: any).displayName,
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
		name = def.name,
		fortification = Shelters.fortification(def, shared),
		entrances = entrances,
		upgrades = ups,
		recipes = recipes,
		escrow = s.profile.escrow,
		class = s.profile.class,
		classes = { "Explorer", "Medic", "Runner", "Technician" },
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
	local shared = occupantsMap(cell)
	local cost, nextStage = Shelters.nextCost(def, shared, upgradeId)
	if not cost or not nextStage then
		return
	end
	if not Inventory.hasAll(s.profile.inventory, cost) then
		services.PlayerService.notify(player, "Not enough materials.", "warn")
		return
	end
	local secs = 3 * (Config.Classes[s.profile.class].repairTimeMultiplier or 1)
	if not services.PlayerService.hold(player, secs) then
		return
	end
	if not Inventory.hasAll(s.profile.inventory, cost) then
		return
	end
	for id, n in cost do
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
		ShelterService.pushPanel(p)
	end
	if Shelters.isSecured(def, s.profile.shelterUpgrades) then
		services.PlayerService.notify(
			player,
			def.name .. " is fully secured. Creatures cannot enter or harm anyone inside.",
			"info"
		)
	end
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
	local secs = recipe.seconds * (Config.Classes[s.profile.class].craftTimeMultiplier or 1)
	if not services.PlayerService.hold(player, secs) then
		return
	end
	local ok, why = Commerce.craft(s.profile.inventory, ItemDefs.get, recipe, atBench)
	if not ok then
		services.PlayerService.notify(player, "Crafting failed: " .. tostring(why), "warn")
		return
	end
	services.SaveService.markDirty(player)
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

-- Party membership changed: occupants move to their new group's cell next time they enter; refresh visuals now.
function ShelterService.onPartyChanged()
	for _, c in cells do
		refreshCellVisuals(c)
	end
end

function ShelterService.init(s)
	services = s
end

function ShelterService.start()
	local CollectionService = game:GetService("CollectionService")
	for _, door in CollectionService:GetTagged("ShelterDoor") do
		local pp = door:FindFirstChildOfClass("ProximityPrompt")
		if pp then
			pp.Triggered:Connect(function(player)
				ShelterService.enter(player, door:GetAttribute("ShelterId"))
			end)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		local c = cellOf(player)
		if c then
			c.occupants[player] = nil
			releaseIfEmpty(c)
		end
	end)
	-- Probe events at unprotected entrances of unsecured cells (section 13: initially relatively safe).
	task.spawn(function()
		while true do
			task.wait(5)
			for _, cell in cells do
				local def = shelterDef(cell.shelterId)
				local map = occupantsMap(cell)
				if Shelters.isSecured(def, map) or os.clock() - cell.lastProbe < 60 then
					continue
				end
				if math.random() > 0.25 then
					continue
				end
				cell.lastProbe = os.clock()
				local spots = {}
				for i, e in def.entrances do
					if Shelters.stage(map, def.id, e.requiredUpgrade) < e.requiredStage then
						table.insert(spots, cell.parts["Ent" .. i .. "Open"].Position)
					end
				end
				local spot = spots[math.random(1, #spots)]
				for p in cell.occupants do
					services.PlayerService.send(p, "cue", { id = "shelter_probe", position = spot })
				end
				task.delay(2.5, function()
					for p in cell.occupants do
						local pos = services.PlayerService.position(p)
						if pos and (pos - spot).Magnitude < 5 then
							services.PlayerService.damage(p, 8, false, "shelter_probe")
						end
					end
				end)
			end
		end
	end)
end

return ShelterService
