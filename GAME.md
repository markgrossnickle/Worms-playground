# Worms Playground - Game Documentation

A 3-team multiplayer worms game built on Roblox using the Knit framework. Players control worms slithering across a **triangular** arena of sand dunes. Each team spawns in its own corner base. A single **Crown** spawns at the map center — pick it up and hold it to score for your team. Die as a worm and you become a **ghost**, which can still shoot, grapple, and ride worms. Ghosts earn **Marks** by harassing enemies and can spend them to respawn as a worm. In the final 90 seconds, respawns lock out, the map collapses via a rising "sand tide", and the match resolves by score, elimination, or clock.

## Elevator Pitch

- **3 teams** (Red / Blue / Green), **team-only mode**, **8-minute matches**
- **Triangular map** — bases in the three corners, Crown at the centroid
- Start as **worm** → die → **ghost** → earn Marks → **respawn as worm**
- **Three win conditions:** score threshold / elimination / timeout
- Ghosts are always **visible** to everyone (team-tinted glow) — not invisible
- **No PvP outside the match loop:** rounds are the whole game

## Worm King Mode

### Match structure

- **Match length:** 8 minutes (`MatchDuration = 480` s)
- **Teams:** 3 (Red, Blue, Green)
- **Lobby size:** 8–16 players ideal; bots fill to a target count so matches always start full
- **Spawn:** all worms of a team cluster on their corner base at T=0 with a brief camera-locked countdown, then move out

### Crown + scoring

- One **Crown** spawns at the centroid of the map at T=0
- Any worm that touches the Crown **picks it up** (visible crown mesh on the head)
- Holding the Crown awards **+1 score per second** to the holder's team
- On the holder's death, Crown **drops at the death position** (eligible for anyone, including the killer)
- If the Crown is left on the ground > 15 s or falls into the sand tide kill zone, it **teleports back to the centroid**
- There is **no killer bounty** on the Crown-holder — the Crown is its own reward; killing the holder doesn't pay extra points

### Ghost lifecycle — Marks

- Die as a **worm** → become a ghost (respawn near death location, no Mark wipe, no base teleport)
- Die as a **ghost** → re-materialize at your team's base, 1 s delay, no penalty
- Ghosts earn **Marks** by:

  | Event | Marks |
  |---|---|
  | Damage assist on an enemy worm | +1 |
  | Killing blow on an enemy worm | +3 |
  | Damage assist on the Crown-carrier | +2 |
  | Killing blow on the Crown-carrier | +5 |

- **Respawn cost:** 10 Marks. Ghosts press a HUD button (or key) to cash in and spawn back as a worm at their team base
- Marks persist for the full match (no per-death reset on the ghost side)

### Win conditions (evaluated in order)

1. **Score** — first team to reach `ScoreThreshold = 100` points
2. **Elimination** — during the respawn-lockdown window (last 90 s), if only one team has any living worms, that team wins
3. **Timeout** — at T=8:00, highest team score wins (tie-break: time spent carrying the Crown)

### Sand tide (map shrink)

The BR-style radial shrink is replaced by a **triangle contraction** from the outside in. The triangle keeps its shape and shrinks toward the centroid on a schedule:

| Time | Event |
|---|---|
| T+0:00 | Full triangle, bases at corners |
| T+4:00 | **Sand tide begins** — triangle starts contracting (slow phase) |
| T+6:00 | **Fast phase** — sand tide accelerates |
| T+6:30 | **Respawn lockdown** — Marks respawn disabled; worms are worms, ghosts are ghosts |
| T+8:00 | Max contraction; match ends |

- **Outside the triangle:** sand level visibly rises (sand tide), damaging worms at 5 HP/s (segment-destroying, survivable briefly so you can dash back in)
- **Bases move** along the corner→centroid line, keeping their relative position as the triangle shrinks
- **Safe zones stay fixed at 60-stud radius** (they do not shrink with the map — otherwise late-game spawn safety vanishes)
- **Crown drops** outside the current triangle instantly teleport back to the centroid

### Spawn protection

- **2-second invulnerability** on any worm spawn (round start, Marks respawn)
- Visual: soft team-colored dome pulse on the worm
- Breaks early on: (a) dealing damage, (b) leaving the 60-stud safe zone of the base, whichever comes first

### Teammate pass-through

- Teammates **do not collide** with each other's bodies — worms can cross their own allies freely
- Enforced by the team collision check in `WormService` (already implemented via `TeamService:AreTeammates`)

### Map & base placement

- **Shape:** equilateral triangle inscribed in the existing `ArenaSize = 1200` square (side length ≈ 1040 studs)
- **Bases:** placed at each corner, each with:
  - Flattened terrain footprint (~60-stud radius, ±2 studs variance)
  - Team-colored banner / flag visual
  - Safe-zone trigger volume (transparent, tagged for client-side dome effect)
  - 8 spawn points arranged in a ring inside the safe zone
- **Crown spawn:** centroid of the triangle, on terrain surface

### Monetization note

Worm King is the **only game mode** for now. Cosmetic monetization only (skins, trails, death effects, etc.) — no paid combat advantages. Details tracked separately.

## Legacy Game Mechanics (still in code, being rebuilt around Worm King)

## Game Mechanics

### Movement

Worms move continuously in the direction of the player's cursor (or touch position on mobile). The server moves each worm's `HumanoidRootPart` by setting its `CFrame` every Heartbeat frame. All physics is disabled (HRP is anchored, WalkSpeed/JumpPower zeroed).

- **Base speed:** 30 studs/s
- **Boost speed:** 60 studs/s (hold Shift, left mouse, gamepad trigger, or tap the mobile boost button)
- **Boost cost:** 0.5 segments/s (stops at 5 minimum segments)
- **Turn rate:** 4 rad/s (≈230 deg/s) — worms rotate toward the cursor direction at a capped rate
- **Initial segments:** 8

Direction is sent from the client via `WormService.Client:SetDirection(dirX, dirZ)`. The client throttles send-rate: a new vector is sent when it has changed by more than ~3° from the last sent one, or at most every 50 ms (20 Hz), whichever comes first.

### Segment Following (Position History Buffer)

Segments don't follow the head with physics. Instead, the server records the head's position every 0.5 studs into a ring buffer (`PositionHistory`). Each segment reads the position that was `index * ENTRIES_PER_SEGMENT` entries behind the current head position. Old entries are trimmed as the worm moves forward.

- `MIN_RECORD_DISTANCE = 0.5` studs between recorded positions
- `SegmentSpacing = 1.5` studs between segment centers
- `SegmentSize = 2.5` studs (ball diameter)
- **Segment HP:** 3 HP per segment — weapon damage reduces HP; segment is destroyed at ≤0

### Eating and Growth

Food is collected when a worm's head comes within `CollisionRadius + 1 = 3` studs. Each food item has a `FoodValue` attribute determining how many segments it adds (see [Food System](#food-system)). When segments are added, new `Part` instances are created in the `WormSegments` folder and the position history buffer is extended.

Worms also have a **passive food magnet**: food within `PassiveMagnetRange = 8` studs drifts toward the head at a slow pull (`PassiveMagnetPull = 1`). The `MAGNET` power-up extends this to 25-stud range with a stronger pull.

### Collision and Death

A worm dies when its head touches another worm's body segment (within `CollisionRadius * 2 = 4` studs). On death:

1. Active power-ups are cleared
2. 70% of segments scatter as collectible food at the actual segment positions
3. The worm's character visuals are destroyed
4. After `RespawnDelay = 3` seconds, the player is offered **Ghost mode** (see below) instead of immediate respawn

Worms also die if they hit the arena walls or exit the shrink zone.

### Player Head

Player worms use the actual Roblox avatar `Head` as the worm head. The setup process: breaks all `Motor6D` joints connecting to the Head, anchors it, resizes it to 3 studs, renames it to `WormHead`, and hides all other character parts (body, accessories, clothing) by setting `Transparency = 1`. Face decals on the Head remain visible.

## Terrain

The arena floor is **Roblox-native terrain** generated from a deterministic height map shared between server and client (`src/ReplicatedStorage/Shared/TerrainHeight.luau`).

### Generation

`WormService:_createArena()` clears the default Studio baseplate and terrain, recolors the Sand/Sandstone/Ground materials for top-down contrast, then fills the arena in an 8-stud grid with `workspace.Terrain:FillBlock()`. Block heights come from a layered noise function:

```lua
h = noise(x * 0.003, z * 0.003) * 14       -- large dunes
  + noise(x * 0.008, z * 0.008) * 5        -- medium ripples
  + noise(x * 0.02,  z * 0.02)  * 1.5      -- wind-blown detail
```

Material is chosen by height: low areas are `Sand`, mid areas `Sandstone`, ridges `Ground`.

### Surface Queries

`TerrainHeight` exports three functions used everywhere that needs a ground Y:

| Function | Purpose |
|---|---|
| `getHeight(x, z)` | Raw noise height (pre-block, no voxel padding) |
| `getSurfaceY(x, z)` | Max of 4 neighbouring grid-cell block tops + voxel pad. Discrete (stair-stepped) — used for **food / power-up / ghost spawn** positioning where being above terrain matters more than smoothness |
| `getSmoothSurfaceY(x, z)` | **Bilinear** interpolation of the 4 block tops + extra pad. Smooth, continuous — used for **worm/bot heads, segments, grapple targets** so segments glide over dunes instead of stair-stepping |

Both surface functions add `VOXEL_PAD = 2` studs because `FillBlock` quantises to half-voxel (2 studs).

## Architecture

Built on the **Knit** framework (v1.7.0). Services run on the server, controllers on the client. Communication uses Knit signals (auto-injected `player` parameter on client-to-server calls).

### Startup Flow

1. **Server:** `Main.server.luau` → `Server:Main()` → `Knit.AddServices()` → `Knit:Start()` → load server components → load shared components → set `ServerStatus = "Started"`
2. **Client:** `ClientEntry.server.luau` → waits for `ServerStatus == "Started"` → `Knit.AddControllers()` → `Knit:Start()` → load client components → load shared components

### Server Services

| Service | File | Purpose |
|---|---|---|
| **WormService** | `Services/WormService/init.luau` | Core game logic: arena creation, food spawning, worm lifecycle, movement, collision detection, ghost system, ghost-rider tracking, game loop |
| **BotService** | `Services/BotService/init.luau` | AI bot worms: spawning, decision-making, movement, food/power-up collection |
| **WeaponService** | `Services/WeaponService/init.luau` | Ghost weapons: assignment, ammo, hitscan & projectile simulation (server-authoritative), pickup spawning, mine proximity triggers |
| **RoundService** | `Services/RoundService/init.luau` | Round lifecycle: countdown, start, poll for round-end, elimination order, placement ranking, coin rewards, Worm King mode orchestration |
| **PowerUpService** | `Services/PowerUpService/init.luau` | Power-up spawning, collection, effect application, expiration |
| **ShrinkZoneService** | `Services/ShrinkZoneService/init.luau` | Battle royale shrink zone (disabled while Worm King mode is active — replaced by SandTideService) |
| **TeamService** | `Services/TeamService/init.luau` | 3-team assignment for Worm King mode, teammate collision skip, team scores, active-mode detection |
| **CoinService** | `Services/CoinService/init.luau` | Coin balance, placement payouts, daily-login rewards with streak tracking |
| **CrownService** | `Services/CrownService/init.luau` | Worm King objective: single Crown part, pickup detection, carrier tracking, +1/s team score while carried, win at threshold |
| **MarksService** | `Services/MarksService/init.luau` | Soft currency earned in ghost mode (kill assists, Crown touches). Spent to respawn as a worm. Per-round, non-persistent |
| **SandTideService** | `Services/SandTideService.luau` | Map contraction: scales the playable triangle over time, damages worms outside the safe zone, broadcasts scale + warnings to clients |
| **PlayerDataService** | `Services/PlayerDataService/` | Profile-based persistence using ProfileStore |
| **LeaderboardService** | `Services/LeaderboardService/` | OrderedDataStore leaderboards (segments, ghost kills, ride time) with caching |
| **BadgeService** | `Services/BadgeService.luau` | Roblox badge management |
| **MilestoneService** | `Services/MilestoneService/` | One-time achievement tracking |
| **MTAnalyticsService** | `Services/MTAnalyticsService.luau` | Analytics wrapper with rate limiting |
| **CmdrService** | `Services/CmdrService/` | Admin command framework (F2 to activate) |

### Client Controllers

| Controller | File | Purpose |
|---|---|---|
| **WormController** | `Controllers/WormController.luau` | Input (mouse/keyboard/touch/gamepad), camera, direction sending, ground grapple (alive), ghost input, ghost grapple state machine, grapple beam rendering |
| **WeaponController** | `Controllers/WeaponController.luau` | Weapon input (fire/charge/reload), projectile visual prediction, weapon pickup collection |
| **WormUIController** | `Controllers/WormUIController.luau` | Full HUD: segment counter, leaderboard, minimap, kill feed, death screen, power-up display, weapon ammo/reload bar, coin display, daily-reward popup, round scoreboard |
| **InputController** | `Controllers/InputController.luau` | Shared input layer / input-device change tracking |
| **DeathCamController** | `Controllers/DeathCamController.luau` | Spectate / free-cam after death before ghost spawn |
| **EffectsController** | `Controllers/EffectsController.luau` | Hit sparks, explosion VFX, damage feedback |
| **AnimationController** | `Controllers/AnimationController.luau` | Ghost avatar animation playback |
| **CmdrController** | `Controllers/CmdrController/` | Cmdr client activation |

### Inter-Service Communication

Services reference each other via `require()` in `KnitStart` (not `KnitInit`) to avoid circular dependency issues:

```
WormService     -> WeaponService, PowerUpService, ShrinkZoneService, TeamService, LeaderboardService, SandTideService
BotService      -> WormService, PowerUpService, ShrinkZoneService, TeamService, SandTideService
WeaponService   -> WormService, TeamService, BotService
RoundService    -> WormService, BotService, ShrinkZoneService, PowerUpService, CoinService, TeamService,
                   CrownService, MarksService, SandTideService
PowerUpService  -> WormService
CrownService    -> WormService, BotService, TeamService
MarksService    -> WormService, CrownService, TeamService
SandTideService -> WormService, BotService, TeamService
```

## Networking & Replication

The game follows the **"Server Brain, Client Body"** pattern (documented in `CLAUDE.md`).

### Server-side position cache

Each `WormData` / `BotData` carries three cached fields:

- `HeadPosition: Vector3`
- `HeadDirection: Vector3`
- `SegmentPositions: { [number]: Vector3 }`

Gameplay reads go through these cached fields. `BasePart.CFrame` / `Part.Position` writes are the expensive replicated operation and are **gated** by a `_broadcastTick` counter — physical parts are only repositioned when `_broadcastTick % 6 == 0` (~10 Hz at 60 fps Heartbeat). Collision detection reads the cache every frame, so gameplay is still tick-perfect even though the wire state updates at 10 Hz.

### Direction send throttle

`WormController` sends `SetDirection` to the server only when the new direction differs from the last sent one by more than ~3° (`dot < 0.9986`), or every 50 ms at minimum, whichever comes first. This caps outbound client-to-server traffic at 20 Hz even if the mouse sweeps fast.

### Projectiles

Server simulates projectile trajectories in a pure-data table (position, velocity, bounces, fuse, etc.). Hits are resolved by server raycasts — no part is moved per frame. The client receives `ProjectileSpawned` and `ProjectileExploded` signals and animates a local visual Part for immediate feedback.

Mines use `workspace:GetPartBoundsInRadius` with a filtered `OverlapParams` for proximity triggering — a spatial query that beats the old O(worms × segments) scan.

## Key Files

```
src/
  ReplicatedStorage/
    Shared/
      WormConfig.luau                     -- Worm / arena / ghost / grapple / power-up / team constants
                                             (incl. WormKing sub-table: Crown, Marks, SandTide tuning)
      WeaponConfig.luau                   -- Weapon definitions
      TerrainHeight.luau                  -- Deterministic terrain height + smooth surface Y
      TeamBase.luau                       -- Equilateral-triangle math: centroid, vertices, scaled
                                             vertices, safe-zone queries, spawn positions per team
      PlatformUtil.luau                   -- IsTouchDevice / IsGamepad / ActionLabel / MinTouchSize
                                             (48pt minimum on touch) / ParticleScale (50% on mobile)
      Configs/LeaderboardConfig.luau      -- Leaderboard periods and keys
      Enums/WormState.luau                -- "Alive" | "Dead" | "Spectating"
    Client/
      init.luau                           -- Client bootstrap
      Controllers/
        WormController.luau               -- Input, camera, ground grapple, ghost grapple (~1650 lines)
        WeaponController.luau             -- Weapon input + projectile visuals (~750 lines)
        WormUIController.luau             -- Full game HUD (~1800 lines)
        DeathCamController.luau, EffectsController.luau, AnimationController.luau, InputController.luau
  ServerScriptService/
    Server/
      init.luau                           -- Server bootstrap
      Main.server.luau                    -- Entry point
      Services/
        WormService/init.luau             -- Core gameplay (~2370 lines)
        BotService/init.luau              -- AI bots (~1230 lines)
        WeaponService/init.luau           -- Ghost weapons & projectiles (~1380 lines)
        RoundService/init.luau            -- Round lifecycle & placement rewards
        PowerUpService/init.luau          -- Power-up system
        ShrinkZoneService/init.luau       -- Shrink zone (disabled during Worm King mode)
        TeamService/init.luau             -- 3-team assignment
        CoinService/init.luau             -- Coin balance & daily rewards
        CrownService/init.luau            -- Worm King objective (Crown + team scoring)
        MarksService/init.luau            -- Ghost currency for respawn
        SandTideService.luau              -- Map contraction + out-of-zone damage
```

## Food System

### Spawning

Food spawns continuously to maintain `MaxFoodOnMap = 400` items on the arena (up to 10 per frame). Each food item is a neon `Ball` Part placed at a random arena position and sat on top of the terrain via `getSurfaceY`.

### Size Tiers

Food comes in three sizes, selected by weighted random:

| Tier | Size (studs) | Segments Added | Spawn Weight |
|---|---|---|---|
| Small | 1.2 | +1 | 60% |
| Medium | 2.0 | +2 | 30% |
| Large | 3.0 | +4 | 10% |

The value is stored as a `FoodValue` attribute on each food Part. Colors are fully randomized (random hue, high saturation).

### Death Scatter

When a worm dies, 70% of its segments become collectible food scattered at the **actual segment positions** (with a small random offset of ±3 studs). If there are more food items to drop than segment positions, extras scatter randomly around the head position. All death-dropped food has value 1.

### Double-Consumption Guard

A `Consumed` attribute is set on food before destruction to prevent multiple worms from eating the same food in the same Heartbeat frame.

## Power-Up System

### Types

| Power-Up | Color | Duration | Effect |
|---|---|---|---|
| **SPEED** | Cyan | 3s | 2× speed multiplier |
| **SPEED_BURST** | Bright cyan | 3s | 3× speed multiplier (with VFX trail) |
| **MAGNET** | Pink | 10s | Pulls food within 25 studs toward the head |
| **GHOST** | Light blue | 5s | Immune to all worm-vs-worm collisions |
| **SHIELD** | Yellow | Until consumed | Blocks one lethal collision, then expires |
| **SIZE_BOMB** | Orange | Instant | Immediately adds 5 segments |
| **FREEZE_RING** | Ice blue | 4s | Slows any worm within 15 studs to 0.5× speed |

### Spawning and Collection

- Spawn every 10–15 seconds (random interval), up to 4 on the map at once
- Visual: neon sphere + 40-stud tall light pillar + PointLight + BillboardGui label
- Despawn after 20 seconds if uncollected
- Collected when any worm's head comes within `CollisionRadius + 2 = 4` studs
- Only one active power-up per worm at a time (new one replaces old)

### Client Signals

- `PowerUpSpawned(id, type, position, color)` — new power-up appears
- `PowerUpCollected(ownerName, type, position)` — someone picked one up
- `PowerUpActivated(ownerName, type, duration)` — effect started
- `PowerUpExpired(ownerName, type)` — effect ended

### Query API

Other services query PowerUpService to apply effects:
- `GetSpeedMultiplier(ownerName)` — returns 1, 2, or 3
- `GetMagnetRange(ownerName)` — returns 25 or 0
- `IsGhost(ownerName)` — true while GHOST is active (separate from ghost-mode player state)
- `ConsumeShield(ownerName)` — returns true if shield was consumed
- `GetFreezeRings()` — returns active freeze-ring positions for slow-check
- `GetNearestPowerUp(pos, range)` — used by bot AI

## Battle Royale (Shrink Zone) — Legacy

> **Note:** The radial BR shrink is being replaced by the triangle-contracting **sand tide** described in [Worm King Mode](#worm-king-mode). This section documents the current code, which still runs until the sand-tide system ships.

### Timeline

| Time | Event |
|---|---|
| 0:00 | Round starts, zone radius = full arena (`ArenaSize / 2 = 600`) |
| 0:50 | Warning: "Zone shrinking in 10 seconds!" |
| 1:00 | Zone begins shrinking (linear interpolation from `ShrinkStartTime = 60`) |
| 2:30 | Warning: "Zone closing in 30 seconds!" |
| 3:00 | `ShrinkEndTime = 180`; zone reaches `ShrinkMinRadius = 40` |

### Ring Border Visual

A ring of neon-red Parts forms the zone boundary. The ring updates every Heartbeat to match the current radius.

### Zone Enforcement

Players and bots are killed instantly if their head is outside the current zone radius (`Vector2 distance from origin > currentRadius`). Checked in `WormService:_checkBounds()` and `BotService:_checkBotCollisions()`.

### Client Updates

Zone radius and elapsed time are sent to all clients at 2 Hz via `ZoneUpdate`. The minimap shows a red circle overlay that shrinks to match. A game timer displays elapsed time in `M:SS`.

## Rounds

Rounds are orchestrated by **RoundService**.

### Lifecycle

1. **Countdown** (`RoundCountdownDuration = 10`s): players see a "Round starting in N…" overlay; world is reset (food, power-ups, shrink zone, team assignments).
2. **Start**: `WormService:SpawnWormForRound(player)` spawns each player; `BotService:SpawnBotsToFill()` tops the population up to the target count.
3. **Active**: round poll fires every few seconds. Round ends when the alive count drops below threshold (1 in FFA, or one team left in Team Mode).
4. **Scoreboard** (`RoundScoreboardDuration = 8`s): placement rankings shown to all players; coin rewards awarded.
5. Loop back to countdown.

### Placement Rewards (coins)

| Placement | Coins |
|---|---|
| 1st | 100 |
| 2nd | 60 |
| 3rd | 40 |
| 4th | 25 |
| Other / eliminated earlier | 10 (default) |

Paid via `CoinService:AwardCoins` on round end. `CoinService` also handles **daily login rewards** with streak tracking.

### Elimination Order

Deaths are recorded in `_eliminationOrder` as they happen. At round end, survivors are prepended (best placements) and eliminations are reversed (last eliminated = best among the dead). Ties are broken by max-segments reached during the round.

## Ghost Mode

When a player dies, they respawn as a **ghost** — a partially-transparent avatar version of themselves at half scale, flying around the arena and able to **shoot** or **grapple-hook** onto living worms. Ghost mode is the primary post-death experience; there is no straight "respawn the worm" path during an active round.

### Ghost Character

- Built from the player's actual Roblox avatar via `Players:CreateHumanoidModelFromUserId`, scaled to `AvatarScale = 0.5` via `HumanoidDescription`
- All BaseParts get `Transparency ≥ 0.45` and `CanCollide = false` (except HRP)
- Head gets a `PointLight` (team-color or ghostly-blue)
- Wispy `ParticleEmitter` trails from the HRP
- Tagged with attributes `IsGhost = true` and `GhostOwner = playerName` for weapon hit-detection
- WalkSpeed / JumpPower controlled by `WormConfig.Ghost.WalkSpeed = 24` / `JumpPower = 30`
- If avatar load fails, a minimal neon fallback ghost is built

### Ghost Controls

| Input | Action |
|---|---|
| **Left-click / RT** | Fire currently-equipped weapon |
| **Right-click / LT** | Grapple (worm first, else ground) |
| **Space / B** | Detach grapple |
| **WASD** | Fly |

There is no slot / weapon-switching on the ghost HUD; the equipped weapon is assigned on spawn (always `Blaster`) and swapped by picking up weapon pickups.

### Knockoff

Weapons can knock ghosts off a worm they're riding. `WeaponService` fires `KnockoffGhost` on the ghost, which applies a `KnockbackForce = 50` impulse and stuns the ghost (no walk/jump) for `KnockoffStunDuration = 1.5` s. The shooter is credited with a **Ghost Kill** on the leaderboard.

### Rider Tracking

Ghosts that grapple onto a worm are tracked in `_ghostRiders[wormName] = { [player] = true }`. Each ride's duration is accumulated in `_totalRideTimes[player]` and submitted to the `RideTime` leaderboard when the ride ends. Riders give the host worm a **speed boost** (`RiderSpeedBoostPerGhost = +15%` per ghost, capped at `MaxRiderSpeedBoost = 2×`).

### Ghost Eating

If a worm head touches a ghost, the worm eats it: `EatValue = 3` segments gained, ghost respawns after `RespawnDelay = 5` s.

## Grapple System

Two distinct grapples share the `WormConfig.Grapple` config (`Range = 80`, `PullSpeed = 100`, `PullDuration = 0.6`, `Cooldown = 2`).

### Ground Grapple (alive worms)

- **Input:** right-click, `E`, or gamepad `ButtonX` while alive and not in ghost mode
- Client raycasts the mouse/touch through the camera onto the worm's horizontal plane, picks a ground spot within `Range`
- Client sends `GrappleGround(targetX, targetZ)`; server validates state, range, and cooldown
- The worm is **lerped** toward the target over `PullDuration` at `PullSpeed`
- A blue anchor Part + Beam between the worm head and target is spawned locally for visual feedback
- Target Y uses `getSmoothSurfaceY` so the hook hits the interpolated surface

### Ghost Grapple (riding worms)

- **Input:** right-click / LT in ghost mode
- State machine: `IDLE → PULLING → RIDING → IDLE`
- **Target worm first**: client finds a worm head under the cursor with a screen-space check; if none, falls back to **ground grapple** (raycast terrain)
- `PULLING`: client lerps the ghost's position toward the target each frame
- `RIDING`: ghost welds onto the target worm; server is notified via `GrappleAttached(wormName)` so ride-tracking and the rider speed boost kick in. Detach via `Space`/`B`, death, or host worm disappearing

## Weapons (Ghost Mode)

Defined in `src/ReplicatedStorage/Shared/WeaponConfig.luau`. Ghosts are assigned `Blaster` on spawn; other weapons are obtained from pickups.

| Weapon | Type | Damage | Ammo | Reload | RoF | Notable |
|---|---|---|---|---|---|---|
| **Blaster** | Hitscan | 3 (1 seg) | 10 | 1.6s | 2/s | Reliable single-target |
| **RapidFire** | Hitscan | 1 chip | 24 | 3.0s | 7/s | 45-stud range; 3 hits to down a segment |
| **HighVoltage** | Hitscan pierce | 5 | 5 | 2.8s | 0.67/s | Pierces through 3 extra segments |
| **Grenade** | Projectile | 4 base | 3 | 3.2s | 1/s | Bouncy (5 bounces, 0.8 decay), 12-stud explosion, 3s fuse |
| **PowerShot** | Chargeable projectile | 3–15 | 3 | 3.2s | 0.5/s | Hold to charge up to 2s; scales damage, size, explosion radius; slower at max charge |
| **Cluster** | Projectile split | 3 per bomblet | 2 | 3.5s | 0.5/s | High arc; splits into 5 bomblets in a 34° cone |
| **Mine** | Proximity projectile | 6 | 2 | 3.5s | 1/s | Short underhand toss; 0.6s arm time, 5-stud trigger, 30s lifetime |

### Damage Model

Segments have `SegmentHP = 3`. Weapon `Damage` is **HP damage**, not segment count. When a segment's HP reaches 0 it is removed and damage rolls to the next segment. Explosions apply damage to every segment in radius.

### Server Authority

Hit-scan weapons: server raycasts from ghost origin along fire direction, checks for `IsGhost`/worm tags, applies damage. Projectiles: server owns the simulation data (no per-frame part move on server); the client receives spawn/explode events and renders a local visual. `HitConfirmed` signal replies to the shooter with damage dealt.

### Charging (PowerShot)

Client holds LMB, server records `_chargeStarts[player]`. `ChargeStarted` is fired to the client for HUD feedback. On release, charge alpha = `(elapsed / ChargeTime)` linearly interpolates damage/speed/size/explosion radius between Min and Max values.

### Reload

Client presses `R` (or implicit on empty-shoot). Server sets `_reloadingUntil[player] = os.clock() + reloadTime`; client shows the reload bar. Ammo refills to max on completion.

### Weapon Pickups

`WeaponService` spawns weapon pickups on the map every `PICKUP_SPAWN_MIN..PICKUP_SPAWN_MAX = 10..15` seconds, up to `PICKUP_MAX_ON_MAP = 10`. Each pickup is a coloured neon Part with a pillar of light. Ghosts collect them by touching within `PICKUP_COLLECT_RADIUS = 6`. Client signals: `WeaponPickupSpawned / Collected / Despawned`.

## Team Mode

Controlled by `WormConfig.TeamModeEnabled` (always `true` in Worm King).

- **Teams:** Red, Blue, Green (3 teams — see [Worm King Mode](#worm-king-mode))
- **Team size:** balanced — every player/bot is load-balanced into the smallest team on match start
- **Assignment:** Automatic — new joiners assigned to the smallest team
- **Collision skip:** Teammates cannot kill each other and **their bodies pass through** (checked via `TeamService:AreTeammates`)
- **Team scores:** Crown-carry seconds + (legacy) sum of member segment counts
- **Ghost colour:** Ghosts inherit their team colour (visible, not invisible)
- **Round end:** See the three Worm King win conditions above

### Client Signals

- `TeamAssigned(player, teamIndex, teamName, teamColor)` — player assigned
- `TeamsUpdated(teams)` — team roster changed

## Bot System

### Population

BotService maintains a target total worm count (players + bots). Every few seconds it checks the count and spawns bots to fill empty slots. Bots pick names from a pool of 20 (Slinky, Noodle, Zigzag, etc.) and get random colors.

### Bot Model

Each bot is a `Model` with:
- `HumanoidRootPart` (invisible, anchored)
- `WormHead` (Roblox head mesh + face decal + name BillboardGui)
- `WormSegments` folder with ball Parts

Bots register with WormService via `RegisterBot()` so they appear in collision checks and the leaderboard. Bot data uses the same `HeadPosition` / `SegmentPositions` cache as player worms.

### AI Decision Priority

Each Heartbeat, bots evaluate these behaviors in order (first match wins):

1. **Shrink zone avoidance** — If within 50 studs of zone edge, steer toward center. Boost if within 20 studs.
2. **Wall avoidance** — If within 50 studs of arena wall, steer away.
3. **Flee** — If a larger worm is within 20 studs, run the opposite direction (may boost).
4. **Chase** — If a smaller worm (<70% of bot's size) is within 15 studs, chase it.
5. **Power-up pursuit** — If a power-up is within 20 studs, steer toward it.
6. **Food seeking** — If food is within 30 studs, steer toward the nearest piece.
7. **Random wander** — Change direction every 1–3 seconds. 10% chance to boost for 0.5–2 seconds.

### Bot Lifecycle

- Bots eat food (respecting `FoodValue`)
- Bots collect power-ups and receive their effects
- Bots die from collisions, walls, and shrink zone — same rules as players
- On death: 70% of segments scatter as food at segment positions, bot is unregistered and destroyed
- Dead bot names return to the pool; new bots spawn to maintain population
- Bots do **not** enter ghost mode

## UI (WormUIController)

All UI is built in a single `ScreenGui` named `WormUI` with `ResetOnSpawn = false`.

### HUD Elements

All top-row elements apply `GuiService:GetGuiInset().Y` as an extra vertical offset so they clear the iPhone/Android notch + Roblox topbar when `IgnoreGuiInset = true`. Wide banners use `UISizeConstraint` to cap at their design width on tablets while shrinking to 90–95% on narrow phones.

| Element | Position | Description |
|---|---|---|
| **Segment counter** | Top center | "Segments: N" in a rounded dark box |
| **Match timer** | Top left | Large `M:SS` clock for Worm King match duration (red <60 s, flashing <10 s, red border during Lockdown) |
| **Team score HUD** | Top center, below counter | 3 coloured chips showing per-team Crown-carry score + "First to N" caption |
| **Crown carrier banner** | Top center, below score HUD | "★ YOU HAVE THE CROWN ★" when local, otherwise "NAME has the Crown" in team colour |
| **Lockdown banner** | Top center | Red warning bar "⚠ LOCKDOWN — LAST TEAM STANDING WINS ⚠" during final-minute lockdown |
| **Ghost HUD** (ghost only) | Top center, below carrier banner | Marks counter + Respawn button (48pt tall on touch) + status line (shown on insufficient funds / respawn failure) |
| **Coin display** | Top right | Current coin balance; briefly highlights on award |
| **Power-up display** | Below counter | Active power-up name + countdown, coloured by type |
| **Leaderboard** | Top left | Top 10 worms by segment count (player highlighted). Updates every 2 s. Includes bots |
| **Kill feed** | Top right | "X ate Y", "X hit the wall", "X shot Y's ghost" — max 5, fade after 4 s |
| **Minimap** | Bottom right | 140×140 dark box, top-down arena overview; see below |
| **Weapon HUD** (ghost only) | Bottom center | Weapon name, ammo dots, reload progress bar, charge bar (PowerShot) |
| **Toolbar** (ghost only) | Bottom center | Slot 1 (Grapple) + Slot 2 (Weapon) — purely visual; LMB = shoot, RMB = grapple are always both bound |
| **Grapple hint** | Near crosshair | "RMB to hook" / "Tap to hook" / "LT to hook" prompt |
| **Boost button** | Bottom right (touch only) | Circular orange button, 100×100 |
| **Grapple button** | Bottom right, left of Boost (touch only) | Circular blue button, 90×90 — dispatches ground or ghost grapple based on state |
| **Death screen** | Full screen | "YOU DIED" + killer name + countdown to ghost spawn |
| **Zone warning** | Upper center | Red flashing text, auto-hides after 3 s (also used by SandTideService TideWarning) |
| **Round scoreboard** | Full screen | Placement list + coin reward after round end |
| **Daily reward popup** | Center | Streak count + coin amount on first login of the day |

### Minimap

- **Local player:** Green triangle arrow that rotates to show heading. Uses camera-relative axes while alive, fixed world axes in ghost mode. Rotation via `math.deg(math.atan2(dir.X, -dir.Z))`.
- **Other players:** Small red dots.
- **Power-ups:** Small yellow dots.
- **Weapon pickups:** Coloured pickup-type dots.
- **Shrink zone:** Red circle outline that shrinks proportionally (disabled during Worm King mode).
- **Sand-tide triangle:** Three thin line segments showing the current scaled safe zone (Worm King only).
- **Crown marker:** Gold dot; position read directly from `workspace.Crown.PrimaryPart.Position` (the Crown Part auto-replicates at 10 Hz, so no dedicated position signal is needed).
- **Compass "N"** is pinned to the top of the frame for orientation.

## Camera

The camera is set to `Scriptable` mode. In alive mode it follows the player's `HumanoidRootPart` from a fixed overhead angle. In ghost mode it switches to a first/third-person chase on the ghost avatar.

### Dynamic Zoom (alive)

Camera height scales with segment count so the full worm stays visible:

```
cameraHeight = 40 + (segments * 0.5)
```

- **Base height:** 40 studs
- **Growth rate:** 0.5 studs per segment
- **At 50 segments:** 65 studs high
- **At 100 segments:** 90 studs high

### Angle

Looks down at 70° from horizontal with a slight forward offset (`cos(70) * 0.3`) so the worm sits slightly below screen center. Always pointed at the head position.

### Input → Direction

The direction vector is built by raycasting from the screen position (mouse/touch) through the camera onto the worm's horizontal plane (`Y = hrp.Position.Y`). The flat XZ delta from HRP to the hit point is normalised and sent to the server (throttled — see [Networking & Replication](#networking--replication)).
