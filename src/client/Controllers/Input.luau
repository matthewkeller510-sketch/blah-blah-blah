--!strict
-- Input (section 07, 17): touch first, then keyboard/mouse and gamepad. Sends intents and requests only.
-- On-screen controls (D108, owner request; geometry in UIRules.hudLayout): consumables as an icon column on the
-- left (shown on every device, with key hints on PC); on touch screens a row of action slots along the very bottom,
-- ending just left of the default jump button, and very small Crouch and Light buttons on the right. Landscape,
-- dynamic thumbstick on the left, camera drag on the right, inside safe areas.
-- Milestone 3 bindings (docs/MILESTONE-3.md 4.7): lantern shield V / ButtonL1 / touch "Shield"; place a flare
-- N / ButtonR1 / touch "Flare"; character and field experience K. Gamepad also gains Menu (DPadUp), medical
-- (DPadDown, moved off ButtonX, the default ProximityPrompt key), swap cell (DPadLeft), throw (DPadRight),
-- rescue (ButtonB) and party ping (ButtonR3); touch gains "Ping" (the verified party ping).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local UI = require(script.Parent.UI)
local UIRules = require(script.Parent.UIRules)
local Icons = require(script.Parent.Icons)

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
local refreshControls: () -> () = function() end

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
	refreshControls()
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
	[Enum.KeyCode.M] = function()
		ctx.panels.toggle("menu")
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

local function releaseTouchSprint()
	sprintTouch = nil
	if not ctx.settings.get("sprintToggle") then
		sprintHeld = false
		sendIntents()
	end
	refreshControls()
end

-- A HUD button that acts the moment it is touched or clicked (no wait for release), like the default jump button:
-- for actions that must be instant (Sprint, Use, Throw, Crouch, Light). Only a touch that begins on the button
-- counts. Roblox also hands a button the InputBegan of a finger that started elsewhere (a camera drag, the
-- thumbstick) once it slides over, in state Change, which is ignored here as the default TouchJump does. Release
-- answers only the touch that pressed.
local function pressable(b: GuiButton, onDown: (InputObject) -> (), onUp: (() -> ())?)
	local pressing: InputObject? = nil
	b.InputBegan:Connect(function(io)
		local t = io.UserInputType
		if t == Enum.UserInputType.Touch then
			if io.UserInputState ~= Enum.UserInputState.Begin then
				return
			end
		elseif t ~= Enum.UserInputType.MouseButton1 then
			return
		end
		pressing = io
		onDown(io)
		refreshControls()
	end)
	b.InputEnded:Connect(function(io)
		if pressing ~= nil and io == pressing then
			pressing = nil
			if onUp then
				onUp()
				refreshControls()
			end
		end
	end)
end

-- A HUD button that acts when it is released over the button (GuiButton.Activated): for consumables and screens.
-- A thumb that lands on it while reaching for the thumbstick and slides away uses nothing, and a finger sliding
-- across it never fires it.
local function tappable(b: GuiButton, onTap: () -> ())
	b.Activated:Connect(function()
		onTap()
		refreshControls()
	end)
end

-- Control labels follow the text size setting (Settings → Text size), as the old touch grid did.
type Scaled = { label: TextLabel, base: number, badge: boolean, area: Frame? }
local scaledLabels: { Scaled } = {}

local function applyTextScale(scale: number)
	for _, e in scaledLabels do
		local px = math.floor(e.base * scale)
		e.label.TextSize = px
		if e.badge then
			e.label.Size = UDim2.fromOffset(0, px + 3)
		else
			local sz = e.label.Size
			e.label.Size = UDim2.new(sz.X.Scale, sz.X.Offset, 0, px + 2)
		end
		local area = e.area
		if area then -- an action slot's icon area makes room for its label
			area.Size = UDim2.new(1, 0, 1, -(px + 2))
		end
	end
end

local function slotButton(parent: Instance, name: string, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.LayoutOrder = order
	b.Text = ""
	b.AutoButtonColor = true
	b.BackgroundColor3 = UI.Colors.charcoal
	b.BackgroundTransparency = 0.3
	b.BorderSizePixel = 0
	UI.corner(b, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Active"
	stroke.Color = UI.Colors.amber
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Enabled = false
	stroke.Parent = b
	b.Parent = parent
	return b
end

local function cornerLabel(parent: Instance, size: number, color: Color3, anchor: Vector2): TextLabel
	local t = UI.label(parent, "", size, color)
	t.AnchorPoint = anchor
	t.Position = UDim2.new(anchor.X, if anchor.X > 0 then -3 else 4, anchor.Y, if anchor.Y > 0 then -1 else 2)
	t.Size = UDim2.new(1, -6, 0, size + 2)
	t.AutomaticSize = Enum.AutomaticSize.None
	t.TextWrapped = false
	t.TextXAlignment = if anchor.X > 0 then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
	t.TextStrokeTransparency = 0.3
	t.TextStrokeColor3 = UI.Colors.charcoal
	t.ZIndex = 2
	table.insert(scaledLabels, { label = t, base = size, badge = false })
	return t
end

-- A small count badge in a slot's bottom-right corner, on its own dark backing so it reads over the icon.
local function countBadge(parent: Instance): TextLabel
	local t = UI.label(parent, "", 12, UI.Colors.bone)
	t.AnchorPoint = Vector2.new(1, 1)
	t.Position = UDim2.new(1, -2, 1, -2)
	t.Size = UDim2.fromOffset(0, 15)
	t.AutomaticSize = Enum.AutomaticSize.X
	t.TextWrapped = false
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.BackgroundColor3 = UI.Colors.charcoal
	t.BackgroundTransparency = 0.15
	t.ZIndex = 2
	UI.corner(t, 4)
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight = UDim.new(0, 3), UDim.new(0, 3)
	p.Parent = t
	table.insert(scaledLabels, { label = t, base = 12, badge = true })
	return t
end

type Consumable = {
	name: string,
	icon: string,
	hint: string, -- keyboard key, shown on PC
	optional: boolean, -- shown only while carried
	count: (have: { [string]: number }) -> number,
	act: () -> (),
	button: TextButton?,
	iconFrame: Frame?,
	countLabel: TextLabel?,
	hintLabel: TextLabel?,
	extraLabel: TextLabel?,
}

local function itemCount(id: string): (have: { [string]: number }) -> number
	return function(have)
		return have[id] or 0
	end
end

-- The consumable column, top to bottom. Sign and rope appear while carried (they had no touch control before).
local CONSUMABLES: { Consumable } = {
	{
		name = "Medical",
		icon = "med",
		hint = "H",
		optional = false,
		count = function(have)
			return (have["med.cloth_dressing"] or 0) + (have["med.bandage"] or 0) + (have["med.splint"] or 0)
		end,
		act = useMedical,
	},
	{
		name = "Cell",
		icon = "cell",
		hint = "R",
		optional = false,
		count = itemCount("power.cell"),
		act = function()
			ctx.send("light.swap")
		end,
	},
	{ name = "Flare", icon = "flare", hint = "N", optional = false, count = itemCount("tool.flare"), act = placeFlare },
	{
		name = "Chalk",
		icon = "chalk",
		hint = "G",
		optional = false,
		count = itemCount("nav.chalk"),
		act = function()
			placeMarker("chalk")
		end,
	},
	{
		name = "Sign",
		icon = "sign",
		hint = "T",
		optional = true,
		count = itemCount("nav.sign"),
		act = function()
			placeMarker("sign")
		end,
	},
	{
		name = "Rope",
		icon = "rope",
		hint = "Y",
		optional = true,
		count = itemCount("nav.rope"),
		act = function()
			placeMarker("rope")
		end,
	},
}

local function buildConsumables()
	local frame = UI.frame(ctx.gui, { Name = "Consumables", BackgroundTransparency = 1 })
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.FillDirection = Enum.FillDirection.Vertical
	grid.Parent = frame
	for i, c in CONSUMABLES do
		local b = slotButton(frame, c.name, i)
		c.button = b
		c.iconFrame = Icons.draw(b, c.icon, 0.14)
		c.countLabel = countBadge(b)
		c.hintLabel = cornerLabel(b, 10, UI.Colors.dim, Vector2.new(0, 0))
		c.extraLabel = cornerLabel(b, 10, UI.Colors.amber, Vector2.new(1, 0))
		tappable(b, c.act)
	end
	UI.onLayout(frame, function(l)
		UI.place(frame, l.column)
		grid.CellSize = UDim2.fromOffset(l.columnCell, l.columnCell)
		grid.CellPadding = UDim2.fromOffset(UIRules.SLOT_GAP, UIRules.SLOT_GAP)
		grid.FillDirectionMaxCells = l.columnRows
		for _, c in CONSUMABLES do
			local h = c.hintLabel
			if h then
				h.Text = if l.touch then "" else c.hint
			end
		end
	end)
end

type Action =
	{ name: string, label: string, icon: string, button: TextButton?, iconFrame: Frame?, labelText: TextLabel? }

-- The touch action row, left to right; Sprint and Use end next to the jump button, nearest the right thumb.
local ACTIONS: { Action } = {
	{ name = "Menu", label = "Menu", icon = "menu" },
	{ name = "Ping", label = "Ping", icon = "ping" },
	{ name = "Help", label = "Help", icon = "help" },
	{ name = "Shield", label = "Shield", icon = "lantern" },
	{ name = "Throw", label = "Throw", icon = "stone" },
	{ name = "Use", label = "Use", icon = "bar" },
	{ name = "Sprint", label = "Sprint", icon = "sprint" },
}
local actionByName: { [string]: Action } = {}

local function buildActionRow()
	local frame = UI.frame(ctx.gui, { Name = "TouchActions", BackgroundTransparency = 1 })
	local list = UI.list(frame, UIRules.SLOT_GAP, true)
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	-- Screens and deliberate actions fire on release (tappable); instant ones on touch (pressable).
	local taps: { [string]: () -> () } = {
		Menu = function()
			ctx.panels.toggle("menu")
		end,
		Ping = function()
			ctx.send("party.ping")
		end,
		Help = rescueAction,
		Shield = shieldLantern,
	}
	local handlers: { [string]: { down: (InputObject) -> (), up: (() -> ())? } } = {
		Throw = {
			down = function()
				ctx.send("throw")
			end,
		},
		Use = { down = useTool },
		Sprint = {
			down = function(io)
				if ctx.settings.get("sprintToggle") then
					sprintToggled = not sprintToggled
				else
					sprintHeld = true
					sprintTouch = io
				end
				sendIntents()
			end,
			up = function()
				if sprintHeld then
					releaseTouchSprint()
				end
			end,
		},
	}
	for i, a in ACTIONS do
		local b = slotButton(frame, a.name, i)
		local area = UI.frame(b, {
			Size = UDim2.new(1, 0, 1, -12),
			BackgroundTransparency = 1,
		})
		a.button = b
		a.iconFrame = Icons.draw(area, a.icon, 0.1)
		local t = cornerLabel(b, 10, UI.Colors.bone, Vector2.new(0.5, 1))
		t.Position = UDim2.new(0.5, 0, 1, -2)
		t.TextXAlignment = Enum.TextXAlignment.Center
		t.Text = a.label
		scaledLabels[#scaledLabels].area = area
		a.labelText = t
		actionByName[a.name] = a
		local tap = taps[a.name]
		if tap then
			tappable(b, tap)
		else
			local h = handlers[a.name]
			pressable(b, h.down, h.up)
		end
	end
	UI.onLayout(frame, function(l)
		local bar = l.bar
		frame.Visible = bar ~= nil
		if bar then
			UI.place(frame, bar)
			for _, a in ACTIONS do
				local b = a.button
				if b then
					b.Size = UDim2.fromOffset(l.barCell, l.barCell)
				end
			end
		end
	end)
end

-- Crouch and Light: very small (owner request, D108): a 30 px button inside a 40 px touch area, on the right.
local crouchVisual: Frame
local crouchIcon: Frame
local lightIcon: Frame

local function buildSmallButtons()
	local frame = UI.frame(ctx.gui, { Name = "SmallActions", BackgroundTransparency = 1 })
	UI.list(frame, UIRules.SMALL_GAP, true)
	local function small(name: string, icon: string, order: number, onDown: () -> ()): (Frame, Frame)
		local hit = Instance.new("TextButton")
		hit.Name = name
		hit.LayoutOrder = order
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromOffset(UIRules.SMALL_HIT, UIRules.SMALL_HIT)
		hit.Parent = frame
		local visual = UI.frame(hit, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(UIRules.SMALL_ICON, UIRules.SMALL_ICON),
			BackgroundColor3 = UI.Colors.charcoal,
			BackgroundTransparency = 0.3,
		})
		UI.corner(visual, UIRules.SMALL_ICON // 2)
		local ic = Icons.draw(visual, icon, 0.16)
		pressable(hit, onDown)
		return visual, ic
	end
	crouchVisual, crouchIcon = small("Crouch", "crouch", 1, function()
		setCrouch(not crouch)
	end)
	local _
	_, lightIcon = small("Light", "light_off", 2, function()
		ctx.send("light.toggle")
	end)
	UI.onLayout(frame, function(l)
		local r = l.small
		frame.Visible = r ~= nil
		if r then
			UI.place(frame, r)
		end
	end)
end

-- Counts, dimmed empties, the selected tool, the shutters and the toggles, from the latest inventory and vitals.
local function refresh()
	local have = inv()
	local v = ctx.state.vitals
	local shown = 0
	for _, c in CONSUMABLES do
		local n = c.count(have)
		local b, ic = c.button, c.iconFrame
		if b and ic then
			b.Visible = not c.optional or n > 0
			if b.Visible then
				shown += 1
			end
			Icons.setDim(ic, n <= 0)
		end
		if c.countLabel then
			c.countLabel.Text = tostring(n)
			c.countLabel.TextColor3 = if n > 0 then UI.Colors.bone else UI.Colors.dim
		end
		if c.extraLabel then
			local lit = if c.icon == "flare" and v then (v.flaresLit or 0) else 0
			c.extraLabel.Text = if lit > 0 then string.format("%d lit", lit) else ""
		end
		local active = b and b:FindFirstChild("Active") :: UIStroke?
		if c.icon == "rope" and active then
			active.Enabled = ropeStart ~= nil
		end
	end
	UI.setConsumableCount(shown)
	local use = actionByName.Use
	if use and use.iconFrame then
		local tool = if (have[selectedTool] or 0) > 0 then selectedTool else nil
		if not tool then
			for _, id in WEAPONS do
				if (have[id] or 0) > 0 then
					tool = id
					break
				end
			end
		end
		Icons.set(use.iconFrame, if tool == "tool.stun_device" then "stun" else "bar")
		Icons.setDim(use.iconFrame, tool == nil)
	end
	local shield = actionByName.Shield
	if shield and shield.iconFrame and shield.labelText then
		local lantern = v ~= nil and v.isLantern == true
		local shut = lantern and v.shielded == true
		Icons.set(shield.iconFrame, if shut then "lantern_shut" else "lantern")
		Icons.setDim(shield.iconFrame, not lantern)
		shield.labelText.Text = if shut then "Open" else "Shield"
	end
	local sprint = actionByName.Sprint
	local sprintActive = sprint and sprint.button and sprint.button:FindFirstChild("Active") :: UIStroke?
	if sprintActive then
		sprintActive.Enabled = if ctx.settings.get("sprintToggle") then sprintToggled else sprintHeld
	end
	if crouchVisual then
		crouchVisual.BackgroundColor3 = if crouch then UI.Colors.amber else UI.Colors.charcoal
		crouchVisual.BackgroundTransparency = if crouch then 0.1 else 0.3
		Icons.set(crouchIcon, if crouch then "crouch_on" else "crouch")
		local lightOn = v ~= nil and v.lightName ~= nil and v.lightOn == true
		Icons.set(lightIcon, if lightOn then "light" else "light_off")
	end
end

local function buildControls()
	buildConsumables()
	buildActionRow()
	buildSmallButtons()
	refreshControls = refresh
	refresh()
	ctx.on("inventory", refresh)
	ctx.on("vitals", refresh)
	applyTextScale(ctx.settings.get("textScale") or 1)
	ctx.settings.onChanged(function(k, v)
		if k == "textScale" then
			applyTextScale(v)
		end
	end)
	local function setMode(t: Enum.UserInputType?)
		UI.setTouchMode(
			if t == nil
				then UserInputService.TouchEnabled
				else t == Enum.UserInputType.Touch
					or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
		)
	end
	setMode(nil)
	UserInputService.LastInputTypeChanged:Connect(setMode)
end

function Input.init(c)
	ctx = c
	-- Gamepad Y toggles the light, but a shown prompt may also use Y (the P04 lever): while one is on screen, Y
	-- belongs to the prompt only.
	local yPrompts: { [ProximityPrompt]: boolean } = {}
	ProximityPromptService.PromptShown:Connect(function(pp)
		if pp.GamepadKeyCode == Enum.KeyCode.ButtonY then
			yPrompts[pp] = true
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(pp)
		yPrompts[pp] = nil
	end)
	UserInputService.InputBegan:Connect(function(io, processed)
		if processed then
			return
		end
		if io.KeyCode == Enum.KeyCode.ButtonY and next(yPrompts) ~= nil then
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
			refreshControls()
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
	buildControls()
	player.CharacterAdded:Connect(function()
		setCrouch(false)
		ropeStart = nil
		refreshControls()
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
