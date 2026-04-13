--!strict

return {
	Name = "swap-weapon",
	Aliases = { "give-weapon", "weapon" },
	Description = "Swap your current ghost weapon for the named weapon",
	Group = "group",
	Args = {
		{
			Type = "string",
			Name = "weaponType",
			Description = "Blaster | RapidFire | HighVoltage | Grenade | PowerShot | Cluster | Mine",
		},
	},
}
