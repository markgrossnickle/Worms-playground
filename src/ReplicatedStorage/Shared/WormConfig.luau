--!strict

return {
	-- Arena
	ArenaSize = 1200,

	-- Movement
	BaseSpeed = 30,
	BoostSpeed = 60,
	BoostSegmentCostPerSec = 0.5,
	MinBoostSegments = 5,
	TurnRate = 4, -- radians per second (~230 deg/sec)

	-- Segments
	SegmentSpacing = 1.5,
	SegmentSize = 2.5,
	SegmentHP = 3, -- hit points per segment; weapon damage depletes this; destroyed on <= 0
	InitialSegments = 8,

	-- Food
	MaxFoodOnMap = 400,
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
	SpeedScaleFactor = 0.008,

	-- Power-ups
	PowerUpSpawnIntervalMin = 10,
	PowerUpSpawnIntervalMax = 15,
	PowerUpMaxOnMap = 4,
	PowerUpDespawnTime = 20,
	PowerUpTypes = {
		SPEED = { Duration = 3, SpeedMultiplier = 2 },
		MAGNET = { Duration = 10, Range = 25 },
		SPEED_BURST = { Duration = 3, SpeedMultiplier = 3 },
		GHOST = { Duration = 5 },
		SHIELD = { Duration = 0 }, -- one-time save, no duration
		SIZE_BOMB = { Duration = 0, SegmentsAdded = 5 }, -- instant effect
		FREEZE_RING = { Duration = 4, Range = 15, SlowFactor = 0.5 },
	},

	-- Rounds
	RoundScoreboardDuration = 8,
	RoundCountdownDuration = 10,

	-- Shrink zone (legacy BR radial shrink — being replaced by Worm King sand tide)
	ShrinkStartTime = 60, -- seconds after game start before shrinking begins
	ShrinkEndTime = 180, -- seconds after game start when zone fully closes
	ShrinkMinRadius = 40, -- zone stops shrinking at this radius

	-- Teams (Worm King: 3 teams, triangular map)
	TeamModeEnabled = true,
	TeamSize = 8, -- soft cap per team (load-balanced)
	TeamColors = {
		{ Name = "Red", Color = Color3.fromRGB(224, 32, 64) },
		{ Name = "Blue", Color = Color3.fromRGB(32, 128, 224) },
		{ Name = "Green", Color = Color3.fromRGB(48, 192, 64) },
	},

	-- Worm King match configuration
	WormKing = {
		MatchDuration = 480, -- 8 minutes total
		ScoreThreshold = 100, -- first team to this score wins (win-con 1)
		CrownScorePerSec = 1, -- points awarded per second of carrying Crown
		CrownLostResetDelay = 15, -- seconds dropped Crown stays on ground before teleporting back
		CrownSpawnHeight = 4, -- Y offset above terrain for Crown spawn

		-- Sand tide (map contraction) timing
		SandTideStart = 240, -- T+4:00 contraction begins
		SandTideFastPhase = 360, -- T+6:00 fast contraction
		SandTideEnd = 480, -- T+8:00 max contraction
		SandTideMinScale = 0.20, -- triangle contracts to 20% of original size at end
		SandTideDamagePerSec = 5, -- HP/s taken outside the safe triangle
		SandTideRiseRate = 4, -- studs/sec the sand rises outside the triangle

		-- Respawn lockdown (win-con 2 "Elimination" window)
		RespawnLockoutStart = 390, -- T+6:30 — no more Marks respawns after this

		-- Marks economy (ghost earns; respawns as worm)
		RespawnCost = 10,
		Marks = {
			AssistEnemy = 1,
			KillEnemy = 3,
			AssistCarrier = 2,
			KillCarrier = 5,
		},

		-- Team base layout (equilateral triangle inscribed in arena)
		BaseSafeRadius = 60, -- studs of invulnerable base safe zone (stays fixed through shrink)
		BaseFlattenRadius = 60, -- studs of terrain flattening around each base
		BaseSpawnRingRadius = 20, -- spawn points arranged in a ring of this radius
		BaseSpawnCount = 8, -- number of spawn points per base
		SpawnProtectionDuration = 2, -- seconds of invulnerability after spawn
	},

	-- Ghost mode
	Ghost = {
		WalkSpeed = 24,
		JumpPower = 30,
		AvatarScale = 0.5,
		Transparency = 0.45,
		RiderSpeedBoostPerGhost = 0.15, -- +15% worm speed per riding ghost
		MaxRiderSpeedBoost = 2.0, -- cap at 2x total from riders
		KnockoffStunDuration = 1.5, -- seconds ghost is stunned after being shot off
		KnockbackForce = 50,
		GlowBrightness = 1.5,
		GlowRange = 12,
		EatValue = 3, -- segments gained by worm eating a ghost
		RespawnDelay = 5, -- seconds before eaten ghost respawns
	},

	-- Grapple (ground pull for worm movement)
	Grapple = {
		Range = 80,
		PullSpeed = 100,
		PullDuration = 0.6,
		Cooldown = 2,
	},
}
