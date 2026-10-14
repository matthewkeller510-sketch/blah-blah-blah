--!strict
-- Subtitled dialogue panel (sections 05, 17): short character lines, readable notes and recordings, one line at a
-- time in large text with Next / Close (auto-advance optional). It is a compact strip at the bottom of the screen
-- and steps aside for threats: it closes when the player goes down or an approach cue for a dangerous creature
-- arrives, so it never covers the screen during a chase. Important instructions are echoed as a journal notice;
-- the persistent journal lives in the notebook (story channel).
-- Next is Modal while the strip shows, so the first-person PC cursor is free to click it. The buttons are full touch
-- targets. A line too long for the strip at the chosen text size (it may take up to 60% of the screen height) is
-- shown in pages, so nothing falls off the screen; the strip stays left of the touch grid (UIRules).
-- Also applies per-player character visibility (`"npcs"` channel): a figure the server marks hidden for this
-- player (Noah at the depot before you rescued him) is hidden locally. Purely cosmetic; the server decides talk.

local CollectionService = game:GetService("CollectionService")
local TextService = game:GetService("TextService")

local UI = require(script.Parent.Parent.Controllers.UI)
local UIRules = require(script.Parent.Parent.Controllers.UIRules)

local Dialogue = {}
local ctx: any
local C = UI.Colors

type Conversation = { name: string, lines: { string } }

local panel: Frame
local nameLabel: TextLabel
local lineLabel: TextLabel
local nextButton: TextButton
local autoButton: TextButton
local queue: { Conversation } = {}
local current: Conversation? = nil
local index = 0
local pages: { string } = {} -- the current line, split to fit the strip
local page = 0 -- 0 = the current line is not split yet
local auto = false -- per session; off by default
local token = 0
-- Until the server's first "npcs" message arrives, Noah's depot figure stays hidden (he appears only after a rescue).
local hidden: { [string]: boolean } = { N06 = true }
local watched: { [Instance]: RBXScriptConnection } = {}

-- Approach cues of damaging creatures: the panel gets out of the way.
local THREAT_CUES = {
	scrabbler_windup = true,
	knocker_knock = true,
	wader_drag = true,
	wader_strike = true,
	thief_rattle = true,
	thief_strike = true,
	shelter_probe = true,
}

local function readSeconds(text: string): number
	return math.clamp(3 + #text / 22, 3, 9)
end

local function close()
	token += 1
	current = nil
	index = 0
	page = 0
	pages = {}
	table.clear(queue)
	panel.Visible = false
	nextButton.Modal = false
end

local showLine: () -> ()

local function advance()
	local conv = current
	if not conv then
		return
	end
	if page < #pages then
		page += 1
		showLine()
		return
	end
	if index < #conv.lines then
		index += 1
		page = 0
		showLine()
		return
	end
	-- conversation finished: the next queued one, or close
	local nextConv = table.remove(queue, 1)
	if nextConv then
		current = nextConv
		index = 1
		page = 0
		showLine()
	else
		close()
	end
end

-- Width of the line text: the laid-out label, or (before the first layout) the strip's computed width.
local function lineWidth(): number
	local w = lineLabel.AbsoluteSize.X
	if w >= 40 then
		return w
	end
	local _, bw = UIRules.band(ctx.gui.AbsoluteSize.X, UI.touchReserve, 0.56, 620, UIRules.EDGE)
	return math.max(40, bw - 2 * UIRules.DIALOGUE_PAD - 116)
end

-- Splits a line into pages that fit the strip's height limit at this text size (UIRules.dialogueLineCap).
local function split(text: string, size: number): { string }
	local width = lineWidth()
	local cap = UIRules.dialogueLineCap(ctx.gui.AbsoluteSize.Y, math.ceil(14 * UI.TextScale) + 2)
	return UIRules.paginate(text, function(candidate: string): boolean
		return TextService:GetTextSize(candidate, size, UI.font(), Vector2.new(width, 100000)).Y <= cap
	end)
end

showLine = function()
	local conv = current
	if not conv then
		return
	end
	token += 1
	local my = token
	local size = math.floor(18 * UI.TextScale)
	lineLabel.TextSize = size
	nameLabel.TextSize = math.floor(14 * UI.TextScale)
	nameLabel.Text = conv.name
	if page == 0 then
		pages = split(conv.lines[index] or "", size)
		page = 1
	end
	local text = pages[page] or ""
	lineLabel.Text = text
	local last = index >= #conv.lines and page >= #pages and #queue == 0
	nextButton.Text = if last then "Done" else "Next ▸"
	panel.Visible = true
	nextButton.Modal = true
	if auto then
		task.delay(readSeconds(text), function()
			if token == my then
				advance()
			end
		end)
	end
end

local function receive(d: any)
	if type(d) ~= "table" or type(d.lines) ~= "table" or #d.lines == 0 then
		return
	end
	local lines = {}
	for _, l in d.lines do
		if type(l) == "string" then
			table.insert(lines, l)
		end
	end
	if #lines == 0 then
		return
	end
	local conv: Conversation = { name = if type(d.name) == "string" then d.name else "", lines = lines }
	if type(d.journal) == "string" and d.journal ~= "" then
		ctx.hud.notice("Journal: " .. d.journal, "info")
	end
	if current then
		if #queue < 4 then
			table.insert(queue, conv)
		end
		if index >= #(current :: Conversation).lines and page >= #pages then
			nextButton.Text = "Next ▸"
		end
		return
	end
	current = conv
	index = 1
	page = 0
	showLine()
end

-- Character visibility --------------------------------------------------------------------------------

local function applyVisibility(model: Instance)
	local id = model:GetAttribute("NpcId")
	local hide = type(id) == "string" and hidden[id] == true
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if hide then 1 else 0
		elseif d:IsA("BillboardGui") or d:IsA("ProximityPrompt") then
			(d :: any).Enabled = not hide
		end
	end
end

local function watch(model: Instance)
	if watched[model] then
		return
	end
	-- Streaming can deliver parts after the tag; re-apply as they arrive.
	watched[model] = model.DescendantAdded:Connect(function()
		applyVisibility(model)
	end)
	applyVisibility(model)
end

function Dialogue.init(c: any)
	ctx = c
	panel = UI.frame(ctx.gui, {
		Name = "Dialogue",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(0.56, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.12,
		Visible = false,
		ZIndex = 0, -- creature captions stay readable on top of it
	})
	-- No height cap: pages keep a line within 60% of the screen height, and a capped strip would push text off-screen.
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(620, math.huge)
	cons.Parent = panel
	UI.corner(panel, 8)
	UI.pad(panel, UIRules.DIALOGUE_PAD)
	UI.list(panel, 8, true)
	UI.keepClearOfTouch(panel, ctx.gui, 0.56, 620)
	local textCol = UI.frame(panel, {
		Size = UDim2.new(1, -116, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
	})
	UI.list(textCol, 2)
	nameLabel = UI.label(textCol, "", 14, C.amber)
	nameLabel.LayoutOrder = 1
	lineLabel = UI.label(textCol, "", 18, C.bone)
	lineLabel.LayoutOrder = 2
	local buttons = UI.frame(panel, {
		Size = UDim2.new(0, 108, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
	})
	-- Three full touch targets with 8 px between them (UIRules.DIALOGUE_BUTTONS = 172 px).
	UI.list(buttons, 8)
	nextButton = UI.button(buttons, "Next ▸", advance, { Size = UDim2.new(1, 0, 0, UI.TOUCH), LayoutOrder = 1 })
	UI.button(
		buttons,
		"Close",
		close,
		{ Size = UDim2.new(1, 0, 0, UI.TOUCH), BackgroundColor3 = C.dim, LayoutOrder = 2 }
	)
	autoButton = UI.button(buttons, "Auto: off", function()
		auto = not auto
		autoButton.Text = if auto then "Auto: on" else "Auto: off"
		if auto and current then
			showLine()
		end
	end, { Size = UDim2.new(1, 0, 0, UI.TOUCH), BackgroundColor3 = C.dim, LayoutOrder = 3 })

	ctx.on("dialogue", receive)
	ctx.on("cue", function(d: any)
		if type(d) == "table" and THREAT_CUES[d.id] and panel.Visible then
			close()
		end
	end)
	ctx.on("vitals", function(d: any)
		if type(d) == "table" and d.condition == "downed" and panel.Visible then
			close()
		end
	end)
	ctx.on("npcs", function(d: any)
		hidden = {}
		if type(d) == "table" and type(d.hidden) == "table" then
			for id, v in d.hidden do
				if type(id) == "string" and v == true then
					hidden[id] = true
				end
			end
		end
		for _, m in CollectionService:GetTagged("StoryNpc") do
			watch(m)
			applyVisibility(m)
		end
	end)
	for _, m in CollectionService:GetTagged("StoryNpc") do
		watch(m)
	end
	CollectionService:GetInstanceAddedSignal("StoryNpc"):Connect(watch)
	CollectionService:GetInstanceRemovedSignal("StoryNpc"):Connect(function(m)
		local conn = watched[m]
		if conn then
			conn:Disconnect()
			watched[m] = nil
		end
	end)
end

return Dialogue
