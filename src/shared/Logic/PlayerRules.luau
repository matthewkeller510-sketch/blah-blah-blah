--!strict
-- Pure rules behind PlayerService (sections 07, 08; owner rules F05, F19; docs/MILESTONE-3.md 4.7).
-- One truth for "is this light actually lit", the light's effective range (lantern shield, Wick Moth factor),
-- flare placement validation, movement speed with the injury penalty, who can act and where a death bag lies.
-- No Roblox globals.

local PlayerRules = {}

-- Light ------------------------------------------------------------------------------------------------

export type LightDef = {
	id: string,
	beamRange: number?,
	brightness: number?,
	lantern: boolean?,
	shieldedRange: number?,
}

export type LightInput = {
	switchedOn: boolean, -- the player's switch (session state)
	def: LightDef?, -- the equipped light, only if the player still holds it
	charge: number, -- profile.lightCharge, 0..100
	condition: string, -- Vitals condition
	shielded: boolean, -- lantern shutters closed (meaningful only for a lantern)
	mothFactor: number, -- 1 = normal; a clinging Wick Moth swarm shortens the range
}

export type LightState = { on: boolean, itemId: string?, isLantern: boolean, shielded: boolean, range: number }

-- PROPOSED/TUNE: a shuttered lantern is dimmer as well as shorter (ItemDefs.shieldedRange sets the radius).
PlayerRules.SHIELDED_BRIGHTNESS = 0.45 -- default; PlayerService sets it from Config.Lantern.shieldedBrightness
-- A moth factor is clamped to this range so a swarm shortens the light but never removes it.
PlayerRules.MOTH_FACTOR_MIN = 0.1

-- The single "is lit" predicate: switched on, a light equipped and held, charge left, and not downed or dead.
function PlayerRules.lightIsOn(i: LightInput): boolean
	return i.switchedOn and i.def ~= nil and i.charge > 0 and i.condition ~= "downed" and i.condition ~= "dead"
end

function PlayerRules.clampMothFactor(factor: any): number?
	if type(factor) ~= "number" or factor ~= factor then
		return nil
	end
	return math.clamp(factor, PlayerRules.MOTH_FACTOR_MIN, 1)
end

-- Range the light reaches when lit: the lantern's open or shuttered radius (or the beam range), times the moth factor.
function PlayerRules.lightRange(def: LightDef, shielded: boolean, mothFactor: number): number
	local base = if def.lantern and shielded then (def.shieldedRange or 9) else (def.beamRange or 30)
	return base * math.clamp(mothFactor, PlayerRules.MOTH_FACTOR_MIN, 1)
end

function PlayerRules.lightBrightness(def: LightDef, shielded: boolean): number
	local b = def.brightness or 1
	return if def.lantern and shielded then b * PlayerRules.SHIELDED_BRIGHTNESS else b
end

-- The contract shape read by creatures: on is the effective state; range is 0 while not lit.
function PlayerRules.lightState(i: LightInput): LightState
	local def = i.def
	local isLantern = def ~= nil and def.lantern == true
	local on = PlayerRules.lightIsOn(i)
	return {
		on = on,
		itemId = if def then def.id else nil,
		isLantern = isLantern,
		shielded = isLantern and i.shielded,
		range = if on and def then PlayerRules.lightRange(def, i.shielded, i.mothFactor) else 0,
	}
end

-- Flares -----------------------------------------------------------------------------------------------

export type FlareInput = {
	alive: boolean,
	condition: string,
	carried: boolean,
	hidden: boolean,
	inTunnel: boolean, -- WorldDefs.isTunnel(regionId)
	inShelter: boolean, -- inside a shelter interior cell
	held: number, -- flares in the inventory
	lit: number, -- this player's flares still burning
}

-- Returns (ok, reason). Reasons: "dead", "downed", "carried", "hidden", "shelter", "region", "none", "limit".
function PlayerRules.canPlaceFlare(i: FlareInput, maxActive: number): (boolean, string?)
	if not i.alive or i.condition == "dead" then
		return false, "dead"
	end
	if i.condition == "downed" then
		return false, "downed"
	end
	if i.carried then
		return false, "carried"
	end
	if i.hidden then
		return false, "hidden" -- PROPOSED: a held niche is for staying still (consistent with stone throwing)
	end
	if i.inShelter then
		return false, "shelter"
	end
	if not i.inTunnel then
		return false, "region"
	end
	if i.held < 1 then
		return false, "none"
	end
	if i.lit >= maxActive then
		return false, "limit"
	end
	return true, nil
end

PlayerRules.FLARE_REFUSALS = {
	downed = "You cannot light a flare while down.",
	carried = "You cannot light a flare while being carried.",
	hidden = "Step out of the niche to light a flare.",
	shelter = "Flares are for the tunnels, not inside a shelter.",
	region = "Flares can only be placed in the tunnels.",
	none = "You have no flares.",
	limit = "You already have the most flares burning at once. Wait for one to burn out.",
} :: { [string]: string }

-- Movement ---------------------------------------------------------------------------------------------

export type MovementConfig =
	{ walkSpeed: number, sprintSpeed: number, crouchSpeed: number, carrySpeedMultiplier: number }
export type InjuryConfig = { sprintSpeedMultiplier: number, staminaRegenMultiplier: number }

export type MoveInput = {
	mode: string, -- granted Stamina mode: "idle" | "walk" | "sprint" | "crouch"
	downed: boolean,
	held: boolean, -- carried by a teammate or held in a hiding niche
	carrying: boolean,
	injured: boolean, -- vitals.injuryFlag (D40)
}

PlayerRules.DOWNED_CRAWL_SPEED = 2.5 -- never an unrecoverable lock

-- F05 / D40: an injury slows only sprinting; walking and crouching are never reduced.
function PlayerRules.moveSpeed(M: MovementConfig, I: InjuryConfig, i: MoveInput): number
	local speed
	if i.downed then
		speed = PlayerRules.DOWNED_CRAWL_SPEED
	elseif i.held then
		speed = 0
	elseif i.mode == "sprint" then
		speed = M.sprintSpeed * (if i.injured then I.sprintSpeedMultiplier else 1)
	elseif i.mode == "crouch" then
		speed = M.crouchSpeed
	else
		speed = M.walkSpeed
	end
	if i.carrying then
		speed = math.min(speed, M.walkSpeed) * M.carrySpeedMultiplier
	end
	return speed
end

-- Stamina regeneration multipliers for Stamina.step (combined and clamped there): class edge times injury penalty.
-- Writes into `into` when given (the per-session table reused every tick) and returns it.
function PlayerRules.regenFactors(
	classMultiplier: number?,
	injured: boolean,
	I: InjuryConfig,
	into: { number }?
): { number }
	local out = into or {}
	out[1] = classMultiplier or 1
	out[2] = if injured then I.staminaRegenMultiplier else 1
	return out
end

-- Acting and dying ---------------------------------------------------------------------------------------

-- The one "can this player act" predicate: alive, and neither downed nor dead. Every held action, interaction,
-- recovery and pickup needs it when it starts and again when it finishes, so a body waiting to respawn never
-- recovers its own new death bag or finishes anything else (F16; review round 2, findings 14 and 16).
function PlayerRules.canAct(alive: boolean, condition: string): boolean
	return alive and condition ~= "downed" and condition ~= "dead"
end

export type V3 = { x: number, y: number, z: number }

export type DeathSpotInput = {
	position: V3?, -- the body's root part, when it still exists
	lastGrounded: V3?, -- the last grounded tunnel point (only tunnels update it)
	inCell: boolean, -- inside an isolated shelter interior cell (or still standing in one while leaving it)
	door: V3?, -- the stand point outside the door of that cell's shelter, when a real shelter is known
	fallback: V3, -- where to put it when nothing else is known (the respawn point)
}

PlayerRules.DEATH_SNAP_RADIUS = 30 -- the last grounded point wins when the body lies this close to it

-- Where a death bag lies (F16: where the player fell). Interior cells are far outside the map, so a death inside
-- one leaves the bag just outside that shelter's door (PROPOSED, review round 2 finding 15); it never maps the
-- cell's coordinates onto whichever chamber happens to be nearest. Elsewhere: the last grounded point when the
-- body lies near it, else the body, else the last grounded point.
function PlayerRules.deathBagSpot(i: DeathSpotInput): V3
	if i.inCell then
		return i.door or i.lastGrounded or i.fallback
	end
	local pos, grounded = i.position, i.lastGrounded
	if pos and grounded then
		local dx, dy, dz = pos.x - grounded.x, pos.y - grounded.y, pos.z - grounded.z
		if math.sqrt(dx * dx + dy * dy + dz * dz) < PlayerRules.DEATH_SNAP_RADIUS then
			return grounded
		end
		return pos
	end
	return pos or grounded or { x = 0, y = 0, z = 0 }
end

return PlayerRules
