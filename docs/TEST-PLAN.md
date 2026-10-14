# Studio and device test plan (Milestone 1)

Run these in a **private published test experience** with API services enabled. Record each run in the ledger: place ID, build commit, device, graphics setting, player count, steps, observed result. Studio device emulation checks layout only.

| # | Scenario (spec ref) | Steps | Expected |
| --- | --- | --- | --- |
| 1 | First spawn (T01) | Join with a new account | Spawn in the depot courtyard. HUD shows Steady 100/100 and the pocket torch at 60%. Save status reads "Profile loaded". |
| 2 | Descent and discovery | Walk down the ramp into the quarry | Discovery toasts for The Descent, then Survey Board. Ambient light is faint, not black. |
| 3 | No light (T02) | Turn the light off and walk to the survey-board crate | Walls and floor legible at close range. Crate searchable without light. Slope toolbox refuses: "Too dark…". |
| 4 | Stamina (T03) | Hold sprint in a corridor until empty | Sprint stops, walking continues at walk speed, "Exhausted" caption. Sprint returns after recovering to ~35%. |
| 5 | Shelter registration and banking | Pick up loot, then enter the Worker's Alcove gate | Teleported into the private interior. "Banked N item(s). Saved." Inventory shows no unbanked items. |
| 6 | Half-health cap (T13) | Take damage to <50, rest inside the shelter | Health rises to 50 and stops. A bandage takes it above 50. |
| 7 | Fortification (T12) | Build gate repair ×2 and crack boarding with scavenged planks and brackets | Panel reads SECURED. Probe events stop; no damage inside. |
| 8 | Death bag (T15) | Die to the Scrabbler, recover the bag, die again elsewhere | One death bag at a time; the second replaces the first. Chalk count unchanged. Coins kept. |
| 9 | Logout bag (T16, T17) | Gather loot, leave the game in a tunnel, rejoin (also after a server shutdown) | Rejoin inside the shelter. A departure bag holds exactly the unbanked loot. Recovering it gives no duplicates. |
| 10 | Scrabbler (T04, T05) | Sprint across the rubble room | Captioned wind-up before the rush. Breaking line of sight escapes. Iron bar kills it in 3 hits. It respawns later with no loot. |
| 11 | Knocker (T05) | Walk the long pier→pulley corridor | Three captioned knocks, then a charge. Stepping into a chamber dodges. Iron bar says "cannot be hurt". Stun during the knocks interrupts it. |
| 12 | Party (T08–T11, T18) | Two accounts: invite/accept, explore, place chalk, discover a room, collect the survey tag | Both get the discovery. Each must collect their own tag. Each sees the other's chalk. After leaving the party the chalk disappears for the other. Interiors differ per group. |
| 13 | Upgrade inheritance (T10) | A has a secured alcove; B (none) joins A's party, then leaves; repeat join/leave | B keeps the secured state permanently. Inventories and coins unchanged by joins. |
| 14 | Downed rescue | Get downed in a party; teammate presses Help twice | Bleed-out timer pauses after stabilize. Carrying into the shelter revives. Dissolving the party mid-carry detaches both safely. |
| 15 | M01 rescue | Accept at the board, follow the cue, treat with and without supplies, escort and carry | Completes at the shelter with an individual +40 coins. Failure/handover follows `docs/MISSIONS.md`. |
| 16 | Concurrent session (T20) | Join the same account on two servers | The second waits, then is refused while the first holds the lock. No inventory overwrite. |
| 17 | Touch layout (T21) | Phone and tablet, landscape | Action buttons ≥48 px, clear of the thumbstick and jump. Text readable. Safe areas respected. |
| 18 | Performance (T22) | Baseline phone: rubble room chase, shelter transition, 16 players | Record median frame time and the bad-frame percentile. Target 30 fps phone, 60 fps PC (TUNE). |
| 19 | First join (D22) | Join with a fresh account | The briefing and class choice appear; choosing closes them. They do not reappear on rejoin. |
| 20 | Act I chain | Follow the story objective at the top of the screen | Each step advances on its own. Returning the old tag to the depot board completes Act I (+60 coins). The notebook shows the journal. |
| 21 | Descent to R02/R03 | Walk north from the Rubble Workings, then from the Long Ossuary | Sloped galleries reach each level with no gaps at either end. Discovery toasts appear. Creatures and bags work at every level. |
| 22 | P01 (T06) | Read the carving by the south door, turn the plaque until it matches | The gate rises after the match and the plaque locks. The chapel holds the story tag (your own copy) and a chest. |
| 23 | P02 (T06) | Read the clue plate, set the valves | The gauge and caption show n of 3 after each turn. On 3/3 the cistern drains and the barrier opens. Leave; after ~10 minutes with nobody inside it refloods. |
| 24 | Wader | Walk through the sluice water, then crouch-wade or use the stepping stones | Walking triggers the dragging-step caption and a pursuit. Silence makes it lose you. A thrown stone (B) into water pulls it away. A stun repels it. The iron bar is ineffective. |
| 25 | Hiding | Enter a niche while a Scrabbler is rushing you | It loses you; you cannot move until you step out. Damage or respawn always frees the niche. |
| 26 | New shelters | Register at the Inspection Office and the Pump Platform; die; rejoin | Respawn and login happen at the last registered shelter. Each interior shows its own theme and entrances. |
| 27 | M02 and M07 | Accept each with a friend in your party | M02: each of you opens your own copy of the case. M07: completes when the named creature's research rises, then pays out at a shelter. |

