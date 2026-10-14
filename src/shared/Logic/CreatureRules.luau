--!strict
-- Pure rules for the creatures (section 10; docs/MILESTONE-3.md 4.3): watching, frame-rate independent rolls, the
-- chamber graph and the movement planner (never a straight leg through a variable pocket's rock), the C02 Borrowed
-- Miner's exact rhythm and listening tests, the C03 Wick Moth swarm state machine, C04 Chalk Hand eligibility and
-- false-mark checks, and C08 Lantern Thief targeting and gating.
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

-- Tools: the order in which aimed-at candidates are tried (each still needs line of sight). Threats come before
-- harmless phenomena, so a nearer roost or miner never absorbs a swing or stun meant for a threat; within each, the
-- nearest first (review R2 finding 11).
export type ToolCandidate = { harmless: boolean, dist: number }

function CreatureRules.toolTargetOrder(cands: { ToolCandidate }): { number }
	local order: { number } = {}
	for i = 1, #cands do
		table.insert(order, i)
	end
	table.sort(order, function(a: number, b: number): boolean
		local ca, cb = cands[a], cands[b]
		if ca.harmless ~= cb.harmless then
			return not ca.harmless
		end
		if ca.dist ~= cb.dist then
			return ca.dist < cb.dist
		end
		return a < b
	end)
	return order
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

-- Adjacency from chamber ids and corridors. Every pocket version honours the same entry/exit contract
-- (docs/MILESTONE-3.md section 2), so by default a pocket corridor is an ordinary edge. With `gatePockets` it is
-- gated by its pocket id instead: the creature service opens it only while the pocket's current version has a
-- creature route (Logic/Pockets.creatureRoute), which creatures then follow instead of a straight line.
function CreatureRules.buildGraph(chamberIds: { string }, corridors: { CorridorLike }, gatePockets: boolean?): Graph
	local g: Graph = {}
	for _, id in chamberIds do
		g[id] = {}
	end
	for _, c in corridors do
		if g[c.from] and g[c.to] then
			local gate = c.gate or (if gatePockets then c.pocket else nil)
			table.insert(g[c.from], { to = c.to, gate = gate })
			table.insert(g[c.to], { to = c.from, gate = gate })
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

-- Movement planner (review finding 10) -----------------------------------------------------------------------
-- Creatures move kinematically in straight legs, ignoring collision, so the planner must never hand out a leg that
-- crosses rock. Inside one chamber a leg is straight (a chamber is an open box). Between chambers the creature walks
-- the chamber graph centre to centre, as before. A variable pocket is different in every version, so inside a
-- pocket, on a pocket's creature route, or heading into a pocket, the creature follows that pocket's current route
-- (Logic/Pockets.creatureRoute) and leaves it only by a leg Nav.clear accepts. Any other straight leg that touches a
-- pocket is refused (the trip is blocked and the caller gives up). Positions are floor points; route tests are
-- horizontal.

export type RouteLine = { pts: { V3 }, cum: { number }, from: string, to: string, y: number }
export type Nav = {
	pocketIds: { string },
	nearestNode: (V3) -> string,
	node: (string) -> V3,
	chamberAt: (V3) -> string?, -- the chamber whose interior holds the point
	pocketsAt: (V3) -> { string }, -- every pocket whose bounds hold the point (bounds can overlap)
	mouths: (string) -> (string, string), -- a pocket's two mouth chambers
	line: (string) -> RouteLine?, -- a pocket's current creature route; nil when it is closed to creatures
	clear: (string, V3, V3) -> boolean, -- a straight leg is clear in the pocket's current version
	room: (string, V3) -> V3?, -- the nearest point to a goal where a body fits (Pockets.creatureRoom)
	crosses: (V3, V3) -> boolean, -- a straight leg comes within a body's clearance of any pocket's bounds
	route: (string, string, boolean) -> { string }, -- chamber path, honouring closed gates and closed pockets
	edgePocket: (string, string) -> string?, -- the pocket a corridor between two chambers runs through
}

CreatureRules.ROUTE_NEAR = 1 -- studs (horizontal): a creature this close to a pocket route is following it
CreatureRules.ROUTE_ARRIVE = 0.5 -- a route point this close counts as reached (Common.moveModel's dead zone)
CreatureRules.ROUTE_LEVEL = 6 -- a route this far above or below is on another level
CreatureRules.ROUTE_ROOM = 3 -- TUNE: how far from a goal against a wall a creature looks for room for its body

local function flatDist(a: V3, b: V3): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- A route polyline with its cumulative horizontal length at each point.
function CreatureRules.routeLine(pts: { V3 }, from: string, to: string): RouteLine
	local cum = { 0 }
	for i = 2, #pts do
		cum[i] = cum[i - 1] + flatDist(pts[i - 1], pts[i])
	end
	return { pts = pts, cum = cum, from = from, to = to, y = pts[1].y }
end

-- Arc position of the route point nearest to `p` (horizontally), and the distance to it.
function CreatureRules.routeProject(line: RouteLine, p: V3): (number, number)
	local bestS, bestD = 0, math.huge
	local pts = line.pts
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local dx, dz = b.x - a.x, b.z - a.z
		local len2 = dx * dx + dz * dz
		local t = if len2 > 1e-9 then math.clamp(((p.x - a.x) * dx + (p.z - a.z) * dz) / len2, 0, 1) else 0
		local d = math.sqrt((p.x - a.x - dx * t) ^ 2 + (p.z - a.z - dz * t) ^ 2)
		if d < bestD then
			bestS, bestD = line.cum[i] + t * math.sqrt(len2), d
		end
	end
	return bestS, bestD
end

-- The route point at arc position `s` (clamped to the route).
function CreatureRules.routePoint(line: RouteLine, s: number): V3
	local pts, cum = line.pts, line.cum
	for i = 1, #pts - 1 do
		if s <= cum[i + 1] then
			local len = cum[i + 1] - cum[i]
			local t = if len > 1e-9 then math.clamp((s - cum[i]) / len, 0, 1) else 0
			local a, b = pts[i], pts[i + 1]
			return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
		end
	end
	local last = pts[#pts]
	return { x = last.x, y = last.y, z = last.z }
end

-- Next point when moving along the route from arc position `s` toward `sGoal`: the next route point on the way, or
-- the point at sGoal when nothing comes first (then the second result is true).
function CreatureRules.routeNext(line: RouteLine, s: number, sGoal: number): (V3, boolean)
	local A = CreatureRules.ROUTE_ARRIVE
	local pts, cum = line.pts, line.cum
	if sGoal > s + A then
		for i = 1, #pts do
			if cum[i] > s + A then
				if cum[i] < sGoal then
					return pts[i], false
				end
				break
			end
		end
	elseif sGoal < s - A then
		for i = #pts, 1, -1 do
			if cum[i] < s - A then
				if cum[i] > sGoal then
					return pts[i], false
				end
				break
			end
		end
	end
	return CreatureRules.routePoint(line, sGoal), true
end

-- The pocket a point is in. Bounds can overlap (PK1's loop side chamber reaches into PK2's bounds), so among the
-- pockets whose bounds hold the point it picks the one whose current route passes nearest.
local function pocketOf(nav: Nav, p: V3): string?
	local best: string? = nil
	local bestD = math.huge
	for _, id in nav.pocketsAt(p) do
		local line = nav.line(id)
		local d = math.huge
		if line then
			local _, dist = CreatureRules.routeProject(line, p)
			d = dist
		end
		if best == nil or d < bestD then
			best, bestD = id, d
		end
	end
	return best
end

-- Graph hops from chamber `a` to `b`: 0 when they are the same, math.huge when unreachable.
local function hops(nav: Nav, a: string, b: string, wades: boolean): number
	if a == b then
		return 0
	end
	local r = nav.route(a, b, wades)
	return if #r > 0 then #r else math.huge
end

-- A straight leg, unless it touches a pocket. Then a creature off its chamber's centre first walks to that centre
-- (`via`: the graph's centre-to-centre lines stay clear of pockets); otherwise the trip is blocked.
local function guarded(nav: Nav, pos: V3, target: V3, final: boolean, via: V3?): (V3, boolean, boolean)
	if not nav.crosses(pos, target) then
		return target, final, false
	end
	if via and flatDist(pos, via) > CreatureRules.ROUTE_ARRIVE and not nav.crosses(pos, via) then
		return via, false, false
	end
	return pos, false, true
end

local function lerp(a: V3, b: V3, t: number): V3
	return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
end

-- Where a creature heads for a goal inside pocket `pk`, and the arc position of the route point it leaves the route
-- from. It aims at the goal, or at the nearest point with room for its body (a goal against a wall). Of the route
-- legs' nearest points to that aim, it takes the closest one with a clear leg to it; with none, it goes from the
-- route point nearest the aim as far toward it as the floor allows.
local function approachPoint(nav: Nav, pk: string, line: RouteLine, goal: V3): (V3, number)
	local aim = nav.room(pk, goal) or goal
	local pts, cum = line.pts, line.cum
	local bestS, bestD = 0, math.huge
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local dx, dz = b.x - a.x, b.z - a.z
		local len2 = dx * dx + dz * dz
		local t = if len2 > 1e-9 then math.clamp(((aim.x - a.x) * dx + (aim.z - a.z) * dz) / len2, 0, 1) else 0
		local q = lerp(a, b, t)
		local d = flatDist(q, aim)
		if d < bestD and nav.clear(pk, q, aim) then
			bestS, bestD = cum[i] + t * math.sqrt(len2), d
		end
	end
	if bestD < math.huge then
		return aim, bestS
	end
	local sAim = CreatureRules.routeProject(line, aim)
	local from = CreatureRules.routePoint(line, sAim)
	local lo, hi = 0, 1
	for _ = 1, 8 do
		local mid = (lo + hi) / 2
		if nav.clear(pk, from, lerp(from, aim, mid)) then
			lo = mid
		else
			hi = mid
		end
	end
	return lerp(from, aim, lo), sAim
end

-- One graph hop from chamber `here` toward `toId`. A pocket corridor is entered from inside its mouth chamber by
-- joining the route at that chamber's doorway point; from anywhere else the creature first walks to the chamber
-- centre, as on any corridor.
local function hop(nav: Nav, pos: V3, room: string?, here: string, toId: string, wades: boolean): (V3, boolean, boolean)
	local nextId = nav.route(here, toId, wades)[1]
	if not nextId then
		return pos, false, true
	end
	local pk = nav.edgePocket(here, nextId)
	if pk then
		local line = nav.line(pk)
		if line and room == here then
			return (if here == line.from then line.pts[2] else line.pts[#line.pts - 1]), false, false
		end
		return guarded(nav, pos, nav.node(here), false, nil)
	end
	return guarded(nav, pos, nav.node(nextId), false, nav.node(here))
end

-- Following pocket `pk`'s route from arc position `s`. Toward a goal inside the same pocket: along the route to the
-- point nearest the goal, then straight to the goal, or as close as the floor allows. Toward anything else: along
-- the route to the end whose chamber is cheaper (the remaining share of the route plus graph hops); nil once at
-- that end, where the chamber graph takes over.
local function follow(
	nav: Nav,
	pk: string,
	line: RouteLine,
	s: number,
	pos: V3,
	goal: V3,
	goalPocket: string?,
	there: string,
	wades: boolean
): (V3?, boolean)
	local L = line.cum[#line.cum]
	if goalPocket == pk then
		local target, sGoal = approachPoint(nav, pk, line, goal)
		if math.abs(sGoal - s) <= CreatureRules.ROUTE_ARRIVE then
			local onRoute = CreatureRules.routePoint(line, sGoal)
			if nav.clear(pk, pos, target) or flatDist(pos, onRoute) <= CreatureRules.ROUTE_ARRIVE then
				return target, true
			end
			return onRoute, false -- onto the route point first, where the leg to the target is clear
		end
		return (CreatureRules.routeNext(line, s, sGoal)), false
	end
	local viaFrom = s / L + hops(nav, line.from, there, wades)
	local viaTo = (L - s) / L + hops(nav, line.to, there, wades)
	local sEnd = if viaTo < viaFrom or (viaTo == viaFrom and s > L / 2) then L else 0
	if math.abs(sEnd - s) <= CreatureRules.ROUTE_ARRIVE then
		return nil, false
	end
	return (CreatureRules.routeNext(line, s, sEnd)), false
end

-- Off the route inside a pocket (after a clear leg toward a goal beside it): back to the nearest route point a clear
-- leg reaches. Displaced into rock (never expected: creatures postpone pocket changes) it takes the shortest way.
local function rejoin(nav: Nav, pk: string, line: RouteLine, pos: V3, s: number): V3
	local q = CreatureRules.routePoint(line, s)
	if nav.clear(pk, pos, q) then
		return q
	end
	local best: V3? = nil
	local bestD = math.huge
	for _, v in line.pts do
		local d = flatDist(pos, v)
		if d < bestD and nav.clear(pk, pos, v) then
			best, bestD = v, d
		end
	end
	return best or q
end

-- The next straight leg toward a floor goal: (target, final, blocked). `final` means reaching the target ends the
-- trip; `blocked` means no route exists and the caller should give up.
function CreatureRules.nextLeg(nav: Nav, pos: V3, goal: V3, wades: boolean): (V3, boolean, boolean)
	local room = nav.chamberAt(pos)
	if room ~= nil and room == nav.chamberAt(goal) then
		return goal, true, false
	end
	local goalPocket = pocketOf(nav, goal)
	if goalPocket and nav.clear(goalPocket, pos, goal) then
		return goal, true, false
	end
	local here, there = nav.nearestNode(pos), nav.nearestNode(goal)
	-- inside a pocket: along its current route
	local pk = pocketOf(nav, pos)
	if pk then
		local line = nav.line(pk)
		if not line then
			-- closed to creatures (no route in this version, or no pocket service): out by the nearer mouth
			local m1, m2 = nav.mouths(pk)
			local n1, n2 = nav.node(m1), nav.node(m2)
			return (if flatDist(pos, n1) <= flatDist(pos, n2) then n1 else n2), false, false
		end
		local s, d = CreatureRules.routeProject(line, pos)
		if d > CreatureRules.ROUTE_NEAR then
			if goalPocket == pk then
				-- beside the route near its goal: stay as close as the floor allows, or move there by a clear leg
				local target = approachPoint(nav, pk, line, goal)
				if flatDist(pos, target) <= CreatureRules.ROUTE_ARRIVE or nav.clear(pk, pos, target) then
					return target, true, false
				end
			end
			return rejoin(nav, pk, line, pos, s), false, false
		end
		local target, final = follow(nav, pk, line, s, pos, goal, goalPocket, there, wades)
		if target then
			return target, final, false
		end
	end
	-- on a pocket route outside its bounds (between a mouth chamber's centre and its doorway)
	for _, id in nav.pocketIds do
		local line = nav.line(id)
		if line and math.abs(pos.y - line.y) <= CreatureRules.ROUTE_LEVEL then
			local s, d = CreatureRules.routeProject(line, pos)
			if d <= CreatureRules.ROUTE_NEAR then
				local target, final = follow(nav, id, line, s, pos, goal, goalPocket, there, wades)
				if target then
					return target, final, false
				end
			end
		end
	end
	-- heading into a pocket: through the cheaper mouth chamber, joining the route at its doorway point
	if goalPocket then
		local line = nav.line(goalPocket)
		if not line then
			return pos, false, true
		end
		local L = line.cum[#line.cum]
		local sGoal = CreatureRules.routeProject(line, goal)
		local viaFrom = hops(nav, here, line.from, wades) + sGoal / L
		local viaTo = hops(nav, here, line.to, wades) + (L - sGoal) / L
		local entry = if viaTo < viaFrom then line.to else line.from
		if entry ~= here then
			return hop(nav, pos, room, here, entry, wades)
		end
		if room == here then
			return (if entry == line.from then line.pts[2] else line.pts[#line.pts - 1]), false, false
		end
		return guarded(nav, pos, nav.node(here), false, nil)
	end
	-- the chamber graph
	if here == there then
		return guarded(nav, pos, goal, true, nav.node(here))
	end
	return hop(nav, pos, room, here, there, wades)
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
-- eligible: wrong region, still inside the per-player interval, or no own chalk close enough. With `inPocket`, a
-- mark inside a variable pocket is never imitated (its fake would sit on a pocket surface; review finding 14).
function CreatureRules.chalkHandTarget(
	regionId: string,
	now: number,
	lastAt: number?,
	interval: number,
	playerPos: V3,
	ownChalk: { V3 },
	inPocket: ((V3) -> boolean)?
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
		if d <= H.triggerRadius and d < bestD and not (inPocket and inPocket(c)) then
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

-- A spot the false mark may take: never on a variable pocket's surface (a version change would leave the private
-- fake floating in void or inside a new wall, and nothing clears it on the client; review finding 14), and never on
-- one of the player's own marks.
function CreatureRules.fakeSpotAllowed(p: V3, own: { V3 }, inPocket: (V3) -> boolean): boolean
	return not inPocket(p) and CreatureRules.farFromAll(p, own, CreatureRules.ChalkHand.minOffset)
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
