--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

type WeaponType = WeaponConfig.WeaponType

local FIRE_RATE_TOLERANCE = WeaponConfig.FireRateTolerance

local WormService -- Set in KnitStart

local WeaponService = Knit.CreateService({
	Name = "WeaponService",
	Client = {
		WeaponAssigned = Knit.CreateSignal(), -- (weaponType, ammo)
		AmmoChanged = Knit.CreateSignal(), -- (ammo)
		ShotReplicated = Knit.CreateUnreliableSignal(), -- (origin, direction, hitPos, hitPlayer?)
		HitConfirmed = Knit.CreateSignal(), -- (targetName, damage)
	},

	-- Server-side signals
	WeaponHit = Signal.new(), -- (shooter: Player, targetPlayer: Player, damage: number)

	_weapons = {} :: { [Player]: { Type: WeaponType, Ammo: number } },
	_lastShotTimestamps = {} :: { [Player]: number },
})

--------------------------------------------------
-- Weapon assignment
--------------------------------------------------

function WeaponService:AssignRandomWeapon(player: Player)
	local names = WeaponConfig.WeaponNames
	local weaponType = names[math.random(1, #names)]
	local weaponDef = WeaponConfig.Weapons[weaponType]

	self._weapons[player] = {
		Type = weaponType,
		Ammo = weaponDef.Ammo,
	}
	self._lastShotTimestamps[player] = 0

	self.Client.WeaponAssigned:Fire(player, weaponType, weaponDef.Ammo)
end

function WeaponService:ClearWeapon(player: Player)
	self._weapons[player] = nil
	self._lastShotTimestamps[player] = nil
end

function WeaponService:GetWeaponData(player: Player): { Type: WeaponType, Ammo: number }?
	return self._weapons[player]
end

--------------------------------------------------
-- Shooting (server-authoritative)
--------------------------------------------------

function WeaponService:_validateShoot(player: Player, origin: Vector3, direction: Vector3): boolean
	-- Must have a weapon
	local weaponData = self._weapons[player]
	if not weaponData then
		return false
	end

	-- Must have ammo
	if weaponData.Ammo <= 0 then
		return false
	end

	-- Must be a ghost
	local wormData = WormService:GetWormData_Server(player)
	if wormData and wormData.State == "Alive" then
		return false -- alive worms can't shoot
	end

	-- Must have a character (ghost model)
	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end

	-- Origin sanity: must be near the ghost's actual position
	local dist = (origin - hrp.Position).Magnitude
	if dist > 20 then
		warn("WeaponService: Origin too far from ghost position for", player.Name)
		return false
	end

	-- Direction must be valid
	if direction.Magnitude < 0.1 then
		return false
	end

	-- Fire rate check
	local weaponDef = WeaponConfig.Weapons[weaponData.Type]
	local minInterval = 60 / weaponDef.FireRate
	local now = Workspace:GetServerTimeNow()
	local lastShot = self._lastShotTimestamps[player] or 0
	if (now - lastShot) < (minInterval - FIRE_RATE_TOLERANCE) then
		warn("WeaponService: Fire rate exceeded for", player.Name)
		return false
	end

	return true
end

function WeaponService:_onShoot(player: Player, origin: Vector3, direction: Vector3)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end

	if not self:_validateShoot(player, origin, direction) then
		return
	end

	local weaponData = self._weapons[player]
	local weaponDef = WeaponConfig.Weapons[weaponData.Type]

	-- Consume ammo
	weaponData.Ammo -= 1
	self._lastShotTimestamps[player] = Workspace:GetServerTimeNow()
	self.Client.AmmoChanged:Fire(player, weaponData.Ammo)

	-- Server raycast
	local dir = direction.Unit
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- Exclude the shooter's ghost model and all food (other ghosts are hittable)
	local excludeList = {}
	if player.Character then
		table.insert(excludeList, player.Character)
	end
	local foodFolder = Workspace:FindFirstChild("Food")
	if foodFolder then
		table.insert(excludeList, foodFolder)
	end
	rayParams.FilterDescendantsInstances = excludeList

	local rayResult = Workspace:Raycast(origin, dir * weaponDef.Range, rayParams)

	local hitPos = if rayResult then rayResult.Position else origin + dir * weaponDef.Range
	local hitPlayerName: string? = nil

	-- Check if we hit a worm segment or head
	if rayResult and rayResult.Instance then
		local hitPart = rayResult.Instance
		local hitModel = hitPart:FindFirstAncestorOfClass("Model")

		if hitModel then
			-- Check if it's a player worm
			local hitPlayer = Players:GetPlayerFromCharacter(hitModel)
			if hitPlayer and hitPlayer ~= player then
				local targetWormData = WormService:GetWormData_Server(hitPlayer)
				if targetWormData and targetWormData.State == "Alive" then
					hitPlayerName = hitPlayer.Name
					-- Extract which segment was hit for hit-point damage
					local hitSegmentIndex: number? = nil
					if string.sub(hitPart.Name, 1, 7) == "Segment" then
						hitSegmentIndex = tonumber(string.sub(hitPart.Name, 8))
					end
					WormService:DamageWorm(
						hitPlayer,
						weaponDef.Damage,
						player,
						dir * weaponDef.Knockback,
						hitSegmentIndex
					)
					self.Client.HitConfirmed:Fire(player, hitPlayer.Name, weaponDef.Damage)
					self.WeaponHit:Fire(player, hitPlayer, weaponDef.Damage)
				end
			else
				-- Check if it's a bot worm (model in workspace with WormSegments)
				local segFolder = hitModel:FindFirstChild("WormSegments")
				local wormHead = hitModel:FindFirstChild("WormHead")
				if segFolder or wormHead then
					hitPlayerName = hitModel.Name
					-- Bot damage is handled differently — just report the hit
					-- BotService can listen to WeaponHit signal if needed
				end
			end

			-- Check if we hit another ghost
			if not hitPlayerName and hitModel:GetAttribute("IsGhost") then
				local ghostOwnerName = hitModel:GetAttribute("GhostOwner")
				if ghostOwnerName and ghostOwnerName ~= player.Name then
					hitPlayerName = ghostOwnerName .. " (ghost)"

					-- Find the ghost owner player
					local ghostOwner: Player? = nil
					for _, p in Players:GetPlayers() do
						if p.Name == ghostOwnerName then
							ghostOwner = p
							break
						end
					end

					if ghostOwner then
						-- Check if ghost is riding a worm
						local isRiding = false
						for _, riders in WormService._ghostRiders do
							if riders[ghostOwner] then
								isRiding = true
								break
							end
						end

						if isRiding then
							-- Knock ghost off the worm
							WormService:KnockoffGhost(ghostOwner, dir, player)
						else
							-- Free-roaming ghost: just apply knockback
							local ghostHrp = hitModel:FindFirstChild("HumanoidRootPart") :: BasePart?
							if ghostHrp then
								ghostHrp:ApplyImpulse(dir * weaponDef.Knockback * 0.5)
							end
						end

						self.Client.HitConfirmed:Fire(player, ghostOwnerName, 0)
					end
				end
			end
		end
	end

	-- Replicate shot to all players for visuals
	self.Client.ShotReplicated:FireAll(player.Name, origin, hitPos, hitPlayerName)
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function WeaponService.Client:Shoot(player: Player, origin: Vector3, direction: Vector3)
	self.Server:_onShoot(player, origin, direction)
end

function WeaponService.Client:GetWeaponData(player: Player): { Type: string, Ammo: number }?
	return self.Server:GetWeaponData(player)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WeaponService:KnitInit()
	Players.PlayerRemoving:Connect(function(player: Player)
		self._weapons[player] = nil
		self._lastShotTimestamps[player] = nil
	end)
end

function WeaponService:KnitStart()
	WormService = require(script.Parent.WormService)
end

return WeaponService
