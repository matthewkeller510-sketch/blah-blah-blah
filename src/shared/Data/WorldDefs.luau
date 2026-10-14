--!strict
-- World, shelter, puzzle, creature and mission definitions (sections 04, 06, 10, 12, 13).
-- Status labels: SLICE = built (greybox) in Milestones 1-2; PLANNED = specified, not built.
-- Coordinates are blockout studs (PROPOSED 4-stud kit grid, 6-stud adult rig). Pure data module.

export type V3 = { x: number, y: number, z: number }
export type Cost = { [string]: number }
export type Region = {
	id: string,
	name: string,
	danger: number,
	inSlice: boolean,
	shelterId: string?,
	landmarks: { string },
}
export type Chamber = { id: string, regionId: string, pos: V3, size: V3, label: string, dry: boolean? }
-- pocket: a variable pocket (section 04, F08) built by PocketService, never by WorldBuilder; every version keeps
-- the same entry/exit contract, so graph code treats the link as always connected.
export type Corridor = { from: string, to: string, gate: string?, pocket: string? }
export type UpgradeDef = { maxStage: number, costPerStage: { Cost } }
export type Entrance = { id: string, requiredUpgrade: string, requiredStage: number }
export type ShelterDef = {
	id: string,
	family: string,
	regionId: string,
	name: string,
	exteriorChamberId: string,
	doorSide: string,
	theme: string,
	entrances: { Entrance },
	safetyUpgrades: { [string]: UpgradeDef },
	functionalUpgrades: { [string]: UpgradeDef },
}
export type ScavengeSite = {
	id: string,
	regionId: string,
	pos: V3,
	requiresLight: boolean,
	respawnSeconds: number,
	contents: Cost,
}
export type UniquePickup = { id: string, itemId: string, pos: V3, discoveryId: string, label: string }
export type HidingSpot = { id: string, pos: V3, facing: V3 }
-- Puzzle and creature definitions carry type-specific fields, so they keep an open indexer.
export type PuzzleDef = { id: string, name: string, status: string, regionId: string?, [string]: any }
export type RescueSpawn = { id: string, chamberId: string, pos: V3, cue: string }
export type CacheSpot = { id: string, chamberId: string, pos: V3, clue: string }
export type CreatureDef = {
	id: string,
	name: string,
	status: string,
	damaging: boolean,
	killable: boolean,
	researchEvidence: { string },
	hints: { string }?,
	[string]: any,
}
export type CharacterDef = { name: string, role: string, status: string, pos: V3?, rescuePos: V3? }
export type MissionDef = { name: string, status: string, estimate: string?, risk: string? }
export type MissionSpot = { id: string, chamberId: string, pos: V3, clue: string? }
export type Readable = { id: string, chamberId: string, pos: V3, facing: V3, title: string }
export type PocketDef = {
	id: string,
	regionId: string,
	from: string, -- static chamber at one mouth
	to: string, -- static chamber at the other mouth
	axis: string, -- "x" or "z": the axis joining the two mouths
	bounds: { min: V3, max: V3 }, -- covers every version; occupancy uses it plus Config.Pockets.occupancyMargin
	versions: { string },
	migrationAnchor: string, -- static chamber that receives records whose pocket version no longer exists here
	doors: { number }?, -- PK3 only: x positions of the three doors on the doorway room's north wall
	puzzle: string?,
}

local WorldDefs = {}

WorldDefs.CORRIDOR_WIDTH = 12 -- rescue-width main routes (section 18)
WorldDefs.CORRIDOR_HEIGHT = 11

-- Regions ---------------------------------------------------------------------------------------
local Regions: { Region } = {
	{
		id = "R00",
		name = "Surface Survey Depot",
		danger = 0.0,
		inSlice = true,
		shelterId = nil,
		landmarks = { "R00.mission_board", "R00.equipment_room", "R00.descent_ramp" },
	},
	{
		id = "R01",
		name = "Old Quarry",
		danger = 0.3,
		inSlice = true,
		shelterId = "S01.worker_alcove",
		landmarks = { "R01.split_pier", "R01.sloped_gallery", "R01.rusted_pulley", "R01.survey_board" },
	},
	{
		id = "R02",
		name = "Ossuary Galleries",
		danger = 0.4,
		inSlice = true,
		shelterId = "S02.inspection_office",
		landmarks = { "R02.bone_gate", "R02.plaque_hall", "R02.lantern_crypt", "R02.sealed_chapel" },
	},
	{
		id = "R03",
		name = "Flooded Works",
		danger = 0.5,
		inSlice = true,
		shelterId = "S03.pump_platform",
		landmarks = { "R03.pump_gallery", "R03.sluice", "R03.cistern", "R03.silt_loop" },
	},
	{
		id = "R04",
		name = "Abandoned Survey Station",
		danger = 0.55,
		inSlice = true,
		shelterId = "S04.service_office",
		landmarks = { "R04.station_hall", "R04.radio_room", "R04.generator_room", "R04.map_room" },
	},
	{
		id = "R05",
		name = "Shifting Crossroads",
		danger = 0.6,
		inSlice = true,
		shelterId = "S05.stable_junction",
		landmarks = { "R05.south_anchor", "R05.center_anchor", "R05.doorway_room", "R05.junction" },
	},
	{ id = "R06", name = "Buried Paris", danger = 0.65, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R07", name = "Inverted Archive", danger = 0.7, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R08", name = "Memory Houses", danger = 0.75, inSlice = false, shelterId = nil, landmarks = {} },
	{ id = "R09", name = "The Survey Heart", danger = 0.85, inSlice = false, shelterId = nil, landmarks = {} },
}
WorldDefs.Regions = Regions

function WorldDefs.region(id: string): Region?
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
local Chambers: { Chamber } = {
	-- R01 Old Quarry
	{
		id = "R01.survey_board",
		regionId = "R01",
		pos = { x = 0, y = 0, z = 150 },
		size = { x = 28, y = 12, z = 24 },
		label = "Survey Board",
	},
	{
		id = "R01.split_pier",
		regionId = "R01",
		pos = { x = 0, y = 0, z = 230 },
		size = { x = 32, y = 14, z = 32 },
		label = "Split Pier",
	},
	{
		id = "R01.sloped_gallery",
		regionId = "R01",
		pos = { x = -84, y = 0, z = 230 },
		size = { x = 28, y = 16, z = 28 },
		label = "Sloped Gallery",
	},
	{
		id = "R01.rubble_room",
		regionId = "R01",
		pos = { x = -84, y = 0, z = 330 },
		size = { x = 32, y = 12, z = 28 },
		label = "Rubble Workings",
	},
	{
		id = "R01.rusted_pulley",
		regionId = "R01",
		pos = { x = 0, y = 0, z = 330 },
		size = { x = 30, y = 18, z = 30 },
		label = "Rusted Pulley",
	},
	{
		id = "R01.east_loop",
		regionId = "R01",
		pos = { x = 92, y = 0, z = 330 },
		size = { x = 24, y = 12, z = 24 },
		label = "East Workings",
	},
	{
		id = "R01.alcove_exterior",
		regionId = "R01",
		pos = { x = 92, y = 0, z = 230 },
		size = { x = 24, y = 12, z = 24 },
		label = "Worker's Alcove",
	},
	-- R02 Ossuary Galleries
	{
		id = "R02.bone_gate",
		regionId = "R02",
		pos = { x = -84, y = -24, z = 440 },
		size = { x = 28, y = 14, z = 28 },
		label = "Bone Gate",
	},
	{
		id = "R02.plaque_hall",
		regionId = "R02",
		pos = { x = -84, y = -24, z = 530 },
		size = { x = 30, y = 14, z = 40 },
		label = "Hall of Plaques",
	},
	{
		id = "R02.lantern_crypt",
		regionId = "R02",
		pos = { x = -174, y = -24, z = 530 },
		size = { x = 26, y = 12, z = 26 },
		label = "Lantern Crypt",
	},
	{
		id = "R02.inspection_room",
		regionId = "R02",
		pos = { x = -174, y = -24, z = 440 },
		size = { x = 24, y = 12, z = 24 },
		label = "Inspection Office",
	},
	{
		id = "R02.sealed_chapel",
		regionId = "R02",
		pos = { x = 6, y = -24, z = 530 },
		size = { x = 24, y = 16, z = 24 },
		label = "Sealed Chapel",
	},
	{
		id = "R02.ossuary_long",
		regionId = "R02",
		pos = { x = -84, y = -24, z = 620 },
		size = { x = 24, y = 12, z = 24 },
		label = "Long Ossuary",
	},
	-- R03 Flooded Works
	{
		id = "R03.pump_gallery",
		regionId = "R03",
		pos = { x = -84, y = -44, z = 720 },
		size = { x = 32, y = 16, z = 32 },
		label = "Old Pumps",
		dry = true,
	},
	{
		id = "R03.sluice",
		regionId = "R03",
		pos = { x = -84, y = -44, z = 820 },
		size = { x = 28, y = 14, z = 40 },
		label = "Sluice Channel",
	},
	{
		id = "R03.cistern",
		regionId = "R03",
		pos = { x = 6, y = -44, z = 820 },
		size = { x = 30, y = 14, z = 30 },
		label = "Cistern",
	},
	{
		id = "R03.pump_platform",
		regionId = "R03",
		pos = { x = -174, y = -44, z = 820 },
		size = { x = 24, y = 14, z = 24 },
		label = "Pump Platform",
		dry = true,
	},
	{
		id = "R03.silt_loop",
		regionId = "R03",
		pos = { x = -174, y = -44, z = 720 },
		size = { x = 24, y = 12, z = 24 },
		label = "Silt Works",
	},
	-- R01 additions (Milestone 3): the Borrowed Miner's dead end and the room behind the P04 grate
	{
		id = "R01.collapsed_drift",
		regionId = "R01",
		pos = { x = 182, y = 0, z = 330 },
		size = { x = 20, y = 12, z = 20 },
		label = "Collapsed Drift",
	},
	{
		id = "R01.pulley_store",
		regionId = "R01",
		pos = { x = 0, y = 0, z = 420 },
		size = { x = 20, y = 12, z = 20 },
		label = "Pulley Store",
	},
	-- R03 additions (Milestone 3, M05): the Overflow Vault and the long dry route to it
	{
		id = "R03.overflow_vault",
		regionId = "R03",
		pos = { x = -264, y = -44, z = 720 },
		size = { x = 24, y = 14, z = 24 },
		label = "Overflow Vault",
		dry = true,
	},
	{
		id = "R03.drain_gallery",
		regionId = "R03",
		pos = { x = -174, y = -44, z = 630 },
		size = { x = 22, y = 12, z = 22 },
		label = "Drain Gallery",
		dry = true,
	},
	{
		id = "R03.vault_stair",
		regionId = "R03",
		pos = { x = -264, y = -44, z = 630 },
		size = { x = 20, y = 12, z = 20 },
		label = "Vault Stair",
		dry = true,
	},
	-- R04 Abandoned Survey Station (y = -64), reached down a slope north of the Sluice Channel
	{
		id = "R04.station_hall",
		regionId = "R04",
		pos = { x = -84, y = -64, z = 930 },
		size = { x = 32, y = 14, z = 32 },
		label = "Survey Station Hall",
	},
	{
		id = "R04.battery_store",
		regionId = "R04",
		pos = { x = -174, y = -64, z = 930 },
		size = { x = 24, y = 12, z = 24 },
		label = "Battery Store",
	},
	{
		id = "R04.collapsed_adit",
		regionId = "R04",
		pos = { x = -264, y = -64, z = 930 },
		size = { x = 20, y = 12, z = 20 },
		label = "Collapsed Adit",
	},
	{
		id = "R04.radio_room",
		regionId = "R04",
		pos = { x = 6, y = -64, z = 930 },
		size = { x = 26, y = 14, z = 26 },
		label = "Radio Room",
	},
	{
		id = "R04.generator_room",
		regionId = "R04",
		pos = { x = -84, y = -64, z = 1020 },
		size = { x = 30, y = 16, z = 30 },
		label = "Generator Room",
	},
	{
		id = "R04.map_room",
		regionId = "R04",
		pos = { x = 6, y = -64, z = 1020 },
		size = { x = 28, y = 14, z = 28 },
		label = "Map Room",
	},
	{
		id = "R04.service_office",
		regionId = "R04",
		pos = { x = -174, y = -64, z = 1020 },
		size = { x = 24, y = 12, z = 24 },
		label = "Service Office",
	},
	-- R05 Shifting Crossroads (y = -84): stable anchor rooms joined in places by variable pockets (WorldDefs.Pockets)
	{
		id = "R05.south_anchor",
		regionId = "R05",
		pos = { x = 6, y = -84, z = 1120 },
		size = { x = 28, y = 14, z = 28 },
		label = "South Survey Anchor",
	},
	{
		id = "R05.sw_bend",
		regionId = "R05",
		pos = { x = -84, y = -84, z = 1120 },
		size = { x = 24, y = 12, z = 24 },
		label = "Measured Bend",
	},
	{
		id = "R05.west_anchor",
		regionId = "R05",
		pos = { x = -84, y = -84, z = 1210 },
		size = { x = 24, y = 14, z = 24 },
		label = "West Survey Anchor",
	},
	{
		id = "R05.center_anchor",
		regionId = "R05",
		pos = { x = 6, y = -84, z = 1210 },
		size = { x = 28, y = 14, z = 28 },
		label = "Measured Crossing",
	},
	{
		id = "R05.east_anchor",
		regionId = "R05",
		pos = { x = 96, y = -84, z = 1210 },
		size = { x = 24, y = 14, z = 24 },
		label = "East Survey Anchor",
	},
	{
		id = "R05.east_niche",
		regionId = "R05",
		pos = { x = 96, y = -84, z = 1300 },
		size = { x = 22, y = 12, z = 22 },
		label = "Numbered Niche",
	},
	{
		id = "R05.doorway_room",
		regionId = "R05",
		pos = { x = 6, y = -84, z = 1300 },
		size = { x = 40, y = 16, z = 24 },
		label = "Room of Three Doors",
	},
	{
		id = "R05.east_loop",
		regionId = "R05",
		pos = { x = 96, y = -84, z = 1390 },
		size = { x = 24, y = 12, z = 24 },
		label = "Returning Gallery",
	},
	{
		id = "R05.junction",
		regionId = "R05",
		pos = { x = 6, y = -84, z = 1390 },
		size = { x = 28, y = 14, z = 28 },
		label = "Stable Stone Junction",
	},
}
WorldDefs.Chambers = Chambers

local Corridors: { Corridor } = {
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
	-- Milestone 3 ------------------------------------------------------------------------------------
	{ from = "R01.east_loop", to = "R01.collapsed_drift" }, -- the Borrowed Miner's misleading dead end
	{ from = "R01.rusted_pulley", to = "R01.pulley_store", gate = "P04" }, -- grate raised by the counterweight
	{ from = "R03.silt_loop", to = "R03.overflow_vault", gate = "W05" }, -- deep until the sluice gates are set (loud)
	{ from = "R03.silt_loop", to = "R03.drain_gallery" }, -- the long silent route begins
	{ from = "R03.drain_gallery", to = "R03.vault_stair" },
	{ from = "R03.vault_stair", to = "R03.overflow_vault" },
	-- descent into the survey station
	{ from = "R03.sluice", to = "R04.station_hall" },
	{ from = "R04.station_hall", to = "R04.battery_store" },
	{ from = "R04.battery_store", to = "R04.collapsed_adit" },
	{ from = "R04.station_hall", to = "R04.radio_room" },
	{ from = "R04.station_hall", to = "R04.generator_room" },
	{ from = "R04.generator_room", to = "R04.map_room" },
	{ from = "R04.radio_room", to = "R04.map_room" },
	{ from = "R04.generator_room", to = "R04.service_office" },
	{ from = "R04.battery_store", to = "R04.service_office" },
	-- descent into the shifting crossroads
	{ from = "R04.map_room", to = "R05.south_anchor" },
	{ from = "R05.south_anchor", to = "R05.sw_bend" },
	{ from = "R05.sw_bend", to = "R05.west_anchor" },
	{ from = "R05.west_anchor", to = "R05.center_anchor" },
	{ from = "R05.center_anchor", to = "R05.doorway_room" },
	{ from = "R05.east_anchor", to = "R05.east_niche" },
	{ from = "R05.east_niche", to = "R05.east_loop" },
	{ from = "R05.east_loop", to = "R05.junction" },
	{ from = "R05.south_anchor", to = "R05.center_anchor", pocket = "PK1" },
	{ from = "R05.center_anchor", to = "R05.east_anchor", pocket = "PK2" },
	{ from = "R05.doorway_room", to = "R05.junction", pocket = "PK3" }, -- also puzzle P06
}
WorldDefs.Corridors = Corridors

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
local Shelters: { [string]: ShelterDef } = {
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
			gate_repair = {
				maxStage = 2,
				costPerStage = {
					{ ["mat.plank"] = 2 },
					{ ["mat.plank"] = 2, ["mat.bracket"] = 2 },
				},
			},
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
			door_reinforcement = {
				maxStage = 2,
				costPerStage = {
					{ ["mat.plank"] = 2 },
					{ ["mat.bracket"] = 2, ["mat.fastener"] = 1 },
				},
			},
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
			hatch_bolts = {
				maxStage = 2,
				costPerStage = {
					{ ["mat.bracket"] = 1 },
					{ ["mat.bracket"] = 2, ["mat.fastener"] = 1 },
				},
			},
			pipe_plug = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
		},
		functionalUpgrades = {
			workbench = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
			better_lighting = { maxStage = 1, costPerStage = { { ["power.cell"] = 1, ["mat.fastener"] = 1 } } },
		},
	},
	["S04.service_office"] = {
		id = "S04.service_office",
		family = "survey_station_room",
		regionId = "R04",
		name = "Reinforced Service Office",
		exteriorChamberId = "R04.service_office",
		doorSide = "W",
		theme = "office",
		entrances = {
			{ id = "steel_door", requiredUpgrade = "door_bars", requiredStage = 2 },
			{ id = "cable_duct", requiredUpgrade = "duct_cover", requiredStage = 1 },
		},
		safetyUpgrades = {
			door_bars = {
				maxStage = 2,
				costPerStage = {
					{ ["mat.bracket"] = 2 },
					{ ["mat.plank"] = 2, ["mat.fastener"] = 2 },
				},
			},
			duct_cover = { maxStage = 1, costPerStage = { { ["mat.bracket"] = 1, ["mat.fastener"] = 2 } } },
		},
		functionalUpgrades = {
			workbench = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
			-- Also requires the private breaker repair (M04); see docs/MILESTONE-3.md 4.1.
			station_power = { maxStage = 1, costPerStage = { { ["tool.fuse_kit"] = 1 } } },
		},
	},
	["S05.stable_junction"] = {
		id = "S05.stable_junction",
		family = "stable_anchor_chamber",
		regionId = "R05",
		name = "Stable Stone Junction",
		exteriorChamberId = "R05.junction",
		doorSide = "N",
		theme = "limestone",
		entrances = {
			{ id = "survey_arch", requiredUpgrade = "arch_brace", requiredStage = 2 },
			{ id = "floor_fissure", requiredUpgrade = "fissure_fill", requiredStage = 1 },
		},
		safetyUpgrades = {
			arch_brace = {
				maxStage = 2,
				costPerStage = {
					{ ["mat.plank"] = 2 },
					{ ["mat.bracket"] = 2, ["mat.fastener"] = 1 },
				},
			},
			fissure_fill = { maxStage = 1, costPerStage = { { ["mat.plank"] = 3, ["mat.fastener"] = 1 } } },
		},
		functionalUpgrades = {
			workbench = { maxStage = 1, costPerStage = { { ["mat.plank"] = 2, ["mat.fastener"] = 2 } } },
			better_lighting = { maxStage = 1, costPerStage = { { ["power.cell"] = 1, ["mat.fastener"] = 1 } } },
		},
	},
}
WorldDefs.Shelters = Shelters
WorldDefs.StartShelterId = "S01.worker_alcove"
-- PROPOSED: before registering any shelter, a new player's "last shelter" spawn is the surface depot.
WorldDefs.DepotPseudoShelterId = "R00.depot"

-- Scavenging sites (section 08: organic acquisition paths; a reachable opportunity with risk, not a kit).
local ScavengeSites: { ScavengeSite } = {
	{
		id = "R01.scav.board_crate",
		regionId = "R01",
		pos = { x = -11, y = 1, z = 158 },
		requiresLight = false,
		respawnSeconds = 600,
		contents = { ["med.cloth_dressing"] = 1, ["power.cell"] = 1 },
	},
	{
		id = "R01.scav.pier_sack",
		regionId = "R01",
		pos = { x = 12, y = 1, z = 240 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.fabric"] = 2, ["mat.chalk_fragment"] = 3 },
	},
	{
		id = "R01.scav.slope_toolbox",
		regionId = "R01",
		pos = { x = -92, y = 1, z = 240 },
		requiresLight = true,
		respawnSeconds = 900,
		contents = { ["mat.bracket"] = 2, ["mat.fastener"] = 2, ["tool.iron_bar"] = 1 },
	},
	{
		id = "R01.scav.rubble_planks",
		regionId = "R01",
		pos = { x = -96, y = 1, z = 338 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.plank"] = 3 },
	},
	{
		id = "R01.scav.pulley_case",
		regionId = "R01",
		pos = { x = 10, y = 1, z = 340 },
		requiresLight = true,
		respawnSeconds = 1200,
		contents = { ["med.bandage"] = 1, ["treasure.brass_rule"] = 1 },
	},
	{
		id = "R01.scav.east_shelf",
		regionId = "R01",
		pos = { x = 100, y = 1, z = 338 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.plank"] = 2, ["mat.bracket"] = 1, ["power.cell"] = 1 },
	},
	{
		id = "R02.scav.crypt_box",
		regionId = "R02",
		pos = { x = -182, y = -23, z = 538 },
		requiresLight = true,
		respawnSeconds = 1200,
		contents = { ["med.bandage"] = 1, ["nav.sign"] = 2, ["power.cell"] = 1 },
	},
	{
		id = "R02.scav.plaque_satchel",
		regionId = "R02",
		pos = { x = -72, y = -23, z = 546 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.fabric"] = 2, ["mat.fastener"] = 1, ["nav.rope"] = 2 },
	},
	{
		id = "R02.scav.inspection_locker",
		regionId = "R02",
		pos = { x = -166, y = -23, z = 448 },
		requiresLight = true,
		respawnSeconds = 3600,
		contents = { ["light.expedition_flashlight"] = 1, ["power.cell"] = 1 },
	},
	{
		id = "R02.scav.long_niche",
		regionId = "R02",
		pos = { x = -76, y = -23, z = 628 },
		requiresLight = false,
		respawnSeconds = 1200,
		contents = { ["mat.plank"] = 2, ["treasure.lead_seal"] = 1 },
	},
	{
		id = "R02.scav.chapel_chest",
		regionId = "R02",
		pos = { x = 12, y = -23, z = 538 },
		requiresLight = false,
		respawnSeconds = 3600,
		contents = { ["tool.stun_device"] = 1, ["med.bandage"] = 1 },
	},
	{
		id = "R03.scav.pump_toolbag",
		regionId = "R03",
		pos = { x = -74, y = -43, z = 712 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.bracket"] = 2, ["mat.fastener"] = 2 },
	},
	{
		id = "R03.scav.silt_crate",
		regionId = "R03",
		pos = { x = -180, y = -42, z = 728 },
		requiresLight = true,
		respawnSeconds = 3600,
		contents = { ["light.compact_headlamp"] = 1, ["power.cell"] = 1 },
	},
	{
		id = "R03.scav.sluice_bundle",
		regionId = "R03",
		pos = { x = -74, y = -42, z = 834 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["mat.plank"] = 3, ["nav.rope"] = 2 },
	},
	{
		id = "R03.scav.cistern_cache",
		regionId = "R03",
		pos = { x = 14, y = -42, z = 828 },
		requiresLight = false,
		respawnSeconds = 1800,
		contents = { ["treasure.brass_rule"] = 2, ["med.bandage"] = 1, ["power.cell"] = 2 },
	},
	-- Milestone 3
	{
		id = "R01.scav.pulley_store_crate",
		regionId = "R01",
		pos = { x = 6, y = 1, z = 426 },
		requiresLight = false,
		respawnSeconds = 1200,
		contents = { ["nav.rope"] = 2, ["treasure.brass_rule"] = 1, ["mat.fabric"] = 2 },
	},
	{
		id = "R03.scav.vault_cache",
		regionId = "R03",
		pos = { x = -256, y = -43, z = 730 },
		requiresLight = false,
		respawnSeconds = 1800,
		contents = { ["tool.flare"] = 2, ["power.cell"] = 1, ["mat.fuse_component"] = 2 },
	},
	{
		id = "R04.scav.hall_desk",
		regionId = "R04",
		pos = { x = -72, y = -63, z = 942 },
		requiresLight = false,
		respawnSeconds = 900,
		contents = { ["tool.flare"] = 1, ["mat.fuse_component"] = 2, ["treasure.dated_battery"] = 1 },
	},
	{
		id = "R04.scav.medical_shelves",
		regionId = "R04",
		pos = { x = -72, y = -63, z = 917 },
		requiresLight = false,
		respawnSeconds = 1200,
		contents = { ["med.splint"] = 1, ["med.cloth_dressing"] = 1, ["mat.fabric"] = 1 },
	},
	{
		id = "R04.scav.battery_shelf",
		regionId = "R04",
		pos = { x = -182, y = -63, z = 921 },
		requiresLight = true,
		respawnSeconds = 3600,
		contents = { ["light.shielded_lantern"] = 1, ["tool.repair_roll"] = 1, ["mat.battery_housing"] = 1 },
	},
	{
		id = "R04.scav.generator_locker",
		regionId = "R04",
		pos = { x = -97, y = -63, z = 1032 },
		requiresLight = false,
		respawnSeconds = 1200,
		contents = { ["tool.fuse_kit"] = 1, ["tool.repair_roll"] = 1, ["mat.bracket"] = 1 },
	},
	{
		id = "R04.scav.radio_bench",
		regionId = "R04",
		pos = { x = 14, y = -63, z = 921 },
		requiresLight = true,
		respawnSeconds = 900,
		contents = { ["mat.fuse_component"] = 2, ["mat.battery_housing"] = 1, ["power.cell"] = 1 },
	},
	{
		id = "R04.scav.map_drawer",
		regionId = "R04",
		pos = { x = 16, y = -63, z = 1009 },
		requiresLight = true,
		respawnSeconds = 1800,
		contents = { ["treasure.field_photograph"] = 1, ["nav.sign"] = 1 },
	},
	{
		id = "R05.scav.anchor_cache",
		regionId = "R05",
		pos = { x = 16, y = -83, z = 1110 },
		requiresLight = false,
		respawnSeconds = 1200,
		contents = { ["treasure.dated_battery"] = 1, ["nav.chalk"] = 5, ["power.cell"] = 1 },
	},
}
WorldDefs.ScavengeSites = ScavengeSites

-- Unique per-player pickups (section 14: each player physically claims their own copy).
local UniquePickups: { UniquePickup } = {
	{
		id = "R01.unique.survey_tag",
		itemId = "treasure.survey_tag",
		pos = { x = -6, y = 1, z = 344 },
		discoveryId = "R01.found_survey_tag",
		label = "Expedition survey tag",
	},
	{
		id = "R02.unique.old_tag",
		itemId = "treasure.old_expedition_tag",
		pos = { x = 0, y = -23, z = 538 },
		discoveryId = "R02.found_old_tag",
		label = "Old expedition tag",
	},
	{
		id = "R03.unique.waterworks_log",
		itemId = "evidence.waterworks_log",
		pos = { x = -2, y = -43, z = 830 },
		discoveryId = "R03.found_waterworks_log",
		label = "Waterworks log",
	},
}
WorldDefs.UniquePickups = UniquePickups

-- Hiding niches (F07: hiding is a primary defense). Facing points out of the niche into the room.
local HidingSpots: { HidingSpot } = {
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
	-- Milestone 3
	{ id = "hide.R03.drain", pos = { x = -165, y = -44, z = 622 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R04.hall", pos = { x = -98, y = -64, z = 942 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R04.battery", pos = { x = -170, y = -64, z = 920 }, facing = { x = 0, y = 0, z = 1 } },
	{ id = "hide.R04.generator", pos = { x = -97, y = -64, z = 1009 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R04.map", pos = { x = 18, y = -64, z = 1031 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R05.south", pos = { x = 18, y = -84, z = 1112 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R05.bend", pos = { x = -94, y = -84, z = 1112 }, facing = { x = 1, y = 0, z = 0 } },
	{ id = "hide.R05.east", pos = { x = 106, y = -84, z = 1200 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R05.niche", pos = { x = 105, y = -84, z = 1300 }, facing = { x = -1, y = 0, z = 0 } },
	{ id = "hide.R05.loop", pos = { x = 106, y = -84, z = 1400 }, facing = { x = -1, y = 0, z = 0 } },
}
WorldDefs.HidingSpots = HidingSpots

-- Puzzles (section 12). P01-P02 SLICE; P03-P06 PLANNED.
local Puzzles: { [string]: PuzzleDef } = {
	P01 = {
		id = "P01",
		name = "Inscription alignment",
		status = "SLICE",
		regionId = "R02",
		plaque = { x = -90, y = -24, z = 540 }, -- rotatable plaque on a pedestal
		carving = { x = -94, y = -24, z = 510.6 }, -- target symbol on the south wall (faces north)
		wornCarving = { x = -76, y = -24, z = 549.4 }, -- worn duplicate on the north wall (faces south)
		gate = { x = -62, y = -24, z = 530 }, -- blocks the corridor to the sealed chapel
		orientations = 4,
	},
	P02 = {
		id = "P02",
		name = "Pump routing",
		status = "SLICE",
		regionId = "R03",
		valves = { { x = -69, y = -40, z = 712 }, { x = -69, y = -40, z = 720 }, { x = -69, y = -40, z = 728 } },
		clue = { x = -69, y = -39, z = 733 },
		gauge = { x = -69, y = -39, z = 705 }, -- south of the valves, below the wall pipes
		reset = { x = -69, y = -42, z = 708.5 },
		barrier = { x = -20, y = -44, z = 820 }, -- deep water in the corridor to the cistern
		refloodSeconds = 600,
	},
	-- P03: three labelled junction boxes on the generator room's north wall (facing -z); the circuit plate names the
	-- dead line. Needs a repair tool roll (kept) and a fuse kit (consumed). Shared per server.
	P03 = {
		id = "P03",
		name = "Fuse bridge",
		status = "SLICE",
		regionId = "R04",
		chamberId = "R04.generator_room",
		boxes = {
			{ label = "A", pos = { x = -92, y = -61, z = 1033 } },
			{ label = "B", pos = { x = -84, y = -61, z = 1033 } },
			{ label = "C", pos = { x = -76, y = -61, z = 1033 } },
		},
		plate = { x = -73, y = -61, z = 1007 }, -- circuit plate on the south wall (faces +z)
		generator = { x = -84, y = -64, z = 1022 },
	},
	-- P04: load stones into the counterweight basket to raise the grate to the Pulley Store; latch it to cross solo.
	P04 = {
		id = "P04",
		name = "Weight and pulley",
		status = "SLICE",
		regionId = "R01",
		chamberId = "R01.rusted_pulley",
		stonePile = { x = -13, y = 0, z = 317 },
		basket = { x = 6, y = 0, z = 334 }, -- hangs from the existing pulley frame
		latch = { x = 13, y = 0, z = 343 },
		grate = { x = 0, y = 0, z = 346 }, -- in the north opening
		innerLever = { x = -8, y = 0, z = 413 }, -- inside the Pulley Store: always opens the grate
		stonesNeeded = 3,
	},
	-- P05: repeat the radio's short/long pattern (lamp and caption give the same rhythm visually).
	P05 = {
		id = "P05",
		name = "Echo sequence",
		status = "SLICE",
		regionId = "R04",
		chamberId = "R04.radio_room",
		radio = { x = 17, y = -64, z = 930 }, -- on the east wall, facing -x
		sequences = { "SLSS", "LSLS", "SSLL", "LSSL", "SLLS" }, -- authored; one is chosen per server
	},
	-- P06: the three-version pocket PK3 (WorldDefs.Pockets). Nothing is locked; verifying the stable door is the success.
	P06 = {
		id = "P06",
		name = "Impossible doorway",
		status = "SLICE",
		regionId = "R05",
		chamberId = "R05.doorway_room",
		pocketId = "PK3",
		observationStep = { x = -10, y = -84, z = 1292 },
		flickerPeriodSeconds = 12,
	},
	-- W05: sluice gates for M05 Waterworks Passage. Turn the three wheels in the clue order; each turn is loud.
	W05 = {
		id = "W05",
		name = "Sluice gates",
		status = "SLICE",
		regionId = "R03",
		chamberId = "R03.silt_loop",
		wheels = {
			{ x = -164, y = -41, z = 710 },
			{ x = -164, y = -41, z = 730 },
			{ x = -184, y = -41, z = 730 },
		},
		clues = {
			{ pos = { x = -99, y = -40, z = 708 }, facing = { x = 1, y = 0, z = 0 } }, -- Old Pumps, west wall
			{ pos = { x = -164, y = -40, z = 630 }, facing = { x = -1, y = 0, z = 0 } }, -- Drain Gallery, east wall
		},
		barrier = { x = -219, y = -44, z = 720 }, -- deep water in the corridor to the Overflow Vault
		orders = { "123", "132", "213", "231", "312", "321" }, -- authored; one is chosen per server
		refloodSeconds = 600,
	},
}
WorldDefs.Puzzles = Puzzles

-- Rescue spawn candidates (M01). Offered only within a few chambers of the player's last shelter.
local RescueSpawns: { RescueSpawn } = {
	{
		id = "R01.rescue.rubble",
		chamberId = "R01.rubble_room",
		pos = { x = -94, y = 1, z = 322 },
		cue = "dropped_lamp",
	},
	{
		id = "R01.rescue.slope",
		chamberId = "R01.sloped_gallery",
		pos = { x = -92, y = 1, z = 222 },
		cue = "chalk_scrawl",
	},
	{ id = "R01.rescue.pulley", chamberId = "R01.rusted_pulley", pos = { x = -8, y = 1, z = 322 }, cue = "rope_end" },
	{ id = "R01.rescue.east", chamberId = "R01.east_loop", pos = { x = 98, y = 1, z = 324 }, cue = "dropped_lamp" },
	{
		id = "R02.rescue.crypt",
		chamberId = "R02.lantern_crypt",
		pos = { x = -180, y = -23, z = 524 },
		cue = "dropped_lamp",
	},
	{
		id = "R02.rescue.long",
		chamberId = "R02.ossuary_long",
		pos = { x = -90, y = -23, z = 614 },
		cue = "chalk_scrawl",
	},
	{ id = "R03.rescue.silt", chamberId = "R03.silt_loop", pos = { x = -168, y = -42, z = 714 }, cue = "rope_end" },
	-- Milestone 3 (stable chambers only; never inside a variable pocket's bounds + occupancy margin)
	{
		id = "R04.rescue.battery",
		chamberId = "R04.battery_store",
		pos = { x = -165, y = -63, z = 939 },
		cue = "dropped_lamp",
	},
	{ id = "R04.rescue.radio", chamberId = "R04.radio_room", pos = { x = -3, y = -63, z = 920 }, cue = "rope_end" },
	-- south-west corner, clear of PK1's bounds + occupancy margin (a waiting survivor is a PocketBlocker), the two
	-- doorways and the east wall's hiding niche and cache
	{
		id = "R05.rescue.south",
		chamberId = "R05.south_anchor",
		pos = { x = -4, y = -83, z = 1110 },
		cue = "chalk_scrawl",
	},
	{
		id = "R05.rescue.west",
		chamberId = "R05.west_anchor",
		pos = { x = -92, y = -83, z = 1204 },
		cue = "dropped_lamp",
	},
}
WorldDefs.RescueSpawns = RescueSpawns

-- M02 cache spots: the objective text describes the landmark, never a map marker.
local CacheSpots: { CacheSpot } = {
	{
		id = "cache.pier",
		chamberId = "R01.split_pier",
		pos = { x = 8, y = 1, z = 222 },
		clue = "beside the pier that is split down the middle",
	},
	{
		id = "cache.pulley",
		chamberId = "R01.rusted_pulley",
		pos = { x = -10, y = 1, z = 338 },
		clue = "under the wheel that no longer turns",
	},
	{
		id = "cache.slope",
		chamberId = "R01.sloped_gallery",
		pos = { x = -74, y = 1, z = 238 },
		clue = "where the ceiling leans down toward the floor",
	},
	{
		id = "cache.plaques",
		chamberId = "R02.plaque_hall",
		pos = { x = -94, y = -23, z = 518 },
		clue = "beneath the wall of numbered plaques",
	},
	{
		id = "cache.crypt",
		chamberId = "R02.lantern_crypt",
		pos = { x = -166, y = -23, z = 522 },
		clue = "in the crypt where every lamp niche is empty",
	},
	{
		id = "cache.pumps",
		chamberId = "R03.pump_gallery",
		pos = { x = -75, y = -43, z = 733 },
		clue = "beside the three iron valves",
	},
	-- Milestone 3
	{
		id = "cache.station",
		chamberId = "R04.station_hall",
		pos = { x = -93, y = -63, z = 917 },
		clue = "under the desk with three calendars that disagree",
	},
	{
		id = "cache.maproom",
		chamberId = "R04.map_room",
		pos = { x = -4, y = -63, z = 1031 },
		clue = "below the map that shows a street where no street can be",
	},
	{
		id = "cache.westanchor",
		chamberId = "R05.west_anchor",
		pos = { x = -92, y = -83, z = 1218 },
		clue = "beside the anchor plaque marked with a diamond",
	},
}
WorldDefs.CacheSpots = CacheSpots

-- Creatures (section 10). status: SLICE or PLANNED.
local Creatures: { [string]: CreatureDef } = {
	C01_Sidelooker = {
		id = "C01",
		name = "Sidelooker",
		status = "SLICE",
		researchCap = 3, -- stage 4 (sketch comparison) is not built yet (D29)
		damaging = false,
		killable = false,
		researchEvidence = { "seen", "seen_retreat_when_watched", "seen_three_locations", "sketch_compared" },
		hints = {
			"Look for a tall shape at the edge of a room.",
			"Watch it deliberately.",
			"Sight it in three different places.",
			"Compare sketches (not yet possible).",
		},
	},
	-- C02: an exact work rhythm; walks toward a dead end when watched; never answers a verified party ping.
	C02_BorrowedMiner = {
		id = "C02",
		name = "Borrowed Miner",
		status = "SLICE",
		damaging = false,
		killable = false,
		walkSpeed = 7,
		watchRadius = 40,
		homes = {
			{
				chamberId = "R01.east_loop",
				workPos = { x = 92, y = 0, z = 340 },
				lureChamberId = "R01.collapsed_drift",
				lurePos = { x = 188, y = 0, z = 330 },
			},
			{
				chamberId = "R04.station_hall",
				workPos = { x = -70, y = -64, z = 920 },
				lureChamberId = "R04.collapsed_adit",
				lurePos = { x = -268, y = -64, z = 930 },
			},
		},
		researchEvidence = { "seen", "heard_exact_rhythm", "waited_for_repeat", "failed_verification" },
		hints = {
			"Look for a miner still working where nobody should be.",
			"Listen: the strokes keep an exact rhythm.",
			"Stay close and let it repeat three times.",
			"Send a verified party ping near it, or watch it fade at the dead end.",
		},
	},
	-- C03: clings to an exposed light and shortens its beam; darkness, shielding or a flare disperses it. Harmless.
	C03_WickMoth = {
		id = "C03",
		name = "Wick Moth",
		status = "SLICE",
		damaging = false,
		killable = false,
		zones = { "R02.lantern_crypt", "R04.battery_store" },
		researchEvidence = { "seen", "heard_flutter", "dispersed_by_darkness", "shielded_or_decoyed" },
		hints = {
			"Carry a lit light into the Lantern Crypt or the Battery Store.",
			"Listen for wing flutter before the beam clouds over.",
			"Switch your light off for a few seconds.",
			"Shield a lantern, or light a flare to draw them away.",
		},
	},
	-- C04: a private false mark near your own chalk in R05. It cannot touch, move or transfer a saved marker.
	C04_ChalkHand = {
		id = "C04",
		name = "Chalk Hand",
		status = "SLICE",
		damaging = false,
		killable = false,
		regionId = "R05",
		researchEvidence = { "seen", "noticed_false_mark", "checked_notebook", "confirmed_own_mark" },
		hints = {
			"Mark your route with chalk in the Shifting Crossroads.",
			"Look for a fresh mark you did not draw.",
			"Inspect it: is it in your notebook?",
			"Inspect one of your own marks to compare.",
		},
	},
	C05_Scrabbler = {
		id = "C05",
		name = "Scrabbler",
		status = "SLICE",
		damaging = true,
		killable = true,
		health = 60,
		damage = 18,
		walkSpeed = 9,
		rushSpeed = 22,
		windupSeconds = 1.1,
		hearingRadius = 45,
		sightRadius = 40,
		homes = { { "R01.rubble_room", "R01.sloped_gallery" }, { "R02.lantern_crypt", "R02.ossuary_long" } },
		researchEvidence = { "seen", "heard_scrape", "escaped_by_breaking_sight", "stunned_or_killed" },
		hints = {
			"Get a look at it in the rubble.",
			"Hear the scrape before it rushes.",
			"Break its line of sight to escape.",
			"Stun it or bring it down.",
		},
	},
	C06_Wader = {
		id = "C06",
		name = "Wader",
		status = "SLICE",
		damaging = true,
		killable = false,
		damage = 25,
		walkSpeed = 7,
		pursueSpeed = 15,
		hearingRadius = 55,
		repelSeconds = 6,
		warnSeconds = 1.6,
		homes = { "R03.sluice", "R03.silt_loop", "R03.cistern" },
		researchEvidence = { "seen", "heard_drag", "evaded_by_silence", "distracted_or_repelled" },
		hints = {
			"See it standing in the water.",
			"Hear the dragging step.",
			"Move silently (crouch or stay dry) while it searches.",
			"Throw a stone to distract it, or repel it with a stun.",
		},
	},
	C07_Knocker = {
		id = "C07",
		name = "Knocker",
		status = "SLICE",
		damaging = true,
		killable = false,
		damage = 30,
		knockCount = 3,
		knockInterval = 0.7,
		chargeSpeed = 34,
		chargeMaxDistance = 110,
		stunSeconds = 4,
		researchEvidence = { "seen", "heard_three_knocks", "dodged_at_junction", "stunned_window" },
		hints = {
			"Walk the long straight corridor in the quarry.",
			"Count the knocks.",
			"Leave the line before the charge.",
			"Stun it while it is still knocking.",
		},
	},
	-- C08: stalks poorly supplied travellers; strikes and snuffs a light (charge unchanged). Flares divert it; breaking
	-- sight loses it; a stun repels it. It never strikes before the player has read the warning (counterEvidence).
	C08_LanternThief = {
		id = "C08",
		name = "Lantern Thief",
		status = "SLICE",
		damaging = true,
		killable = false,
		walkSpeed = 8,
		approachSpeed = 15,
		sightRadius = 50,
		reach = 6,
		repelSeconds = 6,
		regions = { "R04", "R05" },
		homes = { "R04.generator_room", "R04.map_room", "R04.battery_store", "R05.center_anchor" },
		counterEvidence = "R04.thief_notes",
		researchEvidence = { "seen", "heard_rattle", "decoyed_by_flare", "lost_by_breaking_sight" },
		hints = {
			"Something with many dim lights moves deep in the survey station.",
			"Listen for a faint rattle of glass.",
			"Light a flare and let it take the brighter prize.",
			"Break its line of sight until it gives up.",
		},
	},
	C09_Procession = {
		id = "C09",
		name = "Procession",
		status = "PLANNED",
		damaging = true,
		killable = false,
		researchEvidence = {},
	},
	C10_FalseCompanion = {
		id = "C10",
		name = "False Companion",
		status = "PLANNED",
		damaging = false,
		killable = false,
		researchEvidence = {},
	},
	C11_FoldedSurveyor = {
		id = "C11",
		name = "Folded Surveyor",
		status = "PLANNED",
		damaging = true,
		killable = false,
		researchEvidence = {},
	},
	C12_Cartographer = {
		id = "C12",
		name = "Cartographer",
		status = "PLANNED",
		damaging = true,
		killable = false,
		researchEvidence = {},
	},
}
WorldDefs.Creatures = Creatures

function WorldDefs.creatureById(id: string): CreatureDef?
	for _, c in WorldDefs.Creatures do
		if c.id == id then
			return c
		end
	end
	return nil
end

-- Characters (section 05). Only N01 has a placeholder presence (the depot board).
local Characters: { [string]: CharacterDef } = {
	N01 = { name = "Mara Voss", role = "expedition coordinator", status = "SLICE", pos = { x = 14, y = 60, z = -20 } },
	N02 = { name = "Dr Luc Moreau", role = "historian", status = "SLICE", pos = { x = -6, y = 60, z = 10 } },
	N03 = { name = "Ines Vidal", role = "quartermaster", status = "SLICE", pos = { x = -20, y = 60, z = -14 } },
	N04 = { name = "Amadou Diallo", role = "engineer", status = "SLICE", pos = { x = -30, y = 60, z = -12 } },
	-- Elise Renaud appears only in recordings and notes this milestone.
	N05 = { name = "Elise Renaud", role = "missing survey lead", status = "RECORDINGS" },
	-- Noah Perrin waits in the Silt Works (Act II rescue, rescuePos) and stands at the depot afterwards (pos).
	N06 = {
		name = "Noah Perrin",
		role = "rescued courier",
		status = "SLICE",
		pos = { x = 20, y = 60, z = 8 },
		rescuePos = { x = -177, y = -43, z = 718 },
	},
}
WorldDefs.Characters = Characters

-- Missions (section 06).
local Missions: { [string]: MissionDef } = {
	M01 = { name = "Nearby Rescue", status = "SLICE", estimate = "5-15 min", risk = "low" },
	M02 = { name = "Missing Survey Cache", status = "SLICE", estimate = "10-25 min", risk = "low" },
	M03 = { name = "Medical Delivery", status = "SLICE", estimate = "10-20 min", risk = "low" },
	M04 = { name = "Power Restoration", status = "SLICE", estimate = "15-35 min", risk = "medium" },
	M05 = { name = "Waterworks Passage", status = "SLICE", estimate = "20-45 min", risk = "medium" },
	M06 = { name = "False Signal", status = "PLANNED" },
	M07 = { name = "Creature Observation", status = "SLICE", estimate = "10-30 min", risk = "medium" },
	M08 = { name = "Route Survey", status = "PLANNED" },
	M09 = { name = "Shelter Establishment", status = "SLICE", estimate = "20-60 min", risk = "medium" },
	M10 = { name = "Deep Treasure", status = "PLANNED" },
	M11 = { name = "Lost Belongings", status = "SLICE", estimate = "10-45 min", risk = "varies" },
	M12 = { name = "Anomaly Chain", status = "PLANNED" },
}
WorldDefs.Missions = Missions

-- Mission spots (section 06). Stable chambers only, never inside a variable pocket.
local MissionSpots: { [string]: { MissionSpot } } = {
	-- M03: where an injured (generic, unnamed) survey worker waits for supplies.
	M03 = {
		{ id = "M03.R01.board", chamberId = "R01.survey_board", pos = { x = 10, y = 1, z = 142 } },
		{ id = "M03.R02.inspection", chamberId = "R02.inspection_room", pos = { x = -170, y = -23, z = 432 } },
		{ id = "M03.R03.pumps", chamberId = "R03.pump_gallery", pos = { x = -96, y = -43, z = 732 } },
		{ id = "M03.R04.hall", chamberId = "R04.station_hall", pos = { x = -90, y = -63, z = 940 } },
		{ id = "M03.R05.west", chamberId = "R05.west_anchor", pos = { x = -76, y = -83, z = 1218 } },
	},
	-- M05: the sluice-keeper's cache (each participant opens their own copy).
	M05 = {
		{
			id = "M05.vault_cache",
			chamberId = "R03.overflow_vault",
			pos = { x = -272, y = -43, z = 728 },
			clue = "the sluice-keeper's cache in the Overflow Vault",
		},
	},
}
WorldDefs.MissionSpots = MissionSpots

-- Readable notes and plaques with story or counter evidence. Text lives in Data/StoryDefs.
local Readables: { Readable } = {
	-- Counter evidence for C08 before its first dangerous encounter (section 10).
	{
		id = "R04.thief_notes",
		chamberId = "R04.station_hall",
		pos = { x = -99, y = -61, z = 918 },
		facing = { x = 1, y = 0, z = 0 },
		title = "Field note, E. Renaud",
	},
}
WorldDefs.Readables = Readables

-- Variable pockets (section 04, F08; docs/MILESTONE-3.md section 3). PocketService builds the active version.
local Pockets: { [string]: PocketDef } = {
	PK1 = {
		id = "PK1",
		regionId = "R05",
		from = "R05.south_anchor",
		to = "R05.center_anchor",
		axis = "z",
		bounds = { min = { x = -30, y = -84, z = 1134 }, max = { x = 42, y = -66, z = 1196 } },
		versions = { "direct", "loop", "low" },
		migrationAnchor = "R05.south_anchor",
	},
	PK2 = {
		id = "PK2",
		regionId = "R05",
		from = "R05.center_anchor",
		to = "R05.east_anchor",
		axis = "x",
		bounds = { min = { x = 20, y = -84, z = 1176 }, max = { x = 84, y = -66, z = 1244 } },
		versions = { "direct", "dogleg", "low" },
		migrationAnchor = "R05.center_anchor",
	},
	PK3 = {
		id = "PK3",
		regionId = "R05",
		from = "R05.doorway_room",
		to = "R05.junction",
		axis = "z",
		bounds = { min = { x = -14, y = -84, z = 1312 }, max = { x = 26, y = -66, z = 1376 } },
		versions = { "left", "middle", "right" },
		migrationAnchor = "R05.center_anchor",
		doors = { -6, 6, 18 },
		puzzle = "P06",
	},
}
WorldDefs.Pockets = Pockets

-- The pocket whose bounds contain a position (no margin), or nil.
function WorldDefs.pocketAt(pos: V3): PocketDef?
	for _, pk in Pockets do
		local b = pk.bounds
		if
			pos.x >= b.min.x
			and pos.x <= b.max.x
			and pos.y >= b.min.y - 2
			and pos.y <= b.max.y
			and pos.z >= b.min.z
			and pos.z <= b.max.z
		then
			return pk
		end
	end
	return nil
end

local chamberIndex: { [string]: Chamber } = {}
for _, c in WorldDefs.Chambers do
	chamberIndex[c.id] = c
end

function WorldDefs.chamber(id: string): Chamber?
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
		local cur = table.remove(queue, 1) :: string
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
