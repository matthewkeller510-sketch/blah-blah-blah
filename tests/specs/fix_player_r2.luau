--!strict
-- Review fixes, round 2, batch 5 (player, missions, recovery, navigation and saving). Pure rules only: nothing
-- here proves the Roblox services, prompts, holds, DataStore writes or replication work in Studio.
--   Findings 14, 16: a dead (or not-yet-respawned) body can never act, so it cannot recover its own new death bag.
--   Finding 15: a death inside a shelter interior cell leaves the bag outside that shelter's door.
--   Finding 17: full navigation lists are sent only when a viewer's list changed; record changes are paced per
--   viewer, party changes are not (D32).
--   Finding 18: revoking a user who was never authorized changes nothing (no save, no push).

local Config = require("../../src/shared/Data/Config")
local WorldDefs = require("../../src/shared/Data/WorldDefs")
local Vitals = require("../../src/shared/Logic/Vitals")
local PlayerRules = require("../../src/shared/Logic/PlayerRules")
local NavRecords = require("../../src/shared/Logic/NavRecords")
local RecoveryBags = require("../../src/shared/Logic/RecoveryBags")

local H = Config.Health

type V3 = PlayerRules.V3

local function dist(a: V3, b: V3): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- WorldBuilder.nearestChamber's rule (height differences weigh triple), for checking where a spot anchors.
local function nearestChamber(p: V3): any
	local best, bestD = nil, math.huge
	for _, c in WorldDefs.Chambers do
		local dx, dy, dz = c.pos.x - p.x, (c.pos.y + 3 - p.y) * 3, c.pos.z - p.z
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

-- WorldBuilder.shelterDoor's stand point (5 studs in from the door wall, 3 up).
local SIDES: { [string]: V3 } = {
	N = { x = 0, y = 0, z = 1 },
	S = { x = 0, y = 0, z = -1 },
	E = { x = 1, y = 0, z = 0 },
	W = { x = -1, y = 0, z = 0 },
}
local function standOf(shelterId: string): V3
	local sh = WorldDefs.Shelters[shelterId]
	local c = assert(WorldDefs.chamber(sh.exteriorChamberId))
	local dir = SIDES[sh.doorSide]
	local half = if dir.x ~= 0 then c.size.x / 2 else c.size.z / 2
	return { x = c.pos.x + dir.x * (half - 5), y = c.pos.y + 3, z = c.pos.z + dir.z * (half - 5) }
end

local function bagProfile(): RecoveryBags.BagProfile
	return { bags = {}, escrow = {}, appliedOps = {} }
end

local ANCHOR: RecoveryBags.Anchor =
	{ regionId = "R01", pocketVersion = 1, anchorId = "R01.survey_board", offset = { x = 0, y = 0, z = 0 } }

return function(T: any)
	local test, eq, near = T.test, T.eq, T.near

	print("Findings 14 and 16: a body waiting to respawn can never act")
	test("only an alive player who is neither downed nor dead can act", function()
		eq(PlayerRules.canAct(true, "healthy"), true)
		eq(PlayerRules.canAct(true, "injured"), true, "injured players still act")
		eq(PlayerRules.canAct(true, "downed"), false, "downed")
		eq(PlayerRules.canAct(true, "dead"), false, "dead")
		eq(PlayerRules.canAct(false, "dead"), false, "the respawn window")
		eq(PlayerRules.canAct(false, "healthy"), false, "before the character exists")
	end)
	test("the reported exploit: from the killing blow until the respawn, the body cannot recover anything", function()
		local v = Vitals.new(H)
		local alive = true
		eq(PlayerRules.canAct(alive, v.condition), true, "can act before the fight")
		Vitals.damage(H, v, v.max * 2, true) -- lethal while up: downed
		eq(PlayerRules.canAct(alive, v.condition), false, "downed: no holds, no recovery")
		Vitals.damage(H, v, 1, false) -- damage while downed: dead
		eq(v.condition, "dead")
		alive = false -- PlayerService.onDeath; the corpse lies on its own new death bag for the respawn delay
		eq(PlayerRules.canAct(alive, v.condition), false, "dead body, still on the bag")
		-- onCharacter: the new character is alive, at the last shelter
		alive = true
		Vitals.respawn(H, v)
		eq(PlayerRules.canAct(alive, v.condition), true, "after respawning: recover it by walking back")
	end)
	test("a Reset death outside Vitals is covered too (the Died handler marks the condition dead)", function()
		local v = Vitals.new(H)
		v.condition = "dead" -- PlayerService's h.Died handler
		v.health = 0
		eq(PlayerRules.canAct(true, v.condition), false, "even before alive is cleared")
	end)

	print("Finding 15: a death inside an interior cell leaves the bag outside that shelter's door")
	local origin = Config.Shelter.interiorCellOrigin
	local cellPos: V3 = { x = origin.x + 3, y = origin.y + 3, z = origin.z }
	local tunnel: V3 = { x = 30, y = 3, z = 120 } -- the last grounded tunnel point, far from any cell
	local depot: V3 = { x = 0, y = 60, z = 0 }
	test("reported case: a Reset in the Worker's Alcove cell anchors at the alcove, not the deepest region", function()
		local door = standOf("S01.worker_alcove")
		local spot = PlayerRules.deathBagSpot({
			position = cellPos,
			lastGrounded = tunnel,
			inCell = true,
			door = door,
			fallback = door,
		})
		eq(dist(spot, door), 0, "the door stand point")
		eq(nearestChamber(spot).id, "R01.alcove_exterior", "anchors to the shelter's own exterior chamber")
		eq(nearestChamber(cellPos).regionId == "R01", false, "the cell coordinate itself maps to a far chamber")
	end)
	test("every shelter's door stand anchors to its own exterior chamber", function()
		for id, sh in WorldDefs.Shelters do
			eq(nearestChamber(standOf(id)).id, sh.exteriorChamberId, id)
		end
	end)
	test("in a cell without a known shelter: the last grounded point, else the respawn point", function()
		local a =
			PlayerRules.deathBagSpot({ position = cellPos, lastGrounded = tunnel, inCell = true, fallback = depot })
		eq(dist(a, tunnel), 0)
		local b = PlayerRules.deathBagSpot({ position = cellPos, inCell = true, fallback = depot })
		eq(dist(b, depot), 0)
	end)
	test("in the tunnels the old rule is unchanged", function()
		local near30 = { x = tunnel.x + 20, y = tunnel.y, z = tunnel.z }
		local far = { x = tunnel.x + 40, y = tunnel.y, z = tunnel.z }
		local function spot(pos: V3?, grounded: V3?): V3
			return PlayerRules.deathBagSpot({
				position = pos,
				lastGrounded = grounded,
				inCell = false,
				fallback = depot,
			})
		end
		eq(dist(spot(near30, tunnel), tunnel), 0, "the last grounded point when the body lies near it")
		eq(dist(spot(far, tunnel), far), 0, "the body when it lies far from it")
		eq(dist(spot(far, nil), far), 0, "the body when nothing was grounded")
		eq(dist(spot(nil, tunnel), tunnel), 0, "the grounded point when the body is gone")
		eq(dist(spot(nil, nil), { x = 0, y = 0, z = 0 }), 0, "nothing known: the origin, as before")
	end)

	print("Finding 17: paced, change-only navigation lists")
	test("a list's signature depends on the owners present and their revisions only", function()
		local a = NavRecords.viewSignature({ { id = 1, rev = 4 }, { id = 2, rev = 9 } })
		eq(NavRecords.viewSignature({ { id = 2, rev = 9 }, { id = 1, rev = 4 } }), a, "order-independent")
		eq(NavRecords.viewSignature({ { id = 1, rev = 5 }, { id = 2, rev = 9 } }) == a, false, "a record changed")
		eq(NavRecords.viewSignature({ { id = 1, rev = 4 } }) == a, false, "a member left the party")
		eq(
			NavRecords.viewSignature({ { id = 1, rev = 4 }, { id = 2, rev = 9 }, { id = 3, rev = 1 } }) == a,
			false,
			"a member joined"
		)
		eq(
			NavRecords.viewSignature({ { id = 12, rev = 3 } }) == NavRecords.viewSignature({ { id = 1, rev = 23 } }),
			false
		)
	end)
	test("the gap between two lists to one viewer grows with the list and is bounded", function()
		eq(NavRecords.resendGap(0, 400, 0.25, 6), 0.25, "an empty list: the batching delay only")
		eq(NavRecords.resendGap(40, 400, 0.25, 6), 0.25, "a short list")
		near(NavRecords.resendGap(1200, 400, 0.25, 6), 3, 1e-9)
		eq(NavRecords.resendGap(2400, 400, 0.25, 6), 6, "the largest list (400 records x a party of 6)")
		eq(NavRecords.resendGap(1e6, 400, 0.25, 6), 6, "never more than the maximum")
	end)
	test(
		"the reported flood: six permission toggles a second for 60 s reach each viewer at most once per gap",
		function()
			-- One viewer seeing a party of 6 with 300 records each (1,800 entries). Every request changes a revision
			-- (the attacker alternates allow on/off); every flush tick compares signatures and the gap.
			local entries, perSecond, minGap, maxGap = 1800, 400, 0.25, 6
			local rev, sentSig, sentAt, lastCount = 0, "", -math.huge, 0
			local sends, sentEntries = 0, 0
			local t = 0
			while t < 60 do
				rev += 1 -- a request (6 a second)
				local sig = NavRecords.viewSignature({ { id = 1, rev = rev } })
				if t >= sentAt + NavRecords.resendGap(lastCount, perSecond, minGap, maxGap) and sig ~= sentSig then
					sends += 1
					sentEntries += entries
					sentSig, sentAt, lastCount = sig, t, entries
				end
				t += 1 / 6
			end
			eq(sends <= 1 + math.ceil(60 / NavRecords.resendGap(entries, perSecond, minGap, maxGap)), true, "paced")
			eq(
				sentEntries / 60 <= perSecond + entries / 60,
				true,
				"about the per-viewer budget, not 6 x 1,800 a second"
			)
			eq(sends < 60 * 6 / 10, true, "far fewer than one list per request")
		end
	)
	test("nothing changed: no list at all", function()
		local sig = NavRecords.viewSignature({ { id = 1, rev = 7 }, { id = 2, rev = 3 } })
		eq(NavRecords.viewSignature({ { id = 1, rev = 7 }, { id = 2, rev = 3 } }) ~= sig, false)
	end)
	test("a party change is told apart from a record change, so visibility is never paced (D32)", function()
		local before = NavRecords.ownerSetKey({ 1, 2, 3 })
		eq(NavRecords.ownerSetKey({ 3, 1, 2 }), before, "order-independent")
		eq(NavRecords.ownerSetKey({ 1, 2 }) == before, false, "a member left: their markers go at once")
		eq(NavRecords.ownerSetKey({ 1, 2, 3, 4 }) == before, false, "a member joined")
		eq(NavRecords.ownerSetKey({ 12, 3 }) == NavRecords.ownerSetKey({ 1, 23 }), false)
		-- a record change alone: the signature changes (a list is due) but the owner set does not (it is paced)
		local a = NavRecords.viewSignature({ { id = 1, rev = 4 }, { id = 2, rev = 9 } })
		local b = NavRecords.viewSignature({ { id = 1, rev = 5 }, { id = 2, rev = 9 } })
		eq(a == b, false, "sent")
		eq(NavRecords.ownerSetKey({ 1, 2 }), NavRecords.ownerSetKey({ 1, 2 }), "paced")
	end)

	print("Finding 18: a revoke that changes nothing reports it")
	test("revoking with no bag, or a user who was never authorized, returns false and changes nothing", function()
		local p = bagProfile()
		eq(RecoveryBags.revoke(p, "death", 2), false, "no bag")
		RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 1 }, ANCHOR, "op-r2-18", 0, { 2 })
		eq(RecoveryBags.revoke(p, "death", 3), false, "never authorized")
		eq((p.bags.death :: RecoveryBags.Bag).authorized["2"], true, "the real delegate is untouched")
		eq(RecoveryBags.revoke(p, "logout", 2), false, "no bag of that kind")
	end)
	test("revoking a delegate returns true once, and their access is gone", function()
		local p = bagProfile()
		RecoveryBags.create(p, "death", 1, { ["mat.fabric"] = 1 }, ANCHOR, "op-r2-18b", 0, { 2 })
		eq(RecoveryBags.revoke(p, "death", 2), true)
		eq(RecoveryBags.revoke(p, "death", 2), false, "a second revoke changes nothing")
		eq(RecoveryBags.recover(p, "death", 2, { ownerOnline = false }).reason, "not_authorized")
		eq(RecoveryBags.recover(p, "death", 1, { ownerOnline = true }).ok, true, "the owner keeps access")
	end)
end
