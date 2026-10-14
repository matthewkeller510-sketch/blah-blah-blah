--!strict
-- Review fixes, batch 4 (missions, progression and persistence). Pure rules only: nothing here proves the Roblox
-- services, DataStore writes, prompts or replication work in Studio.
--   Finding 0: health and the injury flag survive a rejoin (F18: never a free heal).
--   Findings 1, 2: M11 pays experience only for the owner's own recovery, at most once per cooldown.
--   Finding 7: progression.awarded no longer grows with every mission completion or recovered bag.
--   Finding 8: the P06 puzzle record pays no place experience, live or back-filled (D78).

local Config = require("../../src/shared/Data/Config")
local WorldDefs = require("../../src/shared/Data/WorldDefs")
local Vitals = require("../../src/shared/Logic/Vitals")
local Profile = require("../../src/shared/Logic/Profile")
local Progression = require("../../src/shared/Logic/Progression")
local Discovery = require("../../src/shared/Logic/Discovery")
local MissionRules = require("../../src/shared/Logic/MissionRules")

local H = Config.Health
local P = Config.Progression

return function(T: any)
	local test, eq, near = T.test, T.eq, T.near

	-- A session as PlayerService.onPlayerAdded builds it: fresh vitals, the progression maximum, then the restore.
	local function join(saved: any, bonus: number): Vitals.State
		local v = Vitals.new(H)
		Vitals.setMax(H, v, H.max + bonus)
		Vitals.restore(H, v, saved)
		return v
	end

	-- Round trip through a DataStore-like copy (only plain fields survive).
	local function roundTrip(v: Vitals.State): any
		local s = Vitals.persisted(H, v)
		return { health = s.health, injured = s.injured }
	end

	print("Finding 0: health persists across a rejoin (F18)")
	test("the reported exploit: a rank-5 player at 12 HP who rejoins is not healed", function()
		local v = join(nil, 8)
		eq(v.max, 108)
		Vitals.damage(H, v, 96, true)
		eq(v.health, 12)
		-- passive recovery inside the shelter stops at half the raised maximum
		for _ = 1, 600 do
			Vitals.step(H, v, 0.1, true)
		end
		near(v.health, 54, 1e-9)
		local back = join(roundTrip(v), 8)
		near(back.health, 54, 1e-9, "comes back with what it had")
		eq(back.injuryFlag, true, "the injury penalty survives the rejoin")
		eq(back.condition, "injured")
		assert(back.health < back.max, "no free heal")
	end)
	test("restore clamps to the current (raised) maximum and never below 1", function()
		eq(join({ health = 70, injured = false }, 8).health, 70)
		eq(join({ health = 500, injured = false }, 8).health, 108, "clamped to the raised maximum")
		eq(join({ health = 105, injured = false }, 0).health, 100, "clamped when the maximum is lower")
		eq(join({ health = 0, injured = true }, 0).health, 1)
		eq(join({ health = -40, injured = false }, 0).health, 1)
		eq(join({ health = math.huge, injured = false }, 0).health, 100)
		local low = join({ health = 20, injured = false }, 0)
		eq(low.condition, "injured", "low health shows as injured")
		eq(low.injuryFlag, false)
		local hurt = join({ health = 90, injured = true }, 0)
		eq(hurt.condition, "injured", "the injury flag shows as injured")
		eq(join({ health = 90, injured = false }, 0).condition, "healthy")
	end)
	test("a brand-new or older profile (no record) and malformed records start at full health", function()
		local none = join(nil, 8)
		eq(none.health, 108, "no record: full at the raised maximum")
		eq(none.injuryFlag, false)
		eq(none.condition, "healthy")
		local malformed: { any } = { "x", 5, {}, { health = "50" }, { health = 0 / 0, injured = true } }
		for i, saved in malformed do
			local v = join(saved, 8)
			eq(v.health, 108, "full: case " .. i)
			eq(v.injuryFlag, false)
			eq(v.condition, "healthy")
		end
	end)
	test("downed at logout comes back injured at the stabilized health, never dead and never healed", function()
		local v = join(nil, 0)
		Vitals.damage(H, v, 500)
		eq(v.condition, "downed")
		local s = Vitals.persisted(H, v)
		eq(s.health, H.stabilizedHealth)
		eq(s.injured, true)
		local back = join(roundTrip(v), 0)
		eq(back.condition, "injured")
		eq(back.health, H.stabilizedHealth)
		eq(back.injuryFlag, true)
		eq(back.downedRemaining, 0)
		eq(back.stabilized, false)
	end)
	test("dead before respawning comes back as the respawn would place it (the F18 cap)", function()
		local v = join(nil, 8)
		Vitals.damage(H, v, 500)
		Vitals.damage(H, v, 1)
		eq(v.condition, "dead")
		local back = join(roundTrip(v), 8)
		local respawned = join(nil, 8)
		Vitals.damage(H, respawned, 500)
		Vitals.damage(H, respawned, 1)
		Vitals.respawn(H, respawned)
		eq(back.health, respawned.health)
		eq(back.condition, respawned.condition)
		eq(back.injuryFlag, false)
	end)
	test("schema 2 carries the optional vitals field: default absent, kept by reconcile, no version bump", function()
		eq(Profile.CURRENT_VERSION, 2)
		local fresh = Profile.default(1, "Explorer", "R00.depot")
		eq(fresh.vitals, nil)
		local saved = Profile.default(2, "Explorer", "R00.depot") :: any
		saved.vitals = { health = 33.5, injured = true }
		local p = assert(Profile.reconcile(saved, 2, "Explorer", "R00.depot"))
		local pv = assert(p.vitals)
		eq(pv.health, 33.5)
		eq(pv.injured, true)
		local older = Profile.default(3, "Explorer", "R00.depot") :: any
		older.vitals = nil
		local q = assert(Profile.reconcile(older, 3, "Explorer", "R00.depot"))
		eq(q.vitals, nil, "a profile saved before the field stays without it (full health on join)")
		local v1 = Profile.default(4, "Explorer", "R00.depot") :: any
		v1.schemaVersion = 1
		v1.progression = nil
		local r = assert(Profile.reconcile(v1, 4, "Explorer", "R00.depot"))
		eq(r.vitals, nil)
	end)

	print("Findings 1 and 2: M11 experience only for the owner's own recovery, bounded")
	local function bag(kind: string, id: string): any
		return { bagId = id, kind = kind, anchor = { regionId = "R02", anchorId = "R02.plaque_hall" } }
	end
	test("an emptied slot is 'recovered' only for the owner's own recovery; otherwise 'delegated'", function()
		eq(MissionRules.m11Status({}, "death", "d1", true), "recovered")
		eq(MissionRules.m11Status({}, "death", "d1", false), "delegated")
		eq(MissionRules.m11Status({}, "logout", "l1", nil), "delegated")
		eq(MissionRules.m11Status({ death = bag("death", "d1") }, "death", "d1", true), "pending", "leftover bag")
		eq(MissionRules.m11Status({ death = bag("death", "d2") }, "death", "d1", true), "replaced")
	end)
	test("the experience cooldown: once per window, kept apart from the board cooldown", function()
		eq(MissionRules.m11XpCooldownSeconds(Config.Missions), MissionRules.M11_XP_COOLDOWN_SECONDS)
		eq(MissionRules.M11_XP_COOLDOWN_SECONDS, 900)
		eq(MissionRules.m11XpCooldownSeconds({ lostBelongingsXpCooldownSeconds = 60 }), 60)
		eq(MissionRules.m11XpCooldownSeconds({ lostBelongingsXpCooldownSeconds = "x" }), 900)
		assert(MissionRules.M11_XP_COOLDOWN_KEY ~= "M11", "accepting M11 is never locked by its experience limit")
		eq(MissionRules.cooldownSeconds("M11", Config.Missions), 0)
		eq(MissionRules.m11XpWait({}, 1000), 0)
		eq(MissionRules.m11XpWait({ ["M11.xp"] = 1900 }, 1000), 900)
		eq(MissionRules.m11XpWait({ ["M11.xp"] = 900 }, 1000), 0)
		eq(MissionRules.m11XpWait({ ["M11.xp"] = 0 / 0 }, 1000), 0)
	end)
	test("the relog farming loop pays at most once per cooldown window", function()
		-- MissionService.evaluateM11's decision for an own recovery: pay when the wait is over, then start it.
		local cooldowns: { [string]: number } = {}
		local rec = { xp = 0, awarded = {}, missionPaid = {}, bagsPaid = {} }
		local paid = 0
		local now = 10000
		for i = 1, 120 do -- one new logout bag recovered every 30 s for an hour
			now += 30
			local status = MissionRules.m11Status({}, "logout", "logout:logout:G" .. i, true)
			eq(status, "recovered")
			if MissionRules.m11XpWait(cooldowns, now) <= 0 then
				cooldowns[MissionRules.M11_XP_COOLDOWN_KEY] = now + MissionRules.m11XpCooldownSeconds(Config.Missions)
				if Progression.grant(rec, MissionRules.bagXpKey("logout:logout:G" .. i), P.xp.bag) then
					paid += 1
				end
			end
		end
		eq(paid, 4, "one hour of farming pays four times (once per 15 minutes), not 120")
		eq(rec.xp, 4 * P.xp.bag)
	end)
	test("the objective says only the owner's own recovery earns experience and states the limit", function()
		local text = MissionRules.m11Objective("logout", "Ossuary Galleries", "Hall of Plaques", 900)
		assert(string.find(text, "not a paid recovery service", 1, true), text)
		assert(string.find(text, "departure bag lies in Ossuary Galleries, near Hall of Plaques", 1, true), text)
		assert(string.find(text, "Recovering it yourself earns field experience", 1, true), text)
		assert(string.find(text, "at most once every 15 minutes", 1, true), text)
		assert(string.find(text, "but that earns none", 1, true), text)
		local plain = MissionRules.m11Objective("death", "R", "C")
		assert(not string.find(plain, "at most once", 1, true), plain)
	end)

	print("Finding 7: bounded progression record")
	local function count(t: { [any]: any }): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	test("live mission keys pay once per new n against a per-template high-water mark", function()
		local rec = Progression.normalize({})
		eq(Progression.grant(rec, MissionRules.missionXpKey("M01", 1), P.xp.mission), true)
		eq(Progression.grant(rec, "mission:M01:1", P.xp.mission), false, "same n")
		eq(Progression.grant(rec, "mission:M01:2", P.xp.mission), true)
		eq(Progression.grant(rec, "mission:M01:2", P.xp.mission), false)
		eq(Progression.grant(rec, "mission:M01:1", P.xp.mission), false, "a lower n")
		eq(Progression.grant(rec, "mission:M03:1", P.xp.mission), true, "templates are independent")
		eq(Progression.grant(rec, "mission:A2.rescue:1", P.xp.mission), true, "any template id")
		eq(rec.xp, 4 * P.xp.mission)
		eq(rec.missionPaid.M01, 2)
		eq(rec.missionPaid.M03, 1)
		eq(rec.missionPaid["A2.rescue"], 1)
		eq(count(rec.awarded), 0, "no per-completion keys are stored")
		eq(Progression.grant(rec, "mission:M01:3", 1e9), true)
		eq(rec.xp, 4 * P.xp.mission + Progression.MAX_GRANT, "one grant stays bounded")
		eq(Progression.grant(rec, "mission:M01:4", 0), false, "an invalid amount does not raise the mark")
		eq(rec.missionPaid.M01, 3)
	end)
	test("a record that skipped normalize still pays mission and bag keys", function()
		local rec: any = { xp = 0, awarded = {} }
		eq(Progression.grant(rec, "mission:M01:1", 10), true)
		eq(Progression.grant(rec, "bag:death:x", 5), true)
		eq(rec.xp, 15)
	end)
	test("back-fill pays completions above the mark once; live grants and re-syncs never double-pay", function()
		local facts: any = { discoveries = {}, research = {}, storyStates = { ["M01.completions"] = "3" } }
		local rec = Progression.normalize({})
		local awards = Progression.factAwards(P, facts, {}, {})
		eq(#awards, 1, "one award per template")
		eq(awards[1].key, "mission:M01:3")
		eq(awards[1].through, 3)
		eq(Progression.applyAwards(rec, awards), 3 * P.xp.mission)
		eq(Progression.applyAwards(rec, awards), 0, "re-sync adds nothing")
		-- the next completion (MissionService.payout: completions 4, then grantXp with key n = 4)
		facts.storyStates["M01.completions"] = "4"
		eq(Progression.grant(rec, MissionRules.missionXpKey("M01", 4), P.xp.mission), true)
		eq(Progression.applyAwards(rec, Progression.factAwards(P, facts, {}, {})), 0, "the live grant covered it")
		eq(rec.xp, 4 * P.xp.mission)
		-- the back-fill bound is unchanged: at most MAX_MISSION_BACKFILL completions per template
		local many: any = { discoveries = {}, research = {}, storyStates = { ["M02.completions"] = "9999" } }
		local r2 = Progression.normalize({})
		eq(Progression.applyAwards(r2, Progression.factAwards(P, many, {}, {})), 500 * P.xp.mission)
		eq(r2.missionPaid.M02, Progression.MAX_MISSION_BACKFILL)
		eq(Progression.grant(r2, "mission:M02:10000", P.xp.mission), true, "the next live completion pays once")
		eq(r2.xp, 501 * P.xp.mission)
	end)
	test("normalize folds older per-completion mission keys and bag keys, idempotently and without paying", function()
		local awarded: { [string]: boolean } = {
			["disc:R01.survey_board"] = true,
			["shelter:S01.worker_alcove"] = true,
			["mission:M03:2"] = true,
			["bag:death:death:A"] = true,
			["bag:logout:logout:B"] = true,
			["mission:M01:0"] = true, -- not a completion number: stays a plain key
		}
		for i = 1, 7 do
			awarded["mission:M01:" .. i] = true
		end
		local p: any = { progression = { xp = 321, awarded = awarded } }
		local rec = Progression.normalize(p)
		eq(rec.xp, 321, "folding pays nothing")
		eq(rec.missionPaid.M01, 7)
		eq(rec.missionPaid.M03, 2)
		eq(#rec.bagsPaid, 2)
		eq(rec.bagsPaid[1], "bag:death:death:A")
		eq(rec.bagsPaid[2], "bag:logout:logout:B")
		eq(count(rec.awarded), 3, "only one-off keys remain")
		assert(rec.awarded["disc:R01.survey_board"] and rec.awarded["shelter:S01.worker_alcove"], "kept")
		assert(rec.awarded["mission:M01:0"], "a malformed mission key stays where it was")
		local again = Progression.normalize(p)
		eq(again.missionPaid.M01, 7)
		eq(#again.bagsPaid, 2, "a second fold adds nothing")
		eq(count(again.awarded), 3)
		-- nothing already paid can be paid again
		eq(Progression.grant(rec, "mission:M01:7", 10), false)
		eq(Progression.grant(rec, "mission:M01:3", 10), false)
		eq(Progression.grant(rec, "bag:death:death:A", 5), false)
		local facts: any = { discoveries = {}, research = {}, storyStates = { ["M01.completions"] = "7" } }
		eq(Progression.applyAwards(rec, Progression.factAwards(P, facts, {}, {})), 0, "back-fill after the fold")
		eq(Progression.grant(rec, "mission:M01:8", 10), true, "the next completion pays")
		-- a legacy record that already paid more than the back-fill bound keeps its mark
		local big: { [string]: boolean } = {}
		for i = 1, 600 do
			big["mission:M05:" .. i] = true
		end
		local r3 = Progression.normalize({ progression = { xp = 6000, awarded = big } })
		eq(r3.missionPaid.M05, 600)
		local f3: any = { discoveries = {}, research = {}, storyStates = { ["M05.completions"] = "600" } }
		eq(Progression.applyAwards(r3, Progression.factAwards(P, f3, {}, {})), 0)
	end)
	test("bag keys pay once each and are remembered in a bounded FIFO", function()
		local rec = Progression.normalize({})
		eq(Progression.grant(rec, MissionRules.bagXpKey("death:death:1"), P.xp.bag), true)
		eq(Progression.grant(rec, "bag:death:death:1", P.xp.bag), false, "once per bag")
		for i = 2, 200 do
			eq(Progression.grant(rec, "bag:logout:logout:" .. i, P.xp.bag), true)
		end
		eq(#rec.bagsPaid, Progression.MAX_BAGS_PAID)
		eq(rec.bagsPaid[#rec.bagsPaid], "bag:logout:logout:200", "newest last")
		eq(Progression.grant(rec, "bag:logout:logout:200", P.xp.bag), false, "a remembered bag pays nothing")
		eq(count(rec.awarded), 0)
		eq(Progression.grant(rec, "bag:", P.xp.bag), true, "an empty bag id stays a plain one-off key")
		eq(Progression.grant(rec, "bag:", P.xp.bag), false)
	end)
	test("the saved record stays bounded however long someone plays", function()
		local p: any = Profile.default(9, "Explorer", "R00.depot")
		local rec = Progression.normalize(p)
		local templates = { "M01", "M02", "M03", "M05", "M07" }
		for n = 1, 4000 do
			for _, t in templates do
				Progression.grant(rec, MissionRules.missionXpKey(t, n), P.xp.mission)
			end
			Progression.grant(rec, MissionRules.bagXpKey("logout:logout:" .. n), P.xp.bag)
			if n % 500 == 0 then
				Progression.normalize(p)
			end
		end
		eq(count(rec.awarded), 0)
		eq(count(rec.missionPaid), #templates)
		eq(#rec.bagsPaid, Progression.MAX_BAGS_PAID)
		eq(rec.xp, 4000 * #templates * P.xp.mission + 4000 * P.xp.bag, "every new completion and bag paid once")
	end)

	print("Finding 8: the P06 puzzle record pays no place experience")
	local claims: { [string]: boolean } = {}
	for _, u in WorldDefs.UniquePickups do
		claims[u.discoveryId] = true
	end
	local function isClaim(id: string): boolean
		return claims[id] == true
	end
	-- Exactly how PlayerService builds the back-fill exclusion.
	local noPlace: { [string]: boolean } = table.clone(Discovery.PUZZLE_RECORDS)
	for id in claims do
		noPlace[id] = true
	end
	test("live grant and back-fill both exclude R05.p06_verified; its id is unchanged", function()
		eq(Discovery.PUZZLE_RECORDS["R05.p06_verified"], true)
		eq(Discovery.isPlaceDiscovery("R05.p06_verified", isClaim), false)
		eq(Progression.discoveryAward(P, "R05.p06_verified", noPlace), nil)
		local facts: any = {
			discoveries = { ["R05.p06_verified"] = true, ["R05.doorway_room"] = true },
			research = {},
			storyStates = {},
		}
		local awards = Progression.factAwards(P, facts, noPlace, {})
		eq(#awards, 1)
		eq(awards[1].key, "disc:R05.doorway_room")
		eq(Discovery.isPlaceDiscovery("R05.passage_pk1", isClaim), true, "pocket passages still pay")
	end)
	test("the live rule and the back-fill rule agree on every known discovery id", function()
		local ids: { string } = { "R05.p06_verified", "R05.passage_pk1", "R00.descent_ramp", "R00.mission_board" }
		for _, c in WorldDefs.Chambers do
			table.insert(ids, c.id)
		end
		for _, r in WorldDefs.Readables do
			table.insert(ids, r.id)
		end
		for id in claims do
			table.insert(ids, id)
		end
		for _, pz in WorldDefs.Puzzles do
			table.insert(ids, pz.id .. ".solved")
		end
		for _, id in ids do
			local live = Discovery.isPlaceDiscovery(id, isClaim)
			local backfill = Progression.discoveryAward(P, id, noPlace) ~= nil
			eq(backfill, live, id)
		end
	end)
end
