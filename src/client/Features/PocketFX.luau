--!strict
-- Variable pocket cosmetics (section 04, F08; docs/MILESTONE-3.md section 3). Client-only, optional and cheap:
--   * while a change is telegraphed ("pocketState" channel, phase "telegraph"): falling dust at both mouths and a
--     flicker on the numbered threshold plates (the server already makes them glow steadily; with reduceFlashes the
--     flicker is skipped and only the steady glow remains);
--   * P06: the false doors' lamps follow one shared rhythm computed from server time, so every player sees the same
--     change at the same moment; the stable door's lamp stays steady. reduceFlashes turns the blinks into a slow dip.
-- Captions for pocket_shift / pocket_settled / anchor_verified come from the existing cue channel (Cues).
-- Nothing here decides anything: versions, geometry, blockers and verification are server state.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local Pockets = require(Shared.Logic.Pockets)

local PocketFX = {}

local ctx: any
local fxFolder: Folder
type Telegraph = { endsAt: number, emitters: { BasePart } }
local telegraphs: { [string]: Telegraph } = {}
local touchedPlates: { [BasePart]: boolean } = {}

local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local function reduceFlashes(): boolean
	return ctx.settings.get("reduceFlashes") == true
end

local function stopDust(pocketId: string)
	local t = telegraphs[pocketId]
	if t then
		telegraphs[pocketId] = nil
		for _, e in t.emitters do
			e:Destroy()
		end
	end
end

local function startDust(pocketId: string, mouths: { any }, endsAt: number)
	stopDust(pocketId)
	local emitters: { BasePart } = {}
	for _, m in mouths do
		if typeof(m) == "Vector3" then
			-- a thin invisible source just under the lintel: dust trickles down across the doorway
			local src = Instance.new("Part")
			src.Name = "PocketDust_" .. pocketId
			src.Anchored = true
			src.CanCollide = false
			src.CanQuery = false
			src.CanTouch = false
			src.Transparency = 1
			src.Size = Vector3.new(8, 0.2, 8)
			src.CFrame = CFrame.new(m + Vector3.new(0, 6, 0))
			local pe = Instance.new("ParticleEmitter")
			pe.Texture = DUST_TEXTURE
			pe.Color = ColorSequence.new(Color3.fromRGB(150, 140, 120))
			pe.LightEmission = 0
			pe.LightInfluence = 1
			pe.Rate = 8
			pe.Lifetime = NumberRange.new(2, 3)
			pe.Speed = NumberRange.new(0.3, 1)
			pe.SpreadAngle = Vector2.new(20, 20)
			pe.Acceleration = Vector3.new(0, -3, 0)
			pe.Size = NumberSequence.new(0.35, 0.8)
			pe.Transparency = NumberSequence.new(0.35, 1)
			pe.EmissionDirection = Enum.NormalId.Bottom
			pe.Parent = src
			src.Parent = fxFolder
			table.insert(emitters, src)
		end
	end
	telegraphs[pocketId] = { endsAt = endsAt, emitters = emitters }
end

local function onState(d: any)
	if type(d) ~= "table" or type(d.id) ~= "string" then
		return
	end
	if d.phase == "telegraph" and type(d.endsAt) == "number" and type(d.mouths) == "table" then
		startDust(d.id, d.mouths, d.endsAt)
	else
		stopDust(d.id)
	end
end

local function update()
	local now = workspace:GetServerTimeNow()
	local reduce = reduceFlashes()
	-- telegraph: expire, then flicker the plates of pockets still shifting
	for id, t in telegraphs do
		if now > t.endsAt + 1 then
			stopDust(id)
		end
	end
	local blink = not reduce and math.floor(now * 2) % 2 == 0
	for _, inst in CollectionService:GetTagged("PocketThreshold") do
		if inst:IsA("BasePart") then
			local id = inst:GetAttribute("PocketId")
			local shifting = type(id) == "string" and telegraphs[id] ~= nil
			if shifting then
				inst.LocalTransparencyModifier = if blink then 0.5 else 0
				touchedPlates[inst] = true
			elseif touchedPlates[inst] then
				inst.LocalTransparencyModifier = 0
				touchedPlates[inst] = nil
			end
		end
	end
	-- P06 lamps
	local period = WorldDefs.Puzzles.P06.flickerPeriodSeconds
	local level = Pockets.p06LampLevel(now, period, reduce)
	for _, inst in CollectionService:GetTagged("P06Lamp") do
		if inst:IsA("BasePart") then
			local stable = inst:GetAttribute("Stable") == true
			local l = if stable then 1 else level
			inst.LocalTransparencyModifier = (1 - l) * 0.75
			local light = inst:FindFirstChildOfClass("PointLight")
			if light then
				light.Brightness = 1.2 * l
			end
		end
	end
end

function PocketFX.init(c: any)
	ctx = c
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "PocketFX"
	fxFolder.Parent = workspace
	ctx.on("pocketState", onState)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			update()
		end
	end)
end

return PocketFX
