--!strict
-- Milestone 3 creatures and director (docs/MILESTONE-3.md 4.3; section 10, 11; F06, F07). Pure rules only: these do
-- not prove the creature services, replication or rendering work in Roblox.

local WorldDefs = require("../../src/shared/Data/WorldDefs")
local CueDefs = require("../../src/shared/Data/CueDefs")
local Config = require("../../src/shared/Data/Config")
local Progress = require("../../src/shared/Logic/Progress")
local Director = require("../../src/shared/Logic/Director")
local CreatureRules = require("../../src/shared/Logic/CreatureRules")

type V3 = CreatureRules.V3

local function v(x: number, y: number, z: number): V3
	return { x = x, y = y, z = z }
end

return function(T)
	local test, eq, near = T.test, T.eq, T.near
	print("Creatures M3 (C02, C03, C04, C08) and director")

	-- Shared data ----------------------------------------------------------------------------------
	test("the four M3 creatures are SLICE with four research stages and matching hints", function()
		for _, key in { "C02_BorrowedMiner", "C03_WickMoth", "C04_ChalkHand", "C08_LanternThief" } do
			local c = WorldDefs.Creatures[key]
			eq(c.status, "SLICE", key)
			eq(#c.researchEvidence, 4, key)
			assert(#c.researchEvidence <= #Progress.RESEARCH_STAGES, key .. " exceeds the stage names")
			eq(#(c.hints :: { string }), #c.researchEvidence, key)
		end
	end)
	test("harmless phenomena are internally distinct from the damaging thief", function()
		eq(WorldDefs.Creatures.C02_BorrowedMiner.damaging, false)
		eq(WorldDefs.Creatures.C03_WickMoth.damaging, false)
		eq(WorldDefs.Creatures.C04_ChalkHand.damaging, false)
		eq(WorldDefs.Creatures.C08_LanternThief.damaging, true)
		eq(WorldDefs.Creatures.C08_LanternThief.killable, false)
	end)
	test("every cue the creatures send exists, and the thief's warnings are essential", function()
		for _, id in
			{
				"miner_rhythm",
				"miner_fade",
				"moth_flutter",
				"moth_disperse",
				"chalkhand_scratch",
				"thief_rattle",
				"thief_strike",
				"thief_decoyed",
				"thief_lost",
				"thief_repelled",
				"weapon_ineffective",
				"sidelooker_scrape",
				"sidelooker_retreat",
			}
		do
			assert(CueDefs[id] ~= nil, "missing cue " .. id)
		end
		eq(CueDefs.thief_rattle.essential, true, "rattle precedes damage")
		eq(CueDefs.thief_strike.essential, true)
		eq(CueDefs.moth_flutter.essential, true, "a resource effect is announced")
	end)
	test("miner homes: work spot in its chamber, lure spot in a dead end next to it", function()
		for _, h in WorldDefs.Creatures.C02_BorrowedMiner.homes do
			local c = assert(WorldDefs.chamber(h.chamberId))
			local l = assert(WorldDefs.chamber(h.lureChamberId))
			assert(CreatureRules.inChamber(h.workPos, c.pos, c.size, 0), "work spot outside " .. h.chamberId)
			assert(CreatureRules.inChamber(h.lurePos, l.pos, l.size, 0), "lure spot outside " .. h.lureChamberId)
			eq(#WorldDefs.neighbors(h.lureChamberId), 1, h.lureChamberId .. " is a dead end")
		end
	end)
	test("moth zones and thief homes are real chambers in the right regions", function()
		for _, z in WorldDefs.Creatures.C03_WickMoth.zones do
			assert(WorldDefs.chamber(z), z)
		end
		for _, h in WorldDefs.Creatures.C08_LanternThief.homes do
			local c = assert(WorldDefs.chamber(h), h)
			assert(table.find(WorldDefs.Creatures.C08_LanternThief.regions, c.regionId), h .. " outside R04/R05")
		end
		local note = false
		for _, r in WorldDefs.Readables do
			note = note or r.id == WorldDefs.Creatures.C08_LanternThief.counterEvidence
		end
		assert(note, "the counter evidence is a readable in the world")
	end)

	-- Generic --------------------------------------------------------------------------------------------
	test("rolls are frame-rate independent", function()
		local rate, total = 0.2, 1
		local p15 = 1 - (1 - CreatureRules.chance(rate, total / 15)) ^ 15
		local p60 = 1 - (1 - CreatureRules.chance(rate, total / 60)) ^ 60
		near(p15, p60, 1e-9, "same chance per second at 15 Hz and 60 Hz")
		near(p15, 1 - math.exp(-0.2), 1e-9)
		eq(CreatureRules.chance(0, 1), 0)
		eq(CreatureRules.chance(1, 0), 0)
	end)
	test("watching needs range, the look cone and line of sight; degenerate looks never NaN", function()
		local ahead = v(0, 0, -1)
		assert(CreatureRules.watching(ahead, v(0, 0, -20), 40, CreatureRules.Miner.watchCos, true))
		assert(not CreatureRules.watching(ahead, v(0, 0, -20), 40, CreatureRules.Miner.watchCos, false), "no sight")
		assert(not CreatureRules.watching(ahead, v(0, 0, -50), 40, CreatureRules.Miner.watchCos, true), "too far")
		-- 30 degrees off is outside a 25 degree cone
		local off = v(math.sin(math.rad(30)) * 20, 0, -math.cos(math.rad(30)) * 20)
		assert(not CreatureRules.watching(ahead, off, 40, CreatureRules.Miner.watchCos, true), "outside cone")
		local inside = v(math.sin(math.rad(20)) * 20, 0, -math.cos(math.rad(20)) * 20)
		assert(CreatureRules.watching(ahead, inside, 40, CreatureRules.Miner.watchCos, true), "inside cone")
		eq(CreatureRules.flatCos(v(0, 1, 0), v(0, 0, -5)), nil, "looking straight up")
		eq(CreatureRules.flatCos(ahead, v(0, -5, 0)), nil, "target straight below")
		assert(not CreatureRules.watching(v(0, 1, 0), v(0, 0, -5), 40, 0.9, true))
	end)
	test(
		"creature graph: closed solid gates stop creatures, the Wader wades deep-water gates, pockets connect",
		function()
			local ids = {}
			for _, c in WorldDefs.Chambers do
				table.insert(ids, c.id)
			end
			local g = CreatureRules.buildGraph(ids, WorldDefs.Corridors)
			local closed: { [string]: boolean } = {}
			eq(#CreatureRules.route(g, "R02.plaque_hall", "R02.sealed_chapel", closed, false), 0, "P01 closed")
			eq(
				#CreatureRules.route(g, "R02.plaque_hall", "R02.sealed_chapel", closed, true),
				0,
				"a stone gate is a wall"
			)
			eq(#CreatureRules.route(g, "R02.plaque_hall", "R02.sealed_chapel", { P01 = true }, false), 1, "P01 open")
			eq(#CreatureRules.route(g, "R03.sluice", "R03.cistern", closed, false), 0, "deep water stops walkers")
			eq(#CreatureRules.route(g, "R03.sluice", "R03.cistern", closed, true), 1, "the Wader wades in")
			eq(#CreatureRules.route(g, "R01.rusted_pulley", "R01.pulley_store", closed, true), 0, "P04 grate")
			-- pocket corridors are always connected (every version keeps the same two doors)
			local p = CreatureRules.route(g, "R05.south_anchor", "R05.center_anchor", closed, false)
			eq(#p, 1, "PK1 joins the anchors directly")
			eq(p[1], "R05.center_anchor")
			local toJunction = CreatureRules.route(g, "R05.center_anchor", "R05.junction", closed, false)
			eq(toJunction[#toJunction], "R05.junction")
			-- the misleading paths exist for the miner, and the survey station is reachable from the waterworks
			eq(#CreatureRules.route(g, "R04.station_hall", "R04.collapsed_adit", closed, false), 2)
			eq(#CreatureRules.route(g, "R01.east_loop", "R01.collapsed_drift", closed, false), 1)
			assert(#CreatureRules.route(g, "R03.sluice", "R05.east_anchor", closed, false) > 0)
			eq(#CreatureRules.route(g, "R04.map_room", "R04.map_room", closed, false), 0, "already there")
			eq(#CreatureRules.route(g, "R04.map_room", "nowhere", closed, false), 0, "unknown chamber")
		end
	)
	test("research field-experience keys: one per stage, matching the player package back-fill", function()
		eq(CreatureRules.researchXpKey("C07", 2), "research:C07:2")
		local keys = CreatureRules.researchXpKeys("C02", 1, 3)
		eq(#keys, 2)
		eq(keys[1], "research:C02:2")
		eq(keys[2], "research:C02:3")
		eq(#CreatureRules.researchXpKeys("C02", 2, 2), 0, "no rise, no experience")
	end)
	test("nearest wall faces the miner's wall", function()
		local c = assert(WorldDefs.chamber("R04.station_hall"))
		local d = CreatureRules.nearestWallDir(v(-70, -64, 920), c.pos, c.size)
		eq(d.x, 1)
		eq(d.z, 0)
		local e = assert(WorldDefs.chamber("R01.east_loop"))
		local d2 = CreatureRules.nearestWallDir(v(92, 0, 340), e.pos, e.size)
		eq(d2.z, 1)
	end)

	-- C02 Borrowed Miner -----------------------------------------------------------------------------------
	test("miner rhythm is exact: stroke k falls at origin + k * rhythm, without drift", function()
		local r = Config.Creatures.minerRhythmSeconds
		eq(r, 1.5)
		eq(CreatureRules.strokeCount(100, r, 100), 0)
		eq(CreatureRules.strokeCount(100, r, 101.49), 0)
		eq(CreatureRules.strokeCount(100, r, 101.5), 1)
		eq(CreatureRules.strokeCount(100, r, 100 + 1000 * r), 1000, "no drift after a thousand strokes")
		eq(CreatureRules.strokeTime(100, 7, r), 110.5)
		eq(CreatureRules.strokeCount(100, r, 50), 0, "before the origin")
		-- captions are throttled to one per phrase of three strokes
		local captions = 0
		for k = 1, 9 do
			if CreatureRules.minerCaptionDue(k) then
				captions += 1
			end
		end
		eq(captions, 3)
		assert(CreatureRules.minerCaptionDue(1), "the first stroke is captioned at once")
	end)
	test("miner listening: three strokes within 30 hears the rhythm; three phrases within 25 waits it out", function()
		local track = CreatureRules.newListen()
		local h, w = CreatureRules.minerListen(track, 28)
		eq(h, false)
		h, w = CreatureRules.minerListen(track, 28)
		eq(h, false)
		h, w = CreatureRules.minerListen(track, 28)
		eq(h, true, "three strokes within 30")
		eq(w, false, "28 studs is too far to count as waiting close by")
		local close = CreatureRules.newListen()
		for _ = 1, 8 do
			h, w = CreatureRules.minerListen(close, 20)
			eq(w, false)
		end
		h, w = CreatureRules.minerListen(close, 20)
		eq(w, true, "nine strokes (three repeats of the phrase) within 25")
		-- leaving resets: "without leaving"
		local leaver = CreatureRules.newListen()
		for _ = 1, 8 do
			CreatureRules.minerListen(leaver, 20)
		end
		CreatureRules.minerListen(leaver, math.huge)
		h, w = CreatureRules.minerListen(leaver, 20)
		eq(w, false, "stepping out of earshot starts the count again")
		eq(h, false)
	end)
	test("a verified ping within 40 studs makes the miner fade; farther does not", function()
		assert(CreatureRules.pingFades(v(0, 0, 0), v(39, 0, 0)))
		assert(CreatureRules.pingFades(v(0, 0, 0), v(0, 0, 40)))
		assert(not CreatureRules.pingFades(v(0, 0, 0), v(41, 0, 0)))
	end)
	test("miner research: stages in order; evidence gathered early counts later", function()
		local c = WorldDefs.Creatures.C02_BorrowedMiner
		local r = {}
		eq(Progress.addEvidence(r, c.id, "failed_verification", c.researchEvidence), 0, "cannot skip stages")
		eq(Progress.addEvidence(r, c.id, "seen", c.researchEvidence), 1)
		eq(Progress.addEvidence(r, c.id, "waited_for_repeat", c.researchEvidence), 1)
		eq(Progress.addEvidence(r, c.id, "heard_exact_rhythm", c.researchEvidence), 4, "early evidence now counts")
	end)

	-- C03 Wick Moth ------------------------------------------------------------------------------------
	local cfg: CreatureRules.MothConfig =
		{ flutterSeconds = 1.5, darkSeconds = Config.Creatures.mothDarkSeconds, cooldownSeconds = 12 }
	local lit = { on = true, isLantern = false, shielded = false }
	local dark = { on = false, isLantern = false, shielded = false }
	local openLantern = { on = true, isLantern = true, shielded = false }
	local shieldedLantern = { on = true, isLantern = true, shielded = true }
	local function input(now: number, over: { [string]: any }?): CreatureRules.MothInput
		local i: any = {
			now = now,
			dt = 0.1,
			inZone = true,
			light = lit,
			flareInZone = false,
			perceivable = true,
		}
		for k, val in (over or {}) :: { [string]: any } do
			i[k] = val
		end
		return i
	end
	local function attached(): CreatureRules.MothState
		local st = CreatureRules.newMoth()
		eq(CreatureRules.mothStep(st, input(0), cfg), "flutter")
		eq(CreatureRules.mothStep(st, input(1.0), cfg), nil, "still the flutter warning")
		eq(CreatureRules.mothStep(st, input(1.5), cfg), "attach")
		return st
	end

	test("moth attaches only to a working exposed light in its zone, after the 1.5 s flutter", function()
		attached()
		assert(CreatureRules.mothExposed(lit))
		assert(CreatureRules.mothExposed(openLantern), "an open lantern draws them")
		assert(not CreatureRules.mothExposed(shieldedLantern), "a shielded lantern does not")
		assert(not CreatureRules.mothExposed(dark))
		for _, over in
			{
				{ inZone = false },
				{ light = dark },
				{ light = shieldedLantern },
				{ flareInZone = true },
				{ perceivable = false },
			}
		do
			local st = CreatureRules.newMoth()
			eq(CreatureRules.mothStep(st, input(0, over), cfg), nil)
			eq(st.phase, "none")
		end
	end)
	test("moth disperses after the light is off for mothDarkSeconds (switching back on restarts the timer)", function()
		local st = attached()
		eq(CreatureRules.mothStep(st, input(2, { light = dark, dt = 2 }), cfg), nil)
		eq(CreatureRules.mothStep(st, input(2.5, { light = lit, dt = 0.5 }), cfg), nil, "on again")
		eq(st.darkFor, 0)
		eq(CreatureRules.mothStep(st, input(4, { light = dark, dt = 2 }), cfg), nil)
		eq(CreatureRules.mothStep(st, input(5.2, { light = dark, dt = 1.2 }), cfg), "disperse_dark")
		eq(st.phase, "cooldown")
	end)
	test("moth disperses on a shielded lantern, a flare in the zone, leaving, or being downed/hidden", function()
		eq(CreatureRules.mothStep(attached(), input(3, { light = shieldedLantern }), cfg), "disperse_shield")
		eq(CreatureRules.mothStep(attached(), input(3, { flareInZone = true }), cfg), "disperse_flare")
		eq(CreatureRules.mothStep(attached(), input(3, { inZone = false }), cfg), "disperse_left")
		eq(CreatureRules.mothStep(attached(), input(3, { perceivable = false }), cfg), "disperse_lost")
		-- counters during the flutter warning
		local st = CreatureRules.newMoth()
		CreatureRules.mothStep(st, input(0), cfg)
		eq(CreatureRules.mothStep(st, input(0.5, { light = shieldedLantern }), cfg), "cancel_shield")
		local st2 = CreatureRules.newMoth()
		CreatureRules.mothStep(st2, input(0), cfg)
		eq(CreatureRules.mothStep(st2, input(0.5, { flareInZone = true }), cfg), "cancel_flare")
	end)
	test("moth encounter cooldown after a dispersal", function()
		local st = attached()
		CreatureRules.mothStep(st, input(3, { inZone = false }), cfg)
		eq(CreatureRules.mothStep(st, input(10), cfg), nil, "still cooling down")
		eq(CreatureRules.mothStep(st, input(15.1), cfg), "flutter")
	end)
	test("moth never touches battery charge or health: it only reads the light", function()
		local light: any = { on = true, isLantern = false, shielded = false, charge = 42, health = 77 }
		local st = CreatureRules.newMoth()
		for t = 0, 30, 0.5 do
			CreatureRules.mothStep(st, input(t, { light = light }), cfg)
		end
		eq(light.charge, 42)
		eq(light.health, 77)
		eq(light.on, true)
		local keys = 0
		for _ in st :: any do
			keys += 1
		end
		eq(keys, 3, "the swarm state holds only its phase and timers")
	end)
	test("moth research stages", function()
		local c = WorldDefs.Creatures.C03_WickMoth
		local r = {}
		eq(Progress.addEvidence(r, c.id, "seen", c.researchEvidence), 1)
		eq(Progress.addEvidence(r, c.id, "heard_flutter", c.researchEvidence), 2)
		eq(Progress.addEvidence(r, c.id, "shielded_or_decoyed", c.researchEvidence), 2)
		eq(Progress.addEvidence(r, c.id, "dispersed_by_darkness", c.researchEvidence), 4)
	end)

	-- C04 Chalk Hand -----------------------------------------------------------------------------------
	local interval = Config.Creatures.chalkHandIntervalSeconds
	test("chalk hand: R05 only, at most once per interval, own chalk within 30 studs", function()
		local own = { v(10, -84, 1210), v(60, -84, 1210) }
		local me = v(0, -81, 1210)
		local t = CreatureRules.chalkHandTarget("R05", 1000, nil, interval, me, own)
		assert(t == own[1], "imitates the nearest own mark within 30")
		eq(CreatureRules.chalkHandTarget("R04", 1000, nil, interval, me, own), nil, "outside R05")
		eq(CreatureRules.chalkHandTarget("R05", 1000, 1000 - interval + 1, interval, me, own), nil, "interval")
		assert(CreatureRules.chalkHandTarget("R05", 1000, 1000 - interval, interval, me, own) ~= nil)
		eq(CreatureRules.chalkHandTarget("R05", 1000, nil, interval, v(0, -81, 1300), own), nil, "no chalk near")
		eq(CreatureRules.chalkHandTarget("R05", 1000, nil, interval, me, {}), nil, "no own chalk at all")
	end)
	test("chalk hand: the fake is near the real mark, never on it, on the same surface", function()
		local mark = v(10, -82, 1210)
		local wall = v(-1, 0, 0)
		for _, c in CreatureRules.fakeMarkCandidates(mark, wall) do
			local d = CreatureRules.distance(c, mark)
			assert(d >= CreatureRules.ChalkHand.minOffset and d <= 7, "near but not on: " .. d)
			eq(c.x, mark.x, "stays in the wall plane")
		end
		for _, c in CreatureRules.fakeMarkCandidates(mark, v(0, 1, 0)) do
			eq(c.y, mark.y, "floor mark stays on the floor")
		end
		assert(not CreatureRules.farFromAll(v(10, -82, 1211), { mark }, 2.5))
		assert(CreatureRules.farFromAll(v(10, -82, 1214), { mark }, 2.5))
	end)
	test("chalk hand: requests only for a shown, recent mark from close by", function()
		local range = CreatureRules.ChalkHand.inspectRange
		assert(CreatureRules.falseMarkValid(100, 150, 5, range))
		assert(not CreatureRules.falseMarkValid(nil, 150, 5, range), "never shown to this player")
		assert(not CreatureRules.falseMarkValid(100, 191, 5, range), "expired after 90 s")
		assert(not CreatureRules.falseMarkValid(100, 150, 30, range), "too far to inspect")
	end)
	test("chalk hand: compare confirms only with an own chalk mark within 40 studs", function()
		assert(CreatureRules.compareAllowed(v(0, 0, 0), { v(39, 0, 0) }))
		assert(not CreatureRules.compareAllowed(v(0, 0, 0), { v(41, 0, 0) }))
		assert(not CreatureRules.compareAllowed(v(0, 0, 0), {}))
	end)
	test("chalk hand research stages (inspect grants two in order)", function()
		local c = WorldDefs.Creatures.C04_ChalkHand
		local r = {}
		eq(Progress.addEvidence(r, c.id, "seen", c.researchEvidence), 1)
		eq(Progress.addEvidence(r, c.id, "noticed_false_mark", c.researchEvidence), 2)
		eq(Progress.addEvidence(r, c.id, "checked_notebook", c.researchEvidence), 3)
		eq(Progress.addEvidence(r, c.id, "confirmed_own_mark", c.researchEvidence), 4)
	end)

	-- C08 Lantern Thief --------------------------------------------------------------------------------
	local mult = Config.Lantern.exposureMultiplier
	test("thief never strikes without counter evidence, outside an approach, out of reach or without sight", function()
		local reach = WorldDefs.Creatures.C08_LanternThief.reach
		assert(CreatureRules.thiefMayStrike("approach", true, 4, reach, true))
		assert(not CreatureRules.thiefMayStrike("approach", false, 4, reach, true), "no counter evidence")
		assert(not CreatureRules.thiefMayStrike("stalk", true, 4, reach, true), "only from an approach")
		assert(not CreatureRules.thiefMayStrike("approach", true, reach + 1, reach, true), "out of reach")
		assert(not CreatureRules.thiefMayStrike("approach", true, 4, reach, false), "no line of sight")
	end)
	test("thief approaches only with counter evidence, director permission and while unwatched", function()
		assert(CreatureRules.thiefMayApproach(true, true, false))
		assert(not CreatureRules.thiefMayApproach(false, true, false), "before the warning note: stalk only")
		assert(not CreatureRules.thiefMayApproach(true, false, false), "director refuses")
		assert(not CreatureRules.thiefMayApproach(true, true, true), "begins outside the player's view")
	end)
	test("thief prefers the brightest light that is not its own; an open lantern is exposed", function()
		local torch =
			CreatureRules.lightScore({ on = true, isLantern = false, shielded = false, brightness = 1.2 }, mult)
		local lantern =
			CreatureRules.lightScore({ on = true, isLantern = true, shielded = false, brightness = 1.1 }, mult)
		local shielded =
			CreatureRules.lightScore({ on = true, isLantern = true, shielded = true, brightness = 1.1 }, mult)
		local off = CreatureRules.lightScore({ on = false, isLantern = true, shielded = false, brightness = 1.1 }, mult)
		near(lantern, 1.1 * mult, 1e-9)
		assert(lantern > torch, "an open lantern outshines a pocket torch")
		assert(shielded < torch, "a shielded lantern is a poor prize")
		eq(off, 0, "an unlit light draws nothing")
		eq(CreatureRules.pickVictim({ { score = torch, dist = 5 }, { score = lantern, dist = 40 } }), 2, "brightest")
		eq(CreatureRules.pickVictim({ { score = 1, dist = 30 }, { score = 1, dist = 10 } }), 2, "tie: nearest")
		eq(CreatureRules.pickVictim({ { score = 0, dist = 1 } }), nil, "no light, no victim")
		assert(CreatureRules.Thief.flareScore > lantern, "a lit flare outshines any carried light")
	end)
	test("thief decoy: a flare within 30 of it or its victim diverts it, nearest first, each flare once", function()
		local r = Config.Creatures.thiefDecoyRadius
		eq(r, 30)
		local thief = v(0, 0, 0)
		local victim = v(100, 0, 0)
		local nearThief = { position = v(20, 0, 0), key = "a" }
		local nearVictim = { position = v(120, 0, 0), key = "b" }
		local far = { position = v(60, 0, 0), key = "c" }
		local pick = CreatureRules.pickDecoy({ far, nearVictim, nearThief }, thief, victim, r, {})
		assert(pick and pick.key == "a", "nearest qualifying flare")
		pick = CreatureRules.pickDecoy({ far, nearVictim }, thief, victim, r, {})
		assert(pick and pick.key == "b", "a flare by the victim counts")
		eq(CreatureRules.pickDecoy({ far }, thief, victim, r, {}), nil, "out of range")
		eq(CreatureRules.pickDecoy({ nearThief }, thief, nil, r, { a = 1 }), nil, "each flare decoys once")
	end)
	test("thief lose-sight timer: thiefLoseSightSeconds without sight loses the victim; sight resets it", function()
		local limit = Config.Creatures.thiefLoseSightSeconds
		eq(limit, 4)
		local t, lost = CreatureRules.sightTimer(0, false, 1.5, limit)
		eq(lost, false)
		t, lost = CreatureRules.sightTimer(t, false, 1.5, limit)
		eq(lost, false)
		t, lost = CreatureRules.sightTimer(t, true, 0.1, limit)
		eq(t, 0, "a glimpse resets the timer")
		eq(lost, false)
		for _ = 1, 3 do
			t, lost = CreatureRules.sightTimer(t, false, 1.3, limit)
		end
		eq(lost, false)
		t, lost = CreatureRules.sightTimer(t, false, 0.2, limit)
		eq(lost, true)
	end)
	test("thief notices lights in sight, or close enough to glow around a corner", function()
		assert(CreatureRules.noticed(40, 50, true))
		assert(not CreatureRules.noticed(40, 50, false), "a wall hides a distant light")
		assert(CreatureRules.noticed(20, 50, false), "the glow carries around a corner up close")
		assert(not CreatureRules.noticed(60, 50, true))
	end)
	test("thief stun repels it except while it is already recoiling (no wasted charge)", function()
		for _, s in { "roam", "stalk", "warn", "approach", "withdraw", "decoyed" } do
			assert(CreatureRules.thiefStunRepels(s), s)
		end
		assert(not CreatureRules.thiefStunRepels("repelled"))
	end)
	test("thief stalks closer when supplies are low (F06), within a sane band", function()
		local D = Config.Director
		local wellSupplied = Director.pressure(D, {
			regionDanger = 0.55,
			healthFraction = 1,
			lightChargeFraction = 1,
			medicalItemCount = 3,
			exertionFraction = 0,
			secondsSinceThreat = 0,
			partySize = 1,
			inShelter = false,
		})
		local poor = Director.pressure(D, {
			regionDanger = 0.55,
			healthFraction = 0.4,
			lightChargeFraction = 0.15,
			medicalItemCount = 0,
			exertionFraction = 0.3,
			secondsSinceThreat = 200,
			partySize = 1,
			inShelter = false,
		})
		assert(wellSupplied < CreatureRules.Thief.engageThreshold, "a well-supplied traveller is not pressed")
		local calmR05 = Director.pressure(D, {
			regionDanger = 0.6,
			healthFraction = 1,
			lightChargeFraction = 1,
			medicalItemCount = 2,
			exertionFraction = 0,
			secondsSinceThreat = 3600,
			partySize = 1,
			inShelter = false,
		})
		assert(calmR05 < CreatureRules.Thief.engageThreshold, "nor in R05 after a long calm")
		assert(poor >= CreatureRules.Thief.engageThreshold, "a poorly supplied traveller is")
		local farD = CreatureRules.thiefStalkDistance(Director.stalkDistance(wellSupplied, 70, 22))
		local nearD = CreatureRules.thiefStalkDistance(Director.stalkDistance(poor, 70, 22))
		assert(nearD < farD)
		eq(CreatureRules.thiefStalkDistance(5), CreatureRules.Thief.minStalk)
		eq(CreatureRules.thiefStalkDistance(500), CreatureRules.Thief.maxStalk)
	end)
	test("thief research stages", function()
		local c = WorldDefs.Creatures.C08_LanternThief
		local r = {}
		eq(Progress.addEvidence(r, c.id, "seen", c.researchEvidence), 1)
		eq(Progress.addEvidence(r, c.id, "heard_rattle", c.researchEvidence), 2)
		eq(Progress.addEvidence(r, c.id, "lost_by_breaking_sight", c.researchEvidence), 2)
		eq(Progress.addEvidence(r, c.id, "decoyed_by_flare", c.researchEvidence), 4)
	end)

	-- Director ---------------------------------------------------------------------------------------------
	test("an open lantern raises how far creatures notice its carrier; shielded or off does not", function()
		eq(Director.exposure({ on = true, isLantern = true, shielded = false }, mult), mult)
		eq(Director.exposure({ on = true, isLantern = true, shielded = true }, mult), 1)
		eq(Director.exposure({ on = false, isLantern = true, shielded = false }, mult), 1)
		eq(Director.exposure({ on = true, isLantern = false, shielded = false }, mult), 1)
		near(Director.sightFactor({ on = true, isLantern = true, shielded = false }, mult), 1.4 * mult, 1e-9)
		eq(Director.sightFactor({ on = false, isLantern = false, shielded = false }, mult), 0.6, "darkness")
		assert(mult > 1)
	end)
	test("the thief shares the per-victim damaging-threat cap with every other creature", function()
		local D = Config.Director
		local victim = { activeDamagingThreats = 0, cooldownUntil = 0 }
		eq(Director.mayStartDamagingThreat(D, victim, 0, 10, 0.9, CreatureRules.Thief.engageThreshold), true)
		victim.activeDamagingThreats = 1 -- a Scrabbler, Wader or Knocker is already on them
		eq(Director.mayStartDamagingThreat(D, victim, 1, 10, 0.9, CreatureRules.Thief.engageThreshold), false)
		victim.activeDamagingThreats = 0
		eq(Director.mayStartDamagingThreat(D, victim, D.maxSimultaneousDamagingThreatsPerServer, 10, 0.9, 0.3), false)
	end)
	test("recovery intervals: after a strike, after a chase, and spacing after a threat without a chase", function()
		local D = Config.Director
		local victim = { activeDamagingThreats = 0, cooldownUntil = 0 }
		Director.recover(victim, 100, CreatureRules.Thief.strikeRecoverySeconds)
		eq(victim.cooldownUntil, 100 + CreatureRules.Thief.strikeRecoverySeconds)
		Director.afterChase(D, victim, 100)
		eq(victim.cooldownUntil, 100 + CreatureRules.Thief.strikeRecoverySeconds, "never shortened")
		local v2 = { activeDamagingThreats = 0, cooldownUntil = 0 }
		Director.afterThreat(D, v2, 50)
		eq(v2.cooldownUntil, 50 + D.minSecondsBetweenThreats)
		eq(Director.mayStartDamagingThreat(D, v2, 0, 60, 1, 0), false)
		eq(Director.mayStartDamagingThreat(D, v2, 0, 50 + D.minSecondsBetweenThreats, 1, 0), true)
	end)
	test("pressure counts every medical item (splints too) and never reads spending", function()
		local meds = { ["med.bandage"] = 1, ["med.splint"] = 2, ["nav.chalk"] = 10 }
		local function isMed(id: string): boolean
			return string.sub(id, 1, 4) == "med."
		end
		eq(Director.medicalCount(meds, isMed), 3)
		eq(Director.medicalCount({}, isMed), 0)
		-- the inputs type has no field for spending, Robux or purchases: an extra field changes nothing
		local base: any = {
			regionDanger = 0.6,
			healthFraction = 1,
			lightChargeFraction = 1,
			medicalItemCount = 2,
			exertionFraction = 0,
			secondsSinceThreat = 0,
			partySize = 1,
			inShelter = false,
		}
		local p0 = Director.pressure(Config.Director, base)
		base.robuxSpent = 1e6
		eq(Director.pressure(Config.Director, base), p0)
		-- low light and medical still raise pressure gradually
		base.lightChargeFraction = 0.5
		local p1 = Director.pressure(Config.Director, base)
		base.lightChargeFraction = 0
		local p2 = Director.pressure(Config.Director, base)
		assert(p0 < p1 and p1 < p2, "gradual")
	end)
end
