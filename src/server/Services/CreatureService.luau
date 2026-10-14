--!strict
-- Creatures (section 10). Each creature lives in its own module under Services/Creatures; this service wires them:
-- one tick loop (each creature isolated in its own pcall), noise, player tools, research and requests.
--   C01 Sidelooker (harmless, private sighting)     C05 Scrabbler (vulnerable predator, killable)
--   C02 Borrowed Miner (harmless mimic)             C06 Wader (water-sensitive stalker, unkillable)
--   C03 Wick Moth (harmless light nuisance)         C07 Knocker (line-charge threat, unkillable)
--   C04 Chalk Hand (harmless false marks, private)  C08 Lantern Thief (director-driven stalker, unkillable)
-- Placeholder primitive bodies; production rigs are PLANNED. Every damaging encounter has a readable cue first and an
-- escape route (T04, T05) and goes through the director (one damaging threat per victim, server cap, recovery
-- intervals). Hidden players (F07) cannot be sensed; nothing acts on a player inside a shelter interior.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Progress = require(Shared.Logic.Progress)
local Inventory = require(Shared.Logic.Inventory)
local CreatureRules = require(Shared.Logic.CreatureRules)

local Creatures = script.Parent.Creatures
local Common = require(Creatures.Common)
local Sidelooker = require(Creatures.Sidelooker)
local Scrabbler = require(Creatures.Scrabbler)
local Wader = require(Creatures.Wader)
local Knocker = require(Creatures.Knocker)
local BorrowedMiner = require(Creatures.BorrowedMiner)
local WickMoth = require(Creatures.WickMoth)
local ChalkHand = require(Creatures.ChalkHand)
local LanternThief = require(Creatures.LanternThief)

local CreatureService = {}
local services: any

type Module = {
	init: (any) -> (),
	start: () -> (),
	tick: (number) -> (),
	targets: () -> { Common.Target },
	onPlayerRemoving: (Player) -> (),
}

local MODULES: { { name: string, m: Module } } = {
	{ name = "Scrabbler", m = Scrabbler },
	{ name = "Knocker", m = Knocker },
	{ name = "Wader", m = Wader },
	{ name = "Sidelooker", m = Sidelooker },
	{ name = "BorrowedMiner", m = BorrowedMiner },
	{ name = "WickMoth", m = WickMoth },
	{ name = "ChalkHand", m = ChalkHand },
	{ name = "LanternThief", m = LanternThief },
}

local TOOL_COOLDOWN = 0.8
local lastSwing: { [Player]: number } = {}
local lastWarn: { [string]: number } = {}

-- Research: the existing path (contract API). Unknown creature ids are ignored.
function CreatureService.research(player: Player, creatureId: string, evidenceId: string)
	local def = WorldDefs.creatureById(creatureId)
	if def then
		Common.evidence(player, def, evidenceId)
	end
end

-- Noise entry point: player splashes (source = player) and thrown stones (source = nil, thrower = player).
function CreatureService.noise(pos: Vector3, kind: string, loudness: number, source: Player?, thrower: Player?)
	if kind == "splash" then
		Wader.hear(pos, loudness, source, thrower)
	end
	Scrabbler.noise(pos, kind, source)
end

-- The creature the player is aiming at: within range, inside the aim cone and in clear line of sight (never through
-- rock or round a corner). Threats come before harmless phenomena, so a nearer roost or miner never absorbs a swing
-- or stun meant for a threat; the nearest of each (review R2 findings 10 and 11).
local function facing(player: Player, range: number): Common.Target?
	local head = Common.head(player)
	if not head then
		return nil
	end
	local cands: { Common.Target } = {}
	local order: { CreatureRules.ToolCandidate } = {}
	for _, entry in MODULES do
		for _, t in entry.m.targets() do
			local to = t.part.Position - head.Position
			local d = to.Magnitude
			if d < range and d > 0.01 and head.CFrame.LookVector:Dot(to.Unit) > 0.6 then
				table.insert(cands, t)
				table.insert(order, { harmless = t.kind == "harmless", dist = d })
			end
		end
	end
	for _, i in CreatureRules.toolTargetOrder(order) do
		local t = cands[i]
		if Common.lineOfSight(head.Position, t.part.Position) then
			return t
		end
	end
	return nil
end

local function nothingToStrike(player: Player)
	services.PlayerService.notify(player, "There is nothing there to strike: it passes through like dust.", "info")
end

function CreatureService.useTool(player: Player, itemId: string)
	local sess = services.PlayerService.get(player)
	if
		not sess
		or Inventory.count(sess.profile.inventory, itemId) < 1
		or sess.vitals.condition == "downed"
		or sess.hiddenAt
		or sess.carrying
		or sess.carriedBy
	then
		return
	end
	if itemId ~= "tool.iron_bar" and itemId ~= "tool.stun_device" then
		return
	end
	local now = os.clock()
	if now - (lastSwing[player] or 0) < TOOL_COOLDOWN then
		return
	end
	lastSwing[player] = now
	if itemId == "tool.iron_bar" then
		local target = facing(player, 8)
		if not target then
			if WickMoth.attached(player) then
				nothingToStrike(player) -- swinging at the moths around your own light
			end
			return
		end
		if target.kind == "killable" and target.onBar then
			target.onBar(player)
		elseif target.kind == "unkillable" then
			-- Ordinary weapons fail visibly against an unkillable creature (T05).
			services.PlayerService.send(player, "cue", { id = "weapon_ineffective", position = target.part.Position })
			services.PlayerService.notify(player, "The bar glances off. It cannot be hurt like this.", "warn")
		else
			nothingToStrike(player) -- a harmless phenomenon: no fake hit
		end
		return
	end
	-- stun device: a charge is used only when the stun takes effect
	local charges = sess.profile.toolCharges[itemId]
	if charges == nil then
		local def = ItemDefs.get(itemId)
		charges = (def and def.stunCharges) or 3
	end
	if charges <= 0 then
		services.PlayerService.notify(player, "The stun device is out of charge.", "warn")
		return
	end
	local target = facing(player, 14)
	if not target then
		if WickMoth.attached(player) then
			nothingToStrike(player)
		end
		return
	end
	if target.kind == "harmless" or not target.onStun then
		nothingToStrike(player)
		return
	end
	if target.onStun(player) then
		sess.profile.toolCharges[itemId] = charges - 1
		services.SaveService.markDirty(player)
		services.PlayerService.send(player, "cue", { id = "stun_fired" })
	end
end

local function warnThrottled(name: string, err: any)
	local now = os.clock()
	if now - (lastWarn[name] or -math.huge) > 10 then
		lastWarn[name] = now
		warn("[CreatureService] " .. name .. ": " .. tostring(err))
	end
end

function CreatureService.init(s)
	services = s
	Common.init(s)
	for _, entry in MODULES do
		entry.m.init(s)
	end
	for _, def in WorldDefs.Creatures do
		if def.status == "SLICE" and #def.researchEvidence > #Progress.RESEARCH_STAGES then
			warn("[CreatureService] " .. def.id .. " lists more evidence than there are research stages")
		end
	end
	-- C04 Chalk Hand requests (payloads validated in ChalkHand: id is a string of at most 64 characters)
	s.Router.register("chalkhand.inspect", "interact", function(p: Player, d: any)
		ChalkHand.inspect(p, d)
	end)
	s.Router.register("chalkhand.compare", "interact", function(p: Player, d: any)
		ChalkHand.compare(p, d)
	end)
end

function CreatureService.start()
	for _, entry in MODULES do
		entry.m.start()
	end
	-- C02: a verified party ping near the Borrowed Miner makes it fade (it never answers a verification).
	if services.PartyService and services.PartyService.onPing then
		services.PartyService.onPing(function(player: Player, position: Vector3)
			local ok, err = pcall(BorrowedMiner.onPing :: any, player, position)
			if not ok then
				warnThrottled("BorrowedMiner.onPing", err)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
		for _, entry in MODULES do
			local ok, err = pcall(entry.m.onPlayerRemoving :: any, p)
			if not ok then
				warnThrottled(entry.name, err)
			end
		end
	end)
	local TICK = 1 / 15
	task.spawn(function()
		while true do
			local dt = task.wait(TICK)
			debug.profilebegin("Creatures")
			local okGates, errGates = pcall(Common.refreshGates :: any)
			if not okGates then
				warnThrottled("gates", errGates)
			end
			-- one creature's error never stops the others
			for _, entry in MODULES do
				local ok, err = pcall(entry.m.tick :: any, dt)
				if not ok then
					warnThrottled(entry.name, err)
				end
			end
			debug.profileend()
		end
	end)
end

return CreatureService
