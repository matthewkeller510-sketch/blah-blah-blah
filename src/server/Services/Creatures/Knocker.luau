--!strict
-- C07 Knocker (line-charge threat, cannot be killed). Lives at the ends of the long straight corridor between Split
-- Pier and Rusted Pulley. Exactly three knocks announce the charge; leave the line or stun it while it knocks.
-- The lane is derived from the two chambers' positions and sizes. Anyone who looks at it while it is out of the floor
-- has "seen" it, the first research stage (review R2 finding 8).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Common = require(script.Parent.Common)

local Knocker = {}
local services: any

local KNOCK = WorldDefs.Creatures.C07_Knocker
local ENGAGE_THRESHOLD = 0.2
local COOLDOWN_SECONDS = 40
local LANE_HALF_WIDTH = 7
local BODY_HALF_HEIGHT = 3.75
local SEEN_RADIUS = 70 -- TUNE: the whole lane (about 65 studs) from either end
local SEEN_COS = 0.7 -- TUNE: within about 45 degrees of the look direction

local pierDef = assert(WorldDefs.chamber("R01.split_pier"), "Knocker lane needs R01.split_pier")
local pulleyDef = assert(WorldDefs.chamber("R01.rusted_pulley"), "Knocker lane needs R01.rusted_pulley")
local laneX = pierDef.pos.x
local laneY = pierDef.pos.y
local laneZ0 = pierDef.pos.z + pierDef.size.z / 2 + 2
local laneZ1 = pulleyDef.pos.z - pulleyDef.size.z / 2 - 2
local PARK = Vector3.new(laneX, laneY - 30, laneZ0) -- dormant below the floor, out of play

type Rec = {
	model: Model,
	state: "dormant" | "knocking" | "charging" | "recovering" | "stunned",
	target: Player?,
	knocks: number,
	nextAt: number,
	dir: number,
	endZ: number,
	hit: { [Player]: boolean },
	seen: { [Player]: boolean }, -- who has sighted it since it last emerged
	cooldownUntil: number,
}

local knocker: Rec? = nil

local function place(k: Rec, pos: Vector3, facingDir: Vector3)
	k.model:PivotTo(CFrame.lookAt(pos, pos + facingDir))
end

local function inLane(pos: Vector3): boolean
	return math.abs(pos.X - laneX) < LANE_HALF_WIDTH
		and pos.Z > laneZ0
		and pos.Z < laneZ1
		and pos.Y > laneY - 4
		and pos.Y < laneY + 12
end

local function finish(k: Rec, now: number)
	if k.target then
		services.DirectorService.endThreat(k.target, true)
	end
	k.target = nil
	k.state = "dormant"
	k.cooldownUntil = now + COOLDOWN_SECONDS
	place(k, PARK, Vector3.new(0, 0, 1))
end

function Knocker.tick(dt: number)
	local k = knocker
	if not k then
		return
	end
	local now = os.clock()
	if k.state == "dormant" then
		if now < k.cooldownUntil then
			return
		end
		for p, sess in services.PlayerService.all() do
			local pos = services.PlayerService.position(p)
			if
				pos
				and inLane(pos)
				and Common.active(p, sess)
				and services.DirectorService.mayEngage(p, ENGAGE_THRESHOLD)
			then
				k.target = p
				services.DirectorService.beginThreat(p)
				-- emerge at the far end from the player's direction of travel
				local fromPier = (pos.Z - laneZ0) < (laneZ1 - pos.Z)
				local startZ = if fromPier then laneZ1 - 2 else laneZ0 + 2
				k.dir = if fromPier then -1 else 1
				k.endZ = if fromPier then laneZ0 - 6 else laneZ1 + 6
				place(k, Vector3.new(laneX, laneY + BODY_HALF_HEIGHT, startZ), Vector3.new(0, 0, k.dir))
				k.state = "knocking"
				k.knocks = 0
				k.nextAt = now + 0.6
				k.hit = {}
				k.seen = {}
				return
			end
		end
		return
	end
	local bp = k.model.PrimaryPart :: BasePart
	-- out of the floor (knocking, charging, recovering or stunned) it can be sighted
	for p, sess in services.PlayerService.all() do
		if not k.seen[p] and Common.perceivable(p, sess) and Common.watching(p, bp.Position, SEEN_RADIUS, SEEN_COS) then
			k.seen[p] = true
			Common.evidence(p, KNOCK, "seen")
		end
	end
	if k.state == "knocking" then
		if now >= k.nextAt then
			k.knocks += 1
			local heard = Common.cueAll(bp.Position, 90, "knocker_knock", { index = k.knocks, of = KNOCK.knockCount })
			if k.knocks >= KNOCK.knockCount then
				for _, p in heard do
					Common.evidence(p, KNOCK, "heard_three_knocks")
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
		place(k, pos, Vector3.new(0, 0, k.dir))
		for p, sess in services.PlayerService.all() do
			local pp = services.PlayerService.position(p)
			if
				pp
				and not k.hit[p]
				and Common.active(p, sess) -- never a downed player being rescued
				and math.abs(pp.X - pos.X) < 4
				and math.abs(pp.Z - pos.Z) < 3
				and pp.Y > laneY - 4
				and pp.Y < laneY + 12
				-- a bystander already facing another damaging threat is not stacked (per-victim cap)
				and (p == k.target or services.DirectorService.activeThreats(p) == 0)
			then
				k.hit[p] = true
				services.PlayerService.damage(p, KNOCK.damage, true, "knocker")
			end
		end
		if (k.dir > 0 and pos.Z >= k.endZ) or (k.dir < 0 and pos.Z <= k.endZ) then
			local t = k.target
			if t and not k.hit[t] then
				Common.evidence(t, KNOCK, "dodged_at_junction")
			end
			k.state = "recovering"
			k.nextAt = now + KNOCK.stunSeconds
			Common.cueAll(bp.Position, 60, "knocker_impact")
		end
		return
	end
	if k.state == "recovering" or k.state == "stunned" then
		if now >= k.nextAt then
			finish(k, now)
		end
	end
end

local function onStun(player: Player): boolean
	local k = knocker
	if not k then
		return false
	end
	if k.state ~= "knocking" then
		services.PlayerService.notify(player, "Too late: it is already committed to the charge.", "warn")
		return false -- the stun window is during the knocks; no charge is spent outside it
	end
	-- interrupted attack: the stun window is during the knocks
	k.state = "stunned"
	k.nextAt = os.clock() + KNOCK.stunSeconds
	Common.evidence(player, KNOCK, "stunned_window")
	Common.cueAll((k.model.PrimaryPart :: BasePart).Position, 50, "knocker_stunned")
	return true
end

function Knocker.targets(): { Common.Target }
	local k = knocker
	if not k or k.state == "dormant" then
		return {}
	end
	return { { part = k.model.PrimaryPart :: BasePart, kind = "unkillable", onStun = onStun } }
end

function Knocker.onPlayerRemoving(p: Player)
	local k = knocker
	if k then
		k.hit[p] = nil
		k.seen[p] = nil
		if k.target == p then
			k.target = nil -- the director already dropped this player's record; the charge finishes on its own
		end
	end
end

function Knocker.init(s)
	services = s
end

function Knocker.start()
	local m = Common.body("Knocker", "R01", Vector3.new(4.5, 7.5, 3.5), Color3.fromRGB(64, 58, 52), Enum.Material.Rock)
	m:PivotTo(CFrame.new(PARK))
	Common.addPart(
		m,
		"FoldedForelimbs",
		Vector3.new(5.2, 2, 2),
		CFrame.new(0, 1, -1.6),
		Color3.fromRGB(80, 72, 64),
		Enum.Material.Rock
	)
	m:SetAttribute("CreatureId", KNOCK.id)
	knocker = {
		model = m,
		state = "dormant",
		target = nil,
		knocks = 0,
		nextAt = 0,
		dir = 1,
		endZ = laneZ1,
		hit = {},
		seen = {},
		cooldownUntil = 0,
	}
end

return Knocker
