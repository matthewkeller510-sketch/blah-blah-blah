--!strict
-- Tunable values for the Milestone 1 systems slice.
-- Every number here is a TUNE starting value from the specification (sections 03, 07, 08, 09, 11)
-- and requires playtesting on real phones, tablets and PCs. Nothing here is a fixed promise.
-- This module has no Roblox dependencies so it can be unit-tested outside Studio.

local Config = {}

Config.SCHEMA_VERSION = 2 -- must equal Profile.CURRENT_VERSION (a test checks it)

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
	-- Milestone 3 (docs/MILESTONE-3.md 4.4)
	medicalDeliveryBaseCoins = 10,
	medicalDeliveryCoinsPerItem = 10,
	medicalDeliveryMaxItems = 3,
	medicalDeliveryCooldownSeconds = 180,
	powerRestorationCoins = 50,
	waterworksCoins = 25,
	waterworksCooldownSeconds = 300,
	shelterEstablishmentCoins = 40,
	act2CompletionCoins = 80,
	lostBelongingsXpCooldownSeconds = 900, -- M11: own-recovery experience at most this often (relog cannot farm it)
}

-- 04 / F08. Variable pockets (docs/MILESTONE-3.md section 3). TUNE.
Config.Pockets = {
	cycleSeconds = 600, -- a change is attempted at most once per cycle, and only when the pocket is empty
	telegraphSeconds = 20, -- survey clicks and dust at both mouths before any change; entering aborts it
	occupancyMargin = 6, -- studs added around a pocket's bounds when checking for players, survivors, bags, ropes
	checkSeconds = 5,
}

-- 07/08. Injury penalty (PROPOSED, D40): never affects walking (F05). Bandages and splints remove it.
Config.Injury = {
	sprintSpeedMultiplier = 0.85,
	staminaRegenMultiplier = 0.85,
}

-- 08/09. Lanterns and flares (PROPOSED/TUNE)
Config.Lantern = {
	exposureMultiplier = 1.5, -- an open lantern widens how far creatures notice its carrier
	shieldedBrightness = 0.45, -- brightness multiplier with the shutters closed (range drops to shieldedRange)
}
Config.Flare = {
	maxActivePerPlayer = 2,
	placeDistance = 5,
}

-- 09 / F24. Field experience with diminishing returns (D37). TUNE.
Config.Progression = {
	rankDivisor = 50, -- rank = floor(sqrt(xp / rankDivisor))
	decay = 0.85, -- bonus = cap * (1 - decay ^ rank)
	maxStaminaCap = 15,
	maxHealthCap = 15,
	xp = { discovery = 5, shelter = 20, research = 10, story = 25, mission = 10, bag = 5 },
}

-- 10. Milestone 3 creature tuning (TUNE)
Config.Creatures = {
	mothRangeFactor = 0.4, -- a clinging Wick Moth swarm shortens the beam to this fraction
	mothDarkSeconds = 3, -- light off this long disperses the swarm
	minerRhythmSeconds = 1.5, -- the Borrowed Miner's exact work rhythm
	chalkHandIntervalSeconds = 120, -- at most one false mark per player per interval
	thiefDamage = 20,
	thiefDecoyRadius = 30,
	thiefDecoySeconds = 20,
	thiefLoseSightSeconds = 4,
}

-- 12. Milestone 3 puzzle timings (TUNE)
Config.Puzzles = {
	stationPowerSeconds = 1200, -- P03 power lasts this long, then trips only when the generator room is empty
	fuseInsertSeconds = 3,
	fuseWrongBoxSeconds = 4, -- a wrong box costs time, never health, and returns the fuse
	pulleyDropSeconds = 300, -- P04 grate drops this long after unlatching, only when nobody is under or behind it
	sluiceRefloodSeconds = 600,
	pulleySlipSeconds = 15, -- a full basket alone (no latch, no lever) holds the grate this long
	pulleyLeverSeconds = 30, -- one "hold the lever" action keeps the grate up this long
	sluiceLoudness = 3, -- each wheel turn's splash, as a multiple of the Wader's hearing radius
}

-- 20. Saving (Roblox DataStore limits documented in source S06)
Config.Save = {
	autosaveSeconds = 90,
	maxRetries = 5,
	retryBaseSeconds = 1,
	-- A live session refreshes its lock every autosave (90 s), so a lock older than about three autosaves belongs to
	-- a crashed server. Kept short so a crash does not lock the player out for long.
	sessionLockStaleSeconds = 300,
}

-- Remote rate limiting (19: rate-limit repeated calls)
Config.RateLimit = {
	interactPerSecond = 6,
	placePerSecond = 3,
	partyPerSecond = 2,
}

return Config
