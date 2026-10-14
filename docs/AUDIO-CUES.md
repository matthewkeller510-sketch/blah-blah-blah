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
