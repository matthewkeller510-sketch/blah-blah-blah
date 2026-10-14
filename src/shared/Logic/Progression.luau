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
-- Keys are stored in profile.progression.awarded (DataStore-safe string keys).

export type Config = {
	rankDivisor: number,
	decay: number,
	maxStaminaCap: number,
	maxHealthCap: number,
	xp: { [string]: number },
}

export type Record = { xp: number, awarded: { [string]: boolean } }

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

export type Award = { key: string, amount: number }

-- Facts the back-fill reads (a subset of the profile; the profile itself satisfies it).
export type Facts = {
	discoveries: { [string]: boolean },
	research: { [string]: { stage: number, evidence: { [string]: boolean } } },
	storyStates: { [string]: string },
}

local Progression = {}

-- PROPOSED: one grant never exceeds this, so a faulty caller cannot hand out a whole career at once.
Progression.MAX_GRANT = 100
-- PROPOSED: mission back-fill reads at most this many completions per template (bounded work on load).
Progression.MAX_MISSION_BACKFILL = 500
Progression.MAX_KEY_LENGTH = 128

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Repairs a missing or damaged record in place and returns it (schema 2 creates it; this guards odd saves).
function Progression.normalize(p: any): Record
	if type(p.progression) ~= "table" then
		p.progression = { xp = 0, awarded = {} }
	end
	local rec = p.progression
	if not finite(rec.xp) or rec.xp < 0 then
		rec.xp = 0
	end
	if type(rec.awarded) ~= "table" then
		rec.awarded = {}
	end
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
function Progression.grant(rec: Record, key: any, amount: any): boolean
	if type(key) ~= "string" or #key == 0 or #key > Progression.MAX_KEY_LENGTH then
		return false
	end
	if not finite(amount) or amount <= 0 then
		return false
	end
	if rec.awarded[key] then
		return false
	end
	rec.awarded[key] = true
	rec.xp += math.min(math.floor(amount), Progression.MAX_GRANT)
	return true
end

-- Which key a discovery pays, if any. Shelter records ("shelter:<id>") pay the shelter amount; place ids
-- (chamber ids and other "R0x." place ids) pay the discovery amount; item-claim discoveries (unique pickups)
-- and non-place records (e.g. "P01.solved") pay nothing here.
function Progression.discoveryAward(cfg: Config, discoveryId: string, itemClaimIds: { [string]: boolean }): Award?
	if string.sub(discoveryId, 1, 8) == "shelter:" then
		if #discoveryId > 8 then
			return { key = discoveryId, amount = cfg.xp.shelter }
		end
		return nil
	end
	if itemClaimIds[discoveryId] then
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
-- Sorted by key so the result is deterministic.
function Progression.factAwards(
	cfg: Config,
	facts: Facts,
	itemClaimIds: { [string]: boolean },
	storyStepIds: { string }
): { Award }
	local out: { Award } = {}
	for id, v in facts.discoveries do
		if v == true and type(id) == "string" then
			local a = Progression.discoveryAward(cfg, id, itemClaimIds)
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
			for i = 1, math.min(math.floor(n), Progression.MAX_MISSION_BACKFILL) do
				table.insert(out, { key = "mission:" .. template .. ":" .. i, amount = cfg.xp.mission })
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
		Progression.grant(rec, a.key, a.amount)
	end
	return rec.xp - before
end

return Progression
