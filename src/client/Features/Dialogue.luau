--!strict
-- Subtitled dialogue panel (sections 05, 17): short character lines, readable notes and recordings, one line at a
-- time in large text with Next / Close (auto-advance optional). It is a compact strip at the bottom of the screen
-- and steps aside for threats: it closes when the player goes down or an approach cue for a dangerous creature
-- arrives, so it never covers the screen during a chase. Important instructions are echoed as a journal notice;
-- the persistent journal lives in the notebook (story channel).
-- Also applies per-player character visibility (`"npcs"` channel): a figure the server marks hidden for this
-- player (Noah at the depot before you rescued him) is hidden locally. Purely cosmetic; the server decides talk.

local CollectionService = game:GetService("CollectionService")

local UI = require(script.Parent.Parent.Controllers.UI)

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
	table.clear(queue)
	panel.Visible = false
end

local showLine: () -> ()

local function advance()
	local conv = current
	if not conv then
		return
	end
	if index < #conv.lines then
		index += 1
		showLine()
		return
	end
	-- conversation finished: the next queued one, or close
	local nextConv = table.remove(queue, 1)
	if nextConv then
		current = nextConv
		index = 1
		showLine()
	else
		close()
	end
end

showLine = function()
	local conv = current
	if not conv then
		return
	end
	token += 1
	local my = token
	local text = conv.lines[index] or ""
	nameLabel.Text = conv.name
	lineLabel.Text = text
	lineLabel.TextSize = math.floor(18 * UI.TextScale)
	nameLabel.TextSize = math.floor(14 * UI.TextScale)
	local last = index >= #conv.lines and #queue == 0
	nextButton.Text = if last then "Done" else "Next ▸"
	panel.Visible = true
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
		if index >= #(current :: Conversation).lines then
			nextButton.Text = "Next ▸"
		end
		return
	end
	current = conv
	index = 1
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
	local cons = Instance.new("UISizeConstraint")
	cons.MaxSize = Vector2.new(620, 220)
	cons.Parent = panel
	UI.corner(panel, 8)
	UI.pad(panel, 8)
	UI.list(panel, 8, true)
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
	UI.list(buttons, 4)
	nextButton = UI.button(buttons, "Next ▸", advance, { Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 1 })
	UI.button(buttons, "Close", close, { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.dim, LayoutOrder = 2 })
	autoButton = UI.button(buttons, "Auto: off", function()
		auto = not auto
		autoButton.Text = if auto then "Auto: on" else "Auto: off"
		if auto and current then
			showLine()
		end
	end, { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C.dim, LayoutOrder = 3 })

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
