--!strict
-- The story acts (section 05): Act I "The Descent" and Act II "Contradictory Records" (docs/MILESTONE-3.md 4.5).
-- Story progress is derived from profile facts (Logic/Story.luau), pushed to the HUD as the current objective and
-- to the notebook as journal entries with subtitle-ready text. Completed story objectives are permanent
-- (section 06): repeatable missions never reset them.
-- Also builds the story's world interactions: readable notes (WorldDefs.Readables; text in Data/StoryDefs) and the
-- Map Room table for Act II step 6. Every major revelation has a place, an item and a witness or recording.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local StoryDefs = require(Shared.Data.StoryDefs)
local Story = require(Shared.Logic.Story)
local Inventory = require(Shared.Logic.Inventory)

local StoryService = {}
local services: any
local lastSig: { [Player]: string } = {}
local lastStep: { [Player]: string } = {}
local xpGranted: { [Player]: { [string]: boolean } } = {}
local lastUse: { [Player]: number } = {}

local ACT1_REWARD_COINS = 60 -- TUNE (Milestone 2 value)
local READ_RANGE = 10
local USE_COOLDOWN = 0.8

local RECORDINGS = {
	radio = StoryDefs.Lines.N05.radio_log.journal,
	revelation = StoryDefs.MapTableText.revelation.journal,
}

local function v(t: { x: number, y: number, z: number }): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

local function notify(player: Player, text: string, kind: string?)
	if player.Parent then
		services.PlayerService.notify(player, text, kind)
	end
end

-- Durable commit before the success text (section 20; B5).
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

local function say(player: Player, npcId: string, lineId: string)
	if services.NpcService then
		services.NpcService.say(player, npcId, lineId)
	end
end

local function show(player: Player, name: string, lines: { string }, journal: string?, pushed: boolean?)
	if services.NpcService then
		services.NpcService.show(player, nil, name, lines, journal, pushed)
	end
end

-- Field experience once per completed story step, in story order (key "story:" .. stepId; idempotent by key, and
-- the player package back-fills the same keys on load).
local function grantStoryXp(player: Player, f: Story.Facts)
	local ps = services.PlayerService
	if not ps or type(ps.grantXp) ~= "function" then
		return
	end
	local done = xpGranted[player]
	if not done then
		done = {}
		xpGranted[player] = done
	end
	for _, stepId in Story.completedStepIds(f) do
		local key = Story.xpKey(stepId)
		if not done[key] then
			done[key] = true
			task.spawn(ps.grantXp, player, key, Config.Progression.xp.story)
		end
	end
end

-- Sends the story state. The poll passes onlyIfChanged so unchanged state is not re-sent every few seconds.
function StoryService.push(player: Player, onlyIfChanged: boolean?)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local f = Story.factsOf(s.profile)
	grantStoryXp(player, f)
	local act, index, step = Story.locate(f)
	local id = if step then step.id else "done"
	local notes = Story.notes(f, StoryDefs.Readables, StoryDefs.CharacterNotes, RECORDINGS)
	local sig = id .. "|" .. #notes
	if onlyIfChanged and lastSig[player] == sig then
		return
	end
	lastSig[player] = sig
	local shown = act or Story.ACTS[#Story.ACTS]
	local journal = Story.fullJournal(f)
	for _, n in notes do
		table.insert(journal, { id = n.id, text = n.text, done = true })
	end
	services.PlayerService.send(player, "story", {
		act = shown.title,
		actId = shown.id,
		stepIndex = index,
		steps = #shown.steps,
		objective = if step then step.objective else shown.doneText,
		journal = journal,
		notes = notes,
		complete = step == nil,
	})
	if lastStep[player] and lastStep[player] ~= id then
		notify(player, "Journal updated: " .. (if step then step.objective else shown.doneText), "info")
	end
	lastStep[player] = id
	if services.NpcService then
		services.NpcService.pushVisibility(player)
	end
end

-- Contract API: re-evaluate after any profile fact changes (discoveries, claims, story states, upgrades).
function StoryService.onFact(player: Player)
	StoryService.push(player, true)
	if services.MissionService and services.MissionService.evaluate then
		services.MissionService.evaluate(player)
	end
end

-- Story hand-ins to Mara Voss, at her board or her figure. Returns true when the interaction was handled.
-- Act I: returning the old tag (a keepsake, not consumed) completes the act. Act II: reporting completes it.
-- `source` "figure" turns the board's notice into Mara's dialogue line.
function StoryService.atBoard(player: Player, source: string?): boolean
	local s = services.PlayerService.get(player)
	if not s then
		return false
	end
	local cur = Story.currentId(Story.factsOf(s.profile))
	if cur == "A1.6" then
		if Inventory.count(s.profile.inventory, "treasure.old_expedition_tag") < 1 then
			if source == "figure" then
				say(player, "N01", "act1_needs_tag")
				return true
			end
			notify(player, 'Mara Voss: "You found the tag? Then bring it here — it should be with you."', "info")
			return false
		end
		s.profile.storyStates["A1.complete"] = "1"
		s.profile.coins += ACT1_REWARD_COINS
		Story.raiseMet(s.profile.charactersMet, "N01", "encountered")
		services.SaveService.markDirty(player)
		services.PlayerService.pushInventory(player)
		say(player, "N01", "act1_return")
		commitThen(player, string.format("Act I complete. +%d coins.", ACT1_REWARD_COINS))
		StoryService.push(player)
		return true
	elseif cur == "A2.7" then
		local coins = Config.Missions.act2CompletionCoins
		s.profile.storyStates["act2.complete"] = "1" -- one-way flag: the reward is paid exactly once
		s.profile.coins += coins
		Story.raiseMet(s.profile.charactersMet, "N01", "understood")
		services.SaveService.markDirty(player)
		services.PlayerService.pushInventory(player)
		say(player, "N01", "act2_report")
		commitThen(player, string.format("Act II complete. +%d coins.", coins))
		StoryService.push(player)
		return true
	end
	return false
end

local function canUse(player: Player, at: Vector3, range: number): any
	local s = services.PlayerService.get(player)
	local pos = services.PlayerService.position(player)
	if not s or not pos or not s.alive or s.vitals.condition == "downed" or (pos - at).Magnitude > range then
		return nil
	end
	local now = os.clock()
	if now - (lastUse[player] or 0) < USE_COOLDOWN then
		return nil
	end
	lastUse[player] = now
	return s
end

-- Readables -------------------------------------------------------------------------------------------

-- Reading shows the text on the dialogue panel, writes the journal and records the discovery (party-shared,
-- F12). Party members who gain the discovery this way also receive the text, so shared knowledge is readable.
function StoryService.read(player: Player, readableId: string)
	local def
	for _, r in WorldDefs.Readables do
		if r.id == readableId then
			def = r
		end
	end
	local text = StoryDefs.Readables[readableId]
	if not def or not text or not canUse(player, v(def.pos), READ_RANGE) then
		return
	end
	local newcomers = {}
	for _, m in services.PartyService.members(player) do
		local ms = services.PlayerService.get(m)
		if m ~= player and ms and not ms.profile.discoveries[readableId] then
			table.insert(newcomers, m)
		end
	end
	show(player, text.title, text.lines, text.journal)
	services.DiscoveryService.discover(player, readableId, text.label)
	for _, m in newcomers do
		local ms = services.PlayerService.get(m)
		if ms and ms.profile.discoveries[readableId] then
			show(m, text.title .. " (shared by " .. player.DisplayName .. ")", text.lines, text.journal, true)
			StoryService.onFact(m)
		end
	end
	StoryService.onFact(player)
end

local function buildReadables()
	for _, r in WorldDefs.Readables do
		local text = StoryDefs.Readables[r.id]
		local chamber = WorldDefs.chamber(r.chamberId)
		if not text or not chamber then
			warn("[StoryService] readable " .. r.id .. " has no text or chamber")
			continue
		end
		local pos = v(r.pos)
		local facing = v(r.facing)
		local cf = CFrame.lookAt(pos, pos + facing)
		local board = Instance.new("Part")
		board.Name = "ReadableBoard_" .. r.id
		board.Anchored = true
		board.CanCollide = false
		board.CanQuery = false
		board.CanTouch = false
		board.Size = Vector3.new(2.4, 2.8, 0.2)
		board.CFrame = cf * CFrame.new(0, 0, 0.15)
		board.Color = Color3.fromRGB(92, 74, 54)
		board.Material = Enum.Material.WoodPlanks
		board.Parent = services.WorldBuilder.folder(chamber.regionId)
		local note = Instance.new("Part")
		note.Name = "Readable_" .. r.id
		note.Anchored = true
		note.CanCollide = false
		note.CanQuery = false
		note.CanTouch = false
		note.Size = Vector3.new(1.6, 2.1, 0.05)
		note.CFrame = cf
		note.Color = Color3.fromRGB(222, 214, 192)
		note.Material = Enum.Material.SmoothPlastic
		note.Parent = board.Parent
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.CanvasSize = Vector2.new(160, 210)
		gui.LightInfluence = 0.6
		gui.Parent = note
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(1, 0.3)
		title.Font = Enum.Font.SpecialElite
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(40, 34, 28)
		title.Text = text.title
		title.Parent = gui
		local body = Instance.new("TextLabel")
		body.BackgroundTransparency = 1
		body.Position = UDim2.fromScale(0.06, 0.32)
		body.Size = UDim2.fromScale(0.88, 0.64)
		body.Font = Enum.Font.SpecialElite
		body.TextScaled = true
		body.TextWrapped = true
		body.TextColor3 = Color3.fromRGB(60, 52, 44)
		body.Text = table.concat(text.lines, " ")
		body.Parent = gui
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Read"
		pp.ObjectText = text.title
		pp.HoldDuration = 0
		pp.MaxActivationDistance = 8
		pp.RequiresLineOfSight = false
		pp.Parent = note
		local id = r.id
		pp.Triggered:Connect(function(player)
			StoryService.read(player, id)
		end)
	end
end

-- Map Room table (Act II step 6) ------------------------------------------------------------------------

function StoryService.compareLogs(player: Player)
	local t = StoryDefs.MapTable
	local s = canUse(player, v(t.pos), t.range)
	if not s then
		return
	end
	local inv = s.profile.inventory
	local result, missing = Story.compareLogs(
		Story.factsOf(s.profile),
		Inventory.count(inv, "evidence.waterworks_log") > 0,
		Inventory.count(inv, "evidence.station_tape") > 0
	)
	local texts = StoryDefs.MapTableText
	if result == "ok" then
		-- Both records stay with the player (protected keepsakes); only the fact is recorded.
		s.profile.storyStates["act2.logs_compared"] = "1"
		Story.raiseMet(s.profile.charactersMet, "N05", "understood")
		services.SaveService.markDirty(player)
		task.spawn(services.SaveService.commit, player)
		show(player, "Map Room table", texts.revelation.lines, texts.revelation.journal)
		StoryService.onFact(player)
	elseif result == "done" then
		show(player, "Map Room table", texts.revelation.lines, nil)
	elseif result == "missing" then
		local lines = table.clone(texts.missing.lines)
		table.insert(lines, "To compare the records you still need " .. table.concat(missing, " and ") .. ".")
		show(player, "Map Room table", lines, nil)
	else
		show(player, "Map Room table", texts.too_early.lines, nil)
	end
end

local function buildMapTable()
	local t = StoryDefs.MapTable
	local chamber = WorldDefs.chamber(t.chamberId)
	if not chamber then
		warn("[StoryService] map table chamber missing")
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "MapTable"
	folder.Parent = services.WorldBuilder.folder(chamber.regionId)
	local base = v(t.pos)
	local wood = Color3.fromRGB(88, 66, 46)
	local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		p.Parent = folder
		return p
	end
	local top = part(
		"TableTop",
		Vector3.new(t.size.x, 0.3, t.size.z),
		CFrame.new(base + Vector3.new(0, t.size.y - 0.15, 0)),
		wood,
		Enum.Material.WoodPlanks
	)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(
				"Leg",
				Vector3.new(0.4, t.size.y - 0.3, 0.4),
				CFrame.new(
					base + Vector3.new(sx * (t.size.x / 2 - 0.4), (t.size.y - 0.3) / 2, sz * (t.size.z / 2 - 0.4))
				),
				wood,
				Enum.Material.Wood
			)
		end
	end
	-- Survey sheets with dates that disagree (fictional).
	local sheet = part(
		"SurveySheets",
		Vector3.new(t.size.x - 0.8, 0.05, t.size.z - 0.8),
		top.CFrame * CFrame.new(0, 0.18, 0),
		Color3.fromRGB(214, 206, 180),
		Enum.Material.SmoothPlastic
	)
	sheet.CanCollide = false
	sheet.CanQuery = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.CanvasSize = Vector2.new(260, 160)
	gui.LightInfluence = 0.6
	gui.Parent = sheet
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SpecialElite
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(60, 52, 44)
	label.Text = "STATION SURVEY — 1898 / 1961 / 1987"
	label.Parent = gui
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Compare the logs"
	pp.ObjectText = "Survey map table"
	pp.HoldDuration = 0.6
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = top
	pp.Triggered:Connect(StoryService.compareLogs)
end

function StoryService.init(s)
	services = s
	Players.PlayerRemoving:Connect(function(p)
		lastSig[p] = nil
		lastStep[p] = nil
		xpGranted[p] = nil
		lastUse[p] = nil
	end)
end

function StoryService.start()
	buildReadables()
	buildMapTable()
	-- Facts change from many systems (discoveries, rescues, upgrades, claims); a light poll keeps them in sync.
	task.spawn(function()
		while true do
			task.wait(3)
			for p in services.PlayerService.all() do
				local ok, err = pcall(function(): any
					StoryService.push(p, true)
					return nil
				end)
				if not ok then
					warn("[StoryService] push failed: " .. tostring(err))
				end
			end
		end
	end)
end

return StoryService
