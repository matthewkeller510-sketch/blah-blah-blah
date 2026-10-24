--!strict
-- Gameplay HUD (section 17), laid out per D108 (owner request): no status panel. A slim health readout sits top
-- left, the battery gauge bottom right, the active objective and notices top centre, and the party list, an open
-- party invitation and save problems top right. The consumable column, the touch action row and the very small
-- Crouch and Light buttons belong to Input. No enemy radar and no map of unexplored space.
-- States are never colour alone: the health number, "Exhausted", the injury line and the battery's words
-- ("off", "low", "shut", "moths", "No light") carry them. An invitation is answered in the Party screen (section 14).

local TweenService = game:GetService("TweenService")
local UI = require(script.Parent.UI)
local UIRules = require(script.Parent.UIRules)
local Icons = require(script.Parent.Icons)

local Hud = {}
local ctx: any
local C = UI.Colors

local healthText: TextLabel
local healthFill: Frame
local capMarker: Frame
local staminaRow: Frame
local staminaFill: Frame
local statusText: TextLabel
local batteryText: TextLabel
local batteryBody: Frame
local batteryFill: Frame
local objective: TextLabel
local membersBox: Frame
local noticeBox: Frame
local saveText: TextLabel
local holdBack: Frame
local holdFill: Frame
local crosshair: Frame
local pressureText: TextLabel
local inviteText: TextLabel
local downedText: TextLabel
local missionObjective = ""
local storyObjective = ""
local inShelter = false
local inviteToken = 0
local saveToken = 0
type Invite = { fromUserId: number, fromName: string, expiresAt: number }
local pendingInvite: Invite? = nil
local missionTitle = "Mission" -- the active mission's title, so a failure names the right mission
local MAX_NOTICES = 3

-- Priority: active mission, then the story objective, then the shelter reminder.
local function refreshObjective()
	objective.Text = if missionObjective ~= ""
		then missionObjective
		elseif storyObjective ~= "" then storyObjective
		elseif inShelter then "Shelter: rest here. Passive recovery stops at half health; supplies heal further."
		else ""
end

-- A row of the vitals readout: a 16 px icon slot on the left, a bar in the middle, room for a number on the right.
local function barRow(parent: Instance, name: string, height: number, barHeight: number, color: Color3, order: number)
	local row = UI.frame(parent, {
		Name = name,
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = order,
	})
	local back, fill = UI.bar(row, name .. "Bar", color)
	back.AnchorPoint = Vector2.new(0, 0.5)
	back.Position = UDim2.new(0, 22, 0.5, 0)
	back.Size = UDim2.new(1, -62, 0, barHeight)
	back.BackgroundTransparency = 0.35
	return row, back, fill
end

local function outlined(t: TextLabel): TextLabel
	t.TextStrokeTransparency = 0.45
	t.TextStrokeColor3 = C.charcoal
	return t
end

function Hud.init(c)
	ctx = c
	local gui = ctx.gui

	-- Vitals, top left: heart, health bar with the half-cap marker (F18) and the number; stamina only while it
	-- matters; one status line (exhausted, or the injury penalty and what fixes it).
	local vitals = UI.frame(gui, { Name = "Vitals", BackgroundTransparency = 1 })
	UI.onLayout(vitals, function(l)
		UI.place(vitals, l.vitals)
	end)
	UI.list(vitals, 3)
	local healthRow, hb
	healthRow, hb, healthFill = barRow(vitals, "Health", 16, 8, C.injury, 1)
	local heart = UI.frame(healthRow, { Size = UDim2.fromOffset(16, 16), BackgroundTransparency = 1 })
	Icons.draw(heart, "heart")
	capMarker = UI.frame(hb, {
		Name = "Cap",
		Size = UDim2.new(0, 2, 1, 4),
		Position = UDim2.new(0.5, -1, 0, -2),
		BackgroundColor3 = C.bone,
		BackgroundTransparency = 0.3,
	})
	healthText = outlined(UI.label(healthRow, "", 14))
	healthText.AnchorPoint = Vector2.new(1, 0.5)
	healthText.Position = UDim2.new(1, 0, 0.5, 0)
	healthText.Size = UDim2.new(0, 36, 1, 0)
	healthText.AutomaticSize = Enum.AutomaticSize.None
	healthText.TextXAlignment = Enum.TextXAlignment.Right
	local sRow, _, sFill = barRow(vitals, "Stamina", 8, 5, C.bone, 2)
	staminaRow, staminaFill = sRow, sFill
	staminaRow.Visible = false
	statusText = outlined(UI.label(vitals, "", 12, C.warn))
	statusText.LayoutOrder = 3
	statusText.Visible = false

	-- Battery gauge, bottom right: the words before the percentage say off / low / shut / moths.
	local battery = UI.frame(gui, { Name = "Battery", BackgroundTransparency = 1 })
	UI.onLayout(battery, function(l)
		UI.place(battery, l.battery)
	end)
	local nub = UI.frame(battery, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(3, 8),
		BackgroundColor3 = C.bone,
		BackgroundTransparency = 0.2,
	})
	UI.corner(nub, 1)
	batteryBody = UI.frame(battery, {
		Name = "Body",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.fromOffset(34, 16),
		BackgroundColor3 = C.charcoal,
		BackgroundTransparency = 0.5,
	})
	UI.corner(batteryBody, 3)
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.bone
	stroke.Thickness = 2
	stroke.Parent = batteryBody
	local inner = UI.frame(batteryBody, {
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundTransparency = 1,
	})
	batteryFill = UI.frame(inner, { Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.bone })
	UI.corner(batteryFill, 1)
	batteryText = outlined(UI.label(battery, "No light", 13, C.dim))
	batteryText.AnchorPoint = Vector2.new(1, 0.5)
	batteryText.Position = UDim2.new(1, -44, 0.5, 0)
	batteryText.Size = UDim2.new(1, -44, 1, 0)
	batteryText.AutomaticSize = Enum.AutomaticSize.None
	batteryText.TextXAlignment = Enum.TextXAlignment.Right
	batteryText.TextWrapped = false

	-- Objective and notices, top centre between the vitals and the party list. The objective is one line.
	objective = outlined(UI.label(gui, "", 15))
	objective.AnchorPoint = Vector2.new(0.5, 0)
	objective.Position = UDim2.new(0.5, 0, 0, UIRules.TOP)
	objective.Size = UDim2.new(0.5, 0, 0, UIRules.OBJECTIVE_H)
	objective.AutomaticSize = Enum.AutomaticSize.None
	objective.TextWrapped = false
	objective.TextTruncate = Enum.TextTruncate.AtEnd
	objective.TextXAlignment = Enum.TextXAlignment.Center
	UI.keepInBand(objective, "top", 0.5, 460)

	noticeBox = UI.frame(gui, {
		Name = "Notices",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, UI.layout.noticeTop),
		Size = UDim2.new(0.5, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	local l = UI.list(noticeBox, 4)
	l.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UI.keepInBand(noticeBox, "top", 0.5, 460)

	-- Party list, invitation, save problems and the debug readout, top right.
	local topRight = UI.frame(gui, {
		Name = "Party",
		AnchorPoint = Vector2.new(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	UI.onLayout(topRight, function(lay)
		topRight.Position = UDim2.fromOffset(lay.party.x + lay.party.w, lay.party.y)
		topRight.Size = UDim2.fromOffset(lay.party.w, 0)
	end)
	local tl = UI.list(topRight, 2)
	tl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	membersBox = UI.frame(topRight, {
		Name = "Members",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Visible = false,
	})
	UI.list(membersBox, 2)
	inviteText = outlined(UI.label(topRight, "", 12, C.teal))
	inviteText.LayoutOrder = 2
	inviteText.TextXAlignment = Enum.TextXAlignment.Right
	inviteText.Visible = false
	saveText = outlined(UI.label(topRight, "", 11, C.dim))
	saveText.LayoutOrder = 3
	saveText.TextXAlignment = Enum.TextXAlignment.Right
	saveText.Visible = false
	pressureText = outlined(UI.label(topRight, "", 11, C.dim))
	pressureText.LayoutOrder = 4
	pressureText.TextXAlignment = Enum.TextXAlignment.Right
	local buildText = outlined(UI.label(topRight, UI.BUILD, 11, C.dim))
	buildText.LayoutOrder = 5
	buildText.TextXAlignment = Enum.TextXAlignment.Right
	task.delay(60, function()
		buildText.Visible = false
	end)

	holdBack, holdFill = UI.bar(gui, "Hold", C.amber)
	holdBack.AnchorPoint = Vector2.new(0.5, 0.5)
	holdBack.Position = UDim2.new(0.5, 0, 0.5, 34)
	holdBack.Size = UDim2.fromOffset(160, 8)
	holdBack.Visible = false

	crosshair = UI.frame(gui, {
		Name = "Marker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = C.bone,
		BackgroundTransparency = 0.35,
	})
	UI.corner(crosshair, 2)

	downedText = UI.label(gui, "", 22, C.bone)
	downedText.AnchorPoint = Vector2.new(0.5, 0.5)
	downedText.Position = UDim2.new(0.5, 0, 0.36, 0)
	downedText.Size = UDim2.new(0.7, 0, 0, 0)
	downedText.TextXAlignment = Enum.TextXAlignment.Center
	downedText.TextStrokeTransparency = 0.4
	-- the DOWN / HIDDEN instructions stay readable over every HUD button (text only: taps still reach the buttons)
	downedText.ZIndex = 50

	ctx.settings.onChanged(function(k, v)
		if k == "crosshair" then
			crosshair.Visible = v
		end
	end)
end

local function battery(d: any)
	if not d.lightName then
		batteryFill.Size = UDim2.fromScale(0, 1)
		batteryText.Text = "No light"
		batteryText.TextColor3 = C.dim
		local s = batteryBody:FindFirstChildOfClass("UIStroke")
		if s then
			s.Color = C.dim
		end
		return
	end
	local charge = math.clamp(d.lightCharge, 0, 100)
	local low = charge < 15
	local word = if not d.lightOn
		then "off"
		elseif d.lightDimmed then "moths"
		elseif d.isLantern and d.shielded then "shut"
		elseif low then "low"
		else nil
	batteryText.Text = (if word then word .. " · " else "") .. string.format("%d%%", math.floor(charge))
	local tone = if low or d.lightDimmed then C.warn elseif d.lightOn then C.bone else C.dim
	batteryText.TextColor3 = tone
	batteryFill.BackgroundColor3 = tone
	batteryFill.Size = UDim2.fromScale(charge / 100, 1)
	local s = batteryBody:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = if d.lightOn then C.bone else C.dim
	end
end

function Hud.vitals(d: any)
	local frac = d.health / d.maxHealth
	healthFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	capMarker.Position = UDim2.new(d.passiveCap / d.maxHealth, -1, 0, -2)
	local cond = d.condition
	healthText.Text = tostring(math.floor(d.health + 0.5))
	healthText.TextColor3 = if cond == "healthy" then C.bone else C.warn
	staminaRow.Visible = d.showStamina == true
	staminaFill.Size = UDim2.fromScale(math.clamp(d.stamina / math.max(1, d.staminaMax), 0, 1), 1)
	staminaFill.BackgroundColor3 = if d.exhausted then C.dim else C.bone
	-- One status line: exhaustion while it lasts, otherwise the injury penalty (D40) and what fixes it.
	local injured = d.injured == true and cond ~= "downed" and cond ~= "dead"
	statusText.Text = if d.exhausted
		then "Exhausted: walk to recover"
		elseif injured then "Injured: slow sprint — bandage or splint"
		else ""
	statusText.TextColor3 = if d.exhausted then C.bone else C.warn
	statusText.Visible = statusText.Text ~= ""
	battery(d)
	if d.hidden then
		downedText.Text = "HIDDEN — creatures cannot sense you. Use the niche prompt to step out."
	elseif cond == "downed" then
		downedText.Text = if d.stabilized
			then "DOWN — stabilized. A teammate can treat or carry you."
			else string.format("DOWN — %ds. A party member can stabilize you.", math.ceil(d.downedRemaining))
		if d.carriedBy then
			downedText.Text = "Carried by " .. d.carriedBy
		end
	else
		downedText.Text = ""
	end
	if (d.inShelter ~= nil) ~= inShelter then
		inShelter = d.inShelter ~= nil
		refreshObjective()
	end
end

function Hud.inventory(_d: any) end

-- Compact notices under the objective; at most three at once, the oldest goes first.
function Hud.notice(text: string, kind: string?)
	local f = UI.frame(noticeBox, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = if kind == "danger"
			then C.injury
			elseif kind == "warn" then Color3.fromRGB(70, 56, 30)
			else C.charcoal,
		BackgroundTransparency = 0.35,
	})
	UI.corner(f)
	UI.pad(f, 4)
	local t = UI.label(f, (if kind == "danger" then "! " elseif kind == "warn" then "• " else "") .. text, 14)
	t.TextXAlignment = Enum.TextXAlignment.Center
	local kids = 0
	for _, c in noticeBox:GetChildren() do
		if c:IsA("Frame") then
			kids += 1
		end
	end
	if kids > MAX_NOTICES then
		for _, c in noticeBox:GetChildren() do
			if c:IsA("Frame") and c ~= f then
				c:Destroy()
				break
			end
		end
	end
	-- long enough to read (section 17)
	local secs = math.clamp(3 + #text / 18, 4, 10)
	task.delay(secs, function()
		if f.Parent then
			TweenService:Create(f, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(t, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
			task.wait(0.7)
			f:Destroy()
		end
	end)
end

-- Save status (T20), top right. A problem stays on screen until the next status; routine saves show briefly.
function Hud.save(d: any)
	local map = {
		loaded = "Profile loaded",
		saving = "Saving…",
		saved = "Saved",
		failed = "Save failed — retrying",
		offline = "Not saving",
	}
	local problem = d.status == "failed" or d.status == "offline"
	saveText.Text = map[d.status] or tostring(d.status)
	saveText.TextColor3 = if problem then C.warn else C.dim
	saveText.Visible = true
	saveToken += 1
	if problem then
		if d.detail then
			Hud.notice(tostring(d.detail), "warn")
		end
		return
	end
	local token = saveToken
	task.delay(3, function()
		if saveToken == token then
			saveText.Visible = false
		end
	end)
end

local holdTween: Tween?
function Hud.hold(d: any)
	if holdTween then
		holdTween:Cancel()
	end
	if d.seconds then
		holdBack.Visible = true
		holdFill.Size = UDim2.fromScale(0, 1)
		holdTween = TweenService:Create(
			holdFill,
			TweenInfo.new(d.seconds, Enum.EasingStyle.Linear),
			{ Size = UDim2.fromScale(1, 1) }
		);
		(holdTween :: Tween):Play()
	else
		holdBack.Visible = false
		if d.cancelled then
			Hud.notice("Interrupted.", "warn")
		end
	end
end

function Hud.party(d: any)
	UI.clear(membersBox)
	membersBox.Visible = #d.members > 0
	for _, m in d.members do
		local cond = if m.condition == "healthy"
			then "ok"
			elseif m.condition == "injured" then "injured"
			elseif m.condition == "downed" then "DOWN"
			else m.condition
		local t = outlined(
			UI.label(membersBox, string.format("%s%s · %s", if m.leader then "★ " else "", m.name, cond), 13, C.teal)
		)
		t.TextXAlignment = Enum.TextXAlignment.Right
		t.TextWrapped = false
		t.TextTruncate = Enum.TextTruncate.AtEnd
		if m.condition == "downed" then
			t.TextColor3 = C.warn
		end
	end
end

local function clearInvite()
	inviteToken += 1
	pendingInvite = nil
	inviteText.Visible = false
	ctx.panels.refreshIf("party")
end

function Hud.invite(d: any)
	if type(d) ~= "table" or type(d.fromUserId) ~= "number" then
		return
	end
	local name = if type(d.fromName) == "string" then d.fromName else "Someone"
	local seconds = if type(d.seconds) == "number" then d.seconds else 60
	pendingInvite = { fromUserId = d.fromUserId, fromName = name, expiresAt = os.clock() + seconds }
	inviteText.Text = string.format("%s invites you: Menu → Party", name)
	inviteText.Visible = true
	Hud.notice(name .. " invites you to explore together. Answer in Menu → Party.", "info")
	ctx.panels.refreshIf("party")
	-- Only this invite's timer may clear it (an older invite's timer must not clear a newer one).
	inviteToken += 1
	local token = inviteToken
	task.delay(seconds, function()
		if inviteToken == token then
			clearInvite()
		end
	end)
end

-- The invitation still open, if any (shown with Accept / Decline in the Party screen).
function Hud.pendingInvite(): Invite?
	local p = pendingInvite
	if p and os.clock() < p.expiresAt then
		return p
	end
	return nil
end

function Hud.answerInvite(accept: boolean)
	local p = Hud.pendingInvite()
	if not p then
		return
	end
	ctx.send(if accept then "party.accept" else "party.decline", { fromUserId = p.fromUserId })
	clearInvite()
end

function Hud.discovery(d: any)
	Hud.notice(
		if d.byOther then string.format("Discovered with %s: %s", d.byOther, d.label) else ("Discovered: " .. d.label),
		"info"
	)
end

function Hud.mission(d: any)
	if d.state == "done" or d.state == "ended" then
		-- "ended": the server already sent its own notice naming the mission
		missionObjective = ""
		missionTitle = "Mission"
	elseif d.state == "failed" then
		missionObjective = ""
		Hud.notice(string.format("%s ended: %s", d.title or missionTitle, tostring(d.reason or "failed")), "warn")
		missionTitle = "Mission"
	else
		missionObjective = d.objective or ""
		missionTitle = if type(d.title) == "string" then d.title else "Mission"
	end
	refreshObjective()
end

function Hud.story(d: any)
	storyObjective = if d.complete then "" else ("Story: " .. d.objective)
	refreshObjective()
end

function Hud.debugPressure(d: any)
	pressureText.Text = if ctx.settings.get("showPressureDebug")
		then string.format("director pressure %.2f", d.pressure)
		else ""
end

return Hud
