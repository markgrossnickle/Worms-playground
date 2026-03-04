--!strict

return {
	-- Arena
	ArenaSize = 2000,

	-- Movement
	BaseSpeed = 30,
	BoostSpeed = 60,
	BoostSegmentCostPerSec = 0.5,
	MinBoostSegments = 5,

	-- Segments
	SegmentSpacing = 3,
	SegmentSize = 2.5,
	InitialSegments = 3,

	-- Food
	MaxFoodOnMap = 800,
	FoodValue = 1,
	FoodTiers = {
		{ Weight = 60, Size = 1.2, Value = 1 },
		{ Weight = 30, Size = 2.0, Value = 2 },
		{ Weight = 10, Size = 3.0, Value = 4 },
	},

	-- Food magnet
	PassiveMagnetRange = 8,
	PassiveMagnetPull = 1,
	PowerUpMagnetPull = 3,

	-- Gameplay
	RespawnDelay = 3,
	CollisionRadius = 2,

	-- Power-ups
	PowerUpSpawnIntervalMin = 10,
	PowerUpSpawnIntervalMax = 15,
	PowerUpMaxOnMap = 4,
	PowerUpDespawnTime = 20,
	PowerUpTypes = {
		SPEED = { Duration = 3, SpeedMultiplier = 2 },
		MAGNET = { Duration = 10, Range = 25 },
		GHOST = { Duration = 3 },
		SHIELD = { Duration = 0 }, -- one-time save, no duration
		SIZE_BOMB = { Duration = 0, SegmentsAdded = 5 }, -- instant effect
	},

	-- Shrink zone (battle royale)
	ShrinkStartTime = 60, -- seconds after game start before shrinking begins
	ShrinkEndTime = 180, -- seconds after game start when zone fully closes
	-- Teams
	TeamModeEnabled = false,
	TeamSize = 2,
	TeamColors = {
		{ Name = "Red", Color = Color3.fromRGB(255, 60, 60) },
		{ Name = "Blue", Color = Color3.fromRGB(60, 100, 255) },
		{ Name = "Green", Color = Color3.fromRGB(60, 220, 60) },
		{ Name = "Yellow", Color = Color3.fromRGB(255, 220, 50) },
	},
}
