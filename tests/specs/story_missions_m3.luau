--!strict
-- Package D (Milestone 3): Act II story spine, character dialogue selection, readables, the map-table rule, and the
-- mission rules for M03, M04, M05, M07, M09 and M11 (docs/MILESTONE-3.md 4.4-4.6). Pure logic only: nothing here
-- proves the Roblox services, prompts, rigs or replication work in Studio.

local Config = require("../../src/shared/Data/Config")
local WorldDefs = require("../../src/shared/Data/WorldDefs")
local ItemDefs = require("../../src/shared/Data/ItemDefs")
local StoryDefs = require("../../src/shared/Data/StoryDefs")
local Story = require("../../src/shared/Logic/Story")
local MissionRules = require("../../src/shared/Logic/MissionRules")

return function(T: any)
	local test, eq = T.test, T.eq

	local function facts(): any
		return { discoveries = {}, claims = {}, storyStates = {}, shelterUpgrades = {}, charactersMet = {} }
	end
	local function act1Done(): any
		local f = facts()
		f.discoveries["R01.survey_board"] = true
		f.storyStates["M01.completions"] = "1"
		f.shelterUpgrades["S01.worker_alcove"] = { gate_repair = 1 }
		f.discoveries["R02.bone_gate"] = true
		f.claims["R02.unique.old_tag"] = true
		f.storyStates["A1.complete"] = "1"
		return f
	end
	local function inv(t: { [string]: number }): any
		local out = {}
		for id, n in t do
			out[id] = { loadout = n, expedition = 0 }
		end
		return out
	end
	local function chamber(id: string): any
		return assert(WorldDefs.chamber(id), id)
	end

	print("Act II spine (section 05, MILESTONE-3 4.5)")
	test("Act II steps derive from facts in order after Act I", function()
		local f = act1Done()
		eq(Story.currentId(f), "A2.1")
		f.charactersMet.N02 = "encountered"
		eq(Story.currentId(f), "A2.2")
		f.storyStates["act2.noah_rescued"] = "1"
		eq(Story.currentId(f), "A2.3")
		f.claims["R03.unique.waterworks_log"] = true
		eq(Story.currentId(f), "A2.4")
		f.discoveries["shelter:S04.service_office"] = true
		eq(Story.currentId(f), "A2.5")
		f.storyStates["act2.radio_heard"] = "1"
		eq(Story.currentId(f), "A2.6")
		f.storyStates["act2.logs_compared"] = "1"
		eq(Story.currentId(f), "A2.7")
		f.storyStates["act2.complete"] = "1"
		eq(Story.currentId(f), "done")
		local act = Story.locate(f)
		eq(act, nil)
	end)
	test("Act II never starts before Act I is complete, even with Act II facts present", function()
		local f = facts()
		f.charactersMet.N02 = "encountered"
		f.storyStates["act2.noah_rescued"] = "1"
		f.storyStates["act2.radio_heard"] = "1"
		local act, i, step = Story.locate(f)
		eq((act :: any).id, "A1")
		eq(i, 1)
		eq((step :: any).id, "A1.1")
		f = act1Done()
		f.storyStates["A1.complete"] = nil
		eq(Story.currentId(f), "A1.6")
	end)
	test("Act I behaviour is unchanged: current() still covers Act I only", function()
		local f = act1Done()
		eq((Story.current(f)), nil)
		eq(#Story.journal(f), 6)
		eq(#Story.ACT1, 6)
		eq(#Story.ACT2, 7)
	end)
	test("the Act II step-4 fact is the discovery ShelterService records on registration", function()
		local f = act1Done()
		f.charactersMet.N02 = "encountered"
		f.storyStates["act2.noah_rescued"] = "1"
		f.claims["R03.unique.waterworks_log"] = true
		f.discoveries["S04.service_office"] = true -- the contract text's id; never written by the code
		eq(Story.currentId(f), "A2.4")
		f.discoveries["shelter:" .. "S04.service_office"] = true
		eq(Story.currentId(f), "A2.5")
	end)
	test("journal: earlier acts summarised, then finished steps plus the current one", function()
		local f = act1Done()
		f.charactersMet.N02 = "encountered"
		local j = Story.fullJournal(f)
		eq(j[1].id, "A1")
		eq(j[1].done, true)
		eq(j[2].id, "A2.1")
		eq(j[2].done, true)
		eq(j[3].id, "A2.2")
		eq(j[3].done, false)
		eq(#j, 3)
		for _, step in Story.ACT2 do
			assert(#step.journal > 0 and #step.objective > 0, step.id)
		end
	end)
	test("story step keys are stable, unique and ordered; xp only for steps completed in order", function()
		eq(#Story.STEP_IDS, 13)
		local seen = {}
		for _, id in Story.STEP_IDS do
			assert(not seen[id], "duplicate step id " .. id)
			seen[id] = true
		end
		eq(Story.STEP_IDS[1], "A1.1")
		eq(Story.STEP_IDS[7], "A2.1")
		eq(Story.xpKey("A2.3"), "story:A2.3")
		local f = facts()
		f.discoveries["R01.survey_board"] = true
		f.storyStates["act2.noah_rescued"] = "1" -- out of order: never credited early
		local done = Story.completedStepIds(f)
		eq(#done, 1)
		eq(done[1], "A1.1")
		f = act1Done()
		eq(#Story.completedStepIds(f), 6)
		eq(Story.reached(f, "A1.6"), true)
		eq(Story.reached(f, "A2.1"), false)
	end)

	test("every step predicate works on a raw profile (the player package back-fills with the profile)", function()
		local Profile = require("../../src/shared/Logic/Profile")
		local p: any = Profile.default(1, "Explorer", "R00.depot")
		for _, act in { Story.ACT1, Story.ACT2 } do
			for _, step in act do
				eq(step.done(p), false, step.id)
			end
		end
		p.discoveries["R01.survey_board"] = true
		p.storyStates["M01.completions"] = "1"
		p.shelterUpgrades["S01.worker_alcove"] = { gate_repair = 1 }
		p.discoveries["R02.bone_gate"] = true
		p.claims["R02.unique.old_tag"] = true
		p.storyStates["A1.complete"] = "1"
		p.charactersMet.N02 = "encountered"
		for _, step in Story.ACT1 do
			eq(step.done(p), true, step.id)
		end
		eq(Story.ACT2[1].done(p), true)
		eq(Story.currentId(p), "A2.2")
		local legacy: any = { discoveries = {}, claims = {}, storyStates = {}, shelterUpgrades = {} } -- no charactersMet
		eq(Story.ACT2[1].done(legacy), false)
	end)

	print("Map-table comparison (A2.6)")
	test("compare-logs rule: too early, missing records, ok, done", function()
		local f = facts()
		local r = Story.compareLogs(f, true, true)
		eq(r, "too_early")
		f = act1Done()
		local r2, missing = Story.compareLogs(f, false, false)
		eq(r2, "missing")
		eq(#missing, 2)
		local r3, missing3 = Story.compareLogs(f, true, false)
		eq(r3, "missing")
		eq(#missing3, 1)
		assert(string.find(missing3[1], "station tape"), missing3[1])
		eq((Story.compareLogs(f, true, true)), "ok")
		f.storyStates["act2.logs_compared"] = "1"
		eq((Story.compareLogs(f, false, false)), "done")
	end)
	test("the story records are unique, protected and never sold", function()
		for _, id in { "evidence.waterworks_log", "evidence.station_tape" } do
			local d = assert(ItemDefs.get(id))
			eq(d.protected, true, id)
			eq(d.unique, true, id)
			eq(d.sellValue, 0, id)
			assert(d.category ~= "treasure", id .. " must not appear in the treasure sell list")
		end
	end)
	test("the map table sits inside the Map Room, never in a pocket", function()
		local t = StoryDefs.MapTable
		local c = chamber(t.chamberId)
		assert(math.abs(t.pos.x - c.pos.x) + t.size.x / 2 <= c.size.x / 2, "table x")
		assert(math.abs(t.pos.z - c.pos.z) + t.size.z / 2 <= c.size.z / 2, "table z")
		eq(t.pos.y, c.pos.y)
		eq(WorldDefs.pocketAt(t.pos), nil)
	end)

	print("Characters and dialogue (4.6)")
	test("Moreau only sets the step-1 fact after Act I", function()
		local f = facts()
		local r = assert(Story.talk("N02", f, 0))
		eq(r.line, "before_act2")
		eq(r.met, nil)
		f = act1Done()
		r = assert(Story.talk("N02", f, 0))
		eq(r.line, "act2_tag")
		eq(r.met, "encountered")
		f.charactersMet.N02 = "encountered"
		f.storyStates["act2.noah_rescued"] = "1"
		f.claims["R03.unique.waterworks_log"] = true
		f.discoveries["shelter:S04.service_office"] = true
		f.storyStates["act2.radio_heard"] = "1"
		eq((assert(Story.talk("N02", f, 1))).line, "act2_compare")
		f.storyStates["act2.logs_compared"] = "1"
		local u = assert(Story.talk("N02", f, 2))
		eq(u.line, "act2_understood")
		eq(u.met, "understood")
	end)
	test("Noah has nothing to say (and is hidden) until you rescued him", function()
		local f = act1Done()
		eq(Story.talk("N06", f, 0), nil)
		f.storyStates["act2.noah_rescued"] = "1"
		f.charactersMet.N02 = "encountered"
		local r = assert(Story.talk("N06", f, 0))
		eq(r.line, "log_hint")
		eq(r.met, "rescued")
		f.claims["R03.unique.waterworks_log"] = true
		eq((assert(Story.talk("N06", f, 1))).line, "after")
	end)
	test("Amadou's hints follow the story; Ines greets with the crafting line once", function()
		local f = act1Done()
		f.charactersMet.N02 = "encountered"
		f.storyStates["act2.noah_rescued"] = "1"
		eq((assert(Story.talk("N04", f, 0))).line, "pumps")
		f.claims["R03.unique.waterworks_log"] = true
		f.discoveries["shelter:S04.service_office"] = true
		local p = assert(Story.talk("N04", f, 0))
		eq(p.line, "power")
		eq(p.met, "encountered")
		f.storyStates["act2.radio_heard"] = "1"
		local b = assert(Story.talk("N04", f, 0))
		eq(b.line, "breaker")
		eq(b.met, "understood")
		f.shelterUpgrades["S04.service_office"] = { station_power = 1 }
		eq((assert(Story.talk("N04", f, 0))).line, "barricades")
		eq((assert(Story.talk("N04", f, 1))).line, "sluice")
		eq((assert(Story.talk("N03", facts(), 0))).line, "greet")
		local again = facts()
		again.charactersMet.N03 = "encountered"
		eq((assert(Story.talk("N03", again, 3))).line, "again")
		eq((assert(Story.talk("N01", facts(), 0))).line, "greet")
		again.charactersMet.N01 = "encountered"
		local m = assert(Story.talk("N01", again, 1))
		eq(m.line, "objective")
		eq(m.appendObjective, true)
	end)
	test("every line Story.talk can choose exists in StoryDefs, and lines stay short", function()
		local ids = { "N01", "N02", "N03", "N04", "N06" }
		local states = { facts(), act1Done() }
		local full = act1Done()
		full.charactersMet = { N01 = "encountered", N02 = "encountered", N03 = "encountered" }
		full.storyStates["act2.noah_rescued"] = "1"
		full.storyStates["act2.logs_compared"] = "1"
		full.storyStates["act2.complete"] = "1"
		table.insert(states, full)
		for _, f in states do
			for _, id in ids do
				for visit = 0, 2 do
					local r = Story.talk(id, f, visit)
					if r then
						assert(StoryDefs.Lines[id][r.line], id .. "." .. r.line)
					end
				end
			end
		end
		for npc, lines in StoryDefs.Lines do
			for lineId, l in lines do
				assert(#l.lines >= 1 and #l.lines <= 4, npc .. "." .. lineId .. " line count")
				for _, text in l.lines do
					assert(#text <= 180, npc .. "." .. lineId .. " is too long to read quickly")
				end
			end
		end
		assert(StoryDefs.Lines.N05.radio_log.journal, "Elise's recording writes the journal")
		assert(StoryDefs.Lines.N03.greet.journal, "Ines's crafting line writes the journal")
	end)
	test("charactersMet only rises: encountered < rescued < understood", function()
		local m: { [string]: string } = {}
		eq(Story.raiseMet(m, "N06", "encountered"), true)
		eq(Story.raiseMet(m, "N06", "rescued"), true)
		eq(Story.raiseMet(m, "N06", "encountered"), false)
		eq(m.N06, "rescued")
		eq(Story.raiseMet(m, "N06", "understood"), true)
		eq(Story.raiseMet(m, "N06", "rescued"), false)
		eq(Story.raiseMet(m, "N02", "bogus"), false)
		eq(m.N02, nil)
	end)
	test("character figures stand at authored positions; Noah has a rescue spot in the Silt Works", function()
		for _, id in { "N01", "N02", "N03", "N04", "N06" } do
			assert(WorldDefs.Characters[id].pos, id .. " has no figure position")
		end
		eq(WorldDefs.Characters.N05.pos, nil, "Elise appears only in recordings")
		local rp = assert(WorldDefs.Characters.N06.rescuePos)
		eq(WorldDefs.pocketAt(rp), nil)
	end)

	print("Readables (C08 counter evidence)")
	test("every readable has text; the Lantern Thief note carries its counters", function()
		for _, r in WorldDefs.Readables do
			local t = StoryDefs.Readables[r.id]
			assert(t, "no text for " .. r.id)
			assert(#t.lines > 0 and #t.journal > 0 and #t.title > 0, r.id)
			eq(WorldDefs.pocketAt(r.pos), nil, r.id)
		end
		local note = assert(StoryDefs.Readables["R04.thief_notes"])
		local all = string.lower(table.concat(note.lines, " ") .. " " .. note.journal)
		assert(string.find(all, "rattle of glass") or string.find(all, "glass rattle"), "glass rattle")
		assert(string.find(all, "brightest light that is not its own"), "brightest light")
		assert(string.find(all, "flare"), "flare decoy")
		assert(string.find(all, "line of sight") or string.find(all, "breaking sight"), "break sight")
		eq(WorldDefs.Creatures.C08_LanternThief.counterEvidence, "R04.thief_notes")
	end)
	test("notes derive from facts: characters met, readables read, recordings heard", function()
		local f = act1Done()
		local rec = { radio = "R", revelation = "V" }
		eq(#Story.notes(f, StoryDefs.Readables, StoryDefs.CharacterNotes, rec), 0)
		f.charactersMet.N06 = "rescued"
		f.discoveries["R04.thief_notes"] = true
		f.storyStates["act2.radio_heard"] = "1"
		local n = Story.notes(f, StoryDefs.Readables, StoryDefs.CharacterNotes, rec)
		eq(#n, 3)
		eq(n[1].id, "met:N06")
		assert(string.find(n[1].text, "rescued"), n[1].text)
		eq(n[2].id, "read:R04.thief_notes")
		eq(n[3].text, "R")
	end)

	print("M03 Medical Delivery")
	test("reward is base + per item, capped by the max per delivery", function()
		local M = Config.Missions
		eq(MissionRules.deliveryReward(1, M.medicalDeliveryBaseCoins, M.medicalDeliveryCoinsPerItem), 20)
		eq(MissionRules.deliveryReward(3, M.medicalDeliveryBaseCoins, M.medicalDeliveryCoinsPerItem), 40)
		eq(MissionRules.coinReward("M03", M, 2), 30)
		eq(M.medicalDeliveryMaxItems, 3)
	end)
	test("delivery validation: only medical items, 1..max whole items, never more than held", function()
		local max = Config.Missions.medicalDeliveryMaxItems
		local i = inv({ ["med.bandage"] = 2, ["med.splint"] = 3, ["power.cell"] = 4 })
		eq((MissionRules.validateDelivery(i, "med.bandage", 2, max)), true)
		eq((MissionRules.validateDelivery(i, "med.splint", 3, max)), true)
		local ok, why = MissionRules.validateDelivery(i, "med.bandage", 3, max)
		eq(ok, false)
		eq(why, "held")
		ok, why = MissionRules.validateDelivery(i, "med.splint", 4, max)
		eq(why, "count")
		for _, bad in { 0, -1, 1.5, 0 / 0, math.huge } do
			ok, why = MissionRules.validateDelivery(i, "med.splint", bad, max)
			eq(ok, false, tostring(bad))
			eq(why, "count", tostring(bad))
		end
		ok, why = MissionRules.validateDelivery(i, "power.cell", 1, max)
		eq(why, "item")
		ok, why = MissionRules.validateDelivery(i, "med.cloth_dressing", 1, max)
		eq(why, "held")
		ok, why = MissionRules.validateDelivery(i, 42, 1, max)
		eq(why, "item")
		ok, why = MissionRules.validateDelivery(i, "med.bandage", "2", max)
		eq(why, "count")
	end)
	test("the chooser lists only held medical items with their deliverable maximum", function()
		local o = MissionRules.deliveryOptions(inv({ ["med.splint"] = 1, ["med.cloth_dressing"] = 5 }), 3)
		eq(#o, 2)
		eq(o[1].itemId, "med.cloth_dressing")
		eq(o[1].max, 3)
		eq(o[2].itemId, "med.splint")
		eq(o[2].max, 1)
		eq(#MissionRules.deliveryOptions(inv({ ["power.cell"] = 2 }), 3), 0)
	end)
	test("nothing to give: names nearby places with medical supplies, never a store", function()
		local hops = WorldDefs.hops("R04.station_hall", {})
		local labels = MissionRules.medicalSites(WorldDefs.ScavengeSites :: any, WorldDefs.Chambers :: any, hops, 2)
		eq(#labels, 2)
		eq(labels[1], "Survey Station Hall") -- the hall's own medical shelves come first
		local text = MissionRules.nothingToGiveText(labels)
		for _, banned in { "robux", "store", "shop", "buy", "purchase" } do
			assert(not string.find(string.lower(text), banned), "mentions " .. banned)
		end
		assert(string.find(text, "Survey Station Hall"), text)
		local empty = MissionRules.nothingToGiveText({})
		assert(not string.find(string.lower(empty), "robux"), empty)
		-- only sites with medical contents count
		local onlyFood = MissionRules.medicalSites(
			{ { id = "x", pos = { x = -84, y = -63, z = 930 }, contents = { ["mat.plank"] = 1 } } },
			WorldDefs.Chambers :: any,
			hops,
			2
		)
		eq(#onlyFood, 0)
	end)

	print("Mission spots and reachability")
	test("spot selection: near the last shelter, honours closed gates, never busy, never in a pocket", function()
		local hops = WorldDefs.hops(WorldDefs.homeChamber("S04.service_office"), {})
		local near = MissionRules.nearbySet(hops, MissionRules.NEARBY_HOPS)
		local spots = MissionRules.eligibleSpots(WorldDefs.MissionSpots.M03, near, {}, WorldDefs.pocketAt :: any)
		eq(#spots, 1)
		eq(spots[1].chamberId, "R04.station_hall")
		eq(
			#MissionRules.eligibleSpots(
				WorldDefs.MissionSpots.M03,
				near,
				{ [spots[1].id] = true },
				WorldDefs.pocketAt :: any
			),
			0
		)
		-- a spot inside a pocket is refused even when "near"
		local pk = WorldDefs.Pockets.PK1
		local inPocket = {
			{
				id = "test.pocket",
				chamberId = "R05.south_anchor",
				pos = {
					x = (pk.bounds.min.x + pk.bounds.max.x) / 2,
					y = -83,
					z = (pk.bounds.min.z + pk.bounds.max.z) / 2,
				},
			},
		}
		eq(#MissionRules.eligibleSpots(inPocket, { ["R05.south_anchor"] = true }, {}, WorldDefs.pocketAt :: any), 0)
		-- behind a closed gate: the cistern (P02) is unreachable until the pumps are routed
		local cistern = { { id = "test.cistern", chamberId = "R03.cistern", pos = { x = 6, y = -43, z = 820 } } }
		local s3 = WorldDefs.homeChamber("S03.pump_platform")
		local closed = MissionRules.nearbySet(WorldDefs.hops(s3, {}), 3)
		eq(#MissionRules.eligibleSpots(cistern, closed, {}, WorldDefs.pocketAt :: any), 0)
		local open = MissionRules.nearbySet(WorldDefs.hops(s3, { P02 = true }), 3)
		eq(#MissionRules.eligibleSpots(cistern, open, {}, WorldDefs.pocketAt :: any), 1)
	end)
	test("every M03 spot is reachable within 3 corridors of some shelter with gates closed", function()
		for _, sp in WorldDefs.MissionSpots.M03 do
			local ok = false
			for _, home in
				{
					"R01.survey_board",
					"R01.alcove_exterior",
					"R02.inspection_room",
					"R03.pump_platform",
					"R04.service_office",
					"R05.junction",
				}
			do
				local d = WorldDefs.hops(home, {})[sp.chamberId]
				if d and d <= 3 then
					ok = true
				end
			end
			assert(ok, sp.id .. " is not near any shelter")
		end
	end)

	print("M04 Power Restoration")
	test("offered only with S04 registered and no station power; completes on the breaker repair", function()
		local f = facts()
		eq((MissionRules.m04Offer(f)), false)
		f.discoveries["shelter:S04.service_office"] = true
		eq((MissionRules.m04Offer(f)), true)
		eq(MissionRules.m04Complete(f), false)
		f.storyStates["M04.S04"] = "1"
		eq(MissionRules.m04Complete(f), true)
		eq((MissionRules.m04Offer(f)), false)
		local g = facts()
		g.discoveries["shelter:S04.service_office"] = true
		g.shelterUpgrades["S04.service_office"] = { station_power = 1 } -- inherited through the party union (F13)
		eq((MissionRules.m04Offer(g)), false)
		eq(MissionRules.m04Complete(g), true)
		local h = facts()
		h.discoveries["shelter:S04.service_office"] = true
		h.storyStates["M04.reward"] = "1"
		eq((MissionRules.m04Offer(h)), false, "paid once ever")
		eq(MissionRules.cooldownSeconds("M04", Config.Missions), 0)
		eq(MissionRules.coinReward("M04", Config.Missions), Config.Missions.powerRestorationCoins)
	end)

	print("M05 Waterworks Passage")
	test("offered after reaching the Flooded Works; the vault is reachable by the dry route with W05 closed", function()
		local f = facts()
		eq((MissionRules.m05Offer(f)), false)
		f.discoveries["R03.silt_loop"] = true
		eq((MissionRules.m05Offer(f)), true)
		local closed = WorldDefs.hops("R03.pump_platform", {})
		assert(closed["R03.overflow_vault"] ~= nil, "dry route")
		local open = WorldDefs.hops("R03.pump_platform", { W05 = true })
		assert(open["R03.overflow_vault"] < closed["R03.overflow_vault"], "the loud sluice route is shorter")
		eq(WorldDefs.pocketAt(WorldDefs.MissionSpots.M05[1].pos), nil)
	end)
	test("each participant claims their own cache copy exactly once (F14)", function()
		local collected: { [number]: boolean } = {}
		eq(MissionRules.claimOnce(collected, 1), true)
		eq(MissionRules.claimOnce(collected, 1), false)
		eq(MissionRules.claimOnce(collected, 2), true, "one player's claim never uses up another's")
		local fresh: { [number]: boolean } = {} -- a new mission after the cooldown restocks the cache
		eq(MissionRules.claimOnce(fresh, 1), true)
		for id, n in MissionRules.M05_CACHE do
			assert(ItemDefs.get(id), id)
			eq(n, 1)
		end
		eq(MissionRules.cooldownSeconds("M05", Config.Missions), Config.Missions.waterworksCooldownSeconds)
	end)

	print("M09 Shelter Establishment")
	test("candidates: known, reachable, not established, not yet rewarded; nearest first", function()
		local f = facts()
		local hops = WorldDefs.hops("R04.service_office", {})
		eq(#MissionRules.m09Candidates(f, WorldDefs.Shelters :: any, hops), 0, "nothing known yet")
		f.discoveries["R04.service_office"] = true
		f.discoveries["R03.pump_platform"] = true
		local c = MissionRules.m09Candidates(f, WorldDefs.Shelters :: any, hops)
		eq(#c, 2)
		eq(c[1], "S04.service_office")
		f.shelterUpgrades["S04.service_office"] = { workbench = 1 } -- functional upgrades do not establish
		eq(#MissionRules.m09Candidates(f, WorldDefs.Shelters :: any, hops), 2)
		f.shelterUpgrades["S04.service_office"].duct_cover = 1
		c = MissionRules.m09Candidates(f, WorldDefs.Shelters :: any, hops)
		eq(#c, 1)
		eq(c[1], "S03.pump_platform")
		f.storyStates[MissionRules.m09RewardKey("S03.pump_platform")] = "1"
		eq(#MissionRules.m09Candidates(f, WorldDefs.Shelters :: any, hops), 0)
	end)
	test("completion needs registration and stage 1 of a safety upgrade", function()
		local def = WorldDefs.Shelters["S05.stable_junction"] :: any
		local f = facts()
		f.shelterUpgrades["S05.stable_junction"] = { fissure_fill = 1 }
		eq(MissionRules.m09Complete(f, def), false, "not registered")
		f.discoveries["shelter:S05.stable_junction"] = true
		eq(MissionRules.m09Complete(f, def), true)
		f.shelterUpgrades["S05.stable_junction"] = { better_lighting = 1 }
		eq(MissionRules.m09Complete(f, def), false, "functional only")
		eq(MissionRules.coinReward("M09", Config.Missions), Config.Missions.shelterEstablishmentCoins)
	end)

	print("M11 Lost Belongings")
	local function bag(kind: string, id: string): any
		return { bagId = id, kind = kind, anchor = { regionId = "R02", anchorId = "R02.plaque_hall" } }
	end
	test("offered for the death bag first, else the departure bag", function()
		eq(MissionRules.m11Pick({}), nil)
		eq((MissionRules.m11Pick({ logout = bag("logout", "l1") }) :: any).bagId, "l1")
		eq((MissionRules.m11Pick({ death = bag("death", "d1"), logout = bag("logout", "l1") }) :: any).bagId, "d1")
	end)
	test("completes when that bag is recovered; a replacing death fails it; never coins; xp once per bag", function()
		eq(MissionRules.m11Status({ death = bag("death", "d1") }, "death", "d1"), "pending")
		eq(MissionRules.m11Status({}, "death", "d1"), "recovered")
		eq(MissionRules.m11Status({ death = bag("death", "d2") }, "death", "d1"), "replaced")
		eq(MissionRules.m11Status({ death = bag("death", "d1") }, "logout", "l1"), "recovered")
		eq(MissionRules.coinReward("M11", Config.Missions), 0)
		eq(MissionRules.cooldownSeconds("M11", Config.Missions), 0)
		eq(MissionRules.bagXpKey("death:abc"), "bag:death:abc")
		assert(MissionRules.bagXpKey("d1") ~= MissionRules.bagXpKey("d2"), "a key per bag")
		eq(Config.Progression.xp.bag, 5)
		local text = MissionRules.m11Objective("death", "Ossuary Galleries", "Hall of Plaques")
		assert(string.find(text, "not a paid recovery service"), text)
		assert(string.find(text, "Hall of Plaques") and string.find(text, "Ossuary Galleries"), text)
	end)

	print("M07 and shared mission rules")
	test("M07 includes the new SLICE creatures when unfinished and within reach", function()
		local reachAll = {}
		for _, c in WorldDefs.Chambers do
			reachAll[c.id] = true
		end
		local ids = {}
		for _, ch in MissionRules.m07Choices(WorldDefs.Creatures :: any, {}, reachAll, WorldDefs.Chambers :: any) do
			ids[ch.id] = ch.stage
		end
		for _, id in { "C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08" } do
			eq(ids[id], 0, id .. " offered")
		end
		eq(ids.C09, nil, "PLANNED creatures are never offered")
		local research = { C01 = { stage = 3 }, C08 = { stage = 4 } }
		local again = {}
		for _, ch in MissionRules.m07Choices(WorldDefs.Creatures :: any, research, reachAll, WorldDefs.Chambers :: any) do
			again[ch.id] = true
		end
		eq(again.C01, nil, "Sidelooker capped at 3 (D29)")
		eq(again.C08, nil, "finished research")
		-- from the Worker's Alcove, the station and crossroads creatures are out of reach
		local near = MissionRules.nearbySet(WorldDefs.hops("R01.alcove_exterior", {}), MissionRules.OBSERVE_HOPS)
		local local1 = {}
		for _, ch in MissionRules.m07Choices(WorldDefs.Creatures :: any, {}, near, WorldDefs.Chambers :: any) do
			local1[ch.id] = true
		end
		eq(local1.C08, nil)
		eq(local1.C04, nil)
		eq(local1.C02, true, "the Borrowed Miner also works the East Workings")
	end)
	test("creature homes are normalised from every WorldDefs shape", function()
		local cs = WorldDefs.Chambers :: any
		local c05 = assert(MissionRules.creatureChambers(WorldDefs.Creatures.C05_Scrabbler, cs))
		assert(table.find(c05, "R02.ossuary_long"), "pairs")
		local c06 = assert(MissionRules.creatureChambers(WorldDefs.Creatures.C06_Wader, cs))
		assert(table.find(c06, "R03.cistern"), "flat")
		local c02 = assert(MissionRules.creatureChambers(WorldDefs.Creatures.C02_BorrowedMiner, cs))
		assert(table.find(c02, "R04.station_hall") and table.find(c02, "R01.collapsed_drift"), "records")
		local c03 = assert(MissionRules.creatureChambers(WorldDefs.Creatures.C03_WickMoth, cs))
		assert(table.find(c03, "R04.battery_store"), "zones")
		local c04 = assert(MissionRules.creatureChambers(WorldDefs.Creatures.C04_ChalkHand, cs))
		assert(table.find(c04, "R05.junction"), "regionId")
		eq(MissionRules.creatureChambers(WorldDefs.Creatures.C01_Sidelooker, cs), nil, "roams anywhere")
	end)
	test("late join needs the owner's current party, no other mission and no cooldown (B1, B3)", function()
		eq((MissionRules.canJoin(true, false, true)), true)
		local ok, why = MissionRules.canJoin(false, false, true)
		eq(ok, false)
		eq(why, "party")
		ok, why = MissionRules.canJoin(true, true, true)
		eq(why, "busy")
		ok, why = MissionRules.canJoin(true, false, false)
		eq(why, "cooldown")
	end)
	test("transparent cooldowns and timeouts", function()
		eq(MissionRules.cooldownSeconds("M01", Config.Missions), Config.Missions.nearbyRescueCooldownSeconds)
		eq(MissionRules.cooldownSeconds("M03", Config.Missions), Config.Missions.medicalDeliveryCooldownSeconds)
		eq(MissionRules.cooldownSeconds("M09", Config.Missions), 0)
		eq(MissionRules.cooldownSeconds("A2.rescue", Config.Missions), 0)
		eq(MissionRules.timesOut("M01", "carried", 99999), false, "never drops a carried survivor")
		eq(MissionRules.timesOut("M01", "ready", 25 * 60 + 1), true, "B10: stuck rescues end")
		eq(MissionRules.timesOut("A2.rescue", "treat", 25 * 60 + 1), true)
		eq(MissionRules.timesOut("M07", "return", 99999), false, "research already gained")
		eq(MissionRules.timesOut("M03", "deliver", 60), false)
		eq(MissionRules.timesOut("M05", "collect", 60 * 60 + 1), true)
		for _, t in { "M04", "M09", "M11" } do
			eq(MissionRules.timesOut(t, "work", 1e9), false, t)
		end
		eq(MissionRules.missionXpKey("M03", 4), "mission:M03:4")
		eq(MissionRules.coinReward("A2.rescue", Config.Missions), 0)
		eq(MissionRules.isRescue("A2.rescue"), true)
		eq(MissionRules.isRescue("M03"), false)
	end)
	test("every built mission template has an estimate and a risk", function()
		for _, id in { "M03", "M04", "M05", "M09", "M11" } do
			local d = WorldDefs.Missions[id]
			eq(d.status, "SLICE", id)
			assert(d.estimate and d.risk, id)
		end
	end)
end
