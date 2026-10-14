--!strict
-- C02 Borrowed Miner (early mimic, harmless; docs/MILESTONE-3.md 4.3). One figure per home works a wall with an exact
-- rhythm (Config.Creatures.minerRhythmSeconds). When a player deliberately watches it, it walks the misleading path to
-- its dead end and fades there. A verified party ping nearby makes it fade at once: it never answers a verification.
-- It never damages, never uses a player name or party label and never sends on the "ping" channel.
-- Research: seen (watched), heard_exact_rhythm (three strokes within 30 studs), waited_for_repeat (three whole
-- phrases within 25 studs without leaving), failed_verification (your ping near it, or watching it fade).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local BorrowedMiner = {}
local services: any

local MINER = WorldDefs.Creatures.C02_BorrowedMiner
local R = CreatureRules.Miner
local LIFT = 2.75 -- half its 5.5-stud body: feet on the floor

type Miner = {
	workPos: Vector3,
	workFacing: Vector3,
	lurePos: Vector3,
	regionId: string,
	model: Model,
	state: "work" | "lure" | "gone",
	origin: number, -- the rhythm's time origin (stroke k falls at origin + k * rhythm)
	strokes: number, -- strokes already processed
	listeners: { [Player]: CreatureRules.MinerListen },
	respawnAt: number,
}

local miners: { Miner } = {}

local function v(t: { x: number, y: number, z: number }): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

local function centre(m: Miner): Vector3
	return (m.model.PrimaryPart :: BasePart).Position
end

local function build(regionId: string): Model
	-- old workwear, a face and joints subtly wrong (section 10); greybox from parts
	local m = Common.body(
		"BorrowedMiner",
		regionId,
		Vector3.new(1.8, 5.5, 1),
		Color3.fromRGB(92, 82, 64),
		Enum.Material.Fabric
	)
	Common.addPart(
		m,
		"Head",
		Vector3.new(1.1, 1.2, 1.1),
		CFrame.new(0.25, 3.3, 0) * CFrame.Angles(0, 0, math.rad(14)), -- tilted a little too far
		Color3.fromRGB(150, 138, 120),
		Enum.Material.SmoothPlastic
	)
	Common.addPart(
		m,
		"Helmet",
		Vector3.new(1.3, 0.4, 1.3),
		CFrame.new(0.4, 4, 0) * CFrame.Angles(0, 0, math.rad(14)),
		Color3.fromRGB(70, 66, 52),
		Enum.Material.Metal
	)
	Common.addPart(
		m,
		"ArmR",
		Vector3.new(0.45, 2.4, 0.45),
		CFrame.new(1.1, 1.2, -0.7) * CFrame.Angles(math.rad(-60), 0, 0),
		Color3.fromRGB(88, 78, 60),
		Enum.Material.Fabric
	)
	Common.addPart(
		m,
		"Pick",
		Vector3.new(0.2, 0.2, 3),
		CFrame.new(1.1, 1.9, -2.1),
		Color3.fromRGB(80, 70, 58),
		Enum.Material.Wood
	)
	Common.addPart(
		m,
		"PickHead",
		Vector3.new(0.25, 1.6, 0.25),
		CFrame.new(1.1, 1.9, -3.5),
		Color3.fromRGB(90, 90, 92),
		Enum.Material.Metal
	)
	m:SetAttribute("CreatureId", MINER.id)
	return m
end

local function placeAtWork(m: Miner)
	local at = m.workPos + Vector3.new(0, LIFT, 0)
	m.model:PivotTo(CFrame.lookAt(at, at + m.workFacing))
end

local function nearbyListener(sess: any): boolean
	return not sess.insideShelterId and sess.vitals.condition ~= "dead"
end

-- Fades. `pinger` is the player whose verified ping made it fade (it never answers a verification); otherwise it
-- reached its dead end and everyone watching sees it simply gone.
local function fade(m: Miner, pinger: Player?)
	local at = centre(m)
	if pinger then
		Common.evidence(pinger, MINER, "failed_verification")
	else
		for p, sess in services.PlayerService.all() do
			if Common.active(p, sess) and Common.watching(p, at, MINER.watchRadius, R.fadeWitnessCos) then
				Common.evidence(p, MINER, "failed_verification")
			end
		end
	end
	Common.cueAll(at, R.cueRadius, "miner_fade")
	m.state = "gone"
	m.respawnAt = os.clock() + R.respawnSeconds
	table.clear(m.listeners)
	m.model.Parent = nil
end

local function startLure(m: Miner)
	m.state = "lure"
	table.clear(m.listeners)
end

local function tickWork(m: Miner)
	local now = os.clock()
	local at = centre(m)
	-- deliberate watching sends it down the misleading path (hidden, downed and sheltered players never trigger it)
	local watched = false
	for p, sess in services.PlayerService.all() do
		if Common.active(p, sess) and Common.watching(p, at, MINER.watchRadius, R.watchCos) then
			Common.evidence(p, MINER, "seen")
			watched = true
		end
	end
	if watched then
		startLure(m)
		return
	end
	-- the exact rhythm: process strokes that came due (at most one per tick after a hitch, so no caption burst)
	local count = CreatureRules.strokeCount(m.origin, Config.Creatures.minerRhythmSeconds, now)
	if count <= m.strokes then
		return
	end
	m.strokes = count
	local caption = CreatureRules.minerCaptionDue(count)
	for p, sess in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		local track = m.listeners[p]
		if not pos or not nearbyListener(sess) or not Common.withinLevel(pos, at, R.cueRadius) then
			if track then
				m.listeners[p] = nil -- left earshot: the count starts again
			end
			continue
		end
		if caption then
			Common.cueTo(p, "miner_rhythm", at, { interval = Config.Creatures.minerRhythmSeconds })
		end
		if not track then
			track = CreatureRules.newListen()
			m.listeners[p] = track
		end
		local heard, waited = CreatureRules.minerListen(track, (pos - at).Magnitude)
		if heard then
			Common.evidence(p, MINER, "heard_exact_rhythm")
		end
		if waited then
			Common.evidence(p, MINER, "waited_for_repeat")
		end
	end
end

local function tickLure(m: Miner, dt: number)
	local at = centre(m)
	for p, sess in services.PlayerService.all() do
		if Common.active(p, sess) and Common.watching(p, at, MINER.watchRadius, R.watchCos) then
			Common.evidence(p, MINER, "seen")
		end
	end
	local arrived, blocked = Common.travel(m.model, m.lurePos, LIFT, MINER.walkSpeed, dt)
	if arrived or blocked then
		fade(m, nil)
	end
end

local function tickGone(m: Miner)
	local now = os.clock()
	if now < m.respawnAt then
		return
	end
	-- reappear only when nobody is near its work spot (never pops in in front of someone)
	for p in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		if pos and (pos - m.workPos).Magnitude < R.respawnClearRadius then
			return
		end
	end
	placeAtWork(m)
	m.model.Parent = services.WorldBuilder.folder(m.regionId)
	m.state = "work"
	m.origin = now
	m.strokes = 0
	table.clear(m.listeners)
end

function BorrowedMiner.tick(dt: number)
	for _, m in miners do
		if m.state == "work" then
			tickWork(m)
		elseif m.state == "lure" then
			tickLure(m, dt)
		else
			tickGone(m)
		end
	end
end

-- PartyService.onPing listener: a verified ping within 40 studs makes it fade immediately.
function BorrowedMiner.onPing(player: Player, position: Vector3)
	if typeof(position) ~= "Vector3" then
		return
	end
	for _, m in miners do
		if m.state ~= "gone" and CreatureRules.pingFades(Common.v3(position), Common.v3(centre(m))) then
			fade(m, player)
		end
	end
end

-- A harmless phenomenon: tools pass through it ("nothing to strike").
function BorrowedMiner.targets(): { Common.Target }
	local out: { Common.Target } = {}
	for _, m in miners do
		if m.state ~= "gone" then
			table.insert(out, { part = m.model.PrimaryPart :: BasePart, kind = "harmless" })
		end
	end
	return out
end

function BorrowedMiner.onPlayerRemoving(p: Player)
	for _, m in miners do
		m.listeners[p] = nil
	end
end

function BorrowedMiner.init(s)
	services = s
end

function BorrowedMiner.start()
	for i, home in MINER.homes do
		local c = WorldDefs.chamber(home.chamberId)
		if not c then
			warn("[BorrowedMiner] unknown chamber " .. tostring(home.chamberId))
			continue
		end
		local dir = CreatureRules.nearestWallDir(home.workPos, c.pos, c.size)
		local m: Miner = {
			workPos = v(home.workPos),
			workFacing = Vector3.new(dir.x, 0, dir.z),
			lurePos = v(home.lurePos),
			regionId = c.regionId,
			model = build(c.regionId),
			state = "work",
			origin = os.clock() + i * 0.37, -- the two figures do not strike in unison
			strokes = 0,
			-- weak keys: a write during a departing player's final save never pins the Player (review R2 finding 12)
			listeners = setmetatable({}, { __mode = "k" }) :: any,
			respawnAt = 0,
		}
		placeAtWork(m)
		table.insert(miners, m)
	end
end

return BorrowedMiner
