# Save schema and migration plan

Section 20. Source of truth: `src/shared/Logic/Profile.luau` (`Profile.default`, `Profile.reconcile`).

## Storage

- DataStore `CatacombsProfiles_v1`, key `u_<UserId>`.
- Value: `{ data = <Profile>, lock = { id = <JobId>, time = <unix> } | nil }`.
- **Session lock:** loading uses `UpdateAsync`. If another server holds a lock younger than `Config.Save.sessionLockStaleSeconds` (300 s, about three autosaves), the load waits and retries. After 6 attempts the player is kicked with a clear message rather than risk an overwrite. Every commit writes only while **this** server holds the lock (a missing lock means another session took over and released it, so its data is newer). Releasing the lock happens on departure; a same-server rejoin waits for an in-flight release. If a loaded profile cannot be used here (newer schema, corrupt, missing migration) the lock is released again without touching the data, so the player is never locked out of other servers.
- **Retries:** exponential backoff from 1 s, 5 attempts (`Config.Save`), with no wait after the final attempt.
- **Durable acknowledgements:** banking, bag creation, mission rewards and purchase receipts call `SaveService.commit`, and success text is shown only after it returns true. A failed save shows "Save failed — will retry" in the HUD.
- **Autosave:** every 90 s for dirty profiles. `BindToClose` runs departure handling for everyone still connected.
- **Crash reconciliation:** the expedition checkpoint is saved every 5 s as `{regionId, pocketVersion, pocketId?, anchorId, offset}`. If a profile loads with unbanked expedition items, the previous session did not depart cleanly, so those items move to a logout bag at the checkpoint (a copy of it; the bag never shares the checkpoint table).

## Profile fields (schema 2)

| Field | Type | Notes |
| --- | --- | --- |
| `schemaVersion` | number | 2 (Milestone 3) |
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
| `stats` | `{ maxStaminaBonus, maxHealthBonus }` | Kept for compatibility; F24 bonuses are derived from `progression` |
| `nav` | `{ pages = { [regionId]: { [recordId]: NavRecord } }, nextSeq }` | Paged by region. A record placed in a variable pocket carries `pocketId` and the pocket's string `pocketVersion`; elsewhere `pocketVersion = 1`. A record moved by a pocket change gains `migratedFrom = { pocketId, version }` |
| `bags` | `{ death?, logout? }` | Bag records with anchors (`{regionId, pocketVersion, pocketId?, anchorId, offset}`) and authorizations |
| `escrow` | `{ [itemId]: count }` | Delegate recoveries and store overflow |
| `appliedOps` | `{ opId }` | Last 64 bag operation IDs, for idempotence |
| `receipts` | `{ [purchaseId]: true }` | Developer-product dedupe |
| `missionCooldowns` | `{ [key]: number }` | Mission and scavenging cooldowns (unix time), plus `scavleft:<siteId>\|<itemId>` = units a player left in a site because their pack was full |
| `toolCharges` | `{ [itemId]: number }` | Stun device charges |
| `checkpoint` | anchor or nil | Crash reconciliation; `pocketVersion` is a string and `pocketId` is set inside a pocket |
| `settings` | table | Reserved (settings are per device for now) |
| `progression` | `{ xp, awarded = { [key]: true } }` | Schema 2. Field experience (F24, D37). `awarded` holds the keys already paid: `disc:<id>`, `shelter:<id>`, `research:<Cxx>:<stage>`, `story:<stepId>`, `mission:<Mxx>:<n>`, `bag:<bagId>`. It grows slowly (one key per first discovery, research stage, story step, mission completion and recovered bag) |

`storyStates` keys in use: `onboarded`, `A1.complete`, `act2.noah_rescued`, `act2.radio_heard`, `act2.logs_compared`, `act2.complete`, `<Mxx>.completions`, `M04.<shelterId>` (breaker repaired), `M04.reward`. `claims` gains `R03.unique.waterworks_log` and `R04.unique.station_tape`; `discoveries` gains pocket passages (`R05.passage_pk1..3`), `R05.p06_verified`, `R04.thief_notes`, `P03.solved`, `W05.solved`.

Temporary party state is **never** stored.

## Migration plan

1. Bump `Profile.CURRENT_VERSION` to *n+1*.
2. Add `MIGRATIONS[n] = function(p) ... end` that transforms a version-*n* profile in place. Never delete owed items: move them to `escrow` if a field is retired.
3. `reconcile` applies migrations in order, then fills missing fields from defaults without overwriting saved values.
4. A server that sees a **newer** schema than it knows refuses the profile (`newer_schema`) instead of truncating it. Roll out new servers before writing new fields.
5. Add a unit test that loads a fixture of the previous version.

### Migration 1 → 2 (Milestone 3)

`MIGRATIONS[1]` adds `progression = { xp = 0, awarded = {} }`. Experience for earlier play is then back-filled on load by `Logic/Progression` from existing facts, idempotently per key, so nothing is paid twice. Records saved before pockets keep `pocketVersion = 1` and stay valid. Rollout: a schema-1 server refuses a schema-2 profile (`newer_schema`) and now releases its lock, so roll new servers out first and shut old ones down.

## Size budget

Navigation records are the main growth risk: about 200 bytes each × 400 placement limit ≈ 80 KB, well under the 4 MB DataStore value limit. Revisit if regions or limits grow (consider one key per region page).
