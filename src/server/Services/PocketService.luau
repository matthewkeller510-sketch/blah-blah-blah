--!strict
-- Variable pockets (section 04, owner rule F08; docs/MILESTONE-3.md section 3, D31).
-- Each pocket's version is server state that follows a deterministic schedule (Logic/Pockets.targetVersion), so
-- every server converges on the same version. A change happens only when the pocket is empty (no player, no
-- PocketBlocker, no lit flare, no online owner's bag or rope inside its bounds plus a margin), is telegraphed for
-- Config.Pockets.telegraphSeconds at both mouths (essential captioned cue, glowing threshold plates, client dust),
-- and aborts if anything enters meanwhile. Every version joins the same two mouths, so an escape path always exists.
-- After a change, records of online owners that were placed in the old version migrate to the pocket's documented
-- anchor (never deleted); offline owners' records migrate lazily when their profile is next used here.
-- PK3 is also puzzle P06 (Impossible doorway): walking through the stable door verifies it (personal discovery).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Data.Config)
local WorldDefs = require(Shared.Data.WorldDefs)
local Pockets = require(Shared.Logic.Pockets)
Pockets.bind(WorldDefs)

local PocketService = {}
local services: any

type PocketState = {
	def: WorldDefs.PocketDef,
	current: string,
	phase: string, -- "idle" | "telegraph"
	target: string?, -- version being telegraphed
	telegraphEnds: number, -- os.clock() when the telegraph completes
	telegraphEndsServer: number, -- the same moment in workspace:GetServerTimeNow() (for clients)
	nextCheck: number, -- os.clock() of the next idle check
}

local states: { [string]: PocketState } = {}
local order: { string } = {} -- pocket ids, sorted, so the service behaves the same on every server
local listeners: { (string, string, string) -> () } = {}
local stateSent: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local verifiedAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

local P06_DISCOVERY = "R05.p06_verified"
local P06_LABEL = "Impossible doorway: stable route verified"
local VERIFY_REPEAT_SECONDS = 15 -- the success caption repeats at most this often per player

local function v3(p: Vector3): Pockets.V3
	return { x = p.X, y = p.Y, z = p.Z }
end

local function vec(t: Pockets.V3): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

-- Contract API (docs/MILESTONE-3.md section 5) -----------------------------------------------------------

-- Current version id of a pocket on this server (e.g. "direct"); nil for an unknown pocket.
function PocketService.versionOf(pocketId: string): string?
	local st = states[pocketId]
	return if st then st.current else nil
end

-- The pocket whose build area contains a world position (no margin), or nil. Same predicate as every record tag
-- (Pockets.containing: build area only, ids in sorted order), so the crash checkpoint (PlayerService.checkpointFor)
-- tags exactly like navigation records and bags: a mouth doorway is static, and where two pockets' bounds overlap
-- the answer never depends on table iteration order.
function PocketService.pocketAt(position: Vector3): string?
	local pk = Pockets.containing(v3(position))
	return if pk then pk.id else nil
end

-- Subscribe to version changes: fn(pocketId, oldVersion, newVersion). Called after geometry and records moved.
function PocketService.onChanged(fn: (string, string, string) -> ())
	table.insert(listeners, fn)
end

-- "idle" or "telegraph" (a change is pending and will happen unless something enters).
function PocketService.phaseOf(pocketId: string): string?
	local st = states[pocketId]
	return if st then st.phase else nil
end

-- Blockers (rule 2) -------------------------------------------------------------------------------------

local function blockedBy(def: WorldDefs.PocketDef): string?
	local characters: { Pockets.V3 } = {}
	for _, p in Players:GetPlayers() do
		-- every character counts: alive, downed, hidden (anchored in a niche) or carried (welded to a carrier)
		local c = p.Character
		local root = c and c:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(characters, v3(root.Position))
		end
	end
	local tagged: { Pockets.V3 } = {}
	for _, inst in CollectionService:GetTagged("PocketBlocker") do
		if inst:IsA("BasePart") then
			table.insert(tagged, v3(inst.Position))
		elseif inst:IsA("Model") then
			table.insert(tagged, v3(inst:GetPivot().Position))
		end
	end
	-- PROPOSED: a lit flare blocks too, so geometry never changes under a burning flare (it burns ItemDefs
	-- flareSeconds, 45 s, so the delay is short)
	local flares: { Pockets.V3 } = {}
	for _, f in services.PlayerService.activeFlares() do
		table.insert(flares, v3(f.position))
	end
	local margin = Config.Pockets.occupancyMargin
	local reason = Pockets.blocker(def, { characters = characters, tagged = tagged, flares = flares }, margin)
	if reason then
		return reason
	end
	if services.RecoveryService.bagBlocks(def) then
		return "bag"
	end
	if services.NavigationService.ropeBlocks(def) then
		return "rope"
	end
	return nil
end

-- Telegraph, swap and client state ----------------------------------------------------------------------

local function stateFor(st: PocketState): any
	local mouths = {}
	for _, m in Pockets.mouthPoints(st.def) do
		table.insert(mouths, vec(m))
	end
	return {
		id = st.def.id,
		version = st.current,
		phase = st.phase,
		endsAt = if st.phase == "telegraph" then st.telegraphEndsServer else nil,
		mouths = mouths,
	}
end

local function broadcast(st: PocketState)
	local payload = stateFor(st)
	for player in services.PlayerService.all() do
		services.PlayerService.send(player, "pocketState", payload)
	end
end

-- Cue to every player currently in the pocket's region; `each` sends one per mouth, otherwise the nearest mouth.
local function cueRegion(st: PocketState, cueId: string, each: boolean)
	local mouths = Pockets.mouthPoints(st.def)
	for player, s in services.PlayerService.all() do
		if s.regionId == st.def.regionId then
			if each then
				for _, m in mouths do
					services.PlayerService.send(player, "cue", { id = cueId, position = vec(m) })
				end
			else
				local pos = services.PlayerService.position(player)
				local best = mouths[1]
				if pos then
					for _, m in mouths do
						if (vec(m) - pos).Magnitude < (vec(best) - pos).Magnitude then
							best = m
						end
					end
				end
				services.PlayerService.send(player, "cue", { id = cueId, position = vec(best) })
			end
		end
	end
end

local function startTelegraph(st: PocketState, target: string)
	local secs = Config.Pockets.telegraphSeconds
	st.phase = "telegraph"
	st.target = target
	st.telegraphEnds = os.clock() + secs
	st.telegraphEndsServer = workspace:GetServerTimeNow() + secs
	services.WorldBuilder.setThresholdShifting(st.def.id, true)
	cueRegion(st, "pocket_shift", true)
	broadcast(st)
end

local function endTelegraph(st: PocketState)
	st.phase = "idle"
	st.target = nil
	services.WorldBuilder.setThresholdShifting(st.def.id, false)
	st.nextCheck = os.clock() + Config.Pockets.checkSeconds
end

-- Rule 6: records of online owners placed in the old version move to the documented anchor now.
local function migrateOnline()
	for player in services.PlayerService.all() do
		services.NavigationService.migrateStale(player)
		services.RecoveryService.migrateStale(player)
	end
end

-- Swaps geometry. Runs without yielding between the final blocker check and the rebuild, so nothing can enter
-- in between (Luau scripts are single-threaded; Instance creation does not yield).
local function swap(st: PocketState, target: string)
	local id = st.def.id
	local old = st.current
	-- buildPocket assembles the new version before removing the old one; on error the old version stays standing
	local ok, err = pcall(services.WorldBuilder.buildPocket, id, target)
	if not ok then
		warn("[PocketService] " .. id .. " could not build " .. target .. ": " .. tostring(err))
		endTelegraph(st)
		broadcast(st)
		return
	end
	st.current = target
	endTelegraph(st)
	migrateOnline()
	services.NavigationService.refreshAll()
	services.RecoveryService.pushAll()
	cueRegion(st, "pocket_settled", false)
	broadcast(st)
	for _, fn in listeners do
		task.spawn(fn, id, old, target)
	end
end

local function step(st: PocketState, now: number)
	local target = Pockets.targetVersion(st.def, now, Config.Pockets.cycleSeconds)
	if st.phase == "telegraph" then
		if target == st.current then
			-- the schedule moved back to what is already built: nothing to change
			endTelegraph(st)
			broadcast(st)
			return
		end
		if blockedBy(st.def) then
			-- rule 3: anything that enters during the telegraph aborts the change; it is retried next check
			endTelegraph(st)
			broadcast(st)
			return
		end
		if os.clock() >= st.telegraphEnds then
			swap(st, target)
		end
		return
	end
	if target == st.current or os.clock() < st.nextCheck then
		return
	end
	st.nextCheck = os.clock() + Config.Pockets.checkSeconds
	if blockedBy(st.def) then
		return -- a busy server lags behind the schedule until the pocket is empty
	end
	startTelegraph(st, target)
end

-- P06: walking through the stable door's first few studs verifies the stable route (rule 8). The discovery goes
-- through DiscoveryService.discover like other puzzle discoveries; the caption goes to the walker only.
local function checkVerification()
	for _, id in order do
		local st = states[id]
		if st.def.puzzle == "P06" then
			local box = Pockets.plan(st.def, st.current).verify
			if box then
				local y0 = st.def.bounds.min.y
				for player, s in services.PlayerService.all() do
					if s.regionId == st.def.regionId and s.alive then
						local pos = services.PlayerService.position(player)
						if
							pos
							and pos.X >= box.x0
							and pos.X <= box.x1
							and pos.Z >= box.z0
							and pos.Z <= box.z1
							and pos.Y >= y0
							and pos.Y <= y0 + 9
							and os.clock() >= (verifiedAt[player] or 0)
						then
							verifiedAt[player] = os.clock() + VERIFY_REPEAT_SECONDS
							services.DiscoveryService.discover(player, P06_DISCOVERY, P06_LABEL)
							local mid = Vector3.new((box.x0 + box.x1) / 2, y0 + 3, (box.z0 + box.z1) / 2)
							services.PlayerService.send(player, "cue", { id = "anchor_verified", position = mid })
						end
					end
				end
			end
		end
	end
end

function PocketService.init(s)
	services = s
	for id, def in WorldDefs.Pockets do
		table.insert(order, id)
		states[id] = {
			def = def,
			current = def.versions[1],
			phase = "idle",
			target = nil,
			telegraphEnds = 0,
			telegraphEndsServer = 0,
			nextCheck = 0,
		}
	end
	table.sort(order)
end

function PocketService.start()
	-- Initial build uses the current target. WorldBuilder.start (earlier in ORDER) already built the static world.
	local now = os.time()
	for _, id in order do
		local st = states[id]
		local target = Pockets.targetVersion(st.def, now, Config.Pockets.cycleSeconds)
		-- never leave a pocket unbuilt (its mouths would open onto nothing): fall back through the other versions
		local candidates = { target }
		for _, v in st.def.versions do
			if v ~= target then
				table.insert(candidates, v)
			end
		end
		for _, v in candidates do
			local ok, err = pcall(services.WorldBuilder.buildPocket, id, v)
			if ok then
				st.current = v
				break
			end
			warn("[PocketService] " .. id .. " could not build " .. v .. ": " .. tostring(err))
		end
	end
	task.spawn(function()
		while true do
			task.wait(1)
			local now2 = os.time()
			for _, id in order do
				local ok, err = pcall(function(): any
					step(states[id], now2)
					return nil
				end)
				if not ok then
					warn("[PocketService] " .. id .. ": " .. tostring(err))
				end
			end
			-- late joiners learn each pocket's state once (PocketFX uses it for dust and plate flicker)
			for player in services.PlayerService.all() do
				if not stateSent[player] then
					stateSent[player] = true
					for _, id in order do
						services.PlayerService.send(player, "pocketState", stateFor(states[id]))
					end
				end
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.2)
			local ok, err = pcall(function(): any
				checkVerification()
				return nil
			end)
			if not ok then
				warn("[PocketService] P06: " .. tostring(err))
			end
		end
	end)
end

return PocketService
