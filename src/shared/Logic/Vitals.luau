--!strict
-- Health, passive recovery and the rescue state machine (sections 07, 08; owner rule F18).
-- CONFIRMED: automatic recovery stops at half of current maximum health and never lowers health above that point.
-- PROPOSED: healthy -> injured -> downed -> rescued (back to injured) or dead, with a tunable downed window.
-- Pure module: no Roblox globals.

export type HealthConfig = {
	max: number,
	passiveRecoveryCapFraction: number,
	passiveRecoveryPerSecond: number,
	passiveRecoveryDelaySeconds: number,
	passiveRecoveryShelterOnly: boolean,
	injuredThresholdFraction: number,
	downedWindowSeconds: number,
	stabilizeHoldSeconds: number,
	stabilizedHealth: number,
}

export type Condition = "healthy" | "injured" | "downed" | "dead"

export type State = {
	health: number,
	max: number,
	condition: Condition,
	injuryFlag: boolean, -- an injury penalty that medical items can remove
	downedRemaining: number,
	sinceDamage: number,
	stabilized: boolean,
}

local Vitals = {}

function Vitals.new(cfg: HealthConfig): State
	return {
		health = cfg.max,
		max = cfg.max,
		condition = "healthy",
		injuryFlag = false,
		downedRemaining = 0,
		sinceDamage = math.huge,
		stabilized = false,
	}
end

local function refreshCondition(cfg: HealthConfig, s: State)
	if s.condition == "dead" or s.condition == "downed" then
		return
	end
	if s.health <= s.max * cfg.injuredThresholdFraction or s.injuryFlag then
		s.condition = "injured"
	else
		s.condition = "healthy"
	end
end

-- F18 follows the CURRENT maximum, so a field-experience bonus raises the free-recovery ceiling proportionally.
function Vitals.passiveCap(cfg: HealthConfig, s: State): number
	return s.max * cfg.passiveRecoveryCapFraction
end

-- Sets the maximum (base + field-experience bonus, docs/MILESTONE-3.md 4.8). Current health is kept and only
-- clamped: a higher maximum is never a free heal (F18), a lower one never leaves health above it.
function Vitals.setMax(cfg: HealthConfig, s: State, max: number)
	s.max = math.max(1, max)
	if s.health > s.max then
		s.health = s.max
	end
	refreshCondition(cfg, s)
end

-- Applies damage. Lethal damage while up leads to downed, not instant death, so rescue is possible.
-- Damage while downed is lethal. Returns the resulting condition.
function Vitals.damage(cfg: HealthConfig, s: State, amount: number, causesInjury: boolean?): Condition
	if s.condition == "dead" or amount <= 0 then
		return s.condition
	end
	s.sinceDamage = 0
	if s.condition == "downed" then
		s.condition = "dead"
		s.health = 0
		return s.condition
	end
	s.health = math.max(0, s.health - amount)
	if causesInjury then
		s.injuryFlag = true
	end
	if s.health <= 0 then
		s.health = 0
		s.condition = "downed"
		s.downedRemaining = cfg.downedWindowSeconds
		s.stabilized = false
	else
		refreshCondition(cfg, s)
	end
	return s.condition
end

-- Advances timers and passive recovery. inShelter matters only when passive recovery is shelter-only (PROPOSED).
function Vitals.step(cfg: HealthConfig, s: State, dt: number, inShelter: boolean): Condition
	if s.condition == "dead" then
		return s.condition
	end
	s.sinceDamage += dt
	if s.condition == "downed" then
		if not s.stabilized then
			s.downedRemaining -= dt
			if s.downedRemaining <= 0 then
				s.downedRemaining = 0
				s.condition = "dead"
			end
		end
		return s.condition
	end
	local allowed = (not cfg.passiveRecoveryShelterOnly) or inShelter
	if allowed and s.sinceDamage >= cfg.passiveRecoveryDelaySeconds then
		local cap = Vitals.passiveCap(cfg, s)
		if s.health < cap then
			s.health = math.min(cap, s.health + cfg.passiveRecoveryPerSecond * dt)
		end
		-- Health already above the cap is never reduced (T13).
	end
	refreshCondition(cfg, s)
	return s.condition
end

-- A teammate stabilizes a downed player: stops the bleed-out timer without a free full heal.
function Vitals.stabilize(_cfg: HealthConfig, s: State): boolean
	if s.condition ~= "downed" then
		return false
	end
	s.stabilized = true
	return true
end

-- Revive from downed (after stabilize + treatment, or on reaching a shelter while carried).
function Vitals.revive(cfg: HealthConfig, s: State, health: number?): boolean
	if s.condition ~= "downed" then
		return false
	end
	s.condition = "injured"
	s.health = math.clamp(health or cfg.stabilizedHealth, 1, s.max)
	s.injuryFlag = true
	s.stabilized = false
	s.downedRemaining = 0
	return true
end

-- Medical supplies can heal beyond the passive cap. Returns true if applied (callers consume the item only then).
function Vitals.applyMedical(cfg: HealthConfig, s: State, healAmount: number, removesInjury: boolean): boolean
	if s.condition == "dead" or s.condition == "downed" then
		return false
	end
	if s.health >= s.max and not (removesInjury and s.injuryFlag) then
		return false -- nothing to treat; do not waste the item
	end
	s.health = math.min(s.max, s.health + healAmount)
	if removesInjury then
		s.injuryFlag = false
	end
	refreshCondition(cfg, s)
	return true
end

function Vitals.respawn(cfg: HealthConfig, s: State)
	-- Respawn at the last shelter at the passive cap: greater recovery still requires supplies (F18).
	s.condition = "healthy"
	s.health = Vitals.passiveCap(cfg, s)
	s.injuryFlag = false
	s.downedRemaining = 0
	s.stabilized = false
	s.sinceDamage = math.huge
	refreshCondition(cfg, s)
end

export type Saved = { health: number, injured: boolean }

-- What a session saves for the next join (profile.vitals), so leaving and rejoining is never a free heal (F18).
-- PROPOSED: a downed player who leaves comes back injured at the stabilized health (low, never dead, never healed);
-- a dead player who leaves before respawning comes back exactly as the respawn would place them (the F18 cap).
function Vitals.persisted(cfg: HealthConfig, s: State): Saved
	if s.condition == "downed" then
		return { health = math.min(cfg.stabilizedHealth, s.max), injured = true }
	elseif s.condition == "dead" then
		return { health = Vitals.passiveCap(cfg, s), injured = false }
	end
	return { health = s.health, injured = s.injuryFlag }
end

-- Starts a session from the saved record, clamped to the current (progression-raised) maximum and never below 1.
-- A missing or malformed record (a brand-new profile, or one saved before the field existed) starts at full health.
-- Call after the maximum is set. The condition is derived again: a low or injured player starts "injured".
function Vitals.restore(cfg: HealthConfig, s: State, saved: any)
	local h = if type(saved) == "table" then saved.health else nil
	if type(h) == "number" and h == h then
		s.health = math.clamp(h, 1, s.max)
		s.injuryFlag = saved.injured == true
	else
		s.health = s.max
		s.injuryFlag = false
	end
	s.condition = "healthy"
	s.downedRemaining = 0
	s.stabilized = false
	refreshCondition(cfg, s)
end

return Vitals
