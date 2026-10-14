--!strict
-- Milestone 3 data contract (docs/MILESTONE-3.md): geometry consistency of the new regions, pockets and spots.
-- These checks guard the shared data every package builds on. They do not prove anything renders in Roblox.

local WorldDefs = require("../../src/shared/Data/WorldDefs")
local ItemDefs = require("../../src/shared/Data/ItemDefs")
local CueDefs = require("../../src/shared/Data/CueDefs")
local Config = require("../../src/shared/Data/Config")
local Profile = require("../../src/shared/Logic/Profile")
local Pockets = require("../../src/shared/Logic/Pockets")

type V3 = { x: number, y: number, z: number }

local W = WorldDefs.CORRIDOR_WIDTH
local WALL = 2

local function chamber(id: string): any
	local c = WorldDefs.chamber(id)
	assert(c, "unknown chamber " .. id)
	return c
end

local function inside(c: any, p: V3, slack: number?): boolean
	local s = slack or 0
	return math.abs(p.x - c.pos.x) <= c.size.x / 2 + s
		and math.abs(p.z - c.pos.z) <= c.size.z / 2 + s
		and p.y >= c.pos.y - 1
		and p.y <= c.pos.y + c.size.y
end

-- Axis-aligned box of a chamber including its walls, as min/max.
local function box(c: any)
	return {
		min = { x = c.pos.x - c.size.x / 2 - WALL, y = c.pos.y - 1, z = c.pos.z - c.size.z / 2 - WALL },
		max = { x = c.pos.x + c.size.x / 2 + WALL, y = c.pos.y + c.size.y + 2, z = c.pos.z + c.size.z / 2 + WALL },
	}
end

local function overlaps(a: any, b: any): boolean
	return a.min.x < b.max.x
		and a.max.x > b.min.x
		and a.min.y < b.max.y
		and a.max.y > b.min.y
		and a.min.z < b.max.z
		and a.max.z > b.min.z
end

-- Box swept by a straight (same-height) corridor between the two chambers' outer wall faces.
local function corridorBox(a: any, b: any)
	local alongZ = a.pos.x == b.pos.x
	local lo, hi = a, b
	if (alongZ and a.pos.z > b.pos.z) or (not alongZ and a.pos.x > b.pos.x) then
		lo, hi = b, a
	end
	local y0 = math.min(a.pos.y, b.pos.y) - 1
	local y1 = math.max(a.pos.y, b.pos.y) + WorldDefs.CORRIDOR_HEIGHT + 2
	if alongZ then
		return {
			min = { x = a.pos.x - W / 2 - WALL, y = y0, z = lo.pos.z + lo.size.z / 2 + WALL },
			max = { x = a.pos.x + W / 2 + WALL, y = y1, z = hi.pos.z - hi.size.z / 2 - WALL },
		}
	end
	return {
		min = { x = lo.pos.x + lo.size.x / 2 + WALL, y = y0, z = a.pos.z - W / 2 - WALL },
		max = { x = hi.pos.x - hi.size.x / 2 - WALL, y = y1, z = a.pos.z + W / 2 + WALL },
	}
end

local function side(c: any, other: any): string
	if other.pos.x == c.pos.x then
		return if other.pos.z > c.pos.z then "N" else "S"
	end
	return if other.pos.x > c.pos.x then "E" else "W"
end

return function(T: any)
	local test, eq = T.test, T.eq

	print("Milestone 3 data contract")

	test("schema 2 adds progression and migrates a version-1 profile without loss", function()
		eq(Profile.CURRENT_VERSION, 2)
		eq(Config.SCHEMA_VERSION, 2)
		local v1 = Profile.default(7, "Explorer", "R00.depot") :: any
		v1.schemaVersion = 1
		v1.progression = nil
		v1.coins = 33
		local p = assert(Profile.reconcile(v1, 7, "Explorer", "R00.depot"))
		eq(p.schemaVersion, 2)
		eq(p.coins, 33)
		eq(p.progression.xp, 0)
		assert(type(p.progression.awarded) == "table")
	end)

	test("onboarding back-fill: played legacy profiles only; abandoned new players keep the free choice", function()
		local played = assert(Profile.reconcile({
			schemaVersion = 1,
			class = "Explorer",
			inventory = {},
			storyStates = {},
			discoveries = { ["R01.split_pier"] = true },
		}, 1, "Explorer", "R00.depot"))
		eq(played.storyStates.onboarded, "1", "legacy profile that explored")
		local abandoned = assert(Profile.reconcile({
			schemaVersion = 1,
			class = "Explorer",
			coins = 0,
			inventory = {},
			storyStates = {},
			discoveries = { ["R00.mission_board"] = true },
		}, 2, "Explorer", "R00.depot"))
		eq(abandoned.storyStates.onboarded, nil, "new player who left before choosing")
		local v2 = assert(Profile.reconcile({
			schemaVersion = 2,
			class = "Medic",
			coins = 50,
			inventory = {},
			storyStates = {},
		}, 3, "Explorer", "R00.depot"))
		eq(v2.storyStates.onboarded, nil, "schema 2 never back-fills")
	end)

	test("every chamber is tall enough for a lintel and each open side can hold a doorway", function()
		for _, c in WorldDefs.Chambers do
			assert(c.size.y >= 12, c.id .. " is lower than 12")
			assert(c.size.x > W and c.size.z > W, c.id .. " is too narrow for a doorway")
		end
	end)

	test("each chamber side has at most one corridor and no corridor uses a shelter door side", function()
		local used: { [string]: string } = {}
		local doorSides: { [string]: string } = {}
		for _, sh in WorldDefs.Shelters do
			doorSides[sh.exteriorChamberId] = sh.doorSide
		end
		for _, cor in WorldDefs.Corridors do
			local a, b = chamber(cor.from), chamber(cor.to)
			for _, pair in { { a, b }, { b, a } } do
				local key = pair[1].id .. ":" .. side(pair[1], pair[2])
				assert(used[key] == nil, "two corridors on " .. key)
				used[key] = cor.from .. "->" .. cor.to
				assert(doorSides[pair[1].id] ~= side(pair[1], pair[2]), "corridor on shelter door side " .. key)
			end
		end
	end)

	test("no two chambers overlap", function()
		local cs = WorldDefs.Chambers
		for i = 1, #cs do
			for j = i + 1, #cs do
				assert(not overlaps(box(cs[i]), box(cs[j])), cs[i].id .. " overlaps " .. cs[j].id)
			end
		end
	end)

	test("straight corridors do not cut through a third chamber", function()
		for _, cor in WorldDefs.Corridors do
			local a, b = chamber(cor.from), chamber(cor.to)
			if a.pos.y == b.pos.y and cor.pocket == nil then
				local cb = corridorBox(a, b)
				for _, c in WorldDefs.Chambers do
					if c.id ~= a.id and c.id ~= b.id then
						assert(not overlaps(cb, box(c)), cor.from .. "->" .. cor.to .. " cuts through " .. c.id)
					end
				end
			end
		end
	end)

	test("sloped galleries stay gentle (rise over run at most 0.35)", function()
		for _, cor in WorldDefs.Corridors do
			local a, b = chamber(cor.from), chamber(cor.to)
			if a.pos.y ~= b.pos.y then
				local alongZ = a.pos.x == b.pos.x
				local run = if alongZ
					then math.abs(a.pos.z - b.pos.z) - a.size.z / 2 - b.size.z / 2 - 2 * WALL
					else math.abs(a.pos.x - b.pos.x) - a.size.x / 2 - b.size.x / 2 - 2 * WALL
				assert(math.abs(a.pos.y - b.pos.y) / run <= 0.35, cor.from .. "->" .. cor.to .. " is too steep")
			end
		end
	end)

	test("pockets: mouths and migration anchors are static chambers; every pocket has one corridor", function()
		local seen: { [string]: number } = {}
		for _, cor in WorldDefs.Corridors do
			if cor.pocket then
				local pk = WorldDefs.Pockets[cor.pocket]
				assert(pk, "corridor names unknown pocket " .. cor.pocket)
				eq(cor.from, pk.from, cor.pocket .. " from")
				eq(cor.to, pk.to, cor.pocket .. " to")
				seen[cor.pocket] = (seen[cor.pocket] or 0) + 1
			end
		end
		for id, pk in WorldDefs.Pockets do
			eq(pk.id, id)
			eq(seen[id], 1, id .. " corridor count")
			chamber(pk.from)
			chamber(pk.to)
			eq(chamber(pk.migrationAnchor).regionId, pk.regionId, id .. " migration anchor region")
			assert(#pk.versions >= 2, id .. " needs at least two versions")
			if pk.puzzle then
				eq(WorldDefs.Puzzles[pk.puzzle].pocketId, id)
				eq(#assert(pk.doors), #pk.versions, id .. " doors per version")
			end
		end
	end)

	test("pocket bounds never overlap a static chamber or a stable corridor", function()
		for id, pk in WorldDefs.Pockets do
			local b = { min = pk.bounds.min, max = pk.bounds.max }
			for _, c in WorldDefs.Chambers do
				local cb = box(c)
				-- the mouth chambers may touch the bounds at their wall face, not intrude past it
				local shrunk = {
					min = { x = cb.min.x + WALL, y = cb.min.y, z = cb.min.z + WALL },
					max = { x = cb.max.x - WALL, y = cb.max.y, z = cb.max.z - WALL },
				}
				assert(not overlaps(b, shrunk), id .. " bounds overlap " .. c.id)
			end
			for _, cor in WorldDefs.Corridors do
				local a, c = chamber(cor.from), chamber(cor.to)
				if cor.pocket == nil and a.pos.y == c.pos.y then
					assert(not overlaps(b, corridorBox(a, c)), id .. " bounds overlap " .. cor.from .. "->" .. cor.to)
				end
			end
		end
	end)

	test("pocketAt finds a point inside each pocket and nothing in a static chamber", function()
		for id, pk in WorldDefs.Pockets do
			local mid = {
				x = (pk.bounds.min.x + pk.bounds.max.x) / 2,
				y = pk.bounds.min.y + 1,
				z = (pk.bounds.min.z + pk.bounds.max.z) / 2,
			}
			eq((WorldDefs.pocketAt(mid) :: any).id, id)
		end
		for _, c in WorldDefs.Chambers do
			eq(WorldDefs.pocketAt({ x = c.pos.x, y = c.pos.y + 1, z = c.pos.z }), nil, c.id)
		end
	end)

	test("mission spots, readables and puzzle props sit inside their chambers", function()
		for tmpl, spots in WorldDefs.MissionSpots do
			for _, sp in spots do
				assert(inside(chamber(sp.chamberId), sp.pos), tmpl .. " " .. sp.id)
				eq(WorldDefs.pocketAt(sp.pos), nil, sp.id .. " is inside a pocket")
			end
		end
		for _, r in WorldDefs.Readables do
			assert(inside(chamber(r.chamberId), r.pos, 1), r.id)
		end
		local P = WorldDefs.Puzzles
		for _, bx in P.P03.boxes do
			assert(inside(chamber(P.P03.chamberId), bx.pos, 1), "P03 box " .. bx.label)
		end
		assert(inside(chamber(P.P03.chamberId), P.P03.plate, 1), "P03 plate")
		for _, k in { "stonePile", "basket", "latch" } do
			assert(inside(chamber(P.P04.chamberId), P.P04[k]), "P04 " .. k)
		end
		assert(inside(chamber("R01.pulley_store"), P.P04.innerLever), "P04 inner lever")
		assert(inside(chamber(P.P05.chamberId), P.P05.radio), "P05 radio")
		assert(inside(chamber(P.P06.chamberId), P.P06.observationStep), "P06 observation step")
		for i, wpos in P.W05.wheels do
			assert(inside(chamber(P.W05.chamberId), wpos, 1), "W05 wheel " .. i)
		end
		assert(inside(chamber("R03.pump_gallery"), P.W05.clues[1].pos, 1), "W05 clue 1")
		assert(inside(chamber("R03.drain_gallery"), P.W05.clues[2].pos, 1), "W05 clue 2")
		for _, seq in P.P05.sequences do
			assert(string.match(seq, "^[SL]+$") and #seq == 4, "P05 sequence " .. seq)
		end
		for _, o in P.W05.orders do
			assert(#o == #P.W05.wheels, "W05 order " .. o)
		end
		assert(inside(chamber("R03.silt_loop"), assert(WorldDefs.Characters.N06.rescuePos)), "Noah rescue position")
	end)

	test("hiding spots and scavenging sites are never inside a variable pocket", function()
		for _, h in WorldDefs.HidingSpots do
			eq(WorldDefs.pocketAt(h.pos), nil, h.id)
		end
		for _, sc in WorldDefs.ScavengeSites do
			eq(WorldDefs.pocketAt(sc.pos), nil, sc.id)
		end
	end)

	test("rescue spawns and mission spots stay clear of every pocket's bounds plus occupancy margin", function()
		-- A survivor or worker waiting there is a PocketBlocker pivoted 3 studs above its spot (MissionService
		-- buildRig): inside a pocket's blocking box it would freeze that pocket for the whole mission.
		local margin = Config.Pockets.occupancyMargin
		local spots: { { id: string, pos: V3 } } = {}
		for _, sp in WorldDefs.RescueSpawns do
			table.insert(spots, sp)
		end
		for _, list in WorldDefs.MissionSpots do
			for _, sp in list do
				table.insert(spots, sp)
			end
		end
		assert(#spots > 0, "fixture: no spots")
		for _, sp in spots do
			local rig = { x = sp.pos.x, y = sp.pos.y + 3, z = sp.pos.z }
			for id, pk in WorldDefs.Pockets do
				eq(Pockets.inBounds(pk, rig, margin), false, sp.id .. " blocks " .. id)
			end
		end
	end)

	test("unique pickups name real unique items; story evidence is protected", function()
		for _, u in WorldDefs.UniquePickups do
			local d = ItemDefs.get(u.itemId)
			assert(d, u.id .. " names unknown item " .. u.itemId)
			assert(d.unique, u.itemId .. " is not unique")
		end
		for _, id in { "evidence.waterworks_log", "evidence.station_tape", "treasure.old_expedition_tag" } do
			assert(ItemDefs.isProtected(id), id .. " must be protected")
		end
	end)

	test("shelters have at most two entrances and every entrance names a safety upgrade", function()
		for id, sh in WorldDefs.Shelters do
			assert(#sh.entrances <= 2, id .. " has more than two entrances")
			for _, e in sh.entrances do
				local u = sh.safetyUpgrades[e.requiredUpgrade]
				assert(u, id .. " entrance " .. e.id .. " has no safety upgrade")
				assert(e.requiredStage <= u.maxStage, id .. " entrance stage above max")
			end
		end
	end)

	test("every Milestone 3 item has an organic source in the world", function()
		local found: { [string]: boolean } = {}
		for _, sc in WorldDefs.ScavengeSites do
			for item in sc.contents do
				found[item] = true
			end
		end
		for _, u in WorldDefs.UniquePickups do
			found[u.itemId] = true
		end
		found["evidence.station_tape"] = true -- granted by P05 with station power on (story)
		for _, id in
			{
				"light.shielded_lantern",
				"tool.flare",
				"med.splint",
				"tool.repair_roll",
				"tool.fuse_kit",
				"mat.fuse_component",
				"mat.battery_housing",
				"treasure.field_photograph",
				"treasure.dated_battery",
			}
		do
			assert(ItemDefs.get(id), "missing item " .. id)
			assert(found[id], id .. " has no organic source")
		end
	end)

	test("essential cues have captions", function()
		for id, cue in CueDefs do
			assert(#cue.text > 4, id)
		end
		for _, id in { "pocket_shift", "thief_rattle", "thief_strike", "power_restored", "sluice_gate", "grate_drop" } do
			assert(CueDefs[id] and CueDefs[id].essential, id .. " must be an essential cue")
		end
	end)
end
