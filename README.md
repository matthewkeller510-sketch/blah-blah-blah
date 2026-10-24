# Untitled Catacombs Project — Milestones 1–3

An original Roblox exploration-survival horror experience built from the *Paris Catacombs Horror* design and build prompt (version 1, 13 October 2026).
The working title stays **untitled** until the owner chooses one.

> **Status: Milestones 1–3 in code, not the finished game.**
> - **Milestone 1** (spec section 23): one grounded district, one shelter, a short rescue, killable and unkillable creatures, resource scarcity, party sharing and death/logout recovery.
> - **Milestone 2**: the Ossuary Galleries and the Flooded Works, two more shelters, two puzzles, the Wader, hiding, thrown distractions, Act I of the story, a starting-class briefing, and two more mission types.
> - **Milestone 3** ([`docs/MILESTONE-3.md`](docs/MILESTONE-3.md)): the Abandoned Survey Station and the Shifting Crossroads with passages that change while empty (owner rule F08), two more shelters, puzzles P03–P06 and the sluice gates, the Borrowed Miner, Wick Moth, Chalk Hand and Lantern Thief, missions M03, M04, M05, M09 and M11, Act II with the depot characters, the shielded lantern, flares and splints, and veteran progression (F24).
>
> All world geometry is greybox blockout.
> The pure rule modules are unit-tested outside Roblox and every file passes a strict type check against the Roblox API. **None of the Roblox services have been run in Roblox Studio yet.** No milestone is marked complete. See [`docs/IMPLEMENTATION-LEDGER.md`](docs/IMPLEMENTATION-LEDGER.md).

## What is here

| Path | Contents |
| --- | --- |
| `src/shared/Data` | Tunable config (all **TUNE** values), item definitions, world/creature/mission/pocket definitions (`WorldDefs`), cue captions (`CueDefs`), story text (`StoryDefs`) |
| `src/shared/Logic` | Roblox-independent rules: stamina, vitals and the half-health cap, inventory provenance, recovery bags, shelter upgrade union, navigation records, variable pockets, director pressure, creature rules, discovery and claims, crafting and receipts, missions, story, field experience, profile schema |
| `src/server` | `Main.server.luau` (service start-up and a validated, rate-limited request router that services extend with `services.Router.register`) and `Services/` (world blockout, pockets, saving, player state, parties, shelters, navigation, recovery, discovery, director, creatures in `Services/Creatures/`, puzzles, missions, story, characters, economy) |
| `src/client` | HUD, touch-first input, panels, private rendering of markers and bags, accessible cue captions; `Features/` holds self-registering screens and effects (dialogue, missions, puzzles, creature and pocket effects) |
| `src/character/Health.server.luau` | Replaces Roblox's default regeneration so health stays server-authoritative |
| `tests/specs/*.luau` | Unit tests for the logic modules and the world data contract (run with Lune through `tests/run.luau`) |
| `scripts/` | `check-all.sh` (every gate), `typecheck.sh` (strict luau-lsp check), `check-syntax.luau` (compile every file) |
| `docs/` | Ledger, Milestone 3 contract, decision record, item protection table, save schema, mission behavior, economy sheet, audio cue list, Studio test plan |

## Build and test

Tooling: [Rojo](https://rojo.space) 7.4, [Lune](https://lune-org.github.io/docs) 0.11, [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.6, [selene](https://github.com/Kampfkarren/selene) 0.31, [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) 1.53 (type checking).

```sh
sh scripts/check-all.sh       # every gate below in one go
lune run tests/run            # logic unit tests
lune run scripts/check-syntax # compile every .luau file
sh scripts/typecheck.sh       # strict type check with the Roblox definitions (downloads them once into .cache/)
selene src tests              # lint (uses roblox-lite.yml when the full Roblox std cannot be downloaded)
stylua --check src tests scripts
rojo build -o catacombs.rbxlx # build a place file
rojo serve                    # live-sync into an open Studio place
```

None of these checks prove the game works in Roblox; they catch logic, type and integration mistakes before a Studio run.

### Ready-made place file

`build/CatacombsUntitled.rbxl` contains every script in one place file. Open it directly in Roblox Studio (File → Open from File) and press **Play**. The Workspace looks empty in edit mode because `WorldBuilder` generates every region, shelter exterior and set-piece when the server starts, `PocketService` builds the current version of each variable passage, and the puzzle, character and creature services build their own props. Rebuild it after code changes with `rojo build -o build/CatacombsUntitled.rbxl`.

### Importing into Studio

Work only in a **new or explicitly designated** place (spec section 01). Never sync into Delivery Dash, Creature Cafe, Mine it All, Root & Rise or any other existing experience.

1. Create a new empty Baseplate place and delete its `Baseplate` part. The world is generated at runtime by `WorldBuilder`.
2. Run `rojo serve` and connect from the Rojo Studio plugin, or open the built `catacombs.rbxlx`.
3. For saving, publish to a **private test experience** and enable *Studio Access to API Services*. Without DataStore access the HUD shows "Not saving" and progress does not persist.
4. Follow [`docs/TEST-PLAN.md`](docs/TEST-PLAN.md) (rows 28 onward cover Milestone 3; lower `Config.Pockets.cycleSeconds` to see passages change quickly). Record the place ID, device and observed results in the ledger. A Studio run is not real-device evidence.

## Controls

| Action | Keyboard / mouse | Touch | Gamepad |
| --- | --- | --- | --- |
| Move / look | WASD / mouse | left stick zone / right drag | sticks |
| Sprint | hold Shift (toggle in Settings) | Sprint (bottom row) | hold L2 |
| Crouch | C | small Crouch button (right) | L3 |
| Light on/off · swap cell | F · R | small Light button (right) · Cell (left column) | Y · D-pad left |
| Lantern shutters (shielded lantern) | V | Shield (bottom row) | L1 |
| Light a flare ahead | N | Flare (left column) | R1 |
| Use medical | H | Medical (left column) | D-pad down |
| Use tool (iron bar / stun) · switch tool | click · Q | Use (bottom row) | R2 |
| Chalk · sign · rope (two points) | G · T · Y | Chalk · Sign · Rope (left column; sign and rope while carried) | — |
| Help a downed teammate (stabilize, then carry) / drop | X | Help (bottom row) | B |
| Verified party ping | Z | Ping (bottom row) | R3 |
| Throw a stone (distraction) | B | Throw (bottom row) | D-pad right |
| Hide in a niche / step out | E at the niche | tap prompt | prompt |
| Carry a survivor (rescue prompt) | J | tap prompt | prompt |
| Notebook · inventory · party · settings · character | Tab · I · P · O · K | Menu (bottom row) | D-pad up (menu) |
| Interact (search, shelter, rescue, recover bag, talk, puzzles) | E (hold) | tap prompt | prompt |

On PC the cursor is freed whenever a screen is open (first person otherwise locks it to the centre). HUD (D108): health top left; consumables as an icon column on the left with counts (key hints on PC); battery bottom right; on touch screens a row of action slots along the bottom, ending beside the jump button, and very small Crouch and Light buttons on the right. Icons are drawn from shapes until art is uploaded (D109). Screens close on a chase cue or when you go down.

## Ground rules followed

- Status labels follow the spec: **CONFIRMED** owner rules, **PROPOSED** defaults, **TUNE** numbers. Proposed choices made here are recorded in [`docs/DECISIONS.md`](docs/DECISIONS.md).
- The server validates every change to value, health or ownership. Clients only send requests.
- No developer products are configured and nothing is published. The store stays disabled until an authorized test or live configuration adds product IDs.
- Placeholder content is labeled `PLACEHOLDER` (meshes, icons, sounds). Characters are greybox figures; all story, log, plaque and note text is fictional.
