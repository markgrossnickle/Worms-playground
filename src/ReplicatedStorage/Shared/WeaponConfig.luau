--!strict

export type WeaponType = "Blaster" | "RapidFire" | "HighVoltage" | "Grenade" | "PowerShot" | "Cluster" | "Mine"

export type WeaponDef = {
	Name: string,
	Damage: number, -- HP damage per hit (segments have HP from WormConfig.SegmentHP)
	Ammo: number,
	ReloadTime: number, -- seconds to reload full magazine
	FireRate: number, -- rounds per minute
	Range: number, -- studs
	Knockback: number, -- impulse force on hit
	ProjectileSpeed: number, -- studs per second (for visual only; server raycasts instantly)
	RayRadius: number, -- raycast thickness
	-- Hitscan modifiers
	Pierce: number?, -- max additional segments a single shot can damage after the first hit
	-- Projectile weapons (Grenade, PowerShot, Cluster, Mine)
	IsProjectile: boolean?,
	ExplosionRadius: number?,
	FuseTime: number?,
	MaxBounces: number?,
	BounceDecay: number?,
	Gravity: number?,
	LaunchForce: number?,
	-- PowerShot charge
	IsChargeable: boolean?,
	ChargeTime: number?,
	MinDamage: number?,
	MaxDamage: number?,
	MinSize: number?,
	MaxSize: number?,
	MinSpeed: number?,
	MaxSpeed: number?,
	MinExplosionRadius: number?,
	MaxExplosionRadius: number?,
	-- Cluster bomblets
	BombletCount: number?,
	BombletSpread: number?, -- horizontal spread angle (radians) when splitting
	BombletDamage: number?,
	BombletExplosionRadius: number?,
	BombletFuse: number?,
	-- Mine
	IsMine: boolean?,
	ArmTime: number?, -- seconds before mine becomes active
	TriggerRadius: number?, -- proximity radius that detonates the mine
	MineLifetime: number?, -- max seconds before mine self-destructs
}

local WeaponConfig = {
	Weapons = {
		-- Balance: segments now have HP (default 3). Damage values below are per-hit
		-- HP damage, not segment-removal counts.
		Blaster = {
			Name = "Blaster",
			Damage = 3, -- 1 segment per shot (3 HP)
			Ammo = 10,
			ReloadTime = 1.6,
			FireRate = 120, -- 2 shots/sec — reliable single-target
			Range = 200,
			Knockback = 30,
			ProjectileSpeed = 300,
			RayRadius = 0.5,
		} :: WeaponDef,
		RapidFire = {
			Name = "RapidFire",
			Damage = 1, -- chip damage; needs 3 hits per segment
			Ammo = 24,
			ReloadTime = 3.0,
			FireRate = 420, -- 7 shots/sec
			Range = 45, -- close-quarters only (was 90)
			Knockback = 4,
			ProjectileSpeed = 400,
			RayRadius = 0.3,
		} :: WeaponDef,
		HighVoltage = {
			Name = "HighVoltage",
			Damage = 5, -- 1 segment + chip (5 - 3 = 2 HP bleed)
			Ammo = 5,
			ReloadTime = 2.8,
			FireRate = 40, -- 0.67 shots/sec
			Range = 250,
			Knockback = 0, -- no knockback — pierce-focused
			ProjectileSpeed = 200,
			RayRadius = 1.0,
			Pierce = 3, -- shot continues through up to 3 additional segments after the first
		} :: WeaponDef,
		Grenade = {
			Name = "Grenade",
			Damage = 4, -- per-segment base damage; explosion compounds across segments in radius
			Ammo = 3,
			ReloadTime = 3.2,
			FireRate = 60, -- 1 throw/sec
			Range = 200,
			Knockback = 50,
			ProjectileSpeed = 0, -- not used (physics-based)
			RayRadius = 0,
			IsProjectile = true,
			ExplosionRadius = 12,
			FuseTime = 3,
			MaxBounces = 5,
			BounceDecay = 0.8,
			Gravity = 9.8,
			LaunchForce = 50,
		} :: WeaponDef,
		PowerShot = {
			Name = "PowerShot",
			Damage = 3, -- min damage (used as base; actual scaled by charge)
			Ammo = 3,
			ReloadTime = 3.2,
			FireRate = 30, -- 0.5 shots/sec
			Range = 300,
			Knockback = 60,
			ProjectileSpeed = 150, -- max speed (min charge)
			RayRadius = 0,
			IsProjectile = true,
			IsChargeable = true,
			ChargeTime = 2, -- seconds to full charge
			MinDamage = 3,
			MaxDamage = 15, -- 5 segments at full charge
			MinSize = 1,
			MaxSize = 4,
			MinSpeed = 60, -- slower at max charge (heavier)
			MaxSpeed = 150, -- faster at min charge
			MinExplosionRadius = 12,
			MaxExplosionRadius = 20,
		} :: WeaponDef,
		Cluster = {
			Name = "Cluster",
			Damage = 3, -- per-bomblet base damage; total spray hits hard
			Ammo = 2,
			ReloadTime = 3.5,
			FireRate = 30, -- 0.5 shots/sec
			Range = 200,
			Knockback = 30,
			ProjectileSpeed = 0,
			RayRadius = 0,
			IsProjectile = true,
			ExplosionRadius = 0, -- the carrier shell does not explode itself
			FuseTime = 4,
			MaxBounces = 0,
			BounceDecay = 0,
			Gravity = 9.8,
			LaunchForce = 75, -- arcs up high before splitting
			BombletCount = 5,
			BombletSpread = 0.6, -- ~34° cone of bomblets
			BombletDamage = 3,
			BombletExplosionRadius = 8,
			BombletFuse = 0.9,
		} :: WeaponDef,
		Mine = {
			Name = "Mine",
			Damage = 6, -- big chunk on detonation
			Ammo = 2,
			ReloadTime = 3.5,
			FireRate = 60, -- 1 deploy/sec
			Range = 30, -- short toss
			Knockback = 60,
			ProjectileSpeed = 0,
			RayRadius = 0,
			IsProjectile = true,
			IsMine = true,
			ExplosionRadius = 13,
			Gravity = 9.8,
			LaunchForce = 25, -- short underhand toss
			ArmTime = 0.6,
			TriggerRadius = 5,
			MineLifetime = 30,
		} :: WeaponDef,
	} :: { [string]: WeaponDef },

	WeaponNames = {
		"Blaster",
		"RapidFire",
		"HighVoltage",
		"Grenade",
		"PowerShot",
		"Cluster",
		"Mine",
	} :: { WeaponType },

	-- Tolerance for fire rate checks (seconds)
	FireRateTolerance = 0.05,
}

return WeaponConfig
