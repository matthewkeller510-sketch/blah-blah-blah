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

-- Width at the right edge taken by the touch action grid while it is shown (0 otherwise). Input sets it; HUD strips
-- and small popups stay left of it (keepClearOfTouch) so nothing they show lies under, or on top of, its buttons.
UI.touchReserve = 0
local touchReserveChanged = Instance.new("BindableEvent")

function UI.setTouchReserve(px: number)
	if px ~= UI.touchReserve then
		UI.touchReserve = px
		touchReserveChanged:Fire()
	end
end

-- Keeps a horizontally centred element (AnchorPoint.X = 0.5) between the left margin and the touch grid while the
-- grid is shown (UIRules.band); otherwise it is centred at `frac` of the screen width as before. Only X changes.
-- Follows screen size and grid changes until the element is destroyed.
function UI.keepClearOfTouch(obj: GuiObject, gui: GuiBase2d, frac: number, maxW: number?)
	local function apply()
		local w = gui.AbsoluteSize.X
		local pos, size = obj.Position, obj.Size
		if UI.touchReserve <= 0 or w <= 0 then
			obj.Position = UDim2.new(0.5, 0, pos.Y.Scale, pos.Y.Offset)
			obj.Size = UDim2.new(frac, 0, size.Y.Scale, size.Y.Offset)
		else
			local x, bw = UIRules.band(w, UI.touchReserve, frac, maxW or math.huge, UIRules.EDGE)
			obj.Position = UDim2.new(0, math.floor(x + bw / 2), pos.Y.Scale, pos.Y.Offset)
			obj.Size = UDim2.new(0, math.floor(bw), size.Y.Scale, size.Y.Offset)
		end
	end
	apply()
	local a = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	local b = touchReserveChanged.Event:Connect(apply)
	obj.Destroying:Connect(function()
		a:Disconnect()
		b:Disconnect()
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
	})
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(UIRules.PANEL_MAX_W, UIRules.PANEL_MAX_H)
	cons.Parent = root
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
