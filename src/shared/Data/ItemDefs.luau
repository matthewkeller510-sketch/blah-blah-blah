--!strict
-- Item definitions (section 09). Stable IDs never change once shipped; display names may.
-- protected = survives death (F16, F21). Navigation items are protected regardless of source (F21, CONFIRMED).
-- The complete protection table must still be reviewed by the owner before release (section 15).
-- meshRef/iconRef are PLACEHOLDER labels; no external asset IDs are bound yet.

export type ItemDef = {
	id: string,
	displayName: string,
	category: "light" | "power" | "medical" | "tool" | "navigation" | "material" | "treasure" | "evidence" | "currency",
	stackLimit: number,
	protected: boolean,
	sellValue: number,
	-- Light
	beamRange: number?,
	beamAngle: number?,
	brightness: number?,
	drainPerSecond: number?,
	-- Power
	charge: number?,
	-- Medical
	healAmount: number?,
	treatSeconds: number?,
	removesInjury: boolean?,
	-- Tool
	stunCharges: number?,
	meleeDamage: number?,
	-- Unique claim (section 14: each participant claims their own copy)
	unique: boolean?,
	meshRef: string,
	iconRef: string,
	sound: string?,
}

local defs: { [string]: ItemDef } = {}

local function def(d: ItemDef)
	assert(defs[d.id] == nil, "duplicate item id " .. d.id)
	defs[d.id] = d
end

-- Light family (C01). Range, brightness and drain are separate stats.
def({
	id = "light.pocket_torch", displayName = "Battered Pocket Torch", category = "light",
	stackLimit = 1, protected = false, sellValue = 4,
	beamRange = 28, beamAngle = 45, brightness = 1.2, drainPerSecond = 0.6,
	meshRef = "PLACEHOLDER:C01/torch_small", iconRef = "PLACEHOLDER:icon/torch_small", sound = "equip_torch",
})
def({
	id = "light.expedition_flashlight", displayName = "Expedition Flashlight", category = "light",
	stackLimit = 1, protected = false, sellValue = 18,
	beamRange = 48, beamAngle = 35, brightness = 1.8, drainPerSecond = 0.9,
	meshRef = "PLACEHOLDER:C01/flashlight", iconRef = "PLACEHOLDER:icon/flashlight", sound = "equip_flashlight",
})

-- Power
def({
	id = "power.cell", displayName = "Replaceable Cell", category = "power",
	stackLimit = 6, protected = false, sellValue = 3, charge = 100,
	meshRef = "PLACEHOLDER:C01/cell", iconRef = "PLACEHOLDER:icon/cell",
})

-- Medical (fictional, game-oriented; no real medical instruction)
def({
	id = "med.cloth_dressing", displayName = "Cloth Dressing", category = "medical",
	stackLimit = 5, protected = false, sellValue = 2, healAmount = 15, treatSeconds = 3, removesInjury = false,
	meshRef = "PLACEHOLDER:C02/dressing", iconRef = "PLACEHOLDER:icon/dressing",
})
def({
	id = "med.bandage", displayName = "Proper Bandage", category = "medical",
	stackLimit = 5, protected = false, sellValue = 5, healAmount = 30, treatSeconds = 4, removesInjury = true,
	meshRef = "PLACEHOLDER:C02/bandage", iconRef = "PLACEHOLDER:icon/bandage",
})

-- Tools
def({
	id = "tool.stun_device", displayName = "Limited Stun Device", category = "tool",
	stackLimit = 1, protected = false, sellValue = 20, stunCharges = 3,
	meshRef = "PLACEHOLDER:C02/stun", iconRef = "PLACEHOLDER:icon/stun",
})
def({
	id = "tool.iron_bar", displayName = "Short Iron Bar", category = "tool",
	stackLimit = 1, protected = false, sellValue = 6, meleeDamage = 25,
	meshRef = "PLACEHOLDER:C02/bar", iconRef = "PLACEHOLDER:icon/bar",
})

-- Navigation (F09, F21: protected equally whether earned, found or purchased)
def({
	id = "nav.chalk", displayName = "Chalk Stick", category = "navigation",
	stackLimit = 50, protected = true, sellValue = 1,
	meshRef = "PLACEHOLDER:C03/chalk", iconRef = "PLACEHOLDER:icon/chalk",
})
def({
	id = "nav.sign", displayName = "Route Sign", category = "navigation",
	stackLimit = 10, protected = true, sellValue = 3,
	meshRef = "PLACEHOLDER:C03/sign_arrow", iconRef = "PLACEHOLDER:icon/sign_arrow",
})
def({
	id = "nav.rope", displayName = "Rope Coil (segment)", category = "navigation",
	stackLimit = 20, protected = true, sellValue = 2,
	meshRef = "PLACEHOLDER:C03/rope", iconRef = "PLACEHOLDER:icon/rope",
})

-- Crafting materials
def({
	id = "mat.fabric", displayName = "Recovered Fabric", category = "material",
	stackLimit = 20, protected = false, sellValue = 1,
	meshRef = "PLACEHOLDER:C04/fabric", iconRef = "PLACEHOLDER:icon/fabric",
})
def({
	id = "mat.fastener", displayName = "Fastening Material", category = "material",
	stackLimit = 20, protected = false, sellValue = 1,
	meshRef = "PLACEHOLDER:C04/fastener", iconRef = "PLACEHOLDER:icon/fastener",
})
def({
	id = "mat.plank", displayName = "Rough Plank", category = "material",
	stackLimit = 10, protected = false, sellValue = 1,
	meshRef = "PLACEHOLDER:C04/plank", iconRef = "PLACEHOLDER:icon/plank",
})
def({
	id = "mat.bracket", displayName = "Iron Brackets", category = "material",
	stackLimit = 10, protected = false, sellValue = 1,
	meshRef = "PLACEHOLDER:C04/bracket", iconRef = "PLACEHOLDER:icon/bracket",
})
def({
	id = "mat.chalk_fragment", displayName = "Chalk Fragments", category = "material",
	stackLimit = 30, protected = false, sellValue = 0,
	meshRef = "PLACEHOLDER:C04/chalk_frag", iconRef = "PLACEHOLDER:icon/chalk_frag",
})

-- Treasure / evidence (fictional)
def({
	id = "treasure.survey_tag", displayName = "Expedition Survey Tag", category = "treasure",
	stackLimit = 1, protected = false, sellValue = 25, unique = true,
	meshRef = "PLACEHOLDER:C04/survey_tag", iconRef = "PLACEHOLDER:icon/survey_tag",
})
def({
	id = "treasure.brass_rule", displayName = "Brass Measuring Rule", category = "treasure",
	stackLimit = 5, protected = false, sellValue = 12,
	meshRef = "PLACEHOLDER:C04/brass_rule", iconRef = "PLACEHOLDER:icon/brass_rule",
})

local ItemDefs = {}

function ItemDefs.get(id: string): ItemDef?
	return defs[id]
end

function ItemDefs.require(id: string): ItemDef
	local d = defs[id]
	assert(d, "unknown item id " .. tostring(id))
	return d
end

function ItemDefs.isProtected(id: string): boolean
	local d = defs[id]
	return d ~= nil and d.protected
end

function ItemDefs.all(): { [string]: ItemDef }
	return defs
end

return ItemDefs
