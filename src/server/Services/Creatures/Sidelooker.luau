--!strict
-- C01 Sidelooker (harmless observer): appears at a chamber edge off to one player's side, peeks, and retreats when
-- deliberately watched. Never damages. Early, subtle and easy to miss (F06).
-- A private sighting (section 11, "private cosmetic"): the server keeps only a logical position for the watch test
-- and sends the figure to its one watcher on the "sidelooker" channel; CreatureFX renders it on that client only.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WorldDefs = require(Shared.Data.WorldDefs)
local CreatureRules = require(Shared.Logic.CreatureRules)
local Common = require(script.Parent.Common)

local Sidelooker = {}
local services: any

local SIDE = WorldDefs.Creatures.C01_Sidelooker
local HEIGHT = 8.5
local COOLDOWN_SECONDS = 75 -- per player between sightings
local LIFETIME_SECONDS = 14
local WATCH_RANGE = 70
local WATCH_DOT = 0.94
local RETREAT_AFTER = 0.4 -- seconds of deliberate watching

type State = {
	pos: Vector3?, -- floor position of the figure (nil when none)
	watcher: Player?,
	watchedFor: number,
	chamber: string,
	id: number,
	expiresAt: number,
}
local st: State = { pos = nil, watcher = nil, watchedFor = 0, chamber = "", id = 0, expiresAt = 0 }
-- weak keys: a write during a departing player's final save never pins the Player (review R2 finding 12)
local lastSighting: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

local function clear()
	st.pos = nil
	st.watcher = nil
end

-- Location keys live beside the evidence ids (they never match a stage requirement). Marked dirty when new.
local function recordLocation(w: Player, chamber: string)
	local s = services.PlayerService.get(w)
	if not s then
		return
	end
	local entry = s.profile.research[SIDE.id]
	if not entry then
		entry = { stage = 0, evidence = {} }
		s.profile.research[SIDE.id] = entry
	end
	local key = "loc:" .. chamber
	if not entry.evidence[key] then
		entry.evidence[key] = true
		services.SaveService.markDirty(w)
	end
	local n = 0
	for k in entry.evidence do
		if string.sub(k, 1, 4) == "loc:" then
			n += 1
		end
	end
	if n >= 3 then
		Common.evidence(w, SIDE, "seen_three_locations")
	end
end

local function tickVisible(dt: number)
	local w = st.watcher
	local pos = st.pos
	local head = w and Common.head(w)
	if not w or not pos or not head then
		clear()
		return
	end
	local now = os.clock()
	if now > st.expiresAt then
		services.PlayerService.send(w, "sidelooker", { id = st.id, gone = true })
		clear()
		return
	end
	local centre = pos + Vector3.new(0, HEIGHT / 2, 0)
	local to = centre - head.Position
	local sess = services.PlayerService.get(w)
	local watched = sess ~= nil
		and Common.perceivable(w, sess)
		and to.Magnitude < WATCH_RANGE
		and to.Magnitude > 0.1
		and head.CFrame.LookVector:Dot(to.Unit) > WATCH_DOT
		and Common.lineOfSight(head.Position, centre)
	if watched then
		if st.watchedFor == 0 then
			-- once per sighting, not every tick
			Common.evidence(w, SIDE, "seen")
			recordLocation(w, st.chamber)
		end
		st.watchedFor += dt
	end
	if st.watchedFor > RETREAT_AFTER then
		-- retreat: slide back out of view (away from the watcher, behind the wall) and vanish
		Common.evidence(w, SIDE, "seen_retreat_when_watched")
		services.PlayerService.send(w, "cue", { id = "sidelooker_retreat", position = centre })
		local flat = Vector3.new(to.X, 0, to.Z)
		local away = if flat.Magnitude > 0.1 then pos + flat.Unit * 6 else pos
		services.PlayerService.send(w, "sidelooker", { id = st.id, away = away })
		clear()
	end
end

local function trySpawn(dt: number)
	local now = os.clock()
	for p, s in services.PlayerService.all() do
		if not Common.active(p, s) then
			continue
		end
		if now - (lastSighting[p] or -math.huge) < COOLDOWN_SECONDS then
			continue
		end
		local pressure = services.DirectorService.pressure(p)
		if math.random() > CreatureRules.chance(0.02 + pressure * 0.06, dt) then
			continue
		end
		local head = Common.head(p)
		if not head then
			continue
		end
		-- a chamber in the same region 30-60 studs away, off to the side (outside immediate view)
		local look = Common.v3(head.CFrame.LookVector)
		for id, n in Common.nodes do
			if Common.nodeRegion[id] ~= s.regionId then
				continue
			end
			local to = Vector3.new(n.X - head.Position.X, 0, n.Z - head.Position.Z)
			local d = to.Magnitude
			local c = CreatureRules.flatCos(look, Common.v3(to))
			if d > 30 and d < 60 and c ~= nil and math.abs(c) < 0.6 then
				local def = WorldDefs.chamber(id)
				if not def then
					continue
				end
				local corner = n
					+ Vector3.new(
						(def.size.x / 2 - 1.5) * (if math.random() < 0.5 then -1 else 1),
						0,
						(def.size.z / 2 - 1.5)
					)
				st.id += 1
				st.pos = corner
				st.watcher = p
				st.watchedFor = 0
				st.chamber = id
				st.expiresAt = now + LIFETIME_SECONDS
				lastSighting[p] = now
				services.PlayerService.send(p, "sidelooker", { id = st.id, position = corner, lookAt = head.Position })
				services.PlayerService.send(p, "cue", { id = "sidelooker_scrape", position = corner })
				return
			end
		end
	end
end

function Sidelooker.tick(dt: number)
	if st.pos then
		tickVisible(dt)
	else
		trySpawn(dt) -- one at a time server-wide; a private sighting for one player
	end
end

-- The figure exists only on its watcher's client: nothing to aim a tool at on the server.
function Sidelooker.targets(): { Common.Target }
	return {}
end

function Sidelooker.onPlayerRemoving(p: Player)
	lastSighting[p] = nil
	if st.watcher == p then
		clear()
	end
end

function Sidelooker.init(s)
	services = s
end

function Sidelooker.start() end

return Sidelooker
