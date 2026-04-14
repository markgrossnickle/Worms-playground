--!strict
-- Shared deterministic terrain height function for desert rolling hills.
-- Both server and client use this to position entities on the terrain surface.

-- Must match the step size used in WormService:_createArena() FillBlock loop
local GRID_STEP = 8
-- Terrain voxels are 4 studs; FillBlock can round up by half a voxel
local VOXEL_PAD = 2

local function getHeight(x: number, z: number): number
	-- Primary large dunes (long wavelength, gentle amplitude)
	local h = math.noise(x * 0.003, z * 0.003) * 14
	-- Secondary medium ripples for variation
	h += math.noise(x * 0.008 + 50, z * 0.008 + 50) * 5
	-- Small wind-blown ripple detail
	h += math.noise(x * 0.02 + 100, z * 0.02 + 100) * 1.5
	-- Base offset so everything stays above Y=0
	return math.max(h + 10, 0.5)
end

-- Returns the Y position of the terrain surface at (x, z), accounting for
-- the 8-stud FillBlock grid and voxel quantisation. Place object centres at
-- getSurfaceY(x, z) + objectRadius to sit ON the surface.
local function getSurfaceY(x: number, z: number): number
	-- The terrain is filled in GRID_STEP-wide blocks.  At any (x, z) the
	-- actual surface is the top of whichever neighbouring block is tallest.
	-- Check the four grid cells whose blocks could cover this point.
	local gx0 = math.floor(x / GRID_STEP) * GRID_STEP
	local gz0 = math.floor(z / GRID_STEP) * GRID_STEP
	local maxBlockTop = 0
	for _, dx in { 0, GRID_STEP } do
		for _, dz in { 0, GRID_STEP } do
			local h = getHeight(gx0 + dx, gz0 + dz)
			-- FillBlock CFrame.new(_, h/2, _), Size(_, h+2, _) → top = h + 1
			local blockTop = h + 1
			if blockTop > maxBlockTop then
				maxBlockTop = blockTop
			end
		end
	end
	return maxBlockTop + VOXEL_PAD
end

-- Smoothly interpolated surface Y using bilinear interpolation of block tops.
-- Use for worm/bot head positioning to avoid stair-stepping on slopes.
-- The bilinear result can dip below the actual discrete terrain at steep
-- slopes (up to ~3 studs below a tall neighbour's block). An extra pad of 3
-- studs keeps the entity above terrain while remaining visually smooth.
local SMOOTH_EXTRA_PAD = 3
local function getSmoothSurfaceY(x: number, z: number): number
	local gx0 = math.floor(x / GRID_STEP) * GRID_STEP
	local gz0 = math.floor(z / GRID_STEP) * GRID_STEP
	local tx = (x - gx0) / GRID_STEP
	local tz = (z - gz0) / GRID_STEP
	local h00 = getHeight(gx0, gz0) + 1
	local h10 = getHeight(gx0 + GRID_STEP, gz0) + 1
	local h01 = getHeight(gx0, gz0 + GRID_STEP) + 1
	local h11 = getHeight(gx0 + GRID_STEP, gz0 + GRID_STEP) + 1
	local top = h00 * (1 - tx) * (1 - tz) + h10 * tx * (1 - tz) + h01 * (1 - tx) * tz + h11 * tx * tz
	return top + SMOOTH_EXTRA_PAD
end

return {
	getHeight = getHeight,
	getSurfaceY = getSurfaceY,
	getSmoothSurfaceY = getSmoothSurfaceY,
}
