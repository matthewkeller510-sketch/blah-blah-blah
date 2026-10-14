# Implementation-status ledger

Spec section 23: "Never mark a milestone complete based only on code generation, static checks or a staged screenshot." Nothing below is marked complete.

**Status key**

| Label | Meaning |
| --- | --- |
| `LOGIC-TESTED` | The rule lives in a Roblox-independent module and passes unit tests (`lune run tests/run`, 64 tests). |
| `CODED` | Roblox code exists, compiles (`scripts/check-syntax`) and lints clean (selene), but **has not been run in Studio or on a device**. |
| `PARTIAL` | Part of the requirement is coded; the gap is stated. |
| `PLANNED` | Specified, not built. |

**Environment facts for this commit**

- Exercised: Lune 0.11 unit tests, a Luau compile of every file, selene 0.31 (with a minimal local Roblox globals file), StyLua 2.6 format check, `rojo build` to `build/CatacombsUntitled.rbxl`, and an independent static review of the Roblox-facing code.
- Not exercised: Roblox Studio, DataStores, replication, streaming, touch devices, performance. **No Studio run has been reported back yet.** There is no tested place identity.

## Milestones

| Milestone | Contents | Status |
| --- | --- | --- |
| M1 systems slice (sec 23) | R00 + R01 greybox, Worker's Alcove, M01, Scrabbler, Knocker, Sidelooker, scarcity, parties, death/logout recovery, saving | CODED / LOGIC-TESTED |
| M2 depth and story | R02 Ossuary Galleries and R03 Flooded Works (greybox), shelters S02 and S03, puzzles P01 and P02, C06 Wader, a second Scrabbler, hiding niches, thrown stones, Act I story with journal, first-join class choice, M02 and M07, world sources for every shop item | CODED / LOGIC-TESTED |

## Owner rules (section 02)

| Rule | Status | Notes |
| --- | --- | --- |
| F01 Mature horror, phones/tablets/PC first | PARTIAL | Touch-first controls and safe-area GUI are coded. Tone needs art, audio and device testing. Content rating questionnaire not done (section 22). |
| F02 Historical tunnels get stranger with depth | PARTIAL | R00–R03 are grounded (quarry → ossuary → waterworks). The stranger regions R04–R09 are PLANNED. |
| F03 Repeatable activities + long adventure | PARTIAL | Repeatable M01, M02, M07, scavenging and research. Act I only, about 1–2 hours of the 40-hour target. |
| F04 Light and medical are the primary resources | CODED | |
| F05 Exhaustion stops sprint, walking continues | LOGIC-TESTED | |
| F06 Low supplies → closer stalking; subtle early sightings | LOGIC-TESTED / CODED | |
| F07 Run/hide/flee; some killable, some not; all understandable | CODED | Hiding niches, thrown distractions, killable Scrabbler, unkillable Knocker and Wader, research hints for every stage. |
| F08 Permanent areas + changing pockets | PARTIAL | Record migration is LOGIC-TESTED. No variable pockets (R05) are built. |
| F09 Markers visible to owner + party; persist until retrieved | LOGIC-TESTED / CODED | Now across all regions. |
| F10 Shelters: relatively safe → completely safe | LOGIC-TESTED / CODED | Three shelter families. |
| F11 Shelter improvements private | CODED | |
| F12 Parties temporary; solo vs group progress | CODED | |
| F13 Shared shelter upgrades permanently inherited | LOGIC-TESTED | |
| F14 Individual inventories; collect your own copy | LOGIC-TESTED / CODED | Includes the M02 cache and the story tag. |
| F15 Only groupmates interact with a grouped player | LOGIC-TESTED / CODED | |
| F16 One latest death bag; coins + protected items survive | LOGIC-TESTED | The story tag is protected (D21). |
| F17 Logout bag; login at last shelter | LOGIC-TESTED / CODED | Login places you at whichever shelter you last registered. |
| F18 Auto-heal stops at half max | LOGIC-TESTED | |
| F19 No hard lock when broke or unequipped | PARTIAL | Every puzzle and shelter is optional or reachable without equipment. Needs a T02 device check. |
| F20 Everything obtainable through play | CODED | Every shop item now has a world source (D30). |
| F21 Unused navigation items survive death regardless of source | LOGIC-TESTED | |
| F22 Small class advantages; respec has a cost | CODED | Free first choice (D22), then 150 earned coins. |
| F23 Different perceived events; brief puzzles | PARTIAL | Two puzzles built (P01, P02). The Sidelooker is a private sighting. Party-cosmetic events are PLANNED. |
| F24 Veterans: better stats/equipment | PLANNED | |

## Spec sections

| Section | Status | Notes |
| --- | --- | --- |
| 04 World, R00–R09 | R00–R03 CODED (greybox). R04–R09 PLANNED. | 18 chambers, 21 corridors including two sloped descents. Ossuary bone inserts are authored panels, not wallpaper. The Flooded Works has shallow water, stepping-stone routes and a dry pump gallery. |
| 05 Story, N01–N06 | PARTIAL | Act I's six steps, journal entries and Mara Voss lines (placeholder board, no NPC model). Acts II–V and the N02–N06 characters are PLANNED. |
| 06 Missions M01–M12 | M01, M02, M07 CODED. Others PLANNED. | `docs/MISSIONS.md` |
| 07 Movement, camera, interaction | CODED | Climbing and ledges are PLANNED. |
| 08 Supplies, scarcity | CODED | |
| 09 Equipment, crafting, classes | PARTIAL | Adds the compact headlamp, the old expedition tag and the lead seal. Lantern, flare, splint, harness and others are PLANNED. |
| 10 Creatures C01–C12 | C01, C05 (×2), C06, C07 CODED. Others PLANNED. | |
| 11 Director and perception | PARTIAL | Hidden players are imperceptible. Wader engagement is director-gated. |
| 12 Puzzles P01–P06 | P01, P02 CODED (rules LOGIC-TESTED). P03–P06 PLANNED. | Both have visual and audible feedback and immediate reset (P02). |
| 13 Shelters | PARTIAL | Three of six families: quarry alcove, inspection office, raised pump platform. |
| 14 Parties | CODED | |
| 15 Death, logout, recovery | CODED / LOGIC-TESTED | Anchors in every region. |
| 16 Navigation persistence | CODED / LOGIC-TESTED | Region-paged across R01–R03. |
| 17 UI, accessibility, audio | PARTIAL | Adds the briefing and class choice, story objective, journal, research hints, captions for every new cue, and a throw button. Still no audio assets. |
| 18 Visual production | PLANNED | Greybox only. |
| 19 Performance / client–server | PARTIAL | No device profiling. |
| 20 Save model | CODED | |
| 21 Economy and purchases | CODED (store disabled) | |
| 22 Content rating / history | PLANNED | All plaque and sign texts are fictional French labels; no real inscriptions or records are quoted. A citation review is still needed before any real history is added. |

## Acceptance scenarios (section 24)

| ID | Status | Evidence so far |
| --- | --- | --- |
| T01 Solo: landmark → short objective → shelter on touch | CODED | Needs a device run |
| T02 Half health, no money/light/supplies can still play | PARTIAL | No-light scavenging sites in R01–R03 |
| T03 Stamina exhaustion | LOGIC-TESTED | |
| T04 Subtle early sighting; dangerous encounter has cue + escape | CODED | Captions for every damaging cue |
| T05 Killable dies; unkillable shows ineffectiveness + counter | CODED | Knocker and Wader both show "weapon ineffective" |
| T06 Puzzles solo with cue alternatives | LOGIC-TESTED (rules) / CODED | P01 is visual; P02 has a visual gauge plus a captioned count |
| T07 Different cosmetic events, same authoritative state | PARTIAL | Puzzle state is shared and authoritative |
| T08 Group discovery → personal records | LOGIC-TESTED / CODED | |
| T09 Collect your own treasure | LOGIC-TESTED / CODED | |
| T10 Inherit upgrades, no duplication | LOGIC-TESTED | |
| T11 Outsiders cannot reach another party's interior | PARTIAL | Needs a replication audit |
| T12 Fortified shelter cannot be breached | CODED | |
| T13 Auto-heal half cap | LOGIC-TESTED | |
| T14 Navigation items survive death; placed ones persist | LOGIC-TESTED | |
| T15 One death bag | LOGIC-TESTED | |
| T16 Logout bag exactly once | LOGIC-TESTED / CODED | |
| T17 Bag survives server close | CODED | Needs a published-place test |
| T18 Navigation visibility after party change | LOGIC-TESTED / CODED | |
| T19 Receipts exactly once | LOGIC-TESTED / CODED | No products configured |
| T20 Save failure visible; no concurrent overwrite | CODED | |
| T21 Phone/tablet/PC layouts | PARTIAL | The touch grid is now 3 × 4 |
| T22 Real-device performance | PLANNED | |
| T23 Long-term progression without real money | PLANNED | |
| T24 Content audit | This ledger | |

## Required deliverables (section 23)

| Deliverable | Status |
| --- | --- |
| Editable source, organized Luau modules | Present |
| Single place file | `build/CatacombsUntitled.rbxl` (rebuilt each milestone) |
| World/asset definitions | `src/shared/Data` |
| Test fixtures | `tests/run.luau` (logic and world-graph checks). Studio fixtures PLANNED. |
| Economy sheet | `docs/ECONOMY.md` |
| Audio cue list | `docs/AUDIO-CUES.md` |
| Localization strings | PLANNED. Strings are still inline. |
| Save schema and migration plan | `docs/SAVE-SCHEMA.md` (no schema change in M2) |
| Ledger | This file |
| Import instructions | `README.md` |
| External assets | None bound. All references are `PLACEHOLDER:`. |
