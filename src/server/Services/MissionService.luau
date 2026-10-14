--!strict
-- Repeatable missions (section 06; docs/MILESTONE-3.md 4.4) and the Act II story rescue:
-- M01 Nearby Rescue: follow a readable cue to a survivor, treat them (supplies make it faster; no supplies is slower
--     but never a lock), then escort on foot or carry (slower) to a shelter.
-- M02 Missing Survey Cache: find an instrument case from a described landmark; each participant opens their own copy.
-- M03 Medical Delivery: an injured (generic) survey worker near the last shelter; each participant chooses how many
--     dressings, bandages or splints to hand over; the reward scales with what was delivered. Never a store.
-- M04 Power Restoration: personal; completes when the private breaker in your S04 interior is repaired.
-- M05 Waterworks Passage: reach the Overflow Vault (loud sluice gates or the long dry route), open your own
--     sluice-keeper's cache, then reach any shelter.
-- M07 Creature Observation: gain one new research stage on a reachable creature, then return to any shelter.
-- M09 Shelter Establishment: personal; register a known shelter and build stage 1 of any safety upgrade.
-- M11 Lost Belongings: personal; return to your own death or departure bag. Never coins; experience only for your
--     own recovery (a party member's escrow recovery ends it without), at most once per M11 experience cooldown.
-- A2.rescue: Act II step 2, the rescue of Noah Perrin in the Silt Works, reusing the M01 rescue rules.
-- Objectives are generated only where they are reachable from the player's last shelter (closed gates are walls).
-- Rules live in Logic/MissionRules; failure, abandonment, disconnect and late join are documented in docs/MISSIONS.md.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local ItemDefs = require(Shared.Data.ItemDefs)
local StoryDefs = require(Shared.Data.StoryDefs)
local Inventory = require(Shared.Logic.Inventory)
local MissionRules = require(Shared.Logic.MissionRules)
local Story = require(Shared.Logic.Story)

local MissionService = {}
local services: any

type MissionState =
	"travel"
	| "treat"
	| "ready"
	| "escort"
	| "carried"
	| "collect"
	| "deliver"
	| "observe"
	| "return"
	| "work"
	| "done"
	| "failed"

type Mission = {
	id: string,
	template: string,
	owner: Player, -- player responsible; transfers to a remaining participant on leave
	participants: { [number]: boolean },
	spawn: any, -- RescueSpawn | CacheSpot | MissionSpot | nil (personal objectives)
	npc: Model?, -- rescue survivor or injured worker
	cue: BasePart?,
	case: BasePart?, -- M02 instrument case
	state: MissionState,
	createdAt: number,
	touchedAt: number, -- last progress (os.clock); inactivity timeouts use it
	collected: { [number]: boolean }, -- per-participant claims and turn-ins (M02 case, M03 delivery, M05 cache)
	creatureId: string?, -- M07 target
	startStage: number?, -- M07 research stage when accepted
	target: string?, -- M09 shelter id, M11 bag id
	targetKind: string?, -- M11 bag kind ("death" | "logout")
	escortToken: number, -- only the newest escort loop may move the survivor (B12)
	noted: boolean, -- M09: the registration half is done (objective text changed once)
}

local LORE = {
	'Field note, smudged: "Measured the gallery twice. The second time it was eleven metres longer."',
	"Inventory slip: two lamps, one theodolite, rope 40 m. Signed E. Renaud. The date is torn off.",
	"Survey sheet: a corridor drawn, crossed out, and drawn again one chamber to the left.",
	'Pencil on a card: "If you hear us calling from the water, do not answer."',
}
local SURVIVOR_NAMES = { "Survey porter", "Lost cataphile", "Night inspector", "Cable fitter", "Student surveyor" }
-- Generic survivors and workers get varied, plain work clothes (never a named character's silhouette).
local SKINS = {
	Color3.fromRGB(226, 196, 170),
	Color3.fromRGB(200, 170, 140),
	Color3.fromRGB(150, 110, 84),
	Color3.fromRGB(110, 78, 58),
	Color3.fromRGB(84, 60, 46),
}
local CLOTHES = {
	{ Color3.fromRGB(70, 74, 60), Color3.fromRGB(50, 50, 55) },
	{ Color3.fromRGB(96, 64, 48), Color3.fromRGB(44, 44, 50) },
	{ Color3.fromRGB(60, 70, 88), Color3.fromRGB(54, 52, 48) },
	{ Color3.fromRGB(120, 108, 74), Color3.fromRGB(48, 52, 46) },
	{ Color3.fromRGB(88, 50, 52), Color3.fromRGB(40, 42, 46) },
}
local NOAH_LOOK =
	{ skin = Color3.fromRGB(210, 180, 150), torso = Color3.fromRGB(120, 140, 150), legs = Color3.fromRGB(70, 70, 74) }

local DELIVERY_RANGE = 10
local CACHE_RANGE = 8
local RESCUE_ESCORT_RADIUS = 18

local M02_ITEMS = { ["power.cell"] = 1, ["med.cloth_dressing"] = 1, ["mat.fastener"] = 1 }

-- Coins for a template, one source for every payout and every text (MissionRules.coinReward).
local function coinsFor(template: string, delivered: number?): number
	return MissionRules.coinReward(template, Config.Missions, delivered)
end

local missions: { [string]: Mission } = {}
local reservedSpots: { [string]: boolean } = {} -- spots held while an objective is being built
local starting: { [Player]: boolean } = {} -- one accept at a time per player
local m05Cache: BasePart? = nil
local idleNoah: Model? = nil
-- M11: bag ids each owner recovered themselves this session (RecoveryService.recover reports them). A bag that left
-- its slot without this mark went to the owner's shelter escrow through a party member (no experience).
local ownerRecovered: { [Player]: { [string]: boolean } } = {}

-- Helpers ------------------------------------------------------------------------------------------

local function missionFor(player: Player): Mission?
	for _, m in missions do
		if m.participants[player.UserId] and m.state ~= "done" and m.state ~= "failed" then
			return m
		end
	end
	return nil
end

local function missionForNpc(npc: Model): Mission?
	for _, m in missions do
		if m.npc == npc then
			return m
		end
	end
	return nil
end

local function titleOf(template: string): string
	if template == StoryDefs.Rescue.template then
		return StoryDefs.Rescue.title
	end
	local def = WorldDefs.Missions[template]
	return if def then def.name else template
end

local function touch(m: Mission)
	m.touchedAt = os.clock()
end

-- pcall with a fixed (ok, error) shape for the type checker.
local function try(fn: (...any) -> ...any, ...: any): (boolean, any)
	return pcall(fn, ...)
end

local function online(p: Player?): boolean
	return p ~= nil and p.Parent ~= nil and services.PlayerService.get(p) ~= nil
end

local function notify(p: Player, text: string, kind: string?)
	if p.Parent then
		services.PlayerService.notify(p, text, kind)
	end
end

-- Every rescue, delivery and cache interaction needs a player who can act (alive, not downed, not dead, not
-- carried), checked when it starts and again after its hold: a body waiting to respawn never joins, treats,
-- escorts, carries, collects or delivers (review round 2, finding 14).
local function canAct(p: Player): boolean
	return services.PlayerService.canAct(p)
end

local function openGates(): { [string]: boolean }
	local ok, gates = pcall(function()
		return services.PuzzleService.openGates()
	end)
	return if ok and type(gates) == "table" then gates else {}
end

-- Hop distances from the player's last shelter, honoring closed puzzle gates (section 06: reachable objectives).
local function homeHops(player: Player): { [string]: number }
	local s = services.PlayerService.get(player)
	local home = WorldDefs.homeChamber(s and s.profile.lastShelterId or "")
	return WorldDefs.hops(home, openGates())
end

local function regionName(regionId: string): string
	local r = WorldDefs.region(regionId)
	return if r then r.name else regionId
end

local function chamberLabel(chamberId: string): (string, string)
	local c = WorldDefs.chamber(chamberId)
	if not c then
		return chamberId, "?"
	end
	return c.label, regionName(c.regionId)
end

local function cooldownReady(player: Player, template: string): boolean
	local s = services.PlayerService.get(player)
	return s ~= nil and os.time() >= (s.profile.missionCooldowns[template] or 0)
end

local function bagsOf(player: Player): { death: any?, logout: any? }
	local rs = services.RecoveryService
	if rs and type(rs.bagsOf) == "function" then
		local ok, bags = pcall(rs.bagsOf, player)
		if ok and type(bags) == "table" then
			return bags
		end
	end
	-- Local fallback until RecoveryService.bagsOf (world package) is merged: the owner's own records.
	local s = services.PlayerService.get(player)
	return if s then s.profile.bags else {}
end

local function grantXp(player: Player, key: string, amount: number)
	local ps = services.PlayerService
	if ps and type(ps.grantXp) == "function" then
		task.spawn(ps.grantXp, player, key, amount)
	end
end

local function storyOnFact(player: Player)
	if services.StoryService and services.StoryService.onFact then
		services.StoryService.onFact(player)
	end
end

-- Durable commit, then the success text (section 20 / B5: never show success before the write returns).
local function commitThen(player: Player, text: string)
	task.spawn(function()
		local ok = services.SaveService.commit(player)
		if ok then
			notify(player, text .. " Saved.", "info")
		else
			notify(player, text .. " Saving failed this time; it will retry.", "warn")
		end
	end)
end

-- Objectives ---------------------------------------------------------------------------------------

local function rescueObjective(m: Mission): string
	local noah = m.template == StoryDefs.Rescue.template
	if m.state == "travel" then
		if noah then
			return StoryDefs.Rescue.travel
		end
		return "A survivor was last heard near "
			.. (chamberLabel(m.spawn.chamberId))
			.. ". Look for a "
			.. string.gsub(m.spawn.cue, "_", " ")
			.. "."
	elseif m.state == "treat" or m.state == "ready" then
		return if noah
			then "Treat Noah Perrin, then escort or carry him to any shelter."
			else "Treat the survivor, then escort or carry them to a shelter."
	elseif m.state == "escort" then
		return if noah
			then "Lead Noah Perrin to a shelter. Keep close."
			else "Lead the survivor to a shelter. Keep close."
	elseif m.state == "carried" then
		return if noah then "Carry Noah Perrin to a shelter." else "Carry the survivor to a shelter."
	end
	return ""
end

local function medicalSitesNear(chamberId: string): { string }
	return MissionRules.medicalSites(
		WorldDefs.ScavengeSites :: any,
		WorldDefs.Chambers :: any,
		WorldDefs.hops(chamberId, openGates()),
		2
	)
end

local function objectiveFor(m: Mission, p: Player): string
	local t = m.template
	local s = services.PlayerService.get(p)
	if MissionRules.isRescue(t) then
		return rescueObjective(m)
	elseif t == "M02" then
		local _, region = chamberLabel(m.spawn.chamberId)
		return "A survey cache was left " .. m.spawn.clue .. " (" .. region .. "). Each of you opens your own copy."
	elseif t == "M03" then
		local label, region = chamberLabel(m.spawn.chamberId)
		local head = "An injured survey worker is waiting in " .. label .. " (" .. region .. "). "
		local opts = if s
			then MissionRules.deliveryOptions(s.profile.inventory, Config.Missions.medicalDeliveryMaxItems)
			else {}
		if #opts == 0 then
			return head .. MissionRules.nothingToGiveText(medicalSitesNear(m.spawn.chamberId))
		end
		return head
			.. string.format(
				"Hand over up to %d dressings, bandages or splints: %d coins plus %d per item.",
				Config.Missions.medicalDeliveryMaxItems,
				Config.Missions.medicalDeliveryBaseCoins,
				Config.Missions.medicalDeliveryCoinsPerItem
			)
	elseif t == "M04" then
		local inv = if s then s.profile.inventory else {}
		local roll = if Inventory.count(inv, "tool.repair_roll") > 0 then "you have one" else "none carried"
		local fuse = if Inventory.count(inv, "tool.fuse_kit") > 0 then "you have one" else "none carried"
		return "Restore the station supply in your Reinforced Service Office: bring a repair tool roll ("
			.. roll
			.. ") and a fuse kit ("
			.. fuse
			.. "; craft one from 2 fuse components and a fastener, or search the Generator Room locker), then fix the breaker cabinet inside the office."
	elseif t == "M05" then
		if m.collected[p.UserId] then
			return string.format("Cache opened. Return to any shelter for %d coins.", coinsFor("M05"))
		end
		return "Reach the Overflow Vault in the Flooded Works — set the loud sluice gates in the Silt Works, or take the long, silent dry route through the Drain Gallery — and open your own sluice-keeper's cache."
	elseif t == "M07" then
		local c = WorldDefs.creatureById(m.creatureId or "")
		if m.state == "return" then
			return "Observation recorded. Return to any shelter with your notes."
		end
		local hint = c and c.hints and c.hints[(m.startStage or 0) + 1] or ""
		return "Observe the " .. (c and c.name or "?") .. ": " .. hint
	elseif t == "M09" then
		local def = WorldDefs.Shelters[m.target or ""]
		if not def then
			return ""
		end
		local registered = s ~= nil and s.profile.discoveries["shelter:" .. def.id] == true
		if registered then
			return "Registered. Now build stage 1 of any safety upgrade inside the "
				.. def.name
				.. ". Further protection is a separate project."
		end
		return "Establish the "
			.. def.name
			.. " ("
			.. regionName(def.regionId)
			.. "): enter it to register it, then build stage 1 of any safety upgrade inside."
	elseif t == "M11" then
		local bags = bagsOf(p)
		local bag = if m.targetKind == "death" then bags.death else bags.logout
		if not bag then
			return ""
		end
		local label = chamberLabel(bag.anchor.anchorId)
		return MissionRules.m11Objective(
			m.targetKind or "death",
			regionName(bag.anchor.regionId),
			label,
			MissionRules.m11XpCooldownSeconds(Config.Missions)
		)
	end
	return ""
end

local function pushMission(m: Mission)
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		if p and online(p) then
			services.PlayerService.send(p, "mission", {
				id = m.id,
				template = m.template,
				title = titleOf(m.template),
				state = m.state,
				objective = objectiveFor(m, p),
			})
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

local function releaseCarry(m: Mission)
	if not m.npc then
		return
	end
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		local s = p and services.PlayerService.get(p)
		if s and s.carrying and s.carrying.kind == "npc" and s.carrying.target == m.npc then
			if s.carrying.weld then
				s.carrying.weld:Destroy()
			end
			s.carrying = nil
			s.dirtyState = true
		end
	end
end

local function destroyProps(m: Mission)
	if m.npc then
		m.npc:Destroy()
		m.npc = nil
	end
	if m.cue then
		m.cue:Destroy()
		m.cue = nil
	end
	if m.case then
		m.case:Destroy()
		m.case = nil
	end
end

-- Ends a mission for everyone still in it. Rescue failures keep the existing "failed" HUD message; other templates
-- end with their own title in the notice (B14: the HUD's failure text names rescues only).
local function clearMission(m: Mission, state: "done" | "failed", reason: string?)
	if missions[m.id] ~= m then
		return
	end
	m.state = state
	missions[m.id] = nil -- first, so nothing triggered while tearing down can clear it twice
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		if p and online(p) then
			if state == "done" then
				services.PlayerService.send(p, "mission", { id = m.id, state = "done" })
			elseif MissionRules.isRescue(m.template) then
				services.PlayerService.send(p, "mission", { id = m.id, state = "failed", reason = reason })
			else
				services.PlayerService.send(p, "mission", { id = m.id, state = "ended" })
				notify(p, titleOf(m.template) .. " ended: " .. tostring(reason or "failed"), "warn")
			end
		end
	end
	releaseCarry(m)
	destroyProps(m)
end

-- The owner must be an online participant so late joins keep working after the owner finishes (B17).
local function ensureOwner(m: Mission)
	if m.participants[m.owner.UserId] and online(m.owner) then
		return
	end
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		if p and online(p) then
			m.owner = p
			return
		end
	end
end

-- Shared objectives where each participant finishes individually close once nobody online is left in them.
local function closeIfFinished(m: Mission)
	if missions[m.id] ~= m then
		return
	end
	-- Participants are removed as they finish (collect, deliver, or return for M05), so anyone online who is
	-- still listed has something left to do.
	for uid in m.participants do
		if Players:GetPlayerByUserId(uid) then
			return
		end
	end
	if m.template == "M03" and m.npc then
		-- The worker walks off toward safety on their own (no escort).
		local npc = m.npc
		m.npc = nil
		local h = npc:FindFirstChildOfClass("Humanoid")
		local pp = npc:FindFirstChild("RescuePrompt", true)
		if pp then
			pp:Destroy()
		end
		if h then
			h.Sit = false
			local gates = openGates()
			for _, cor in WorldDefs.Corridors do
				local other = if cor.from == m.spawn.chamberId
					then cor.to
					elseif cor.to == m.spawn.chamberId then cor.from
					else nil
				local c = other and WorldDefs.chamber(other)
				if c and (cor.gate == nil or gates[cor.gate]) and cor.pocket == nil then
					h:MoveTo(Vector3.new(c.pos.x, c.pos.y + 3, c.pos.z))
					break
				end
			end
		end
		task.delay(12, function()
			npc:Destroy()
		end)
	end
	clearMission(m, "done")
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
		case = nil,
		state = "travel",
		createdAt = os.clock(),
		touchedAt = os.clock(),
		collected = {},
		creatureId = nil,
		startStage = nil,
		target = nil,
		targetKind = nil,
		escortToken = 0,
		noted = false,
	}
end

local function busySpots(): { [string]: boolean }
	local out = table.clone(reservedSpots)
	for _, m in missions do
		if m.spawn and m.spawn.id then
			out[m.spawn.id] = true
		end
	end
	return out
end

-- A party accepts a shared objective; rewards remain individual. Members already busy or on this template's
-- cooldown are not added (B3: cooldowns cannot be bypassed by taking turns).
local function addParty(m: Mission, player: Player)
	m.participants[player.UserId] = true
	for _, mem in services.PartyService.members(player) do
		if mem ~= player and not missionFor(mem) and not starting[mem] and cooldownReady(mem, m.template) then
			m.participants[mem.UserId] = true
		end
	end
end

-- Late join of a shared objective (rescue, cache, delivery, waterworks). Returns true when the player is in it.
local function tryJoin(player: Player, m: Mission): boolean
	if m.participants[player.UserId] then
		return true
	end
	local ok, why = MissionRules.canJoin(
		online(m.owner) and services.PartyService.sameParty(player, m.owner),
		missionFor(player) ~= nil or starting[player] == true,
		cooldownReady(player, m.template)
	)
	if ok then
		m.participants[player.UserId] = true
		touch(m)
		pushMission(m)
		return true
	end
	if why == "party" then
		notify(player, "This belongs to another group's " .. titleOf(m.template) .. ".", "info")
	elseif why == "busy" then
		notify(player, "Finish or abandon your current mission first.", "info")
	else
		notify(
			player,
			"You did this kind of mission recently. Check the mission list for when it is available.",
			"info"
		)
	end
	return false
end

-- Builds a mission prop and registers the mission only when everything succeeded (B11: no zombie missions).
local function launch(m: Mission, build: (() -> ())?)
	if build then
		local ok, err = try(build)
		if not ok then
			destroyProps(m)
			error(err)
		end
		-- Building can yield: anyone who joined another objective meanwhile is not added twice (one mission each).
		for uid in m.participants do
			local p = Players:GetPlayerByUserId(uid)
			if not p or (p ~= m.owner and missionFor(p) ~= nil) then
				m.participants[uid] = nil
			end
		end
		if missionFor(m.owner) ~= nil or not online(m.owner) then
			destroyProps(m)
			return
		end
	end
	missions[m.id] = m
	pushMission(m)
end

-- Rewards: coins, cooldown, completion counter, items; durable commit before the success text.
local function payout(p: Player, template: string, coins: number, items: { [string]: number }?, text: string)
	local s = services.PlayerService.get(p)
	if not s then
		return
	end
	s.profile.coins += coins
	local cd = MissionRules.cooldownSeconds(template, Config.Missions)
	if cd > 0 then
		s.profile.missionCooldowns[template] = os.time() + cd
	end
	local key = template .. ".completions"
	local n = (tonumber(s.profile.storyStates[key]) or 0) + 1
	s.profile.storyStates[key] = tostring(n)
	if items then
		-- anything that does not fit goes to shelter escrow rather than being lost
		local leftover = Inventory.addContents(s.profile.inventory, ItemDefs.get, items, "expedition")
		for id, k in leftover do
			s.profile.escrow[id] = (s.profile.escrow[id] or 0) + k
		end
	end
	services.SaveService.markDirty(p)
	services.PlayerService.pushInventory(p)
	grantXp(p, MissionRules.missionXpKey(template, n), Config.Progression.xp.mission)
	commitThen(p, text)
	-- Deferred: re-evaluating synchronously could re-enter the completion that is paying right now.
	task.defer(storyOnFact, p)
end

-- Survivors and workers ----------------------------------------------------------------------------

-- An R15 figure that can sit, stand, walk and be carried. Parts never intercept world raycasts where Roblox allows
-- it (CanQuery needs CanCollide off; the Humanoid manages its root), and the model postpones pocket changes.
local function buildRig(
	name: string,
	pos: { x: number, y: number, z: number },
	regionId: string,
	skin: Color3,
	torso: Color3,
	legs: Color3
): Model
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor = skin
	desc.TorsoColor = torso
	desc.LeftArmColor, desc.RightArmColor = skin, skin
	desc.LeftLegColor, desc.RightLegColor = legs, legs
	local model = Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	model.Name = name
	local h = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Subject
	h.NameDisplayDistance = 12
	h.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	h.WalkSpeed = Config.Movement.walkSpeed * 0.9
	model:PivotTo(CFrame.new(pos.x, pos.y + 3, pos.z))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanQuery = false
			d.CanTouch = false
			if d.Name ~= "HumanoidRootPart" then
				d.CanCollide = false
			end
		end
	end
	CollectionService:AddTag(model, "PocketBlocker")
	model.Parent = services.WorldBuilder.folder(regionId)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	h.Sit = true -- slumped against the wall until treated
	return model
end

local function addPrompt(model: Model, name: string, action: string, onTrigger: (Player) -> ()): ProximityPrompt
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = action
	pp.ObjectText = model.Name
	pp.HoldDuration = 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = root
	pp.Triggered:Connect(onTrigger)
	return pp
end

-- A survivor or worker that dies or falls out of the world ends its mission instead of locking it (B12).
local function watchSurvivor(model: Model)
	local h = model:FindFirstChildOfClass("Humanoid")
	if h then
		h.Died:Connect(function()
			local m = missionForNpc(model)
			if m then
				clearMission(m, "failed", "the person you were helping was lost")
			end
		end)
	end
end

local function buildSurvivor(m: Mission): Model
	local chamber = assert(WorldDefs.chamber(m.spawn.chamberId), "unknown chamber " .. tostring(m.spawn.chamberId))
	local clothes = CLOTHES[math.random(1, #CLOTHES)]
	local model = buildRig(
		SURVIVOR_NAMES[math.random(1, #SURVIVOR_NAMES)],
		m.spawn.pos,
		chamber.regionId,
		SKINS[math.random(1, #SKINS)],
		clothes[1],
		clothes[2]
	)
	addPrompt(model, "RescuePrompt", "Treat survivor", function(player)
		local mm = missionForNpc(model)
		if mm then
			MissionService.interact(player, mm)
		end
	end)
	watchSurvivor(model)
	return model
end

local function buildWorker(m: Mission): Model
	local chamber = assert(WorldDefs.chamber(m.spawn.chamberId), "unknown chamber " .. tostring(m.spawn.chamberId))
	local clothes = CLOTHES[math.random(1, #CLOTHES)]
	local model = buildRig(
		"Injured survey worker",
		m.spawn.pos,
		chamber.regionId,
		SKINS[math.random(1, #SKINS)],
		clothes[1],
		clothes[2]
	)
	addPrompt(model, "RescuePrompt", "Give supplies", function(player)
		local mm = missionForNpc(model)
		if mm then
			MissionService.openDelivery(player, mm)
		end
	end)
	watchSurvivor(model)
	return model
end

-- Noah Perrin in the Silt Works (Act II step 2): rain shell and a worn messenger bag.
local function buildNoah(): Model
	local def = WorldDefs.Characters.N06
	local pos = assert(def.rescuePos, "N06 has no rescuePos")
	local model = buildRig(def.name, pos, "R03", NOAH_LOOK.skin, NOAH_LOOK.torso, NOAH_LOOK.legs)
	local torso = model:FindFirstChild("UpperTorso") :: BasePart?
	if torso then
		local bag = Instance.new("Part")
		bag.Name = "MessengerBag"
		bag.Size = Vector3.new(1.1, 0.9, 0.35)
		bag.Color = Color3.fromRGB(96, 74, 52)
		bag.Material = Enum.Material.Leather
		bag.CanCollide = false
		bag.CanQuery = false
		bag.CanTouch = false
		bag.Massless = true
		bag.CFrame = torso.CFrame * CFrame.new(-1.1, -0.9, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = bag
		weld.Parent = bag
		bag.Parent = model
	end
	addPrompt(model, "RescuePrompt", "Help Noah Perrin", function(player)
		local mm = missionForNpc(model)
		if mm then
			MissionService.interact(player, mm)
		else
			MissionService.startStoryRescue(player, model)
		end
	end)
	watchSurvivor(model)
	return model
end

local function buildCue(m: Mission): BasePart
	local chamber = assert(WorldDefs.chamber(m.spawn.chamberId), "unknown chamber " .. tostring(m.spawn.chamberId))
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Name = "RescueCue"
	-- Floor-relative (the old code used y = 0.3, which only matched R01's floor height).
	local pos = Vector3.new(m.spawn.pos.x, chamber.pos.y + 0.3, m.spawn.pos.z)
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
	p.Parent = services.WorldBuilder.folder(chamber.regionId)
	return p
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

-- Offers ------------------------------------------------------------------------------------------

local function m07Choices(player: Player): { { id: string, stage: number } }
	local s = services.PlayerService.get(player)
	if not s then
		return {}
	end
	local reach = MissionRules.nearbySet(homeHops(player), MissionRules.OBSERVE_HOPS)
	return MissionRules.m07Choices(WorldDefs.Creatures :: any, s.profile.research, reach, WorldDefs.Chambers :: any)
end

local function m09Choices(player: Player): { string }
	local s = services.PlayerService.get(player)
	if not s then
		return {}
	end
	return MissionRules.m09Candidates(Story.factsOf(s.profile), WorldDefs.Shelters :: any, homeHops(player))
end

-- Why a built template cannot be offered right now (shown in the list; enforced again in accept).
local function lockReason(player: Player, template: string): string?
	local s = services.PlayerService.get(player)
	if not s then
		return nil
	end
	local f = Story.factsOf(s.profile)
	if template == "M04" then
		local ok, why = MissionRules.m04Offer(f)
		return if ok then nil else why
	elseif template == "M05" then
		local ok, why = MissionRules.m05Offer(f)
		if not ok then
			return why
		end
		if homeHops(player)["R03.overflow_vault"] == nil then
			return "The Overflow Vault cannot be reached from your last shelter right now."
		end
	elseif template == "M07" then
		if #m07Choices(player) == 0 then
			return "Nothing new to observe within reach of your last shelter."
		end
	elseif template == "M09" then
		if #m09Choices(player) == 0 then
			return "No known shelter left to establish. Discover another refuge first."
		end
	elseif template == "M11" then
		if not MissionRules.m11Pick(bagsOf(player)) then
			return "You have no death or departure bag right now."
		end
	end
	return nil
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
		local built = def.status == "SLICE"
		table.insert(list, {
			id = id,
			name = def.name,
			status = def.status,
			estimate = def.estimate,
			risk = def.risk,
			available = built and os.time() >= cd and active == nil,
			cooldown = if built then math.max(0, cd - os.time()) else nil,
			-- PROPOSED UI field: why accepting would be refused right now (accept explains it too).
			locked = if built then lockReason(player, id) else nil,
		})
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	services.PlayerService.send(player, "missionList", list)
end

-- Spot-pool templates: an unused authored spot near the last shelter, never inside a variable pocket.
local function pickSpot(player: Player, pool: { any }): any?
	local near = MissionRules.nearbySet(homeHops(player), MissionRules.NEARBY_HOPS)
	local candidates = MissionRules.eligibleSpots(pool, near, busySpots(), WorldDefs.pocketAt :: any)
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

local function startTemplate(player: Player, s: any, templateId: string)
	local f = Story.factsOf(s.profile)
	if templateId == "M01" or templateId == "M02" or templateId == "M03" then
		local pool: { any } = if templateId == "M01"
			then WorldDefs.RescueSpawns
			elseif templateId == "M02" then WorldDefs.CacheSpots
			else WorldDefs.MissionSpots.M03 or {}
		local spot = pickSpot(player, pool)
		if not spot then
			notify(
				player,
				"Nothing suitable is close to your last shelter right now. Try again shortly or register a different shelter.",
				"warn"
			)
			return
		end
		local m = newMission(player, templateId, spot)
		addParty(m, player)
		-- Building a rig can yield: hold the spot so a concurrent accept cannot pick it meanwhile.
		reservedSpots[spot.id] = true
		local ok, err = try(launch, m, function()
			if templateId == "M01" then
				m.cue = buildCue(m)
				m.npc = buildSurvivor(m)
			elseif templateId == "M02" then
				m.state = "collect"
				buildCase(m)
			else
				m.state = "deliver"
				m.npc = buildWorker(m)
			end
		end)
		reservedSpots[spot.id] = nil
		if not ok then
			error(err)
		end
	elseif templateId == "M04" then
		local ok, why = MissionRules.m04Offer(f)
		if not ok then
			notify(player, why or "Not available.", "info")
			return
		end
		local m = newMission(player, "M04", nil)
		m.participants[player.UserId] = true
		m.state = "work"
		m.target = MissionRules.S04
		launch(m, nil)
	elseif templateId == "M05" then
		local reason = lockReason(player, "M05")
		if reason then
			notify(player, reason, "info")
			return
		end
		local m = newMission(player, "M05", nil)
		addParty(m, player)
		m.state = "collect"
		launch(m, nil)
	elseif templateId == "M07" then
		-- Personal objective: a built creature whose research is unfinished and whose home is within reach (B8).
		local choices = m07Choices(player)
		if #choices == 0 then
			notify(
				player,
				"Your journal already holds everything observable within reach of your last shelter.",
				"info"
			)
			return
		end
		local pick = choices[math.random(1, #choices)]
		local m = newMission(player, "M07", nil)
		m.participants[player.UserId] = true
		m.creatureId = pick.id
		m.startStage = pick.stage
		m.state = "observe"
		launch(m, nil)
	elseif templateId == "M09" then
		local choices = m09Choices(player)
		if #choices == 0 then
			notify(player, "No known shelter left to establish. Discover another refuge first.", "info")
			return
		end
		local m = newMission(player, "M09", nil)
		m.participants[player.UserId] = true
		m.state = "work"
		m.target = choices[1] -- the nearest known shelter you have not established
		launch(m, nil)
	elseif templateId == "M11" then
		local bag = MissionRules.m11Pick(bagsOf(player))
		if not bag then
			notify(player, "You have no death or departure bag right now.", "info")
			return
		end
		local m = newMission(player, "M11", nil)
		m.participants[player.UserId] = true
		m.state = "work"
		m.target = bag.bagId
		m.targetKind = bag.kind
		launch(m, nil)
	end
end

function MissionService.accept(player: Player, templateId: string)
	local s = services.PlayerService.get(player)
	local def = WorldDefs.Missions[templateId]
	if not s or not def or def.status ~= "SLICE" then
		return
	end
	if missionFor(player) then
		notify(player, "You already have an active mission. Abandon it from the mission list first.", "info")
		return
	end
	local ready = s.profile.missionCooldowns[templateId] or 0
	if os.time() < ready then
		notify(player, string.format("%s is available again in %d s.", def.name, ready - os.time()), "info")
		return
	end
	if starting[player] then
		return
	end
	starting[player] = true
	local ok, err = try(startTemplate, player, s, templateId)
	starting[player] = nil
	if not ok then
		warn("[MissionService] could not start " .. templateId .. ": " .. tostring(err))
		notify(player, "That mission could not be set up right now. Nothing was lost.", "warn")
	end
end

-- Rescue (M01 and the Act II story rescue) ------------------------------------------------------------

local function addCarryPrompt(npc: Model)
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or root:FindFirstChild("CarryPrompt") then
		return
	end
	local carry = Instance.new("ProximityPrompt")
	carry.Name = "CarryPrompt"
	carry.ActionText = "Carry (slower)"
	carry.ObjectText = npc.Name
	-- PROPOSED: J, a key nothing else binds. V is the lantern shield (D79) and E is the Escort prompt beside this one.
	carry.KeyboardKeyCode = Enum.KeyCode.J
	carry.UIOffset = Vector2.new(0, 60)
	carry.HoldDuration = 0.5
	carry.MaxActivationDistance = 8
	carry.RequiresLineOfSight = false
	carry.Parent = root
	carry.Triggered:Connect(function(p2)
		local mm = missionForNpc(npc)
		if mm then
			MissionService.carry(p2, mm)
		end
	end)
end

function MissionService.interact(player: Player, m: Mission)
	if missions[m.id] ~= m or not canAct(player) or not tryJoin(player, m) then
		return
	end
	local s = services.PlayerService.get(player)
	local npc = m.npc
	if not s or not npc then
		return
	end
	local h = npc:FindFirstChildOfClass("Humanoid")
	local pp = npc:FindFirstChild("RescuePrompt", true) :: ProximityPrompt?
	if not h then
		return
	end
	if m.state == "travel" or m.state == "treat" then
		m.state = "treat"
		touch(m)
		local inv = s.profile.inventory
		local useItem = if Inventory.count(inv, "med.bandage") > 0
			then "med.bandage"
			elseif Inventory.count(inv, "med.splint") > 0 then "med.splint"
			elseif Inventory.count(inv, "med.cloth_dressing") > 0 then "med.cloth_dressing"
			else nil
		local secs = (if useItem then 4 else 9) * ((Config.Classes[s.profile.class] or {}).treatTimeMultiplier or 1)
		if not useItem then
			notify(player, "No supplies: steadying them by hand takes longer.", "info")
		end
		if not services.PlayerService.hold(player, secs) then
			return
		end
		-- B2: re-check after the hold; another participant may have finished treating or started moving them.
		if
			missions[m.id] ~= m
			or m.state ~= "treat"
			or m.npc ~= npc
			or not m.participants[player.UserId]
			or not canAct(player)
		then
			return
		end
		if useItem then
			if not Inventory.remove(inv, useItem, 1) then
				return -- the item was used elsewhere during the hold; nothing is consumed, try again
			end
			services.SaveService.markDirty(player)
			services.PlayerService.pushInventory(player)
		end
		m.state = "ready"
		touch(m)
		h.Sit = false
		if pp then
			pp.ActionText = "Escort (walk)"
		end
		addCarryPrompt(npc)
		pushMission(m)
	elseif m.state == "ready" then
		MissionService.escort(player, m)
	elseif m.state == "escort" then
		m.owner = player -- the survivor follows whoever asked last
		touch(m)
	end
end

function MissionService.escort(player: Player, m: Mission)
	local npc = m.npc
	if not npc then
		return
	end
	local h = npc:FindFirstChildOfClass("Humanoid")
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not h or not root then
		return
	end
	m.state = "escort"
	m.owner = player
	touch(m)
	m.escortToken += 1
	local token = m.escortToken
	pushMission(m)
	-- One loop per escort (B12): an older loop exits as soon as a newer escort starts.
	task.spawn(function()
		local function active(): boolean
			return m.state == "escort" and m.escortToken == token and npc.Parent ~= nil and missions[m.id] == m
		end
		while active() do
			local os_ = services.PlayerService.get(m.owner)
			-- The leader went inside a shelter without the survivor: wait here instead of walking at the far
			-- interior cell (B12).
			local target = if os_ and not os_.insideShelterId then services.PlayerService.position(m.owner) else nil
			if root.Position.Y < -1000 then
				clearMission(m, "failed", "the survivor was lost")
				return
			end
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
						while active() and (root.Position - wps[i].Position).Magnitude > 3 and os.clock() - t0 < 2 do
							task.wait(0.1)
						end
						if not active() then
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
	if missions[m.id] ~= m or not npc or (m.state ~= "ready" and m.state ~= "escort") then
		return
	end
	local sess = services.PlayerService.get(player)
	if not sess then
		return
	end
	if not canAct(player) then
		if sess.vitals.condition == "downed" then
			notify(player, "You cannot carry anyone while you are down.", "warn")
		end
		return
	end
	if not tryJoin(player, m) then
		return
	end
	local pr = services.PlayerService.rootPart(player)
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not pr or not root or (pr.Position - root.Position).Magnitude > 9 then
		return
	end
	if sess.carrying then
		notify(player, "Your hands are already full.", "warn")
		return
	end
	local h = npc:FindFirstChildOfClass("Humanoid")
	if h then
		h.PlatformStand = true
	end
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
		if h then
			h.PlatformStand = false
		end
		return
	end
	pcall(function()
		root:SetNetworkOwner(player)
	end)
	m.state = "carried"
	m.owner = player
	m.escortToken += 1 -- stops any escort loop
	touch(m)
	pushMission(m)
end

function MissionService.onNpcDropped(_player: Player, npc: Model)
	local m = missionForNpc(npc)
	if not m then
		return
	end
	local h = npc:FindFirstChildOfClass("Humanoid")
	if h then
		h.PlatformStand = false
	end
	for _, d in npc:GetDescendants() do
		if d:IsA("BasePart") then
			d.Massless = false -- collisions stay off: the figure must not intercept raycasts
		end
	end
	local root = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	m.state = "ready"
	touch(m)
	pushMission(m)
end

local function completeRescue(m: Mission)
	if missions[m.id] ~= m then
		return
	end
	local story = m.template == StoryDefs.Rescue.template
	for uid in m.participants do
		local p = Players:GetPlayerByUserId(uid)
		local s = p and services.PlayerService.get(p)
		if p and s then
			if story then
				-- Act II step 2 is recorded for every participant (party members share the objective).
				s.profile.storyStates["act2.noah_rescued"] = "1"
				Story.raiseMet(s.profile.charactersMet, "N06", "rescued")
				services.SaveService.markDirty(p)
				commitThen(p, StoryDefs.Rescue.done)
				if services.NpcService then
					services.NpcService.say(p, "N06", "rescued", true)
				end
				task.defer(storyOnFact, p)
			else
				payout(p, "M01", coinsFor("M01"), nil, string.format("Rescue complete. +%d coins.", coinsFor("M01")))
			end
			services.DirectorService.afterRescue(p)
		end
	end
	clearMission(m, "done")
end

-- Called when a player carrying an NPC enters a shelter.
function MissionService.deliverToShelter(player: Player, npc: Model)
	local m = missionForNpc(npc)
	if not m then
		-- B21: a carried model that belongs to no mission is still put down.
		services.PlayerService.dropCarry(player)
		return
	end
	local s = services.PlayerService.get(player)
	if s and s.carrying then
		if s.carrying.weld then
			s.carrying.weld:Destroy()
		end
		s.carrying = nil
		s.dirtyState = true
	end
	completeRescue(m)
end

-- Act II story rescue: Noah waits in the Silt Works while someone online is at step 2.
function MissionService.startStoryRescue(player: Player, model: Model)
	if model ~= idleNoah or not model.Parent then
		return
	end
	local s = services.PlayerService.get(player)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local pos = services.PlayerService.position(player)
	if not s or not root or not pos or (pos - root.Position).Magnitude > 10 or not canAct(player) then
		return
	end
	local needed = false
	for _, mem in services.PartyService.members(player) do
		local ms = services.PlayerService.get(mem)
		if ms and Story.currentId(Story.factsOf(ms.profile)) == "A2.2" then
			needed = true
		end
	end
	if not needed then
		if services.NpcService then
			services.NpcService.say(player, "N06", "waiting")
		end
		return
	end
	if missionFor(player) then
		notify(player, "Finish or abandon your current mission first (mission list → Abandon current).", "info")
		return
	end
	local def = WorldDefs.Characters.N06
	local m = newMission(
		player,
		StoryDefs.Rescue.template,
		{ id = "A2.noah", chamberId = "R03.silt_loop", pos = def.rescuePos }
	)
	addParty(m, player)
	m.npc = model
	idleNoah = nil
	missions[m.id] = m
	pushMission(m)
	MissionService.interact(player, m)
end

local function anyoneNeedsNoah(): boolean
	for _, s in services.PlayerService.all() do
		if Story.currentId(Story.factsOf(s.profile)) == "A2.2" then
			return true
		end
	end
	return false
end

local function tickStoryRescue()
	for _, m in missions do
		if m.template == StoryDefs.Rescue.template then
			return
		end
	end
	local need = anyoneNeedsNoah()
	local noah = idleNoah
	if noah and not noah.Parent then
		idleNoah = nil
		noah = nil
	end
	if need and not noah then
		local ok, built = pcall(buildNoah)
		if ok then
			idleNoah = built
		else
			warn("[MissionService] could not place Noah Perrin: " .. tostring(built))
		end
	elseif not need and noah then
		noah:Destroy()
		idleNoah = nil
	end
end

-- M02 Missing Survey Cache ---------------------------------------------------------------------------

function MissionService.collectCache(player: Player, m: Mission)
	if missions[m.id] ~= m or m.state ~= "collect" or not canAct(player) then
		return
	end
	if m.collected[player.UserId] then
		notify(player, "You already took your copy.", "info")
		return
	end
	if not tryJoin(player, m) then
		return
	end
	if not services.PlayerService.hold(player, 1.5) then
		return
	end
	-- re-check after the hold: the mission may have ended, the player abandoned, gone down or died meanwhile
	if
		missions[m.id] ~= m
		or m.state ~= "collect"
		or not m.participants[player.UserId]
		or m.collected[player.UserId]
		or not canAct(player)
	then
		return
	end
	m.collected[player.UserId] = true
	touch(m)
	-- the collector is finished: free them for new missions (collected[] still blocks a second copy)
	m.participants[player.UserId] = nil
	payout(
		player,
		"M02",
		coinsFor("M02"),
		M02_ITEMS,
		string.format("Cache recovered (+%d coins). %s", coinsFor("M02"), LORE[math.random(1, #LORE)])
	)
	services.PlayerService.send(player, "mission", { id = m.id, state = "done" })
	ensureOwner(m)
	closeIfFinished(m)
end

-- M03 Medical Delivery -----------------------------------------------------------------------------

-- Opens the amount chooser for this player (or explains where supplies can be found). Never a store.
function MissionService.openDelivery(player: Player, m: Mission)
	if missions[m.id] ~= m or m.state ~= "deliver" or not canAct(player) then
		return
	end
	if m.collected[player.UserId] then
		notify(player, "You already gave your share. Thank you.", "info")
		return
	end
	if not tryJoin(player, m) then
		return
	end
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local max = Config.Missions.medicalDeliveryMaxItems
	local options = {}
	for _, o in MissionRules.deliveryOptions(s.profile.inventory, max) do
		local d = ItemDefs.get(o.itemId)
		table.insert(options, { itemId = o.itemId, name = d and d.displayName or o.itemId, have = o.have, max = o.max })
	end
	services.PlayerService.send(player, "missionDeliver", {
		missionId = m.id,
		title = titleOf("M03"),
		options = options,
		max = max,
		base = Config.Missions.medicalDeliveryBaseCoins,
		perItem = Config.Missions.medicalDeliveryCoinsPerItem,
		nothing = if #options == 0 then MissionRules.nothingToGiveText(medicalSitesNear(m.spawn.chamberId)) else nil,
	})
	if #options == 0 then
		pushMission(m) -- the objective now lists where supplies have turned up
	end
end

local DELIVERY_REASONS = {
	item = "The worker can use dressings, bandages or splints.",
	count = "Choose between 1 and %d items.",
	held = "You do not carry that many.",
}

-- `mission.deliver { itemId, count }` (validated request).
function MissionService.deliver(player: Player, itemId: string, n: number)
	local m = missionFor(player)
	if not m or m.template ~= "M03" or m.state ~= "deliver" or m.collected[player.UserId] then
		return
	end
	local s = services.PlayerService.get(player)
	local npc = m.npc
	local root = npc and npc:FindFirstChild("HumanoidRootPart") :: BasePart?
	local pos = services.PlayerService.position(player)
	if not s or not root or not pos or (pos - root.Position).Magnitude > DELIVERY_RANGE then
		return
	end
	if not canAct(player) then
		return
	end
	local max = Config.Missions.medicalDeliveryMaxItems
	local ok, why = MissionRules.validateDelivery(s.profile.inventory, itemId, n, max)
	if not ok then
		notify(player, string.format(DELIVERY_REASONS[why or "item"] or "Cannot deliver that.", max), "warn")
		return
	end
	if not services.PlayerService.hold(player, 1.5) then
		return
	end
	-- re-check everything after the hold
	if
		missions[m.id] ~= m
		or m.state ~= "deliver"
		or not m.participants[player.UserId]
		or m.collected[player.UserId]
		or not canAct(player)
		or not MissionRules.validateDelivery(s.profile.inventory, itemId, n, max)
	then
		return
	end
	if not Inventory.remove(s.profile.inventory, itemId, n) then
		return
	end
	m.collected[player.UserId] = true
	touch(m)
	m.participants[player.UserId] = nil
	local coins = coinsFor("M03", n)
	local d = ItemDefs.get(itemId)
	payout(
		player,
		"M03",
		coins,
		nil,
		string.format("Delivered %d × %s. +%d coins.", n, d and d.displayName or itemId, coins)
	)
	services.PlayerService.send(player, "mission", { id = m.id, state = "done" })
	ensureOwner(m)
	closeIfFinished(m)
end

-- M05 Waterworks Passage ---------------------------------------------------------------------------

function MissionService.openWaterworksCache(player: Player)
	local cache = m05Cache
	local pos = services.PlayerService.position(player)
	local s = services.PlayerService.get(player)
	if not cache or not pos or not s or (pos - cache.Position).Magnitude > CACHE_RANGE or not canAct(player) then
		return
	end
	local m = missionFor(player)
	if not m or m.template ~= "M05" then
		if m then
			notify(player, "This cache belongs to the Waterworks Passage. Finish your current mission first.", "info")
			return
		end
		-- Late join: an active Waterworks Passage of a current party member.
		for _, mm in missions do
			if mm.template == "M05" and online(mm.owner) and services.PartyService.sameParty(player, mm.owner) then
				m = mm
				break
			end
		end
		if not m then
			notify(
				player,
				"A sluice-keeper's cache. Accept the Waterworks Passage (M05) at a mission board or shelter to open your own copy.",
				"info"
			)
			return
		end
	end
	local mission = m :: Mission
	if mission.collected[player.UserId] then
		notify(player, "You already opened your copy. Return to any shelter.", "info")
		return
	end
	if not tryJoin(player, mission) then
		return
	end
	if not services.PlayerService.hold(player, 1.5) then
		return
	end
	if missions[mission.id] ~= mission or not mission.participants[player.UserId] or not canAct(player) then
		return
	end
	if not MissionRules.claimOnce(mission.collected, player.UserId) then
		return
	end
	touch(mission)
	-- The cooldown starts with the claim, so abandoning and re-accepting cannot restock the cache early.
	s.profile.missionCooldowns.M05 = os.time() + MissionRules.cooldownSeconds("M05", Config.Missions)
	local leftover = Inventory.addContents(s.profile.inventory, ItemDefs.get, MissionRules.M05_CACHE, "expedition")
	for id, k in leftover do
		s.profile.escrow[id] = (s.profile.escrow[id] or 0) + k
	end
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	commitThen(
		player,
		"Opened your copy of the sluice-keeper's cache: a flare, a bandage and a battery housing. Return to any shelter."
	)
	pushMission(mission)
end

local function buildWaterworksCache()
	local spot = WorldDefs.MissionSpots.M05 and WorldDefs.MissionSpots.M05[1]
	local chamber = spot and WorldDefs.chamber(spot.chamberId)
	if not spot or not chamber then
		return
	end
	local p = Instance.new("Part")
	p.Name = "SluiceKeepersCache"
	p.Anchored = true
	p.Size = Vector3.new(2.6, 1.4, 1.6)
	p.CFrame = CFrame.new(spot.pos.x, spot.pos.y - 0.3, spot.pos.z) * CFrame.Angles(0, -0.4, 0)
	p.Color = Color3.fromRGB(64, 70, 66)
	p.Material = Enum.Material.CorrodedMetal
	p.Parent = services.WorldBuilder.folder(chamber.regionId)
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Open your copy"
	pp.ObjectText = "Sluice-keeper's cache"
	pp.HoldDuration = 0.5
	pp.MaxActivationDistance = 7
	pp.RequiresLineOfSight = false
	pp.Parent = p
	pp.Triggered:Connect(MissionService.openWaterworksCache)
	m05Cache = p
end

-- M07 Creature Observation -------------------------------------------------------------------------

-- Called by CreatureService whenever a player's research stage rises.
function MissionService.onResearch(player: Player, creatureId: string, stage: number)
	local m = missionFor(player)
	if
		m
		and m.template == "M07"
		and m.state == "observe"
		and m.creatureId == creatureId
		and stage > (m.startStage or 0)
	then
		m.state = "return"
		touch(m)
		pushMission(m)
	end
end

-- Shelter arrival ----------------------------------------------------------------------------------

-- A participant at a shelter with a "return" objective finishes it. Also reached by respawning inside a shelter
-- (B13: ShelterService.onSpawn places the player without calling enter).
local function reachedShelter(player: Player, m: Mission)
	if m.template == "M07" and m.state == "return" then
		clearMission(m, "done") -- first: the mission can never pay twice
		payout(
			player,
			"M07",
			coinsFor("M07"),
			nil,
			string.format("Observation filed in the journal. +%d coins.", coinsFor("M07"))
		)
	elseif m.template == "M05" and m.collected[player.UserId] and m.participants[player.UserId] then
		m.participants[player.UserId] = nil
		payout(
			player,
			"M05",
			coinsFor("M05"),
			nil,
			string.format("Waterworks Passage complete. +%d coins.", coinsFor("M05"))
		)
		services.PlayerService.send(player, "mission", { id = m.id, state = "done" })
		ensureOwner(m)
		closeIfFinished(m)
	end
end

local function evaluateM04(player: Player, s: any, m: Mission, f: Story.Facts)
	if not MissionRules.m04Complete(f) then
		return
	end
	if s.profile.storyStates["M04.reward"] ~= "1" then
		s.profile.storyStates["M04.reward"] = "1" -- once ever (one per shelter facility)
		payout(
			player,
			"M04",
			coinsFor("M04"),
			nil,
			string.format(
				"Power Restoration complete: the station supply runs in your service office. +%d coins.",
				coinsFor("M04")
			)
		)
	end
	clearMission(m, "done")
end

local function evaluateM09(player: Player, s: any, m: Mission, f: Story.Facts)
	local def = WorldDefs.Shelters[m.target or ""]
	if not def then
		clearMission(m, "failed", "that shelter no longer exists")
		return
	end
	if MissionRules.m09Complete(f, def :: any) then
		local key = MissionRules.m09RewardKey(def.id)
		if s.profile.storyStates[key] ~= "1" then
			s.profile.storyStates[key] = "1" -- once per shelter
			payout(
				player,
				"M09",
				coinsFor("M09"),
				nil,
				string.format("%s established. +%d coins.", def.name, coinsFor("M09"))
			)
		end
		clearMission(m, "done")
	elseif f.discoveries["shelter:" .. def.id] and not m.noted then
		m.noted = true -- registered: the objective now names the remaining half
		touch(m)
		pushMission(m)
	end
end

local function evaluateM11(player: Player, s: any, m: Mission)
	local target = m.target or ""
	local marks = ownerRecovered[player]
	local status = MissionRules.m11Status(bagsOf(player), m.targetKind or "", target, marks ~= nil and marks[target])
	if marks and (status == "recovered" or status == "delegated") then
		marks[target] = nil
	end
	if status == "recovered" then
		-- Never coins (no incentive to die); field experience once per bag, at most once per cooldown (D37).
		local now = os.time()
		local wait = MissionRules.m11XpWait(s.profile.missionCooldowns, now)
		if wait <= 0 then
			s.profile.missionCooldowns[MissionRules.M11_XP_COOLDOWN_KEY] = now
				+ MissionRules.m11XpCooldownSeconds(Config.Missions)
			services.SaveService.markDirty(player)
			grantXp(player, MissionRules.bagXpKey(target), Config.Progression.xp.bag)
			notify(
				player,
				"Lost Belongings: you recovered your own bag. Field experience recorded — no coins, this was your own journey.",
				"info"
			)
		else
			notify(
				player,
				string.format(
					"Lost Belongings: you recovered your own bag. No field experience this time: a recovered bag pays at most once every %d minutes (again in %d min).",
					math.ceil(MissionRules.m11XpCooldownSeconds(Config.Missions) / 60),
					math.ceil(wait / 60)
				),
				"info"
			)
		end
		clearMission(m, "done")
	elseif status == "delegated" then
		notify(
			player,
			"Lost Belongings: a party member moved your bag to your shelter escrow; claim it at any shelter. No field experience: only recovering it yourself earns it.",
			"info"
		)
		clearMission(m, "done")
	elseif status == "replaced" then
		clearMission(m, "failed", "a newer bag replaced the one you were looking for")
	end
end

-- Personal objectives that complete from profile facts (M04, M09, M11) plus shelter-return checks.
-- Safe to call at any time (StoryService.onFact calls it after other packages change facts).
function MissionService.evaluate(player: Player)
	local m = missionFor(player)
	local s = services.PlayerService.get(player)
	if not m or not s then
		return
	end
	local t = m.template
	if t == "M04" or t == "M09" or t == "M11" then
		if m.state ~= "work" then
			return
		end
		local f = Story.factsOf(s.profile)
		if t == "M04" then
			evaluateM04(player, s, m, f)
		elseif t == "M09" then
			evaluateM09(player, s, m, f)
		else
			evaluateM11(player, s, m)
		end
	elseif s.insideShelterId and (t == "M07" or t == "M05") then
		reachedShelter(player, m)
	end
end

-- Called by RecoveryService.recover after the owner recovered their own bag (not a delegate's escrow recovery), so
-- M11 can tell the two apart. Completes the journey at once instead of on the next poll.
function MissionService.noteOwnerRecovered(owner: Player, bagId: string)
	local marks = ownerRecovered[owner] or {}
	ownerRecovered[owner] = marks
	marks[bagId] = true
	task.defer(function()
		local ok, err = try(MissionService.evaluate, owner)
		if not ok then
			warn("[MissionService] evaluate after a recovery failed: " .. tostring(err))
		end
	end)
end

-- Called by ShelterService.enter (after registration and banking, before the player is placed inside).
function MissionService.onShelterReached(player: Player)
	local m = missionFor(player)
	if not m then
		return
	end
	if MissionRules.isRescue(m.template) then
		if m.state ~= "escort" or not m.npc then
			return
		end
		local root = m.npc:FindFirstChild("HumanoidRootPart") :: BasePart?
		local p = services.PlayerService.position(player)
		if root and p and (p - root.Position).Magnitude < RESCUE_ESCORT_RADIUS then
			completeRescue(m)
		end
		return
	end
	reachedShelter(player, m)
	if missions[m.id] == m then
		MissionService.evaluate(player)
	end
end

-- Optional hook for ShelterService.upgrade (puzzles/shelters package): completes M09 without waiting for the poll.
function MissionService.onShelterUpgraded(player: Player, _shelterId: string?, _upgradeId: string?, _stage: number?)
	MissionService.evaluate(player)
end

-- Leaving, dying, abandoning ---------------------------------------------------------------------------

-- `reason` is what the remaining participants are told if the objective fails; the leaver hears `endedText` when
-- the objective ended with them, or `leftText` when their party carries on.
local function handOver(player: Player, reason: string, endedText: string?, leftText: string?)
	local m = missionFor(player)
	if not m then
		return
	end
	-- Abandoning behaves like leaving: put a carried survivor down first, as death and disconnect already have,
	-- so the leaver is never left with a stale carry or the survivor welded to them (review round 2, finding 0).
	local s = services.PlayerService.get(player)
	if m.npc and s and s.carrying and s.carrying.kind == "npc" and s.carrying.target == m.npc then
		services.PlayerService.dropCarry(player)
	end
	m.participants[player.UserId] = nil
	if m.template == "M02" or m.template == "M03" or m.template == "M05" then
		ensureOwner(m)
		closeIfFinished(m)
	elseif m.owner == player then
		local nextOwner: Player? = nil
		for uid in m.participants do
			local p = Players:GetPlayerByUserId(uid)
			if p and online(p) then
				nextOwner = p
				break
			end
		end
		if nextOwner then
			m.owner = nextOwner
			if m.state == "escort" or m.state == "carried" then
				m.state = "ready"
				m.escortToken += 1
			end
			touch(m)
			pushMission(m)
		else
			clearMission(m, "failed", reason)
		end
	end
	-- B4: the leaver's HUD objective ends too ("left" clears it without a failure message).
	if player.Parent then
		services.PlayerService.send(player, "mission", { id = m.id, state = "left" })
		local text = if missions[m.id] == m then leftText else endedText
		if text then
			notify(player, text, "info")
		end
	end
end

function MissionService.onPlayerDied(player: Player)
	local m = missionFor(player)
	if not m then
		return
	end
	if MissionRules.isRescue(m.template) then
		-- Only a rescue depends on staying alive; other objectives can be finished after respawning.
		handOver(
			player,
			"You died. The survivor was found by another team.",
			"You died. The survivor was found by another team.",
			"You died. Your party carries on with the rescue."
		)
	elseif m.template == "M11" then
		MissionService.evaluate(player) -- a new death bag may have replaced the one this journey was for
	end
end

function MissionService.onPlayerLeft(player: Player)
	handOver(player, "disconnected", nil, nil)
end

function MissionService.abandon(player: Player)
	local m = missionFor(player)
	if not m then
		return
	end
	local title = titleOf(m.template)
	handOver(player, "abandoned", "You abandoned " .. title .. ".", "You left " .. title .. "; your party carries on.")
end

function MissionService.init(s)
	services = s
	-- M03 amount chooser (MissionUI). Every field is validated here and again inside deliver().
	s.Router.register("mission.deliver", "interact", function(player: Player, d: any)
		local itemId, n = d.itemId, d.count
		if type(itemId) ~= "string" or #itemId > 64 then
			return
		end
		if type(n) ~= "number" or n ~= n or math.abs(n) > 1e6 then
			return
		end
		MissionService.deliver(player, itemId, n)
	end)
end

function MissionService.start()
	for _, board in CollectionService:GetTagged("MissionBoard") do
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Missions"
		pp.ObjectText = "Mara Voss's mission board"
		pp.MaxActivationDistance = 10
		pp.RequiresLineOfSight = false
		pp.Parent = board
		pp.Triggered:Connect(function(player)
			-- Story hand-ins to Mara take precedence over the mission list.
			if services.StoryService and services.StoryService.atBoard(player, "board") then
				return
			end
			MissionService.list(player)
		end)
	end
	buildWaterworksCache()
	task.spawn(function()
		local sinceTimeout = 0
		while true do
			task.wait(2)
			sinceTimeout += 2
			for player in services.PlayerService.all() do
				local ok, err = try(MissionService.evaluate, player)
				if not ok then
					warn("[MissionService] evaluate failed: " .. tostring(err))
				end
			end
			local ok, err = try(tickStoryRescue)
			if not ok then
				warn("[MissionService] story rescue tick failed: " .. tostring(err))
			end
			if sinceTimeout >= 15 then
				sinceTimeout = 0
				for _, m in missions do
					if MissionRules.timesOut(m.template, m.state, os.clock() - m.touchedAt) then
						clearMission(m, "failed", "timed out")
					end
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		starting[p] = nil
		ownerRecovered[p] = nil
	end)
end

return MissionService
