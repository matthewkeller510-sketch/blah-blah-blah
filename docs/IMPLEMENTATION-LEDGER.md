# Implementation-status ledger

Spec section 23: "Never mark a milestone complete based only on code generation, static checks or a staged screenshot." Nothing below is marked complete.

**Status key**

| Label | Meaning |
| --- | --- |
| `LOGIC-TESTED` | The rule lives in a Roblox-independent module and passes unit tests (`lune run tests/run`; 341 tests in `tests/specs`). |
| `CODED` | Roblox code exists, compiles, passes the strict type check against the Roblox API definitions and lints clean, but **has not been run in Studio or on a device**. |
| `PARTIAL` | Part of the requirement is coded; the gap is stated. |
| `PLANNED` | Specified, not built. |

**Environment facts for this commit**

- Exercised: `sh scripts/check-all.sh` — Lune 0.11 unit tests, a Luau compile of every file, a strict type check with luau-lsp 1.53 and its Roblox definitions (0 diagnostics), selene 0.31, StyLua 2.6; `rojo build` to `build/CatacombsUntitled.rbxl`; a scripted cross-package check (every service call resolves, every client request has a handler, every cue id exists, every server channel has a client listener); and two rounds of multi-lens review with independent verification of every finding (Milestone 3: round one confirmed 26 findings and round two 17, all fixed; a regression review of those fixes confirmed 10 more, all fixed; 6 findings were refuted). Fixes that change behaviour carry a test that fails on the old code where the rule is pure logic.
- Not exercised: Roblox Studio, DataStores, replication, streaming, touch devices, performance. **No Studio run has been reported back yet.** There is no tested place identity.

## Milestones

| Milestone | Contents | Status |
| --- | --- | --- |
| M1 systems slice (sec 23) | R00 + R01 greybox, Worker's Alcove, M01, Scrabbler, Knocker, Sidelooker, scarcity, parties, death/logout recovery, saving | CODED / LOGIC-TESTED |
| M2 depth and story | R02 Ossuary Galleries and R03 Flooded Works (greybox), shelters S02 and S03, puzzles P01 and P02, C06 Wader, a second Scrabbler, hiding niches, thrown stones, Act I story with journal, first-join class choice, M02 and M07, world sources for every shop item | CODED / LOGIC-TESTED |
| M3 Contradictory Records (`docs/MILESTONE-3.md`) | R04 Abandoned Survey Station and R05 Shifting Crossroads (greybox) with three variable pockets (F08) and pocket-versioned records; shelters S04 and S05; puzzles P03, P04, P05, P06 and W05; creatures C02 Borrowed Miner, C03 Wick Moth, C04 Chalk Hand, C08 Lantern Thief; missions M03, M04, M05, M09, M11; Act II with NPC figures N01–N04 and N06 and Elise Renaud's recordings; shielded lantern, flares, splint, fuse kits, repair tool roll; injury penalty; field-experience progression (F24); schema 3; item protection table | CODED / LOGIC-TESTED |

## Owner rules (section 02)

| Rule | Status | Notes |
| --- | --- | --- |
| F01 Mature horror, phones/tablets/PC first | PARTIAL | Touch-first controls: a 5 × 3 grid of 52 px buttons above the jump button, a free cursor on PC whenever a screen is open, screens that close during a chase. Tone needs art, audio and device testing. Content direction recorded (D36); the rating questionnaire is not done (section 22). |
| F02 Historical tunnels get stranger with depth | PARTIAL | R00–R03 grounded, R04 survey station with mis-dated equipment, R05 changing passages. R06–R09 are PLANNED. |
| F03 Repeatable activities + long adventure | PARTIAL | Repeatable M01, M02, M03, M05, M07, scavenging and research; Acts I–II (roughly 3–5 hours of the 40-hour target, untested). Acts III–V PLANNED. |
| F04 Light and medical are the primary resources | CODED | Adds the shielded lantern, flares, splints and battery crafting. |
| F05 Exhaustion stops sprint, walking continues | LOGIC-TESTED | The injury penalty slows sprint and stamina recovery only, never walking (D40). |
| F06 Low supplies → closer stalking; subtle early sightings | LOGIC-TESTED / CODED | The Lantern Thief engages only above director pressure 0.35 (a poorly supplied traveller). |
| F07 Run/hide/flee; some killable, some not; all understandable | CODED | Four new creatures with cues, counters and four-stage research each; the Lantern Thief never strikes before its counter evidence has been read (D47). |
| F08 Permanent areas + changing pockets | CODED / LOGIC-TESTED | Three pockets in R05 change on a deterministic schedule, only when empty, after a telegraph; every version keeps both mouths connected. |
| F09 Markers visible to owner + party; persist until retrieved | LOGIC-TESTED / CODED | Records inside a pocket migrate to a documented anchor when their version is gone, with a notice; never deleted (D31). |
| F10 Shelters: relatively safe → completely safe | LOGIC-TESTED / CODED | Five shelters. |
| F11 Shelter improvements private | CODED | |
| F12 Parties temporary; solo vs group progress | CODED | |
| F13 Shared shelter upgrades permanently inherited | LOGIC-TESTED | Includes the grant-only `station_power`. |
| F14 Individual inventories; collect your own copy | LOGIC-TESTED / CODED | Station tape, waterworks log and the M05 cache are per-player claims. |
| F15 Only groupmates interact with a grouped player | LOGIC-TESTED / CODED | |
| F16 One latest death bag; coins + protected items survive | LOGIC-TESTED | Protection table in `docs/PROTECTION-TABLE.md` (D33); a dead, downed or carried player can no longer act (so a body cannot recover its own new bag before respawning). |
| F17 Logout bag; login at last shelter | LOGIC-TESTED / CODED | |
| F18 Auto-heal stops at half max | LOGIC-TESTED | Health is now saved, so a rejoin never heals (D81); the cap follows the progression-raised maximum. |
| F19 No hard lock when broke or unequipped | PARTIAL | Every Milestone 3 objective, puzzle and story step has organic sources and needs no money; needs a T02 device check. |
| F20 Everything obtainable through play | CODED | Every new shop item has a world source (tested). |
| F21 Unused navigation items survive death regardless of source | LOGIC-TESTED | |
| F22 Small class advantages; respec has a cost | CODED | Technician works fuses faster. |
| F23 Different perceived events; brief puzzles | PARTIAL | Six puzzles built (P01–P06) plus W05. Private sightings (Sidelooker), private swarms (Wick Moth) and private false marks (Chalk Hand). |
| F24 Veterans: better stats/equipment | LOGIC-TESTED / CODED | Field experience and ranks with diminishing returns (D37); equipment stays the larger advantage. |

## Spec sections

| Section | Status | Notes |
| --- | --- | --- |
| 04 World, R00–R09 | R00–R05 CODED (greybox). R06–R09 PLANNED. | 39 chambers. R05 has three variable pockets (PK1, PK2, PK3) built by `PocketService`. |
| 05 Story, N01–N06 | PARTIAL | Acts I–II with journal; greybox figures for N01–N04 and N06 with subtitled dialogue; N05 in recordings and notes. Acts III–V PLANNED. |
| 06 Missions M01–M12 | M01, M02, M03, M04, M05, M07, M09, M11 CODED. M06, M08, M10, M12 PLANNED. | `docs/MISSIONS.md` |
| 07 Movement, camera, interaction | CODED | Climbing and ledges PLANNED. |
| 08 Supplies, scarcity | CODED | Injury penalty, lantern, flares. |
| 09 Equipment, crafting, classes | PARTIAL | Adds lantern, flare, splint, repair roll, fuse kit, fuse components, battery housing and three recipes. Searchlight, harness, gloves, jacket, anchor stake and survey compass PLANNED. |
| 10 Creatures C01–C12 | C01–C08 CODED. C09–C12 PLANNED. | |
| 11 Director and perception | CODED | Lantern exposure, flare decoys, one damaging threat per victim. |
| 12 Puzzles P01–P06 | P01–P06 and W05 CODED (rules LOGIC-TESTED). | |
| 13 Shelters | PARTIAL | Five of six families (quarry alcove, inspection office, raised pump platform, survey station room, stable anchor chamber). Buried workshop PLANNED (D34). |
| 14 Parties | CODED | Shelter occupants regroup when parties change. |
| 15 Death, logout, recovery | CODED / LOGIC-TESTED | Pocket-aware anchors; health saved across sessions. |
| 16 Navigation persistence | CODED / LOGIC-TESTED | Pocket versions and migration; preset route ids only. |
| 17 UI, accessibility, audio | PARTIAL | Dialogue, mission and puzzle screens; captions above panels; Reduce flashes respected by every new effect. Still no audio assets. |
| 18 Visual production | PLANNED | Greybox only. |
| 19 Performance / client–server | PARTIAL | No device profiling. |
| 20 Save model | CODED | Schema 3 (`docs/SAVE-SCHEMA.md`): field experience, pocket-versioned records, saved health. |
| 21 Economy and purchases | CODED (store disabled) | |
| 22 Content rating / history | PLANNED | All plaque, sign, log and note texts are fictional. |

## Acceptance scenarios (section 24)

| ID | Status | Evidence so far |
| --- | --- | --- |
| T01 Solo: landmark → short objective → shelter on touch | CODED | Needs a device run |
| T02 Half health, no money/light/supplies can still play | PARTIAL | No-light scavenging sites in R01–R05 |
| T03 Stamina exhaustion | LOGIC-TESTED | |
| T04 Subtle early sighting; dangerous encounter has cue + escape | CODED | Captions for every damaging cue |
| T05 Killable dies; unkillable shows ineffectiveness + counter | CODED | Knocker, Wader and Lantern Thief show "weapon ineffective" |
| T06 Puzzles solo with cue alternatives | LOGIC-TESTED / CODED | P05 is fully readable with sound off |
| T07 Different cosmetic events, same authoritative state | PARTIAL | Private swarms and false marks; collision, puzzles and records stay authoritative |
| T08 Group discovery → personal records | LOGIC-TESTED / CODED | |
| T09 Collect your own treasure | LOGIC-TESTED / CODED | |
| T10 Inherit upgrades, no duplication | LOGIC-TESTED | |
| T11 Outsiders cannot reach another party's interior | PARTIAL | Needs a replication audit |
| T12 Fortified shelter cannot be breached | CODED | |
| T13 Auto-heal half cap | LOGIC-TESTED | Also across rejoins |
| T14 Navigation items survive death; placed ones persist | LOGIC-TESTED | |
| T15 One death bag | LOGIC-TESTED | |
| T16 Logout bag exactly once | LOGIC-TESTED / CODED | |
| T17 Bag survives server close | CODED | Pocket-aware; needs a published-place test |
| T18 Navigation visibility after party change | LOGIC-TESTED / CODED | Includes pocket migration |
| T19 Receipts exactly once | LOGIC-TESTED / CODED | No products configured |
| T20 Save failure visible; no concurrent overwrite | CODED | Lock-release and same-server rejoin fixes |
| T21 Phone/tablet/PC layouts | PARTIAL | Layout arithmetic tested for phones and tablets; needs devices |
| T22 Real-device performance | PLANNED | |
| T23 Long-term progression without real money | LOGIC-TESTED | Field experience; no paid path |
| T24 Content audit | This ledger | |

## Required deliverables (section 23)

| Deliverable | Status |
| --- | --- |
| Editable source, organized Luau modules | Present |
| Single place file | `build/CatacombsUntitled.rbxl` (rebuilt each milestone) |
| World/asset definitions | `src/shared/Data` |
| Test fixtures | `tests/specs/*.luau` (logic, world-graph and data-contract checks). Studio fixtures PLANNED. |
| Economy sheet | `docs/ECONOMY.md` |
| Audio cue list | `docs/AUDIO-CUES.md` |
| Localization strings | PLANNED. Strings are still inline (story text in `src/shared/Data/StoryDefs.luau`). |
| Save schema and migration plan | `docs/SAVE-SCHEMA.md` (schema 3) |
| Item protection table | `docs/PROTECTION-TABLE.md` |
| Ledger | This file |
| Import instructions | `README.md` |
| External assets | None bound. All references are `PLACEHOLDER:`. |
