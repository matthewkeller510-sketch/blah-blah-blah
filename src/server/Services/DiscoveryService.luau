--!strict
-- Landmark discovery, scavenging and unique pickups (sections 08, 14; owner rules F12, F14).
-- Discoveries made while grouped are committed to each online party member's personal record (no proximity
-- requirement). Pickups are per player: each player claims their own copy; scavenging cooldowns are per player.

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Progress = require(Shared.Logic.Progress)

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

function DiscoveryService.discover(player: Player, discoveryId: string, label: string?)
	local recs = {}
	for _, m in services.PartyService.members(player) do
		local s = services.PlayerService.get(m)
		if s then
			recs[m.UserId] = s.profile.discoveries
		end
	end
	local newly = Progress.commitDiscovery(recs, discoveryId)
	for _, uid in newly do
		local p = game:GetService("Players"):GetPlayerByUserId(uid)
		if p then
			services.SaveService.markDirty(p)
			services.PlayerService.send(p, "discovery", {
				id = discoveryId,
				label = label or LABELS[discoveryId] or discoveryId,
				byOther = p ~= player and player.DisplayName or nil,
			})
		end
	end
end

local function grant(player: Player, contents: { [string]: number }): { [string]: number }
	local s = services.PlayerService.get(player)
	local got = {}
	if not s then
		return got
	end
	for id, n in contents do
		local added = Inventory.add(s.profile.inventory, ItemDefs.get, id, n, "expedition")
		if added > 0 then
			got[id] = added
		end
	end
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	return got
end

local function describe(got: { [string]: number }): string
	local parts = {}
	for id, n in got do
		table.insert(parts, string.format("%d× %s", n, (ItemDefs.get(id) :: any).displayName))
	end
	return if #parts == 0 then "nothing you can carry" else table.concat(parts, ", ")
end

local function buildPickups()
	local f = Instance.new("Folder")
	f.Name = "Pickups"
	f.Parent = services.WorldBuilder.folder("R01")
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
		pp.Triggered:Connect(function(player)
			local s = services.PlayerService.get(player)
			if not s then
				return
			end
			if site.requiresLight and not s.lightOn then
				services.PlayerService.notify(player, "Too dark to search this properly. You need light here.", "warn")
				return
			end
			local key = "scav:" .. site.id
			local ready = s.profile.missionCooldowns[key] or 0
			if os.time() < ready then
				services.PlayerService.notify(player, "You already searched this recently. Come back later.", "info")
				return
			end
			s.profile.missionCooldowns[key] = os.time() + site.respawnSeconds
			local got = grant(player, site.contents)
			services.PlayerService.notify(player, "Found " .. describe(got) .. ".", "info")
		end)
	end
	for _, u in WorldDefs.UniquePickups do
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
		pp.ObjectText = (ItemDefs.get(u.itemId) :: any).displayName
		pp.HoldDuration = 0.6
		pp.MaxActivationDistance = 7
		pp.RequiresLineOfSight = false
		pp.Parent = p
		pp.Triggered:Connect(function(player)
			local s = services.PlayerService.get(player)
			if not s then
				return
			end
			if s.profile.claims[u.id] then
				services.PlayerService.notify(player, "You already collected your copy.", "info")
				return
			end
			if Inventory.count(s.profile.inventory, u.itemId) >= (ItemDefs.require(u.itemId)).stackLimit then
				services.PlayerService.notify(player, "No room to carry it.", "warn")
				return
			end
			Progress.claim(s.profile.claims, u.id)
			grant(player, { [u.itemId] = 1 })
			services.PlayerService.notify(player, "Collected your " .. pp.ObjectText .. ". Party members must collect their own.", "info")
			DiscoveryService.discover(player, u.discoveryId, "Expedition survey tag")
		end)
	end
end

function DiscoveryService.init(s)
	services = s
end

function DiscoveryService.start()
	buildPickups()
	local volumes = CollectionService:GetTagged("DiscoveryVolume")
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player, s in services.PlayerService.all() do
				local pos = services.PlayerService.position(player)
				if not pos then
					continue
				end
				for _, v in volumes do
					local id = v:GetAttribute("ChamberId")
					if s.profile.discoveries[id] then
						continue
					end
					local rel = v.CFrame:PointToObjectSpace(pos)
					local h = v.Size / 2
					if math.abs(rel.X) <= h.X and math.abs(rel.Y) <= h.Y + 3 and math.abs(rel.Z) <= h.Z then
						DiscoveryService.discover(player, id)
					end
				end
			end
		end
	end)
end

return DiscoveryService
