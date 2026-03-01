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

local CAMERA_HEIGHT = 60
local CAMERA_ANGLE = 70 -- Degrees from horizontal

local WormController = Knit.CreateController({
	Name = "WormController",

	SegmentsChanged = Signal.new(),
	WormDied = Signal.new(),
	WormSpawned = Signal.new(),

	_trove = nil :: any,
	_wormService = nil :: any,
	_direction = Vector3.new(0, 0, -1),
	_boosting = false,
	_segments = WormConfig.InitialSegments,
	_alive = false,
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

	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	local pos = head.Position
	local angleRad = math.rad(CAMERA_ANGLE)
	local offset = Vector3.new(0, CAMERA_HEIGHT * math.sin(angleRad), CAMERA_HEIGHT * math.cos(angleRad) * 0.3)
	Camera.CFrame = CFrame.new(pos + offset, pos)
end

--------------------------------------------------
-- Input
--------------------------------------------------

function WormController:_getWorldDirection(): Vector3?
	local mouse = LocalPlayer:GetMouse()
	local ray = Camera:ScreenPointToRay(mouse.X, mouse.Y)

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

	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil
	end

	local dir = (hitPoint - head.Position) * Vector3.new(1, 0, 1)
	if dir.Magnitude < 0.1 then
		return nil
	end

	return dir.Unit
end

function WormController:_setupInput()
	-- Boost: hold left mouse button or Shift
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
			self._boosting = true
			if self._wormService then
				self._wormService:SetBoosting(true)
			end
		end
	end)

	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
			self._boosting = false
			if self._wormService then
				self._wormService:SetBoosting(false)
			end
		end
	end)

	-- Touch boost (mobile)
	self._trove:Connect(UserInputService.TouchStarted, function(_touch: InputObject, processed: boolean)
		if processed then
			return
		end
		self._boosting = true
		if self._wormService then
			self._wormService:SetBoosting(true)
		end
	end)

	self._trove:Connect(UserInputService.TouchEnded, function()
		self._boosting = false
		if self._wormService then
			self._wormService:SetBoosting(false)
		end
	end)
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

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormController:KnitInit()
	self._trove = Trove.new()
end

function WormController:KnitStart()
	self._wormService = Knit.GetService("WormService")

	self:_setupInput()
	self:_connectServerSignals()

	self._trove:Add(RunService.RenderStepped:Connect(function()
		self:_onRenderStep()
	end))
end

return WormController
