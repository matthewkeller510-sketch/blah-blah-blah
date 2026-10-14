--!strict
-- Encounter director pressure and scheduling (section 11, PROPOSED; owner rule F06).
-- Depleted resources raise stalking pressure gradually. Inputs intentionally exclude spending, Robux balance
-- and purchase history: the PressureInputs type has no field for them.
-- Pure module.

export type Weights = {
	regionDanger: number,
	lowHealth: number,
	lowLight: number,
	noMedical: number,
	exertion: number,
	timeSinceThreat: number,
}

export type DirectorConfig = {
	tickSeconds: number,
	minSecondsBetweenThreats: number,
	recoveryIntervalAfterChaseSeconds: number,
	recoveryIntervalAfterRescueSeconds: number,
	maxSimultaneousDamagingThreatsPerVictim: number,
	maxSimultaneousDamagingThreatsPerServer: number,
	weights: Weights,
	partyPressureScale: number,
}

export type PressureInputs = {
	regionDanger: number, -- 0..1 authored per region
	healthFraction: number, -- 0..1
	lightChargeFraction: number, -- 0..1, 0 when the player has no light
	medicalItemCount: number,
	exertionFraction: number, -- 0..1 recent sprinting
	secondsSinceThreat: number,
	partySize: number, -- 1 when solo
	inShelter: boolean,
}

-- Encounter states are distinct (section 11).
export type EncounterState = "observation" | "stalking" | "warning" | "pursuit" | "search" | "disengage" | "idle"

local Director = {}

function Director.pressure(cfg: DirectorConfig, i: PressureInputs): number
	if i.inShelter then
		return 0
	end
	local w = cfg.weights
	local p = w.regionDanger * math.clamp(i.regionDanger, 0, 1)
		+ w.lowHealth * (1 - math.clamp(i.healthFraction, 0, 1))
		+ w.lowLight * (1 - math.clamp(i.lightChargeFraction, 0, 1))
		+ w.noMedical * (if i.medicalItemCount <= 0 then 1 elseif i.medicalItemCount == 1 then 0.5 else 0)
		+ w.exertion * math.clamp(i.exertionFraction, 0, 1)
		+ w.timeSinceThreat * math.clamp(i.secondsSinceThreat / 300, 0, 1)
	if i.partySize > 1 then
		p *= cfg.partyPressureScale
	end
	return math.clamp(p, 0, 1)
end

-- Stalking distance shrinks as pressure rises: low supplies encourage closer stalking (F06).
function Director.stalkDistance(pressure: number, far: number, near: number): number
	return far + (near - far) * math.clamp(pressure, 0, 1)
end

export type VictimRecord = {
	activeDamagingThreats: number,
	cooldownUntil: number,
}

-- Decides whether a new damaging threat may be started for this victim right now.
function Director.mayStartDamagingThreat(
	cfg: DirectorConfig,
	victim: VictimRecord,
	serverActiveDamaging: number,
	now: number,
	pressure: number,
	threshold: number
): boolean
	if now < victim.cooldownUntil then
		return false
	end
	if victim.activeDamagingThreats >= cfg.maxSimultaneousDamagingThreatsPerVictim then
		return false -- nearby parties must not stack full-strength encounters on one victim
	end
	if serverActiveDamaging >= cfg.maxSimultaneousDamagingThreatsPerServer then
		return false
	end
	return pressure >= threshold
end

-- Recovery intervals after a hard chase or a rescue.
function Director.afterChase(cfg: DirectorConfig, victim: VictimRecord, now: number)
	victim.cooldownUntil = math.max(victim.cooldownUntil, now + cfg.recoveryIntervalAfterChaseSeconds)
end

function Director.afterRescue(cfg: DirectorConfig, victim: VictimRecord, now: number)
	victim.cooldownUntil = math.max(victim.cooldownUntil, now + cfg.recoveryIntervalAfterRescueSeconds)
end

-- Deterministic per-recipient seed for individual perception events (section 11).
-- Scope labels tell callers whether an event may be local-only.
export type EventScope = "private_cosmetic" | "party_cosmetic" | "shared_authoritative"

function Director.eventSeed(serverSeed: number, recipientId: number, eventIndex: number): number
	-- simple 32-bit mix; deterministic across server and client
	local h = (serverSeed * 2654435761 + recipientId * 40503 + eventIndex * 9973) % 4294967296
	return bit32.bxor(h, bit32.rshift(h, 16))
end

-- Footstep noise for water-sensitive hearing (C06 Wader). Crouch-wading and standing still are silent; walking
-- in water splashes; sprinting in water splashes loudly. Dry footing is silent to the Wader.
function Director.splashNoise(mode: string, inWater: boolean): number
	if not inWater or mode == "idle" or mode == "crouch" then
		return 0
	end
	return if mode == "sprint" then 1 else 0.6
end

return Director
