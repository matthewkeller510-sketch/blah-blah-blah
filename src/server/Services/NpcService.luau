--!strict
-- Story characters N01-N06 (section 05; docs/MILESTONE-3.md 4.6): greybox adult figures built from parts at the
-- depot, each with a name label and a Talk prompt. Talking opens a short subtitled dialogue panel on the client
-- (`"dialogue"` channel) and echoes important instructions to the journal. Who says what is chosen from story facts
-- by Logic/Story.talk; the text lives in Data/StoryDefs.
-- Silhouettes follow the B05 descriptions with colour and props only (PROPOSED greybox): Mara's olive coat and
-- clipboard, Moreau's satchel and gloves, Ines's apron and stock shelf, Amadou's tool harness and repaired headlamp,
-- Noah's rain shell and messenger bag. N05 Elise Renaud exists only as recordings and notes.
-- Noah stands at the depot for players who rescued him; for everyone else the client hides that figure locally
-- (`"npcs"` channel) and the server ignores the prompt (talk() has nothing to say).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local StoryDefs = require(Shared.Data.StoryDefs)
local Story = require(Shared.Logic.Story)

local NpcService = {}
local services: any

local TALK_RANGE = 12 -- studs from the figure; the prompt itself activates at 10
local TALK_COOLDOWN = 0.6

type Look = {
	skin: Color3,
	coat: Color3,
	legs: Color3,
	hands: Color3?,
	prop: string,
}

local LOOKS: { [string]: Look } = {
	N01 = {
		skin = Color3.fromRGB(196, 160, 132),
		coat = Color3.fromRGB(86, 92, 58),
		legs = Color3.fromRGB(52, 50, 46),
		prop = "clipboard",
	},
	N02 = {
		skin = Color3.fromRGB(150, 110, 84),
		coat = Color3.fromRGB(110, 92, 70),
		legs = Color3.fromRGB(60, 58, 54),
		hands = Color3.fromRGB(46, 40, 34),
		prop = "satchel",
	},
	N03 = {
		skin = Color3.fromRGB(120, 84, 60),
		coat = Color3.fromRGB(176, 166, 146),
		legs = Color3.fromRGB(64, 60, 56),
		prop = "apron",
	},
	N04 = {
		skin = Color3.fromRGB(84, 58, 44),
		coat = Color3.fromRGB(64, 72, 80),
		legs = Color3.fromRGB(50, 52, 56),
		prop = "harness",
	},
	N06 = {
		skin = Color3.fromRGB(210, 180, 150),
		coat = Color3.fromRGB(120, 140, 150),
		legs = Color3.fromRGB(70, 70, 74),
		prop = "messenger",
	},
}

local figures: { [string]: Model } = {}
local lastTalk: { [Player]: number } = {}
local visits: { [Player]: { [string]: number } } = {}
local lastHidden: { [Player]: string } = {}

local function figurePosition(npcId: string): Vector3?
	local def = WorldDefs.Characters[npcId]
	local pos = def and def.pos
	return if pos then Vector3.new(pos.x, pos.y, pos.z) else nil
end
NpcService.figurePosition = figurePosition

-- Figures ----------------------------------------------------------------------------------------------

local function buildFigure(npcId: string, name: string, role: string, pos: Vector3, look: Look): Model
	-- Face the courtyard centre (the depot's open space).
	local toward = Vector3.new(-pos.X, 0, -pos.Z)
	if toward.Magnitude < 0.1 then
		toward = Vector3.new(0, 0, 1)
	end
	local cf = CFrame.lookAt(pos, pos + toward.Unit)
	local model = Instance.new("Model")
	model.Name = "Npc_" .. npcId
	local function add(partName: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material?): Part
		local p = Instance.new("Part")
		p.Name = partName
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false -- never intercepts anchors, navigation placement, line of sight or checkpoint rays
		p.CanTouch = false
		p.Size = size
		p.CFrame = cf * offset
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	-- Body (6-stud adult). Local -Z is the front.
	add("LeftLeg", Vector3.new(0.9, 2.8, 0.9), CFrame.new(-0.5, 1.4, 0), look.legs, Enum.Material.Fabric)
	add("RightLeg", Vector3.new(0.9, 2.8, 0.9), CFrame.new(0.5, 1.4, 0), look.legs, Enum.Material.Fabric)
	local torso = add("Torso", Vector3.new(2, 2.4, 1), CFrame.new(0, 4, 0), look.coat, Enum.Material.Fabric)
	add("LeftArm", Vector3.new(0.8, 2.3, 0.8), CFrame.new(-1.4, 4.05, 0), look.coat, Enum.Material.Fabric)
	add("RightArm", Vector3.new(0.8, 2.3, 0.8), CFrame.new(1.4, 4.05, 0), look.coat, Enum.Material.Fabric)
	add("LeftHand", Vector3.new(0.7, 0.55, 0.7), CFrame.new(-1.4, 2.6, 0), look.hands or look.skin)
	add("RightHand", Vector3.new(0.7, 0.55, 0.7), CFrame.new(1.4, 2.6, 0), look.hands or look.skin)
	local head = add("Head", Vector3.new(1.1, 1.2, 1.1), CFrame.new(0, 5.8, 0), look.skin)
	-- Silhouette props
	if look.prop == "clipboard" then
		add("CoatSkirt", Vector3.new(2.1, 1.3, 1.1), CFrame.new(0, 2.25, 0), look.coat, Enum.Material.Fabric)
		add(
			"Clipboard",
			Vector3.new(1, 1.3, 0.1),
			CFrame.new(0.55, 3.7, -0.7) * CFrame.Angles(math.rad(-20), 0, 0),
			Color3.fromRGB(92, 70, 48),
			Enum.Material.Wood
		)
		add(
			"ClipboardSheet",
			Vector3.new(0.8, 1, 0.02),
			CFrame.new(0.55, 3.7, -0.77) * CFrame.Angles(math.rad(-20), 0, 0),
			Color3.fromRGB(230, 226, 214)
		)
	elseif look.prop == "satchel" then
		add(
			"SatchelStrap",
			Vector3.new(0.18, 2.9, 0.12),
			CFrame.new(0, 4, -0.56) * CFrame.Angles(0, 0, math.rad(35)),
			Color3.fromRGB(70, 50, 34),
			Enum.Material.Leather
		)
		add(
			"Satchel",
			Vector3.new(1.1, 0.9, 0.4),
			CFrame.new(1.2, 3, 0.15),
			Color3.fromRGB(96, 66, 42),
			Enum.Material.Leather
		)
		add(
			"Waistcoat",
			Vector3.new(1.4, 1.6, 0.06),
			CFrame.new(0, 4.2, -0.52),
			Color3.fromRGB(150, 140, 120),
			Enum.Material.Fabric
		)
	elseif look.prop == "apron" then
		add(
			"Apron",
			Vector3.new(1.8, 2.8, 0.08),
			CFrame.new(0, 3.2, -0.55),
			Color3.fromRGB(150, 128, 90),
			Enum.Material.Fabric
		)
		-- rolled sleeves: forearms show skin
		add("LeftForearm", Vector3.new(0.82, 0.9, 0.82), CFrame.new(-1.4, 3.3, 0), look.skin)
		add("RightForearm", Vector3.new(0.82, 0.9, 0.82), CFrame.new(1.4, 3.3, 0), look.skin)
		-- compact stock shelf behind her
		local wood = Color3.fromRGB(96, 74, 50)
		add("ShelfFrame", Vector3.new(3, 4.2, 0.2), CFrame.new(0, 2.1, 2.2), wood, Enum.Material.WoodPlanks)
		for i = 1, 3 do
			add("Shelf" .. i, Vector3.new(3, 0.15, 0.9), CFrame.new(0, i * 1.3, 1.75), wood, Enum.Material.WoodPlanks)
			add(
				"Stock" .. i,
				Vector3.new(0.7, 0.6, 0.6),
				CFrame.new(-0.9 + (i - 1) * 0.9, i * 1.3 + 0.38, 1.7),
				Color3.fromRGB(150 - i * 20, 120, 90 + i * 15),
				Enum.Material.Cardboard
			)
		end
	elseif look.prop == "harness" then
		local strap = Color3.fromRGB(40, 38, 34)
		add("HarnessL", Vector3.new(0.25, 2.4, 0.08), CFrame.new(-0.5, 4, -0.54), strap, Enum.Material.Leather)
		add("HarnessR", Vector3.new(0.25, 2.4, 0.08), CFrame.new(0.5, 4, -0.54), strap, Enum.Material.Leather)
		add("ToolBelt", Vector3.new(2.15, 0.35, 1.15), CFrame.new(0, 2.95, 0), strap, Enum.Material.Leather)
		add("Pouch", Vector3.new(0.5, 0.5, 0.35), CFrame.new(0.8, 2.75, -0.6), strap, Enum.Material.Leather)
		add("LampBand", Vector3.new(1.16, 0.22, 1.16), CFrame.new(0, 6.05, 0), strap, Enum.Material.Fabric)
		add(
			"Headlamp",
			Vector3.new(0.34, 0.3, 0.16),
			CFrame.new(0, 6.05, -0.62),
			Color3.fromRGB(255, 226, 160),
			Enum.Material.Neon
		)
		-- the repair: a strip of tape across the lamp housing
		add(
			"LampTape",
			Vector3.new(0.4, 0.08, 0.18),
			CFrame.new(0, 6.15, -0.64),
			Color3.fromRGB(190, 180, 150),
			Enum.Material.Fabric
		)
	elseif look.prop == "messenger" then
		add("Hood", Vector3.new(1.2, 0.6, 0.4), CFrame.new(0, 5.5, 0.62), look.coat)
		add(
			"BagStrap",
			Vector3.new(0.18, 2.9, 0.12),
			CFrame.new(0, 4, -0.56) * CFrame.Angles(0, 0, math.rad(-35)),
			Color3.fromRGB(70, 56, 40),
			Enum.Material.Leather
		)
		add(
			"MessengerBag",
			Vector3.new(1.1, 0.9, 0.35),
			CFrame.new(-1.25, 3, 0.1),
			Color3.fromRGB(96, 74, 52),
			Enum.Material.Leather
		)
	end
	model.PrimaryPart = torso
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic -- the client hides/shows the whole figure at once
	model:SetAttribute("NpcId", npcId)
	-- Name label (readable at conversation distance, not through walls from afar).
	local bb = Instance.new("BillboardGui")
	bb.Name = "NameLabel"
	bb.Size = UDim2.fromOffset(200, 44)
	bb.StudsOffset = Vector3.new(0, 1.4, 0)
	bb.MaxDistance = 28
	bb.LightInfluence = 0
	bb.Parent = head
	local nameText = Instance.new("TextLabel")
	nameText.BackgroundTransparency = 1
	nameText.Size = UDim2.new(1, 0, 0.58, 0)
	nameText.Font = Enum.Font.GothamMedium
	nameText.TextScaled = true
	nameText.TextColor3 = Color3.fromRGB(232, 226, 210)
	nameText.TextStrokeTransparency = 0.4
	nameText.Text = name
	nameText.Parent = bb
	local roleText = Instance.new("TextLabel")
	roleText.BackgroundTransparency = 1
	roleText.Position = UDim2.fromScale(0, 0.6)
	roleText.Size = UDim2.new(1, 0, 0.4, 0)
	roleText.Font = Enum.Font.Gotham
	roleText.TextScaled = true
	roleText.TextColor3 = Color3.fromRGB(180, 174, 160)
	roleText.TextStrokeTransparency = 0.5
	roleText.Text = role
	roleText.Parent = bb
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "TalkPrompt"
	pp.ActionText = if npcId == "N03" then "Talk / trade" else "Talk"
	pp.ObjectText = name
	pp.HoldDuration = 0
	pp.MaxActivationDistance = 10
	pp.RequiresLineOfSight = false
	pp.Parent = torso
	pp.Triggered:Connect(function(player)
		NpcService.talk(player, npcId)
	end)
	CollectionService:AddTag(model, "StoryNpc")
	model.Parent = services.WorldBuilder.folder("R00")
	return model
end

-- Dialogue ---------------------------------------------------------------------------------------------

-- Sends a subtitled dialogue panel to one player. `journal` is echoed to the journal on the client; the
-- persistent journal is derived from facts by StoryService (Story.notes / step journals).
-- pushed: the player did not ask for this (a teammate's shared note, a line after a rescue). The client then keeps
-- mouse-look locked and offers keyboard controls instead of freeing the cursor (D88).
function NpcService.show(
	player: Player,
	npcId: string?,
	name: string,
	lines: { string },
	journal: string?,
	pushed: boolean?
)
	if not player.Parent or not services.PlayerService.get(player) then
		return
	end
	services.PlayerService.send(
		player,
		"dialogue",
		{ npcId = npcId, name = name, lines = lines, journal = journal, pushed = pushed == true }
	)
end

local function characterName(npcId: string): string
	local def = WorldDefs.Characters[npcId]
	return if def then def.name else npcId
end

local function raiseMet(player: Player, npcId: string, state: string)
	local s = services.PlayerService.get(player)
	if s and Story.raiseMet(s.profile.charactersMet, npcId, state) then
		services.SaveService.markDirty(player)
		task.spawn(services.SaveService.commit, player)
		if services.StoryService and services.StoryService.onFact then
			-- Deferred: say() is called from other packages' flows; never re-enter them synchronously.
			task.defer(services.StoryService.onFact, player)
		end
	end
end

-- Contract API: shows a specific line from StoryDefs (e.g. say(player, "N05", "radio_log") for Elise's recording)
-- and writes its journal echo.
function NpcService.say(player: Player, npcId: string, lineId: string, pushed: boolean?)
	local byNpc = StoryDefs.Lines[npcId]
	local line = byNpc and byNpc[lineId]
	if not line then
		warn(string.format("[NpcService] no line %s.%s", tostring(npcId), tostring(lineId)))
		return
	end
	NpcService.show(player, npcId, characterName(npcId), line.lines, line.journal, pushed)
	if npcId == "N05" then
		raiseMet(player, "N05", "encountered") -- heard in a recording
	end
end

-- Talk prompt handler (server-side ProximityPrompt: no client request involved).
function NpcService.talk(player: Player, npcId: string)
	local s = services.PlayerService.get(player)
	local at = figurePosition(npcId)
	local pos = services.PlayerService.position(player)
	if not s or not at or not pos or not s.alive or s.vitals.condition == "downed" then
		return
	end
	if (pos - at).Magnitude > TALK_RANGE then
		return
	end
	local now = os.clock()
	if now - (lastTalk[player] or 0) < TALK_COOLDOWN then
		return
	end
	lastTalk[player] = now
	local f = Story.factsOf(s.profile)
	-- Mara takes story hand-ins (Act I tag, Act II report) exactly like her board does.
	if npcId == "N01" then
		local cur = Story.currentId(f)
		if
			(cur == "A1.6" or cur == "A2.7")
			and services.StoryService
			and services.StoryService.atBoard(player, "figure")
		then
			return
		end
	end
	local perNpc = visits[player]
	if not perNpc then
		perNpc = {}
		visits[player] = perNpc
	end
	local n = perNpc[npcId] or 0
	perNpc[npcId] = n + 1
	local r = Story.talk(npcId, f, n)
	if not r then
		return -- nothing to say to this player (e.g. Noah has not been rescued by them)
	end
	local line = StoryDefs.Lines[npcId] and StoryDefs.Lines[npcId][r.line]
	if not line then
		warn(string.format("[NpcService] no line %s.%s", npcId, r.line))
		return
	end
	local lines = table.clone(line.lines)
	if r.appendObjective then
		local _, _, step = Story.locate(f)
		if step then
			table.insert(lines, "Right now: " .. step.objective)
		end
	end
	NpcService.show(player, npcId, characterName(npcId), lines, line.journal)
	if r.met then
		raiseMet(player, npcId, r.met)
	end
	if npcId == "N03" and services.EconomyService and services.EconomyService.openShop then
		services.EconomyService.openShop(player)
	end
end

-- Per-player figure visibility (Noah at the depot only after you rescued him). Sent only when it changes.
function NpcService.pushVisibility(player: Player, force: boolean?)
	local s = services.PlayerService.get(player)
	if not s or not player.Parent then
		return
	end
	local hidden: { [string]: boolean } = {}
	if s.profile.storyStates["act2.noah_rescued"] ~= "1" then
		hidden.N06 = true
	end
	local sig = if hidden.N06 then "N06" else ""
	if not force and lastHidden[player] == sig then
		return
	end
	lastHidden[player] = sig
	services.PlayerService.send(player, "npcs", { hidden = hidden })
end

function NpcService.init(s)
	services = s
	Players.PlayerRemoving:Connect(function(p)
		lastTalk[p] = nil
		visits[p] = nil
		lastHidden[p] = nil
	end)
end

function NpcService.start()
	for _, npcId in { "N01", "N02", "N03", "N04", "N06" } do
		local def = WorldDefs.Characters[npcId]
		local pos = figurePosition(npcId)
		local look = LOOKS[npcId]
		if def and pos and look then
			local ok, model = pcall(buildFigure, npcId, def.name, def.role, pos, look)
			if ok then
				figures[npcId] = model
			else
				warn("[NpcService] could not build " .. npcId .. ": " .. tostring(model))
			end
		end
	end
end

return NpcService
