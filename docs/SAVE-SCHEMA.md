# Save schema and migration plan

Section 20. Source of truth: `src/shared/Logic/Profile.luau` (`Profile.default`, `Profile.reconcile`).

## Storage

- DataStore `CatacombsProfiles_v1`, key `u_<UserId>`.
- Value: `{ data = <Profile>, lock = { id = <JobId>, time = <unix> } | nil }`.
- **Session lock:** loading uses `UpdateAsync`. If another server holds a lock younger than `Config.Save.sessionLockStaleSeconds` (600 s), the load waits and retries. After 6 attempts the player is kicked with a clear message rather than risk an overwrite. Every commit checks the lock is still ours and refuses to write if it is not. Releasing the lock happens on departure.
- **Retries:** exponential backoff from 1 s, 5 attempts (`Config.Save`).
- **Durable acknowledgements:** banking, bag creation, mission rewards and purchase receipts call `SaveService.commit`, and success text is shown only after it returns true. A failed save shows "Save failed — will retry" in the HUD.
- **Autosave:** every 90 s for dirty profiles. `BindToClose` runs departure handling for everyone still connected.
- **Crash reconciliation:** the expedition checkpoint is saved every 5 s as `{regionId, pocketVersion, anchorId, offset}`. If a profile loads with unbanked expedition items, the previous session did not depart cleanly, so those items move to a logout bag at the checkpoint.

## Profile v1 fields

| Field | Type | Notes |
| --- | --- | --- |
| `schemaVersion` | number | 1 |
| `userId` | number | Overwritten from the live player on load |
| `class` | string | Explorer, Medic, Runner or Technician |
| `coins` | number | Survives death (F16) |
| `inventory` | `{ [itemId]: { loadout, expedition } }` | Provenance per unit count |
| `lightCharge`, `equippedLight` | number, string? | Equipped light's cell charge, 0–100 |
| `lastShelterId` | string | `R00.depot` until a shelter is registered |
| `shelterUpgrades` | `{ [shelterId]: { [upgradeId]: stage } }` | Monotonic; party max-union inherited |
| `discoveries` | `{ [id]: true }` | Places and shelters |
| `claims` | `{ [pickupId]: true }` | Unique per-player pickups |
| `storyStates` | `{ [key]: string }` | e.g. `M01.completions` |
| `research` | `{ [creatureId]: { stage, evidence } }` | |
| `charactersMet` | `{ [npcId]: string }` | Reserved |
| `stats` | `{ maxStaminaBonus, maxHealthBonus }` | Reserved for F24 |
| `nav` | `{ pages = { [regionId]: { [recordId]: NavRecord } }, nextSeq }` | Paged by region |
| `bags` | `{ death?, logout? }` | Bag records with anchors and authorizations |
| `escrow` | `{ [itemId]: count }` | Delegate recoveries and store overflow |
| `appliedOps` | `{ opId }` | Last 64 bag operation IDs, for idempotence |
| `receipts` | `{ [purchaseId]: true }` | Developer-product dedupe |
| `missionCooldowns` | `{ [key]: unixTime }` | Mission and scavenging cooldowns |
| `toolCharges` | `{ [itemId]: number }` | Stun device charges |
| `checkpoint` | anchor or nil | Crash reconciliation |
| `settings` | table | Reserved (settings are per device for now) |

Temporary party state is **never** stored.

## Migration plan

1. Bump `Profile.CURRENT_VERSION` to *n+1*.
2. Add `MIGRATIONS[n] = function(p) ... end` that transforms a version-*n* profile in place. Never delete owed items: move them to `escrow` if a field is retired.
3. `reconcile` applies migrations in order, then fills missing fields from defaults without overwriting saved values.
4. A server that sees a **newer** schema than it knows refuses the profile (`newer_schema`) instead of truncating it. Roll out new servers before writing new fields.
5. Add a unit test that loads a fixture of the previous version.

## Size budget

Navigation records are the main growth risk: about 200 bytes each × 400 placement limit ≈ 80 KB, well under the 4 MB DataStore value limit. Revisit if regions or limits grow (consider one key per region page).
