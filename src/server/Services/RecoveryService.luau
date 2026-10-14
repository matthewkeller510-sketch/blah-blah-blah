--!strict
-- Death and logout bags (sections 14, 15). Records live in the owner's profile and are anchored to stable chamber
-- anchors so they survive the server closing (T17). Visuals are rendered privately on authorized clients only.
-- Milestone 1 limitation: a delegate can recover an owner's bag only while the owner is online on the same server,
-- because escrow writes into the owner's profile. Cross-server delegation needs a queued operation (PLANNED).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDefs = require(Shared.Data.ItemDefs)
local Inventory = require(Shared.Logic.Inventory)
local RecoveryBags = require(Shared.Logic.RecoveryBags)

local RecoveryService = {}
local services: any

local RECOVER_RANGE = 10

local function anchorFrom(pos: Vector3)
	local anchorId, offset, regionId = services.WorldBuilder.anchorFor(pos)
	return {
		regionId = regionId,
		pocketVersion = 1,
		anchorId = anchorId,
		offset = { x = offset.X, y = offset.Y, z = offset.Z },
	}
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
	}
end

-- Sends the viewer every bag record they may currently access.
function RecoveryService.pushBags(viewer: Player)
	local list = {}
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
		anchor =
			{ regionId = "R01", pocketVersion = 1, anchorId = "R01.survey_board", offset = { x = 0, y = 0, z = 0 } }
	end
	local authorized = partyIdsOf(player) or {}
	local bag, replaced =
		RecoveryBags.create(s.profile, kind, player.UserId, contents, anchor, opId, os.time(), authorized)
	if replaced then
		services.PlayerService.notify(player, "Your previous " .. kind .. " bag was replaced.", "warn")
	end
	services.SaveService.markDirty(player)
	-- Durable write before telling anyone it exists (section 20).
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
	local cp = s.profile.checkpoint
	create(player, "logout", contents, nil, "crash:" .. tostring(cp.anchorId) .. ":" .. tostring(os.time()), cp)
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
	else
		services.PlayerService.notify(
			owner,
			requester.DisplayName .. " recovered your " .. kind .. " bag into your shelter escrow.",
			"info"
		)
		services.PlayerService.notify(requester, "Recovered into " .. owner.DisplayName .. "'s shelter escrow.", "info")
	end
	services.SaveService.markDirty(owner)
	task.spawn(services.SaveService.commit, owner)
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
