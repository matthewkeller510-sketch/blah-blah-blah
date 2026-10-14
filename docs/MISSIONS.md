# Mission behavior

Section 06 requires every template to specify failure, abandonment, disconnect and late-join behavior. M01, M02, M03, M04, M05, M07, M09 and M11 are built (M03, M04, M05, M09 and M11 in Milestone 3). M06, M08, M10 and M12 are PLANNED and must get the same table before implementation. Rules live in `src/shared/Logic/MissionRules.luau` (unit-tested); `src/server/Services/MissionService.luau` applies them.

Common rules for every template:

- Missions are offered from Mara Voss's depot board or a shelter panel. The list shows the estimate, the risk, any cooldown in seconds and, when a template cannot be offered right now, the reason (`locked`). Accepting explains every refusal in a notice. There is never a GPS path.
- Objectives are generated only where they are reachable from the player's **last shelter** on the corridor graph; closed puzzle gates count as walls (`WorldDefs.hops` with `PuzzleService.openGates()`). "Nearby" means within 3 corridors (D28). Mission spots are never inside a variable pocket.
- One active mission per player. A party accepts a shared objective together: every member without another active mission and without a running cooldown for that template joins. Rewards are always individual.
- **Late join**: a current party member of the mission's owner may join a shared objective by interacting with it, unless they already have a mission or are on that template's cooldown.
- Rewards are written to the profile, then **saved durably before the success text** appears ("… Saved."). If the save fails, the text says so and the save retries.
- Every completion adds field experience once per completion (`mission:<template>:<n>`), except M11, which grants its own once-per-bag experience.
- Leaving a mission (abandon, death where it applies, disconnect) clears its objective from your HUD. Failure messages name the mission.

## M01 Nearby Rescue (5–15 min, low risk)

| Phase | Behavior |
| --- | --- |
| Offer | Shows estimate and risk, never a GPS path. Unavailable during the per-player cooldown (`Config.Missions.nearbyRescueCooldownSeconds`, 120 s TUNE) or while another mission is active. |
| Objective generation | Picks an unused spawn from `WorldDefs.RescueSpawns` (R01–R05, stable chambers only) within 3 corridors of the last shelter. If none qualifies, nothing is offered. |
| Cue | A readable environmental cue at the spawn: dropped lamp (dim light), rope end, or chalk scrawl "AIDE ↓". The objective text names the area and the cue type. |
| Treat | Hold interaction. With a bandage, splint or dressing: 4 s and consumes one. Without supplies: 9 s, and the player is told it is slower. Never a lock. Medic class 5% faster. If two people treat at once, only the first finished hold counts. |
| Move | **Escort**: the survivor follows the player with pathfinding (one follow loop at a time; it waits if the leader enters a shelter without it). **Carry**: welded to the player, carry speed multiplier 0.6, cannot sprint. Dropping returns the survivor to "ready". |
| Complete | Carry the survivor into the shelter, or enter the shelter with the escorted survivor within 18 studs. Each participant gets 40 coins individually, the cooldown, a durable save, and a director recovery interval. |
| Party | The party at acceptance shares the objective. A current party member of the owner who interacts later joins it (late join; not while on cooldown or in another mission). Rewards are per participant. |
| Death | The dead player leaves the mission. If others remain, ownership transfers and a carried or escorting survivor becomes "ready" where they are. If nobody remains, the mission fails: "The survivor was found by another team." |
| Disconnect / logout | Same as death (handover or fail). Nothing about the mission is persisted; the survivor is not owed. |
| Abandon | The "Abandon current" button in the mission list behaves like leaving. |
| Timeout | 25 minutes without progress (finding, treating, moving the survivor) fails it with "timed out". A survivor being carried never times out. A survivor who dies or falls out of the world fails it ("the survivor was lost"). |
| Story | M01 completions are counted in `storyStates["M01.completions"]`. Repeating never resets story state. |

## M02 Missing Survey Cache (10–25 min, low risk)

| Phase | Behavior |
| --- | --- |
| Objective | An instrument case appears at an unused `WorldDefs.CacheSpots` spot near the last shelter. The text describes the landmark ("under the wheel that no longer turns") and names the region, never the exact room. |
| Collect | Hold to open **your own copy**: +20 coins, 1 cell, 1 cloth dressing, 1 fastener (expedition loot; overflow goes to escrow) and a short lore fragment. Each participant opens their own; one player's copy never consumes another's. |
| Party / late join | The party at acceptance shares the objective. A current party member of the owner may join by opening the case (not while on cooldown or in another mission). Ownership moves to a remaining participant once the owner has their copy, so late joins keep working. |
| End | The case is removed once every online participant has their copy, or after 25 minutes without progress. |
| Death | Does not cancel it: come back after respawning. |
| Disconnect / abandon | The leaver drops out. If nobody remains, it ends. |
| Cooldown | 180 s per player (TUNE). |

## M03 Medical Delivery (10–20 min, low risk)

| Phase | Behavior |
| --- | --- |
| Offer | Always offerable while no other mission is active and the cooldown has run out, even with no medical items (the objective then helps you find some). |
| Objective generation | An injured, generic survey worker (never one of the named characters; varied clothes) sits at an unused `WorldDefs.MissionSpots.M03` spot within 3 corridors of the last shelter (R01 survey board, R02 inspection room, R03 old pumps, R04 station hall, R05 west anchor). If none qualifies, nothing is offered. The objective names the room and region, never a route. |
| Deliver | "Give supplies" opens a chooser listing the dressings, bandages and splints you hold. You choose 1–3 items of one kind (`medicalDeliveryMaxItems`); the server checks the mission, your range (10 studs), that you hold that many, then after a 1.5 s hand-over re-checks and removes exactly that many. |
| Nothing to give | The chooser and the objective name the nearest reachable rooms whose scavenging sites hold medical supplies, and mention that a shelter workbench makes dressings and splints. It never opens a store and never mentions Robux. |
| Reward | `10 + 10 × items delivered` coins (TUNE), individual, durable save first. Each participant makes one delivery of their own. |
| Complete | When every online participant has delivered, the worker stands up and walks off toward a neighbouring room on their own (no escort). |
| Party / late join | The party at acceptance shares the objective; a current party member of the owner may join by using the worker's prompt. |
| Death | Does not cancel it. |
| Disconnect / abandon | The leaver drops out; when nobody remains, the worker leaves. |
| Timeout | 25 minutes without a delivery. |
| Cooldown | 180 s per player (`medicalDeliveryCooldownSeconds`, TUNE), starting at your own delivery. |

## M04 Power Restoration (15–35 min, medium risk)

| Phase | Behavior |
| --- | --- |
| Offer | Personal. Offered when you have registered the Reinforced Service Office (S04) and its station supply does not run for you yet (no `station_power` upgrade, no breaker repair recorded), and you have never been paid for it. Otherwise the list explains why. |
| Objective | Bring a repair tool roll (kept) and a fuse kit (crafted from 2 fuse components + 1 fastener at a workbench, or found in the Generator Room locker), then fix the breaker cabinet inside your S04 interior (a private fuse layout built by the shelters package). The objective says whether you carry each part. |
| Complete | When your breaker repair is recorded (`storyStates["M04.S04"]`, set by the shelters package) or the restored supply reaches you through the party upgrade union (F13) while the mission is active: +50 coins once ever (`storyStates["M04.reward"]`). The `station_power` upgrade itself is granted by the shelters package. |
| Party | Personal: each member accepts their own. A party member's repair counts for you only through the ordinary upgrade inheritance. |
| Death | Does not cancel it. |
| Disconnect / abandon | Ends it. A repair made later without the mission active still grants the upgrade but not these coins. |
| Timeout / cooldown | None (one reward per shelter facility). |

## M05 Waterworks Passage (20–45 min, medium risk)

| Phase | Behavior |
| --- | --- |
| Offer | Offered once you have reached the Flooded Works (PROPOSED pacing gate) and the Overflow Vault is reachable from your last shelter. |
| Objective | Reach the Overflow Vault (`R03.overflow_vault`): either set the three sluice wheels in the Silt Works in the clue order (loud: every turn can draw the Wader) or take the long, silent dry route through the Drain Gallery and the Vault Stair. Then open **your own** copy of the sluice-keeper's cache (`MissionSpots.M05`). |
| Cache | One shared cache prop; each participant opens their own copy once per mission: 1 signal flare, 1 bandage, 1 battery housing (expedition loot; overflow to escrow), saved durably. Without an active M05 it explains how to get one. |
| Complete | Reach any shelter (entering it, or respawning inside it) after opening your copy: +25 coins (TUNE), individual. You are then free for another mission; the objective closes when every participant has returned. |
| Party / late join | The party at acceptance shares it; a current party member of the owner may join by opening the cache. |
| Death | Does not cancel it (the cache contents follow the normal death-bag rules). |
| Disconnect / abandon | The leaver drops out; when nobody remains it ends. |
| Timeout | 60 minutes without progress. |
| Cooldown | 300 s per player (`waterworksCooldownSeconds`, TUNE). The per-player cache claim belongs to the mission, so it restocks with the next mission after the cooldown. |

## M07 Creature Observation (10–30 min, medium risk)

| Phase | Behavior |
| --- | --- |
| Objective | Personal. Picks a built creature (Sidelooker, Borrowed Miner, Wick Moth, Chalk Hand, Scrabbler, Wader, Knocker, Lantern Thief) whose research is unfinished and whose home lies within 6 corridors of your last shelter, and shows the hint for the next stage (e.g. "Count the knocks"). Killing is never required. The Sidelooker is capped at stage 3 (D29). |
| Progress | Completes the moment that creature's research stage rises, then asks you to return to any shelter. |
| Reward | +30 coins on reaching a shelter (entering it or respawning inside it). |
| Death | Does not cancel it. |
| Disconnect / abandon | Ends it. Research already gained stays in the journal. |
| Timeout | 25 minutes while observing; never once the observation is recorded. |
| Cooldown | 240 s (TUNE). |

## M09 Shelter Establishment (20–60 min, medium risk)

| Phase | Behavior |
| --- | --- |
| Offer | Personal. Offered when you know a shelter (its exterior room is discovered), it is reachable from your last shelter, none of its safety upgrades has reached stage 1 for you, and you have not been paid for establishing it. The nearest such shelter is chosen. |
| Objective | Enter the shelter to register it, then build stage 1 of any of its safety upgrades inside. The objective updates once you have registered it. Further protection is a separate project. |
| Complete | Registered (`discoveries["shelter:<id>"]`) and any safety upgrade at stage 1 (functional upgrades do not count). +40 coins once per shelter (`storyStates["M09.<shelterId>"]`). An upgrade inherited from your party (F13) counts. |
| Party | Personal: each member accepts their own; building together still helps through the upgrade union. |
| Death | Does not cancel it. |
| Disconnect / abandon | Ends it. |
| Timeout / cooldown | None. |

## M11 Lost Belongings (10–45 min, risk varies)

| Phase | Behavior |
| --- | --- |
| Offer | Personal. Offered when you have a death or departure bag (`RecoveryService.bagsOf`); the death bag is chosen first. This is your own journey, not a paid recovery service. |
| Objective | Names the bag kind, its region and the nearest room label (the bag's stable anchor): an honest location, never a GPS route. |
| Complete | When that bag no longer exists because you recovered it, or a party member moved it into your shelter escrow (that completes it too, without experience: claim the items at any shelter). If items did not fit, the bag stays and so does the objective. |
| Reward | No coins, ever (no incentive to die). Field experience only for recovering it **yourself**: once per bag (`bag:<bagId>`, 5 TUNE) and at most once every 15 minutes (`missionCooldowns["M11.xp"]`), so relogging to make new bags cannot farm it. |
| Failure | A newer bag of the same kind replaced it (only the latest death bag persists, F16): "a newer bag replaced the one you were looking for". |
| Death | Only matters if it replaces the bag this journey is for. |
| Disconnect / abandon | Ends it; the bag itself is untouched. |
| Timeout / cooldown | None for the mission itself; the experience has the 15-minute limit above. |

## Act II story rescue: Noah Perrin (story objective, not on the board)

| Phase | Behavior |
| --- | --- |
| Offer | Not from the board. While any player on the server is at Act II step 2, Noah waits injured in the Silt Works (`Characters.N06.rescuePos`). Using "Help Noah Perrin" starts the rescue for you if you (or a member of your current party) are at that step and you have no other mission. Anyone else hears that he is waiting for someone else. One Noah exists per server; if another group is already helping him, he returns for you once they finish. |
| Rules | Exactly M01's: treat (faster with supplies, never a lock), escort or carry to **any** shelter, same handover, death, disconnect, abandon and 25-minute inactivity rules. Solo-completable. |
| Complete | Every participant gets the story fact `act2.noah_rescued`, `charactersMet.N06 = "rescued"`, a durable save and a director recovery interval. No coins (story experience instead). Noah then stands at the depot for those players. |
| Party / late join | The party shares it; party members who are earlier in the story get the fact recorded for later. |
