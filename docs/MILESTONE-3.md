# Milestone 3 — Contradictory Records (design contract)

This is the build contract for Milestone 3. It fixes the scope, every new stable ID, the shared data, the cross-package APIs and the decisions taken where the specification left a choice. The owner asked implementation to proceed using best judgement; every such judgement is recorded in [`DECISIONS.md`](DECISIONS.md) (D31 onward) and labelled **PROPOSED** or **TUNE**. Nothing here changes a **CONFIRMED** owner rule.

Status at writing: specified, not built. The ledger records what is actually built.

## 1. Scope

| Area | Adds | Spec |
| --- | --- | --- |
| Regions | R04 Abandoned Survey Station; R05 Shifting Crossroads with the first **variable pockets** | 04, F08 |
| Shelters | S04 Reinforced Service Office (`survey_station_room`); S05 Stable Stone Junction (`stable_anchor_chamber`) | 13 |
| Puzzles | P03 Fuse bridge (R04, public); P04 Weight and pulley (R01, optional); P05 Echo sequence (R04 radio); P06 Impossible doorway (R05, a three-version pocket); W05 sluice gates for M05 (R03) | 12 |
| Creatures | C02 Borrowed Miner; C03 Wick Moth; C04 Chalk Hand; C08 Lantern Thief | 10, 11 |
| Missions | M03 Medical Delivery; M04 Power Restoration; M05 Waterworks Passage; M09 Shelter Establishment; M11 Lost Belongings | 06 |
| Story | Act II "Contradictory Records" (seven steps); NPC figures N01–N04 and N06 at the depot; N05 Elise Renaud in recordings only | 05 |
| Equipment | Shielded lantern, flare, splint, repair tool roll, replacement fuse kit, fuse components, battery housing; an injury penalty that medical items remove | 07, 08, 09 |
| Progression | Field experience and ranks with diminishing returns on max stamina and max health (F24, T23) | 09 |
| Records | Pocket-versioned navigation and bag records with documented migration; checkpoint pocket version | 04, 15, 16 |

Out of scope (stay PLANNED): R06–R09, C09–C12, M06, M08, M10, M12, Acts III–V, recharge bench, survey compass, anchor stake, real assets and audio, localization.

## 2. Geography (greybox, studs)

Conventions are unchanged: chamber `pos` is the floor centre, corridors are axis-aligned between two chambers, a corridor between different floor heights is a sloped gallery, `doorSide` is a wall with no corridor.

### R04 Abandoned Survey Station (floor y = −64, danger 0.55)

Reached by a slope north from **R03.sluice** (z 820 → 930). Theme: survey desks, old batteries and field maps whose dates disagree ("familiar equipment in incompatible decades").

| Chamber | pos (x, y, z) | size (x, y, z) | Label | Role |
| --- | --- | --- | --- | --- |
| `R04.station_hall` | −84, −64, 930 | 32, 14, 32 | Survey Station Hall | Landmark. Desks, dated battery racks, medical shelves (scavenging) |
| `R04.battery_store` | −174, −64, 930 | 24, 12, 24 | Battery Store | Wick Moth zone, lantern and repair-roll scavenging |
| `R04.collapsed_adit` | −264, −64, 930 | 20, 10, 20 | Collapsed Adit | Dead end. The Borrowed Miner's misleading path |
| `R04.radio_room` | 6, −64, 930 | 26, 14, 26 | Radio Room | Landmark. P05, Elise's interrupted log |
| `R04.generator_room` | −84, −64, 1020 | 30, 16, 30 | Generator Room | Landmark. P03 public fuse bridge |
| `R04.map_room` | 6, −64, 1020 | 28, 14, 28 | Map Room | Landmark. Act II log comparison. Slope north to R05 |
| `R04.service_office` | −174, −64, 1020 | 24, 12, 24 | Service Office | S04 exterior, door on the **W** wall |

Corridors: `R03.sluice–R04.station_hall` (slope), `station_hall–battery_store`, `station_hall–radio_room`, `station_hall–generator_room`, `generator_room–map_room`, `radio_room–map_room`, `generator_room–service_office`, `battery_store–service_office`, `battery_store–collapsed_adit`. No corridor is gated: the main route never needs a puzzle.

### R05 Shifting Crossroads (floor y = −84, danger 0.6)

Reached by a slope north from **R04.map_room** (z 1020 → 1120). Stable anchor rooms carry a survey plaque with an anchor symbol; variable pockets join some of them.

| Chamber | pos | size | Label | Role |
| --- | --- | --- | --- | --- |
| `R05.south_anchor` | 6, −84, 1120 | 28, 14, 28 | South Survey Anchor | Landmark (anchor ▲). Migration anchor for PK1 |
| `R05.sw_bend` | −84, −84, 1120 | 24, 12, 24 | Measured Bend | Stable bypass around PK1 |
| `R05.west_anchor` | −84, −84, 1210 | 24, 14, 24 | West Survey Anchor | Anchor ◆ |
| `R05.center_anchor` | 6, −84, 1210 | 28, 14, 28 | Measured Crossing | Landmark (anchor ●). Migration anchor for PK2 and PK3 |
| `R05.east_anchor` | 96, −84, 1210 | 24, 14, 24 | East Survey Anchor | Anchor ■ |
| `R05.east_niche` | 96, −84, 1300 | 22, 12, 22 | Numbered Niche | Stable |
| `R05.doorway_room` | 6, −84, 1300 | 40, 16, 24 | Room of Three Doors | P06; three doors on the north wall |
| `R05.east_loop` | 96, −84, 1390 | 24, 12, 24 | Returning Gallery | Stable |
| `R05.junction` | 6, −84, 1390 | 28, 14, 28 | Stable Stone Junction | Landmark. S05 exterior, door on the **N** wall |

Stable corridors: `R04.map_room–R05.south_anchor` (slope), `south_anchor–sw_bend`, `sw_bend–west_anchor`, `west_anchor–center_anchor`, `center_anchor–doorway_room`, `east_anchor–east_niche`, `east_niche–east_loop`, `east_loop–junction`.

Pocket corridors (`pocket = "PKn"` in `WorldDefs.Corridors`; WorldBuilder does **not** build them, PocketService does; graph code treats them as always connected because every version honours the same entry/exit contract):

| Pocket | Joins | Bounding box (x, z) | Versions | Migration anchor |
| --- | --- | --- | --- | --- |
| PK1 | `south_anchor` (north door) ↔ `center_anchor` (south door) | x −30…42, z 1134…1196 | `direct` (straight), `loop` (east detour through a small side chamber), `low` (low narrow gallery, ceiling 8) | `R05.south_anchor` |
| PK2 | `center_anchor` (east door) ↔ `east_anchor` (west door) | x 20…84, z 1176…1244 | `direct`, `dogleg` (jogs north), `low` | `R05.center_anchor` |
| PK3 | `doorway_room` (north wall) ↔ `junction` (south door) | x −14…26, z 1312…1376 | `left`, `middle`, `right`: which of the three doors (x = −6, 6, 18) reaches the junction; the two others lead into short loops that return to the same door | `R05.center_anchor` |

The junction is always reachable without P06: `center_anchor → PK2 → east_anchor → east_niche → east_loop → junction`.

### R03 additions (M05)

| Chamber | pos | size | Label |
| --- | --- | --- | --- |
| `R03.overflow_vault` | −264, −44, 720 | 24, 14, 24 | Overflow Vault |
| `R03.drain_gallery` | −174, −44, 630 | 22, 12, 22 | Drain Gallery (dry) |
| `R03.vault_stair` | −264, −44, 630 | 20, 12, 20 | Vault Stair (dry) |

Corridors: `R03.silt_loop–R03.overflow_vault` with `gate = "W05"` (deep water until the sluice gates are set; loud), and the long silent dry route `silt_loop–drain_gallery`, `drain_gallery–vault_stair`, `vault_stair–overflow_vault`.

### R01 additions

| Chamber | pos | size | Label | Role |
| --- | --- | --- | --- | --- |
| `R01.collapsed_drift` | 182, 0, 330 | 20, 10, 20 | Collapsed Drift | Dead end east of the East Workings: the Borrowed Miner's misleading path |
| `R01.pulley_store` | 0, 0, 420 | 20, 12, 20 | Pulley Store | Optional room behind the P04 grate, north of the Rusted Pulley |

Corridors: `R01.east_loop–R01.collapsed_drift`, `R01.rusted_pulley–R01.pulley_store` with `gate = "P04"`.

## 3. Variable pockets (F08) — rules

These implement section 04 and decision D31.

1. A pocket's current version is **server state** driven by a deterministic schedule: the target version is `versions[((os.time() // cycleSeconds) + offset(pocketId)) % #versions + 1]` (`Config.Pockets.cycleSeconds`, TUNE 600 s), so every server converges on the same version and a record placed on one server usually matches the next. A busy server simply lags behind the schedule until the pocket is empty.
2. A change is attempted only when the pocket is **empty**: no player inside its bounding box (plus a 6-stud margin), no active rescue survivor inside, no bag of an online owner inside, no **rope** record of an online owner whose endpoints are inside, no lit flare inside (flares burn at most 45 s). Any blocker postpones the change to the next cycle. Chalk and signs do not block.
3. Every change is **telegraphed** for `Config.Pockets.telegraphSeconds` (TUNE 20 s): survey clicks and falling dust at both mouths (`pocket_shift` cue, essential, captioned) and the threshold number plates flicker. If anything enters during the telegraph the change aborts.
4. Every version connects the same two doors (entry/exit contract), so a valid escape path always exists.
5. Records carry the pocket version they were placed in. When a record's version differs from the pocket's current version, the record **migrates** (persisted) to that pocket's migration anchor chamber, keeps its owner, units and route ID, gains `migratedFrom = { pocketId, version }`, and the owner sees a notice and a notebook line: "Your chalk mark in PK1 moved to the South Survey Anchor — the passage changed." Records are never deleted by variation.
6. Records of online owners migrate when the pocket changes on that server. Records of offline owners migrate lazily when their profile next loads on a server whose pocket version differs. Bags follow the same rule through the existing anchor reconstruction.
7. The expedition checkpoint stores the real pocket version (not the constant 1) when the player stands in a pocket.
8. PK3 is also puzzle P06: the stable door carries the same survey symbol as the anchor plaques; above the two false doors a lamp flickers in the same repeating pattern every 12 s while the stable door's lamp stays steady. A raised step on the south side of the room is the safe observation position. Walking through the stable door records the personal discovery `R05.p06_verified` (clear success caption and lamp). Nothing is locked.

## 4. New content definitions

### 4.1 Shelters

| ID | Family | Region | Exterior | Door | Entrances (upgrade, stage) | Safety costs | Functional |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `S04.service_office` | `survey_station_room` | R04 | `R04.service_office` | W | `steel_door` (door_bars, 2), `cable_duct` (duct_cover, 1) | door_bars 1: 2 brackets · 2: 2 planks + 2 fasteners; duct_cover 1: 1 bracket + 2 fasteners | `workbench` (2 planks + 2 fasteners), `station_power` (1 fuse kit; also requires M04's private breaker repair) |
| `S05.stable_junction` | `stable_anchor_chamber` | R05 | `R05.junction` | N | `survey_arch` (arch_brace, 2), `floor_fissure` (fissure_fill, 1) | arch_brace 1: 2 planks · 2: 2 brackets + 1 fastener; fissure_fill 1: 3 planks + 1 fastener | `workbench`, `better_lighting` (1 cell + 1 fastener) |

D34 records the family mapping for the remaining regions: R06 shuttered workshop → `buried_workshop`; R07 catalogue room → `inspection_office`; R08 anchored survey room → `survey_station_room`; R09 return-route chamber → `stable_anchor_chamber`.

### 4.2 Puzzles

| ID | Where | Scope | Rule | Feedback | Reset |
| --- | --- | --- | --- | --- | --- |
| P03 Fuse bridge | `R04.generator_room` | Shared per server | Three labelled junction boxes (A, B, C) along a conduit; a circuit plate names the dead line; one box is burnt (authored layouts, randomized per server). Inserting a fuse needs a **repair tool roll** (reusable, not consumed) and consumes one **fuse kit**. A wrong box costs time (4 s, fuse returned), never health. | Sparks, `fuse_spark` / `power_restored` cues, station lamps come on | Power lasts `Config.Puzzles.stationPowerSeconds` (TUNE 1200 s), then the line trips again only when nobody is in the generator room |
| P04 Weight and pulley | `R01.rusted_pulley` | Shared per server | Load three stones into the counterweight basket (hold interactions) to raise the grate to the Pulley Store. Solo: pull the **latch** to hold it raised (only with a full basket). A party can hold the lever instead, which needs a second member present to cross. The grate can never close on or behind a player: an inner lever always opens it and it does not drop while anyone is under it or inside. | Grate position, `pulley_creak` cue | Drops 300 s after unlatching when nobody is inside |
| P05 Echo sequence | `R04.radio_room` | Personal attempt, shared radio | The radio plays a 4-element pattern of short and long tones; the lamp on the set blinks the same rhythm (driven on each client from server attributes, so it follows Reduce flashes) and the caption shows `• — • •`. The player repeats it with a **Short** / **Long** pair of buttons (or holds the prompt short or long). Randomized among authored sequences per server. Unlimited retries. | Per-element tick; `radio_locked` on success | Immediate |
| P06 Impossible doorway | `R05.doorway_room` | Pocket PK3 | See §3 rule 8 | Steady lamp, `anchor_verified` caption | Version changes with the pocket cycle |
| W05 Sluice gates | `R03.silt_loop` | Shared per server | Three gate wheels must be turned in a clue-supported **order** (clue plates in the Old Pumps and the Drain Gallery, each naming part of the order). Each turn makes a loud splash noise (draws the Wader if it is around). Wrong order resets the wheels. Success drains the flooded corridor to the Overflow Vault. | `sluice_gate` cue with n of 3 | Refloods 600 s later when nobody is in the corridor or vault |

### 4.3 Creatures

| ID | Name | Where | Damaging | Killable | Behaviour (cue → counter) | Research stages (evidence ids) |
| --- | --- | --- | --- | --- | --- | --- |
| C02 | Borrowed Miner | `R01.east_loop`, `R04.station_hall` | no | no | Works a wall with an **exact** 1.5 s rhythm (`miner_rhythm`). When a player watches it, it walks toward the dead end (`R01.collapsed_drift`, `R04.collapsed_adit`) and fades there or when a verified party ping is issued nearby (it never answers a verification). It never copies a real player's name or party label. | `seen`, `heard_exact_rhythm`, `waited_for_repeat` (stay within 25 studs through three repeats), `failed_verification` (party ping or watched it fade) |
| C03 | Wick Moth | `R02.lantern_crypt`, `R04.battery_store` | no | no | Wing flutter and dust (`moth_flutter`) precede a swarm that clings to an exposed light and cuts its range (`Config.Creatures.mothRangeFactor`, TUNE 0.4). Switching the light off for 3 s, shielding a lantern, or walking out of the zone disperses it. A lit flare draws the swarm away. It never changes battery charge or health. | `seen`, `heard_flutter`, `dispersed_by_darkness`, `shielded_or_decoyed` |
| C04 | Chalk Hand | R05 anchors and pockets | no | no | Near a player's own chalk mark in R05 a thin hand withdraws into a crack (`chalkhand_scratch`) and a **fake** reversed arrow appears (private cosmetic, no record). Inspecting it says "This mark is not in your notebook." It cannot delete, move or transfer any saved marker. | `seen`, `noticed_false_mark`, `checked_notebook` (inspect the fake), `confirmed_own_mark` (inspect a real own mark within 60 s) |
| C08 | Lantern Thief | R04 (generator, map, battery rooms), R05 | yes | no (weapons glance off) | A faint **glass rattle** (`thief_rattle`, essential) precedes an approach from outside view. It prefers the brightest light that is not its own and presses poorly supplied travellers (director). If it reaches a player in its sight it strikes (`Config.Creatures.thiefDamage`, TUNE 20) and snuffs the light (switched off; **charge unchanged**), then withdraws. A lit flare within 30 studs diverts it for 20 s; breaking line of sight for 4 s makes it lose you; a stun repels it. **Counter evidence first:** until the player has read Elise's warning note in `R04.station_hall` (discovery `R04.thief_notes`), it only stalks and is seen, never strikes. | `seen`, `heard_rattle`, `decoyed_by_flare`, `lost_by_breaking_sight` |

### 4.4 Missions

All follow `docs/MISSIONS.md` conventions: estimate and risk shown, never a GPS path, individual rewards, explicit failure, abandonment, disconnect and late-join behaviour, transparent cooldowns. Full tables go in `MISSIONS.md`.

| ID | Summary | Reward (TUNE) | Cooldown |
| --- | --- | --- | --- |
| M03 Medical Delivery | An injured (generic, unnamed) survey worker waits at an authored spot near the last shelter. The player chooses how many medical items to hand over (1–3; dressing, bandage or splint). Reward scales with what was delivered. With nothing to give, the objective lists nearby scavenging sites; it never opens a store or asks for Robux. | 10 coins per item delivered + 10 | 180 s |
| M04 Power Restoration | Registered S04 without `station_power`: collect or craft a fuse kit, bring a repair tool roll, trace the private breaker circuit inside your S04 interior (a private P03 layout) and restart the station supply. Completion grants the permanent functional upgrade `station_power` (party-union inherited like any upgrade). | 50 coins once | none (one per shelter facility) |
| M05 Waterworks Passage | Reach the Overflow Vault (either set the loud sluice gates or take the long dry route), open **your own** sluice-keeper's cache, and return to a shelter. | cache contents + 25 coins at a shelter | 300 s; cache restocks per player |
| M09 Shelter Establishment | Pick a known shelter you have not secured: register it and build stage 1 of any safety upgrade. Further protection is separate. | 40 coins once per shelter | none |
| M11 Lost Belongings | Offered when you have a death or logout bag. Names its region and the nearest chamber (honest location). Completes when the owner recovers it (a party member's escrow recovery completes it without experience). Not a paid recovery service; no coin reward (no incentive to die); field experience once per bag, at most once every 15 minutes. | experience only | none (experience: 15 min) |

### 4.5 Act II — Contradictory Records

Unlocked by completing Act I. Steps derive from profile facts in order (like Act I):

| # | Step | Fact | Place · item · witness/record |
| --- | --- | --- | --- |
| 1 | Ask Dr Luc Moreau about the old tag | `charactersMet.N02` | Depot · old expedition tag · Moreau |
| 2 | Find the courier who saw the survey team | `storyStates["act2.noah_rescued"]` (story rescue of N06 Noah Perrin in `R03.silt_loop`, carried or escorted to any shelter) | Silt Works · courier's satchel · Noah |
| 3 | Recover the waterworks log from the drained cistern | claim `R03.unique.waterworks_log` | Cistern (behind P02) · waterworks log · Noah's account |
| 4 | Reach the survey station and register its shelter | `discoveries["shelter:S04.service_office"]` | Service Office |
| 5 | Restore station power and lock the radio frequency | `storyStates["act2.radio_heard"]` (P03 solved on the server **and** your P05 success) | Radio room · station tape (unique, protected) · Elise Renaud's recording |
| 6 | Compare the logs in the Map Room | `storyStates["act2.logs_compared"]` (interact at the map table carrying the waterworks log and the station tape) | Map room · both logs · the revelation journal |
| 7 | Report to Mara Voss | `storyStates["act2.complete"]` | Depot board · +80 coins |

Story items (`evidence.waterworks_log`, `evidence.station_tape`) are unique and **protected** (D21 pattern). Dialogue is short, subtitled and copied to the journal. All text is fictional.

### 4.6 Characters

Greybox figures built from parts with the silhouettes from B05 (colour and props only), a name label, and a **Talk** prompt that opens a subtitled dialogue panel and writes a journal line. Positions are in `WorldDefs.Characters`.

| ID | Where | Purpose this milestone |
| --- | --- | --- |
| N01 Mara Voss | Depot, by the board | Mission board voice; Act I/II hand-ins |
| N02 Dr Luc Moreau | Depot courtyard | Act II step 1; separates real history from anomaly claims |
| N03 Ines Vidal | Depot equipment room | Replaces the quartermaster placeholder (shop, sell, crafting tips) |
| N04 Amadou Diallo | Depot equipment room | Teaches barricades, pumps and power (hints for P03, W05, M04) |
| N05 Elise Renaud | Recordings only (radio, notes) | Act II step 5; the Lantern Thief warning |
| N06 Noah Perrin | Silt Works (rescue), then depot | Act II steps 2–3 |

### 4.7 Items (all in `ItemDefs`)

| ID | Name | Category | Stack | Protected | Sell | Key stats | Organic sources |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `light.shielded_lantern` | Shielded Lantern | light | 1 | no | 20 | omni radius 22, brightness 1.1, drain 0.7/s, `lantern = true`, shield mode radius 9 | `R04.scav.battery_shelf` (needs light, 60 min) |
| `tool.flare` | Signal Flare | tool | 5 | no | 2 | burns 45 s where placed, red omni light radius 18 | `R04.scav.hall_desk`, `R03.scav.vault_cache` |
| `med.splint` | Field Splint | medical | 3 | no | 4 | heal 5, removes injury, treat 4 s | `R04.scav.medical_shelves`; crafting |
| `tool.repair_roll` | Repair Tool Roll | tool | 1 | no | 8 | reusable for fuse work | `R04.scav.battery_shelf`, `R04.scav.generator_locker` |
| `tool.fuse_kit` | Replacement Fuse Kit | tool | 5 | no | 3 | consumed by P03 / M04 | `R04.scav.generator_locker`; crafting |
| `mat.fuse_component` | Fuse Components | material | 20 | no | 1 | | `R04.scav.radio_bench`, `R04.scav.hall_desk` |
| `mat.battery_housing` | Battery Housing | material | 10 | no | 1 | | `R04.scav.battery_shelf`, `R04.scav.radio_bench` |
| `evidence.waterworks_log` | Waterworks Log | evidence | 1 | **yes** | 0 | unique | `R03.unique.waterworks_log` (cistern) |
| `evidence.station_tape` | Station Tape | evidence | 1 | **yes** | 0 | unique | granted at P05 success with power on |
| `treasure.field_photograph` | Field Photograph (fictional) | treasure | 5 | no | 15 | | `R04.scav.map_drawer` |
| `treasure.dated_battery` | Mis-dated Battery (fictional) | treasure | 5 | no | 8 | | `R04.scav.hall_desk`, `R05.scav.anchor_cache` |

Recipes (shelter workbench rules unchanged): `craft.fuse_kit` 2 fuse components + 1 fastener → 1 fuse kit; `craft.splint` 1 plank + 1 fabric → 1 splint; `craft.repaired_cell` 1 battery housing + 1 fastener → 1 replaceable cell. Shop additions (Ines Vidal, earned coins): lantern 140, flare 10, splint 12, fuse kit 9, repair roll 30.

Injury penalty (D40, PROPOSED): while `injuryFlag` is set, sprint speed is multiplied by 0.85 and stamina regeneration by 0.85. Walking is never affected (F05). Bandages and splints remove it.

### 4.8 Progression (F24, T23 — D37)

- Experience is granted once per dedupe key: first discovery of a place or shelter (5), shelter registration (20), research stage (10), story step (25), rescue or mission completion (10, bounded by mission cooldowns), M11 own bag recovery (5 once per bag, at most once every 15 minutes).
- `rank = floor(sqrt(xp / 50))`. `bonus(rank) = cap × (1 − 0.85^rank)`, cap 15 for max stamina and 15 for max health. Rank 1 ≈ +2, rank 5 ≈ +8, rank 10 ≈ +12; it never exceeds +15.
- The half-health passive cap (F18) applies to the new maximum. No enemy stat scales with rank. Equipment remains the larger advantage.

## 5. Cross-package APIs (fixed names)

Services receive the `services` table in `init`. These names are the contract; implement them exactly.

| Owner | Function | Meaning |
| --- | --- | --- |
| Router (Main.server) | `services.Router.register(action, category, fn)` | Adds a validated request handler. Categories: `interact`, `place`, `party`, `intents`. |
| PlayerService | `grantXp(player, key, amount)` | Idempotent per key; persists; pushes progression |
| PlayerService | `lightState(player) -> { on, itemId, isLantern, shielded, range }` | Read by creatures |
| PlayerService | `snuffLight(player)` | Switch the light off without changing charge |
| PlayerService | `setMothRangeFactor(player, factor)` | 1 = normal |
| PlayerService | `activeFlares() -> { { position, owner, expires } }` | Lit flares |
| PocketService | `versionOf(pocketId) -> string`, `pocketAt(position) -> pocketId?`, `onChanged(fn(pocketId, oldVersion, newVersion))` | `pocketAt` tests the build area between the mouth walls (the same rule records use), not the looser `WorldDefs.pocketAt` bounds |
| PuzzleService | `isPowered() -> boolean`, `isGateOpen(gateId) -> boolean` (P01, P02, P04, W05), `radioSolvedBy(player) -> boolean` | |
| StoryService | `onFact(player)` | Re-evaluate after any profile fact changes (existing pattern) |
| NpcService | `say(player, npcId, lineId)` | Shows subtitled dialogue and writes the journal |
| CreatureService | `research(player, creatureId, evidenceId)` | Existing research path |
| RecoveryService | `bagsOf(player) -> { death?, logout? }` | For M11 |
| PartyService | `onPing(fn(player, position))` | Verified party pings (lead-owned; already implemented) |
| NavigationService | `ownRecords(player, regionId) -> { NavRecord }` | Read-only copy of a player's own records in a region (C04) |
| any | CollectionService tag `PocketBlocker` | A model or part with this tag inside a pocket's bounds postpones a pocket change (rescue survivors, carried NPCs) |
| StoryDefs | `src/shared/Data/StoryDefs.luau` (story package, new) | Dialogue lines, journal text, readable texts, map table position |

Client features live in `src/client/Features/*.luau`. `Main.client` requires every module there after the core controllers and calls `init(ctx)`. A feature subscribes with `ctx.on(channel, fn)`. Cue captions live in `src/shared/Data/CueDefs.luau`.

## 6. Work packages and file ownership

Each package owns its files. A package must not edit another package's files; if it needs a change there, it records the request in its report. Shared contract files are edited only in the scaffold step and at integration.

| Package | Owns |
| --- | --- |
| World and pockets | `WorldBuilder`, new `PocketService`, new `Logic/Pockets`, `DiscoveryService`, `NavigationService`, `Logic/NavRecords`, `RecoveryService`, `Logic/RecoveryBags`, `client/Controllers/WorldRenderer`, `client/Features/PocketFX` |
| Creatures | `CreatureService` (may split into `Services/Creatures/*`), `DirectorService`, `Logic/Director`, `client/Features/CreatureFX` |
| Puzzles and shelters | `PuzzleService`, `Logic/Puzzles`, `ShelterService`, `Logic/Shelters`, `client/Features/PuzzleUI` |
| Story, missions and NPCs | `MissionService`, `StoryService`, `Logic/Story`, new `NpcService`, `EconomyService`, `client/Features/Dialogue`, `client/Features/MissionUI` |
| Player, items and progression | `PlayerService`, `Logic/Vitals`, `Logic/Stamina`, `Logic/Inventory`, `Logic/Commerce`, new `Logic/Progression`, `client/Controllers/Hud`, `client/Controllers/Input`, `client/Controllers/Panels` |
| Scaffold and integration (lead) | `Data/*`, `Logic/Profile`, `Net`, `Main.server`, `Main.client`, `Cues`, `SaveService`, `PartyService`, docs |

Every package adds its own `tests/specs/<package>.luau` and must leave `sh scripts/check-all.sh` passing (unit tests, compile, strict type check with the Roblox definitions, selene, StyLua).

The shared data for all of this already exists (scaffold commit): `WorldDefs` (chambers, corridors with `pocket`, `Pockets`, `pocketAt`, shelters S04/S05, scavenging, hiding, puzzles P03–P06 and W05, rescue and cache spots, `MissionSpots`, `Readables`, creatures C02/C03/C04/C08, characters, missions), `ItemDefs`, `Config` (`Pockets`, `Injury`, `Lantern`, `Flare`, `Progression`, `Creatures`, `Puzzles`, mission numbers), `Profile` schema 2 (`progression`), `CueDefs`, `services.Router`, stub `PocketService` and `NpcService`, and client `ctx.on` with `src/client/Features`. `tests/specs/m3_contract.luau` checks the geometry of that data.
