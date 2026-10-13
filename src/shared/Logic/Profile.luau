--!strict
-- Versioned player profile (section 20). Temporary party state is NOT stored here.
-- See docs/SAVE-SCHEMA.md for the field-by-field description and migration plan.
-- Pure module.

export type Profile = {
	schemaVersion: number,
	userId: number,
	class: string,
	coins: number,
	inventory: { [string]: { loadout: number, expedition: number } },
	lightCharge: number, -- remaining charge of the equipped light's cell, 0..100
	equippedLight: string?,
	lastShelterId: string,
	shelterUpgrades: { [string]: { [string]: number } },
	discoveries: { [string]: boolean },
	claims: { [string]: boolean },
	storyStates: { [string]: string },
	research: { [string]: { stage: number, evidence: { [string]: boolean } } },
	charactersMet: { [string]: string }, -- npcId -> "encountered" | "rescued" | "understood"
	stats: { maxStaminaBonus: number, maxHealthBonus: number },
	nav: { pages: { [string]: { [string]: any } }, nextSeq: number },
	bags: { death: any?, logout: any? },
	escrow: { [string]: number },
	appliedOps: { string },
	receipts: { [string]: boolean },
	missionCooldowns: { [string]: number },
	toolCharges: { [string]: number },
	-- Durable expedition checkpoint (section 20): last valid grounded position for crash reconciliation.
	checkpoint: { regionId: string, pocketVersion: number, anchorId: string, offset: { x: number, y: number, z: number } }?,
	settings: { [string]: any },
}

local Profile = {}

Profile.CURRENT_VERSION = 1

function Profile.default(userId: number, defaultClass: string, startShelterId: string): Profile
	return {
		schemaVersion = Profile.CURRENT_VERSION,
		userId = userId,
		class = defaultClass,
		coins = 0,
		-- No free recurring handout (section 08). One-time starting kit only, PROPOSED in docs/DECISIONS.md D07.
		inventory = {
			["light.pocket_torch"] = { loadout = 1, expedition = 0 },
			["med.cloth_dressing"] = { loadout = 1, expedition = 0 },
			["nav.chalk"] = { loadout = 10, expedition = 0 },
		},
		lightCharge = 60,
		equippedLight = "light.pocket_torch",
		lastShelterId = startShelterId,
		shelterUpgrades = {},
		discoveries = {},
		claims = {},
		storyStates = {},
		research = {},
		charactersMet = {},
		stats = { maxStaminaBonus = 0, maxHealthBonus = 0 },
		nav = { pages = {}, nextSeq = 1 },
		bags = {},
		escrow = {},
		appliedOps = {},
		receipts = {},
		missionCooldowns = {},
		toolCharges = {},
		checkpoint = nil,
		settings = {},
	}
end

-- Ordered migrations: MIGRATIONS[n] upgrades a version-n profile to n+1.
local MIGRATIONS: { [number]: (any) -> () } = {
	-- [1] = function(p) ... p.schemaVersion = 2 end,
}

-- Fills missing fields from defaults without overwriting saved values, then applies migrations.
-- Returns (profile, error). A profile from a NEWER schema is refused so an old server never truncates it.
function Profile.reconcile(saved: any, userId: number, defaultClass: string, startShelterId: string): (Profile?, string?)
	local def = Profile.default(userId, defaultClass, startShelterId)
	if saved == nil then
		return def, nil
	end
	if type(saved) ~= "table" then
		return nil, "corrupt"
	end
	local v = saved.schemaVersion or 1
	if v > Profile.CURRENT_VERSION then
		return nil, "newer_schema"
	end
	while v < Profile.CURRENT_VERSION do
		local m = MIGRATIONS[v]
		if not m then
			return nil, "missing_migration_" .. v
		end
		m(saved)
		v += 1
		saved.schemaVersion = v
	end
	for k, dv in def :: any do
		if saved[k] == nil and k ~= "inventory" then
			saved[k] = dv
		end
	end
	if saved.inventory == nil then
		saved.inventory = {}
	end
	saved.userId = userId
	return saved :: Profile, nil
end

return Profile
