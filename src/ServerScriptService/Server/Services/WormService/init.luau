--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local TerrainHeight = require(ReplicatedStorage.Shared.TerrainHeight)
local Enums = require(ReplicatedStorage.Shared.Enums)
local TeamBase = require(ReplicatedStorage.Shared.TeamBase)
local SpatialIndex = require(ReplicatedStorage.Shared.SpatialIndex)

type WormState = Enums.WormState
type WormData = {
	State: WormState,
	Segments: number,
	MaxSegments: number,
	Direction: Vector3, -- Target direction (set by client input)
	CurrentDirection: Vector3, -- Actual facing direction (interpolated toward Direction)
	Boosting: boolean,
	Color: Color3,
	Kills: number,
	PositionHistory: { [number]: Vector3 },
	HistoryStart: number,
	HistoryEnd: number,
	LastRecordedPos: Vector3,
	SpawnTime: number,
	LerpingSegments: { [number]: { StartTime: number, StartPos: Vector3 } }?, -- segment indices currently lerping after a mid-body hit
	-- Cached position state: updated every frame as the source of truth for gameplay.
	-- Actual Part CFrames are only written at 10Hz (every 6th Heartbeat) to keep
	-- replication bandwidth bounded — see _broadcastTick.
	HeadPosition: Vector3,
	HeadDirection: Vector3,
	SegmentPositions: { [number]: Vector3 },
	-- Worm King: spawn invulnerability window. Broken by damaging others or leaving base safe zone.
	SpawnProtectionUntil: number,
}

local PowerUpService -- Set in KnitStart
local ShrinkZoneService -- Set in KnitStart
local TeamService -- Set in KnitStart
local WeaponService -- Set in KnitStart
local LeaderboardService -- Set in KnitStart
local SandTideService -- Set in KnitStart

local GHOST_FOOD_VALUE = WormConfig.Ghost.EatValue
local GHOST_RESPAWN_DELAY = WormConfig.Ghost.RespawnDelay

local HALF_ARENA = WormConfig.ArenaSize / 2
local SPAWN_GRACE_PERIOD = 3 -- seconds of zone immunity after spawning

-- Position history: record a position every MIN_RECORD_DISTANCE studs.
-- Each segment reads ENTRIES_PER_SEGMENT entries behind the head in the buffer.
local MIN_RECORD_DISTANCE = 0.5
local ENTRIES_PER_SEGMENT = math.ceil(WormConfig.SegmentSpacing / MIN_RECORD_DISTANCE)
local SEGMENT_LERP_DELAY = 0.08 -- brief pause after a hit before back segments begin sliding in

local WormService = Knit.CreateService({
	Name = "WormService",
	Client = {
		WormSpawned = Knit.CreateSignal(),
		WormDied = Knit.CreateSignal(),
		WormAte = Knit.CreateSignal(),
		FoodSpawned = Knit.CreateSignal(),
		PlayerKillsUpdated = Knit.CreateSignal(),
		GhostSpawned = Knit.CreateSignal(),
		GhostDespawned = Knit.CreateSignal(),
		GhostKnockoff = Knit.CreateSignal(), -- fired to ghost player when shot off a worm
		GhostEaten = Knit.CreateSignal(), -- fired to all clients when a ghost is eaten (position, eaterName)
		RiderAttached = Knit.CreateSignal(), -- fired to worm owner when ghost mounts
		RiderDetached = Knit.CreateSignal(), -- fired to worm owner when ghost dismounts
	},

	_worms = {} :: { [Player]: WormData },
	_troves = {} :: { [Player]: any },
	_foodFolder = nil :: Folder?,
	_wormFolder = nil :: Folder?,
	_foodCount = 0,
	_gameLoopConnection = nil :: RBXScriptConnection?,
	_botModels = {} :: { [string]: { Model: Model, Segments: number } },
	_roundActive = false,
	_ghosts = {} :: { [Player]: Model },
	_ghostHP = {} :: { [Player]: number }, -- current ghost HP per player; weapon hits deplete; ≤0 → killed + respawn after delay
	_ghostRiders = {} :: { [string]: { [Player]: boolean } }, -- wormOwnerName -> { ridingGhostPlayer -> true }
	_ghostKillCounts = {} :: { [Player]: number }, -- ghost knockoff kills per session
	_rideStartTimes = {} :: { [Player]: number }, -- os.clock() when ghost started riding
	_totalRideTimes = {} :: { [Player]: number }, -- accumulated ride seconds
	_batchSpawning = false, -- Suppress FoodSpawned signal during bulk food creation
	_broadcastTick = 0, -- Heartbeat counter; Part CFrames are written when this % 6 == 0 (10Hz at 60fps)
	-- Per-player rate-limit clocks for client RPCs that can be called at high
	-- frequency. See Client:SetDirection / Client:GrappleAttached.
	_lastDirSetTime = {} :: { [Player]: number },
	_lastGrappleAttachTime = {} :: { [Player]: number },
	-- Food-magnet de-dup table: weak-keyed so destroyed food is GC'd. Maps
	-- food Part → magnet-tick number it was last pulled in. WormService and
	-- BotService both call _tryClaimMagnetPull before writing food.Position
	-- so the same food can't be Position-replicated twice in one tick.
	_magnetClaim = setmetatable({}, { __mode = "k" }) :: any,
	-- Shared spatial grid for fast neighbor lookups. Populated each frame
	-- with every alive worm's head + segment positions. WormService and
	-- BotService both query it for collision checks and AI threat search,
	-- replacing what was previously O(N²·S) iteration each frame.
	_collisionGrid = SpatialIndex.new(30),
	-- os.clock() at last rebuild — used by RebuildCollisionGrid to dedupe
	-- when both services try to rebuild on the same frame.
	_collisionGridBuiltAt = 0,
	-- Per-frame food index. Cell size 10 (≈ max magnet range / 3) means
	-- the 9-cell neighborhood at any position covers a 30-stud radius —
	-- larger than the 25-stud MAGNET powerup range, so no in-range food
	-- is missed. Replaces O(N·F) per-frame iteration of all food per worm
	-- with O(F) build + O(k) per-worm query (typically k = 1-5).
	_foodGrid = SpatialIndex.new(10),
	_foodGridBuiltAt = 0,

	-- Signals for other services to listen to
	PlayerKilled = Signal.new(),
	PlayerDied = Signal.new(), -- Fires for ALL player deaths (name, killerName?)
	PlayerScoreChanged = Signal.new(),
})

--------------------------------------------------
-- Private helpers
--------------------------------------------------

function WormService:_randomArenaPosition(): Vector3
	-- Spawn within a circle (not square) so players don't land outside the zone
	local margin = 50
	local maxRadius = HALF_ARENA - margin
	local angle = math.random() * math.pi * 2
	local dist = math.sqrt(math.random()) * maxRadius -- sqrt for uniform distribution
	local x = math.cos(angle) * dist
	local z = math.sin(angle) * dist
	return Vector3.new(x, TerrainHeight.getSmoothSurfaceY(x, z) + WormConfig.SegmentSize / 2, z)
end

-- Distance any new spawn must keep from existing live worms (player + bot)
-- so multiple players spawning the same frame don't pile on top of each other.
local SPAWN_MIN_SEPARATION = 25
local SPAWN_MAX_RETRIES = 16

-- Returns true if `pos` is at least SPAWN_MIN_SEPARATION away from every
-- alive worm head (players + bots).
function WormService:_isSpawnPosClear(pos: Vector3): boolean
	local minSq = SPAWN_MIN_SEPARATION * SPAWN_MIN_SEPARATION
	for _, wormData in self._worms do
		if wormData.State == "Alive" and wormData.HeadPosition then
			local dx = wormData.HeadPosition.X - pos.X
			local dz = wormData.HeadPosition.Z - pos.Z
			if dx * dx + dz * dz < minSq then
				return false
			end
		end
	end
	-- BotService keeps its own table; reach in via the Knit-loaded reference if available.
	local BotService = self._botService
	if BotService then
		for _, botData in BotService._bots do
			if botData.State == "Alive" and botData.HeadPosition then
				local dx = botData.HeadPosition.X - pos.X
				local dz = botData.HeadPosition.Z - pos.Z
				if dx * dx + dz * dz < minSq then
					return false
				end
			end
		end
	end
	return true
end

-- Solo-mode spawn picker: tries up to SPAWN_MAX_RETRIES random positions,
-- accepting the first that's clear of existing worms. Falls back to the
-- last candidate if none qualify (rare; only happens on very crowded maps).
function WormService:_findSpreadArenaPosition(): Vector3
	local last: Vector3 = self:_randomArenaPosition()
	if self:_isSpawnPosClear(last) then
		return last
	end
	for _ = 1, SPAWN_MAX_RETRIES do
		local cand = self:_randomArenaPosition()
		if self:_isSpawnPosClear(cand) then
			return cand
		end
		last = cand
	end
	return last
end

-- Worm King: pick a spawn point inside a team's base ring. Uses a per-team
-- round-robin slot counter so simultaneous spawns map to distinct points on
-- the 8-slot ring (BaseSpawnCount = 8). Bases ride the sand tide scale, so
-- fetch the current scale from SandTideService.
function WormService:_spawnPositionForTeam(teamIndex: number?): Vector3
	if not teamIndex or teamIndex <= 0 then
		return self:_findSpreadArenaPosition()
	end
	local scale = if SandTideService then SandTideService:GetScale() else 1.0
	-- Per-team rolling slot; first call gets slot 0, then 1, 2, ... wrapping
	-- at BaseSpawnCount. This guarantees N≤BaseSpawnCount concurrent spawns
	-- get distinct ring points; for N>BaseSpawnCount, wraps deterministically.
	self._teamSpawnSlot = self._teamSpawnSlot or { 0, 0, 0 }
	local slot = self._teamSpawnSlot[teamIndex] or 0
	self._teamSpawnSlot[teamIndex] = slot + 1
	return TeamBase.getScaledSpawnPosition(teamIndex, scale, slot)
end

-- Worm King: initial facing when spawning at a team base — point toward centroid so worms
-- naturally move out from their corner toward the Crown. Flat (Y=0), unit length.
function WormService:_spawnFacingForTeam(teamIndex: number?): Vector3
	if not teamIndex or teamIndex <= 0 then
		return Vector3.new(0, 0, -1)
	end
	-- Scale doesn't matter for facing (direction is invariant under uniform scale about origin)
	local basePos = TeamBase.getBasePositionXZ(teamIndex)
	local toCenter = Vector3.new(-basePos.X, 0, -basePos.Z)
	if toCenter.Magnitude < 0.001 then
		return Vector3.new(0, 0, -1)
	end
	return toCenter.Unit
end

function WormService:_randomColor(): Color3
	return Color3.fromHSV(math.random(), 0.8, 0.9)
end

function WormService:_applyTeamColor(character: Model, teamColor: Color3)
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		wormHead.Color = teamColor
	end
	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if segFolder then
		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				seg.Color = teamColor
			end
		end
	end
end

function WormService:_updateLeaderstats(player: Player, segments: number)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local segValue = leaderstats:FindFirstChild("Segments") :: IntValue?
		if segValue then
			segValue.Value = math.floor(segments)
		end
	end
end

function WormService:_createArena()
	-- Remove default Studio baseplate to avoid z-fighting
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end

	-- Clear existing terrain and generate desert sand dunes
	workspace.Terrain:Clear()

	-- Customize terrain material colors for top-down contrast
	workspace.Terrain:SetMaterialColor(Enum.Material.Sand, Color3.fromRGB(210, 180, 120))
	workspace.Terrain:SetMaterialColor(Enum.Material.Sandstone, Color3.fromRGB(170, 130, 80))
	workspace.Terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(145, 115, 70))

	-- Generate sand-dune terrain from height map with material variation by height
	-- Low areas = Sand, mid = Sandstone, high ridges = Ground for top-down readability
	local step = 8
	local count = 0
	for x = -HALF_ARENA, HALF_ARENA, step do
		for z = -HALF_ARENA, HALF_ARENA, step do
			local h = TerrainHeight.getHeight(x, z)
			local mat = Enum.Material.Sand
			if h > 16 then
				mat = Enum.Material.Ground
			elseif h > 11 then
				mat = Enum.Material.Sandstone
			end
			workspace.Terrain:FillBlock(CFrame.new(x, h / 2, z), Vector3.new(step, h + 2, step), mat)
		end
		count += 1
		if count % 15 == 0 then
			task.wait()
		end
	end

	-- Boundary walls — animated energy barrier (tall enough to cover terrain height).
	-- In Worm King mode the SandTide triangle IS the physical boundary, so skip the
	-- square walls entirely — otherwise players see a square around the triangle.
	if not WormConfig.TeamModeEnabled then
		local wallHeight = 40
		local wallThickness = 4
		local wallY = 15
		local wallData = {
			{
				Vector3.new(WormConfig.ArenaSize + wallThickness * 2, wallHeight, wallThickness),
				Vector3.new(0, wallY, HALF_ARENA),
			},
			{
				Vector3.new(WormConfig.ArenaSize + wallThickness * 2, wallHeight, wallThickness),
				Vector3.new(0, wallY, -HALF_ARENA),
			},
			{
				Vector3.new(wallThickness, wallHeight, WormConfig.ArenaSize + wallThickness * 2),
				Vector3.new(HALF_ARENA, wallY, 0),
			},
			{
				Vector3.new(wallThickness, wallHeight, WormConfig.ArenaSize + wallThickness * 2),
				Vector3.new(-HALF_ARENA, wallY, 0),
			},
		}

		local wallsFolder = Instance.new("Folder")
		wallsFolder.Name = "BoundaryWalls"
		wallsFolder.Parent = workspace

		local animatedWallParts: { Part } = {}

		for i, data in wallData do
			-- Main force-field body — keep CanCollide=true so ghosts can't leave the arena
			local wall = Instance.new("Part")
			wall.Name = "Wall" .. i
			wall.Size = data[1]
			wall.Position = data[2]
			wall.Anchored = true
			wall.CanQuery = false -- don't block weapon raycasts
			wall.CanCollide = true
			wall.Material = Enum.Material.ForceField
			wall.Color = Color3.fromRGB(255, 40, 40)
			wall.Transparency = 0.2
			wall.Parent = wallsFolder
			table.insert(animatedWallParts, wall)

			-- Glowing capstone along the top
			local size = data[1]
			local pos = data[2]
			local topCap = Instance.new("Part")
			topCap.Name = "WallCapTop" .. i
			topCap.Size = Vector3.new(size.X, 0.6, size.Z)
			topCap.Position = Vector3.new(pos.X, pos.Y + wallHeight / 2, pos.Z)
			topCap.Anchored = true
			topCap.CanQuery = false
			topCap.CanCollide = false
			topCap.Material = Enum.Material.Neon
			topCap.Color = Color3.fromRGB(255, 30, 30)
			topCap.Parent = wallsFolder
			table.insert(animatedWallParts, topCap)

			-- Glowing capstone along the bottom
			local bottomCap = Instance.new("Part")
			bottomCap.Name = "WallCapBot" .. i
			bottomCap.Size = Vector3.new(size.X, 0.6, size.Z)
			bottomCap.Position = Vector3.new(pos.X, 0.3, pos.Z)
			bottomCap.Anchored = true
			bottomCap.CanQuery = false
			bottomCap.CanCollide = false
			bottomCap.Material = Enum.Material.Neon
			bottomCap.Color = Color3.fromRGB(255, 30, 30)
			bottomCap.Parent = wallsFolder
			table.insert(animatedWallParts, bottomCap)

			-- Point lights every ~80 studs along the wall for a patrol-light effect
			local longAxis = math.max(size.X, size.Z)
			local numLights = math.max(4, math.floor(longAxis / 80))
			for j = 1, numLights do
				local t = (j - 0.5) / numLights - 0.5 -- -0.5 .. 0.5
				local lightPos: Vector3
				if size.X > size.Z then
					lightPos = Vector3.new(pos.X + size.X * t, wallHeight + 1, pos.Z)
				else
					lightPos = Vector3.new(pos.X, wallHeight + 1, pos.Z + size.Z * t)
				end
				local lightAnchor = Instance.new("Part")
				lightAnchor.Name = "WallLight" .. i .. "_" .. j
				lightAnchor.Size = Vector3.new(1.5, 1.5, 1.5)
				lightAnchor.Shape = Enum.PartType.Ball
				lightAnchor.Position = lightPos
				lightAnchor.Anchored = true
				lightAnchor.CanCollide = false
				lightAnchor.CanQuery = false
				lightAnchor.Material = Enum.Material.Neon
				lightAnchor.Color = Color3.fromRGB(255, 60, 60)
				lightAnchor.Parent = wallsFolder

				local pointLight = Instance.new("PointLight")
				pointLight.Color = Color3.fromRGB(255, 80, 80)
				pointLight.Brightness = 3
				pointLight.Range = 30
				pointLight.Parent = lightAnchor
			end
		end

		-- Pulse the walls between two red shades on Heartbeat for an energy-barrier feel
		RunService.Heartbeat:Connect(function()
			local t = os.clock()
			local pulse = (math.sin(t * 2.5) + 1) * 0.5 -- 0..1
			local r = 180 + pulse * 75
			local g = 20 + pulse * 40
			local b = 20 + pulse * 40
			local pulsedColor = Color3.fromRGB(r, g, b)
			for _, part in animatedWallParts do
				part.Color = pulsedColor
			end
		end)
	end

	-- Configure desert lighting
	local Lighting = game:GetService("Lighting")
	Lighting.EnvironmentDiffuseScale = 0.3
	Lighting.EnvironmentSpecularScale = 0.1
	Lighting.GlobalShadows = true
	Lighting.Brightness = 3
	Lighting.ClockTime = 14
	Lighting.Ambient = Color3.fromRGB(80, 70, 50)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 110, 90)
	for _, child in Lighting:GetChildren() do
		child:Destroy()
	end

	-- Warm desert atmosphere with sandy haze
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.3
	atmosphere.Offset = 0.5
	atmosphere.Color = Color3.fromRGB(200, 180, 140)
	atmosphere.Decay = Color3.fromRGB(180, 160, 130)
	atmosphere.Glare = 0.5
	atmosphere.Haze = 6
	atmosphere.Parent = Lighting

	-- Warm color correction for desert feel
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.TintColor = Color3.fromRGB(255, 240, 210)
	colorCorrection.Brightness = 0.05
	colorCorrection.Saturation = 0.1
	colorCorrection.Parent = Lighting

	-- Worm King: carve out 3 team bases at triangle corners
	self:_createTeamBases()
end

-- Flatten the terrain under each base, then spawn a visible flag/banner + safe-zone dome.
function WormService:_createTeamBases()
	local basesFolder = workspace:FindFirstChild("TeamBases") :: Folder?
	if basesFolder then
		basesFolder:Destroy()
	end
	basesFolder = Instance.new("Folder")
	basesFolder.Name = "TeamBases"
	basesFolder.Parent = workspace

	local flattenRadius = WormConfig.WormKing.BaseFlattenRadius
	local safeRadius = WormConfig.WormKing.BaseSafeRadius

	for teamIndex, teamConfig in WormConfig.TeamColors do
		local baseXZ = TeamBase.getBasePositionXZ(teamIndex)
		local cx, cz = baseXZ.X, baseXZ.Z

		-- Flatten terrain: fill a cylinder-ish region with compacted blocks at a target height,
		-- then sit the base platform on top. We sample the smooth surface at the center and
		-- re-fill blocks within `flattenRadius` to that height.
		local targetY = TerrainHeight.getHeight(cx, cz)
		local step = 8
		for x = cx - flattenRadius, cx + flattenRadius, step do
			for z = cz - flattenRadius, cz + flattenRadius, step do
				local dx = x - cx
				local dz = z - cz
				if dx * dx + dz * dz <= flattenRadius * flattenRadius then
					workspace.Terrain:FillBlock(
						CFrame.new(x, targetY / 2, z),
						Vector3.new(step, targetY + 2, step),
						Enum.Material.Sandstone
					)
				end
			end
		end

		-- Flat platform on top for a clean spawn surface (slight y offset for visual pop)
		local platform = Instance.new("Part")
		platform.Name = "BasePlatform_" .. teamConfig.Name
		platform.Shape = Enum.PartType.Cylinder
		platform.Size = Vector3.new(1.5, flattenRadius * 2, flattenRadius * 2)
		platform.CFrame = CFrame.new(cx, targetY + 1.2, cz) * CFrame.Angles(0, 0, math.rad(90))
		platform.Anchored = true
		platform.CanCollide = false
		platform.CanQuery = false
		platform.Material = Enum.Material.SmoothPlastic
		platform.Color = teamConfig.Color:Lerp(Color3.fromRGB(80, 60, 40), 0.55)
		platform.Transparency = 0.3
		platform.Parent = basesFolder

		-- Team-colored glowing ring at the safe-zone boundary (purely visual, dome-like)
		local ring = Instance.new("Part")
		ring.Name = "SafeZoneRing_" .. teamConfig.Name
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.5, safeRadius * 2, safeRadius * 2)
		ring.CFrame = CFrame.new(cx, targetY + 0.6, cz) * CFrame.Angles(0, 0, math.rad(90))
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.Material = Enum.Material.Neon
		ring.Color = teamConfig.Color
		ring.Transparency = 0.6
		ring.Parent = basesFolder

		-- Tall flag pole + banner at the exact center
		local pole = Instance.new("Part")
		pole.Name = "FlagPole_" .. teamConfig.Name
		pole.Size = Vector3.new(1, 40, 1)
		pole.CFrame = CFrame.new(cx, targetY + 20, cz)
		pole.Anchored = true
		pole.CanCollide = false
		pole.CanQuery = false
		pole.Material = Enum.Material.Metal
		pole.Color = Color3.fromRGB(90, 90, 90)
		pole.Parent = basesFolder

		local banner = Instance.new("Part")
		banner.Name = "Banner_" .. teamConfig.Name
		banner.Size = Vector3.new(0.2, 12, 16)
		banner.CFrame = CFrame.new(cx + 8, targetY + 30, cz)
		banner.Anchored = true
		banner.CanCollide = false
		banner.CanQuery = false
		banner.Material = Enum.Material.Neon
		banner.Color = teamConfig.Color
		banner.Parent = basesFolder

		-- Team-colored light so the base is readable at a glance
		local pointLight = Instance.new("PointLight")
		pointLight.Color = teamConfig.Color
		pointLight.Brightness = 4
		pointLight.Range = 80
		pointLight.Parent = pole

		-- BillboardGui name label above the banner
		local labelAnchor = Instance.new("Part")
		labelAnchor.Name = "BaseLabel_" .. teamConfig.Name
		labelAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
		labelAnchor.Anchored = true
		labelAnchor.CanCollide = false
		labelAnchor.CanQuery = false
		labelAnchor.Transparency = 1
		labelAnchor.CFrame = CFrame.new(cx, targetY + 44, cz)
		labelAnchor.Parent = basesFolder

		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromOffset(200, 50)
		billboard.StudsOffset = Vector3.new(0, 0, 0)
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.Parent = labelAnchor

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 28
		label.TextColor3 = teamConfig.Color
		label.TextStrokeTransparency = 0.3
		label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		label.Text = teamConfig.Name .. " BASE"
		label.Parent = billboard
	end
end

local function pickFoodTier()
	local tiers = WormConfig.FoodTiers
	local totalWeight = 0
	for _, tier in tiers do
		totalWeight += tier.Weight
	end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, tier in tiers do
		cumulative += tier.Weight
		if roll <= cumulative then
			return tier
		end
	end
	return tiers[#tiers]
end

function WormService:_spawnFood()
	if self._foodCount >= WormConfig.MaxFoodOnMap then
		return
	end

	local tier = pickFoodTier()
	local food = Instance.new("Part")
	food.Name = "Food"
	food.Shape = Enum.PartType.Ball
	food.Size = Vector3.new(tier.Size, tier.Size, tier.Size)
	local pos = self:_randomArenaPosition()
	food.Position = Vector3.new(pos.X, TerrainHeight.getSurfaceY(pos.X, pos.Z) + tier.Size / 2, pos.Z)
	food.Anchored = true
	food.CanCollide = false
	food.Material = Enum.Material.Neon
	food.Color = Color3.fromHSV(math.random(), 0.9, 1)
	food:SetAttribute("FoodValue", tier.Value)
	food.Parent = self._foodFolder

	self._foodCount += 1
	if not self._batchSpawning then
		self.Client.FoodSpawned:FireAll(food.Position, food.Color)
	end
end

function WormService:_spawnFoodBatch(count: number)
	self._batchSpawning = true
	for _ = 1, count do
		self:_spawnFood()
	end
	self._batchSpawning = false
end

function WormService:_collectSegmentPositions(model: Model): { Vector3 }
	local positions = {}
	local wormHead = model:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		table.insert(positions, wormHead.Position)
	end
	local segFolder = model:FindFirstChild("WormSegments") :: Folder?
	if segFolder then
		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				table.insert(positions, seg.Position)
			end
		end
	end
	return positions
end

function WormService:_dropFoodAtPositions(positions: { Vector3 }, count: number)
	for i = 1, count do
		local pos
		if i <= #positions then
			pos = positions[i] + Vector3.new(math.random(-3, 3), 0, math.random(-3, 3))
		elseif #positions > 0 then
			pos = positions[1] + Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
		else
			return
		end
		pos = Vector3.new(pos.X, TerrainHeight.getSurfaceY(pos.X, pos.Z) + 0.75, pos.Z)

		local food = Instance.new("Part")
		food.Name = "Food"
		food.Shape = Enum.PartType.Ball
		food.Size = Vector3.new(1.5, 1.5, 1.5)
		food.Position = pos
		food.Anchored = true
		food.CanCollide = false
		food.Material = Enum.Material.Neon
		food.Color = Color3.fromHSV(math.random(), 0.9, 1)
		food:SetAttribute("FoodValue", 1)
		food.Parent = self._foodFolder
		self._foodCount += 1
	end
end

function WormService:_dropFoodFromWorm(player: Player, count: number)
	local character = player.Character
	if not character then
		return
	end
	local positions = self:_collectSegmentPositions(character)
	self:_dropFoodAtPositions(positions, count)
end

function WormService:_setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0

	-- Tag for client-side interpolation (BotInterpController-style smoothing
	-- on every non-local worm — bots already use IsBotWorm, players use this).
	character:SetAttribute("IsPlayerWorm", true)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Clean up any existing worm visuals (prevents duplicate from CharacterAdded double-call)
	local existingHead = character:FindFirstChild("WormHead")
	if existingHead then
		existingHead:Destroy()
	end
	local existingSegs = character:FindFirstChild("WormSegments")
	if existingSegs then
		existingSegs:Destroy()
	end

	-- Anchor HRP so server CFrame sets are authoritative (no physics fighting)
	hrp.Anchored = true

	-- Find the actual avatar Head before hiding parts
	local head = character:FindFirstChild("Head") :: BasePart?

	-- Hide all character parts EXCEPT the Head (which becomes the worm head)
	-- Keep face decals on the Head visible
	-- Set CanQuery = false so weapon raycasts pass through invisible parts
	for _, desc in character:GetDescendants() do
		if desc:IsA("BasePart") then
			if desc ~= head then
				desc.Transparency = 1
				desc.CanCollide = false
				desc.CanQuery = false
			end
		elseif desc:IsA("Decal") then
			if desc.Parent ~= head then
				desc.Transparency = 1
			end
		end
	end

	-- Hide any parts that load late (accessories, layered clothing, etc.)
	character.DescendantAdded:Connect(function(desc)
		local wormHead = character:FindFirstChild("WormHead")
		if desc:IsA("BasePart") and desc.Name ~= "WormHead" and not string.match(desc.Name, "^Segment") then
			desc.Transparency = 1
			desc.CanCollide = false
			desc.CanQuery = false
		elseif desc:IsA("Decal") then
			if desc.Parent ~= wormHead then
				desc.Transparency = 1
			end
		end
	end)

	local wormData = self._worms[player]
	local color = if wormData then wormData.Color else Color3.new(1, 1, 1)

	-- Use the avatar Head as the worm head: break rig, anchor, rename
	local headSize = WormConfig.SegmentSize + 0.5
	if head then
		-- Destroy all Motor6Ds that connect to the Head (Neck joint, etc.)
		for _, desc in character:GetDescendants() do
			if desc:IsA("Motor6D") and (desc.Part0 == head or desc.Part1 == head) then
				desc:Destroy()
			end
		end

		head.Anchored = true
		head.CanCollide = false
		head.Transparency = 0
		head.Size = Vector3.new(headSize, headSize, headSize)
		head.CFrame = hrp.CFrame
		head.Name = "WormHead" -- Rename so all existing FindFirstChild("WormHead") code works
	else
		-- Fallback: create a ball if Head somehow doesn't exist
		local wormHead = Instance.new("Part")
		wormHead.Name = "WormHead"
		wormHead.Shape = Enum.PartType.Ball
		wormHead.Size = Vector3.new(headSize, headSize, headSize)
		wormHead.Color = color
		wormHead.Material = Enum.Material.Neon
		wormHead.Transparency = 0
		wormHead.Anchored = true
		wormHead.CanCollide = false
		wormHead.CFrame = hrp.CFrame
		wormHead.Parent = character
	end

	-- Create body segments folder under character
	local segFolder = Instance.new("Folder")
	segFolder.Name = "WormSegments"
	segFolder.Parent = character

	if wormData then
		for i = 1, wormData.Segments do
			self:_createSegment(character, player, i, color)
		end
	end
end

function WormService:_createSegment(character: Model, player: Player, index: number, color: Color3): Part?
	local wormData = self._worms[player]
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if not hrp or not segFolder then
		return nil
	end

	local seg = Instance.new("Part")
	seg.Name = "Segment" .. index
	seg.Shape = Enum.PartType.Ball
	seg.Size = Vector3.new(WormConfig.SegmentSize, WormConfig.SegmentSize, WormConfig.SegmentSize)
	seg.Anchored = true
	seg.CanCollide = false
	seg.Material = Enum.Material.SmoothPlastic
	seg.Color = color
	seg:SetAttribute("MaxHP", WormConfig.SegmentHP)
	seg:SetAttribute("HP", WormConfig.SegmentHP)

	-- Position from history if available, otherwise behind head in current direction
	if wormData and wormData.HistoryEnd >= wormData.HistoryStart then
		local histIndex = wormData.HistoryEnd - index * ENTRIES_PER_SEGMENT
		if histIndex >= wormData.HistoryStart and wormData.PositionHistory[histIndex] then
			seg.Position = wormData.PositionHistory[histIndex]
		else
			seg.Position = hrp.Position - wormData.Direction * (index * WormConfig.SegmentSpacing)
		end
	else
		seg.Position = hrp.Position - Vector3.new(0, 0, index * WormConfig.SegmentSpacing)
	end

	seg.Parent = segFolder
	return seg
end

--------------------------------------------------
-- Position history
--------------------------------------------------

function WormService:_initPositionHistory(wormData: WormData, spawnPos: Vector3)
	wormData.PositionHistory = {}
	wormData.HistoryStart = 1
	wormData.HistoryEnd = 0

	-- Seed with positions trailing behind spawn in the initial direction
	local numEntries = (WormConfig.InitialSegments + 1) * ENTRIES_PER_SEGMENT
	for j = numEntries, 0, -1 do
		local behindDist = j * MIN_RECORD_DISTANCE
		local pos = spawnPos - wormData.Direction * behindDist
		wormData.HistoryEnd += 1
		wormData.PositionHistory[wormData.HistoryEnd] =
			Vector3.new(pos.X, TerrainHeight.getSmoothSurfaceY(pos.X, pos.Z) + WormConfig.SegmentSize / 2, pos.Z)
	end

	wormData.LastRecordedPos = spawnPos
end

function WormService:_recordPosition(wormData: WormData, pos: Vector3)
	local distMoved = (pos - wormData.LastRecordedPos).Magnitude
	if distMoved < MIN_RECORD_DISTANCE then
		return
	end

	wormData.HistoryEnd += 1
	wormData.PositionHistory[wormData.HistoryEnd] = pos
	wormData.LastRecordedPos = pos

	-- Trim old entries we no longer need
	local maxEntries = (math.ceil(wormData.Segments) + 2) * ENTRIES_PER_SEGMENT
	local trimTo = wormData.HistoryEnd - maxEntries
	while wormData.HistoryStart <= trimTo do
		wormData.PositionHistory[wormData.HistoryStart] = nil
		wormData.HistoryStart += 1
	end
end

--------------------------------------------------
-- Worm lifecycle
--------------------------------------------------

function WormService:_spawnWorm(player: Player)
	local wormData = self._worms[player]
	if not wormData then
		return
	end

	wormData.State = "Alive" :: WormState
	wormData.Segments = WormConfig.InitialSegments
	wormData.MaxSegments = WormConfig.InitialSegments
	wormData.Boosting = false
	wormData.Kills = 0
	wormData.SpawnTime = os.clock()
	wormData.LerpingSegments = nil

	-- Worm King: assign team FIRST so spawn position + facing can use it.
	local teamIndex: number? = nil
	if TeamService:IsEnabled() then
		teamIndex = TeamService:AssignToTeam(player.Name)
	end

	-- Pick spawn at the team base (fall back to random arena if no team mode).
	local spawnPos = self:_spawnPositionForTeam(teamIndex)
	local spawnFacing = self:_spawnFacingForTeam(teamIndex)
	wormData.Direction = spawnFacing
	wormData.CurrentDirection = spawnFacing

	-- 2-second spawn protection window; broken early by leaving safe zone or damaging others.
	wormData.SpawnProtectionUntil = os.clock() + WormConfig.WormKing.SpawnProtectionDuration

	player.RespawnLocation = nil
	player:LoadCharacter()

	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	-- Orient HRP so segments are laid out behind the head along the facing direction
	local lookAt = spawnPos + spawnFacing
	hrp.CFrame = CFrame.lookAt(spawnPos, lookAt)

	-- Seed cached position state so any gameplay reads before the first
	-- _updateMovement tick get a sensible value (matches the just-set HRP CFrame).
	wormData.HeadPosition = hrp.Position
	wormData.HeadDirection = wormData.CurrentDirection
	wormData.SegmentPositions = {}

	-- Initialize position history before setting up character (so segments can read from it)
	self:_initPositionHistory(wormData, spawnPos)

	self:_setupCharacter(player, character)

	-- Apply team color
	if teamIndex and teamIndex > 0 then
		local teamColor = TeamService:GetTeamColor(teamIndex)
		if teamColor then
			wormData.Color = teamColor
			self:_applyTeamColor(character, teamColor)
		end
	end

	self:_updateLeaderstats(player, wormData.Segments)

	self.Client.WormSpawned:Fire(player, {
		Segments = wormData.Segments,
		Color = { wormData.Color.R, wormData.Color.G, wormData.Color.B },
		Position = { spawnPos.X, spawnPos.Y, spawnPos.Z },
		SpawnProtectionDuration = WormConfig.WormKing.SpawnProtectionDuration,
		TeamIndex = teamIndex or 0,
	})
end

function WormService:_killWorm(player: Player, killer: Player?, killerBotName: string?)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Clear any active power-up
	PowerUpService:ClearActivePowerUp(player.Name)

	-- Knock off all ghost riders on this worm
	local riders = self._ghostRiders[player.Name]
	if riders then
		for ghostPlayer, _ in riders do
			self:KnockoffGhost(ghostPlayer, Vector3.new(0, 1, 0), nil)
		end
		self._ghostRiders[player.Name] = nil
	end

	local segmentsToDrop = math.floor(wormData.Segments * 0.7)
	self:_dropFoodFromWorm(player, segmentsToDrop)

	wormData.State = "Dead" :: WormState
	self:_updateLeaderstats(player, 0)

	-- Credit killer
	if killer and killer ~= player then
		local killerData = self._worms[killer]
		if killerData then
			killerData.Kills += 1
			self.Client.PlayerKillsUpdated:Fire(killer, killerData.Kills)
		end
		self.PlayerKilled:Fire(killer, player)
	end

	local killerDisplayName = if killer then killer.Name elseif killerBotName then killerBotName else nil
	local deadSegments = math.floor(wormData.Segments)
	local killerSegments = 0
	if killer then
		local kd = self._worms[killer]
		if kd then
			killerSegments = math.floor(kd.Segments)
		end
	elseif killerBotName then
		local botInfo = self._botModels[killerBotName]
		if botInfo then
			killerSegments = botInfo.Segments
		end
	end
	self.Client.WormDied:FireAll(player.Name, killerDisplayName, killerSegments, deadSegments)
	self.PlayerDied:Fire(player, killerDisplayName)

	-- Clean up character visuals
	local character = player.Character
	if character then
		local segFolder = character:FindFirstChild("WormSegments")
		if segFolder then
			segFolder:Destroy()
		end
		local wormHead = character:FindFirstChild("WormHead")
		if wormHead then
			wormHead:Destroy()
		end
		local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
		if humanoid then
			humanoid.Health = 0
		end
	end

	-- No auto-respawn; RoundService controls respawning
end

--------------------------------------------------
-- Weapon damage (called by WeaponService)
--------------------------------------------------

function WormService:DamageWorm(
	player: Player,
	damage: number,
	attacker: Player?,
	knockbackImpulse: Vector3?,
	hitSegmentIndex: number?,
	isWeaponHit: boolean?
)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Worm King: spawn protection blocks all incoming damage during the invuln window.
	if os.clock() < wormData.SpawnProtectionUntil then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local currentFloor = math.floor(wormData.Segments)
	if damage <= 0 or currentFloor <= 0 then
		return
	end

	local segFolder = character:FindFirstChild("WormSegments") :: Folder?

	-- Weapon hits (with a specific segment) deplete HP starting at the hit segment and
	-- cascade remaining damage toward the tail. Non-weapon damage (collisions, shrink
	-- zone, boost) still removes whole segments from the tail as before — `damage` is
	-- treated as a segment count in that case.
	local removeStart: number
	local removeEnd: number
	local actualRemoved = 0

	if isWeaponHit and hitSegmentIndex and hitSegmentIndex >= 1 and hitSegmentIndex <= currentFloor and segFolder then
		removeStart = hitSegmentIndex + 1 -- placeholder; narrowed below if anything destroyed
		removeEnd = hitSegmentIndex
		local remaining = damage
		local idx = hitSegmentIndex
		while remaining > 0 and idx <= currentFloor do
			local seg = segFolder:FindFirstChild("Segment" .. idx) :: BasePart?
			if not seg then
				break
			end
			local hp = tonumber(seg:GetAttribute("HP")) or WormConfig.SegmentHP
			if remaining >= hp then
				remaining -= hp
				seg:SetAttribute("HP", 0)
				if actualRemoved == 0 then
					removeStart = idx
				end
				removeEnd = idx
				actualRemoved += 1
				idx += 1
			else
				seg:SetAttribute("HP", hp - remaining)
				remaining = 0
			end
		end

		if actualRemoved == 0 then
			-- Damage was absorbed by segment HP — no segments destroyed this hit.
			return
		end
	else
		-- Tail removal: `damage` is a segment count
		actualRemoved = math.min(damage, currentFloor)
		if actualRemoved <= 0 then
			return
		end
		removeEnd = currentFloor
		removeStart = currentFloor - actualRemoved + 1
	end

	-- Drop food from removed segments
	local dropPositions = {}
	if segFolder then
		for i = removeStart, removeEnd do
			local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
			if seg then
				table.insert(dropPositions, seg.Position)
			end
		end
	end
	if #dropPositions > 0 then
		self:_dropFoodAtPositions(dropPositions, actualRemoved)
	else
		self:_dropFoodFromWorm(player, actualRemoved)
	end

	-- Remove segments
	wormData.Segments = math.max(0, wormData.Segments - actualRemoved)
	local newFloor = math.floor(wormData.Segments)

	-- Destroy removed segment visuals and renumber remaining tail segments
	local isMidBodyHit = isWeaponHit == true and removeEnd < currentFloor
	if segFolder then
		-- Destroy the hit segments
		for i = removeStart, removeEnd do
			local seg = segFolder:FindFirstChild("Segment" .. i)
			if seg then
				seg:Destroy()
			end
		end

		-- Renumber: segments after removeEnd shift down to fill the gap
		if removeEnd < currentFloor then
			-- Rename in ascending order (from lowest new index up) so we never clash
			for i = removeEnd + 1, currentFloor do
				local seg = segFolder:FindFirstChild("Segment" .. i)
				if seg then
					seg.Name = "Segment" .. (i - actualRemoved)
				end
			end
		end
	end

	-- For mid-body hits, lerp the shifted segments smoothly to fill the gap.
	-- We rebuild the lerp table, shifting any existing entries down by actualRemoved
	-- so that indices stay consistent after segment renumbering.
	if isMidBodyHit then
		local oldLerping = wormData.LerpingSegments
		local newLerping: { [number]: { StartTime: number, StartPos: Vector3 } } = {}

		-- Shift existing lerp entries down (their segment indices decreased due to renumbering)
		if oldLerping then
			for oldIdx, entry in oldLerping do
				if oldIdx > removeEnd then
					local shifted = oldIdx - actualRemoved
					if shifted >= 1 then
						newLerping[shifted] = entry
					end
				end
			end
		end

		-- Add new lerp entries for segments that just shifted to fill this gap
		local lerpStartTime = os.clock() + SEGMENT_LERP_DELAY
		for newIdx = removeStart, currentFloor - actualRemoved do
			if not newLerping[newIdx] then -- don't override an in-progress lerp
				local seg = segFolder and segFolder:FindFirstChild("Segment" .. newIdx) :: BasePart?
				local startPos = if seg then seg.Position else Vector3.zero
				newLerping[newIdx] = { StartTime = lerpStartTime, StartPos = startPos }
			end
		end

		wormData.LerpingSegments = newLerping
	end

	if newFloor < currentFloor then
		self.Client.WormAte:Fire(player, newFloor)
		self.PlayerScoreChanged:Fire(player, newFloor)
		self:_updateLeaderstats(player, newFloor)
	end

	-- Apply knockback impulse to worm head
	if knockbackImpulse then
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local newPos = hrp.Position + knockbackImpulse.Unit * (knockbackImpulse.Magnitude * 0.1)
			newPos = Vector3.new(
				newPos.X,
				TerrainHeight.getSmoothSurfaceY(newPos.X, newPos.Z) + WormConfig.SegmentSize / 2,
				newPos.Z
			)
			hrp.CFrame = CFrame.new(newPos, newPos + wormData.CurrentDirection)

			local wormHead = character:FindFirstChild("WormHead") :: BasePart?
			if wormHead then
				wormHead.CFrame = hrp.CFrame
			end
		end
	end

	-- Kill if segments reach 0
	if wormData.Segments <= 0 then
		self:_killWorm(player, attacker)
	end
end

--------------------------------------------------
-- Explosion damage (per-segment radial)
--------------------------------------------------

-- Apply explosion damage to a worm by damaging every segment whose position is
-- within `radius` of `center`. The first segment found inside the radius is
-- treated as the "primary hit" so the cascading HP-removal logic can run, and
-- each additional in-radius segment beyond that adds extra damage equal to its
-- own HP plus an overflow buffer so the blast actually carves a chunk out of
-- the worm rather than just nicking the tail.
function WormService:ExplodeWorm(player: Player, center: Vector3, radius: number, baseDamage: number, attacker: Player?)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if not segFolder then
		return
	end

	local segCount = math.floor(wormData.Segments)
	local primaryHit: number? = nil
	local extraDamage = 0
	for i = 1, segCount do
		local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
		if seg and (seg.Position - center).Magnitude <= radius then
			if not primaryHit then
				primaryHit = i
			else
				local hp = tonumber(seg:GetAttribute("HP")) or WormConfig.SegmentHP
				extraDamage += hp
			end
		end
	end

	if not primaryHit then
		-- Nothing inside radius — fall back to a single tail-segment hit so the
		-- player still gets feedback when they barely clip an enemy.
		primaryHit = segCount
	end

	local knockback = (Vector3.new(center.X, 0, center.Z) - Vector3.zero) -- placeholder
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local diff = hrp.Position - center
		if diff.Magnitude > 0.1 then
			knockback = diff.Unit * 40
		else
			knockback = Vector3.zero
		end
	end

	self:DamageWorm(player, baseDamage + extraDamage, attacker, knockback, primaryHit, true)
end

--------------------------------------------------
-- Game loop
--------------------------------------------------

-- Returns true exactly once per `tickNum` per `food` — the first caller in a
-- tick wins the right to write food.Position; subsequent callers (other
-- worms / bots within range of the same food) get false and skip the
-- write. Prevents double-replication of the same Part Position in a tick.
function WormService:_tryClaimMagnetPull(food: BasePart, tickNum: number): boolean
	if self._magnetClaim[food] == tickNum then
		return false
	end
	self._magnetClaim[food] = tickNum
	return true
end

function WormService:_checkFoodCollection(player: Player, headPos: Vector3)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Food magnet: passive pull + power-up pull
	local powerUpMagnetRange = PowerUpService:GetMagnetRange(player.Name)
	local effectiveRange = math.max(WormConfig.PassiveMagnetRange, powerUpMagnetRange)
	local pullSpeed = if powerUpMagnetRange > 0 then WormConfig.PowerUpMagnetPull else WormConfig.PassiveMagnetPull

	-- Gate Part.Position writes to 10Hz (every 6th Heartbeat) to stay
	-- within the "Server Brain, Client Body" replication budget.
	-- pullSpeed is multiplied by 6 to preserve the original studs/sec rate.
	local magnetFlush = (self._broadcastTick % 6 == 0)
	local eatRadius = WormConfig.CollisionRadius + 1
	local eatRadiusSq = eatRadius * eatRadius
	-- 9-cell neighborhood around the head. Cell size 10 → covers a 30-stud
	-- radius — bigger than the 25-stud max magnet range, so no in-range
	-- food is missed.
	self._foodGrid:ForEachNeighbor(headPos, function(entry)
		local food = entry.Part
		if not food or not food.Parent then
			return nil
		end
		local dx = entry.Pos.X - headPos.X
		local dz = entry.Pos.Z - headPos.Z
		local distSq = dx * dx + dz * dz

		-- Magnet pull
		if
			magnetFlush
			and effectiveRange > 0
			and distSq < effectiveRange * effectiveRange
			and distSq > eatRadiusSq
			and self:_tryClaimMagnetPull(food, self._broadcastTick)
		then
			-- Need a 3D vector for the pull direction; fall back to the
			-- xz-only direction since food is mostly at terrain level.
			local foodPos = food.Position
			local diff = foodPos - headPos
			local mag = diff.Magnitude
			if mag > 0.01 then
				food.Position = foodPos - (diff / mag) * (pullSpeed * 6)
			end
		end

		-- Eat (collision)
		if distSq < eatRadiusSq then
			if food:GetAttribute("Consumed") then
				return nil
			end
			food:SetAttribute("Consumed", true)
			local foodValue = food:GetAttribute("FoodValue") or WormConfig.FoodValue
			food:Destroy()
			self._foodCount -= 1
			local prevFloor = math.floor(wormData.Segments)
			wormData.Segments += foodValue
			if wormData.Segments > wormData.MaxSegments then
				wormData.MaxSegments = wormData.Segments
			end
			local newFloor = math.floor(wormData.Segments)
			local character = player.Character
			if character then
				for i = prevFloor + 1, newFloor do
					self:_createSegment(character, player, i, wormData.Color)
				end
			end
			self.Client.WormAte:Fire(player, wormData.Segments)
			self.PlayerScoreChanged:Fire(player, wormData.Segments)
			self:_updateLeaderstats(player, wormData.Segments)
		end
		return nil
	end)

	-- Check power-up collection
	PowerUpService:CollectPowerUp(player.Name, headPos)
end

-- Rebuild the food spatial grid. Indexes the workspace _foodFolder once;
-- per-worm food checks then walk only the 9-cell neighborhood around the
-- head. Idempotent within a frame.
function WormService:RebuildFoodGrid()
	local now = os.clock()
	if (now - self._foodGridBuiltAt) < 0.005 then
		return
	end
	self._foodGridBuiltAt = now

	local grid = self._foodGrid
	grid:Clear()

	local foodFolder = self._foodFolder
	if not foodFolder then
		return
	end
	for _, food in foodFolder:GetChildren() do
		if food:IsA("BasePart") then
			grid:Insert({
				Pos = food.Position,
				OwnerName = "",
				TeamIndex = 0,
				IsHead = false,
				Part = food,
			})
		end
	end
end

-- Rebuild the shared spatial grid from cached positions. Idempotent within
-- a single frame: callers from WormService.Heartbeat and BotService.Heartbeat
-- can both invoke and only the first one this frame does work.
--
-- The grid is the source of truth for:
--   - WormService:_checkWormCollisions (player worm vs everyone)
--   - BotService:_checkBotCollisions (bot worm vs everyone)
--   - BotService:_findNearestWormThreat (AI threat search)
--
-- It's rebuilt from already-cached server-side positions
-- (`wormData.HeadPosition`, `wormData.SegmentPositions[i]`, same for bots),
-- so this adds no Roblox property reads — pure Lua table walk.
function WormService:RebuildCollisionGrid(botService: any)
	local now = os.clock()
	-- Skip if already built this frame (within 5ms ≈ same Heartbeat tick).
	if (now - self._collisionGridBuiltAt) < 0.005 then
		return
	end
	self._collisionGridBuiltAt = now

	local grid = self._collisionGrid
	grid:Clear()

	-- Insert every alive player worm — head + each segment.
	for player, wormData in self._worms do
		if wormData.State ~= "Alive" then
			continue
		end
		local teamIndex = 0
		if TeamService and TeamService:IsEnabled() then
			teamIndex = TeamService:GetTeamForMember(player.Name) or 0
		end
		grid:Insert({
			Pos = wormData.HeadPosition,
			OwnerName = player.Name,
			TeamIndex = teamIndex,
			IsHead = true,
		})
		for _, segPos in wormData.SegmentPositions do
			grid:Insert({
				Pos = segPos,
				OwnerName = player.Name,
				TeamIndex = teamIndex,
				IsHead = false,
			})
		end
	end

	-- Insert every alive bot — head + each segment.
	if botService then
		for botName, botData in botService._bots do
			if botData.State ~= "Alive" then
				continue
			end
			local teamIndex = 0
			if TeamService and TeamService:IsEnabled() then
				teamIndex = TeamService:GetTeamForMember(botName) or 0
			end
			grid:Insert({
				Pos = botData.HeadPosition,
				OwnerName = botName,
				TeamIndex = teamIndex,
				IsHead = true,
			})
			for _, segPos in botData.SegmentPositions do
				grid:Insert({
					Pos = segPos,
					OwnerName = botName,
					TeamIndex = teamIndex,
					IsHead = false,
				})
			end
		end
	end
end

function WormService:_checkWormCollisions(player: Player, headPos: Vector3)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Ghost power-up: skip all collision checks
	if PowerUpService:IsGhost(player.Name) then
		return
	end

	-- Worm King: spawn protection blocks worm-vs-worm collision death entirely.
	if os.clock() < wormData.SpawnProtectionUntil then
		return
	end

	local myName = player.Name
	local myTeam = 0
	if TeamService and TeamService:IsEnabled() then
		myTeam = TeamService:GetTeamForMember(myName) or 0
	end
	local thresholdSq = (WormConfig.CollisionRadius * 2) ^ 2

	-- Single grid query covers any-other-worm-segment-near-my-head check.
	-- Replaces O(N·S) iteration with O(k) where k = entities in 9
	-- neighbor cells (typically 1-3 in this arena).
	local hitOwnerName: string? = nil
	self._collisionGrid:ForEachNeighbor(headPos, function(entry)
		if entry.OwnerName == myName then
			return nil -- self
		end
		if myTeam > 0 and entry.TeamIndex == myTeam then
			return nil -- teammate
		end
		local dx = entry.Pos.X - headPos.X
		local dy = entry.Pos.Y - headPos.Y
		local dz = entry.Pos.Z - headPos.Z
		if dx * dx + dy * dy + dz * dz < thresholdSq then
			hitOwnerName = entry.OwnerName
			return true -- stop iteration on first hit
		end
		return nil
	end)

	if hitOwnerName then
		-- Shield power-up: consume shield instead of dying
		if PowerUpService:ConsumeShield(player.Name) then
			return
		end
		-- Identify killer: player vs bot. Look up by name in players first.
		local killerPlayer = Players:FindFirstChild(hitOwnerName) :: Player?
		if killerPlayer then
			self:_killWorm(player, killerPlayer)
		else
			self:_killWorm(player, nil, hitOwnerName)
		end
	end
end

function WormService:_checkBounds(player: Player, headPos: Vector3)
	-- Static arena wall check (always lethal, no grace)
	if math.abs(headPos.X) > HALF_ARENA or math.abs(headPos.Z) > HALF_ARENA then
		self:_killWorm(player, nil)
		return
	end

	-- Shrink zone check — skip during spawn grace period
	local wormData = self._worms[player]
	if wormData and wormData.SpawnTime and (os.clock() - wormData.SpawnTime) < SPAWN_GRACE_PERIOD then
		return
	end

	if ShrinkZoneService:IsOutsideZone(headPos) then
		self:_killWorm(player, nil)
	end
end

function WormService:_checkGhostEating(player: Player, headPos: Vector3)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	for ghostPlayer, ghost in self._ghosts do
		-- Skip friendly ghosts
		if TeamService:AreTeammates(player.Name, ghostPlayer.Name) then
			continue
		end

		local ghostHrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not ghostHrp then
			continue
		end

		local dist = (ghostHrp.Position - headPos).Magnitude
		if dist < WormConfig.CollisionRadius + 1 then
			local eatPos = ghostHrp.Position

			-- Eat the ghost: add segments to the worm
			local prevFloor = math.floor(wormData.Segments)
			wormData.Segments += GHOST_FOOD_VALUE
			if wormData.Segments > wormData.MaxSegments then
				wormData.MaxSegments = wormData.Segments
			end
			local newFloor = math.floor(wormData.Segments)

			local character = player.Character
			if character then
				for i = prevFloor + 1, newFloor do
					self:_createSegment(character, player, i, wormData.Color)
				end
			end

			self.Client.WormAte:Fire(player, wormData.Segments)
			self.PlayerScoreChanged:Fire(player, wormData.Segments)
			self:_updateLeaderstats(player, wormData.Segments)

			-- Notify all clients for visual effect
			self.Client.GhostEaten:FireAll(eatPos, player.Name)

			-- Despawn the ghost
			self:DespawnGhost(ghostPlayer)

			-- Respawn ghost after delay
			task.delay(GHOST_RESPAWN_DELAY, function()
				-- Only respawn if player is still in game and round is active and still dead
				local data = self._worms[ghostPlayer]
				if data and data.State ~= "Alive" and self._roundActive then
					self:SpawnGhost(ghostPlayer, "Blaster")
				end
			end)

			return -- only eat one ghost per frame
		end
	end
end

function WormService:_checkBotGhostEating(botName: string, headPos: Vector3)
	for ghostPlayer, ghost in self._ghosts do
		-- Skip friendly ghosts
		if TeamService:AreTeammates(botName, ghostPlayer.Name) then
			continue
		end

		local ghostHrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not ghostHrp then
			continue
		end

		local dist = (ghostHrp.Position - headPos).Magnitude
		if dist < WormConfig.CollisionRadius + 1 then
			local eatPos = ghostHrp.Position

			-- Add segments to the bot via AddSegments
			self:AddSegments(botName, GHOST_FOOD_VALUE)

			-- Notify all clients for visual effect
			self.Client.GhostEaten:FireAll(eatPos, botName)

			-- Despawn the ghost
			self:DespawnGhost(ghostPlayer)

			-- Respawn ghost after delay
			task.delay(GHOST_RESPAWN_DELAY, function()
				local data = self._worms[ghostPlayer]
				if data and data.State ~= "Alive" and self._roundActive then
					self:SpawnGhost(ghostPlayer, "Blaster")
				end
			end)

			return
		end
	end
end

local SEGMENT_LERP_DURATION = 0.4 -- seconds for gap-fill slide (linear interpolation)

function WormService:_updateSegments(player: Player)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if not segFolder then
		return
	end

	local shouldBroadcast = (self._broadcastTick % 6 == 0)

	-- Place each segment at the position the head was at (index * ENTRIES_PER_SEGMENT) entries ago.
	-- We always update wormData.SegmentPositions (source of truth for gameplay reads), but
	-- only write to the actual Part.Position at 10Hz to limit replication bandwidth.
	local segCount = math.floor(wormData.Segments)
	local lerping = wormData.LerpingSegments
	local segmentPositions = wormData.SegmentPositions
	for i = 1, segCount do
		local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
		if not seg then
			continue
		end

		local histIndex = wormData.HistoryEnd - i * ENTRIES_PER_SEGMENT
		if histIndex >= wormData.HistoryStart and wormData.PositionHistory[histIndex] then
			local target = wormData.PositionHistory[histIndex]
			local lerpEntry = lerping and lerping[i] or nil
			local resolved: Vector3? = nil
			if lerpEntry then
				local now = os.clock()
				if now >= lerpEntry.StartTime then
					-- Linear interpolation from start position to target over fixed duration
					local elapsed = now - lerpEntry.StartTime
					local t = math.min(1, elapsed / SEGMENT_LERP_DURATION)
					resolved = lerpEntry.StartPos:Lerp(target, t)
					if t >= 1 then
						lerping[i] = nil
					end
				end
				-- Pre-delay (StartTime not reached): leave segment in place
				-- so the destroyed segment's gap is briefly visible. Don't update
				-- the cached position either; preserve whatever was last computed.
			else
				-- Not lerping: snap to target position from history
				resolved = target
			end

			if resolved then
				segmentPositions[i] = resolved
				if shouldBroadcast then
					seg.Position = resolved
				end
			end
		end
	end

	-- Drop stale cached positions for segments that no longer exist (worm shrank).
	for idx in segmentPositions do
		if idx > segCount then
			segmentPositions[idx] = nil
		end
	end

	-- Cleanup empty lerp table
	if lerping and next(lerping) == nil then
		wormData.LerpingSegments = nil
	end
end

function WormService:_updateMovement(player: Player, dt: number)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Handle boosting and power-up speed (larger worms move slower)
	local sizeScale = 1 / (1 + wormData.Segments * WormConfig.SpeedScaleFactor)
	local slowFactor = PowerUpService:GetSlowFactor(player.Name)

	-- Ghost rider speed boost: each riding ghost adds a speed multiplier
	local riderBoost = 1
	local riders = self._ghostRiders[player.Name]
	if riders then
		local riderCount = 0
		for _ in riders do
			riderCount += 1
		end
		riderBoost =
			math.min(1 + riderCount * WormConfig.Ghost.RiderSpeedBoostPerGhost, WormConfig.Ghost.MaxRiderSpeedBoost)
	end

	local speed = WormConfig.BaseSpeed
		* sizeScale
		* PowerUpService:GetSpeedMultiplier(player.Name)
		* slowFactor
		* riderBoost

	-- "Free boost" powerups (SPEED / SPEED_BURST) auto-engage boost AND
	-- waive the segment cost. Without a powerup, normal boost rules apply:
	-- player must be holding the input AND have segments above the floor,
	-- and the boost burns segments.
	local hasFreeBoost = PowerUpService:HasFreeBoost(player.Name)
	local boostingNow = hasFreeBoost or (wormData.Boosting and wormData.Segments > WormConfig.MinBoostSegments)
	if boostingNow then
		speed = WormConfig.BoostSpeed
			* sizeScale
			* PowerUpService:GetSpeedMultiplier(player.Name)
			* slowFactor
			* riderBoost
		if not hasFreeBoost then
			local prevFloor = math.floor(wormData.Segments)
			local segmentsToLose = WormConfig.BoostSegmentCostPerSec * dt
			wormData.Segments = math.max(WormConfig.MinBoostSegments, wormData.Segments - segmentsToLose)
			local newFloor = math.floor(wormData.Segments)

			-- Remove excess segments and notify client when a visible segment is lost
			if newFloor < prevFloor then
				local segFolder = character:FindFirstChild("WormSegments") :: Folder?
				if segFolder then
					for _, seg in segFolder:GetChildren() do
						local idx = tonumber(string.match(seg.Name, "%d+"))
						if idx and idx > newFloor then
							seg:Destroy()
						end
					end
				end
				self.Client.WormAte:Fire(player, newFloor)
				self:_updateLeaderstats(player, newFloor)
			end
		end
	end

	-- Interpolate current direction toward target direction with turn rate
	local targetDir = wormData.Direction
	local currentDir = wormData.CurrentDirection
	local currentAngle = math.atan2(currentDir.X, currentDir.Z)
	local targetAngle = math.atan2(targetDir.X, targetDir.Z)
	local angleDiff = targetAngle - currentAngle
	-- Normalize to [-pi, pi]
	while angleDiff > math.pi do
		angleDiff -= 2 * math.pi
	end
	while angleDiff < -math.pi do
		angleDiff += 2 * math.pi
	end
	local maxTurn = WormConfig.TurnRate * dt
	local actualTurn = math.clamp(angleDiff, -maxTurn, maxTurn)
	local newAngle = currentAngle + actualTurn
	local dir = Vector3.new(math.sin(newAngle), 0, math.cos(newAngle))
	wormData.CurrentDirection = dir

	-- Move HRP in direction (anchored, so CFrame set is authoritative).
	-- HeadPosition is the per-frame source of truth (HRP CFrame writes
	-- below propagate it to clients each frame).
	local move = dir * speed * dt
	local newPos = wormData.HeadPosition + move
	newPos = Vector3.new(
		newPos.X,
		TerrainHeight.getSmoothSurfaceY(newPos.X, newPos.Z) + WormConfig.SegmentSize / 2,
		newPos.Z
	)

	-- Always update cached gameplay state every frame.
	wormData.HeadPosition = newPos
	wormData.HeadDirection = dir

	-- Heads (HRP + WormHead) write EVERY FRAME — they drive the local
	-- camera and visual smoothness. Keeping them at 10Hz produced visible
	-- jumps every 100ms even with client-side interpolation, since the
	-- local player's character is excluded from BotInterpController and
	-- their camera follows hrp.Position directly.
	-- Replication cost: 4 players × 2 parts × 60Hz = 480 writes/sec
	-- (negligible vs the bot population's writes).
	local newCFrame = CFrame.new(newPos, newPos + dir)
	hrp.CFrame = newCFrame
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		wormHead.CFrame = newCFrame
	end

	-- Record position in history for segment following
	self:_recordPosition(wormData, newPos)
end

function WormService:_gameStep(dt: number)
	-- Bump the broadcast tick at the top of the step. _updateMovement and
	-- _updateSegments check `_broadcastTick % 6 == 0` to decide whether to write
	-- to actual Part CFrames this frame (10Hz at 60fps).
	self._broadcastTick += 1

	-- Spawn food to maintain target count
	local foodDeficit = WormConfig.MaxFoodOnMap - self._foodCount
	if foodDeficit > 0 then
		local toSpawn = math.min(foodDeficit, 10) -- Spawn up to 10 per frame
		self:_spawnFoodBatch(toSpawn)
	end

	-- Rebuild the shared spatial grids for this frame's collision/food
	-- checks. Both are idempotent — if BotService already rebuilt this
	-- frame the calls no-op.
	self:RebuildCollisionGrid(self._botService)
	self:RebuildFoodGrid()

	-- Update all alive worms
	for player, wormData in self._worms do
		if wormData.State ~= "Alive" then
			continue
		end

		local character = player.Character
		if not character then
			continue
		end

		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		self:_updateMovement(player, dt)
		self:_updateSegments(player)

		-- Read from cached HeadPosition (updated every frame by _updateMovement)
		-- rather than hrp.Position, since the Part is only written at 10Hz.
		local headPos = wormData.HeadPosition
		self:_checkFoodCollection(player, headPos)
		self:_checkWormCollisions(player, headPos)
		self:_checkBounds(player, headPos)
		self:_checkGhostEating(player, headPos)
	end

	-- Check bot worm heads eating enemy ghosts
	for botName, botInfo in self._botModels do
		local botHrp = botInfo.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if botHrp then
			self:_checkBotGhostEating(botName, botHrp.Position)
		end
	end

	-- Despawn ghosts that go outside arena walls
	for player, ghost in self._ghosts do
		local ghostHrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
		if ghostHrp then
			local pos = ghostHrp.Position
			if math.abs(pos.X) > HALF_ARENA or math.abs(pos.Z) > HALF_ARENA then
				self:DespawnGhost(player)
			end
		end
	end
end

--------------------------------------------------
-- Bot integration (called by BotService)
--------------------------------------------------

function WormService:RegisterBot(name: string, model: Model, segments: number)
	self._botModels[name] = { Model = model, Segments = segments }
end

function WormService:UnregisterBot(name: string)
	self._botModels[name] = nil
end

function WormService:UpdateBotSegments(name: string, segments: number)
	local bot = self._botModels[name]
	if bot then
		bot.Segments = segments
	end
end

function WormService:ConsumeFood(food: BasePart): boolean
	-- Guard against double-consumption in the same frame
	if food:GetAttribute("Consumed") then
		return false
	end
	food:SetAttribute("Consumed", true)
	food:Destroy()
	self._foodCount -= 1
	return true
end

function WormService:DropFoodAtPosition(position: Vector3, count: number)
	self:_dropFoodAtPositions({ position }, count)
end

function WormService:DropFoodFromModel(model: Model, count: number)
	local positions = self:_collectSegmentPositions(model)
	self:_dropFoodAtPositions(positions, count)
end

function WormService:FireBotDeath(botName: string, killerName: string?)
	self.Client.WormDied:FireAll(botName, killerName)
end

-- Used by PowerUpService (SIZE_BOMB)
function WormService:AddSegments(ownerName: string, count: number)
	-- Check if it's a player
	for player, wormData in self._worms do
		if player.Name == ownerName and wormData.State == "Alive" then
			wormData.Segments += count
			if wormData.Segments > wormData.MaxSegments then
				wormData.MaxSegments = wormData.Segments
			end
			local character = player.Character
			if character then
				for i = math.floor(wormData.Segments - count) + 1, math.floor(wormData.Segments) do
					self:_createSegment(character, player, i, wormData.Color)
				end
			end
			self.Client.WormAte:Fire(player, wormData.Segments)
			self.PlayerScoreChanged:Fire(player, wormData.Segments)
			self:_updateLeaderstats(player, wormData.Segments)
			return
		end
	end

	-- Check if it's a bot
	local botInfo = self._botModels[ownerName]
	if botInfo then
		botInfo.Segments += count
	end
end

--------------------------------------------------
-- Ghost mode (dead player first-person)
--------------------------------------------------

function WormService:_addGhostNameLabel(ghost: Model, playerName: string, labelColor: Color3?)
	local head = ghost:FindFirstChild("Head")
	local labelParent = head or ghost.PrimaryPart
	if not labelParent then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 80, 0, 20)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = labelParent

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = playerName
	nameLabel.TextColor3 = labelColor or Color3.fromRGB(180, 200, 255)
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.5
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Parent = billboard
end

function WormService:_buildFallbackGhost(player: Player, spawnPos: Vector3): (Model, Color3)
	local ghostConfig = WormConfig.Ghost
	local ghost = Instance.new("Model")
	ghost.Name = player.Name .. "_Ghost"

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(0.67, 0.67, 0.67)
	hrp.Transparency = ghostConfig.Transparency
	hrp.Anchored = false
	hrp.CanCollide = true
	hrp.Position = spawnPos + Vector3.new(0, 2, 0)
	hrp.Parent = ghost
	ghost.PrimaryPart = hrp

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = ghostConfig.WalkSpeed
	humanoid.JumpPower = ghostConfig.JumpPower
	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge
	humanoid.Parent = ghost

	-- Determine ghost color (team color if team mode, default ghostly blue otherwise)
	local ghostColor = Color3.fromRGB(180, 200, 255)
	if TeamService:IsEnabled() then
		local teamIndex = TeamService:GetTeamForMember(player.Name)
		if teamIndex then
			local teamColor = TeamService:GetTeamColor(teamIndex)
			if teamColor then
				ghostColor = teamColor
			end
		end
	end

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(0.5, 0.5, 0.5)
	head.Color = ghostColor
	head.Material = Enum.Material.Neon
	head.Transparency = ghostConfig.Transparency
	head.CanCollide = false
	head.Position = hrp.Position + Vector3.new(0, 0.6, 0)
	head.Parent = ghost

	local headWeld = Instance.new("Weld")
	headWeld.Part0 = hrp
	headWeld.Part1 = head
	headWeld.C0 = CFrame.new(0, 0.6, 0)
	headWeld.Parent = head

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(0.5, 0.67, 0.33)
	torso.Color = ghostColor
	torso.Material = Enum.Material.Neon
	torso.Transparency = ghostConfig.Transparency
	torso.CanCollide = false
	torso.Position = hrp.Position
	torso.Parent = ghost

	local torsoWeld = Instance.new("Weld")
	torsoWeld.Part0 = hrp
	torsoWeld.Part1 = torso
	torsoWeld.C0 = CFrame.new(0, 0, 0)
	torsoWeld.Parent = torso

	-- Glow light
	local light = Instance.new("PointLight")
	light.Brightness = ghostConfig.GlowBrightness
	light.Range = ghostConfig.GlowRange
	light.Color = ghostColor
	light.Parent = head

	return ghost, ghostColor
end

function WormService:SpawnGhost(player: Player, weaponType: string?)
	-- Remove existing ghost if any
	self:DespawnGhost(player)

	local wormData = self._worms[player]
	if not wormData or wormData.State == "Alive" then
		return
	end

	local ghostConfig = WormConfig.Ghost

	-- Worm King: ghosts respawn at their team's base (instead of a random corner of the map).
	-- Pick a spawn near the team base using the base spawn ring helper. If the player has no
	-- team yet (edge case: ghost called before team assignment), fall back to near-origin.
	local spawnPos: Vector3
	local teamIndex: number? = nil
	if TeamService:IsEnabled() then
		teamIndex = TeamService:GetTeamForMember(player.Name)
	end
	if teamIndex and teamIndex > 0 then
		local scale = if SandTideService then SandTideService:GetScale() else 1.0
		local baseSpawn = TeamBase.getScaledSpawnPosition(teamIndex, scale, nil)
		spawnPos = Vector3.new(baseSpawn.X, baseSpawn.Y + 2, baseSpawn.Z)
	else
		local gx, gz = math.random(-50, 50), math.random(-50, 50)
		spawnPos = Vector3.new(gx, TerrainHeight.getSurfaceY(gx, gz) + 2, gz)
	end

	-- Determine ghost color (team color if team mode, default ghostly blue otherwise)
	local ghostColor = Color3.fromRGB(180, 200, 255)
	if teamIndex then
		local teamColor = TeamService:GetTeamColor(teamIndex)
		if teamColor then
			ghostColor = teamColor
		end
	end

	-- Try to load the player's actual avatar
	local ghost: Model
	local success, avatarModel = pcall(function()
		return Players:CreateHumanoidModelFromUserId(player.UserId)
	end)

	if success and avatarModel then
		ghost = avatarModel
		ghost.Name = player.Name .. "_Ghost"

		-- Ensure player is still in game after async load
		if not player.Parent then
			ghost:Destroy()
			return
		end

		local humanoid = ghost:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = ghostConfig.WalkSpeed
			humanoid.JumpPower = ghostConfig.JumpPower
			humanoid.MaxHealth = math.huge
			humanoid.Health = math.huge

			-- Scale down via HumanoidDescription
			pcall(function()
				local desc = humanoid:GetAppliedDescription()
				local s = ghostConfig.AvatarScale
				desc.HeadScale = desc.HeadScale * s
				desc.BodyDepthScale = desc.BodyDepthScale * s
				desc.BodyHeightScale = desc.BodyHeightScale * s
				desc.BodyWidthScale = desc.BodyWidthScale * s
				humanoid:ApplyDescription(desc)
			end)
		end

		-- Apply transparency and disable collisions on body parts
		for _, part in ghost:GetDescendants() do
			if part:IsA("BasePart") then
				part.Transparency = math.max(part.Transparency, ghostConfig.Transparency)
				if part.Name ~= "HumanoidRootPart" then
					part.CanCollide = false
				end
			end
		end

		-- Add glow light on head
		local head = ghost:FindFirstChild("Head")
		if head then
			local light = Instance.new("PointLight")
			light.Brightness = ghostConfig.GlowBrightness
			light.Range = ghostConfig.GlowRange
			light.Color = ghostColor
			light.Parent = head
		end

		-- Position the ghost
		local hrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			hrp.CFrame = CFrame.new(spawnPos + Vector3.new(0, 3, 0))
		end
	else
		-- Fallback to minimal neon ghost
		ghost, ghostColor = self:_buildFallbackGhost(player, spawnPos)
	end

	-- Name label above ghost
	self:_addGhostNameLabel(ghost, player.Name, ghostColor)

	-- Ghostly particle emitter for visibility
	local ghostHrpForFx = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
	if ghostHrpForFx then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "GhostWisp"
		emitter.Color = ColorSequence.new(ghostColor, Color3.fromRGB(255, 255, 255))
		emitter.Transparency =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		emitter.Lifetime = NumberRange.new(0.5, 1.2)
		emitter.Rate = 15
		emitter.Speed = NumberRange.new(1, 3)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.LightEmission = 1
		emitter.LightInfluence = 0
		emitter.Parent = ghostHrpForFx
	end

	-- Tag ghost for hit detection (used by WeaponService)
	ghost:SetAttribute("IsGhost", true)
	ghost:SetAttribute("GhostOwner", player.Name)

	-- Worm King: team-tinted outline so ghosts are instantly readable (and never invisible).
	-- Highlight renders a constant-width outline visible through occlusion, anchored to the model.
	local highlight = Instance.new("Highlight")
	highlight.Name = "GhostTeamOutline"
	highlight.FillColor = ghostColor
	highlight.FillTransparency = 0.75 -- subtle body tint
	highlight.OutlineColor = ghostColor
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = ghost

	ghost.Parent = workspace

	-- Set player's character to the ghost so they can control it
	player.Character = ghost

	self._ghosts[player] = ghost
	-- Reset HP on each spawn — full health every time the ghost respawns.
	self._ghostHP[player] = WormConfig.Ghost.MaxHP

	-- Assign weapon to the ghost
	if WeaponService then
		if weaponType then
			WeaponService:AssignWeapon(player, weaponType)
		else
			WeaponService:AssignRandomWeapon(player)
		end
	end

	-- Notify client
	self.Client.GhostSpawned:Fire(player, spawnPos)
end

function WormService:DespawnGhost(player: Player)
	local ghost = self._ghosts[player]
	if ghost then
		-- Flush any active ride time before cleanup
		self:_onGrappleDetached(player)

		ghost:Destroy()
		self._ghosts[player] = nil
		self._ghostHP[player] = nil

		-- Clear weapon
		if WeaponService then
			WeaponService:ClearWeapon(player)
		end

		-- Clear leaderboard tracking for this ghost
		self._ghostKillCounts[player] = nil
		self._rideStartTimes[player] = nil
		self._totalRideTimes[player] = nil

		self.Client.GhostDespawned:Fire(player)
	end
end

-- Apply weapon damage to a player ghost. Returns true iff this hit
-- killed the ghost (HP went to 0). On kill: despawn the ghost
-- immediately and schedule a respawn after Ghost.RespawnDelay seconds
-- (LoL-style death timer). Friendly to round-end / player-leave: the
-- delayed respawn no-ops if conditions changed.
function WormService:DamageGhost(player: Player, damage: number, attacker: Player?): boolean
	if damage <= 0 then
		return false
	end
	if not self._ghosts[player] then
		return false
	end
	local hp = (self._ghostHP[player] or WormConfig.Ghost.MaxHP) - damage
	if hp > 0 then
		self._ghostHP[player] = hp
		return false
	end

	-- Killed. Show poof at the death position so the shooter sees
	-- confirmation, credit the attacker, then despawn + delayed respawn.
	local ghost = self._ghosts[player]
	local deathPos = Vector3.zero
	if ghost then
		local hrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			deathPos = hrp.Position
		end
	end
	self.Client.GhostEaten:FireAll(deathPos, if attacker then attacker.Name else "")

	if attacker and LeaderboardService then
		local kills = (self._ghostKillCounts[attacker] or 0) + 1
		self._ghostKillCounts[attacker] = kills
		LeaderboardService:SubmitScoreAllPeriods(attacker.UserId, "GhostKills", kills)
	end

	self:DespawnGhost(player)

	task.delay(WormConfig.Ghost.RespawnDelay, function()
		-- Only respawn if player still in game, round still active, still dead.
		if not player or not player.Parent then
			return
		end
		if not self._roundActive then
			return
		end
		local data = self._worms[player]
		if not data or data.State == "Alive" then
			return
		end
		self:SpawnGhost(player, "Blaster")
	end)

	return true
end

function WormService:DespawnAllGhosts()
	for player, ghost in self._ghosts do
		self:_onGrappleDetached(player)
		ghost:Destroy()
		self.Client.GhostDespawned:Fire(player)
	end
	self._ghosts = {}
	self._ghostHP = {}
	self._ghostRiders = {}
	self._ghostKillCounts = {}
	self._rideStartTimes = {}
	self._totalRideTimes = {}

	-- Clear weapon pickups when all ghosts are gone (round reset)
	if WeaponService then
		WeaponService:ClearAllPickups()
	end
end

--------------------------------------------------
-- Ghost rider tracking
--------------------------------------------------

-- Maximum world distance allowed between a ghost and the worm head it's
-- claiming to grapple onto. The ghost grapple range itself is tuned via
-- WormConfig.Grapple.Range; we add 50% slack to account for the lerp in
-- progress at attach-time on the client.
local GRAPPLE_ATTACH_MAX_DIST = WormConfig.Grapple.Range * 1.5
-- Clients fire GrappleAttached/Detached around the snap moment; once per
-- attempt is plenty. 0.4s blocks the trivial 60Hz spam DoS on the worm
-- owner's RiderAttached signal.
local GRAPPLE_ATTACH_MIN_INTERVAL = 0.4

function WormService:_onGrappleAttached(player: Player, targetWormName: string)
	-- Rate limit: drop attaches faster than every 400ms per player. Without
	-- this a malicious client can flood RiderAttached at the worm owner.
	local now = os.clock()
	local last = self._lastGrappleAttachTime[player] or 0
	if now - last < GRAPPLE_ATTACH_MIN_INTERVAL then
		return
	end
	self._lastGrappleAttachTime[player] = now

	-- Validate: player must be a ghost
	local ghost = self._ghosts[player]
	if not ghost then
		return
	end
	local ghostHrp = ghost:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not ghostHrp then
		return
	end

	-- Validate: target worm must exist and be alive (Players name lookup is
	-- O(1) compared to scanning self._worms).
	local targetOwner = Players:FindFirstChild(targetWormName) :: Player?
	if not targetOwner then
		return
	end
	local data = self._worms[targetOwner]
	if not data or data.State ~= "Alive" then
		return
	end

	-- Validate: ghost must actually be near the target worm head. Without
	-- this a ghost across the map can claim to grapple anyone.
	local targetHeadPos = data.HeadPosition or Vector3.zero
	if (ghostHrp.Position - targetHeadPos).Magnitude > GRAPPLE_ATTACH_MAX_DIST then
		return
	end

	-- Remove from any previous ride first
	self:_onGrappleDetached(player)

	-- Track this rider
	if not self._ghostRiders[targetWormName] then
		self._ghostRiders[targetWormName] = {}
	end
	self._ghostRiders[targetWormName][player] = true

	-- Record ride start time for leaderboard
	self._rideStartTimes[player] = os.clock()

	-- Notify the worm owner
	self.Client.RiderAttached:Fire(targetOwner, player.Name)
end

function WormService:_onGrappleDetached(player: Player)
	-- Find and remove from any rider table
	for wormName, riders in self._ghostRiders do
		if riders[player] then
			riders[player] = nil

			-- Flush ride duration to leaderboard
			local startTime = self._rideStartTimes[player]
			if startTime then
				local elapsed = os.clock() - startTime
				self._rideStartTimes[player] = nil
				local total = (self._totalRideTimes[player] or 0) + elapsed
				self._totalRideTimes[player] = total
				if LeaderboardService then
					LeaderboardService:SubmitScoreAllPeriods(player.UserId, "RideTime", math.floor(total))
				end
			end

			-- Clean up empty table
			if not next(riders) then
				self._ghostRiders[wormName] = nil
			end

			-- Notify worm owner
			for p, _ in self._worms do
				if p.Name == wormName then
					self.Client.RiderDetached:Fire(p, player.Name)
					break
				end
			end
			break
		end
	end
end

function WormService:KnockoffGhost(ghostPlayer: Player, knockbackDir: Vector3, shooterPlayer: Player?)
	self:_onGrappleDetached(ghostPlayer)
	self.Client.GhostKnockoff:Fire(ghostPlayer, knockbackDir)

	-- Credit the shooter with a ghost kill
	if shooterPlayer and LeaderboardService then
		local kills = (self._ghostKillCounts[shooterPlayer] or 0) + 1
		self._ghostKillCounts[shooterPlayer] = kills
		LeaderboardService:SubmitScoreAllPeriods(shooterPlayer.UserId, "GhostKills", kills)
	end
end

-- Client methods for grapple attach/detach
function WormService.Client:GrappleAttached(player: Player, targetWormName: string)
	if typeof(targetWormName) ~= "string" then
		return
	end
	self.Server:_onGrappleAttached(player, targetWormName)
end

function WormService.Client:GrappleDetached(player: Player)
	self.Server:_onGrappleDetached(player)
end

-- (worm-grapple GrappleGround RPC removed — grapple is a ghost-only
--  mechanic; ghost-side handlers are GrappleAttached / GrappleDetached above.
--  See CLAUDE.md.)

-- Client method to request ghost spawn/despawn
function WormService.Client:ToggleGhost(player: Player)
	local ghost = self.Server._ghosts[player]
	if ghost then
		self.Server:DespawnGhost(player)
	else
		self.Server:SpawnGhost(player)
	end
end

--------------------------------------------------
-- Round API (called by RoundService)
--------------------------------------------------

function WormService:SetRoundActive(active: boolean)
	self._roundActive = active
end

function WormService:GetAliveCount(): number
	local count = 0
	for _, wormData in self._worms do
		if wormData.State == "Alive" then
			count += 1
		end
	end
	return count
end

function WormService:GetAlivePlayers(): { Player }
	local alive = {}
	for player, wormData in self._worms do
		if wormData.State == "Alive" then
			table.insert(alive, player)
		end
	end
	return alive
end

function WormService:GetRoundStats(): { [string]: { Kills: number, MaxSegments: number } }
	local stats = {}
	for player, wormData in self._worms do
		stats[player.Name] = {
			Kills = wormData.Kills,
			MaxSegments = math.floor(wormData.MaxSegments),
		}
	end
	return stats
end

function WormService:SpawnWormForRound(player: Player)
	local wormData = self._worms[player]
	if not wormData then
		return
	end
	-- Remove ghost if player was in ghost mode
	self:DespawnGhost(player)
	self:_spawnWorm(player)
end

function WormService:KillAllWorms()
	-- Despawn all ghosts first
	self:DespawnAllGhosts()
	for player, wormData in self._worms do
		if wormData.State == "Alive" then
			-- Clear active power-up
			PowerUpService:ClearActivePowerUp(player.Name)
			wormData.State = "Dead" :: WormState
			self:_updateLeaderstats(player, 0)

			local character = player.Character
			if character then
				local segFolder = character:FindFirstChild("WormSegments")
				if segFolder then
					segFolder:Destroy()
				end
				local wormHead = character:FindFirstChild("WormHead")
				if wormHead then
					wormHead:Destroy()
				end
				local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
				if humanoid then
					humanoid.Health = 0
				end
			end
		end

		-- Reset per-worm round state. Without this, PositionHistory and
		-- SegmentPositions accumulate across rounds — PositionHistory grows
		-- by ~120 entries/sec while alive (every 0.5 studs of movement) and
		-- isn't trimmed on death. Over a few rounds this becomes thousands
		-- of stale Vector3s per player.
		wormData.SegmentPositions = {}
		wormData.PositionHistory = {}
		wormData.HistoryStart = 1
		wormData.HistoryEnd = 0
		wormData.LerpingSegments = nil
		wormData.LastRecordedPos = Vector3.zero
	end
end

function WormService:ResetFood()
	local foodFolder = self._foodFolder :: Folder
	for _, food in foodFolder:GetChildren() do
		food:Destroy()
	end
	self._foodCount = 0
	self:_spawnFoodBatch(WormConfig.MaxFoodOnMap)
end

function WormService:GetWormData_Server(player: Player): WormData?
	return self._worms[player]
end

-- Server-side helper used by MarksService (avoids reaching into _ghosts table).
function WormService:IsGhostPlayer(player: Player): boolean
	return self._ghosts[player] ~= nil
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

-- Per-player rate limit for SetDirection — clients politely throttle to 20 Hz
-- (one update per 50 ms), so we accept up to 30 Hz with slack and drop the
-- excess. Without this a malicious or buggy client can flood the server.
local SET_DIRECTION_MIN_INTERVAL = 0.033

function WormService.Client:SetDirection(player: Player, dirX: number, dirZ: number)
	if type(dirX) ~= "number" or type(dirZ) ~= "number" then
		return
	end
	if dirX ~= dirX or dirZ ~= dirZ then
		return -- NaN check
	end

	local now = os.clock()
	local last = self.Server._lastDirSetTime[player] or 0
	if now - last < SET_DIRECTION_MIN_INTERVAL then
		return
	end
	self.Server._lastDirSetTime[player] = now

	local wormData = self.Server._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local dir = Vector3.new(dirX, 0, dirZ)
	if dir.Magnitude > 0 then
		wormData.Direction = dir.Unit
	end
end

function WormService.Client:SetBoosting(player: Player, boosting: boolean)
	if type(boosting) ~= "boolean" then
		return
	end

	local wormData = self.Server._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	wormData.Boosting = boosting
end

function WormService.Client:GetLeaderboard(_player: Player): { { Name: string, Segments: number } }
	local board = {}
	for p, data in self.Server._worms do
		if data.State == "Alive" then
			table.insert(board, { Name = p.Name, Segments = math.floor(data.Segments) })
		end
	end
	-- Include bots in leaderboard
	for botName, botInfo in self.Server._botModels do
		table.insert(board, { Name = botName, Segments = math.floor(botInfo.Segments) })
	end
	table.sort(board, function(a, b)
		return a.Segments > b.Segments
	end)
	return board
end

function WormService.Client:GetWormData(player: Player): { Segments: number, State: string }?
	local wormData = self.Server._worms[player]
	if not wormData then
		return nil
	end
	return { Segments = math.floor(wormData.Segments), State = wormData.State }
end

function WormService.Client:IsGhost(player: Player): boolean
	return self.Server._ghosts[player] ~= nil
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormService:KnitInit()
	self._foodFolder = Instance.new("Folder")
	self._foodFolder.Name = "Food"
	self._foodFolder.Parent = workspace

	self._wormFolder = Instance.new("Folder")
	self._wormFolder.Name = "Worms"
	self._wormFolder.Parent = workspace
end

local function newWormData(color: Color3): WormData
	return {
		State = "Dead" :: WormState,
		Segments = WormConfig.InitialSegments,
		MaxSegments = WormConfig.InitialSegments,
		Direction = Vector3.new(0, 0, -1),
		CurrentDirection = Vector3.new(0, 0, -1),
		Boosting = false,
		Color = color,
		Kills = 0,
		PositionHistory = {},
		HistoryStart = 1,
		HistoryEnd = 0,
		LastRecordedPos = Vector3.zero,
		SpawnTime = 0,
		HeadPosition = Vector3.zero, -- Overwritten on first movement / spawn
		HeadDirection = Vector3.new(0, 0, -1),
		SegmentPositions = {},
		SpawnProtectionUntil = 0, -- Worm King spawn invuln; set in _spawnWorm
	}
end

function WormService:KnitStart()
	PowerUpService = require(script.Parent.PowerUpService)
	ShrinkZoneService = require(script.Parent.ShrinkZoneService)
	TeamService = require(script.Parent.TeamService)
	WeaponService = require(script.Parent.WeaponService)
	LeaderboardService = require(script.Parent.LeaderboardService)
	SandTideService = require(script.Parent.SandTideService)

	-- Cached for spawn-spread checks (avoids requiring BotService here, which
	-- would create a load-order cycle).
	self._botService = require(script.Parent.BotService)

	self:_createArena()
	self:_spawnFoodBatch(WormConfig.MaxFoodOnMap)

	-- Handle players joining
	Players.PlayerAdded:Connect(function(player: Player)
		local trove = Trove.new()
		self._troves[player] = trove

		-- Set up Roblox built-in leaderboard
		local leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player

		local segmentsValue = Instance.new("IntValue")
		segmentsValue.Name = "Segments"
		segmentsValue.Value = WormConfig.InitialSegments
		segmentsValue.Parent = leaderstats

		self._worms[player] = newWormData(self:_randomColor())

		trove:Connect(player.CharacterAdded, function(character: Model)
			task.wait(0.1) -- Let character load
			-- Skip if _spawnWorm already set up this character (prevents double-call)
			if character:FindFirstChild("WormHead") then
				return
			end
			if self._worms[player] and self._worms[player].State == "Alive" then
				self:_setupCharacter(player, character)
			end
		end)

		-- Gate spawn: only spawn if a round is active; otherwise set to Spectating
		if self._roundActive then
			-- Late joiner during round — spectate
			self._worms[player].State = "Spectating"
		end
		-- RoundService controls initial spawning
	end)

	-- Handle players leaving
	Players.PlayerRemoving:Connect(function(player: Player)
		local wormData = self._worms[player]
		if wormData and wormData.State == "Alive" then
			self:_dropFoodFromWorm(player, math.floor(wormData.Segments * 0.5))
		end

		-- Clear ghost and power-ups for the leaving player
		self:DespawnGhost(player)
		PowerUpService:ClearActivePowerUp(player.Name)

		-- Clean up any riders on this player's worm
		local riders = self._ghostRiders[player.Name]
		if riders then
			for ghostPlayer, _ in riders do
				self:KnockoffGhost(ghostPlayer, Vector3.new(0, 1, 0), nil)
			end
			self._ghostRiders[player.Name] = nil
		end

		self._worms[player] = nil
		-- Per-player rate-limit clocks: clear so we don't leak entries
		-- keyed by leaving Players (Roblox keeps strong refs to Player
		-- userdata via the table key).
		self._lastDirSetTime[player] = nil
		self._lastGrappleAttachTime[player] = nil
		self._ghostHP[player] = nil

		local trove = self._troves[player]
		if trove then
			trove:Destroy()
			self._troves[player] = nil
		end
	end)

	-- Existing players (Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			local trove = Trove.new()
			self._troves[player] = trove

			-- Set up Roblox built-in leaderboard
			if not player:FindFirstChild("leaderstats") then
				local leaderstats = Instance.new("Folder")
				leaderstats.Name = "leaderstats"
				leaderstats.Parent = player

				local segmentsValue = Instance.new("IntValue")
				segmentsValue.Name = "Segments"
				segmentsValue.Value = WormConfig.InitialSegments
				segmentsValue.Parent = leaderstats
			end

			self._worms[player] = newWormData(self:_randomColor())

			trove:Connect(player.CharacterAdded, function(character: Model)
				task.wait(0.1)
				if character:FindFirstChild("WormHead") then
					return
				end
				if self._worms[player] and self._worms[player].State == "Alive" then
					self:_setupCharacter(player, character)
				end
			end)

			-- RoundService controls spawning
		end)
	end

	-- Start game loop
	self._gameLoopConnection = RunService.Heartbeat:Connect(function(dt: number)
		self:_gameStep(dt)
	end)
end

return WormService
