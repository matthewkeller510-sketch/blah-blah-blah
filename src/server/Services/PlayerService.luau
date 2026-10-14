--!strict
-- Server-authoritative player session: stamina, health, light, medical use, downed/rescue, death, logout,
-- lantern shield, flares, the injury penalty and field experience (docs/MILESTONE-3.md 4.7, 4.8).
-- Clients send intents (sprint/crouch held, toggle light); the server decides speeds and outcomes (section 19).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Stamina = require(Shared.Logic.Stamina)
local Vitals = require(Shared.Logic.Vitals)
local Inventory = require(Shared.Logic.Inventory)
local Net = require(Shared.Net)
local Director = require(Shared.Logic.Director)
local Progress = require(Shared.Logic.Progress)
local Progression = require(Shared.Logic.Progression)
local PlayerRules = require(Shared.Logic.PlayerRules)
PlayerRules.SHIELDED_BRIGHTNESS = Config.Lantern.shieldedBrightness
local Story = require(Shared.Logic.Story)

local PlayerService = {}

export type Session = {
	player: Player,
	profile: any,
	vitals: Vitals.State,
	stamina: Stamina.State,
	staminaMods: Stamina.Modifiers, -- reused every tick (class edge x injury penalty)
	intents: { sprint: boolean, crouch: boolean },
	mode: string,
	lightOn: boolean, -- the switch; never true without a held light and charge (see lightIsOn for "lit")
	lightDiedOn: boolean, -- the cell ran flat while switched on: a fresh cell switches it back on
	shielded: boolean, -- lantern shutters closed (session only)
	mothFactor: number, -- 1 = normal; CreatureService shortens the light while a Wick Moth swarm clings to it
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
	lastCondition: string,
	hiddenAt: string?, -- hiding spot id while hidden (F07)
	inWater: boolean,
	lastSplash: number,
	lastThrow: number,
	rank: number, -- field-experience rank last applied (rank-up notices)
	syncAt: number, -- os.clock() of the next fact-based experience sync
}

local sessions: { [Player]: Session } = {}
local services: any
local stateEvent: RemoteEvent

local FLARE_ID = "tool.flare"
local PROGRESSION_SYNC_SECONDS = 10 -- PROPOSED: periodic idempotent re-sync of fact-based experience
local CUE_RADIUS = 60

-- Discoveries that record an item claim (unique pickups) pay no place experience.
local ITEM_CLAIM_DISCOVERIES: { [string]: boolean } = {}
for _, u in WorldDefs.UniquePickups do
	ITEM_CLAIM_DISCOVERIES[u.discoveryId] = true
end

-- Notebook labels for the join-time snapshot (matches DiscoveryService's labels for places).
local LABELS: { [string]: string } = {
	["R00.mission_board"] = "Mission Board",
	["R00.equipment_room"] = "Equipment Room",
	["R00.descent_ramp"] = "The Descent",
}
for _, c in WorldDefs.Chambers do
	LABELS[c.id] = c.label
end
for id, sh in WorldDefs.Shelters do
	LABELS["shelter:" .. id] = sh.name
end
for _, u in WorldDefs.UniquePickups do
	LABELS[u.discoveryId] = u.label
end
for _, r in WorldDefs.Readables do
	LABELS[r.id] = r.title
end
for _, pz in WorldDefs.Puzzles do
	LABELS[pz.id .. ".solved"] = pz.name .. " — solved"
end

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
	-- Facts that pay field experience just changed (a discovery, a research stage, a story step): re-sync on the
	-- next tick. Idempotent per key, so it never double-pays whatever the owning package granted itself.
	if channel == "discovery" or channel == "research" or channel == "story" then
		local s = sessions[player]
		if s then
			s.syncAt = 0
		end
	end
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

local function within(a: Player, b: Player, range: number): boolean
	local pa, pb = PlayerService.position(a), PlayerService.position(b)
	return pa ~= nil and pb ~= nil and (pa - pb).Magnitude <= range
end

-- Sends a cue to every player within `radius` of `pos`, and always to `also` (the actor).
local function cueNear(pos: Vector3, radius: number, id: string, also: Player?)
	for p in sessions do
		local pp = PlayerService.position(p)
		if p == also or (pp and (pp - pos).Magnitude <= radius) then
			stateEvent:FireClient(p, "cue", { id = id, position = pos })
		end
	end
end

-- Light ------------------------------------------------------------------------------------------------

local function lightDef(s: Session): ItemDefs.ItemDef?
	local id = s.profile.equippedLight
	if type(id) == "string" and Inventory.count(s.profile.inventory, id) > 0 then
		return ItemDefs.get(id)
	end
	return nil
end

local function lightInput(s: Session): PlayerRules.LightInput
	return {
		switchedOn = s.lightOn,
		def = lightDef(s),
		charge = s.profile.lightCharge,
		condition = s.vitals.condition,
		shielded = s.shielded,
		mothFactor = s.mothFactor,
	}
end

-- The one "is lit" truth: refreshLight, the drain, the HUD payload and lightState all use it.
local function lightIsOn(s: Session): boolean
	return PlayerRules.lightIsOn(lightInput(s))
end

local LANTERN_COLOR = Color3.fromRGB(255, 214, 160)
local BEAM_COLOR = Color3.fromRGB(255, 236, 205)

-- The character's light. A lantern is an omni PointLight (it lights the area for everyone nearby); other lights
-- are the head SpotLight. Both are named ExpeditionLight so the client's low-charge flicker keeps working, and
-- BaseBrightness carries the effective brightness (the client flicker writes Brightness from it).
local function refreshLight(s: Session)
	local c = s.player.Character
	local head = c and c:FindFirstChild("Head")
	if not head then
		return
	end
	local def = lightDef(s)
	local wantPoint = def ~= nil and def.lantern == true
	local existing = head:FindFirstChild("ExpeditionLight")
	if
		existing
		and ((wantPoint and not existing:IsA("PointLight")) or (not wantPoint and not existing:IsA("SpotLight")))
	then
		existing:Destroy()
		existing = nil
	end
	local light: Light
	if existing and existing:IsA("Light") then
		light = existing :: Light
	elseif wantPoint then
		local pl = Instance.new("PointLight")
		pl.Name = "ExpeditionLight"
		pl.Shadows = true
		pl.Parent = head
		light = pl
	else
		local sl = Instance.new("SpotLight")
		sl.Name = "ExpeditionLight"
		sl.Face = Enum.NormalId.Front
		sl.Shadows = true
		sl.Parent = head
		light = sl
	end
	light.Enabled = lightIsOn(s)
	if def then
		local range = PlayerRules.lightRange(def :: any, s.shielded, s.mothFactor)
		local brightness = PlayerRules.lightBrightness(def :: any, s.shielded)
		if wantPoint then
			(light :: PointLight).Range = range
		else
			local sl = light :: SpotLight
			sl.Range = range
			sl.Angle = def.beamAngle or 40
		end
		light.Brightness = brightness
		light:SetAttribute("BaseBrightness", brightness)
		light.Color = if wantPoint then LANTERN_COLOR else BEAM_COLOR
	end
	head:SetAttribute("LightLow", s.profile.lightCharge / 100 < Config.Light.flickerWarningFraction)
end

-- Unequipping or losing a light opens the shutters and drops any moth factor (1 = normal).
local function resetLightMods(s: Session)
	s.shielded = false
	s.mothFactor = 1
end

-- If the equipped light is no longer held (lost in a bag, say), equip the first held light (by id) instead,
-- so a newly found or bought light works without a manual Equip. Returns true when it changed.
local function ensureEquippedLight(s: Session): boolean
	local id = s.profile.equippedLight
	if type(id) == "string" and Inventory.count(s.profile.inventory, id) > 0 then
		return false
	end
	local best: string? = nil
	for itemId in s.profile.inventory do
		local d = ItemDefs.get(itemId)
		if d and d.category == "light" and Inventory.count(s.profile.inventory, itemId) > 0 then
			if best == nil or itemId < best then
				best = itemId
			end
		end
	end
	if best == nil then
		return false
	end
	s.profile.equippedLight = best
	resetLightMods(s)
	services.SaveService.markDirty(s.player)
	refreshLight(s)
	s.dirtyState = true
	return true
end

-- Inventory snapshot for the client (counts only; the server holds the truth).
function PlayerService.pushInventory(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	ensureEquippedLight(s)
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
	s.dirtyState = true -- held flare and cell counts ride on the vitals payload
end

local function applySpeed(s: Session)
	local h = humanoid(s.player)
	if not h then
		return
	end
	h.WalkSpeed = PlayerRules.moveSpeed(Config.Movement, Config.Injury, {
		mode = s.mode,
		downed = s.vitals.condition == "downed",
		held = s.carriedBy ~= nil or s.hiddenAt ~= nil,
		carrying = s.carrying ~= nil,
		injured = s.vitals.injuryFlag,
	})
end

local function syncHumanoidHealth(s: Session)
	local h = humanoid(s.player)
	if h and s.vitals.condition ~= "dead" then
		h.MaxHealth = s.vitals.max
		h.Health = math.max(1, s.vitals.health) -- Humanoid never dies on its own; Vitals decides
	end
end

-- Flares -----------------------------------------------------------------------------------------------

type Flare = { id: number, position: Vector3, owner: Player, expires: number, part: BasePart }
local flares: { Flare } = {}
local flareSeq = 0
local flareFolderRef: Folder? = nil

local function litCount(player: Player): number
	local now, n = os.clock(), 0
	for _, f in flares do
		if f.owner == player and f.expires > now then
			n += 1
		end
	end
	return n
end

-- Lit flares for creatures (C03 lure, C08 decoy). `expires` is on the server os.clock() timebase.
function PlayerService.activeFlares(): { { position: Vector3, owner: Player, expires: number } }
	local now = os.clock()
	local out = {}
	for _, f in flares do
		if f.expires > now then
			table.insert(out, { position = f.position, owner = f.owner, expires = f.expires })
		end
	end
	return out
end

local function flareFolder(): Folder
	local f = flareFolderRef
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Flares"
	nf.Parent = services.WorldBuilder.root()
	flareFolderRef = nf
	return nf
end

-- Config.Flare.placeDistance ahead of the character on the floor; a wall shortens it; no floor -> the feet.
local function flareSpot(root: BasePart): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
	local origin = root.Position
	local down = Vector3.new(0, -12, 0)
	local wall = workspace:Raycast(origin, flat * Config.Flare.placeDistance, params)
	local ahead = if wall then wall.Position - flat * 0.75 else origin + flat * Config.Flare.placeDistance
	local floor = workspace:Raycast(ahead + Vector3.new(0, 1, 0), down, params)
	if floor and floor.Normal.Y > 0.6 then
		return floor.Position
	end
	local feet = workspace:Raycast(origin, down, params)
	if feet then
		return feet.Position
	end
	return origin - Vector3.new(0, 3, 0)
end

local function expireFlare(id: number)
	for i, f in flares do
		if f.id == id then
			table.remove(flares, i)
			f.part:Destroy()
			cueNear(f.position, CUE_RADIUS, "flare_out")
			local s = sessions[f.owner]
			if s then
				s.dirtyState = true
			end
			return
		end
	end
end

-- Request "flare.place": a red flare on the floor ahead, a real shared light for everyone (sections 08, 09).
function PlayerService.placeFlare(player: Player)
	local s = sessions[player]
	local def = ItemDefs.get(FLARE_ID)
	local root = rootPart(player)
	if not s or not def or not root then
		return
	end
	local ok, why = PlayerRules.canPlaceFlare({
		alive = s.alive,
		condition = s.vitals.condition,
		carried = s.carriedBy ~= nil,
		hidden = s.hiddenAt ~= nil,
		inTunnel = WorldDefs.isTunnel(s.regionId),
		inShelter = s.insideShelterId ~= nil,
		held = Inventory.count(s.profile.inventory, FLARE_ID),
		lit = litCount(player),
	}, Config.Flare.maxActivePerPlayer)
	if not ok then
		local msg = why and PlayerRules.FLARE_REFUSALS[why]
		if msg then
			PlayerService.notify(player, msg, "warn")
		end
		return
	end
	local pos = flareSpot(root)
	-- Inventory.remove consumes expedition units before loadout units (existing provenance rule).
	if not Inventory.remove(s.profile.inventory, FLARE_ID, 1) then
		return
	end
	services.SaveService.markDirty(player)
	PlayerService.pushInventory(player)
	local seconds = def.flareSeconds or 45
	local p = Instance.new("Part")
	p.Name = "Flare"
	p.Shape = Enum.PartType.Cylinder -- lies along X, flat on the floor
	p.Size = Vector3.new(1.1, 0.35, 0.35)
	p.CFrame = CFrame.new(pos + Vector3.new(0, 0.18, 0))
		* CFrame.Angles(0, math.atan2(root.CFrame.LookVector.X, root.CFrame.LookVector.Z), 0)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(220, 40, 30)
	p:SetAttribute("OwnerUserId", player.UserId)
	local light = Instance.new("PointLight")
	light.Range = def.flareRange or 18
	light.Brightness = 2.2
	light.Color = Color3.fromRGB(255, 90, 60)
	light.Shadows = false -- TUNE: many flares at once; shadows off keeps them cheap
	light.Parent = p
	p.Parent = flareFolder()
	CollectionService:AddTag(p, "LitFlare")
	flareSeq += 1
	local id = flareSeq
	table.insert(
		flares,
		{ id = id, position = pos, owner = player, expires = os.clock() + seconds, part = p :: BasePart }
	)
	cueNear(pos, CUE_RADIUS, "flare_lit", player)
	s.dirtyState = true
	task.delay(seconds, expireFlare, id)
end

-- Progression (F24, D37) ------------------------------------------------------------------------------

-- Story step lists exported by Logic/Story, in order (ACT1, ACT2, ...).
local function storyActs(): { { any } }
	local acts = {}
	local i = 1
	while true do
		local a = (Story :: any)["ACT" .. i]
		if type(a) ~= "table" then
			break
		end
		table.insert(acts, a)
		i += 1
	end
	return acts
end

local function factAwards(s: Session): { Progression.Award }
	local p = s.profile
	-- The profile carries every fact the story predicates read (discoveries, claims, storyStates, upgrades...).
	local stepIds = Progression.completedStepIds(storyActs(), p)
	return Progression.factAwards(Config.Progression, {
		discoveries = p.discoveries,
		research = p.research,
		storyStates = p.storyStates,
	}, ITEM_CLAIM_DISCOVERIES, stepIds)
end

local function progressionPayload(snap: Progression.Snapshot)
	return {
		xp = snap.xp,
		rank = snap.rank,
		rankXp = snap.rankXp,
		nextRankXp = snap.nextRankXp,
		staminaBonus = snap.staminaBonus,
		healthBonus = snap.healthBonus,
		staminaCap = snap.staminaCap,
		healthCap = snap.healthCap,
	}
end

-- Applies the bonuses to the live session (Stamina max, Vitals max, Humanoid) and pushes "progression".
-- A higher maximum is never a free heal; the F18 passive cap follows the new maximum (Vitals.passiveCap).
local function applyProgression(s: Session, announce: boolean)
	local rec = Progression.normalize(s.profile)
	local snap = Progression.snapshot(Config.Progression, rec.xp)
	Stamina.setMax(Config.Stamina, s.stamina, Config.Stamina.max + snap.staminaBonus)
	Vitals.setMax(Config.Health, s.vitals, Config.Health.max + snap.healthBonus)
	if type(s.profile.stats) == "table" then
		-- derived cache of the bonuses (profile.stats); the experience record stays the source of truth
		s.profile.stats.maxStaminaBonus = snap.staminaBonus
		s.profile.stats.maxHealthBonus = snap.healthBonus
	end
	syncHumanoidHealth(s)
	s.dirtyState = true
	stateEvent:FireClient(s.player, "progression", progressionPayload(snap))
	if announce and snap.rank > s.rank then
		PlayerService.notify(
			s.player,
			string.format(
				"Field experience: rank %d — max stamina +%d, max health +%d",
				snap.rank,
				snap.staminaBonus,
				snap.healthBonus
			),
			"info"
		)
	end
	s.rank = snap.rank
end

-- Pays every fact-based key not yet paid (idempotent). Returns the experience added.
local function syncProgression(s: Session, announce: boolean): number
	local rec = Progression.normalize(s.profile)
	local added = Progression.applyAwards(rec, factAwards(s))
	if added > 0 then
		services.SaveService.markDirty(s.player)
		applyProgression(s, announce)
	end
	return added
end

-- Contract API: idempotent per key (see Logic/Progression for the key formats); persists; pushes "progression".
function PlayerService.grantXp(player: Player, key: string, amount: number): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	local rec = Progression.normalize(s.profile)
	if not Progression.grant(rec, key, amount) then
		return false
	end
	services.SaveService.markDirty(player)
	applyProgression(s, true)
	return true
end

-- Join-time notebook snapshot: the client otherwise only learns of discoveries and research as they happen.
local function pushNotebook(s: Session)
	local discoveries = {}
	for id, v in s.profile.discoveries do
		if v == true and type(id) == "string" then
			table.insert(discoveries, { id = id, label = LABELS[id] or id })
		end
	end
	local research = {}
	for creatureId, e in s.profile.research do
		local def = WorldDefs.creatureById(creatureId)
		local stage = type(e) == "table" and tonumber(e.stage) or 0
		if def and stage and stage >= 1 then
			table.insert(research, {
				id = creatureId,
				name = def.name,
				stage = stage,
				stageName = Progress.stageName(stage),
				stages = #def.researchEvidence,
				nextHint = def.hints and def.hints[stage + 1] or nil,
			})
		end
	end
	stateEvent:FireClient(s.player, "notebook", { discoveries = discoveries, research = research })
end

-- State payload ----------------------------------------------------------------------------------------

local function statePayload(s: Session)
	local def = lightDef(s)
	local ls = PlayerRules.lightState(lightInput(s))
	return {
		health = s.vitals.health,
		maxHealth = s.vitals.max,
		passiveCap = Vitals.passiveCap(Config.Health, s.vitals),
		condition = s.vitals.condition,
		injured = s.vitals.injuryFlag, -- the injury penalty (D40): sprint and stamina regen slowed until treated
		downedRemaining = s.vitals.downedRemaining,
		stabilized = s.vitals.stabilized,
		stamina = s.stamina.value,
		staminaMax = Stamina.maxOf(Config.Stamina, s.stamina),
		exhausted = s.stamina.exhausted,
		showStamina = Stamina.shouldShowBar(Config.Stamina, s.stamina),
		lightOn = ls.on,
		lightName = def and def.displayName or nil,
		lightCharge = s.profile.lightCharge,
		isLantern = ls.isLantern,
		shielded = ls.shielded,
		lightDimmed = ls.on and s.mothFactor < 1,
		cells = Inventory.count(s.profile.inventory, "power.cell"),
		flares = Inventory.count(s.profile.inventory, FLARE_ID),
		flaresLit = litCount(s.player),
		regionId = s.regionId,
		inShelter = s.insideShelterId,
		busy = os.clock() < s.busyUntil,
		carrying = s.carrying ~= nil,
		carriedBy = s.carriedBy and s.carriedBy.DisplayName or nil,
		hidden = s.hiddenAt ~= nil,
		inWater = s.inWater,
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
	if s.hiddenAt then
		PlayerService.unhide(player)
	end
	local before = s.vitals.condition
	local cond = Vitals.damage(Config.Health, s.vitals, amount, causesInjury)
	s.busyUntil = 0 -- damage interrupts held medical actions
	s.busyToken += 1
	s.lastThreatAt = os.clock()
	if cond == "downed" and before ~= "downed" then
		PlayerService.notify(
			player,
			"You are down. A party member can stabilize you, or crawl toward safety.",
			"danger"
		)
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

local function upright(s: Session): boolean
	return s.alive and s.vitals.condition ~= "downed" and s.vitals.condition ~= "dead"
end

-- Bandage, dressing or splint (the splint heals 5 and removes the injury penalty through the same path).
function PlayerService.useMedical(player: Player, itemId: string, target: Player?)
	local s = sessions[player]
	local d = ItemDefs.get(itemId)
	if not s or not d or d.category ~= "medical" then
		return
	end
	if s.vitals.condition == "downed" or s.carriedBy then
		PlayerService.notify(player, "You cannot treat anyone while down. A party member can help you.", "warn")
		return
	end
	if not upright(s) then
		return
	end
	local ts = s
	local other = target ~= nil and target ~= player
	if other then
		local t = sessions[target :: Player]
		if not t then
			return
		end
		if not services.PartyService.sameParty(player, target) then
			PlayerService.notify(player, "You can only treat members of your current party.", "warn")
			return
		end
		if not within(player, target :: Player, 9) then
			return
		end
		ts = t
	end
	if Inventory.count(s.profile.inventory, itemId) < 1 then
		PlayerService.notify(player, "You have no " .. d.displayName .. ".", "warn")
		return
	end
	-- Say so before the hold instead of wasting it.
	if ts.vitals.condition == "downed" then
		if not ts.vitals.stabilized then
			PlayerService.notify(player, "Stabilize them first.", "warn")
			return
		end
	elseif ts.vitals.health >= ts.vitals.max and not (d.removesInjury and ts.vitals.injuryFlag) then
		PlayerService.notify(player, if other then "They do not need that." else "You do not need that now.", "info")
		return
	end
	local treat = (d.treatSeconds or 3) * (classMods(s).treatTimeMultiplier or 1)
	if not PlayerService.hold(player, treat) then
		return
	end
	-- Re-validate after the hold: the healer may have been downed, the target may have left, moved off or
	-- left the party, and the item may be gone.
	if sessions[player] ~= s or not upright(s) then
		return
	end
	if other then
		local t = target :: Player
		if sessions[t] ~= ts or not services.PartyService.sameParty(player, t) or not within(player, t, 9) then
			PlayerService.notify(player, "They moved out of reach.", "warn")
			return
		end
	end
	if Inventory.count(s.profile.inventory, itemId) < 1 then
		return
	end
	local applied
	if ts.vitals.condition == "downed" then
		applied = ts.vitals.stabilized
			and Vitals.revive(Config.Health, ts.vitals, Config.Health.stabilizedHealth + (d.healAmount or 0))
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
		-- A teammate revived while being carried is released, never left welded and unable to move.
		if ts.carriedBy then
			PlayerService.dropCarry(ts.carriedBy)
		end
	end
end

function PlayerService.stabilize(player: Player, target: Player)
	local s, t = sessions[player], sessions[target]
	if not s or not t or player == target or not upright(s) or s.hiddenAt then
		return
	end
	if not services.PartyService.sameParty(player, target) then
		PlayerService.notify(player, "Only party members can stabilize each other. Invite them first.", "warn")
		return
	end
	if t.vitals.condition ~= "downed" then
		return
	end
	if not within(player, target, 8) then
		return
	end
	local secs = Config.Health.stabilizeHoldSeconds * (classMods(s).treatTimeMultiplier or 1)
	if not PlayerService.hold(player, secs) then
		return
	end
	if
		sessions[player] ~= s
		or sessions[target] ~= t
		or not upright(s)
		or t.vitals.condition ~= "downed"
		or not services.PartyService.sameParty(player, target)
		or not within(player, target, 8)
	then
		return
	end
	Vitals.stabilize(Config.Health, t.vitals)
	t.dirtyState = true
	PlayerService.notify(target, player.DisplayName .. " stabilized you.", "info")
end

-- Carrying a downed teammate (section 07). Uses a weld; detaches safely on drop, party change or downing.
function PlayerService.startCarry(player: Player, target: Player)
	local s, t = sessions[player], sessions[target]
	if not s or not t or s.carrying or t.carriedBy or player == target then
		return
	end
	if not upright(s) or s.hiddenAt or s.carriedBy then
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

-- The switch only turns on when there is something to light: no "on" flag on a missing light or flat cell.
function PlayerService.toggleLight(player: Player)
	local s = sessions[player]
	if not s or s.vitals.condition == "dead" then
		return
	end
	s.lightDiedOn = false
	if s.lightOn then
		s.lightOn = false
	elseif not lightDef(s) then
		PlayerService.notify(player, "You have no light. Move slowly and feel along the walls.", "warn")
	elseif s.profile.lightCharge <= 0 then
		PlayerService.notify(player, "The cell is flat. Swap in a replacement cell if you have one.", "warn")
	else
		s.lightOn = true
	end
	refreshLight(s)
	s.dirtyState = true
end

function PlayerService.swapCell(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	if not upright(s) then
		return
	end
	if Inventory.count(s.profile.inventory, "power.cell") < 1 then
		PlayerService.notify(player, "No replacement cells.", "warn")
		return
	end
	if not lightDef(s) then
		PlayerService.notify(player, "Equip a light first.", "info")
		return
	end
	local full = (ItemDefs.require("power.cell")).charge or 100
	if s.profile.lightCharge >= full then
		PlayerService.notify(player, "Your cell is still full.", "info")
		return
	end
	if not PlayerService.hold(player, Config.Light.batterySwapSeconds, true) then
		return
	end
	if sessions[player] ~= s or not upright(s) or not lightDef(s) then
		return
	end
	if Inventory.remove(s.profile.inventory, "power.cell", 1) then
		s.profile.lightCharge = full
		if s.lightDiedOn then
			s.lightOn = true -- it went out while switched on: a fresh cell brings it back
			s.lightDiedOn = false
		end
		services.SaveService.markDirty(player)
		refreshLight(s)
		s.dirtyState = true
		PlayerService.pushInventory(player)
	end
end

function PlayerService.equipLight(player: Player, itemId: string)
	local s = sessions[player]
	local d = ItemDefs.get(itemId)
	if not s or not d or d.category ~= "light" or Inventory.count(s.profile.inventory, itemId) < 1 then
		return
	end
	if s.profile.equippedLight ~= itemId then
		s.profile.equippedLight = itemId
		resetLightMods(s)
		services.SaveService.markDirty(player)
	end
	refreshLight(s)
	s.dirtyState = true
end

-- Contract: the effective light state read by creatures (C03 Wick Moth, C08 Lantern Thief, the director).
function PlayerService.lightState(player: Player): PlayerRules.LightState
	local s = sessions[player]
	if not s then
		return { on = false, itemId = nil, isLantern = false, shielded = false, range = 0 }
	end
	return PlayerRules.lightState(lightInput(s))
end

-- Contract: a creature switches the light off. The charge is unchanged; the player can switch it back on.
function PlayerService.snuffLight(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	local wasOn = lightIsOn(s)
	s.lightOn = false
	s.lightDiedOn = false
	refreshLight(s)
	s.dirtyState = true
	if wasOn then
		PlayerService.notify(player, "Your light was snuffed.", "warn")
	end
end

-- Contract: a clinging Wick Moth swarm shortens the light (factor 1 = normal). Never touches charge or health.
-- Reset to 1 on unequip and on death.
function PlayerService.setMothRangeFactor(player: Player, factor: number)
	local s = sessions[player]
	local f = PlayerRules.clampMothFactor(factor)
	if not s or f == nil or f == s.mothFactor then
		return
	end
	s.mothFactor = f
	refreshLight(s)
	s.dirtyState = true
end

-- Request "light.shield": close or open the lantern shutters (shielded = short, dim, quiet for creatures).
function PlayerService.toggleShield(player: Player)
	local s = sessions[player]
	if not s or s.vitals.condition == "dead" then
		return
	end
	local def = lightDef(s)
	if not def or not def.lantern then
		PlayerService.notify(player, "Only a lantern has shutters to close.", "info")
		return
	end
	s.shielded = not s.shielded
	refreshLight(s)
	s.dirtyState = true
	local pos = PlayerService.position(player)
	if pos then
		cueNear(pos, 20, "lantern_shield", player)
	end
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
	if WorldDefs.Shelters[sid] then
		local _, stand = services.WorldBuilder.shelterDoor(sid)
		return stand
	end
	local sp = WorldDefs.Depot.spawn
	return CFrame.new(sp.x, sp.y, sp.z)
end

-- Hiding (F07) ----------------------------------------------------------------------------------------
local occupiedSpots: { [string]: Player } = {}
local spotIndex: { [string]: BasePart } = {} -- HidingSpotId -> anchor, kept current by tag signals

local function spotAnchor(spotId: string): BasePart?
	return spotIndex[spotId]
end

function PlayerService.unhide(player: Player)
	local s = sessions[player]
	if not s or not s.hiddenAt then
		return
	end
	local anchor = spotAnchor(s.hiddenAt)
	occupiedSpots[s.hiddenAt] = nil
	s.hiddenAt = nil
	local r = rootPart(player)
	if r then
		r.Anchored = false
		if anchor then
			r.CFrame = anchor.CFrame * CFrame.new(0, 0, -3) -- step out into the room
		end
	end
	s.dirtyState = true
end

function PlayerService.hide(player: Player, spotId: string)
	local s = sessions[player]
	local anchor = spotAnchor(spotId)
	local r = rootPart(player)
	if not s or not anchor or not r then
		return
	end
	if s.hiddenAt == spotId then
		PlayerService.unhide(player)
		return
	end
	if s.hiddenAt or s.carrying or s.carriedBy or not upright(s) then
		return
	end
	if occupiedSpots[spotId] then
		PlayerService.notify(player, "Someone is already hiding there.", "info")
		return
	end
	if (r.Position - anchor.Position).Magnitude > 9 then
		return
	end
	occupiedSpots[spotId] = player
	s.hiddenAt = spotId
	r.CFrame = anchor.CFrame
	r.Anchored = true
	s.dirtyState = true
	PlayerService.notify(player, "Hidden. Creatures cannot sense you here. Use the niche again to step out.", "info")
end

function PlayerService.isHidden(player: Player): boolean
	local s = sessions[player]
	return s ~= nil and s.hiddenAt ~= nil
end

-- Hiding spots built at any time (pocket versions included) get a prompt; removed ones release their occupant.
local function hookSpot(inst: Instance)
	local id = inst:GetAttribute("HidingSpotId")
	if not inst:IsA("BasePart") or type(id) ~= "string" then
		return
	end
	spotIndex[id] = inst :: BasePart
	if inst:FindFirstChild("HidePrompt") then
		return
	end
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "HidePrompt"
	pp.ActionText = "Hide / step out"
	pp.ObjectText = "Niche"
	pp.HoldDuration = 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = inst
	pp.Triggered:Connect(function(player)
		PlayerService.hide(player, id)
	end)
end

local function unhookSpot(inst: Instance)
	local id = inst:GetAttribute("HidingSpotId")
	if type(id) ~= "string" or spotIndex[id] ~= inst then
		return
	end
	local occupant = occupiedSpots[id]
	if occupant then
		PlayerService.unhide(occupant)
	end
	spotIndex[id] = nil
	occupiedSpots[id] = nil
end

-- Throwing a stone makes a noise where it lands: a splash in water, a clatter on stone. No item needed.
function PlayerService.throwStone(player: Player)
	local s = sessions[player]
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not s or not head or s.hiddenAt or not upright(s) then
		return
	end
	if os.clock() - s.lastThrow < 2.5 then
		return
	end
	s.lastThrow = os.clock()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local dir = head.CFrame.LookVector
	local hit = workspace:Raycast(head.Position, dir * 40, params)
	local landing = if hit then hit.Position else head.Position + dir * 40
	-- drop to the floor below the landing point
	local floor = workspace:Raycast(landing + Vector3.new(0, 1, 0), Vector3.new(0, -20, 0), params)
	if floor then
		landing = floor.Position
	end
	local wet = services.WorldBuilder.inWater(landing + Vector3.new(0, 0.2, 0))
	services.CreatureService.noise(landing, if wet then "splash" else "clatter", 1, nil, player)
	for p in sessions do
		local pos = PlayerService.position(p)
		if pos and (pos - landing).Magnitude < 60 then
			PlayerService.send(p, "cue", { id = if wet then "stone_splash" else "stone_clatter", position = landing })
		end
	end
end

-- First join: choose a class once for free (F22: changing later has a cost).
function PlayerService.chooseStartingClass(player: Player, className: string)
	local s = sessions[player]
	if not s or s.profile.storyStates.onboarded == "1" or not Config.Classes[className] then
		return
	end
	s.profile.class = className
	s.profile.storyStates.onboarded = "1"
	services.SaveService.markDirty(player)
	PlayerService.pushInventory(player)
	PlayerService.send(player, "onboarding", { done = true })
	if services.StoryService then
		services.StoryService.push(player)
	end
end

local function onCharacter(s: Session, character: Model)
	if s.hiddenAt then
		occupiedSpots[s.hiddenAt] = nil
		s.hiddenAt = nil
	end
	local h = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	if sessions[s.player] ~= s or s.player.Character ~= character then
		return -- left, or a newer character arrived, while this one was loading
	end
	s.alive = true
	h.BreakJointsOnDeath = false
	h.RequiresNeck = false
	if s.vitals.condition == "dead" then
		Vitals.respawn(Config.Health, s.vitals) -- at the F18 cap of the current (bonus-raised) maximum
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
	-- The light (and everything unprotected) goes to the bag: switch off, open shutters, drop any moth factor.
	s.lightOn = false
	s.lightDiedOn = false
	resetLightMods(s)
	local pos = PlayerService.position(player) or s.lastGrounded or Vector3.zero
	if s.lastGrounded and (pos - s.lastGrounded).Magnitude < 30 then
		pos = s.lastGrounded -- prefer the last valid grounded location
	end
	services.RecoveryService.createDeathBag(player, pos)
	if services.MissionService then
		services.MissionService.onPlayerDied(player)
	end
	PlayerService.notify(
		player,
		"You died. Your unprotected supplies are in a death bag where you fell. Coins and navigation supplies are kept. A later death replaces this death bag.",
		"danger"
	)
	local h = humanoid(player)
	s.alive = false
	refreshLight(s)
	s.dirtyState = true
	if h and h.Health > 0 then
		h.Health = 0 -- CharacterAutoLoads respawns the character; onCharacter places it at the last shelter
	end
end

-- Logout / disconnect (F17). Moves unbanked expedition loot to a logout bag at the last valid grounded location,
-- unless the player is inside a shelter (banking already happened there).
local departed: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function PlayerService.handleDeparture(player: Player)
	if departed[player] then
		return
	end
	departed[player] = true
	local s = sessions[player]
	if not s then
		return
	end
	if s.hiddenAt then
		occupiedSpots[s.hiddenAt] = nil
	end
	if s.carrying then
		PlayerService.dropCarry(player)
	end
	if s.carriedBy then
		PlayerService.dropCarry(s.carriedBy)
	end
	-- Create the bag while the party still exists so present members are authorized (proposal D03).
	if not s.insideShelterId then
		local pos = s.lastGrounded or PlayerService.position(player)
		services.RecoveryService.createLogoutBag(player, pos, "logout:" .. s.sessionId)
	end
	if services.MissionService then
		services.MissionService.onPlayerLeft(player)
	end
	if services.PartyService then
		services.PartyService.onPlayerLeft(player)
	end
	services.SaveService.release(player)
	sessions[player] = nil
	-- Lit flares keep burning after their owner leaves; they simply expire.
end

local function onPlayerAdded(player: Player)
	local profile, err = services.SaveService.load(player)
	if profile and (not player.Parent or departed[player]) then
		-- Left while the profile was loading: release the lock instead of leaving an orphan session.
		services.SaveService.release(player)
		return
	end
	if not profile then
		player:Kick(
			"Your expedition record could not be loaded safely (" .. tostring(err) .. "). Please rejoin in a moment."
		)
		return
	end
	local s: Session = {
		player = player,
		profile = profile,
		vitals = Vitals.new(Config.Health),
		stamina = Stamina.new(Config.Stamina),
		staminaMods = { regen = { 1, 1 } },
		intents = { sprint = false, crouch = false },
		mode = "idle",
		lightOn = false,
		lightDiedOn = false,
		shielded = false,
		mothFactor = 1,
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
		lastCondition = "healthy",
		hiddenAt = nil,
		inWater = false,
		lastSplash = 0,
		lastThrow = 0,
		rank = 0,
		syncAt = os.clock() + PROGRESSION_SYNC_SECONDS,
	}
	sessions[player] = s
	-- Crash reconciliation (section 20): a previous session that ended without a clean departure leaves
	-- expedition-provenance items in the saved inventory. Move them to a logout bag at the saved checkpoint.
	if Inventory.unbankedCount(profile.inventory) > 0 and profile.checkpoint then
		services.RecoveryService.reconcileCrash(player)
	end
	-- Field experience: back-fill idempotently from existing facts (earlier play, offline changes), then apply
	-- the bonuses before the character exists. A fresh session starts at full health as before (vitals are not
	-- persisted), now at the raised maximum.
	local rec = Progression.normalize(profile)
	local added = Progression.applyAwards(rec, factAwards(s))
	s.rank = Progression.rank(Config.Progression, rec.xp)
	applyProgression(s, false)
	s.vitals.health = s.vitals.max
	s.stamina.value = Stamina.maxOf(Config.Stamina, s.stamina)
	if added > 0 then
		services.SaveService.markDirty(player)
		local snap = Progression.snapshot(Config.Progression, rec.xp)
		PlayerService.notify(
			player,
			string.format(
				"Field experience from earlier expeditions recorded (+%d): rank %d — max stamina +%d, max health +%d.",
				added,
				snap.rank,
				snap.staminaBonus,
				snap.healthBonus
			),
			"info"
		)
	end
	player.CharacterAdded:Connect(function(c)
		onCharacter(s, c)
	end)
	if player.Character then
		task.spawn(onCharacter, s, player.Character)
	end
	PlayerService.pushInventory(player)
	pushNotebook(s)
	if profile.storyStates.onboarded ~= "1" then
		PlayerService.send(player, "onboarding", { classes = Config.Classes, current = profile.class })
	end
	if services.StoryService then
		services.StoryService.push(player)
	end
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
	-- Milestone 3 requests. Payloads carry nothing: the server derives position, facing and inventory itself.
	s.Router.register("light.shield", "interact", function(p: Player)
		PlayerService.toggleShield(p)
	end)
	s.Router.register("flare.place", "interact", function(p: Player)
		PlayerService.placeFlare(p)
	end)
end

-- Expedition checkpoint (section 20): the anchor shape RecoveryService.reconcileCrash uses as a bag anchor.
-- Inside a variable pocket it also records pocketId and that pocket's current version id (a string); elsewhere
-- it keeps the old numeric pocketVersion = 1 so earlier saves and records stay valid.
local function checkpointFor(pos: Vector3): { [string]: any }
	local anchorId, offset, regionId = services.WorldBuilder.anchorFor(pos)
	local cp: { [string]: any } = {
		regionId = regionId,
		pocketVersion = 1,
		anchorId = anchorId,
		offset = { x = offset.X, y = offset.Y, z = offset.Z },
	}
	local pockets = services.PocketService
	if pockets then
		local pocketId = pockets.pocketAt(pos)
		if type(pocketId) == "string" then
			local version = pockets.versionOf(pocketId)
			if version ~= nil then
				cp.pocketId = pocketId
				cp.pocketVersion = version
			end
		end
	end
	return cp
end

local CHECKPOINT_PERIOD = 5

local function tickPlayer(player: Player, s: Session, dt: number, params: RaycastParams)
	local h = humanoid(player)
	local r = rootPart(player)
	if not h or not r or not s.alive then
		return
	end
	local moving = h.MoveDirection.Magnitude > 0.1
	local mods = classMods(s)
	-- Stamina regeneration: class edge times the injury penalty (D40), combined and clamped by Stamina.
	PlayerRules.regenFactors(mods.staminaRegenMultiplier, s.vitals.injuryFlag, Config.Injury, s.staminaMods.regen)
	local prevExhausted = s.stamina.exhausted
	local prevMode = s.mode
	if s.vitals.condition == "downed" or s.carriedBy then
		s.mode = Stamina.step(Config.Stamina, s.stamina, dt, false, false, false, s.staminaMods)
	else
		s.mode = Stamina.step(
			Config.Stamina,
			s.stamina,
			dt,
			moving,
			s.intents.sprint and not s.carrying,
			s.intents.crouch,
			s.staminaMods
		)
	end
	s.exertion = math.clamp(s.exertion + (if s.mode == "sprint" then dt / 10 else -dt / 20), 0, 1)
	if prevMode ~= s.mode or prevExhausted ~= s.stamina.exhausted then
		s.dirtyState = true
	end
	-- A carried teammate who is no longer down (revived by any path) is released, never left welded.
	if s.carriedBy and s.vitals.condition ~= "downed" then
		PlayerService.dropCarry(s.carriedBy)
	end
	applySpeed(s)
	-- Splash noise for water-sensitive hearing (C06 Wader): crouch-wading and dry footing are silent.
	s.inWater = services.WorldBuilder.inWater(r.Position - Vector3.new(0, 3, 0))
	-- hidden players make no noise even if they press movement keys while held in the niche
	local splash = if s.hiddenAt then 0 else Director.splashNoise(s.mode, s.inWater)
	if splash > 0 and os.clock() - s.lastSplash > 0.4 then
		s.lastSplash = os.clock()
		services.CreatureService.noise(r.Position - Vector3.new(0, 3, 0), "splash", splash, player)
	end
	-- region & grounded checkpoint
	local region = services.WorldBuilder.regionAt(r.Position)
	if region ~= s.regionId then
		s.regionId = region
		s.dirtyState = true
	end
	if h.FloorMaterial ~= Enum.Material.Air and WorldDefs.isTunnel(region) then
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
	-- Any condition change (damage, revive, bleed-out) refreshes the light: a downed player's goes out.
	if s.lastCondition ~= s.vitals.condition then
		s.lastCondition = s.vitals.condition
		refreshLight(s)
	end
	-- light drain: only while actually lit (never while downed, flat or without a held light)
	if lightIsOn(s) then
		local d = lightDef(s)
		local drain = ((d and d.drainPerSecond) or 1) * (mods.batteryDrainMultiplier or 1)
		local before2 = s.profile.lightCharge
		s.profile.lightCharge = math.max(0, s.profile.lightCharge - drain * dt)
		if s.profile.lightCharge <= 0 then
			s.lightOn = false
			s.lightDiedOn = true
			PlayerService.notify(player, "Your light has died.", "warn")
			refreshLight(s)
			s.dirtyState = true
		elseif math.floor(before2) ~= math.floor(s.profile.lightCharge) then
			refreshLight(s)
		end
	end
	-- fact-based field experience (pushes request an immediate sync; otherwise a slow periodic one)
	if os.clock() >= s.syncAt then
		s.syncAt = os.clock() + PROGRESSION_SYNC_SECONDS
		syncProgression(s, true)
	end
	-- send state at up to 5 Hz when changed, 1 Hz otherwise
	local now = os.clock()
	if
		(s.dirtyState and now - s.lastSent > 0.2)
		or now - s.lastSent > 1
		or (s.mode == "sprint" and now - s.lastSent > 0.2)
	then
		s.dirtyState = false
		s.lastSent = now
		stateEvent:FireClient(player, "vitals", statePayload(s))
	end
end

function PlayerService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(PlayerService.handleDeparture)
	for _, a in CollectionService:GetTagged("HidingSpot") do
		hookSpot(a)
	end
	CollectionService:GetInstanceAddedSignal("HidingSpot"):Connect(hookSpot)
	CollectionService:GetInstanceRemovedSignal("HidingSpot"):Connect(unhookSpot)

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
				-- One player's failure (or another service's) never stops the loop for everyone.
				xpcall(tickPlayer, function(err)
					warn(
						string.format(
							"[PlayerService] tick for %d failed: %s",
							player.UserId,
							debug.traceback(tostring(err))
						)
					)
				end, player, s, dt, params)
			end
			if accCheckpoint >= CHECKPOINT_PERIOD then
				accCheckpoint = 0
				for player, s in sessions do
					local grounded = s.lastGrounded
					if grounded and WorldDefs.isTunnel(s.regionId) then
						local ok, cp = pcall(checkpointFor, grounded)
						if ok then
							s.profile.checkpoint = cp
							services.SaveService.markDirty(player)
						else
							warn("[PlayerService] checkpoint failed: " .. tostring(cp))
						end
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
