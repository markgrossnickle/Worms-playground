--!strict
--
-- TeamBase — equilateral triangle layout for 3-team Worm King mode.
--
-- Three corners of the map, one per team:
--   Team 1 (Red)   -> top      (  0, +R)
--   Team 2 (Blue)  -> bot-left (-R*sin(120), R*cos(120)) = (-R*√3/2, -R/2)
--   Team 3 (Green) -> bot-right( +R*√3/2, -R/2)
--
-- Circumradius R is derived from the arena half-size minus a margin so bases
-- fit inside the boundary walls. `getBasePosition` returns the XZ center.
--
-- Centroid is always (0, 0). Safe-zone radius / spawn-ring radius come from
-- WormConfig.WormKing for tuning without recompiling clients.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local TerrainHeight = require(ReplicatedStorage.Shared.TerrainHeight)

local HALF_ARENA = WormConfig.ArenaSize / 2
local MARGIN = 80 -- studs of space between base center and outer wall

local TeamBase = {}

-- Circumradius of the equilateral triangle inscribed in the arena (corner → centroid)
TeamBase.Circumradius = HALF_ARENA - MARGIN

-- Angle offsets (radians) for each team corner, measured from +Z axis (north), CCW
-- Team 1 sits at the top, then CCW to bottom-left, then bottom-right
local TEAM_ANGLES: { number } = {
	math.rad(90), -- Team 1: +Z (top)
	math.rad(210), -- Team 2: -X / -Z (bottom-left)
	math.rad(330), -- Team 3: +X / -Z (bottom-right)
}

-- Flat XZ position of a team base (Y = 0)
function TeamBase.getBasePositionXZ(teamIndex: number): Vector3
	local angle = TEAM_ANGLES[teamIndex]
	if not angle then
		return Vector3.zero
	end
	-- angle measured CCW from +Z: x = R*cos(angle), z = R*sin(angle)
	-- But we want 90° at +Z, so use standard 2D: x = R*cos(angle), z = R*sin(angle)
	-- with angle=90° => (0, R). ✓
	local r = TeamBase.Circumradius
	local x = math.cos(angle) * r
	local z = math.sin(angle) * r
	return Vector3.new(x, 0, z)
end

-- 3D position of a team base (Y sampled from terrain)
function TeamBase.getBasePosition(teamIndex: number): Vector3
	local flat = TeamBase.getBasePositionXZ(teamIndex)
	local y = TerrainHeight.getSmoothSurfaceY(flat.X, flat.Z)
	return Vector3.new(flat.X, y, flat.Z)
end

-- Is a world XZ position inside this base's safe zone? (uses flat distance)
function TeamBase.isInsideSafeZone(teamIndex: number, worldPos: Vector3): boolean
	local base = TeamBase.getBasePositionXZ(teamIndex)
	local dx = worldPos.X - base.X
	local dz = worldPos.Z - base.Z
	return (dx * dx + dz * dz) <= (WormConfig.WormKing.BaseSafeRadius * WormConfig.WormKing.BaseSafeRadius)
end

-- Pick a spawn position inside a team's base (ring around the base center).
-- `slot` (optional) deterministically picks one of N evenly-spaced points; if nil, random angle.
function TeamBase.getSpawnPosition(teamIndex: number, slot: number?): Vector3
	local base = TeamBase.getBasePositionXZ(teamIndex)
	local ringRadius = WormConfig.WormKing.BaseSpawnRingRadius
	local spawnCount = WormConfig.WormKing.BaseSpawnCount

	local angle: number
	if slot then
		angle = (slot % spawnCount) * (2 * math.pi / spawnCount)
	else
		angle = math.random() * 2 * math.pi
	end

	local x = base.X + math.cos(angle) * ringRadius
	local z = base.Z + math.sin(angle) * ringRadius
	local y = TerrainHeight.getSmoothSurfaceY(x, z) + WormConfig.SegmentSize / 2
	return Vector3.new(x, y, z)
end

-- The centroid (Crown spawn location). Always origin for equilateral triangle.
function TeamBase.getCentroid(): Vector3
	local y = TerrainHeight.getSmoothSurfaceY(0, 0) + WormConfig.WormKing.CrownSpawnHeight
	return Vector3.new(0, y, 0)
end

--------------------------------------------------
-- Sand Tide helpers (Phase 5) — scaled triangle
--
-- `scale` ∈ [SandTideMinScale .. 1.0] shrinks the triangle about the centroid.
-- All the `Scaled*` variants below take a scale factor; passing 1.0 yields the
-- same values as the un-scaled versions.
--------------------------------------------------

-- Flat XZ base position at a given triangle scale (centroid stays at origin).
function TeamBase.getScaledBasePositionXZ(teamIndex: number, scale: number): Vector3
	return TeamBase.getBasePositionXZ(teamIndex) * scale
end

-- Scaled-safe-zone test: base safe radius stays fixed (60 studs) but the base
-- itself has moved with the triangle scale. Use this for sand-tide damage
-- bypass so players standing in their own base don't take tide damage even
-- when the base vertex sits right on the triangle boundary.
function TeamBase.isInsideScaledSafeZone(teamIndex: number, worldPos: Vector3, scale: number): boolean
	local base = TeamBase.getScaledBasePositionXZ(teamIndex, scale)
	local dx = worldPos.X - base.X
	local dz = worldPos.Z - base.Z
	return (dx * dx + dz * dz) <= (WormConfig.WormKing.BaseSafeRadius * WormConfig.WormKing.BaseSafeRadius)
end

-- Spawn point inside a team base ring at the current triangle scale.
-- Mirrors getSpawnPosition but uses the shrunk base position.
function TeamBase.getScaledSpawnPosition(teamIndex: number, scale: number, slot: number?): Vector3
	local base = TeamBase.getScaledBasePositionXZ(teamIndex, scale)
	local ringRadius = WormConfig.WormKing.BaseSpawnRingRadius
	local spawnCount = WormConfig.WormKing.BaseSpawnCount

	local angle: number
	if slot then
		angle = (slot % spawnCount) * (2 * math.pi / spawnCount)
	else
		angle = math.random() * 2 * math.pi
	end

	local x = base.X + math.cos(angle) * ringRadius
	local z = base.Z + math.sin(angle) * ringRadius
	local y = TerrainHeight.getSmoothSurfaceY(x, z) + WormConfig.SegmentSize / 2
	return Vector3.new(x, y, z)
end

-- 3 XZ vertex positions of the scaled triangle (Y=0). Suitable for minimap or
-- in-world boundary rendering.
function TeamBase.getScaledVertices(scale: number): { Vector3 }
	local verts = {}
	for i = 1, 3 do
		table.insert(verts, TeamBase.getScaledBasePositionXZ(i, scale))
	end
	return verts
end

-- Point-in-triangle test for the scaled equilateral triangle centered at origin.
-- Uses the inradius formulation: for each vertex unit direction v_i,
--   dot(P, v_i) ≥ -R/2 where R = Circumradius * scale
-- Returns true iff the XZ point lies inside the (closed) triangle.
function TeamBase.isInsideTriangle(x: number, z: number, scale: number): boolean
	local r = TeamBase.Circumradius * scale
	local halfR = r * 0.5
	for i = 1, 3 do
		local angle = TEAM_ANGLES[i]
		local vx = math.cos(angle)
		local vz = math.sin(angle)
		local d = x * vx + z * vz
		if d < -halfR then
			return false
		end
	end
	return true
end

-- Signed distance from a point to the nearest triangle edge (positive = inside).
-- Useful for gradient damage or proximity warnings.
function TeamBase.distanceToTriangle(x: number, z: number, scale: number): number
	local r = TeamBase.Circumradius * scale
	local halfR = r * 0.5
	local minDist = math.huge
	for i = 1, 3 do
		local angle = TEAM_ANGLES[i]
		local vx = math.cos(angle)
		local vz = math.sin(angle)
		local d = x * vx + z * vz + halfR
		if d < minDist then
			minDist = d
		end
	end
	return minDist
end

return TeamBase
