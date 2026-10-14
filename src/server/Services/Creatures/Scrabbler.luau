--!strict
-- C05 Scrabbler (vulnerable predator, killable; one per home group). Searches noisy rubble routes, stalks at the
-- director's distance when it may not attack, accelerates after a visible wind-up. Breaking sight and quiet footing
-- help; stun and melee can kill it. Its corpse drops nothing and respawns later, so it cannot be farmed.

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Director = require(Shared.Logic.Director)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local Scrabbler = {}
local services: any

local SCRAB = WorldDefs.Creatures.C05_Scrabbler
local LIFT = 0.9
local ENGAGE_THRESHOLD = 0.25
local STALK_GIVE_UP_SECONDS = 4 -- TUNE: unseen and unheard this long, a stalk turns into a search
local STAGGER_SECONDS = 0.6 -- TUNE: a bar hit during the wind-up or rush makes it falter (consistent hit reaction)
local IDLE_CUE_RATE = 0.15 -- per second at home (was 1% per tick at 15 Hz)

type State = "idle" | "search" | "stalk" | "warning" | "rush" | "recover" | "stunned" | "dead"
type Rec = {
	model: Model,
	health: number,
	state: State,
	target: Player?,
	stalkTarget: Player?,
	lastPerceived: number,
	stateUntil: number,
	lastKnown: Vector3?,
	investigate: Vector3?,
	homes: { string },
	home: string,
	regionId: string,
	engaged: boolean,
	lastHit: number,
	respawnAt: number,
	staggerUntil: number,
}

local list: { Rec } = {}

local function spawn(homes: { string }): Rec
	local home = homes[math.random(1, #homes)]
	local regionId = Common.nodeRegion[home]
	local m =
		Common.body("Scrabbler", regionId, Vector3.new(3.6, 1.8, 5.5), Color3.fromRGB(70, 66, 58), Enum.Material.Slate)
	m:PivotTo(CFrame.new(Common.nodes[home] + Vector3.new(math.random(-6, 6), LIFT, math.random(-6, 6))))
	Common.addPart(
		m,
		"MineralPlates",
		Vector3.new(3, 0.6, 4.6),
		CFrame.new(0, 1.1, 0),
		Color3.fromRGB(120, 116, 108),
		Enum.Material.Basalt
	)
	m:SetAttribute("CreatureId", SCRAB.id)
	return {
		model = m,
		health = SCRAB.health,
		state = "idle",
		target = nil,
		stalkTarget = nil,
		lastPerceived = 0,
		stateUntil = 0,
		lastKnown = nil,
		investigate = nil,
		homes = homes,
		home = home,
		regionId = regionId,
		engaged = false,
		lastHit = 0,
		respawnAt = 0,
		staggerUntil = 0,
	}
end

local function scrabEnd(s: Rec, wasChase: boolean)
	if s.engaged and s.target then
		services.DirectorService.endThreat(s.target, wasChase)
	end
	s.engaged = false
	s.target = nil
end

-- NoisyFloor volumes are static after boot; refresh the tagged list now and then instead of every call.
local noisyFloors: { Instance } = {}
local noisyAt = -math.huge
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
	if os.clock() - noisyAt > 5 then
		noisyAt = os.clock()
		noisyFloors = CollectionService:GetTagged("NoisyFloor")
	end
	for _, inst in noisyFloors do
		if inst:IsA("BasePart") then
			local rel = inst.CFrame:PointToObjectSpace(pos)
			local h = inst.Size / 2
			if math.abs(rel.X) <= h.X and math.abs(rel.Z) <= h.Z and math.abs(rel.Y) <= h.Y + 4 then
				return true
			end
		end
	end
	return false
end

local function tickOne(s: Rec, dt: number)
	if s.state == "dead" then
		if os.clock() > s.respawnAt then
			s.model:Destroy()
			local fresh = spawn(s.homes)
			for k, v in fresh :: any do
				(s :: any)[k] = v
			end
			-- nil fields are not copied by the loop above; clear them explicitly
			s.investigate = nil
			s.lastKnown = nil
			s.target = nil
			s.stalkTarget = nil
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
	if s.state == "idle" or s.state == "search" or s.state == "stalk" then
		local best: Player?, bestD = nil, math.huge
		for p, sess in services.PlayerService.all() do
			if not Common.active(p, sess) or sess.regionId ~= s.regionId then
				continue
			end
			local pos = services.PlayerService.position(p) :: Vector3
			local d = (pos - bp.Position).Magnitude
			local heard = d < SCRAB.hearingRadius and noisy(p, sess)
			-- the effective light, never the raw toggle; an open lantern exposes its carrier further
			local factor = Director.sightFactor(Common.light(p), Config.Lantern.exposureMultiplier)
			local seen = d < SCRAB.sightRadius * factor and Common.lineOfSight(bp.Position + Vector3.new(0, 1, 0), pos)
			if (heard or seen) and d < bestD then
				best, bestD = p, d
			end
			if seen and d < 30 then
				Common.evidence(p, SCRAB, "seen")
			end
		end
		if best then
			s.lastKnown = services.PlayerService.position(best)
			s.lastPerceived = now
			-- Director gates the dangerous rush; otherwise it stalks at the director's distance (F06).
			if services.DirectorService.mayEngage(best, ENGAGE_THRESHOLD) then
				s.target = best
				s.engaged = true
				s.investigate = nil
				s.stalkTarget = nil
				services.DirectorService.beginThreat(best)
				s.state = "warning"
				s.stateUntil = now + SCRAB.windupSeconds
				for _, p in Common.cueAll(bp.Position, 60, "scrabbler_windup") do
					Common.evidence(p, SCRAB, "heard_scrape")
				end
				return
			end
			s.state = "stalk"
			s.stalkTarget = best
			s.investigate = nil
		elseif s.state == "stalk" and now - s.lastPerceived > STALK_GIVE_UP_SECONDS then
			s.state = "search"
			s.stalkTarget = nil
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
		if
			not t
			or not tpos
			or not tsess
			or tsess.insideShelterId
			or tsess.hiddenAt
			or tsess.vitals.condition == "downed" -- never finishes off a downed player (rescue must stay possible)
			or tsess.vitals.condition == "dead"
			or tsess.regionId ~= s.regionId
		then
			if t and tsess and tsess.hiddenAt then
				Common.evidence(t, SCRAB, "escaped_by_breaking_sight")
			end
			s.state = "search"
			scrabEnd(s, true)
			return
		end
		if now < s.staggerUntil then
			return -- faltering after a bar hit: no movement, no strike
		end
		local canSee = Common.lineOfSight(bp.Position + Vector3.new(0, 1, 0), tpos)
		if canSee then
			s.lastKnown = tpos
		end
		local goal = (s.lastKnown or tpos) - Vector3.new(0, 3, 0)
		if canSee then
			Common.moveModel(s.model, goal, LIFT, SCRAB.rushSpeed, dt)
		else
			local arrived, blocked = Common.travel(s.model, goal, LIFT, SCRAB.rushSpeed * 0.8, dt)
			if arrived or blocked then
				-- reached the last known position without sight: the player broke sight and escaped
				Common.evidence(t, SCRAB, "escaped_by_breaking_sight")
				s.state = "search"
				scrabEnd(s, true)
				return
			end
		end
		if (tpos - bp.Position).Magnitude < 4.5 and now - s.lastHit > 1.2 then
			s.lastHit = now
			services.PlayerService.damage(t, SCRAB.damage, true, "scrabbler")
			s.state = "recover"
			s.stateUntil = now + 2.5
			Common.cueAll(bp.Position, 40, "scrabbler_hit")
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
	if s.state == "stalk" then
		-- it works only from where it last sensed the target: a hidden player's real position is never used (F07)
		local t = s.stalkTarget
		local tsess = t and services.PlayerService.get(t)
		local known = s.lastKnown
		if not t or not tsess or not known or not Common.active(t, tsess) or tsess.regionId ~= s.regionId then
			s.state = "search"
			s.stalkTarget = nil
			return
		end
		if (known - bp.Position).Magnitude > services.DirectorService.stalkDistance(t) then
			local _, blocked = Common.travel(s.model, known - Vector3.new(0, 3, 0), LIFT, SCRAB.walkSpeed, dt)
			if blocked then
				s.state = "search"
				s.stalkTarget = nil
			end
		else
			Common.face(s.model, known) -- holds its distance and watches
		end
		return
	end
	-- idle / search: investigate a noise, otherwise wander back home slowly
	if s.investigate then
		local arrived, blocked = Common.travel(s.model, s.investigate, LIFT, SCRAB.walkSpeed * 1.4, dt)
		if arrived or blocked then
			s.investigate = nil
		end
		return
	end
	local homePos = Common.nodes[s.home]
	if (bp.Position - (homePos + Vector3.new(0, LIFT, 0))).Magnitude > 4 then
		Common.travel(s.model, homePos, LIFT, SCRAB.walkSpeed, dt)
	elseif math.random() < CreatureRules.chance(IDLE_CUE_RATE, dt) then
		Common.cueAll(bp.Position, 35, "scrabbler_idle")
	end
end

function Scrabbler.tick(dt: number)
	for _, s in list do
		tickOne(s, dt)
	end
end

-- A clatter (or a thrown stone's splash) draws idle or searching Scrabblers in its own region to investigate.
function Scrabbler.noise(pos: Vector3, kind: string, source: Player?)
	if not (kind == "clatter" or (kind == "splash" and source == nil)) then
		return
	end
	local region = Common.nodeRegion[Common.nearestNode(pos)]
	for _, s in list do
		if
			(s.state == "idle" or s.state == "search")
			and region == s.regionId
			and (pos - (s.model.PrimaryPart :: BasePart).Position).Magnitude < 35
		then
			s.investigate = pos
		end
	end
end

local function onBar(s: Rec, player: Player)
	if s.state == "dead" then
		return
	end
	local now = os.clock()
	local bar = ItemDefs.get("tool.iron_bar")
	s.health -= (bar and bar.meleeDamage) or 25
	Common.cueAll((s.model.PrimaryPart :: BasePart).Position, 40, "scrabbler_hurt")
	if s.health <= 0 then
		s.state = "dead"
		s.respawnAt = now + 8 * 60
		scrabEnd(s, true)
		s.stalkTarget = nil
		Common.evidence(player, SCRAB, "stunned_or_killed")
		services.PlayerService.notify(player, "The scrabbler is dead.", "info")
		for _, p in s.model:GetChildren() do
			if p:IsA("BasePart") then
				p.Color = Color3.fromRGB(40, 36, 32)
			end
		end
		-- No loot from the corpse: encounters cannot be farmed (section 10).
	elseif s.state == "warning" then
		s.stateUntil += STAGGER_SECONDS
	elseif s.state == "rush" then
		s.staggerUntil = now + STAGGER_SECONDS
		s.stateUntil += STAGGER_SECONDS
	end
end

local function onStun(s: Rec, player: Player): boolean
	if s.state == "dead" then
		return false
	end
	s.state = "stunned"
	s.stateUntil = os.clock() + 3
	scrabEnd(s, true)
	s.stalkTarget = nil
	Common.evidence(player, SCRAB, "stunned_or_killed")
	return true
end

function Scrabbler.targets(): { Common.Target }
	local out: { Common.Target } = {}
	for _, s in list do
		if s.state ~= "dead" then
			table.insert(out, {
				part = s.model.PrimaryPart :: BasePart,
				kind = "killable",
				onBar = function(p: Player)
					onBar(s, p)
				end,
				onStun = function(p: Player): boolean
					return onStun(s, p)
				end,
			})
		end
	end
	return out
end

function Scrabbler.onPlayerRemoving(p: Player)
	for _, s in list do
		if s.target == p then
			scrabEnd(s, true) -- no record is re-created for a player who left
			s.state = "search"
		end
		if s.stalkTarget == p then
			s.stalkTarget = nil
			s.state = "search"
		end
	end
end

function Scrabbler.init(s)
	services = s
end

function Scrabbler.start()
	for _, homes in SCRAB.homes do
		table.insert(list, spawn(homes))
	end
end

return Scrabbler
