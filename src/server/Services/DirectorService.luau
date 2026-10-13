--!strict
-- Server encounter director (section 11, PROPOSED). Computes per-player pressure from region danger, health,
-- useful light charge, medical supplies, recent exertion, group context and time since a threat.
-- It never reads spending, Robux balance or purchase history.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local Director = require(Shared.Logic.Director)
local Inventory = require(Shared.Logic.Inventory)

local DirectorService = {}
local services: any

local victims: { [Player]: Director.VictimRecord } = {}
local activeDamaging = 0

local function victim(p: Player): Director.VictimRecord
	local v = victims[p]
	if not v then
		v = { activeDamagingThreats = 0, cooldownUntil = os.clock() + 30 } -- a calm first half-minute
		victims[p] = v
	end
	return v
end

function DirectorService.pressure(player: Player): number
	local s = services.PlayerService.get(player)
	if not s then
		return 0
	end
	local r = WorldDefs.region(s.regionId)
	local med = Inventory.count(s.profile.inventory, "med.bandage") + Inventory.count(s.profile.inventory, "med.cloth_dressing")
	local hasLight = s.profile.equippedLight ~= nil and Inventory.count(s.profile.inventory, s.profile.equippedLight) > 0
	return Director.pressure(Config.Director, {
		regionDanger = r and r.danger or 0,
		healthFraction = s.vitals.health / s.vitals.max,
		lightChargeFraction = if hasLight then s.profile.lightCharge / 100 else 0,
		medicalItemCount = med,
		exertionFraction = s.exertion,
		secondsSinceThreat = os.clock() - s.lastThreatAt,
		partySize = #services.PartyService.members(player),
		inShelter = s.insideShelterId ~= nil or s.regionId ~= "R01",
	})
end

-- Threshold drops as pressure rises; callers ask whether a damaging threat may begin now.
function DirectorService.mayEngage(player: Player, threshold: number): boolean
	local s = services.PlayerService.get(player)
	if not s or s.insideShelterId or s.vitals.condition == "downed" then
		return false
	end
	return Director.mayStartDamagingThreat(Config.Director, victim(player), activeDamaging, os.clock(), DirectorService.pressure(player), threshold)
end

function DirectorService.beginThreat(player: Player)
	local v = victim(player)
	v.activeDamagingThreats += 1
	activeDamaging += 1
	local s = services.PlayerService.get(player)
	if s then
		s.lastThreatAt = os.clock()
	end
end

function DirectorService.endThreat(player: Player, wasChase: boolean)
	local v = victim(player)
	if v.activeDamagingThreats > 0 then
		v.activeDamagingThreats -= 1
		activeDamaging = math.max(0, activeDamaging - 1)
	end
	if wasChase then
		Director.afterChase(Config.Director, v, os.clock())
	end
end

function DirectorService.afterRescue(player: Player)
	Director.afterRescue(Config.Director, victim(player), os.clock())
end

function DirectorService.stalkDistance(player: Player): number
	return Director.stalkDistance(DirectorService.pressure(player), 70, 22)
end

function DirectorService.init(s)
	services = s
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		local v = victims[p]
		if v then
			activeDamaging = math.max(0, activeDamaging - v.activeDamagingThreats)
		end
		victims[p] = nil
	end)
end

function DirectorService.start()
	-- Debug/telemetry: pressure per player every few seconds (shown only in the developer HUD toggle).
	task.spawn(function()
		while true do
			task.wait(Config.Director.tickSeconds * 2)
			for p in services.PlayerService.all() do
				services.PlayerService.send(p, "debugPressure", { pressure = DirectorService.pressure(p) })
			end
		end
	end)
end

return DirectorService
