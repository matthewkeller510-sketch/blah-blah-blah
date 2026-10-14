--!strict
-- Shared helpers for every creature (section 10): the chamber graph and movement along it, perception, research
-- evidence (with field experience), cues and greybox bodies. CreatureService.init hands the services table in.
-- Movement is server-driven along the chamber graph (centre-to-centre lines stay inside corridors, including the
-- sloped galleries between levels). Closed puzzle gates are impassable; pocket corridors are always connected because
-- every pocket version honours the same entry/exit contract (docs/MILESTONE-3.md section 2).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Progress = require(Shared.Logic.Progress)
local Inventory = require(Shared.Logic.Inventory)
local CreatureRules = require(Shared.Logic.CreatureRules)

local Common = {}
local services: any

-- Effective light of a player as creatures see it (the player package's lightState contract).
export type LightState = { on: boolean, itemId: string?, isLantern: boolean, shielded: boolean, range: number }
-- A lit flare (the player package's activeFlares contract) plus a stable key for "each flare decoys once".
export type Flare = { position: Vector3, owner: Player?, key: string }
-- Something a player can aim a tool at. kind: killable (melee hurts it), unkillable (weapons glance off), harmless
-- (a phenomenon: tools do nothing). onStun returns true when the stun took effect (only then is a charge used).
export type Target = {
	part: BasePart,
	kind: "killable" | "unkillable" | "harmless",
	onBar: ((Player) -> ())?,
	onStun: ((Player) -> boolean)?,
}

-- Chamber graph ----------------------------------------------------------------------------------
local nodes: { [string]: Vector3 } = {} -- chamber floor centres
local nodeRegion: { [string]: string } = {}
local chamberIds: { string } = {}
local gateIds: { string } = {}
for _, c in WorldDefs.Chambers do
	nodes[c.id] = Vector3.new(c.pos.x, c.pos.y, c.pos.z)
	nodeRegion[c.id] = c.regionId
	table.insert(chamberIds, c.id)
end
for _, cor in WorldDefs.Corridors do
	if cor.gate and not table.find(gateIds, cor.gate) then
		table.insert(gateIds, cor.gate)
	end
end
local graph = CreatureRules.buildGraph(chamberIds, WorldDefs.Corridors)
Common.nodes = nodes
Common.nodeRegion = nodeRegion

local gateOpen: { [string]: boolean } = {}
local gateSignature = ""
local routeCache: { [string]: { string } } = {}

-- Reads puzzle gate state once per creature tick; a change clears the cached routes.
function Common.refreshGates()
	local ps = services.PuzzleService
	local legacy: { [string]: boolean }? = nil
	if ps and not ps.isGateOpen and ps.openGates then
		legacy = ps.openGates()
	end
	local parts = {}
	for _, g in gateIds do
		local open = false
		if ps and ps.isGateOpen then
			local ok, v = pcall(ps.isGateOpen, g)
			open = ok and v == true
		elseif legacy then
			open = legacy[g] == true
		end
		gateOpen[g] = open
		table.insert(parts, if open then "1" else "0")
	end
	local sig = table.concat(parts)
	if sig ~= gateSignature then
		gateSignature = sig
		table.clear(routeCache)
	end
end

-- Nearest chamber to a FLOOR position. Same metric as WorldBuilder.nearestChamber for a standing player (whose root
-- is about 3 studs above the floor): height differences weigh triple.
function Common.nearestNode(p: Vector3): string
	local best, bd = "", math.huge
	for id, n in nodes do
		local d = Vector3.new(p.X - n.X, (p.Y - n.Y) * 3, p.Z - n.Z).Magnitude
		if d < bd then
			best, bd = id, d
		end
	end
	return best
end

-- Shortest chamber path (excluding `fromId`) honouring closed gates (`wades`: deep-water gates are passable).
-- Empty when unreachable (or already there). Cached until a gate changes.
function Common.route(fromId: string, toId: string, wades: boolean?): { string }
	local key = fromId .. (if wades then ">~" else ">") .. toId
	local cached = routeCache[key]
	if cached then
		return cached
	end
	local path = CreatureRules.route(graph, fromId, toId, gateOpen, wades == true)
	routeCache[key] = path
	return path
end

-- Moves a model toward `to` (a floor position) keeping its body `lift` studs above the floor.
function Common.moveModel(m: Model, to: Vector3, lift: number, speed: number, dt: number): boolean
	local bp = m.PrimaryPart :: BasePart
	local from = bp.Position
	local goal = to + Vector3.new(0, lift, 0)
	local d = goal - from
	if d.Magnitude < 0.5 then
		return true
	end
	local step = math.min(d.Magnitude, speed * dt)
	local np = from + d.Unit * step
	local flat = Vector3.new(d.X, 0, d.Z)
	local cf = if flat.Magnitude > 0.01
		then CFrame.lookAt(np, np + flat.Unit)
		else CFrame.new(np) * (bp.CFrame - bp.Position)
	m:PivotTo(cf)
	return step >= d.Magnitude - 0.01
end

-- Walks toward a floor goal along the chamber graph (direct when already in the goal's chamber).
-- Returns (arrived, blocked). Blocked means no open route exists: callers give up instead of stalling forever.
function Common.travel(
	m: Model,
	goal: Vector3,
	lift: number,
	speed: number,
	dt: number,
	wades: boolean?
): (boolean, boolean)
	local bp = m.PrimaryPart :: BasePart
	local here, there = Common.nearestNode(bp.Position - Vector3.new(0, lift, 0)), Common.nearestNode(goal)
	if here == there then
		return Common.moveModel(m, goal, lift, speed, dt), false
	end
	local nextId = Common.route(here, there, wades)[1]
	if not nextId then
		return false, true
	end
	Common.moveModel(m, nodes[nextId], lift, speed, dt)
	return false, false
end

-- Turns a model in place to face a point (horizontal only). No-op when the point is directly above or below.
function Common.face(m: Model, point: Vector3)
	local bp = m.PrimaryPart :: BasePart
	local flat = Vector3.new(point.X - bp.Position.X, 0, point.Z - bp.Position.Z)
	if flat.Magnitude > 0.1 then
		m:PivotTo(CFrame.lookAt(bp.Position, bp.Position + flat.Unit))
	end
end

-- Perception ---------------------------------------------------------------------------------------------
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Include

-- Creature parts are CanQuery=false, so they never block this ray.
function Common.lineOfSight(a: Vector3, b: Vector3): boolean
	worldParams.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local hit = workspace:Raycast(a, b - a, worldParams)
	return hit == nil
end

-- A player creatures may perceive right now: not in a shelter, not hidden (F07), alive, in a tunnel region.
function Common.perceivable(p: Player, sess: any): boolean
	return not sess.insideShelterId
		and not sess.hiddenAt
		and sess.vitals.condition ~= "dead"
		and WorldDefs.isTunnel(sess.regionId)
		and services.PlayerService.position(p) ~= nil
end

-- Perceivable and not downed: phenomena and stalkers never act on a downed player.
function Common.active(p: Player, sess: any): boolean
	return Common.perceivable(p, sess) and sess.vitals.condition ~= "downed"
end

function Common.head(p: Player): BasePart?
	local c = p.Character
	local h = c and c:FindFirstChild("Head")
	return if h and h:IsA("BasePart") then h else nil
end

function Common.v3(v: Vector3): CreatureRules.V3
	return { x = v.X, y = v.Y, z = v.Z }
end

-- Deliberate watching of a point: within range, the look direction inside the cone (horizontal), clear sight.
function Common.watching(p: Player, target: Vector3, range: number, cosLimit: number): boolean
	local head = Common.head(p)
	if not head then
		return false
	end
	local to = target - head.Position
	if to.Magnitude > range then
		return false
	end
	if not CreatureRules.watching(Common.v3(head.CFrame.LookVector), Common.v3(to), range, cosLimit, true) then
		return false
	end
	return Common.lineOfSight(head.Position, target)
end

-- Effective light. Uses PlayerService.lightState (player package contract); until that exists, the same predicate
-- PlayerService.refreshLight uses (on, a light equipped and held, charge > 0, not downed). Never the raw toggle.
function Common.light(p: Player): LightState
	local ps = services.PlayerService
	if ps.lightState then
		local ok, st = pcall(ps.lightState, p)
		if ok and type(st) == "table" then
			return {
				on = st.on == true,
				itemId = if type(st.itemId) == "string" then st.itemId else nil,
				isLantern = st.isLantern == true,
				shielded = st.shielded == true,
				range = if type(st.range) == "number" then st.range else 0,
			}
		end
	end
	local s = ps.get(p)
	local id = s and s.profile.equippedLight
	local def = if s and id and Inventory.count(s.profile.inventory, id) > 0 then ItemDefs.get(id) else nil
	local on = s ~= nil and def ~= nil and s.lightOn and s.profile.lightCharge > 0 and s.vitals.condition ~= "downed"
	return {
		on = on == true,
		itemId = if def then def.id else nil,
		isLantern = def ~= nil and def.lantern == true,
		shielded = false,
		range = if def then def.beamRange or 0 else 0,
	}
end

-- Lit flares (PlayerService.activeFlares, player package contract); empty until that exists.
function Common.flares(): { Flare }
	local ps = services.PlayerService
	local out: { Flare } = {}
	if not ps.activeFlares then
		return out
	end
	local ok, list = pcall(ps.activeFlares)
	if not ok or type(list) ~= "table" then
		return out
	end
	for _, f in list do
		if type(f) == "table" and typeof(f.position) == "Vector3" then
			local owner: Player? = if typeof(f.owner) == "Instance" and f.owner:IsA("Player") then f.owner else nil
			local pos = f.position :: Vector3
			local key = string.format(
				"%d@%s@%d,%d,%d",
				if owner then owner.UserId else 0,
				tostring(f.expires),
				math.floor(pos.X),
				math.floor(pos.Y),
				math.floor(pos.Z)
			)
			table.insert(out, { position = pos, owner = owner, key = key })
		end
	end
	return out
end

-- Whether a world position is inside a chamber's interior (with slack).
function Common.inChamber(pos: Vector3, chamberId: string, slack: number): boolean
	local c = WorldDefs.chamber(chamberId)
	if not c then
		return false
	end
	return CreatureRules.inChamber(Common.v3(pos), c.pos, c.size, slack)
end

-- Research ---------------------------------------------------------------------------------------
local function researchPayload(def: any, stage: number)
	return {
		id = def.id,
		name = def.name,
		stage = stage,
		-- never nil, even if a definition ever lists more evidence than there are stage names
		stageName = Progress.stageName(stage) or "documented",
		stages = #def.researchEvidence,
		nextHint = def.hints and def.hints[stage + 1] or nil,
	}
end
Common.researchPayload = researchPayload

-- Records evidence. New evidence marks the profile dirty even when the stage does not move yet (evidence gathered
-- early counts later). A stage rise pushes the journal, grants field experience once per stage key and tells
-- missions.
function Common.evidence(player: Player, def: any, evidenceId: string)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local entry = s.profile.research[def.id]
	local before = if entry then entry.stage else 0
	local had = entry ~= nil and entry.evidence[evidenceId] == true
	local stage = Progress.addEvidence(s.profile.research, def.id, evidenceId, def.researchEvidence)
	if not had or stage ~= before then
		services.SaveService.markDirty(player)
	end
	if stage ~= before then
		services.PlayerService.send(player, "research", researchPayload(def, stage))
		local grantXp = services.PlayerService.grantXp
		if grantXp then
			-- idempotent per key: the player package back-fills the same keys on load, so nothing double-pays
			for _, key in CreatureRules.researchXpKeys(def.id, before, stage) do
				local ok, err = pcall(grantXp, player, key, Config.Progression.xp.research)
				if not ok then
					warn("[Creatures] grantXp " .. key .. ": " .. tostring(err))
				end
			end
		end
		if services.MissionService then
			services.MissionService.onResearch(player, def.id, stage)
		end
	end
end

-- Cues -------------------------------------------------------------------------------------------
local CUE_LEVEL = 14 -- studs of height: a cue never carries to the level above or below (levels are 20+ apart)

-- Sends a cue to every player within a radius on the same level and returns who heard it ("heard" evidence).
function Common.cueAll(near: Vector3, radius: number, id: string, extra: any?): { Player }
	local heard = {}
	for p in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and (pos - near).Magnitude <= radius and math.abs(pos.Y - near.Y) <= CUE_LEVEL then
			services.PlayerService.send(p, "cue", { id = id, position = near, extra = extra })
			table.insert(heard, p)
		end
	end
	return heard
end

function Common.cueTo(p: Player, id: string, position: Vector3?, extra: any?)
	services.PlayerService.send(p, "cue", { id = id, position = position, extra = extra })
end

-- True when two positions are within `radius` and on the same level.
function Common.withinLevel(a: Vector3, b: Vector3, radius: number): boolean
	return (a - b).Magnitude <= radius and math.abs(a.Y - b.Y) <= CUE_LEVEL
end

-- Bodies -----------------------------------------------------------------------------------------
-- Placeholder primitive bodies; production rigs are PLANNED. Every part is anchored, CanCollide=false and
-- CanQuery=false so bodies never block rays (line of sight, aim, placement). Move a whole model with PivotTo.
function Common.body(name: string, regionId: string, size: Vector3, color: Color3, material: Enum.Material): Model
	local m = Instance.new("Model")
	m.Name = name
	local p = Instance.new("Part")
	p.Name = "Body"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.Parent = m
	m.PrimaryPart = p
	m.Parent = services.WorldBuilder.folder(regionId)
	return m
end

function Common.addPart(
	m: Model,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = (m.PrimaryPart :: BasePart).CFrame * offset
	p.Parent = m
	return p
end

function Common.init(s)
	services = s
end

return Common
