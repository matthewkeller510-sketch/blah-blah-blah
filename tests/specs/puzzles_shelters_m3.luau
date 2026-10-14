--!strict
-- Package C (Milestone 3): puzzles P03, P04, P05, W05, the M04 private breaker and shelters S04/S05.
-- Pure rules only (Logic/Puzzles, Logic/Shelters) against the shared data. These tests do not prove anything about
-- Roblox replication, prompts, tweens or physics; see docs/TEST-PLAN.md for the Studio rows.

local Puzzles = require("../../src/shared/Logic/Puzzles")
local Shelters = require("../../src/shared/Logic/Shelters")
local Inventory = require("../../src/shared/Logic/Inventory")
local WorldDefs = require("../../src/shared/Data/WorldDefs")
local ItemDefs = require("../../src/shared/Data/ItemDefs")
local Config = require("../../src/shared/Data/Config")
local CueDefs = require("../../src/shared/Data/CueDefs")

return function(T)
	local test, eq = T.test, T.eq

	local function chamber(id: string): any
		return assert(WorldDefs.chamber(id), "unknown chamber " .. id)
	end

	local function sameOrder(a: { number }, b: { number }): boolean
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	print("P03 fuse bridge and M04 breaker layouts")
	test("there are at least three authored layouts and every one is structurally valid", function()
		assert(#Puzzles.P03_LAYOUTS >= 3, "need >= 3 layouts")
		for i, layout in Puzzles.P03_LAYOUTS do
			local ok, why = Puzzles.validLayout(layout)
			assert(ok, "layout " .. i .. ": " .. tostring(why))
		end
	end)
	test("exactly one box is burnt, never the naive guess, and the burnt box varies between layouts", function()
		local seen: { [string]: boolean } = {}
		for i, layout in Puzzles.P03_LAYOUTS do
			local burnt = Puzzles.burntBox(layout)
			local n = 0
			for _, b in Puzzles.FUSE_BOXES do
				if layout.wiring[b] == layout.dead then
					n += 1
				end
			end
			eq(n, 1, "boxes on the dead line in layout " .. i)
			assert(burnt ~= Puzzles.FUSE_BOXES[layout.dead], "layout " .. i .. " answer is the naive box")
			seen[burnt] = true
		end
		local kinds = 0
		for _ in seen do
			kinds += 1
		end
		assert(kinds >= 2, "every layout has the same burnt box")
	end)
	test("labels alone trace the dead line to the burnt box (plate -> terminal tag -> box tag)", function()
		for i, layout in Puzzles.P03_LAYOUTS do
			local plate = Puzzles.fuseDeadText(layout, "LINE")
			assert(string.find(plate, "LINE " .. layout.dead, 1, true), "plate names the dead line " .. i)
			local terminal = Puzzles.fuseTerminalText(layout, layout.dead, "LINE")
			local tag = assert(string.match(terminal, "conduit (%w+)$"), "terminal shows a conduit tag")
			local matches = {}
			for _, b in Puzzles.FUSE_BOXES do
				if string.find(Puzzles.fuseBoxText(layout, b, "BOX"), "conduit " .. tag, 1, true) then
					table.insert(matches, b)
				end
			end
			eq(#matches, 1, "boxes carrying tag " .. tag)
			eq(matches[1], Puzzles.burntBox(layout), "traced box in layout " .. i)
			-- the private wiring card carries the same trace
			local card = Puzzles.fuseCardText(layout, "CIRCUIT")
			assert(string.find(card, "CIRCUIT " .. layout.dead .. " — NO CURRENT", 1, true), card)
		end
	end)
	test("a wrong box costs time, returns the fuse and never consumes the roll", function()
		local s = Puzzles.newP03(1)
		local burnt = Puzzles.burntBox(Puzzles.P03_LAYOUTS[1])
		local inv = Inventory.new()
		Inventory.add(inv, ItemDefs.get, Puzzles.REPAIR_ROLL, 1, "loadout")
		Inventory.add(inv, ItemDefs.get, Puzzles.FUSE_KIT, 2, "expedition")
		for _, b in Puzzles.FUSE_BOXES do
			if b ~= burnt then
				local r = Puzzles.insertFuse(s, b, 1, 2, Config.Puzzles.fuseWrongBoxSeconds, 10)
				eq(r.outcome, "wrong")
				eq(r.fusesConsumed, 0, "fuse returned")
				eq(r.rollsConsumed, 0, "roll kept")
				eq(r.delaySeconds, Config.Puzzles.fuseWrongBoxSeconds, "time cost")
				assert(Inventory.remove(inv, Puzzles.FUSE_KIT, r.fusesConsumed))
			end
		end
		eq(s.powered, false)
		eq(Inventory.count(inv, Puzzles.FUSE_KIT), 2, "no fuse lost to wrong boxes")
		eq(Inventory.count(inv, Puzzles.REPAIR_ROLL), 1)
		assert(Config.Puzzles.fuseWrongBoxSeconds > 0, "a wrong box must cost some time")
	end)
	test("the right box consumes exactly one fuse, keeps the roll and powers the line once", function()
		for idx, layout in Puzzles.P03_LAYOUTS do
			local s = Puzzles.newP03(idx)
			local r = Puzzles.insertFuse(s, Puzzles.burntBox(layout), 1, 3, 4, 42)
			eq(r.outcome, "powered")
			eq(r.fusesConsumed, 1)
			eq(r.rollsConsumed, 0)
			eq(r.delaySeconds, 0)
			eq(s.powered, true)
			eq(s.poweredAt, 42)
			local again = Puzzles.insertFuse(s, Puzzles.burntBox(layout), 1, 2, 4, 50)
			eq(again.outcome, "already")
			eq(again.fusesConsumed, 0, "a second fuse is never taken")
		end
	end)
	test("the repair roll and a fuse kit are both required, even at the right box", function()
		local layout = Puzzles.P03_LAYOUTS[2]
		local s = Puzzles.newP03(2)
		local noRoll = Puzzles.insertFuse(s, Puzzles.burntBox(layout), 0, 5, 4, 1)
		eq(noRoll.outcome, "missing")
		eq(noRoll.fusesConsumed, 0)
		eq(noRoll.missing[1], Puzzles.REPAIR_ROLL)
		local noFuse = Puzzles.insertFuse(s, Puzzles.burntBox(layout), 1, 0, 4, 1)
		eq(noFuse.outcome, "missing")
		eq(noFuse.missing[1], Puzzles.FUSE_KIT)
		eq(#Puzzles.fuseMissing(0, 0), 2)
		eq(#Puzzles.fuseMissing(1, 1), 0)
		eq(s.powered, false)
	end)
	test("the missing-tool notice names organic sources and never points at a store", function()
		for _, missing in { { Puzzles.REPAIR_ROLL }, { Puzzles.FUSE_KIT }, { Puzzles.REPAIR_ROLL, Puzzles.FUSE_KIT } } do
			local text = Puzzles.fuseMissingText(missing)
			assert(string.find(text, "generator locker", 1, true), text)
			local lower = string.lower(text)
			for _, bad in { "robux", "buy", "shop", "store prompt", "purchase" } do
				assert(not string.find(lower, bad, 1, true), "mentions " .. bad .. ": " .. text)
			end
		end
		assert(string.find(Puzzles.fuseMissingText({ Puzzles.REPAIR_ROLL }), "Battery Store", 1, true))
		-- the item ids the puzzle needs exist and the roll is reusable
		assert(ItemDefs.get(Puzzles.REPAIR_ROLL), "repair roll item")
		assert(ItemDefs.get(Puzzles.FUSE_KIT), "fuse kit item")
	end)
	test("power trips only after its time and only when the generator room is empty; the layout changes", function()
		local s = Puzzles.newP03(1)
		Puzzles.insertFuse(s, Puzzles.burntBox(Puzzles.P03_LAYOUTS[1]), 1, 1, 4, 100)
		local secs = Config.Puzzles.stationPowerSeconds
		eq(Puzzles.p03ShouldTrip(s, 100 + secs - 1, secs, false), false, "too early")
		eq(Puzzles.p03ShouldTrip(s, 100 + secs + 5, secs, true), false, "someone in the generator room")
		eq(Puzzles.p03ShouldTrip(s, 100 + secs + 5, secs, false), true)
		local nextIdx = Puzzles.nextLayout(s.layout, #Puzzles.P03_LAYOUTS, 2)
		Puzzles.tripP03(s, nextIdx)
		eq(s.powered, false)
		assert(s.layout ~= 1, "a trip picks a new layout")
		eq(Puzzles.p03ShouldTrip(s, 1e9, secs, false), false, "an unpowered line never trips")
	end)
	test("nextLayout never repeats the current layout and reaches every other one", function()
		local n = #Puzzles.P03_LAYOUTS
		for cur = 1, n do
			local reached: { [number]: boolean } = {}
			for roll = 1, n - 1 do
				local nx = Puzzles.nextLayout(cur, n, roll)
				assert(nx ~= cur and nx >= 1 and nx <= n, "bad next layout")
				reached[nx] = true
			end
			for other = 1, n do
				if other ~= cur then
					assert(reached[other], "layout " .. other .. " unreachable from " .. cur)
				end
			end
		end
		eq(Puzzles.nextLayout(1, 1, 5), 1)
	end)
	test("P03 data: three labelled boxes A, B, C; Technician fuse work is about 5% faster", function()
		local P03 = WorldDefs.Puzzles.P03
		eq(#P03.boxes, #Puzzles.FUSE_BOXES)
		for i, b in P03.boxes do
			eq(b.label, Puzzles.FUSE_BOXES[i])
		end
		eq(Config.Classes.Technician.repairTimeMultiplier, 0.95)
		assert(Config.Puzzles.fuseInsertSeconds > 0 and Config.Puzzles.stationPowerSeconds > 0)
	end)

	print("W05 sluice gates (sequence puzzle)")
	test("orders parse only as permutations", function()
		local o = assert(Puzzles.parseOrder("231", 3))
		assert(sameOrder(o, { 2, 3, 1 }))
		eq(Puzzles.parseOrder("221", 3), nil)
		eq(Puzzles.parseOrder("12", 3), nil)
		eq(Puzzles.parseOrder("124", 3), nil)
		eq(Puzzles.parseOrder("1a3", 3), nil)
	end)
	test("every authored order opens on the right sequence and counts n of 3", function()
		local W05 = WorldDefs.Puzzles.W05
		eq(#W05.wheels, 3)
		eq(#W05.clues, 2)
		for _, text in W05.orders do
			local s = Puzzles.newW05(text, #W05.wheels)
			for i, wheel in s.order do
				local result, n = Puzzles.turnWheel(s, wheel, 7)
				eq(n, i, "n of 3 after turn " .. i .. " of " .. text)
				eq(result, if i == #s.order then "open" else "progress")
			end
			eq(s.open, true)
			eq(s.openedAt, 7)
			local locked, n = Puzzles.turnWheel(s, s.order[1], 8)
			eq(locked, "locked", "an open sluice ignores further turns")
			eq(n, 3)
		end
	end)
	test("a wrong wheel resets the sequence to zero at any step", function()
		local s = Puzzles.newW05("231", 3)
		local r, n = Puzzles.turnWheel(s, 1, 0)
		eq(r, "reset")
		eq(n, 0)
		Puzzles.turnWheel(s, 2, 0)
		r, n = Puzzles.turnWheel(s, 2, 0) -- the same wheel twice is wrong too
		eq(r, "reset")
		eq(n, 0)
		eq(s.progress, 0)
		Puzzles.turnWheel(s, 2, 0)
		Puzzles.turnWheel(s, 3, 0)
		r, n = Puzzles.turnWheel(s, 2, 0)
		eq(r, "reset", "wrong third wheel")
		eq(s.open, false)
		-- the full right order still works after resets
		Puzzles.turnWheel(s, 2, 0)
		Puzzles.turnWheel(s, 3, 0)
		r, n = Puzzles.turnWheel(s, 1, 0)
		eq(r, "open")
		eq(n, 3)
	end)
	test("the two clue plates together determine every authored order uniquely; neither does alone", function()
		for _, text in WorldDefs.Puzzles.W05.orders do
			local order = assert(Puzzles.parseOrder(text, 3))
			local a, b = Puzzles.w05CluesFor(text)
			assert(Puzzles.clueHolds(a, order) and Puzzles.clueHolds(b, order), "clues contradict " .. text)
			local both = Puzzles.ordersMatching({ a, b }, 3)
			eq(#both, 1, "orders matching both clues for " .. text)
			assert(sameOrder(both[1], order), "unique solution is the authored order " .. text)
			assert(#Puzzles.ordersMatching({ a }, 3) > 1, "plate 1 alone decides " .. text)
			assert(#Puzzles.ordersMatching({ b }, 3) > 1, "plate 2 alone decides " .. text)
			local ta, tb = Puzzles.clueText(a), Puzzles.clueText(b)
			assert(string.find(ta, "before", 1, true), ta)
			assert(string.find(tb, "turns", 1, true), tb)
		end
		local a, b = Puzzles.w05CluesFor("123")
		eq(Puzzles.clueText(a), "The upper race (I) closes before the middle race (II).")
		eq(Puzzles.clueText(b), "The lower wheel (III) turns last.")
	end)
	test("the corridor refloods only after its time and only when nobody is in it or the vault", function()
		local s = Puzzles.newW05("312", 3)
		for _, w in s.order do
			Puzzles.turnWheel(s, w, 50)
		end
		local secs = Config.Puzzles.sluiceRefloodSeconds
		eq(Puzzles.w05ShouldReflood(s, 50 + secs - 1, secs, false), false)
		eq(Puzzles.w05ShouldReflood(s, 50 + secs, secs, true), false, "occupied")
		eq(Puzzles.w05ShouldReflood(s, 50 + secs, secs, false), true)
		Puzzles.refloodW05(s)
		eq(s.open, false)
		eq(s.progress, 0)
		eq(Puzzles.w05ShouldReflood(s, 1e9, secs, false), false)
	end)

	print("P05 echo sequence")
	test("attempts are normalised: case-insensitive, only S and L, 1 to 8 symbols", function()
		eq(Puzzles.normalizeEcho("SLSS"), "SLSS")
		eq(Puzzles.normalizeEcho("slss"), "SLSS")
		eq(Puzzles.normalizeEcho("sLsS"), "SLSS")
		eq(Puzzles.normalizeEcho("SSSSLLLL"), "SSSSLLLL")
		eq(Puzzles.normalizeEcho("SSSSLLLLS"), nil, "nine symbols")
		eq(Puzzles.normalizeEcho(""), nil)
		eq(Puzzles.normalizeEcho("SLXS"), nil)
		eq(Puzzles.normalizeEcho("S L S"), nil)
		eq(Puzzles.normalizeEcho("•—••"), nil)
		eq(Puzzles.normalizeEcho(nil), nil)
		eq(Puzzles.normalizeEcho(12), nil)
		eq(Puzzles.normalizeEcho({ "S" }), nil)
	end)
	test("matching needs the exact pattern: same length, same order", function()
		eq(Puzzles.echoMatches("SLSS", "SLSS"), true)
		eq(Puzzles.echoMatches("SLSS", "slss"), true, "case does not matter")
		eq(Puzzles.echoMatches("SLSS", "SLS"), false, "too short")
		eq(Puzzles.echoMatches("SLSS", "SLSSS"), false, "too long")
		eq(Puzzles.echoMatches("SLSS", "LSSS"), false)
		eq(Puzzles.echoMatches("SLSS", "SLSX"), false)
		eq(Puzzles.echoMatches("SLSS", nil), false)
	end)
	test("the pattern is always readable as text and as a rhythm (never audio-only)", function()
		eq(Puzzles.echoSymbols("SLSS"), "• — • •")
		eq(Puzzles.echoSymbols("LL"), "— —")
		for _, seq in WorldDefs.Puzzles.P05.sequences do
			eq(Puzzles.normalizeEcho(seq), seq, "authored sequence " .. seq)
			local tl = Puzzles.echoTimeline(seq)
			eq(#tl, #seq)
			for i, step in tl do
				local long = string.sub(seq, i, i) == "L"
				eq(step.on, if long then Puzzles.ECHO_LONG_SECONDS else Puzzles.ECHO_SHORT_SECONDS)
				assert(step.off > 0, "gap between pulses")
			end
		end
		assert(Puzzles.ECHO_LONG_SECONDS >= 2 * Puzzles.ECHO_SHORT_SECONDS, "long is clearly longer than short")
		for _, id in { "radio_wrong", "radio_locked" } do
			local c = assert(CueDefs[id], id)
			eq(c.essential, true, id .. " essential (captioned)")
		end
	end)

	print("P04 weight and pulley")
	test("three stones raise the grate; extra stones change nothing", function()
		eq(WorldDefs.Puzzles.P04.stonesNeeded, 3)
		local s = Puzzles.newP04(3)
		local n, up = Puzzles.loadStone(s, 0, 15)
		eq(n, 1)
		eq(up, false)
		n, up = Puzzles.loadStone(s, 0, 15)
		eq(up, false)
		eq(s.raised, false)
		n, up = Puzzles.loadStone(s, 0, 15)
		eq(n, 3)
		eq(up, true)
		eq(s.raised, true)
		n, up = Puzzles.loadStone(s, 1, 15)
		eq(n, 3)
		eq(up, false)
	end)
	test("unlatched, the worn brake holds a short time; latched it never drops", function()
		local s = Puzzles.newP04(3)
		for _ = 1, 3 do
			Puzzles.loadStone(s, 0, 15)
		end
		eq(Puzzles.p04ShouldDrop(s, 10, false), false, "within the slip time")
		eq(Puzzles.p04ShouldDrop(s, 16, false), true, "slipped")
		eq(Puzzles.toggleLatch(s, 5, 300), "latched")
		eq(Puzzles.p04ShouldDrop(s, 1e9, false), false, "latched holds")
		eq(Puzzles.toggleLatch(s, 1000, 300), "unlatched")
		eq(Puzzles.p04ShouldDrop(s, 1299, false), false, "unlatching starts the drop timer")
		eq(Puzzles.p04ShouldDrop(s, 1300, false), true)
		eq(Puzzles.p04ShouldDrop(s, 1300, true), false, "never drops while anyone is under or behind it")
		Puzzles.dropP04(s)
		eq(s.raised, false)
		eq(s.stones, 0, "the basket tips out on a drop")
		eq(Puzzles.toggleLatch(s, 1400, 300), "not_raised")
		eq(s.latched, false)
	end)
	test("the drop rule waits for an empty area no matter how long the timer has run", function()
		local s = Puzzles.newP04(3)
		Puzzles.innerLever(s, 0, 300)
		for t = 0, 5000, 250 do
			eq(Puzzles.p04ShouldDrop(s, t, true), false, "occupied at t=" .. t)
		end
		eq(Puzzles.p04ShouldDrop(s, 5000, false), true)
	end)
	test("a party member holding the lever raises it without stones, only while held", function()
		local s = Puzzles.newP04(3)
		eq(Puzzles.leverHold(s), true)
		eq(s.raised, true)
		eq(s.stones, 0)
		eq(Puzzles.leverHold(s), false, "a second holder does not re-raise")
		eq(Puzzles.p04ShouldDrop(s, 1e6, false), false, "held")
		Puzzles.leverRelease(s)
		eq(Puzzles.p04ShouldDrop(s, 101, false), false, "still one holder")
		Puzzles.leverRelease(s)
		eq(s.holders, 0)
		eq(Puzzles.p04ShouldDrop(s, 101, true), false, "never drops on anyone who crossed")
		eq(Puzzles.p04ShouldDrop(s, 101, false), true, "no slip time after the last release (review R2-3)")
		Puzzles.leverRelease(s)
		eq(s.holders, 0, "never negative")
	end)
	test("the inner lever always raises the grate", function()
		local s = Puzzles.newP04(3)
		eq(Puzzles.innerLever(s, 0, 300), true, "from fully down with an empty basket")
		eq(s.raised, true)
		eq(Puzzles.innerLever(s, 10, 300), false, "already up")
		eq(s.raised, true)
		Puzzles.dropP04(s)
		eq(Puzzles.innerLever(s, 500, 300), true, "again after a drop")
		eq(Puzzles.p04ShouldDrop(s, 799, false), false, "holds for the drop time")
	end)

	test("every cue this package sends has a caption; essential ones are flagged essential", function()
		local essential = {
			"fuse_spark",
			"power_restored",
			"power_tripped",
			"grate_rise",
			"grate_drop",
			"radio_wrong",
			"radio_locked",
			"sluice_gate",
			"sluice_reset",
			"sluice_open",
			"sluice_flood",
			"gate_open",
			"water_drain",
			"water_rising",
			"shelter_probe",
		}
		for _, id in essential do
			local c = assert(CueDefs[id], "no caption for " .. id)
			eq(c.essential, true, id)
			assert(#c.text > 0, id)
		end
		for _, id in { "pulley_creak", "radio_tone", "valve_turn", "valve_reset", "plaque_turn" } do
			assert(CueDefs[id], "no caption for " .. id)
		end
	end)

	print("Occupancy boxes and gates")
	test("the P04 area covers under the grate, the corridor and the store, not the pulley room", function()
		local pulley, store = chamber("R01.rusted_pulley"), chamber("R01.pulley_store")
		local W, H = WorldDefs.CORRIDOR_WIDTH, WorldDefs.CORRIDOR_HEIGHT
		local boxes = { Puzzles.corridorBox(pulley, store, W, H, 1, 4), Puzzles.chamberBox(store, 1) }
		local g = WorldDefs.Puzzles.P04.grate
		assert(Puzzles.inAnyBox(boxes, g.x, g.y + 1, g.z), "under the grate")
		assert(Puzzles.inAnyBox(boxes, g.x + 3, g.y + 1, g.z - 3), "just in front of the grate")
		assert(Puzzles.inAnyBox(boxes, 0, 1, 380), "mid corridor")
		local il = WorldDefs.Puzzles.P04.innerLever
		assert(Puzzles.inAnyBox(boxes, il.x, il.y + 1, il.z), "at the inner lever")
		assert(Puzzles.inAnyBox(boxes, store.pos.x, store.pos.y + 1, store.pos.z), "in the store")
		assert(not Puzzles.inAnyBox(boxes, pulley.pos.x, pulley.pos.y + 1, pulley.pos.z), "pulley room centre")
		local b = WorldDefs.Puzzles.P04.basket
		assert(not Puzzles.inAnyBox(boxes, b.x, b.y + 1, b.z), "the basket is outside the area")
	end)
	test("the W05 area covers the flooded corridor and the vault, not the silt works", function()
		local silt, vault = chamber("R03.silt_loop"), chamber("R03.overflow_vault")
		local W, H = WorldDefs.CORRIDOR_WIDTH, WorldDefs.CORRIDOR_HEIGHT
		local boxes = { Puzzles.corridorBox(silt, vault, W, H, 1, 2), Puzzles.chamberBox(vault, 1) }
		local bp = WorldDefs.Puzzles.W05.barrier
		assert(Puzzles.inAnyBox(boxes, bp.x, bp.y + 1, bp.z), "barrier point")
		assert(Puzzles.inAnyBox(boxes, vault.pos.x, vault.pos.y + 1, vault.pos.z), "vault")
		assert(Puzzles.inAnyBox(boxes, silt.pos.x - silt.size.x / 2 - 1, silt.pos.y + 1, silt.pos.z), "silt-side mouth")
		assert(not Puzzles.inAnyBox(boxes, silt.pos.x, silt.pos.y + 1, silt.pos.z), "silt works centre")
		for i, w in WorldDefs.Puzzles.W05.wheels do
			assert(not Puzzles.inAnyBox(boxes, w.x, w.y, w.z), "wheel " .. i .. " is outside the area")
		end
	end)
	test("every gated corridor's gate is reported by openGates (unknown gates fail closed)", function()
		local ids: { [string]: boolean } = {}
		for _, id in Puzzles.GATE_IDS do
			ids[id] = true
		end
		for _, need in { "P01", "P02", "P04", "W05" } do
			assert(ids[need], need .. " missing from GATE_IDS")
		end
		for _, cor in WorldDefs.Corridors do
			if cor.gate then
				assert(ids[cor.gate], "gate " .. cor.gate .. " is not reported")
			end
		end
	end)
	test("P01 and P02 helpers no longer assume four orientations or three valves", function()
		for orientations = 2, 6 do
			for target = 0, orientations - 1 do
				eq(Puzzles.newP01(target, orientations).solved, false)
				assert(Puzzles.newP01(target, orientations).orientation ~= target, "starts on the answer")
			end
		end
		eq(Puzzles.p01Label(1, 4), "→")
		eq(Puzzles.p01Label(1, 8), "45°")
		local p = Puzzles.newP02(1)
		Puzzles.toggleValve(p, 1)
		Puzzles.resetP02(p)
		eq(#p.valves, #p.solution)
		eq(p.valves[1], false)
		eq(#WorldDefs.Puzzles.P02.valves, #Puzzles.P02_SOLUTIONS[1])
		eq(Puzzles.roman(4), "IV")
	end)

	print("Shelters S04 and S05")
	local S04 = WorldDefs.Shelters["S04.service_office"]
	local S05 = WorldDefs.Shelters["S05.stable_junction"]
	test("every shelter definition is sound for interiors and panels", function()
		for id, def in WorldDefs.Shelters do
			local problems = Shelters.validate(def, function(itemId)
				return ItemDefs.get(itemId) ~= nil
			end)
			eq(#problems, 0, id .. ": " .. table.concat(problems, "; "))
		end
		eq(S04.family, "survey_station_room")
		eq(S05.family, "stable_anchor_chamber")
	end)
	test("validation catches broken definitions", function()
		local bad = {
			id = "SX.bad",
			family = "x",
			regionId = "R01",
			entrances = {
				{ id = "a", requiredUpgrade = "nope", requiredStage = 1 },
				{ id = "b", requiredUpgrade = "bars", requiredStage = 3 },
			},
			safetyUpgrades = { bars = { maxStage = 2, costPerStage = { { ["mat.plank"] = 1 } } } },
			functionalUpgrades = { hot_tub = { maxStage = 1, costPerStage = { { ["mat.unobtainium"] = 1 } } } },
		}
		local problems = Shelters.validate(bad, function(itemId)
			return ItemDefs.get(itemId) ~= nil
		end)
		local text = table.concat(problems, "\n")
		for _, want in { "names no safety upgrade", "above max", "do not match", "unknown item", "no interior visual" } do
			assert(string.find(text, want, 1, true), "missing problem: " .. want .. "\n" .. text)
		end
		local many = table.clone(bad)
		many.entrances = {}
		for i = 1, #Shelters.ENTRANCE_SLOTS + 1 do
			table.insert(many.entrances, { id = "e" .. i, requiredUpgrade = "bars", requiredStage = 1 })
		end
		assert(string.find(table.concat(Shelters.validate(many), "\n"), "more entrances than", 1, true))
		local none = table.clone(bad)
		none.entrances = {}
		assert(string.find(table.concat(Shelters.validate(none), "\n"), "at least one entrance", 1, true))
	end)
	test("the generic visuals map covers every functional upgrade and follows the union stage", function()
		for _, id in { "workbench", "supply_shelves", "better_lighting", "station_power" } do
			assert(Shelters.FUNCTIONAL_VISUALS[id], id .. " has no visual")
		end
		local map: Shelters.UpgradeMap = {}
		local vis = Shelters.functionalVisuals(S04, map)
		local n = 0
		for id, on in vis do
			n += 1
			assert(S04.functionalUpgrades[id], "visual for an upgrade S04 does not define: " .. id)
			eq(on, false, id .. " starts off")
		end
		local defined = 0
		for _ in S04.functionalUpgrades do
			defined += 1
		end
		eq(n, defined)
		Shelters.raise(map, S04.id, "station_power", 1)
		eq(Shelters.functionalVisuals(S04, map).station_power, true)
		eq(Shelters.functionalVisuals(S04, map).workbench, false)
		eq(Shelters.functionalVisuals(S05, map).better_lighting, false, "upgrades are per shelter")
	end)
	test("entrance visuals and slots", function()
		eq(Shelters.entranceLook(0, 2), "open")
		eq(Shelters.entranceLook(1, 2), "patched")
		eq(Shelters.entranceLook(2, 2), "secured")
		eq(Shelters.entranceLook(3, 2), "secured")
		eq(Shelters.entranceLook(1, 1), "secured")
		local seen: { [string]: boolean } = {}
		for _, slot in Shelters.ENTRANCE_SLOTS do
			local key = slot.wall .. ":" .. slot.along
			assert(not seen[key], "duplicate slot " .. key)
			seen[key] = true
			assert(slot.width > 0 and slot.y > 0, "slot size")
		end
		local most = 0
		for _, def in WorldDefs.Shelters do
			most = math.max(most, #def.entrances)
		end
		assert(most <= #Shelters.ENTRANCE_SLOTS, "a shelter has more entrances than slots")
	end)
	test("S04 and S05 reach secured only when every entrance meets its stage", function()
		for _, def in { S04, S05 } do
			local m: Shelters.UpgradeMap = {}
			eq(Shelters.fortification(def, m), "discovered")
			for i, e in def.entrances do
				Shelters.raise(m, def.id, e.requiredUpgrade, e.requiredStage)
				eq(Shelters.isSecured(def, m), i == #def.entrances, def.id .. " after entrance " .. i)
			end
			-- functional upgrades never count toward security
			local f: Shelters.UpgradeMap = {}
			for id, u in def.functionalUpgrades do
				Shelters.raise(f, def.id, id, u.maxStage)
			end
			eq(Shelters.isSecured(def, f), false)
		end
	end)
	test("station_power cannot be bought through the panel; its cost row stays informational", function()
		local map: Shelters.UpgradeMap = {}
		local info, stage = Shelters.nextCost(S04, map, "station_power")
		local cost = assert(info, "station_power keeps an informational cost row")
		eq(stage, 1)
		eq(cost["tool.fuse_kit"], 1)
		local n = 0
		for _ in cost do
			n += 1
		end
		eq(n, 1, "the row is one fuse kit")
		eq(Shelters.isPurchasable(S04, "station_power"), false)
		local buy, buyStage = Shelters.purchaseCost(S04, map, "station_power")
		eq(buy, nil, "even with a fuse kit in hand")
		eq(buyStage, nil)
		assert(Shelters.GRANT_ONLY.station_power and #Shelters.GRANT_ONLY.station_power > 0, "lock reason")
		-- ordinary upgrades are unaffected
		local wb, wbStage = Shelters.purchaseCost(S04, map, "workbench")
		assert(wb and wbStage == 1, "workbench is still buyable")
		eq(Shelters.purchaseCost(S04, map, "door_bars") ~= nil, true)
		eq(Shelters.isPurchasable(S04, "hot_tub"), false, "unknown ids are not purchasable")
	end)
	test("station_power reaches party members only through the existing union and inheritance", function()
		-- the breaker repair raises it for the acting player only
		local actor: Shelters.UpgradeMap = { ["S04.service_office"] = { door_bars = 1 } }
		local member: Shelters.UpgradeMap = { ["S04.service_office"] = { duct_cover = 1 } }
		eq(Shelters.raise(actor, S04.id, "station_power", 1), true)
		eq(Shelters.stage(member, S04.id, "station_power"), 0, "nothing granted to others directly")
		-- PartyService.propagateUpgrades: union of the members' maps, inherited into each member
		local shared = Shelters.union({ actor, member })
		eq(Shelters.stage(shared, S04.id, "station_power"), 1)
		eq(Shelters.stage(shared, S04.id, "door_bars"), 1)
		eq(Shelters.stage(shared, S04.id, "duct_cover"), 1)
		eq(Shelters.inherit(member, shared), 2, "station_power and door_bars inherited")
		eq(Shelters.stage(member, S04.id, "station_power"), 1)
		eq(Shelters.inherit(member, shared), 0, "repeated joins change nothing (T10)")
		eq(Shelters.inherit(actor, shared), 1, "actor inherits duct_cover only")
		-- never a sum, and a grant is never lowered by a later union
		eq(Shelters.raise(member, S04.id, "station_power", 1), false)
		eq(Shelters.stage(Shelters.union({ member, member, actor }), S04.id, "station_power"), 1)
	end)
	test("regrouping on party change keeps groups apart and avoids needless moves", function()
		local function free(_k: string): boolean
			return false
		end
		-- everyone still belongs: nothing changes
		local keep, moves = Shelters.regroup("party:P@S", { a = "party:P@S", b = "party:P@S" }, free)
		eq(keep, "party:P@S")
		eq(next(moves), nil)
		-- b left the party: only b moves, to their own solo cell
		keep, moves = Shelters.regroup("party:P@S", { a = "party:P@S", b = "solo:2@S" }, free)
		eq(keep, "party:P@S")
		eq(moves.b, "solo:2@S")
		eq(moves.a, nil)
		-- the party dissolved around a lone occupant: the cell is re-keyed, nobody is teleported
		keep, moves = Shelters.regroup("party:P@S", { a = "solo:1@S" }, free)
		eq(keep, "solo:1@S")
		eq(next(moves), nil)
		-- a solo occupant joined a party whose cell already exists: they move there
		keep, moves = Shelters.regroup("solo:1@S", { a = "party:Q@S" }, function(k)
			return k == "party:Q@S"
		end)
		eq(keep, "solo:1@S")
		eq(moves.a, "party:Q@S")
		-- two new groups: the larger keeps the room, ties go to the smaller key
		keep, moves = Shelters.regroup("party:P@S", { a = "solo:1@S", b = "party:R@S", c = "party:R@S" }, free)
		eq(keep, "party:R@S")
		eq(moves.a, "solo:1@S")
		eq(moves.b, nil)
		keep, moves = Shelters.regroup("party:P@S", { a = "solo:2@S", b = "solo:1@S" }, free)
		eq(keep, "solo:1@S")
		eq(moves.a, "solo:2@S")
	end)
end
