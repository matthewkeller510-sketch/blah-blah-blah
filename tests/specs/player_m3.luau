--!strict
-- Milestone 3 player package (docs/MILESTONE-3.md 4.7, 4.8): field experience, injury penalty, raised maxima
-- with the F18 half cap, the effective light predicate, lantern shield and moth factor, flare validation, and the
-- new crafting recipes. Pure rules only; nothing here proves the Roblox services or replication work.

local Config = require("../../src/shared/Data/Config")
local ItemDefs = require("../../src/shared/Data/ItemDefs")
local Stamina = require("../../src/shared/Logic/Stamina")
local Vitals = require("../../src/shared/Logic/Vitals")
local Inventory = require("../../src/shared/Logic/Inventory")
local Commerce = require("../../src/shared/Logic/Commerce")
local Progression = require("../../src/shared/Logic/Progression")
local PlayerRules = require("../../src/shared/Logic/PlayerRules")
local Story = require("../../src/shared/Logic/Story")
local Profile = require("../../src/shared/Logic/Profile")

local P = Config.Progression
local H = Config.Health
local S = Config.Stamina
local M = Config.Movement
local I = Config.Injury

local function lantern(): any
	return ItemDefs.require("light.shielded_lantern")
end

local function lightInput(over: { [string]: any }?): PlayerRules.LightInput
	local i: any = {
		switchedOn = true,
		def = ItemDefs.require("light.pocket_torch"),
		charge = 50,
		condition = "healthy",
		shielded = false,
		mothFactor = 1,
	}
	for k, v in (over or {}) :: { [string]: any } do
		i[k] = v
	end
	if i.def == false then
		i.def = nil -- "no held light" (a table literal cannot carry nil)
	end
	return i
end

local function flareInput(over: { [string]: any }?): PlayerRules.FlareInput
	local i: any = {
		alive = true,
		condition = "healthy",
		carried = false,
		hidden = false,
		inTunnel = true,
		inShelter = false,
		held = 3,
		lit = 0,
	}
	for k, v in (over or {}) :: { [string]: any } do
		i[k] = v
	end
	return i
end

local function sameInventory(a: any, b: any): boolean
	for id, e in a do
		local o = b[id]
		if not o or o.loadout ~= e.loadout or o.expedition ~= e.expedition then
			return false
		end
	end
	for id in b do
		if not a[id] then
			return false
		end
	end
	return true
end

return function(T: any)
	local test, eq, near = T.test, T.eq, T.near
	Commerce.bind(Inventory)
	local lookup = ItemDefs.get

	print("Progression (F24, T23, D37)")
	test("rank = floor(sqrt(xp / 50)) at and around every threshold", function()
		for _, c in { { 0, 0 }, { -10, 0 }, { 49, 0 }, { 50, 1 }, { 199, 1 }, { 200, 2 }, { 449, 2 }, { 450, 3 } } do
			eq(Progression.rank(P, c[1]), c[2], "rank of " .. c[1])
		end
		eq(Progression.rank(P, 1250), 5)
		eq(Progression.rank(P, 5000), 10)
		eq(Progression.rank(P, 0 / 0), 0, "NaN xp")
		for r = 0, 30 do
			eq(Progression.rank(P, Progression.xpForRank(P, r)), r, "exact threshold for rank " .. r)
			eq(Progression.rank(P, Progression.xpForRank(P, r) - 1), math.max(0, r - 1), "just below rank " .. r)
		end
	end)
	test("bonuses match the contract: rank 1 +2, rank 5 +8, rank 10 +12", function()
		eq(Progression.bonus(P.maxStaminaCap, P.decay, 0), 0)
		eq(Progression.bonus(P.maxStaminaCap, P.decay, 1), 2)
		eq(Progression.bonus(P.maxStaminaCap, P.decay, 5), 8)
		eq(Progression.bonus(P.maxStaminaCap, P.decay, 10), 12)
		eq(Progression.bonus(P.maxHealthCap, P.decay, 10), 12)
	end)
	test("bonuses are monotonic, show diminishing returns and never exceed the +15 cap", function()
		local prev = 0
		local prevGain = math.huge
		for r = 1, 400 do
			local b = Progression.bonus(P.maxStaminaCap, P.decay, r)
			assert(b >= prev, "monotonic at rank " .. r)
			assert(b <= P.maxStaminaCap and (r > 100 or b < P.maxStaminaCap), "never above the cap at rank " .. r)
			local exact = P.maxStaminaCap * (1 - P.decay ^ r)
			local gain = exact - P.maxStaminaCap * (1 - P.decay ^ (r - 1))
			assert(r > 60 or gain < prevGain, "each rank adds less than the one before")
			prev, prevGain = b, gain
		end
		local snap = Progression.snapshot(P, 1e12)
		assert(snap.staminaBonus <= P.maxStaminaCap and snap.healthBonus <= P.maxHealthCap, "huge xp stays capped")
	end)
	test("snapshot reports the current and next rank thresholds", function()
		local s = Progression.snapshot(P, 230)
		eq(s.rank, 2)
		eq(s.rankXp, 200)
		eq(s.nextRankXp, 450)
		eq(s.staminaBonus, Progression.bonus(P.maxStaminaCap, P.decay, 2))
		eq(s.healthBonus, Progression.bonus(P.maxHealthCap, P.decay, 2))
		eq(Progression.snapshot(P, -5).xp, 0)
	end)
	test("grant pays once per key; invalid keys or amounts pay nothing and keep the key free", function()
		local rec = { xp = 0, awarded = {} }
		eq(Progression.grant(rec, "disc:R01.survey_board", 5), true)
		eq(Progression.grant(rec, "disc:R01.survey_board", 5), false, "second grant")
		eq(Progression.grant(rec, "disc:R01.survey_board", 50), false, "a different amount is still the same key")
		eq(rec.xp, 5)
		eq(Progression.grant(rec, "", 5), false, "empty key")
		eq(Progression.grant(rec, 42, 5), false, "non-string key")
		eq(Progression.grant(rec, string.rep("k", 200), 5), false, "overlong key")
		eq(Progression.grant(rec, "story:A1.1", 0), false, "zero")
		eq(Progression.grant(rec, "story:A1.1", -3), false, "negative")
		eq(Progression.grant(rec, "story:A1.1", 0 / 0), false, "NaN")
		eq(Progression.grant(rec, "story:A1.1", math.huge), false, "infinite")
		eq(rec.awarded["story:A1.1"], nil, "a refused grant does not burn the key")
		eq(Progression.grant(rec, "story:A1.1", 25.9), true)
		eq(rec.xp, 30, "amounts are whole points")
		eq(Progression.grant(rec, "mission:M01:1", 1e9), true)
		eq(rec.xp, 30 + Progression.MAX_GRANT, "one grant is bounded")
	end)
	test("xp only ever grows and rank never decreases across grants", function()
		local rec = { xp = 0, awarded = {} }
		local lastRank = 0
		for i = 1, 300 do
			local before = rec.xp
			Progression.grant(rec, "k" .. (i % 120), (i % 7) + 1)
			assert(rec.xp >= before, "monotonic xp")
			local r = Progression.rank(P, rec.xp)
			assert(r >= lastRank, "monotonic rank")
			lastRank = r
		end
	end)
	test("discovery keys: places pay discovery, shelters pay shelter, item claims and puzzles pay nothing", function()
		local claims = { ["R01.found_survey_tag"] = true }
		local a = Progression.discoveryAward(P, "R01.survey_board", claims)
		assert(a, "place award")
		eq(a.key, "disc:R01.survey_board")
		eq(a.amount, P.xp.discovery)
		local sh = Progression.discoveryAward(P, "shelter:S01.worker_alcove", claims)
		assert(sh, "shelter award")
		eq(sh.key, "shelter:S01.worker_alcove", "same key the shelter package grants on registration")
		eq(sh.amount, P.xp.shelter)
		eq(Progression.discoveryAward(P, "R01.found_survey_tag", claims), nil, "item claim")
		eq(Progression.discoveryAward(P, "P01.solved", claims), nil, "puzzle record")
		eq(Progression.discoveryAward(P, "shelter:", claims), nil, "malformed shelter id")
		local readable = Progression.discoveryAward(P, "R04.thief_notes", claims)
		assert(readable and readable.key == "disc:R04.thief_notes", "R0x place ids pay")
	end)
	local function sampleFacts(): any
		return {
			discoveries = {
				["R01.survey_board"] = true,
				["R01.split_pier"] = true,
				["shelter:S01.worker_alcove"] = true,
				["R01.found_survey_tag"] = true,
				["P01.solved"] = true,
			},
			claims = {},
			research = { C07 = { stage = 3, evidence = {} }, C01 = { stage = 0, evidence = {} } },
			storyStates = { ["M01.completions"] = "2", onboarded = "1" },
			shelterUpgrades = {},
		}
	end
	test("fact awards use the shared key formats for every source", function()
		local f = sampleFacts()
		local claims = { ["R01.found_survey_tag"] = true }
		local ids = Progression.completedStepIds({ Story.ACT1 }, f)
		local awards = Progression.factAwards(P, f, claims, ids)
		local byKey: { [string]: number } = {}
		for _, a in awards do
			assert(byKey[a.key] == nil, "duplicate key " .. a.key)
			byKey[a.key] = a.amount
		end
		eq(byKey["disc:R01.survey_board"], P.xp.discovery)
		eq(byKey["disc:R01.split_pier"], P.xp.discovery)
		eq(byKey["shelter:S01.worker_alcove"], P.xp.shelter)
		eq(byKey["disc:R01.found_survey_tag"], nil)
		eq(byKey["disc:P01.solved"], nil)
		eq(byKey["research:C07:1"], P.xp.research)
		eq(byKey["research:C07:2"], P.xp.research)
		eq(byKey["research:C07:3"], P.xp.research)
		eq(byKey["research:C07:4"], nil)
		eq(byKey["research:C01:1"], nil)
		eq(byKey["story:A1.1"], P.xp.story, "A1.1 survey board")
		eq(byKey["story:A1.2"], P.xp.story, "A1.2 one rescue")
		eq(byKey["story:A1.3"], nil, "A1.3 not done")
		eq(byKey["mission:M01:1"], P.xp.mission)
		eq(byKey["mission:M01:2"], P.xp.mission)
		eq(byKey["mission:M01:3"], nil)
		for i = 2, #awards do
			assert(awards[i - 1].key < awards[i].key, "sorted, deterministic")
		end
	end)
	test("back-fill is idempotent and never double-pays a key a package granted live", function()
		local f = sampleFacts()
		local claims = { ["R01.found_survey_tag"] = true }
		local rec = { xp = 0, awarded = {} }
		-- live grants from the owning packages first (creatures, shelters)
		Progression.grant(rec, "research:C07:1", P.xp.research)
		Progression.grant(rec, "shelter:S01.worker_alcove", P.xp.shelter)
		local awards = Progression.factAwards(P, f, claims, Progression.completedStepIds({ Story.ACT1 }, f))
		local added = Progression.applyAwards(rec, awards)
		local expected = 2 * P.xp.discovery + P.xp.shelter + 3 * P.xp.research + 2 * P.xp.story + 2 * P.xp.mission
		eq(rec.xp, expected, "total equals one payment per fact")
		eq(added, expected - P.xp.research - P.xp.shelter, "back-fill added only the unpaid keys")
		eq(Progression.applyAwards(rec, awards), 0, "second back-fill adds nothing")
		eq(Progression.applyAwards(rec, awards), 0, "third back-fill adds nothing")
		eq(rec.xp, expected)
	end)
	test("story steps count in journal order; a later act only after the earlier act is complete", function()
		local f: any = sampleFacts()
		f.shelterUpgrades = { ["S01.worker_alcove"] = { gate_repair = 1 } }
		f.storyStates["M01.completions"] = nil -- A1.2 not done, A1.3 done out of order
		local ids = Progression.completedStepIds({ Story.ACT1 }, f)
		eq(#ids, 1, "stops at the first unfinished step")
		eq(ids[1], "A1.1")
		local act2 = { {
			id = "A2.1",
			done = function(_)
				return true
			end,
		} }
		eq(#Progression.completedStepIds({ Story.ACT1, act2 }, f), 1, "Act II waits for Act I")
		local all: any = sampleFacts()
		all.shelterUpgrades = { ["S01.worker_alcove"] = { gate_repair = 1 } }
		all.discoveries["R02.bone_gate"] = true
		all.claims["R02.unique.old_tag"] = true
		all.storyStates["A1.complete"] = "1"
		local done = Progression.completedStepIds({ Story.ACT1, act2 }, all)
		eq(#done, #Story.ACT1 + 1, "every Act I step plus Act II step 1")
		eq(done[#done], "A2.1")
		local broken = { {
			id = "X.1",
			done = function(_)
				error("bad predicate")
			end,
		} }
		eq(#Progression.completedStepIds({ broken }, all), 0, "a throwing predicate stops the scan safely")
	end)
	test("normalize repairs missing or damaged records; a fresh profile starts at rank 0", function()
		local p: any = {}
		local rec = Progression.normalize(p)
		eq(rec.xp, 0)
		assert(type(rec.awarded) == "table", "awarded table")
		local bad: any = { progression = { xp = -4, awarded = "x" } }
		local r2 = Progression.normalize(bad)
		eq(r2.xp, 0)
		assert(type(r2.awarded) == "table", "awarded repaired")
		local fresh = Profile.default(1, "Explorer", "R00.depot")
		eq(Progression.rank(P, Progression.normalize(fresh).xp), 0)
	end)
	test("no enemy stat reads rank: progression config holds only player-side values", function()
		for k in P :: any do
			assert(
				k == "rankDivisor" or k == "decay" or k == "maxStaminaCap" or k == "maxHealthCap" or k == "xp",
				"unexpected progression key " .. tostring(k)
			)
		end
	end)

	print("Raised maxima and the F18 half cap (T13)")
	test("a raised max health moves the passive cap to half of the new maximum", function()
		local v = Vitals.new(H)
		Vitals.setMax(H, v, H.max + 15)
		eq(v.max, 115)
		near(Vitals.passiveCap(H, v), 57.5, 1e-9)
		Vitals.damage(H, v, 90) -- 10 of 115
		for _ = 1, 600 do
			Vitals.step(H, v, 0.5, true)
		end
		near(v.health, 57.5, 1e-9, "passive recovery stops at half of the raised max")
	end)
	test("raising the max is no free heal; lowering it clamps; health above the cap is never reduced", function()
		local v = Vitals.new(H)
		Vitals.damage(H, v, 20) -- 80
		Vitals.setMax(H, v, 112)
		eq(v.health, 80, "no free heal")
		for _ = 1, 100 do
			Vitals.step(H, v, 1, true)
		end
		eq(v.health, 80, "above the cap stays put")
		Vitals.setMax(H, v, 60)
		eq(v.health, 60, "clamped to a lower max")
	end)
	test("respawn lands at half of the raised maximum; revive never exceeds the maximum", function()
		local v = Vitals.new(H)
		Vitals.setMax(H, v, 108)
		v.condition = "dead"
		Vitals.respawn(H, v)
		near(v.health, 54, 1e-9)
		local d = Vitals.new(H)
		Vitals.damage(H, d, 100)
		eq(d.condition, "downed")
		Vitals.revive(H, d, 500)
		eq(d.health, d.max, "revive clamps to max")
	end)
	test("a raised max stamina is honoured by regeneration, the bar and exhaustion recovery", function()
		local st = Stamina.new(S)
		eq(Stamina.maxOf(S, st), S.max)
		Stamina.setMax(S, st, S.max + 12)
		eq(st.value, S.max, "no free refill")
		eq(Stamina.shouldShowBar(S, st), true, "below the raised max shows the bar")
		for _ = 1, 100 do
			Stamina.step(S, st, 0.1, true, false, false)
		end
		near(st.value, S.max + 12, 1e-9, "regenerates to the new max")
		eq(Stamina.shouldShowBar(S, st), false)
		st.value, st.exhausted, st.sinceSprint = 0, true, 0
		local threshold = (S.max + 12) * S.exhaustionRecoverFraction
		while st.value < threshold - 0.5 do
			Stamina.step(S, st, 0.05, true, true, false)
			eq(st.exhausted, true, "still exhausted below the scaled threshold")
		end
		for _ = 1, 10 do
			Stamina.step(S, st, 0.05, true, false, false)
		end
		eq(st.exhausted, false)
		Stamina.setMax(S, st, 20)
		assert(st.value <= 20, "lowering clamps")
	end)

	print("Injury penalty (D40, F05)")
	local function speed(mode: string, injured: boolean, extra: { [string]: any }?): number
		local i: any = { mode = mode, downed = false, held = false, carrying = false, injured = injured }
		for k, v in (extra or {}) :: { [string]: any } do
			i[k] = v
		end
		return PlayerRules.moveSpeed(M, I, i)
	end
	test("walking and crouching are never slowed by an injury", function()
		eq(speed("walk", true), M.walkSpeed)
		eq(speed("walk", false), M.walkSpeed)
		eq(speed("idle", true), M.walkSpeed)
		eq(speed("crouch", true), M.crouchSpeed)
		eq(speed("walk", true, { carrying = true }), speed("walk", false, { carrying = true }))
	end)
	test("sprint is slowed while injured and still faster than walking", function()
		near(speed("sprint", true), M.sprintSpeed * I.sprintSpeedMultiplier, 1e-9)
		eq(speed("sprint", false), M.sprintSpeed)
		assert(speed("sprint", true) > M.walkSpeed, "injured sprint still beats walking")
	end)
	test("downed crawl and held states are unchanged by injury", function()
		eq(speed("walk", true, { downed = true }), PlayerRules.DOWNED_CRAWL_SPEED)
		eq(speed("sprint", true, { held = true }), 0)
	end)
	test("stamina regenerates more slowly while injured, within the documented clamp", function()
		local runner = Config.Classes.Runner.staminaRegenMultiplier
		local f = PlayerRules.regenFactors(runner, true, I)
		near(Stamina.regenMultiplier(S, { regen = f }), runner * I.staminaRegenMultiplier, 1e-9)
		local reuse = { 9, 9 }
		local out = PlayerRules.regenFactors(nil, false, I, reuse)
		assert(out == reuse, "writes into the reused table")
		eq(out[1], 1)
		eq(out[2], 1)
		local healthy, hurt = Stamina.new(S), Stamina.new(S)
		healthy.value, hurt.value = 10, 10
		healthy.sinceSprint, hurt.sinceSprint = 5, 5
		Stamina.step(S, healthy, 1, true, false, false, { regen = PlayerRules.regenFactors(1, false, I) })
		Stamina.step(S, hurt, 1, true, false, false, { regen = PlayerRules.regenFactors(1, true, I) })
		near(healthy.value - 10, S.regenPerSecond, 1e-9)
		near(hurt.value - 10, S.regenPerSecond * I.staminaRegenMultiplier, 1e-9)
	end)
	test("an injured, exhausted player is still granted walking (F05)", function()
		local st = Stamina.new(S)
		st.value, st.exhausted = 0, true
		local mode = Stamina.step(S, st, 0.1, true, true, false, { regen = PlayerRules.regenFactors(1, true, I) })
		eq(mode, "walk")
	end)
	test("a splint or bandage removes the injury; a dressing does not", function()
		local splint = ItemDefs.require("med.splint")
		local v = Vitals.new(H)
		Vitals.damage(H, v, 1, true)
		Vitals.applyMedical(H, v, 100, false) -- back to full health, still injured
		eq(v.injuryFlag, true)
		local dressing = ItemDefs.require("med.cloth_dressing")
		eq(
			Vitals.applyMedical(H, v, dressing.healAmount or 0, dressing.removesInjury == true),
			false,
			"dressing at full health is refused (item kept)"
		)
		eq(v.injuryFlag, true)
		eq(Vitals.applyMedical(H, v, splint.healAmount or 0, splint.removesInjury == true), true, "splint applies")
		eq(v.injuryFlag, false)
		eq(v.condition, "healthy")
		eq(speed("sprint", v.injuryFlag), M.sprintSpeed, "sprint restored once treated")
		local b = Vitals.new(H)
		Vitals.damage(H, b, 30, true)
		local bandage = ItemDefs.require("med.bandage")
		Vitals.applyMedical(H, b, bandage.healAmount or 0, bandage.removesInjury == true)
		eq(b.injuryFlag, false)
	end)
	test("the splint matches the contract (heal 5, removes injury, 4 s, stack 3, medical)", function()
		local d = ItemDefs.require("med.splint")
		eq(d.category, "medical")
		eq(d.healAmount, 5)
		eq(d.removesInjury, true)
		eq(d.treatSeconds, 4)
		eq(d.stackLimit, 3)
	end)

	print("Effective light, lantern shield and Wick Moth factor")
	test("lit only when switched on, a light is held, charge remains, and the player is up", function()
		eq(PlayerRules.lightIsOn(lightInput()), true)
		eq(PlayerRules.lightIsOn(lightInput({ switchedOn = false })), false, "switched off")
		eq(PlayerRules.lightIsOn(lightInput({ def = false })), false, "no held light")
		eq(PlayerRules.lightIsOn(lightInput({ charge = 0 })), false, "flat cell")
		eq(PlayerRules.lightIsOn(lightInput({ condition = "downed" })), false, "downed")
		eq(PlayerRules.lightIsOn(lightInput({ condition = "dead" })), false, "dead")
		eq(PlayerRules.lightIsOn(lightInput({ condition = "injured" })), true, "injured players keep their light")
	end)
	test("lightState: off means range 0; on reports item, lantern and effective range", function()
		local off = PlayerRules.lightState(lightInput({ charge = 0 }))
		eq(off.on, false)
		eq(off.range, 0)
		eq(off.itemId, "light.pocket_torch")
		local on = PlayerRules.lightState(lightInput())
		eq(on.on, true)
		eq(on.range, ItemDefs.require("light.pocket_torch").beamRange)
		eq(on.isLantern, false)
		eq(on.shielded, false)
		local none = PlayerRules.lightState(lightInput({ def = false }))
		eq(none.itemId, nil)
		eq(none.on, false)
	end)
	test("the lantern is omni and open by default; shielding shortens and dims it", function()
		local L = lantern()
		eq(L.lantern, true)
		assert((L.shieldedRange :: number) < (L.beamRange :: number), "shield radius below open radius")
		local open = PlayerRules.lightState(lightInput({ def = L }))
		eq(open.isLantern, true)
		eq(open.shielded, false)
		eq(open.range, 22)
		local shut = PlayerRules.lightState(lightInput({ def = L, shielded = true }))
		eq(shut.shielded, true)
		eq(shut.range, 9)
		assert(PlayerRules.lightBrightness(L, true) < PlayerRules.lightBrightness(L, false), "shielded is dimmer")
		local torch = PlayerRules.lightState(lightInput({ shielded = true }))
		eq(torch.shielded, false, "only a lantern can be shielded")
		eq(torch.range, ItemDefs.require("light.pocket_torch").beamRange)
	end)
	test("the moth factor multiplies the current range, composes with the shield, and 1 restores it", function()
		local L = lantern()
		local f = Config.Creatures.mothRangeFactor
		near(PlayerRules.lightState(lightInput({ def = L, mothFactor = f })).range, 22 * f, 1e-9)
		near(PlayerRules.lightState(lightInput({ def = L, mothFactor = f, shielded = true })).range, 9 * f, 1e-9)
		near(PlayerRules.lightState(lightInput({ mothFactor = f })).range, 28 * f, 1e-9)
		eq(PlayerRules.lightState(lightInput({ def = L, mothFactor = 1 })).range, 22, "reset to 1 is normal range")
		eq(PlayerRules.lightState(lightInput({ mothFactor = f, switchedOn = false })).range, 0)
	end)
	test("moth factors are validated and clamped: never removes the light, never boosts it", function()
		eq(PlayerRules.clampMothFactor("x"), nil)
		eq(PlayerRules.clampMothFactor(0 / 0), nil)
		eq(PlayerRules.clampMothFactor(0), PlayerRules.MOTH_FACTOR_MIN)
		eq(PlayerRules.clampMothFactor(-3), PlayerRules.MOTH_FACTOR_MIN)
		eq(PlayerRules.clampMothFactor(5), 1)
		eq(PlayerRules.clampMothFactor(0.4), 0.4)
		eq(PlayerRules.lightRange(lantern(), false, 99), 22, "lightRange clamps too")
	end)

	print("Flares")
	local MAX = Config.Flare.maxActivePerPlayer
	test("a flare can be placed by a standing player in the tunnels who holds one and is under the limit", function()
		local ok, why = PlayerRules.canPlaceFlare(flareInput(), MAX)
		eq(ok, true)
		eq(why, nil)
		eq((PlayerRules.canPlaceFlare(flareInput({ lit = MAX - 1 }), MAX)), true, "one below the limit")
	end)
	test("each refusal: dead, downed, carried, hidden, shelter, outside tunnels, none held, limit", function()
		local cases: { { any } } = {
			{ { alive = false }, "dead" },
			{ { condition = "dead" }, "dead" },
			{ { condition = "downed" }, "downed" },
			{ { carried = true }, "carried" },
			{ { hidden = true }, "hidden" },
			{ { inShelter = true }, "shelter" },
			{ { inTunnel = false }, "region" },
			{ { held = 0 }, "none" },
			{ { lit = MAX }, "limit" },
			{ { lit = MAX + 3 }, "limit" },
		}
		for _, c in cases do
			local ok, why = PlayerRules.canPlaceFlare(flareInput(c[1]), MAX)
			eq(ok, false, c[2])
			eq(why, c[2])
			if c[2] ~= "dead" then
				assert(type(PlayerRules.FLARE_REFUSALS[c[2]]) == "string", "explained to the player: " .. c[2])
			end
		end
	end)
	test("the flare matches the contract and is consumed expedition-first", function()
		local d = ItemDefs.require("tool.flare")
		eq(d.stackLimit, 5)
		eq(d.flareSeconds, 45)
		eq(d.flareRange, 18)
		eq(d.protected, false)
		local inv = Inventory.new()
		Inventory.add(inv, lookup, "tool.flare", 2, "loadout")
		Inventory.add(inv, lookup, "tool.flare", 1, "expedition")
		eq(Inventory.remove(inv, "tool.flare", 1), true)
		eq(inv["tool.flare"].expedition, 0, "expedition unit used first")
		eq(inv["tool.flare"].loadout, 2)
		eq(Inventory.add(inv, lookup, "tool.flare", 9, "expedition"), 3, "stack limit 5")
	end)
	test("lantern, flares and splints go to the death bag; story evidence stays (F16, D21)", function()
		local inv = Inventory.new()
		Inventory.add(inv, lookup, "light.shielded_lantern", 1, "loadout")
		Inventory.add(inv, lookup, "tool.flare", 2, "expedition")
		Inventory.add(inv, lookup, "med.splint", 1, "loadout")
		Inventory.add(inv, lookup, "evidence.station_tape", 1, "expedition")
		local out = Inventory.extractForDeath(inv, lookup)
		eq(out["light.shielded_lantern"], 1)
		eq(out["tool.flare"], 2)
		eq(out["med.splint"], 1)
		eq(out["evidence.station_tape"], nil)
		eq(Inventory.count(inv, "evidence.station_tape"), 1)
	end)

	print("Crafting (D19)")
	test("the three new recipes match the contract", function()
		local fk = Commerce.recipe("craft.fuse_kit")
		assert(fk, "fuse kit recipe")
		eq(fk.output, "tool.fuse_kit")
		eq(fk.inputs["mat.fuse_component"], 2)
		eq(fk.inputs["mat.fastener"], 1)
		local sp = Commerce.recipe("craft.splint")
		assert(sp, "splint recipe")
		eq(sp.output, "med.splint")
		eq(sp.inputs["mat.plank"], 1)
		eq(sp.inputs["mat.fabric"], 1)
		local rc = Commerce.recipe("craft.repaired_cell")
		assert(rc, "repaired cell recipe")
		eq(rc.output, "power.cell")
		eq(rc.inputs["mat.battery_housing"], 1)
		eq(rc.inputs["mat.fastener"], 1)
		for _, r in { fk, sp, rc } do
			eq(r.outputCount, 1)
			for id in r.inputs do
				assert(ItemDefs.get(id), "input exists " .. id)
			end
			assert(ItemDefs.get(r.output), "output exists")
		end
	end)
	test("each new recipe crafts atomically into loadout", function()
		for _, c in
			{
				{ "craft.fuse_kit", { ["mat.fuse_component"] = 3, ["mat.fastener"] = 1 }, "tool.fuse_kit" },
				{ "craft.splint", { ["mat.plank"] = 1, ["mat.fabric"] = 2 }, "med.splint" },
				{ "craft.repaired_cell", { ["mat.battery_housing"] = 1, ["mat.fastener"] = 2 }, "power.cell" },
			} :: { { any } }
		do
			local r = assert(Commerce.recipe(c[1]))
			local inv = Inventory.new()
			for id, n in c[2] :: { [string]: number } do
				Inventory.add(inv, lookup, id, n, "expedition")
			end
			local ok, why = Commerce.craft(inv, lookup, r, false)
			eq(ok, true, c[1] .. " " .. tostring(why))
			eq(Inventory.count(inv, c[3]), 1)
			eq(inv[c[3]].loadout, 1, "crafted output is loadout")
			for id, n in r.inputs do
				eq(Inventory.count(inv, id), (c[2] :: any)[id] - n, "consumed " .. id)
			end
		end
	end)
	test("insufficient materials or no room change nothing", function()
		local fk = assert(Commerce.recipe("craft.fuse_kit"))
		local inv = Inventory.new()
		Inventory.add(inv, lookup, "mat.fuse_component", 1, "loadout")
		Inventory.add(inv, lookup, "mat.fastener", 4, "expedition")
		local before = Inventory.clone(inv)
		local p = Commerce.preview(inv, lookup, fk, false)
		eq(p.canCraft, false)
		eq(p.missing["mat.fuse_component"], 1, "preview names the missing amount")
		local ok, why = Commerce.craft(inv, lookup, fk, false)
		eq(ok, false)
		eq(why, "insufficient")
		assert(sameInventory(inv, before), "unchanged after a refused craft")
		local rc = assert(Commerce.recipe("craft.repaired_cell"))
		local full = Inventory.new()
		Inventory.add(full, lookup, "power.cell", 6, "loadout")
		Inventory.add(full, lookup, "mat.battery_housing", 1, "loadout")
		Inventory.add(full, lookup, "mat.fastener", 1, "loadout")
		local snapshot = Inventory.clone(full)
		local ok2, why2 = Commerce.craft(full, lookup, rc, false)
		eq(ok2, false)
		eq(why2, "no_space")
		assert(sameInventory(full, snapshot), "unchanged when the output does not fit")
		local sp = assert(Commerce.recipe("craft.splint"))
		local splints = Inventory.new()
		Inventory.add(splints, lookup, "med.splint", 3, "loadout")
		Inventory.add(splints, lookup, "mat.plank", 1, "loadout")
		Inventory.add(splints, lookup, "mat.fabric", 1, "loadout")
		eq((Commerce.craft(splints, lookup, sp, false)), false, "splint stack of 3 is full")
	end)
	test("bag contents with a retired item id stay in the bag instead of throwing", function()
		local inv = Inventory.new()
		local left = Inventory.addContents(inv, lookup, { ["item.retired"] = 2, ["tool.flare"] = 1 }, "expedition")
		eq(left["item.retired"], 2)
		eq(left["tool.flare"], nil)
		eq(Inventory.count(inv, "tool.flare"), 1)
	end)
end
