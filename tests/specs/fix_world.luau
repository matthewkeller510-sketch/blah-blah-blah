--!strict
-- Review fixes, batch 3 (world, pockets, puzzles). Pure rules only: the pocket predicate the crash checkpoint uses,
-- lit flares as pocket blockers, and per-rectangle pocket discovery volumes. Mirrors of service code are marked;
-- none of this proves anything about Roblox replication, raycasts or rendering.

local WorldDefs = require("../../src/shared/Data/WorldDefs")
local Config = require("../../src/shared/Data/Config")
local Pockets = require("../../src/shared/Logic/Pockets")

Pockets.bind(WorldDefs)

type V3 = { x: number, y: number, z: number }
type Box = { x0: number, z0: number, x1: number, z1: number }

local MARGIN = Config.Pockets.occupancyMargin

local function def(id: string): any
	return assert(WorldDefs.Pockets[id])
end

local function pocketIds(): { string }
	local ids = {}
	for id in WorldDefs.Pockets do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Walkable cells of one version as unit boxes (world x/z).
local function walkableCells(pk: any, version: string): { Box }
	local plan = Pockets.plan(pk, version)
	local g: any = Pockets.grid(plan.area, plan.walk, plan.lowWalk)
	local out: { Box } = {}
	for k = 0, g.nz - 1 do
		for i = 0, g.nx - 1 do
			if Pockets.isWalkable(g.cells[k * g.nx + i + 1]) then
				local x, z = g.x0 + i, g.z0 + k
				table.insert(out, { x0 = x, z0 = z, x1 = x + 1, z1 = z + 1 })
			end
		end
	end
	return out
end

-- Mirror of WorldBuilder.buildPocket: one discovery volume per walkable rectangle, clipped to the build area.
local function discoveryVolumes(pk: any, version: string): { Box }
	local plan = Pockets.plan(pk, version)
	local a = plan.area.box
	local out: { Box } = {}
	for _, wb in plan.walk do
		local x0, x1 = math.max(wb.x0, a.x0), math.min(wb.x1, a.x1)
		local z0, z1 = math.max(wb.z0, a.z0), math.min(wb.z1, a.z1)
		if x1 > x0 and z1 > z0 then
			table.insert(out, { x0 = x0, z0 = z0, x1 = x1, z1 = z1 })
		end
	end
	return out
end

-- Closed-box overlap grown by `slack` (DiscoveryService tests volumes inclusively, with no XZ slack).
local function touches(a: Box, b: Box, slack: number): boolean
	return a.x0 - slack <= b.x1 and b.x0 <= a.x1 + slack and a.z0 - slack <= b.z1 and b.z0 <= a.z1 + slack
end

local function inside(b: Box, p: V3): boolean
	return p.x >= b.x0 and p.x <= b.x1 and p.z >= b.z0 and p.z <= b.z1
end

return function(T: any)
	local test, eq = T.test, T.eq

	print("Review fixes: world, pockets and puzzles")

	-- Findings 4, 6, 12 ----------------------------------------------------------------------------------
	local floorY = def("PK1").bounds.min.y

	test("the checkpoint's pocket is PK1 everywhere on PK1's floor, even where PK2's bounds overlap it", function()
		local cells = walkableCells(def("PK1"), "loop")
		local inPk2Bounds = 0
		for _, c in cells do
			local p = { x = (c.x0 + c.x1) / 2, y = floorY + 1, z = (c.z0 + c.z1) / 2 }
			if Pockets.inBounds(def("PK2"), p, 0) then
				inPk2Bounds += 1
			end
			eq((Pockets.containing(p) :: any).id, "PK1", string.format("PK1 floor at %g,%g", p.x, p.z))
		end
		-- fixture: the overlap is real (the loose bounds lookup could answer PK2 here, by table order)
		assert(inPk2Bounds > 0, "fixture: PK1 'loop' floor inside PK2's bounds")
		-- the finding's own point in the loop's side chamber
		local side = { x = 30, y = floorY + 1, z = 1178 }
		assert(Pockets.inBounds(def("PK2"), side, 0), "fixture: inside PK2's bounds")
		eq((Pockets.containing(side) :: any).id, "PK1")
	end)

	test("a checkpoint in a mouth doorway (static wall band) is static, like a record there", function()
		-- PK1's doorway into center_anchor, and both PK3 mouth bands
		local pk3 = def("PK3")
		local area3 = Pockets.area(pk3)
		local points: { V3 } = {
			{ x = 6, y = floorY + 1, z = 1195 },
			{ x = 6, y = floorY + 1, z = 1135 },
			{ x = 6, y = floorY + 1, z = area3.start - 1 },
			{ x = 6, y = floorY + 1, z = area3.start + area3.length + 1 },
		}
		for _, p in points do
			assert(WorldDefs.pocketAt(p) ~= nil, "fixture: the loose bounds include " .. p.z)
			eq(Pockets.containing(p), nil, "doorway at z " .. p.z)
		end
	end)

	test("checkpoint tagging (PocketService.pocketAt + versionOf) equals record tagging across R05", function()
		local versions = { PK1 = "loop", PK2 = "dogleg", PK3 = "middle" }
		local versionOf = function(id: string): string?
			return (versions :: any)[id]
		end
		-- Mirror of PlayerService.checkpointFor with PocketService.pocketAt = Pockets.containing.
		local function checkpointTag(p: V3): (string?, any)
			local pk = Pockets.containing(p)
			local id = if pk then pk.id else nil
			if id then
				local v = versionOf(id)
				if v ~= nil then
					return id, v
				end
			end
			return nil, 1
		end
		local n = 0
		for x = -40, 100, 2 do
			for z = 1100, 1400, 2 do
				local p = { x = x + 0.5, y = floorY + 1, z = z + 0.5 }
				local id1, v1 = checkpointTag(p)
				local id2, v2 = Pockets.tagFor({ p }, versionOf)
				eq(id1, id2, string.format("pocket at %g,%g", p.x, p.z))
				eq(v1, v2, string.format("version at %g,%g", p.x, p.z))
				if id1 then
					n += 1
				end
			end
		end
		assert(n > 100, "fixture: the sweep crosses the pockets")
	end)

	-- Finding 14 ------------------------------------------------------------------------------------------
	test("a lit flare inside bounds plus margin blocks a pocket change; beyond the margin it does not", function()
		local pk = def("PK1")
		local area = Pockets.area(pk)
		-- PK1 'direct' floor at u 0, v 20 is unbuilt void in 'loop': the finding's flare spot
		local spot = Pockets.toWorld(area, 0, 20, area.floorY)
		local onDirect, onLoop = false, false
		for _, c in walkableCells(pk, "direct") do
			onDirect = onDirect or inside(c, spot)
		end
		for _, c in walkableCells(pk, "loop") do
			onLoop = onLoop or inside(c, spot)
		end
		assert(onDirect and not onLoop, "fixture: the spot is floor in 'direct' and void in 'loop'")
		eq(Pockets.blocker(pk, { flares = { spot } }, MARGIN), "flare")
		local edge = { x = pk.bounds.max.x + MARGIN - 0.5, y = area.floorY, z = spot.z }
		eq(Pockets.blocker(pk, { flares = { edge } }, MARGIN), "flare", "inside the margin")
		local beyond = { x = pk.bounds.max.x + MARGIN + 0.5, y = area.floorY, z = spot.z }
		eq(Pockets.blocker(pk, { flares = { beyond } }, MARGIN), nil, "beyond the margin")
		eq(Pockets.blocker(pk, { flares = {} }, MARGIN), nil, "no flares")
		-- a flare in one pocket never blocks another
		eq(Pockets.blocker(def("PK3"), { flares = { spot } }, MARGIN), nil, "PK3")
		-- existing reasons keep their priority
		eq(Pockets.blocker(pk, { characters = { spot }, flares = { spot } }, MARGIN), "player")
	end)

	-- Finding 11 ------------------------------------------------------------------------------------------
	test("fixture: one area-sized volume for PK2 would cover PK1 'loop' floor", function()
		local a = Pockets.area(def("PK2")).box
		local covered = 0
		for _, c in walkableCells(def("PK1"), "loop") do
			if c.x0 >= a.x0 and c.x1 <= a.x1 and c.z0 >= a.z0 and c.z1 <= a.z1 then
				covered += 1
			end
		end
		assert(covered > 0, "the old volume covered no PK1 floor; the overlap fixture changed")
	end)

	test("pocket discovery volumes cover their own floor and never another pocket's walkable floor", function()
		for _, id in pocketIds() do
			local pk = def(id)
			for _, version in pk.versions do
				local vols = discoveryVolumes(pk, version)
				assert(#vols > 0, id .. " " .. version .. " has no volume")
				-- every walkable cell of this version is discoverable
				for _, c in walkableCells(pk, version) do
					local mid = { x = (c.x0 + c.x1) / 2, y = 0, z = (c.z0 + c.z1) / 2 }
					local found = false
					for _, vb in vols do
						if inside(vb, mid) then
							found = true
							break
						end
					end
					assert(found, string.format("%s %s floor at %g,%g has no volume", id, version, mid.x, mid.z))
				end
				-- no volume reaches within a stud of another pocket's walkable floor, in any of its versions
				for _, otherId in pocketIds() do
					if otherId ~= id then
						local other = def(otherId)
						for _, ov in other.versions do
							for _, c in walkableCells(other, ov) do
								for _, vb in vols do
									assert(
										not touches(vb, c, 1),
										string.format(
											"%s %s volume covers %s %s floor at %g,%g",
											id,
											version,
											otherId,
											ov,
											c.x0,
											c.z0
										)
									)
								end
							end
						end
					end
				end
			end
		end
	end)
end
