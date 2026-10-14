--!strict
-- Variable pockets (section 04, owner rule F08; docs/MILESTONE-3.md section 3, D31). Pure rules shared by
-- PocketService, WorldBuilder, NavigationService and RecoveryService:
--   * the deterministic version schedule (every server converges on the same version),
--   * the "change only when empty" blocker rule (players, PocketBlocker instances, online owners' bags and ropes;
--     chalk and signs never block),
--   * the greybox layout of every version (each one joins the same two mouth doorways, so an escape path always
--     exists), rasterized to floor, wall and ceiling boxes,
--   * where records of a retired version go: documented spots in the pocket's migration anchor chamber.
-- WorldDefs is injected with bind() so this module works with both Roblox instance requires and file-path requires.
-- Pure module.

export type V3 = { x: number, y: number, z: number }
export type Box = { x0: number, z0: number, x1: number, z1: number }
export type Chamber = { id: string, regionId: string, pos: V3, size: V3, label: string }
export type PocketDef = {
	id: string,
	regionId: string,
	from: string,
	to: string,
	axis: string,
	bounds: { min: V3, max: V3 },
	versions: { string },
	migrationAnchor: string,
	doors: { number }?,
	puzzle: string?,
}
type World = {
	CORRIDOR_WIDTH: number,
	CORRIDOR_HEIGHT: number,
	Pockets: { [string]: PocketDef },
	chamber: (string) -> any,
	region: (string) -> any,
	pocketAt: (V3) -> any,
}

-- A walkable rectangle in pocket-local coordinates: u runs across the pocket (0 = the mouths' centre line),
-- v runs along it from the first mouth (0) to the second (the pocket length; END stands for it).
type LocalRect = { u0: number, u1: number, v0: number, v1: number, low: boolean }

export type Area = {
	axis: string,
	floorY: number,
	center: number, -- across coordinate of the mouths' centre line (x for axis "z", z for axis "x")
	start: number, -- along coordinate of the first mouth (outer face of the first chamber's wall)
	length: number,
	uMin: number,
	uMax: number,
	box: Box, -- world rectangle of the build grid
}

export type DoorMark = { x: number, z: number, stable: boolean, symbol: string }

export type Plan = {
	pocketId: string,
	version: string,
	floorY: number,
	area: Area,
	walk: { Box }, -- authored walkable rectangles (world)
	lowWalk: { boolean }, -- parallel to walk: true under the low ceiling
	floors: { Box }, -- walkable and wall cells (floor slabs and ceilings)
	walls: { Box },
	lows: { Box }, -- walkable cells under a low ceiling (filled from LOW_CEILING up to the corridor height)
	plate: { pos: V3, normal: V3, text: string },
	verify: Box?, -- P06: trigger area just past the stable door
	doors: { DoorMark }?, -- P06: one entry per door on the doorway room's wall (room side)
}

export type MigrationTarget = {
	regionId: string,
	anchorId: string,
	spot: (index: number) -> V3,
	facing: V3,
}

export type BagInput = { pos: V3, ownerOnline: boolean }
export type NavInput = { kind: string, pos: V3, endPos: V3?, ownerOnline: boolean }
export type BlockerInputs = {
	characters: { V3 }?, -- every player character: alive, downed, hidden or carried
	tagged: { V3 }?, -- instances tagged PocketBlocker (rescue survivors, carried NPCs)
	flares: { V3 }?, -- lit flares (PlayerService.activeFlares); each burns at most 45 s
	bags: { BagInput }?,
	nav: { NavInput }?,
}

local W: World = nil :: any

local Pockets = {}

Pockets.WALL = 2
Pockets.DOOR_WIDTH = 6 -- P06 doors on the doorway room's wall
Pockets.LOW_CEILING = 8 -- the "low" versions: still passable standing (never crouch-only clearance)
Pockets.STATIC_VERSION = 1 -- pocketVersion of records outside every pocket (keeps pre-pocket records valid)
Pockets.UNKNOWN_VERSION = "unknown" -- a record inside a pocket whose version was never recorded: it migrates
Pockets.END = math.huge

-- Survey anchor symbols on the R05 anchor plaques; the P06 stable door carries the centre anchor's symbol.
Pockets.ANCHOR_SYMBOLS = {
	["R05.south_anchor"] = "▲",
	["R05.west_anchor"] = "◆",
	["R05.center_anchor"] = "●",
	["R05.east_anchor"] = "■",
}
Pockets.STABLE_SYMBOL = "●"
Pockets.FALSE_SYMBOLS = { "▲", "■" } -- other anchors' marks: they do not belong to the room you came from

-- Notebook labels and threshold numbers (PROPOSED fictional survey numbering).
Pockets.LABELS = {
	PK1 = "Shifting Passage I",
	PK2 = "Shifting Passage II",
	PK3 = "Beyond the Three Doors",
}
local NUMBERS = { PK1 = "51", PK2 = "52", PK3 = "53" }

function Pockets.bind(worldDefs: any)
	W = worldDefs
end

-- Schedule ------------------------------------------------------------------------------------------

-- Stable small hash of a pocket id (djb2), so pockets do not all change in lockstep.
function Pockets.offset(pocketId: string): number
	local h = 5381
	for i = 1, #pocketId do
		h = (h * 33 + string.byte(pocketId, i)) % 16777216
	end
	return h % 1000
end

-- The version this pocket should show at `now` (unix seconds). Same inputs give the same version on every server.
function Pockets.targetVersion(def: PocketDef, now: number, cycleSeconds: number): string
	local n = #def.versions
	local idx = ((now // cycleSeconds) + Pockets.offset(def.id)) % n + 1
	return def.versions[idx]
end

-- Bounds and blockers ------------------------------------------------------------------------------

local function lo(def: PocketDef, margin: number): V3
	local b = def.bounds.min
	return { x = b.x - margin, y = b.y - 2 - margin, z = b.z - margin }
end

local function hi(def: PocketDef, margin: number): V3
	local b = def.bounds.max
	return { x = b.x + margin, y = b.y + margin, z = b.z + margin }
end

function Pockets.inBounds(def: PocketDef, p: V3, margin: number): boolean
	local a, b = lo(def, margin), hi(def, margin)
	return p.x >= a.x and p.x <= b.x and p.y >= a.y and p.y <= b.y and p.z >= a.z and p.z <= b.z
end

-- Slab test for one axis: narrows [t0, t1] to where the segment is inside [lo, hi] on that axis.
local function slab(a: number, d: number, l: number, h: number, t0: number, t1: number): (number, number)
	if math.abs(d) < 1e-9 then
		if a < l or a > h then
			return 1, 0
		end
		return t0, t1
	end
	local ta, tb = (l - a) / d, (h - a) / d
	if ta > tb then
		ta, tb = tb, ta
	end
	return math.max(t0, ta), math.min(t1, tb)
end

-- True when a rope (or any segment) touches the bounds plus margin: an endpoint inside, or the line through it.
function Pockets.segmentInBounds(def: PocketDef, a: V3, b: V3, margin: number): boolean
	if Pockets.inBounds(def, a, margin) or Pockets.inBounds(def, b, margin) then
		return true
	end
	local l, h = lo(def, margin), hi(def, margin)
	local t0, t1 = 0, 1
	t0, t1 = slab(a.x, b.x - a.x, l.x, h.x, t0, t1)
	t0, t1 = slab(a.y, b.y - a.y, l.y, h.y, t0, t1)
	t0, t1 = slab(a.z, b.z - a.z, l.z, h.z, t0, t1)
	return t0 <= t1
end

-- Rule 2 (section 3): the first reason this pocket may not change now, or nil when it is empty.
-- Any player character (alive, downed, hidden or carried) or PocketBlocker inside bounds + margin blocks; so does a
-- bag or a rope of an ONLINE owner. Chalk and signs never block (they migrate instead). PROPOSED: a lit flare
-- inside bounds + margin blocks too, whoever owns it, so a burning flare is never left floating in void or inside
-- a new wall; it burns out within 45 s, so it only delays a change briefly.
function Pockets.blocker(def: PocketDef, inputs: BlockerInputs, margin: number): string?
	local characters: { V3 } = inputs.characters or {}
	local tagged: { V3 } = inputs.tagged or {}
	local flares: { V3 } = inputs.flares or {}
	local bags: { BagInput } = inputs.bags or {}
	local nav: { NavInput } = inputs.nav or {}
	for _, p in characters do
		if Pockets.inBounds(def, p, margin) then
			return "player"
		end
	end
	for _, p in tagged do
		if Pockets.inBounds(def, p, margin) then
			return "blocker"
		end
	end
	for _, p in flares do
		if Pockets.inBounds(def, p, margin) then
			return "flare"
		end
	end
	for _, bag in bags do
		if bag.ownerOnline and Pockets.inBounds(def, bag.pos, margin) then
			return "bag"
		end
	end
	for _, r in nav do
		if r.ownerOnline and r.kind == "rope" and Pockets.segmentInBounds(def, r.pos, r.endPos or r.pos, margin) then
			return "rope"
		end
	end
	return nil
end

-- Record tagging -----------------------------------------------------------------------------------

-- The pocket whose variable geometry contains a point: inside its build area (between the mouth chambers' outer
-- wall faces). Stricter than WorldDefs.pocketAt, whose bounds also cover the mouth chambers' own wall thickness:
-- a mark on a static wall beside a mouth is static and never migrates.
function Pockets.containing(p: V3): PocketDef?
	local ids = {}
	for id in W.Pockets do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local pk = W.Pockets[id]
		local a = Pockets.area(pk).box
		local b = pk.bounds
		if p.x >= a.x0 and p.x <= a.x1 and p.z >= a.z0 and p.z <= a.z1 and p.y >= b.min.y - 2 and p.y <= b.max.y then
			return pk
		end
	end
	return nil
end

-- The pocket a record placed at these positions belongs to (a rope belongs to a pocket if either end is inside)
-- and its version: (pocketId, versionId) inside a pocket, (nil, STATIC_VERSION) elsewhere.
function Pockets.tagFor(positions: { V3 }, versionOf: (string) -> string?): (string?, number | string)
	for _, p in positions do
		local pk = Pockets.containing(p)
		if pk then
			return pk.id, versionOf(pk.id) or Pockets.UNKNOWN_VERSION
		end
	end
	return nil, Pockets.STATIC_VERSION
end

-- True when a record tagged with this pocket must migrate on this server. A nil current version (pocket not
-- running) never migrates anything: no information is not a reason to move an owned object.
function Pockets.isStale(pocketId: string?, pocketVersion: any, versionOf: (string) -> string?): boolean
	if pocketId == nil then
		return false
	end
	local cur = versionOf(pocketId)
	return cur ~= nil and cur ~= pocketVersion
end

-- An anchor without a pocket tag whose position lies inside a pocket (an expedition checkpoint written without
-- pocket data) gets that pocket and UNKNOWN_VERSION, so it migrates to the documented anchor instead of being
-- resolved onto whatever geometry the pocket shows now. Returns true when it tagged the anchor.
function Pockets.tagAnchor(anchor: any): boolean
	if type(anchor) ~= "table" or anchor.pocketId ~= nil or type(anchor.anchorId) ~= "string" then
		return false
	end
	local c = W.chamber(anchor.anchorId)
	local o = anchor.offset
	if not c or type(o) ~= "table" or type(o.x) ~= "number" or type(o.y) ~= "number" or type(o.z) ~= "number" then
		return false
	end
	local pk = Pockets.containing({ x = c.pos.x + o.x, y = c.pos.y + o.y, z = c.pos.z + o.z })
	if not pk then
		return false
	end
	anchor.pocketId = pk.id
	anchor.pocketVersion = Pockets.UNKNOWN_VERSION
	return true
end

-- Geometry ----------------------------------------------------------------------------------------

local function chamber(id: string): Chamber
	return assert(W.chamber(id), "unknown chamber " .. id) :: Chamber
end

-- The build area between the two mouth chambers' outer wall faces, as wide as the pocket bounds.
function Pockets.area(def: PocketDef): Area
	local a, b = chamber(def.from), chamber(def.to)
	local WALL = Pockets.WALL
	if def.axis == "z" then
		local l, h = if a.pos.z < b.pos.z then a else b, if a.pos.z < b.pos.z then b else a
		local s = l.pos.z + l.size.z / 2 + WALL
		local e = h.pos.z - h.size.z / 2 - WALL
		local c = l.pos.x
		return {
			axis = "z",
			floorY = def.bounds.min.y,
			center = c,
			start = s,
			length = e - s,
			uMin = def.bounds.min.x - c,
			uMax = def.bounds.max.x - c,
			box = { x0 = def.bounds.min.x, z0 = s, x1 = def.bounds.max.x, z1 = e },
		}
	end
	local l, h = if a.pos.x < b.pos.x then a else b, if a.pos.x < b.pos.x then b else a
	local s = l.pos.x + l.size.x / 2 + WALL
	local e = h.pos.x - h.size.x / 2 - WALL
	local c = l.pos.z
	return {
		axis = "x",
		floorY = def.bounds.min.y,
		center = c,
		start = s,
		length = e - s,
		uMin = def.bounds.min.z - c,
		uMax = def.bounds.max.z - c,
		box = { x0 = s, z0 = def.bounds.min.z, x1 = e, z1 = def.bounds.max.z },
	}
end

-- World point from pocket-local (u across, v along, y height).
function Pockets.toWorld(area: Area, u: number, v: number, y: number): V3
	if area.axis == "z" then
		return { x = area.center + u, y = y, z = area.start + v }
	end
	return { x = area.start + v, y = y, z = area.center + u }
end

local function toBox(area: Area, u0: number, u1: number, v0: number, v1: number): Box
	if area.axis == "z" then
		return { x0 = area.center + u0, z0 = area.start + v0, x1 = area.center + u1, z1 = area.start + v1 }
	end
	return { x0 = area.start + v0, z0 = area.center + u0, x1 = area.start + v1, z1 = area.center + u1 }
end

local function r(u0: number, u1: number, v0: number, v1: number, low: boolean?): LocalRect
	return { u0 = u0, u1 = u1, v0 = v0, v1 = v1, low = low == true }
end
local END = Pockets.END

-- PK3 (P06): rings behind a false door (enter, walk round a pillar, come back out of the same door) and the
-- stable passages from each door to the junction's south doorway. Door centres are at u = -12, 0, 12.
local RING_LEFT = {
	r(-15, -9, 0, 3),
	r(-18, -8, 3, 8),
	r(-18, -8, 37, 42),
	r(-18, -14, 3, 42),
	r(-12, -8, 3, 42),
}
local RING_RIGHT = { r(9, 15, 0, 3), r(8, 18, 3, 8), r(8, 18, 37, 42), r(8, 12, 3, 42), r(14, 18, 3, 42) }

-- Authored versions (PROPOSED greybox). Every list joins both mouth doorways; see tests/specs/world_pockets.luau.
local LAYOUTS: { [string]: { [string]: { LocalRect } } } = {
	PK1 = {
		direct = { r(-6, 6, 0, END) },
		-- detour east through a small side chamber; the straight line is solid rock
		loop = { r(-6, 6, 0, 14), r(-6, 24, 2, 14), r(16, 34, 8, 44), r(-6, 24, 32, 44), r(-6, 6, 32, END) },
		low = { r(-4, 4, 0, END, true) },
	},
	PK2 = {
		direct = { r(-6, 6, 0, END) },
		-- jogs north (+z) and back
		dogleg = { r(-6, 6, 0, 18), r(-6, 30, 6, 18), r(18, 30, 6, 48), r(-6, 30, 36, 48), r(-6, 6, 36, END) },
		low = { r(-4, 4, 0, END, true) },
	},
	PK3 = {
		left = {
			r(-15, -9, 0, 42),
			r(-15, 6, 32, 44),
			r(-6, 6, 32, END),
			-- middle door: ring round a pillar
			r(-3, 3, 0, 3),
			r(-7, 6, 3, 8),
			r(-7, 6, 25, 30),
			r(-7, -3, 3, 30),
			r(2, 6, 3, 30),
			table.unpack(RING_RIGHT),
		},
		middle = {
			r(-3, 3, 0, 8),
			r(-6, 6, 6, END),
			RING_LEFT[1],
			RING_LEFT[2],
			RING_LEFT[3],
			RING_LEFT[4],
			RING_LEFT[5],
			table.unpack(RING_RIGHT),
		},
		right = {
			r(9, 15, 0, 42),
			r(-6, 15, 32, 44),
			r(-6, 6, 32, END),
			r(-3, 3, 0, 3),
			r(-6, 7, 3, 8),
			r(-6, 7, 25, 30),
			r(-6, -2, 3, 30),
			r(3, 7, 3, 30),
			table.unpack(RING_LEFT),
		},
	},
}

local function localLayout(def: PocketDef, version: string): { LocalRect }
	local byPocket = LAYOUTS[def.id]
	local rects = byPocket and byPocket[version]
	if rects then
		return rects
	end
	-- Unknown pocket or version: a plain corridor still honours the entry/exit contract.
	return { r(-W.CORRIDOR_WIDTH / 2, W.CORRIDOR_WIDTH / 2, 0, END) }
end

-- Index of the stable door for a PK3-style pocket (door i belongs to versions[i]; ids are internal, players read
-- the doors by survey symbol and lamp).
function Pockets.stableDoor(def: PocketDef, version: string): number?
	if not def.doors then
		return nil
	end
	local i = table.find(def.versions, version)
	return i
end

-- Doorway openings on each mouth edge, as across-axis spans in local u. Used by WorldBuilder for the static walls
-- and by the tests for the entry/exit contract.
function Pockets.mouthSpans(def: PocketDef): { first: { { number } }, second: { { number } } }
	local area = Pockets.area(def)
	local a, b = chamber(def.from), chamber(def.to)
	local fromIsFirst = if def.axis == "z" then a.pos.z < b.pos.z else a.pos.x < b.pos.x
	local half = W.CORRIDOR_WIDTH / 2
	local plain = { { -half, half } }
	local fromSpans: { { number } } = plain
	if def.doors then
		fromSpans = {}
		local dh = Pockets.DOOR_WIDTH / 2
		for _, d in def.doors do
			table.insert(fromSpans, { d - area.center - dh, d - area.center + dh })
		end
	end
	if fromIsFirst then
		return { first = fromSpans, second = plain }
	end
	return { first = plain, second = fromSpans }
end

-- Rasterize walkable rectangles on a 1-stud grid, put 2-stud walls round them (inside the area only: the mouth
-- chambers' own walls close the ends), then merge cells into as few boxes as possible.
type Grid = { nx: number, nz: number, x0: number, z0: number, cells: { number } }
local EMPTY, WALK, WALLC, LOWC = 0, 1, 2, 3

local function mesh(grid: Grid, want: (number) -> boolean): { Box }
	local nx, nz = grid.nx, grid.nz
	local used: { boolean } = {}
	local out: { Box } = {}
	local function ok(i: number, k: number): boolean
		local idx = k * nx + i + 1
		return not used[idx] and want(grid.cells[idx])
	end
	for k = 0, nz - 1 do
		for i = 0, nx - 1 do
			if ok(i, k) then
				local i1 = i
				while i1 + 1 < nx and ok(i1 + 1, k) do
					i1 += 1
				end
				local k1 = k
				local grow = true
				while grow and k1 + 1 < nz do
					for ii = i, i1 do
						if not ok(ii, k1 + 1) then
							grow = false
							break
						end
					end
					if grow then
						k1 += 1
					end
				end
				for kk = k, k1 do
					for ii = i, i1 do
						used[kk * nx + ii + 1] = true
					end
				end
				table.insert(out, {
					x0 = grid.x0 + i,
					z0 = grid.z0 + k,
					x1 = grid.x0 + i1 + 1,
					z1 = grid.z0 + k1 + 1,
				})
			end
		end
	end
	return out
end

-- Grid of the area with every cell classified (EMPTY, WALK, WALLC or LOWC = walkable under the low ceiling).
function Pockets.grid(area: Area, walk: { Box }, lowWalk: { boolean }): Grid
	local b = area.box
	local nx, nz = math.floor(b.x1 - b.x0 + 0.5), math.floor(b.z1 - b.z0 + 0.5)
	local cells: { number } = table.create(nx * nz, EMPTY)
	for idx, box in walk do
		local i0 = math.max(0, math.floor(box.x0 - b.x0 + 0.5))
		local i1 = math.min(nx, math.floor(box.x1 - b.x0 + 0.5))
		local k0 = math.max(0, math.floor(box.z0 - b.z0 + 0.5))
		local k1 = math.min(nz, math.floor(box.z1 - b.z0 + 0.5))
		local value = if lowWalk[idx] then LOWC else WALK
		for k = k0, k1 - 1 do
			for i = i0, i1 - 1 do
				local cur = cells[k * nx + i + 1]
				-- a normal-height rectangle wins where it overlaps a low one
				if cur == EMPTY or (cur == LOWC and value == WALK) then
					cells[k * nx + i + 1] = value
				end
			end
		end
	end
	local R = Pockets.WALL
	local out = table.clone(cells)
	for k = 0, nz - 1 do
		for i = 0, nx - 1 do
			if cells[k * nx + i + 1] == EMPTY then
				local near = false
				for dk = -R, R do
					local kk = k + dk
					if kk >= 0 and kk < nz then
						for di = -R, R do
							local ii = i + di
							if ii >= 0 and ii < nx then
								local c = cells[kk * nx + ii + 1]
								if c == WALK or c == LOWC then
									near = true
									break
								end
							end
						end
					end
					if near then
						break
					end
				end
				if near then
					out[k * nx + i + 1] = WALLC
				end
			end
		end
	end
	return { nx = nx, nz = nz, x0 = b.x0, z0 = b.z0, cells = out }
end

function Pockets.isWalkable(cell: number): boolean
	return cell == WALK or cell == LOWC
end
function Pockets.isWall(cell: number): boolean
	return cell == WALLC
end

local planCache: { [string]: Plan } = {}

-- The full build plan of one version (memoized: layouts are fixed data).
function Pockets.plan(def: PocketDef, version: string): Plan
	local key = def.id .. "|" .. version
	local cached = planCache[key]
	if cached then
		return cached
	end
	local area = Pockets.area(def)
	local walk: { Box } = {}
	local lowWalk: { boolean } = {}
	local rects = localLayout(def, version)
	for _, lr in rects do
		local v1 = if lr.v1 == END then area.length else lr.v1
		table.insert(walk, toBox(area, lr.u0, lr.u1, lr.v0, v1))
		table.insert(lowWalk, lr.low)
	end
	local grid = Pockets.grid(area, walk, lowWalk)
	local floors = mesh(grid, function(c)
		return c ~= EMPTY
	end)
	local walls = mesh(grid, function(c)
		return c == WALLC
	end)
	local lows = mesh(grid, function(c)
		return c == LOWC
	end)
	-- Numbered plate on the first passage's -u wall: the same number and "measured" length on every version, so
	-- the longer routes disagree with it (section 04: numbered corridors disagree with a measured route).
	local first = rects[1]
	local firstV1 = if first.v1 == END then area.length else first.v1
	local platePos = Pockets.toWorld(area, first.u0 + 0.15, (first.v0 + firstV1) / 2, area.floorY + 5)
	local normal = if area.axis == "z" then { x = 1, y = 0, z = 0 } else { x = 0, y = 0, z = 1 }
	local plan: Plan = {
		pocketId = def.id,
		version = version,
		floorY = area.floorY,
		area = area,
		walk = walk,
		lowWalk = lowWalk,
		floors = floors,
		walls = walls,
		lows = lows,
		plate = {
			pos = platePos,
			normal = normal,
			text = string.format("GALERIE %s — %d m", NUMBERS[def.id] or "?", math.floor(area.length + 0.5)),
		},
		verify = nil,
		doors = nil,
	}
	local stable = Pockets.stableDoor(def, version)
	if def.doors and stable then
		-- door marks sit on the doors' chamber wall facing -z (the only door pocket, PK3, runs north from it)
		assert(
			area.axis == "z" and chamber(def.from).pos.z < chamber(def.to).pos.z,
			def.id .. ": a pocket with doors must run north from its doors' chamber"
		)
		local doors: { DoorMark } = {}
		local falseIdx = 0
		local wallFace = area.start - Pockets.WALL -- the doorway room's interior wall face
		for i, d in def.doors do
			local symbol = Pockets.STABLE_SYMBOL
			if i ~= stable then
				falseIdx += 1
				symbol = Pockets.FALSE_SYMBOLS[(falseIdx - 1) % #Pockets.FALSE_SYMBOLS + 1]
			end
			table.insert(doors, { x = d, z = wallFace, stable = i == stable, symbol = symbol })
		end
		plan.doors = doors
		local du = def.doors[stable] - area.center
		plan.verify = toBox(area, du - Pockets.DOOR_WIDTH / 2, du + Pockets.DOOR_WIDTH / 2, 1, 9)
	end
	planCache[key] = plan
	return plan
end

-- P06 false-door lamp brightness (0..1) at shared time `t` (workspace:GetServerTimeNow(), the same on every
-- client). PROPOSED rhythm: once every `period` seconds, three dark pulses over 2.1 s (at most about 1.4 changes per
-- second, well under the 3 flashes per second photosensitivity guideline), steady otherwise. With reduceFlashes the
-- lamp never goes dark: one slow dip to 45% over the same 2.1 s, still a visible repeated change.
Pockets.P06_PULSE_SECONDS = 2.1
function Pockets.p06LampLevel(t: number, period: number, reduceFlashes: boolean): number
	local phase = t % period
	if phase >= Pockets.P06_PULSE_SECONDS then
		return 1
	end
	if reduceFlashes then
		return 1 - 0.55 * math.sin(math.pi * phase / Pockets.P06_PULSE_SECONDS)
	end
	-- dark on [0, 0.35), [0.7, 1.05), [1.4, 1.75)
	local slot = math.floor(phase / 0.35)
	return if slot % 2 == 0 then 0.08 else 1
end

-- Mouth centres (doorway middle at head height, inside the chambers' wall plane) for cues and dust.
function Pockets.mouthPoints(def: PocketDef): { V3 }
	local area = Pockets.area(def)
	local y = area.floorY + 3
	return {
		Pockets.toWorld(area, 0, -Pockets.WALL / 2, y),
		Pockets.toWorld(area, 0, area.length + Pockets.WALL / 2, y),
	}
end

-- Numbered threshold plates beside each mouth, on the static chambers' interior wall faces.
function Pockets.thresholds(def: PocketDef): { { pos: V3, normal: V3, text: string } }
	local area = Pockets.area(def)
	local y = area.floorY + 6
	local num = NUMBERS[def.id] or "?"
	local spans = Pockets.mouthSpans(def)
	local firstLateral = W.CORRIDOR_WIDTH / 2 + 3
	if #spans.first > 1 then
		-- between the second and third doors
		firstLateral = (spans.first[2][2] + spans.first[3][1]) / 2
	end
	local secondLateral = W.CORRIDOR_WIDTH / 2 + 3
	if #spans.second > 1 then
		secondLateral = (spans.second[2][2] + spans.second[3][1]) / 2
	end
	local back = Pockets.toWorld(area, 0, -1, 0)
	local fwd = Pockets.toWorld(area, 0, 1, 0)
	local origin = Pockets.toWorld(area, 0, 0, 0)
	local n1 = { x = back.x - origin.x, y = 0, z = back.z - origin.z }
	local n2 = { x = fwd.x - origin.x, y = 0, z = fwd.z - origin.z }
	return {
		{
			pos = Pockets.toWorld(area, firstLateral, -Pockets.WALL - 0.15, y),
			normal = n1,
			text = string.format("SEUIL %s · 1", num),
		},
		{
			pos = Pockets.toWorld(area, secondLateral, area.length + Pockets.WALL + 0.15, y),
			normal = n2,
			text = string.format("SEUIL %s · 2", num),
		},
	}
end

-- Migration --------------------------------------------------------------------------------------

local spotCache: { [string]: { V3 } } = {}

-- Candidate floor points inside the pocket's migration anchor chamber, nearest to the pocket first, never inside
-- any pocket's bounds plus margin (so a moved bag or coiled rope can never block a pocket).
function Pockets.migrationSpots(def: PocketDef, margin: number): { V3 }
	local key = def.id .. "|" .. margin
	local cached = spotCache[key]
	if cached then
		return cached
	end
	local c = chamber(def.migrationAnchor)
	local hx, hz = c.size.x / 2 - 3, c.size.z / 2 - 3
	local mid = {
		x = (def.bounds.min.x + def.bounds.max.x) / 2,
		z = (def.bounds.min.z + def.bounds.max.z) / 2,
	}
	local target = {
		x = math.clamp(mid.x, c.pos.x - c.size.x / 2, c.pos.x + c.size.x / 2),
		z = math.clamp(mid.z, c.pos.z - c.size.z / 2, c.pos.z + c.size.z / 2),
	}
	local spots: { V3 } = {}
	local x = c.pos.x - hx
	while x <= c.pos.x + hx + 1e-6 do
		local z = c.pos.z - hz
		while z <= c.pos.z + hz + 1e-6 do
			local p = { x = x, y = c.pos.y, z = z }
			local clear = true
			for _, pk in W.Pockets do
				if Pockets.inBounds(pk, p, margin + 1) then
					clear = false
					break
				end
			end
			if clear then
				table.insert(spots, p)
			end
			z += 2
		end
		x += 2
	end
	table.sort(spots, function(a, b)
		local da = (a.x - target.x) ^ 2 + (a.z - target.z) ^ 2
		local db = (b.x - target.x) ^ 2 + (b.z - target.z) ^ 2
		if da ~= db then
			return da < db
		end
		if a.x ~= b.x then
			return a.x < b.x
		end
		return a.z < b.z
	end)
	if #spots == 0 then
		table.insert(spots, { x = c.pos.x, y = c.pos.y, z = c.pos.z })
	end
	spotCache[key] = spots
	return spots
end

function Pockets.migrationSpot(def: PocketDef, index: number, margin: number): V3
	local spots = Pockets.migrationSpots(def, margin)
	local s = spots[(math.max(0, index) % #spots) + 1]
	return { x = s.x, y = s.y, z = s.z }
end

-- Where records of this pocket go, for NavRecords.migratePocketRecords and RecoveryBags.migratePocket.
function Pockets.migrationTarget(def: PocketDef, margin: number): MigrationTarget
	local c = chamber(def.migrationAnchor)
	local first = Pockets.migrationSpot(def, 0, margin)
	-- moved signs face away from the pocket, into the room
	local dx, dz = c.pos.x - first.x, c.pos.z - first.z
	local facing = if math.abs(dx) > math.abs(dz)
		then { x = if dx > 0 then 1 else -1, y = 0, z = 0 }
		else { x = 0, y = 0, z = if dz >= 0 then 1 else -1 }
	return {
		regionId = c.regionId,
		anchorId = c.id,
		spot = function(index: number): V3
			return Pockets.migrationSpot(def, index, margin)
		end,
		facing = facing,
	}
end

local KIND_NAMES: { [string]: string } = {
	chalk = "chalk mark",
	sign = "sign",
	rope = "rope (now coiled)",
	death = "death bag",
	logout = "departure bag",
}

-- "Your chalk mark in the Shifting Crossroads moved to the South Survey Anchor — the passage changed."
function Pockets.migrationNotice(kinds: { string }, regionName: string, anchorLabel: string): string
	local first = KIND_NAMES[kinds[1]] or kinds[1] or "marker"
	local rest = #kinds - 1
	local subject = "Your " .. first
	if rest == 1 then
		subject ..= " and 1 other item"
	elseif rest > 1 then
		subject ..= string.format(" and %d other items", rest)
	end
	return string.format("%s in the %s moved to the %s — the passage changed.", subject, regionName, anchorLabel)
end

-- Region name and anchor label for a pocket's notices.
function Pockets.noticeNames(def: PocketDef): (string, string)
	local region = W.region(def.regionId)
	local anchor = W.chamber(def.migrationAnchor)
	return (region and region.name or def.regionId), (anchor and anchor.label or def.migrationAnchor)
end

return Pockets
