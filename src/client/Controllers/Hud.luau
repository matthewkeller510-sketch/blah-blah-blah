--!strict
-- Gameplay HUD (section 17): center marker, health state, contextual stamina, light charge, concise objective,
-- small party list, notices and save status. No enemy radar and no map of unexplored space.

local TweenService = game:GetService("TweenService")
local UI = require(script.Parent.UI)

local Hud = {}
local ctx: any
local C = UI.Colors

local healthText: TextLabel
local healthFill: Frame
local capMarker: Frame
local staminaBack: Frame
local staminaFill: Frame
local staminaText: TextLabel
local lightText: TextLabel
local objective: TextLabel
local partyBox: Frame
local noticeBox: Frame
local saveText: TextLabel
local holdBack: Frame
local holdFill: Frame
local crosshair: Frame
local pressureText: TextLabel
local inviteBox: Frame
local downedText: TextLabel
local missionObjective = ""
local inShelter = false

local function refreshObjective()
	objective.Text = if missionObjective ~= "" then missionObjective
		elseif inShelter then "Shelter: rest here. Passive recovery stops at half health; supplies heal further."
		else ""
end

function Hud.init(c)
	ctx = c
	local gui = ctx.gui

	local status = UI.frame(gui, { Name = "Status", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(250, 0), AutomaticSize = Enum.AutomaticSize.Y })
	UI.corner(status)
	UI.pad(status, 8)
	UI.list(status, 4)
	healthText = UI.label(status, "Health", 15)
	local hb
	hb, healthFill = UI.bar(status, "Health", C.injury)
	capMarker = UI.frame(hb, { Name = "Cap", Size = UDim2.new(0, 2, 1, 4), Position = UDim2.new(0.5, -1, 0, -2), BackgroundColor3 = C.bone, BackgroundTransparency = 0.3 })
	staminaText = UI.label(status, "", 13, C.dim)
	staminaBack, staminaFill = UI.bar(status, "Stamina", C.bone)
	lightText = UI.label(status, "Light: —", 14)

	objective = UI.label(gui, "", 16)
	objective.AnchorPoint = Vector2.new(0.5, 0)
	objective.Position = UDim2.new(0.5, 0, 0, 12)
	objective.Size = UDim2.new(0.5, 0, 0, 0)
	objective.TextXAlignment = Enum.TextXAlignment.Center
	objective.TextStrokeTransparency = 0.6

	partyBox = UI.frame(gui, { Name = "Party", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(190, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false })
	UI.corner(partyBox)
	UI.pad(partyBox, 6)
	UI.list(partyBox, 2)

	noticeBox = UI.frame(gui, { Name = "Notices", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -150), Size = UDim2.new(0.55, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 })
	local l = UI.list(noticeBox, 4)
	l.VerticalAlignment = Enum.VerticalAlignment.Bottom
	l.HorizontalAlignment = Enum.HorizontalAlignment.Center

	saveText = UI.label(gui, "", 12, C.dim)
	saveText.AnchorPoint = Vector2.new(0, 1)
	saveText.Position = UDim2.new(0, 12, 1, -8)
	saveText.Size = UDim2.fromOffset(300, 0)

	holdBack, holdFill = UI.bar(gui, "Hold", C.amber)
	holdBack.AnchorPoint = Vector2.new(0.5, 0.5)
	holdBack.Position = UDim2.new(0.5, 0, 0.5, 34)
	holdBack.Size = UDim2.fromOffset(160, 8)
	holdBack.Visible = false

	crosshair = UI.frame(gui, { Name = "Marker", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = C.bone, BackgroundTransparency = 0.35 })
	UI.corner(crosshair, 2)

	downedText = UI.label(gui, "", 22, C.bone)
	downedText.AnchorPoint = Vector2.new(0.5, 0.5)
	downedText.Position = UDim2.new(0.5, 0, 0.36, 0)
	downedText.Size = UDim2.new(0.7, 0, 0, 0)
	downedText.TextXAlignment = Enum.TextXAlignment.Center
	downedText.TextStrokeTransparency = 0.4

	pressureText = UI.label(gui, "", 12, C.dim)
	pressureText.AnchorPoint = Vector2.new(1, 1)
	pressureText.Position = UDim2.new(1, -12, 1, -8)
	pressureText.Size = UDim2.fromOffset(200, 0)
	pressureText.TextXAlignment = Enum.TextXAlignment.Right

	inviteBox = UI.frame(gui, { Name = "Invite", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 140), Size = UDim2.fromOffset(220, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false })
	UI.corner(inviteBox)
	UI.pad(inviteBox, 8)
	UI.list(inviteBox, 4)

	ctx.settings.onChanged(function(k, v)
		if k == "crosshair" then
			crosshair.Visible = v
		end
	end)
end

function Hud.vitals(d: any)
	local frac = d.health / d.maxHealth
	healthFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	capMarker.Position = UDim2.new(d.passiveCap / d.maxHealth, -1, 0, -2)
	local cond = d.condition
	local word = if cond == "healthy" then "Steady" elseif cond == "injured" then "Injured" elseif cond == "downed" then "DOWN" else "Dead"
	healthText.Text = string.format("%s · %d/%d", word, math.floor(d.health + 0.5), d.maxHealth)
	healthText.TextColor3 = if cond == "healthy" then C.bone else C.warn
	staminaBack.Visible = d.showStamina
	staminaText.Visible = d.showStamina
	staminaFill.Size = UDim2.fromScale(d.stamina / d.staminaMax, 1)
	staminaFill.BackgroundColor3 = if d.exhausted then C.dim else C.bone
	staminaText.Text = if d.exhausted then "Exhausted — walking until you recover" else "Stamina"
	if d.lightName then
		lightText.Text = string.format("%s %s · %d%% · %d cell%s", d.lightName, if d.lightOn then "ON" else "off", math.floor(d.lightCharge), d.cells, if d.cells == 1 then "" else "s")
		lightText.TextColor3 = if d.lightCharge < 15 then C.warn else C.bone
	else
		lightText.Text = "No light"
		lightText.TextColor3 = C.dim
	end
	if cond == "downed" then
		downedText.Text = if d.stabilized then "DOWN — stabilized. A teammate can treat or carry you."
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

function Hud.notice(text: string, kind: string?)
	local f = UI.frame(noticeBox, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = if kind == "danger" then C.injury elseif kind == "warn" then Color3.fromRGB(70, 56, 30) else C.panel })
	UI.corner(f)
	UI.pad(f, 6)
	local t = UI.label(f, (if kind == "danger" then "! " elseif kind == "warn" then "• " else "") .. text, 15)
	t.TextXAlignment = Enum.TextXAlignment.Center
	local kids = 0
	for _, c in noticeBox:GetChildren() do
		if c:IsA("Frame") then
			kids += 1
		end
	end
	if kids > 4 then
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

function Hud.save(d: any)
	local map = {
		loaded = "Profile loaded",
		saving = "Saving…",
		saved = "Saved",
		failed = "Save failed — will retry",
		offline = "Not saving: data store unavailable",
	}
	saveText.Text = (map[d.status] or d.status) .. (if d.detail then (" (" .. d.detail .. ")") else "")
	saveText.TextColor3 = if d.status == "failed" or d.status == "offline" then C.warn else C.dim
end

local holdTween: Tween?
function Hud.hold(d: any)
	if holdTween then
		holdTween:Cancel()
	end
	if d.seconds then
		holdBack.Visible = true
		holdFill.Size = UDim2.fromScale(0, 1)
		holdTween = TweenService:Create(holdFill, TweenInfo.new(d.seconds, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, 1) })
		;(holdTween :: Tween):Play()
	else
		holdBack.Visible = false
		if d.cancelled then
			Hud.notice("Interrupted.", "warn")
		end
	end
end

function Hud.party(d: any)
	UI.clear(partyBox)
	partyBox.Visible = #d.members > 0
	for _, m in d.members do
		local cond = if m.condition == "healthy" then "ok" elseif m.condition == "injured" then "injured" elseif m.condition == "downed" then "DOWN" else m.condition
		local t = UI.label(partyBox, string.format("%s%s · %s", if m.leader then "★ " else "", m.name, cond), 14, C.teal)
		if m.condition == "downed" then
			t.TextColor3 = C.warn
		end
	end
end

function Hud.invite(d: any)
	UI.clear(inviteBox)
	inviteBox.Visible = true
	UI.label(inviteBox, d.fromName .. " invites you to explore together.", 14, C.teal)
	UI.button(inviteBox, "Accept", function()
		ctx.send("party.accept", { fromUserId = d.fromUserId })
		inviteBox.Visible = false
	end, { Size = UDim2.new(1, 0, 0, 34) })
	UI.button(inviteBox, "Decline", function()
		ctx.send("party.decline", { fromUserId = d.fromUserId })
		inviteBox.Visible = false
	end, { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.dim })
	task.delay(d.seconds, function()
		inviteBox.Visible = false
	end)
end

function Hud.discovery(d: any)
	Hud.notice(if d.byOther then string.format("Discovered with %s: %s", d.byOther, d.label) else ("Discovered: " .. d.label), "info")
end

function Hud.mission(d: any)
	if d.state == "done" then
		missionObjective = ""
	elseif d.state == "failed" then
		missionObjective = ""
		Hud.notice("Rescue ended: " .. tostring(d.reason or "failed"), "warn")
	else
		missionObjective = d.objective or ""
	end
	refreshObjective()
end

function Hud.debugPressure(d: any)
	pressureText.Text = if ctx.settings.get("showPressureDebug") then string.format("director pressure %.2f", d.pressure) else ""
end

return Hud
