# Mission behavior

Section 06 requires every template to specify failure, abandonment, disconnect and late-join behavior. M01, M02 and M07 are built. The others are PLANNED and must get the same table before implementation.

All built missions are offered from Mara Voss's depot board or a shelter panel, only where the objective is reachable within 3 corridors of the player's last shelter (closed puzzle gates count as walls).

## M01 Nearby Rescue (5–15 min, low risk)

| Phase | Behavior |
| --- | --- |
| Offer | Shows estimate and risk, never a GPS path. Unavailable during the per-player cooldown (120 s TUNE) or while another mission is active. |
| Objective generation | Picks an unused spawn from `WorldDefs.RescueSpawns` (R01, R02, R03) near the last shelter. If none qualifies, nothing is offered. |
| Cue | A readable environmental cue at the spawn: dropped lamp (dim light), rope end, or chalk scrawl "AIDE ↓". The objective text names the area and the cue type. |
| Treat | Hold interaction. With a bandage or dressing: 4 s and consumes one. Without supplies: 9 s, and the player is told it is slower. Never a lock. Medic class 5% faster. |
| Move | **Escort**: the survivor follows the player with pathfinding. **Carry**: welded to the player, carry speed multiplier 0.6, cannot sprint. Dropping returns the survivor to "ready". |
| Complete | Carry the survivor into the shelter, or enter the shelter with the escorted survivor within 18 studs. Each participant gets 40 coins individually, the cooldown, a durable save, and a director recovery interval. |
| Party | The party at acceptance shares the objective. A current party member of the owner who interacts later joins it (late join). Rewards are per participant. |
| Death | The dead player leaves the mission. If others remain, ownership transfers and a carried or escorting survivor becomes "ready" where they are. If nobody remains, the mission fails: "The survivor was found by another team." |
| Disconnect / logout | Same as death (handover or fail). Nothing about the mission is persisted; the survivor is not owed. |
| Abandon | The "Abandon current" button in the mission list behaves like leaving. |
| Timeout | If nobody reaches the survivor within 25 minutes, the mission fails with "timed out". |
| Story | M01 completions are counted in `storyStates["M01.completions"]`. Repeating never resets story state. |

## M02 Missing Survey Cache (10–25 min, low risk)

| Phase | Behavior |
| --- | --- |
| Objective | An instrument case appears at an unused `WorldDefs.CacheSpots` spot near the last shelter. The text describes the landmark ("under the wheel that no longer turns") and names the region, never the exact room. |
| Collect | Hold to open **your own copy**: +20 coins, 1 cell, 1 cloth dressing, 1 fastener (expedition loot; overflow goes to escrow) and a short lore fragment. Each participant opens their own; one player's copy never consumes another's. |
| Party / late join | The party at acceptance shares the objective. A current party member of the owner may join by opening the case. |
| End | The case is removed once every online participant has their copy, or after 25 minutes. |
| Death | Does not cancel it: come back after respawning. |
| Disconnect | The leaver drops out. If nobody remains, it ends. |
| Cooldown | 180 s per player (TUNE). |

## M07 Creature Observation (10–30 min, medium risk)

| Phase | Behavior |
| --- | --- |
| Objective | Personal. Picks a built creature (Sidelooker, Scrabbler, Wader, Knocker) whose research is unfinished and shows the hint for the next stage (e.g. "Count the knocks"). Killing is never required. |
| Progress | Completes the moment that creature's research stage rises, then asks you to return to any shelter. |
| Reward | +30 coins on reaching a shelter. |
| Death | Does not cancel it. |
| Disconnect / abandon | Ends it. Research already gained stays in the journal. |
| Cooldown | 240 s (TUNE). |
