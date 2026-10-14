--!strict
-- Crafting transactions and purchase-receipt deduplication (sections 09, 20, 21).
-- Crafting: preview shows costs and outcome; the craft itself is all-or-nothing. No random paid results.
-- Receipts: a replayed receipt grants exactly once; grants are recorded before the receipt is acknowledged.
-- Pure module.

-- Inventory is injected with bind() so this module works with both Roblox instance requires and file-path requires.
local Inventory = nil :: any

export type Recipe = {
	id: string,
	inputs: { [string]: number },
	output: string,
	outputCount: number,
	seconds: number,
	requiresWorkbench: boolean,
}

local Commerce = {}

function Commerce.bind(inventoryModule: any)
	Inventory = inventoryModule
end

Commerce.RECIPES = {
	{
		id = "craft.field_dressing",
		inputs = { ["mat.fabric"] = 2, ["mat.fastener"] = 1 },
		output = "med.cloth_dressing",
		outputCount = 1,
		seconds = 3,
		requiresWorkbench = false,
	},
	{
		id = "craft.chalk",
		inputs = { ["mat.chalk_fragment"] = 3 },
		output = "nav.chalk",
		outputCount = 1,
		seconds = 2,
		requiresWorkbench = false,
	},
	-- Milestone 3 (docs/MILESTONE-3.md 4.7). Quantities are the contract's; times are TUNE. Like the existing
	-- recipes they need a shelter but no workbench (PROPOSED: "workbench rules unchanged").
	{
		id = "craft.fuse_kit",
		inputs = { ["mat.fuse_component"] = 2, ["mat.fastener"] = 1 },
		output = "tool.fuse_kit",
		outputCount = 1,
		seconds = 3,
		requiresWorkbench = false,
	},
	{
		id = "craft.splint",
		inputs = { ["mat.plank"] = 1, ["mat.fabric"] = 1 },
		output = "med.splint",
		outputCount = 1,
		seconds = 3,
		requiresWorkbench = false,
	},
	{
		id = "craft.repaired_cell",
		inputs = { ["mat.battery_housing"] = 1, ["mat.fastener"] = 1 },
		output = "power.cell",
		outputCount = 1,
		seconds = 4,
		requiresWorkbench = false,
	},
} :: { Recipe }

function Commerce.recipe(id: string): Recipe?
	for _, r in Commerce.RECIPES do
		if r.id == id then
			return r
		end
	end
	return nil
end

export type Preview = { recipe: Recipe, canCraft: boolean, missing: { [string]: number }, outputFits: boolean }

function Commerce.preview(inv: any, lookup: any, recipe: Recipe, atWorkbench: boolean): Preview
	local missing = {}
	for id, n in recipe.inputs do
		local have = Inventory.count(inv, id)
		if have < n then
			missing[id] = n - have
		end
	end
	local d = lookup(recipe.output)
	local fits = d ~= nil and Inventory.count(inv, recipe.output) + recipe.outputCount <= d.stackLimit
	return {
		recipe = recipe,
		canCraft = next(missing) == nil and fits and (atWorkbench or not recipe.requiresWorkbench),
		missing = missing,
		outputFits = fits,
	}
end

-- Atomic: validates everything on a clone, then commits. Returns (ok, reason).
-- PROPOSED: crafting is offered only at shelters in Milestone 1, after banking, so output is loadout.
function Commerce.craft(inv: any, lookup: any, recipe: Recipe, atWorkbench: boolean): (boolean, string?)
	local p = Commerce.preview(inv, lookup, recipe, atWorkbench)
	if not p.canCraft then
		return false,
			if next(p.missing) ~= nil then "insufficient" elseif not p.outputFits then "no_space" else "needs_workbench"
	end
	local work = Inventory.clone(inv)
	for id, n in recipe.inputs do
		if not Inventory.remove(work, id, n) then
			return false, "insufficient"
		end
	end
	if Inventory.add(work, lookup, recipe.output, recipe.outputCount, "loadout") ~= recipe.outputCount then
		return false, "no_space"
	end
	-- commit
	for k in inv do
		inv[k] = nil
	end
	for k, v in work do
		inv[k] = v
	end
	return true, nil
end

-- Receipt ledger. Developer products are navigation packs only (section 21); IDs come from configuration.
export type ReceiptLedger = { [string]: boolean }

function Commerce.alreadyGranted(ledger: ReceiptLedger, purchaseId: string): boolean
	return ledger[purchaseId] == true
end

function Commerce.recordGrant(ledger: ReceiptLedger, purchaseId: string)
	ledger[purchaseId] = true
end

return Commerce
