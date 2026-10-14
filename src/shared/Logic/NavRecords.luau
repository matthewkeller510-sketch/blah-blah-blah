--!strict
-- Placed navigation persistence (section 16; owner rules F09, F21).
-- Logical records persist independently of streamed visuals. Only the owner and the owner's CURRENT party see them.
-- Retrieval is server-authorized, idempotent and returns only the remaining units of that record.
-- Placed items persist until retrieved; limits are transparent and never solved by silent deletion.
-- Variable pockets (section 04, F08): a record placed inside a pocket carries its pocketId and the version id it was
-- placed in. When that version no longer exists on a server, the record migrates (never deletes) to the pocket's
-- documented anchor chamber and remembers where it came from (migratedFrom).
-- Pure module.

export type NavKind = "chalk" | "sign" | "rope"
export type Vec = { x: number, y: number, z: number }
-- A pocket version id ("direct", "loop", ...) inside a pocket; the number 1 outside pockets, which keeps records
-- saved before pockets existed valid without a schema change.
export type PocketVersion = number | string

export type NavRecord = {
	recordId: string,
	ownerId: number,
	kind: NavKind,
	itemId: string,
	regionId: string,
	pocketId: string?, -- set only for records placed inside a variable pocket
	pocketVersion: PocketVersion,
	anchorId: string,
	position: Vec,
	facing: Vec,
	endPosition: Vec?, -- rope only
	routeId: string?, -- preset route letter (ROUTE_IDS), never free text
	content: string, -- preset symbol/label ID; never unfiltered free text
	units: number, -- remaining recoverable units
	allowPartyRecovery: boolean,
	migratedFrom: { pocketId: string, version: string }?, -- set when a pocket change moved the record
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

-- Route identifiers are preset letters so no client text is ever persisted or replicated (D15).
NavRecords.ROUTE_IDS = { "A", "B", "C", "D", "E", "F" }

function NavRecords.isRouteId(v: any): boolean
	return type(v) == "string" and table.find(NavRecords.ROUTE_IDS, v) ~= nil
end

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
	pocketId: string?,
	pocketVersion: PocketVersion,
	anchorId: string,
	position: Vec,
	facing: Vec,
	endPosition: Vec?,
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
		pocketId = args.pocketId,
		pocketVersion = args.pocketVersion,
		anchorId = args.anchorId,
		position = args.position,
		facing = args.facing,
		endPosition = args.endPosition,
		routeId = args.routeId,
		content = args.content,
		units = args.units,
		allowPartyRecovery = false,
		migratedFrom = nil,
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

export type MigrationTarget = {
	regionId: string, -- region of the anchor chamber (the page the records move to)
	anchorId: string, -- the pocket's documented migration anchor (a stable chamber)
	spot: (index: number) -> Vec, -- floor point inside the anchor chamber for the n-th moved record (0-based)
	facing: Vec, -- horizontal direction a moved sign faces
}

-- Height above the floor spot at which each kind lies once moved: chalk on the floor, a sign standing, a coil.
local LIFT: { [string]: number } = { chalk = 0.05, sign = 0, rope = 0.3 }

-- Pocket migration (section 04; docs/MILESTONE-3.md section 3 rule 5): every record of THIS pocket whose version
-- differs from the pocket's current version moves to the migration anchor. Owner, kind, item, units, content,
-- route and party permission are kept; migratedFrom records the pocket and version; a rope collapses to a coil.
-- Records of other pockets and records outside pockets are never touched. Never deletes. Idempotent: a moved
-- record no longer belongs to the pocket. Returns the moved records in a stable order.
function NavRecords.migratePocketRecords(
	store: NavStore,
	pocketId: string,
	currentVersion: PocketVersion,
	target: MigrationTarget
): { NavRecord }
	local list: { NavRecord } = {}
	local already = 0
	for _, page in store.pages do
		for _, r in page do
			if r.pocketId == pocketId and r.pocketVersion ~= currentVersion then
				table.insert(list, r)
			elseif r.anchorId == target.anchorId and r.migratedFrom ~= nil then
				already += 1 -- earlier moves keep their spots; new ones go next to them
			end
		end
	end
	table.sort(list, function(a, b)
		return a.recordId < b.recordId
	end)
	for j, r in list do
		local spot = target.spot(already + j - 1)
		local fromRegion = r.regionId
		r.migratedFrom = { pocketId = pocketId, version = tostring(r.pocketVersion) }
		r.pocketId = nil
		r.pocketVersion = 1
		r.anchorId = target.anchorId
		r.position = { x = spot.x, y = spot.y + (LIFT[r.kind] or 0), z = spot.z }
		r.facing = if r.kind == "sign"
			then { x = target.facing.x, y = target.facing.y, z = target.facing.z }
			else { x = 0, y = 1, z = 0 }
		r.endPosition = nil -- a moved rope collapses to a coil at the anchor
		if fromRegion ~= target.regionId then
			local old = store.pages[fromRegion]
			if old then
				old[r.recordId] = nil
				if next(old) == nil then
					store.pages[fromRegion] = nil
				end
			end
			local page = store.pages[target.regionId]
			if not page then
				page = {}
				store.pages[target.regionId] = page
			end
			r.regionId = target.regionId
			page[r.recordId] = r
		end
	end
	return list
end

-- A deep copy that callers outside this module may read without touching the saved record.
function NavRecords.copy(r: NavRecord): NavRecord
	local c = table.clone(r)
	c.position = table.clone(r.position)
	c.facing = table.clone(r.facing)
	c.endPosition = if r.endPosition then table.clone(r.endPosition) else nil
	c.migratedFrom = if r.migratedFrom then table.clone(r.migratedFrom) else nil
	return c
end

return NavRecords
