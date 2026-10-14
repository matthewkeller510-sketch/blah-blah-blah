# Item protection table

Section 15: "A complete item protection table must be reviewed before implementation; do not infer that every purchased consumable is infinite or that every shop-bought item is protected."

**Protected** items stay in the player's inventory on death (owner rule F16) and are never moved into a death bag. **Unprotected** items in the inventory go into the latest death bag, where the owner (or an authorized delegate, into the owner's escrow) can recover them (F16, D02, D03). Logging out is separate: only unbanked expedition loot moves to a logout bag; owned loadout and protected items stay (D09).

The table below is the implemented state (`ItemDefs.protected`). Rows marked **CONFIRMED** follow an owner rule. Rows marked **PROPOSED** are a judgement made to keep the game fair and must be reviewed by the owner before release. A unit test (`tests/specs/m3_contract.luau`) pins the story items.

| Item | Protected | Label | Why |
| --- | --- | --- | --- |
| Coins (not an item) | yes | CONFIRMED (F16) | "Coins and designated protected items survive death." |
| `nav.chalk` Chalk Stick | yes | CONFIRMED (F21) | Unused navigation items survive death equally, earned, found or purchased. |
| `nav.sign` Route Sign | yes | CONFIRMED (F21) | As above. |
| `nav.rope` Rope Coil (segment) | yes | CONFIRMED (F21) | As above. |
| `treasure.old_expedition_tag` | yes | PROPOSED (D21) | Act I story item. A replaced death bag must never lock the story. |
| `evidence.waterworks_log` | yes | PROPOSED (D41) | Act II story item, same reason. |
| `evidence.station_tape` | yes | PROPOSED (D41) | Act II story item, same reason. |
| `light.pocket_torch` | no | PROPOSED | Equipment is the stake of a death (F16 "death leaves recoverable loot"); it is recoverable from the bag. |
| `light.expedition_flashlight` | no | PROPOSED | As above. |
| `light.compact_headlamp` | no | PROPOSED | As above. |
| `light.shielded_lantern` | no | PROPOSED | As above. |
| `power.cell` | no | PROPOSED | Consumable supply; dwindling supplies are the core fear (section 01). |
| `med.cloth_dressing`, `med.bandage`, `med.splint` | no | PROPOSED | Consumable supplies. |
| `tool.stun_device` | no | PROPOSED | Equipment; charges already spent stay spent (section 15). |
| `tool.iron_bar` | no | PROPOSED | Equipment. |
| `tool.flare` | no | PROPOSED | Consumable. A purchased flare is not protected: only navigation packs are the intended paid product (section 21). |
| `tool.repair_roll` | no | PROPOSED | Reusable tool, but still equipment at stake. |
| `tool.fuse_kit` | no | PROPOSED | Consumable component. |
| `mat.*` (fabric, fastener, plank, bracket, chalk fragment, fuse component, battery housing) | no | PROPOSED | Crafting materials. |
| `treasure.survey_tag` | no | PROPOSED | A unique find, but not required by the story; it can be recovered from the bag. |
| `treasure.brass_rule`, `treasure.lead_seal`, `treasure.field_photograph`, `treasure.dated_battery` | no | PROPOSED | Sellable treasure: the reward for getting home. |

## Rules that follow from the table

- **Paid items.** The only intended developer products are navigation packs (section 21). Their units are the same `nav.*` items as earned ones and get exactly the same protection. No other shop item becomes protected by being bought.
- **Placed navigation items** are not in the inventory. They persist as world records until retrieved (F09) and are never deleted by death, logout, a pocket change (they migrate, D31) or a placement limit (D15). Picking one up restores only that unit.
- **Planned items.** The anchor stake and the survey compass (section 09 navigation family) are not built. When they are, the proposed default is **protected** for the anchor stake (a navigation consumable, in the spirit of F21) and **protected** for the survey compass (a reusable navigation tool that should never strand a player). The owner should confirm both.
- **Story items** stay protected so no story step can be lost to a replaced death bag.
