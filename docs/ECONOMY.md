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
