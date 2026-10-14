--!strict
-- Private creature visuals (sections 10, 11: "private cosmetic"). Renders, on this client only:
--   * the C01 Sidelooker figure for its one watcher ("sidelooker" channel);
--   * the C03 Wick Moth swarm: a few pale flecks around the local player's light ("moth" channel). Density and
--     motion are reduced with the reduceFlashes setting;
--   * the C04 Chalk Hand's false mark: a fresh reversed chalk arrow beside your own mark, a thin hand withdrawing into
--     a crack, and an Inspect prompt ("falseMark" channel). Inspecting shows "This mark is not in your notebook." and
--     offers "Compare with my own mark"; both only send requests (chalkhand.inspect / chalkhand.compare);
--   * the notebook's research entries after a rejoin ("researchAll" channel, no notice per creature).
-- Nothing here authors damage, pickups, records or any economic outcome; every part is CanQuery=false so it never
-- interferes with aiming or placement rays.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.Parent.Controllers.UI)

local CreatureFX = {}
local ctx: any
local player = Players.LocalPlayer
local folder: Folder

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Parent = folder
	return p
end

local function head(): BasePart?
	local c = player.Character
	local h = c and c:FindFirstChild("Head")
	return if h and h:IsA("BasePart") then h else nil
end

local function fadeOut(inst: Instance, seconds: number)
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, TweenInfo.new(seconds), { Transparency = 1 }):Play()
		end
	end
	if inst:IsA("BasePart") then
		TweenService:Create(inst, TweenInfo.new(seconds), { Transparency = 1 }):Play()
	end
	task.delay(seconds + 0.05, function()
		inst:Destroy()
	end)
end

-- C01 Sidelooker -------------------------------------------------------------------------------------
local figures: { [number]: Model } = {}

local function buildFigure(base: Vector3, lookAt: Vector3): Model
	local m = Instance.new("Model")
	m.Name = "Sidelooker"
	local centre = base + Vector3.new(0, 4.25, 0)
	local flat = Vector3.new(lookAt.X - centre.X, 0, lookAt.Z - centre.Z)
	local cf = if flat.Magnitude > 0.1 then CFrame.lookAt(centre, centre + flat.Unit) else CFrame.new(centre)
	local body = part("Body", Vector3.new(1.2, 8.5, 0.8), cf, Color3.fromRGB(58, 56, 52), Enum.Material.Slate)
	body.Parent = m
	local face = part(
		"Face",
		Vector3.new(0.9, 1.1, 0.4),
		cf * CFrame.new(0.15, 3.6, -0.45) * CFrame.Angles(0, math.rad(25), 0),
		Color3.fromRGB(96, 92, 86),
		Enum.Material.Slate
	)
	face.Parent = m
	m.PrimaryPart = body
	m.Parent = folder
	return m
end

local function onSidelooker(d: any)
	if type(d) ~= "table" or type(d.id) ~= "number" then
		return
	end
	if typeof(d.position) == "Vector3" then
		local old = figures[d.id]
		if old then
			old:Destroy()
		end
		local lookAt = if typeof(d.lookAt) == "Vector3" then d.lookAt else d.position
		figures[d.id] = buildFigure(d.position, lookAt)
		return
	end
	local m = figures[d.id]
	if not m then
		return
	end
	figures[d.id] = nil
	if typeof(d.away) == "Vector3" and m.PrimaryPart then
		-- slides back out of view, then is gone
		local from = m:GetPivot()
		local to = from + (d.away - (from.Position - Vector3.new(0, 4.25, 0)))
		local t = 0
		local conn: RBXScriptConnection? = nil
		conn = RunService.RenderStepped:Connect(function(dt)
			t += dt
			if not m.Parent then
				if conn then
					conn:Disconnect()
				end
				return
			end
			m:PivotTo(from:Lerp(to, math.min(1, t / 0.25)))
			if t >= 0.25 then
				if conn then
					conn:Disconnect()
				end
				m:Destroy()
			end
		end)
	else
		m:Destroy()
	end
end

-- C03 Wick Moth swarm ----------------------------------------------------------------------------------
local FLECKS_FULL = 7
local FLECKS_REDUCED = 3
local flecks: { Part } = {}
local swarmState = "clear"
local swarmSince = 0

local function clearFlecks(scatter: boolean)
	for _, f in flecks do
		if scatter then
			local away = f.Position + Vector3.new(math.random() - 0.5, math.random() * 0.8, math.random() - 0.5) * 6
			TweenService:Create(f, TweenInfo.new(0.6), { Position = away, Transparency = 1 }):Play()
			task.delay(0.65, function()
				f:Destroy()
			end)
		else
			f:Destroy()
		end
	end
	table.clear(flecks)
end

local function ensureFlecks()
	local want = if ctx.settings.get("reduceFlashes") then FLECKS_REDUCED else FLECKS_FULL
	while #flecks > want do
		local f = table.remove(flecks) :: Part
		f:Destroy()
	end
	local h = head()
	local at = if h then h.Position else Vector3.zero
	while #flecks < want do
		local f = part(
			"MothFleck",
			Vector3.new(0.28, 0.04, 0.2),
			CFrame.new(at + Vector3.new(math.random() - 0.5, math.random(), math.random() - 0.5) * 6),
			Color3.fromRGB(226, 220, 204),
			Enum.Material.SmoothPlastic
		)
		table.insert(flecks, f)
	end
end

local function onMoth(d: any)
	local state = if type(d) == "table" and type(d.state) == "string" then d.state else "clear"
	if state == "flutter" or state == "attached" then
		if swarmState == "clear" then
			swarmSince = os.clock()
		end
		swarmState = state
		ensureFlecks()
	else
		swarmState = "clear"
		clearFlecks(true)
	end
end

local function stepSwarm()
	if swarmState == "clear" or #flecks == 0 then
		return
	end
	local h = head()
	if not h then
		return
	end
	ensureFlecks()
	local reduced = ctx.settings.get("reduceFlashes") == true
	local t = os.clock()
	-- gather in front of the light over the flutter warning, then cling
	local gather = math.clamp((t - swarmSince) / 1.5, 0, 1)
	local centre = h.Position + h.CFrame.LookVector * 1.8 + Vector3.new(0, 0.3, 0)
	local speed = if reduced then 0.8 else 2.2
	for i, f in flecks do
		local a = t * speed + i * 2.39
		local r = 0.7 + 0.35 * math.sin(t * 1.3 + i)
		local spread = 1 + (1 - gather) * 4
		local offset = Vector3.new(math.cos(a) * r, math.sin(a * 1.7) * 0.35, math.sin(a) * r) * spread
		f.CFrame = CFrame.new(centre + offset) * CFrame.Angles(0, a, math.sin(a * 3) * 0.6)
		f.Transparency = if reduced then 0.2 else 0.1 + 0.25 * (0.5 + 0.5 * math.sin(t * 9 + i))
	end
end

-- C04 Chalk Hand false marks ---------------------------------------------------------------------------
local marks: { [string]: Model } = {}
local inspectPanel: Frame? = nil

local function closePanel()
	if inspectPanel then
		inspectPanel:Destroy()
		inspectPanel = nil
	end
end

local function showInspect(id: string)
	closePanel()
	local f = UI.frame(ctx.gui, {
		Name = "FalseMarkInspect",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -160),
		Size = UDim2.new(0.8, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(420, 400)
	cons.Parent = f
	UI.corner(f, 8)
	UI.pad(f, 10)
	UI.list(f, 8)
	local t = UI.label(f, "This mark is not in your notebook.", 17)
	t.TextXAlignment = Enum.TextXAlignment.Center
	UI.button(f, "Compare with my own mark", function()
		ctx.send("chalkhand.compare", { id = id })
		closePanel()
	end, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	UI.button(f, "Close", closePanel, { Size = UDim2.new(1, 0, 0, UI.TOUCH) })
	inspectPanel = f
	task.delay(20, function()
		if inspectPanel == f then
			closePanel()
		end
	end)
end

local function buildHand(at: Vector3, n: Vector3, up: Vector3): Model
	local m = Instance.new("Model")
	m.Name = "ChalkHand"
	local right = n:Cross(up)
	if right.Magnitude < 0.01 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local crackPos = at + right * 1.6
	local crack = part(
		"Crack",
		Vector3.new(0.12, 2.2, 0.06),
		CFrame.lookAt(crackPos + n * 0.02, crackPos + n),
		Color3.fromRGB(20, 18, 16),
		Enum.Material.Slate
	)
	crack.Parent = m
	for i = -2, 1 do
		local fingerPos = crackPos + up * (i * 0.32) + n * 0.25 - right * 0.35
		local finger = part(
			"Finger",
			Vector3.new(0.9, 0.08, 0.08),
			CFrame.lookAt(fingerPos, fingerPos + right),
			Color3.fromRGB(60, 56, 52),
			Enum.Material.SmoothPlastic
		)
		finger.Parent = m
		-- the thin hand withdraws into the crack
		TweenService:Create(
			finger,
			TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ CFrame = CFrame.lookAt(crackPos - n * 0.3, crackPos - n * 0.3 + right), Transparency = 1 }
		):Play()
	end
	m.Parent = folder
	task.delay(6, function()
		fadeOut(crack, 1.5)
	end)
	task.delay(8, function()
		m:Destroy()
	end)
	return m
end

local function onFalseMark(d: any)
	if type(d) ~= "table" or type(d.id) ~= "string" then
		return
	end
	local id: string = d.id
	if typeof(d.position) ~= "Vector3" or typeof(d.normal) ~= "Vector3" then
		return
	end
	local old = marks[id]
	if old then
		old:Destroy()
	end
	local pos: Vector3 = d.position
	local n: Vector3 = (d.normal :: Vector3).Unit
	local m = Instance.new("Model")
	m.Name = "FalseMark_" .. id
	local p = part(
		"Mark",
		Vector3.new(1.6, 1.6, 0.05),
		CFrame.lookAt(pos + n * 0.03, pos + n),
		Color3.new(1, 1, 1),
		Enum.Material.SmoothPlastic
	)
	p.Transparency = 1
	p.Parent = m
	m.PrimaryPart = p
	-- the same chalk look as a real mark (WorldRenderer), but fresh and reversed
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.LightInfluence = 0.7
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = Enum.Font.PermanentMarker
	t.TextColor3 = Color3.fromRGB(246, 245, 240)
	t.Text = if d.content == "arrow" then "➜" else "?"
	t.Rotation = if d.reversed then 180 else 0
	t.Parent = g
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Inspect"
	pp.ObjectText = "Chalk mark"
	pp.HoldDuration = 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = p
	pp.Triggered:Connect(function()
		ctx.send("chalkhand.inspect", { id = id })
		showInspect(id)
	end)
	m.Parent = folder
	marks[id] = m
	local up = if math.abs(n.Y) > 0.7 then Vector3.zAxis else Vector3.yAxis
	buildHand(pos, n, up)
	local ttl = if type(d.ttl) == "number" then math.clamp(d.ttl, 1, 300) else 90
	task.delay(ttl, function()
		if marks[id] == m then
			marks[id] = nil
			m:Destroy()
		end
	end)
end

-- Notebook after a rejoin ---------------------------------------------------------------------------------
local function onResearchAll(d: any)
	if type(d) ~= "table" or type(d.entries) ~= "table" then
		return
	end
	local panels = ctx.panels
	if not panels or not panels.research then
		return
	end
	for _, e in d.entries do
		if type(e) == "table" and type(e.id) == "string" then
			panels.research(e)
		end
	end
end

function CreatureFX.init(c: any)
	ctx = c
	folder = Instance.new("Folder")
	folder.Name = "CreatureFX"
	folder.Parent = workspace
	ctx.on("sidelooker", onSidelooker)
	ctx.on("moth", onMoth)
	ctx.on("falseMark", onFalseMark)
	ctx.on("researchAll", onResearchAll)
	RunService.RenderStepped:Connect(stepSwarm)
	player.CharacterAdded:Connect(function()
		-- a new character: nothing private survives a respawn
		swarmState = "clear"
		clearFlecks(false)
		closePanel()
	end)
end

return CreatureFX
