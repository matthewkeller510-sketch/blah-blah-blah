--!strict
-- Chalk, signs and ropes (sections 09, 16; owner rules F09, F21). Records persist in the owner's profile until
-- retrieved. Only the owner and the owner's current party receive the records; clients render nearby ones.
-- Variable pockets (section 04, F08): a record placed inside a pocket carries the pocket and its version. When this
-- server shows a different version, the record migrates to the pocket's documented anchor (never deleted) and the
-- owner is told where it went. Online owners migrate when the pocket changes; offline owners migrate lazily the
-- next time their records are sent from a server whose version differs.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local Inventory = require(Shared.Logic.Inventory)
local NavRecords = require(Shared.Logic.NavRecords)
local WorldDefs = require(Shared.Data.WorldDefs)
local Pockets = require(Shared.Logic.Pockets)
Pockets.bind(WorldDefs)

local NavigationService = {}
local services: any

local KIND_ITEM = { chalk = "nav.chalk", sign = "nav.sign", rope = "nav.rope" }
local PLACE_RANGE = 10

local function vec(t): Vector3
	return Vector3.new(t.x, t.y, t.z)
end
local function tbl(v: Vector3)
	return { x = v.X, y = v.Y, z = v.Z }
end

local function isFiniteVector(v: any): boolean
	return typeof(v) == "Vector3" and v.X == v.X and v.Y == v.Y and v.Z == v.Z and v.Magnitude < 1e6
end

local function surfaceCheck(origin: Vector3, target: Vector3): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local dir = target - origin
	return workspace:Raycast(origin, dir.Unit * (dir.Magnitude + 1), params)
end

-- Current version of a pocket on this server (nil until PocketService runs: nothing migrates then).
local function versionOf(pocketId: string): string?
	return services.PocketService.versionOf(pocketId)
end

function NavigationService.place(player: Player, payload: any)
	local s = services.PlayerService.get(player)
	if not s or type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	local itemId = if type(kind) == "string" then KIND_ITEM[kind] else nil
	if not itemId or type(payload.content) ~= "string" or not isFiniteVector(payload.position) then
		return
	end
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local pos = payload.position :: Vector3
	if (pos - head.Position).Magnitude > PLACE_RANGE then
		return
	end
	local regionId = services.WorldBuilder.regionAt(pos)
	if not WorldDefs.isTunnel(regionId) then
		services.PlayerService.notify(player, "Markers can only be placed in the tunnels.", "warn")
		return
	end
	local hit = surfaceCheck(head.Position, pos)
	if not hit or (hit.Position - pos).Magnitude > 1.5 then
		return
	end
	local endPos: Vector3? = nil
	if kind == "rope" then
		if not isFiniteVector(payload.endPosition) then
			return
		end
		endPos = payload.endPosition
		assert(endPos)
		if
			(endPos - pos).Magnitude > Config.Navigation.ropeMaxSegmentLength
			or (endPos - head.Position).Magnitude > Config.Navigation.ropeMaxSegmentLength + PLACE_RANGE
		then
			services.PlayerService.notify(player, "Rope segment too long.", "warn")
			return
		end
	end
	if Inventory.count(s.profile.inventory, itemId) < 1 then
		services.PlayerService.notify(player, "You have no " .. (ItemDefs.require(itemId)).displayName .. ".", "warn")
		return
	end
	local anchorId = services.WorldBuilder.anchorFor(pos)
	-- Inside a variable pocket the record keeps the pocket and its current version; elsewhere the static default.
	local tagAt = { tbl(hit.Position) }
	if endPos then
		table.insert(tagAt, tbl(endPos))
	end
	local pocketId, pocketVersion = Pockets.tagFor(tagAt, versionOf)
	local rec, err = NavRecords.place(s.profile.nav, {
		ownerId = player.UserId,
		kind = kind,
		itemId = itemId,
		regionId = regionId,
		pocketId = pocketId,
		pocketVersion = pocketVersion,
		anchorId = anchorId,
		position = tbl(hit.Position),
		facing = tbl(hit.Normal),
		endPosition = endPos and tbl(endPos) or nil,
		routeId = if NavRecords.isRouteId(payload.routeId) then payload.routeId else nil,
		content = payload.content,
		units = 1,
	}, Config.Navigation.maxPlacedPerPlayer)
	if not rec then
		services.PlayerService.notify(
			player,
			if err == "placement_limit"
				then string.format(
					"You have %d markers placed. Pick some up to place more; your notebook lists where they are.",
					Config.Navigation.maxPlacedPerPlayer
				)
				else "That marker cannot be placed.",
			"warn"
		)
		return
	end
	Inventory.remove(s.profile.inventory, itemId, 1)
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	NavigationService.refreshGroup(player)
end

function NavigationService.retrieve(player: Player, ownerUserId: number, recordId: string)
	if type(recordId) ~= "string" or type(ownerUserId) ~= "number" then
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	local os_ = owner and services.PlayerService.get(owner)
	if not os_ or not owner then
		return
	end
	local regionId, rec = nil, nil
	for rid, pg in os_.profile.nav.pages do
		if pg[recordId] then
			regionId, rec = rid, pg[recordId]
			break
		end
	end
	if not rec or not regionId then
		return
	end
	local p = services.PlayerService.position(player)
	if not p or (p - vec(rec.position)).Magnitude > PLACE_RANGE then
		return
	end
	-- Check room first so a full inventory leaves the record (and every unit's provenance) untouched.
	local def = ItemDefs.get(rec.itemId)
	if not def or def.stackLimit - Inventory.count(os_.profile.inventory, rec.itemId) < rec.units then
		services.PlayerService.notify(player, "No room to carry it.", "warn")
		return
	end
	local res =
		NavRecords.retrieve(os_.profile.nav, regionId, recordId, player.UserId, services.PartyService.memberIds(owner))
	if not res.ok then
		if res.reason == "not_authorized" then
			services.PlayerService.notify(
				player,
				"Only the owner can pick that up unless they allow party recovery.",
				"warn"
			)
		end
		return
	end
	Inventory.add(os_.profile.inventory, ItemDefs.get, res.itemId :: string, res.units :: number, "loadout")
	services.SaveService.markDirty(owner)
	services.PlayerService.pushInventory(owner)
	NavigationService.refreshGroup(owner)
end

function NavigationService.setPartyRecovery(player: Player, recordId: string, allow: boolean)
	local s = services.PlayerService.get(player)
	local rec = nil
	if s then
		for _, pg in s.profile.nav.pages do
			rec = rec or pg[recordId]
		end
	end
	if rec then
		rec.allowPartyRecovery = allow == true
		services.SaveService.markDirty(player)
		NavigationService.refreshGroup(player)
	end
end

-- Migrates every record of `owner` whose pocket shows a different version on this server (rule 6), marks the
-- profile dirty and tells the owner once per pocket where the records went. Returns how many moved.
function NavigationService.migrateStale(owner: Player): number
	local s = services.PlayerService.get(owner)
	if not s then
		return 0
	end
	local store = s.profile.nav
	local stale: { [string]: boolean } = {}
	for _, page in store.pages do
		for _, r in page do
			if Pockets.isStale(r.pocketId, r.pocketVersion, versionOf) then
				stale[r.pocketId] = true
			end
		end
	end
	local ids = {}
	for id in stale do
		table.insert(ids, id)
	end
	table.sort(ids)
	local total = 0
	for _, pocketId in ids do
		local def = WorldDefs.Pockets[pocketId]
		local current = versionOf(pocketId)
		if def and current then
			local target = Pockets.migrationTarget(def, Config.Pockets.occupancyMargin)
			local moved = NavRecords.migratePocketRecords(store, pocketId, current, target)
			if #moved > 0 then
				total += #moved
				local kinds = {}
				for _, r in moved do
					table.insert(kinds, r.kind)
				end
				local regionName, anchorLabel = Pockets.noticeNames(def)
				services.PlayerService.notify(owner, Pockets.migrationNotice(kinds, regionName, anchorLabel), "warn")
			end
		end
	end
	if total > 0 then
		services.SaveService.markDirty(owner)
	end
	return total
end

-- Read-only copies of a player's own records in one region (creatures package, C04 Chalk Hand). Never a live
-- reference: nothing outside this service can move, delete or transfer a saved marker.
function NavigationService.ownRecords(player: Player, regionId: string): { NavRecords.NavRecord }
	local s = services.PlayerService.get(player)
	local out = {}
	if s then
		for _, r in NavRecords.inRegion(s.profile.nav, regionId) do
			table.insert(out, NavRecords.copy(r))
		end
	end
	return out
end

-- Rule 2: true when a rope of an online owner touches the pocket's bounds plus margin.
function NavigationService.ropeBlocks(pocketDef: WorldDefs.PocketDef): boolean
	local nav: { Pockets.NavInput } = {}
	for _, s in services.PlayerService.all() do
		-- a rope at a pocket lives in the pocket's region page: regionAt anywhere in a pocket's bounds plus margin
		-- is the pocket's region (nearest chamber), so other pages never need scanning
		local page = s.profile.nav.pages[pocketDef.regionId]
		if page then
			for _, r in page do
				if r.kind == "rope" then
					table.insert(nav, { kind = "rope", pos = r.position, endPos = r.endPosition, ownerOnline = true })
				end
			end
		end
	end
	return Pockets.blocker(pocketDef, { nav = nav }, Config.Pockets.occupancyMargin) ~= nil
end

-- Sends the viewer every record they may see: their own, plus their current party members'. Records of a pocket
-- version that does not exist here migrate first (lazy migration, rule 6).
function NavigationService.refreshFor(viewer: Player)
	local out = {}
	local owners = services.PartyService.members(viewer)
	for _, owner in owners do
		if NavigationService.migrateStale(owner) > 0 then
			-- the owner's party sees the move too (the second pass finds nothing stale, so this does not repeat)
			task.defer(function()
				if owner.Parent and services.PlayerService.get(owner) then
					NavigationService.refreshGroup(owner)
				end
			end)
		end
		local s = services.PlayerService.get(owner)
		if s then
			local ids = services.PartyService.memberIds(owner)
			for regionId in s.profile.nav.pages do
				for _, rec in NavRecords.inRegion(s.profile.nav, regionId) do
					if NavRecords.canSee(rec, viewer.UserId, ids) then
						table.insert(out, {
							recordId = rec.recordId,
							ownerId = rec.ownerId,
							isOwn = rec.ownerId == viewer.UserId,
							kind = rec.kind,
							content = rec.content,
							position = vec(rec.position),
							facing = vec(rec.facing),
							endPosition = rec.endPosition and vec(rec.endPosition) or nil,
							routeId = rec.routeId,
							allowPartyRecovery = rec.allowPartyRecovery,
							regionId = rec.regionId,
							pocketId = rec.pocketId,
							pocketVersion = rec.pocketVersion,
							migratedFrom = if rec.migratedFrom
								then { pocketId = rec.migratedFrom.pocketId, version = rec.migratedFrom.version }
								else nil,
						})
					end
				end
			end
		end
	end
	services.PlayerService.send(viewer, "nav", out)
end

function NavigationService.refreshGroup(player: Player)
	for _, m in services.PartyService.members(player) do
		NavigationService.refreshFor(m)
	end
end

function NavigationService.refreshAll()
	for _, p in Players:GetPlayers() do
		if services.PlayerService.get(p) then
			NavigationService.refreshFor(p)
		end
	end
end

function NavigationService.init(s)
	services = s
end

function NavigationService.start() end

return NavigationService
