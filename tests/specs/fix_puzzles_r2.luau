--!strict
-- Review fixes, round 2, batch 6 (puzzles and shelters). Pure rules only: the P04 latch and lever rules that stop a
-- solo player skipping the counterweight, and the shelter arrival spot kept clear of the probe at every entrance.
-- Mirrors of service geometry are marked. None of this proves anything about Roblox prompts, welds, streaming or
-- physics; the service-side guards are listed in the batch report.

local Puzzles = require("../../src/shared/Logic/Puzzles")
local Shelters = require("../../src/shared/Logic/Shelters")
local WorldDefs = require("../../src/shared/Data/WorldDefs")

local function dist(a: { x: number, y: number, z: number }, b: { x: number, y: number, z: number }): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return function(T)
	local test, eq = T.test, T.eq

	print("R2-3 P04: the stones cannot be skipped alone")
	test("a lever raise with an empty basket cannot be latched", function()
		local s = Puzzles.newP04(3)
		eq(Puzzles.leverHold(s), true)
		eq(Puzzles.toggleLatch(s, 1, 300), "not_raised", "the holder cannot latch their own lever raise")
		eq(s.latched, false)
		Puzzles.leverRelease(s)
		eq(Puzzles.p04ShouldDrop(s, 1, false), true, "drops as soon as nobody holds it and the area is empty")
	end)
	test("letting go of the lever gives no slip time to walk through", function()
		local s = Puzzles.newP04(3)
		Puzzles.leverHold(s)
		Puzzles.leverRelease(s)
		eq(s.holdUntil, 0)
		eq(Puzzles.p04ShouldDrop(s, 0, false), true)
	end)
	test("a partial basket cannot be latched, even while something else holds the grate up", function()
		local s = Puzzles.newP04(3)
		Puzzles.loadStone(s, 0, 15)
		Puzzles.loadStone(s, 0, 15)
		Puzzles.innerLever(s, 0, 300)
		eq(s.raised, true)
		eq(Puzzles.toggleLatch(s, 1, 300), "not_raised", "2 of 3 stones")
		Puzzles.leverHold(s)
		eq(Puzzles.toggleLatch(s, 2, 300), "not_raised", "2 of 3 stones with the lever held")
	end)
	test("the solo route still works: a full basket raises, slips after 15 s, and latches", function()
		local s = Puzzles.newP04(3)
		for _ = 1, 3 do
			Puzzles.loadStone(s, 0, 15)
		end
		eq(Puzzles.p04ShouldDrop(s, 14, false), false, "a full basket alone holds it 15 s (D64)")
		eq(Puzzles.toggleLatch(s, 5, 300), "latched")
		eq(Puzzles.p04ShouldDrop(s, 1e9, false), false, "latched holds")
		eq(Puzzles.toggleLatch(s, 100, 300), "unlatched", "releasing the latch is unchanged")
		eq(Puzzles.p04ShouldDrop(s, 399, false), false)
		eq(Puzzles.p04ShouldDrop(s, 400, false), true)
	end)
	test("a full basket keeps its own slip time when a lever holder lets go", function()
		local s = Puzzles.newP04(3)
		for _ = 1, 3 do
			Puzzles.loadStone(s, 0, 15)
		end
		Puzzles.leverHold(s)
		Puzzles.leverRelease(s)
		eq(Puzzles.p04ShouldDrop(s, 10, false), false)
		eq(Puzzles.p04ShouldDrop(s, 15, false), true)
	end)
	test("a full basket loaded during a lever hold can be latched", function()
		local s = Puzzles.newP04(3)
		Puzzles.leverHold(s)
		for _ = 1, 3 do
			Puzzles.loadStone(s, 0, 15)
		end
		eq(Puzzles.toggleLatch(s, 1, 300), "latched")
		Puzzles.leverRelease(s)
		eq(Puzzles.p04ShouldDrop(s, 1e9, false), false)
	end)
	test("why the lever needs a partner: the latch post is in prompt reach of the no-drop area (mirror)", function()
		-- Mirror of PuzzleService.buildP04: p04Boxes and the latch handle (latch + (0, 3.2, -0.6)), prompt reach 8.
		local P04 = WorldDefs.Puzzles.P04
		local room = assert(WorldDefs.chamber("R01.rusted_pulley"))
		local store = assert(WorldDefs.chamber("R01.pulley_store"))
		local W, H = WorldDefs.CORRIDOR_WIDTH, WorldDefs.CORRIDOR_HEIGHT
		local area = { Puzzles.corridorBox(room, store, W, H, 1, 4), Puzzles.chamberBox(store, 1) }
		local handle = { x = P04.latch.x, y = P04.latch.y + 3.2, z = P04.latch.z - 0.6 }
		local stand = { x = area[1].max.x - 0.5, y = room.pos.y + 3, z = handle.z }
		assert(Puzzles.inAnyBox(area, stand.x, stand.y, stand.z), "a holder can stand in the no-drop area")
		assert(dist(stand, handle) < 8, "and still reach the lever prompt")
		-- the cross area (room + p04Boxes) covers wherever a partner would cross from
		local cross = { Puzzles.chamberBox(room, 1), area[1], area[2] }
		for _, p in
			{
				{ x = room.pos.x, y = room.pos.y + 3, z = room.pos.z },
				{ x = P04.grate.x, y = P04.grate.y + 3, z = P04.grate.z },
				{ x = store.pos.x, y = store.pos.y + 3, z = store.pos.z },
				{ x = P04.stonePile.x, y = P04.stonePile.y + 3, z = P04.stonePile.z },
			}
		do
			assert(Puzzles.inAnyBox(cross, p.x, p.y, p.z), string.format("cross area at %d,%d", p.x, p.z))
		end
	end)

	print("R2-6 shelter arrival spot and the probe")
	test("slot offsets match the interior entrance frames", function()
		local w = Shelters.slotOffset(Shelters.ENTRANCE_SLOTS[1])
		eq(w.x, -Shelters.ROOM.x / 2 + 0.5)
		eq(w.y, 4.5)
		eq(w.z, 0)
		local n = Shelters.slotOffset({ wall = "N", along = 6, width = 4, y = 4 })
		eq(n.x, 6)
		eq(n.z, Shelters.ROOM.z / 2 - 0.5)
		local s = Shelters.slotOffset({ wall = "S", along = 5.5, width = 4, y = 4 })
		eq(s.z, -Shelters.ROOM.z / 2 + 0.5)
		local e = Shelters.slotOffset({ wall = "E", along = 2, width = 4, y = 4 })
		eq(e.x, Shelters.ROOM.x / 2 - 0.5)
		eq(e.z, 2)
	end)
	test("the old arrival spot was inside the probe radius of entrance 1 (the bug)", function()
		local old = { x = -Shelters.ROOM.x / 2 + 5, y = 3, z = 0 }
		assert(dist(old, Shelters.slotOffset(Shelters.ENTRANCE_SLOTS[1])) < Shelters.PROBE_RADIUS, "regression premise")
	end)
	test("arriving or respawning never puts anyone in reach of any entrance probe", function()
		local a = Shelters.ARRIVAL
		for i, slot in Shelters.ENTRANCE_SLOTS do
			local d = dist(a, Shelters.slotOffset(slot))
			assert(d > Shelters.PROBE_RADIUS + 3, string.format("slot %d is %.2f studs from the arrival spot", i, d))
		end
		-- inside the room, clear of the walls
		assert(math.abs(a.x) < Shelters.ROOM.x / 2 - 2 and math.abs(a.z) < Shelters.ROOM.z / 2 - 2, "inside the room")
		assert(a.y > 0 and a.y < Shelters.ROOM.y, "between floor and ceiling")
	end)
	test("every shelter's entrances sit in slots (so the probe aims only at slot offsets)", function()
		for id, def in WorldDefs.Shelters do
			assert(#def.entrances <= #Shelters.ENTRANCE_SLOTS, id)
		end
	end)
end
