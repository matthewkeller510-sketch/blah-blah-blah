--!strict
-- Draws the procedural icons of IconDefs with plain frames (D109): no image assets, so nothing to upload or bind.

local IconDefs = require(script.Parent.IconDefs)

local Icons = {}

local DIM = 0.65 -- how far a dimmed icon fades toward transparent (an empty consumable)

local function color(key: string): Color3
	local c = IconDefs.COLORS[key] or IconDefs.COLORS.bone
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function applyAlpha(f: Frame, dim: boolean)
	local base = (f:GetAttribute("alpha") :: number?) or 0
	local a = if dim then base + (1 - base) * DIM else base
	local stroke = f:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = a
	else
		f.BackgroundTransparency = a
	end
end

local function applyThickness(holder: Frame)
	local px = holder.AbsoluteSize.X
	for _, f in holder:GetChildren() do
		local stroke = f:FindFirstChildOfClass("UIStroke")
		local t = f:GetAttribute("t") :: number?
		if stroke and t then
			stroke.Thickness = math.max(1, t * px)
		end
	end
end

-- Replaces the shapes in `holder` with icon `name` (no work if it already shows it).
function Icons.set(holder: Frame, name: string)
	if holder:GetAttribute("icon") == name then
		return
	end
	holder:SetAttribute("icon", name)
	for _, c in holder:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local dim = holder:GetAttribute("dim") == true
	for i, s in IconDefs.ICONS[name] or IconDefs.ICONS.missing do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(s.x, s.y)
		f.Size = UDim2.fromScale(s.w, s.h)
		f.Rotation = s.r or 0
		f.ZIndex = i
		f:SetAttribute("alpha", s.a or 0)
		if s.k == "ring" then
			f.BackgroundTransparency = 1
			f:SetAttribute("t", s.t or 0.06)
			local stroke = Instance.new("UIStroke")
			stroke.Color = color(s.c)
			stroke.Parent = f
		else
			f.BackgroundColor3 = color(s.c)
		end
		if s.rad then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(s.rad, 0)
			corner.Parent = f
		end
		applyAlpha(f, dim)
		f.Parent = holder
	end
	applyThickness(holder)
end

-- Draws icon `name` centred in `parent`, square, `inset` (a fraction) in from each side. Returns the icon's frame.
function Icons.draw(parent: GuiObject, name: string, inset: number?): Frame
	local m = inset or 0
	local holder = Instance.new("Frame")
	holder.Name = "Icon"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1 - 2 * m, 1 - 2 * m)
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.Parent = holder
	holder.Parent = parent
	Icons.set(holder, name)
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		applyThickness(holder)
	end)
	return holder
end

-- Fades an icon (an empty consumable) or restores it.
function Icons.setDim(holder: Frame, dim: boolean)
	if (holder:GetAttribute("dim") == true) == dim then
		return
	end
	holder:SetAttribute("dim", dim)
	for _, f in holder:GetChildren() do
		if f:IsA("Frame") then
			applyAlpha(f, dim)
		end
	end
end

return Icons
