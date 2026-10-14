--!strict
-- Stamina model (section 07, owner rule F05).
-- Exhausting stamina disables sprinting and leaves the player walking while stamina recovers.
-- Exhaustion never disables walking. Modifiers combine multiplicatively and are clamped to documented caps.
-- Pure module: no Roblox globals. Configuration is passed in.

export type StaminaConfig = {
	max: number,
	sprintDrainPerSecond: number,
	regenPerSecond: number,
	regenDelaySeconds: number,
	exhaustionRecoverFraction: number,
	regenMultiplierMin: number,
	regenMultiplierMax: number,
	drainMultiplierMin: number,
	drainMultiplierMax: number,
}

export type State = {
	value: number,
	exhausted: boolean,
	sinceSprint: number,
	max: number?, -- per-player maximum (base + field-experience bonus); nil means cfg.max
}

export type Modifiers = {
	regen: { number }?,
	drain: { number }?,
}

export type Mode = "walk" | "sprint" | "crouch" | "idle"

local Stamina = {}

function Stamina.new(cfg: StaminaConfig): State
	return { value = cfg.max, exhausted = false, sinceSprint = math.huge, max = cfg.max }
end

function Stamina.maxOf(cfg: StaminaConfig, state: State): number
	return state.max or cfg.max
end

-- Raises (or lowers) the maximum. Current stamina is kept, only clamped: a rank-up is no free refill.
function Stamina.setMax(cfg: StaminaConfig, state: State, max: number)
	state.max = math.max(1, max)
	state.value = math.min(state.value, Stamina.maxOf(cfg, state))
end

local function combine(list: { number }?, lo: number, hi: number): number
	local m = 1
	if list then
		for _, v in list do
			m *= v
		end
	end
	return math.clamp(m, lo, hi)
end

function Stamina.regenMultiplier(cfg: StaminaConfig, mods: Modifiers?): number
	return combine(mods and mods.regen, cfg.regenMultiplierMin, cfg.regenMultiplierMax)
end

function Stamina.drainMultiplier(cfg: StaminaConfig, mods: Modifiers?): number
	return combine(mods and mods.drain, cfg.drainMultiplierMin, cfg.drainMultiplierMax)
end

function Stamina.canSprint(state: State): boolean
	return not state.exhausted and state.value > 0
end

-- Advances stamina by dt. Returns the movement mode actually granted.
-- wantsSprint is ignored (downgraded to walk) while exhausted. Walking is always granted when moving.
function Stamina.step(
	cfg: StaminaConfig,
	state: State,
	dt: number,
	moving: boolean,
	wantsSprint: boolean,
	wantsCrouch: boolean,
	mods: Modifiers?
): Mode
	local max = Stamina.maxOf(cfg, state)
	local mode: Mode
	if not moving then
		mode = "idle"
	elseif wantsCrouch then
		mode = "crouch"
	elseif wantsSprint and Stamina.canSprint(state) then
		mode = "sprint"
	else
		mode = "walk"
	end

	if mode == "sprint" then
		state.value -= cfg.sprintDrainPerSecond * Stamina.drainMultiplier(cfg, mods) * dt
		state.sinceSprint = 0
		if state.value <= 0 then
			state.value = 0
			state.exhausted = true
		end
	else
		state.sinceSprint += dt
		if state.sinceSprint >= cfg.regenDelaySeconds then
			state.value = math.min(max, state.value + cfg.regenPerSecond * Stamina.regenMultiplier(cfg, mods) * dt)
		end
		if state.exhausted and state.value >= max * cfg.exhaustionRecoverFraction then
			state.exhausted = false
		end
	end

	return mode
end

-- Visible only when relevant (section 07: "show the stamina bar when relevant").
function Stamina.shouldShowBar(cfg: StaminaConfig, state: State): boolean
	return state.exhausted or state.value < Stamina.maxOf(cfg, state)
end

return Stamina
