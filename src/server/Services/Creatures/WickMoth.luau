--!strict
-- C03 Wick Moth (light-seeking nuisance, harmless; docs/MILESTONE-3.md 4.3). In its zones (WorldDefs C03 `zones`), a
-- working exposed light (on, and not a shielded lantern) draws a flutter warning (moth_flutter, 1.5 s), then a swarm
-- that clings to the light and shortens its range (PlayerService.setMothRangeFactor). Darkness for
-- Config.Creatures.mothDarkSeconds, shielding a lantern, leaving the zone or a lit flare in the zone disperses it
-- (moth_disperse) and restores the range. It never changes battery charge or health.
-- Each player has their own small swarm (state below); CreatureFX draws it around that player's own light. A static
-- roost of pale wings in each zone is the shared silhouette.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local WickMoth = {}
local services: any

local MOTH = WorldDefs.Creatures.C03_WickMoth
local M = CreatureRules.Moth
local CFG: CreatureRules.MothConfig = {
	flutterSeconds = M.flutterSeconds,
	darkSeconds = Config.Creatures.mothDarkSeconds,
	cooldownSeconds = M.cooldownSeconds,
}
local ZONE_SLACK = 1
local FLARE_SLACK = 2
local ROOST_CHECK_SECONDS = 0.5

type Swarm = { st: CreatureRules.MothState, appliedItem: string? }
-- weak keys: a write during a departing player's final save never pins the Player (review R2 finding 12)
local swarms: { [Player]: Swarm } = setmetatable({}, { __mode = "k" }) :: any
local roosts: { [string]: BasePart } = {} -- zone chamber id -> roost body
local roostCheckAt = 0

local function setFactor(p: Player, factor: number)
	local ps = services.PlayerService
	if ps.setMothRangeFactor then
		ps.setMothRangeFactor(p, factor)
	end
end

local function zoneAt(pos: Vector3): string?
	for _, z in MOTH.zones do
		if Common.inChamber(pos, z, ZONE_SLACK) then
			return z
		end
	end
	return nil
end

local function flareIn(zone: string, flares: { Common.Flare }): boolean
	for _, f in flares do
		if Common.inChamber(f.position, zone, FLARE_SLACK) then
			return true
		end
	end
	return false
end

local function handle(p: Player, sw: Swarm, ev: string, at: Vector3?, light: Common.LightState)
	if ev == "flutter" then
		Common.cueTo(p, "moth_flutter", at)
		services.PlayerService.send(p, "moth", { state = "flutter" })
		Common.evidence(p, MOTH, "heard_flutter")
	elseif ev == "attach" then
		setFactor(p, Config.Creatures.mothRangeFactor)
		sw.appliedItem = light.itemId
		services.PlayerService.send(p, "moth", { state = "attached" })
		Common.evidence(p, MOTH, "seen") -- the swarm is right there in the beam
	else
		local wasAttached = string.sub(ev, 1, 8) == "disperse"
		if wasAttached then
			setFactor(p, 1)
			sw.appliedItem = nil
		end
		services.PlayerService.send(p, "moth", { state = "clear" })
		if ev ~= "cancel" and ev ~= "disperse_lost" then
			Common.cueTo(p, "moth_disperse", at)
		end
		if ev == "disperse_dark" then
			Common.evidence(p, MOTH, "dispersed_by_darkness")
		elseif ev == "disperse_shield" or ev == "disperse_flare" or ev == "cancel_shield" or ev == "cancel_flare" then
			Common.evidence(p, MOTH, "shielded_or_decoyed")
		end
	end
end

function WickMoth.tick(dt: number)
	local now = os.clock()
	local flares: { Common.Flare }? = nil
	local checkRoosts = now >= roostCheckAt
	if checkRoosts then
		roostCheckAt = now + ROOST_CHECK_SECONDS
	end
	for p, sess in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		local zone = if pos then zoneAt(pos) else nil
		local sw = swarms[p]
		if not sw then
			if not zone then
				continue -- nothing can happen outside a zone without a swarm
			end
			sw = { st = CreatureRules.newMoth(), appliedItem = nil }
			swarms[p] = sw
		end
		assert(sw)
		if zone and not flares then
			flares = Common.flares()
		end
		local light = Common.light(p)
		local ev = CreatureRules.mothStep(sw.st, {
			now = now,
			dt = dt,
			inZone = zone ~= nil,
			light = light,
			flareInZone = zone ~= nil and flareIn(zone, flares or {}),
			perceivable = Common.active(p, sess),
		}, CFG)
		if ev then
			handle(p, sw, ev, pos, light)
		elseif sw.st.phase == "attached" and light.on and (light.itemId ~= sw.appliedItem or checkRoosts) then
			-- a different (or re-equipped) light under the swarm: it clings to that one too. Re-applied twice a
			-- second while attached because the player package resets the factor on unequip and death.
			setFactor(p, Config.Creatures.mothRangeFactor)
			sw.appliedItem = light.itemId
		end
		if sw.st.phase == "none" and not zone then
			swarms[p] = nil
		end
		-- the roost can be sighted without a light
		if checkRoosts and zone and pos and Common.active(p, sess) then
			local roost = roosts[zone]
			if roost and Common.watching(p, roost.Position, M.roostSeenRadius, 0.7) then
				Common.evidence(p, MOTH, "seen")
			end
		end
	end
end

-- Whether a swarm is clinging to this player's light (tools find "nothing to strike" in the dust).
function WickMoth.attached(p: Player): boolean
	local sw = swarms[p]
	return sw ~= nil and (sw.st.phase == "attached" or sw.st.phase == "flutter")
end

function WickMoth.targets(): { Common.Target }
	local out: { Common.Target } = {}
	for _, part in roosts do
		table.insert(out, { part = part, kind = "harmless" })
	end
	return out
end

function WickMoth.onPlayerRemoving(p: Player)
	swarms[p] = nil
end

function WickMoth.init(s)
	services = s
end

function WickMoth.start()
	for _, zone in MOTH.zones do
		local c = WorldDefs.chamber(zone)
		if not c then
			warn("[WickMoth] unknown zone " .. tostring(zone))
			continue
		end
		-- a dusty cluster of pale wings high in one corner of the room
		local at = Vector3.new(c.pos.x + c.size.x / 2 - 1.5, c.pos.y + c.size.y - 2, c.pos.z + c.size.z / 2 - 1.5)
		local m = Common.body(
			"WickMothRoost",
			c.regionId,
			Vector3.new(1.2, 0.6, 1.2),
			Color3.fromRGB(214, 206, 186),
			Enum.Material.Fabric
		)
		m:PivotTo(CFrame.new(at))
		for i = 1, 6 do
			local a = i * math.pi / 3
			Common.addPart(
				m,
				"Wing",
				Vector3.new(0.6, 0.05, 0.4),
				CFrame.new(math.cos(a) * 1.1, (i % 3) * 0.3 - 0.3, math.sin(a) * 1.1) * CFrame.Angles(0, a, 0.3),
				Color3.fromRGB(226, 220, 204),
				Enum.Material.Fabric
			)
		end
		m:SetAttribute("CreatureId", MOTH.id)
		roosts[zone] = m.PrimaryPart :: BasePart
	end
end

return WickMoth
