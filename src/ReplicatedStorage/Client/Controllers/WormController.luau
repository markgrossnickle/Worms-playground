--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local CAMERA_BASE_HEIGHT = 40
local CAMERA_HEIGHT_PER_SEGMENT = 0.5
local CAMERA_ANGLE = 70 -- Degrees from horizontal

local WormController = Knit.CreateController({
	Name = "WormController",

	SegmentsChanged = Signal.new(),
	WormDied = Signal.new(),
	WormSpawned = Signal.new(),
	PowerUpActivated = Signal.new(),
	PowerUpExpired = Signal.new(),
	ZoneUpdate = Signal.new(),
	ZoneWarning = Signal.new(),

	_trove = nil :: any,
	_wormService = nil :: any,
	_powerUpService = nil :: any,
	_shrinkZoneService = nil :: any,
	_teamService = nil :: any,
	_direction = Vector3.new(0, 0, -1),
	_boosting = false,
	_segments = WormConfig.InitialSegments,
	_alive = false,
	_touchPosition = nil :: Vector2?,
	_isTouchDevice = false,
})

--------------------------------------------------
-- Camera
--------------------------------------------------

function WormController:_setupCamera()
	Camera.CameraType = Enum.CameraType.Scriptable
end

function WormController:_updateCamera()
	local character = LocalPlayer.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Scale camera distance based on segment count so the full worm stays on screen
	local cameraHeight = CAMERA_BASE_HEIGHT + (self._segments * CAMERA_HEIGHT_PER_SEGMENT)

	local pos = hrp.Position
	local angleRad = math.rad(CAMERA_ANGLE)
	local offset = Vector3.new(0, cameraHeight * math.sin(angleRad), cameraHeight * math.cos(angleRad) * 0.3)
	Camera.CFrame = CFrame.new(pos + offset, pos)
end

--------------------------------------------------
-- Input
--------------------------------------------------

function WormController:_getWorldDirection(): Vector3?
	-- Determine screen position: use tracked touch position on mobile, mouse otherwise
	local screenX, screenY
	if self._isTouchDevice and self._touchPosition then
		screenX = self._touchPosition.X
		screenY = self._touchPosition.Y
	else
		local mouse = LocalPlayer:GetMouse()
		screenX = mouse.X
		screenY = mouse.Y
	end

	local ray = Camera:ScreenPointToRay(screenX, screenY)

	-- Intersect ray with ground plane (Y = 1)
	local planeY = 1
	if ray.Direction.Y == 0 then
		return nil
	end

	local t = (planeY - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end

	local hitPoint = ray.Origin + ray.Direction * t

	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local dir = (hitPoint - hrp.Position) * Vector3.new(1, 0, 1)
	if dir.Magnitude < 0.1 then
		return nil
	end

	return dir.Unit
end

function WormController:_setupInput()
	self._isTouchDevice = UserInputService.TouchEnabled

	-- Keyboard/mouse boost: hold Shift or left mouse button
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
			self:SetBoosting(true)
		end
	end)

	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
			self:SetBoosting(false)
		end
	end)

	-- Touch direction tracking: update position on touch start, move, and clear on end
	if self._isTouchDevice then
		self._trove:Connect(UserInputService.TouchStarted, function(touch: InputObject, processed: boolean)
			if processed then
				return
			end
			self._touchPosition = Vector2.new(touch.Position.X, touch.Position.Y)
		end)

		self._trove:Connect(UserInputService.TouchMoved, function(touch: InputObject, processed: boolean)
			if processed then
				return
			end
			self._touchPosition = Vector2.new(touch.Position.X, touch.Position.Y)
		end)

		self._trove:Connect(UserInputService.TouchEnded, function()
			self._touchPosition = nil
		end)
	end
end

--------------------------------------------------
-- Render loop
--------------------------------------------------

function WormController:_onRenderStep()
	if not self._alive then
		return
	end

	-- Send direction to server
	local dir = self:_getWorldDirection()
	if dir and self._wormService then
		self._direction = dir
		self._wormService:SetDirection(dir.X, dir.Z)
	end

	self:_updateCamera()
end

--------------------------------------------------
-- Server signals
--------------------------------------------------

function WormController:_connectServerSignals()
	self._trove:Add(
		self._wormService.WormSpawned:Connect(
			function(data: { Segments: number, Color: { number }, Position: { number } })
				self._alive = true
				self._segments = data.Segments
				self:_setupCamera()
				self.WormSpawned:Fire(data)
			end
		)
	)

	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		if deadName == LocalPlayer.Name then
			self._alive = false
			self.WormDied:Fire(killerName)
		end
	end))

	self._trove:Add(self._wormService.WormAte:Connect(function(newSegments: number)
		self._segments = newSegments
		self.SegmentsChanged:Fire(newSegments)
	end))

	-- Power-up signals
	self._trove:Add(
		self._powerUpService.PowerUpActivated:Connect(function(ownerName: string, powerUpType: string, duration: number)
			if ownerName == LocalPlayer.Name then
				self.PowerUpActivated:Fire(powerUpType, duration)
			end
		end)
	)

	self._trove:Add(self._powerUpService.PowerUpExpired:Connect(function(ownerName: string, _powerUpType: string)
		if ownerName == LocalPlayer.Name then
			self.PowerUpExpired:Fire()
		end
	end))

	-- Suppress Knit warnings for signals we don't directly use here
	self._trove:Add(self._powerUpService.PowerUpSpawned:Connect(function() end))
	self._trove:Add(self._powerUpService.PowerUpCollected:Connect(function() end))

	-- Shrink zone signals
	self._trove:Add(self._shrinkZoneService.ZoneUpdate:Connect(function(radius: number, elapsed: number)
		self.ZoneUpdate:Fire(radius, elapsed)
	end))

	self._trove:Add(self._shrinkZoneService.ZoneWarning:Connect(function(message: string)
		self.ZoneWarning:Fire(message)
	end))

	-- Team signals (suppress Knit warning)
	self._trove:Add(self._teamService.TeamAssigned:Connect(function() end))
	self._trove:Add(self._teamService.TeamsUpdated:Connect(function() end))
end

--------------------------------------------------
-- Public API
--------------------------------------------------

function WormController:GetSegments(): number
	return self._segments
end

function WormController:IsAlive(): boolean
	return self._alive
end

function WormController:IsBoosting(): boolean
	return self._boosting
end

function WormController:SetBoosting(boosting: boolean)
	self._boosting = boosting
	if self._wormService then
		self._wormService:SetBoosting(boosting)
	end
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormController:KnitInit()
	self._trove = Trove.new()
end

function WormController:KnitStart()
	self._wormService = Knit.GetService("WormService")
	self._powerUpService = Knit.GetService("PowerUpService")
	self._shrinkZoneService = Knit.GetService("ShrinkZoneService")
	self._teamService = Knit.GetService("TeamService")

	self:_setupInput()
	self:_connectServerSignals()

	-- Catch up: server may have spawned our worm before client connected signals
	local ok, data = pcall(function()
		return self._wormService:GetWormData()
	end)
	if ok and data and data.State == "Alive" then
		self._alive = true
		self._segments = data.Segments
		self:_setupCamera()
		self.WormSpawned:Fire(data)
	end

	self._trove:Add(RunService.RenderStepped:Connect(function()
		self:_onRenderStep()
	end))
end

return WormController
