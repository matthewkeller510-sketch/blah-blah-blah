--!strict
-- Perception and accessible cues (sections 10, 11, 17). Every essential creature cue has a caption with a rough
-- direction so it remains counterable with sound muted. Audio asset IDs are PLACEHOLDERS (see docs/AUDIO-CUES.md);
-- until real sounds are produced, captions are the delivered cue channel.
-- Private cosmetic effects here never author damage, pickups or any economic outcome.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)

local Cues = {}
local ctx: any
local player = Players.LocalPlayer
local captionBox: Frame
local nearLight: PointLight?
local lastVitals: any = nil
local wasExhausted = false

-- id -> { caption, essential }
local CUES: { [string]: { text: string, essential: boolean } } = {
	sidelooker_scrape = { text = "[a faint scrape of stone]", essential = false },
	sidelooker_retreat = { text = "[something slips out of sight]", essential = false },
	scrabbler_idle = { text = "[claws shifting rubble]", essential = false },
	scrabbler_windup = { text = "[SCRAPING CLAWS — something is about to rush]", essential = true },
	scrabbler_hit = { text = "[claws strike]", essential = true },
	scrabbler_hurt = { text = "[a shrill hiss]", essential = false },
	knocker_knock = { text = "[KNOCK]", essential = true },
	knocker_impact = { text = "[a heavy impact against stone]", essential = true },
	knocker_stunned = { text = "[the knocking stops abruptly]", essential = true },
	weapon_ineffective = { text = "[metal glances off without effect]", essential = true },
	shelter_probe = { text = "[scratching at an unprotected entrance]", essential = true },
	stun_fired = { text = "[stun device discharges]", essential = false },
	breathing = { text = "[heavy breathing]", essential = false },
	wader_ripple = { text = "[ripples spreading across the water]", essential = false },
	wader_drag = { text = "[A DRAGGING STEP IN THE WATER — it heard you. Stop splashing.]", essential = true },
	wader_strike = { text = "[long arms strike from the water]", essential = true },
	wader_lost = { text = "[the dragging steps wander away]", essential = true },
	wader_repelled = { text = "[it recoils and wades off]", essential = true },
	stone_splash = { text = "[a stone splashes]", essential = false },
	stone_clatter = { text = "[a stone clatters on rock]", essential = false },
	plaque_turn = { text = "[stone grinds as the plaque turns]", essential = false },
	gate_open = { text = "[a heavy gate grinds open]", essential = true },
	valve_turn = { text = "[the valve squeals; water shifts in the pipes]", essential = false },
	valve_reset = { text = "[all valves clank shut]", essential = false },
	water_drain = { text = "[a deep gurgle — the cistern is draining]", essential = true },
	water_rising = { text = "[water rushes back into the cistern]", essential = true },
}

local function direction(pos: Vector3?): string
	local cam = workspace.CurrentCamera
	if not pos or not cam then
		return ""
	end
	local rel = cam.CFrame:PointToObjectSpace(pos)
	local dist = rel.Magnitude
	local horiz = Vector3.new(rel.X, 0, rel.Z)
	if horiz.Magnitude < 1 then
		return " (here)"
	end
	local ang = math.deg(math.atan2(rel.X, -rel.Z))
	local dir = if math.abs(ang) < 35
		then "ahead"
		elseif math.abs(ang) > 145 then "behind"
		elseif ang > 0 then "right"
		else "left"
	local range = if dist < 15 then "close" elseif dist < 45 then "near" else "far"
	return string.format(" (%s, %s)", dir, range)
end

local function caption(text: string, essential: boolean)
	if not ctx.settings.get("subtitles") and not essential then
		return
	end
	local t = UI.label(captionBox, text, 16)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.TextStrokeTransparency = 0.3
	task.delay(math.clamp(2.5 + #text / 20, 3, 7), function()
		if t.Parent then
			TweenService:Create(t, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			task.wait(0.6)
			t:Destroy()
		end
	end)
	local n = 0
	for _, c in captionBox:GetChildren() do
		if c:IsA("TextLabel") then
			n += 1
		end
	end
	if n > 4 then
		for _, c in captionBox:GetChildren() do
			if c:IsA("TextLabel") and c ~= t then
				c:Destroy()
				break
			end
		end
	end
end

function Cues.cue(d: any)
	local def = CUES[d.id]
	if not def then
		return
	end
	local text = def.text
	if d.id == "knocker_knock" and d.extra then
		text = string.format("[KNOCK %d of %d — get out of the straight corridor]", d.extra.index, d.extra.of)
		if d.extra.index < d.extra.of then
			text = string.format("[KNOCK %d of %d]", d.extra.index, d.extra.of)
		end
	end
	if d.id == "valve_turn" and d.extra then
		text =
			string.format("[the valve squeals; the gauge settles — %d of %d set right]", d.extra.correct, d.extra.of)
	elseif d.id == "plaque_turn" and d.extra and d.extra.solved then
		text = "[the plaque locks into place with a deep click]"
	end
	caption(text .. direction(d.position), def.essential)
	-- visual alternative for essential cues: a brief edge pulse (not a flash; respects reduceFlashes)
	if def.essential and not ctx.settings.get("reduceFlashes") then
		local edge = UI.frame(ctx.gui, {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(0, 0, 0),
			BackgroundTransparency = 1,
			ZIndex = 0,
		})
		local stroke = Instance.new("UIStroke")
		stroke.Color = UI.Colors.warn
		stroke.Thickness = 6
		stroke.Transparency = 0.4
		stroke.Parent = edge
		TweenService:Create(stroke, TweenInfo.new(0.8), { Transparency = 1 }):Play()
		task.delay(0.9, function()
			edge:Destroy()
		end)
	end
end

local function ensureNearLight()
	local head = player.Character and player.Character:FindFirstChild("Head")
	if not head then
		return
	end
	if nearLight and nearLight.Parent == head then
		return
	end
	-- Close-range legibility without a flashlight (section 08: never a solid black screen). Local only.
	local l = Instance.new("PointLight")
	l.Name = "CloseRangeLegibility"
	l.Range = 9
	l.Shadows = false
	l.Color = Color3.fromRGB(170, 175, 190)
	l.Parent = head
	nearLight = l
end

function Cues.vitals(d: any)
	lastVitals = d
	if d.exhausted and not wasExhausted then
		caption(CUES.breathing.text, false)
	end
	wasExhausted = d.exhausted
end

function Cues.init(c)
	ctx = c
	captionBox = UI.frame(ctx.gui, {
		Name = "Captions",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.new(0.6, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	local l = UI.list(captionBox, 2)
	l.HorizontalAlignment = Enum.HorizontalAlignment.Center
	local t = 0
	RunService.RenderStepped:Connect(function(dt)
		t += dt
		ensureNearLight()
		if nearLight then
			local boost = ctx.settings.get("lowLightBoost") or 0
			nearLight.Brightness = 0.22 + boost * 0.35
		end
		-- readable flicker before depletion, gentler when reduceFlashes is on
		local head = player.Character and player.Character:FindFirstChild("Head")
		local spot = head and head:FindFirstChild("ExpeditionLight") :: SpotLight?
		if spot and lastVitals and lastVitals.lightOn then
			local low = lastVitals.lightCharge < 15
			local base = spot:GetAttribute("BaseBrightness") or 1
			if low then
				local wave = if ctx.settings.get("reduceFlashes")
					then (0.85 + 0.15 * math.sin(t * 2))
					else (if math.noise(t * 6) > 0.25 then 0.35 else 1)
				spot.Brightness = (base :: number) * wave
			else
				spot.Brightness = base :: number
			end
		end
	end)
end

return Cues
