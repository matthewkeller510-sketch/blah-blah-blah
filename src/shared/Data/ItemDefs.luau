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
	-- Lantern (omni light that supports a group and exposes its carrier; shield mode is dim and draws no moths)
	lantern: boolean?,
	shieldedRange: number?,
	-- Tool
	stunCharges: number?,
	meleeDamage: number?,
	flareSeconds: number?, -- a placed flare burns this long
	flareRange: number?,
	reusable: boolean?, -- a tool that is required but never consumed (repair tool roll)
	-- Unique claim (section 14: each participant claims their own copy)
	unique: boolean?,
	-- Short inventory text (fictional and game-oriented; no real medical instruction). Panels falls back to its own.
	description: string?,
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
	id = "light.pocket_torch",
	displayName = "Battered Pocket Torch",
	category = "light",
	stackLimit = 1,
	protected = false,
	sellValue = 4,
	beamRange = 28,
	beamAngle = 45,
	brightness = 1.2,
	drainPerSecond = 0.6,
	meshRef = "PLACEHOLDER:C01/torch_small",
	iconRef = "PLACEHOLDER:icon/torch_small",
	sound = "equip_torch",
})
def({
	id = "light.expedition_flashlight",
	displayName = "Expedition Flashlight",
	category = "light",
	stackLimit = 1,
	protected = false,
	sellValue = 18,
	beamRange = 48,
	beamAngle = 35,
	brightness = 1.8,
	drainPerSecond = 0.9,
	meshRef = "PLACEHOLDER:C01/flashlight",
	iconRef = "PLACEHOLDER:icon/flashlight",
	sound = "equip_flashlight",
})

def({
	id = "light.compact_headlamp",
	displayName = "Compact Headlamp",
	category = "light",
	stackLimit = 1,
	protected = false,
	sellValue = 22,
	beamRange = 36,
	beamAngle = 50,
	brightness = 1.4,
	drainPerSecond = 0.5,
	meshRef = "PLACEHOLDER:C01/headlamp",
	iconRef = "PLACEHOLDER:icon/headlamp",
	sound = "equip_headlamp",
})

-- Power
def({
	id = "power.cell",
	displayName = "Replaceable Cell",
	category = "power",
	stackLimit = 6,
	protected = false,
	sellValue = 3,
	charge = 100,
	meshRef = "PLACEHOLDER:C01/cell",
	iconRef = "PLACEHOLDER:icon/cell",
})

-- Medical (fictional, game-oriented; no real medical instruction)
def({
	id = "med.cloth_dressing",
	displayName = "Cloth Dressing",
	category = "medical",
	stackLimit = 5,
	protected = false,
	sellValue = 2,
	healAmount = 15,
	treatSeconds = 3,
	removesInjury = false,
	meshRef = "PLACEHOLDER:C02/dressing",
	iconRef = "PLACEHOLDER:icon/dressing",
})
def({
	id = "med.bandage",
	displayName = "Proper Bandage",
	category = "medical",
	stackLimit = 5,
	protected = false,
	sellValue = 5,
	healAmount = 30,
	treatSeconds = 4,
	removesInjury = true,
	meshRef = "PLACEHOLDER:C02/bandage",
	iconRef = "PLACEHOLDER:icon/bandage",
})

-- Tools
def({
	id = "tool.stun_device",
	displayName = "Limited Stun Device",
	category = "tool",
	stackLimit = 1,
	protected = false,
	sellValue = 20,
	stunCharges = 3,
	meshRef = "PLACEHOLDER:C02/stun",
	iconRef = "PLACEHOLDER:icon/stun",
})
def({
	id = "tool.iron_bar",
	displayName = "Short Iron Bar",
	category = "tool",
	stackLimit = 1,
	protected = false,
	sellValue = 6,
	meleeDamage = 25,
	meshRef = "PLACEHOLDER:C02/bar",
	iconRef = "PLACEHOLDER:icon/bar",
})

-- Navigation (F09, F21: protected equally whether earned, found or purchased)
def({
	id = "nav.chalk",
	displayName = "Chalk Stick",
	category = "navigation",
	stackLimit = 50,
	protected = true,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C03/chalk",
	iconRef = "PLACEHOLDER:icon/chalk",
})
def({
	id = "nav.sign",
	displayName = "Route Sign",
	category = "navigation",
	stackLimit = 10,
	protected = true,
	sellValue = 3,
	meshRef = "PLACEHOLDER:C03/sign_arrow",
	iconRef = "PLACEHOLDER:icon/sign_arrow",
})
def({
	id = "nav.rope",
	displayName = "Rope Coil (segment)",
	category = "navigation",
	stackLimit = 20,
	protected = true,
	sellValue = 2,
	meshRef = "PLACEHOLDER:C03/rope",
	iconRef = "PLACEHOLDER:icon/rope",
})

-- Crafting materials
def({
	id = "mat.fabric",
	displayName = "Recovered Fabric",
	category = "material",
	stackLimit = 20,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/fabric",
	iconRef = "PLACEHOLDER:icon/fabric",
})
def({
	id = "mat.fastener",
	displayName = "Fastening Material",
	category = "material",
	stackLimit = 20,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/fastener",
	iconRef = "PLACEHOLDER:icon/fastener",
})
def({
	id = "mat.plank",
	displayName = "Rough Plank",
	category = "material",
	stackLimit = 10,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/plank",
	iconRef = "PLACEHOLDER:icon/plank",
})
def({
	id = "mat.bracket",
	displayName = "Iron Brackets",
	category = "material",
	stackLimit = 10,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/bracket",
	iconRef = "PLACEHOLDER:icon/bracket",
})
def({
	id = "mat.chalk_fragment",
	displayName = "Chalk Fragments",
	category = "material",
	stackLimit = 30,
	protected = false,
	sellValue = 0,
	meshRef = "PLACEHOLDER:C04/chalk_frag",
	iconRef = "PLACEHOLDER:icon/chalk_frag",
})

-- Treasure / evidence (fictional)
def({
	id = "treasure.survey_tag",
	displayName = "Expedition Survey Tag",
	category = "treasure",
	stackLimit = 1,
	protected = false,
	sellValue = 25,
	unique = true,
	meshRef = "PLACEHOLDER:C04/survey_tag",
	iconRef = "PLACEHOLDER:icon/survey_tag",
})
def({
	id = "treasure.brass_rule",
	displayName = "Brass Measuring Rule",
	category = "treasure",
	stackLimit = 5,
	protected = false,
	sellValue = 12,
	meshRef = "PLACEHOLDER:C04/brass_rule",
	iconRef = "PLACEHOLDER:icon/brass_rule",
})

def({
	id = "treasure.old_expedition_tag",
	displayName = "Old Expedition Tag",
	category = "treasure",
	stackLimit = 1,
	protected = true, -- story item: protected so a replaced death bag can never lock Act I
	sellValue = 0,
	unique = true,
	meshRef = "PLACEHOLDER:C04/old_tag",
	iconRef = "PLACEHOLDER:icon/old_tag",
})
def({
	id = "treasure.lead_seal",
	displayName = "Lead Seal (fictional)",
	category = "treasure",
	stackLimit = 5,
	protected = false,
	sellValue = 18,
	meshRef = "PLACEHOLDER:C04/lead_seal",
	iconRef = "PLACEHOLDER:icon/lead_seal",
})

-- Milestone 3 (docs/MILESTONE-3.md 4.7) -------------------------------------------------------------
def({
	id = "light.shielded_lantern",
	displayName = "Shielded Lantern",
	category = "light",
	stackLimit = 1,
	protected = false,
	sellValue = 20,
	beamRange = 22, -- omni radius when open
	beamAngle = 180,
	brightness = 1.1,
	drainPerSecond = 0.7,
	lantern = true,
	shieldedRange = 9,
	meshRef = "PLACEHOLDER:C01/lantern",
	iconRef = "PLACEHOLDER:icon/lantern",
	sound = "equip_lantern",
})
def({
	id = "tool.flare",
	displayName = "Signal Flare",
	category = "tool",
	stackLimit = 5,
	protected = false,
	sellValue = 2,
	flareSeconds = 45,
	flareRange = 18,
	meshRef = "PLACEHOLDER:C01/flare",
	iconRef = "PLACEHOLDER:icon/flare",
	sound = "flare_strike",
})
def({
	id = "med.splint",
	displayName = "Field Splint",
	category = "medical",
	stackLimit = 3,
	protected = false,
	sellValue = 4,
	healAmount = 5,
	treatSeconds = 4,
	removesInjury = true,
	meshRef = "PLACEHOLDER:C02/splint",
	iconRef = "PLACEHOLDER:icon/splint",
})
def({
	id = "tool.repair_roll",
	displayName = "Repair Tool Roll",
	category = "tool",
	stackLimit = 1,
	protected = false,
	sellValue = 8,
	reusable = true,
	meshRef = "PLACEHOLDER:C02/repair_roll",
	iconRef = "PLACEHOLDER:icon/repair_roll",
})
def({
	id = "tool.fuse_kit",
	displayName = "Replacement Fuse Kit",
	category = "tool",
	stackLimit = 5,
	protected = false,
	sellValue = 3,
	meshRef = "PLACEHOLDER:C02/fuse_kit",
	iconRef = "PLACEHOLDER:icon/fuse_kit",
})
def({
	id = "mat.fuse_component",
	displayName = "Fuse Components",
	category = "material",
	stackLimit = 20,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/fuse_component",
	iconRef = "PLACEHOLDER:icon/fuse_component",
})
def({
	id = "mat.battery_housing",
	displayName = "Battery Housing",
	category = "material",
	stackLimit = 10,
	protected = false,
	sellValue = 1,
	meshRef = "PLACEHOLDER:C04/battery_housing",
	iconRef = "PLACEHOLDER:icon/battery_housing",
})
def({
	id = "evidence.waterworks_log",
	displayName = "Waterworks Log",
	category = "evidence",
	stackLimit = 1,
	protected = true, -- story item (Act II): a replaced death bag can never lock the story
	sellValue = 0,
	unique = true,
	meshRef = "PLACEHOLDER:C04/waterworks_log",
	iconRef = "PLACEHOLDER:icon/journal",
})
def({
	id = "evidence.station_tape",
	displayName = "Station Tape",
	category = "evidence",
	stackLimit = 1,
	protected = true, -- story item (Act II)
	sellValue = 0,
	unique = true,
	meshRef = "PLACEHOLDER:C04/station_tape",
	iconRef = "PLACEHOLDER:icon/tape",
})
def({
	id = "treasure.field_photograph",
	displayName = "Field Photograph (fictional)",
	category = "treasure",
	stackLimit = 5,
	protected = false,
	sellValue = 15,
	meshRef = "PLACEHOLDER:C04/photograph",
	iconRef = "PLACEHOLDER:icon/photograph",
})
def({
	id = "treasure.dated_battery",
	displayName = "Mis-dated Battery (fictional)",
	category = "treasure",
	stackLimit = 5,
	protected = false,
	sellValue = 8,
	meshRef = "PLACEHOLDER:C04/dated_battery",
	iconRef = "PLACEHOLDER:icon/dated_battery",
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
