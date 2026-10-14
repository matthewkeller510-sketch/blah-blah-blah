--!strict
-- C04 Chalk Hand (marking anomaly, harmless; docs/MILESTONE-3.md 4.3). In R05, near one of the player's OWN chalk
-- marks, at most once per Config.Creatures.chalkHandIntervalSeconds, a thin hand withdraws into a crack
-- (chalkhand_scratch) and a fake reversed arrow appears beside the real mark. The fake is a private cosmetic sent on
-- the "falseMark" channel to that player only: it is never a NavRecord, never on the "nav" channel, and nothing here
-- writes, moves, deletes or transfers any saved marker (F09, F21). It expires after 90 s. It is never drawn on a
-- variable pocket's surface, which a pocket change could replace under it.
-- Requests (registered by CreatureService): chalkhand.inspect {id} and chalkhand.compare {id}.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local NavRecords = require(Shared.Logic.NavRecords)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local ChalkHand = {}
local services: any

local HAND = WorldDefs.Creatures.C04_ChalkHand
local H = CreatureRules.ChalkHand
local TICK_SECONDS = 0.5

type Mark = { id: string, position: Vector3, createdAt: number, seen: boolean }
type Chalk = { position: Vector3, normal: Vector3 }

-- weak keys: a write during a departing player's final save never pins the Player (review R2 finding 12)
local marks: { [Player]: { [string]: Mark } } = setmetatable({}, { __mode = "k" }) :: any
local lastAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
local seq = 0
local acc = 0

local function vecOf(t: any): Vector3?
	if typeof(t) == "Vector3" then
		return t
	end
	if type(t) == "table" and type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number" then
		return Vector3.new(t.x, t.y, t.z)
	end
	return nil
end

-- Read-only positions of the player's own chalk marks in R05. Uses NavigationService.ownRecords (world package
-- contract); until it exists, reads the owner's own saved page without changing anything.
local function ownChalk(player: Player): { Chalk }
	local out: { Chalk } = {}
	local list: any = nil
	local nav = services.NavigationService
	if nav and nav.ownRecords then
		local ok, res = pcall(nav.ownRecords, player, H.regionId)
		list = if ok then res else nil
	else
		local s = services.PlayerService.get(player)
		if s and type(s.profile.nav) == "table" and type(s.profile.nav.pages) == "table" then
			list = NavRecords.inRegion(s.profile.nav, H.regionId)
		end
	end
	if type(list) ~= "table" then
		return out
	end
	for _, r in list do
		if type(r) == "table" and r.kind == "chalk" then
			local pos = vecOf(r.position)
			if pos then
				table.insert(out, { position = pos, normal = vecOf(r.facing) or Vector3.yAxis })
			end
		end
	end
	return out
end

local function positions(list: { Chalk }): { CreatureRules.V3 }
	local out = {}
	for _, c in list do
		table.insert(out, Common.v3(c.position))
	end
	return out
end

local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include

-- Inside a variable pocket's bounds (review finding 14): a pocket change would leave a private fake floating in void
-- or inside a new wall, so the hand never draws there and never imitates a mark there.
local function inPocket(p: CreatureRules.V3): boolean
	return WorldDefs.pocketAt(p) ~= nil
end

-- Finds a spot on a real surface near (never on) the imitated mark, never on a pocket surface. Returns (position,
-- normal) or nil.
local function placeFake(mark: Chalk, own: { CreatureRules.V3 }): (Vector3?, Vector3?)
	surfaceParams.FilterDescendantsInstances = { services.WorldBuilder.root() }
	local n = mark.normal
	for _, c in CreatureRules.fakeMarkCandidates(Common.v3(mark.position), Common.v3(n)) do
		local cand = Vector3.new(c.x, c.y, c.z)
		local hit = workspace:Raycast(cand + n * 1.5, -n * 3, surfaceParams)
		if
			hit
			and hit.Normal:Dot(n) > 0.8
			and (hit.Position - cand).Magnitude < 1.2
			and CreatureRules.fakeSpotAllowed(Common.v3(hit.Position), own, inPocket)
		then
			return hit.Position, hit.Normal
		end
	end
	return nil, nil
end

local function liveCount(p: Player): number
	local n = 0
	local list = marks[p]
	if list then
		for _ in list do
			n += 1
		end
	end
	return n
end

local function spawnFor(p: Player, imitated: Chalk, own: { Chalk }): boolean
	local pos, normal = placeFake(imitated, positions(own))
	if not pos or not normal then
		return false
	end
	seq += 1
	local id = "fm" .. tostring(seq)
	local list = marks[p]
	if not list then
		list = {}
		marks[p] = list
	end
	list[id] = { id = id, position = pos, createdAt = os.clock(), seen = false }
	-- a reversed arrow from the existing chalk preset set; rendered privately by CreatureFX
	services.PlayerService.send(p, "falseMark", {
		id = id,
		position = pos,
		normal = normal,
		content = "arrow",
		reversed = true,
		ttl = H.ttl,
	})
	Common.cueTo(p, "chalkhand_scratch", pos)
	return true
end

function ChalkHand.tick(dt: number)
	acc += dt
	if acc < TICK_SECONDS then
		return
	end
	local step = acc
	acc = 0
	local now = os.clock()
	for p, sess in services.PlayerService.all() do
		local pos = services.PlayerService.position(p)
		-- expire, and grant "seen" the first time the player is close to a shown false mark
		local list = marks[p]
		if list then
			for id, mk in list do
				if now - mk.createdAt > H.ttl then
					list[id] = nil
				elseif not mk.seen and pos and (pos - mk.position).Magnitude <= H.seenRadius then
					mk.seen = true
					Common.evidence(p, HAND, "seen")
				end
			end
			if next(list) == nil then
				marks[p] = nil
			end
		end
		-- a new false mark: R05, active (not hidden, downed or sheltered), interval passed, own chalk within 30
		if
			pos
			and sess.regionId == H.regionId
			and Common.active(p, sess)
			and now - (lastAt[p] or -math.huge) >= Config.Creatures.chalkHandIntervalSeconds
			and liveCount(p) < H.maxLive
			and math.random() < CreatureRules.chance(H.ratePerSecond, step)
		then
			local own = ownChalk(p)
			local mine = positions(own)
			local target = CreatureRules.chalkHandTarget(
				sess.regionId,
				now,
				lastAt[p],
				Config.Creatures.chalkHandIntervalSeconds,
				Common.v3(pos),
				mine,
				inPocket
			)
			local index = if target then table.find(mine, target) else nil
			if index and spawnFor(p, own[index], own) then
				lastAt[p] = now
			end
		end
	end
end

local function lookup(player: Player, payload: any): (Mark?, Vector3?)
	local id = if type(payload) == "table" then payload.id else nil
	if type(id) ~= "string" or #id > 64 then
		return nil, nil
	end
	local list = marks[player]
	local mk = list and list[id]
	local pos = services.PlayerService.position(player)
	return mk, pos
end

-- "This mark is not in your notebook." Valid only for a mark this player was shown, still live, from close by.
function ChalkHand.inspect(player: Player, payload: any)
	local mk, pos = lookup(player, payload)
	if not mk or not pos then
		return
	end
	if not CreatureRules.falseMarkValid(mk.createdAt, os.clock(), (pos - mk.position).Magnitude, H.inspectRange) then
		return
	end
	if not mk.seen then
		mk.seen = true
		Common.evidence(player, HAND, "seen")
	end
	Common.evidence(player, HAND, "noticed_false_mark")
	Common.evidence(player, HAND, "checked_notebook")
end

-- "Compare with my own mark": confirmed only with one of the player's own chalk marks within 40 studs.
function ChalkHand.compare(player: Player, payload: any)
	local mk, pos = lookup(player, payload)
	if not mk or not pos then
		return
	end
	if not CreatureRules.falseMarkValid(mk.createdAt, os.clock(), (pos - mk.position).Magnitude, H.compareRadius) then
		return
	end
	if CreatureRules.compareAllowed(Common.v3(pos), positions(ownChalk(player))) then
		Common.evidence(player, HAND, "confirmed_own_mark")
		services.PlayerService.notify(
			player,
			"Your own mark is where you left it, in your notebook. The reversed arrow is not yours.",
			"info"
		)
	else
		services.PlayerService.notify(
			player,
			string.format("None of your own chalk marks is within %d studs to compare with.", H.compareRadius),
			"info"
		)
	end
end

-- Only exists on its owner's client: nothing on the server to aim a tool at.
function ChalkHand.targets(): { Common.Target }
	return {}
end

function ChalkHand.onPlayerRemoving(p: Player)
	marks[p] = nil
	lastAt[p] = nil
end

function ChalkHand.init(s)
	services = s
end

function ChalkHand.start() end

return ChalkHand
