--!strict
-- Input (section 07, 17): touch first, then keyboard/mouse and gamepad. Sends intents and requests only.
-- Touch layout: landscape, default Roblox left thumbstick for movement, right side for look, separated action
-- buttons (48-52 px) clustered just above the default jump button, whose size and place depend on the screen size
-- (UIRules.touchGrid), inside safe areas.
-- Milestone 3 bindings (docs/MILESTONE-3.md 4.7): lantern shield V / ButtonL1 / touch "Shield"; place a flare
-- N / ButtonR1 / touch "Flare"; character and field experience K. Gamepad also gains Menu (DPadUp), medical
-- (DPadDown, moved off ButtonX, the default ProximityPrompt key), swap cell (DPadLeft), throw (DPadRight),
-- rescue (ButtonB) and party ping (ButtonR3); touch gains "Ping" (the verified party ping).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent.UI)
local UIRules = require(script.Parent.UIRules)

local Input = {}
local ctx: any
local player = Players.LocalPlayer

local sprintHeld = false
local sprintToggled = false
local crouch = false
local lastSent = { sprint = false, crouch = false }
local ropeStart: Vector3? = nil
local selectedTool = "tool.iron_bar"
-- Only hand weapons cycle as the "Use" tool; flares, fuse kits and the repair roll have their own actions.
local WEAPONS = { "tool.iron_bar", "tool.stun_device" }
local WEAPON_NAMES: { [string]: string } =
	{ ["tool.iron_bar"] = "Short Iron Bar", ["tool.stun_device"] = "Stun Device" }
local sprintTouch: InputObject? = nil -- the touch that holds Sprint (released wherever that finger lifts)
local touchButtons: { TextButton } = {}
local flareButton: TextButton? = nil
local shieldButton: TextButton? = nil

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

-- Picks the medical item that fits the need (the server re-checks everything and never wastes an item):
-- an injury on a mostly full health bar wants the splint (it removes the injury), otherwise the biggest heal.
local function pickMedical(have: { [string]: number }, v: any): string?
	local injured = v ~= nil and v.injured == true
	local mostlyHealthy = v ~= nil and type(v.maxHealth) == "number" and v.health >= v.maxHealth * 0.7
	local order: { string } = if injured and mostlyHealthy
		then { "med.splint", "med.bandage", "med.cloth_dressing" }
		elseif injured then { "med.bandage", "med.splint", "med.cloth_dressing" }
		else { "med.bandage", "med.cloth_dressing", "med.splint" }
	for _, id in order do
		if (have[id] or 0) > 0 then
			return id
		end
	end
	return nil
end

local function useMedical()
	local v = ctx.state.vitals
	if v and not v.injured and v.health >= v.maxHealth and v.condition ~= "downed" then
		ctx.hud.notice("You are not hurt.", "info")
		return
	end
	local id = pickMedical(inv(), v)
	if id then
		ctx.send("med.use", { itemId = id })
	else
		ctx.hud.notice("No medical supplies.", "warn")
	end
end

local function useTool()
	local have = inv()
	if (have[selectedTool] or 0) <= 0 then
		local found = nil
		for _, id in WEAPONS do
			if (have[id] or 0) > 0 then
				found = id
				break
			end
		end
		if not found then
			ctx.hud.notice("No tool in hand.", "info")
			return
		end
		selectedTool = found
	end
	ctx.send("tool.use", { itemId = selectedTool })
end

local function cycleTool()
	local i = table.find(WEAPONS, selectedTool) or 0
	selectedTool = WEAPONS[i % #WEAPONS + 1]
	ctx.hud.notice("Tool: " .. (WEAPON_NAMES[selectedTool] or selectedTool), "info")
end

local function shieldLantern()
	ctx.send("light.shield")
end

local function placeFlare()
	if (inv()["tool.flare"] or 0) <= 0 then
		ctx.hud.notice("You have no flares.", "info")
		return
	end
	ctx.send("flare.place")
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
	[Enum.KeyCode.V] = shieldLantern,
	[Enum.KeyCode.N] = placeFlare,
	[Enum.KeyCode.K] = function()
		ctx.panels.toggle("character")
	end,
	[Enum.KeyCode.ButtonL3] = function()
		setCrouch(not crouch)
	end,
	[Enum.KeyCode.ButtonY] = function()
		ctx.send("light.toggle")
	end,
	[Enum.KeyCode.ButtonL1] = shieldLantern,
	[Enum.KeyCode.ButtonR1] = placeFlare,
	[Enum.KeyCode.ButtonB] = rescueAction,
	[Enum.KeyCode.ButtonR3] = function()
		ctx.send("party.ping")
	end,
	[Enum.KeyCode.DPadUp] = function()
		ctx.panels.toggle("menu")
	end,
	[Enum.KeyCode.DPadDown] = useMedical,
	[Enum.KeyCode.DPadLeft] = function()
		ctx.send("light.swap")
	end,
	[Enum.KeyCode.DPadRight] = function()
		ctx.send("throw")
	end,
}

local function refreshTouchLabels()
	local fb = flareButton
	if fb then
		local n = inv()["tool.flare"] or 0
		fb.Text = if n > 0 then string.format("Flare %d", n) else "Flare"
		fb.TextTransparency = if n > 0 then 0 else 0.45
	end
	local sb = shieldButton
	if sb then
		local v = ctx.state.vitals
		local lantern = v ~= nil and v.isLantern == true
		sb.Text = if lantern and v.shielded then "Open" else "Shield"
		sb.TextTransparency = if lantern then 0 else 0.45
	end
end

local function releaseTouchSprint()
	sprintTouch = nil
	if not ctx.settings.get("sprintToggle") then
		sprintHeld = false
		sendIntents()
	end
end

-- Touch grid: 5 columns x 3 rows (13 used), filled from the bottom-right corner so the most used actions (Sprint,
-- Crouch, Use, Med, Light) sit nearest the thumb. It sits just above the default jump button, which is 70 px on
-- phones and 120 px and higher up on tablets, so the offset follows the screen size. At 52 px it fits a 390-px-tall
-- phone; cells shrink only on shorter screens and never below 48 px (UIRules.touchGrid). It stays on the right side:
-- the left thumbstick zone is never covered, and the HUD strips and popups keep clear of it (UI.setTouchReserve).
-- PROPOSED (D79 revised from 4 x 4), to be checked on real phones (T21).
local function buildTouch()
	local frame = UI.frame(ctx.gui, {
		Name = "TouchActions",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
	})
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.StartCorner = Enum.StartCorner.BottomRight
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Right
	grid.VerticalAlignment = Enum.VerticalAlignment.Bottom
	grid.Parent = frame
	-- Size and place the grid for the current screen; tell the HUD how much of the right edge it takes.
	local function place()
		local s = ctx.gui.AbsoluteSize
		local cam = workspace.CurrentCamera
		local view = if cam then cam.ViewportSize else s
		local g = UIRules.touchGrid(s.X, s.Y, view.X, view.Y)
		frame.Position = UDim2.new(1, -g.right, 1, -g.bottom)
		frame.Size = UDim2.fromOffset(g.width, g.height)
		grid.CellSize = UDim2.fromOffset(g.cell, g.cell)
		grid.CellPadding = UDim2.fromOffset(g.gap, g.gap)
		UI.setTouchReserve(if frame.Visible then g.reserve else 0)
	end
	local order = 0
	local function btn(text: string, onDown: (InputObject) -> (), onUp: (() -> ())?): TextButton
		local b = Instance.new("TextButton")
		order += 1
		b.LayoutOrder = order
		b.Text = text
		b.Font = UI.font()
		b.TextSize = math.floor(13 * UI.TextScale)
		b.TextWrapped = true
		b.TextColor3 = UI.Colors.bone
		b.BackgroundColor3 = UI.Colors.charcoal
		b.BackgroundTransparency = 0.25
		UI.corner(b, 26)
		b.Parent = frame
		b.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				onDown(io)
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
		table.insert(touchButtons, b)
		return b
	end
	-- bottom row, right to left: Sprint, Crouch, Use, Med, Light
	btn("Sprint", function(io)
		if ctx.settings.get("sprintToggle") then
			sprintToggled = not sprintToggled
		else
			sprintHeld = true
			sprintTouch = io
		end
		sendIntents()
	end, function()
		if sprintHeld then
			releaseTouchSprint()
		end
	end)
	btn("Crouch", function()
		setCrouch(not crouch)
	end)
	btn("Use", function()
		useTool()
	end)
	btn("Med", function()
		useMedical()
	end)
	btn("Light", function()
		ctx.send("light.toggle")
	end)
	-- second row: Cell, Throw, Mark, Flare, Shield
	btn("Cell", function()
		ctx.send("light.swap")
	end)
	btn("Throw", function()
		ctx.send("throw")
	end)
	btn("Mark", function()
		placeMarker("chalk")
	end)
	flareButton = btn("Flare", function()
		placeFlare()
	end)
	shieldButton = btn("Shield", function()
		shieldLantern()
	end)
	-- top row: Help, Ping, Menu
	btn("Help", function()
		rescueAction()
	end)
	btn("Ping", function()
		ctx.send("party.ping")
	end)
	btn("Menu", function()
		ctx.panels.toggle("menu")
	end)
	refreshTouchLabels()
	ctx.on("inventory", refreshTouchLabels)
	ctx.on("vitals", refreshTouchLabels)
	ctx.settings.onChanged(function(k, v)
		if k == "textScale" then
			for _, b in touchButtons do
				b.TextSize = math.floor(13 * v)
			end
		end
	end)
	frame.Visible = UserInputService.TouchEnabled
	place()
	UserInputService.LastInputTypeChanged:Connect(function(t)
		frame.Visible = t == Enum.UserInputType.Touch
			or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
		place()
	end)
	ctx.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
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
		elseif sprintTouch ~= nil and (io :: any) == sprintTouch then
			-- the finger holding touch Sprint lifted somewhere else on the screen: release, never stick
			releaseTouchSprint()
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
