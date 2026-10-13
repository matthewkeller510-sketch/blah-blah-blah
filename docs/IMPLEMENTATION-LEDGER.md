# Implementation-status ledger

Spec section 23: "Never mark a milestone complete based only on code generation, static checks or a staged screenshot." Nothing below is marked complete.

**Status key**

| Label | Meaning |
| --- | --- |
| `LOGIC-TESTED` | The rule lives in a Roblox-independent module and passes unit tests (`lune run tests/run`, 50 tests). |
| `CODED` | Roblox code exists, compiles (`scripts/check-syntax`) and lints clean (selene), but **has not been run in Studio or on a device**. |
| `PARTIAL` | Part of the requirement is coded; the gap is stated. |
| `PLANNED` | Specified, not built. |

**Environment facts for this commit**

- Exercised: Lune 0.11 unit tests, a Luau compile of all 37 files, selene 0.31 (with a minimal local Roblox globals file, because the full Roblox std could not be downloaded here), StyLua 2.6 format check, and `rojo build` of the project (see the end of this file).
- Not exercised: Roblox Studio, DataStores, replication, streaming, touch devices, performance. **No Studio place was inspected or changed** (spec section 01). There is no tested place identity yet.

## Milestone 1 systems slice (spec section 23)

| Slice item | Status | Where | How exercised | Remaining limitations / next dependency |
| --- | --- | --- | --- | --- |
| One grounded district | CODED (greybox) | `WorldBuilder.luau`, `WorldDefs.Chambers/Corridors` | Compile + lint only | R00 depot + ramp; R01 Old Quarry with 7 chambers, 8 corridors, 2 loops and landmarks (split pier, sloped gallery, rusted pulley, survey board). Primitive parts tagged `BLOCKOUT`. Needs Studio walk-through, scale check against the 6-stud rig and lighting review on devices. No modular kit, LODs or audio yet. |
| One shelter | CODED | `ShelterService.luau`, `WorldDefs.Shelters` | Upgrade rules LOGIC-TESTED | Worker's Alcove: exterior gate, isolated interior cells per solo player or party, banking, 3 fortification stages, safety vs functional upgrades. Interiors are separated by distance and streaming, not a hard replication boundary (see T11). |
| Complete short rescue (M01) | CODED | `MissionService.luau` | Compile + lint only | Cue → treat (faster with supplies, slower without) → escort (pathfinding) or carry → shelter → individual coin reward and cooldown. Needs Studio test of escort pathing through corridor openings. |
| Vulnerable creature (C05 Scrabbler) | CODED | `CreatureService.luau` | Compile + lint only | Hears sprinting or walking on rubble, sees further when your light is on, scraping wind-up, rush, iron bar kills (60 HP), stun device stuns, no farmable loot. Placeholder body; no animation. |
| Unkillable creature (C07 Knocker) | CODED | `CreatureService.luau` | Compile + lint only | Three captioned knocks, then a line charge down the long pier–pulley corridor. Stepping out of the line dodges it. A stun during the knocks interrupts it. Melee visibly fails. |
| Resource scarcity | LOGIC-TESTED (pressure) / CODED | `Director.luau`, `DirectorService`, `PlayerService` light drain | Pressure tests | Light charge drains; cells are swapped with a timed action; medical items are consumed; the director raises pressure as supplies dwindle and never reads spending. |
| Party sharing | LOGIC-TESTED (union, discovery) / CODED | `PartyService`, `Shelters.luau`, `Progress.luau` | Union, inherit and discovery tests | Session-only parties, explicit invite flow, permanent upgrade inheritance, shared discoveries, individual claims. |
| Death / logout recovery | LOGIC-TESTED / CODED | `Inventory.luau`, `RecoveryBags.luau`, `RecoveryService.luau` | Provenance and bag tests | Anchored records survive server close by design (T17 still needs a published test). Cross-server delegate recovery is PLANNED. |

## Owner rules (section 02)

| Rule | Status | Notes |
| --- | --- | --- |
| F01 Mature horror, phones/tablets/PC first | PARTIAL | Touch-first controls and safe-area GUI are coded. Tone needs art, audio and device testing. Content rating questionnaire not done (section 22). |
| F02 Historical tunnels get stranger with depth | PARTIAL | Only R00/R01 exist. R02–R09 are PLANNED. |
| F03 Repeatable activities + long adventure | PARTIAL | Repeatable M01, scavenging and creature research only. The 40-hour story is PLANNED. |
| F04 Light and medical are the primary resources | CODED | No food or water. |
| F05 Exhaustion stops sprint, walking continues | LOGIC-TESTED | `Stamina.luau`, T03 tests. |
| F06 Low supplies → closer stalking; subtle early sightings | LOGIC-TESTED (pressure, stalk distance) / CODED (Sidelooker) | |
| F07 Run/hide/flee; some killable, some not; all understandable | CODED | Scrabbler killable, Knocker not. Research stages LOGIC-TESTED. Hiding spots (lockers, niches) are PLANNED. |
| F08 Permanent areas + changing pockets | PARTIAL | Pocket versioning and migration of navigation records are LOGIC-TESTED. No variable pockets are built (R05). |
| F09 Chalk/signs/rope visible only to owner + party; persist until retrieved | LOGIC-TESTED / CODED | `NavRecords.luau`, `NavigationService`, `WorldRenderer`. |
| F10 Shelters: relatively safe → completely safe when fortified | LOGIC-TESTED (fortification) / CODED (damage block, probe) | |
| F11 Shelter improvements private | CODED | Per-player upgrade maps; isolated interior cells. |
| F12 Parties temporary; solo vs group progress | CODED | Party IDs are never persisted. |
| F13 Shared shelter upgrades permanently inherited | LOGIC-TESTED | Max-union, idempotent. |
| F14 Individual inventories; collect your own copy | LOGIC-TESTED (claims) / CODED (scavenge and unique pickups per player) | |
| F15 Only groupmates interact with / collect a grouped player's belongings | LOGIC-TESTED (bag access) / CODED (medical, carry) | |
| F16 One latest death bag; coins + protected items survive | LOGIC-TESTED | |
| F17 Logout bag of expedition loot; login at last shelter | LOGIC-TESTED / CODED | Crash reconciliation from the saved checkpoint is CODED. |
| F18 Auto-heal stops at half max; more needs supplies | LOGIC-TESTED | T13 tests. Default regeneration script replaced. |
| F19 No hard lock when broke or unequipped | PARTIAL | No-light close-range legibility light, no-supply rescue treatment and a no-light scavenging site exist. Needs T02 device check. |
| F20 Everything obtainable through play | CODED | Every shop item is also scavengeable or craftable, except the expedition flashlight and stun device, which are bought for earned coins only. A world source for those two is PLANNED. |
| F21 Unused navigation items survive death regardless of source | LOGIC-TESTED | |
| F22 Small class advantages; respec has a cost | CODED | ~5% modifiers; 150 earned coins (D06). |
| F23 Different perceived events; brief puzzles | PARTIAL | Deterministic per-recipient seed is LOGIC-TESTED; the Sidelooker is a private sighting. Puzzles P01–P06 are PLANNED. |
| F24 Veterans: better stats/equipment | PLANNED | `profile.stats` fields exist; there is no progression curve. |

## Spec sections

| Section | Status | Notes |
| --- | --- | --- |
| 04 World structure, R00–R09 | R00/R01 CODED (greybox). R02–R09 PLANNED. | |
| 05 Story, N01–N06 | PLANNED | Only a Mara Voss mission board placeholder exists. No dialogue or journals. |
| 06 Missions M01–M12 | M01 CODED. M02–M12 PLANNED. | Behavior: `docs/MISSIONS.md`. |
| 07 Movement, camera, interaction | CODED | Sprint, crouch (camera offset only, no crawlspaces), cancelable held actions, carry with weld, downed crawl. Climbing and ledges PLANNED. |
| 08 Supplies, scarcity, fair danger | CODED | |
| 09 Equipment, crafting, classes | PARTIAL | 2 lights, cells, 2 medical, 2 tools, 3 navigation items, 5 materials, 2 treasures. Headlamp, lantern, flare, splint, harness and the rest are PLANNED. 2 recipes. |
| 10 Creatures C01–C12 | C01, C05, C07 CODED. Others PLANNED. | Research stages LOGIC-TESTED. |
| 11 Director and perception | PARTIAL | Pressure, caps and cooldowns are LOGIC-TESTED and used. Encounter states are distinct in each creature. Party-cosmetic events are PLANNED. |
| 12 Puzzles P01–P06 | PLANNED | |
| 13 Shelters | PARTIAL | One family (quarry alcove). The other five families are PLANNED. |
| 14 Parties | CODED | |
| 15 Death, logout, recovery | CODED / LOGIC-TESTED | |
| 16 Navigation persistence | CODED / LOGIC-TESTED | Region paging covers R01 only. |
| 17 UI, accessibility, audio | PARTIAL | HUD, captions with direction, visual pulse for essential cues, settings for flashes, motion, text, sensitivity, FOV, sprint hold/toggle and low light. **No audio assets.** Screens still PLANNED: onboarding/class preview, item comparison, discovery collection, dedicated recovery screen, reconnect screen. |
| 18 Visual production | PLANNED | Greybox only. |
| 19 Performance / client–server | PARTIAL | Server-authoritative requests, rate limits, client rendering radius for private markers. No device profiling. |
| 20 Save model | CODED | Session-locked `UpdateAsync`, retries with backoff, autosave, `BindToClose`, durable commits before success messages, versioned schema. See `docs/SAVE-SCHEMA.md`. |
| 21 Economy and purchases | CODED (store disabled) | Receipt dedupe is LOGIC-TESTED. No product IDs configured (deliberate). |
| 22 Content rating / history | PLANNED | No real historical text is shipped. The survey board uses fictional French labels. |

## Acceptance scenarios (section 24)

| ID | Status | Evidence so far |
| --- | --- | --- |
| T01 Solo: landmark → short objective → shelter on touch | CODED | Needs a device run |
| T02 Half health, no money/light/supplies can still play | PARTIAL | No-light scavenging site test; close-range light coded |
| T03 Stamina exhaustion | LOGIC-TESTED | `tests/run.luau` Stamina |
| T04 Subtle early sighting; dangerous encounter has cue + escape | CODED | |
| T05 Killable dies; unkillable shows ineffectiveness + counter | CODED | |
| T06 Puzzles solo with cue alternatives | PLANNED | No puzzles yet |
| T07 Different cosmetic events, same authoritative state | PARTIAL | Event seed test; Sidelooker is private |
| T08 Group discovery → personal records | LOGIC-TESTED / CODED | |
| T09 Collect your own treasure | LOGIC-TESTED / CODED | |
| T10 Newcomer inherits upgrades, no duplication | LOGIC-TESTED | |
| T11 Outsiders cannot see, enter or loot another party's interior | PARTIAL | Separate cells by distance and streaming; needs a replication audit |
| T12 Fortified shelter cannot be breached | CODED | `canBeDamaged` gate plus physically closed cells |
| T13 Auto-heal stops at half, never reduces higher health | LOGIC-TESTED | |
| T14 Earned and paid navigation items survive death; placed ones persist | LOGIC-TESTED | |
| T15 One death bag; next death removes only the prior death bag | LOGIC-TESTED | |
| T16 Logout bag exactly once; no duplicate on rejoin | LOGIC-TESTED (opId replay) / CODED | |
| T17 Bag survives server close | CODED (anchored records) | Needs a published-place test |
| T18 Navigation visibility after party change; stream-out/in | LOGIC-TESTED / CODED | |
| T19 Receipts grant exactly once | LOGIC-TESTED (ledger) / CODED | No products configured |
| T20 Save failure visible; concurrent sessions can't overwrite | CODED | Session lock + HUD save status |
| T21 Phone/tablet/PC layouts | PARTIAL | Needs device check |
| T22 Real-device performance | PLANNED | |
| T23 Long-term progression without real money | PLANNED | |
| T24 Content audit | This ledger | |

## Required deliverables (section 23)

| Deliverable | Status |
| --- | --- |
| Editable project source, organized Luau modules | Present |
| World/asset definitions | `src/shared/Data` |
| Configured test fixtures | `tests/run.luau` (logic). Studio fixtures PLANNED. |
| Economy/progression sheet | `docs/ECONOMY.md` |
| Audio cue list | `docs/AUDIO-CUES.md` |
| Localization strings | PLANNED. Strings are still inline in code. |
| Save schema and migration plan | `docs/SAVE-SCHEMA.md` |
| Implementation-status ledger | This file |
| Clean import instructions | `README.md` |
| External assets with ownership and asset IDs | None bound. Every mesh, icon and sound reference is `PLACEHOLDER:` in `ItemDefs.luau`. |
| Reference mapping (A01–D01) | PLANNED. The reference images were not supplied as separate files in this session. |
