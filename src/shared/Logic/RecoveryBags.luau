--!strict
-- Death and logout recovery records (sections 14, 15; owner rules F15, F16, F17).
-- PROVISIONAL bag policy (section 15, not owner-approved): one latest death bag plus one latest logout bag,
-- replaced independently. See docs/DECISIONS.md D02.
-- PROPOSED delegation policy (section 14): owner access is unconditional; a delegate needs a saved authorization,
-- and while the owner is online and grouped the delegate must also be in the owner's current party.
-- Delegate recovery moves contents into the owner's escrow, never into the delegate's inventory.
-- Pure module: records are plain tables persisted inside the player profile.

export type Contents = { [string]: number }

export type Anchor = {
	regionId: string,
	pocketVersion: number,
	anchorId: string,
	offset: { x: number, y: number, z: number },
}

export type BagKind = "death" | "logout"

export type Bag = {
	bagId: string,
	kind: BagKind,
	ownerId: number,
	contents: Contents,
	anchor: Anchor,
	createdAt: number,
	opId: string,
	authorized: { [string]: boolean }, -- string user IDs (DataStore-safe keys)
}

export type BagProfile = {
	bags: { death: Bag?, logout: Bag? },
	escrow: Contents,
	appliedOps: { string },
}

local MAX_APPLIED_OPS = 64

local RecoveryBags = {}

function RecoveryBags.wasApplied(p: BagProfile, opId: string): boolean
	for _, id in p.appliedOps do
		if id == opId then
			return true
		end
	end
	return false
end

function RecoveryBags.markApplied(p: BagProfile, opId: string)
	table.insert(p.appliedOps, opId)
	while #p.appliedOps > MAX_APPLIED_OPS do
		table.remove(p.appliedOps, 1)
	end
end

local function isEmpty(c: Contents): boolean
	for _, n in c do
		if n > 0 then
			return false
		end
	end
	return true
end

-- Creates a bag of `kind`, replacing only the previous bag of the same kind.
-- Returns (newBag, replacedBag). Empty contents create no bag (section 15). Replaying the same opId is a no-op.
function RecoveryBags.create(
	p: BagProfile,
	kind: BagKind,
	ownerId: number,
	contents: Contents,
	anchor: Anchor,
	opId: string,
	now: number,
	authorizedIds: { number }?
): (Bag?, Bag?)
	if RecoveryBags.wasApplied(p, opId) then
		return p.bags[kind], nil
	end
	RecoveryBags.markApplied(p, opId)
	if isEmpty(contents) then
		return nil, nil
	end
	local auth: { [string]: boolean } = {}
	if authorizedIds then
		for _, uid in authorizedIds do
			if uid ~= ownerId then
				auth[tostring(uid)] = true
			end
		end
	end
	local bag: Bag = {
		bagId = kind .. ":" .. opId,
		kind = kind,
		ownerId = ownerId,
		contents = table.clone(contents),
		anchor = anchor,
		createdAt = now,
		opId = opId,
		authorized = auth,
	}
	local replaced = p.bags[kind]
	p.bags[kind] = bag
	return bag, replaced
end

export type AccessContext = {
	ownerOnline: boolean,
	ownerPartyMemberIds: { number }?, -- nil when the owner is ungrouped or offline
}

function RecoveryBags.canAccess(bag: Bag, requesterId: number, ctx: AccessContext): boolean
	if requesterId == bag.ownerId then
		return true
	end
	if not bag.authorized[tostring(requesterId)] then
		return false -- stranger access is off by default
	end
	if ctx.ownerOnline and ctx.ownerPartyMemberIds then
		-- Confirmed current-party protection (F15) takes precedence over saved authorization.
		return table.find(ctx.ownerPartyMemberIds, requesterId) ~= nil
	end
	return true
end

export type RecoverResult = {
	ok: boolean,
	reason: string?,
	toOwnerInventory: Contents?,
	toEscrow: Contents?,
}

-- Removes the bag record and reports where its contents go. The caller applies the inventory side atomically
-- inside the same profile update. Calling again after success fails with "no_bag" (idempotent).
function RecoveryBags.recover(p: BagProfile, kind: BagKind, requesterId: number, ctx: AccessContext): RecoverResult
	local bag = p.bags[kind]
	if not bag then
		return { ok = false, reason = "no_bag" }
	end
	if not RecoveryBags.canAccess(bag, requesterId, ctx) then
		return { ok = false, reason = "not_authorized" }
	end
	p.bags[kind] = nil
	if requesterId == bag.ownerId then
		return { ok = true, toOwnerInventory = bag.contents }
	end
	for id, n in bag.contents do
		p.escrow[id] = (p.escrow[id] or 0) + n
	end
	return { ok = true, toEscrow = bag.contents }
end

-- If the owner's inventory cannot hold everything, the remainder goes back into a bag of the same kind at the
-- same anchor so nothing is destroyed.
function RecoveryBags.restoreLeftover(p: BagProfile, original: Bag, leftover: Contents)
	if isEmpty(leftover) then
		return
	end
	local b = table.clone(original)
	b.contents = leftover
	p.bags[original.kind] = b
end

function RecoveryBags.revoke(p: BagProfile, kind: BagKind, userId: number): boolean
	local bag = p.bags[kind]
	if not bag then
		return false
	end
	bag.authorized[tostring(userId)] = nil
	return true
end

-- Owner collects escrowed items at a shelter. Returns and clears escrow exactly once.
function RecoveryBags.takeEscrow(p: BagProfile): Contents
	local c = p.escrow
	p.escrow = {}
	return c
end

return RecoveryBags
