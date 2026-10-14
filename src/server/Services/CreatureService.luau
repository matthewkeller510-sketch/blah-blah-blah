--!strict
-- Creatures (section 10): C01 Sidelooker (harmless), C05 Scrabbler (vulnerable predator, killable; one per home
-- group), C06 Wader (water-sensitive stalker, cannot be killed), C07 Knocker (line-charge threat, cannot be killed).
-- Placeholder primitive bodies; production rigs are PLANNED.
-- Movement is server-driven along the chamber graph (centre-to-centre lines stay inside corridors, including the
-- sloped galleries between levels). Every damaging encounter has a readable cue first and an escape route
-- (T04, T05). Hidden players (F07) cannot be sensed.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Progress = require(Shared.Logic.Progress)
local Inventory = require(Shared.Logic.Inventory)

local CreatureService = {}
local services: any

local SCRAB = WorldDefs.Creatures.C05_Scrabbler
local KNOCK = WorldDefs.Creatures.C07_Knocker
local SIDE = WorldDefs.Creatures.C01_Sidelooker
local WADER = WorldDefs.Creatures.C06_Wader

-- Chamber graph ----------------------------------------------------------------------------------
local nodes: { [string]: Vector3 } = {} -- chamber floor centres
local nodeRegion: { [string]: string } = {}
local adj: { [string]: { string } } = {}
for _, c in WorldDefs.Chambers do
	nodes[c.id] = Vector3.new(c.pos.x, c.pos.y, c.pos.z)
	nodeRegion[c.id] = c.regionId
	adj[c.id] = {}
end
for _, cor in WorldDefs.Corridors do
	table.insert(adj[cor.from], cor.to)
	table.insert(adj[cor.to], cor.from)
end

local function nearestNode(p: Vector3): string
	local best, bd = "", math.huge
	for id, n in nodes do
		local d = Vector3.new(p.X - n.X, (p.Y - n.Y - 2) * 3, p.Z - n.Z).Magnitude
		if d < bd then
			best, bd = id, d
		end
	end
	return best
end

local function route(fromId: string, toId: string): { string }
	local prev: { [string]: string } = {}
	local seen = { [fromId] = true }
	local q = { fromId }
	while #q > 0 do
		local cur = table.remove(q, 1)
		if cur == toId then
			break
		end
		for _, n in adj[cur] do
			if not seen[n] then
				seen[n] = true
				prev[n] = cur
				table.insert(q, n)
			end
		end
	end
	local path = {}
	local cur: string? = toId
	while cur and cur ~= fromId do
		table.insert(path, 1, cur)
		cur = prev[cur]
	end
	return path
end

local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Include

local function lineOfSight(a: Vector3, b: Vector3): boolean
	worldParams.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local hit = workspace:Raycast(a, b - a, worldParams)
	return hit == nil
end

-- A player creatures may perceive right now.
local function perceivable(p: Player, sess: any): boolean
	return not sess.insideShelterId
		and not sess.hiddenAt
		and sess.vitals.condition ~= "dead"
		and WorldDefs.isTunnel(sess.regionId)
		and services.PlayerService.position(p) ~= nil
end

-- Research ---------------------------------------------------------------------------------------
local function evidence(player: Player, def: any, evidenceId: string)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local before = s.profile.research[def.id] and s.profile.research[def.id].stage or 0
	local stage = Progress.addEvidence(s.profile.research, def.id, evidenceId, def.researchEvidence)
	if stage ~= before then
		services.SaveService.markDirty(player)
		services.PlayerService.send(player, "research", {
			id = def.id,
			name = def.name,
			stage = stage,
			stageName = Progress.stageName(stage),
			stages = #def.researchEvidence,
			nextHint = def.hints and def.hints[stage + 1] or nil,
		})
		if services.MissionService then
			services.MissionService.onResearch(player, def.id, stage)
		end
	end
end

local function cueAll(near: Vector3, radius: number, id: string, extra: any?): { Player }
	local heard = {}
	for p in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and (pos - near).Magnitude <= radius then
			services.PlayerService.send(p, "cue", { id = id, position = near, extra = extra })
			table.insert(heard, p)
		end
	end
	return heard
end

local function body(name: string, regionId: string, size: Vector3, color: Color3, material: Enum.Material): Model
	local m = Instance.new("Model")
	m.Name = name
	local p = Instance.new("Part")
	p.Name = "Body"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.Parent = m
	m.PrimaryPart = p
	m.Parent = services.WorldBuilder.folder(regionId)
	return m
end

local function addPart(m: Model, name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = (m.PrimaryPart :: BasePart).CFrame * offset
	p.Parent = m
	return p
end

-- Moves a model toward `to` (a floor position) keeping its body `lift` studs above the floor.
local function moveModel(m: Model, to: Vector3, lift: number, speed: number, dt: number): boolean
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
	local cf = if flat.Magnitude > 0.01 then CFrame.lookAt(np, np + flat.Unit) else CFrame.new(np) * (bp.CFrame - bp.Position)
	m:PivotTo(cf)
	return step >= d.Magnitude - 0.01
end

-- Walks toward a floor goal along the chamber graph (direct when already in the goal's chamber).
local function travel(m: Model, goal: Vector3, lift: number, speed: number, dt: number): boolean
	local bp = m.PrimaryPart :: BasePart
	local here, there = nearestNode(bp.Position - Vector3.new(0, lift, 0)), nearestNode(goal)
	if here == there then
		return moveModel(m, goal, lift, speed, dt)
	end
	local path = route(here, there)
	local nextId = path[1]
	if nextId then
		moveModel(m, nodes[nextId], lift, speed, dt)
	end
	return false
end

-- C01 Sidelooker: appears at a chamber edge, peeks; retreats when deliberately watched. Never damages.
local sideState = { model = nil :: Model?, watcher = nil :: Player?, watchedFor = 0, chamber = "" }
local lastSighting: { [Player]: number } = {}

local function sidelookerTick(dt: number)
	local m = sideState.model
	if m then
		local w = sideState.watcher
		local head = w and w.Character and w.Character:FindFirstChild("Head") :: BasePart?
		local bp = m.PrimaryPart :: BasePart
		if not head or not w then
			m:Destroy()
			sideState.model = nil
			return
		end
		local to = (bp.Position - head.Position)
		local look = head.CFrame.LookVector
		local watched = to.Magnitude < 70 and look:Dot(to.Unit) > 0.94 and lineOfSight(head.Position, bp.Position)
		if watched then
			sideState.watchedFor += dt
			evidence(w, SIDE, "seen")
			local s = services.PlayerService.get(w)
			if s then
				local key = "loc:" .. sideState.chamber
				s.profile.research[SIDE.id] = s.profile.research[SIDE.id] or { stage = 0, evidence = {} }
				local ev = s.profile.research[SIDE.id].evidence
				ev[key] = true
				local n = 0
				for k in ev do
					if string.sub(k, 1, 4) == "loc:" then
						n += 1
					end
				end
				if n >= 3 then
					evidence(w, SIDE, "seen_three_locations")
				end
			end
		end
		if sideState.watchedFor > 0.4 then
			-- retreat: slide back out of view and vanish
			evidence(w, SIDE, "seen_retreat_when_watched")
			services.PlayerService.send(w, "cue", { id = "sidelooker_retreat", position = bp.Position })
			local away = bp.Position - Vector3.new(to.X, 0, to.Z).Unit * 6
			m:PivotTo(CFrame.new(away))
			task.delay(0.25, function()
				m:Destroy()
			end)
			sideState.model = nil
			return
		end
		return
	end
	-- maybe spawn: early, subtle, easy to miss (F06, T04). One at a time server-wide; a private sighting.
	for p, s in services.PlayerService.all() do
		if not perceivable(p, s) then
			continue
		end
		if os.clock() - (lastSighting[p] or 0) < 75 then
			continue
		end
		local pressure = services.DirectorService.pressure(p)
		if math.random() > 0.02 + pressure * 0.06 then
			continue
		end
		local head = p.Character and p.Character:FindFirstChild("Head") :: BasePart?
		if not head then
			continue
		end
		-- choose a chamber in the same region 30-60 studs away, off to the side (outside immediate view)
		for id, n in nodes do
			if nodeRegion[id] ~= s.regionId then
				continue
			end
			local to = Vector3.new(n.X - head.Position.X, 0, n.Z - head.Position.Z)
			local d = to.Magnitude
			local look = Vector3.new(head.CFrame.LookVector.X, 0, head.CFrame.LookVector.Z).Unit
			if d > 30 and d < 60 and math.abs(look:Dot(to.Unit)) < 0.6 then
				local c = assert(WorldDefs.chamber(id))
				local corner = n + Vector3.new((c.size.x / 2 - 1.5) * (if math.random() < 0.5 then -1 else 1), 0, (c.size.z / 2 - 1.5))
				local mm = body("Sidelooker", c.regionId, Vector3.new(1.2, 8.5, 0.8), Color3.fromRGB(58, 56, 52), Enum.Material.Slate)
				mm:PivotTo(CFrame.lookAt(corner + Vector3.new(0, 4.25, 0), head.Position))
				sideState.model = mm
				sideState.watcher = p
				sideState.watchedFor = 0
				sideState.chamber = id
				lastSighting[p] = os.clock()
				services.PlayerService.send(p, "cue", { id = "sidelooker_scrape", position = corner })
				task.delay(14, function()
					if sideState.model == mm then
						mm:Destroy()
						sideState.model = nil
					end
				end)
				return
			end
		end
	end
end

-- C05 Scrabbler ---------------------------------------------------------------------------------------
type Scrabbler = {
	model: Model,
	health: number,
	state: "idle" | "search" | "warning" | "rush" | "recover" | "stunned" | "dead",
	target: Player?,
	stateUntil: number,
	lastKnown: Vector3?,
	investigate: Vector3?,
	homes: { string },
	home: string,
	regionId: string,
	engaged: boolean,
	lastHit: number,
	respawnAt: number,
}

local SCRAB_LIFT = 0.9
local scrabblers: { Scrabbler } = {}

local function spawnScrabbler(homes: { string }): Scrabbler
	local home = homes[math.random(1, #homes)]
	local regionId = nodeRegion[home]
	local m = body("Scrabbler", regionId, Vector3.new(3.6, 1.8, 5.5), Color3.fromRGB(70, 66, 58), Enum.Material.Slate)
	m:PivotTo(CFrame.new(nodes[home] + Vector3.new(math.random(-6, 6), SCRAB_LIFT, math.random(-6, 6))))
	addPart(m, "MineralPlates", Vector3.new(3, 0.6, 4.6), CFrame.new(0, 1.1, 0), Color3.fromRGB(120, 116, 108), Enum.Material.Basalt)
	m:SetAttribute("CreatureId", SCRAB.id)
	return {
		model = m,
		health = SCRAB.health,
		state = "idle",
		target = nil,
		stateUntil = 0,
		lastKnown = nil,
		investigate = nil,
		homes = homes,
		home = home,
		regionId = regionId,
		engaged = false,
		lastHit = 0,
		respawnAt = 0,
	}
end

local function scrabEnd(s: Scrabbler, wasChase: boolean)
	if s.engaged and s.target then
		services.DirectorService.endThreat(s.target, wasChase)
	end
	s.engaged = false
	s.target = nil
end

local function noisy(p: Player, sess: any): boolean
	if sess.mode == "sprint" then
		return true
	end
	if sess.mode ~= "walk" then
		return false -- crouching / idle is quiet footing
	end
	local pos = services.PlayerService.position(p)
	if not pos then
		return false
	end
	for _, v in CollectionService:GetTagged("NoisyFloor") do
		local rel = v.CFrame:PointToObjectSpace(pos)
		local h = v.Size / 2
		if math.abs(rel.X) <= h.X and math.abs(rel.Z) <= h.Z and math.abs(rel.Y) <= h.Y + 4 then
			return true
		end
	end
	return false
end

local function scrabblerTick(s: Scrabbler, dt: number)
	if s.state == "dead" then
		if os.clock() > s.respawnAt then
			s.model:Destroy()
			local fresh = spawnScrabbler(s.homes)
			for k, v in fresh :: any do
				(s :: any)[k] = v
			end
		end
		return
	end
	local bp = s.model.PrimaryPart :: BasePart
	local now = os.clock()
	if s.state == "stunned" then
		if now > s.stateUntil then
			s.state = "search"
		end
		return
	end
	-- perception
	if s.state == "idle" or s.state == "search" then
		local best: Player?, bestD = nil, math.huge
		for p, sess in services.PlayerService.all() do
			if not perceivable(p, sess) or sess.regionId ~= s.regionId then
				continue
			end
			local pos = services.PlayerService.position(p) :: Vector3
			local d = (pos - bp.Position).Magnitude
			local heard = d < SCRAB.hearingRadius and noisy(p, sess)
			local seen = d < SCRAB.sightRadius * (if sess.lightOn then 1.4 else 0.6) and lineOfSight(bp.Position + Vector3.new(0, 1, 0), pos)
			if (heard or seen) and d < bestD then
				best, bestD = p, d
			end
			if seen and d < 30 then
				evidence(p, SCRAB, "seen")
			end
		end
		if best then
			s.lastKnown = services.PlayerService.position(best)
			-- Director gates the dangerous rush; otherwise it keeps a stalking distance.
			if services.DirectorService.mayEngage(best, 0.25) then
				s.target = best
				s.engaged = true
				s.investigate = nil
				services.DirectorService.beginThreat(best)
				s.state = "warning"
				s.stateUntil = now + SCRAB.windupSeconds
				for _, p in cueAll(bp.Position, 60, "scrabbler_windup") do
					evidence(p, SCRAB, "heard_scrape")
				end
				return
			elseif bestD > services.DirectorService.stalkDistance(best) then
				s.state = "search"
			end
		end
	end
	if s.state == "warning" then
		if now >= s.stateUntil then
			s.state = "rush"
			s.stateUntil = now + 6
		end
		return
	end
	if s.state == "rush" then
		local t = s.target
		local tpos = t and services.PlayerService.position(t)
		local tsess = t and services.PlayerService.get(t)
		-- leash: it never follows a target out of its own region, into a shelter, or to a hiding niche
		if not t or not tpos or not tsess or tsess.insideShelterId or tsess.hiddenAt or tsess.regionId ~= s.regionId then
			if t and tsess and tsess.hiddenAt then
				evidence(t, SCRAB, "escaped_by_breaking_sight")
			end
			s.state = "search"
			scrabEnd(s, true)
			return
		end
		local canSee = lineOfSight(bp.Position + Vector3.new(0, 1, 0), tpos)
		if canSee then
			s.lastKnown = tpos
		end
		local goal = (s.lastKnown or tpos) - Vector3.new(0, 3, 0)
		if canSee then
			moveModel(s.model, goal, SCRAB_LIFT, SCRAB.rushSpeed, dt)
		elseif travel(s.model, goal, SCRAB_LIFT, SCRAB.rushSpeed * 0.8, dt) then
			-- reached last known position without sight: the player broke sight and escaped
			evidence(t, SCRAB, "escaped_by_breaking_sight")
			s.state = "search"
			scrabEnd(s, true)
			return
		end
		if (tpos - bp.Position).Magnitude < 4.5 and now - s.lastHit > 1.2 then
			s.lastHit = now
			services.PlayerService.damage(t, SCRAB.damage, true, "scrabbler")
			s.state = "recover"
			s.stateUntil = now + 2.5
			cueAll(bp.Position, 40, "scrabbler_hit")
			return
		end
		if now > s.stateUntil then
			s.state = "search"
			scrabEnd(s, true)
		end
		return
	end
	if s.state == "recover" then
		if now > s.stateUntil then
			s.state = "search"
			scrabEnd(s, true)
		end
		return
	end
	-- idle / search: investigate a noise, otherwise wander back home slowly
	if s.investigate then
		if travel(s.model, s.investigate, SCRAB_LIFT, SCRAB.walkSpeed * 1.4, dt) then
			s.investigate = nil
		end
		return
	end
	local homePos = nodes[s.home]
	if (bp.Position - (homePos + Vector3.new(0, SCRAB_LIFT, 0))).Magnitude > 4 then
		travel(s.model, homePos, SCRAB_LIFT, SCRAB.walkSpeed, dt)
	elseif math.random() < 0.01 then
		cueAll(bp.Position, 35, "scrabbler_idle")
	end
end

-- C06 Wader -------------------------------------------------------------------------------------------
-- Blind; hears splashes. Crouch-wading, stepping stones, dry floors and hiding are silent. A thrown stone that
-- lands in water draws it away. It can be repelled briefly but never killed.
type Wader = {
	model: Model,
	state: "wander" | "listening" | "pursue" | "recover" | "repelled",
	target: Player?,
	goal: Vector3?,
	stateUntil: number,
	lastHeard: number,
	home: string,
	engaged: boolean,
}

local WADER_LIFT = 5
local wader: Wader

local function spawnWader()
	local home = WADER.homes[1]
	local m = body("Wader", "R03", Vector3.new(2.2, 9, 1.6), Color3.fromRGB(58, 66, 62), Enum.Material.SmoothPlastic)
	m:PivotTo(CFrame.new(nodes[home] + Vector3.new(0, WADER_LIFT, 0)))
	addPart(m, "LongArmL", Vector3.new(0.5, 7, 0.5), CFrame.new(-1.5, -1, -0.2) * CFrame.Angles(0.1, 0, 0.08), Color3.fromRGB(50, 58, 54), Enum.Material.SmoothPlastic)
	addPart(m, "LongArmR", Vector3.new(0.5, 7, 0.5), CFrame.new(1.5, -1, -0.2) * CFrame.Angles(0.1, 0, -0.08), Color3.fromRGB(50, 58, 54), Enum.Material.SmoothPlastic)
	addPart(m, "Head", Vector3.new(1.4, 1.6, 1.2), CFrame.new(0, 5.3, -0.3), Color3.fromRGB(72, 80, 74), Enum.Material.SmoothPlastic)
	m:SetAttribute("CreatureId", WADER.id)
	wader = { model = m, state = "wander", target = nil, goal = nil, stateUntil = 0, lastHeard = 0, home = home, engaged = false }
end

local function waderEnd(wasChase: boolean)
	if wader.engaged and wader.target then
		services.DirectorService.endThreat(wader.target, wasChase)
	end
	wader.engaged = false
	wader.target = nil
end

local function waderHear(pos: Vector3, loudness: number, source: Player?, thrower: Player?)
	local w = wader
	if not w or w.state == "repelled" or w.state == "recover" then
		return
	end
	if services.WorldBuilder.regionAt(pos) ~= "R03" then
		return
	end
	local bp = w.model.PrimaryPart :: BasePart
	if (pos - bp.Position).Magnitude > WADER.hearingRadius * loudness then
		return
	end
	local now = os.clock()
	w.lastHeard = now
	if source == nil then
		-- a distraction: go and listen there, abandoning any pursuit
		if thrower then
			evidence(thrower, WADER, "distracted_or_repelled")
		end
		waderEnd(true)
		w.goal = pos
		w.state = "wander"
		return
	end
	if w.state == "pursue" and w.target == source then
		w.goal = pos -- blind tracking: it only updates on the next splash
		return
	end
	if w.state == "wander" and services.DirectorService.mayEngage(source, 0.2) then
		w.target = source
		w.engaged = true
		services.DirectorService.beginThreat(source)
		w.goal = pos
		w.state = "listening"
		w.stateUntil = now + WADER.warnSeconds
		for _, p in cueAll(bp.Position, 70, "wader_drag") do
			evidence(p, WADER, "heard_drag")
		end
	elseif w.state == "wander" then
		w.goal = pos -- not allowed to engage yet: it drifts toward the sound without attacking
	end
end

local function waderTick(dt: number)
	local w = wader
	local bp = w.model.PrimaryPart :: BasePart
	local now = os.clock()
	for p, sess in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and perceivable(p, sess) and (pos - bp.Position).Magnitude < 30 and lineOfSight(pos, bp.Position) then
			evidence(p, WADER, "seen")
		end
	end
	if w.state == "repelled" or w.state == "recover" then
		if now > w.stateUntil then
			w.state = "wander"
		end
		if w.state == "repelled" then
			travel(w.model, nodes[w.home], WADER_LIFT, WADER.walkSpeed, dt)
		end
		return
	end
	if w.state == "listening" then
		if now > w.stateUntil then
			w.state = "pursue"
			w.stateUntil = now + 20
		end
		return
	end
	if w.state == "pursue" then
		local t = w.target
		local tsess = t and services.PlayerService.get(t)
		if not t or not tsess or tsess.insideShelterId or not WorldDefs.isTunnel(tsess.regionId) then
			waderEnd(true)
			w.state = "wander"
			return
		end
		local arrived = w.goal == nil or travel(w.model, w.goal :: Vector3, WADER_LIFT, WADER.pursueSpeed, dt)
		local tpos = services.PlayerService.position(t)
		if tpos and not tsess.hiddenAt and tsess.inWater and (tpos - bp.Position).Magnitude < 5 then
			services.PlayerService.damage(t, WADER.damage, true, "wader")
			cueAll(bp.Position, 40, "wader_strike")
			waderEnd(true)
			w.state = "recover"
			w.stateUntil = now + 4
			return
		end
		if (arrived and now - w.lastHeard > 4) or now > w.stateUntil then
			-- silence wins: the player stayed quiet long enough
			evidence(t, WADER, "evaded_by_silence")
			cueAll(bp.Position, 50, "wader_lost")
			waderEnd(true)
			w.state = "wander"
		end
		return
	end
	-- wander: drift to a heard sound, otherwise between home pools
	if w.goal then
		if travel(w.model, w.goal :: Vector3, WADER_LIFT, WADER.walkSpeed, dt) then
			w.goal = nil
		end
		return
	end
	if (bp.Position - (nodes[w.home] + Vector3.new(0, WADER_LIFT, 0))).Magnitude < 3 then
		if math.random() < 0.004 then
			w.home = WADER.homes[math.random(1, #WADER.homes)]
		elseif math.random() < 0.01 then
			cueAll(bp.Position, 45, "wader_ripple")
		end
	else
		travel(w.model, nodes[w.home], WADER_LIFT, WADER.walkSpeed, dt)
	end
end

-- Noise entry point: player splashes (source = player) and thrown stones (source = nil, thrower = player).
function CreatureService.noise(pos: Vector3, kind: string, loudness: number, source: Player?, thrower: Player?)
	if kind == "splash" then
		waderHear(pos, loudness, source, thrower)
	end
	if kind == "clatter" or (kind == "splash" and source == nil) then
		for _, s in scrabblers do
			if (s.state == "idle" or s.state == "search") and (pos - (s.model.PrimaryPart :: BasePart).Position).Magnitude < 35 then
				s.investigate = pos
			end
		end
	end
end

-- C07 Knocker -----------------------------------------------------------------------------------------
-- Lives at the ends of the long straight corridor between Split Pier and Rusted Pulley.
local pier = nodes["R01.split_pier"]
local pulley = nodes["R01.rusted_pulley"]
local laneZ0 = pier.Z + 16 + 2
local laneZ1 = pulley.Z - 15 - 2

type Knocker = {
	model: Model,
	state: "dormant" | "knocking" | "charging" | "recovering" | "stunned",
	target: Player?,
	knocks: number,
	nextAt: number,
	dir: number,
	endZ: number,
	hit: { [Player]: boolean },
	cooldownUntil: number,
}

local knocker: Knocker
local function spawnKnocker()
	local m = body("Knocker", "R01", Vector3.new(4.5, 7.5, 3.5), Color3.fromRGB(64, 58, 52), Enum.Material.Rock)
	m:PivotTo(CFrame.new(0, -30, laneZ0)) -- dormant below the floor, out of play
	addPart(m, "FoldedForelimbs", Vector3.new(5.2, 2, 2), CFrame.new(0, 1, -1.6), Color3.fromRGB(80, 72, 64), Enum.Material.Rock)
	knocker = { model = m, state = "dormant", target = nil, knocks = 0, nextAt = 0, dir = 1, endZ = laneZ1, hit = {}, cooldownUntil = 0 }
end

local function placeKnocker(pos: Vector3, facingDir: Vector3)
	knocker.model:PivotTo(CFrame.lookAt(pos, pos + facingDir))
end

local function inLane(pos: Vector3): boolean
	return math.abs(pos.X) < 7 and pos.Z > laneZ0 and pos.Z < laneZ1 and pos.Y > -4 and pos.Y < 12
end

local function knockerTick(dt: number)
	local k = knocker
	local now = os.clock()
	if k.state == "dormant" then
		if now < k.cooldownUntil then
			return
		end
		for p, sess in services.PlayerService.all() do
			local pos = services.PlayerService.position(p)
			if pos and inLane(pos) and perceivable(p, sess) and services.DirectorService.mayEngage(p, 0.2) then
				k.target = p
				services.DirectorService.beginThreat(p)
				-- emerge at the far end from the player's direction of travel
				local fromPier = (pos.Z - laneZ0) < (laneZ1 - pos.Z)
				local startZ = if fromPier then laneZ1 - 2 else laneZ0 + 2
				k.dir = if fromPier then -1 else 1
				k.endZ = if fromPier then laneZ0 - 6 else laneZ1 + 6
				placeKnocker(Vector3.new(0, 3.75, startZ), Vector3.new(0, 0, k.dir))
				k.state = "knocking"
				k.knocks = 0
				k.nextAt = now + 0.6
				k.hit = {}
				return
			end
		end
		return
	end
	local bp = k.model.PrimaryPart :: BasePart
	if k.state == "knocking" then
		if now >= k.nextAt then
			k.knocks += 1
			local heard = cueAll(bp.Position, 90, "knocker_knock", { index = k.knocks, of = KNOCK.knockCount })
			if k.knocks >= KNOCK.knockCount then
				for _, p in heard do
					evidence(p, KNOCK, "heard_three_knocks")
				end
				k.state = "charging"
			else
				k.nextAt = now + KNOCK.knockInterval
			end
		end
		return
	end
	if k.state == "charging" then
		local pos = bp.Position + Vector3.new(0, 0, k.dir * KNOCK.chargeSpeed * dt)
		placeKnocker(pos, Vector3.new(0, 0, k.dir))
		for p, sess in services.PlayerService.all() do
			local pp = services.PlayerService.position(p)
			if pp and not k.hit[p] and perceivable(p, sess) and math.abs(pp.X - pos.X) < 4 and math.abs(pp.Z - pos.Z) < 3 and pp.Y > -4 and pp.Y < 12 then
				k.hit[p] = true
				services.PlayerService.damage(p, KNOCK.damage, true, "knocker")
			end
		end
		if (k.dir > 0 and pos.Z >= k.endZ) or (k.dir < 0 and pos.Z <= k.endZ) then
			local t = k.target
			if t and not k.hit[t] then
				evidence(t, KNOCK, "dodged_at_junction")
			end
			k.state = "recovering"
			k.nextAt = now + KNOCK.stunSeconds
			cueAll(bp.Position, 60, "knocker_impact")
		end
		return
	end
	if k.state == "recovering" or k.state == "stunned" then
		if now >= k.nextAt then
			if k.target then
				services.DirectorService.endThreat(k.target, true)
			end
			k.target = nil
			k.state = "dormant"
			k.cooldownUntil = now + 40
			placeKnocker(Vector3.new(0, -30, laneZ0), Vector3.new(0, 0, 1))
		end
	end
end

-- Player tools ----------------------------------------------------------------------------------------
local lastSwing: { [Player]: number } = {}

-- Returns what the player is facing within range: ("scrabbler", instance) | ("knocker") | ("wader").
local function facing(player: Player, range: number): (string?, any)
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil, nil
	end
	local function aimed(bp: BasePart): boolean
		local to = bp.Position - head.Position
		return to.Magnitude < range and head.CFrame.LookVector:Dot(to.Unit) > 0.6
	end
	for _, s in scrabblers do
		if s.state ~= "dead" and aimed(s.model.PrimaryPart :: BasePart) then
			return "scrabbler", s
		end
	end
	if knocker.state ~= "dormant" and aimed(knocker.model.PrimaryPart :: BasePart) then
		return "knocker", knocker
	end
	if wader and aimed(wader.model.PrimaryPart :: BasePart) then
		return "wader", wader
	end
	return nil, nil
end

function CreatureService.useTool(player: Player, itemId: string)
	local sess = services.PlayerService.get(player)
	if not sess or Inventory.count(sess.profile.inventory, itemId) < 1 or sess.vitals.condition == "downed" or sess.hiddenAt then
		return
	end
	local now = os.clock()
	if now - (lastSwing[player] or 0) < 0.8 then
		return
	end
	lastSwing[player] = now
	if itemId == "tool.iron_bar" then
		local which, inst = facing(player, 8)
		if which == "scrabbler" then
			local s = inst :: Scrabbler
			s.health -= 25
			cueAll((s.model.PrimaryPart :: BasePart).Position, 40, "scrabbler_hurt")
			if s.health <= 0 then
				s.state = "dead"
				s.respawnAt = now + 8 * 60
				scrabEnd(s, true)
				evidence(player, SCRAB, "stunned_or_killed")
				services.PlayerService.notify(player, "The scrabbler is dead.", "info")
				for _, p in s.model:GetChildren() do
					if p:IsA("BasePart") then
						p.Color = Color3.fromRGB(40, 36, 32)
					end
				end
				-- No loot from the corpse: encounters cannot be farmed (section 10).
			end
		elseif which == "knocker" or which == "wader" then
			-- Ordinary weapons fail visibly against an unkillable creature (T05).
			local bp = (if which == "knocker" then knocker.model.PrimaryPart else wader.model.PrimaryPart) :: BasePart
			services.PlayerService.send(player, "cue", { id = "weapon_ineffective", position = bp.Position })
			services.PlayerService.notify(player, "The bar glances off. It cannot be hurt like this.", "warn")
		end
	elseif itemId == "tool.stun_device" then
		local charges = sess.profile.toolCharges["tool.stun_device"]
		if charges == nil then
			charges = 3
		end
		if charges <= 0 then
			services.PlayerService.notify(player, "The stun device is out of charge.", "warn")
			return
		end
		local which, inst = facing(player, 14)
		if not which then
			return
		end
		sess.profile.toolCharges["tool.stun_device"] = charges - 1
		services.SaveService.markDirty(player)
		if which == "scrabbler" then
			local s = inst :: Scrabbler
			s.state = "stunned"
			s.stateUntil = now + 3
			scrabEnd(s, true)
			evidence(player, SCRAB, "stunned_or_killed")
		elseif which == "knocker" then
			if knocker.state == "knocking" then
				-- interrupted attack: the stun window is during the knocks
				knocker.state = "stunned"
				knocker.nextAt = now + KNOCK.stunSeconds
				evidence(player, KNOCK, "stunned_window")
				cueAll((knocker.model.PrimaryPart :: BasePart).Position, 50, "knocker_stunned")
			else
				services.PlayerService.notify(player, "Too late: it is already committed to the charge.", "warn")
			end
		elseif which == "wader" then
			-- repelled briefly, never killed
			waderEnd(true)
			wader.state = "repelled"
			wader.stateUntil = now + WADER.repelSeconds
			wader.goal = nil
			evidence(player, WADER, "distracted_or_repelled")
			cueAll((wader.model.PrimaryPart :: BasePart).Position, 50, "wader_repelled")
		end
		services.PlayerService.send(player, "cue", { id = "stun_fired" })
	end
end

function CreatureService.init(s)
	services = s
end

function CreatureService.start()
	for _, homes in SCRAB.homes do
		table.insert(scrabblers, spawnScrabbler(homes))
	end
	spawnKnocker()
	spawnWader()
	Players.PlayerRemoving:Connect(function(p)
		lastSighting[p] = nil
		lastSwing[p] = nil
		if sideState.watcher == p and sideState.model then
			sideState.model:Destroy()
			sideState.model = nil
		end
	end)
	local TICK = 1 / 15
	task.spawn(function()
		while true do
			local dt = task.wait(TICK)
			debug.profilebegin("Creatures")
			local ok, err = pcall(function()
				for _, s in scrabblers do
					scrabblerTick(s, dt)
				end
				knockerTick(dt)
				waderTick(dt)
				sidelookerTick(dt)
			end)
			debug.profileend()
			if not ok then
				warn("[CreatureService]", err)
			end
		end
	end)
end

return CreatureService
