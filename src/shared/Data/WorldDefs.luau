--!strict
-- World, shelter, puzzle, creature and mission definitions (sections 04, 06, 10, 12, 13).
-- Status labels: SLICE = built (greybox) in Milestones 1-2; PLANNED = specified, not built.
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
	{ id = "R02", name = "Ossuary Galleries", danger = 0.4, inSlice = true, shelterId = "S02.inspection_office",
		landmarks = { "R02.bone_gate", "R02.plaque_hall", "R02.lantern_crypt", "R02.sealed_chapel" } },
	{ id = "R03", name = "Flooded Works", danger = 0.5, inSlice = true, shelterId = "S03.pump_platform",
		landmarks = { "R03.pump_gallery", "R03.sluice", "R03.cistern", "R03.silt_loop" } },
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

-- True for underground regions where expedition rules apply (bags, checkpoints, creatures, markers).
function WorldDefs.isTunnel(regionId: string?): boolean
	return regionId ~= nil and regionId ~= "R00" and string.sub(regionId, 1, 1) == "R"
end

-- Blockout graph. Chambers are boxes; corridors join chambers along one horizontal axis. A corridor between
-- chambers at different heights is built as a sloped gallery.
-- R01 loops: board -> pier -> pulley -> rubble -> slope -> pier, and pier -> alcove -> east -> pulley.
-- R02 (y = -24) is reached down a slope north of the rubble workings; R03 (y = -44) north of the long ossuary.
WorldDefs.Chambers = {
	-- R01 Old Quarry
	{ id = "R01.survey_board", regionId = "R01", pos = { x = 0, y = 0, z = 150 }, size = { x = 28, y = 12, z = 24 }, label = "Survey Board" },
	{ id = "R01.split_pier", regionId = "R01", pos = { x = 0, y = 0, z = 230 }, size = { x = 32, y = 14, z = 32 }, label = "Split Pier" },
	{ id = "R01.sloped_gallery", regionId = "R01", pos = { x = -84, y = 0, z = 230 }, size = { x = 28, y = 16, z = 28 }, label = "Sloped Gallery" },
	{ id = "R01.rubble_room", regionId = "R01", pos = { x = -84, y = 0, z = 330 }, size = { x = 32, y = 12, z = 28 }, label = "Rubble Workings" },
	{ id = "R01.rusted_pulley", regionId = "R01", pos = { x = 0, y = 0, z = 330 }, size = { x = 30, y = 18, z = 30 }, label = "Rusted Pulley" },
	{ id = "R01.east_loop", regionId = "R01", pos = { x = 92, y = 0, z = 330 }, size = { x = 24, y = 12, z = 24 }, label = "East Workings" },
	{ id = "R01.alcove_exterior", regionId = "R01", pos = { x = 92, y = 0, z = 230 }, size = { x = 24, y = 12, z = 24 }, label = "Worker's Alcove" },
	-- R02 Ossuary Galleries
	{ id = "R02.bone_gate", regionId = "R02", pos = { x = -84, y = -24, z = 440 }, size = { x = 28, y = 14, z = 28 }, label = "Bone Gate" },
	{ id = "R02.plaque_hall", regionId = "R02", pos = { x = -84, y = -24, z = 530 }, size = { x = 30, y = 14, z = 40 }, label = "Hall of Plaques" },
	{ id = "R02.lantern_crypt", regionId = "R02", pos = { x = -174, y = -24, z = 530 }, size = { x = 26, y = 12, z = 26 }, label = "Lantern Crypt" },
	{ id = "R02.inspection_room", regionId = "R02", pos = { x = -174, y = -24, z = 440 }, size = { x = 24, y = 12, z = 24 }, label = "Inspection Office" },
	{ id = "R02.sealed_chapel", regionId = "R02", pos = { x = 6, y = -24, z = 530 }, size = { x = 24, y = 16, z = 24 }, label = "Sealed Chapel" },
	{ id = "R02.ossuary_long", regionId = "R02", pos = { x = -84, y = -24, z = 620 }, size = { x = 24, y = 12, z = 24 }, label = "Long Ossuary" },
	-- R03 Flooded Works
	{ id = "R03.pump_gallery", regionId = "R03", pos = { x = -84, y = -44, z = 720 }, size = { x = 32, y = 16, z = 32 }, label = "Old Pumps", dry = true },
	{ id = "R03.sluice", regionId = "R03", pos = { x = -84, y = -44, z = 820 }, size = { x = 28, y = 14, z = 40 }, label = "Sluice Channel" },
	{ id = "R03.cistern", regionId = "R03", pos = { x = 6, y = -44, z = 820 }, size = { x = 30, y = 14, z = 30 }, label = "Cistern" },
	{ id = "R03.pump_platform", regionId = "R03", pos = { x = -174, y = -44, z = 820 }, size = { x = 24, y = 14, z = 24 }, label = "Pump Platform", dry = true },
	{ id = "R03.silt_loop", regionId = "R03", pos = { x = -174, y = -44, z = 720 }, size = { x = 24, y = 12, z = 24 }, label = "Silt Works" },
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
	-- descent into the ossuary
	{ from = "R01.rubble_room", to = "R02.bone_gate" },
	{ from = "R02.bone_gate", to = "R02.plaque_hall" },
	{ from = "R02.plaque_hall", to = "R02.lantern_crypt" },
	{ from = "R02.lantern_crypt", to = "R02.inspection_room" },
	{ from = "R02.inspection_room", to = "R02.bone_gate" },
	{ from = "R02.plaque_hall", to = "R02.sealed_chapel", gate = "P01" }, -- opened by the inscription puzzle
	{ from = "R02.plaque_hall", to = "R02.ossuary_long" },
	-- descent into the waterworks
	{ from = "R02.ossuary_long", to = "R03.pump_gallery" },
	{ from = "R03.pump_gallery", to = "R03.sluice" },
	{ from = "R03.sluice", to = "R03.cistern", gate = "P02" }, -- too deep to wade until the pumps are routed
	{ from = "R03.sluice", to = "R03.pump_platform" },
	{ from = "R03.pump_platform", to = "R03.silt_loop" },
	{ from = "R03.silt_loop", to = "R03.pump_gallery" },
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
-- doorSide is the exterior chamber wall that holds the shelter entrance (never a side with a corridor).
-- entrances[1] is shown on the interior's west wall, entrances[2] on its north wall.
WorldDefs.Shelters = {
	["S01.worker_alcove"] = {
		id = "S01.worker_alcove",
		family = "quarry_alcove",
		regionId = "R01",
		name = "Worker's Alcove",
		exteriorChamberId = "R01.alcove_exterior",
		doorSide = "E",
		theme = "limestone",
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
	["S02.inspection_office"] = {
		id = "S02.inspection_office",
		family = "inspection_office",
		regionId = "R02",
		name = "Inspection Office",
		exteriorChamberId = "R02.inspection_room",
		doorSide = "W",
		theme = "office",
		entrances = {
			{ id = "office_door", requiredUpgrade = "door_reinforcement", requiredStage = 2 },
			{ id = "air_vent", requiredUpgrade = "vent_grille", requiredStage = 1 },
		},
		safetyUpgrades = {
			door_reinforcement = { maxStage = 2, costPerStage = {
				{ ["mat.plank"] = 2 },
				{ ["mat.bracket"] = 2, ["mat.fastener"] = 1 },
			} },
			vent_grille = { maxStage = 1, costPerStage = { { ["mat.bracket"] = 2 } } },
		},
		functionalUpgrades = {
			workbench = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
			supply_shelves = { maxStage = 1, costPerStage = { { ["mat.plank"] = 3 } } },
		},
	},
	["S03.pump_platform"] = {
		id = "S03.pump_platform",
		family = "raised_pump_platform",
		regionId = "R03",
		name = "Raised Pump Platform",
		exteriorChamberId = "R03.pump_platform",
		doorSide = "W",
		theme = "ironwork",
		entrances = {
			{ id = "ladder_hatch", requiredUpgrade = "hatch_bolts", requiredStage = 2 },
			{ id = "open_pipe", requiredUpgrade = "pipe_plug", requiredStage = 1 },
		},
		safetyUpgrades = {
			hatch_bolts = { maxStage = 2, costPerStage = {
				{ ["mat.bracket"] = 1 },
				{ ["mat.bracket"] = 2, ["mat.fastener"] = 1 },
			} },
			pipe_plug = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
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
	{ id = "R02.scav.crypt_box", regionId = "R02", pos = { x = -182, y = -23, z = 538 }, requiresLight = true,
		respawnSeconds = 1200, contents = { ["med.bandage"] = 1, ["nav.sign"] = 2, ["power.cell"] = 1 } },
	{ id = "R02.scav.plaque_satchel", regionId = "R02", pos = { x = -72, y = -23, z = 546 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.fabric"] = 2, ["mat.fastener"] = 1, ["nav.rope"] = 2 } },
	{ id = "R02.scav.inspection_locker", regionId = "R02", pos = { x = -166, y = -23, z = 448 }, requiresLight = true,
		respawnSeconds = 3600, contents = { ["light.expedition_flashlight"] = 1, ["power.cell"] = 1 } },
	{ id = "R02.scav.long_niche", regionId = "R02", pos = { x = -76, y = -23, z = 628 }, requiresLight = false,
		respawnSeconds = 1200, contents = { ["mat.plank"] = 2, ["treasure.lead_seal"] = 1 } },
	{ id = "R02.scav.chapel_chest", regionId = "R02", pos = { x = 12, y = -23, z = 538 }, requiresLight = false,
		respawnSeconds = 3600, contents = { ["tool.stun_device"] = 1, ["med.bandage"] = 1 } },
	{ id = "R03.scav.pump_toolbag", regionId = "R03", pos = { x = -74, y = -43, z = 712 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.bracket"] = 2, ["mat.fastener"] = 2 } },
	{ id = "R03.scav.silt_crate", regionId = "R03", pos = { x = -180, y = -42, z = 728 }, requiresLight = true,
		respawnSeconds = 3600, contents = { ["light.compact_headlamp"] = 1, ["power.cell"] = 1 } },
	{ id = "R03.scav.sluice_bundle", regionId = "R03", pos = { x = -74, y = -42, z = 834 }, requiresLight = false,
		respawnSeconds = 900, contents = { ["mat.plank"] = 3, ["nav.rope"] = 2 } },
	{ id = "R03.scav.cistern_cache", regionId = "R03", pos = { x = 14, y = -42, z = 828 }, requiresLight = false,
		respawnSeconds = 1800, contents = { ["treasure.brass_rule"] = 2, ["med.bandage"] = 1, ["power.cell"] = 2 } },
}

-- Unique per-player pickups (section 14: each player physically claims their own copy).
WorldDefs.UniquePickups = {
	{ id = "R01.unique.survey_tag", itemId = "treasure.survey_tag", pos = { x = -6, y = 1, z = 344 }, discoveryId = "R01.found_survey_tag", label = "Expedition survey tag" },
	{ id = "R02.unique.old_tag", itemId = "treasure.old_expedition_tag", pos = { x = 0, y = -23, z = 538 }, discoveryId = "R02.found_old_tag", label = "Old expedition tag" },
}

-- Hiding niches (F07: hiding is a primary defense). Facing points out of the niche into the room.
WorldDefs.HidingSpots = {
	{ id = "hide.R01.rubble", pos = { x = -98, y = 0, z = 322 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R01.slope", pos = { x = -96, y = 0, z = 220 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R01.pulley", pos = { x = 13, y = 0, z = 318 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R01.pier", pos = { x = -14, y = 0, z = 244 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R02.plaque", pos = { x = -97, y = -24, z = 545 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R02.crypt", pos = { x = -185, y = -24, z = 522 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R02.long", pos = { x = -94, y = -24, z = 628 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R03.pumps", pos = { x = -98, y = -44, z = 708 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R03.silt", pos = { x = -184, y = -44, z = 712 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R03.sluice", pos = { x = -96, y = -44, z = 836 }, facing = { x = 1, y = 0, z = 0 } },
}

-- Puzzles (section 12). P01-P02 SLICE; P03-P06 PLANNED.
WorldDefs.Puzzles = {
	P01 = {
		id = "P01", name = "Inscription alignment", status = "SLICE", regionId = "R02",
		plaque = { x = -90, y = -24, z = 540 }, -- rotatable plaque on a pedestal
		carving = { x = -94, y = -24, z = 510.6 }, -- target symbol on the south wall (faces north)
		wornCarving = { x = -76, y = -24, z = 549.4 }, -- worn duplicate on the north wall (faces south)
		gate = { x = -62, y = -24, z = 530 }, -- blocks the corridor to the sealed chapel
		orientations = 4,
	},
	P02 = {
		id = "P02", name = "Pump routing", status = "SLICE", regionId = "R03",
		valves = { { x = -69, y = -40, z = 712 }, { x = -69, y = -40, z = 720 }, { x = -69, y = -40, z = 728 } },
		clue = { x = -69, y = -39, z = 733 },
		gauge = { x = -69, y = -39, z = 705 }, -- south of the valves, below the wall pipes
		reset = { x = -69, y = -42, z = 708.5 },
		barrier = { x = -20, y = -44, z = 820 }, -- deep water in the corridor to the cistern
		refloodSeconds = 600,
	},
	P03 = { id = "P03", name = "Fuse bridge", status = "PLANNED" },
	P04 = { id = "P04", name = "Weight and pulley", status = "PLANNED" },
	P05 = { id = "P05", name = "Echo sequence", status = "PLANNED" },
	P06 = { id = "P06", name = "Impossible doorway", status = "PLANNED" },
}

-- Rescue spawn candidates (M01). Offered only within a few chambers of the player's last shelter.
WorldDefs.RescueSpawns = {
	{ id = "R01.rescue.rubble", chamberId = "R01.rubble_room", pos = { x = -94, y = 1, z = 322 }, cue = "dropped_lamp" },
	{ id = "R01.rescue.slope", chamberId = "R01.sloped_gallery", pos = { x = -92, y = 1, z = 222 }, cue = "chalk_scrawl" },
	{ id = "R01.rescue.pulley", chamberId = "R01.rusted_pulley", pos = { x = -8, y = 1, z = 322 }, cue = "rope_end" },
	{ id = "R01.rescue.east", chamberId = "R01.east_loop", pos = { x = 98, y = 1, z = 324 }, cue = "dropped_lamp" },
	{ id = "R02.rescue.crypt", chamberId = "R02.lantern_crypt", pos = { x = -180, y = -23, z = 524 }, cue = "dropped_lamp" },
	{ id = "R02.rescue.long", chamberId = "R02.ossuary_long", pos = { x = -90, y = -23, z = 614 }, cue = "chalk_scrawl" },
	{ id = "R03.rescue.silt", chamberId = "R03.silt_loop", pos = { x = -168, y = -42, z = 714 }, cue = "rope_end" },
}

-- M02 cache spots: the objective text describes the landmark, never a map marker.
WorldDefs.CacheSpots = {
	{ id = "cache.pier", chamberId = "R01.split_pier", pos = { x = 8, y = 1, z = 222 }, clue = "beside the pier that is split down the middle" },
	{ id = "cache.pulley", chamberId = "R01.rusted_pulley", pos = { x = -10, y = 1, z = 338 }, clue = "under the wheel that no longer turns" },
	{ id = "cache.slope", chamberId = "R01.sloped_gallery", pos = { x = -74, y = 1, z = 238 }, clue = "where the ceiling leans down toward the floor" },
	{ id = "cache.plaques", chamberId = "R02.plaque_hall", pos = { x = -94, y = -23, z = 518 }, clue = "beneath the wall of numbered plaques" },
	{ id = "cache.crypt", chamberId = "R02.lantern_crypt", pos = { x = -166, y = -23, z = 522 }, clue = "in the crypt where every lamp niche is empty" },
	{ id = "cache.pumps", chamberId = "R03.pump_gallery", pos = { x = -75, y = -43, z = 733 }, clue = "beside the three iron valves" },
}

-- Creatures (section 10). status: SLICE or PLANNED.
WorldDefs.Creatures = {
	C01_Sidelooker = { id = "C01", name = "Sidelooker", status = "SLICE", damaging = false, killable = false,
		researchEvidence = { "seen", "seen_retreat_when_watched", "seen_three_locations", "sketch_compared" },
		hints = { "Look for a tall shape at the edge of a room.", "Watch it deliberately.", "Sight it in three different places.", "Compare sketches (not yet possible)." } },
	C02_BorrowedMiner = { id = "C02", name = "Borrowed Miner", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C03_WickMoth = { id = "C03", name = "Wick Moth", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C04_ChalkHand = { id = "C04", name = "Chalk Hand", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C05_Scrabbler = { id = "C05", name = "Scrabbler", status = "SLICE", damaging = true, killable = true,
		health = 60, damage = 18, walkSpeed = 9, rushSpeed = 22, windupSeconds = 1.1, hearingRadius = 45, sightRadius = 40,
		homes = { { "R01.rubble_room", "R01.sloped_gallery" }, { "R02.lantern_crypt", "R02.ossuary_long" } },
		researchEvidence = { "seen", "heard_scrape", "escaped_by_breaking_sight", "stunned_or_killed" },
		hints = { "Get a look at it in the rubble.", "Hear the scrape before it rushes.", "Break its line of sight to escape.", "Stun it or bring it down." } },
	C06_Wader = { id = "C06", name = "Wader", status = "SLICE", damaging = true, killable = false,
		damage = 25, walkSpeed = 7, pursueSpeed = 15, hearingRadius = 55, repelSeconds = 6, warnSeconds = 1.6,
		homes = { "R03.sluice", "R03.silt_loop", "R03.cistern" },
		researchEvidence = { "seen", "heard_drag", "evaded_by_silence", "distracted_or_repelled" },
		hints = { "See it standing in the water.", "Hear the dragging step.", "Move silently (crouch or stay dry) while it searches.", "Throw a stone to distract it, or repel it with a stun." } },
	C07_Knocker = { id = "C07", name = "Knocker", status = "SLICE", damaging = true, killable = false,
		damage = 30, knockCount = 3, knockInterval = 0.7, chargeSpeed = 34, chargeMaxDistance = 110, stunSeconds = 4,
		researchEvidence = { "seen", "heard_three_knocks", "dodged_at_junction", "stunned_window" },
		hints = { "Walk the long straight corridor in the quarry.", "Count the knocks.", "Leave the line before the charge.", "Stun it while it is still knocking." } },
	C08_LanternThief = { id = "C08", name = "Lantern Thief", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C09_Procession = { id = "C09", name = "Procession", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C10_FalseCompanion = { id = "C10", name = "False Companion", status = "PLANNED", damaging = false, killable = false, researchEvidence = {} },
	C11_FoldedSurveyor = { id = "C11", name = "Folded Surveyor", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
	C12_Cartographer = { id = "C12", name = "Cartographer", status = "PLANNED", damaging = true, killable = false, researchEvidence = {} },
}

function WorldDefs.creatureById(id: string)
	for _, c in WorldDefs.Creatures do
		if c.id == id then
			return c
		end
	end
	return nil
end

-- Characters (section 05). Only N01 has a placeholder presence (the depot board).
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
	M02 = { name = "Missing Survey Cache", status = "SLICE", estimate = "10-25 min", risk = "low" },
	M03 = { name = "Medical Delivery", status = "PLANNED" },
	M04 = { name = "Power Restoration", status = "PLANNED" },
	M05 = { name = "Waterworks Passage", status = "PLANNED" },
	M06 = { name = "False Signal", status = "PLANNED" },
	M07 = { name = "Creature Observation", status = "SLICE", estimate = "10-30 min", risk = "medium" },
	M08 = { name = "Route Survey", status = "PLANNED" },
	M09 = { name = "Shelter Establishment", status = "PLANNED" },
	M10 = { name = "Deep Treasure", status = "PLANNED" },
	M11 = { name = "Lost Belongings", status = "PLANNED" },
	M12 = { name = "Anomaly Chain", status = "PLANNED" },
}

local chamberIndex: { [string]: any } = {}
for _, c in WorldDefs.Chambers do
	chamberIndex[c.id] = c
end

function WorldDefs.chamber(id: string)
	return chamberIndex[id]
end

-- Chambers adjacent on the corridor graph (gated corridors included; callers check gate state).
function WorldDefs.neighbors(id: string): { string }
	local out = {}
	for _, cor in WorldDefs.Corridors do
		if cor.from == id then
			table.insert(out, cor.to)
		elseif cor.to == id then
			table.insert(out, cor.from)
		end
	end
	return out
end

-- Graph hop distance from `fromId` to every reachable chamber, skipping corridors whose gate is closed.
function WorldDefs.hops(fromId: string, openGates: { [string]: boolean }?): { [string]: number }
	local dist = { [fromId] = 0 }
	local queue = { fromId }
	while #queue > 0 do
		local cur = table.remove(queue, 1)
		for _, cor in WorldDefs.Corridors do
			local other = if cor.from == cur then cor.to elseif cor.to == cur then cor.from else nil
			if other and dist[other] == nil and (cor.gate == nil or (openGates ~= nil and openGates[cor.gate])) then
				dist[other] = dist[cur] + 1
				table.insert(queue, other)
			end
		end
	end
	return dist
end

-- The chamber a shelter (or the depot) hands players to when they step outside.
function WorldDefs.homeChamber(shelterId: string): string
	local s = WorldDefs.Shelters[shelterId]
	return if s then s.exteriorChamberId else "R01.survey_board"
end

return WorldDefs
