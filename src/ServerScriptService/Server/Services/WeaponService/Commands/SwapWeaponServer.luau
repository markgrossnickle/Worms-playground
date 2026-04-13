--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

return function(context, weaponType: string)
	local player = context.Executor

	-- Case-insensitive match against known weapon names
	local match: string? = nil
	local lower = string.lower(weaponType)
	for _, name in WeaponConfig.WeaponNames do
		if string.lower(name) == lower then
			match = name
			break
		end
	end

	if not match then
		return "Unknown weapon '"
			.. weaponType
			.. "'. Valid: Blaster, RapidFire, HighVoltage, Grenade, PowerShot, Cluster, Mine"
	end

	local WeaponService = Knit.GetService("WeaponService")
	WeaponService:AssignWeapon(player, match)
	return "Weapon swapped to " .. match
end
