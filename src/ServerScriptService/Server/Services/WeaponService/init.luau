--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

type WeaponType = WeaponConfig.WeaponType

local FIRE_RATE_TOLERANCE = WeaponConfig.FireRateTolerance

local WormService -- Set in KnitStart
local TeamService -- Set in KnitStart
local BotService -- Set in KnitStart

type ProjectileData = {
	Id: number,
	Player: Player,
	WeaponType: string,
	Position: Vector3,
	Velocity: Vector3,
	Origin: Vector3,
	Time: number,
	TotalTime: number,
	Bounces: number,
	Stopped: boolean,
	Damage: number,
	ExplosionRadius: number,
	Instance: Part?,
	-- PowerShot-specific
	ChargeAlpha: number?,
}

local HALF_ARENA = WormConfig.ArenaSize / 2
local PICKUP_SPAWN_MIN = 10
local PICKUP_SPAWN_MAX = 15
local PICKUP_MAX_ON_MAP = 10
local PICKUP_DESPAWN_TIME = 30
local PICKUP_COLLECT_RADIUS = 6

type WeaponPickup = {
	Id: number,
	WeaponType: string,
	Position: Vector3,
	SpawnTime: number,
}

local WEAPON_PICKUP_COLORS: { [string]: { number } } = {
	Blaster = { 50, 180, 255 },
	RapidFire = { 255, 220, 50 },
	HighVoltage = { 180, 50, 255 },
	Grenade = { 236, 140, 70 },
	PowerShot = { 255, 80, 30 },
}

local WeaponService = Knit.CreateService({
	Name = "WeaponService",
	Client = {
		WeaponAssigned = Knit.CreateSignal(), -- (weaponType, ammo)
		AmmoChanged = Knit.CreateSignal(), -- (ammo)
		ShotReplicated = Knit.CreateUnreliableSignal(), -- (origin, direction, hitPos, hitPlayer?)
		HitConfirmed = Knit.CreateSignal(), -- (targetName, damage)
		ProjectileSpawned = Knit.CreateSignal(), -- (projId, weaponType, position, velocity, size)
		ProjectileExploded = Knit.CreateSignal(), -- (projId, position, radius)
		ChargeStarted = Knit.CreateSignal(), -- () — tells client charge began
		WeaponPickupSpawned = Knit.CreateSignal(), -- (id, weaponType, position, color)
		WeaponPickupCollected = Knit.CreateSignal(), -- (id)
		WeaponPickupDespawned = Knit.CreateSignal(), -- (id)
	},

	-- Server-side signals
	WeaponHit = Signal.new(), -- (shooter: Player, targetPlayer: Player, damage: number)

	_weapons = {} :: { [Player]: { Type: WeaponType, Ammo: number } },
	_lastShotTimestamps = {} :: { [Player]: number },
	_projectiles = {} :: { [number]: ProjectileData },
	_nextProjectileId = 1,
	_chargeStarts = {} :: { [Player]: number }, -- os.clock() when charge began

	-- Weapon pickups
	_pickups = {} :: { [number]: WeaponPickup },
	_nextPickupId = 1,
	_lastPickupSpawn = 0,
	_nextPickupInterval = 0,
})

--------------------------------------------------
-- Weapon assignment
--------------------------------------------------

function WeaponService:AssignRandomWeapon(player: Player)
	local names = WeaponConfig.WeaponNames
	local weaponType = names[math.random(1, #names)]
	local weaponDef = WeaponConfig.Weapons[weaponType]

	local isNewGhost = self._weapons[player] == nil
	self._weapons[player] = {
		Type = weaponType,
		Ammo = weaponDef.Ammo,
	}
	self._lastShotTimestamps[player] = 0

	self.Client.WeaponAssigned:Fire(player, weaponType, weaponDef.Ammo)

	-- Send existing pickups to newly spawned ghost
	if isNewGhost then
		self:_sendExistingPickups(player)
	end
end

function WeaponService:AssignWeapon(player: Player, weaponType: WeaponType)
	local weaponDef = WeaponConfig.Weapons[weaponType]
	if not weaponDef then
		return
	end

	local isNewGhost = self._weapons[player] == nil
	self._weapons[player] = {
		Type = weaponType,
		Ammo = weaponDef.Ammo,
	}
	self._lastShotTimestamps[player] = 0

	self.Client.WeaponAssigned:Fire(player, weaponType, weaponDef.Ammo)

	if isNewGhost then
		self:_sendExistingPickups(player)
	end
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
				-- Skip friendly fire — teammates can't damage each other
				if not TeamService:AreTeammates(player.Name, hitPlayer.Name) then
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
				end
			else
				-- Check if it's a bot worm (model in workspace with WormSegments)
				local segFolder = hitModel:FindFirstChild("WormSegments")
				local wormHead = hitModel:FindFirstChild("WormHead")
				if (segFolder or wormHead) and not TeamService:AreTeammates(player.Name, hitModel.Name) then
					hitPlayerName = hitModel.Name
					BotService:DamageBot(hitModel.Name, weaponDef.Damage, player.Name)
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
-- Projectile system (Grenade + PowerShot)
--------------------------------------------------

function WeaponService:_validateProjectileShoot(player: Player, origin: Vector3, direction: Vector3): boolean
	local weaponData = self._weapons[player]
	if not weaponData then
		return false
	end
	if weaponData.Ammo <= 0 then
		return false
	end

	local wormData = WormService:GetWormData_Server(player)
	if wormData and wormData.State == "Alive" then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end

	if (origin - hrp.Position).Magnitude > 20 then
		return false
	end
	if direction.Magnitude < 0.1 then
		return false
	end

	local weaponDef = WeaponConfig.Weapons[weaponData.Type]
	local minInterval = 60 / weaponDef.FireRate
	local now = Workspace:GetServerTimeNow()
	local lastShot = self._lastShotTimestamps[player] or 0
	if (now - lastShot) < (minInterval - FIRE_RATE_TOLERANCE) then
		return false
	end

	return true
end

function WeaponService:_spawnGrenade(player: Player, origin: Vector3, direction: Vector3)
	local weaponData = self._weapons[player]
	local weaponDef = WeaponConfig.Weapons[weaponData.Type]

	weaponData.Ammo -= 1
	self._lastShotTimestamps[player] = Workspace:GetServerTimeNow()
	self.Client.AmmoChanged:Fire(player, weaponData.Ammo)

	local dir = direction.Unit
	-- Gentle lob: mostly forward with a small upward arc
	local velocity = dir * weaponDef.LaunchForce + Vector3.new(0, weaponDef.LaunchForce * 0.1, 0)

	local projId = self._nextProjectileId
	self._nextProjectileId += 1

	-- Create visual grenade part
	local grenade = Instance.new("Part")
	grenade.Name = "Grenade_" .. projId
	grenade.Shape = Enum.PartType.Ball
	grenade.Size = Vector3.new(1, 1, 1)
	grenade.Color = Color3.fromRGB(236, 140, 70)
	grenade.Material = Enum.Material.Rock
	grenade.Anchored = true
	grenade.CanCollide = false
	grenade.CanQuery = false
	grenade.Position = origin
	grenade.Parent = workspace

	local projData: ProjectileData = {
		Id = projId,
		Player = player,
		WeaponType = "Grenade",
		Position = origin,
		Velocity = velocity,
		Origin = origin,
		Time = 0,
		TotalTime = 0,
		Bounces = 0,
		Stopped = false,
		Damage = weaponDef.Damage,
		ExplosionRadius = weaponDef.ExplosionRadius :: number,
		Instance = grenade,
	}

	self._projectiles[projId] = projData

	self.Client.ProjectileSpawned:FireAll(projId, "Grenade", origin, velocity, 1)
end

function WeaponService:_spawnPowerShot(player: Player, origin: Vector3, direction: Vector3, chargeAlpha: number)
	local weaponData = self._weapons[player]
	local weaponDef = WeaponConfig.Weapons[weaponData.Type]

	weaponData.Ammo -= 1
	self._lastShotTimestamps[player] = Workspace:GetServerTimeNow()
	self.Client.AmmoChanged:Fire(player, weaponData.Ammo)

	local alpha = math.clamp(chargeAlpha, 0, 1)
	local dir = direction.Unit

	local damage = math.floor(weaponDef.MinDamage + (weaponDef.MaxDamage - weaponDef.MinDamage) * alpha)
	local size = weaponDef.MinSize + (weaponDef.MaxSize - weaponDef.MinSize) * alpha
	local speed = weaponDef.MaxSpeed + (weaponDef.MinSpeed - weaponDef.MaxSpeed) * alpha
	local explosionRadius = weaponDef.MinExplosionRadius
		+ (weaponDef.MaxExplosionRadius - weaponDef.MinExplosionRadius) * alpha

	local velocity = dir * speed

	local projId = self._nextProjectileId
	self._nextProjectileId += 1

	local shot = Instance.new("Part")
	shot.Name = "PowerShot_" .. projId
	shot.Shape = Enum.PartType.Ball
	shot.Size = Vector3.new(size, size, size)
	shot.Color = Color3.fromRGB(255, 100, 30)
	shot.Material = Enum.Material.Neon
	shot.Anchored = true
	shot.CanCollide = false
	shot.CanQuery = false
	shot.Position = origin
	shot.Parent = workspace

	-- Fire trail
	local fire = Instance.new("Fire")
	fire.Size = size * 2
	fire.Heat = 5
	fire.Color = Color3.fromRGB(255, 140, 0)
	fire.SecondaryColor = Color3.fromRGB(255, 60, 0)
	fire.Parent = shot

	local projData: ProjectileData = {
		Id = projId,
		Player = player,
		WeaponType = "PowerShot",
		Position = origin,
		Velocity = velocity,
		Origin = origin,
		Time = 0,
		TotalTime = 0,
		Bounces = 0,
		Stopped = false,
		Damage = damage,
		ExplosionRadius = explosionRadius,
		Instance = shot,
		ChargeAlpha = alpha,
	}

	self._projectiles[projId] = projData

	self.Client.ProjectileSpawned:FireAll(projId, "PowerShot", origin, velocity, size)
end

function WeaponService:_explodeProjectile(projData: ProjectileData)
	local pos = projData.Position
	local radius = projData.ExplosionRadius
	local damage = projData.Damage
	local shooter = projData.Player

	-- Destroy visual
	if projData.Instance then
		projData.Instance:Destroy()
		projData.Instance = nil
	end

	-- Notify clients
	self.Client.ProjectileExploded:FireAll(projData.Id, pos, radius)

	-- Damage all enemy worms in radius
	-- Check player worms
	for player, wormData in WormService._worms do
		if wormData.State ~= "Alive" then
			continue
		end
		if TeamService:AreTeammates(shooter.Name, player.Name) then
			continue
		end

		local char = player.Character
		if not char then
			continue
		end
		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		if (hrp.Position - pos).Magnitude <= radius then
			local dir = (hrp.Position - pos)
			local knockback = if dir.Magnitude > 0.1 then dir.Unit * 40 else Vector3.zero
			WormService:DamageWorm(player, damage, shooter, knockback)
			self.Client.HitConfirmed:Fire(shooter, player.Name, damage)
		end
	end

	-- Check bot worms
	for botName, botInfo in WormService._botModels do
		if TeamService:AreTeammates(shooter.Name, botName) then
			continue
		end
		local botHrp = botInfo.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not botHrp then
			continue
		end
		if (botHrp.Position - pos).Magnitude <= radius then
			-- Bot segment damage: use BotService internal method
			BotService:DamageBot(botName, damage, shooter.Name)
		end
	end

	-- Remove from tracking
	self._projectiles[projData.Id] = nil
end

function WeaponService:_updateProjectiles(dt: number)
	for id, projData in self._projectiles do
		if not projData.Instance then
			self._projectiles[id] = nil
			continue
		end

		projData.Time += dt
		projData.TotalTime += dt

		if projData.WeaponType == "Grenade" then
			self:_updateGrenade(projData, dt)
		elseif projData.WeaponType == "PowerShot" then
			self:_updatePowerShot(projData, dt)
		end
	end
end

function WeaponService:_updateGrenade(projData: ProjectileData, dt: number)
	local weaponDef = WeaponConfig.Weapons.Grenade

	if not projData.Stopped then
		-- Apply gravity
		projData.Velocity = projData.Velocity + Vector3.new(0, -(weaponDef.Gravity :: number) * dt, 0)
		local newPos = projData.Position + projData.Velocity * dt

		-- Raycast for bounce
		local rayDir = newPos - projData.Position
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		local excludeList = {}
		if projData.Player.Character then
			table.insert(excludeList, projData.Player.Character)
		end
		local foodFolder = Workspace:FindFirstChild("Food")
		if foodFolder then
			table.insert(excludeList, foodFolder)
		end
		-- Exclude ghost models
		for otherPlayer, _ in self._weapons do
			if otherPlayer.Character then
				table.insert(excludeList, otherPlayer.Character)
			end
		end
		-- Exclude other projectiles (they have CanQuery=false already)
		rayParams.FilterDescendantsInstances = excludeList

		local rayResult = Workspace:Raycast(projData.Position, rayDir, rayParams)

		if rayResult then
			local hitPart = rayResult.Instance
			local hitModel = hitPart:FindFirstAncestorOfClass("Model")

			-- Check worm hit — explode immediately
			local hitWorm = false
			if hitModel then
				local hitPlayer = Players:GetPlayerFromCharacter(hitModel)
				if hitPlayer and not TeamService:AreTeammates(projData.Player.Name, hitPlayer.Name) then
					local wormData = WormService:GetWormData_Server(hitPlayer)
					if wormData and wormData.State == "Alive" then
						hitWorm = true
					end
				elseif
					hitModel:FindFirstChild("WormSegments")
					and not TeamService:AreTeammates(projData.Player.Name, hitModel.Name)
				then
					hitWorm = true
				end
			end

			if hitWorm then
				projData.Position = rayResult.Position
				if projData.Instance then
					projData.Instance.Position = projData.Position
				end
				self:_explodeProjectile(projData)
				return
			end

			-- Bounce off terrain
			projData.Bounces += 1
			if projData.Bounces <= (weaponDef.MaxBounces :: number) then
				local normal = rayResult.Normal
				local reflected = projData.Velocity - 2 * projData.Velocity:Dot(normal) * normal
				projData.Velocity = reflected * (weaponDef.BounceDecay :: number)
				projData.Position = rayResult.Position + normal * 0.2

				if projData.Velocity.Magnitude < 3 then
					projData.Stopped = true
					projData.Position = rayResult.Position + normal * 0.5
				end
			else
				projData.Stopped = true
				projData.Position = rayResult.Position + rayResult.Normal * 0.5
			end
		else
			projData.Position = newPos
		end
	end

	if projData.Instance then
		projData.Instance.Position = projData.Position
	end

	-- Fuse timer
	if projData.TotalTime >= (weaponDef.FuseTime :: number) then
		self:_explodeProjectile(projData)
	end
end

function WeaponService:_updatePowerShot(projData: ProjectileData, _dt: number)
	local newPos = projData.Position + projData.Velocity * _dt

	-- Raycast for collision
	local rayDir = newPos - projData.Position
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = {}
	if projData.Player.Character then
		table.insert(excludeList, projData.Player.Character)
	end
	local foodFolder = Workspace:FindFirstChild("Food")
	if foodFolder then
		table.insert(excludeList, foodFolder)
	end
	for otherPlayer, _ in self._weapons do
		if otherPlayer.Character then
			table.insert(excludeList, otherPlayer.Character)
		end
	end
	rayParams.FilterDescendantsInstances = excludeList

	local rayResult = Workspace:Raycast(projData.Position, rayDir, rayParams)

	if rayResult then
		projData.Position = rayResult.Position
		if projData.Instance then
			projData.Instance.Position = projData.Position
		end
		self:_explodeProjectile(projData)
		return
	end

	projData.Position = newPos
	if projData.Instance then
		projData.Instance.Position = projData.Position
	end

	-- Lifetime (5 seconds)
	if projData.TotalTime > 5 then
		self:_explodeProjectile(projData)
	end
end

--------------------------------------------------
-- Weapon pickups (ghost-only)
--------------------------------------------------

function WeaponService:_countPickups(): number
	local count = 0
	for _ in self._pickups do
		count += 1
	end
	return count
end

function WeaponService:_spawnPickup()
	if self:_countPickups() >= PICKUP_MAX_ON_MAP then
		return
	end

	local names = WeaponConfig.WeaponNames
	local weaponType = names[math.random(1, #names)]
	local x = math.random(-HALF_ARENA + 100, HALF_ARENA - 100)
	local z = math.random(-HALF_ARENA + 100, HALF_ARENA - 100)
	local position = Vector3.new(x, 3, z)

	local id = self._nextPickupId
	self._nextPickupId += 1

	self._pickups[id] = {
		Id = id,
		WeaponType = weaponType,
		Position = position,
		SpawnTime = os.clock(),
	}

	local colorData = WEAPON_PICKUP_COLORS[weaponType] or { 255, 255, 255 }

	-- Only fire to ghost players
	for player, _ in self._weapons do
		self.Client.WeaponPickupSpawned:Fire(player, id, weaponType, position, colorData)
	end
end

function WeaponService:_despawnPickup(id: number)
	self._pickups[id] = nil

	-- Notify all ghost players
	for player, _ in self._weapons do
		self.Client.WeaponPickupDespawned:Fire(player, id)
	end
end

function WeaponService:_updatePickups()
	local now = os.clock()

	-- Despawn expired pickups
	local toRemove = {}
	for id, pickup in self._pickups do
		if now - pickup.SpawnTime >= PICKUP_DESPAWN_TIME then
			table.insert(toRemove, id)
		end
	end
	for _, id in toRemove do
		self:_despawnPickup(id)
	end

	-- Spawn new pickups periodically
	if now - self._lastPickupSpawn >= self._nextPickupInterval then
		self._lastPickupSpawn = now
		self._nextPickupInterval = PICKUP_SPAWN_MIN + math.random() * (PICKUP_SPAWN_MAX - PICKUP_SPAWN_MIN)
		self:_spawnPickup()
	end
end

function WeaponService:_tryCollectPickup(player: Player, pickupId: number)
	local pickup = self._pickups[pickupId]
	if not pickup then
		return
	end

	-- Must be a ghost (have a weapon entry = is ghost with weapon)
	local wormData = WormService:GetWormData_Server(player)
	if wormData and wormData.State == "Alive" then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Proximity check
	if (hrp.Position - pickup.Position).Magnitude > PICKUP_COLLECT_RADIUS then
		return
	end

	-- Assign weapon
	self:AssignWeapon(player, pickup.WeaponType)

	-- Notify all ghost clients to remove the visual
	for otherPlayer, _ in self._weapons do
		self.Client.WeaponPickupCollected:Fire(otherPlayer, pickupId)
	end

	self._pickups[pickupId] = nil
end

-- Send all existing pickups to a newly spawned ghost
function WeaponService:_sendExistingPickups(player: Player)
	for _, pickup in self._pickups do
		local colorData = WEAPON_PICKUP_COLORS[pickup.WeaponType] or { 255, 255, 255 }
		self.Client.WeaponPickupSpawned:Fire(player, pickup.Id, pickup.WeaponType, pickup.Position, colorData)
	end
end

function WeaponService:ClearAllPickups()
	for id in self._pickups do
		self:_despawnPickup(id)
	end
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function WeaponService.Client:Shoot(player: Player, origin: Vector3, direction: Vector3)
	self.Server:_onShoot(player, origin, direction)
end

function WeaponService.Client:ThrowGrenade(player: Player, origin: Vector3, direction: Vector3)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	local weaponData = self.Server._weapons[player]
	if not weaponData or weaponData.Type ~= "Grenade" then
		return
	end
	if not self.Server:_validateProjectileShoot(player, origin, direction) then
		return
	end
	self.Server:_spawnGrenade(player, origin, direction)
end

function WeaponService.Client:StartCharge(player: Player)
	local weaponData = self.Server._weapons[player]
	if not weaponData or weaponData.Type ~= "PowerShot" then
		return
	end
	if weaponData.Ammo <= 0 then
		return
	end
	self.Server._chargeStarts[player] = Workspace:GetServerTimeNow()
end

function WeaponService.Client:ReleasePowerShot(player: Player, origin: Vector3, direction: Vector3)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	local weaponData = self.Server._weapons[player]
	if not weaponData or weaponData.Type ~= "PowerShot" then
		return
	end

	local chargeStart = self.Server._chargeStarts[player]
	if not chargeStart then
		return
	end
	self.Server._chargeStarts[player] = nil

	if not self.Server:_validateProjectileShoot(player, origin, direction) then
		return
	end

	local chargeDuration = Workspace:GetServerTimeNow() - chargeStart
	local weaponDef = WeaponConfig.Weapons.PowerShot
	local chargeAlpha = math.clamp(chargeDuration / (weaponDef.ChargeTime :: number), 0, 1)

	self.Server:_spawnPowerShot(player, origin, direction, chargeAlpha)
end

function WeaponService.Client:CollectWeaponPickup(player: Player, pickupId: number)
	if type(pickupId) ~= "number" then
		return
	end
	self.Server:_tryCollectPickup(player, pickupId)
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
		self._chargeStarts[player] = nil
	end)
end

function WeaponService:KnitStart()
	WormService = require(script.Parent.WormService)
	TeamService = require(script.Parent.TeamService)
	BotService = require(script.Parent.BotService)

	-- Projectile + pickup update loop
	RunService.Heartbeat:Connect(function(dt: number)
		self:_updateProjectiles(dt)
		self:_updatePickups()
	end)
end

return WeaponService
