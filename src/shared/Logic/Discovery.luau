--!strict
-- Discovery, scavenging and pickup rules (sections 08, 14; owner rules F12, F14, F24). Pure module.
--   * Who may search a site or claim a pickup (server-side checks; the ProximityPrompt alone is not trusted).
--   * Per-player scavenging (D18) that never destroys a remainder: what does not fit stays in the site for that
--     player, and a search that grants nothing neither starts the cooldown nor consumes the site.
--   * Which discoveries count as places for field experience (F24, D37).

export type Contents = { [string]: number }

export type Searcher = {
	alive: boolean,
	downed: boolean,
	carried: boolean,
	hidden: boolean,
	inShelter: boolean,
	distance: number?, -- studs from the character to the site; nil when the character has no root part
}

export type SiteState = {
	readyAt: number?, -- unix time the site restocks for this player (nil: never searched or long restocked)
	remainder: Contents?, -- what this player left behind because it did not fit
}

export type SearchResult = {
	outcome: string, -- "full" | "partial" | "no_room" | "cooldown"
	got: Contents,
	state: SiteState, -- the site state to save (unchanged for "no_room" and "cooldown")
}

local Discovery = {}

Discovery.SEARCH_RANGE = 10 -- prompts reach 7 studs; the server allows a little latency slack

-- Returns (ok, reason). Reasons: "dead", "downed", "carried", "hidden", "in_shelter", "too_far".
function Discovery.canSearch(st: Searcher, range: number): (boolean, string?)
	if not st.alive then
		return false, "dead"
	end
	if st.downed then
		return false, "downed"
	end
	if st.carried then
		return false, "carried"
	end
	if st.hidden then
		return false, "hidden"
	end
	if st.inShelter then
		return false, "in_shelter"
	end
	if st.distance == nil or st.distance > range then
		return false, "too_far"
	end
	return true, nil
end

local function sortedIds(c: Contents): { string }
	local ids = {}
	for id in c do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- One search of a per-player site. `add(itemId, n)` performs the inventory add and returns how many fit.
-- A restocked site offers its full contents; before it restocks, only the player's remainder (if any).
-- Grants what fits; leaves the rest in the site; starts the restock timer only when something was taken.
function Discovery.search(
	contents: Contents,
	state: SiteState,
	now: number,
	respawnSeconds: number,
	add: (string, number) -> number
): SearchResult
	local restocked = state.readyAt == nil or now >= (state.readyAt :: number)
	local available: Contents
	if restocked then
		available = contents
	elseif state.remainder ~= nil and next(state.remainder) ~= nil then
		available = state.remainder :: Contents
	else
		return { outcome = "cooldown", got = {}, state = state }
	end
	local got: Contents, left: Contents = {}, {}
	for _, id in sortedIds(available) do
		local n = available[id]
		if n > 0 then
			local a = math.clamp(add(id, n), 0, n)
			if a > 0 then
				got[id] = a
			end
			if a < n then
				left[id] = n - a
			end
		end
	end
	if next(got) == nil then
		return { outcome = "no_room", got = got, state = state }
	end
	local full = next(left) == nil
	return {
		outcome = if full then "full" else "partial",
		got = got,
		state = {
			readyAt = if restocked then now + respawnSeconds else state.readyAt,
			remainder = if full then nil else left,
		},
	}
end

-- Site state lives in profile.missionCooldowns (already persisted, string keys and numbers only):
--   "scav:<siteId>" = restock time (the key Milestone 1 already used), and
--   "scavleft:<siteId>|<itemId>" = units this player left behind.
local function leftPrefix(siteId: string): string
	return "scavleft:" .. siteId .. "|"
end

function Discovery.readSite(cooldowns: { [string]: number }, siteId: string): SiteState
	local prefix = leftPrefix(siteId)
	local remainder: Contents? = nil
	for key, n in cooldowns do
		if string.sub(key, 1, #prefix) == prefix and n > 0 then
			remainder = remainder or {}
			assert(remainder)[string.sub(key, #prefix + 1)] = n
		end
	end
	return { readyAt = cooldowns["scav:" .. siteId], remainder = remainder }
end

function Discovery.writeSite(cooldowns: { [string]: number }, siteId: string, state: SiteState)
	local prefix = leftPrefix(siteId)
	local stale = {}
	for key in cooldowns do
		if string.sub(key, 1, #prefix) == prefix then
			table.insert(stale, key)
		end
	end
	for _, key in stale do
		cooldowns[key] = nil
	end
	local readyAt = state.readyAt
	if readyAt ~= nil then
		cooldowns["scav:" .. siteId] = readyAt
	else
		cooldowns["scav:" .. siteId] = nil
	end
	if state.remainder then
		for id, n in state.remainder do
			if n > 0 then
				cooldowns[prefix .. id] = n
			end
		end
	end
end

-- Puzzle records that carry a place-like "Rxx." id but pay no place experience (D78: "not item claims or puzzle
-- records"). The ids stay as saved. Shared by the live grant (isPlaceDiscovery) and the back-fill (PlayerService
-- passes this set to Progression.factAwards).
Discovery.PUZZLE_RECORDS = {
	["R05.p06_verified"] = true, -- P06 impossible doorway (docs/MILESTONE-3.md section 3 rule 8)
} :: { [string]: boolean }

-- Field experience for places (D37): chamber ids, depot landmarks and other "Rxx." place ids, but never a puzzle
-- record or the discovery that accompanies an item claim (that would pay for loot rather than exploration).
function Discovery.isPlaceDiscovery(id: string, isItemClaim: (string) -> boolean): boolean
	if Discovery.PUZZLE_RECORDS[id] or isItemClaim(id) then
		return false
	end
	return string.match(id, "^R%d%d%.") ~= nil
end

return Discovery
