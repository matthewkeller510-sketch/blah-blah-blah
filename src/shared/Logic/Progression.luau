--!strict
-- Field experience and ranks (section 09; owner rule F24; acceptance T23; docs/MILESTONE-3.md 4.8, D37).
-- Veterans gain modestly more max stamina and max health with diminishing returns; equipment and knowledge stay the
-- larger advantage. No enemy stat ever reads rank (section 09: "do not secretly increase every enemy stat").
-- Experience is granted at most once per dedupe key, so live grants from several packages and the load-time
-- back-fill can never pay the same fact twice. Pure module: no Roblox globals.
--
-- Dedupe key formats (shared contract; other packages call PlayerService.grantXp with exactly these keys):
--   "disc:" .. discoveryId                    first discovery of a place (chamber ids, R0x.* place ids), xp.discovery
--   "shelter:" .. shelterId                   a shelter in the player's record (registration), xp.shelter
--   "research:" .. creatureId .. ":" .. k     research stage k reached for creature "Cxx" (k = 1..stage), xp.research
--   "story:" .. stepId                        a completed story step (Logic/Story step ids, e.g. "A1.3"), xp.story
--   "mission:" .. templateId .. ":" .. n      the n-th completion of a mission template (e.g. "mission:M01:2"), xp.mission
--   "bag:" .. bagIdOrOpId                     M11: a lost bag recovered by its owner, once per bag, xp.bag
-- One-off keys (disc, shelter, research, story) are stored in profile.progression.awarded (DataStore-safe string
-- keys); they are bounded by world content. Repeatable sources are stored compactly so the saved profile does not
-- grow with play time:
--   mission keys raise a per-template high-water mark, progression.missionPaid[templateId] = n. A key pays once,
--   when its n is above the mark; an n at or below the mark pays nothing.
--   bag keys go to progression.bagsPaid, a FIFO of the last MAX_BAGS_PAID keys (bag ids are unique, and a recovered
--   bag is never targeted again).
-- normalize folds keys of both kinds that older records kept in `awarded` into these, idempotently.

export type Config = {
	rankDivisor: number,
	decay: number,
	maxStaminaCap: number,
	maxHealthCap: number,
	xp: { [string]: number },
}

export type Record = {
	xp: number,
	awarded: { [string]: boolean },
	missionPaid: { [string]: number },
	bagsPaid: { string },
}

export type Snapshot = {
	xp: number,
	rank: number,
	rankXp: number, -- experience at which the current rank began
	nextRankXp: number, -- experience needed for the next rank
	staminaBonus: number,
	healthBonus: number,
	staminaCap: number,
	healthCap: number,
}

-- A mission back-fill award also carries `template` and `through`: every completion above that template's mark,
-- up to `through`, pays `amount` once. Its key names the last of them ("mission:<T>:<through>").
export type Award = { key: string, amount: number, template: string?, through: number? }

-- Facts the back-fill reads (a subset of the profile; the profile itself satisfies it).
export type Facts = {
	discoveries: { [string]: boolean },
	research: { [string]: { stage: number, evidence: { [string]: boolean } } },
	storyStates: { [string]: string },
}

local Progression = {}

-- PROPOSED: one grant never exceeds this, so a faulty caller cannot hand out a whole career at once.
Progression.MAX_GRANT = 100
-- PROPOSED: mission back-fill pays at most this many completions per template (one award per template).
Progression.MAX_MISSION_BACKFILL = 500
Progression.MAX_KEY_LENGTH = 128
-- PROPOSED: how many paid bag keys are remembered (like RecoveryBags' 64 applied operation ids).
Progression.MAX_BAGS_PAID = 64

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- "mission:<template>:<n>" with a whole n >= 1 -> (template, n); anything else -> nil (a plain one-off key).
local function parseMissionKey(key: string): (string?, number?)
	local template, digits = string.match(key, "^mission:(.+):(%d+)$")
	local n = tonumber(digits)
	if template == nil or n == nil or not finite(n) or n < 1 then
		return nil, nil
	end
	return template, n
end

local function isBagKey(key: string): boolean
	return #key > 4 and string.sub(key, 1, 4) == "bag:"
end

-- The compact tables may be missing on a record that skipped normalize (tests, odd saves).
local function compact(rec: Record)
	if type(rec.missionPaid) ~= "table" then
		rec.missionPaid = {}
	end
	if type(rec.bagsPaid) ~= "table" then
		rec.bagsPaid = {}
	end
end

local function paidOf(rec: Record, template: string): number
	local v = rec.missionPaid[template]
	return if finite(v) and v > 0 then math.floor(v) else 0
end

local function trimBags(rec: Record)
	while #rec.bagsPaid > Progression.MAX_BAGS_PAID do
		table.remove(rec.bagsPaid, 1)
	end
end

-- Moves "mission:" and "bag:" keys that older records kept in `awarded` into the compact tables (idempotent: a
-- second call finds nothing to move). The mark becomes the highest n paid, so nothing is ever paid twice.
local function foldLegacy(rec: Record)
	local moved: { string } = {}
	local bags: { string } = {}
	for key in rec.awarded do
		if type(key) == "string" then
			local template, n = parseMissionKey(key)
			if template and n then
				if n > paidOf(rec, template) then
					rec.missionPaid[template] = n
				end
				table.insert(moved, key)
			elseif isBagKey(key) then
				table.insert(bags, key)
				table.insert(moved, key)
			end
		end
	end
	for _, key in moved do
		rec.awarded[key] = nil
	end
	table.sort(bags) -- deterministic order for keys that had none
	for _, key in bags do
		if not table.find(rec.bagsPaid, key) then
			table.insert(rec.bagsPaid, key)
		end
	end
	trimBags(rec)
end

-- Repairs a missing or damaged record in place and returns it (schema 2 creates it; this guards odd saves), and
-- folds older per-completion mission keys and bag keys into the compact tables.
function Progression.normalize(p: any): Record
	if type(p.progression) ~= "table" then
		p.progression = { xp = 0, awarded = {}, missionPaid = {}, bagsPaid = {} }
	end
	local rec = p.progression
	if not finite(rec.xp) or rec.xp < 0 then
		rec.xp = 0
	end
	if type(rec.awarded) ~= "table" then
		rec.awarded = {}
	end
	compact(rec)
	foldLegacy(rec)
	return rec :: Record
end

-- rank = floor(sqrt(xp / divisor)): 50 xp -> 1, 200 -> 2, 1250 -> 5, 5000 -> 10.
function Progression.rank(cfg: Config, xp: number): number
	if not finite(xp) or xp <= 0 then
		return 0
	end
	-- the small epsilon keeps exact thresholds (e.g. 200 / 50 = 4 -> 2) from flooring down through rounding
	return math.floor(math.sqrt(xp / cfg.rankDivisor) + 1e-9)
end

function Progression.xpForRank(cfg: Config, rank: number): number
	return rank * rank * cfg.rankDivisor
end

-- bonus(rank) = cap * (1 - decay ^ rank), rounded down to whole points (PROPOSED: integer stats).
-- Monotonic in rank and never above the cap: rank 1 -> 2, rank 5 -> 8, rank 10 -> 12 (15 only past rank 200).
function Progression.bonus(cap: number, decay: number, rank: number): number
	if rank <= 0 then
		return 0
	end
	return math.clamp(math.floor(cap * (1 - decay ^ rank)), 0, cap)
end

function Progression.snapshot(cfg: Config, xp: number): Snapshot
	local x = if finite(xp) and xp > 0 then xp else 0
	local r = Progression.rank(cfg, x)
	return {
		xp = x,
		rank = r,
		rankXp = Progression.xpForRank(cfg, r),
		nextRankXp = Progression.xpForRank(cfg, r + 1),
		staminaBonus = Progression.bonus(cfg.maxStaminaCap, cfg.decay, r),
		healthBonus = Progression.bonus(cfg.maxHealthCap, cfg.decay, r),
		staminaCap = cfg.maxStaminaCap,
		healthCap = cfg.maxHealthCap,
	}
end

-- Pays `amount` once for `key`. Returns true only when the key was new and something was paid.
-- Invalid keys or amounts (non-string, empty, too long, non-finite, <= 0) pay nothing and do not consume the key.
-- "mission:<T>:<n>" pays when n is above the template's high-water mark and raises the mark to n; "bag:<id>" pays
-- when the key is not among the remembered paid bag keys (see the header).
function Progression.grant(rec: Record, key: any, amount: any): boolean
	if type(key) ~= "string" or #key == 0 or #key > Progression.MAX_KEY_LENGTH then
		return false
	end
	if not finite(amount) or amount <= 0 then
		return false
	end
	compact(rec)
	local template, n = parseMissionKey(key)
	if template and n then
		if n <= paidOf(rec, template) then
			return false
		end
		rec.missionPaid[template] = n
	elseif isBagKey(key) then
		if table.find(rec.bagsPaid, key) then
			return false
		end
		table.insert(rec.bagsPaid, key)
		trimBags(rec)
	else
		if rec.awarded[key] then
			return false
		end
		rec.awarded[key] = true
	end
	rec.xp += math.min(math.floor(amount), Progression.MAX_GRANT)
	return true
end

-- Mission back-fill: raises the template's mark to `through` and pays `amount` (capped like one grant) for every
-- completion above the old mark. Returns the experience added (0 when the mark already covers `through`).
function Progression.grantMissionThrough(rec: Record, template: string, through: number, amount: number): number
	if type(template) ~= "string" or #template == 0 or not finite(through) or not finite(amount) or amount <= 0 then
		return 0
	end
	compact(rec)
	local n = math.floor(through)
	local paid = paidOf(rec, template)
	if n <= paid then
		return 0
	end
	rec.missionPaid[template] = n
	local added = (n - paid) * math.min(math.floor(amount), Progression.MAX_GRANT)
	rec.xp += added
	return added
end

-- Which key a discovery pays, if any. Shelter records ("shelter:<id>") pay the shelter amount; place ids
-- (chamber ids and other "R0x." place ids) pay the discovery amount; non-place records (e.g. "P01.solved") and the
-- ids in `noPlaceIds` pay nothing here. Callers pass the item-claim discoveries (unique pickups) plus
-- Logic/Discovery's PUZZLE_RECORDS (D78), the same exclusion Discovery.isPlaceDiscovery applies to live grants.
function Progression.discoveryAward(cfg: Config, discoveryId: string, noPlaceIds: { [string]: boolean }): Award?
	if string.sub(discoveryId, 1, 8) == "shelter:" then
		if #discoveryId > 8 then
			return { key = discoveryId, amount = cfg.xp.shelter }
		end
		return nil
	end
	if noPlaceIds[discoveryId] then
		return nil
	end
	if string.match(discoveryId, "^R%d%d%.") then
		return { key = "disc:" .. discoveryId, amount = cfg.xp.discovery }
	end
	return nil
end

-- Story step ids that are complete, act by act: within an act, steps count in order up to the first unfinished
-- one (exactly like the journal); a later act counts only once every earlier act is complete.
-- `acts` holds step lists ({ id, done(facts) }); errors in a step predicate stop the scan (never throw).
function Progression.completedStepIds(acts: { { any } }, facts: any): { string }
	local out = {}
	for _, steps in acts do
		for _, step in steps do
			local ok, done = pcall(step.done, facts)
			if not ok or done ~= true then
				return out
			end
			if type(step.id) == "string" then
				table.insert(out, step.id)
			end
		end
	end
	return out
end

-- Every award the existing profile facts justify (used for the load-time back-fill and periodic re-sync).
-- Sorted by key so the result is deterministic. `noPlaceIds` as in discoveryAward. Missions give one award per
-- template (its completions, at most MAX_MISSION_BACKFILL), paid against the template's high-water mark.
function Progression.factAwards(
	cfg: Config,
	facts: Facts,
	noPlaceIds: { [string]: boolean },
	storyStepIds: { string }
): { Award }
	local out: { Award } = {}
	for id, v in facts.discoveries do
		if v == true and type(id) == "string" then
			local a = Progression.discoveryAward(cfg, id, noPlaceIds)
			if a then
				table.insert(out, a)
			end
		end
	end
	for creatureId, e in facts.research do
		local stage = if type(e) == "table" and finite(e.stage) then math.floor(e.stage) else 0
		for k = 1, math.min(stage, 10) do
			table.insert(out, { key = "research:" .. creatureId .. ":" .. k, amount = cfg.xp.research })
		end
	end
	for _, stepId in storyStepIds do
		table.insert(out, { key = "story:" .. stepId, amount = cfg.xp.story })
	end
	for k, v in facts.storyStates do
		local template = string.match(k, "^(M%d%d)%.completions$")
		local n = tonumber(v)
		if template and n then
			local through = math.min(math.floor(n), Progression.MAX_MISSION_BACKFILL)
			if through >= 1 then
				table.insert(out, {
					key = "mission:" .. template .. ":" .. through,
					amount = cfg.xp.mission,
					template = template,
					through = through,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

-- Applies awards idempotently. Returns the experience added (0 when everything was already paid).
function Progression.applyAwards(rec: Record, awards: { Award }): number
	local before = rec.xp
	for _, a in awards do
		local template, through = a.template, a.through
		if template ~= nil and through ~= nil then
			Progression.grantMissionThrough(rec, template, through, a.amount)
		else
			Progression.grant(rec, a.key, a.amount)
		end
	end
	return rec.xp - before
end

return Progression
