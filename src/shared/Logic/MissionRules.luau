--!strict
-- Pure mission rules (section 06; docs/MILESTONE-3.md 4.4; docs/MISSIONS.md). MissionService supplies world state
-- (gate state, inventories, bags) and applies the results; these functions decide offers, eligibility, rewards and
-- completion so they can be tested outside Roblox. Pure module: no requires, no Roblox globals.

export type V3 = { x: number, y: number, z: number }
export type Spot = { id: string, chamberId: string, pos: V3, clue: string? }
export type ChamberLike = { id: string, regionId: string, pos: V3, size: V3, label: string }
export type Inv = { [string]: { loadout: number, expedition: number } }
export type Facts = {
	discoveries: { [string]: boolean },
	storyStates: { [string]: string },
	shelterUpgrades: { [string]: { [string]: number } },
}
export type ShelterLike = {
	id: string,
	name: string,
	exteriorChamberId: string,
	safetyUpgrades: { [string]: any },
}
export type BagLike = { bagId: string, kind: string, anchor: { regionId: string, anchorId: string } }
export type SiteLike = { id: string, pos: V3, contents: { [string]: number } }

local MissionRules = {}

MissionRules.NEARBY_HOPS = 3 -- D28: "nearby" objectives sit within 3 corridors of the last shelter
MissionRules.OBSERVE_HOPS = 6 -- TUNE (PROPOSED): M07 only picks creatures whose home lies within 6 corridors
MissionRules.S04 = "S04.service_office"

-- Items an injured worker can be given, in the order the chooser lists them (M03).
MissionRules.MEDICAL_ITEMS = { "med.cloth_dressing", "med.bandage", "med.splint" }

-- M05 sluice-keeper's cache contents (each participant opens their own copy; expedition provenance).
MissionRules.M05_CACHE = { ["tool.flare"] = 1, ["med.bandage"] = 1, ["mat.battery_housing"] = 1 }

-- Research caps where the final stage needs features that are not built (D29: Sidelooker sketch comparison).
MissionRules.RESEARCH_CAPS = { C01 = 3 } :: { [string]: number }

-- Inactivity timeouts in seconds (TUNE). Templates not listed never time out (fact-based personal objectives).
MissionRules.TIMEOUTS = {
	M01 = 25 * 60,
	["A2.rescue"] = 25 * 60,
	M02 = 25 * 60,
	M03 = 25 * 60,
	M05 = 60 * 60,
	M07 = 25 * 60,
} :: { [string]: number }

-- Rescue-type templates share the M01 machinery (treat, escort or carry to any shelter).
function MissionRules.isRescue(template: string): boolean
	return template == "M01" or template == "A2.rescue"
end

-- Transparent per-player cooldowns, one source for every template (B15). `missions` is Config.Missions.
function MissionRules.cooldownSeconds(template: string, missions: { [string]: any }): number
	if template == "M01" then
		return missions.nearbyRescueCooldownSeconds or 120
	elseif template == "M02" then
		return 180 -- TUNE (Milestone 2 value)
	elseif template == "M03" then
		return missions.medicalDeliveryCooldownSeconds or 180
	elseif template == "M05" then
		return missions.waterworksCooldownSeconds or 300
	elseif template == "M07" then
		return 240 -- TUNE (Milestone 2 value)
	end
	return 0 -- M04, M09, M11 and story objectives: once-only rewards instead of cooldowns
end

-- Coins paid per participant on completion (TUNE; `missions` is Config.Missions). M11 pays none: a lost bag must
-- never make dying profitable. Story objectives pay through the story, not here.
function MissionRules.coinReward(template: string, missions: { [string]: any }, delivered: number?): number
	if template == "M01" then
		return missions.nearbyRescueRewardCoins or 40
	elseif template == "M02" then
		return 20 -- TUNE (Milestone 2 value)
	elseif template == "M03" then
		return MissionRules.deliveryReward(
			delivered or 0,
			missions.medicalDeliveryBaseCoins or 10,
			missions.medicalDeliveryCoinsPerItem or 10
		)
	elseif template == "M04" then
		return missions.powerRestorationCoins or 50
	elseif template == "M05" then
		return missions.waterworksCoins or 25
	elseif template == "M07" then
		return 30 -- TUNE (Milestone 2 value)
	elseif template == "M09" then
		return missions.shelterEstablishmentCoins or 40
	end
	return 0
end

function MissionRules.timesOut(template: string, state: string, idleSeconds: number): boolean
	local limit = MissionRules.TIMEOUTS[template]
	if not limit or idleSeconds <= limit then
		return false
	end
	if MissionRules.isRescue(template) then
		return state ~= "carried" -- a survivor on someone's back is never abandoned by the timer
	elseif template == "M07" then
		return state == "observe" -- research already gained is never taken back
	end
	return true
end

-- A non-participant may join a shared objective only as a current party member of its owner, with no other active
-- mission and no cooldown running for that template (fixes B1 and B3).
function MissionRules.canJoin(sameParty: boolean, hasOtherMission: boolean, cooldownReady: boolean): (boolean, string?)
	if not sameParty then
		return false, "party"
	elseif hasOtherMission then
		return false, "busy"
	elseif not cooldownReady then
		return false, "cooldown"
	end
	return true, nil
end

-- Chambers within `maxHops` corridors on the reachable graph (hops already honours closed gates).
function MissionRules.nearbySet(hops: { [string]: number }, maxHops: number): { [string]: boolean }
	local out = {}
	for id, d in hops do
		if d <= maxHops then
			out[id] = true
		end
	end
	return out
end

-- Spots an objective may use: in a nearby chamber, not used by another active mission, never inside a pocket.
function MissionRules.eligibleSpots(
	spots: { Spot },
	near: { [string]: boolean },
	busy: { [string]: boolean },
	pocketAt: (V3) -> any?
): { Spot }
	local out = {}
	for _, sp in spots do
		if near[sp.chamberId] and not busy[sp.id] and pocketAt(sp.pos) == nil then
			table.insert(out, sp)
		end
	end
	return out
end

local function count(inv: Inv, id: string): number
	local e = inv[id]
	return if e then e.loadout + e.expedition else 0
end

local function isMedicalDeliveryItem(id: string): boolean
	return table.find(MissionRules.MEDICAL_ITEMS, id) ~= nil
end

-- M03: what the player can hand over, with the most they can give of each in one delivery.
function MissionRules.deliveryOptions(inv: Inv, maxItems: number): { { itemId: string, have: number, max: number } }
	local out = {}
	for _, id in MissionRules.MEDICAL_ITEMS do
		local have = count(inv, id)
		if have > 0 then
			table.insert(out, { itemId = id, have = have, max = math.min(have, maxItems) })
		end
	end
	return out
end

-- M03 server validation of a `mission.deliver` payload. Reasons: "item", "count", "held".
function MissionRules.validateDelivery(inv: Inv, itemId: any, n: any, maxItems: number): (boolean, string?)
	if type(itemId) ~= "string" or not isMedicalDeliveryItem(itemId) then
		return false, "item"
	end
	if type(n) ~= "number" or n ~= n or n ~= math.floor(n) or n < 1 or n > maxItems then
		return false, "count"
	end
	if count(inv, itemId) < n then
		return false, "held"
	end
	return true, nil
end

function MissionRules.deliveryReward(n: number, base: number, perItem: number): number
	return base + perItem * n
end

-- The chamber whose box holds a position (floor-centre convention), or nil.
function MissionRules.chamberAt(chambers: { ChamberLike }, pos: V3): ChamberLike?
	for _, c in chambers do
		if
			math.abs(pos.x - c.pos.x) <= c.size.x / 2 + 1
			and math.abs(pos.z - c.pos.z) <= c.size.z / 2 + 1
			and pos.y >= c.pos.y - 2
			and pos.y <= c.pos.y + c.size.y
		then
			return c
		end
	end
	return nil
end

-- M03 with nothing to give: labels of the nearest reachable chambers whose scavenging sites can hold medical
-- items, nearest first (by corridor hops from `hops`' origin), at most `n`. Never a store.
function MissionRules.medicalSites(
	sites: { SiteLike },
	chambers: { ChamberLike },
	hops: { [string]: number },
	n: number
): { string }
	local found: { { label: string, d: number } } = {}
	local seen: { [string]: boolean } = {}
	for _, site in sites do
		local medical = false
		for id in site.contents do
			if string.sub(id, 1, 4) == "med." then
				medical = true
			end
		end
		local c = if medical then MissionRules.chamberAt(chambers, site.pos) else nil
		if c and hops[c.id] ~= nil and not seen[c.id] then
			seen[c.id] = true
			table.insert(found, { label = c.label, d = hops[c.id] })
		end
	end
	table.sort(found, function(a, b)
		return if a.d == b.d then a.label < b.label else a.d < b.d
	end)
	local out = {}
	for i = 1, math.min(n, #found) do
		table.insert(out, found[i].label)
	end
	return out
end

-- The objective line shown when a worker needs supplies the player does not carry (section 06: never demand a
-- purchase). It names places, not routes.
function MissionRules.nothingToGiveText(labels: { string }): string
	if #labels == 0 then
		return "You have nothing to give. Dressings, bandages and splints turn up in crates below; a shelter workbench can make dressings and splints."
	end
	return "You have nothing to give. Medical supplies have turned up near: "
		.. table.concat(labels, ", ")
		.. ". A shelter workbench can also make dressings and splints."
end

local function stage(f: Facts, shelterId: string, upgradeId: string): number
	local s = f.shelterUpgrades[shelterId]
	return if s then (s[upgradeId] or 0) else 0
end

-- M04 Power Restoration offer: registered S04 and its station supply not yet restored (or rewarded).
function MissionRules.m04Offer(f: Facts): (boolean, string?)
	if not f.discoveries["shelter:" .. MissionRules.S04] then
		return false, "Register the Reinforced Service Office in the Abandoned Survey Station first."
	end
	if f.storyStates["M04.reward"] == "1" then
		return false, "You already restored the station supply."
	end
	if stage(f, MissionRules.S04, "station_power") >= 1 or f.storyStates["M04.S04"] == "1" then
		return false, "The station supply in your service office already runs."
	end
	return true, nil
end

-- M04 completes on your own breaker repair (the shelters package sets storyStates["M04.S04"]) or when the
-- restored supply reaches you through the party upgrade union (F13) while the mission is active.
function MissionRules.m04Complete(f: Facts): boolean
	return f.storyStates["M04.S04"] == "1" or stage(f, MissionRules.S04, "station_power") >= 1
end

-- A shelter counts as established once any of its safety upgrades has reached stage 1 (M09).
function MissionRules.shelterEstablished(def: ShelterLike, upgrades: { [string]: { [string]: number } }): boolean
	local s = upgrades[def.id]
	if not s then
		return false
	end
	for upId in def.safetyUpgrades do
		if (s[upId] or 0) >= 1 then
			return true
		end
	end
	return false
end

function MissionRules.m09RewardKey(shelterId: string): string
	return "M09." .. shelterId
end

-- M09 candidates: known shelters (exterior chamber discovered), reachable now, not yet established and not yet
-- rewarded; nearest first.
function MissionRules.m09Candidates(
	f: Facts,
	shelters: { [string]: ShelterLike },
	hops: { [string]: number }
): { string }
	local out: { { id: string, d: number } } = {}
	for id, def in shelters do
		local d = hops[def.exteriorChamberId]
		if
			f.discoveries[def.exteriorChamberId]
			and d ~= nil
			and not MissionRules.shelterEstablished(def, f.shelterUpgrades)
			and f.storyStates[MissionRules.m09RewardKey(id)] ~= "1"
		then
			table.insert(out, { id = id, d = d })
		end
	end
	table.sort(out, function(a, b)
		return if a.d == b.d then a.id < b.id else a.d < b.d
	end)
	local ids = {}
	for _, e in out do
		table.insert(ids, e.id)
	end
	return ids
end

-- M09 completes when the shelter is registered (entered) and stage 1 of any safety upgrade is built.
function MissionRules.m09Complete(f: Facts, def: ShelterLike): boolean
	return f.discoveries["shelter:" .. def.id] == true and MissionRules.shelterEstablished(def, f.shelterUpgrades)
end

-- M05 is offered once the player has reached the Flooded Works (PROPOSED pacing gate).
function MissionRules.m05Offer(f: Facts): (boolean, string?)
	for _, id in { "R03.pump_gallery", "R03.silt_loop", "R03.sluice", "R03.pump_platform" } do
		if f.discoveries[id] then
			return true, nil
		end
	end
	return false, "Reach the Flooded Works first."
end

-- Per-participant claim inside one mission: true exactly once (F14: your own copy).
function MissionRules.claimOnce(collected: { [number]: boolean }, uid: number): boolean
	if collected[uid] then
		return false
	end
	collected[uid] = true
	return true
end

-- M11: the bag the journey targets (the death bag first: it is the one a later death would replace).
function MissionRules.m11Pick(bags: { death: BagLike?, logout: BagLike? }): BagLike?
	return bags.death or bags.logout
end

-- "pending" while the bag exists, "recovered" once the owner (or their escrow) emptied it, "replaced" when a newer
-- bag of the same kind took its slot (F16: only the latest death bag persists).
function MissionRules.m11Status(bags: { death: BagLike?, logout: BagLike? }, kind: string, bagId: string): string
	local cur: BagLike? = if kind == "death" then bags.death elseif kind == "logout" then bags.logout else nil
	if cur == nil then
		return "recovered"
	elseif cur.bagId == bagId then
		return "pending"
	end
	return "replaced"
end

function MissionRules.bagXpKey(bagId: string): string
	return "bag:" .. bagId
end

function MissionRules.m11Objective(kind: string, regionName: string, chamberLabel: string): string
	return string.format(
		"Your own journey, not a paid recovery service: your %s bag lies in %s, near %s. Recover it yourself, or let a party member move it to your shelter escrow.",
		if kind == "death" then "death" else "departure",
		regionName,
		chamberLabel
	)
end

function MissionRules.missionXpKey(template: string, n: number): string
	return "mission:" .. template .. ":" .. tostring(n)
end

function MissionRules.researchCap(def: { id: string, researchEvidence: { string }, [string]: any }): number
	local cap = def.researchCap
	if type(cap) == "number" then
		return cap
	end
	return MissionRules.RESEARCH_CAPS[def.id] or #def.researchEvidence
end

-- The chambers a creature can be met in, normalising the different `homes` shapes in WorldDefs (B8):
-- flat ids (C06), pairs of ids (C05), records with chamberId/lureChamberId (C02), `zones` (C03), `regionId` (C04),
-- `regions` (C08). Returns nil when the definition names no place (it may be met anywhere).
function MissionRules.creatureChambers(def: { [string]: any }, chambers: { ChamberLike }): { string }?
	local out: { [string]: boolean } = {}
	local any = false
	local function add(v: any)
		if type(v) == "string" then
			out[v] = true
			any = true
		elseif type(v) == "table" then
			if type(v.chamberId) == "string" then
				add(v.chamberId)
			end
			if type(v.lureChamberId) == "string" then
				add(v.lureChamberId)
			end
			for _, e in ipairs(v) do
				add(e)
			end
		end
	end
	add(def.homes)
	add(def.zones)
	local regions: { string } = {}
	if type(def.regionId) == "string" then
		table.insert(regions, def.regionId)
	end
	if type(def.regions) == "table" then
		for _, r in def.regions do
			if type(r) == "string" then
				table.insert(regions, r)
			end
		end
	end
	for _, c in chambers do
		if table.find(regions, c.regionId) then
			out[c.id] = true
			any = true
		end
	end
	if not any then
		return nil
	end
	local list = {}
	for id in out do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

-- M07 choices: built creatures whose research is below their cap and whose home is within reach (`reach` is the
-- set of chambers within OBSERVE_HOPS of the last shelter). Includes every SLICE creature automatically.
function MissionRules.m07Choices(
	creatures: { [string]: { [string]: any } },
	research: { [string]: { stage: number } },
	reach: { [string]: boolean },
	chambers: { ChamberLike }
): { { id: string, stage: number } }
	local out = {}
	for _, c in creatures do
		if c.status == "SLICE" then
			local st = research[c.id] and research[c.id].stage or 0
			if st < MissionRules.researchCap(c :: any) then
				local where = MissionRules.creatureChambers(c, chambers)
				local reachable = where == nil
				if where then
					for _, id in where do
						if reach[id] then
							reachable = true
							break
						end
					end
				end
				if reachable then
					table.insert(out, { id = c.id, stage = st })
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

return MissionRules
