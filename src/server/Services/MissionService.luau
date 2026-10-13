--!strict
-- M01 Nearby Rescue (section 06). Follow a readable cue to a survivor, treat them (supplies make it faster; no
-- supplies is slower but never a lock), then escort on foot or carry (slower) to a shelter.
-- Failure, abandonment, disconnect and late-join behavior are documented in docs/MISSIONS.md.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)

local MissionService = {}
local services: any

type Mission = {
	id: string,
	template: string,
	owner: Player, -- player responsible; transfers to a remaining party member on leave
	participants: { [number]: boolean },
	spawn: any,
	npc: Model?,
	cue: BasePart?,
	state: "travel" | "treat" | "ready" | "escort" | "carried" | "done" | "failed",
	createdAt: number,
}

local missions: { [string]: Mission } = {}
local SURVIVOR_NAMES = { "Survey porter", "Lost cataphile", "Night inspector", "Cable fitter", "Student surveyor" }

local function missionFor(player: Player): Mission?
	for _, m in missions do
		if m.participants[player.UserId] and m.state ~= "done" and m.state ~= "failed" then
			return m
		end
	end
	return nil
end

local function reachableChambers(): { [string]: boolean }
	local seen = { ["R01.alcove_exterior"] = true }
	local queue = { "R01.alcove_exterior" }
	while #queue > 0 do
		local cur = table.remove(queue, 1)
		for _, c in WorldDefs.Corridors do
			local other = if c.from == cur then c.to elseif c.to == cur then c.from else nil
			if other and not seen[other] then
				seen[other] = true
				table.insert(queue, other)
			end
		end
	end
	return seen
end

local function pushMission(m: Mission)
	local payload = {
		id = m.id,
		template = m.template,
		title = "Nearby Rescue",
		state = m.state,
		objective = (function()
			if m.state == "travel" then
				return "A survivor was last heard near " .. (assert(WorldDefs.chamber(m.spawn.chamberId))).label .. ". Look for a " .. string.gsub(m.spawn.cue, "_", " ") .. "."
			elseif m.state == "treat" or m.state == "ready" then
				return "Treat the survivor, then escort or carry them to a shelter."
			elseif m.state == "escort" then
				return "Lead the survivor to the Worker's Alcove. Keep close."
			elseif m.state == "carried" then
				return "Carry the survivor to the Worker's Alcove."
			end
			return ""
		end)(),
	}
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			services.PlayerService.send(p, "mission", payload)
		end
	end
end

local function clearMission(m: Mission, state: "done" | "failed", reason: string?)
	m.state = state
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			services.PlayerService.send(p, "mission", { id = m.id, state = state, reason = reason })
			local s = services.PlayerService.get(p)
			if s and s.carrying and s.carrying.kind == "npc" and s.carrying.target == m.npc then
				if s.carrying.weld then
					s.carrying.weld:Destroy()
				end
				s.carrying = nil
				s.dirtyState = true
			end
		end
	end
	if m.npc then
		m.npc:Destroy()
	end
	if m.cue then
		m.cue:Destroy()
	end
	missions[m.id] = nil
end

local function buildNpc(m: Mission): Model
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor = Color3.fromRGB(200, 170, 140)
	desc.TorsoColor = Color3.fromRGB(70, 74, 60)
	desc.LeftArmColor, desc.RightArmColor = desc.HeadColor, desc.HeadColor
	desc.LeftLegColor, desc.RightLegColor = Color3.fromRGB(50, 50, 55), Color3.fromRGB(50, 50, 55)
	local model = Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	model.Name = SURVIVOR_NAMES[math.random(1, #SURVIVOR_NAMES)]
	local h = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Subject
	h.NameDisplayDistance = 12
	h.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	h.WalkSpeed = Config.Movement.walkSpeed * 0.9
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	model:PivotTo(CFrame.new(m.spawn.pos.x, m.spawn.pos.y + 3, m.spawn.pos.z))
	model.Parent = services.WorldBuilder.folder("R01")
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	h.Sit = true -- slumped against the wall until treated
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "RescuePrompt"
	pp.ActionText = "Treat survivor"
	pp.ObjectText = model.Name
	pp.HoldDuration = 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = root
	pp.Triggered:Connect(function(player)
		MissionService.interact(player, m)
	end)
	return model
end

local function buildCue(m: Mission): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Name = "RescueCue"
	local pos = Vector3.new(m.spawn.pos.x, 0.3, m.spawn.pos.z)
	if m.spawn.cue == "dropped_lamp" then
		p.Size = Vector3.new(0.8, 1.2, 0.8)
		p.CFrame = CFrame.new(pos + Vector3.new(3, 0.4, -3)) * CFrame.Angles(0, 0, math.rad(80))
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 190, 120)
		local l = Instance.new("PointLight")
		l.Range = 10
		l.Brightness = 0.7
		l.Color = p.Color
		l.Parent = p
	elseif m.spawn.cue == "rope_end" then
		p.Size = Vector3.new(0.3, 0.3, 8)
		p.CFrame = CFrame.new(pos + Vector3.new(0, 0, -6))
		p.Material = Enum.Material.Fabric
		p.Color = Color3.fromRGB(200, 180, 120)
	else
		p.Size = Vector3.new(4, 3, 0.1)
		p.CFrame = CFrame.new(pos + Vector3.new(0, 3, 4))
		p.Transparency = 1
		local g = Instance.new("SurfaceGui")
		g.Face = Enum.NormalId.Back
		g.Parent = p
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.TextScaled = true
		t.Font = Enum.Font.PermanentMarker
		t.TextColor3 = Color3.fromRGB(235, 235, 225)
		t.Text = "AIDE ↓"
		t.Parent = g
	end
	p.Parent = services.WorldBuilder.folder("R01")
	return p
end

function MissionService.list(player: Player)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local cd = s.profile.missionCooldowns.M01 or 0
	local list = {}
	for id, def in WorldDefs.Missions do
		table.insert(list, {
			id = id,
			name = def.name,
			status = def.status,
			estimate = def.estimate,
			risk = def.risk,
			available = def.status == "SLICE" and os.time() >= cd and missionFor(player) == nil,
			cooldown = if id == "M01" then math.max(0, cd - os.time()) else nil,
		})
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	services.PlayerService.send(player, "missionList", list)
end

function MissionService.accept(player: Player, templateId: string)
	local s = services.PlayerService.get(player)
	if not s or templateId ~= "M01" or missionFor(player) then
		return
	end
	if os.time() < (s.profile.missionCooldowns.M01 or 0) then
		return
	end
	-- Generate a reachable objective before offering it (section 06).
	local reach = reachableChambers()
	local candidates = {}
	for _, sp in WorldDefs.RescueSpawns do
		local busy = false
		for _, m in missions do
			if m.spawn.id == sp.id then
				busy = true
			end
		end
		if reach[sp.chamberId] and not busy then
			table.insert(candidates, sp)
		end
	end
	if #candidates == 0 then
		services.PlayerService.notify(player, "No safe rescue can be offered right now. Try again shortly.", "warn")
		return
	end
	local m: Mission = {
		id = HttpService:GenerateGUID(false),
		template = "M01",
		owner = player,
		participants = {},
		spawn = candidates[math.random(1, #candidates)],
		npc = nil,
		cue = nil,
		state = "travel",
		createdAt = os.clock(),
	}
	-- A party accepts a shared objective; rewards remain individual.
	for _, mem in services.PartyService.members(player) do
		if not missionFor(mem) then
			m.participants[mem.UserId] = true
		end
	end
	missions[m.id] = m
	m.cue = buildCue(m)
	m.npc = buildNpc(m)
	pushMission(m)
end

function MissionService.interact(player: Player, m: Mission)
	if not m.participants[player.UserId] then
		-- Late join: a current party member of the owner may help.
		if services.PartyService.sameParty(player, m.owner) then
			m.participants[player.UserId] = true
		else
			services.PlayerService.notify(player, "This survivor is part of another group's rescue.", "info")
			return
		end
	end
	local s = services.PlayerService.get(player)
	local npc = m.npc
	if not s or not npc then
		return
	end
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart
	local h = npc:FindFirstChildOfClass("Humanoid") :: Humanoid
	local pp = root:FindFirstChild("RescuePrompt") :: ProximityPrompt
	if m.state == "travel" or m.state == "treat" then
		m.state = "treat"
		local useItem = if Inventory.count(s.profile.inventory, "med.bandage") > 0 then "med.bandage"
			elseif Inventory.count(s.profile.inventory, "med.cloth_dressing") > 0 then "med.cloth_dressing"
			else nil
		local secs = (if useItem then 4 else 9) * ((Config.Classes[s.profile.class] or {}).treatTimeMultiplier or 1)
		if not useItem then
			services.PlayerService.notify(player, "No supplies: steadying them by hand takes longer.", "info")
		end
		if not services.PlayerService.hold(player, secs) then
			return
		end
		if useItem then
			Inventory.remove(s.profile.inventory, useItem, 1)
			services.SaveService.markDirty(player)
			services.PlayerService.pushInventory(player)
		end
		m.state = "ready"
		h.Sit = false
		pp.ActionText = "Escort (walk)"
		local carry = Instance.new("ProximityPrompt")
		carry.Name = "CarryPrompt"
		carry.ActionText = "Carry (slower)"
		carry.ObjectText = npc.Name
		carry.KeyboardKeyCode = Enum.KeyCode.F
		carry.UIOffset = Vector2.new(0, 60)
		carry.HoldDuration = 0.5
		carry.MaxActivationDistance = 8
		carry.RequiresLineOfSight = false
		carry.Parent = root
		carry.Triggered:Connect(function(p2)
			MissionService.carry(p2, m)
		end)
		pushMission(m)
	elseif m.state == "ready" then
		MissionService.escort(player, m)
	elseif m.state == "escort" then
		m.owner = player -- the survivor follows whoever asked last
	end
end

function MissionService.escort(player: Player, m: Mission)
	local npc = m.npc
	if not npc then
		return
	end
	m.state = "escort"
	m.owner = player
	pushMission(m)
	local h = npc:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart
	task.spawn(function()
		while m.state == "escort" and npc.Parent do
			local target = services.PlayerService.position(m.owner)
			if target and (target - root.Position).Magnitude > 6 then
				local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = false })
				local ok = pcall(function()
					path:ComputeAsync(root.Position, target)
				end)
				if ok and path.Status == Enum.PathStatus.Success then
					local wps = path:GetWaypoints()
					for i = 2, math.min(#wps, 4) do
						h:MoveTo(wps[i].Position)
						h.MoveToFinished:Wait()
						if m.state ~= "escort" then
							break
						end
					end
				else
					h:MoveTo(target)
					task.wait(0.5)
				end
			else
				task.wait(0.4)
			end
		end
	end)
end

function MissionService.carry(player: Player, m: Mission)
	local npc = m.npc
	if not npc or (m.state ~= "ready" and m.state ~= "escort") then
		return
	end
	if not m.participants[player.UserId] then
		return
	end
	local pr = services.PlayerService.rootPart(player)
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart
	if not pr or (pr.Position - root.Position).Magnitude > 9 then
		return
	end
	local h = npc:FindFirstChildOfClass("Humanoid") :: Humanoid
	h.PlatformStand = true
	for _, d in npc:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
		end
	end
	root.CFrame = pr.CFrame * CFrame.new(0, 0.6, 1.4)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = pr
	weld.Part1 = root
	weld.Parent = pr
	if not services.PlayerService.startCarryNpc(player, npc, weld) then
		weld:Destroy()
		return
	end
	pcall(function()
		root:SetNetworkOwner(player)
	end)
	m.state = "carried"
	m.owner = player
	pushMission(m)
end

function MissionService.onNpcDropped(_player: Player, npc: Model)
	for _, m in missions do
		if m.npc == npc then
			local h = npc:FindFirstChildOfClass("Humanoid")
			if h then
				h.PlatformStand = false
			end
			for _, d in npc:GetDescendants() do
				if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
					d.CanCollide = true
					d.Massless = false
				end
			end
			local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				pcall(function()
					root:SetNetworkOwner(nil)
				end)
			end
			m.state = "ready"
			pushMission(m)
		end
	end
end

local function complete(m: Mission)
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		local s = p and services.PlayerService.get(p)
		if p and s then
			s.profile.coins += Config.Missions.nearbyRescueRewardCoins
			s.profile.missionCooldowns.M01 = os.time() + Config.Missions.nearbyRescueCooldownSeconds
			s.profile.storyStates["M01.completions"] = tostring((tonumber(s.profile.storyStates["M01.completions"]) or 0) + 1)
			services.SaveService.markDirty(p)
			task.spawn(services.SaveService.commit, p)
			services.PlayerService.notify(p, string.format("Rescue complete. +%d coins.", Config.Missions.nearbyRescueRewardCoins), "info")
			services.PlayerService.pushInventory(p)
			services.DirectorService.afterRescue(p)
		end
	end
	clearMission(m, "done")
end

-- Called when a player carrying the survivor enters the shelter.
function MissionService.deliverToShelter(player: Player, npc: Model)
	for _, m in missions do
		if m.npc == npc then
			local s = services.PlayerService.get(player)
			if s and s.carrying then
				if s.carrying.weld then
					s.carrying.weld:Destroy()
				end
				s.carrying = nil
				s.dirtyState = true
			end
			complete(m)
			return
		end
	end
end

-- Escorted survivor close enough when the player registers at the shelter.
function MissionService.onShelterReached(player: Player)
	local m = missionFor(player)
	if not m or m.state ~= "escort" or not m.npc then
		return
	end
	local root = m.npc:FindFirstChild("HumanoidRootPart") :: BasePart
	local p = services.PlayerService.position(player)
	if p and (p - root.Position).Magnitude < 18 then
		complete(m)
	end
end

local function handOver(player: Player, reason: string)
	local m = missionFor(player)
	if not m then
		return
	end
	m.participants[player.UserId] = nil
	if m.owner == player then
		local nextOwner: Player? = nil
		for uid in m.participants do
			nextOwner = Players:GetPlayerByUserId(uid)
			if nextOwner then
				break
			end
		end
		if nextOwner then
			m.owner = nextOwner
			if m.state == "escort" or m.state == "carried" then
				m.state = "ready"
			end
			pushMission(m)
		else
			clearMission(m, "failed", reason)
		end
	end
end

function MissionService.onPlayerDied(player: Player)
	handOver(player, "You died. The survivor was found by another team.")
end

function MissionService.onPlayerLeft(player: Player)
	handOver(player, "disconnected")
end

function MissionService.abandon(player: Player)
	handOver(player, "abandoned")
end

function MissionService.init(s)
	services = s
end

function MissionService.start()
	local CollectionService = game:GetService("CollectionService")
	for _, board in CollectionService:GetTagged("MissionBoard") do
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Missions"
		pp.ObjectText = "Mara Voss's board (placeholder)"
		pp.MaxActivationDistance = 10
		pp.RequiresLineOfSight = false
		pp.Parent = board
		pp.Triggered:Connect(function(player)
			MissionService.list(player)
		end)
	end
	-- Missions time out if nobody reaches the survivor for 25 minutes (documented).
	task.spawn(function()
		while true do
			task.wait(15)
			for _, m in missions do
				if m.state == "travel" and os.clock() - m.createdAt > 25 * 60 then
					clearMission(m, "failed", "timed out")
				end
			end
		end
	end)
end

return MissionService
