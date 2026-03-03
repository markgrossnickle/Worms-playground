# Worms Playground - Game Documentation

A multiplayer snake/worms game built on Roblox using the Knit framework. Players control worms that slither around a 2000x2000 arena, eating food to grow longer, boosting for speed at the cost of segments, and competing against other players and AI bots. Features include power-ups, a battle royale shrink zone, and an optional team mode.

## Game Mechanics

### Movement

Worms move continuously in the direction of the player's cursor (or touch position on mobile). The server moves each worm's `HumanoidRootPart` by setting its `CFrame` every Heartbeat frame. All physics is disabled (HRP is anchored, WalkSpeed/JumpPower zeroed).

- **Base speed:** 30 studs/s
- **Boost speed:** 60 studs/s (hold Shift, left mouse, or tap the mobile boost button)
- **Boost cost:** 0.5 segments/s (stops at 5 minimum segments)

Direction is sent from the client via `WormService.Client:SetDirection(dirX, dirZ)` each render frame. The server normalizes it and stores it in `WormData.Direction`.

### Segment Following (Position History Buffer)

Segments don't follow the head with physics. Instead, the server records the head's position every 0.5 studs into a ring buffer (`PositionHistory`). Each segment reads the position that was `index * ENTRIES_PER_SEGMENT` entries behind the current head position. Old entries are trimmed as the worm moves forward.

- `MIN_RECORD_DISTANCE = 0.5` studs between recorded positions
- `ENTRIES_PER_SEGMENT = ceil(SegmentSpacing / MIN_RECORD_DISTANCE) = 6` entries per segment gap
- `SegmentSpacing = 3` studs between segment centers
- `SegmentSize = 2.5` studs (ball diameter)

### Eating and Growth

Food is collected when a worm's head comes within `CollisionRadius + 1 = 3` studs. Each food item has a `FoodValue` attribute determining how many segments it adds (see [Food System](#food-system)). When segments are added, new `Part` instances are created in the `WormSegments` folder and the position history buffer is extended.

### Collision and Death

A worm dies when its head touches another worm's body segment (within `CollisionRadius * 2 = 4` studs). On death:

1. Active power-ups are cleared
2. 70% of segments scatter as collectible food at actual segment positions
3. The worm's character visuals are destroyed
4. The player respawns after 3 seconds at a random position

Worms also die if they hit the arena walls or exit the shrink zone.

### Player Head

Player worms use the actual Roblox avatar `Head` as the worm head. The setup process: breaks all `Motor6D` joints connecting to the Head, anchors it, resizes it to 3 studs, renames it to `WormHead`, and hides all other character parts (body, accessories, clothing) by setting `Transparency = 1`. Face decals on the Head remain visible.

## Architecture

Built on the **Knit** framework (v1.7.0). Services run on the server, controllers on the client. Communication uses Knit signals (auto-injected `player` parameter on client-to-server calls).

### Startup Flow

1. **Server:** `Main.server.luau` -> `Server:Start()` -> `Knit.AddServices()` -> `Knit:Start()` -> load components -> set `ServerStatus = "Started"`
2. **Client:** `ClientEntry.server.luau` -> waits for `ServerStatus == "Started"` -> `Knit.AddControllers()` -> `Knit:Start()` -> load components

### Server Services

| Service | File | Purpose |
|---|---|---|
| **WormService** | `Services/WormService/init.luau` | Core game logic: arena creation, food spawning, worm lifecycle, movement, collision detection, game loop |
| **BotService** | `Services/BotService/init.luau` | AI bot worms: spawning, decision-making, movement, food/power-up collection |
| **PowerUpService** | `Services/PowerUpService/init.luau` | Power-up spawning, collection, effect application, expiration |
| **ShrinkZoneService** | `Services/ShrinkZoneService/init.luau` | Battle royale shrink zone: ring visual, radius calculation, boundary checks |
| **TeamService** | `Services/TeamService/init.luau` | Optional team mode: assignment, teammate collision skip, team scores |
| **PlayerDataService** | `Services/PlayerDataService/` | Profile-based persistence using ProfileStore |
| **LeaderboardService** | `Services/LeaderboardService/` | OrderedDataStore leaderboards with caching |
| **BadgeService** | `Services/BadgeService.luau` | Roblox badge management |
| **MTAnalyticsService** | `Services/MTAnalyticsService.luau` | Analytics wrapper with rate limiting |
| **CmdrService** | `Services/CmdrService/` | Admin command framework (F2 to activate) |
| **MilestoneService** | `Services/MilestoneService/` | One-time achievement tracking |

### Client Controllers

| Controller | File | Purpose |
|---|---|---|
| **WormController** | `Controllers/WormController.luau` | Input handling (mouse/touch), camera control, direction/boost sending to server, signal relay to UI |
| **WormUIController** | `Controllers/WormUIController.luau` | Full game HUD: segment counter, leaderboard, minimap, kill feed, death screen, power-up display, zone warnings |

### Inter-Service Communication

Services reference each other via `require()` in `KnitStart` (not `KnitInit`) to avoid circular dependency issues:

```
WormService -> PowerUpService, ShrinkZoneService, TeamService
BotService  -> WormService, PowerUpService, ShrinkZoneService, TeamService
PowerUpService -> WormService
```

WormService exposes bot integration methods (`RegisterBot`, `UnregisterBot`, `UpdateBotSegments`, `ConsumeFood`, `DropFoodFromModel`, `FireBotDeath`) that BotService calls directly.

## Key Files

```
src/
  ReplicatedStorage/
    Shared/
      WormConfig.luau                     -- All game constants (speeds, sizes, power-ups, timers)
      Enums/WormState.luau                -- "Alive" | "Dead" | "Spectating"
    Client/
      init.luau                           -- Client bootstrap (waits for server, starts Knit)
      Controllers/
        WormController.luau               -- Input, camera, server signal relay (~300 lines)
        WormUIController.luau             -- Full game HUD (~750 lines)
  ServerScriptService/
    Server/
      init.luau                           -- Server bootstrap (loads services, starts Knit)
      Main.server.luau                    -- Entry point
      Services/
        WormService/init.luau             -- Core gameplay (~980 lines)
        BotService/init.luau              -- AI bots (~785 lines)
        PowerUpService/init.luau          -- Power-up system (~330 lines)
        ShrinkZoneService/init.luau       -- Shrink zone (~140 lines)
        TeamService/init.luau             -- Team mode (~220 lines)
```

## Food System

### Spawning

Food spawns continuously to maintain `MaxFoodOnMap = 800` items on the arena (up to 10 per frame). Each food item is a neon `Ball` Part placed at a random arena position.

### Size Tiers

Food comes in three sizes, selected by weighted random:

| Tier | Size (studs) | Segments Added | Spawn Weight |
|---|---|---|---|
| Small | 1.2 | +1 | 60% |
| Medium | 2.0 | +2 | 30% |
| Large | 3.0 | +4 | 10% |

The value is stored as a `FoodValue` attribute on each food Part. Colors are fully randomized (random hue, high saturation).

### Death Scatter

When a worm dies, 70% of its segments become collectible food scattered at the **actual segment positions** (with a small random offset of +/-3 studs). If there are more food items to drop than segment positions, extras scatter randomly around the head position. All death-dropped food has value 1.

### Double-Consumption Guard

A `Consumed` attribute is set on food before destruction to prevent multiple worms from eating the same food in the same Heartbeat frame.

## Power-Up System

### Types

| Power-Up | Color | Duration | Effect |
|---|---|---|---|
| **SPEED** | Cyan | 3s | 2x speed multiplier |
| **MAGNET** | Pink | 5s | Pulls food within 15 studs toward the head |
| **GHOST** | Light blue | 3s | Immune to all worm-vs-worm collisions |
| **SHIELD** | Yellow | Until consumed | Blocks one lethal collision, then expires |
| **SIZE_BOMB** | Orange | Instant | Immediately adds 5 segments |

### Spawning and Collection

- Spawn every 10-15 seconds (random interval), up to 4 on the map at once
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
- `GetSpeedMultiplier(ownerName)` — returns 2 or 1
- `GetMagnetRange(ownerName)` — returns 15 or 0
- `IsGhost(ownerName)` — returns true/false
- `ConsumeShield(ownerName)` — returns true if shield was consumed
- `GetNearestPowerUp(pos, range)` — used by bot AI to find nearby power-ups

## Battle Royale (Shrink Zone)

### Timeline

| Time | Event |
|---|---|
| 0:00 | Game starts, zone radius = 1000 (full arena) |
| 0:50 | Warning: "Zone shrinking in 10 seconds!" |
| 1:00 | Zone begins shrinking (linear interpolation) |
| 2:30 | Warning: "Zone closing in 30 seconds!" |
| 3:00 | Zone radius reaches 0, arena fully closed |

### Ring Border Visual

A ring of 64 neon-red Parts (15 studs tall, 40% transparent) forms the zone boundary. Each Part is a wall section positioned along the circle's circumference. The ring updates every Heartbeat frame to match the current radius.

### Zone Enforcement

Both players and bots are killed instantly if their head position is outside the current zone radius (`Vector2 distance from origin > currentRadius`). Players check in `WormService:_checkBounds()`, bots check in `BotService:_checkBotCollisions()`.

### Client Updates

Zone radius and elapsed time are sent to all clients at 2Hz (every 0.5s) via `ZoneUpdate` signal. The minimap shows a red circle overlay that shrinks to match. A game timer displays elapsed time in `M:SS` format.

## Team Mode

Controlled by `WormConfig.TeamModeEnabled` (default: `false`).

### Configuration

- **Team size:** 2 players per team
- **Teams:** Red, Blue, Green, Yellow (4 teams, up to 8 players)
- **Assignment:** Automatic load-balancing — new players/bots join the team with fewest members

### Collision Skip

Teammates cannot kill each other. Both `WormService:_checkWormCollisions()` and `BotService:_checkBotCollisions()` call `TeamService:AreTeammates(name1, name2)` and skip collision checks for teammates.

### Team Scores

`TeamService:GetTeamScores(wormSegments)` sums all team members' segment counts. Teams are ranked by total segments.

### Client Signals

- `TeamAssigned(player, teamIndex, teamName, teamColor)` — player assigned to a team
- `TeamsUpdated(teams)` — team roster changed

## Bot System

### Population

BotService maintains a target of **16 total worms** (players + bots). Every 2 seconds it checks the count and spawns bots to fill empty slots. Bots pick names from a pool of 20 (Slinky, Noodle, Zigzag, etc.) and get random colors.

### Bot Model

Each bot is a `Model` with:
- `HumanoidRootPart` (invisible, anchored)
- `WormHead` (Roblox head mesh + face decal + name BillboardGui)
- `WormSegments` folder with ball Parts

Bots register with WormService via `RegisterBot()` so they appear in collision checks and the leaderboard.

### AI Decision Priority

Each Heartbeat, bots evaluate these behaviors in order (first match wins):

1. **Shrink zone avoidance** — If within 50 studs of zone edge, steer toward center. Boost if within 20 studs.
2. **Wall avoidance** — If within 50 studs of arena wall, steer away.
3. **Flee** — If a larger worm is within 20 studs, run the opposite direction (may boost).
4. **Chase** — If a smaller worm (< 70% of bot's size) is within 15 studs, chase it.
5. **Power-up pursuit** — If a power-up is within 20 studs, steer toward it.
6. **Food seeking** — If food is within 30 studs, steer toward the nearest piece.
7. **Random wander** — Change direction every 1-3 seconds. 10% chance to boost for 0.5-2 seconds.

### Bot Lifecycle

- Bots eat food (respecting the `FoodValue` attribute for different sizes)
- Bots collect power-ups and receive their effects (speed, magnet, ghost, shield, size bomb)
- Bots die from collisions, walls, and shrink zone — same rules as players
- On death: 70% of segments scatter as food at segment positions, bot is unregistered and destroyed
- Dead bot names return to the pool; new bots spawn to maintain population

## UI (WormUIController)

All UI is built in a single `ScreenGui` named `WormUI` with `ResetOnSpawn = false`.

### HUD Elements

| Element | Position | Description |
|---|---|---|
| **Segment counter** | Top center | "Segments: N" in a rounded dark box |
| **Game timer** | Right of counter | Elapsed time as `M:SS` |
| **Power-up display** | Below counter | Active power-up name + countdown timer, colored by type |
| **Leaderboard** | Top left | Top 10 worms ranked by segment count (local player highlighted yellow). Updates every 2s. Includes bots. |
| **Kill feed** | Top right | "X ate Y" or "X hit the wall" entries, max 5, fade after 4s |
| **Minimap** | Bottom right | 140x140 dark box showing arena overview |
| **Boost button** | Bottom right (touch only) | Circular orange button, visible only on touch devices |
| **Death screen** | Full screen | "YOU DIED" + killer name + respawn countdown, semi-transparent overlay |
| **Zone warning** | Upper center | Red text flashing zone warnings, auto-hides after 3s |

### Minimap

- **Local player:** Green triangle (`▲`) that rotates to show heading direction. Rotation is calculated as `math.deg(math.atan2(dir.X, -dir.Z))` from `WormController._direction`.
- **Other players:** Small red dots (6x6 pixels).
- **Power-ups:** Small yellow dots (5x5 pixels).
- **Shrink zone:** Red circle outline that shrinks proportionally to the current zone radius.

The minimap updates every 2 seconds (same interval as leaderboard).

## Camera

The camera is set to `Scriptable` mode. It follows the player's `HumanoidRootPart` from a fixed overhead angle.

### Dynamic Zoom

Camera height scales with segment count so the full worm stays visible:

```
cameraHeight = 40 + (segments * 0.5)
```

- **Base height:** 40 studs (at 3 segments, camera is at 41.5 studs)
- **Growth rate:** 0.5 studs per segment
- **At 50 segments:** 65 studs high
- **At 100 segments:** 90 studs high

### Angle

The camera looks down at 70 degrees from horizontal, with a slight forward offset (`cos(70) * 0.3`) so the worm is centered slightly below screen center. The camera always points at the head position.

### Input

Direction is determined by raycasting from the screen position (mouse or touch) through the camera onto the ground plane (Y = 1). The direction vector from the HRP to the hit point becomes the worm's movement direction, sent to the server every render frame.
