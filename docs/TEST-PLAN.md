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


## Milestone 3 (docs/MILESTONE-3.md)

Lower `Config.Pockets.cycleSeconds` in a test place to see pocket changes quickly. Use two accounts for party rows.

| # | Scenario (spec ref) | Steps | Expected |
| --- | --- | --- | --- |
| 28 | Survey station and crossroads build | Walk Sluice → Station Hall, every R04 room, Map Room → R05 anchors | Region folders populated; three doors on the Room of Three Doors' north wall; S04 and S05 doors work; slopes have no gaps |
| 29 | Pocket telegraph (F08) | Stand in the Measured Crossing more than 6 studs from a mouth | `pocket_shift` captions at both mouths, plates glow, dust (no flicker with Reduce flashes); after 20 s the passage changes and `pocket_settled` shows |
| 30 | Pocket abort and blockers | Walk in during a telegraph; or stand, lie downed, hide, be carried inside; or leave your rope or death bag inside while online; or light a flare inside and step out | The change aborts or never starts (a flare delays it until it burns out); nothing rebuilds under anyone |
| 31 | Every pocket version passable | Force each version of PK1–PK3 and walk mouth to mouth, also carrying a teammate | Passable standing; the low gallery needs no crouch |
| 32 | P06 impossible doorway | Watch from the observation step for 12 s with two clients; walk through the ● door | False-door lamps pulse in sync for both, the ● lamp is steady; ● reaches the junction; `anchor_verified` and a notebook line; false doors loop back |
| 33 | Marker migration online (T18) | Place chalk in PK1, step out, wait for a change | Notice names the South Survey Anchor; the mark lies there labelled "moved"; notebook lists it |
| 34 | Marker and bag migration offline (T17, T18) | Place chalk, sign, rope in PK2 and die in PK1; log out; rejoin after a change (also on another server) | Records and bag at the anchor chamber, never under the floor; one notice; rope coiled; units recoverable |
| 35 | Dry route and scavenging remainder | Walk Silt Works → Drain Gallery → Vault Stair → Overflow Vault; search a site with a full stack, then partial room | No splash noise on the route; "No room" without a cooldown; partial grant leaves the rest for you |
| 36 | Borrowed Miner (C02) | Listen in the Station Hall without looking; then look at it; then ping near it | Rhythm captions every ~4.5 s; it walks to the Collapsed Adit and fades; a ping makes it fade at once; it never answers a ping |
| 37 | Wick Moth (C03) | Torch on in the Battery Store; then light off 3 s / shield a lantern / light a flare / walk out | Flutter caption, flecks around your light and a shorter beam, no extra drain; each counter disperses it |
| 38 | Chalk Hand (C04) | Place chalk in R05 and wait nearby; inspect the fake; compare | Scratch caption, a reversed arrow beside your mark; "not in your notebook"; compare confirms with your own mark; nothing new in your marker list |
| 39 | Lantern Thief before the note (C08, D47) | Lit torch in R04 without reading Elise's note | Rattle captions with direction; it can be sighted; it never strikes |
| 40 | Lantern Thief after the note | Read the note, run low on supplies, walk lit | Essential rattle, approach from outside view; strike: −20 health, light off, charge unchanged; flare diverts it; breaking sight 4 s loses it; stun repels; the bar is ineffective |
| 41 | Never two damaging threats | Thief and a Scrabbler near one player | Never both damaging the same victim at once |
| 42 | P03 fuse bridge | Try with no roll/fuse; fit the wrong box; trace and fit the right one; leave after 20 min | Notice names organic sources; wrong box costs time and returns the fuse; R04 lamps on, `power_restored`; trips only once the room is empty |
| 43 | P04 weight and pulley | Load three stones, latch, cross, release; stand under the grate when it should drop; pull the inner lever; try the lever alone, then with a party member | Grate rises and stays latched; never drops on anyone; inner lever always opens; the lever alone is refused (stones and latch instead) and a lever raise cannot be latched |
| 44 | P05 echo sequence | With sound off, tune the radio and enter the pattern; then restore power and tune again; watch the radio lamp with and without Reduce flashes | Pattern readable as • and —; the lamp blinks the same rhythm (amber unpowered, green powered; a gentle dip with Reduce flashes); `radio_locked`; without power, "no power"; with power, Elise's log plays and the station tape is granted once |
| 45 | W05 sluice gates and M05 | Read both plates, turn wheels in the wrong then right order; take the cache; return to a shelter | "n of 3", wrong order resets; each turn can draw the Wader; corridor drains; own cache copy; +25 at a shelter |
| 46 | S04 / S05 and M04 | Register both; in S04 fix the breaker (wrong then right) | Family looks; +20 experience once each; wrong breaker costs time; lights on, station power granted, +50 once; panel shows why station power cannot be bought |
| 47 | Upgrade inheritance (T10) | Repair the breaker, then a newcomer joins the party and leaves | Newcomer keeps station power permanently; no inventory changes |
| 48 | Depot characters | Walk the depot | Mara, Moreau, Ines, Amadou visible with Talk prompts; Noah hidden for a new account; rays and markers pass through them |
| 49 | Act II spine (sec 05) | Finish Act I; talk to Moreau; rescue Noah; take the waterworks log; register S04; power + radio; compare at the map table; report to Mara | Each step advances in order with journal lines; +80 coins once at the end; works solo |
| 50 | Elise's note | Read it in a party | Text panel; partner gains the discovery and the text; the thief's strike gate opens for both |
| 51 | M03 Medical Delivery | Accept with nothing, then with two bandages | Text names rooms with supplies (never a store); +30 coins; the worker walks off |
| 52 | M09 and M11 | Establish a shelter; die, accept M11, recover the bag; repeat within 15 minutes; let a party member recover it to escrow | +40 once; M11 pays experience only for your own recovery, at most once per 15 minutes; escrow recovery completes it without experience; it fails if a newer bag replaces it |
| 53 | Lantern and flares | Equip the lantern, toggle shield (V); place flares (N) three times; try in a shelter | Omni light seen by others; range 9 shielded; two flares land, the third is refused; refused in shelters and at the depot |
| 54 | Injury and splint | Take an injuring hit, sprint, then apply a splint | Sprint about 14.5, walk 11; HUD injury line; splint clears it |
| 55 | Field experience (F24, T23) | Explore past 50 experience; rejoin an older profile | Rank-up notice, max health and stamina +2, no free heal; one back-fill notice for older profiles and no second payment on rejoin |
| 56 | Touch and gamepad | Phone landscape (390 px tall) and tablet; gamepad | Action row along the bottom ends beside the jump button, 52 px slots; consumable column on the left clear of where the thumb starts the stick; party list top right; Sprint never sticks; shoulder and D-pad bindings work |
| 57 | Notebook after rejoin | Rejoin | Discoveries and research listed, sorted, with no notice burst |
| 58 | Schema 3 rollout | Join a schema-3 profile on an older (schema-1 or schema-2) server, then a new one | The older server refuses with a clear message and releases the lock; the new server loads at once |
| 59 | Ray-blocking barriers | Aim a chalk mark into the flooded W05 corridor and at the closed P04 grate | The mark lands on the floor or wall, never on an invisible mid-air plane |
| 60 | Overlapping pocket volumes | Walk PK1's loop version near its east side chamber | Only the PK1 passage is discovered, never PK2 |
| 61 | No heal on rejoin (F18) | Drop to low health in a tunnel and rejoin; get downed and leave; rejoin | Same health as before leaving, no heal; back injured at 15 health after leaving while downed |
| 62 | Mouse cursor in first person (PC) | Open every screen: inventory, notebook, shelter, missions, shop, onboarding, dialogue, radio, M03 chooser, Chalk Hand popup | The cursor is free while each is open and every button can be clicked; it locks again when the screen closes |
| 63 | Screens close in danger | Open a panel, the radio or dialogue, then trigger a chase cue or get downed | They close; captions stay visible above everything |
| 64 | Dialogue at large text | Text size 1.6 on a 390-px phone; talk to every character | Lines page instead of being cut off; buttons stay 52 px |
| 65 | Creatures through pockets | Force each pocket version; lead the Lantern Thief through PK1, PK2 and PK3; watch a creature turn corners in R01 and R04 | It follows the open passage (never through walls or the low ceiling), takes a bypass when a pocket is closed to it, and turns at chamber centres; the pocket never changes while it is inside |
| 66 | Knocker research and tools | Watch the Knocker; swing the bar and fire the stun through a wall | "Seen" is recorded; tools do nothing through walls and prefer a threat over a moth roost |
| 67 | Shelter exits and arrivals | Try to leave while carrying or being carried; arrive or respawn in an unsecured shelter during a probe | Leaving is refused until the teammate is set down; arrivals are never hit by the probe |
| 68 | Death costs its loot (F16) | Die next to loot, then try to recover your own new bag before respawning; recover it after respawning | Refused while dead; works after walking back |
| 69 | Death inside a shelter | Die inside an interior (e.g. a probe at an open entrance) | The bag is just outside that shelter's door; the notice says so |
| 70 | Abandon while carrying | Carry a survivor, then abandon the mission (solo and in a party) | The survivor is set down first; you can sprint, hide and use tools; nobody is welded to anyone |
| 71 | Prompt keys | On keyboard and gamepad, use the Carry (J) and lever (U / gamepad Y) prompts and the escort prompt | Each prompt fires without also toggling the light or another action (Y lights nothing while the lever prompt shows); note any gamepad clash |
| 72 | Marker pacing | Four players in a party place markers quickly | Lists update within a few seconds; leaving the party hides markers at once |
| 73 | Pushed dialogue on PC | A party member reads Elise's note while you look around; rescue Noah with a friend | The shared text appears but mouse-look keeps working; Enter advances, Backspace closes |
| 74 | Stalking rattle | Open the notebook while the Lantern Thief only stalks nearby | The rattle is captioned but the notebook stays open; it closes when the thief starts its approach |
| 75 | Revive inside a shelter | Get downed by a probe inside an unsecured shelter; a party member stabilizes you | You are back on your feet at low health, injured |
| 76 | HUD redesign (D108–D111) | Phone (390 px tall), small phone, tablet and PC | No status panel. Health top left; consumable icons stacked on the left with counts (empty ones faded, Sign and Rope only while carried); battery bottom right with off/low/shut/moths words; action slots along the very bottom beside the jump button; Crouch and Light very small on the right and still easy to hit; no coloured pulse around the screen on creature cues (captions still appear); icons look right (frames, rotation, rings); nothing overlaps at text size 1.0 |
