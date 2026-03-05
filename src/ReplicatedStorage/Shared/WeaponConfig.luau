--!strict

export type WeaponType = "Blaster" | "RapidFire" | "HighVoltage"

export type WeaponDef = {
	Name: string,
	Damage: number, -- segments removed per hit
	Ammo: number,
	FireRate: number, -- rounds per minute
	Range: number, -- studs
	Knockback: number, -- impulse force on hit
	ProjectileSpeed: number, -- studs per second (for visual only; server raycasts instantly)
	RayRadius: number, -- raycast thickness
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
	} :: { [string]: WeaponDef },

	WeaponNames = { "Blaster", "RapidFire", "HighVoltage" } :: { WeaponType },

	-- Tolerance for fire rate checks (seconds)
	FireRateTolerance = 0.05,
}

return WeaponConfig
