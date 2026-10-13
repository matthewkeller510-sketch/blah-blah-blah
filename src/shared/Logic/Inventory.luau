--!strict
-- Individual inventory with provenance (sections 09, 15; owner rules F14, F16, F17, F21).
-- Each held unit is either "loadout" (brought from / banked at a shelter) or "expedition" (gathered since the last banking).
-- Pure module: definitions are passed in as a lookup function so it can be tested outside Roblox.

export type Entry = { loadout: number, expedition: number }
export type Inventory = { [string]: Entry }
export type Contents = { [string]: number }
export type Provenance = "loadout" | "expedition"
export type DefLookup = (id: string) -> { stackLimit: number, protected: boolean }?

local Inventory = {}

function Inventory.new(): Inventory
	return {}
end

function Inventory.count(inv: Inventory, id: string): number
	local e = inv[id]
	return if e then e.loadout + e.expedition else 0
end

-- Adds up to `count` units, respecting the per-item holding limit. Returns how many were actually added.
-- Callers must leave any remainder in the world rather than destroying it.
function Inventory.add(inv: Inventory, lookup: DefLookup, id: string, count: number, provenance: Provenance): number
	local d = lookup(id)
	assert(d, "unknown item " .. id)
	assert(count >= 0 and count == math.floor(count), "count must be a non-negative integer")
	local space = d.stackLimit - Inventory.count(inv, id)
	local n = math.clamp(count, 0, math.max(0, space))
	if n == 0 then
		return 0
	end
	local e = inv[id]
	if not e then
		e = { loadout = 0, expedition = 0 }
		inv[id] = e
	end
	e[provenance] += n
	return n
end

-- Removes exactly `count` units or nothing. Expedition units are consumed first so banked equipment lasts longest.
function Inventory.remove(inv: Inventory, id: string, count: number): boolean
	if count <= 0 then
		return true
	end
	local e = inv[id]
	if not e or e.loadout + e.expedition < count then
		return false
	end
	local fromExp = math.min(e.expedition, count)
	e.expedition -= fromExp
	e.loadout -= count - fromExp
	if e.loadout + e.expedition == 0 then
		inv[id] = nil
	end
	return true
end

function Inventory.hasAll(inv: Inventory, cost: Contents): boolean
	for id, n in cost do
		if Inventory.count(inv, id) < n then
			return false
		end
	end
	return true
end

-- Shelter registration banks eligible expedition loot (section 15). Returns the banked contents.
function Inventory.bank(inv: Inventory): Contents
	local banked: Contents = {}
	for id, e in inv do
		if e.expedition > 0 then
			banked[id] = e.expedition
			e.loadout += e.expedition
			e.expedition = 0
		end
	end
	return banked
end

function Inventory.unbankedCount(inv: Inventory): number
	local n = 0
	for _, e in inv do
		n += e.expedition
	end
	return n
end

local function isEmpty(c: Contents): boolean
	return next(c) == nil
end
Inventory.isEmpty = isEmpty

-- Death (F16): atomically remove all unprotected inventory. Protected items (navigation supplies,
-- designated entitlements) stay. Returns removed contents; the caller writes them into the death-bag record.
function Inventory.extractForDeath(inv: Inventory, lookup: DefLookup): Contents
	local out: Contents = {}
	for id, e in inv do
		local d = lookup(id)
		if d and not d.protected then
			out[id] = e.loadout + e.expedition
		end
	end
	for id in out do
		inv[id] = nil
	end
	return out
end

-- Logout (F17, PROPOSED interpretation in section 15): move only unbanked expedition loot.
-- Already-owned loadout and protected navigation supplies remain in inventory.
function Inventory.extractForLogout(inv: Inventory, lookup: DefLookup): Contents
	local out: Contents = {}
	for id, e in inv do
		local d = lookup(id)
		if d and not d.protected and e.expedition > 0 then
			out[id] = e.expedition
		end
	end
	for id, n in out do
		local e = inv[id]
		e.expedition -= n
		if e.loadout + e.expedition == 0 then
			inv[id] = nil
		end
	end
	return out
end

-- Recovered bag contents return as expedition loot: they must be carried home again to bank.
-- Returns what did not fit so the bag can keep it (no silent destruction).
function Inventory.addContents(inv: Inventory, lookup: DefLookup, contents: Contents, provenance: Provenance): Contents
	local leftover: Contents = {}
	for id, n in contents do
		local added = Inventory.add(inv, lookup, id, n, provenance)
		if added < n then
			leftover[id] = n - added
		end
	end
	return leftover
end

function Inventory.clone(inv: Inventory): Inventory
	local c: Inventory = {}
	for id, e in inv do
		c[id] = { loadout = e.loadout, expedition = e.expedition }
	end
	return c
end

function Inventory.total(inv: Inventory): Contents
	local out: Contents = {}
	for id, e in inv do
		out[id] = e.loadout + e.expedition
	end
	return out
end

return Inventory
