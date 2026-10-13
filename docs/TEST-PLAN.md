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
