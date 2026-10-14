# Economy and progression sheet (Milestone 1)

All numbers are **TUNE** starting points. Coins are earned only; Robux is never required (sections 20–21).

## Sources of coins

| Source | Amount | Limit |
| --- | --- | --- |
| M01 Nearby Rescue | 40 | 120 s cooldown per player |
| M02 Missing Survey Cache | 20 + 1 cell, 1 dressing, 1 fastener | 180 s cooldown |
| M07 Creature Observation | 30 | 240 s cooldown; needs a new research stage |
| Act I completion | 60 | Once |
| Sell Lead Seal | 18 | Long Ossuary niche (20 min restock) |
| Sell Brass Measuring Rule | 12 | Found in the pulley case (20 min per-player restock) |
| Unique items (Survey Tag) | not sellable | One claim per player |

## Sinks (quartermaster placeholder, depot)

| Item | Price | Organic source |
| --- | --- | --- |
| Replaceable Cell | 15 | Survey-board crate, east shelf |
| Cloth Dressing | 6 | Survey-board crate; crafting (2 fabric + 1 fastener) |
| Proper Bandage | 14 | Pulley case |
| Chalk Stick | 2 | Crafting (3 chalk fragments, from the pier sack) |
| Route Sign | 6 | Lantern Crypt box (R02) |
| Rope segment | 4 | Plaque Hall satchel (R02), sluice bundle (R03) |
| Expedition Flashlight | 120 | Inspection Office locker (R02, needs light, 60 min restock) |
| Limited Stun Device (3 charges) | 90 | Sealed Chapel chest (R02, behind P01, 60 min restock) |
| Compact Headlamp | not sold | Silt Works crate (R03, needs light, 60 min restock) |
| Class change | 150 | — |

## Shelter (Worker's Alcove) upgrades

| Upgrade | Kind | Stage costs |
| --- | --- | --- |
| Gate repair | Safety | 1: 2 planks · 2: 2 planks + 2 brackets |
| Crack boarding | Safety | 1: 3 planks + 1 bracket |
| Workbench | Functional | 1: 2 planks + 2 fasteners |
| Better lighting | Functional | 1: 1 cell + 1 fastener |

Full security needs gate repair stage 2 **and** crack boarding stage 1: 7 planks, 3 brackets. Planks come from the rubble pile and the east shelf, brackets from the slope toolbox and the east shelf. That is roughly 2–3 expeditions solo, faster in a party. Functional upgrades never create free consumables.

## Developer products

None configured. The intended products are navigation packs only (chalk, signs, rope). Paid units are identical to earned ones and follow the same protection rule. Prices must come from `MarketplaceService:GetProductInfo`.

## Inspection Office (S02) and Raised Pump Platform (S03)

| Shelter | Upgrade | Kind | Stage costs |
| --- | --- | --- | --- |
| S02 | Door reinforcement | Safety | 1: 2 planks · 2: 2 brackets + 1 fastener |
| S02 | Vent grille | Safety | 1: 2 brackets |
| S02 | Workbench | Functional | 1: 2 planks + 2 fasteners |
| S02 | Supply shelves | Functional | 1: 3 planks (storage look only; no free items) |
| S03 | Hatch bolts | Safety | 1: 1 bracket · 2: 2 brackets + 1 fastener |
| S03 | Pipe plug | Safety | 1: 2 planks + 2 fasteners |
| S03 | Workbench | Functional | 1: 2 planks + 2 fasteners |
| S03 | Better lighting | Functional | 1: 1 cell + 1 fastener |

Securing S02 needs 2 planks, 4 brackets and 1 fastener. Securing S03 needs 2 planks, 3 brackets and 3 fasteners. Brackets and fasteners come from the R03 pump toolbag and the R01 toolbox/shelf.

## Milestone 3 additions

All numbers are **TUNE**; coins are earned only. Sources below are organic (F20); the shop is a convenience.

### New coin sources

| Source | Amount | Limit |
| --- | --- | --- |
| M03 Medical Delivery | 10 + 10 per item delivered (1–3) | 180 s cooldown; the items are consumed, so buying dressings to deliver nets less than M01 per minute |
| M04 Power Restoration | 50 | Once per shelter facility (S04 today) |
| M05 Waterworks Passage | 25 at a shelter + your own cache (1 flare, 1 bandage, 1 battery housing) | 300 s cooldown from the cache claim |
| M09 Shelter Establishment | 40 | Once per shelter (up to 5 today) |
| M11 Lost Belongings | 0 (experience only) | Never pays to die (D45) |
| Act II completion | 80 | Once |
| Noah's story rescue | 0 (story experience only) | Once |
| Sell Field Photograph / Mis-dated Battery | 15 / 8 | Map-room drawer (30 min), hall desk and anchor cache (15–20 min), per player |

### Quartermaster (Ines Vidal, depot) additions

| Item | Price | Organic source |
| --- | --- | --- |
| Shielded Lantern | 140 | Battery Store shelf (R04, needs light, 60 min restock) |
| Signal Flare | 10 | Station hall desk (R04), Overflow Vault cache (R03), M05 cache |
| Field Splint | 12 | Station medical shelves (R04); crafting (1 plank + 1 fabric) |
| Replacement Fuse Kit | 9 | Generator locker (R04); crafting (2 fuse components + 1 fastener) |
| Repair Tool Roll | 30 | Battery Store shelf, generator locker (R04) |

Fuse components come from the hall desk, the radio bench and the Overflow Vault cache; battery housings from the Battery Store shelf and the radio bench. A replaceable cell can also be crafted (1 battery housing + 1 fastener). None of the new recipes needs a workbench.

### Consumption

| Use | Cost |
| --- | --- |
| P03 station power (public) | 1 fuse kit per power-up; the repair roll is kept; a wrong box returns the fuse |
| M04 breaker (private) | 1 fuse kit once; the repair roll is kept |
| Lantern | 0.7 charge/s whether open or shielded |
| Flares | 1 per flare; at most two lit per player |

### Shelter upgrades (S04, S05)

| Shelter | Upgrade | Kind | Stage costs |
| --- | --- | --- | --- |
| S04 | Door bars | Safety | 1: 2 brackets · 2: 2 planks + 2 fasteners |
| S04 | Duct cover | Safety | 1: 1 bracket + 2 fasteners |
| S04 | Workbench | Functional | 1: 2 planks + 2 fasteners |
| S04 | Station power | Functional, grant-only | Repair the breaker cabinet (1 fuse kit, repair roll kept) — M04 |
| S05 | Arch brace | Safety | 1: 2 planks · 2: 2 brackets + 1 fastener |
| S05 | Fissure fill | Safety | 1: 3 planks + 1 fastener |
| S05 | Workbench | Functional | 1: 2 planks + 2 fasteners |
| S05 | Better lighting | Functional | 1: 1 cell + 1 fastener |

Securing S04 needs 2 planks, 3 brackets and 4 fasteners; S05 needs 5 planks, 2 brackets and 2 fasteners.

### Field experience (D37)

Not a currency: it only raises max stamina and max health with diminishing returns (never above +15 each). Sources: first place discovery 5, shelter registration 20, research stage 10, story step 25, mission completion 10, own bag recovered 5. Rank `floor(sqrt(xp / 50))`.
