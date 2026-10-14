# Untitled Catacombs Project — Milestones 1–2

An original Roblox exploration-survival horror experience built from the *Paris Catacombs Horror* design and build prompt (version 1, 13 October 2026).
The working title stays **untitled** until the owner chooses one.

> **Status: Milestones 1–2 in code, not the finished game.**
> - **Milestone 1** (spec section 23): one grounded district, one shelter, a short rescue, killable and unkillable creatures, resource scarcity, party sharing and death/logout recovery.
> - **Milestone 2**: the Ossuary Galleries and the Flooded Works, two more shelters, two puzzles, the Wader, hiding, thrown distractions, Act I of the story, a starting-class briefing, and two more mission types.
>
> All world geometry is greybox blockout.
> The pure rule modules are unit-tested outside Roblox. **None of the Roblox services have been run in Roblox Studio yet.** No milestone is marked complete. See [`docs/IMPLEMENTATION-LEDGER.md`](docs/IMPLEMENTATION-LEDGER.md).

## What is here

| Path | Contents |
| --- | --- |
| `src/shared/Data` | Tunable config (all **TUNE** values), item definitions, world/creature/mission definitions |
| `src/shared/Logic` | Roblox-independent rules: stamina, vitals and the half-health cap, inventory provenance, recovery bags, shelter upgrade union, navigation records, director pressure, discovery and claims, crafting and receipts, profile schema |
| `src/server` | `Main.server.luau` (service start-up and a validated, rate-limited request router) and `Services/` (world blockout, saving, player state, parties, shelters, navigation, recovery, discovery, director, creatures, missions, economy) |
| `src/client` | HUD, touch-first input, panels, private rendering of markers and bags, accessible cue captions |
| `src/character/Health.server.luau` | Replaces Roblox's default regeneration so health stays server-authoritative |
| `tests/run.luau` | Unit tests for the logic modules (run with Lune) |
| `scripts/check-syntax.luau` | Compiles every Luau file to catch syntax errors |
| `docs/` | Ledger, decision record, save schema, mission behavior, economy sheet, audio cue list, Studio test plan |

## Build and test

Tooling: [Rojo](https://rojo.space) 7, [Lune](https://lune-org.github.io/docs) 0.11, [StyLua](https://github.com/JohnnyMorganz/StyLua), [selene](https://github.com/Kampfkarren/selene).

```sh
lune run tests/run            # logic unit tests
lune run scripts/check-syntax # compile every .luau file
selene src tests              # lint (uses roblox-lite.yml when the full Roblox std cannot be downloaded)
stylua --check src tests scripts
rojo build -o catacombs.rbxlx # build a place file
rojo serve                    # live-sync into an open Studio place
```

### Ready-made place file

`build/CatacombsUntitled.rbxl` contains every script in one place file. Open it directly in Roblox Studio (File → Open from File) and press **Play**. The Workspace looks empty in edit mode because `WorldBuilder` generates the depot, quarry and shelter when the server starts. Rebuild it after code changes with `rojo build -o build/CatacombsUntitled.rbxl`.

### Importing into Studio

Work only in a **new or explicitly designated** place (spec section 01). Never sync into Delivery Dash, Creature Cafe, Mine it All, Root & Rise or any other existing experience.

1. Create a new empty Baseplate place and delete its `Baseplate` part. The world is generated at runtime by `WorldBuilder`.
2. Run `rojo serve` and connect from the Rojo Studio plugin, or open the built `catacombs.rbxlx`.
3. For saving, publish to a **private test experience** and enable *Studio Access to API Services*. Without DataStore access the HUD shows "Not saving" and progress does not persist.
4. Follow [`docs/TEST-PLAN.md`](docs/TEST-PLAN.md). Record the place ID, device and observed results in the ledger. A Studio run is not real-device evidence.

## Controls

| Action | Keyboard / mouse | Touch | Gamepad |
| --- | --- | --- | --- |
| Move / look | WASD / mouse | left stick zone / right drag | sticks |
| Sprint | hold Shift (toggle in Settings) | Sprint | hold L2 |
| Crouch | C | Crouch | L3 |
| Light on/off · swap cell | F · R | Light · Cell | Y |
| Use medical | H | Med | X |
| Use tool (iron bar / stun) · switch tool | click · Q | Use | R2 |
| Chalk · sign · rope (two points) | G · T · Y | Mark (chalk) | — |
| Help a downed teammate (stabilize, then carry) / drop | X | Help | — |
| Verified party ping | Z | — | — |
| Throw a stone (distraction) | B | Throw | — |
| Hide in a niche / step out | E at the niche | tap prompt | prompt |
| Notebook · inventory · party · settings | Tab · I · P · O | Menu | — |
| Interact (search, shelter, rescue, recover bag) | E (hold) | tap prompt | prompt |

## Ground rules followed

- Status labels follow the spec: **CONFIRMED** owner rules, **PROPOSED** defaults, **TUNE** numbers. Proposed choices made here are recorded in [`docs/DECISIONS.md`](docs/DECISIONS.md).
- The server validates every change to value, health or ownership. Clients only send requests.
- No developer products are configured and nothing is published. The store stays disabled until an authorized test or live configuration adds product IDs.
- Placeholder content is labeled `PLACEHOLDER` (meshes, icons, sounds) or "placeholder" in-game (quartermaster, Mara Voss's board).
