--!strict
-- Package A (world, variable pockets, pocket-versioned records, discovery fixes). Pure rules only: the version
-- schedule, the blocker rule, every version's geometry contract, record migration and the scavenging remainder.
-- None of this proves the geometry renders, replicates or feels right in Roblox; see docs/TEST-PLAN.md rows.

local WorldDefs = require("../../src/shared/Data/WorldDefs")
local Config = require("../../src/shared/Data/Config")
local Pockets = require("../../src/shared/Logic/Pockets")
local NavRecords = require("../../src/shared/Logic/NavRecords")
local RecoveryBags = require("../../src/shared/Logic/RecoveryBags")
local Discovery = require("../../src/shared/Logic/Discovery")

Pockets.bind(WorldDefs)

type V3 = { x: number, y: number, z: number }

local MARGIN = Config.Pockets.occupancyMargin
local CYCLE = Config.Pockets.cycleSeconds

local function pocketIds(): { string }
	local ids = {}
	for id in WorldDefs.Pockets do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function def(id: string): any
	return assert(WorldDefs.Pockets[id])
end

local function centre(pk: any): V3
	return {
		x = (pk.bounds.min.x + pk.bounds.max.x) / 2,
		y = pk.bounds.min.y + 3,
		z = (pk.bounds.min.z + pk.bounds.max.z) / 2,
	}
end

-- Grid helpers over a plan --------------------------------------------------------------------------
type G = { nx: number, nz: number, x0: number, z0: number, cells: { number } }

local function gridOf(plan: any): G
	return Pockets.grid(plan.area, plan.walk, plan.lowWalk) :: any
end

local function cell(g: G, i: number, k: number): number
	return g.cells[k * g.nx + i + 1]
end

local function walkable(g: G, i: number, k: number): boolean
	return i >= 0 and i < g.nx and k >= 0 and k < g.nz and Pockets.isWalkable(cell(g, i, k))
end

-- Cell indices of the first and last rows (along the pocket axis) as {i, k} pairs, and the across coordinate.
local function edgeCells(plan: any, g: G, last: boolean): { { number } }
	local out = {}
	local area = plan.area
	if area.axis == "z" then
		local k = if last then g.nz - 1 else 0
		for i = 0, g.nx - 1 do
			table.insert(out, { i, k })
		end
	else
		local i = if last then g.nx - 1 else 0
		for k = 0, g.nz - 1 do
			table.insert(out, { i, k })
		end
	end
	return out
end

-- local u (across) of a cell's centre
local function uOf(plan: any, g: G, i: number, k: number): number
	local area = plan.area
	if area.axis == "z" then
		return g.x0 + i + 0.5 - area.center
	end
	return g.z0 + k + 0.5 - area.center
end

local function flood(g: G, seeds: { { number } }): { [number]: boolean }
	local seen: { [number]: boolean } = {}
	local queue = {}
	for _, s in seeds do
		if walkable(g, s[1], s[2]) then
			local idx = s[2] * g.nx + s[1]
			if not seen[idx] then
				seen[idx] = true
				table.insert(queue, s)
			end
		end
	end
	local head = 1
	while head <= #queue do
		local c = queue[head]
		head += 1
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local i, k = c[1] + d[1], c[2] + d[2]
			if walkable(g, i, k) then
				local idx = k * g.nx + i
				if not seen[idx] then
					seen[idx] = true
					table.insert(queue, { i, k })
				end
			end
		end
	end
	return seen
end

local function inSpan(u: number, spans: { { number } }): number?
	for n, sp in spans do
		if u > sp[1] and u < sp[2] then
			return n
		end
	end
	return nil
end

-- True when the component encloses a non-walkable hole (the false-door rings go round a pillar).
local function hasHole(g: G, comp: { [number]: boolean }): boolean
	local i0, i1, k0, k1 = math.huge, -math.huge, math.huge, -math.huge
	for idx in comp do
		local i, k = idx % g.nx, idx // g.nx
		i0, i1, k0, k1 = math.min(i0, i), math.max(i1, i), math.min(k0, k), math.max(k1, k)
	end
	i0, i1, k0, k1 = i0 - 1, i1 + 1, k0 - 1, k1 + 1
	local outside: { [string]: boolean } = {}
	local queue = {}
	local function push(i: number, k: number)
		local key = i .. ":" .. k
		if i < i0 or i > i1 or k < k0 or k > k1 or outside[key] or comp[k * g.nx + i] then
			return
		end
		outside[key] = true
		table.insert(queue, { i, k })
	end
	for i = i0, i1 do
		push(i, k0)
		push(i, k1)
	end
	for k = k0, k1 do
		push(i0, k)
		push(i1, k)
	end
	local head = 1
	while head <= #queue do
		local c = queue[head]
		head += 1
		push(c[1] + 1, c[2])
		push(c[1] - 1, c[2])
		push(c[1], c[2] + 1)
		push(c[1], c[2] - 1)
	end
	for i = i0 + 1, i1 - 1 do
		for k = k0 + 1, k1 - 1 do
			if not comp[k * g.nx + i] and not outside[i .. ":" .. k] then
				return true
			end
		end
	end
	return false
end

local function boxesOverlap(a: any, b: any): boolean
	return a.x0 < b.x1 and a.x1 > b.x0 and a.z0 < b.z1 and a.z1 > b.z0
end

local function chamberBox(c: any)
	return {
		x0 = c.pos.x - c.size.x / 2 - 2,
		z0 = c.pos.z - c.size.z / 2 - 2,
		x1 = c.pos.x + c.size.x / 2 + 2,
		z1 = c.pos.z + c.size.z / 2 + 2,
	}
end

return function(T: any)
	local test, eq = T.test, T.eq

	print("Variable pockets: schedule and blockers (F08, section 04)")

	test("the schedule is deterministic and cycles through every version", function()
		for _, id in pocketIds() do
			local pk = def(id)
			local t = 1_790_000_000
			eq(Pockets.targetVersion(pk, t, CYCLE), Pockets.targetVersion(pk, t, CYCLE), id .. " same inputs")
			eq(Pockets.targetVersion(pk, t, CYCLE), Pockets.targetVersion(pk, t + CYCLE - 1 - t % CYCLE, CYCLE))
			local seen: { [string]: boolean } = {}
			for c = 0, #pk.versions - 1 do
				seen[Pockets.targetVersion(pk, t + c * CYCLE, CYCLE)] = true
			end
			for _, v in pk.versions do
				assert(seen[v], id .. " never shows " .. v)
			end
			-- consecutive cycles always change the version
			assert(Pockets.targetVersion(pk, t, CYCLE) ~= Pockets.targetVersion(pk, t + CYCLE, CYCLE), id)
		end
		eq(Pockets.offset("PK1"), Pockets.offset("PK1"))
	end)

	test("pockets do not all change in lockstep", function()
		local phases: { [number]: boolean } = {}
		local n = 0
		for _, id in pocketIds() do
			local p = Pockets.offset(id) % #def(id).versions
			if not phases[p] then
				phases[p] = true
				n += 1
			end
		end
		assert(n >= 2, "every pocket has the same schedule phase")
	end)

	test("players block inside bounds plus margin, whatever their state; just beyond the margin does not", function()
		local pk = def("PK1")
		local c = centre(pk)
		eq(Pockets.blocker(pk, { characters = { c } }, MARGIN), "player")
		local edge = { x = pk.bounds.max.x + MARGIN - 0.5, y = c.y, z = c.z }
		eq(Pockets.blocker(pk, { characters = { edge } }, MARGIN), "player", "inside the margin")
		local beyond = { x = pk.bounds.max.x + MARGIN + 0.5, y = c.y, z = c.z }
		eq(Pockets.blocker(pk, { characters = { beyond } }, MARGIN), nil, "beyond the margin")
		eq(Pockets.blocker(pk, {}, MARGIN), nil, "empty")
		-- a hidden, downed or carried player is still a character position: the service passes every character
		eq(Pockets.blocker(pk, { characters = { beyond, c } }, MARGIN), "player")
	end)

	test(
		"PocketBlocker instances, online owners' bags and ropes block; offline owners, chalk and signs never",
		function()
			local pk = def("PK2")
			local c = centre(pk)
			local far = { x = 0, y = 0, z = 0 }
			eq(Pockets.blocker(pk, { tagged = { c } }, MARGIN), "blocker")
			eq(Pockets.blocker(pk, { bags = { { pos = c, ownerOnline = true } } }, MARGIN), "bag")
			eq(Pockets.blocker(pk, { bags = { { pos = c, ownerOnline = false } } }, MARGIN), nil)
			eq(Pockets.blocker(pk, { nav = { { kind = "rope", pos = c, ownerOnline = true } } }, MARGIN), "rope")
			eq(Pockets.blocker(pk, { nav = { { kind = "rope", pos = c, ownerOnline = false } } }, MARGIN), nil)
			eq(
				Pockets.blocker(pk, { nav = { { kind = "rope", pos = far, endPos = c, ownerOnline = true } } }, MARGIN),
				"rope"
			)
			eq(Pockets.blocker(pk, { nav = { { kind = "chalk", pos = c, ownerOnline = true } } }, MARGIN), nil)
			eq(Pockets.blocker(pk, { nav = { { kind = "sign", pos = c, ownerOnline = true } } }, MARGIN), nil)
			-- a rope whose line crosses the bounds blocks even with both ends outside
			local a = { x = pk.bounds.min.x - MARGIN - 3, y = c.y, z = c.z }
			local b = { x = pk.bounds.max.x + MARGIN + 3, y = c.y, z = c.z }
			eq(
				Pockets.blocker(pk, { nav = { { kind = "rope", pos = a, endPos = b, ownerOnline = true } } }, MARGIN),
				"rope"
			)
			local a2 = { x = pk.bounds.min.x - MARGIN - 3, y = c.y, z = pk.bounds.min.z - MARGIN - 3 }
			local b2 = { x = pk.bounds.min.x - MARGIN - 3, y = c.y, z = pk.bounds.max.z + MARGIN + 3 }
			eq(
				Pockets.blocker(pk, { nav = { { kind = "rope", pos = a2, endPos = b2, ownerOnline = true } } }, MARGIN),
				nil
			)
		end
	)

	print("Variable pockets: geometry contract")

	test("every version joins the same two mouth doorways and stays inside the pocket area", function()
		for _, id in pocketIds() do
			local pk = def(id)
			local spans = Pockets.mouthSpans(pk)
			for _, version in pk.versions do
				local plan = Pockets.plan(pk, version)
				local g = gridOf(plan)
				local tag = id .. " " .. version
				-- walls must fit inside the area across the pocket
				for idx, cv in g.cells do
					if Pockets.isWalkable(cv) then
						local i, k = (idx - 1) % g.nx, (idx - 1) // g.nx
						local u = uOf(plan, g, i, k)
						assert(
							u > plan.area.uMin + 2 and u < plan.area.uMax - 2,
							tag .. " walkable too close to bounds"
						)
					end
				end
				-- walkable mouth-row cells only open onto a doorway
				local firstRow, lastRow = edgeCells(plan, g, false), edgeCells(plan, g, true)
				for _, c in firstRow do
					if walkable(g, c[1], c[2]) then
						assert(inSpan(uOf(plan, g, c[1], c[2]), spans.first), tag .. " opens beside the first doorway")
					end
				end
				for _, c in lastRow do
					if walkable(g, c[1], c[2]) then
						assert(
							inSpan(uOf(plan, g, c[1], c[2]), spans.second),
							tag .. " opens beside the second doorway"
						)
					end
				end
				-- every door leads somewhere, and the second mouth is reachable from the first
				local reach = flood(g, firstRow)
				local reachesEnd = false
				for _, c in lastRow do
					if reach[c[2] * g.nx + c[1]] then
						reachesEnd = true
					end
				end
				assert(reachesEnd, tag .. " has no path between the mouths")
				for n in spans.first do
					local any = false
					for _, c in firstRow do
						if walkable(g, c[1], c[2]) and inSpan(uOf(plan, g, c[1], c[2]), spans.first) == n then
							any = true
						end
					end
					assert(any, tag .. " door " .. n .. " is sealed")
				end
			end
		end
	end)

	test("every passage is passable standing: width at least 4, ceilings at least 8", function()
		assert(Pockets.LOW_CEILING >= 8)
		assert(Pockets.LOW_CEILING < WorldDefs.CORRIDOR_HEIGHT)
		-- every walkable cell lies in a fully walkable 4x4 square: no gap narrower than 4 studs anywhere
		for _, id in pocketIds() do
			local pk = def(id)
			for _, version in pk.versions do
				local g = gridOf(Pockets.plan(pk, version))
				for k = 0, g.nz - 1 do
					for i = 0, g.nx - 1 do
						if walkable(g, i, k) then
							local fits = false
							for a = -3, 0 do
								for b = -3, 0 do
									local all = true
									for di = 0, 3 do
										for dk = 0, 3 do
											if not walkable(g, i + a + di, k + b + dk) then
												all = false
											end
										end
									end
									fits = fits or all
								end
							end
							assert(fits, string.format("%s %s squeezes below 4 studs at cell %d,%d", id, version, i, k))
						end
					end
				end
			end
		end
		assert(#Pockets.plan(def("PK1"), "low").lows > 0, "PK1 low has a low ceiling")
		eq(#Pockets.plan(def("PK1"), "direct").lows, 0)
	end)

	test("walls never stand on walkable floor and floors cover every walkable and wall cell", function()
		for _, id in pocketIds() do
			local pk = def(id)
			for _, version in pk.versions do
				local plan = Pockets.plan(pk, version)
				local g = gridOf(plan)
				local function covered(list: { any }, x: number, z: number): boolean
					for _, b in list do
						if x > b.x0 and x < b.x1 and z > b.z0 and z < b.z1 then
							return true
						end
					end
					return false
				end
				for k = 0, g.nz - 1 do
					for i = 0, g.nx - 1 do
						local x, z = g.x0 + i + 0.5, g.z0 + k + 0.5
						local cv = cell(g, i, k)
						eq(covered(plan.walls, x, z), Pockets.isWall(cv), id .. " " .. version .. " wall cell")
						eq(covered(plan.floors, x, z), cv ~= 0, id .. " " .. version .. " floor cell")
					end
				end
			end
		end
	end)

	test("versions really differ and the detours block the straight line", function()
		for _, id in pocketIds() do
			local pk = def(id)
			local seen: { [string]: string } = {}
			for _, version in pk.versions do
				local g = gridOf(Pockets.plan(pk, version))
				local sig = table.concat(g.cells :: any, "")
				assert(seen[sig] == nil, id .. " " .. version .. " is identical to " .. tostring(seen[sig]))
				seen[sig] = version
			end
		end
		-- PK1 loop: the straight line between the mouths is rock half way along
		local plan = Pockets.plan(def("PK1"), "loop")
		local g = gridOf(plan)
		local mid = math.floor(g.nz / 2)
		local i = math.floor(plan.area.center - g.x0)
		eq(walkable(g, i, mid), false, "PK1 loop centre line")
	end)

	test("P06: only the named door reaches the junction; the other doors loop back to themselves", function()
		local pk = def("PK3")
		local spans = Pockets.mouthSpans(pk)
		for vi, version in pk.versions do
			local plan = Pockets.plan(pk, version)
			local g = gridOf(plan)
			local firstRow, lastRow = edgeCells(plan, g, false), edgeCells(plan, g, true)
			for n in spans.first do
				local seeds = {}
				for _, c in firstRow do
					if inSpan(uOf(plan, g, c[1], c[2]), spans.first) == n then
						table.insert(seeds, c)
					end
				end
				local comp = flood(g, seeds)
				local reachesJunction = false
				for _, c in lastRow do
					if comp[c[2] * g.nx + c[1]] then
						reachesJunction = true
					end
				end
				eq(reachesJunction, n == vi, version .. " door " .. n .. " reaches the junction")
				-- no door's passage reaches another door
				for _, c in firstRow do
					if comp[c[2] * g.nx + c[1]] then
						eq(
							inSpan(uOf(plan, g, c[1], c[2]), spans.first),
							n,
							version .. " door " .. n .. " joins another"
						)
					end
				end
				if n ~= vi then
					assert(hasHole(g, comp), version .. " false door " .. n .. " is a dead end without a loop")
				end
			end
			eq(Pockets.stableDoor(pk, version), vi)
			-- door marks: exactly one stable door carrying the centre anchor's symbol
			local stable = 0
			for di, d in assert(plan.doors) do
				eq(d.x, assert(pk.doors)[di])
				if d.stable then
					stable += 1
					eq(d.symbol, Pockets.ANCHOR_SYMBOLS["R05.center_anchor"])
				else
					assert(d.symbol ~= Pockets.STABLE_SYMBOL, "a false door shows the stable symbol")
				end
			end
			eq(stable, 1)
			-- the verification trigger sits just past the stable door, on walkable floor of the true passage
			local v = assert(plan.verify)
			local door = assert(pk.doors)[vi]
			assert(v.x0 >= door - 3 and v.x1 <= door + 3, version .. " verify box outside the door")
			local gi, gk = math.floor((v.x0 + v.x1) / 2 - g.x0), math.floor((v.z0 + v.z1) / 2 - g.z0)
			assert(walkable(g, gi, gk), version .. " verify box not on the passage")
		end
		local obs = WorldDefs.Puzzles.P06.observationStep
		eq(WorldDefs.pocketAt(obs), nil, "the observation step is outside the pocket")
	end)

	test("P06 lamps: one shared, repeating rhythm; never strobing; reduceFlashes never goes dark", function()
		local period = WorldDefs.Puzzles.P06.flickerPeriodSeconds
		local t0 = 1_790_000_000
		local changes, last = 0, Pockets.p06LampLevel(t0, period, false)
		local dimmest = 1
		for i = 1, 120 do -- 12 s at 0.1 s steps
			local t = t0 + i * 0.1
			eq(Pockets.p06LampLevel(t, period, false), Pockets.p06LampLevel(t + period, period, false), "repeats")
			local l = Pockets.p06LampLevel(t, period, false)
			if l ~= last then
				changes += 1
			end
			last = l
			local r = Pockets.p06LampLevel(t, period, true)
			dimmest = math.min(dimmest, r)
			assert(math.abs(r - Pockets.p06LampLevel(t - 0.1, period, true)) < 0.2, "reduceFlashes jumps")
		end
		assert(changes > 0, "the false-door lamps never change")
		assert(changes <= 3 * Pockets.P06_PULSE_SECONDS + 1, "more than 3 changes per second")
		assert(dimmest >= 0.4 and dimmest < 0.9, "reduceFlashes dip " .. dimmest)
		eq(Pockets.p06LampLevel(t0 - (t0 % period) + period - 1, period, false), 1, "steady between pulses")
	end)

	test("every point a pocket can block maps to the pocket's region (records there use that page)", function()
		-- WorldBuilder.nearestChamber's metric: height weighs triple
		local function regionAt(p: V3): string
			local best, bestD = nil, math.huge
			for _, c in WorldDefs.Chambers do
				local d = math.sqrt((c.pos.x - p.x) ^ 2 + ((c.pos.y + 3 - p.y) * 3) ^ 2 + (c.pos.z - p.z) ^ 2)
				if d < bestD then
					best, bestD = c, d
				end
			end
			return assert(best).regionId
		end
		for _, id in pocketIds() do
			local pk = def(id)
			local b = pk.bounds
			for x = b.min.x - MARGIN, b.max.x + MARGIN, 4 do
				for z = b.min.z - MARGIN, b.max.z + MARGIN, 4 do
					eq(regionAt({ x = x, y = b.min.y + 3, z = z }), pk.regionId, id .. " at " .. x .. "," .. z)
				end
			end
		end
	end)

	test("pocket geometry never intrudes into static chambers, stable corridors or another pocket", function()
		local plans = {}
		for _, id in pocketIds() do
			for _, version in def(id).versions do
				table.insert(plans, Pockets.plan(def(id), version))
			end
		end
		local corridors = {}
		for _, cor in WorldDefs.Corridors do
			local a, c = assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to))
			if cor.pocket == nil and a.pos.y == c.pos.y then
				local lo, hi = a, c
				if (a.pos.x == c.pos.x and a.pos.z > c.pos.z) or (a.pos.x ~= c.pos.x and a.pos.x > c.pos.x) then
					lo, hi = c, a
				end
				local w = WorldDefs.CORRIDOR_WIDTH / 2 + 2
				table.insert(
					corridors,
					if a.pos.x == c.pos.x
						then {
							x0 = a.pos.x - w,
							x1 = a.pos.x + w,
							z0 = lo.pos.z + lo.size.z / 2 + 2,
							z1 = hi.pos.z - hi.size.z / 2 - 2,
							y = a.pos.y,
						}
						else {
							x0 = lo.pos.x + lo.size.x / 2 + 2,
							x1 = hi.pos.x - hi.size.x / 2 - 2,
							z0 = a.pos.z - w,
							z1 = a.pos.z + w,
							y = a.pos.y,
						}
				)
			end
		end
		for _, plan in plans do
			for _, b in plan.floors do
				for _, c in WorldDefs.Chambers do
					if c.pos.y == plan.floorY then
						assert(
							not boxesOverlap(b, chamberBox(c)),
							plan.pocketId .. " " .. plan.version .. " cuts " .. c.id
						)
					end
				end
				for _, cb in corridors do
					if cb.y == plan.floorY then
						assert(
							not boxesOverlap(b, cb),
							plan.pocketId .. " " .. plan.version .. " cuts a stable corridor"
						)
					end
				end
				for _, other in plans do
					if other.pocketId ~= plan.pocketId then
						for _, ob in other.floors do
							assert(not boxesOverlap(b, ob), plan.pocketId .. " overlaps " .. other.pocketId)
						end
					end
				end
			end
		end
	end)

	test("threshold plates sit on the mouth chambers' walls beside (not in) the doorways", function()
		for _, id in pocketIds() do
			local pk = def(id)
			local spans = Pockets.mouthSpans(pk)
			local plates = Pockets.thresholds(pk)
			eq(#plates, 2)
			local area = Pockets.area(pk)
			for n, p in plates do
				local u = if area.axis == "z" then p.pos.x - area.center else p.pos.z - area.center
				local list = if n == 1 then spans.first else spans.second
				for _, sp in list do
					assert(u - 1.6 >= sp[2] or u + 1.6 <= sp[1], id .. " plate " .. n .. " covers a doorway")
				end
				eq(WorldDefs.pocketAt(p.pos), nil, id .. " plate inside the pocket")
			end
			eq(#Pockets.mouthPoints(pk), 2)
		end
	end)

	print("Pocket-versioned records (section 04, 15, 16; T17, T18)")

	test("records are tagged with pocket and version inside pockets and keep the static default outside", function()
		local versionOf = function(pid: string): string?
			return if pid == "PK1" then "loop" else "direct"
		end
		local inPk1 = centre(def("PK1"))
		local pid, ver = Pockets.tagFor({ inPk1 }, versionOf)
		eq(pid, "PK1")
		eq(ver, "loop")
		local south = assert(WorldDefs.chamber("R05.south_anchor")).pos
		pid, ver = Pockets.tagFor({ { x = south.x, y = south.y + 1, z = south.z } }, versionOf)
		eq(pid, nil)
		eq(ver, Pockets.STATIC_VERSION)
		-- a rope starting outside with its end inside belongs to the pocket
		pid = Pockets.tagFor({ { x = south.x, y = south.y + 1, z = south.z }, inPk1 }, versionOf)
		eq(pid, "PK1")
		-- a mark on the mouth chamber's own (static) wall face is static, although WorldDefs bounds touch it
		local wallFace = { x = south.x + 9, y = south.y + 4, z = def("PK1").bounds.min.z }
		assert(WorldDefs.pocketAt(wallFace) ~= nil, "fixture: the bounds include the wall face")
		eq((Pockets.tagFor({ wallFace }, versionOf)), nil, "static wall face")
		-- just inside the pocket's first row it belongs to the pocket
		local firstRow = { x = south.x, y = south.y + 1, z = Pockets.area(def("PK1")).start + 0.5 }
		eq((Pockets.tagFor({ firstRow }, versionOf)), "PK1")
		-- the pocket service not running yet: the record still knows its pocket and migrates later
		pid, ver = Pockets.tagFor({ inPk1 }, function()
			return nil
		end)
		eq(pid, "PK1")
		eq(ver, Pockets.UNKNOWN_VERSION)
	end)

	local function store3()
		local st = NavRecords.newStore()
		local function put(kind: any, pocketId: string?, version: any, pos: V3, endPos: V3?)
			local item = if kind == "chalk" then "nav.chalk" elseif kind == "sign" then "nav.sign" else "nav.rope"
			local content = if kind == "chalk" then "arrow" elseif kind == "sign" then "dead_end" else "guide"
			return assert(NavRecords.place(st, {
				ownerId = 7,
				kind = kind,
				itemId = item,
				regionId = "R05",
				pocketId = pocketId,
				pocketVersion = version,
				anchorId = "R05.south_anchor",
				position = pos,
				facing = { x = 0, y = 0, z = -1 },
				endPosition = endPos,
				routeId = "B",
				content = content,
				units = 1,
			}, 400))
		end
		return st, put
	end

	test("migration moves only that pocket's stale records, keeps owner, units and route, never deletes", function()
		local st, put = store3()
		local c1, c2 = centre(def("PK1")), centre(def("PK2"))
		local chalk = put("chalk", "PK1", "direct", c1)
		local rope = put("rope", "PK1", "direct", c1, { x = c1.x, y = c1.y, z = c1.z + 10 })
		local sign = put("sign", "PK1", "loop", c1) -- already the current version
		local other = put("chalk", "PK2", "direct", c2)
		local static = put("chalk", nil, 1, { x = 6, y = -83, z = 1110 })
		local before = NavRecords.countOwned(st)
		local target = Pockets.migrationTarget(def("PK1"), MARGIN)
		local moved = NavRecords.migratePocketRecords(st, "PK1", "loop", target)
		eq(#moved, 2)
		eq(NavRecords.countOwned(st), before, "never deletes")
		eq(chalk.pocketId, nil)
		eq(chalk.anchorId, "R05.south_anchor")
		eq(chalk.ownerId, 7)
		eq(chalk.units, 1)
		eq(chalk.routeId, "B")
		eq(chalk.content, "arrow")
		eq(assert(chalk.migratedFrom).pocketId, "PK1")
		eq(assert(chalk.migratedFrom).version, "direct")
		eq(rope.endPosition, nil, "a moved rope collapses to a coil")
		eq(rope.units, 1)
		eq(sign.pocketId, "PK1", "a record of the current version stays")
		eq(sign.migratedFrom, nil)
		eq(other.pocketId, "PK2", "other pockets untouched")
		eq(other.position.x, c2.x)
		eq(static.migratedFrom, nil, "static records untouched")
		eq(static.position.z, 1110)
		-- moved records lie inside the anchor chamber, outside every pocket, on distinct spots
		local anchor = assert(WorldDefs.chamber("R05.south_anchor"))
		for _, r in moved do
			assert(math.abs(r.position.x - anchor.pos.x) < anchor.size.x / 2, "inside the anchor chamber")
			assert(math.abs(r.position.z - anchor.pos.z) < anchor.size.z / 2, "inside the anchor chamber")
			for _, pk in WorldDefs.Pockets do
				eq(Pockets.inBounds(pk, r.position, MARGIN), false, "a moved record must never block a pocket")
			end
		end
		assert(chalk.position.x ~= rope.position.x or chalk.position.z ~= rope.position.z, "stacked on one spot")
		-- idempotent
		eq(#NavRecords.migratePocketRecords(st, "PK1", "loop", target), 0)
		eq(#NavRecords.migratePocketRecords(st, "PK1", "low", target), 1, "the sign moves at the next change")
	end)

	test(
		"lazy migration: a record placed on another server migrates when the versions differ, not when equal",
		function()
			local here = function(pid: string): string?
				return if pid == "PK3" then "middle" else nil
			end
			eq(Pockets.isStale("PK3", "left", here), true)
			eq(Pockets.isStale("PK3", "middle", here), false)
			eq(Pockets.isStale("PK1", "direct", here), false, "pocket not running: never move")
			eq(Pockets.isStale(nil, 1, here), false, "static records never migrate")
			eq(Pockets.isStale("PK3", Pockets.UNKNOWN_VERSION, here), true)
		end
	)

	test("legacy checkpoint anchors inside a pocket are tagged so they migrate; others are left alone", function()
		local south = assert(WorldDefs.chamber("R05.south_anchor"))
		local c = centre(def("PK1"))
		local a = {
			regionId = "R05",
			pocketVersion = 1,
			anchorId = south.id,
			offset = { x = c.x - south.pos.x, y = 1, z = c.z - south.pos.z },
		}
		eq(Pockets.tagAnchor(a), true)
		eq((a :: any).pocketId, "PK1")
		eq(a.pocketVersion, Pockets.UNKNOWN_VERSION)
		local b = { regionId = "R05", pocketVersion = 1, anchorId = south.id, offset = { x = 0, y = 1, z = 0 } }
		eq(Pockets.tagAnchor(b), false)
		eq((b :: any).pocketId, nil)
		eq(Pockets.tagAnchor({ anchorId = "nowhere", offset = { x = 0, y = 0, z = 0 } }), false)
		eq(Pockets.tagAnchor(nil), false)
	end)

	test("bags migrate with a fresh anchor, keep contents and id, and anchors are never aliased", function()
		local p = { bags = {}, escrow = {}, appliedOps = {} }
		local c = centre(def("PK2"))
		local cp = {
			regionId = "R05",
			pocketVersion = "dogleg",
			pocketId = "PK2",
			anchorId = "R05.center_anchor",
			offset = {
				x = c.x - 6,
				y = 1,
				z = c.z - 1210,
			},
		}
		local bag = assert(RecoveryBags.create(p :: any, "logout", 7, { ["mat.plank"] = 2 }, cp :: any, "op-1", 0))
		assert(bag.anchor ~= (cp :: any), "anchor aliased to the checkpoint")
		local death = assert(RecoveryBags.create(p :: any, "death", 7, { ["mat.fabric"] = 1 }, {
			regionId = "R01",
			pocketVersion = 1,
			anchorId = "R01.split_pier",
			offset = { x = 0, y = 0, z = 0 },
		}, "op-2", 0))
		local def2 = def("PK2")
		local target = {
			regionId = "R05",
			anchorId = def2.migrationAnchor,
			offsetFor = function(kind: any)
				local s = Pockets.migrationSpot(def2, if kind == "death" then 24 else 25, MARGIN)
				return { x = s.x - 6, y = 1, z = s.z - 1210 }
			end,
		}
		local moved = RecoveryBags.migratePocket(p :: any, "PK2", "low", target :: any)
		eq(#moved, 1)
		eq(moved[1], bag)
		eq(bag.anchor.anchorId, "R05.center_anchor")
		eq(bag.anchor.pocketId, nil)
		eq(assert(bag.migratedFrom).version, "dogleg")
		eq(bag.contents["mat.plank"], 2)
		eq(bag.bagId, "logout:op-1")
		eq(cp.pocketId, "PK2", "the checkpoint did not move with the bag")
		eq(death.anchor.anchorId, "R01.split_pier", "static bag untouched")
		eq(#RecoveryBags.migratePocket(p :: any, "PK2", "low", target :: any), 0, "idempotent")
		local copy = RecoveryBags.copy(bag)
		copy.contents["mat.plank"] = 99
		eq(bag.contents["mat.plank"], 2, "copies are read-only views")
	end)

	test("migration spots are inside the anchor chamber and outside every pocket's blocking area", function()
		for _, id in pocketIds() do
			local pk = def(id)
			local anchor = assert(WorldDefs.chamber(pk.migrationAnchor))
			local spots = Pockets.migrationSpots(pk, MARGIN)
			assert(#spots >= 20, id .. " has too few migration spots")
			for _, s in spots do
				assert(math.abs(s.x - anchor.pos.x) <= anchor.size.x / 2 - 2, id .. " spot near a wall")
				assert(math.abs(s.z - anchor.pos.z) <= anchor.size.z / 2 - 2, id .. " spot near a wall")
				for _, other in WorldDefs.Pockets do
					eq(Pockets.inBounds(other, s, MARGIN), false, id .. " spot blocks " .. other.id)
				end
			end
			eq(Pockets.migrationSpot(pk, 3, MARGIN).x, Pockets.migrationSpot(pk, 3, MARGIN).x, "deterministic")
		end
	end)

	test("the owner's notice names the region and the anchor honestly", function()
		local region, anchor = Pockets.noticeNames(def("PK1"))
		eq(
			Pockets.migrationNotice({ "chalk" }, region, anchor),
			"Your chalk mark in the Shifting Crossroads moved to the South Survey Anchor — the passage changed."
		)
		eq(
			Pockets.migrationNotice({ "rope", "chalk", "sign" }, region, anchor),
			"Your rope (now coiled) and 2 other items in the Shifting Crossroads moved to the South Survey Anchor"
				.. " — the passage changed."
		)
	end)

	test("route ids are presets, never free text", function()
		eq(NavRecords.isRouteId("A"), true)
		eq(NavRecords.isRouteId("anything I type"), false)
		eq(NavRecords.isRouteId(3), false)
	end)

	test("the legacy anchor-map migration no longer re-versions records it does not move", function()
		local st = NavRecords.newStore()
		local function put(anchorId: string)
			return assert(NavRecords.place(st, {
				ownerId = 1,
				kind = "chalk",
				itemId = "nav.chalk",
				regionId = "R05",
				pocketVersion = 1,
				anchorId = anchorId,
				position = { x = 0, y = 0, z = 0 },
				facing = { x = 0, y = 1, z = 0 },
				content = "x",
				units = 1,
			}, 400))
		end
		local a, b = put("R05.south_anchor"), put("R05.east_anchor")
		eq(
			NavRecords.migratePocket(
				st,
				"R05",
				1,
				2,
				{ ["R05.south_anchor"] = { anchorId = "X", position = a.position } }
			),
			1
		)
		eq(b.pocketVersion, 1, "unmapped record keeps its version")
		eq(a.pocketVersion, 2)
	end)

	print("Discovery and scavenging fixes (sections 08, 14)")

	test("searching needs a live, free, nearby player outside a shelter", function()
		local ok = { alive = true, downed = false, carried = false, hidden = false, inShelter = false, distance = 4 }
		eq((Discovery.canSearch(ok, 10)), true)
		for field, reason in
			{ alive = "dead", downed = "downed", carried = "carried", hidden = "hidden", inShelter = "in_shelter" }
		do
			local s = table.clone(ok) :: any
			s[field] = field ~= "alive"
			local allowed, why = Discovery.canSearch(s, 10)
			eq(allowed, false, field)
			eq(why, reason)
		end
		local far = table.clone(ok)
		far.distance = 30
		eq(select(2, Discovery.canSearch(far, 10)), "too_far")
		far.distance = nil
		eq(select(2, Discovery.canSearch(far, 10)), "too_far")
	end)

	test("a full inventory neither consumes the site nor starts its cooldown", function()
		local res = Discovery.search({ ["tool.flare"] = 1 }, {}, 100, 900, function()
			return 0
		end)
		eq(res.outcome, "no_room")
		eq(res.state.readyAt, nil)
		eq(next(res.got), nil)
	end)

	test("what does not fit stays in the site for that player; the restock timer starts once", function()
		local room = { ["mat.plank"] = 1, ["nav.rope"] = 2 }
		local add = function(id: string, n: number): number
			local a = math.min(n, room[id] or 0)
			room[id] = (room[id] or 0) - a
			return a
		end
		local site = { ["mat.plank"] = 3, ["nav.rope"] = 2 }
		local r1 = Discovery.search(site, {}, 100, 900, add)
		eq(r1.outcome, "partial")
		eq(r1.got["mat.plank"], 1)
		eq(r1.got["nav.rope"], 2)
		eq(r1.state.readyAt, 1000)
		eq(assert(r1.state.remainder)["mat.plank"], 2)
		-- before the restock only the remainder is offered
		room["mat.plank"] = 5
		local r2 = Discovery.search(site, r1.state, 200, 900, add)
		eq(r2.outcome, "full")
		eq(r2.got["mat.plank"], 2)
		eq(r2.got["nav.rope"], nil)
		eq(r2.state.readyAt, 1000, "the remainder does not restart the timer")
		eq(r2.state.remainder, nil)
		eq(Discovery.search(site, r2.state, 300, 900, add).outcome, "cooldown")
		eq(Discovery.search(site, r2.state, 1000, 900, add).outcome, "partial", "restocked at readyAt")
	end)

	test("site state round-trips through the cooldown map without touching other keys", function()
		local cd: { [string]: number } = { M01 = 50, ["scav:other"] = 70 }
		Discovery.writeSite(cd, "R04.scav.hall_desk", { readyAt = 900, remainder = { ["tool.flare"] = 1 } })
		local st = Discovery.readSite(cd, "R04.scav.hall_desk")
		eq(st.readyAt, 900)
		eq(assert(st.remainder)["tool.flare"], 1)
		Discovery.writeSite(cd, "R04.scav.hall_desk", { readyAt = 950, remainder = nil })
		eq(Discovery.readSite(cd, "R04.scav.hall_desk").remainder, nil)
		eq(cd.M01, 50)
		eq(cd["scav:other"], 70)
	end)

	test("field experience pays for places, never for item-claim discoveries", function()
		local claims: { [string]: boolean } = {}
		for _, u in WorldDefs.UniquePickups do
			claims[u.discoveryId] = true
		end
		local isClaim = function(id: string): boolean
			return claims[id] == true
		end
		eq(Discovery.isPlaceDiscovery("R04.station_hall", isClaim), true)
		eq(Discovery.isPlaceDiscovery("R00.descent_ramp", isClaim), true)
		eq(Discovery.isPlaceDiscovery("R05.p06_verified", isClaim), true)
		eq(Discovery.isPlaceDiscovery("R01.found_survey_tag", isClaim), false)
		eq(Discovery.isPlaceDiscovery("shelter:S04.service_office", isClaim), false)
		eq(Discovery.isPlaceDiscovery("P01.solved", isClaim), false)
	end)
end
