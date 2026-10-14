--!strict
-- Server entry point. Initializes services in dependency order and routes validated client requests.
-- Clients request; the server validates every change to value, health or ownership (section 19).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local Net = require(Shared.Net)

local Services = script.Parent:WaitForChild("Services")

local services = {
	WorldBuilder = require(Services.WorldBuilder),
	SaveService = require(Services.SaveService),
	PlayerService = require(Services.PlayerService),
	PartyService = require(Services.PartyService),
	ShelterService = require(Services.ShelterService),
	NavigationService = require(Services.NavigationService),
	RecoveryService = require(Services.RecoveryService),
	DiscoveryService = require(Services.DiscoveryService),
	DirectorService = require(Services.DirectorService),
	CreatureService = require(Services.CreatureService),
	MissionService = require(Services.MissionService),
	EconomyService = require(Services.EconomyService),
	PuzzleService = require(Services.PuzzleService),
	StoryService = require(Services.StoryService),
}

local ORDER = {
	"WorldBuilder", "SaveService", "PartyService", "ShelterService", "NavigationService", "RecoveryService",
	"DiscoveryService", "DirectorService", "CreatureService", "PuzzleService", "MissionService", "EconomyService",
	"StoryService",
	"PlayerService", -- last: starts accepting players once everything else is ready
}

for _, name in ORDER do
	(services :: any)[name].init(services)
end
for _, name in ORDER do
	(services :: any)[name].start()
end

-- Rate limiting: token bucket per player per category ----------------------------------------------
type Bucket = { tokens: number, last: number }
local buckets: { [Player]: { [string]: Bucket } } = {}
local RATES = {
	intents = 20,
	interact = Config.RateLimit.interactPerSecond,
	place = Config.RateLimit.placePerSecond,
	party = Config.RateLimit.partyPerSecond,
}

local function allow(player: Player, cat: string): boolean
	local per = buckets[player]
	if not per then
		per = {}
		buckets[player] = per
	end
	local rate = RATES[cat] or 4
	local b = per[cat]
	local now = os.clock()
	if not b then
		b = { tokens = rate, last = now }
		per[cat] = b
	end
	b.tokens = math.min(rate, b.tokens + (now - b.last) * rate)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(p)
	buckets[p] = nil
end)

local function str(v: any): string?
	return if type(v) == "string" and #v <= 64 then v else nil
end
local function num(v: any): number?
	return if type(v) == "number" and v == v and math.abs(v) < 1e15 then v else nil
end
local function playerById(v: any): Player?
	local id = num(v)
	return id and Players:GetPlayerByUserId(id) or nil
end

local PS, PartyS, ShelterS, NavS = services.PlayerService, services.PartyService, services.ShelterService, services.NavigationService

local handlers: { [string]: { cat: string, fn: (Player, any) -> () } } = {
	["intents"] = { cat = "intents", fn = function(p, d) PS.setIntents(p, d) end },
	["throw"] = { cat = "interact", fn = function(p) PS.throwStone(p) end },
	["onboard.choose"] = { cat = "interact", fn = function(p, d) local c = str(d.className) if c then PS.chooseStartingClass(p, c) end end },
	["hide.exit"] = { cat = "interact", fn = function(p) PS.unhide(p) end },
	["light.toggle"] = { cat = "interact", fn = function(p) PS.toggleLight(p) end },
	["light.swap"] = { cat = "interact", fn = function(p) PS.swapCell(p) end },
	["light.equip"] = { cat = "interact", fn = function(p, d) local id = str(d.itemId) if id then PS.equipLight(p, id) end end },
	["med.use"] = { cat = "interact", fn = function(p, d)
		local id = str(d.itemId)
		if id then PS.useMedical(p, id, playerById(d.targetUserId)) end
	end },
	["rescue.stabilize"] = { cat = "interact", fn = function(p, d) local t = playerById(d.targetUserId) if t then PS.stabilize(p, t) end end },
	["rescue.carry"] = { cat = "interact", fn = function(p, d) local t = playerById(d.targetUserId) if t then PS.startCarry(p, t) end end },
	["rescue.drop"] = { cat = "interact", fn = function(p) PS.dropCarry(p) end },
	["tool.use"] = { cat = "interact", fn = function(p, d) local id = str(d.itemId) if id then services.CreatureService.useTool(p, id) end end },
	["nav.place"] = { cat = "place", fn = function(p, d) NavS.place(p, d) end },
	["nav.retrieve"] = { cat = "place", fn = function(p, d)
		local o, r = num(d.ownerId), str(d.recordId)
		if o and r then NavS.retrieve(p, o, r) end
	end },
	["nav.partyRecovery"] = { cat = "interact", fn = function(p, d) local r = str(d.recordId) if r then NavS.setPartyRecovery(p, r, d.allow == true) end end },
	["bag.recover"] = { cat = "interact", fn = function(p, d)
		local o, k = num(d.ownerId), str(d.kind)
		if o and k then services.RecoveryService.recover(p, o, k) end
	end },
	["bag.revoke"] = { cat = "interact", fn = function(p, d)
		local k, u = str(d.kind), num(d.userId)
		if k and u then services.RecoveryService.revoke(p, k, u) end
	end },
	["shelter.upgrade"] = { cat = "interact", fn = function(p, d) local u = str(d.upgradeId) if u then ShelterS.upgrade(p, u) end end },
	["shelter.craft"] = { cat = "interact", fn = function(p, d) local r = str(d.recipeId) if r then ShelterS.craft(p, r) end end },
	["shelter.class"] = { cat = "interact", fn = function(p, d) local c = str(d.className) if c then ShelterS.changeClass(p, c) end end },
	["shelter.escrow"] = { cat = "interact", fn = function(p) services.RecoveryService.claimEscrow(p) ShelterS.pushPanel(p) end },
	["shelter.exit"] = { cat = "interact", fn = function(p) ShelterS.exit(p) end },
	["shelter.panel"] = { cat = "interact", fn = function(p) ShelterS.pushPanel(p) end },
	["party.invite"] = { cat = "party", fn = function(p, d) local id = num(d.userId) if id then PartyS.invite(p, id) end end },
	["party.accept"] = { cat = "party", fn = function(p, d) local id = num(d.fromUserId) if id then PartyS.accept(p, id) end end },
	["party.decline"] = { cat = "party", fn = function(p, d) local id = num(d.fromUserId) if id then PartyS.decline(p, id) end end },
	["party.leave"] = { cat = "party", fn = function(p) PartyS.leave(p) end },
	["party.remove"] = { cat = "party", fn = function(p, d) local id = num(d.userId) if id then PartyS.remove(p, id) end end },
	["party.ping"] = { cat = "party", fn = function(p) PartyS.ping(p) end },
	["mission.list"] = { cat = "interact", fn = function(p) services.MissionService.list(p) end },
	["mission.accept"] = { cat = "interact", fn = function(p, d) local id = str(d.id) if id then services.MissionService.accept(p, id) end end },
	["mission.abandon"] = { cat = "interact", fn = function(p) services.MissionService.abandon(p) end },
	["shop.buy"] = { cat = "interact", fn = function(p, d) local id = str(d.itemId) if id then services.EconomyService.buy(p, id) end end },
	["shop.sell"] = { cat = "interact", fn = function(p, d) local id = str(d.itemId) if id then services.EconomyService.sell(p, id) end end },
	["shop.product"] = { cat = "interact", fn = function(p, d) local id = num(d.productId) if id then services.EconomyService.promptProduct(p, id) end end },
}

Net.event(Net.Names.State) -- ensure it exists before clients connect
Net.event(Net.Names.Request).OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	local h = type(action) == "string" and handlers[action]
	if not h then
		return
	end
	if not PS.get(player) then
		return
	end
	if not allow(player, h.cat) then
		return
	end
	if type(payload) ~= "table" then
		payload = {}
	end
	local ok, err = pcall(h.fn, player, payload)
	if not ok then
		warn(string.format("[Request] %s from %d failed: %s", action, player.UserId, tostring(err)))
	end
end)
