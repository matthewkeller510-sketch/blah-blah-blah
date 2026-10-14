--!strict
-- Chalk, signs and ropes (sections 09, 16; owner rules F09, F21). Records persist in the owner's profile until
-- retrieved. Only the owner and the owner's current party receive the records; clients render nearby ones.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local Inventory = require(Shared.Logic.Inventory)
local NavRecords = require(Shared.Logic.NavRecords)
local WorldDefs = require(Shared.Data.WorldDefs)

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

function NavigationService.place(player: Player, payload: any)
	local s = services.PlayerService.get(player)
	if not s or type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	local itemId = KIND_ITEM[kind]
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
	local pocketVersion = 1 -- no variable pockets exist yet (R05); records still carry the field
	local rec, err = NavRecords.place(s.profile.nav, {
		ownerId = player.UserId,
		kind = kind,
		itemId = itemId,
		regionId = regionId,
		pocketVersion = pocketVersion,
		anchorId = anchorId,
		position = tbl(hit.Position),
		facing = tbl(hit.Normal),
		endPosition = endPos and tbl(endPos) or nil,
		routeId = if type(payload.routeId) == "string" and #payload.routeId <= 12 then payload.routeId else nil,
		content = payload.content,
		units = 1,
	}, Config.Navigation.maxPlacedPerPlayer)
	if not rec then
		services.PlayerService.notify(
			player,
			if err == "placement_limit"
				then string.format(
					"You have %d markers placed. Pick some up from your notebook list to place more.",
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
	local regionId, page, rec = nil, nil, nil
	for rid, pg in os_.profile.nav.pages do
		if pg[recordId] then
			regionId, page, rec = rid, pg, pg[recordId]
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
	local added =
		Inventory.add(os_.profile.inventory, ItemDefs.get, res.itemId :: string, res.units :: number, "loadout")
	if added < (res.units :: number) then
		-- Not enough room: put the record back unchanged rather than destroying the unit.
		Inventory.remove(os_.profile.inventory, res.itemId :: string, added)
		page = os_.profile.nav.pages[regionId] or {}
		os_.profile.nav.pages[regionId] = page
		page[recordId] = rec
		services.PlayerService.notify(player, "No room to carry it.", "warn")
		return
	end
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

-- Sends the viewer every record they may see: their own, plus their current party members'.
function NavigationService.refreshFor(viewer: Player)
	local out = {}
	local owners = services.PartyService.members(viewer)
	for _, owner in owners do
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
