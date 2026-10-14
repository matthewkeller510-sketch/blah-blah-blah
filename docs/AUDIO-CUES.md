# Audio cue list

Section 17 asks for a cue spreadsheet before final sound production. **No sound assets are bound yet.** Every cue below is delivered today as a caption with a rough direction (ahead, behind, left, right; close, near, far). Essential cues also get a brief screen-edge pulse, unless "Reduce flashes" is on. Captions for essential cues show even with subtitles off, so counterplay survives muted audio.

| Cue ID | Source | Essential | Caption | Intended sound (to produce) | Gameplay meaning |
| --- | --- | --- | --- | --- | --- |
| `sidelooker_scrape` | C01 | no | [a faint scrape of stone] | Single dry scrape, slightly off-axis | Harmless observer nearby |
| `sidelooker_retreat` | C01 | no | [something slips out of sight] | Soft cloth/stone slide | It retreats when watched |
| `scrabbler_idle` | C05 | no | [claws shifting rubble] | Low rubble shuffle | Predator resting near home |
| `scrabbler_windup` | C05 | **yes** | [SCRAPING CLAWS — something is about to rush] | Accelerating claw scrape, 1.1 s | Break line of sight now |
| `scrabbler_hit` | C05 | yes | [claws strike] | Impact + cloth tear | You were hit |
| `scrabbler_hurt` | C05 | no | [a shrill hiss] | Hiss | Your strike landed |
| `knocker_knock` | C07 | **yes** | [KNOCK n of 3] | Three identical heavy knocks, 0.7 s apart | Leave the straight corridor before the third |
| `knocker_impact` | C07 | yes | [a heavy impact against stone] | Thud at the corridor end | Charge finished; brief recovery window |
| `knocker_stunned` | C07 | yes | [the knocking stops abruptly] | Knock cut off mid-sequence | Stun worked |
| `weapon_ineffective` | any unkillable | **yes** | [metal glances off without effect] | Dull clank, no flesh | This creature cannot be hurt like this |
| `shelter_probe` | shelter | **yes** | [scratching at an unprotected entrance] | Scratching behind boards | Step away from that entrance; fortify it |
| `stun_fired` | tool | no | [stun device discharges] | Electrical snap | |
| `breathing` | player | no | [heavy breathing] | Personal breathing loop | Exhausted: sprint unavailable |
| `wader_ripple` | C06 | no | [ripples spreading across the water] | Slow ripple lap | It is in the water nearby |
| `wader_drag` | C06 | **yes** | [A DRAGGING STEP IN THE WATER — it heard you. Stop splashing.] | Heavy dragging step through water | Crouch, get onto stones or dry floor, or hide |
| `wader_strike` | C06 | yes | [long arms strike from the water] | Splash + strike | You were hit while in water |
| `wader_lost` | C06 | yes | [the dragging steps wander away] | Receding steps | Silence worked |
| `wader_repelled` | C06 | yes | [it recoils and wades off] | Recoil splash | Stun worked; it will return |
| `stone_splash` / `stone_clatter` | player | no | [a stone splashes] / [a stone clatters on rock] | Pebble in water / on stone | A distraction you threw |
| `plaque_turn` | P01 | no | [stone grinds as the plaque turns] / [the plaque locks into place with a deep click] | Stone grind; heavy click on success | Puzzle feedback |
| `gate_open` | P01 | yes | [a heavy gate grinds open] | Gate grind | The chapel is open |
| `valve_turn` | P02 | no | [the valve squeals; the gauge settles — n of 3 set right] | Valve squeal + pipe gurgle, pitch rises with n | Puzzle feedback (also shown on the gauge) |
| `valve_reset` | P02 | no | [all valves clank shut] | Three clanks | Reset |
| `water_drain` / `water_rising` | P02 | yes | [a deep gurgle — the cistern is draining] / [water rushes back into the cistern] | Drain gurgle / inrush | Cistern state changed |

Region ambience still to produce: R00 rain, traffic and courtyard reverb, extinguished during the descent; R01 dry air tone, distant drips, limestone footsteps. Use distance and occlusion coherently, and avoid constant stingers (section 17).

Region ambience still to produce for R02 (dry stillness, distant settling bone, muffled steps) and R03 (constant drip, pump groans, slow water lap).

## Milestone 3 cues

Same rules: every cue below is delivered today as a caption (`src/shared/Data/CueDefs.luau`); essential ones also pulse the screen edge unless "Reduce flashes" is on, and show even with subtitles off.

| Cue ID | Source | Essential | Caption | Intended sound (to produce) | Gameplay meaning |
| --- | --- | --- | --- | --- | --- |
| `pocket_shift` | R05 pockets | **yes** | [SURVEY CLICKS AND FALLING DUST — the passage ahead is about to change] | Measured survey clicks, trickling grit, low stone groan | A pocket will change when it is empty; stay out to let it, or step in to stop it |
| `pocket_settled` | R05 pockets | **yes** | [the clicking stops — the passage is different now] | Clicks stop; a settling thud | The pocket has a new version; your moved markers are at the anchor |
| `anchor_verified` | P06 | **yes** | [a survey lamp steadies — this door is the stable route] | Soft relay click, steady hum | You found the stable door |
| `miner_rhythm` | C02 | no | [tok… tok… tok — pick strokes in an exact rhythm] | Pick on limestone, exactly 1.5 s apart, no variation | A mimic: real work is never this regular |
| `miner_fade` | C02 | no | [the working figure is simply gone] | Air pressure drop, no footsteps | It failed verification or reached its dead end |
| `moth_flutter` | C03 | **yes** | [dry wings flutter around your light] | Papery wing flutter, dust | A swarm will cloud your beam |
| `moth_disperse` | C03 | no | [the moths scatter] | Flutter receding | Beam restored |
| `chalkhand_scratch` | C04 | no | [a thin scratching inside a crack] | Chalk on stone from inside a wall | A false mark may have appeared nearby |
| `thief_rattle` | C08 | **yes** | [A FAINT RATTLE OF GLASS — something is drawn to your light] | Lamp glass rattling on wire, directional | The Lantern Thief is near; light a flare or break its sight |
| `thief_strike` | C08 | **yes** | [glass and cold fingers — your light is snuffed] | Glass clink, wick snuff, impact | You were hit and your light switched off (charge kept) |
| `thief_decoyed` | C08 | **yes** | [the rattle turns toward the flare] | Rattle moving away | The flare is drawing it |
| `thief_lost` | C08 | **yes** | [the rattle fades away] | Rattle receding | Breaking sight worked |
| `thief_repelled` | C08 | **yes** | [it recoils, its lights swinging] | Glass swinging, retreat | The stun worked; it will return |
| `fuse_spark` | P03 / M04 | **yes** | [a fuse sparks and pops out — wrong box] | Spark, pop, fuse rattle | Wrong box: time lost, fuse returned |
| `power_restored` | P03 | **yes** | [the generator coughs, then hums — the station lights come on] | Generator start, lamp buzz | Station power on |
| `power_tripped` | P03 | **yes** | [a relay clacks — the station lights die] | Relay clack, hum dies | Power is off again |
| `pulley_creak` | P04 | no | [the pulley creaks as the counterweight settles] | Rope and wheel creak | Puzzle feedback |
| `grate_rise` / `grate_drop` | P04 | **yes** | [a grate grinds upward] / [a grate slams down] | Iron grate scrape / slam | The Pulley Store is open / closed |
| `radio_tone` | P05 | no | [a radio tone] | Short or long sine tone through static | One element of the pattern (also shown as • and —) |
| `radio_wrong` | P05 | **yes** | [the tone slides back into static] | Detune into static | Try again |
| `radio_locked` | P05 | **yes** | [the static clears — the frequency holds] | Static clears to a carrier hum | Solved |
| `sluice_gate` | W05 | **yes** | [a sluice wheel groans — water surges loudly] (with n of 3) | Wheel groan, rushing water | Correct so far; it is loud and can draw the Wader |
| `sluice_reset` | W05 | **yes** | [the wheels spin back — wrong order] | Wheels spinning back | Start again |
| `sluice_open` / `sluice_flood` | W05 | **yes** | [the flooded passage drains with a roar] / [water pours back into the overflow passage] | Drain roar / inrush | Overflow Vault corridor open / closed |
| `flare_lit` / `flare_out` | tool | no | [a flare hisses alight] / [the flare sputters out] | Strike and hiss / sputter | Decoy light on / off |
| `lantern_shield` | tool | no | [the lantern shutters click] | Metal shutter click | Lantern shielded or opened |

Region ambience still to produce: R04 (dead fluorescent tick, distant generator when powered, paper settling, radio static) and R05 (a measured, slightly wrong echo; distant survey clicks even when nothing is shifting).
