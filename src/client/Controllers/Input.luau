--!strict
-- Input (section 07, 17): touch first, then keyboard/mouse and gamepad. Sends intents and requests only.
-- Touch layout: landscape, default Roblox left thumbstick for movement, right side for look, separated action
-- buttons (~52 px) clustered above the jump button, inside safe areas.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent.UI)

local Input = {}
local ctx: any
local player = Players.LocalPlayer

local sprintHeld = false
local sprintToggled = false
local crouch = false
local lastSent = { sprint = false, crouch = false }
local ropeStart: Vector3? = nil
local selectedTool = "tool.iron_bar"

local function aim(range: number): RaycastResult?
	local cam = workspace.CurrentCamera
	local world = workspace:FindFirstChild("World")
	if not cam or not world then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { world }
	local ray = cam:ViewportPointToRay(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
	return workspace:Raycast(ray.Origin, ray.Direction * range, params)
end

local function sendIntents()
	local sprint = if ctx.settings.get("sprintToggle") then sprintToggled else sprintHeld
	if sprint ~= lastSent.sprint or crouch ~= lastSent.crouch then
		lastSent.sprint, lastSent.crouch = sprint, crouch
		ctx.send("intents", { sprint = sprint, crouch = crouch })
	end
end

local function setCrouch(v: boolean)
	crouch = v
	local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if h then
		h.CameraOffset = if crouch then Vector3.new(0, -1.6, 0) else Vector3.zero
	end
	sendIntents()
end

local function inv(): { [string]: number }
	local out = {}
	local d = ctx.state.inventory
	if d then
		for _, it in d.items do
			out[it.id] = it.loadout + it.expedition
		end
	end
	return out
end

local function useMedical()
	local have = inv()
	local id = if (have["med.bandage"] or 0) > 0
		then "med.bandage"
		elseif (have["med.cloth_dressing"] or 0) > 0 then "med.cloth_dressing"
		else nil
	if id then
		ctx.send("med.use", { itemId = id })
	else
		ctx.hud.notice("No medical supplies.", "warn")
	end
end

local function useTool()
	local have = inv()
	if (have[selectedTool] or 0) <= 0 then
		local other = if selectedTool == "tool.iron_bar" then "tool.stun_device" else "tool.iron_bar"
		if (have[other] or 0) > 0 then
			selectedTool = other
		else
			ctx.hud.notice("No tool in hand.", "info")
			return
		end
	end
	ctx.send("tool.use", { itemId = selectedTool })
end

local function cycleTool()
	selectedTool = if selectedTool == "tool.iron_bar" then "tool.stun_device" else "tool.iron_bar"
	ctx.hud.notice("Tool: " .. (if selectedTool == "tool.iron_bar" then "Short Iron Bar" else "Stun Device"), "info")
end

local function placeMarker(kind: string)
	local hit = aim(10)
	if not hit then
		ctx.hud.notice("Aim at a nearby wall or floor.", "info")
		return
	end
	if kind == "rope" then
		if not ropeStart then
			ropeStart = hit.Position
			ctx.hud.notice("Rope anchored. Aim at the end point and place again.", "info")
			return
		end
		ctx.send("nav.place", { kind = "rope", content = "guide", position = ropeStart, endPosition = hit.Position })
		ropeStart = nil
		return
	end
	local content = if kind == "sign"
		then (ctx.state.signPreset or "to_shelter")
		else (ctx.state.chalkPreset or "arrow")
	ctx.send("nav.place", { kind = kind, content = content, position = hit.Position })
end

-- Nearest downed party member within reach for stabilize / carry.
local function nearestDowned(): Player?
	local party = ctx.state.party
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not party or not root then
		return nil
	end
	for _, m in party.members do
		if m.condition == "downed" and m.userId ~= player.UserId then
			local p = Players:GetPlayerByUserId(m.userId)
			local r = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r and (r.Position - root.Position).Magnitude < 8 then
				return p
			end
		end
	end
	return nil
end

local function rescueAction()
	local vs = ctx.state.vitals
	if vs and vs.carrying then
		ctx.send("rescue.drop")
		return
	end
	local p = nearestDowned()
	if not p then
		ctx.hud.notice("No downed party member within reach.", "info")
		return
	end
	-- First press stabilizes (a held action); press again once stabilized to carry them.
	local target = p
	local downedStabilized = false
	for _, m in ctx.state.party.members do
		if m.userId == target.UserId then
			downedStabilized = m.stabilized == true
		end
	end
	if downedStabilized then
		ctx.send("rescue.carry", { targetUserId = target.UserId })
	else
		ctx.send("rescue.stabilize", { targetUserId = target.UserId })
	end
end

local KEYMAP: { [Enum.KeyCode]: () -> () } = {
	[Enum.KeyCode.F] = function()
		ctx.send("light.toggle")
	end,
	[Enum.KeyCode.R] = function()
		ctx.send("light.swap")
	end,
	[Enum.KeyCode.H] = useMedical,
	[Enum.KeyCode.G] = function()
		placeMarker("chalk")
	end,
	[Enum.KeyCode.T] = function()
		placeMarker("sign")
	end,
	[Enum.KeyCode.Y] = function()
		placeMarker("rope")
	end,
	[Enum.KeyCode.Z] = function()
		ctx.send("party.ping")
	end,
	[Enum.KeyCode.B] = function()
		ctx.send("throw")
	end,
	[Enum.KeyCode.X] = rescueAction,
	[Enum.KeyCode.Q] = cycleTool,
	[Enum.KeyCode.Tab] = function()
		ctx.panels.toggle("notebook")
	end,
	[Enum.KeyCode.I] = function()
		ctx.panels.toggle("inventory")
	end,
	[Enum.KeyCode.P] = function()
		ctx.panels.toggle("party")
	end,
	[Enum.KeyCode.O] = function()
		ctx.panels.toggle("settings")
	end,
	[Enum.KeyCode.C] = function()
		setCrouch(not crouch)
	end,
	[Enum.KeyCode.ButtonL3] = function()
		setCrouch(not crouch)
	end,
	[Enum.KeyCode.ButtonY] = function()
		ctx.send("light.toggle")
	end,
	[Enum.KeyCode.ButtonX] = useMedical,
}

local function buildTouch()
	local frame = UI.frame(ctx.gui, {
		Name = "TouchActions",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -150), -- above the default jump button
		Size = UDim2.fromOffset(UI.TOUCH * 3 + 16, UI.TOUCH * 4 + 24), -- 3 columns x 4 rows,
		BackgroundTransparency = 1,
	})
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(UI.TOUCH, UI.TOUCH)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Right
	grid.VerticalAlignment = Enum.VerticalAlignment.Bottom
	grid.Parent = frame
	local function btn(text: string, onDown: () -> (), onUp: (() -> ())?)
		local b = Instance.new("TextButton")
		b.Text = text
		b.Font = UI.font()
		b.TextSize = 13
		b.TextWrapped = true
		b.TextColor3 = UI.Colors.bone
		b.BackgroundColor3 = UI.Colors.charcoal
		b.BackgroundTransparency = 0.25
		UI.corner(b, 26)
		b.Parent = frame
		b.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				onDown()
			end
		end)
		if onUp then
			b.InputEnded:Connect(function(io)
				if
					io.UserInputType == Enum.UserInputType.Touch
					or io.UserInputType == Enum.UserInputType.MouseButton1
				then
					onUp()
				end
			end)
		end
		return b
	end
	btn("Menu", function()
		ctx.panels.toggle("menu")
	end)
	btn("Med", useMedical)
	btn("Mark", function()
		placeMarker("chalk")
	end)
	btn("Light", function()
		ctx.send("light.toggle")
	end)
	btn("Use", useTool)
	btn("Help", rescueAction)
	btn("Crouch", function()
		setCrouch(not crouch)
	end)
	btn("Sprint", function()
		if ctx.settings.get("sprintToggle") then
			sprintToggled = not sprintToggled
		else
			sprintHeld = true
		end
		sendIntents()
	end, function()
		if not ctx.settings.get("sprintToggle") then
			sprintHeld = false
			sendIntents()
		end
	end)
	btn("Cell", function()
		ctx.send("light.swap")
	end)
	btn("Throw", function()
		ctx.send("throw")
	end)
	frame.Visible = UserInputService.TouchEnabled
	UserInputService.LastInputTypeChanged:Connect(function(t)
		frame.Visible = t == Enum.UserInputType.Touch
			or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
	end)
end

function Input.init(c)
	ctx = c
	UserInputService.InputBegan:Connect(function(io, processed)
		if processed then
			return
		end
		if io.KeyCode == Enum.KeyCode.LeftShift then
			if ctx.settings.get("sprintToggle") then
				sprintToggled = not sprintToggled
			else
				sprintHeld = true
			end
			sendIntents()
			return
		end
		if io.KeyCode == Enum.KeyCode.ButtonL2 then
			sprintHeld = true
			sendIntents()
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.KeyCode == Enum.KeyCode.ButtonR2 then
			useTool()
			return
		end
		local f = KEYMAP[io.KeyCode]
		if f then
			f()
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if
			(io.KeyCode == Enum.KeyCode.LeftShift or io.KeyCode == Enum.KeyCode.ButtonL2)
			and not ctx.settings.get("sprintToggle")
		then
			sprintHeld = false
			sendIntents()
		end
	end)
	buildTouch()
	player.CharacterAdded:Connect(function()
		setCrouch(false)
		ropeStart = nil
	end)
	-- Camera comfort settings
	local function applyCamera()
		local cam = workspace.CurrentCamera
		if cam then
			cam.FieldOfView = ctx.settings.get("fieldOfView")
		end
		UserInputService.MouseDeltaSensitivity = ctx.settings.get("sensitivity")
	end
	ctx.settings.onChanged(applyCamera)
	applyCamera()
end

Input.aim = aim

return Input
