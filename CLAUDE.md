# CLAUDE.md - Worms Playground

See [GAME.md](GAME.md) for game mechanics, architecture, and design details.

This is a MindTrust Roblox project. It uses the Knit framework for service-oriented architecture.

## Project Structure

```
src/
  ReplicatedStorage/
    Client/                    # Client-side entry point and initialization
      ClientEntry.server.luau  # Entry script (RunContext: Client via metadata)
      init.luau                # Client bootstrap — waits for server, loads controllers/components
      Controllers/             # Knit controllers (client-side singletons)
      Components/              # Client-only components
    Shared/                    # Code shared between server and client
      Components/              # Shared components (loaded by both sides)
      Configs/                 # Configuration modules (LeaderboardConfig, etc.)
      Enums/                   # Enum definitions
      Environment.luau         # Maps game IDs to environments (Studio/Dev/Staging/Review/Production)
      CmdrHelper.luau          # Cmdr permission checks and registration helper
      GameVersion.luau         # Reads version from GameVersion.txt
    Packages/                  # Wally shared packages (gitignored, auto-installed)
  ServerScriptService/
    Server/
      Main.server.luau         # Server entry point — calls Server:Main()
      init.luau                # Server bootstrap — loads services, then components
      Services/                # Knit services (server-side singletons)
      Components/              # Server-only components
    ServerPackages/            # Wally server packages (gitignored, auto-installed)
```

## Knit Framework

We always use the **Knit** framework (sleitnick/knit@1.7.0). Knit provides a service-oriented architecture with clear client/server separation.

### Services (Server Side)

Services are server-side singletons created with `Knit.CreateService`. They live in `src/ServerScriptService/Server/Services/`.

```lua
local MyService = Knit.CreateService({
    Name = "MyService",
    Client = {},  -- Table for methods/signals exposed to clients
})

function MyService:KnitInit()
    -- Called first. Safe to reference other services, but do NOT call their methods yet.
end

function MyService:KnitStart()
    -- Called after ALL KnitInit methods finish. Safe to use other services fully.
end
```

All services are loaded via `Knit.AddServices(script.Services)` in the server bootstrap.

### Controllers (Client Side)

Controllers are client-side singletons created with `Knit.CreateController`. They live in `src/ReplicatedStorage/Client/Controllers/`.

```lua
local MyController = Knit.CreateController({
    Name = "MyController",
})

function MyController:KnitInit()
    -- Same rules as services: reference only, don't call methods on other controllers.
end

function MyController:KnitStart()
    -- Safe to use other controllers and call server services.
    local MyService = Knit.GetService("MyService")
end
```

All controllers are loaded via `Knit.AddControllers(script.Controllers)` in the client bootstrap.

### Components (Both Sides)

Components use the Component library (sleitnick/component@2.4.8) to bind behavior to instances via CollectionService tags. They work on **both server and client**.

- **Server components:** `src/ServerScriptService/Server/Components/`
- **Client components:** `src/ReplicatedStorage/Client/Components/` (or inside a Controller's Components folder)
- **Shared components:** `src/ReplicatedStorage/Shared/Components/`

Component modules must have names ending in `Component` (e.g., `HealthComponent.luau`). The bootstrap code auto-discovers them by checking `instance.Name:sub(#instance.Name - 8) == "Component"`.

```lua
local Component = require(ReplicatedStorage.Packages.Component)

local HealthComponent = Component.new({
    Tag = "Health",
    Ancestors = { workspace },
})

function HealthComponent:Construct()
    -- Initialize state. self.Instance is the tagged Roblox instance.
end

function HealthComponent:Start()
    -- Component is active. Safe to get sibling components.
end

function HealthComponent:Stop()
    -- Cleanup when tag is removed or instance leaves ancestors.
end
```

Components are loaded **after** Knit starts (via Promise chain in both server and client bootstrap).

### The Player Parameter in Knit

This is critical to understand. The `player` argument is handled differently depending on which side initiates the call:

**Client-to-server calls — `player` is auto-injected:**
When a client calls a method on a service's `Client` table, Knit automatically passes the calling player as the first argument on the server side. The client does NOT pass `player`.

```lua
-- SERVER: define with `player` as first param
function MyService.Client:GetData(player)
    return self.Server:_getData(player)  -- self.Server refers to the service root
end

-- CLIENT: call WITHOUT `player` — Knit injects it
local MyService = Knit.GetService("MyService")
MyService:GetData()  -- player is NOT passed here
```

**Client-to-server signals — `player` is auto-injected:**
```lua
-- SERVER: listener receives `player` automatically
self.Client.SomeSignal:Connect(function(player, data)
    -- player is the client who fired
end)

-- CLIENT: fires WITHOUT `player`
MyService.SomeSignal:Fire(data)
```

**Server-to-client signals — `player` must be passed explicitly:**
```lua
-- SERVER: must specify which player to send to
self.Client.PointsChanged:Fire(player, newPoints)

-- CLIENT: receives only the data, no player
MyService.PointsChanged:Connect(function(newPoints) end)
```

**Internal service methods — no auto-injection:**
Regular methods on the service (not on `Client`) are normal Lua methods. You pass `player` explicitly when needed.

```lua
function MyService:_getData(player)
    return self.data[player]  -- caller must pass player
end
```

**Summary:**
| Direction | `player` auto-injected? | Who passes it? |
|---|---|---|
| Client calls `Service.Client:Method(player, ...)` | Yes | Knit injects it |
| Client fires `Service.Client.Signal` | Yes | Knit injects it |
| Server fires `self.Client.Signal:Fire(player, ...)` | No | You pass it explicitly |
| Server calls internal `Service:Method(player, ...)` | No | You pass it explicitly |

### Knit `self.Server` and `self.Client` References

Inside a `Client` method, `self.Server` refers back to the root service table — use it to delegate to internal service logic. From the service root, `self.Client` refers to the Client table — use it to fire signals or set properties for clients.

## Promise Handling (IMPORTANT)

Knit service methods called from the client return **Promises**, not direct values. You MUST handle them.

### Rules
- **Always await or chain** service method return values: use `:andThen()`, `:await()`, or `:expect()`
- **Never assign a Promise to a variable** expecting a plain value (e.g., `local data = Service:GetData()` is WRONG — use `local ok, data = Service:GetData():await()`)
- **Fire-and-forget** is acceptable ONLY for void methods (signals, events). If the method returns data or can fail, handle the promise
- **Chain `:catch()`** with `:andThen()` to handle errors — never silently drop promise rejections
- **Wrap in `task.spawn()`** when calling promise-returning methods inside event connections where you don't want to block

### Correct Patterns
```lua
-- Blocking await (returns success, value)
local ok, data = MyService:GetData():await()

-- Promise chaining
MyService:DoThing():andThen(function(result)
    -- handle result
end):catch(function(err)
    warn("Failed:", err)
end)

-- Synchronous extraction (throws on failure)
local profile = PlayerDataService:WaitForProfile(player):expect()

-- Fire-and-forget in event connection (wrap in task.spawn)
Players.PlayerAdded:Connect(function(player)
    task.spawn(function()
        PlayerDataService:WaitForProfile(player)
            :andThen(function() --[[ ... ]] end)
            :catch(function(err) warn(err) end)
    end)
end)
```

### Anti-Patterns (DO NOT DO)
```lua
-- BAD: Assigns Promise object to variable instead of awaited value
local modes = TeamService:GetGameModes()

-- BAD: Ignores returned Promise from method that can fail
PlayerBadgeService:AwardBadge(player, badgeName)

-- BAD: No error handling on chain
MyService:RiskyOperation():andThen(function() end)  -- missing :catch()
```

## Startup Flow

1. **Server:** `Main.server.luau` → `Server:Main()` → `Knit.AddServices()` → `Knit:Start()` → load server components → load shared components → set `ServerStatus = "Started"`
2. **Client:** `ClientEntry.server.luau` (RunContext: Client) → waits for `ServerStatus == "Started"` → `Knit.AddControllers()` → `Knit:Start()` → load client components → load shared components

If the server crashes during startup, clients are kicked with an error message.

## Toolchain

| Tool | Version | Purpose |
|---|---|---|
| Rojo | 7.6.1 | Syncs code to Roblox Studio (port 34872) |
| Wally | 0.3.2 | Package manager |
| StyLua | 2.3.0 | Code formatter |
| Selene | 0.29.0 | Linter |
| wally-package-types | 1.6.2 | Fixes Luau types for Wally packages |

Managed via **aftman** (`aftman.toml`).

## Code Style

- **Language:** Luau (strict mode preferred: `--!strict`)
- **Formatter:** StyLua — tabs (width 4), 120 column width, double quotes, Unix line endings
- **Linter:** Selene with `roblox` standard (excludes `Packages/*` and `ServerPackages/*`)
- **Quote style:** Double quotes preferred
- **Call parentheses:** Always use parentheses

## Dependencies (wally.toml)

**Shared:** Knit 1.7.0, Promise 4.0.0, TableUtil 1.2.1, Signal 2.0.3, Component 2.4.8, Logging 0.3.0, Trove 1.5.1
**Server-only:** ProfileStore 1.0.3, Cmdr 1.12.0

## Development Commands

```bash
aftman install              # Install toolchain
wally install               # Install packages (or: make wally-install)
make wally-package-types    # Fix Luau types for Wally packages
rojo serve                  # Start Rojo sync server (port 34872)
stylua .                    # Format code
selene .                    # Lint code
```

## Environment System

`Environment.luau` maps `game.GameId` to an environment enum. Update the `GameIds` table with real game IDs when forking this template. Studio is always detected automatically. Default for unknown IDs is `Production`.

## Cmdr (Admin Commands)

Cmdr is available in Studio always, in non-production environments always, and in Production/Review only for group members with rank >= 252 (GROUP_ID: 361311171). Activation key: F2. Custom commands go in a `Commands/` folder under your service or controller.

## Key Services

- **PlayerDataService** — Profile-based persistence using ProfileStore. Supports DataStorePath pattern for typed path accessors with change signals.
- **BadgeService** — Roblox badge management (award, check, bulk check).
- **MTAnalyticsService** — Wrapper around Roblox AnalyticsService with rate limiting.
- **CmdrService** — Admin command framework initialization and registration.
- **LeaderboardService** — OrderedDataStore-backed leaderboards with caching, budget-aware queue processing, and automatic period rotation. Configure in `Shared/Configs/LeaderboardConfig.luau`.
- **MilestoneService** — Tracks one-time player achievements using DataStorePath pattern. Wire to game events in KnitStart.

## Networking & Replication (CRITICAL)

**Never move many objects server-side every frame.** Server-side `PivotTo` / `CFrame =` on anchored parts replicates every property change to every client. With 100 enemies × 25 parts each, that's ~150,000 property updates/second — smooth on WiFi, unplayable on mobile data.

### The Pattern: "Server Brain, Client Body"

| Layer | Runs On | Responsibility |
|---|---|---|
| **AI decisions** | Server | Who to target, where to move, when to attack |
| **State snapshots** | Server → Client | Compressed position/rotation at **10Hz** (not 60Hz) |
| **Visual rendering** | Client | Interpolate between snapshots, animate body parts locally |
| **Hit validation** | Server | Verify damage claims from clients |

### Implementation Rules

1. **Server AI loop** (Heartbeat) computes positions in a data table — does NOT call `PivotTo` or set `CFrame` directly
2. **Every ~6 Heartbeats** (10Hz), server fires a single batched RemoteEvent with compressed position data:
   - `Vector2int16` for XZ position (~4 bytes vs 24 for two floats)
   - `int16` for Y-rotation (multiply radians × 10, divide on client)
   - Arrays, not dictionaries (dictionaries add ~8 bytes/key overhead)
3. **Client interpolates** between snapshots using `CFrame:Lerp()` or `TweenService` — creates smooth movement despite infrequent updates
4. **Client runs animations locally** (walk cycles, wing flaps, particles) — never replicate per-part animation from server
5. **Use `workspace:BulkMoveTo()`** on the client for batch CFrame updates instead of per-model PivotTo loops (C++-optimized, avoids unnecessary Changed events)
6. **Render-throttle on low-end devices**: split creature rendering across 2-3 frames instead of updating all in one frame

### Projectiles

- **Client-side prediction**: client fires + animates bullet locally for instant feedback
- **Server validates**: server reconstructs trajectory mathematically, verifies hit position is within tolerance
- **One remote call per hit**, not per frame — minimal network traffic

### Purely Visual Modes (Viewers, Parades, Lobbies)

For modes with no gameplay consequence:
- Server spawns models and sends initial state via RemoteEvent
- **Client owns all movement and animation** — zero network traffic

### Anti-Patterns (DO NOT DO)

```lua
-- BAD: Server moves every enemy every frame via PivotTo
RunService.Heartbeat:Connect(function(dt)
    for _, enemy in enemies do
        enemy.Model:PivotTo(newCFrame)  -- bandwidth explosion
    end
end)
```

### Correct Pattern

```lua
-- SERVER: compute positions in data table, broadcast at 10Hz
local _tickCounter = 0
RunService.Heartbeat:Connect(function(dt)
    for _, enemy in enemies do
        enemy.Position = computeNewPos(enemy, dt)  -- data only, no PivotTo
    end
    _tickCounter += 1
    if _tickCounter % 6 == 0 then
        local packed = packPositions(enemies)
        EnemyService.Client.PositionUpdate:FireAll(packed)
    end
end)

-- CLIENT: interpolate + animate locally
RunService.RenderStepped:Connect(function(dt)
    for model, target in enemyTargets do
        model:PivotTo(model:GetPivot():Lerp(target, math.min(1, dt * 15)))
    end
end)
```

## Conventions

- Services go in `Services/` as a folder with `init.luau` (or as a single `.luau` file)
- Controllers go in `Controllers/` with the same structure
- Component modules must be named `*Component` (e.g., `HealthComponent.luau`)
- Use Promises (evaera/promise) for async operations
- Use Trove for cleanup/lifecycle management
- Use Signal for custom events
- Clean up player-specific data on `Players.PlayerRemoving` to prevent memory leaks
