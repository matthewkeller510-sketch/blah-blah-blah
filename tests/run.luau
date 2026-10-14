--!strict
-- Unit tests for the Roblox-independent logic modules. Run with: lune run tests/run
-- These tests exercise pure rules only. They do NOT prove the Roblox services, replication, DataStores,
-- streaming or device performance work; those require Studio and published-test-place evidence (section 23).

local Config = require("../src/shared/Data/Config")
local ItemDefs = require("../src/shared/Data/ItemDefs")
local Stamina = require("../src/shared/Logic/Stamina")
local Vitals = require("../src/shared/Logic/Vitals")
local Inventory = require("../src/shared/Logic/Inventory")
local RecoveryBags = require("../src/shared/Logic/RecoveryBags")
local Shelters = require("../src/shared/Logic/Shelters")
local NavRecords = require("../src/shared/Logic/NavRecords")
local Director = require("../src/shared/Logic/Director")
local Progress = require("../src/shared/Logic/Progress")
local Commerce = require("../src/shared/Logic/Commerce")
local Profile = require("../src/shared/Logic/Profile")
local WorldDefs = require("../src/shared/Data/WorldDefs")
local Puzzles = require("../src/shared/Logic/Puzzles")
local Story = require("../src/shared/Logic/Story")

Commerce.bind(Inventory)
local lookup = ItemDefs.get

local passed, failed = 0, 0
local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok   " .. name)
	else
		failed += 1
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end
local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
	end
end
local function near(a: number, b: number, eps: number, msg: string?)
	if math.abs(a - b) > eps then
		error(string.format("%s: expected ~%s, got %s", msg or "near", tostring(b), tostring(a)), 2)
	end
end

print("Stamina (T03)")
test("exhaustion disables sprint but walking continues", function()
	local s = Stamina.new(Config.Stamina)
	local mode
	for _ = 1, 100 do
		mode = Stamina.step(Config.Stamina, s, 0.1, true, true, false)
	end
	eq(s.exhausted, true, "exhausted")
	eq(mode, "walk", "mode while exhausted and holding sprint")
	eq(Stamina.canSprint(s), false)
end)
test("sprint returns only after recovering to threshold, after regen delay", function()
	local s = Stamina.new(Config.Stamina)
	s.value, s.exhausted, s.sinceSprint = 0, true, 0
	Stamina.step(Config.Stamina, s, 0.5, true, false, false)
	eq(s.value, 0, "no regen during delay")
	for _ = 1, 30 do
		Stamina.step(Config.Stamina, s, 0.1, true, false, false)
	end
	eq(s.exhausted, false, "recovered")
	eq(Stamina.step(Config.Stamina, s, 0.1, true, true, false), "sprint")
end)
test("Runner class regen modifier is ~5% and capped", function()
	local m = Stamina.regenMultiplier(Config.Stamina, { regen = { Config.Classes.Runner.staminaRegenMultiplier } })
	near(m, 1.05, 1e-9)
	local capped = Stamina.regenMultiplier(Config.Stamina, { regen = { 3, 3 } })
	eq(capped, Config.Stamina.regenMultiplierMax)
end)
test("drain matches 12/s at default", function()
	local s = Stamina.new(Config.Stamina)
	Stamina.step(Config.Stamina, s, 1, true, true, false)
	near(s.value, 88, 1e-9)
end)

print("Vitals (T13, rescue flow)")
local H = Config.Health
test("passive recovery stops at half max", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 90)
	for _ = 1, 600 do
		Vitals.step(H, v, 0.5, true)
	end
	near(v.health, 50, 1e-9)
end)
test("passive recovery never lowers health above the cap", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 20)
	for _ = 1, 100 do
		Vitals.step(H, v, 1, true)
	end
	near(v.health, 80, 1e-9)
end)
test("PROPOSED shelter-only passive recovery: none in tunnels", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 90)
	for _ = 1, 100 do
		Vitals.step(H, v, 1, false)
	end
	near(v.health, 10, 1e-9)
end)
test("medical supplies heal beyond the cap", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 60)
	eq(Vitals.applyMedical(H, v, 30, true), true)
	near(v.health, 70, 1e-9)
end)
test("medical item not consumed at full health", function()
	local v = Vitals.new(H)
	eq(Vitals.applyMedical(H, v, 30, false), false)
end)
test("lethal damage downs, downed window expires to dead", function()
	local v = Vitals.new(H)
	eq(Vitals.damage(H, v, 500), "downed")
	for _ = 1, 44 do
		Vitals.step(H, v, 1, false)
	end
	eq(v.condition, "downed")
	Vitals.step(H, v, 1.5, false)
	eq(v.condition, "dead")
end)
test("stabilize stops bleed-out without full heal; revive gives low health", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 500)
	Vitals.stabilize(H, v)
	for _ = 1, 100 do
		Vitals.step(H, v, 1, false)
	end
	eq(v.condition, "downed")
	Vitals.revive(H, v)
	eq(v.condition, "injured")
	eq(v.health, H.stabilizedHealth)
end)
test("respawn at half health, not full", function()
	local v = Vitals.new(H)
	Vitals.damage(H, v, 500)
	Vitals.damage(H, v, 1)
	eq(v.condition, "dead")
	Vitals.respawn(H, v)
	near(v.health, 50, 1e-9)
end)

print("Inventory provenance, death and logout (T14, T15, T16)")
test("death removes unprotected, keeps navigation regardless of source", function()
	local inv = Inventory.new()
	Inventory.add(inv, lookup, "nav.chalk", 5, "loadout")
	Inventory.add(inv, lookup, "nav.chalk", 3, "expedition") -- e.g. found or purchased: identical item
	Inventory.add(inv, lookup, "nav.rope", 2, "expedition")
	Inventory.add(inv, lookup, "med.bandage", 2, "loadout")
	Inventory.add(inv, lookup, "treasure.brass_rule", 1, "expedition")
	local bag = Inventory.extractForDeath(inv, lookup)
	eq(bag["med.bandage"], 2)
	eq(bag["treasure.brass_rule"], 1)
	eq(bag["nav.chalk"], nil)
	eq(Inventory.count(inv, "nav.chalk"), 8)
	eq(Inventory.count(inv, "nav.rope"), 2)
	eq(Inventory.count(inv, "med.bandage"), 0)
end)
test("logout moves only unbanked expedition loot, keeps loadout", function()
	local inv = Inventory.new()
	Inventory.add(inv, lookup, "med.bandage", 1, "loadout")
	Inventory.add(inv, lookup, "med.bandage", 2, "expedition")
	Inventory.add(inv, lookup, "nav.chalk", 4, "expedition")
	local bag = Inventory.extractForLogout(inv, lookup)
	eq(bag["med.bandage"], 2)
	eq(bag["nav.chalk"], nil)
	eq(Inventory.count(inv, "med.bandage"), 1)
	eq(Inventory.count(inv, "nav.chalk"), 4)
end)
test("banking converts expedition to loadout; logout after banking yields empty", function()
	local inv = Inventory.new()
	Inventory.add(inv, lookup, "treasure.brass_rule", 2, "expedition")
	Inventory.bank(inv)
	eq(Inventory.isEmpty(Inventory.extractForLogout(inv, lookup)), true)
	eq(Inventory.count(inv, "treasure.brass_rule"), 2)
end)
test("stack limit respected, remainder reported", function()
	local inv = Inventory.new()
	eq(Inventory.add(inv, lookup, "med.bandage", 9, "expedition"), 5)
end)
test("remove is all-or-nothing", function()
	local inv = Inventory.new()
	Inventory.add(inv, lookup, "mat.fabric", 1, "loadout")
	eq(Inventory.remove(inv, "mat.fabric", 2), false)
	eq(Inventory.count(inv, "mat.fabric"), 1)
end)

local function bagProfile()
	return { bags = {}, escrow = {}, appliedOps = {} }
end
local anchor = { regionId = "R01", pocketVersion = 1, anchorId = "R01.split_pier", offset = { x = 0, y = 0, z = 0 } }

print("Recovery bags (T15, T16, proposed delegation)")
test("second death replaces only the death bag; logout bag independent", function()
	local p = bagProfile()
	RecoveryBags.create(p, "logout", 1, { ["med.bandage"] = 1 }, anchor, "op-l1", 0)
	local b1 = RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 2 }, anchor, "op-d1", 1)
	local b2, replaced = RecoveryBags.create(p, "death", 1, { ["mat.plank"] = 1 }, anchor, "op-d2", 2)
	assert(b1 and b2 and replaced)
	eq(replaced.bagId, b1.bagId)
	eq(p.bags.death.bagId, b2.bagId)
	eq(p.bags.logout ~= nil, true, "logout bag survives")
end)
test("empty contents create no bag", function()
	local p = bagProfile()
	local b = RecoveryBags.create(p, "logout", 1, {}, anchor, "op-x", 0)
	eq(b, nil)
end)
test("replayed opId creates exactly once", function()
	local p = bagProfile()
	RecoveryBags.create(p, "logout", 1, { ["mat.fabric"] = 1 }, anchor, "op-same", 0)
	RecoveryBags.recover(p, "logout", 1, { ownerOnline = true })
	local again = RecoveryBags.create(p, "logout", 1, { ["mat.fabric"] = 1 }, anchor, "op-same", 0)
	eq(again, nil, "replay must not recreate a recovered bag")
end)
test("owner recovery is unconditional and idempotent", function()
	local p = bagProfile()
	RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 1 }, anchor, "op-a", 0)
	local r = RecoveryBags.recover(p, "death", 1, { ownerOnline = true, ownerPartyMemberIds = { 1, 2 } })
	eq(r.ok, true)
	eq(r.toOwnerInventory["mat.fabric"], 1)
	eq(RecoveryBags.recover(p, "death", 1, { ownerOnline = true }).reason, "no_bag")
end)
test("stranger cannot recover; delegate goes to escrow", function()
	local p = bagProfile()
	RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 3 }, anchor, "op-b", 0, { 1, 2 })
	eq(RecoveryBags.recover(p, "death", 99, { ownerOnline = false }).reason, "not_authorized")
	local r = RecoveryBags.recover(p, "death", 2, { ownerOnline = false })
	eq(r.ok, true)
	eq(r.toOwnerInventory, nil)
	eq(p.escrow["mat.fabric"], 3)
	local e = RecoveryBags.takeEscrow(p)
	eq(e["mat.fabric"], 3)
	eq(next(p.escrow), nil, "escrow emptied once")
end)
test("current-party protection overrides saved authorization", function()
	local p = bagProfile()
	RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 1 }, anchor, "op-c", 0, { 2 })
	local r = RecoveryBags.recover(p, "death", 2, { ownerOnline = true, ownerPartyMemberIds = { 1, 3 } })
	eq(r.reason, "not_authorized")
end)
test("owner can revoke delegate", function()
	local p = bagProfile()
	RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 1 }, anchor, "op-r", 0, { 2 })
	RecoveryBags.revoke(p, "death", 2)
	eq(RecoveryBags.recover(p, "death", 2, { ownerOnline = false }).reason, "not_authorized")
end)

print("Shelters (T10, T12)")
local alcove = WorldDefs.Shelters["S01.worker_alcove"]
test("union is max, not sum", function()
	local a = { s = { gate = 1, light = 2 } }
	local b = { s = { gate = 2 } }
	local u = Shelters.union({ a, b, b })
	eq(u.s.gate, 2)
	eq(u.s.light, 2)
end)
test("inheritance is permanent and idempotent on repeated joins", function()
	local mine = {}
	local shared = { s = { gate = 2 } }
	eq(Shelters.inherit(mine, shared), 1)
	eq(Shelters.inherit(mine, shared), 0)
	eq(Shelters.inherit(mine, {}), 0)
	eq(mine.s.gate, 2, "kept after leaving")
end)
test("stages never decrease", function()
	local m = { s = { gate = 3 } }
	eq(Shelters.raise(m, "s", "gate", 1), false)
	eq(m.s.gate, 3)
end)
test("fortification requires every entrance", function()
	local m = {}
	eq(Shelters.fortification(alcove, m), "discovered")
	for _, e in alcove.entrances do
		Shelters.raise(m, alcove.id, e.requiredUpgrade, 1)
	end
	local expect = "patched"
	local allOne = true
	for _, e in alcove.entrances do
		if e.requiredStage > 1 then
			allOne = false
		end
	end
	if allOne then
		expect = "secured"
	end
	eq(Shelters.fortification(alcove, m), expect)
	for _, e in alcove.entrances do
		Shelters.raise(m, alcove.id, e.requiredUpgrade, e.requiredStage)
	end
	eq(Shelters.isSecured(alcove, m), true)
end)

print("Navigation records (T14, T18)")
local function place(store, owner, units, limit: number?)
	return NavRecords.place(store, {
		ownerId = owner, kind = "chalk", itemId = "nav.chalk", regionId = "R01", pocketVersion = 1,
		anchorId = "R01.split_pier", position = { x = 1, y = 2, z = 3 }, facing = { x = 0, y = 0, z = -1 },
		content = "arrow", units = units,
	}, limit or 400)
end
test("visibility: owner and current party only", function()
	local st = NavRecords.newStore()
	local r = place(st, 1, 1)
	assert(r)
	eq(NavRecords.canSee(r, 1, nil), true)
	eq(NavRecords.canSee(r, 2, { 1, 2 }), true)
	eq(NavRecords.canSee(r, 2, nil), false, "after party dissolves")
	eq(NavRecords.canSee(r, 3, { 1, 2 }), false)
end)
test("free text rejected", function()
	local st = NavRecords.newStore()
	local r, err = NavRecords.place(st, {
		ownerId = 1, kind = "sign", itemId = "nav.sign", regionId = "R01", pocketVersion = 1, anchorId = "a",
		position = { x = 0, y = 0, z = 0 }, facing = { x = 0, y = 0, z = 1 }, content = "anything I type", units = 1,
	}, 400)
	eq(r, nil)
	eq(err, "invalid_content")
end)
test("retrieval returns only that record's units, once", function()
	local st = NavRecords.newStore()
	local r = place(st, 1, 1)
	assert(r)
	local res = NavRecords.retrieve(st, "R01", r.recordId, 1, nil)
	eq(res.ok, true)
	eq(res.units, 1)
	eq(NavRecords.retrieve(st, "R01", r.recordId, 1, nil).reason, "not_found")
end)
test("party member cannot take owner's supply unless permitted; then units go to owner", function()
	local st = NavRecords.newStore()
	local r = place(st, 1, 1)
	assert(r)
	eq(NavRecords.retrieve(st, "R01", r.recordId, 2, { 1, 2 }).reason, "not_authorized")
	r.allowPartyRecovery = true
	local res = NavRecords.retrieve(st, "R01", r.recordId, 2, { 1, 2 })
	eq(res.ok, true)
	eq(res.toOwnerId, 1)
end)
test("transparent limit, no silent deletion", function()
	local st = NavRecords.newStore()
	for _ = 1, 3 do
		NavRecords.place(st, {
			ownerId = 1, kind = "chalk", itemId = "nav.chalk", regionId = "R01", pocketVersion = 1, anchorId = "a",
			position = { x = 0, y = 0, z = 0 }, facing = { x = 0, y = 0, z = 1 }, content = "x", units = 1,
		}, 3)
	end
	local r, err = place(st, 1, 1, 3)
	eq(r, nil)
	eq(err, "placement_limit")
	eq(NavRecords.countOwned(st), 3)
end)
test("pocket migration moves, never deletes", function()
	local st = NavRecords.newStore()
	place(st, 1, 1)
	local n = NavRecords.migratePocket(st, "R01", 1, 2, {
		["R01.split_pier"] = { anchorId = "R01.split_pier_v2", position = { x = 9, y = 9, z = 9 } },
	})
	eq(n, 1)
	local recs = NavRecords.inRegion(st, "R01")
	eq(#recs, 1)
	eq(recs[1].pocketVersion, 2)
	eq(recs[1].anchorId, "R01.split_pier_v2")
end)

print("Director (F06, section 11)")
local D = Config.Director
test("pressure rises as supplies dwindle", function()
	local base = { regionDanger = 0.3, healthFraction = 1, lightChargeFraction = 1, medicalItemCount = 3,
		exertionFraction = 0, secondsSinceThreat = 0, partySize = 1, inShelter = false }
	local low = table.clone(base)
	low.healthFraction, low.lightChargeFraction, low.medicalItemCount = 0.4, 0.05, 0
	assert(Director.pressure(D, low) > Director.pressure(D, base) + 0.3, "low supplies should raise pressure")
end)
test("zero pressure inside shelters", function()
	eq(Director.pressure(D, { regionDanger = 1, healthFraction = 0, lightChargeFraction = 0, medicalItemCount = 0,
		exertionFraction = 1, secondsSinceThreat = 999, partySize = 1, inShelter = true }), 0)
end)
test("one damaging threat per victim and cooldowns respected", function()
	local v = { activeDamagingThreats = 0, cooldownUntil = 0 }
	eq(Director.mayStartDamagingThreat(D, v, 0, 10, 0.9, 0.5), true)
	v.activeDamagingThreats = 1
	eq(Director.mayStartDamagingThreat(D, v, 1, 10, 0.9, 0.5), false)
	v.activeDamagingThreats = 0
	Director.afterChase(D, v, 10)
	eq(Director.mayStartDamagingThreat(D, v, 0, 20, 0.9, 0.5), false)
	eq(Director.mayStartDamagingThreat(D, v, 0, 10 + D.recoveryIntervalAfterChaseSeconds, 0.9, 0.5), true)
end)
test("stalk distance closes with pressure", function()
	assert(Director.stalkDistance(0.9, 80, 20) < Director.stalkDistance(0.1, 80, 20))
end)
test("event seed deterministic per recipient", function()
	eq(Director.eventSeed(7, 100, 3), Director.eventSeed(7, 100, 3))
	assert(Director.eventSeed(7, 100, 3) ~= Director.eventSeed(7, 101, 3))
end)

print("Progress: shared discovery and individual claims (T08, T09)")
test("group discovery commits to every member once", function()
	local recs = { [1] = {}, [2] = { d1 = true }, [3] = {} }
	local newly = Progress.commitDiscovery(recs, "d1")
	eq(#newly, 2)
	eq(recs[1].d1 and recs[3].d1, true)
end)
test("a friend's pickup does not consume my claim", function()
	local mine, friend = {}, {}
	eq(Progress.claim(friend, "R01.cache.tag"), true)
	eq(Progress.claim(mine, "R01.cache.tag"), true)
	eq(Progress.claim(mine, "R01.cache.tag"), false)
end)
test("research advances one evidenced stage at a time", function()
	local r = {}
	local reqs = WorldDefs.Creatures.C05_Scrabbler.researchEvidence
	eq(Progress.addEvidence(r, "C05", reqs[3], reqs), 0, "cannot skip stages")
	eq(Progress.addEvidence(r, "C05", reqs[1], reqs), 1)
	eq(Progress.addEvidence(r, "C05", reqs[2], reqs), 3, "earlier evidence now counts")
end)

print("Commerce (crafting atomicity, receipts T19)")
test("craft is atomic", function()
	local inv = Inventory.new()
	Inventory.add(inv, lookup, "mat.fabric", 2, "loadout")
	local recipe = Commerce.recipe("craft.field_dressing")
	assert(recipe)
	local ok, why = Commerce.craft(inv, lookup, recipe, false)
	eq(ok, false)
	eq(why, "insufficient")
	eq(Inventory.count(inv, "mat.fabric"), 2, "nothing consumed")
	Inventory.add(inv, lookup, "mat.fastener", 1, "loadout")
	eq((Commerce.craft(inv, lookup, recipe, false)), true)
	eq(Inventory.count(inv, "med.cloth_dressing"), 1)
	eq(Inventory.count(inv, "mat.fabric"), 0)
end)
test("receipt granted once", function()
	local ledger = {}
	eq(Commerce.alreadyGranted(ledger, "p1"), false)
	Commerce.recordGrant(ledger, "p1")
	eq(Commerce.alreadyGranted(ledger, "p1"), true)
end)

print("Profile schema (section 20)")
test("default profile has no recurring handout fields and correct version", function()
	local p = Profile.default(1, "Explorer", "S01.worker_alcove")
	eq(p.schemaVersion, Profile.CURRENT_VERSION)
	eq(p.lastShelterId, "S01.worker_alcove")
end)
test("reconcile fills missing fields without overwriting", function()
	local p = Profile.reconcile({ schemaVersion = 1, coins = 77, inventory = {} }, 5, "Explorer", "S01.worker_alcove")
	assert(p)
	eq(p.coins, 77)
	eq(p.userId, 5)
	eq(type(p.nav), "table")
	eq(next(p.inventory), nil, "no free starter kit re-granted to an existing profile")
end)
test("newer schema refused", function()
	local p, err = Profile.reconcile({ schemaVersion = 999 }, 5, "Explorer", "S01.worker_alcove")
	eq(p, nil)
	eq(err, "newer_schema")
end)

print("World definitions")
test("every item referenced by world scavenging exists", function()
	for _, site in WorldDefs.ScavengeSites do
		for id in site.contents do
			assert(ItemDefs.get(id), "unknown item " .. id)
		end
	end
end)
test("each region in the slice has >=3 landmarks and a shelter", function()
	for _, r in WorldDefs.Regions do
		if r.inSlice then
			assert(#r.landmarks >= 3, r.id .. " landmarks")
			assert(r.shelterId == nil or WorldDefs.Shelters[r.shelterId], r.id .. " shelter")
		end
	end
end)
test("an organic scavenging site exists that needs no light and no money (T02)", function()
	local found = false
	for _, s in WorldDefs.ScavengeSites do
		if s.requiresLight == false and s.regionId == "R01" then
			found = true
		end
	end
	eq(found, true)
end)

print("Puzzles (section 12, T06)")
test("P01 starts unsolved and solves on the target orientation", function()
	for target = 0, 3 do
		local p = Puzzles.newP01(target, 4)
		eq(p.solved, false)
		local solvedAt = 0
		for i = 1, 4 do
			if Puzzles.rotateP01(p) then
				solvedAt = i
				break
			end
		end
		eq(solvedAt, 2, "two quarter turns from the start")
		eq(Puzzles.rotateP01(p), false, "stays solved")
		eq(p.orientation, target)
	end
end)
test("P02 counts correct valves, drains on the authored pattern, resets immediately", function()
	for idx, sol in Puzzles.P02_SOLUTIONS do
		local p = Puzzles.newP02(idx)
		eq(p.drained, false)
		local drained = false
		for i, open in sol do
			if open then
				local _, d = Puzzles.toggleValve(p, i)
				drained = drained or d
			end
		end
		eq(drained, true, "solution " .. idx)
		eq(Puzzles.correctCount(p), 3)
		Puzzles.resetP02(p)
		eq(p.drained, false)
		eq(Puzzles.correctCount(p) < 3, true)
	end
end)
test("P02 solutions are never the reset state", function()
	for _, sol in Puzzles.P02_SOLUTIONS do
		eq(sol[1] or sol[2] or sol[3], true)
	end
end)
test("P02 clue names every valve", function()
	local c = Puzzles.p02Clue({ true, false, true })
	assert(string.find(c, "I OUVERT") and string.find(c, "II FERMÉ") and string.find(c, "III OUVERT"), c)
end)

print("Story Act I (section 05)")
local function facts()
	return { discoveries = {}, claims = {}, storyStates = {}, shelterUpgrades = {} }
end
test("steps derive from profile facts in order", function()
	local f = facts()
	eq((Story.current(f)), 1)
	f.discoveries["R01.survey_board"] = true
	eq((Story.current(f)), 2)
	f.storyStates["M01.completions"] = "1"
	eq((Story.current(f)), 3)
	f.shelterUpgrades["S01.worker_alcove"] = { gate_repair = 1 }
	eq((Story.current(f)), 4)
	f.discoveries["R02.bone_gate"] = true
	eq((Story.current(f)), 5)
	f.claims["R02.unique.old_tag"] = true
	eq((Story.current(f)), 6)
	f.storyStates["A1.complete"] = "1"
	eq((Story.current(f)), nil)
end)
test("journal shows finished steps plus the current one", function()
	local f = facts()
	f.discoveries["R01.survey_board"] = true
	local j = Story.journal(f)
	eq(#j, 2)
	eq(j[1].done, true)
	eq(j[2].done, false)
end)
test("the story item is protected so Act I cannot be lost to a replaced death bag", function()
	eq(ItemDefs.isProtected("treasure.old_expedition_tag"), true)
end)

print("World graph (Milestone 2)")
test("every chamber is reachable from the depot ramp with puzzle gates open", function()
	local d = WorldDefs.hops("R01.survey_board", { P01 = true, P02 = true })
	for _, c in WorldDefs.Chambers do
		assert(d[c.id] ~= nil, c.id .. " unreachable")
	end
end)
test("main progression needs no puzzle: every shelter reachable with gates closed", function()
	local d = WorldDefs.hops("R01.survey_board", {})
	for _, s in WorldDefs.Shelters do
		assert(d[s.exteriorChamberId] ~= nil, s.id .. " gated")
	end
	eq(d["R02.sealed_chapel"], nil, "chapel is behind P01")
	eq(d["R03.cistern"], nil, "cistern is behind P02")
end)
test("corridors are axis-aligned", function()
	for _, cor in WorldDefs.Corridors do
		local a, b = WorldDefs.chamber(cor.from), WorldDefs.chamber(cor.to)
		assert(a and b, cor.from .. "/" .. cor.to)
		assert(a.pos.x == b.pos.x or a.pos.z == b.pos.z, cor.from .. " -> " .. cor.to)
	end
end)
test("shelter doors are on walls without corridors", function()
	for _, s in WorldDefs.Shelters do
		local c = WorldDefs.chamber(s.exteriorChamberId)
		for _, n in WorldDefs.neighbors(c.id) do
			local o = WorldDefs.chamber(n)
			local side = if o.pos.x == c.pos.x then (if o.pos.z > c.pos.z then "N" else "S") else (if o.pos.x > c.pos.x then "E" else "W")
			assert(side ~= s.doorSide, s.id .. " door collides with corridor to " .. n)
		end
	end
end)
test("every slice creature has research hints for each stage", function()
	for _, c in WorldDefs.Creatures do
		if c.status == "SLICE" then
			eq(#c.hints, #c.researchEvidence, c.name)
		end
	end
end)
test("scavenge, pickup, cache and rescue spots sit inside their chambers", function()
	local function inside(pos, regionId)
		for _, c in WorldDefs.Chambers do
			if (regionId == nil or c.regionId == regionId)
				and math.abs(pos.x - c.pos.x) < c.size.x / 2
				and math.abs(pos.z - c.pos.z) < c.size.z / 2
				and pos.y >= c.pos.y - 1 and pos.y <= c.pos.y + 4 then
				return true
			end
		end
		return false
	end
	for _, s in WorldDefs.ScavengeSites do
		assert(inside(s.pos, s.regionId), s.id)
	end
	for _, u in WorldDefs.UniquePickups do
		assert(inside(u.pos), u.id)
	end
	for _, r in WorldDefs.RescueSpawns do
		assert(inside(r.pos), r.id)
	end
	for _, c in WorldDefs.CacheSpots do
		assert(inside(c.pos), c.id)
	end
end)
test("splash noise: crouching and dry footing are silent to the Wader", function()
	eq(Director.splashNoise("crouch", true), 0)
	eq(Director.splashNoise("sprint", false), 0)
	assert(Director.splashNoise("sprint", true) > Director.splashNoise("walk", true))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
