# Decision record

Section 26 of the spec allows proposed defaults to change "without rewriting confirmed owner requirements, but record the decision instead of silently improvising". This file records every proposal adopted in Milestone 1. **None of these are owner decisions.** Each one is open for the owner to confirm or replace.

| ID | Topic | Adopted for Milestone 1 | Status | Where |
| --- | --- | --- | --- | --- |
| D01 | Camera | First person (`CameraMode = LockFirstPerson`), adjustable FOV and sensitivity, optional center marker, reduced camera motion on by default | PROPOSED (sec 03) | `default.project.json`, `Input.luau`, `Settings.luau` |
| D02 | Death vs logout bag coexistence | One latest **death** bag plus one latest **logout** bag per player, replaced independently. Empty contents create no bag. | PROPOSED, **provisional** (sec 15) | `RecoveryBags.luau` |
| D03 | Bag delegation | Owner access is unconditional. Saved authorization = party members present at the loss; the owner can revoke it. While the owner is online and grouped, a delegate must also be in the owner's current party. Delegate recovery goes to the owner's **escrow**. Stranger access is off. | PROPOSED; needs owner confirmation (sec 14) | `RecoveryBags.luau`, `RecoveryService.luau` |
| D04 | Where passive recovery happens | Only inside shelters, after a 5 s safe delay, capped at 50% of max health. The 50% cap itself is **CONFIRMED** (F18); the shelter-only location is not. | PROPOSED (sec 08) | `Config.Health`, `Vitals.luau` |
| D05 | Server / party size | 16 players per server, parties up to 6. Unverified capacity. | TUNE (sec 03) | `Config.Server` |
| D06 | Class change cost | 150 **earned** coins, at a shelter. Never Robux. | PROPOSED (sec 09, 26) | `Config.ClassChangeCoinCost`, `ShelterService.changeClass` |
| D07 | Starting kit | One-time new-profile kit: pocket torch (60% charge), 1 cloth dressing, 10 chalk. Not re-granted to existing profiles. There is no recurring free handout (sec 08). | PROPOSED | `Profile.default` |
| D08 | Unkillable creature for the slice | **C07 Knocker** (dry quarry corridor) rather than C06 Wader. Wader belongs to R03 Flooded Works, which is not built yet. | PROPOSED | `CreatureService.luau` |
| D09 | Logout interpretation | Logout moves **unbanked, unprotected** expedition loot to a logout bag. Loadout and protected navigation supplies stay in inventory. Logging out inside a shelter creates no bag. | PROPOSED interpretation (sec 15) | `Inventory.extractForLogout` |
| D10 | Banking | Entering a shelter registers it as the last shelter and banks all expedition loot in one transaction, followed by a durable save. | PROPOSED | `ShelterService.enter` |
| D11 | Before any shelter is registered | New players spawn at the surface depot (R00). | PROPOSED | `WorldDefs.DepotPseudoShelterId` |
| D12 | Out-of-party rescue | Medical help, stabilizing and carrying require the **same current party**. A stranger joins a party to help. A separate one-off consent flow is not built. | PROPOSED (sec 07, 14) | `PlayerService` |
| D13 | Downed window | 45 s bleed-out, paused by a teammate's stabilize. Lethal damage while up → downed. Damage while downed → dead. | PROPOSED / TUNE (sec 07) | `Config.Health`, `Vitals.luau` |
| D14 | Unsecured shelter danger | "Relatively safe" is implemented as an occasional, captioned probe at an **unprotected** entrance. It damages only someone standing right at it (8 HP). A secured shelter blocks all creature damage. | PROPOSED (sec 13) | `ShelterService` probe loop, `canBeDamaged` |
| D15 | Navigation markers | Preset symbols and labels only. No free text, so nothing unfiltered is replicated. Placement limit of 400 per player, shown transparently. | PROPOSED (sec 09, 16) | `NavRecords.PRESETS`, `Config.Navigation` |
| D16 | Quartermaster | A placeholder counter in the depot equipment room stands in for N03 Ines Vidal. It buys and sells for earned coins. | PLACEHOLDER | `EconomyService.luau` |
| D17 | Settings persistence | Per device, held in client memory for the session. Not saved to the profile yet. | PROPOSED, limitation | `Settings.luau` |
| D18 | Scavenging restock | Per player, per site cooldown (10–20 min) stored in the profile, so relogging does not farm it. Each player searches their own copy (F14). | PROPOSED / TUNE | `DiscoveryService`, `WorldDefs.ScavengeSites` |
| D19 | Crafting location | Crafting is offered only inside shelters. Output is loadout (already banked). | PROPOSED | `Commerce.craft` |
