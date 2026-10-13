--!strict
-- World, shelter, creature and mission definitions (sections 04, 06, 10, 13).
-- Status labels: SLICE = built in Milestone 1 blockout; PLANNED = specified, not built.
-- Coordinates are blockout studs (PROPOSED 4-stud kit grid, 6-stud adult rig). Pure data module.

export type V3 = { x: number, y: number, z: number }

local WorldDefs = {}

WorldDefs.CORRIDOR_WIDTH = 12 -- rescue-width main routes (section 18)
WorldDefs.CORRIDOR_HEIGHT = 11

-- Regions ---------------------------------------------------------------------------------------
WorldDefs.Regions = {
	{ id = "R00", name = "Surface Survey Depot", danger = 0.0, inSlice = true, shelterId = nil,
		landmarks = { "R00.mission_board", "R00.equipment_room", "R00.descent_ramp" } },
	{ id = "R01", name = "Old Quarry", danger = 0.3, inSlice = true, shelterId = "S01.worker_alcove",
		landmarks = { "R01.split_pier", "R01.sloped_gallery", "R01.rusted_pulley", "R01.survey_board" } },
	{ id = "R02", name = "Ossuary Galleries", danger = 0.4, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R03", name = "Flooded Works", danger = 0.5, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R04", name = "Abandoned Survey Station", danger = 0.55, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R05", name = "Shifting Crossroads", danger = 0.6, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R06", name = "Buried Paris", danger = 0.65, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R07", name = "Inverted Archive", danger = 0.7, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R08", name = "Memory Houses", danger = 0.75, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R09", name = "The Survey Heart", danger = 0.85, inSlice = false, shelterId = nil, landmarks = {} },
}

function WorldDefs.region(id: string)
	for _, r in WorldDefs.Regions do
		if r.id == id then
			return r
		end
	end
	return nil
end

-- Old Quarry blockout graph. Chambers are boxes; corridors join chambers along one axis.
-- Loops: entry -> pier -> pulley -> rubble -> slope -> pier, and pier -> alcove -> loop -> pulley.
WorldDefs.Chambers = {
	{ id = "R01.survey_board", regionId = "R01", pos = { x = 0, y = 0, z = 150 }, size = { x = 28, y = 12, z = 24 }, label = "Survey Board" },
	{ id = "R01.split_pier", regionId = "R01", pos = { x = 0, y = 0, z = 230 }, size = { x = 32, y = 14, z = 32 }, label = "Split Pier" },
	{ id = "R01.sloped_gallery", regionId = "R01", pos = { x = -84, y = 0, z = 230 }, size = { x = 28, y = 16, z = 28 }, label = "Sloped Gallery" },
	{ id = "R01.rubble_room", regionId = "R01", pos = { x = -84, y = 0, z = 330 }, size = { x = 32, y = 12, z = 28 }, label = "Rubble Workings" },
	{ id = "R01.rusted_pulley", regionId = "R01", pos = { x = 0, y = 0, z = 330 }, size = { x = 30, y = 18, z = 30 }, label = "Rusted Pulley" },
	{ id = "R01.east_loop", regionId = "R01", pos = { x = 92, y = 0, z = 330 }, size = { x = 24, y = 12, z = 24 }, label = "East Workings" },
	{ id = "R01.alcove_exterior", regionId = "R01", pos = { x = 92, y = 0, z = 230 }, size = { x = 24, y = 12, z = 24 }, label = "Worker's Alcove" },
}

WorldDefs.Corridors = {
	{ from = "R01.survey_board", to = "R01.split_pier" },
	{ from = "R01.split_pier", to = "R01.rusted_pulley" }, -- long straight: Knocker line-charge route
	{ from = "R01.split_pier", to = "R01.sloped_gallery" },
	{ from = "R01.sloped_gallery", to = "R01.rubble_room" },
	{ from = "R01.rubble_room", to = "R01.rusted_pulley" }, -- noisy rubble route: Scrabbler
	{ from = "R01.rusted_pulley", to = "R01.east_loop" },
	{ from = "R01.split_pier", to = "R01.alcove_exterior" }, -- main gate side
	{ from = "R01.alcove_exterior", to = "R01.east_loop" }, -- side crack side
}

-- Surface depot and descent (R00).
WorldDefs.Depot = {
	courtyard = { pos = { x = 0, y = 60, z = 0 }, size = { x = 70, y = 1, z = 60 } },
	equipmentRoom = { pos = { x = -24, y = 60, z = -18 }, size = { x = 20, y = 12, z = 18 } },
	missionBoard = { x = 10, y = 64, z = -20 },
	ramp = { top = { x = 0, y = 60, z = 30 }, bottom = { x = 0, y = 0, z = 138 } },
	spawn = { x = 0, y = 63, z = -6 },
}

-- Shelters ----------------------------------------------------------------------------------------
WorldDefs.Shelters = {
	["S01.worker_alcove"] = {
		id = "S01.worker_alcove",
		family = "quarry_alcove",
		regionId = "R01",
		name = "Worker's Alcove",
		exteriorDoor = { x = 92, y = 0, z = 230 },
		entrances = {
			{ id = "main_gate", requiredUpgrade = "gate_repair", requiredStage = 2 },
			{ id = "side_crack", requiredUpgrade = "crack_boarding", requiredStage = 1 },
		},
		safetyUpgrades = {
			gate_repair = { maxStage = 2, costPerStage = {
				{ ["mat.plank"] = 2 },
				{ ["mat.plank"] = 2, ["mat.bracket"] = 2 },
			} },
			crack_boarding = { maxStage = 1, costPerStage = { { ["mat.plank"] = 3, ["mat.bracket"] = 1 } } },
		},
		functionalUpgrades = {
			workbench = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
			better_lighting = { maxStage = 1, costPerStage = { { ["power.cell"] = 1, ["mat.fastener"] = 1 } } },
		},
	},
}
WorldDefs.StartShelterId = "S01.worker_alcove"
-- PROPOSED: before registering any shelter, a new player's "last shelter" spawn is the surface depot.
WorldDefs.DepotPseudoShelterId = "R00.depot"

-- Scavenging sites (section 08: organic acquisition paths; a reachable opportunity with risk, not a kit).
WorldDefs.ScavengeSites = {
	{ id = "R01.scav.board_crate", regionId = "R01", pos = { x = -11, y = 1, z = 158 }, requiresLight = false,
		respawnSeconds = 600, contents = { ["med.cloth_dressing"] = 1, ["power.cell"] = 1 } },
	{ id = "R01.scav.pier_sack", regionId = "R01", pos = { x = 12, y = 1, z = 240 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.fabric"] = 2, ["mat.chalk_fragment"] = 3 } },
	{ id = "R01.scav.slope_toolbox", regionId = "R01", pos = { x = -92, y = 1, z = 240 }, requiresLight = true,
		respawnSeconds = 900, contents = { ["mat.bracket"] = 2, ["mat.fastener"] = 2, ["tool.iron_bar"] = 1 } },
	{ id = "R01.scav.rubble_planks", regionId = "R01", pos = { x = -96, y = 1, z = 338 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.plank"] = 3 } },
	{ id = "R01.scav.pulley_case", regionId = "R01", pos = { x = 10, y = 1, z = 340 }, requiresLight = true,
		respawnSeconds = 1200, contents = { ["med.bandage"] = 1, ["treasure.brass_rule"] = 1 } },
	{ id = "R01.scav.east_shelf", regionId = "R01", pos = { x = 100, y = 1, z = 338 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.plank"] = 2, ["mat.bracket"] = 1, ["power.cell"] = 1 } },
}

-- Unique per-player treasure (section 14: each player physically claims their own copy).
WorldDefs.UniquePickups = {
	{ id = "R01.unique.survey_tag", itemId = "treasure.survey_tag", pos = { x = -6, y = 1, z = 344 }, discoveryId = "R01.found_survey_tag" },
}

-- Rescue spawn candidates (M01). Each must be reachable from the shelter on the stable graph.
WorldDefs.RescueSpawns = {
	{ id = "R01.rescue.rubble", chamberId = "R01.rubble_room", pos = { x = -94, y = 1, z = 322 }, cue = "dropped_lamp" },
	{ id = "R01.rescue.slope", chamberId = "R01.sloped_gallery", pos = { x = -92, y = 1, z = 222 }, cue = "chalk_scrawl" },
	{ id = "R01.rescue.pulley", chamberId = "R01.rusted_pulley", pos = { x = -8, y = 1, z = 322 }, cue = "rope_end" },
	{ id = "R01.rescue.east", chamberId = "R01.east_loop", pos = { x = 98, y = 1, z = 324 }, cue = "dropped_lamp" },
}

-- Creatures (section 10). status: SLICE or PLANNED.
WorldDefs.Creatures = {
	C01_Sidelooker = { id = "C01", name = "Sidelooker", status = "SLICE", damaging = false, killable = false,
		researchEvidence = { "seen", "seen_retreat_when_watched", "seen_three_locations", "sketch_compared" } },
	C02_BorrowedMiner = { id = "C02", name = "Borrowed Miner", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C03_WickMoth = { id = "C03", name = "Wick Moth", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C04_ChalkHand = { id = "C04", name = "Chalk Hand", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C05_Scrabbler = { id = "C05", name = "Scrabbler", status = "SLICE", damaging = true, killable = true,
		health = 60, damage = 18, walkSpeed = 9, rushSpeed = 22, windupSeconds = 1.1, hearingRadius = 45, sightRadius = 40,
		researchEvidence = { "seen", "heard_scrape", "escaped_by_breaking_sight", "stunned_or_killed" } },
	C06_Wader = { id = "C06", name = "Wader", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C07_Knocker = { id = "C07", name = "Knocker", status = "SLICE", damaging = true, killable = false,
		damage = 30, knockCount = 3, knockInterval = 0.7, chargeSpeed = 34, chargeMaxDistance = 110, stunSeconds = 4,
		researchEvidence = { "seen", "heard_three_knocks", "dodged_at_junction", "stunned_window" } },
	C08_LanternThief = { id = "C08", name = "Lantern Thief", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C09_Procession = { id = "C09", name = "Procession", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C10_FalseCompanion = { id = "C10", name = "False Companion", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C11_FoldedSurveyor = { id = "C11", name = "Folded Surveyor", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C12_Cartographer = { id = "C12", name = "Cartographer", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
}

-- Characters (section 05). Only N01 has a Milestone 1 placeholder presence.
WorldDefs.Characters = {
	N01 = { name = "Mara Voss", role = "expedition coordinator", status = "SLICE_PLACEHOLDER", pos = { x = 14, y = 60, z = -20 } },
	N02 = { name = "Dr Luc Moreau", role = "historian", status = "PLANNED" },
	N03 = { name = "Ines Vidal", role = "quartermaster", status = "PLANNED" },
	N04 = { name = "Amadou Diallo", role = "engineer", status = "PLANNED" },
	N05 = { name = "Elise Renaud", role = "missing survey lead", status = "PLANNED" },
	N06 = { name = "Noah Perrin", role = "rescued courier", status = "PLANNED" },
}

-- Missions (section 06).
WorldDefs.Missions = {
	M01 = { name = "Nearby Rescue", status = "SLICE", estimate = "5-15 min", risk = "low" },
	M02 = { name = "Missing Survey Cache", status = "PLANNED" },
	M03 = { name = "Medical Delivery", status = "PLANNED" },
	M04 = { name = "Power Restoration", status = "PLANNED" },
	M05 = { name = "Waterworks Passage", status = "PLANNED" },
	M06 = { name = "False Signal", status = "PLANNED" },
	M07 = { name = "Creature Observation", status = "PLANNED" },
	M08 = { name = "Route Survey", status = "PLANNED" },
	M09 = { name = "Shelter Establishment", status = "PLANNED" },
	M10 = { name = "Deep Treasure", status = "PLANNED" },
	M11 = { name = "Lost Belongings", status = "PLANNED" },
	M12 = { name = "Anomaly Chain", status = "PLANNED" },
}

function WorldDefs.chamber(id: string)
	for _, c in WorldDefs.Chambers do
		if c.id == id then
			return c
		end
	end
	return nil
end

return WorldDefs
