# TODO — Worms Playground

Running list of next steps. Newest priorities near the top of each section.
Keep this file honest: delete items when done, add context (file paths,
"why") so a future session can act without re-deriving everything.

---

## God-file refactor (split up with `fable`)

Several files have grown well past a maintainable size. They're doing too
many jobs each and are hard to navigate, review, and reason about. Use
**fable** to split these into focused modules. **Do NOT start this yet** —
it's a large, careful, mechanical refactor that deserves its own dedicated
session so we don't destabilize gameplay mid-feature.

Current offenders (line counts as of 2026-05):

| File | Lines | Rough responsibilities that could split out |
|---|---|---|
| `src/ServerScriptService/Server/Services/WormService/init.luau` | ~2840 | worm lifecycle/movement, food spawning+collection, ghost spawn/despawn/damage, ghost rider tracking, spatial-grid build, collision checks, client RPCs, bot registration bridge |
| `src/ReplicatedStorage/Client/Controllers/WormUIController.luau` | ~2670 | HUD, minimap, death screen, scoreboard, toolbar, crown banner, ghost HUD, match timer, respawn countdown, team scores — basically every piece of UI in one controller |
| `src/ServerScriptService/Server/Services/BotService/init.luau` | ~2290 | bot worm AI+movement+collision, bot ghost rig build+animation+AI, avatar template cache, spatial-grid queries, separation/flocking |
| `src/ReplicatedStorage/Client/Controllers/WormController.luau` | ~1540 | camera, spectate, input, ghost mode, ground/ghost grapple visuals, render loop |
| `src/ServerScriptService/Server/Services/WeaponService/init.luau` | ~1400 | weapon assignment, shoot validation, raycast hit resolution, projectile handling, reload |
| `src/ServerScriptService/Server/Services/LeaderboardService/init.luau` | ~1340 | (review — may be legitimately large; check before splitting) |

### Suggested split strategy (per file, when we do start)
- Keep the Knit service/controller shell (`init.luau`) thin: lifecycle
  (`KnitInit`/`KnitStart`), state tables, and delegation.
- Extract cohesive concerns into sibling modules the shell requires and
  composes (e.g. `WormService/Ghosts.luau`, `WormService/Food.luau`,
  `WormService/Collision.luau`; `WormUIController/Minimap.luau`,
  `WormUIController/DeathScreen.luau`, etc.).
- Preserve the existing public method surface — other services call into
  these by name; the refactor must be behavior-neutral.
- Split ONE file per PR/commit, run stylua + selene + a full playtest
  between each so a regression is easy to bisect.

---

## Deferred multiplayer-audit items (from the earlier best-practices pass)

These were identified in the audit but not yet addressed. Ordered by
rough leverage.

- [ ] **O(N²) fully retired?** The spatial hash covers collision + threat
  search + food. Double-check no remaining per-frame full-scan loops
  (search for `:GetChildren()` inside Heartbeat paths).
- [ ] **Late-joiner race** — `WormService.PlayerAdded` vs
  `RoundService.PlayerAdded` both wire the player; the `task.wait(2)`
  in RoundService is a band-aid. Replace with a synchronous
  `RegisterPlayer` handshake and early-return if the player left.
- [ ] **Wall-pulse Heartbeat** — `WormService:_createArena` connects an
  unconditional Heartbeat that writes `part.Color` every frame on the
  animated wall parts (replicates to all clients for a purely cosmetic
  effect). Move the pulse to a client controller; server just tags the
  parts.
- [ ] **PowerUp `FireAll` fan-out** — per-player powerup state broadcast to
  everyone. Consider per-worm attribute changes or filtered fires.
- [ ] **WeaponService reload `task.delay`** not cancellable on player
  leave — track timers per player, cancel in PlayerRemoving.
- [ ] **Crown carrier head lookup** — `CrownService` resolves the carrier
  head position by scanning `_worms`/`_bots` every Heartbeat; cache the
  resolver on pickup, clear on drop.

---

## Gameplay / feel polish (ideas, not yet scoped)

- [ ] Grapple styles (`GrappleStyles.luau`) currently only vary color /
  width / particles on a straight rope. `SnapEasing`/`PullEasing`/
  `SagFactor`/`FlingFactor`/`PostPullWiggleCount` are no-ops on the
  ghost-grapple visual. Either wire them into a richer visual or prune
  the dead fields.
- [ ] Bot difficulty tuning pass once combat is stable (reaction time,
  boost usage, target selection).
- [ ] Food iteration (`_findNearestFood`) still linear per bot — cheap
  now, but could reuse the food spatial grid if it ever shows up in the
  profiler.

---

## Housekeeping

- [ ] Remove leftover diagnostic `print`s (grep `[bot-ghost]`, `[grapple]`,
  `[grapple-srv]`) once the relevant systems are confirmed stable.
