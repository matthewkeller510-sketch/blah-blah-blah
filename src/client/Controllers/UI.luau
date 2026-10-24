--!strict
-- Small UI kit. Palette from section 17: charcoal, bone-white text, muted amber for actions, desaturated teal for
-- verified party information, dark red for injury. Critical states always carry text/shape, never color alone.

local UIRules = require(script.Parent.UIRules)

local UI = {}

UI.Colors = {
	charcoal = Color3.fromRGB(24, 23, 22),
	panel = Color3.fromRGB(34, 32, 30),
	bone = Color3.fromRGB(232, 226, 210),
	dim = Color3.fromRGB(150, 145, 135),
	amber = Color3.fromRGB(201, 150, 70),
	teal = Color3.fromRGB(96, 150, 148),
	injury = Color3.fromRGB(140, 38, 34),
	warn = Color3.fromRGB(214, 170, 90),
}

UI.TextScale = 1 -- adjustable text size (settings)
-- Shown for the first minute of play and at the bottom of the Menu, so a tester can tell which build is running.
UI.BUILD = "Build: HUD 2 (Oct 24)"
UI.TOUCH = UIRules.TOUCH -- logical px touch target (48-56 per section 17)

function UI.font(): Enum.Font
	return Enum.Font.GothamMedium
end

function UI.frame(parent: Instance, props: { [string]: any }?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = UI.Colors.panel
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	for k, v in (props or {}) :: { [string]: any } do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

function UI.corner(parent: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 6)
	c.Parent = parent
end

function UI.pad(parent: Instance, p: number)
	local u = Instance.new("UIPadding")
	u.PaddingTop, u.PaddingBottom = UDim.new(0, p), UDim.new(0, p)
	u.PaddingLeft, u.PaddingRight = UDim.new(0, p), UDim.new(0, p)
	u.Parent = parent
end

function UI.list(parent: Instance, gap: number?, horizontal: boolean?)
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, gap or 4)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	l.Parent = parent
	return l
end

function UI.label(parent: Instance, text: string, size: number?, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = color or UI.Colors.bone
	t.Font = UI.font()
	t.TextSize = math.floor((size or 16) * UI.TextScale)
	t.TextWrapped = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.Size = UDim2.new(1, 0, 0, 0)
	t.Parent = parent
	return t
end

function UI.button(parent: Instance, text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local b = Instance.new("TextButton")
	b.Text = text
	b.Font = UI.font()
	b.TextSize = math.floor(16 * UI.TextScale)
	b.TextColor3 = UI.Colors.charcoal
	b.BackgroundColor3 = UI.Colors.amber
	b.AutoButtonColor = true
	b.Size = UDim2.new(1, 0, 0, 40)
	for k, v in (props or {}) :: { [string]: any } do
		(b :: any)[k] = v
	end
	UI.corner(b)
	b.Parent = parent
	b.Activated:Connect(onClick)
	return b
end

function UI.clear(parent: Instance)
	for _, c in parent:GetChildren() do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") and not c:IsA("UICorner") then
			c:Destroy()
		end
	end
end

function UI.bar(parent: Instance, name: string, color: Color3): (Frame, Frame)
	local back =
		UI.frame(parent, { Name = name, Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = Color3.fromRGB(60, 58, 54) })
	UI.corner(back, 4)
	local fill = UI.frame(
		back,
		{ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 0 }
	)
	UI.corner(fill, 4)
	return back, fill
end

-- HUD layout (UIRules.hudLayout, D108) for the current screen size, input mode and number of consumable slots.
-- Hud and Input place their elements from it; centred strips and popups stay inside its bands (keepInBand).
UI.BAR_SLOTS = 7 -- touch action row: Menu, Ping, Help, Shield, Throw, Use, Sprint
UI.layout = (nil :: any) :: UIRules.HudLayout
local layoutChanged = Instance.new("BindableEvent")
local layoutGui: GuiBase2d? = nil
local touchMode = false
local consumableCount = 4

function UI.relayout()
	local gui = layoutGui
	if not gui then
		return
	end
	local s = gui.AbsoluteSize
	local cam = workspace.CurrentCamera
	local view = if cam then cam.ViewportSize else s
	UI.layout = UIRules.hudLayout(s.X, s.Y, view.X, view.Y, touchMode, consumableCount, UI.BAR_SLOTS)
	layoutChanged:Fire()
end

-- Called once by Main with the HUD's ScreenGui, before any controller builds its elements.
function UI.attach(gui: GuiBase2d)
	layoutGui = gui
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(UI.relayout)
	UI.relayout()
end

function UI.setTouchMode(on: boolean)
	if on ~= touchMode then
		touchMode = on
		UI.relayout()
	end
end

function UI.isTouchMode(): boolean
	return touchMode
end

function UI.setConsumableCount(n: number)
	if n ~= consumableCount then
		consumableCount = n
		UI.relayout()
	end
end

-- Calls fn with the layout now and after every change, until `owner` is destroyed.
function UI.onLayout(owner: Instance, fn: (UIRules.HudLayout) -> ())
	fn(UI.layout)
	local c = layoutChanged.Event:Connect(function()
		fn(UI.layout)
	end)
	owner.Destroying:Connect(function()
		c:Disconnect()
	end)
end

-- Puts a GuiObject on a layout rectangle (offsets from the gui's top-left corner).
function UI.place(obj: GuiObject, r: UIRules.Rect)
	obj.AnchorPoint = Vector2.zero
	obj.Position = UDim2.fromOffset(r.x, r.y)
	obj.Size = UDim2.fromOffset(r.w, r.h)
end

-- Keeps a horizontally centred element (AnchorPoint.X = 0.5) inside a layout band: "top" (objective, notices) or
-- "low" (captions, the dialogue strip, popups). The bands are symmetric, so only the width changes. With
-- `bottomGap`, the element's bottom (AnchorPoint.Y = 1) also sits that far above the low band's bottom edge, which
-- is above the touch action row.
function UI.keepInBand(obj: GuiObject, band: "top" | "low", frac: number, maxW: number?, bottomGap: number?)
	UI.onLayout(obj, function(l)
		local w = if layoutGui then layoutGui.AbsoluteSize.X else 0
		local b = if band == "top" then l.topBand else l.lowBand
		local size, pos = obj.Size, obj.Position
		local bw = UIRules.bandWidth(w, b, frac, maxW or math.huge)
		obj.Size = UDim2.new(0, math.floor(bw), size.Y.Scale, size.Y.Offset)
		local y = if bottomGap then UDim.new(1, -(l.lowBottom + bottomGap)) else pos.Y
		obj.Position = UDim2.new(0.5, 0, y.Scale, y.Offset)
	end)
end

-- Scrollable modal panel with a title and close button. Returns (root, body).
-- Close is Modal: in first person (D01) the PC cursor is locked to the screen centre and Roblox frees it only while a
-- visible Modal button exists, so every screen built on UI.panel can be used with a mouse.
-- The header row is as tall as Close (a full touch target); the title stays on one line, truncated at large text
-- sizes, and ends before Close, so it never runs under Close or into the body.
function UI.panel(parent: Instance, title: string, onClose: () -> ()): (Frame, ScrollingFrame)
	local root = UI.frame(parent, {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(UIRules.PANEL_SCALE_W, 0, UIRules.PANEL_SCALE_H, 0),
		BackgroundTransparency = 0.05,
		ZIndex = 10, -- over the HUD's consumable column and action row; captions (50) stay above
	})
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(UIRules.PANEL_MAX_W, UIRules.PANEL_MAX_H)
	cons.Parent = root
	-- On touch screens the panel ends above the action row, so its edge never cuts across the slots.
	UI.onLayout(root, function(l)
		local bar = l.bar
		local gui = layoutGui
		if bar and gui then
			local s = gui.AbsoluteSize
			local x, y, w, h = UIRules.panelRectAbove(s.X, s.Y, bar.y - UIRules.LOW_GAP)
			root.AnchorPoint = Vector2.zero
			root.Position = UDim2.fromOffset(x, y)
			root.Size = UDim2.fromOffset(w, h)
		else
			root.AnchorPoint = Vector2.new(0.5, 0.5)
			root.Position = UDim2.fromScale(0.5, 0.5)
			root.Size = UDim2.new(UIRules.PANEL_SCALE_W, 0, UIRules.PANEL_SCALE_H, 0)
		end
	end)
	UI.corner(root, 10)
	UI.pad(root, UIRules.PANEL_PAD)
	local closeW = UIRules.PANEL_CLOSE_W
	local head = UI.label(root, title, 20)
	head.Size = UDim2.new(1, -(closeW + 8), 0, UI.TOUCH)
	head.AutomaticSize = Enum.AutomaticSize.None
	head.TextWrapped = false
	head.TextTruncate = Enum.TextTruncate.AtEnd
	local closeButton = UI.button(
		root,
		"Close",
		onClose,
		{ Size = UDim2.new(0, closeW, 0, UI.TOUCH), Position = UDim2.new(1, -closeW, 0, 0) }
	)
	closeButton.Modal = true
	local top = UIRules.PANEL_BODY_TOP
	local body = Instance.new("ScrollingFrame")
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.new(0, 0, 0, top)
	body.Size = UDim2.new(1, 0, 1, -top)
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollBarThickness = 6
	body.Parent = root
	UI.list(body, 6)
	return root, body
end

return UI
