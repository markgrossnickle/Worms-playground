--!strict
-- Shared deterministic terrain height function for desert rolling hills.
-- Both server and client use this to position entities on the terrain surface.

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

return {
	getHeight = getHeight,
}
