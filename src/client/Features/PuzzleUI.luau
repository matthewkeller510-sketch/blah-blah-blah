--!strict
-- P05 Echo sequence panel (section 12; T06; section 17 accessibility). The server opens it with "radioPattern"
-- { pattern, symbols, position, powered } when this player tunes the station radio. The pattern is always readable as
-- text (• — • •) and plays as a visual pulse (a dot for short, a bar for long: shape and text, never colour or sound
-- alone). Large Short / Long buttons enter the answer. The client only sends the attempt (radio.attempt { input });
-- the server decides and answers on "radioResult" { ok, powered }. Audio for the tones is a PLACEHOLDER (none yet).
-- The panel steps aside like the other screens: a dangerous creature's approach cue or going down closes it.
-- The set's lamp (tag "P05Lamp", attributes Pattern / Powered / Epoch set by the server) is blinked here, on each
-- client within 30 studs, locked to server time so everyone nearby sees the same rhythm; with Reduce flashes it
-- swells gently instead (UIRules.echoLampLevel). Purely cosmetic; out of range the lamp keeps its own look.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Puzzles = require(Shared.Logic.Puzzles)
local UI = require(script.Parent.Parent.Controllers.UI)
local UIRules = require(script.Parent.Parent.Controllers.UIRules)

local PuzzleUI = {}
local ctx: any
local player = Players.LocalPlayer

-- Walking away from the set closes the panel. Just inside the server's 12-stud range for attempts (RADIO_RANGE in
-- PuzzleService), so the panel is never open where an attempt would be silently ignored.
local CLOSE_DISTANCE = 11.5
local REPLY_TIMEOUT = 2.5

local LAMP_TAG = "P05Lamp"
local LAMP_RANGE = 30 -- studs from the local character (the range the server lamp used)
local LAMP_REST = 2.5 -- dark seconds between repeats of the pattern
local LAMP_GREEN = Color3.fromRGB(70, 170, 90) -- station powered (same colours as PuzzleService)
local LAMP_AMBER = Color3.fromRGB(230, 160, 60) -- no power

type View = {
	root: Frame,
	pulse: Frame,
	pulseText: TextLabel,
	input: TextLabel,
	status: TextLabel,
	pattern: string,
	entered: string,
	position: Vector3?,
	sendToken: number,
}

local view: View? = nil
local playToken = 0

local function close()
	local v = view
	view = nil
	playToken += 1
	if v then
		v.root:Destroy()
	end
end

local function setPulse(v: View, on: boolean, long: boolean)
	local reduce = ctx.settings.get("reduceFlashes") == true
	v.pulse.BackgroundColor3 = if on then UI.Colors.amber else UI.Colors.charcoal
	-- gentler contrast with reduceFlashes; the shape change (dot vs bar) carries the rhythm either way
	v.pulse.BackgroundTransparency = if on then (if reduce then 0.45 else 0) else 0.3
	v.pulse.Size = if on and long then UDim2.new(0, 140, 0, 44) else UDim2.new(0, 44, 0, 44)
	v.pulseText.Text = if on then (if long then "—" else "•") else ""
end

-- Plays the rhythm once on the pulse indicator (same timing as the radio lamp).
local function play(v: View)
	playToken += 1
	local token = playToken
	task.spawn(function()
		task.wait(0.4)
		for i, step in Puzzles.echoTimeline(v.pattern) do
			if token ~= playToken or view ~= v then
				return
			end
			setPulse(v, true, string.sub(v.pattern, i, i) == "L")
			task.wait(step.on)
			if token ~= playToken or view ~= v then
				return
			end
			setPulse(v, false, false)
			task.wait(step.off)
		end
	end)
end

local function showInput(v: View)
	v.input.Text = "Your answer:  " .. (if v.entered == "" then "(nothing yet)" else Puzzles.echoSymbols(v.entered))
end

-- Farther from the set than an attempt may be sent from (unknown positions never count as far).
local function tooFar(v: View): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local pos = v.position
	return pos ~= nil and hrp ~= nil and hrp:IsA("BasePart") and (hrp.Position - pos).Magnitude > CLOSE_DISTANCE
end

local function press(v: View, symbol: string)
	if view ~= v or #v.entered >= #v.pattern then
		return
	end
	v.entered ..= symbol
	showInput(v)
	-- per-element tick: the pulse shows what was just entered
	playToken += 1
	setPulse(v, true, symbol == "L")
	task.delay(if symbol == "L" then Puzzles.ECHO_LONG_SECONDS else Puzzles.ECHO_SHORT_SECONDS, function()
		if view == v then
			setPulse(v, false, false)
		end
	end)
	if #v.entered == #v.pattern then
		if tooFar(v) then
			-- stepped out of range since the last check: the server would ignore the attempt; walking away closes
			close()
			return
		end
		v.status.Text = "Transmitting…"
		v.sendToken += 1
		local token = v.sendToken
		ctx.send("radio.attempt", { input = v.entered })
		task.delay(REPLY_TIMEOUT, function()
			if view == v and v.sendToken == token then
				v.entered = ""
				showInput(v)
				v.status.Text = "No answer from the set. Stay right beside it and try again."
			end
		end)
	end
end

local function open(d: any)
	if type(d) ~= "table" then
		return
	end
	local pattern = Puzzles.normalizeEcho(d.pattern)
	if not pattern then
		return
	end
	close()
	local root, body = UI.panel(ctx.gui, "Station radio — echo the pattern", close)
	local n = 0
	local function ordered<T>(inst: T): T
		local gui: any = inst
		n += 1
		gui.LayoutOrder = n
		return inst
	end
	ordered(
		UI.label(
			body,
			"The lamp on the set pulses short and long tones. Repeat the pattern with the buttons below.",
			14,
			UI.Colors.dim
		)
	)
	ordered(UI.label(body, "Pattern:  " .. Puzzles.echoSymbols(pattern), 30))
	ordered(UI.label(body, "• = short    — = long", 14, UI.Colors.dim))
	local row = ordered(UI.frame(body, { Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1 }))
	local pulse = UI.frame(row, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 44, 0, 44),
		BackgroundColor3 = UI.Colors.charcoal,
		BackgroundTransparency = 0.3,
	})
	UI.corner(pulse, 22)
	local pulseText = UI.label(pulse, "", 28, UI.Colors.charcoal)
	pulseText.AutomaticSize = Enum.AutomaticSize.None
	pulseText.Size = UDim2.fromScale(1, 1)
	pulseText.TextXAlignment = Enum.TextXAlignment.Center
	local input = ordered(UI.label(body, "", 22))
	local status = ordered(UI.label(body, "", 15, UI.Colors.warn))
	local v: View = {
		root = root,
		pulse = pulse,
		pulseText = pulseText,
		input = input,
		status = status,
		pattern = pattern,
		entered = "",
		position = if typeof(d.position) == "Vector3" then d.position else nil,
		sendToken = 0,
	}
	view = v
	showInput(v)
	local buttons = ordered(UI.frame(body, { Size = UDim2.new(1, 0, 0, 72), BackgroundTransparency = 1 }))
	UI.list(buttons, 8, true)
	UI.button(buttons, "Short  •", function()
		press(v, "S")
	end, { Size = UDim2.new(0.48, 0, 0, 68), TextSize = math.floor(22 * UI.TextScale), LayoutOrder = 1 })
	UI.button(buttons, "Long  —", function()
		press(v, "L")
	end, { Size = UDim2.new(0.48, 0, 0, 68), TextSize = math.floor(22 * UI.TextScale), LayoutOrder = 2 })
	ordered(UI.button(body, "Play the rhythm again", function()
		play(v)
	end, { BackgroundColor3 = UI.Colors.teal, Size = UDim2.new(1, 0, 0, UI.TOUCH) }))
	ordered(UI.button(body, "Clear my answer", function()
		v.entered = ""
		v.sendToken += 1
		v.status.Text = ""
		showInput(v)
	end, { BackgroundColor3 = UI.Colors.dim, Size = UDim2.new(1, 0, 0, UI.TOUCH) }))
	if d.powered == false then
		ordered(
			UI.label(body, "The station has no power: the set can hold a frequency but not play it.", 13, UI.Colors.dim)
		)
	end
	play(v)
	-- Close when the player walks away from the set.
	task.spawn(function()
		while view == v do
			task.wait(0.5)
			if view == v and tooFar(v) then
				close()
			end
		end
	end)
end

local function result(d: any)
	local v = view
	if not v or type(d) ~= "table" then
		return
	end
	v.sendToken += 1
	if d.ok then
		v.status.TextColor3 = UI.Colors.teal
		v.status.Text = if d.powered
			then "Locked. The static clears and the frequency holds: a recording begins."
			else "Locked. The frequency holds, but the set has no power. Restore the generator."
		task.delay(3, function()
			if view == v then
				close()
			end
		end)
	else
		v.status.TextColor3 = UI.Colors.warn
		v.status.Text = "Wrong: the tone slides back into static. Watch the pattern and try again."
		v.entered = ""
		showInput(v)
	end
end

-- P05 radio lamp ---------------------------------------------------------------------------------------
type LampLook = { material: Enum.Material, color: Color3 }
local lamps: { [BasePart]: boolean } = {} -- tagged lamps currently on this client (StreamingEnabled adds and removes)
local driven: { [BasePart]: LampLook } = {} -- lamps being blinked here, with the look to put back

local function restoreLamp(p: BasePart)
	local look = driven[p]
	if look then
		driven[p] = nil
		p.Material = look.material
		p.Color = look.color
	end
end

local function trackLamp(inst: Instance)
	if inst:IsA("BasePart") then
		lamps[inst] = true
	end
end

local function untrackLamp(inst: Instance)
	if inst:IsA("BasePart") then
		lamps[inst] = nil
		restoreLamp(inst)
	end
end

local function driveLamps()
	if next(lamps) == nil then
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local origin = if hrp and hrp:IsA("BasePart") then hrp.Position else nil
	local now = workspace:GetServerTimeNow()
	local reduce = ctx.settings.get("reduceFlashes") == true
	for p in lamps do
		local pattern = Puzzles.normalizeEcho(p:GetAttribute("Pattern"))
		local epoch = p:GetAttribute("Epoch")
		if
			p.Parent ~= nil
			and pattern ~= nil
			and type(epoch) == "number"
			and origin ~= nil
			and (p.Position - origin).Magnitude <= LAMP_RANGE
		then
			local look: LampLook = driven[p] or { material = p.Material, color = p.Color }
			driven[p] = look
			local level = UIRules.echoLampLevel(Puzzles.echoTimeline(pattern), LAMP_REST, now - epoch, reduce)
			local onColor = if p:GetAttribute("Powered") == true then LAMP_GREEN else LAMP_AMBER
			if reduce then
				-- no Neon snap: the lamp's own colour swells toward the signal colour and back
				p.Material = look.material
				p.Color = look.color:Lerp(onColor, level)
			else
				p.Material = if level > 0 then Enum.Material.Neon else look.material
				p.Color = if level > 0 then onColor else look.color
			end
		else
			restoreLamp(p)
		end
	end
end

function PuzzleUI.init(c)
	ctx = c
	ctx.on("radioPattern", open)
	ctx.on("radioResult", result)
	-- step aside for danger, like Dialogue and MissionUI
	ctx.on("cue", function(d: any)
		if view and type(d) == "table" and UIRules.THREAT_CUES[d.id] then
			close()
		end
	end)
	ctx.on("vitals", function(d: any)
		if view and type(d) == "table" and d.condition == "downed" then
			close()
		end
	end)
	for _, inst in CollectionService:GetTagged(LAMP_TAG) do
		trackLamp(inst)
	end
	CollectionService:GetInstanceAddedSignal(LAMP_TAG):Connect(trackLamp)
	CollectionService:GetInstanceRemovedSignal(LAMP_TAG):Connect(untrackLamp)
	RunService.Heartbeat:Connect(driveLamps)
end

return PuzzleUI
