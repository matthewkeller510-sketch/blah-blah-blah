--!strict
-- Placed navigation persistence (section 16; owner rules F09, F21).
-- Logical records persist independently of streamed visuals. Only the owner and the owner's CURRENT party see them.
-- Retrieval is server-authorized, idempotent and returns only the remaining units of that record.
-- Placed items persist until retrieved; limits are transparent and never solved by silent deletion.
-- Pure module.

export type NavKind = "chalk" | "sign" | "rope"

export type NavRecord = {
	recordId: string,
	ownerId: number,
	kind: NavKind,
	itemId: string,
	regionId: string,
	pocketVersion: number,
	anchorId: string,
	position: { x: number, y: number, z: number },
	facing: { x: number, y: number, z: number },
	endPosition: { x: number, y: number, z: number }?, -- rope only
	routeId: string?,
	content: string, -- preset symbol/label ID; never unfiltered free text
	units: number, -- remaining recoverable units
	allowPartyRecovery: boolean,
}

export type NavStore = {
	pages: { [string]: { [string]: NavRecord } }, -- regionId -> recordId -> record
	nextSeq: number,
}

local NavRecords = {}

-- Preset content keeps placement fast on touch and avoids replicating user text (section 09).
NavRecords.PRESETS = {
	chalk = { "arrow", "danger", "shelter", "exit", "water", "x", "route_a", "route_b", "route_c" },
	sign = { "to_shelter", "to_exit", "danger_ahead", "water_crossing", "dead_end", "rescue_here" },
	rope = { "guide" },
}

function NavRecords.newStore(): NavStore
	return { pages = {}, nextSeq = 1 }
end

function NavRecords.isPreset(kind: NavKind, content: string): boolean
	return table.find(NavRecords.PRESETS[kind], content) ~= nil
end

function NavRecords.countOwned(store: NavStore): number
	local n = 0
	for _, page in store.pages do
		for _ in page do
			n += 1
		end
	end
	return n
end

export type PlaceArgs = {
	ownerId: number,
	kind: NavKind,
	itemId: string,
	regionId: string,
	pocketVersion: number,
	anchorId: string,
	position: { x: number, y: number, z: number },
	facing: { x: number, y: number, z: number },
	endPosition: { x: number, y: number, z: number }?,
	routeId: string?,
	content: string,
	units: number,
}

-- Returns (record?, error?). The caller must remove `units` from inventory in the same profile update.
function NavRecords.place(store: NavStore, args: PlaceArgs, maxPlaced: number): (NavRecord?, string?)
	if not NavRecords.isPreset(args.kind, args.content) then
		return nil, "invalid_content"
	end
	if args.units < 1 then
		return nil, "invalid_units"
	end
	if NavRecords.countOwned(store) >= maxPlaced then
		return nil, "placement_limit" -- surfaced to the player with reclaim controls
	end
	local id = string.format("%d-%d", args.ownerId, store.nextSeq)
	store.nextSeq += 1
	local rec: NavRecord = {
		recordId = id,
		ownerId = args.ownerId,
		kind = args.kind,
		itemId = args.itemId,
		regionId = args.regionId,
		pocketVersion = args.pocketVersion,
		anchorId = args.anchorId,
		position = args.position,
		facing = args.facing,
		endPosition = args.endPosition,
		routeId = args.routeId,
		content = args.content,
		units = args.units,
		allowPartyRecovery = false,
	}
	local page = store.pages[args.regionId]
	if not page then
		page = {}
		store.pages[args.regionId] = page
	end
	page[id] = rec
	return rec, nil
end

-- Visibility: owner, or a member of the owner's current party.
function NavRecords.canSee(rec: NavRecord, viewerId: number, ownerPartyMemberIds: { number }?): boolean
	if viewerId == rec.ownerId then
		return true
	end
	return ownerPartyMemberIds ~= nil and table.find(ownerPartyMemberIds, viewerId) ~= nil
end

-- Retrieval: owner always; a current party member only if the owner deliberately permitted recovery.
-- Party retrieval returns units to the OWNER (no theft of the owner's supply).
export type RetrieveResult = { ok: boolean, reason: string?, itemId: string?, units: number?, toOwnerId: number? }

function NavRecords.retrieve(
	store: NavStore,
	regionId: string,
	recordId: string,
	requesterId: number,
	ownerPartyMemberIds: { number }?
): RetrieveResult
	local page = store.pages[regionId]
	local rec = page and page[recordId]
	if not rec then
		return { ok = false, reason = "not_found" } -- already retrieved: idempotent
	end
	local isOwner = requesterId == rec.ownerId
	if not isOwner then
		if not (rec.allowPartyRecovery and NavRecords.canSee(rec, requesterId, ownerPartyMemberIds)) then
			return { ok = false, reason = "not_authorized" }
		end
	end
	assert(page)
	page[recordId] = nil
	if next(page) == nil then
		store.pages[regionId] = nil
	end
	return { ok = true, itemId = rec.itemId, units = rec.units, toOwnerId = rec.ownerId }
end

-- Lists records in a region page (rendering only instantiates nearby visible ones).
function NavRecords.inRegion(store: NavStore, regionId: string): { NavRecord }
	local out = {}
	local page = store.pages[regionId]
	if page then
		for _, r in page do
			table.insert(out, r)
		end
	end
	return out
end

-- Pocket migration: move records pinned to a retired pocket version to a documented equivalent anchor.
-- Never deletes. Returns the number of migrated records.
function NavRecords.migratePocket(
	store: NavStore,
	regionId: string,
	fromVersion: number,
	toVersion: number,
	anchorMap: { [string]: { anchorId: string, position: { x: number, y: number, z: number } } }
): number
	local n = 0
	local page = store.pages[regionId]
	if not page then
		return 0
	end
	for _, r in page do
		if r.pocketVersion == fromVersion then
			local target = anchorMap[r.anchorId]
			if target then
				r.anchorId = target.anchorId
				r.position = target.position
				r.endPosition = nil -- a moved rope collapses to a coil at the recovery anchor
			end
			r.pocketVersion = toVersion
			n += 1
		end
	end
	return n
end

return NavRecords
