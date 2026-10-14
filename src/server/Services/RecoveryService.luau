--!strict
-- Death and logout bags (sections 14, 15). Records live in the owner's profile and are anchored to stable chamber
-- anchors so they survive the server closing (T17). Visuals are rendered privately on authorized clients only.
-- Milestone 1 limitation: a delegate can recover an owner's bag only while the owner is online on the same server,
-- because escrow writes into the owner's profile. Cross-server delegation needs a queued operation (PLANNED).
-- Variable pockets (section 04, F08): a bag inside a pocket records the pocket and version; while its owner is online
-- it blocks that pocket's change. When this server shows another version, the bag migrates (never deleted) to the
-- pocket's documented anchor and the owner is told where it is now (lazy for owners who were offline).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local RecoveryBags = require(Shared.Logic.RecoveryBags)
local Pockets = require(Shared.Logic.Pockets)
Pockets.bind(WorldDefs)

local RecoveryService = {}
local services: any

local RECOVER_RANGE = 10
-- Migration spot indices for moved bags (navigation records use the spots nearest the pocket first).
local BAG_SPOT: { [string]: number } = { death = 24, logout = 25 }

local function versionOf(pocketId: string): string?
	return services.PocketService.versionOf(pocketId)
end

local function anchorFrom(pos: Vector3): RecoveryBags.Anchor
	local anchorId, offset, regionId = services.WorldBuilder.anchorFor(pos)
	local pocketId, pocketVersion = Pockets.tagFor({ { x = pos.X, y = pos.Y, z = pos.Z } }, versionOf)
	return {
		regionId = regionId,
		pocketVersion = pocketVersion,
		pocketId = pocketId,
		anchorId = anchorId,
		offset = { x = offset.X, y = offset.Y, z = offset.Z },
	}
end

-- Unresolved world position of an anchor (chamber centre + offset), for bounds tests without a raycast.
local function anchorPoint(a: any): Pockets.V3?
	if type(a) ~= "table" or type(a.anchorId) ~= "string" or type(a.offset) ~= "table" then
		return nil
	end
	local c = WorldDefs.chamber(a.anchorId)
	if not c then
		return nil
	end
	local o = a.offset
	return { x = c.pos.x + o.x, y = c.pos.y + o.y, z = c.pos.z + o.z }
end

local function bagWorldPos(bag): Vector3
	local o = bag.anchor.offset
	return services.WorldBuilder.resolveAnchor(bag.anchor.anchorId, Vector3.new(o.x, o.y, o.z))
end

local function partyIdsOf(player: Player): { number }?
	return services.PartyService.memberIds(player)
end

local function bagView(bag, viewer: Player)
	return {
		ownerId = bag.ownerId,
		kind = bag.kind,
		isOwn = bag.ownerId == viewer.UserId,
		position = bagWorldPos(bag),
		count = (function()
			local n = 0
			for _, c in bag.contents do
				n += c
			end
			return n
		end)(),
		moved = bag.migratedFrom ~= nil,
	}
end

-- Migrates the owner's bags whose pocket shows another version on this server (rule 6), marks the profile dirty
-- and tells the owner where each bag is now. Returns how many moved.
function RecoveryService.migrateStale(owner: Player): number
	local s = services.PlayerService.get(owner)
	if not s then
		return 0
	end
	local stale: { [string]: boolean } = {}
	for _, kind in { "death", "logout" } do
		local bag = s.profile.bags[kind]
		if bag and Pockets.isStale(bag.anchor.pocketId, bag.anchor.pocketVersion, versionOf) then
			stale[bag.anchor.pocketId] = true
		end
	end
	local total = 0
	for pocketId in stale do
		local def = WorldDefs.Pockets[pocketId]
		local current = versionOf(pocketId)
		local anchor = def and WorldDefs.chamber(def.migrationAnchor)
		if def and current and anchor then
			local margin = Config.Pockets.occupancyMargin
			local moved = RecoveryBags.migratePocket(s.profile, pocketId, current, {
				regionId = anchor.regionId,
				anchorId = anchor.id,
				offsetFor = function(kind: RecoveryBags.BagKind)
					local spot = Pockets.migrationSpot(def, BAG_SPOT[kind] or 24, margin)
					return { x = spot.x - anchor.pos.x, y = 1, z = spot.z - anchor.pos.z }
				end,
			})
			local regionName, anchorLabel = Pockets.noticeNames(def)
			for _, bag in moved do
				total += 1
				services.PlayerService.notify(
					owner,
					Pockets.migrationNotice({ bag.kind }, regionName, anchorLabel),
					"warn"
				)
			end
		end
	end
	if total > 0 then
		services.SaveService.markDirty(owner)
	end
	return total
end

-- Rule 2: true when a bag of an online owner lies inside the pocket's bounds plus margin.
function RecoveryService.bagBlocks(pocketDef: WorldDefs.PocketDef): boolean
	local bags: { Pockets.BagInput } = {}
	for _, s in services.PlayerService.all() do
		for _, kind in { "death", "logout" } do
			local bag = s.profile.bags[kind]
			local p = bag and anchorPoint(bag.anchor)
			if p then
				table.insert(bags, { pos = p, ownerOnline = true })
			end
		end
	end
	return Pockets.blocker(pocketDef, { bags = bags }, Config.Pockets.occupancyMargin) ~= nil
end

-- Read-only copies of a player's current bags (contract: M11 Lost Belongings names the region and nearest chamber
-- from bag.anchor; bag.migratedFrom says it was moved when a passage changed).
function RecoveryService.bagsOf(player: Player): { death: RecoveryBags.Bag?, logout: RecoveryBags.Bag? }
	local s = services.PlayerService.get(player)
	if not s then
		return {}
	end
	local d, l = s.profile.bags.death, s.profile.bags.logout
	return {
		death = if d then RecoveryBags.copy(d) else nil,
		logout = if l then RecoveryBags.copy(l) else nil,
	}
end

-- Sends the viewer every bag record they may currently access. Bags of a pocket version that does not exist on
-- this server migrate first (lazy migration, rule 6), so a bag never resolves onto geometry it was not dropped on.
function RecoveryService.pushBags(viewer: Player)
	local list = {}
	for owner in services.PlayerService.all() do
		RecoveryService.migrateStale(owner)
	end
	for owner, s in services.PlayerService.all() do
		for _, kind in { "death", "logout" } do
			local bag = s.profile.bags[kind]
			if bag then
				local ctx = { ownerOnline = true, ownerPartyMemberIds = partyIdsOf(owner) }
				if RecoveryBags.canAccess(bag, viewer.UserId, ctx) then
					table.insert(list, bagView(bag, viewer))
				end
			end
		end
	end
	services.PlayerService.send(viewer, "bags", list)
end

function RecoveryService.pushAll()
	for _, p in Players:GetPlayers() do
		if services.PlayerService.get(p) then
			RecoveryService.pushBags(p)
		end
	end
end

local function create(
	player: Player,
	kind: "death" | "logout",
	contents,
	pos: Vector3?,
	opId: string,
	anchorOverride: any?
)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local anchor = anchorOverride or (pos and anchorFrom(pos))
	if not anchor then
		-- No valid position known: never destroy owed items. Put them on the safest anchor.
		anchor = {
			regionId = "R01",
			pocketVersion = Pockets.STATIC_VERSION,
			pocketId = nil,
			anchorId = "R01.survey_board",
			offset = { x = 0, y = 0, z = 0 },
		}
	end
	local authorized = partyIdsOf(player) or {}
	local bag, replaced =
		RecoveryBags.create(s.profile, kind, player.UserId, contents, anchor, opId, os.time(), authorized)
	if replaced then
		services.PlayerService.notify(player, "Your previous " .. kind .. " bag was replaced.", "warn")
	end
	services.SaveService.markDirty(player)
	-- Durable write attempted before the bag is shown (section 20). It is shown even if that write failed: the record
	-- exists in the live profile, the save status says the save failed, and the autosave retries; hiding a bag
	-- that can be recovered here would only cost the owner their items.
	task.spawn(function()
		services.SaveService.commit(player)
		RecoveryService.pushAll()
	end)
	return bag
end

function RecoveryService.createDeathBag(player: Player, pos: Vector3)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local contents = Inventory.extractForDeath(s.profile.inventory, ItemDefs.get)
	services.PlayerService.pushInventory(player)
	return create(player, "death", contents, pos, "death:" .. HttpService:GenerateGUID(false))
end

function RecoveryService.createLogoutBag(player: Player, pos: Vector3?, opId: string)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local contents = Inventory.extractForLogout(s.profile.inventory, ItemDefs.get)
	if Inventory.isEmpty(contents) then
		return nil -- no empty bags
	end
	return create(player, "logout", contents, pos, opId)
end

-- The previous session crashed: its checkpoint holds the last valid grounded anchor.
function RecoveryService.reconcileCrash(player: Player)
	local s = services.PlayerService.get(player)
	if not s or not s.profile.checkpoint then
		return
	end
	local contents = Inventory.extractForLogout(s.profile.inventory, ItemDefs.get)
	if Inventory.isEmpty(contents) then
		return
	end
	local cp: any = s.profile.checkpoint
	if type(cp) ~= "table" then
		cp = {} -- corrupt checkpoint: the bag falls back to the safest anchor below; owed items are never destroyed
	end
	-- A copy, never the checkpoint table itself (the bag must not move when the checkpoint is next updated).
	local anchor: any = nil
	local o = cp.offset
	local c = type(cp.anchorId) == "string" and WorldDefs.chamber(cp.anchorId) or nil
	if c and type(o) == "table" and type(o.x) == "number" and type(o.y) == "number" and type(o.z) == "number" then
		anchor = {
			regionId = if type(cp.regionId) == "string" then cp.regionId else c.regionId,
			pocketVersion = cp.pocketVersion or Pockets.STATIC_VERSION,
			pocketId = if type(cp.pocketId) == "string" then cp.pocketId else nil,
			anchorId = cp.anchorId,
			offset = { x = o.x, y = o.y, z = o.z },
		}
		-- A checkpoint written without pocket data but standing in a pocket: its version is unknown, so the bag
		-- migrates to the pocket's documented anchor rather than resolving onto whatever geometry is there now.
		Pockets.tagAnchor(anchor)
	end
	create(player, "logout", contents, nil, "crash:" .. tostring(cp.anchorId) .. ":" .. tostring(os.time()), anchor)
	services.PlayerService.notify(
		player,
		"Your last session ended unexpectedly. Unbanked loot was left in a departure bag.",
		"warn"
	)
end

function RecoveryService.recover(requester: Player, ownerUserId: number, kind: string)
	if kind ~= "death" and kind ~= "logout" then
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	local os_ = owner and services.PlayerService.get(owner)
	local rs = services.PlayerService.get(requester)
	if not os_ or not rs or not owner then
		return
	end
	local bag = os_.profile.bags[kind]
	if not bag then
		return
	end
	local rp = services.PlayerService.position(requester)
	if not rp or (rp - bagWorldPos(bag)).Magnitude > RECOVER_RANGE then
		return
	end
	if not services.PlayerService.hold(requester, 1.5) then
		return
	end
	-- The owner may have left, or the bag been replaced, during the hold.
	if services.PlayerService.get(owner) ~= os_ or os_.profile.bags[kind] ~= bag then
		return
	end
	local ctx = { ownerOnline = true, ownerPartyMemberIds = partyIdsOf(owner) }
	local res = RecoveryBags.recover(os_.profile, kind :: any, requester.UserId, ctx)
	if not res.ok then
		if res.reason == "not_authorized" then
			services.PlayerService.notify(requester, "You are not allowed to open this bag.", "warn")
		end
		return
	end
	if res.toOwnerInventory then
		-- Recovered items are expedition loot again until carried home.
		local leftover = Inventory.addContents(os_.profile.inventory, ItemDefs.get, res.toOwnerInventory, "expedition")
		RecoveryBags.restoreLeftover(os_.profile, bag, leftover)
		if not Inventory.isEmpty(leftover) then
			services.PlayerService.notify(owner, "Some items did not fit and stay in the bag.", "warn")
		end
		services.PlayerService.pushInventory(owner)
		-- M11 pays field experience only for the owner's own recovery, never for a delegate's escrow recovery.
		local missions = services.MissionService
		if missions and missions.noteOwnerRecovered then
			missions.noteOwnerRecovered(owner, bag.bagId)
		end
	end
	services.SaveService.markDirty(owner)
	local toEscrow = res.toEscrow ~= nil
	task.spawn(function()
		-- Escrow is acknowledged only after the durable write (section 20); a failed save says so honestly.
		local saved = services.SaveService.commit(owner)
		if toEscrow then
			local tail = if saved then "" else " Saving failed for now and will retry."
			if owner.Parent then
				services.PlayerService.notify(
					owner,
					requester.DisplayName .. " recovered your " .. kind .. " bag into your shelter escrow." .. tail,
					"info"
				)
			end
			if requester.Parent then
				services.PlayerService.notify(
					requester,
					"Recovered into " .. owner.DisplayName .. "'s shelter escrow." .. tail,
					"info"
				)
			end
		end
	end)
	RecoveryService.pushAll()
end

function RecoveryService.revoke(owner: Player, kind: string, userId: number)
	local s = services.PlayerService.get(owner)
	if s and (kind == "death" or kind == "logout") then
		RecoveryBags.revoke(s.profile, kind, userId)
		services.SaveService.markDirty(owner)
		RecoveryService.pushAll()
	end
end

-- Owner collects escrow at a shelter; items are banked immediately because the owner is in a shelter.
function RecoveryService.claimEscrow(player: Player)
	local s = services.PlayerService.get(player)
	if not s or not s.insideShelterId then
		return
	end
	local c = RecoveryBags.takeEscrow(s.profile)
	if Inventory.isEmpty(c) then
		services.PlayerService.notify(player, "Escrow is empty.", "info")
		return
	end
	local leftover = Inventory.addContents(s.profile.inventory, ItemDefs.get, c, "loadout")
	for id, n in leftover do
		s.profile.escrow[id] = (s.profile.escrow[id] or 0) + n
	end
	services.SaveService.markDirty(player)
	task.spawn(services.SaveService.commit, player)
	services.PlayerService.pushInventory(player)
end

function RecoveryService.init(s)
	services = s
end

function RecoveryService.start() end

return RecoveryService
