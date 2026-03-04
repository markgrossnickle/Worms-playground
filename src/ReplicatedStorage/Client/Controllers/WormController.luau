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

	-- Round signals (relayed from RoundService)
	RoundEnded = Signal.new(),
	RoundCountdown = Signal.new(),
	RoundStarted = Signal.new(),
	SpectateChanged = Signal.new(),

	_trove = nil :: any,
	_wormService = nil :: any,
	_roundService = nil :: any,
	_powerUpService = nil :: any,
	_shrinkZoneService = nil :: any,
	_teamService = nil :: any,
	_direction = Vector3.new(0, 0, -1),
	_boosting = false,
	_segments = WormConfig.InitialSegments,
	_alive = false,
	_touchPosition = nil :: Vector2?,
	_isTouchDevice = false,

	-- Spectate state
	_spectateTarget = nil :: string?,
	_spectateTargetModel = nil :: Model?,
	_spectatePlayers = {} :: { string },
	_spectateIndex = 0,

	-- Per-round stat tracking
	_peakSegments = WormConfig.InitialSegments,
	_kills = 0,

	-- Ghost mode state
	_inGhostMode = false,
	GhostModeChanged = Signal.new(),
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

function WormController:_updateSpectateCamera()
	local model = self._spectateTargetModel
	if not model then
		return
	end

	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		-- Target may have died, try to find next
		self:_rebuildSpectateList()
		if #self._spectatePlayers > 0 then
			self:SpectateTarget(self._spectatePlayers[1])
		else
			self._spectateTargetModel = nil
		end
		return
	end

	local cameraHeight = CAMERA_BASE_HEIGHT

	local pos = hrp.Position
	local angleRad = math.rad(CAMERA_ANGLE)
	local offset = Vector3.new(0, cameraHeight * math.sin(angleRad), cameraHeight * math.cos(angleRad) * 0.3)
	Camera.CFrame = CFrame.new(pos + offset, pos)
end

--------------------------------------------------
-- Spectate
--------------------------------------------------

function WormController:_rebuildSpectateList()
	local names = {}
	-- Find alive worms by checking workspace models with WormHead
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("WormHead") then
			-- Skip local player's model
			if child.Name ~= LocalPlayer.Name then
				table.insert(names, child.Name)
			end
		end
	end
	-- Also check player characters
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer and player.Character then
			local wormHead = player.Character:FindFirstChild("WormHead")
			if wormHead then
				-- Avoid duplicates
				local found = false
				for _, n in names do
					if n == player.Name then
						found = true
						break
					end
				end
				if not found then
					table.insert(names, player.Name)
				end
			end
		end
	end
	self._spectatePlayers = names
end

function WormController:SpectateTarget(name: string)
	self._spectateTarget = name
	self._spectateTargetModel = nil

	-- Find model in workspace
	local model = workspace:FindFirstChild(name) :: Model?
	if model and model:IsA("Model") and model:FindFirstChild("WormHead") then
		self._spectateTargetModel = model
	else
		-- Check player characters
		for _, player in Players:GetPlayers() do
			if player.Name == name and player.Character and player.Character:FindFirstChild("WormHead") then
				self._spectateTargetModel = player.Character
				break
			end
		end
	end

	-- Update spectate index
	for i, n in self._spectatePlayers do
		if n == name then
			self._spectateIndex = i
			break
		end
	end

	self.SpectateChanged:Fire(name)
end

function WormController:CycleSpectate(direction: number)
	self:_rebuildSpectateList()
	if #self._spectatePlayers == 0 then
		return
	end

	self._spectateIndex += direction
	if self._spectateIndex < 1 then
		self._spectateIndex = #self._spectatePlayers
	elseif self._spectateIndex > #self._spectatePlayers then
		self._spectateIndex = 1
	end

	self:SpectateTarget(self._spectatePlayers[self._spectateIndex])
end

function WormController:_autoSpectate()
	task.delay(1, function()
		if self._alive then
			return
		end
		self:_rebuildSpectateList()
		if #self._spectatePlayers > 0 then
			self:_setupCamera()
			self:SpectateTarget(self._spectatePlayers[1])
		end
	end)
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
	if self._alive then
		-- Send direction to server
		local dir = self:_getWorldDirection()
		if dir and self._wormService then
			self._direction = dir
			self._wormService:SetDirection(dir.X, dir.Z)
		end

		self:_updateCamera()
	elseif not self._inGhostMode and self._spectateTargetModel then
		self:_updateSpectateCamera()
	end
end

--------------------------------------------------
-- Server signals
--------------------------------------------------

function WormController:_connectServerSignals()
	self._trove:Add(
		self._wormService.WormSpawned:Connect(
			function(data: { Segments: number, Color: { number }, Position: { number } })
				if self._inGhostMode then
					self:_exitGhostMode()
				end
				self._alive = true
				self._segments = data.Segments
				self._peakSegments = data.Segments
				self._kills = 0
				self._spectateTarget = nil
				self._spectateTargetModel = nil
				self:_setupCamera()
				self.WormSpawned:Fire(data)
			end
		)
	)

	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		if deadName == LocalPlayer.Name then
			self._alive = false
			self.WormDied:Fire({
				KillerName = killerName,
				MaxSegments = math.floor(self._peakSegments),
				Kills = self._kills,
			})
			self:_autoSpectate()
		end
	end))

	self._trove:Add(self._wormService.WormAte:Connect(function(newSegments: number)
		self._segments = newSegments
		if newSegments > self._peakSegments then
			self._peakSegments = newSegments
		end
		self.SegmentsChanged:Fire(newSegments)
	end))

	-- Kills tracking
	self._trove:Add(self._wormService.PlayerKillsUpdated:Connect(function(kills: number)
		self._kills = kills
	end))

	-- Power-up signals
	self._trove:Add(
		self._powerUpService.PowerUpActivated:Connect(function(ownerName: string, powerUpType: string, duration: number)
			if ownerName == LocalPlayer.Name then
				self.PowerUpActivated:Fire(powerUpType, duration)
			end
			-- Ghost semi-transparent visual for any worm
			if powerUpType == "GHOST" then
				self:_setWormTransparency(ownerName, 0.6)
			end
			-- Speed Burst trail effect
			if powerUpType == "SPEED_BURST" and ownerName == LocalPlayer.Name then
				self:_addSpeedBurstTrail()
			end
		end)
	)

	self._trove:Add(self._powerUpService.PowerUpExpired:Connect(function(ownerName: string, powerUpType: string)
		if ownerName == LocalPlayer.Name then
			self.PowerUpExpired:Fire()
		end
		-- Restore transparency when ghost expires
		if powerUpType == "GHOST" then
			self:_setWormTransparency(ownerName, 0)
		end
		-- Remove speed burst trail
		if powerUpType == "SPEED_BURST" and ownerName == LocalPlayer.Name then
			self:_removeSpeedBurstTrail()
		end
	end))

	-- Ghost mode signals
	self._trove:Add(self._wormService.GhostSpawned:Connect(function(_spawnPos: Vector3)
		self:_enterGhostMode()
	end))

	self._trove:Add(self._wormService.GhostDespawned:Connect(function()
		if self._inGhostMode then
			self:_exitGhostMode()
			-- If still dead, auto-spectate
			if not self._alive then
				self:_setupCamera()
				self:_autoSpectate()
			end
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

	-- Round signals from RoundService
	self._trove:Add(self._roundService.RoundEnded:Connect(function(results: any)
		self._spectateTarget = nil
		self._spectateTargetModel = nil
		self.RoundEnded:Fire(results)
	end))

	self._trove:Add(self._roundService.RoundCountdown:Connect(function(seconds: number)
		self.RoundCountdown:Fire(seconds)
	end))

	self._trove:Add(self._roundService.RoundStarted:Connect(function()
		self._spectateTarget = nil
		self._spectateTargetModel = nil
		self.RoundStarted:Fire()
	end))

	self._trove:Add(self._roundService.ForceSpectate:Connect(function()
		self._alive = false
		self:_setupCamera()
		self:_autoSpectate()
	end))
end

--------------------------------------------------
-- Visual effects
--------------------------------------------------

function WormController:_setWormTransparency(ownerName: string, transparency: number)
	-- Find the model (player character or bot model)
	local model: Model? = nil
	for _, player in Players:GetPlayers() do
		if player.Name == ownerName and player.Character then
			model = player.Character
			break
		end
	end
	if not model then
		model = workspace:FindFirstChild(ownerName) :: Model?
	end
	if not model then
		return
	end

	local wormHead = model:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		wormHead.Transparency = transparency
	end
	local segFolder = model:FindFirstChild("WormSegments") :: Folder?
	if segFolder then
		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				seg.Transparency = transparency
			end
		end
	end
end

function WormController:_addSpeedBurstTrail()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if not wormHead then
		return
	end
	-- Remove existing trail if any
	local existing = wormHead:FindFirstChild("SpeedBurstTrail")
	if existing then
		existing:Destroy()
	end

	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "TrailA0"
	attachment0.Position = Vector3.new(0, 0, -1)
	attachment0.Parent = wormHead

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "TrailA1"
	attachment1.Position = Vector3.new(0, 0, 1)
	attachment1.Parent = wormHead

	local trail = Instance.new("Trail")
	trail.Name = "SpeedBurstTrail"
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 140, 0), Color3.fromRGB(255, 60, 0))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = 0.5
	trail.MinLength = 0.1
	trail.WidthScale = NumberSequence.new(1)
	trail.LightEmission = 0.5
	trail.Parent = wormHead
end

function WormController:ToggleGhostMode()
	if self._alive then
		return -- Can't ghost while alive
	end
	self._wormService:ToggleGhost()
end

function WormController:_enterGhostMode()
	self._inGhostMode = true
	self._spectateTarget = nil
	self._spectateTargetModel = nil

	-- Switch to first-person camera
	Camera.CameraType = Enum.CameraType.Custom
	Camera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")

	-- Force first person
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	self.GhostModeChanged:Fire(true)
end

function WormController:_exitGhostMode()
	self._inGhostMode = false

	-- Restore camera
	LocalPlayer.CameraMode = Enum.CameraMode.Classic
	Camera.CameraType = Enum.CameraType.Scriptable

	self.GhostModeChanged:Fire(false)
end

function WormController:_removeSpeedBurstTrail()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if not wormHead then
		return
	end
	local trail = wormHead:FindFirstChild("SpeedBurstTrail")
	if trail then
		trail:Destroy()
	end
	local a0 = wormHead:FindFirstChild("TrailA0")
	if a0 then
		a0:Destroy()
	end
	local a1 = wormHead:FindFirstChild("TrailA1")
	if a1 then
		a1:Destroy()
	end
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
	self._roundService = Knit.GetService("RoundService")
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
