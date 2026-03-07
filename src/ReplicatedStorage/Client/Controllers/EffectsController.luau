--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local PlatformUtil = require(ReplicatedStorage.Shared.PlatformUtil)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

--------------------------------------------------
-- Constants
--------------------------------------------------

local FOOD_TIER_COLORS = {
	[1] = Color3.fromRGB(80, 220, 80), -- green
	[2] = Color3.fromRGB(60, 140, 255), -- blue
	[4] = Color3.fromRGB(255, 200, 50), -- gold
}

local POWERUP_AURA_COLORS = {
	SPEED = Color3.fromRGB(0, 200, 255),
	SPEED_BURST = Color3.fromRGB(255, 140, 0),
	MAGNET = Color3.fromRGB(200, 0, 255),
	GHOST = Color3.fromRGB(200, 200, 255),
	SHIELD = Color3.fromRGB(255, 220, 0),
	SIZE_BOMB = Color3.fromRGB(255, 80, 0),
	FREEZE_RING = Color3.fromRGB(100, 180, 255),
}

local KILL_STREAK_LABELS = {
	[2] = "Double Kill!",
	[3] = "Triple Kill!",
	[4] = "Quad Kill!",
	[5] = "RAMPAGE!",
}
local KILL_STREAK_TIMEOUT = 5 -- seconds between kills to maintain streak

local BOOST_FOV_ADD = 8
local FOV_LERP_SPEED = 4

local ZONE_WARN_DISTANCE = 40 -- studs from edge to start vignette

--------------------------------------------------
-- Controller
--------------------------------------------------

local EffectsController = Knit.CreateController({
	Name = "EffectsController",

	_trove = nil :: any,
	_wormService = nil :: any,
	_powerUpService = nil :: any,
	_weaponService = nil :: any,
	_shrinkZoneService = nil :: any,
	_wormController = nil :: any,
	_weaponController = nil :: any,

	-- Segment tracking for eat detection
	_prevSegments = WormConfig.InitialSegments,

	-- Kill streak
	_killStreak = 0,
	_lastKillTime = 0,

	-- Boost
	_boostTrails = {} :: { Trail },

	-- FOV
	_baseFOV = 70,
	_currentFOV = 70,

	-- Screen shake
	_shakeIntensity = 0,
	_shakeDuration = 0,
	_shakeElapsed = 0,
	_shakeFrequency = 30,

	-- Zone
	_currentZoneRadius = WormConfig.ArenaSize / 2,
	_outsideZone = false,
	_lastZoneDamageTick = 0,

	-- UI elements
	_screenGui = nil :: ScreenGui?,
	_vignetteFrame = nil :: ImageLabel?,
	_hitMarkerFrame = nil :: Frame?,
	_zoneVignetteFrame = nil :: ImageLabel?,

	-- Power-up auras
	_activeAuras = {} :: { [string]: { Highlight: Highlight, Emitter: ParticleEmitter? } },

	-- Death vignette
	_deathVignetteActive = false,
})

--------------------------------------------------
-- UI setup
--------------------------------------------------

function EffectsController:_buildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "EffectsUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = PlayerGui
	self._screenGui = gui

	-- Red death vignette (full screen, initially invisible)
	local deathVignette = Instance.new("ImageLabel")
	deathVignette.Name = "DeathVignette"
	deathVignette.Size = UDim2.fromScale(1, 1)
	deathVignette.Position = UDim2.fromScale(0.5, 0.5)
	deathVignette.AnchorPoint = Vector2.new(0.5, 0.5)
	deathVignette.BackgroundColor3 = Color3.fromRGB(200, 0, 0)
	deathVignette.BackgroundTransparency = 1
	deathVignette.BorderSizePixel = 0
	deathVignette.Image = ""
	deathVignette.Parent = gui
	self._vignetteFrame = deathVignette

	-- Hit marker (X shape, center screen)
	local hitMarker = Instance.new("Frame")
	hitMarker.Name = "HitMarker"
	hitMarker.Size = UDim2.fromOffset(30, 30)
	hitMarker.Position = UDim2.fromScale(0.5, 0.5)
	hitMarker.AnchorPoint = Vector2.new(0.5, 0.5)
	hitMarker.BackgroundTransparency = 1
	hitMarker.Visible = false
	hitMarker.Parent = gui

	-- Two crossed lines for X
	for i = 1, 2 do
		local line = Instance.new("Frame")
		line.Name = "Line" .. i
		line.Size = UDim2.fromOffset(3, 28)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Rotation = if i == 1 then 45 else -45
		line.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
		line.BorderSizePixel = 0
		line.Parent = hitMarker
	end
	self._hitMarkerFrame = hitMarker

	-- Zone warning vignette (red pulsing edges)
	local zoneVignette = Instance.new("ImageLabel")
	zoneVignette.Name = "ZoneVignette"
	zoneVignette.Size = UDim2.fromScale(1, 1)
	zoneVignette.Position = UDim2.fromScale(0.5, 0.5)
	zoneVignette.AnchorPoint = Vector2.new(0.5, 0.5)
	zoneVignette.BackgroundColor3 = Color3.fromRGB(255, 30, 30)
	zoneVignette.BackgroundTransparency = 1
	zoneVignette.BorderSizePixel = 0
	zoneVignette.Image = ""
	zoneVignette.Parent = gui
	self._zoneVignetteFrame = zoneVignette
end

--------------------------------------------------
-- 1. Eating effects
--------------------------------------------------

function EffectsController:_onSegmentsChanged(newSegments: number)
	local delta = newSegments - self._prevSegments
	self._prevSegments = newSegments

	if delta <= 0 then
		return -- lost segments, not eating
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if not wormHead then
		return
	end

	local headPos = wormHead.Position

	-- Determine food tier color
	local tierColor = FOOD_TIER_COLORS[delta] or FOOD_TIER_COLORS[1]

	-- Particle burst at head
	self:_spawnEatParticles(headPos, tierColor)

	-- Scale pulse on worm head
	self:_pulseHeadScale(wormHead)

	-- Floating text
	local text = "+" .. tostring(math.floor(delta))
	self:_spawnFloatingText(headPos, text, tierColor)
end

function EffectsController:_spawnEatParticles(position: Vector3, color: Color3)
	local part = Instance.new("Part")
	part.Name = "EatParticles"
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.3, 0.5)
	emitter.Speed = NumberRange.new(8, 15)
	emitter.SpreadAngle = Vector2.new(360, 360)
	emitter.Rate = 0
	emitter.LightEmission = 0.8
	emitter.Parent = part

	emitter:Emit(math.floor(8 * PlatformUtil.ParticleScale))

	task.delay(0.6, function()
		part:Destroy()
	end)
end

function EffectsController:_pulseHeadScale(wormHead: BasePart)
	local originalSize = wormHead:GetAttribute("OriginalSize")
	if not originalSize then
		originalSize = wormHead.Size
		wormHead:SetAttribute("OriginalSize", originalSize)
	end

	local pulsedSize = (originalSize :: Vector3) * 1.1
	wormHead.Size = pulsedSize
	TweenService:Create(wormHead, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = originalSize :: Vector3,
	}):Play()
end

function EffectsController:_spawnFloatingText(position: Vector3, text: string, color: Color3)
	local part = Instance.new("Part")
	part.Name = "FloatingText"
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Position = position + Vector3.new(0, 2, 0)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(60, 30)
	billboard.StudsOffset = Vector3.new(0, 0, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	-- Rise and fade
	task.spawn(function()
		local duration = 1
		local steps = 20
		for i = 1, steps do
			local alpha = i / steps
			part.Position = position + Vector3.new(0, 2 + alpha * 4, 0)
			label.TextTransparency = alpha
			label.TextStrokeTransparency = 0.3 + alpha * 0.7
			task.wait(duration / steps)
		end
		part:Destroy()
	end)
end

--------------------------------------------------
-- 2. Boost trail & FOV
--------------------------------------------------

function EffectsController:_startBoostEffects()
	local character = LocalPlayer.Character
	if not character then
		return
	end

	-- Add trails to worm head and segments (on mobile, head only for performance)
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		self:_addBoostTrail(wormHead)
	end
	if not PlatformUtil.IsTouchDevice then
		local segFolder = character:FindFirstChild("WormSegments") :: Folder?
		if segFolder then
			for _, seg in segFolder:GetChildren() do
				if seg:IsA("BasePart") then
					self:_addBoostTrail(seg)
				end
			end
		end
	end
end

function EffectsController:_stopBoostEffects()
	-- Remove boost trails
	for _, trail in self._boostTrails do
		trail:Destroy()
	end
	self._boostTrails = {}

	-- Also clean up attachments
	local character = LocalPlayer.Character
	if character then
		for _, desc in character:GetDescendants() do
			if desc.Name == "BoostTrailA0" or desc.Name == "BoostTrailA1" then
				desc:Destroy()
			end
		end
	end
end

function EffectsController:_addBoostTrail(part: BasePart)
	-- Check if already has one
	if part:FindFirstChild("BoostTrail") then
		return
	end

	local att0 = Instance.new("Attachment")
	att0.Name = "BoostTrailA0"
	att0.Position = Vector3.new(0, 0, -0.8)
	att0.Parent = part

	local att1 = Instance.new("Attachment")
	att1.Name = "BoostTrailA1"
	att1.Position = Vector3.new(0, 0, 0.8)
	att1.Parent = part

	local trail = Instance.new("Trail")
	trail.Name = "BoostTrail"
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 200), Color3.fromRGB(255, 200, 50))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = 0.3
	trail.MinLength = 0.1
	trail.LightEmission = 0.6
	trail.WidthScale = NumberSequence.new(1)
	trail.Parent = part

	table.insert(self._boostTrails, trail)
end

function EffectsController:_updateBoostFOV(dt: number)
	local isBoosting = self._wormController:IsBoosting() and self._wormController:IsAlive()
	local targetFOV = self._baseFOV + (if isBoosting then BOOST_FOV_ADD else 0)

	self._currentFOV = self._currentFOV + (targetFOV - self._currentFOV) * math.min(1, dt * FOV_LERP_SPEED)

	-- Only set FOV when in worm mode (scriptable camera), not ghost mode
	if self._wormController:IsAlive() then
		Camera.FieldOfView = self._currentFOV
	end
end

--------------------------------------------------
-- 3. Death effects
--------------------------------------------------

function EffectsController:_onAnyWormDied(deadName: string, _killerName: string?)
	-- Find death position
	local deathPos: Vector3? = nil

	-- Check if we have a model for this worm
	local model = workspace:FindFirstChild(deadName) :: Model?
	if model and model:IsA("Model") then
		local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			deathPos = hrp.Position
		end
	end
	if not deathPos then
		-- Check player characters
		for _, player in Players:GetPlayers() do
			if player.Name == deadName and player.Character then
				local hrp = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp then
					deathPos = hrp.Position
				end
				break
			end
		end
	end

	if not deathPos then
		return
	end

	-- Big particle explosion at death position
	self:_spawnDeathExplosion(deathPos)

	-- Screen shake for nearby players (not if it's you dying)
	if deadName ~= LocalPlayer.Name then
		local character = LocalPlayer.Character
		if character then
			local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				local dist = (hrp.Position - deathPos).Magnitude
				if dist < 80 then
					local intensity = math.clamp(1 - dist / 80, 0, 1) * 0.8
					self:Shake(intensity, 0.4, 25)
				end
			end
		end
	end
end

function EffectsController:_onLocalDeath(_data: { KillerName: string?, MaxSegments: number, Kills: number })
	-- Red flash vignette
	self:_flashVignette(Color3.fromRGB(200, 0, 0), 0.5, 0.6)

	-- Screen shake
	self:Shake(1.2, 0.5, 30)

	-- Brief camera zoom to death location (if killed by someone else)
	-- Reset kill streak
	self._killStreak = 0
end

function EffectsController:_spawnDeathExplosion(position: Vector3)
	local part = Instance.new("Part")
	part.Name = "DeathExplosion"
	part.Size = Vector3.new(1, 1, 1)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = workspace

	-- Main burst particles
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 100, 50), Color3.fromRGB(255, 200, 50))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.5, 1)
	emitter.Speed = NumberRange.new(15, 30)
	emitter.SpreadAngle = Vector2.new(360, 360)
	emitter.Rate = 0
	emitter.LightEmission = 1
	emitter.Parent = part

	emitter:Emit(math.floor(25 * PlatformUtil.ParticleScale))

	-- Flash light
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 50)
	light.Brightness = 5
	light.Range = 30
	light.Parent = part

	-- Fade light
	task.spawn(function()
		for i = 1, 10 do
			light.Brightness = 5 * (1 - i / 10)
			task.wait(0.05)
		end
	end)

	task.delay(1.2, function()
		part:Destroy()
	end)
end

function EffectsController:_flashVignette(color: Color3, duration: number, maxAlpha: number)
	local vignette = self._vignetteFrame
	if not vignette then
		return
	end

	vignette.BackgroundColor3 = color
	vignette.BackgroundTransparency = 1 - maxAlpha

	TweenService:Create(vignette, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

--------------------------------------------------
-- 4. Power-up effects
--------------------------------------------------

function EffectsController:_onPowerUpActivated(ownerName: string, powerUpType: string, _duration: number)
	local color = POWERUP_AURA_COLORS[powerUpType]
	if not color then
		return
	end

	-- Find worm model
	local model = self:_findWormModel(ownerName)
	if not model then
		return
	end

	-- Remove existing aura for this owner
	self:_removePowerUpAura(ownerName)

	if powerUpType == "GHOST" then
		-- Ethereal particles on head
		local wormHead = model:FindFirstChild("WormHead") :: BasePart?
		if wormHead then
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "GhostAura"
			emitter.Color = ColorSequence.new(Color3.fromRGB(200, 200, 255))
			emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
			emitter.Transparency =
				NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
			emitter.Lifetime = NumberRange.new(0.5, 1)
			emitter.Speed = NumberRange.new(1, 3)
			emitter.SpreadAngle = Vector2.new(360, 360)
			emitter.Rate = math.floor(15 * PlatformUtil.ParticleScale)
			emitter.LightEmission = 0.8
			emitter.Parent = wormHead

			self._activeAuras[ownerName] = { Highlight = nil :: any, Emitter = emitter }
		end
		return
	end

	if powerUpType == "SHIELD" then
		-- Golden sphere highlight
		local highlight = Instance.new("Highlight")
		highlight.Name = "ShieldAura"
		highlight.FillColor = Color3.fromRGB(255, 220, 0)
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = Color3.fromRGB(255, 200, 0)
		highlight.OutlineTransparency = 0
		highlight.Parent = model

		self._activeAuras[ownerName] = { Highlight = highlight }
		return
	end

	-- Generic glow highlight for other power-ups
	local highlight = Instance.new("Highlight")
	highlight.Name = "PowerUpAura"
	highlight.FillColor = color
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0.2
	highlight.Parent = model

	local entry: { Highlight: Highlight, Emitter: ParticleEmitter? } = { Highlight = highlight }

	-- Speed types get blue/orange streaks
	if powerUpType == "SPEED" or powerUpType == "SPEED_BURST" then
		local wormHead = model:FindFirstChild("WormHead") :: BasePart?
		if wormHead then
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "SpeedStreaks"
			emitter.Color = ColorSequence.new(color)
			emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
			emitter.Transparency =
				NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
			emitter.Lifetime = NumberRange.new(0.2, 0.4)
			emitter.Speed = NumberRange.new(5, 10)
			emitter.SpreadAngle = Vector2.new(20, 20)
			emitter.Rate = math.floor(30 * PlatformUtil.ParticleScale)
			emitter.LightEmission = 0.6
			emitter.Parent = wormHead
			entry.Emitter = emitter
		end
	end

	-- Magnet gets pull-line particles
	if powerUpType == "MAGNET" then
		local wormHead = model:FindFirstChild("WormHead") :: BasePart?
		if wormHead then
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "MagnetPull"
			emitter.Color = ColorSequence.new(Color3.fromRGB(200, 0, 255))
			emitter.Size =
				NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.5) })
			emitter.Transparency =
				NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) })
			emitter.Lifetime = NumberRange.new(0.3, 0.6)
			emitter.Speed = NumberRange.new(-8, -4) -- pull inward
			emitter.SpreadAngle = Vector2.new(360, 360)
			emitter.Rate = math.floor(20 * PlatformUtil.ParticleScale)
			emitter.LightEmission = 0.5
			emitter.Parent = wormHead
			entry.Emitter = emitter
		end
	end

	self._activeAuras[ownerName] = entry
end

function EffectsController:_onPowerUpExpired(ownerName: string, _powerUpType: string)
	self:_removePowerUpAura(ownerName)
end

function EffectsController:_removePowerUpAura(ownerName: string)
	local aura = self._activeAuras[ownerName]
	if not aura then
		return
	end
	if aura.Highlight then
		aura.Highlight:Destroy()
	end
	if aura.Emitter then
		aura.Emitter:Destroy()
	end
	self._activeAuras[ownerName] = nil
end

--------------------------------------------------
-- 5. Weapon effects
--------------------------------------------------

function EffectsController:_onShotReplicated(
	shooterName: string,
	_origin: Vector3,
	_hitPos: Vector3,
	_hitPlayerName: string?
)
	-- Muzzle flash (PointLight burst at origin)
	if shooterName ~= LocalPlayer.Name then
		return -- only show muzzle flash for our own shots
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local flashLight = Instance.new("PointLight")
	flashLight.Color = Color3.fromRGB(255, 220, 100)
	flashLight.Brightness = 4
	flashLight.Range = 12
	flashLight.Parent = hrp

	task.delay(0.08, function()
		flashLight:Destroy()
	end)
end

function EffectsController:_onHitConfirmed(_targetName: string, _damage: number)
	-- Show hit marker
	local marker = self._hitMarkerFrame
	if not marker then
		return
	end

	marker.Visible = true
	task.delay(0.15, function()
		if marker then
			marker.Visible = false
		end
	end)
end

function EffectsController:_onProjectileExploded(_projId: number, position: Vector3, radius: number)
	-- Expanding sphere + particles + light flash
	-- (WeaponController already has _spawnExplosionVisual, but we add screen shake + light)

	-- Camera shake based on distance
	local character = LocalPlayer.Character
	if character then
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local dist = (hrp.Position - position).Magnitude
			if dist < radius * 4 then
				local intensity = math.clamp(1 - dist / (radius * 4), 0, 1) * 1.5
				self:Shake(intensity, 0.4, 20)
			end
		end
	end

	-- Bright flash light at explosion
	local flashPart = Instance.new("Part")
	flashPart.Name = "ExplosionFlash"
	flashPart.Size = Vector3.new(0.5, 0.5, 0.5)
	flashPart.Position = position
	flashPart.Anchored = true
	flashPart.CanCollide = false
	flashPart.CanQuery = false
	flashPart.CanTouch = false
	flashPart.Transparency = 1
	flashPart.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 180, 50)
	light.Brightness = 8
	light.Range = radius * 3
	light.Parent = flashPart

	task.spawn(function()
		for i = 1, 8 do
			light.Brightness = 8 * (1 - i / 8)
			task.wait(0.03)
		end
		flashPart:Destroy()
	end)
end

--------------------------------------------------
-- 6. Zone effects
--------------------------------------------------

function EffectsController:_onZoneUpdate(radius: number, _elapsed: number)
	self._currentZoneRadius = radius
end

function EffectsController:_updateZoneEffects()
	if not self._wormController:IsAlive() then
		if self._zoneVignetteFrame then
			self._zoneVignetteFrame.BackgroundTransparency = 1
		end
		return
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local distFromCenter = Vector3.new(hrp.Position.X, 0, hrp.Position.Z).Magnitude
	local distToEdge = self._currentZoneRadius - distFromCenter

	local vignette = self._zoneVignetteFrame
	if not vignette then
		return
	end

	if distToEdge < 0 then
		-- Outside zone: damage tick flash
		self._outsideZone = true
		local pulse = 0.5 + math.sin(os.clock() * 6) * 0.2
		vignette.BackgroundTransparency = 1 - pulse
	elseif distToEdge < ZONE_WARN_DISTANCE then
		-- Near edge: pulsing warning
		self._outsideZone = false
		local alpha = 1 - (distToEdge / ZONE_WARN_DISTANCE)
		local pulse = alpha * 0.25 * (0.7 + math.sin(os.clock() * 3) * 0.3)
		vignette.BackgroundTransparency = 1 - pulse
	else
		self._outsideZone = false
		vignette.BackgroundTransparency = 1
	end
end

--------------------------------------------------
-- 7. Screen shake
--------------------------------------------------

function EffectsController:Shake(intensity: number, duration: number, frequency: number)
	-- Stack: take the stronger shake if one is already active
	if intensity > self._shakeIntensity then
		self._shakeIntensity = intensity
		self._shakeDuration = duration
		self._shakeElapsed = 0
		self._shakeFrequency = frequency
	end
end

function EffectsController:_updateShake(dt: number)
	if self._shakeIntensity <= 0 then
		return
	end

	self._shakeElapsed += dt
	if self._shakeElapsed >= self._shakeDuration then
		self._shakeIntensity = 0
		return
	end

	-- Decay intensity over time
	local remaining = 1 - (self._shakeElapsed / self._shakeDuration)
	local currentIntensity = self._shakeIntensity * remaining

	local freq = self._shakeFrequency
	local t = self._shakeElapsed * freq
	local offsetX = math.sin(t * 1.1) * currentIntensity * 0.5
	local offsetY = math.cos(t * 1.3) * currentIntensity * 0.5

	Camera.CFrame = Camera.CFrame * CFrame.new(offsetX, offsetY, 0)
end

--------------------------------------------------
-- 8. Kill streak
--------------------------------------------------

function EffectsController:_onKillsUpdated(_kills: number)
	local now = os.clock()
	if now - self._lastKillTime < KILL_STREAK_TIMEOUT then
		self._killStreak += 1
	else
		self._killStreak = 1
	end
	self._lastKillTime = now

	-- Show streak popup
	local label = KILL_STREAK_LABELS[self._killStreak]
	if not label and self._killStreak >= 6 then
		label = "UNSTOPPABLE!"
	end

	if label then
		self:_showStreakPopup(label, self._killStreak)
	end
end

function EffectsController:_showStreakPopup(text: string, streak: number)
	local gui = self._screenGui
	if not gui then
		return
	end

	local size = math.min(28 + streak * 4, 52)

	local label = Instance.new("TextLabel")
	label.Name = "StreakPopup"
	label.Size = UDim2.new(0.3, 0, 0, 60)
	label.Position = UDim2.fromScale(0.5, 0.35)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 220, 50)
	label.TextStrokeColor3 = Color3.fromRGB(180, 80, 0)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = size
	label.TextTransparency = 0
	label.Parent = gui

	-- Punch scale in then fade out
	label.TextSize = size * 1.5
	TweenService:Create(label, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextSize = size,
	}):Play()

	task.delay(1.5, function()
		TweenService:Create(label, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		task.delay(0.5, function()
			label:Destroy()
		end)
	end)
end

--------------------------------------------------
-- Freeze Ring visual (triggered from PowerUpActivated)
--------------------------------------------------

function EffectsController:_onFreezeRingActivated(ownerName: string)
	-- Find owner position
	local model = self:_findWormModel(ownerName)
	if not model then
		return
	end
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Ice particles at the ring origin
	local part = Instance.new("Part")
	part.Name = "FreezeRingParticles"
	part.Size = Vector3.new(1, 1, 1)
	part.Position = hrp.Position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(150, 220, 255))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.5, 1)
	emitter.Speed = NumberRange.new(10, 20)
	emitter.SpreadAngle = Vector2.new(360, 10)
	emitter.Rate = 0
	emitter.LightEmission = 0.7
	emitter.Parent = part

	emitter:Emit(math.floor(30 * PlatformUtil.ParticleScale))

	task.delay(1.5, function()
		part:Destroy()
	end)
end

--------------------------------------------------
-- Helpers
--------------------------------------------------

function EffectsController:_findWormModel(ownerName: string): Model?
	for _, player in Players:GetPlayers() do
		if player.Name == ownerName and player.Character then
			if player.Character:FindFirstChild("WormHead") then
				return player.Character
			end
		end
	end
	local model = workspace:FindFirstChild(ownerName) :: Model?
	if model and model:IsA("Model") and model:FindFirstChild("WormHead") then
		return model
	end
	return nil
end

--------------------------------------------------
-- Render loop
--------------------------------------------------

function EffectsController:_onRenderStep(dt: number)
	self:_updateBoostFOV(dt)
	self:_updateShake(dt)
	self:_updateZoneEffects()
	self:_updateBoostState()
end

function EffectsController:_updateBoostState()
	local isBoosting = self._wormController:IsBoosting() and self._wormController:IsAlive()
	local hasTrails = #self._boostTrails > 0

	if isBoosting and not hasTrails then
		self:_startBoostEffects()
	elseif not isBoosting and hasTrails then
		self:_stopBoostEffects()
	end
end

--------------------------------------------------
-- Signal wiring
--------------------------------------------------

function EffectsController:_connectSignals()
	-- Eating effects (from WormController local signal)
	self._trove:Add(self._wormController.SegmentsChanged:Connect(function(newSegments: number)
		self:_onSegmentsChanged(newSegments)
	end))

	-- Death effects — all deaths from server
	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		self:_onAnyWormDied(deadName, killerName)
	end))

	-- Local player death
	self._trove:Add(
		self._wormController.WormDied:Connect(
			function(data: { KillerName: string?, MaxSegments: number, Kills: number })
				self:_onLocalDeath(data)
			end
		)
	)

	-- Spawned: reset state
	self._trove:Add(self._wormController.WormSpawned:Connect(function(_data: any)
		self._prevSegments = WormConfig.InitialSegments
		self._killStreak = 0
		self._currentFOV = self._baseFOV
		self:_stopBoostEffects()
	end))

	-- Power-up effects — from server signals (all players)
	self._trove:Add(
		self._powerUpService.PowerUpActivated:Connect(function(ownerName: string, powerUpType: string, duration: number)
			self:_onPowerUpActivated(ownerName, powerUpType, duration)
			if powerUpType == "FREEZE_RING" then
				self:_onFreezeRingActivated(ownerName)
			end
		end)
	)

	self._trove:Add(self._powerUpService.PowerUpExpired:Connect(function(ownerName: string, powerUpType: string)
		self:_onPowerUpExpired(ownerName, powerUpType)
	end))

	-- Weapon effects
	self._trove:Add(
		self._weaponService.ShotReplicated:Connect(
			function(shooterName: string, origin: Vector3, hitPos: Vector3, hitPlayerName: string?)
				self:_onShotReplicated(shooterName, origin, hitPos, hitPlayerName)
			end
		)
	)

	self._trove:Add(self._weaponService.HitConfirmed:Connect(function(targetName: string, damage: number)
		self:_onHitConfirmed(targetName, damage)
	end))

	self._trove:Add(
		self._weaponService.ProjectileExploded:Connect(function(projId: number, position: Vector3, radius: number)
			self:_onProjectileExploded(projId, position, radius)
		end)
	)

	-- Kill streak tracking
	self._trove:Add(self._wormService.PlayerKillsUpdated:Connect(function(kills: number)
		self:_onKillsUpdated(kills)
	end))

	-- Zone updates
	self._trove:Add(self._shrinkZoneService.ZoneUpdate:Connect(function(radius: number, elapsed: number)
		self:_onZoneUpdate(radius, elapsed)
	end))

	-- Muzzle flash for own shots (client-side, fired before server roundtrip)
	self._trove:Add(self._weaponController.WeaponAssigned:Connect(function() end)) -- suppress
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function EffectsController:KnitInit()
	self._trove = Trove.new()
	self._baseFOV = Camera.FieldOfView
	self._currentFOV = Camera.FieldOfView
end

function EffectsController:KnitStart()
	self._wormService = Knit.GetService("WormService")
	self._powerUpService = Knit.GetService("PowerUpService")
	self._weaponService = Knit.GetService("WeaponService")
	self._shrinkZoneService = Knit.GetService("ShrinkZoneService")
	self._wormController = Knit.GetController("WormController")
	self._weaponController = Knit.GetController("WeaponController")

	self:_buildUI()
	self:_connectSignals()

	self._trove:Add(RunService.RenderStepped:Connect(function(dt: number)
		self:_onRenderStep(dt)
	end))
end

return EffectsController
