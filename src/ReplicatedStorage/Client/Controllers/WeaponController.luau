--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local PICKUP_COLLECT_RADIUS = 5
local PICKUP_BOB_SPEED = 2
local PICKUP_BOB_HEIGHT = 0.5
local PICKUP_ROTATE_SPEED = 1

local WeaponController = Knit.CreateController({
	Name = "WeaponController",

	-- Public signals for UI
	WeaponAssigned = Signal.new(), -- (weaponType, ammo)
	AmmoChanged = Signal.new(), -- (ammo)
	HitConfirmed = Signal.new(), -- (targetName, damage)
	WeaponCleared = Signal.new(),
	ReloadStarted = Signal.new(), -- (duration)
	ReloadFinished = Signal.new(),

	_trove = nil :: any,
	_weaponService = nil :: any,
	_wormController = nil :: any,
	_weaponType = nil :: string?,
	_ammo = 0,
	_lastShotTime = 0,
	_holding = false, -- for auto-fire (RapidFire)
	_charging = false, -- for PowerShot charge
	_chargeStartTime = 0,
	_reloading = false,
	_reloadEndTime = 0,
	_maxAmmo = 0,

	-- Weapon pickup visuals (client-side only)
	_pickupVisuals = {} :: { [number]: { Part: Part, BaseY: number, WeaponType: string, Position: Vector3 } },
	_pickupFolder = nil :: Folder?,
})

--------------------------------------------------
-- Shooting
--------------------------------------------------

function WeaponController:_getAimRay(): (Vector3?, Vector3?)
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	-- Use camera look direction for aiming (first-person ghost mode)
	local camCF = Camera.CFrame
	local origin = hrp.Position
	local direction = camCF.LookVector

	return origin, direction
end

function WeaponController:TryReload()
	if not self._weaponType then
		return
	end
	if self._reloading then
		return
	end
	if self._ammo >= self._maxAmmo then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end
	self._weaponService:Reload()
end

function WeaponController:TryShoot()
	if not self._weaponType then
		return
	end
	if self._ammo <= 0 then
		-- Auto-reload when trying to shoot with empty mag
		self:TryReload()
		return
	end
	if self._reloading then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end
	-- Don't shoot while grapple is pulling toward a worm
	if self._wormController._grappleState == "PULLING" then
		return
	end
	-- Only shoot when weapon slot is selected
	if self._wormController:GetSelectedSlot() ~= 2 then
		return
	end

	local weaponDef = WeaponConfig.Weapons[self._weaponType]
	if not weaponDef then
		return
	end

	-- Projectile weapons use different methods
	if weaponDef.IsProjectile then
		return
	end

	-- Client-side fire rate check
	local minInterval = 60 / weaponDef.FireRate
	local now = os.clock()
	if (now - self._lastShotTime) < (minInterval - WeaponConfig.FireRateTolerance) then
		return
	end

	local origin, direction = self:_getAimRay()
	if not origin or not direction then
		return
	end

	self._lastShotTime = now
	self._ammo -= 1 -- Optimistic update
	self.AmmoChanged:Fire(self._ammo)

	-- Client-side visual: raycast to find hit point, then show tracer immediately
	local range = weaponDef.Range
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { LocalPlayer.Character :: Instance }
	local rayResult = workspace:Raycast(origin, direction * range, raycastParams)
	local hitPos = if rayResult then rayResult.Position else origin + direction * range
	self:_spawnProjectileVisual(LocalPlayer.Name, origin, hitPos, nil)

	-- Send to server
	self._weaponService:Shoot(origin, direction)
end

function WeaponController:TryThrowGrenade()
	if self._weaponType ~= "Grenade" then
		return
	end
	if self._ammo <= 0 then
		self:TryReload()
		return
	end
	if self._reloading then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end

	local weaponDef = WeaponConfig.Weapons.Grenade
	local minInterval = 60 / weaponDef.FireRate
	local now = os.clock()
	if (now - self._lastShotTime) < (minInterval - WeaponConfig.FireRateTolerance) then
		return
	end

	local origin, direction = self:_getAimRay()
	if not origin or not direction then
		return
	end

	self._lastShotTime = now
	self._ammo -= 1
	self.AmmoChanged:Fire(self._ammo)

	self._weaponService:ThrowGrenade(origin, direction)
end

function WeaponController:TryThrowCluster()
	if self._weaponType ~= "Cluster" then
		return
	end
	if self._ammo <= 0 then
		self:TryReload()
		return
	end
	if self._reloading then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end

	local weaponDef = WeaponConfig.Weapons.Cluster
	local minInterval = 60 / weaponDef.FireRate
	local now = os.clock()
	if (now - self._lastShotTime) < (minInterval - WeaponConfig.FireRateTolerance) then
		return
	end

	local origin, direction = self:_getAimRay()
	if not origin or not direction then
		return
	end

	self._lastShotTime = now
	self._ammo -= 1
	self.AmmoChanged:Fire(self._ammo)

	self._weaponService:ThrowCluster(origin, direction)
end

function WeaponController:TryDeployMine()
	if self._weaponType ~= "Mine" then
		return
	end
	if self._ammo <= 0 then
		self:TryReload()
		return
	end
	if self._reloading then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end

	local weaponDef = WeaponConfig.Weapons.Mine
	local minInterval = 60 / weaponDef.FireRate
	local now = os.clock()
	if (now - self._lastShotTime) < (minInterval - WeaponConfig.FireRateTolerance) then
		return
	end

	local origin, direction = self:_getAimRay()
	if not origin or not direction then
		return
	end

	self._lastShotTime = now
	self._ammo -= 1
	self.AmmoChanged:Fire(self._ammo)

	self._weaponService:DeployMine(origin, direction)
end

function WeaponController:StartPowerShotCharge()
	if self._weaponType ~= "PowerShot" then
		return
	end
	if self._ammo <= 0 then
		self:TryReload()
		return
	end
	if self._reloading then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end
	if self._charging then
		return
	end

	self._charging = true
	self._chargeStartTime = os.clock()
	self._weaponService:StartCharge()
end

function WeaponController:ReleasePowerShot()
	if not self._charging then
		return
	end
	self._charging = false

	local origin, direction = self:_getAimRay()
	if not origin or not direction then
		return
	end

	self._ammo -= 1
	self.AmmoChanged:Fire(self._ammo)

	self._weaponService:ReleasePowerShot(origin, direction)
end

function WeaponController:GetChargeAlpha(): number
	if not self._charging then
		return 0
	end
	local weaponDef = WeaponConfig.Weapons.PowerShot
	local elapsed = os.clock() - self._chargeStartTime
	return math.clamp(elapsed / (weaponDef.ChargeTime :: number), 0, 1)
end

--------------------------------------------------
-- Visual effects
--------------------------------------------------

function WeaponController:_spawnProjectileVisual(
	_shooterName: string,
	origin: Vector3,
	hitPos: Vector3,
	_hitPlayerName: string?
)
	local direction = (hitPos - origin)
	local distance = direction.Magnitude
	if distance < 0.1 then
		return
	end

	-- Tracer beam
	local midpoint = origin + direction / 2
	local tracer = Instance.new("Part")
	tracer.Name = "Tracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.Size = Vector3.new(0.2, 0.2, distance)
	tracer.CFrame = CFrame.new(midpoint, hitPos)
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 200, 50)
	tracer.Transparency = 0.3
	tracer.Parent = workspace

	-- Fade out
	task.delay(0.05, function()
		for i = 1, 5 do
			tracer.Transparency = 0.3 + (i / 5) * 0.7
			task.wait(0.02)
		end
		tracer:Destroy()
	end)

	-- Expanding explosion burst
	local burst = Instance.new("Part")
	burst.Name = "HitBurst"
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.new(3, 3, 3)
	burst.Position = hitPos
	burst.Material = Enum.Material.Neon
	burst.Color = Color3.fromRGB(255, 220, 50)
	burst.Transparency = 0
	burst.Parent = workspace

	-- Expanding ring effect (flat cylinder)
	local ring = Instance.new("Part")
	ring.Name = "HitRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.3, 3, 3)
	ring.CFrame = CFrame.new(hitPos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 160, 30)
	ring.Transparency = 0.2
	ring.Parent = workspace

	task.delay(0, function()
		for i = 1, 8 do
			local t = i / 8
			burst.Size = Vector3.new(3 + t * 3, 3 + t * 3, 3 + t * 3)
			burst.Transparency = t
			ring.Size = Vector3.new(0.3 * (1 - t), 3 + t * 6, 3 + t * 6)
			ring.Transparency = 0.2 + t * 0.8
			task.wait(0.025)
		end
		burst:Destroy()
		ring:Destroy()
	end)
end

function WeaponController:_spawnExplosionVisual(position: Vector3, radius: number)
	-- Expanding sphere
	local sphere = Instance.new("Part")
	sphere.Name = "Explosion"
	sphere.Shape = Enum.PartType.Ball
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CanTouch = false
	sphere.Material = Enum.Material.Neon
	sphere.Color = Color3.fromRGB(255, 150, 30)
	sphere.Size = Vector3.new(1, 1, 1)
	sphere.Position = position
	sphere.Transparency = 0.3
	sphere.Parent = workspace

	-- Expand and fade
	task.spawn(function()
		local duration = 0.3
		local steps = 10
		for i = 1, steps do
			local alpha = i / steps
			local size = radius * 2 * alpha
			sphere.Size = Vector3.new(size, size, size)
			sphere.Transparency = 0.3 + alpha * 0.7
			task.wait(duration / steps)
		end
		sphere:Destroy()
	end)
end

--------------------------------------------------
-- Weapon pickup visuals (ghost-only, client-side)
--------------------------------------------------

function WeaponController:_createPickupVisual(id: number, weaponType: string, position: Vector3, colorData: { number })
	if not self._wormController._inGhostMode then
		return
	end

	local folder = self._pickupFolder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "WeaponPickups_Local"
		folder.Parent = workspace
		self._pickupFolder = folder
	end

	local color = Color3.fromRGB(colorData[1], colorData[2], colorData[3])

	local part = Instance.new("Part")
	part.Name = "WeaponPickup_" .. id
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = 0.2
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Position = position
	part.Parent = folder

	-- Glow effect
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2
	light.Range = 8
	light.Parent = part

	-- Name label
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 100, 0, 24)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = weaponType
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	self._pickupVisuals[id] = {
		Part = part,
		BaseY = position.Y,
		WeaponType = weaponType,
		Position = position,
	}
end

function WeaponController:_removePickupVisual(id: number)
	local visual = self._pickupVisuals[id]
	if visual then
		visual.Part:Destroy()
		self._pickupVisuals[id] = nil
	end
end

function WeaponController:_clearAllPickupVisuals()
	for id, visual in self._pickupVisuals do
		visual.Part:Destroy()
		self._pickupVisuals[id] = nil
	end
	if self._pickupFolder then
		self._pickupFolder:Destroy()
		self._pickupFolder = nil
	end
end

function WeaponController:_updatePickupVisuals()
	if not self._wormController._inGhostMode then
		return
	end

	local now = os.clock()
	local character = LocalPlayer.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil

	for id, visual in self._pickupVisuals do
		local part = visual.Part
		if not part.Parent then
			self._pickupVisuals[id] = nil
			continue
		end

		-- Bobbing animation
		local bobOffset = math.sin(now * PICKUP_BOB_SPEED + id) * PICKUP_BOB_HEIGHT
		part.Position = Vector3.new(visual.Position.X, visual.BaseY + bobOffset, visual.Position.Z)

		-- Rotation
		part.CFrame = CFrame.new(part.Position) * CFrame.Angles(0, now * PICKUP_ROTATE_SPEED + id, 0)

		-- Auto-collect on proximity
		if hrp and (hrp.Position - visual.Position).Magnitude < PICKUP_COLLECT_RADIUS then
			self._weaponService:CollectWeaponPickup(id)
		end
	end
end

--------------------------------------------------
-- Input
--------------------------------------------------

function WeaponController:_setupInput()
	-- Left click: shoot hitscan / throw grenade
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if not self._wormController._inGhostMode then
			return
		end
		if not self._weaponType then
			return
		end
		if self._wormController:GetSelectedSlot() ~= 2 then
			return
		end

		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonR2
		then
			if self._weaponType == "Grenade" then
				self:TryThrowGrenade()
			elseif self._weaponType == "Cluster" then
				self:TryThrowCluster()
			elseif self._weaponType == "Mine" then
				self:TryDeployMine()
			elseif self._weaponType == "PowerShot" then
				self:StartPowerShotCharge()
			else
				self._holding = true
				self:TryShoot()
			end
		end
	end)

	-- Reload key — handled separately so it works regardless of selected slot
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonX then
			if self._wormController._inGhostMode and self._weaponType then
				-- Ensure weapon slot is selected so reload+shoot flow makes sense
				if self._wormController:GetSelectedSlot() ~= 2 then
					self._wormController:SetSelectedSlot(2)
				end
				self:TryReload()
			end
		end
	end)

	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonR2
		then
			self._holding = false
			-- Release PowerShot charge on release
			if self._charging then
				self:ReleasePowerShot()
			end
		end
	end)

	-- Auto-fire for held button + pickup visual updates
	self._trove:Connect(RunService.RenderStepped, function()
		if
			self._holding
			and self._wormController._inGhostMode
			and self._weaponType
			and self._wormController:GetSelectedSlot() == 2
		then
			self:TryShoot()
		end
		self:_updatePickupVisuals()
	end)
end

--------------------------------------------------
-- Server signals
--------------------------------------------------

function WeaponController:_connectSignals()
	self._trove:Add(self._weaponService.WeaponAssigned:Connect(function(weaponType: string, ammo: number)
		self._weaponType = weaponType
		self._ammo = ammo
		self._maxAmmo = ammo
		self._lastShotTime = 0
		self._reloading = false
		self.WeaponAssigned:Fire(weaponType, ammo)
		-- Auto-select weapon slot when a weapon is assigned
		self._wormController:SetSelectedSlot(2)
	end))

	self._trove:Add(self._weaponService.AmmoChanged:Connect(function(ammo: number)
		self._ammo = ammo
		if self._reloading and ammo >= self._maxAmmo then
			self._reloading = false
			self.ReloadFinished:Fire()
		end
		self.AmmoChanged:Fire(ammo)
	end))

	self._trove:Add(self._weaponService.ReloadStarted:Connect(function(duration: number)
		self._reloading = true
		self._reloadEndTime = os.clock() + duration
		self.ReloadStarted:Fire(duration)
	end))

	self._trove:Add(self._weaponService.HitConfirmed:Connect(function(targetName: string, damage: number)
		self.HitConfirmed:Fire(targetName, damage)
	end))

	self._trove:Add(
		self._weaponService.ShotReplicated:Connect(
			function(shooterName: string, origin: Vector3, hitPos: Vector3, hitPlayerName: string?)
				-- Don't render our own shots again (we already see client-side feedback)
				if shooterName == LocalPlayer.Name then
					return
				end
				self:_spawnProjectileVisual(shooterName, origin, hitPos, hitPlayerName)
			end
		)
	)

	-- Projectile explosion visual
	self._trove:Add(
		self._weaponService.ProjectileExploded:Connect(function(_projId: number, position: Vector3, radius: number)
			self:_spawnExplosionVisual(position, radius)
		end)
	)

	-- Suppress ProjectileSpawned / ChargeStarted warnings
	self._trove:Add(self._weaponService.ProjectileSpawned:Connect(function() end))
	self._trove:Add(self._weaponService.ChargeStarted:Connect(function() end))

	-- Weapon pickup signals
	self._trove:Add(
		self._weaponService.WeaponPickupSpawned:Connect(
			function(id: number, weaponType: string, position: Vector3, colorData: { number })
				self:_createPickupVisual(id, weaponType, position, colorData)
			end
		)
	)

	self._trove:Add(self._weaponService.WeaponPickupCollected:Connect(function(id: number)
		self:_removePickupVisual(id)
	end))

	self._trove:Add(self._weaponService.WeaponPickupDespawned:Connect(function(id: number)
		self:_removePickupVisual(id)
	end))

	-- Clear weapon when ghost mode ends
	self._wormController.GhostModeChanged:Connect(function(isGhost: boolean)
		if not isGhost then
			self._weaponType = nil
			self._ammo = 0
			self._maxAmmo = 0
			self._holding = false
			self._charging = false
			self._reloading = false
			self:_clearAllPickupVisuals()
			self.WeaponCleared:Fire()
		end
	end)
end

--------------------------------------------------
-- Public API
--------------------------------------------------

function WeaponController:GetWeaponType(): string?
	return self._weaponType
end

function WeaponController:GetAmmo(): number
	return self._ammo
end

function WeaponController:IsReloading(): boolean
	return self._reloading
end

function WeaponController:GetReloadAlpha(): number
	if not self._reloading then
		return 0
	end
	local weaponDef = WeaponConfig.Weapons[self._weaponType or ""]
	if not weaponDef then
		return 0
	end
	local reloadTime = weaponDef.ReloadTime or 2
	local remaining = self._reloadEndTime - os.clock()
	return math.clamp(1 - remaining / reloadTime, 0, 1)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WeaponController:KnitInit()
	self._trove = Trove.new()
end

function WeaponController:KnitStart()
	self._weaponService = Knit.GetService("WeaponService")
	self._wormController = Knit.GetController("WormController")

	self:_setupInput()
	self:_connectSignals()

	-- Catch up: check if we already have a weapon (late join)
	local ok, data = pcall(function()
		return self._weaponService:GetWeaponData()
	end)
	if ok and data then
		self._weaponType = data.Type
		self._ammo = data.Ammo
		local weaponDef = WeaponConfig.Weapons[data.Type]
		self._maxAmmo = if weaponDef then weaponDef.Ammo else data.Ammo
		self.WeaponAssigned:Fire(data.Type, self._maxAmmo)
	end
end

return WeaponController
