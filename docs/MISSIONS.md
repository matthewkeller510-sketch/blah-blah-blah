# Mission behavior

Section 06 requires every template to specify failure, abandonment, disconnect and late-join behavior. Only M01 is built. M02–M12 are PLANNED and must get the same table before implementation.

## M01 Nearby Rescue (5–15 min, low risk)

| Phase | Behavior |
| --- | --- |
| Offer | From the depot mission board (Mara Voss placeholder) or the shelter panel. Shows estimate and risk, never a GPS path. Unavailable during the per-player cooldown (120 s TUNE) or while another mission is active. |
| Objective generation | Picks a spawn from `WorldDefs.RescueSpawns` whose chamber is reachable from the Worker's Alcove on the stable chamber graph (BFS) and not already used. If none qualifies, nothing is offered. |
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
