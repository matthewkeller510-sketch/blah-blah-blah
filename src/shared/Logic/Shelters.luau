--!strict
-- Private shelter improvements (section 13; owner rules F10, F11, F13).
-- Upgrades are stored per player as shelterId -> upgradeId -> stage (integer, monotonic).
-- Forming a party uses a monotonic union/max of compatible permanent upgrades, never a sum.
-- Inherited upgrades are persisted to each member and kept after leaving. Inheritance never creates items or coins.
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

-- Cost of the next stage for an upgrade, or nil if maxed / unknown.
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

return Shelters
