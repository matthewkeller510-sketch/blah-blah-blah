--!strict
-- Server encounter director (section 11, PROPOSED). Computes per-player pressure from region danger, health,
-- useful light charge, medical supplies, recent exertion, group context and time since a threat.
-- It never reads spending, Robux balance or purchase history.
-- Every damaging creature (Scrabbler, Wader, Knocker, Lantern Thief) asks mayEngage, then beginThreat, then calls
-- endThreat exactly once, so no two of them stack on one victim and the server cap holds.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Director = require(Shared.Logic.Director)
local Inventory = require(Shared.Logic.Inventory)

local DirectorService = {}
local services: any

local GRACE_SECONDS = 30 -- a calm first half-minute after joining
local PRESSURE_CACHE_SECONDS = 0.25 -- several creatures ask every tick; compute once per player per quarter second

-- Weak keys (review R2 finding 12): a departing player's session outlives PlayerRemoving while the final save yields,
-- so a late write must never pin the Player. Nothing is computed or engaged for a player who has left (Parent nil).
local victims: { [Player]: Director.VictimRecord } = setmetatable({}, { __mode = "k" }) :: any
local activeDamaging = 0
local pressureCache: { [Player]: { value: number, at: number } } = setmetatable({}, { __mode = "k" }) :: any

local function victim(p: Player): Director.VictimRecord
	local v = victims[p]
	if not v then
		v = { activeDamagingThreats = 0, cooldownUntil = os.clock() + GRACE_SECONDS }
		victims[p] = v
	end
	return v
end

local function isMedical(id: string): boolean
	local d = ItemDefs.get(id)
	return d ~= nil and d.category == "medical"
end

local function computePressure(s: any, player: Player): number
	local r = WorldDefs.region(s.regionId)
	local counts: { [string]: number } = {}
	for id in s.profile.inventory do
		counts[id] = Inventory.count(s.profile.inventory, id)
	end
	local hasLight = s.profile.equippedLight ~= nil
		and Inventory.count(s.profile.inventory, s.profile.equippedLight) > 0
	return Director.pressure(Config.Director, {
		regionDanger = r and r.danger or 0,
		healthFraction = s.vitals.health / math.max(1, s.vitals.max),
		lightChargeFraction = if hasLight then s.profile.lightCharge / 100 else 0,
		medicalItemCount = Director.medicalCount(counts, isMedical),
		exertionFraction = s.exertion,
		secondsSinceThreat = os.clock() - s.lastThreatAt,
		partySize = #services.PartyService.members(player),
		inShelter = s.insideShelterId ~= nil or not WorldDefs.isTunnel(s.regionId),
	})
end

function DirectorService.pressure(player: Player): number
	local s = services.PlayerService.get(player)
	if not s or not player.Parent then
		return 0
	end
	local now = os.clock()
	local c = pressureCache[player]
	if c and now - c.at < PRESSURE_CACHE_SECONDS then
		return c.value
	end
	local value = computePressure(s, player)
	pressureCache[player] = { value = value, at = now }
	return value
end

-- Threshold drops as pressure rises; callers ask whether a damaging threat may begin now. Shelters, hidden (F07),
-- downed and dead players and non-tunnel regions are always refused here, whatever the caller checked.
function DirectorService.mayEngage(player: Player, threshold: number): boolean
	local s = services.PlayerService.get(player)
	if
		not s
		or not player.Parent -- leaving: its session lives on only for the final save
		or s.insideShelterId
		or s.hiddenAt
		or s.vitals.condition == "downed"
		or s.vitals.condition == "dead"
		or not WorldDefs.isTunnel(s.regionId)
	then
		return false
	end
	return Director.mayStartDamagingThreat(
		Config.Director,
		victim(player),
		activeDamaging,
		os.clock(),
		DirectorService.pressure(player),
		threshold
	)
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

-- Ends one damaging threat on `player`. A chase starts the chase recovery interval; any other end still spaces the
-- next threat by minSecondsBetweenThreats. `recoverySeconds` adds a specific interval (e.g. after a Lantern Thief
-- strike). A player who already left has no record any more: nothing is re-created for them.
function DirectorService.endThreat(player: Player, wasChase: boolean, recoverySeconds: number?)
	local v = victims[player]
	if not v then
		return
	end
	if v.activeDamagingThreats > 0 then
		v.activeDamagingThreats -= 1
		activeDamaging = math.max(0, activeDamaging - 1)
	end
	local now = os.clock()
	if wasChase then
		Director.afterChase(Config.Director, v, now)
	else
		Director.afterThreat(Config.Director, v, now)
	end
	if recoverySeconds then
		Director.recover(v, now, recoverySeconds)
	end
end

-- Damaging threats currently engaged on this player (a charge never adds a second one to a bystander).
function DirectorService.activeThreats(player: Player): number
	local v = victims[player]
	return if v then v.activeDamagingThreats else 0
end

function DirectorService.afterRescue(player: Player)
	if not player.Parent then
		return
	end
	Director.afterRescue(Config.Director, victim(player), os.clock())
end

function DirectorService.stalkDistance(player: Player): number
	return Director.stalkDistance(DirectorService.pressure(player), 70, 22)
end

function DirectorService.init(s)
	services = s
	-- The calm first half-minute starts when the player joins, not at the first creature that notices them.
	Players.PlayerAdded:Connect(function(p)
		victim(p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		local v = victims[p]
		if v then
			activeDamaging = math.max(0, activeDamaging - v.activeDamagingThreats)
		end
		victims[p] = nil
		pressureCache[p] = nil
	end)
end

function DirectorService.start()
	for _, p in Players:GetPlayers() do
		victim(p)
	end
	-- Debug/telemetry: pressure per player every few seconds (shown only in the developer HUD toggle).
	task.spawn(function()
		while true do
			task.wait(Config.Director.tickSeconds * 2)
			for p in services.PlayerService.all() do
				if p.Parent then
					services.PlayerService.send(p, "debugPressure", { pressure = DirectorService.pressure(p) })
				end
			end
		end
	end)
end

return DirectorService
