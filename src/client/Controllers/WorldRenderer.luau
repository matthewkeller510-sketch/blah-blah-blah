--!strict
-- Private rendering of navigation markers and recovery bags (sections 15, 16). The server only sends records the
-- viewer may see; this client instantiates nearby ones and rebuilds them from records after stream-out/in.
-- Pick-up prompts send requests; the server validates range, ownership and party permission.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local UI = require(script.Parent.UI)

local WorldRenderer = {}
local ctx: any
local folder: Folder
local navRecords: { any } = {}
local bagRecords: { any } = {}
local built: { [string]: Instance } = {}

local SYMBOL = {
	arrow = "➜",
	danger = "⚠",
	shelter = "⌂",
	exit = "⇧",
	water = "≈",
	x = "✕",
	route_a = "A",
	route_b = "B",
	route_c = "C",
	to_shelter = "→ SHELTER",
	to_exit = "→ EXIT",
	danger_ahead = "DANGER AHEAD",
	water_crossing = "WATER",
	dead_end = "DEAD END",
	rescue_here = "RESCUE HERE",
}

local function textOn(part: BasePart, face: Enum.NormalId, text: string, color: Color3, font: Enum.Font)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.LightInfluence = 0.7
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.Parent = part
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = font
	t.TextColor3 = color
	t.Text = text
	t.Parent = g
end

-- A CFrame at `pos` facing `dir`. A floor or ceiling mark faces straight up or down, where the default up vector
-- is parallel to the look direction, so another up vector is used there.
local function facingCF(pos: Vector3, dir: Vector3): CFrame
	if dir.Magnitude < 1e-4 then
		dir = Vector3.yAxis
	end
	local up = if math.abs(dir.Unit.Y) > 0.99 then Vector3.zAxis else Vector3.yAxis
	return CFrame.lookAt(pos, pos + dir, up)
end

-- Small label on a marker or bag that a pocket change moved (section 04: show the recovery location honestly).
local function movedLabel(parent: BasePart, offset: number)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Moved"
	bb.Size = UDim2.fromOffset(200, 22)
	bb.StudsOffset = Vector3.new(0, offset, 0)
	bb.MaxDistance = 30
	bb.AlwaysOnTop = false
	bb.Parent = parent
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = UI.font()
	t.TextScaled = true
	t.TextColor3 = UI.Colors.bone
	t.Text = "moved: the passage changed"
	t.Parent = bb
end

local function pickupPrompt(parent: Instance, text: string, onTrigger: () -> ())
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = text
	pp.HoldDuration = 0.5
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Style = Enum.ProximityPromptStyle.Default
	pp.Parent = parent
	pp.Triggered:Connect(onTrigger)
end

local function buildNav(rec: any): Instance
	local m = Instance.new("Model")
	m.Name = "Nav_" .. rec.recordId
	local pos: Vector3 = rec.position
	local n: Vector3 = rec.facing
	if rec.kind == "chalk" then
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery = true, false, true
		p.Transparency = 1
		p.Size = Vector3.new(1.6, 1.6, 0.05)
		p.CFrame = facingCF(pos + n * 0.03, n)
		textOn(
			p,
			Enum.NormalId.Front,
			SYMBOL[rec.content] or "?",
			Color3.fromRGB(238, 236, 228),
			Enum.Font.PermanentMarker
		)
		p.Parent = m
		m.PrimaryPart = p
	elseif rec.kind == "sign" then
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery = true, false, true
		p.Size = Vector3.new(3, 0.9, 0.15)
		p.Color = Color3.fromRGB(120, 90, 55)
		p.Material = Enum.Material.WoodPlanks
		p.CFrame = facingCF(pos + n * 0.1 + Vector3.new(0, 1.5, 0), n)
		textOn(
			p,
			Enum.NormalId.Front,
			SYMBOL[rec.content] or "?",
			Color3.fromRGB(245, 235, 210),
			Enum.Font.SpecialElite
		)
		p.Parent = m
		m.PrimaryPart = p
	else
		local a, b = pos, rec.endPosition or pos
		local len = math.max(0.5, (b - a).Magnitude)
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery = true, false, true
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(len, 0.18, 0.18)
		p.Color = Color3.fromRGB(205, 180, 120)
		p.Material = Enum.Material.Fabric
		p.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
		p.Parent = m
		for _, endPos in { a, b } do
			local e = Instance.new("Part")
			e.Anchored, e.CanCollide = true, false
			e.Size = Vector3.new(0.5, 0.5, 0.5)
			e.Color = Color3.fromRGB(150, 150, 150)
			e.Material = Enum.Material.Metal
			e.Position = endPos
			e.Parent = m
		end
		m.PrimaryPart = p
	end
	if rec.isOwn or rec.allowPartyRecovery then
		pickupPrompt(m.PrimaryPart :: BasePart, "Pick up " .. rec.kind, function()
			ctx.send("nav.retrieve", { ownerId = rec.ownerId, recordId = rec.recordId })
		end)
	end
	if rec.migratedFrom then
		movedLabel(m.PrimaryPart :: BasePart, 1.6)
	end
	m.Parent = folder
	return m
end

local function buildBag(rec: any): Instance
	local p = Instance.new("Part")
	p.Name = "Bag_" .. rec.kind .. "_" .. rec.ownerId
	p.Anchored, p.CanCollide = true, false
	p.Size = Vector3.new(2, 1.4, 1.4)
	p.Color = if rec.kind == "death" then Color3.fromRGB(90, 40, 34) else Color3.fromRGB(80, 78, 60)
	p.Material = Enum.Material.Fabric
	p.Position = rec.position
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(200, 40)
	bb.StudsOffset = Vector3.new(0, 2, 0)
	bb.MaxDistance = 40
	bb.AlwaysOnTop = false
	bb.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = UI.font()
	t.TextScaled = true
	t.TextColor3 = UI.Colors.bone
	t.Text = (if rec.isOwn then "Your " else "Party member's ")
		.. (if rec.kind == "death" then "death bag" else "departure bag")
		.. " ("
		.. rec.count
		.. ")"
	t.Parent = bb
	pickupPrompt(p, if rec.isOwn then "Recover" else "Recover to their escrow", function()
		ctx.send("bag.recover", { ownerId = rec.ownerId, kind = rec.kind })
	end)
	if rec.moved then
		movedLabel(p, 3)
	end
	p.Parent = folder
	return p
end

-- Everything that changes how a record looks is in its key, so a moved or re-versioned record rebuilds at once
-- instead of lingering where it was (pocket migration).
local function key(rec: any, isBag: boolean): string
	if isBag then
		return "bag:" .. rec.ownerId .. ":" .. rec.kind .. ":" .. tostring(rec.position) .. ":" .. tostring(rec.moved)
	end
	local moved = rec.migratedFrom
	return table.concat({
		"nav",
		rec.recordId,
		tostring(rec.allowPartyRecovery),
		tostring(rec.position),
		tostring(rec.facing),
		tostring(rec.endPosition),
		tostring(rec.pocketId),
		tostring(rec.pocketVersion),
		if moved then tostring(moved.pocketId) .. "/" .. tostring(moved.version) else "-",
	}, ":")
end

local function refresh()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local here = cam.CFrame.Position
	local want: { [string]: any } = {}
	local radius = Config.Navigation.renderRadius
	for _, r in navRecords do
		if (r.position - here).Magnitude < radius then
			want[key(r, false)] = { r, false }
		end
	end
	for _, r in bagRecords do
		want[key(r, true)] = { r, true } -- bags are few; always shown to their authorized viewers
	end
	for k, inst in built do
		if not want[k] then
			inst:Destroy()
			built[k] = nil
		end
	end
	for k, pair in want do
		if not built[k] then
			built[k] = if pair[2] then buildBag(pair[1]) else buildNav(pair[1])
		end
	end
end

function WorldRenderer.init(c)
	ctx = c
	folder = Instance.new("Folder")
	folder.Name = "PrivateMarkers"
	folder.Parent = workspace
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc > 0.5 then
			acc = 0
			refresh()
		end
	end)
end

function WorldRenderer.nav(list)
	navRecords = list
	refresh()
end

function WorldRenderer.bags(list)
	bagRecords = list
	refresh()
end

-- Verified party ping: authored by the server with the real party identity; mimics cannot forge it.
function WorldRenderer.ping(d: any)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.Transparency = true, false, 1
	p.Size = Vector3.one
	p.Position = d.position + Vector3.new(0, 3, 0)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(180, 36)
	bb.AlwaysOnTop = true
	bb.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = UI.Colors.charcoal
	t.BackgroundTransparency = 0.3
	t.Font = UI.font()
	t.TextScaled = true
	t.TextColor3 = UI.Colors.teal
	t.Text = "✔ " .. d.name .. " (party)"
	t.Parent = bb
	p.Parent = folder
	task.delay(6, function()
		p:Destroy()
	end)
	if d.userId ~= Players.LocalPlayer.UserId then
		ctx.hud.notice("Verified ping from " .. d.name, "info")
	end
end

return WorldRenderer
