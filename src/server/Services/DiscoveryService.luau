--!strict
-- Landmark discovery, scavenging and unique pickups (sections 08, 14; owner rules F12, F14, F24).
-- Discoveries made while grouped are committed to each online party member's personal record (no proximity
-- requirement). Pickups are per player: each player claims their own copy; scavenging cooldowns are per player.
-- The server re-checks every search and claim (alive, not downed, not carried, not hidden, outside a shelter, in
-- range); the ProximityPrompt alone is never trusted. A search grants what fits and leaves the rest in the site for
-- that player; a search that grants nothing neither consumes the site nor starts its restock timer.
-- Place discoveries pay field experience once per place (D37) through PlayerService.grantXp.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Progress = require(Shared.Logic.Progress)
local Discovery = require(Shared.Logic.Discovery)

local DiscoveryService = {}
local services: any

local LABELS: { [string]: string } = {
	["R00.mission_board"] = "Mission Board",
	["R00.equipment_room"] = "Equipment Room",
	["R00.descent_ramp"] = "The Descent",
}
for _, c in WorldDefs.Chambers do
	LABELS[c.id] = c.label
end

-- Discoveries that accompany an item claim never pay place experience.
local ITEM_CLAIMS: { [string]: boolean } = {}
for _, u in WorldDefs.UniquePickups do
	ITEM_CLAIMS[u.discoveryId] = true
end
local function isItemClaim(id: string): boolean
	return ITEM_CLAIMS[id] == true
end

-- Messages for refused searches; nil means stay silent (dead, or a stale prompt from too far away).
local REFUSALS: { [string]: string } = {
	downed = "You cannot search while you are down.",
	carried = "You cannot search while being carried.",
	hidden = "Step out of hiding first.",
	in_shelter = "Nothing to search from inside a shelter.",
}

function DiscoveryService.discover(player: Player, discoveryId: string, label: string?)
	local recs = {}
	for _, m in services.PartyService.members(player) do
		local s = services.PlayerService.get(m)
		if s then
			recs[m.UserId] = s.profile.discoveries
		end
	end
	local newly = Progress.commitDiscovery(recs, discoveryId)
	local isPlace = Discovery.isPlaceDiscovery(discoveryId, isItemClaim)
	for _, uid in newly do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			services.SaveService.markDirty(p)
			services.PlayerService.send(p, "discovery", {
				id = discoveryId,
				label = label or LABELS[discoveryId] or discoveryId,
				byOther = p ~= player and player.DisplayName or nil,
			})
			-- Field experience once per place per player (player package API; idempotent per key). Spawned so a
			-- persisting grant can never stall the caller (the volume loop, a puzzle, PocketService).
			local grantXp = services.PlayerService.grantXp
			if isPlace and grantXp then
				task.spawn(grantXp, p, "disc:" .. discoveryId, Config.Progression.xp.discovery)
			end
		end
	end
end

-- The effective light predicate: PlayerService.lightState (player package). Until it exists, the same rule its
-- refreshLight applies: switched on, a light equipped and held, charge left, not downed.
local function hasWorkingLight(player: Player, s: any): boolean
	local lightState = services.PlayerService.lightState
	if lightState then
		local st = lightState(player)
		return type(st) == "table" and st.on == true
	end
	local id = s.profile.equippedLight
	return s.lightOn == true
		and id ~= nil
		and Inventory.count(s.profile.inventory, id) > 0
		and s.profile.lightCharge > 0
		and s.vitals.condition ~= "downed"
end

local function searcher(player: Player, s: any, at: Vector3): Discovery.Searcher
	local pos = services.PlayerService.position(player)
	return {
		alive = s.alive == true and s.vitals.condition ~= "dead",
		downed = s.vitals.condition == "downed",
		carried = s.carriedBy ~= nil,
		hidden = s.hiddenAt ~= nil,
		inShelter = s.insideShelterId ~= nil,
		distance = if pos then (pos - at).Magnitude else nil,
	}
end

-- Returns the session when the player may search or claim at `at`, after telling them why not otherwise.
local function allowed(player: Player, at: Vector3): any
	local s = services.PlayerService.get(player)
	if not s then
		return nil
	end
	local ok, why = Discovery.canSearch(searcher(player, s, at), Discovery.SEARCH_RANGE)
	if not ok then
		local msg = why and REFUSALS[why]
		if msg then
			services.PlayerService.notify(player, msg, "warn")
		end
		return nil
	end
	return s
end

-- Adds up to n units as expedition loot; returns how many fit. A found device arrives charged.
local function addItem(s: any, id: string, n: number): number
	local d = ItemDefs.get(id)
	if not d then
		return 0
	end
	local added = Inventory.add(s.profile.inventory, ItemDefs.get, id, n, "expedition")
	if added > 0 and d.stunCharges then
		s.profile.toolCharges[id] = d.stunCharges
	end
	return added
end

local function describe(got: { [string]: number }): string
	local parts = {}
	for id, n in got do
		local d = ItemDefs.get(id)
		table.insert(parts, string.format("%d× %s", n, if d then d.displayName else id))
	end
	table.sort(parts)
	return if #parts == 0 then "nothing you can carry" else table.concat(parts, ", ")
end

local function search(player: Player, site: WorldDefs.ScavengeSite, at: Vector3)
	local s = allowed(player, at)
	if not s then
		return
	end
	if site.requiresLight and not hasWorkingLight(player, s) then
		services.PlayerService.notify(
			player,
			"Too dark to search this properly. You need a working light here.",
			"warn"
		)
		return
	end
	local cooldowns = s.profile.missionCooldowns
	local res = Discovery.search(
		site.contents,
		Discovery.readSite(cooldowns, site.id),
		os.time(),
		site.respawnSeconds,
		function(id: string, n: number): number
			return addItem(s, id, n)
		end
	)
	if res.outcome == "cooldown" then
		services.PlayerService.notify(player, "You already searched this recently. Come back later.", "info")
		return
	end
	if res.outcome == "no_room" then
		services.PlayerService.notify(player, "No room to carry anything from here. It stays where it is.", "warn")
		return
	end
	Discovery.writeSite(cooldowns, site.id, res.state)
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	local text = "Found " .. describe(res.got) .. "."
	if res.outcome == "partial" then
		text ..= " The rest does not fit; it stays here for you."
	end
	services.PlayerService.notify(player, text, "info")
end

local function buildPickups()
	local f = Instance.new("Folder")
	f.Name = "Pickups"
	f.Parent = services.WorldBuilder.root()
	for _, site in WorldDefs.ScavengeSites do
		local p = Instance.new("Part")
		p.Name = site.id
		p.Anchored = true
		p.Size = Vector3.new(2.4, 1.6, 1.8)
		p.CFrame = CFrame.new(site.pos.x, site.pos.y - 0.2, site.pos.z)
		p.Color = Color3.fromRGB(96, 78, 56)
		p.Material = Enum.Material.WoodPlanks
		p.Parent = f
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Search"
		pp.ObjectText = if site.requiresLight then "Dark corner" else "Crate"
		pp.HoldDuration = 1.2
		pp.MaxActivationDistance = 7
		pp.RequiresLineOfSight = false
		pp.Parent = p
		local at = p.Position
		pp.Triggered:Connect(function(player)
			search(player, site, at)
		end)
	end
	for _, u in WorldDefs.UniquePickups do
		local itemDef = ItemDefs.get(u.itemId)
		if not itemDef then
			-- A data mistake must not stop the server from starting: skip this pickup and say so clearly.
			warn(string.format("[DiscoveryService] unique pickup %s names unknown item %s; not built", u.id, u.itemId))
			continue
		end
		local displayName = itemDef.displayName
		local p = Instance.new("Part")
		p.Name = u.id
		p.Anchored = true
		p.Size = Vector3.new(0.8, 0.2, 1.2)
		p.CFrame = CFrame.new(u.pos.x, u.pos.y - 0.4, u.pos.z)
		p.Color = Color3.fromRGB(170, 140, 80)
		p.Material = Enum.Material.Metal
		p.Parent = f
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Collect"
		pp.ObjectText = displayName
		pp.HoldDuration = 0.6
		pp.MaxActivationDistance = 7
		pp.RequiresLineOfSight = false
		pp.Parent = p
		local at = p.Position
		pp.Triggered:Connect(function(player)
			local s = allowed(player, at)
			if not s then
				return
			end
			if s.profile.claims[u.id] then
				services.PlayerService.notify(player, "You already collected your copy.", "info")
				return
			end
			if Inventory.count(s.profile.inventory, u.itemId) >= itemDef.stackLimit then
				services.PlayerService.notify(player, "No room to carry it.", "warn")
				return
			end
			Progress.claim(s.profile.claims, u.id)
			addItem(s, u.itemId, 1)
			services.SaveService.markDirty(player)
			services.PlayerService.pushInventory(player)
			services.PlayerService.notify(
				player,
				"Collected your " .. displayName .. ". Party members must collect their own.",
				"info"
			)
			DiscoveryService.discover(player, u.discoveryId, u.label)
		end)
	end
end

function DiscoveryService.init(s)
	services = s
end

function DiscoveryService.start()
	buildPickups()
	-- Volumes are tracked live: pocket versions (and anything else built after boot) add and remove their own.
	local volumes: { [BasePart]: boolean } = {}
	local function track(inst: Instance)
		if inst:IsA("BasePart") then
			volumes[inst] = true
		end
	end
	for _, inst in CollectionService:GetTagged("DiscoveryVolume") do
		track(inst)
	end
	CollectionService:GetInstanceAddedSignal("DiscoveryVolume"):Connect(track)
	CollectionService:GetInstanceRemovedSignal("DiscoveryVolume"):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then
			volumes[inst] = nil
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player, s in services.PlayerService.all() do
				local pos = services.PlayerService.position(player)
				if not pos then
					continue
				end
				for v in volumes do
					local id = v:GetAttribute("ChamberId")
					if type(id) ~= "string" or s.profile.discoveries[id] or not v.Parent then
						continue
					end
					local rel = v.CFrame:PointToObjectSpace(pos)
					local h = v.Size / 2
					if math.abs(rel.X) <= h.X and math.abs(rel.Y) <= h.Y + 3 and math.abs(rel.Z) <= h.Z then
						local label = v:GetAttribute("DiscoveryLabel")
						DiscoveryService.discover(player, id, if type(label) == "string" then label else nil)
					end
				end
			end
		end
	end)
end

return DiscoveryService
