--!strict

export type WeaponType = "Blaster" | "RapidFire" | "HighVoltage" | "Grenade" | "PowerShot"

export type WeaponDef = {
	Name: string,
	Damage: number, -- segments removed per hit
	Ammo: number,
	FireRate: number, -- rounds per minute
	Range: number, -- studs
	Knockback: number, -- impulse force on hit
	ProjectileSpeed: number, -- studs per second (for visual only; server raycasts instantly)
	RayRadius: number, -- raycast thickness
	-- Projectile weapons (Grenade, PowerShot)
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
}

local WeaponConfig = {
	Weapons = {
		Blaster = {
			Name = "Blaster",
			Damage = 3,
			Ammo = 12,
			FireRate = 120, -- 2 shots/sec
			Range = 200,
			Knockback = 30,
			ProjectileSpeed = 300,
			RayRadius = 0.5,
		} :: WeaponDef,
		RapidFire = {
			Name = "RapidFire",
			Damage = 1,
			Ammo = 40,
			FireRate = 600, -- 10 shots/sec
			Range = 150,
			Knockback = 10,
			ProjectileSpeed = 400,
			RayRadius = 0.3,
		} :: WeaponDef,
		HighVoltage = {
			Name = "HighVoltage",
			Damage = 8,
			Ammo = 6,
			FireRate = 40, -- 0.67 shots/sec
			Range = 250,
			Knockback = 80,
			ProjectileSpeed = 200,
			RayRadius = 1.0,
		} :: WeaponDef,
		Grenade = {
			Name = "Grenade",
			Damage = 5, -- segments removed per worm in explosion
			Ammo = 4,
			FireRate = 60, -- 1 throw/sec
			Range = 200,
			Knockback = 50,
			ProjectileSpeed = 0, -- not used (physics-based)
			RayRadius = 0,
			IsProjectile = true,
			ExplosionRadius = 15,
			FuseTime = 3,
			MaxBounces = 5,
			BounceDecay = 0.8,
			Gravity = 9.8,
			LaunchForce = 120,
		} :: WeaponDef,
		PowerShot = {
			Name = "PowerShot",
			Damage = 2, -- min damage (used as base; actual scaled by charge)
			Ammo = 3,
			FireRate = 30, -- 0.5 shots/sec
			Range = 300,
			Knockback = 60,
			ProjectileSpeed = 150, -- max speed (min charge)
			RayRadius = 0,
			IsProjectile = true,
			IsChargeable = true,
			ChargeTime = 2, -- seconds to full charge
			MinDamage = 2,
			MaxDamage = 10,
			MinSize = 1,
			MaxSize = 4,
			MinSpeed = 60, -- slower at max charge (heavier)
			MaxSpeed = 150, -- faster at min charge
			MinExplosionRadius = 12,
			MaxExplosionRadius = 20,
		} :: WeaponDef,
	} :: { [string]: WeaponDef },

	WeaponNames = { "Blaster", "RapidFire", "HighVoltage", "Grenade", "PowerShot" } :: { WeaponType },

	-- Tolerance for fire rate checks (seconds)
	FireRateTolerance = 0.05,
}

return WeaponConfig
