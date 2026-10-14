--!strict
-- Repeatable missions (section 06):
-- M01 Nearby Rescue: follow a readable cue to a survivor, treat them (supplies make it faster; no supplies is slower
--     but never a lock), then escort on foot or carry (slower) to a shelter.
-- M02 Missing Survey Cache: find an instrument case from a described landmark; each participant opens their own copy.
-- M07 Creature Observation: gain one new research stage on a creature, then return to any shelter. Killing is not
--     the assumed goal.
-- Objectives are generated only where they are reachable from the player's last shelter. Failure, abandonment,
-- disconnect and late-join behavior are documented in docs/MISSIONS.md.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local ItemDefs = require(Shared.Data.ItemDefs)

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
	state: "travel" | "treat" | "ready" | "escort" | "carried" | "collect" | "observe" | "return" | "done" | "failed",
	createdAt: number,
	case: BasePart?, -- M02 instrument case
	collected: { [number]: boolean }, -- M02 per-participant claims
	creatureId: string?, -- M07 target
	startStage: number?, -- M07 research stage when accepted
}

local NEARBY_HOPS = 3
local M02_REWARD = { coins = 20, items = { ["power.cell"] = 1, ["med.cloth_dressing"] = 1, ["mat.fastener"] = 1 } }
local M07_REWARD_COINS = 30
local COOLDOWNS = { M01 = 120, M02 = 180, M07 = 240 } -- TUNE seconds
local LORE = {
	"Field note, smudged: \"Measured the gallery twice. The second time it was eleven metres longer.\"",
	"Inventory slip: two lamps, one theodolite, rope 40 m. Signed E. Renaud. The date is torn off.",
	"Survey sketch: a corridor drawn, crossed out, and drawn again one chamber to the left.",
	"Pencil on a card: \"If you hear us calling from the water, do not answer.\"",
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

-- Chambers within a few corridors of the player's last shelter, honoring closed puzzle gates (section 06:
-- generate a reachable objective before offering it).
local function nearbyChambers(player: Player): { [string]: boolean }
	local s = services.PlayerService.get(player)
	local home = WorldDefs.homeChamber(s and s.profile.lastShelterId or "")
	local out = {}
	for id, d in WorldDefs.hops(home, services.PuzzleService.openGates()) do
		if d <= NEARBY_HOPS then
			out[id] = true
		end
	end
	return out
end

local function pushMission(m: Mission)
	local payload = {
		id = m.id,
		template = m.template,
		title = (WorldDefs.Missions[m.template] :: any).name,
		state = m.state,
		objective = (function()
			if m.template == "M02" then
				local region = WorldDefs.region((assert(WorldDefs.chamber(m.spawn.chamberId))).regionId)
				return "A survey cache was left " .. m.spawn.clue .. " (" .. (region and region.name or "?") .. "). Each of you opens your own copy."
			elseif m.template == "M07" then
				local c = WorldDefs.creatureById(m.creatureId or "")
				if m.state == "return" then
					return "Observation recorded. Return to any shelter with your notes."
				end
				local hint = c and c.hints and c.hints[(m.startStage or 0) + 1] or ""
				return "Observe the " .. (c and c.name or "?") .. ": " .. hint
			end
			if m.state == "travel" then
				return "A survivor was last heard near " .. (assert(WorldDefs.chamber(m.spawn.chamberId))).label .. ". Look for a " .. string.gsub(m.spawn.cue, "_", " ") .. "."
			elseif m.state == "treat" or m.state == "ready" then
				return "Treat the survivor, then escort or carry them to a shelter."
			elseif m.state == "escort" then
				return "Lead the survivor to a shelter. Keep close."
			elseif m.state == "carried" then
				return "Carry the survivor to a shelter."
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
	if m.case then
		m.case:Destroy()
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
	local active = missionFor(player)
	local list = {}
	for id, def in WorldDefs.Missions do
		local cd = s.profile.missionCooldowns[id] or 0
		table.insert(list, {
			id = id,
			name = def.name,
			status = def.status,
			estimate = def.estimate,
			risk = def.risk,
			available = def.status == "SLICE" and os.time() >= cd and active == nil,
			cooldown = if def.status == "SLICE" then math.max(0, cd - os.time()) else nil,
		})
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	services.PlayerService.send(player, "missionList", list)
end

local function newMission(player: Player, template: string, spawn: any): Mission
	return {
		id = HttpService:GenerateGUID(false),
		template = template,
		owner = player,
		participants = {},
		spawn = spawn,
		npc = nil,
		cue = nil,
		state = "travel",
		createdAt = os.clock(),
		case = nil,
		collected = {},
		creatureId = nil,
		startStage = nil,
	}
end

local function spotBusy(spotId: string): boolean
	for _, m in missions do
		if m.spawn and m.spawn.id == spotId then
			return true
		end
	end
	return false
end

local function addParty(m: Mission, player: Player)
	-- A party accepts a shared objective; rewards remain individual.
	for _, mem in services.PartyService.members(player) do
		if not missionFor(mem) then
			m.participants[mem.UserId] = true
		end
	end
end

local function buildCase(m: Mission)
	local p = Instance.new("Part")
	p.Name = "InstrumentCase"
	p.Anchored = true
	p.Size = Vector3.new(2.2, 1.2, 1.4)
	p.CFrame = CFrame.new(m.spawn.pos.x, m.spawn.pos.y - 0.3, m.spawn.pos.z) * CFrame.Angles(0, 0.6, 0)
	p.Color = Color3.fromRGB(70, 60, 44)
	p.Material = Enum.Material.Leather
	local region = (assert(WorldDefs.chamber(m.spawn.chamberId))).regionId
	p.Parent = services.WorldBuilder.folder(region)
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Open your copy"
	pp.ObjectText = "Survey instrument case"
	pp.HoldDuration = 1
	pp.MaxActivationDistance = 7
	pp.RequiresLineOfSight = false
	pp.Parent = p
	pp.Triggered:Connect(function(player)
		MissionService.collectCache(player, m)
	end)
	m.case = p
end

function MissionService.accept(player: Player, templateId: string)
	local s = services.PlayerService.get(player)
	local def = WorldDefs.Missions[templateId]
	if not s or not def or def.status ~= "SLICE" or missionFor(player) then
		return
	end
	if os.time() < (s.profile.missionCooldowns[templateId] or 0) then
		return
	end
	local near = nearbyChambers(player)
	if templateId == "M01" or templateId == "M02" then
		local pool = if templateId == "M01" then WorldDefs.RescueSpawns else WorldDefs.CacheSpots
		local candidates = {}
		for _, sp in pool do
			if near[sp.chamberId] and not spotBusy(sp.id) then
				table.insert(candidates, sp)
			end
		end
		if #candidates == 0 then
			services.PlayerService.notify(player, "Nothing suitable is close to your last shelter right now. Try again shortly or register a different shelter.", "warn")
			return
		end
		local m = newMission(player, templateId, candidates[math.random(1, #candidates)])
		addParty(m, player)
		missions[m.id] = m
		if templateId == "M01" then
			m.cue = buildCue(m)
			m.npc = buildNpc(m)
		else
			m.state = "collect"
			buildCase(m)
		end
		pushMission(m)
	elseif templateId == "M07" then
		-- Personal objective: pick a built creature whose research is not yet complete (stage caps where the
		-- final stage needs features that are not built yet, e.g. the Sidelooker's sketch comparison).
		local choices = {}
		for _, c in WorldDefs.Creatures do
			if c.status == "SLICE" then
				local stage = s.profile.research[c.id] and s.profile.research[c.id].stage or 0
				local cap = if c.id == "C01" then 3 else #c.researchEvidence
				if stage < cap then
					table.insert(choices, { c = c, stage = stage })
				end
			end
		end
		if #choices == 0 then
			services.PlayerService.notify(player, "Your journal already holds everything observable here.", "info")
			return
		end
		local pick = choices[math.random(1, #choices)]
		local m = newMission(player, "M07", nil)
		m.participants[player.UserId] = true
		m.creatureId = pick.c.id
		m.startStage = pick.stage
		m.state = "observe"
		missions[m.id] = m
		pushMission(m)
	end
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
		carry.KeyboardKeyCode = Enum.KeyCode.V
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
						-- Bounded wait: MoveToFinished never fires if the survivor is destroyed mid-move.
						local t0 = os.clock()
						while
							m.state == "escort"
							and npc.Parent
							and (root.Position - wps[i].Position).Magnitude > 3
							and os.clock() - t0 < 2
						do
							task.wait(0.1)
						end
						if m.state ~= "escort" or not npc.Parent then
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
	local sess = services.PlayerService.get(player)
	if not sess or sess.carrying or sess.vitals.condition == "downed" then
		services.PlayerService.notify(player, "Your hands are already full.", "warn")
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

local function reward(p: Player, template: string, coins: number, items: { [string]: number }?)
	local s = services.PlayerService.get(p)
	if not s then
		return
	end
	s.profile.coins += coins
	s.profile.missionCooldowns[template] = os.time() + (COOLDOWNS[template] or 120)
	local key = template .. ".completions"
	s.profile.storyStates[key] = tostring((tonumber(s.profile.storyStates[key]) or 0) + 1)
	if items then
		-- anything that does not fit goes to shelter escrow rather than being lost
		local leftover = Inventory.addContents(s.profile.inventory, ItemDefs.get, items, "expedition")
		for id, n in leftover do
			s.profile.escrow[id] = (s.profile.escrow[id] or 0) + n
		end
	end
	services.SaveService.markDirty(p)
	task.spawn(services.SaveService.commit, p)
	services.PlayerService.pushInventory(p)
end

function MissionService.collectCache(player: Player, m: Mission)
	if m.state ~= "collect" then
		return
	end
	if not m.participants[player.UserId] then
		if m.owner and services.PartyService.sameParty(player, m.owner) then
			m.participants[player.UserId] = true -- late join
		else
			services.PlayerService.notify(player, "This cache belongs to another group's survey.", "info")
			return
		end
	end
	if m.collected[player.UserId] then
		services.PlayerService.notify(player, "You already took your copy.", "info")
		return
	end
	if not services.PlayerService.hold(player, 1.5) then
		return
	end
	m.collected[player.UserId] = true
	reward(player, "M02", M02_REWARD.coins, M02_REWARD.items)
	local lore = LORE[math.random(1, #LORE)]
	services.PlayerService.notify(player, string.format("Cache recovered (+%d coins). %s", M02_REWARD.coins, lore), "info")
	services.PlayerService.send(player, "mission", { id = m.id, state = "done" })
	-- the case stays until every participant has their copy
	for uid in m.participants do
		if not m.collected[uid] and Players:GetPlayerByUserId(uid) then
			return
		end
	end
	clearMission(m, "done")
end

-- Called by CreatureService whenever a player's research stage rises.
function MissionService.onResearch(player: Player, creatureId: string, stage: number)
	local m = missionFor(player)
	if m and m.template == "M07" and m.state == "observe" and m.creatureId == creatureId and stage > (m.startStage or 0) then
		m.state = "return"
		pushMission(m)
	end
end

local function complete(m: Mission)
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		local s = p and services.PlayerService.get(p)
		if p and s then
			reward(p, "M01", Config.Missions.nearbyRescueRewardCoins, nil)
			s.profile.missionCooldowns.M01 = os.time() + Config.Missions.nearbyRescueCooldownSeconds
			services.PlayerService.notify(p, string.format("Rescue complete. +%d coins.", Config.Missions.nearbyRescueRewardCoins), "info")
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
	if not m then
		return
	end
	if m.template == "M07" and m.state == "return" then
		reward(player, "M07", M07_REWARD_COINS, nil)
		services.PlayerService.notify(player, string.format("Observation filed in the journal. +%d coins.", M07_REWARD_COINS), "info")
		clearMission(m, "done")
		return
	end
	if m.template ~= "M01" or m.state ~= "escort" or not m.npc then
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
	-- Only a rescue depends on staying alive; a cache or an observation can still be finished after respawning.
	local m = missionFor(player)
	if m and m.template ~= "M01" then
		return
	end
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
			-- Returning the Act I tag to Mara takes precedence over the mission list.
			if services.StoryService and services.StoryService.atBoard(player) then
				return
			end
			MissionService.list(player)
		end)
	end
	-- Missions time out if nobody reaches the survivor for 25 minutes (documented).
	task.spawn(function()
		while true do
			task.wait(15)
			for _, m in missions do
				if (m.state == "travel" or m.state == "collect" or m.state == "observe") and os.clock() - m.createdAt > 25 * 60 then
					clearMission(m, "failed", "timed out")
				end
			end
		end
	end)
end

return MissionService
