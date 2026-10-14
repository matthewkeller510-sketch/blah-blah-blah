--!strict
-- Lead integration fixes after the Milestone 3 reviews.

local WorldDefs = require("../../src/shared/Data/WorldDefs")
local CreatureRules = require("../../src/shared/Logic/CreatureRules")

type V3 = CreatureRules.V3

local W = WorldDefs.CORRIDOR_WIDTH

local function v(x: number, y: number, z: number): V3
	return { x = x, y = y, z = z }
end

local function node(id: string): V3
	local c = assert(WorldDefs.chamber(id))
	return v(c.pos.x, c.pos.y + 1, c.pos.z)
end

-- Static floor only (chamber interiors and straight or sloped corridor bands); pockets are out of scope here.
local function onStaticFloor(p: V3): boolean
	for _, c in WorldDefs.Chambers do
		if math.abs(p.x - c.pos.x) <= c.size.x / 2 and math.abs(p.z - c.pos.z) <= c.size.z / 2 then
			return true
		end
	end
	for _, cor in WorldDefs.Corridors do
		if cor.pocket == nil then
			local a, b = assert(WorldDefs.chamber(cor.from)), assert(WorldDefs.chamber(cor.to))
			if a.pos.x == b.pos.x then
				local z0, z1 = math.min(a.pos.z, b.pos.z), math.max(a.pos.z, b.pos.z)
				if math.abs(p.x - a.pos.x) <= W / 2 and p.z >= z0 and p.z <= z1 then
					return true
				end
			else
				local x0, x1 = math.min(a.pos.x, b.pos.x), math.max(a.pos.x, b.pos.x)
				if math.abs(p.z - a.pos.z) <= W / 2 and p.x >= x0 and p.x <= x1 then
					return true
				end
			end
		end
	end
	return false
end

-- A navigator over the static chamber graph (no pockets), as Common builds it.
local function staticNav(): CreatureRules.Nav
	local adj: { [string]: { string } } = {}
	for _, cor in WorldDefs.Corridors do
		if cor.pocket == nil then
			adj[cor.from] = adj[cor.from] or {}
			adj[cor.to] = adj[cor.to] or {}
			table.insert(adj[cor.from], cor.to)
			table.insert(adj[cor.to], cor.from)
		end
	end
	return {
		pocketIds = {},
		nearestNode = function(p: V3): string
			local best, bd = "", math.huge
			for _, c in WorldDefs.Chambers do
				local d = math.sqrt((p.x - c.pos.x) ^ 2 + ((p.y - c.pos.y) * 3) ^ 2 + (p.z - c.pos.z) ^ 2)
				if d < bd then
					best, bd = c.id, d
				end
			end
			return best
		end,
		node = node,
		chamberAt = function(p: V3): string?
			for _, c in WorldDefs.Chambers do
				if math.abs(p.x - c.pos.x) <= c.size.x / 2 and math.abs(p.z - c.pos.z) <= c.size.z / 2 then
					if math.abs(p.y - c.pos.y) <= 6 then
						return c.id
					end
				end
			end
			return nil
		end,
		pocketsAt = function(_p: V3): { string }
			return {}
		end,
		mouths = function(_id: string): (string, string)
			return "", ""
		end,
		line = function(_id: string): any
			return nil
		end,
		clear = function(_id: string, _a: V3, _b: V3): boolean
			return true
		end,
		room = function(_id: string, _g: V3): V3?
			return nil
		end,
		crosses = function(_a: V3, _b: V3): boolean
			return false
		end,
		route = function(from: string, to: string, _wades: boolean): { string }
			local prev: { [string]: string } = {}
			local seen = { [from] = true }
			local q = { from }
			local i = 1
			while i <= #q do
				local cur = q[i]
				i += 1
				if cur == to then
					break
				end
				for _, n in adj[cur] or {} do
					if not seen[n] then
						seen[n] = true
						prev[n] = cur
						table.insert(q, n)
					end
				end
			end
			if not seen[to] then
				return {}
			end
			local path = {}
			local cur = to
			while cur ~= from do
				table.insert(path, 1, cur)
				cur = prev[cur]
			end
			return path
		end,
		edgePocket = function(_a: string, _b: string): string?
			return nil
		end,
	}
end

local function walk(start: V3, goal: V3, tag: string)
	local nav = staticNav()
	local pos = start
	for _ = 1, 4000 do
		local target, final, blocked = CreatureRules.nextLeg(nav, pos, goal, false)
		assert(not blocked, tag .. ": blocked")
		local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d < 0.5 and final then
			return
		end
		local step = math.min(d, 1)
		if d > 0 then
			pos = v(pos.x + dx / d * step, pos.y + dy / d * step, pos.z + dz / d * step)
		end
		assert(onStaticFloor(pos), string.format("%s: through rock at (%.1f, %.1f)", tag, pos.x, pos.z))
	end
	error(tag .. ": never arrives")
end

return function(T: any)
	local test, eq = T.test, T.eq

	print("Lead integration fixes")

	test("creatures turn corners at chamber centres instead of cutting through rock", function()
		-- an L-shaped trip (hall -> generator room -> map room) from an off-centre start
		walk(v(-74, -63, 920), v(10, -63, 1026), "R04 hall corner to map room")
		-- a multi-corner trip across the quarry, starting in a room corner
		walk(v(-10, 1, 142), v(98, 1, 336), "R01 survey board to east workings")
		-- down a slope and around corners into the ossuary
		walk(v(-90, 1, 340), v(-180, -23, 446), "R01 rubble to R02 inspection room")
	end)

	test("the corridor-axis rule: leave only from the line between two centres", function()
		local a, b = v(0, 0, 0), v(0, 0, 100)
		eq(CreatureRules.segmentOffset(a, b, v(0, 0, 50)), 0)
		eq(CreatureRules.segmentOffset(a, b, v(3, 0, 50)), 3)
		eq(CreatureRules.segmentOffset(a, b, v(0, 0, -4)), 4, "behind the start counts from the start")
	end)
end
