--!strict
-- C06 Wader (water-sensitive stalker, cannot be killed). Blind; hears splashes. Crouch-wading, stepping stones, dry
-- floors and hiding are silent. A thrown stone that lands in water draws it away. It can be repelled briefly but
-- never killed. Its region comes from its homes (no hard-coded region).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local Wader = {}
local services: any

local WADER = WorldDefs.Creatures.C06_Wader
local LIFT = 4.5 -- half its body height: feet on the floor, head below corridor ceilings
local ENGAGE_THRESHOLD = 0.2
local HOME_SWITCH_RATE = 0.06 -- per second at home (was 0.4% per tick at 15 Hz)
local RIPPLE_RATE = 0.15 -- per second at home (was 1% per tick at 15 Hz)
local REGION = Common.nodeRegion[WADER.homes[1]]

type Rec = {
	model: Model,
	state: "wander" | "listening" | "pursue" | "recover" | "repelled",
	target: Player?,
	goal: Vector3?,
	stateUntil: number,
	lastHeard: number,
	home: string,
	engaged: boolean,
}

local wader: Rec? = nil

local function spawn(): Rec
	local home = WADER.homes[1]
	local m =
		Common.body("Wader", REGION, Vector3.new(2.2, 9, 1.6), Color3.fromRGB(58, 66, 62), Enum.Material.SmoothPlastic)
	m:PivotTo(CFrame.new(Common.nodes[home] + Vector3.new(0, LIFT, 0)))
	Common.addPart(
		m,
		"LongArmL",
		Vector3.new(0.5, 7, 0.5),
		CFrame.new(-1.5, -1, -0.2) * CFrame.Angles(0.1, 0, 0.08),
		Color3.fromRGB(50, 58, 54),
		Enum.Material.SmoothPlastic
	)
	Common.addPart(
		m,
		"LongArmR",
		Vector3.new(0.5, 7, 0.5),
		CFrame.new(1.5, -1, -0.2) * CFrame.Angles(0.1, 0, -0.08),
		Color3.fromRGB(50, 58, 54),
		Enum.Material.SmoothPlastic
	)
	Common.addPart(
		m,
		"Head",
		Vector3.new(1.4, 1.6, 1.2),
		CFrame.new(0, 5.3, -0.3),
		Color3.fromRGB(72, 80, 74),
		Enum.Material.SmoothPlastic
	)
	m:SetAttribute("CreatureId", WADER.id)
	return {
		model = m,
		state = "wander",
		target = nil,
		goal = nil,
		stateUntil = 0,
		lastHeard = 0,
		home = home,
		engaged = false,
	}
end

local function waderEnd(w: Rec, wasChase: boolean)
	if w.engaged and w.target then
		services.DirectorService.endThreat(w.target, wasChase)
	end
	w.engaged = false
	w.target = nil
end

-- Picks a home it can reach (a closed solid gate can cut one off; it wades through deep-water gates).
local function reachableHome(w: Rec): string?
	local here = Common.nearestNode((w.model.PrimaryPart :: BasePart).Position - Vector3.new(0, LIFT, 0))
	local options = {}
	for _, h in WADER.homes do
		if h == here or #Common.route(here, h, true) > 0 then
			table.insert(options, h)
		end
	end
	return if #options > 0 then options[math.random(1, #options)] else nil
end

-- Splashes from players (source) and thrown stones (source = nil, thrower = the player who threw).
function Wader.hear(pos: Vector3, loudness: number, source: Player?, thrower: Player?)
	local w = wader
	if not w or w.state == "repelled" or w.state == "recover" then
		return
	end
	if services.WorldBuilder.regionAt(pos) ~= REGION then
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
			Common.evidence(thrower, WADER, "distracted_or_repelled")
		end
		waderEnd(w, true)
		w.goal = pos
		w.state = "wander"
		return
	end
	if w.state == "pursue" and w.target == source then
		w.goal = pos -- blind tracking: it only updates on the next splash
		return
	end
	local ssess = services.PlayerService.get(source)
	local perceivable = ssess ~= nil and Common.perceivable(source, ssess)
	if w.state == "wander" and perceivable and services.DirectorService.mayEngage(source, ENGAGE_THRESHOLD) then
		w.target = source
		w.engaged = true
		services.DirectorService.beginThreat(source)
		w.goal = pos
		w.state = "listening"
		w.stateUntil = now + WADER.warnSeconds
		for _, p in Common.cueAll(bp.Position, 70, "wader_drag") do
			Common.evidence(p, WADER, "heard_drag")
		end
	elseif w.state == "wander" then
		w.goal = pos -- not allowed to engage yet: it drifts toward the sound without attacking
	end
end

function Wader.tick(dt: number)
	local w = wader
	if not w then
		return
	end
	local bp = w.model.PrimaryPart :: BasePart
	local now = os.clock()
	for p, sess in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if
			pos
			and Common.perceivable(p, sess)
			and (pos - bp.Position).Magnitude < 30
			and Common.lineOfSight(pos, bp.Position)
		then
			Common.evidence(p, WADER, "seen")
		end
	end
	if w.state == "repelled" or w.state == "recover" then
		if now > w.stateUntil then
			w.state = "wander"
		end
		if w.state == "repelled" then
			local _, blocked = Common.travel(w.model, Common.nodes[w.home], LIFT, WADER.walkSpeed, dt, true)
			if blocked then
				w.home = reachableHome(w) or w.home
			end
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
		if
			not t
			or not tsess
			or tsess.insideShelterId
			or tsess.vitals.condition == "downed" -- never finishes off a downed player (rescue must stay possible)
			or tsess.vitals.condition == "dead"
			or not WorldDefs.isTunnel(tsess.regionId)
		then
			waderEnd(w, true)
			w.state = "wander"
			return
		end
		local arrived = true
		if w.goal then
			local a, blocked = Common.travel(w.model, w.goal :: Vector3, LIFT, WADER.pursueSpeed, dt, true)
			arrived = a or blocked
		end
		local tpos = services.PlayerService.position(t)
		local flat = if tpos
			then Vector3.new(tpos.X - bp.Position.X, 0, tpos.Z - bp.Position.Z).Magnitude
			else math.huge
		if tpos and not tsess.hiddenAt and tsess.inWater and flat < 5 and math.abs(tpos.Y - bp.Position.Y) < 8 then
			services.PlayerService.damage(t, WADER.damage, true, "wader")
			Common.cueAll(bp.Position, 40, "wader_strike")
			waderEnd(w, true)
			w.state = "recover"
			w.stateUntil = now + 4
			return
		end
		if (arrived and now - w.lastHeard > 4) or now > w.stateUntil then
			-- silence wins: the player stayed quiet long enough
			Common.evidence(t, WADER, "evaded_by_silence")
			Common.cueAll(bp.Position, 50, "wader_lost")
			waderEnd(w, true)
			w.state = "wander"
		end
		return
	end
	-- wander: drift to a heard sound, otherwise between home pools
	if w.goal then
		local arrived, blocked = Common.travel(w.model, w.goal :: Vector3, LIFT, WADER.walkSpeed, dt, true)
		if arrived or blocked then
			w.goal = nil
		end
		return
	end
	if (bp.Position - (Common.nodes[w.home] + Vector3.new(0, LIFT, 0))).Magnitude < 3 then
		if math.random() < CreatureRules.chance(HOME_SWITCH_RATE, dt) then
			w.home = reachableHome(w) or w.home
		elseif math.random() < CreatureRules.chance(RIPPLE_RATE, dt) then
			Common.cueAll(bp.Position, 45, "wader_ripple")
		end
	else
		local _, blocked = Common.travel(w.model, Common.nodes[w.home], LIFT, WADER.walkSpeed, dt, true)
		if blocked then
			w.home = reachableHome(w) or w.home
		end
	end
end

local function onStun(player: Player): boolean
	local w = wader
	if not w then
		return false
	end
	if w.state == "repelled" then
		services.PlayerService.notify(player, "It is already recoiling.", "info")
		return false -- no second charge for nothing
	end
	-- repelled briefly, never killed
	waderEnd(w, true)
	w.state = "repelled"
	w.stateUntil = os.clock() + WADER.repelSeconds
	w.goal = nil
	Common.evidence(player, WADER, "distracted_or_repelled")
	Common.cueAll((w.model.PrimaryPart :: BasePart).Position, 50, "wader_repelled")
	return true
end

function Wader.targets(): { Common.Target }
	local w = wader
	if not w then
		return {}
	end
	return { { part = w.model.PrimaryPart :: BasePart, kind = "unkillable", onStun = onStun } }
end

function Wader.onPlayerRemoving(p: Player)
	local w = wader
	if w and w.target == p then
		waderEnd(w, true)
		w.state = "wander"
	end
end

function Wader.init(s)
	services = s
end

function Wader.start()
	wader = spawn()
end

return Wader
