--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WeaponConfig = require(ReplicatedStorage.Shared.WeaponConfig)

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local WeaponController = Knit.CreateController({
	Name = "WeaponController",

	-- Public signals for UI
	WeaponAssigned = Signal.new(), -- (weaponType, ammo)
	AmmoChanged = Signal.new(), -- (ammo)
	HitConfirmed = Signal.new(), -- (targetName, damage)
	WeaponCleared = Signal.new(),

	_trove = nil :: any,
	_weaponService = nil :: any,
	_wormController = nil :: any,
	_weaponType = nil :: string?,
	_ammo = 0,
	_lastShotTime = 0,
	_holding = false, -- for auto-fire (RapidFire)
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

function WeaponController:TryShoot()
	if not self._weaponType then
		return
	end
	if self._ammo <= 0 then
		return
	end
	if not self._wormController._inGhostMode then
		return
	end

	-- Client-side fire rate check
	local weaponDef = WeaponConfig.Weapons[self._weaponType]
	if not weaponDef then
		return
	end
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

	-- Send to server
	self._weaponService:Shoot(origin, direction)
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

	-- Hit flash
	local flash = Instance.new("Part")
	flash.Name = "HitFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(1, 1, 1)
	flash.Position = hitPos
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 255, 100)
	flash.Transparency = 0
	flash.Parent = workspace

	task.delay(0.1, function()
		flash:Destroy()
	end)
end

--------------------------------------------------
-- Input
--------------------------------------------------

function WeaponController:_setupInput()
	-- Mouse button for shooting (replaces grapple click when weapon is equipped)
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

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._holding = true
			self:TryShoot()
		end
	end)

	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._holding = false
		end
	end)

	-- Auto-fire for held button (RapidFire benefits from this)
	self._trove:Connect(game:GetService("RunService").RenderStepped, function()
		if self._holding and self._wormController._inGhostMode and self._weaponType then
			self:TryShoot()
		end
	end)
end

--------------------------------------------------
-- Server signals
--------------------------------------------------

function WeaponController:_connectSignals()
	self._trove:Add(self._weaponService.WeaponAssigned:Connect(function(weaponType: string, ammo: number)
		self._weaponType = weaponType
		self._ammo = ammo
		self._lastShotTime = 0
		self.WeaponAssigned:Fire(weaponType, ammo)
	end))

	self._trove:Add(self._weaponService.AmmoChanged:Connect(function(ammo: number)
		self._ammo = ammo
		self.AmmoChanged:Fire(ammo)
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

	-- Clear weapon when ghost mode ends
	self._wormController.GhostModeChanged:Connect(function(isGhost: boolean)
		if not isGhost then
			self._weaponType = nil
			self._ammo = 0
			self._holding = false
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
		self.WeaponAssigned:Fire(data.Type, data.Ammo)
	end
end

return WeaponController
