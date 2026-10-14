--!strict
-- Review fixes, batch 2: creatures in variable pockets. Finding 10: a creature never crosses a pocket's rock in a
-- straight line; it follows the current version's creature route, leaves it only by clear legs, and keeps its body
-- under a low ceiling. Finding 14 (Chalk Hand half): no false mark on a pocket surface. Round 2: every obtainable
-- research evidence id has a grant site (finding 8, the Knocker's "seen"); tools try threats before harmless
-- phenomena (finding 11).
-- Pure rules only. makeNav below mirrors the Roblox wiring in Services/Creatures/Common (the Nav table); that wiring,
-- the low-ceiling body clamp, the PocketBlocker tag, the tools' line-of-sight check and the weak per-player tables
-- still need a Studio check.

local fs = require("@lune/fs")
local WorldDefs = require("../../src/shared/Data/WorldDefs")
local Pockets = require("../../src/shared/Logic/Pockets")
local CreatureRules = require("../../src/shared/Logic/CreatureRules")

Pockets.bind(WorldDefs)

type V3 = CreatureRules.V3
type Versions = { [string]: string? }

local CLEAR = Pockets.CREATURE_CLEARANCE
-- Lantern Thief greybox (LanternThief.build): trapped lights ring at radius 1.3 plus 0.225; the head (centre 3.9 above
-- the pivot, 1.1 tall, tilted 25 degrees) tops out about 4.59 above the pivot; it hangs 5 studs above the floor.
local THIEF_HALF_WIDTH = 1.6
local THIEF_TOP = 4.6
local THIEF_LIFT = 5

local function v(x: number, y: number, z: number): V3
	return { x = x, y = y, z = z }
end

local function pocketIds(): { string }
	local ids = {}
	for id in WorldDefs.Pockets do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function defaults(): Versions
	local out: Versions = {}
	for id, def in WorldDefs.Pockets do
		out[id] = def.versions[1]
	end
	return out
end

local function node(id: string): V3
	local c = assert(WorldDefs.chamber(id), id)
	return v(c.pos.x, c.pos.y, c.pos.z)
end

-- Independent open-floor check ------------------------------------------------------------------------------
-- A cell centre is open when it lies in a chamber interior, on a walkable cell of a pocket's version, or in a
-- doorway through a mouth chamber's wall. Written apart from Pockets' own clearance cover.

local gridCache: { [string]: any } = {}
local function gridFor(def: any, version: string): any
	local key = def.id .. "|" .. version
	local g = gridCache[key]
	if not g then
		local plan = Pockets.plan(def, version)
		g = Pockets.grid(plan.area, plan.walk, plan.lowWalk)
		gridCache[key] = g
	end
	return g
end

local function toLocal(area: any, x: number, z: number): (number, number)
	if area.axis == "z" then
		return x - area.center, z - area.start
	end
	return z - area.center, x - area.start
end

local function inSpans(u: number, spans: { { number } }): boolean
	for _, sp in spans do
		if u >= sp[1] and u <= sp[2] then
			return true
		end
	end
	return false
end

local function openAt(x: number, y: number, z: number, versions: Versions): boolean
	for _, c in WorldDefs.Chambers do
		if
			math.abs(y - c.pos.y) <= 6
			and math.abs(x - c.pos.x) <= c.size.x / 2
			and math.abs(z - c.pos.z) <= c.size.z / 2
		then
			return true
		end
	end
	for id, def in WorldDefs.Pockets do
		local version = versions[id]
		if version and math.abs(y - def.bounds.min.y) <= 6 then
			local area = Pockets.area(def)
			local u, w = toLocal(area, x, z)
			if u >= area.uMin and u <= area.uMax then
				if w >= 0 and w < area.length then
					local g = gridFor(def, version)
					local i, k = math.floor(x - g.x0), math.floor(z - g.z0)
					if
						i >= 0
						and i < g.nx
						and k >= 0
						and k < g.nz
						and Pockets.isWalkable(g.cells[k * g.nx + i + 1])
					then
						return true
					end
				else
					local spans = Pockets.mouthSpans(def)
					if w >= -Pockets.WALL and w < 0 and inSpans(u, spans.first) then
						return true
					end
					if w >= area.length and w < area.length + Pockets.WALL and inSpans(u, spans.second) then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Every unit cell under a square body of half-width r centred on p is open.
local function bodyOk(p: V3, r: number, versions: Versions): boolean
	for cx = math.floor(p.x - r), math.ceil(p.x + r) - 1 do
		for cz = math.floor(p.z - r), math.ceil(p.z + r) - 1 do
			if not openAt(cx + 0.5, p.y, cz + 0.5, versions) then
				return false
			end
		end
	end
	return true
end

-- Within r of any pocket's bounds on its level (elsewhere the static world is out of scope here).
local function nearPocket(p: V3, r: number): boolean
	for _, def in WorldDefs.Pockets do
		local b = def.bounds
		if
			math.abs(p.y - b.min.y) <= 6
			and p.x >= b.min.x - r
			and p.x <= b.max.x + r
			and p.z >= b.min.z - r
			and p.z <= b.max.z + r
		then
			return true
		end
	end
	return false
end

local function insideBounds(p: V3, id: string): boolean
	return Pockets.inBounds(WorldDefs.Pockets[id], p, 0)
end

-- Every point of a straight leg near a pocket leaves a body of half-width r on open floor.
local function legOk(a: V3, b: V3, r: number, versions: Versions): (boolean, V3?)
	local len = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
	local n = math.max(1, math.ceil(len / 0.25))
	for i = 0, n do
		local t = i / n
		local p = v(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
		if nearPocket(p, r) and not bodyOk(p, r, versions) then
			return false, p
		end
	end
	return true, nil
end

-- The planner's world, wired like Services/Creatures/Common (puzzle gates closed; they are not in R04/R05) ----
local chamberIds: { string } = {}
for _, c in WorldDefs.Chambers do
	table.insert(chamberIds, c.id)
end
local pocketEdges: { [string]: string } = {}
for _, cor in WorldDefs.Corridors do
	if cor.pocket then
		pocketEdges[cor.from .. ">" .. cor.to] = cor.pocket
		pocketEdges[cor.to .. ">" .. cor.from] = cor.pocket
	end
end
local graph = CreatureRules.buildGraph(chamberIds, WorldDefs.Corridors, true)

local function makeNav(versions: Versions): CreatureRules.Nav
	local lines: { [string]: CreatureRules.RouteLine } = {}
	local open: { [string]: boolean } = {}
	for _, id in pocketIds() do
		local version = versions[id]
		local def = WorldDefs.Pockets[id]
		local pts = if version then Pockets.creatureRoute(def, version) else nil
		if pts then
			lines[id] = CreatureRules.routeLine(pts, def.from, def.to)
			open[id] = true
		end
	end
	local cache: { [string]: { string } } = {}
	return {
		pocketIds = pocketIds(),
		nearestNode = function(p: V3): string
			local best, bd = "", math.huge
			for _, c in WorldDefs.Chambers do
				local d = math.sqrt((p.x - c.pos.x) ^ 2 + ((p.y - c.pos.y) * 3) ^ 2 + (p.z - c.pos.z) ^ 2)
				if d < bd then
					best, bd = c.id, d
				end
			end
			return best
		end,
		node = node,
		chamberAt = function(p: V3): string?
			for _, c in WorldDefs.Chambers do
				if CreatureRules.inChamber(p, c.pos, c.size, 0) then
					return c.id
				end
			end
			return nil
		end,
		pocketsAt = function(p: V3): { string }
			local out = {}
			for _, id in pocketIds() do
				if insideBounds(p, id) then
					table.insert(out, id)
				end
			end
			return out
		end,
		mouths = function(id: string): (string, string)
			local def = WorldDefs.Pockets[id]
			return def.from, def.to
		end,
		line = function(id: string): CreatureRules.RouteLine?
			return lines[id]
		end,
		clear = function(id: string, a: V3, b: V3): boolean
			local version = versions[id]
			return version ~= nil and Pockets.creatureClear(WorldDefs.Pockets[id], version, a, b)
		end,
		room = function(id: string, p: V3): V3?
			local version = versions[id]
			if not version then
				return nil
			end
			return Pockets.creatureRoom(WorldDefs.Pockets[id], version, p, CreatureRules.ROUTE_ROOM)
		end,
		crosses = function(a: V3, b: V3): boolean
			for _, def in WorldDefs.Pockets do
				if Pockets.segmentInBounds(def, a, b, CLEAR) then
					return true
				end
			end
			return false
		end,
		route = function(a: string, b: string, wades: boolean): { string }
			local key = a .. ">" .. b .. tostring(wades)
			local r = cache[key]
			if not r then
				r = CreatureRules.route(graph, a, b, open, wades)
				cache[key] = r
			end
			return r
		end,
		edgePocket = function(a: string, b: string): string?
			return pocketEdges[a .. ">" .. b]
		end,
	}
end

-- Drives CreatureRules.nextLeg the way Common.travel and Common.moveModel do (straight steps, a 0.5 dead zone) and
-- checks every step. Returns the end position and every position visited.
local STEP = 2
local function walk(versions: Versions, start: V3, goal: V3, tag: string): (V3, { V3 })
	local nav = makeNav(versions)
	local pos = start
	local trail = { pos }
	local stalls = 0
	for _ = 1, 2000 do
		local target, final, blocked = CreatureRules.nextLeg(nav, pos, goal, false)
		assert(not blocked, string.format("%s: blocked at (%.1f, %.1f)", tag, pos.x, pos.z))
		local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d < 0.5 then
			if final then
				return pos, trail
			end
			stalls += 1
			assert(stalls < 3, string.format("%s: stalls at (%.1f, %.1f)", tag, pos.x, pos.z))
		else
			stalls = 0
			local step = math.min(d, STEP)
			local np = v(pos.x + dx / d * step, pos.y + dy / d * step, pos.z + dz / d * step)
			local ok, at = legOk(pos, np, THIEF_HALF_WIDTH, versions)
			if not ok then
				local p = at :: V3
				error(string.format("%s: moves through rock near (%.2f, %.2f)", tag, p.x, p.z))
			end
			pos = np
			table.insert(trail, pos)
			if final and step >= d - 1e-9 then
				return pos, trail
			end
		end
	end
	error(tag .. ": never arrives")
end

local function near(a: V3, b: V3, eps: number): boolean
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) <= eps
end

return function(T: any)
	local test, eq = T.test, T.eq
	print("Review fixes batch 2: creatures in variable pockets (finding 10), Chalk Hand fakes (finding 14)")

	test("every pocket version has a creature route whose every leg keeps body clearance in that version", function()
		assert(CLEAR >= THIEF_HALF_WIDTH, "the route clearance must fit the Lantern Thief's body")
		for _, id in pocketIds() do
			local def = WorldDefs.Pockets[id]
			for _, version in def.versions do
				local tag = id .. " " .. version
				local route = assert(Pockets.creatureRoute(def, version), tag .. " has no creature route")
				assert(near(route[1], node(def.from), 1e-9), tag .. " starts at the from chamber's centre")
				assert(near(route[#route], node(def.to), 1e-9), tag .. " ends at the to chamber's centre")
				for i = 1, #route - 1 do
					local ok, at = legOk(route[i], route[i + 1], CLEAR, { [id] = version })
					if not ok then
						local p = at :: V3
						error(string.format("%s leg %d crosses rock near (%.2f, %.2f)", tag, i, p.x, p.z))
					end
				end
			end
		end
	end)

	test("each route follows its own version's passage: the loop, the dogleg and PK3's stable door", function()
		local function maxOf(route: { V3 }, key: string): number
			local m = -math.huge
			for _, p in route do
				m = math.max(m, (p :: any)[key])
			end
			return m
		end
		local pk1, pk2, pk3 = WorldDefs.Pockets.PK1, WorldDefs.Pockets.PK2, WorldDefs.Pockets.PK3
		local loop = assert(Pockets.creatureRoute(pk1, "loop"))
		-- the side chamber starts 16 studs east of the centre line
		assert(maxOf(loop, "x") >= Pockets.area(pk1).center + 16, "PK1 loop goes east through the side chamber")
		local dogleg = assert(Pockets.creatureRoute(pk2, "dogleg"))
		assert(maxOf(dogleg, "z") >= Pockets.area(pk2).center + 18, "PK2 dogleg jogs north")
		for _, version in { "direct", "low" } do
			eq(#assert(Pockets.creatureRoute(pk1, version)), 4, "PK1 " .. version .. " is straight")
			eq(#assert(Pockets.creatureRoute(pk2, version)), 4, "PK2 " .. version .. " is straight")
		end
		local doorZ = Pockets.area(pk3).start - Pockets.WALL -- the doorway room's wall face
		for _, version in pk3.versions do
			local route = assert(Pockets.creatureRoute(pk3, version))
			local stable = assert(Pockets.stableDoor(pk3, version))
			local doors = pk3.doors :: { number }
			eq(route[2].x, doors[stable], "PK3 " .. version .. " lines up with the stable door")
			assert(route[2].z < doorZ, "PK3 " .. version .. " joins inside the doorway room")
			-- where the next leg passes the wall it is inside the stable doorway with room for the body
			local a, b = route[2], route[3]
			local x = a.x + (b.x - a.x) * (doorZ - a.z) / (b.z - a.z)
			assert(math.abs(x - doors[stable]) <= Pockets.DOOR_WIDTH / 2 - CLEAR, "PK3 " .. version .. " door")
		end
	end)

	test("the straight mouth-to-mouth line is clear only where the version really is straight", function()
		local expect = {
			PK1 = { direct = true, loop = false, low = true },
			PK2 = { direct = true, dogleg = false, low = true },
			PK3 = { left = false, middle = true, right = false },
		}
		for _, id in pocketIds() do
			local def = WorldDefs.Pockets[id]
			local area = Pockets.area(def)
			local inset = Pockets.WALL + CLEAR + 1
			local a = Pockets.toWorld(area, 0, -inset, area.floorY)
			local b = Pockets.toWorld(area, 0, area.length + inset, area.floorY)
			for _, version in def.versions do
				eq(Pockets.creatureClear(def, version, a, b), expect[id][version], id .. " " .. version)
			end
		end
		-- a leg that brushes a wall is refused even where the floor itself continues
		local pk1 = WorldDefs.Pockets.PK1
		local area = Pockets.area(pk1)
		local edge = 6 - CLEAR + 0.5 -- the direct passage spans u -6..6
		eq(
			Pockets.creatureClear(
				pk1,
				"direct",
				Pockets.toWorld(area, edge, 10, area.floorY),
				Pockets.toWorld(area, edge, 40, area.floorY)
			),
			false
		)
	end)

	test("a low ceiling lowers the body under it; other versions keep the creature's own lift", function()
		for _, id in pocketIds() do
			local def = WorldDefs.Pockets[id]
			for _, version in def.versions do
				local lift = Pockets.creatureLift(def, version, THIEF_LIFT, THIEF_TOP)
				if version == "low" then
					assert(lift < THIEF_LIFT, id .. " low lowers the thief")
					assert(
						lift + THIEF_TOP <= Pockets.LOW_CEILING - Pockets.CREATURE_HEADROOM + 1e-9,
						id .. " low: the head stays under the ceiling"
					)
				else
					eq(lift, THIEF_LIFT, id .. " " .. version)
				end
			end
		end
		eq(Pockets.creatureLift(WorldDefs.Pockets.PK1, "low", 2, THIEF_TOP), 2, "a short body is not raised")
	end)

	test("gated pocket edges: open while the version has a route, closed pockets are routed round", function()
		local function r(a: string, b: string, open: { [string]: boolean }): { string }
			return CreatureRules.route(graph, a, b, open, false)
		end
		local all = { PK1 = true, PK2 = true, PK3 = true }
		eq(#r("R05.south_anchor", "R05.center_anchor", all), 1, "PK1 open")
		eq(#r("R05.south_anchor", "R05.center_anchor", { PK2 = true, PK3 = true }), 3, "PK1 closed: the bypass")
		eq(#r("R05.doorway_room", "R05.junction", all), 1, "PK3 open")
		eq(#r("R05.doorway_room", "R05.junction", { PK1 = true, PK2 = true }), 5, "PK3 closed: the east loop")
		eq(#r("R05.doorway_room", "R05.junction", {}), 0, "every pocket closed")
		-- the default graph (no gatePockets) keeps pocket corridors as plain edges
		local plain = CreatureRules.buildGraph(chamberIds, WorldDefs.Corridors)
		eq(#CreatureRules.route(plain, "R05.south_anchor", "R05.center_anchor", {}, false), 1)
	end)

	test("route geometry helpers: projection, points and the next point either way", function()
		local line = CreatureRules.routeLine({ v(0, 0, 0), v(10, 0, 0), v(10, 0, 10) }, "A", "B")
		eq(line.cum[3], 20)
		local s, d = CreatureRules.routeProject(line, v(4, 0, 1))
		T.near(s, 4, 1e-9)
		T.near(d, 1, 1e-9)
		local p = CreatureRules.routePoint(line, 15)
		T.near(p.x, 10, 1e-9)
		T.near(p.z, 5, 1e-9)
		local nxt, atGoal = CreatureRules.routeNext(line, 4, 20)
		assert(not atGoal and nxt.x == 10 and nxt.z == 0, "forward: the corner first")
		nxt, atGoal = CreatureRules.routeNext(line, 10, 20)
		assert(atGoal and nxt.z == 10, "at the corner: on to the end")
		nxt, atGoal = CreatureRules.routeNext(line, 15, 0)
		assert(not atGoal and nxt.x == 10 and nxt.z == 0, "backward: the corner first")
		nxt, atGoal = CreatureRules.routeNext(line, 15, 12)
		assert(atGoal and nxt.z == 2, "a goal before the next corner")
		nxt, atGoal = CreatureRules.routeNext(line, 10.3, 0)
		assert(atGoal and nxt.x == 0 and nxt.z == 0, "a corner within reach counts as passed")
	end)

	test("crossing every pocket version both ways stays in its passage and arrives", function()
		for _, id in pocketIds() do
			local def = WorldDefs.Pockets[id]
			for _, version in def.versions do
				local versions = defaults()
				versions[id] = version
				local tag = id .. " " .. version
				local a, b = node(def.from), node(def.to)
				local fin, trail = walk(versions, a, b, tag .. " forward")
				assert(near(fin, b, 0.5), tag .. " forward arrives")
				local through = false
				for _, p in trail do
					through = through or insideBounds(p, id)
				end
				assert(through, tag .. " takes the pocket (the shortest way)")
				fin = walk(versions, b, a, tag .. " back")
				assert(near(fin, a, 0.5), tag .. " back arrives")
			end
		end
	end)

	test("goals anywhere on a pocket's floor: the creature gets there or stops, never through rock", function()
		for _, id in pocketIds() do
			local def = WorldDefs.Pockets[id]
			for _, version in def.versions do
				local versions = defaults()
				versions[id] = version
				local g = gridFor(def, version)
				local y = def.bounds.min.y
				local arrived, close, total = 0, 0, 0
				local far: { string } = {}
				for k = 2, g.nz - 1, 5 do
					for i = 2, g.nx - 1, 5 do
						if Pockets.isWalkable(g.cells[k * g.nx + i + 1]) then
							local goal = v(g.x0 + i + 0.5, y, g.z0 + k + 0.5)
							local tag = string.format("%s %s goal (%.1f, %.1f)", id, version, goal.x, goal.z)
							local start = if (i + k) % 2 == 0 then node(def.from) else node(def.to)
							local fin = walk(versions, start, goal, tag)
							total += 1
							if near(fin, goal, 0.5) then
								arrived += 1
							end
							-- a goal against a wall leaves no room for the body: it gets as close as the floor allows
							if near(fin, goal, CLEAR * math.sqrt(2) + 1) then
								close += 1
							elseif #far < 4 then
								table.insert(
									far,
									string.format("(%.1f, %.1f) ends (%.1f, %.1f)", goal.x, goal.z, fin.x, fin.z)
								)
							end
						end
					end
				end
				local tag = string.format("%s %s: %d of %d goals, %d close", id, version, arrived, total, close)
				if id ~= "PK3" and close < total then
					tag ..= "; not close: " .. table.concat(far, ", ")
				end
				print("       " .. tag)
				assert(total > 0, tag)
				if id == "PK3" then
					-- the two false-door rings (about half of PK3's floor) are off the stable route
					assert(close >= total * 0.4, tag)
				else
					eq(close, total, tag)
				end
			end
		end
	end)

	test("the finding's cases: a roam to the centre anchor and a victim in the loop's side chamber", function()
		local versions = defaults()
		versions.PK1 = "loop"
		-- R04.map_room -> R05.center_anchor (a Lantern Thief home) runs through PK1
		local home = node("R05.center_anchor")
		local fin, trail = walk(versions, node("R04.map_room"), home, "roam home")
		assert(near(fin, home, 0.5), "arrives home")
		local east = -math.huge
		for _, p in trail do
			east = math.max(east, p.x)
		end
		assert(east > 20, "it walks the loop's side chamber instead of the rock on the centre line")
		-- a victim in the side chamber shares the south anchor as nearest chamber: still no straight line
		local victim = v(31, -84, 1160)
		fin = walk(versions, node("R05.south_anchor"), victim, "victim in the side chamber")
		assert(near(fin, victim, 0.5), "reaches the victim through the passage")
		-- from there (off the route) back out to the survey station
		fin = walk(versions, victim, node("R04.map_room"), "back out")
		assert(near(fin, node("R04.map_room"), 0.5))
		-- the side chamber's north end lies inside PK2's bounds too: it is still PK1's floor
		local northEnd = v(30, -84, 1178)
		assert(insideBounds(northEnd, "PK2"), "the bounds overlap here")
		fin = walk(versions, node("R05.south_anchor"), northEnd, "side chamber north end")
		assert(near(fin, northEnd, 0.5))
	end)

	test("PK3 left and right: the chase goes through the stable door, never the middle door's pillar", function()
		for _, version in { "left", "right" } do
			local versions = defaults()
			versions.PK3 = version
			local fin, trail = walk(versions, node("R05.doorway_room"), node("R05.junction"), "PK3 " .. version)
			assert(near(fin, node("R05.junction"), 0.5))
			local doors = WorldDefs.Pockets.PK3.doors :: { number }
			local door = doors[assert(Pockets.stableDoor(WorldDefs.Pockets.PK3, version))]
			local doorZ = Pockets.area(WorldDefs.Pockets.PK3).start - Pockets.WALL / 2
			for i = 1, #trail - 1 do
				local a, b = trail[i], trail[i + 1]
				if (a.z - doorZ) * (b.z - doorZ) <= 0 and a.z ~= b.z then
					local x = a.x + (b.x - a.x) * (doorZ - a.z) / (b.z - a.z)
					assert(math.abs(x - door) < 3, "PK3 " .. version .. " passes the wall at its stable door")
				end
			end
		end
	end)

	test("a pocket with no creature route is closed: creatures take the stable bypass", function()
		local versions = defaults()
		versions.PK1 = nil
		local fin, trail = walk(versions, node("R05.south_anchor"), node("R05.center_anchor"), "PK1 closed")
		assert(near(fin, node("R05.center_anchor"), 0.5))
		for _, p in trail do
			assert(not insideBounds(p, "PK1"), "never enters a closed pocket")
		end
	end)

	test("a straight leg that would cross a pocket is refused: back to the chamber centre, else blocked", function()
		local nav = makeNav(defaults())
		-- both ends outside every pocket and nearest the south anchor, but the line runs through PK1's rock
		local centre = node("R05.south_anchor")
		local from, to = v(6, -84, 1110), v(45, -84, 1150)
		eq(nav.nearestNode(from), "R05.south_anchor")
		eq(nav.nearestNode(to), "R05.south_anchor")
		local target, final, blocked = CreatureRules.nextLeg(nav, from, to, false)
		assert(near(target, centre, 1e-9) and not final and not blocked, "first to the chamber centre")
		target, final, blocked = CreatureRules.nextLeg(nav, centre, to, false)
		assert(blocked and not final, "from the centre the line still crosses: blocked")
		-- the corner a closed pocket's bypass turns at west_anchor: never the diagonal past PK1
		local versions = defaults()
		versions.PK1 = nil
		local corner = v(-62.8, -84, 1166.7) -- nearest west_anchor, heading for the centre anchor
		target = CreatureRules.nextLeg(makeNav(versions), corner, node("R05.center_anchor"), false)
		assert(near(target, node("R05.west_anchor"), 1e-9), "via the west anchor's centre")
	end)

	print("Chalk Hand false marks never on pocket surfaces (finding 14)")

	test("a false-mark spot inside any pocket's bounds is refused; anchors still take one", function()
		local function inPocket(p: V3): boolean
			return WorldDefs.pocketAt(p) ~= nil
		end
		assert(not CreatureRules.fakeSpotAllowed(v(6, -83, 1160), {}, inPocket), "PK1 floor")
		assert(not CreatureRules.fakeSpotAllowed(v(30, -80, 1178), {}, inPocket), "PK1 loop, inside PK2's bounds")
		assert(not CreatureRules.fakeSpotAllowed(v(-6, -80, 1340), {}, inPocket), "PK3 passage wall")
		assert(CreatureRules.fakeSpotAllowed(v(6, -83, 1112), {}, inPocket), "South Survey Anchor floor")
		assert(
			not CreatureRules.fakeSpotAllowed(v(6, -83, 1112), { v(7, -83, 1112) }, inPocket),
			"still never on one of the player's own marks"
		)
		-- candidates round a mark on the south anchor's north wall, beside the PK1 doorway
		local mark = v(16, -80, 1133.9)
		local kept = 0
		for _, c in CreatureRules.fakeMarkCandidates(mark, v(0, 0, -1)) do
			if CreatureRules.fakeSpotAllowed(c, { mark }, inPocket) then
				kept += 1
				assert(WorldDefs.pocketAt(c) == nil)
			end
		end
		assert(kept > 0, "a static wall beside a pocket still takes fakes")
	end)

	test("the hand never imitates a mark inside a pocket, but still imitates one in an anchor room", function()
		local H = CreatureRules.ChalkHand
		local function inPocket(p: V3): boolean
			return WorldDefs.pocketAt(p) ~= nil
		end
		local player = v(6, -81, 1132)
		local inPk1 = v(6, -83, 1140) -- nearer, inside PK1
		local inAnchor = v(6, -83, 1112)
		local own = { inPk1, inAnchor }
		eq(CreatureRules.chalkHandTarget(H.regionId, 1000, nil, 120, player, own), inPk1, "default: the nearest")
		eq(CreatureRules.chalkHandTarget(H.regionId, 1000, nil, 120, player, own, inPocket), inAnchor)
		eq(CreatureRules.chalkHandTarget(H.regionId, 1000, nil, 120, player, { inPk1 }, inPocket), nil)
	end)

	print("Review round 2: research grants and tool targets")

	test("every obtainable research evidence id of every SLICE creature is granted by its module", function()
		-- Progress.addEvidence raises a stage only when the evidence for every earlier stage is present, so one
		-- missing grant (the Knocker's "seen") freezes that creature's research at stage 0 (F07)
		local checked = 0
		for key, def in WorldDefs.Creatures do
			if def.status == "SLICE" then
				local name = assert(string.match(key, "^C%d+_(%w+)$"), key)
				local src = fs.readFile("src/server/Services/Creatures/" .. name .. ".luau")
				local cap = (def :: any).researchCap or #def.researchEvidence
				for i = 1, cap do
					local id = def.researchEvidence[i]
					assert(
						string.find(src, 'Common%.evidence%([^\n]*"' .. id .. '"%)') ~= nil,
						string.format("%s never grants %q (stage %d)", key, id, i)
					)
					checked += 1
				end
			end
		end
		assert(checked >= 8 * 3, "every SLICE creature checked")
	end)

	test("tools try threats before harmless phenomena, nearest first within each", function()
		local order = CreatureRules.toolTargetOrder({
			{ harmless = true, dist = 5 }, -- a roost right in front
			{ harmless = false, dist = 12 }, -- the thief behind it
			{ harmless = false, dist = 9 },
			{ harmless = true, dist = 3 },
		})
		eq(table.concat(order, ","), "3,2,4,1")
		eq(#CreatureRules.toolTargetOrder({}), 0)
		eq(table.concat(CreatureRules.toolTargetOrder({ { harmless = true, dist = 4 } }), ","), "1")
	end)
end
