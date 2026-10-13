--!strict
-- Small UI kit. Palette from section 17: charcoal, bone-white text, muted amber for actions, desaturated teal for
-- verified party information, dark red for injury. Critical states always carry text/shape, never color alone.

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
UI.TOUCH = 52 -- logical px touch target (48-56 per section 17)

function UI.font(): Enum.Font
	return Enum.Font.GothamMedium
end

function UI.frame(parent: Instance, props: { [string]: any }?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = UI.Colors.panel
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	for k, v in props or {} do
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
	for k, v in props or {} do
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
	local back = UI.frame(parent, { Name = name, Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = Color3.fromRGB(60, 58, 54) })
	UI.corner(back, 4)
	local fill = UI.frame(back, { Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 0 })
	UI.corner(fill, 4)
	return back, fill
end

-- Scrollable modal panel with a title and close button. Returns (root, body).
function UI.panel(parent: Instance, title: string, onClose: () -> ()): (Frame, ScrollingFrame)
	local root = UI.frame(parent, {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0.82, 0),
		BackgroundTransparency = 0.05,
	})
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(560, 640)
	cons.Parent = root
	UI.corner(root, 10)
	UI.pad(root, 12)
	local head = UI.label(root, title, 20)
	head.Size = UDim2.new(1, -60, 0, 28)
	head.AutomaticSize = Enum.AutomaticSize.None
	UI.button(root, "Close", onClose, { Size = UDim2.new(0, 72, 0, UI.TOUCH * 0.8), Position = UDim2.new(1, -72, 0, -4) })
	local body = Instance.new("ScrollingFrame")
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.new(0, 0, 0, 40)
	body.Size = UDim2.new(1, 0, 1, -40)
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollBarThickness = 6
	body.Parent = root
	UI.list(body, 6)
	return root, body
end

return UI
