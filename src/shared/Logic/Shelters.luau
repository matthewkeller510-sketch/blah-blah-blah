--!strict
-- Private shelter improvements (section 13; owner rules F10, F11, F13).
-- Upgrades are stored per player as shelterId -> upgradeId -> stage (integer, monotonic).
-- Forming a party uses a monotonic union/max of compatible permanent upgrades, never a sum.
-- Inherited upgrades are persisted to each member and kept after leaving. Inheritance never creates items or coins.
-- Milestone 3: grant-only upgrades (station_power), data-driven interior visuals (entrance slots, functional props),
-- definition validation and the occupant regrouping rule used when parties change while players are inside.
-- Pure module.

export type UpgradeMap = { [string]: { [string]: number } } -- shelterId -> upgradeId -> stage

export type EntranceDef = { id: string, requiredUpgrade: string, requiredStage: number }

export type ShelterDef = {
	id: string,
	family: string,
	regionId: string,
	entrances: { EntranceDef },
	-- Safety upgrades and functional upgrades are separate definitions (section 13).
	safetyUpgrades: { [string]: { maxStage: number, costPerStage: { { [string]: number } } } },
	functionalUpgrades: { [string]: { maxStage: number, costPerStage: { { [string]: number } } } },
}

export type Fortification = "discovered" | "patched" | "secured"

local Shelters = {}

function Shelters.stage(map: UpgradeMap, shelterId: string, upgradeId: string): number
	local s = map[shelterId]
	return if s then (s[upgradeId] or 0) else 0
end

-- Raises a stage; stages never decrease. Returns true if the map changed.
function Shelters.raise(map: UpgradeMap, shelterId: string, upgradeId: string, stage: number): boolean
	local s = map[shelterId]
	if not s then
		s = {}
		map[shelterId] = s
	end
	if (s[upgradeId] or 0) >= stage then
		return false
	end
	s[upgradeId] = stage
	return true
end

-- Union/max across members. Returns the shared map; does not modify inputs.
function Shelters.union(maps: { UpgradeMap }): UpgradeMap
	local out: UpgradeMap = {}
	for _, m in maps do
		for shelterId, ups in m do
			for upId, stage in ups do
				Shelters.raise(out, shelterId, upId, stage)
			end
		end
	end
	return out
end

-- Applies a party union to one member's persistent map. Idempotent: repeated joins change nothing further.
-- Returns the number of (shelter, upgrade) pairs that were raised.
function Shelters.inherit(memberMap: UpgradeMap, shared: UpgradeMap): number
	local changed = 0
	for shelterId, ups in shared do
		for upId, stage in ups do
			if Shelters.raise(memberMap, shelterId, upId, stage) then
				changed += 1
			end
		end
	end
	return changed
end

-- Full security is a real rule: every entrance must meet its required upgrade stage.
function Shelters.fortification(def: ShelterDef, map: UpgradeMap): Fortification
	local met, anyProgress = 0, false
	for _, e in def.entrances do
		local s = Shelters.stage(map, def.id, e.requiredUpgrade)
		if s >= e.requiredStage then
			met += 1
		end
		if s > 0 then
			anyProgress = true
		end
	end
	if #def.entrances > 0 and met == #def.entrances then
		return "secured"
	end
	return if anyProgress then "patched" else "discovered"
end

function Shelters.isSecured(def: ShelterDef, map: UpgradeMap): boolean
	return Shelters.fortification(def, map) == "secured"
end

-- Cost of the next stage for an upgrade, or nil if maxed / unknown. Informational for grant-only upgrades.
function Shelters.nextCost(def: ShelterDef, map: UpgradeMap, upgradeId: string): ({ [string]: number }?, number?)
	local u = def.safetyUpgrades[upgradeId] or def.functionalUpgrades[upgradeId]
	if not u then
		return nil, nil
	end
	local cur = Shelters.stage(map, def.id, upgradeId)
	if cur >= u.maxStage then
		return nil, nil
	end
	return u.costPerStage[cur + 1], cur + 1
end

-- Grant-only upgrades are applied by an in-world repair, never bought from the shelter panel. Their cost row stays
-- informational (station_power: one fuse kit, consumed by the M04 private breaker repair). Once granted they are
-- ordinary permanent upgrades: the party union and inheritance treat them like any other (F13).
Shelters.GRANT_ONLY = {
	station_power = "Restored at the breaker cabinet inside this shelter (Power Restoration). Bring a repair tool roll; the repair uses one fuse kit.",
} :: { [string]: string }

function Shelters.isPurchasable(def: ShelterDef, upgradeId: string): boolean
	if Shelters.GRANT_ONLY[upgradeId] then
		return false
	end
	return def.safetyUpgrades[upgradeId] ~= nil or def.functionalUpgrades[upgradeId] ~= nil
end

-- What the panel's Build button may charge: nil for grant-only, maxed or unknown upgrades.
function Shelters.purchaseCost(def: ShelterDef, map: UpgradeMap, upgradeId: string): ({ [string]: number }?, number?)
	if not Shelters.isPurchasable(def, upgradeId) then
		return nil, nil
	end
	return Shelters.nextCost(def, map, upgradeId)
end

-- Interior visuals ------------------------------------------------------------------------------------
-- Functional upgrades with an interior prop, keyed by upgrade id. ShelterService builds and toggles these
-- generically for whatever functional upgrades a shelter defines (no hard-coded shelter or upgrade ids).
Shelters.FUNCTIONAL_VISUALS = {
	workbench = "Workbench",
	supply_shelves = "Shelves",
	better_lighting = "Lamp",
	station_power = "StationLamps",
} :: { [string]: string }

-- Which functional props are on (stage >= 1), for every functional upgrade the shelter defines.
function Shelters.functionalVisuals(def: ShelterDef, map: UpgradeMap): { [string]: boolean }
	local out = {}
	for id in def.functionalUpgrades do
		out[id] = Shelters.stage(map, def.id, id) >= 1
	end
	return out
end

export type EntranceLook = "open" | "patched" | "secured"

-- Entrance visual per stage: 0 = open vulnerability, partial = patched boards, >= required = solid and barred.
function Shelters.entranceLook(stage: number, requiredStage: number): EntranceLook
	if stage >= requiredStage then
		return "secured"
	end
	return if stage > 0 then "patched" else "open"
end

-- Interior wall slots for entrance visuals: entrances[i] is shown at slot i. `along` is the offset along the wall from
-- the room centre (z for W/E walls, x for N/S walls), `y` the height of the frame centre above the floor.
-- Slots 1-2 keep the Milestone 1-2 positions; 3-4 avoid the exit door, furniture and the breaker cabinet.
export type EntranceSlot = { wall: string, along: number, width: number, y: number }
Shelters.ENTRANCE_SLOTS = {
	{ wall = "W", along = 0, width = 8, y = 4.5 },
	{ wall = "N", along = 6, width = 4, y = 4 },
	{ wall = "N", along = -11, width = 4, y = 4 },
	{ wall = "S", along = 5.5, width = 4, y = 4 },
} :: { EntranceSlot }

-- Interior cell geometry shared with ShelterService (studs; offsets are from the cell origin, the floor centre).
export type Offset = { x: number, y: number, z: number }
Shelters.ROOM = { x = 28, y = 12, z = 22 } :: Offset

-- Centre of an entrance slot's frame, half a stud inside its wall. The entrance visuals are built here and the
-- unsecured-shelter probe aims at it.
function Shelters.slotOffset(slot: EntranceSlot): Offset
	local hx, hz = Shelters.ROOM.x / 2, Shelters.ROOM.z / 2
	if slot.wall == "W" then
		return { x = -hx + 0.5, y = slot.y, z = slot.along }
	elseif slot.wall == "E" then
		return { x = hx - 0.5, y = slot.y, z = slot.along }
	elseif slot.wall == "S" then
		return { x = slot.along, y = slot.y, z = -hz + 0.5 }
	end
	return { x = slot.along, y = slot.y, z = hz - 0.5 }
end

-- The probe (D14) damages only someone whose root is closer than this to an unprotected entrance.
Shelters.PROBE_RADIUS = 5
-- PROPOSED: where an arriving or respawning player's root is placed. It stays more than PROBE_RADIUS + 3 studs from
-- every entrance slot (tested), so arriving never counts as "standing right at" an unprotected entrance, even when a
-- party arrives together and jostles apart.
Shelters.ARRIVAL = { x = -4, y = 3, z = 0 } :: Offset

-- Definition problems that would break interiors or panels (empty when the def is sound). Checked by the tests for
-- every WorldDefs shelter and logged by ShelterService at start.
function Shelters.validate(def: ShelterDef, itemExists: ((string) -> boolean)?): { string }
	local problems = {}
	local function check(ok: boolean, msg: string)
		if not ok then
			table.insert(problems, def.id .. ": " .. msg)
		end
	end
	check(#def.entrances >= 1, "needs at least one entrance (it could never be secured)")
	check(#def.entrances <= #Shelters.ENTRANCE_SLOTS, "more entrances than interior slots")
	for _, e in def.entrances do
		local u = def.safetyUpgrades[e.requiredUpgrade]
		check(u ~= nil, "entrance " .. e.id .. " names no safety upgrade")
		check(u == nil or e.requiredStage <= u.maxStage, "entrance " .. e.id .. " requires a stage above max")
	end
	for _, group in { def.safetyUpgrades, def.functionalUpgrades } do
		for id, u in group do
			check(#u.costPerStage == u.maxStage, id .. " cost rows do not match its stages")
			for _, cost in u.costPerStage do
				for itemId, n in cost do
					check(n > 0, id .. " has a non-positive cost")
					check(itemExists == nil or itemExists(itemId), id .. " costs unknown item " .. itemId)
				end
			end
		end
	end
	for id in def.functionalUpgrades do
		check(def.safetyUpgrades[id] == nil, id .. " is both a safety and a functional upgrade")
		check(Shelters.FUNCTIONAL_VISUALS[id] ~= nil, id .. " has no interior visual")
	end
	for id in def.safetyUpgrades do
		check(Shelters.GRANT_ONLY[id] == nil, id .. " is grant-only but listed as safety")
	end
	return problems
end

-- Party membership changed while players are inside (F11, F13, T11): every occupant must sit in the cell of their
-- current group. Given the cell's key and each occupant's current key, returns the key the cell should carry and
-- the occupants that must move to another cell (occupant -> key). When nobody from the cell's own group is left, the
-- cell is handed to the largest remaining group whose key has no cell yet (ties by key), so a lone occupant is never
-- teleported needlessly.
function Shelters.regroup(
	cellKey: string,
	occupantKeys: { [any]: string },
	keyTaken: (string) -> boolean
): (string, { [any]: string })
	local groups: { [string]: number } = {}
	for _, k in occupantKeys do
		groups[k] = (groups[k] or 0) + 1
	end
	local keep = cellKey
	if groups[cellKey] == nil then
		local best: string?, bestN = nil, 0
		for k, n in groups do
			if not keyTaken(k) and (n > bestN or (n == bestN and best ~= nil and k < best)) then
				best, bestN = k, n
			end
		end
		if best then
			keep = best
		end
	end
	local moves: { [any]: string } = {}
	for p, k in occupantKeys do
		if k ~= keep then
			moves[p] = k
		end
	end
	return keep, moves
end

return Shelters
