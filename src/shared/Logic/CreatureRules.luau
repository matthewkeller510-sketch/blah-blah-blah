--!strict
-- Pure rules for the creatures (section 10; docs/MILESTONE-3.md 4.3): watching, frame-rate independent rolls, the
-- C02 Borrowed Miner's exact rhythm and listening tests, the C03 Wick Moth swarm state machine, C04 Chalk Hand
-- eligibility and false-mark checks, and C08 Lantern Thief targeting and gating.
-- Every number below that the specification or docs/MILESTONE-3.md does not fix is a TUNE starting value or a
-- PROPOSED interpretation (see the comments). Nothing here reads spending, Robux or purchase history (F06).
-- Pure module: positions are plain { x, y, z } tables so it runs outside Roblox.

export type V3 = { x: number, y: number, z: number }

local CreatureRules = {}

local function len(v: V3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function sub(a: V3, b: V3): V3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function CreatureRules.distance(a: V3, b: V3): number
	return len(sub(a, b))
end

-- Generic ---------------------------------------------------------------------------------------------

-- Chance that an event with `ratePerSecond` happens within `dt` seconds. Frame-rate independent, so a roll made every
-- tick has the same expected frequency at 15 Hz or 60 Hz (fixes per-tick rolls that scaled with the tick rate).
function CreatureRules.chance(ratePerSecond: number, dt: number): number
	if ratePerSecond <= 0 or dt <= 0 then
		return 0
	end
	return 1 - math.exp(-ratePerSecond * dt)
end

-- Cosine of the horizontal angle between a look direction and the direction to a target. Nil when either is
-- degenerate (looking straight up or down, or the target directly above or below): never a NaN.
function CreatureRules.flatCos(look: V3, to: V3): number?
	local ll = math.sqrt(look.x * look.x + look.z * look.z)
	local tl = math.sqrt(to.x * to.x + to.z * to.z)
	if ll < 1e-3 or tl < 1e-3 then
		return nil
	end
	return (look.x * to.x + look.z * to.z) / (ll * tl)
end

-- Deliberate watching: the target is within range, the (horizontal) look direction is inside the cone, and the
-- caller has confirmed line of sight. `to` points from the watcher's head to the target.
function CreatureRules.watching(look: V3, to: V3, range: number, cosLimit: number, los: boolean): boolean
	if not los or len(to) > range then
		return false
	end
	local c = CreatureRules.flatCos(look, to)
	return c ~= nil and c >= cosLimit
end

-- Research: the field-experience key for reaching `stage` of a creature (shared with the player package back-fill).
function CreatureRules.researchXpKey(creatureId: string, stage: number): string
	return "research:" .. creatureId .. ":" .. tostring(stage)
end

-- Every key earned when research rises from `before` to `after` (stages can rise by more than one when evidence
-- gathered early starts to count).
function CreatureRules.researchXpKeys(creatureId: string, before: number, after: number): { string }
	local keys = {}
	for stage = before + 1, after do
		table.insert(keys, CreatureRules.researchXpKey(creatureId, stage))
	end
	return keys
end

-- Chamber graph -------------------------------------------------------------------------------------
export type Edge = { to: string, gate: string? }
export type Graph = { [string]: { Edge } }
export type CorridorLike = { from: string, to: string, gate: string?, pocket: string? }

-- PROPOSED: deep-water gates are water, not walls. Only a wading creature (the Wader) passes them while closed; solid
-- gates (P01 stone gate, P04 grate) stop every creature until they open.
CreatureRules.WATER_GATES = { P02 = true, W05 = true } :: { [string]: boolean }

-- Adjacency from chamber ids and corridors. Pocket corridors are ordinary edges: every pocket version honours the
-- same entry/exit contract, so creature graphs treat them as always connected (docs/MILESTONE-3.md section 2).
function CreatureRules.buildGraph(chamberIds: { string }, corridors: { CorridorLike }): Graph
	local g: Graph = {}
	for _, id in chamberIds do
		g[id] = {}
	end
	for _, c in corridors do
		if g[c.from] and g[c.to] then
			table.insert(g[c.from], { to = c.to, gate = c.gate })
			table.insert(g[c.to], { to = c.from, gate = c.gate })
		end
	end
	return g
end

-- Whether a creature may use a corridor: ungated, an open gate, or (wading) a deep-water gate.
function CreatureRules.passable(gate: string?, open: { [string]: boolean }, wades: boolean): boolean
	return gate == nil or open[gate] == true or (wades and CreatureRules.WATER_GATES[gate] == true)
end

-- Shortest chamber path from `fromId` to `toId` (excluding `fromId`). Empty when unreachable or already there.
function CreatureRules.route(
	g: Graph,
	fromId: string,
	toId: string,
	open: { [string]: boolean },
	wades: boolean
): { string }
	local path: { string } = {}
	if fromId == toId or not g[fromId] or not g[toId] then
		return path
	end
	local prev: { [string]: string } = {}
	local seen = { [fromId] = true }
	local q = { fromId }
	local head = 1
	local found = false
	while head <= #q and not found do
		local cur = q[head]
		head += 1
		for _, e in g[cur] do
			if not seen[e.to] and CreatureRules.passable(e.gate, open, wades) then
				seen[e.to] = true
				prev[e.to] = cur
				if e.to == toId then
					found = true
					break
				end
				table.insert(q, e.to)
			end
		end
	end
	if found then
		local cur: string? = toId
		while cur and cur ~= fromId do
			table.insert(path, 1, cur)
			cur = prev[cur]
		end
	end
	return path
end

-- Unit direction (horizontal) from a point inside a chamber toward its nearest wall; used to face the miner's wall.
function CreatureRules.nearestWallDir(pos: V3, chamberPos: V3, chamberSize: V3): V3
	local dxp = (chamberPos.x + chamberSize.x / 2) - pos.x
	local dxn = pos.x - (chamberPos.x - chamberSize.x / 2)
	local dzp = (chamberPos.z + chamberSize.z / 2) - pos.z
	local dzn = pos.z - (chamberPos.z - chamberSize.z / 2)
	local m = math.min(dxp, dxn, dzp, dzn)
	if m == dxp then
		return { x = 1, y = 0, z = 0 }
	elseif m == dxn then
		return { x = -1, y = 0, z = 0 }
	elseif m == dzp then
		return { x = 0, y = 0, z = 1 }
	end
	return { x = 0, y = 0, z = -1 }
end

-- Whether a position lies inside a chamber's interior box (floor centre `pos`, interior `size`), with slack.
function CreatureRules.inChamber(p: V3, chamberPos: V3, chamberSize: V3, slack: number): boolean
	return math.abs(p.x - chamberPos.x) <= chamberSize.x / 2 + slack
		and math.abs(p.z - chamberPos.z) <= chamberSize.z / 2 + slack
		and p.y >= chamberPos.y - 2 - slack
		and p.y <= chamberPos.y + chamberSize.y + slack
end

-- C02 Borrowed Miner ----------------------------------------------------------------------------------
CreatureRules.Miner = {
	-- PROPOSED: one caption per phrase of three strokes. A real sound would play on every stroke (exactly periodic);
	-- one caption per phrase keeps the caption stream readable.
	strokesPerPhrase = 3,
	heardStrokes = 3, -- heard_exact_rhythm: within heardRadius for three consecutive strokes (brief)
	heardRadius = 30,
	-- PROPOSED: "waited for three repeats" = three whole phrases (nine consecutive strokes) within waitRadius.
	waitPhrases = 3,
	waitRadius = 25,
	pingRadius = 40, -- a verified party ping this close makes it fade (brief)
	watchCos = math.cos(math.rad(25)), -- "looks at it": within about 25 degrees (brief)
	fadeWitnessCos = math.cos(math.rad(45)), -- PROPOSED: watching it fade needs it roughly in front of you
	cueRadius = 45, -- TUNE: who hears the strokes
	respawnSeconds = 120, -- TUNE: encounter cooldown before it works the wall again
	respawnClearRadius = 45, -- TUNE: nobody this close to the work spot when it reappears
}

-- Strokes that have happened by `now` for a rhythm that started at `origin`. Stroke k falls exactly at
-- origin + k * rhythm, so the rhythm never drifts with frame timing.
function CreatureRules.strokeCount(origin: number, rhythm: number, now: number): number
	if rhythm <= 0 or now < origin then
		return 0
	end
	return math.floor((now - origin) / rhythm)
end

function CreatureRules.strokeTime(origin: number, k: number, rhythm: number): number
	return origin + k * rhythm
end

-- Caption on the first stroke of each phrase (strokes 1, 4, 7, ...).
function CreatureRules.minerCaptionDue(k: number): boolean
	return k >= 1 and (k - 1) % CreatureRules.Miner.strokesPerPhrase == 0
end

export type MinerListen = { heard: number, waited: number }

function CreatureRules.newListen(): MinerListen
	return { heard = 0, waited = 0 }
end

-- Called once per stroke for one listener at `dist` studs (math.huge when out of earshot). Leaving a radius resets
-- its count ("without leaving"). Returns (heard_exact_rhythm earned, waited_for_repeat earned).
function CreatureRules.minerListen(track: MinerListen, dist: number): (boolean, boolean)
	local M = CreatureRules.Miner
	track.heard = if dist <= M.heardRadius then track.heard + 1 else 0
	track.waited = if dist <= M.waitRadius then track.waited + 1 else 0
	return track.heard >= M.heardStrokes, track.waited >= M.waitPhrases * M.strokesPerPhrase
end

-- It never answers a verification: any verified party ping this close makes it fade.
function CreatureRules.pingFades(pingPos: V3, minerPos: V3): boolean
	return CreatureRules.distance(pingPos, minerPos) <= CreatureRules.Miner.pingRadius
end

-- C03 Wick Moth ---------------------------------------------------------------------------------------
export type MothPhase = "none" | "flutter" | "attached" | "cooldown"
export type MothState = { phase: MothPhase, untilT: number, darkFor: number }
export type LightInfo = { on: boolean, isLantern: boolean, shielded: boolean }
export type MothInput = {
	now: number,
	dt: number,
	inZone: boolean,
	light: LightInfo,
	flareInZone: boolean,
	perceivable: boolean, -- not hidden, not downed, not in a shelter, alive
}
export type MothConfig = { flutterSeconds: number, darkSeconds: number, cooldownSeconds: number }
export type MothEvent =
	"flutter"
	| "attach"
	| "cancel"
	| "cancel_shield"
	| "cancel_flare"
	| "disperse_dark"
	| "disperse_shield"
	| "disperse_flare"
	| "disperse_left"
	| "disperse_lost"

CreatureRules.Moth = {
	flutterSeconds = 1.5, -- warning before the swarm attaches (brief)
	cooldownSeconds = 12, -- TUNE: encounter cooldown after a dispersal or a cancelled flutter
	roostSeenRadius = 20, -- TUNE: sighting the roost without a light
}

function CreatureRules.newMoth(): MothState
	return { phase = "none", untilT = 0, darkFor = 0 }
end

-- A working light that is not a shielded lantern.
function CreatureRules.mothExposed(light: LightInfo): boolean
	return light.on and not (light.isLantern and light.shielded)
end

local function rest(st: MothState, now: number, cfg: MothConfig)
	st.phase = "cooldown"
	st.untilT = now + cfg.cooldownSeconds
	st.darkFor = 0
end

-- Advances one player's swarm. Reads the light; never changes battery charge or health (the caller only applies the
-- range factor). Returns the event to act on, or nil.
function CreatureRules.mothStep(st: MothState, i: MothInput, cfg: MothConfig): MothEvent?
	if st.phase == "cooldown" then
		if i.now < st.untilT then
			return nil
		end
		st.phase = "none"
	end
	if st.phase == "none" then
		if i.perceivable and i.inZone and not i.flareInZone and CreatureRules.mothExposed(i.light) then
			st.phase = "flutter"
			st.untilT = i.now + cfg.flutterSeconds
			st.darkFor = 0
			return "flutter"
		end
		return nil
	end
	if st.phase == "flutter" then
		if not i.perceivable or not i.inZone or not i.light.on then
			rest(st, i.now, cfg)
			return "cancel"
		end
		if i.light.isLantern and i.light.shielded then
			rest(st, i.now, cfg)
			return "cancel_shield"
		end
		if i.flareInZone then
			rest(st, i.now, cfg)
			return "cancel_flare"
		end
		if i.now >= st.untilT then
			st.phase = "attached"
			st.darkFor = 0
			return "attach"
		end
		return nil
	end
	-- attached
	if not i.perceivable then
		rest(st, i.now, cfg)
		return "disperse_lost"
	end
	if not i.inZone then
		rest(st, i.now, cfg)
		return "disperse_left"
	end
	if i.flareInZone then
		rest(st, i.now, cfg)
		return "disperse_flare" -- a lit flare draws the swarm away
	end
	if i.light.on and i.light.isLantern and i.light.shielded then
		rest(st, i.now, cfg)
		return "disperse_shield"
	end
	if not i.light.on then
		st.darkFor += i.dt
		if st.darkFor >= cfg.darkSeconds then
			rest(st, i.now, cfg)
			return "disperse_dark"
		end
		return nil
	end
	st.darkFor = 0 -- switching back on before the darkness timer ends restarts it
	return nil
end

-- C04 Chalk Hand --------------------------------------------------------------------------------------
CreatureRules.ChalkHand = {
	regionId = "R05",
	triggerRadius = 30, -- within this of one of your own chalk marks (brief)
	seenRadius = 20, -- seen when the false mark is shown this close (brief)
	compareRadius = 40, -- compare needs an own chalk mark this close (brief)
	ttl = 90, -- false marks expire (brief)
	inspectRange = 12, -- TUNE: prompt range 8 plus latency slack
	ratePerSecond = 0.2, -- TUNE: once eligible it appears within a few seconds, not instantly
	maxLive = 2, -- TUNE
	minOffset = 2.5, -- near but never on an own mark
}

-- The player's own chalk mark the hand would imitate (the nearest within the trigger radius), or nil when not
-- eligible: wrong region, still inside the per-player interval, or no own chalk close enough.
function CreatureRules.chalkHandTarget(
	regionId: string,
	now: number,
	lastAt: number?,
	interval: number,
	playerPos: V3,
	ownChalk: { V3 }
): V3?
	local H = CreatureRules.ChalkHand
	if regionId ~= H.regionId then
		return nil
	end
	if lastAt ~= nil and now - lastAt < interval then
		return nil
	end
	local best: V3? = nil
	local bestD = math.huge
	for _, c in ownChalk do
		local d = CreatureRules.distance(playerPos, c)
		if d <= H.triggerRadius and d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

-- Candidate spots for the false mark on the same surface as the real one: a few studs along the wall (or the floor),
-- never on top of it. The service keeps the first one a raycast confirms is on a surface.
function CreatureRules.fakeMarkCandidates(mark: V3, normal: V3): { V3 }
	local out = {}
	local function add(dx: number, dy: number, dz: number)
		table.insert(out, { x = mark.x + dx, y = mark.y + dy, z = mark.z + dz })
	end
	if math.abs(normal.y) > 0.7 then
		-- floor or ceiling mark: offsets in the plane
		for _, o in { { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 }, { 5.5, 0 }, { -5.5, 0 } } do
			add(o[1], 0, o[2])
		end
		return out
	end
	-- wall mark: tangent along the wall = normal x up, flattened
	local tx, tz = -normal.z, normal.x
	local tl = math.sqrt(tx * tx + tz * tz)
	if tl < 1e-3 then
		tx, tz, tl = 1, 0, 1
	end
	tx, tz = tx / tl, tz / tl
	for _, o in { { 4, 0 }, { -4, 0 }, { 4, 1.2 }, { -4, 1.2 }, { 5.5, -1 }, { -5.5, -1 } } do
		add(tx * o[1], o[2], tz * o[1])
	end
	return out
end

-- True when `p` is at least `minDist` from every mark (the false mark is never on one of the player's own).
function CreatureRules.farFromAll(p: V3, marks: { V3 }, minDist: number): boolean
	for _, m in marks do
		if CreatureRules.distance(p, m) < minDist then
			return false
		end
	end
	return true
end

-- A request about a false mark is valid only for a mark the server showed this player, still within its lifetime,
-- from close enough.
function CreatureRules.falseMarkValid(createdAt: number?, now: number, dist: number, range: number): boolean
	return createdAt ~= nil
		and now - createdAt >= 0
		and now - createdAt <= CreatureRules.ChalkHand.ttl
		and dist <= range
end

-- Compare grants confirmed_own_mark only if one of the player's own chalk marks is within compareRadius.
function CreatureRules.compareAllowed(playerPos: V3, ownChalk: { V3 }): boolean
	for _, c in ownChalk do
		if CreatureRules.distance(playerPos, c) <= CreatureRules.ChalkHand.compareRadius then
			return true
		end
	end
	return false
end

-- C08 Lantern Thief -----------------------------------------------------------------------------------
CreatureRules.Thief = {
	-- TUNE: "poorly supplied / high pressure". A well-supplied solo traveller sits at 0.19-0.29 in R04 and 0.21-0.31 in
	-- R05 (rising with time since the last threat), so some real depletion of light, health or medical is needed.
	engageThreshold = 0.35,
	warnSeconds = 1.2, -- TUNE: essential rattle before the approach (readable cue before damage, T04)
	rattleInterval = 6, -- TUNE: rattle while stalking within rattleRadius
	rattleRadius = 45, -- brief
	glowFraction = 0.5, -- PROPOSED: a light this fraction of the notice radius away is noticed around corners
	flareScore = 3, -- PROPOSED: a lit flare outshines any carried light
	shieldedFactor = 0.35, -- PROPOSED: a shielded lantern is a dim, poor prize
	encounterCooldown = 40, -- TUNE: after any encounter ends it roams before stalking again
	victimIgnoreSeconds = 45, -- TUNE: it leaves the same traveller alone for a while
	strikeRecoverySeconds = 90, -- TUNE: director recovery interval for the victim after a strike
	withdrawSeconds = 8, -- TUNE
	approachMaxSeconds = 14, -- TUNE: an approach that never connects gives up
	minStalk = 18, -- TUNE: clamp of the director's stalking distance
	maxStalk = 70,
	seenCos = 0.85, -- TUNE: about 32 degrees
	homeRatePerSecond = 1 / 30, -- TUNE: how often it moves to another home while roaming
}

export type ThiefLight = { on: boolean, isLantern: boolean, shielded: boolean, brightness: number }

-- How attractive a carried light is. Unlit lights are invisible to it. An open lantern exposes its carrier
-- (Config.Lantern.exposureMultiplier); a shielded one is a poor prize.
function CreatureRules.lightScore(l: ThiefLight, exposureMultiplier: number): number
	if not l.on then
		return 0
	end
	if l.isLantern and l.shielded then
		return l.brightness * CreatureRules.Thief.shieldedFactor
	end
	if l.isLantern then
		return l.brightness * exposureMultiplier
	end
	return l.brightness
end

-- Noticed when within the notice radius with line of sight, or close enough that the glow shows around a corner.
function CreatureRules.noticed(dist: number, radius: number, los: boolean): boolean
	return (dist <= radius and los) or dist <= radius * CreatureRules.Thief.glowFraction
end

export type Candidate = { score: number, dist: number }

-- Prefers the brightest light that is not its own; ties go to the nearest. Returns the index, or nil.
function CreatureRules.pickVictim(cands: { Candidate }): number?
	local best: number? = nil
	for i, c in cands do
		if c.score > 0 then
			local b = if best then cands[best] else nil
			if not b or c.score > b.score or (c.score == b.score and c.dist < b.dist) then
				best = i
			end
		end
	end
	return best
end

export type FlareRef = { position: V3, key: string }

-- A lit flare within `radius` of the thief or of its victim diverts it (a flare outshines any carried light). Each
-- flare decoys it once. Returns the nearest qualifying flare to the thief, or nil.
function CreatureRules.pickDecoy(
	flares: { FlareRef },
	thiefPos: V3,
	victimPos: V3?,
	radius: number,
	used: { [string]: any }
): FlareRef?
	local best: FlareRef? = nil
	local bestD = math.huge
	for _, f in flares do
		if used[f.key] == nil then
			local dt = CreatureRules.distance(f.position, thiefPos)
			local near = dt <= radius or (victimPos ~= nil and CreatureRules.distance(f.position, victimPos) <= radius)
			if near and dt < bestD then
				best, bestD = f, dt
			end
		end
	end
	return best
end

-- Approach (the damaging phase) needs the counter evidence (the player has read the warning note), the director's
-- permission (per-victim and server caps, recovery intervals, pressure at or above the threshold) and the victim not
-- watching it (encounters begin outside the player's view).
function CreatureRules.thiefMayApproach(
	hasCounterEvidence: boolean,
	directorAllows: boolean,
	watchedByVictim: boolean
): boolean
	return hasCounterEvidence and directorAllows and not watchedByVictim
end

-- It strikes only from an approach, only after the counter evidence, within reach and with line of sight.
function CreatureRules.thiefMayStrike(
	state: string,
	hasCounterEvidence: boolean,
	dist: number,
	reach: number,
	los: boolean
): boolean
	return state == "approach" and hasCounterEvidence and dist <= reach and los
end

-- Line-of-sight timer: any sighting resets it; `limit` seconds without sight loses the victim.
function CreatureRules.sightTimer(lostFor: number, hasSight: boolean, dt: number, limit: number): (number, boolean)
	if hasSight then
		return 0, false
	end
	local t = lostFor + dt
	return t, t >= limit
end

-- A stun repels it in every state except while it is already recoiling (no second charge is spent).
function CreatureRules.thiefStunRepels(state: string): boolean
	return state ~= "repelled"
end

-- Stalking distance: the director's (closer when supplies are low, F06) clamped to a sane band.
function CreatureRules.thiefStalkDistance(directorDistance: number): number
	return math.clamp(directorDistance, CreatureRules.Thief.minStalk, CreatureRules.Thief.maxStalk)
end

return CreatureRules
