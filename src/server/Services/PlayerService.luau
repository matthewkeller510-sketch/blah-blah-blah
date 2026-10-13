--!strict
-- Server-authoritative player session: stamina, health, light, medical use, downed/rescue, death, logout.
-- Clients send intents (sprint/crouch held, toggle light); the server decides speeds and outcomes (section 19).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Stamina = require(Shared.Logic.Stamina)
local Vitals = require(Shared.Logic.Vitals)
local Inventory = require(Shared.Logic.Inventory)
local Net = require(Shared.Net)

local PlayerService = {}

export type Session = {
	player: Player,
	profile: any,
	vitals: Vitals.State,
	stamina: Stamina.State,
	intents: { sprint: boolean, crouch: boolean },
	mode: string,
	lightOn: boolean,
	regionId: string,
	insideShelterId: string?, -- set while in an isolated interior cell
	lastGrounded: Vector3?,
	exertion: number,
	lastThreatAt: number,
	busyUntil: number, -- held interaction in progress (cancelable)
	busyToken: number,
	carrying: any?, -- { kind = "player"|"npc", target = Player|Model }
	carriedBy: Player?,
	sessionId: string,
	dirtyState: boolean,
	lastSent: number,
	alive: boolean,
}

local sessions: { [Player]: Session } = {}
local services: any
local stateEvent: RemoteEvent

local function classMods(s: Session)
	return Config.Classes[s.profile.class] or {}
end

function PlayerService.get(player: Player): Session?
	return sessions[player]
end

function PlayerService.all(): { [Player]: Session }
	return sessions
end

function PlayerService.send(player: Player, channel: string, data: any)
	stateEvent:FireClient(player, channel, data)
end

function PlayerService.notify(player: Player, text: string, kind: string?)
	stateEvent:FireClient(player, "notice", { text = text, kind = kind or "info" })
end

function PlayerService.pushSaveStatus(player: Player, status: string, detail: string?)
	stateEvent:FireClient(player, "save", { status = status, detail = detail })
end

local function rootPart(player: Player): BasePart?
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end
PlayerService.rootPart = rootPart

local function humanoid(player: Player): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

function PlayerService.position(player: Player): Vector3?
	local r = rootPart(player)
	return r and r.Position
end

-- Inventory snapshot for the client (counts only; the server holds the truth).
function PlayerService.pushInventory(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	local items = {}
	for id, e in s.profile.inventory do
		local d = ItemDefs.get(id)
		table.insert(items, {
			id = id,
			name = d and d.displayName or id,
			category = d and d.category or "?",
			loadout = e.loadout,
			expedition = e.expedition,
			protected = d and d.protected or false,
		})
	end
	table.sort(items, function(a, b)
		return a.id < b.id
	end)
	stateEvent:FireClient(player, "inventory", { items = items, coins = s.profile.coins, class = s.profile.class })
end

local function lightDef(s: Session)
	local id = s.profile.equippedLight
	if id and Inventory.count(s.profile.inventory, id) > 0 then
		return ItemDefs.get(id)
	end
	return nil
end

local function refreshLight(s: Session)
	local c = s.player.Character
	local head = c and c:FindFirstChild("Head")
	if not head then
		return
	end
	local spot = head:FindFirstChild("ExpeditionLight") :: SpotLight?
	if not spot then
		local ns = Instance.new("SpotLight")
		ns.Name = "ExpeditionLight"
		ns.Face = Enum.NormalId.Front
		ns.Shadows = true
		ns.Parent = head
		spot = ns
	end
	local def = lightDef(s)
	local on = s.lightOn and def ~= nil and s.profile.lightCharge > 0 and s.vitals.condition ~= "downed"
	assert(spot)
	spot.Enabled = on
	if def then
		spot.Range = def.beamRange or 30
		spot.Angle = def.beamAngle or 40
		spot.Brightness = def.brightness or 1
		spot:SetAttribute("BaseBrightness", def.brightness or 1)
		spot.Color = Color3.fromRGB(255, 236, 205)
	end
	head:SetAttribute("LightLow", s.profile.lightCharge / 100 < Config.Light.flickerWarningFraction)
end

local function applySpeed(s: Session)
	local h = humanoid(s.player)
	if not h then
		return
	end
	local M = Config.Movement
	local speed
	if s.vitals.condition == "downed" then
		speed = 2.5 -- downed crawl; never an unrecoverable lock
	elseif s.carriedBy then
		speed = 0
	elseif s.mode == "sprint" then
		speed = M.sprintSpeed
	elseif s.mode == "crouch" then
		speed = M.crouchSpeed
	else
		speed = M.walkSpeed
	end
	if s.carrying then
		speed = math.min(speed, M.walkSpeed) * M.carrySpeedMultiplier
	end
	h.WalkSpeed = speed
end

local function syncHumanoidHealth(s: Session)
	local h = humanoid(s.player)
	if h and s.vitals.condition ~= "dead" then
		h.MaxHealth = s.vitals.max
		h.Health = math.max(1, s.vitals.health) -- Humanoid never dies on its own; Vitals decides
	end
end

local function statePayload(s: Session)
	local def = lightDef(s)
	return {
		health = s.vitals.health,
		maxHealth = s.vitals.max,
		passiveCap = Vitals.passiveCap(Config.Health, s.vitals),
		condition = s.vitals.condition,
		injured = s.vitals.injuryFlag,
		downedRemaining = s.vitals.downedRemaining,
		stabilized = s.vitals.stabilized,
		stamina = s.stamina.value,
		staminaMax = Config.Stamina.max,
		exhausted = s.stamina.exhausted,
		showStamina = Stamina.shouldShowBar(Config.Stamina, s.stamina),
		lightOn = s.lightOn and def ~= nil and s.profile.lightCharge > 0,
		lightName = def and def.displayName or nil,
		lightCharge = s.profile.lightCharge,
		cells = Inventory.count(s.profile.inventory, "power.cell"),
		regionId = s.regionId,
		inShelter = s.insideShelterId,
		busy = os.clock() < s.busyUntil,
		carrying = s.carrying ~= nil,
		carriedBy = s.carriedBy and s.carriedBy.DisplayName or nil,
	}
end

function PlayerService.markState(player: Player)
	local s = sessions[player]
	if s then
		s.dirtyState = true
	end
end

-- Damage entry point for creatures. Shelter interiors are respected by ShelterService.canBeDamaged.
function PlayerService.damage(player: Player, amount: number, causesInjury: boolean, source: string): boolean
	local s = sessions[player]
	if not s or not s.alive then
		return false
	end
	if services.ShelterService and not services.ShelterService.canBeDamaged(player) then
		return false
	end
	local before = s.vitals.condition
	local cond = Vitals.damage(Config.Health, s.vitals, amount, causesInjury)
	s.busyUntil = 0 -- damage interrupts held medical actions
	s.busyToken += 1
	s.lastThreatAt = os.clock()
	if cond == "downed" and before ~= "downed" then
		PlayerService.notify(player, "You are down. A party member can stabilize you, or crawl toward safety.", "danger")
		if s.carrying then
			PlayerService.dropCarry(player)
		end
	end
	if cond == "dead" then
		PlayerService.onDeath(player, source)
	end
	syncHumanoidHealth(s)
	s.dirtyState = true
	return true
end

-- Cancelable held action. Returns true if it completed without moving or being damaged.
function PlayerService.hold(player: Player, seconds: number, allowMove: boolean?): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	if os.clock() < s.busyUntil then
		return false
	end
	local start = PlayerService.position(player)
	s.busyToken += 1
	local token = s.busyToken
	s.busyUntil = os.clock() + seconds
	s.dirtyState = true
	PlayerService.send(player, "hold", { seconds = seconds })
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		task.wait(0.1)
		if not sessions[player] or s.busyToken ~= token then
			PlayerService.send(player, "hold", { cancelled = true })
			return false
		end
		local p = PlayerService.position(player)
		if not allowMove and start and p and (p - start).Magnitude > 2.5 then
			s.busyUntil = 0
			s.busyToken += 1
			PlayerService.send(player, "hold", { cancelled = true })
			return false
		end
	end
	s.busyUntil = 0
	s.dirtyState = true
	PlayerService.send(player, "hold", { done = true })
	return true
end

function PlayerService.useMedical(player: Player, itemId: string, target: Player?)
	local s = sessions[player]
	local d = ItemDefs.get(itemId)
	if not s or not d or d.category ~= "medical" then
		return
	end
	local ts = s
	if target and target ~= player then
		local t = sessions[target]
		if not t then
			return
		end
		if not services.PartyService.sameParty(player, target) then
			PlayerService.notify(player, "You can only treat members of your current party.", "warn")
			return
		end
		local a, b = PlayerService.position(player), PlayerService.position(target)
		if not a or not b or (a - b).Magnitude > 9 then
			return
		end
		ts = t
	end
	if Inventory.count(s.profile.inventory, itemId) < 1 then
		PlayerService.notify(player, "You have no " .. d.displayName .. ".", "warn")
		return
	end
	local treat = (d.treatSeconds or 3) * (classMods(s).treatTimeMultiplier or 1)
	if not PlayerService.hold(player, treat) then
		return
	end
	-- re-validate after the hold
	if Inventory.count(s.profile.inventory, itemId) < 1 then
		return
	end
	local applied
	if ts.vitals.condition == "downed" then
		applied = ts.vitals.stabilized and Vitals.revive(Config.Health, ts.vitals, Config.Health.stabilizedHealth + (d.healAmount or 0))
		if not applied then
			PlayerService.notify(player, "Stabilize them first.", "warn")
		end
	else
		applied = Vitals.applyMedical(Config.Health, ts.vitals, d.healAmount or 0, d.removesInjury == true)
	end
	if applied then
		Inventory.remove(s.profile.inventory, itemId, 1)
		services.SaveService.markDirty(player)
		syncHumanoidHealth(ts)
		ts.dirtyState = true
		s.dirtyState = true
		PlayerService.pushInventory(player)
	end
end

function PlayerService.stabilize(player: Player, target: Player)
	local s, t = sessions[player], sessions[target]
	if not s or not t or player == target then
		return
	end
	if not services.PartyService.sameParty(player, target) then
		PlayerService.notify(player, "Only party members can stabilize each other. Invite them first.", "warn")
		return
	end
	if t.vitals.condition ~= "downed" then
		return
	end
	local a, b = PlayerService.position(player), PlayerService.position(target)
	if not a or not b or (a - b).Magnitude > 8 then
		return
	end
	local secs = Config.Health.stabilizeHoldSeconds * (classMods(s).treatTimeMultiplier or 1)
	if PlayerService.hold(player, secs) and t.vitals.condition == "downed" then
		Vitals.stabilize(Config.Health, t.vitals)
		t.dirtyState = true
		PlayerService.notify(target, player.DisplayName .. " stabilized you.", "info")
	end
end

-- Carrying a downed teammate (section 07). Uses a weld; detaches safely on drop, party change or downing.
function PlayerService.startCarry(player: Player, target: Player)
	local s, t = sessions[player], sessions[target]
	if not s or not t or s.carrying or t.carriedBy or player == target then
		return
	end
	if not services.PartyService.sameParty(player, target) or t.vitals.condition ~= "downed" then
		return
	end
	local ra, rb = rootPart(player), rootPart(target)
	if not ra or not rb or (ra.Position - rb.Position).Magnitude > 8 then
		return
	end
	local th = humanoid(target)
	if th then
		th.PlatformStand = true
	end
	rb.CFrame = ra.CFrame * CFrame.new(0, 0.5, 1.6)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = ra
	weld.Part1 = rb
	weld.Parent = ra
	pcall(function()
		rb:SetNetworkOwner(player)
	end)
	s.carrying = { kind = "player", target = target, weld = weld }
	t.carriedBy = player
	s.dirtyState, t.dirtyState = true, true
end

function PlayerService.startCarryNpc(player: Player, npc: Model, weld: WeldConstraint)
	local s = sessions[player]
	if not s or s.carrying then
		return false
	end
	s.carrying = { kind = "npc", target = npc, weld = weld }
	s.dirtyState = true
	return true
end

function PlayerService.dropCarry(player: Player)
	local s = sessions[player]
	if not s or not s.carrying then
		return
	end
	local c = s.carrying
	s.carrying = nil
	if c.weld then
		c.weld:Destroy()
	end
	if c.kind == "player" then
		local target = c.target :: Player
		local t = sessions[target]
		if t then
			t.carriedBy = nil
			t.dirtyState = true
		end
		local th = humanoid(target)
		if th then
			th.PlatformStand = false
		end
		local rb = rootPart(target)
		if rb then
			pcall(function()
				rb:SetNetworkOwner(target)
			end)
		end
	elseif c.kind == "npc" and services.MissionService then
		services.MissionService.onNpcDropped(player, c.target)
	end
	s.dirtyState = true
end

function PlayerService.toggleLight(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	s.lightOn = not s.lightOn
	if s.lightOn and not lightDef(s) then
		PlayerService.notify(player, "You have no light. Move slowly and feel along the walls.", "warn")
		s.lightOn = false
	elseif s.lightOn and s.profile.lightCharge <= 0 then
		PlayerService.notify(player, "The cell is flat. Swap in a replacement cell if you have one.", "warn")
	end
	refreshLight(s)
	s.dirtyState = true
end

function PlayerService.swapCell(player: Player)
	local s = sessions[player]
	if not s or Inventory.count(s.profile.inventory, "power.cell") < 1 then
		if s then
			PlayerService.notify(player, "No replacement cells.", "warn")
		end
		return
	end
	if not lightDef(s) then
		return
	end
	if PlayerService.hold(player, Config.Light.batterySwapSeconds, true) then
		if Inventory.remove(s.profile.inventory, "power.cell", 1) then
			s.profile.lightCharge = 100
			services.SaveService.markDirty(player)
			refreshLight(s)
			PlayerService.pushInventory(player)
		end
	end
end

function PlayerService.equipLight(player: Player, itemId: string)
	local s = sessions[player]
	local d = ItemDefs.get(itemId)
	if not s or not d or d.category ~= "light" or Inventory.count(s.profile.inventory, itemId) < 1 then
		return
	end
	s.profile.equippedLight = itemId
	refreshLight(s)
	s.dirtyState = true
end

function PlayerService.setIntents(player: Player, payload: any)
	local s = sessions[player]
	if not s or type(payload) ~= "table" then
		return
	end
	s.intents.sprint = payload.sprint == true
	s.intents.crouch = payload.crouch == true
end

-- Spawn position for the player's last shelter (or the depot before any shelter is registered).
function PlayerService.spawnCFrame(s: Session): CFrame
	local sid = s.profile.lastShelterId
	local sh = WorldDefs.Shelters[sid]
	if sh then
		local c = assert(WorldDefs.chamber("R01.alcove_exterior"))
		return CFrame.new(c.pos.x - 4, 3, c.pos.z)
	end
	local sp = WorldDefs.Depot.spawn
	return CFrame.new(sp.x, sp.y, sp.z)
end

local function onCharacter(s: Session, character: Model)
	s.alive = true
	local h = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	h.BreakJointsOnDeath = false
	h.RequiresNeck = false
	if s.vitals.condition == "dead" then
		Vitals.respawn(Config.Health, s.vitals)
	end
	-- Login and respawn resume at the last shelter. If it has an interior, ShelterService moves them inside.
	task.defer(function()
		root.CFrame = PlayerService.spawnCFrame(s)
		if services.ShelterService then
			services.ShelterService.onSpawn(s.player)
		end
	end)
	syncHumanoidHealth(s)
	refreshLight(s)
	h.Died:Connect(function()
		-- Deaths outside Vitals (e.g. falling out of the world) still create the death bag exactly once.
		if s.vitals.condition ~= "dead" and sessions[s.player] == s then
			s.vitals.condition = "dead"
			s.vitals.health = 0
			PlayerService.onDeath(s.player, "humanoid")
		end
		s.alive = false
	end)
	s.dirtyState = true
end

function PlayerService.onDeath(player: Player, _source: string)
	local s = sessions[player]
	if not s then
		return
	end
	if s.carrying then
		PlayerService.dropCarry(player)
	end
	if s.carriedBy then
		PlayerService.dropCarry(s.carriedBy)
	end
	local pos = PlayerService.position(player) or s.lastGrounded or Vector3.zero
	if s.lastGrounded and (pos - s.lastGrounded).Magnitude < 30 then
		pos = s.lastGrounded -- prefer the last valid grounded location
	end
	services.RecoveryService.createDeathBag(player, pos)
	if services.MissionService then
		services.MissionService.onPlayerDied(player)
	end
	PlayerService.notify(player, "You died. Your unprotected supplies are in a death bag where you fell. Coins and navigation supplies are kept. A later death replaces this death bag.", "danger")
	local h = humanoid(player)
	s.alive = false
	if h and h.Health > 0 then
		h.Health = 0 -- CharacterAutoLoads respawns the character; onCharacter places it at the last shelter
	end
end

-- Logout / disconnect (F17). Moves unbanked expedition loot to a logout bag at the last valid grounded location,
-- unless the player is inside a shelter (banking already happened there).
local departed: { [Player]: boolean } = {}
function PlayerService.handleDeparture(player: Player)
	if departed[player] then
		return
	end
	departed[player] = true
	local s = sessions[player]
	if not s then
		return
	end
	if s.carrying then
		PlayerService.dropCarry(player)
	end
	if s.carriedBy then
		PlayerService.dropCarry(s.carriedBy)
	end
	if services.MissionService then
		services.MissionService.onPlayerLeft(player)
	end
	if services.PartyService then
		services.PartyService.onPlayerLeft(player)
	end
	if not s.insideShelterId then
		local pos = s.lastGrounded or PlayerService.position(player)
		services.RecoveryService.createLogoutBag(player, pos, "logout:" .. s.sessionId)
	end
	services.SaveService.release(player)
	sessions[player] = nil
end

local function onPlayerAdded(player: Player)
	local profile, err = services.SaveService.load(player)
	if not profile then
		player:Kick("Your expedition record could not be loaded safely (" .. tostring(err) .. "). Please rejoin in a moment.")
		return
	end
	local s: Session = {
		player = player,
		profile = profile,
		vitals = Vitals.new(Config.Health),
		stamina = Stamina.new(Config.Stamina),
		intents = { sprint = false, crouch = false },
		mode = "idle",
		lightOn = false,
		regionId = "R00",
		insideShelterId = nil,
		lastGrounded = nil,
		exertion = 0,
		lastThreatAt = os.clock(),
		busyUntil = 0,
		busyToken = 0,
		carrying = nil,
		carriedBy = nil,
		sessionId = HttpService:GenerateGUID(false),
		dirtyState = true,
		lastSent = 0,
		alive = false,
	}
	sessions[player] = s
	-- Crash reconciliation (section 20): a previous session that ended without a clean departure leaves
	-- expedition-provenance items in the saved inventory. Move them to a logout bag at the saved checkpoint.
	if Inventory.unbankedCount(profile.inventory) > 0 and profile.checkpoint then
		services.RecoveryService.reconcileCrash(player)
	end
	player.CharacterAdded:Connect(function(c)
		onCharacter(s, c)
	end)
	if player.Character then
		task.spawn(onCharacter, s, player.Character)
	end
	PlayerService.pushInventory(player)
	if services.RecoveryService then
		services.RecoveryService.pushBags(player)
	end
	if services.NavigationService then
		services.NavigationService.refreshFor(player)
	end
end

function PlayerService.init(s)
	services = s
	stateEvent = Net.event(Net.Names.State)
end

local CHECKPOINT_PERIOD = 5
function PlayerService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(PlayerService.handleDeparture)

	local accCheckpoint = 0
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local TICK = 0.1
	task.spawn(function()
		while true do
			local dt = task.wait(TICK)
			accCheckpoint += dt
			params.FilterDescendantsInstances = { workspace:FindFirstChild("World") :: Instance }
			for player, s in sessions do
				local h = humanoid(player)
				local r = rootPart(player)
				if not h or not r or not s.alive then
					continue
				end
				local moving = h.MoveDirection.Magnitude > 0.1
				local mods = classMods(s)
				local stMods = { regen = { mods.staminaRegenMultiplier or 1 } }
				local prevExhausted = s.stamina.exhausted
				local prevMode = s.mode
				if s.vitals.condition == "downed" or s.carriedBy then
					s.mode = Stamina.step(Config.Stamina, s.stamina, dt, false, false, false, stMods)
				else
					s.mode = Stamina.step(Config.Stamina, s.stamina, dt, moving, s.intents.sprint and not s.carrying, s.intents.crouch, stMods)
				end
				s.exertion = math.clamp(s.exertion + (if s.mode == "sprint" then dt / 10 else -dt / 20), 0, 1)
				if prevMode ~= s.mode or prevExhausted ~= s.stamina.exhausted then
					s.dirtyState = true
				end
				applySpeed(s)
				-- region & grounded checkpoint
				local region = services.WorldBuilder.regionAt(r.Position)
				if region ~= s.regionId then
					s.regionId = region
					s.dirtyState = true
				end
				if h.FloorMaterial ~= Enum.Material.Air and region == "R01" then
					local hit = workspace:Raycast(r.Position, Vector3.new(0, -6, 0), params)
					if hit then
						s.lastGrounded = hit.Position + Vector3.new(0, 1, 0)
					end
				end
				-- vitals
				local before = s.vitals.condition
				Vitals.step(Config.Health, s.vitals, dt, s.insideShelterId ~= nil)
				if before ~= "dead" and s.vitals.condition == "dead" then
					PlayerService.onDeath(player, "bleed_out")
				elseif before ~= s.vitals.condition then
					s.dirtyState = true
				end
				syncHumanoidHealth(s)
				-- light drain
				if s.lightOn and lightDef(s) and s.profile.lightCharge > 0 then
					local d = lightDef(s)
					local drain = ((d and d.drainPerSecond) or 1) * (mods.batteryDrainMultiplier or 1)
					local before2 = s.profile.lightCharge
					s.profile.lightCharge = math.max(0, s.profile.lightCharge - drain * dt)
					if before2 > 0 and s.profile.lightCharge <= 0 then
						PlayerService.notify(player, "Your light has died.", "warn")
						refreshLight(s)
					elseif math.floor(before2) ~= math.floor(s.profile.lightCharge) then
						refreshLight(s)
					end
				end
				-- send state at up to 5 Hz when changed, 1 Hz otherwise
				local now = os.clock()
				if (s.dirtyState and now - s.lastSent > 0.2) or now - s.lastSent > 1 or (s.mode == "sprint" and now - s.lastSent > 0.2) then
					s.dirtyState = false
					s.lastSent = now
					stateEvent:FireClient(player, "vitals", statePayload(s))
				end
			end
			if accCheckpoint >= CHECKPOINT_PERIOD then
				accCheckpoint = 0
				for player, s in sessions do
					if s.lastGrounded and s.regionId == "R01" then
						local anchorId, offset = services.WorldBuilder.anchorFor(s.lastGrounded)
						s.profile.checkpoint = {
							regionId = "R01",
							pocketVersion = 1,
							anchorId = anchorId,
							offset = { x = offset.X, y = offset.Y, z = offset.Z },
						}
						services.SaveService.markDirty(player)
					end
				end
			end
		end
	end)
end

function PlayerService.refreshLight(player: Player)
	local s = sessions[player]
	if s then
		refreshLight(s)
	end
end

return PlayerService
