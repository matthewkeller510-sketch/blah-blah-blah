--!strict
-- C08 Lantern Thief (advanced stalker, damaging, cannot be killed; docs/MILESTONE-3.md 4.3). Roams R04/R05 between
-- its homes and stalks the traveller carrying the brightest light that is not its own (an open lantern exposes its
-- carrier; a lit flare outshines everything). A faint glass rattle (thief_rattle, essential) announces it.
-- States (section 11): roam (idle/search) -> stalk (stalking, out of view, at the director's distance) -> warn
-- (essential rattle) -> approach (pursuit) -> strike -> withdraw (disengage); decoyed and repelled also disengage.
-- Approach needs ALL of: the victim has read Elise's warning note (discovery R04.thief_notes, the counter evidence),
-- the director allows a damaging threat for that victim (per-victim and server caps, recovery intervals, pressure at
-- or above the threshold: poorly supplied travellers), and the victim is not watching it. Before the note it only
-- stalks and can be sighted; it never strikes.
-- Counters: a lit flare within Config.Creatures.thiefDecoyRadius of it or its victim diverts it; breaking line of
-- sight (walls, darkness, hiding) for thiefLoseSightSeconds loses the victim; a stun repels it; melee glances off.
-- A strike damages (PlayerService.damage) and snuffs the light (PlayerService.snuffLight: charge unchanged); it never
-- takes items.

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Director = require(Shared.Logic.Director)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local LanternThief = {}
local services: any

local THIEF = WorldDefs.Creatures.C08_LanternThief
local C = Config.Creatures
local R = CreatureRules.Thief
local LIFT = 5 -- it hangs: body centre 5 studs above the floor
local SEEN_CHECK_SECONDS = 0.25
local SEARCH_SECONDS = 0.25 -- how often a roaming thief looks for a light
local STRIKE_CUE_RADIUS = 40
local REPEL_CUE_RADIUS = 50
local OWNER_WITNESS_RADIUS = 60 -- a flare's owner this close sees the decoy work
local FLARE_MEMORY_SECONDS = 120

type State = "roam" | "stalk" | "warn" | "approach" | "withdraw" | "decoyed" | "repelled"
type Rec = {
	model: Model,
	state: State,
	victim: Player?,
	engaged: boolean, -- a director threat is open on the victim (warn/approach)
	stateUntil: number,
	home: string,
	goal: Vector3?,
	lostFor: number, -- seconds without sight of the victim's light
	lastKnown: Vector3?,
	nextRattle: number,
	cooldownUntil: number,
	nextSearch: number,
}

local thief: Rec? = nil
local usedFlares: { [string]: number } = {} -- flare key -> when it decoyed the thief (each flare decoys once)
-- weak keys: a write during a departing player's final save never pins the Player (review R2 finding 12)
local ignoreUntil: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
local seenCheckAt = 0

local function inRegions(regionId: string): boolean
	return table.find(THIEF.regions, regionId) ~= nil
end

local function hasCounterEvidence(p: Player): boolean
	local s = services.PlayerService.get(p)
	return s ~= nil and s.profile.discoveries[THIEF.counterEvidence] == true
end

local function scoreOf(light: Common.LightState): number
	local def = if light.itemId then ItemDefs.get(light.itemId) else nil
	return CreatureRules.lightScore({
		on = light.on,
		isLantern = light.isLantern,
		shielded = light.shielded,
		brightness = if def and def.brightness then def.brightness else 1,
	}, Config.Lantern.exposureMultiplier)
end

local function floorOf(t: Rec): Vector3
	return (t.model.PrimaryPart :: BasePart).Position - Vector3.new(0, LIFT, 0)
end

-- A home it can reach from where it is (closed gates can cut one off); `avoid` skips the current home if possible.
local function pickHome(t: Rec, avoid: boolean): string
	local here = Common.nearestNode(floorOf(t))
	local options = {}
	for _, h in THIEF.homes do
		if (not avoid or h ~= t.home) and (h == here or #Common.route(here, h) > 0) then
			table.insert(options, h)
		end
	end
	return if #options > 0 then options[math.random(1, #options)] else t.home
end

-- Ends any hold on the victim. Closes the director threat exactly once (chase recovery, plus `recovery` seconds).
local function release(t: Rec, recovery: number?)
	local v = t.victim
	if v then
		if t.engaged then
			services.DirectorService.endThreat(v, true, recovery)
		end
		ignoreUntil[v] = os.clock() + R.victimIgnoreSeconds
	end
	t.engaged = false
	t.victim = nil
	t.lostFor = 0
	t.lastKnown = nil
end

local function toRoam(t: Rec, cooldown: number)
	t.state = "roam"
	t.goal = nil
	t.cooldownUntil = os.clock() + cooldown
end

-- The victim broke its sight long enough (or hid): it loses them.
local function lose(t: Rec, at: Vector3)
	local v = t.victim
	if v then
		Common.cueTo(v, "thief_lost", at)
		Common.evidence(v, THIEF, "lost_by_breaking_sight")
	end
	release(t, nil)
	toRoam(t, R.encounterCooldown)
end

local function decoy(t: Rec, flare: Common.Flare, at: Vector3)
	local now = os.clock()
	usedFlares[flare.key] = now
	local v = t.victim
	local heard = Common.cueAll(at, R.rattleRadius, "thief_decoyed")
	if v then
		if not table.find(heard, v) then
			Common.cueTo(v, "thief_decoyed", at) -- the victim always learns the decoy worked
		end
		Common.evidence(v, THIEF, "decoyed_by_flare")
	end
	local owner = flare.owner
	if owner and owner ~= v then
		local opos = services.PlayerService.position(owner)
		if opos and (opos - at).Magnitude <= OWNER_WITNESS_RADIUS then
			Common.evidence(owner, THIEF, "decoyed_by_flare")
		end
	end
	release(t, nil)
	t.state = "decoyed"
	t.goal = flare.position
	t.stateUntil = now + C.thiefDecoySeconds
end

local function strike(t: Rec, v: Player, at: Vector3)
	local ps = services.PlayerService
	ps.damage(v, C.thiefDamage, true, "C08")
	if ps.snuffLight then
		ps.snuffLight(v) -- switched off; battery charge unchanged
	end
	Common.cueAll(at, STRIKE_CUE_RADIUS, "thief_strike")
	release(t, R.strikeRecoverySeconds) -- recovery interval for the victim after a strike
	t.state = "withdraw"
	t.stateUntil = os.clock() + R.withdrawSeconds
	t.home = pickHome(t, true)
end

local function findVictim(at: Vector3): Player?
	local now = os.clock()
	local players: { Player } = {}
	local cands: { CreatureRules.Candidate } = {}
	for p, sess in services.PlayerService.all() do
		if not Common.active(p, sess) or not inRegions(sess.regionId) or (ignoreUntil[p] or 0) > now then
			continue
		end
		local pos = services.PlayerService.position(p)
		if not pos then
			continue
		end
		local light = Common.light(p)
		local score = scoreOf(light)
		if score <= 0 then
			continue -- no working light: nothing to draw it
		end
		local radius = THIEF.sightRadius * Director.exposure(light, Config.Lantern.exposureMultiplier)
		local d = (pos - at).Magnitude
		if d <= radius and CreatureRules.noticed(d, radius, Common.lineOfSight(at, pos)) then
			table.insert(players, p)
			table.insert(cands, { score = score, dist = d })
		end
	end
	local i = CreatureRules.pickVictim(cands)
	return if i then players[i] else nil
end

local function tickRoam(t: Rec, dt: number, at: Vector3)
	local now = os.clock()
	if now >= t.cooldownUntil and now >= t.nextSearch then
		t.nextSearch = now + SEARCH_SECONDS
		local v = findVictim(at)
		if v then
			t.victim = v
			t.state = "stalk"
			t.lostFor = 0
			t.lastKnown = services.PlayerService.position(v)
			t.nextRattle = now + 1.5
			return
		end
	end
	local homePos = Common.nodes[t.home]
	if (at - (homePos + Vector3.new(0, LIFT, 0))).Magnitude > 3 then
		local _, blocked = Common.travel(t.model, homePos, LIFT, THIEF.walkSpeed, dt)
		if blocked then
			t.home = pickHome(t, true)
		end
	elseif math.random() < CreatureRules.chance(R.homeRatePerSecond, dt) then
		t.home = pickHome(t, true)
	end
end

-- stalk / warn / approach: the hunt for one victim.
local function tickHunt(t: Rec, dt: number, at: Vector3)
	local now = os.clock()
	local v = t.victim
	local vs = v and services.PlayerService.get(v)
	local vpos = v and services.PlayerService.position(v)
	if not v or not vs or not vpos then
		release(t, nil)
		toRoam(t, R.encounterCooldown)
		return
	end
	if vs.hiddenAt then
		lose(t, at) -- hiding breaks its sight at once (F07)
		return
	end
	if not Common.active(v, vs) or not inRegions(vs.regionId) then
		-- a shelter, downed, or out of its regions: it lets go
		release(t, nil)
		toRoam(t, R.encounterCooldown)
		return
	end
	local los = Common.lineOfSight(at, vpos)
	local hasSight = los and Common.light(v).on -- it follows the light: a wall or darkness breaks its sight
	local lostNow
	t.lostFor, lostNow = CreatureRules.sightTimer(t.lostFor, hasSight, dt, C.thiefLoseSightSeconds)
	if lostNow then
		lose(t, at)
		return
	end
	if hasSight then
		t.lastKnown = vpos
	end
	local d = (vpos - at).Magnitude
	if t.state ~= "approach" and now >= t.nextRattle and d <= R.rattleRadius then
		t.nextRattle = now + R.rattleInterval
		for _, p in Common.cueAll(at, R.rattleRadius, "thief_rattle") do
			Common.evidence(p, THIEF, "heard_rattle")
		end
	end
	if t.state == "stalk" then
		local watched = Common.watching(v, at, THIEF.sightRadius, R.seenCos)
		local stalkD = CreatureRules.thiefStalkDistance(services.DirectorService.stalkDistance(v))
		if not watched then
			if d > stalkD or not hasSight then
				local goal = (t.lastKnown or vpos) - Vector3.new(0, 3, 0)
				local _, blocked = Common.travel(t.model, goal, LIFT, THIEF.walkSpeed, dt)
				if blocked then
					release(t, nil)
					toRoam(t, R.encounterCooldown)
					return
				end
			else
				Common.face(t.model, vpos)
			end
		end -- while watched it hangs perfectly still
		if hasSight and d <= stalkD + 6 and not watched and hasCounterEvidence(v) then
			local allows = services.DirectorService.mayEngage(v, R.engageThreshold)
			if CreatureRules.thiefMayApproach(true, allows, watched) then
				services.DirectorService.beginThreat(v)
				t.engaged = true
				t.state = "warn"
				t.stateUntil = now + R.warnSeconds
				t.nextRattle = now + R.rattleInterval
				-- the essential warning reaches the victim even at the edge of the stalking distance (T04)
				-- warn = true: this rattle starts an approach (screens step aside); the periodic stalking rattle does not
				for _, p in Common.cueAll(at, math.max(R.rattleRadius, d + 5), "thief_rattle", { warn = true }) do
					Common.evidence(p, THIEF, "heard_rattle")
				end
			end
		end
		return
	end
	if t.state == "warn" then
		Common.face(t.model, vpos)
		if now >= t.stateUntil then
			t.state = "approach"
			t.stateUntil = now + R.approachMaxSeconds
		end
		return
	end
	-- approach
	if CreatureRules.thiefMayStrike(t.state, hasCounterEvidence(v), d, THIEF.reach, los) then
		strike(t, v, at)
		return
	end
	if now > t.stateUntil then
		release(t, nil) -- it never connected
		toRoam(t, R.encounterCooldown)
		return
	end
	local goal = (if hasSight then vpos else (t.lastKnown or vpos)) - Vector3.new(0, 3, 0)
	if hasSight then
		Common.approach(t.model, goal, LIFT, THIEF.approachSpeed, dt) -- never straight through a pocket's rock
	else
		local _, blocked = Common.travel(t.model, goal, LIFT, THIEF.approachSpeed, dt)
		if blocked then
			lose(t, at)
		end
	end
end

function LanternThief.tick(dt: number)
	local t = thief
	if not t then
		return
	end
	local now = os.clock()
	local at = (t.model.PrimaryPart :: BasePart).Position
	-- sightings: anyone deliberately looking at it within its sight radius
	if now >= seenCheckAt then
		seenCheckAt = now + SEEN_CHECK_SECONDS
		for p, sess in services.PlayerService.all() do
			if Common.perceivable(p, sess) and Common.watching(p, at, THIEF.sightRadius, R.seenCos) then
				Common.evidence(p, THIEF, "seen")
			end
		end
		for key, when in usedFlares do
			if now - when > FLARE_MEMORY_SECONDS then
				usedFlares[key] = nil
			end
		end
	end
	-- a lit flare near it or its victim outshines any carried light (decoy)
	if t.state == "roam" or t.state == "stalk" or t.state == "warn" or t.state == "approach" then
		local flares = Common.flares()
		if #flares > 0 then
			local refs: { CreatureRules.FlareRef } = {}
			for _, f in flares do
				table.insert(refs, { position = Common.v3(f.position), key = f.key })
			end
			local vpos = if t.victim then services.PlayerService.position(t.victim) else nil
			local pick = CreatureRules.pickDecoy(
				refs,
				Common.v3(at),
				if vpos then Common.v3(vpos) else nil,
				C.thiefDecoyRadius,
				usedFlares
			)
			if pick then
				for _, f in flares do
					if f.key == pick.key then
						decoy(t, f, at)
						return
					end
				end
			end
		end
	end
	if t.state == "roam" then
		tickRoam(t, dt, at)
	elseif t.state == "stalk" or t.state == "warn" or t.state == "approach" then
		tickHunt(t, dt, at)
	elseif t.state == "decoyed" then
		if t.goal then
			local arrived, blocked = Common.travel(t.model, t.goal, LIFT, THIEF.approachSpeed, dt)
			if arrived or blocked then
				t.goal = nil -- hangs by the flare
			end
		end
		if now >= t.stateUntil then
			toRoam(t, R.encounterCooldown)
		end
	else -- withdraw / repelled: back off toward a home, then roam after a cooldown
		Common.travel(t.model, Common.nodes[t.home], LIFT, THIEF.approachSpeed, dt)
		if now >= t.stateUntil then
			toRoam(t, R.encounterCooldown)
		end
	end
end

local function onStun(player: Player): boolean
	local t = thief
	if not t then
		return false
	end
	if not CreatureRules.thiefStunRepels(t.state) then
		services.PlayerService.notify(player, "It is already recoiling.", "info")
		return false
	end
	release(t, nil)
	t.state = "repelled"
	t.goal = nil
	t.stateUntil = os.clock() + THIEF.repelSeconds
	t.home = pickHome(t, true)
	Common.cueAll((t.model.PrimaryPart :: BasePart).Position, REPEL_CUE_RADIUS, "thief_repelled")
	return true
end

-- Weapons glance off (unkillable); a stun repels it.
function LanternThief.targets(): { Common.Target }
	local t = thief
	if not t then
		return {}
	end
	return { { part = t.model.PrimaryPart :: BasePart, kind = "unkillable", onStun = onStun } }
end

function LanternThief.onPlayerRemoving(p: Player)
	local t = thief
	if t and t.victim == p then
		release(t, nil)
		toRoam(t, R.encounterCooldown)
	end
	ignoreUntil[p] = nil
end

function LanternThief.init(s)
	services = s
end

local function build(regionId: string): Model
	-- a gaunt hanging body ringed by several trapped dim lights (section 10); greybox from parts
	local m = Common.body(
		"LanternThief",
		regionId,
		Vector3.new(1, 7, 0.8),
		Color3.fromRGB(44, 42, 40),
		Enum.Material.SmoothPlastic
	)
	Common.addPart(
		m,
		"Head",
		Vector3.new(0.9, 1.1, 0.9),
		CFrame.new(0, 3.9, -0.4) * CFrame.Angles(math.rad(-25), 0, 0),
		Color3.fromRGB(58, 54, 50),
		Enum.Material.SmoothPlastic
	)
	for _, side in { -1, 1 } do
		Common.addPart(
			m,
			"LongArm",
			Vector3.new(0.3, 6.5, 0.3),
			CFrame.new(side * 0.85, -0.8, -0.2) * CFrame.Angles(math.rad(8), 0, math.rad(side * 6)),
			Color3.fromRGB(50, 46, 44),
			Enum.Material.SmoothPlastic
		)
	end
	for i = 1, 5 do
		local a = i * (2 * math.pi / 5)
		local glass = Common.addPart(
			m,
			"TrappedLight",
			Vector3.new(0.45, 0.6, 0.45),
			CFrame.new(math.cos(a) * 1.3, -1.5 + (i % 3) * 1.2, math.sin(a) * 1.3),
			Color3.fromRGB(226, 196, 130),
			Enum.Material.Neon
		)
		glass.Transparency = 0.45
	end
	local glow = Instance.new("PointLight")
	glow.Range = 7
	glow.Brightness = 0.5
	glow.Color = Color3.fromRGB(226, 196, 130)
	glow.Shadows = false
	glow.Parent = m.PrimaryPart
	m:SetAttribute("CreatureId", THIEF.id)
	-- PROPOSED (review finding 10): inside a pocket's bounds plus margin it postpones that pocket's change, like a
	-- rescue survivor, so the passage it is following never turns to rock round it. Its regions (R04, R05) hold no
	-- other PocketBlocker check: PuzzleService's tagged-blocker reverts are in R01 and R03, and P03 counts players only.
	CollectionService:AddTag(m, "PocketBlocker")
	return m
end

function LanternThief.start()
	local home = THIEF.homes[1]
	local regionId = Common.nodeRegion[home]
	if not regionId then
		warn("[LanternThief] unknown home " .. tostring(home))
		return
	end
	local m = build(regionId)
	m:PivotTo(CFrame.new(Common.nodes[home] + Vector3.new(0, LIFT, 0)))
	thief = {
		model = m,
		state = "roam",
		victim = nil,
		engaged = false,
		stateUntil = 0,
		home = home,
		goal = nil,
		lostFor = 0,
		lastKnown = nil,
		nextRattle = 0,
		cooldownUntil = os.clock() + R.encounterCooldown, -- a quiet start
		nextSearch = 0,
	}
end

return LanternThief
