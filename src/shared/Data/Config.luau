--!strict
-- Tunable values for the Milestone 1 systems slice.
-- Every number here is a TUNE starting value from the specification (sections 03, 07, 08, 09, 11)
-- and requires playtesting on real phones, tablets and PCs. Nothing here is a fixed promise.
-- This module has no Roblox dependencies so it can be unit-tested outside Studio.

local Config = {}

Config.SCHEMA_VERSION = 1

-- 03. Server/party capacity (TUNE, unverified)
Config.Server = {
	maxPlayers = 16,
	maxPartySize = 6,
	pvpEnabled = false,
}

-- 07. Movement and stamina (TUNE)
Config.Movement = {
	walkSpeed = 11,
	sprintSpeed = 17,
	crouchSpeed = 6,
	exhaustedWalkSpeed = 11, -- exhaustion disables sprint, never walking (F05)
	carrySpeedMultiplier = 0.6,
}

Config.Stamina = {
	max = 100,
	sprintDrainPerSecond = 12,
	regenPerSecond = 15,
	regenDelaySeconds = 1.0,
	-- After hitting zero, sprint stays disabled until stamina recovers to this fraction.
	exhaustionRecoverFraction = 0.35,
	-- Modifier caps keep stacked bonuses predictable (07: "documented caps").
	regenMultiplierMin = 0.5,
	regenMultiplierMax = 1.5,
	drainMultiplierMin = 0.6,
	drainMultiplierMax = 1.5,
}

-- 07/08. Health and recovery (F18 is CONFIRMED: automatic healing stops at half max)
Config.Health = {
	max = 100,
	passiveRecoveryCapFraction = 0.5, -- CONFIRMED owner rule F18
	passiveRecoveryPerSecond = 2, -- TUNE
	passiveRecoveryDelaySeconds = 5, -- PROPOSED: shelter-only passive recovery after short safe delay
	passiveRecoveryShelterOnly = true, -- PROPOSED, not an owner rule (see docs/DECISIONS.md D04)
	injuredThresholdFraction = 0.35,
	downedWindowSeconds = 45, -- PROPOSED/TUNE rescue window
	stabilizeHoldSeconds = 4,
	stabilizedHealth = 15,
}

-- 09. Classes: small (~5%) advantages; every class can do everything (F22)
Config.Classes = {
	Explorer = { batteryDrainMultiplier = 0.95 },
	Medic = { treatTimeMultiplier = 0.95 },
	Runner = { staminaRegenMultiplier = 1.05 },
	Technician = { repairTimeMultiplier = 0.95, craftTimeMultiplier = 0.95 },
}
Config.DefaultClass = "Explorer"
Config.ClassChangeCoinCost = 150 -- PROPOSED: earned coins, never Robux (D06)

-- 08. Light (light is valuable, not mandatory)
Config.Light = {
	ambientNoLightBrightness = 0.04, -- deliberately faint reflected illumination, never solid black
	flickerWarningFraction = 0.15,
	batterySwapSeconds = 2.5,
}

-- 11. Encounter director (PROPOSED). Inputs never include spending, Robux or purchase history.
Config.Director = {
	tickSeconds = 2,
	minSecondsBetweenThreats = 45,
	recoveryIntervalAfterChaseSeconds = 60,
	recoveryIntervalAfterRescueSeconds = 90,
	maxSimultaneousDamagingThreatsPerVictim = 1,
	maxSimultaneousDamagingThreatsPerServer = 4,
	weights = {
		regionDanger = 0.35,
		lowHealth = 0.2,
		lowLight = 0.2,
		noMedical = 0.1,
		exertion = 0.05,
		timeSinceThreat = 0.1,
	},
	partyPressureScale = 0.85, -- groups are tuned separately from solo players
}

-- 13. Shelters
Config.Shelter = {
	registerRadius = 10,
	interiorCellSpacing = 400, -- studs between isolated interior cells
	interiorCellOrigin = { x = 20000, y = 500, z = 20000 },
}

-- 16. Navigation (placed items persist until retrieved; transparent limits only)
Config.Navigation = {
	maxPlacedPerPlayer = 400, -- transparent placement limit with reclaim controls, never silent deletion
	ropeMaxSegmentLength = 24,
	renderRadius = 160,
}

-- 06. Missions
Config.Missions = {
	nearbyRescueRewardCoins = 40,
	nearbyRescueCooldownSeconds = 120,
}

-- 20. Saving (Roblox DataStore limits documented in source S06)
Config.Save = {
	autosaveSeconds = 90,
	maxRetries = 5,
	retryBaseSeconds = 1,
	sessionLockStaleSeconds = 600,
}

-- Remote rate limiting (19: rate-limit repeated calls)
Config.RateLimit = {
	interactPerSecond = 6,
	placePerSecond = 3,
	partyPerSecond = 2,
}

return Config
