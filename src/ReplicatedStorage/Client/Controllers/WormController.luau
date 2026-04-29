--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local GrappleStyles = require(ReplicatedStorage.Shared.GrappleStyles)

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
	KillConfirmed = Signal.new(),

	_trove = nil :: any,
	_wormService = nil :: any,
	_roundService = nil :: any,
	_powerUpService = nil :: any,
	_shrinkZoneService = nil :: any,
	_teamService = nil :: any,
	_direction = Vector3.new(0, 0, -1),
	_boosting = false,
	-- Throttle direction updates to server (20Hz) to save bandwidth
	_lastSentDirection = Vector3.new(0, 0, -1),
	_lastDirectionSendTime = 0,
	_segments = WormConfig.InitialSegments,
	_alive = false,
	_touchPosition = nil :: Vector2?,
	_isTouchDevice = false,

	-- Spectate state
	_spectateTarget = nil :: string?,
	_spectateTargetModel = nil :: Model?,
	_spectatePlayers = {} :: { string },
	_spectateIndex = 0,
	_freeCamActive = false,
	_freeCamCFrame = CFrame.new(),
	FreeCamChanged = Signal.new(),

	-- Per-round stat tracking
	_peakSegments = WormConfig.InitialSegments,
	_kills = 0,
	_spawnTime = 0,
	_lastDeathPosition = nil :: Vector3?,

	-- Ghost mode state
	_inGhostMode = false,
	GhostModeChanged = Signal.new(),

	-- Grapple state
	_grappleState = "IDLE" :: string, -- IDLE | TARGETING | PULLING | RIDING
	_grappleTarget = nil :: BasePart?,
	_grappleTargetName = nil :: string?,
	_grappleBeam = nil :: Beam?,
	_grappleAttachment0 = nil :: Attachment?,
	_grappleAttachment1 = nil :: Attachment?,
	_grappleHighlight = nil :: Highlight?,
	_grappleVisualTrove = nil :: any, -- Trove holding hook/anchor/light/beam/particles
	_grapplePullStart = 0,
	_grapplePullDuration = 0.3,
	_grapplePullStartPos = nil :: Vector3?,
	_rideWeld = nil :: WeldConstraint?,
	_grappleGroundTarget = nil :: Vector3?, -- ground-pull target position
	_grappleGroundPart = nil :: BasePart?, -- temp part for beam attachment

	-- Power-up hiding in ghost mode
	_powerUpHideConn = nil :: RBXScriptConnection?,

	-- Gamepad state
	_gamepadThumbstick = Vector2.zero,
})

--------------------------------------------------
-- Grapple constants
--------------------------------------------------

local GRAPPLE_RANGE = 30
local GRAPPLE_PULL_DURATION = 0.3

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

function WormController:ToggleFreeCam()
	if self._alive or self._inGhostMode then
		return
	end
	self._freeCamActive = not self._freeCamActive
	if self._freeCamActive then
		self._freeCamCFrame = Camera.CFrame
		self._spectateTargetModel = nil
	end
	self.FreeCamChanged:Fire(self._freeCamActive)
end

function WormController:_updateFreeCam(dt: number)
	local speed = 100
	local move = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		move += Camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		move -= Camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		move -= Camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		move += Camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then
		move += Vector3.new(0, 1, 0)
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
		move -= Vector3.new(0, 1, 0)
	end
	if move.Magnitude > 0 then
		move = move.Unit * speed * dt
	end

	local delta = UserInputService:GetMouseDelta()
	local rotX = math.rad(-delta.X * 0.3)
	local rotY = math.rad(-delta.Y * 0.3)

	self._freeCamCFrame = self._freeCamCFrame + move
	self._freeCamCFrame = self._freeCamCFrame * CFrame.Angles(rotY, rotX, 0)
	Camera.CFrame = self._freeCamCFrame
end

--------------------------------------------------
-- Input
--------------------------------------------------

function WormController:_getWorldDirection(): Vector3?
	-- Gamepad thumbstick: convert 2D stick input to world direction
	if self._gamepadThumbstick.Magnitude > 0.2 then
		local camCF = Camera.CFrame
		local forward = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z).Unit
		local right = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z).Unit
		local dir = forward * self._gamepadThumbstick.Y + right * self._gamepadThumbstick.X
		if dir.Magnitude > 0.1 then
			return dir.Unit
		end
		return nil
	end

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

	-- Intersect ray with approximate ground plane at player's terrain height
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local planeY = hrp.Position.Y
	if ray.Direction.Y == 0 then
		return nil
	end

	local t = (planeY - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end

	local hitPoint = ray.Origin + ray.Direction * t

	local dir = (hitPoint - hrp.Position) * Vector3.new(1, 0, 1)
	if dir.Magnitude < 0.1 then
		return nil
	end

	return dir.Unit
end

function WormController:_setupInput()
	self._isTouchDevice = UserInputService.TouchEnabled

	-- Keyboard/mouse boost: hold Shift or left mouse button (skip in ghost mode)
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if self._inGhostMode then
			return
		end

		if not processed then
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
				self:SetBoosting(true)
			end
		end
	end)

	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.LeftShift then
			self:SetBoosting(false)
		end
	end)

	-- Spectate/free-cam keybinds (only when dead, not in ghost mode)
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or self._alive or self._inGhostMode then
			return
		end
		if input.KeyCode == Enum.KeyCode.Left then
			if not self._freeCamActive then
				self:CycleSpectate(-1)
			end
		elseif input.KeyCode == Enum.KeyCode.Right then
			if not self._freeCamActive then
				self:CycleSpectate(1)
			end
		elseif input.KeyCode == Enum.KeyCode.V then
			self:ToggleFreeCam()
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

	-- Gamepad input
	self._trove:Connect(UserInputService.InputChanged, function(input: InputObject, _processed: boolean)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			-- Left thumbstick for movement direction (Y is inverted on Roblox)
			self._gamepadThumbstick = Vector2.new(input.Position.X, -input.Position.Y)
		end
	end)

	-- Gamepad boost: left trigger
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or self._inGhostMode then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA then
			self:SetBoosting(true)
		end
	end)
	self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, _processed: boolean)
		if input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA then
			self:SetBoosting(false)
		end
	end)

	-- Gamepad spectate cycling: bumpers (when dead, not ghost)
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or self._alive or self._inGhostMode then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonL1 then
			if not self._freeCamActive then
				self:CycleSpectate(-1)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR1 then
			if not self._freeCamActive then
				self:CycleSpectate(1)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonY then
			self:ToggleFreeCam()
		end
	end)
end

--------------------------------------------------
-- Render loop
--------------------------------------------------

function WormController:_onRenderStep(dt: number)
	if self._alive then
		-- Compute direction locally every frame (for camera/animation responsiveness)
		local dir = self:_getWorldDirection()
		if dir and self._wormService then
			self._direction = dir
			-- Throttle server sends: only when direction changed > ~3 degrees OR 50ms elapsed (20Hz cap)
			local now = os.clock()
			local dirChangedEnough = dir:Dot(self._lastSentDirection) < 0.9986 -- ~3° threshold
			if dirChangedEnough or (now - self._lastDirectionSendTime) >= 0.05 then
				self._wormService:SetDirection(dir.X, dir.Z)
				self._lastSentDirection = dir
				self._lastDirectionSendTime = now
			end
		end

		self:_updateCamera()
	elseif self._inGhostMode then
		self:_updateGhostGrapple()
	elseif self._freeCamActive then
		self:_updateFreeCam(dt)
	elseif self._spectateTargetModel then
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
				self._spawnTime = os.clock()
				self._lastDeathPosition = nil
				self._freeCamActive = false
				self._spectateTarget = nil
				self._spectateTargetModel = nil
				self:_setupCamera()
				self:_updateCamera() -- Position camera immediately so the first frame isn't misplaced
				self.WormSpawned:Fire(data)
			end
		)
	)

	self._trove:Add(
		self._wormService.WormDied:Connect(
			function(deadName: string, killerName: string?, killerSegments: number?, deadSegments: number?)
				if deadName == LocalPlayer.Name then
					local deathPos = Vector3.zero
					local character = LocalPlayer.Character
					if character then
						local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
						if hrp then
							deathPos = hrp.Position
						end
					end
					self._lastDeathPosition = deathPos

					local survivalTime = math.floor(os.clock() - self._spawnTime)
					self._alive = false
					self._freeCamActive = false
					self.WormDied:Fire({
						KillerName = killerName,
						KillerSegments = killerSegments or 0,
						MaxSegments = math.floor(self._peakSegments),
						Kills = self._kills,
						SurvivalTime = survivalTime,
						DeathPosition = deathPos,
					})
					self:_autoSpectate()
				elseif killerName == LocalPlayer.Name then
					self.KillConfirmed:Fire(deadName, deadSegments or 0)
				end
			end
		)
	)

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

	self._trove:Add(self._wormService.GhostKnockoff:Connect(function(knockbackDir: Vector3)
		self:_onKnockoff(knockbackDir)
	end))

	-- Ghost eaten visual effect
	self._trove:Add(self._wormService.GhostEaten:Connect(function(eatPos: Vector3, _eaterName: string)
		self:_showGhostEatEffect(eatPos)
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

function WormController:_showGhostEatEffect(position: Vector3)
	-- Brief particle burst at eat location
	local part = Instance.new("Part")
	part.Name = "GhostEatFX"
	part.Size = Vector3.new(1, 1, 1)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 255), Color3.fromRGB(255, 255, 255))
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 0) })
	emitter.Lifetime = NumberRange.new(0.3, 0.8)
	emitter.Speed = NumberRange.new(5, 15)
	emitter.SpreadAngle = Vector2.new(360, 360)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = 0 -- use Emit
	emitter.Parent = part
	emitter:Emit(20)

	-- Point light flash
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(180, 200, 255)
	light.Brightness = 3
	light.Range = 15
	light.Parent = part

	-- Clean up after particles fade
	task.delay(1, function()
		part:Destroy()
	end)
end

function WormController:ToggleGhostMode()
	if self._alive then
		return -- Can't ghost while alive
	end
	self._wormService:ToggleGhost()
end

function WormController:_hidePowerUpPart(part: Instance)
	if part:IsA("BasePart") then
		(part :: BasePart).Transparency = 1
	end
	if part:IsA("BasePart") then
		local light = part:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = false
		end
	end
	local billboard = part:FindFirstChildOfClass("BillboardGui")
	if billboard then
		billboard.Enabled = false
	end
	for _, child in part:GetChildren() do
		if child:IsA("BasePart") then
			(child :: BasePart).Transparency = 1
		end
	end
end

function WormController:_showPowerUpPart(part: Instance)
	if part:IsA("BasePart") then
		(part :: BasePart).Transparency = 0
	end
	if part:IsA("BasePart") then
		local light = part:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = true
		end
	end
	local billboard = part:FindFirstChildOfClass("BillboardGui")
	if billboard then
		billboard.Enabled = true
	end
	for _, child in part:GetChildren() do
		if child:IsA("BasePart") then
			-- Pillar has Transparency = 0.5
			if child.Name == "Pillar" then
				(child :: BasePart).Transparency = 0.5
			else
				(child :: BasePart).Transparency = 0
			end
		end
	end
end

function WormController:_hideAllPowerUps()
	local folder = workspace:FindFirstChild("PowerUps")
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		self:_hidePowerUpPart(child)
	end
	-- Hide any new power-ups that spawn while in ghost mode
	if self._powerUpHideConn then
		self._powerUpHideConn:Disconnect()
	end
	self._powerUpHideConn = folder.ChildAdded:Connect(function(child)
		self:_hidePowerUpPart(child)
	end)
end

function WormController:_showAllPowerUps()
	if self._powerUpHideConn then
		self._powerUpHideConn:Disconnect()
		self._powerUpHideConn = nil
	end
	local folder = workspace:FindFirstChild("PowerUps")
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		self:_showPowerUpPart(child)
	end
end

function WormController:_enterGhostMode()
	self._inGhostMode = true
	self._freeCamActive = false
	self._spectateTarget = nil
	self._spectateTargetModel = nil

	-- Hide power-ups from ghost players
	self:_hideAllPowerUps()

	-- Switch to first-person camera
	Camera.CameraType = Enum.CameraType.Custom
	Camera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")

	-- Force first person
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	self.GhostModeChanged:Fire(true)
end

function WormController:_exitGhostMode()
	-- Detach grapple if riding
	if self._grappleState ~= "IDLE" then
		self:_detachGrapple()
	end

	self._inGhostMode = false

	-- Restore power-up visibility
	self:_showAllPowerUps()

	-- Restore camera
	LocalPlayer.CameraMode = Enum.CameraMode.Classic
	Camera.CameraType = Enum.CameraType.Scriptable

	self.GhostModeChanged:Fire(false)
end

--------------------------------------------------
-- Grapple mechanic (ghost mode only)
--------------------------------------------------

function WormController:_findWormUnderCursor(): (BasePart?, Model?)
	local screenCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
	local ray = Camera:ViewportPointToRay(screenCenter.X, screenCenter.Y)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include

	-- Build filter list of all worm head parts
	local filterList = {}
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("WormHead") then
			table.insert(filterList, child)
		end
	end
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("WormHead") then
			table.insert(filterList, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = filterList

	local result = workspace:Raycast(ray.Origin, ray.Direction * GRAPPLE_RANGE, rayParams)
	if result and result.Instance then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChild("WormHead") then
			return model:FindFirstChild("WormHead") :: BasePart, model
		end
	end
	return nil, nil
end

function WormController:_findGroundUnderCursor(): Vector3?
	local screenCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
	local ray = Camera:ViewportPointToRay(screenCenter.X, screenCenter.Y)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { workspace.Terrain }

	local result = workspace:Raycast(ray.Origin, ray.Direction * GRAPPLE_RANGE * 3, rayParams)
	if result then
		return result.Position
	end
	return nil
end

function WormController:_startGroundGrapplePull(targetPos: Vector3)
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	self._grappleState = "PULLING"
	self._grappleGroundTarget = targetPos
	self._grappleTarget = nil
	self._grappleTargetName = nil
	self._grapplePullStart = os.clock()
	-- Scale pull duration with distance so it feels consistent
	local dist = (targetPos - hrp.Position).Magnitude
	self._grapplePullDuration = math.clamp(dist / 150, 0.15, 0.6)
	self._grapplePullStartPos = hrp.Position

	-- Create a small invisible anchored part at the ground target for the beam
	local groundPart = Instance.new("Part")
	groundPart.Name = "GrappleGroundAnchor"
	groundPart.Size = Vector3.new(0.5, 0.5, 0.5)
	groundPart.Position = targetPos
	groundPart.Anchored = true
	groundPart.CanCollide = false
	groundPart.Transparency = 1
	groundPart.Parent = workspace
	self._grappleGroundPart = groundPart

	self:_createBeam(hrp, groundPart)
end

function WormController:_updateGrappleHighlight(wormHead: BasePart?, wormModel: Model?)
	-- Remove old highlight if target changed
	if self._grappleHighlight then
		if not wormModel or self._grappleHighlight.Parent ~= wormModel then
			self._grappleHighlight:Destroy()
			self._grappleHighlight = nil
		end
	end

	if not wormModel or not wormHead then
		return
	end

	-- Create highlight if needed
	if not self._grappleHighlight then
		local highlight = Instance.new("Highlight")
		highlight.Name = "GrappleHighlight"
		highlight.FillColor = Color3.fromRGB(100, 200, 255)
		highlight.FillTransparency = 0.7
		highlight.OutlineColor = Color3.fromRGB(0, 180, 255)
		highlight.OutlineTransparency = 0
		highlight.Parent = wormModel
		self._grappleHighlight = highlight
	end
end

-- Build the ghost-grapple visual: a straight rope that connects the ghost's
-- chest to the target, instantly. No fly-out animation — the line just
-- appears at full length on right-click, the same way a laser shot reads.
-- Particle bursts fire at both endpoints simultaneously to suggest the
-- "shoot out" moment; the existing pull lerp in _updateGrapplePull then
-- reels the ghost in along the visible rope.
--
-- Why no animated tip: a tip Part interpolating linearly through 3D from
-- ghost-height down to ground-target-height visibly dips through terrain
-- when the camera angle is non-trivial, AND with FaceCamera=true the quad
-- orientation goes unstable when one attachment is right at the camera
-- (the ghost's HRP is essentially the camera in first-person). Both
-- problems disappear when the beam is full-length from the start.
--
-- This is PURELY visual. The PULLING → RIDING → IDLE state machine and
-- the per-frame ghost lerp in _updateGrapplePull are untouched.
function WormController:_createBeam(fromPart: BasePart, toPart: BasePart)
	-- Clean up old visual
	self:_cleanupBeam()

	local style = GrappleStyles.getCurrent()
	local color = style.Color

	-- One Trove for the whole visual; _cleanupBeam destroys it in one shot.
	local trove = Trove.new()
	self._grappleVisualTrove = trove

	-- att0 is offset 2 studs forward and 1 stud down in HRP-local space, so
	-- the rope visibly emerges from the ghost's chest rather than from
	-- inside their head/camera. This also keeps att0's world position
	-- meaningfully separated from the camera, which avoids a FaceCamera
	-- quad-orientation degeneracy that produces the "flicker" artifact.
	local att0 = Instance.new("Attachment")
	att0.Name = "GrappleAtt0"
	att0.Position = Vector3.new(0, -1, -2)
	att0.Parent = fromPart
	self._grappleAttachment0 = att0
	trove:Add(att0)

	local toAtt = Instance.new("Attachment")
	toAtt.Name = "GrappleAtt1"
	toAtt.Parent = toPart
	self._grappleAttachment1 = toAtt
	trove:Add(toAtt)

	-- Beam — straight rope, no curve sag, no fly-out. CurveSize=0 means a
	-- direct line between the two attachments; Segments=1 keeps it a
	-- single quad. FaceCamera=true rotates the quad to face the camera
	-- each frame, which is required for a single straight quad to be
	-- visible from arbitrary angles — without it the quad's normal is
	-- determined by the attachments' (default-identity) orientation and
	-- usually ends up edge-on to the camera.
	--
	-- Parent to toPart (worm head or transparent ground anchor Part). Both
	-- are workspace descendants that aren't part of the local ghost
	-- character, so first-person rendering won't cull them.
	local beam = Instance.new("Beam")
	beam.Name = "GrappleBeam"
	beam.Enabled = true
	beam.Attachment0 = att0
	beam.Attachment1 = toAtt
	beam.Color = ColorSequence.new(color)
	-- Minimum width 0.35 — thin enough to read as a rope, not a pipe, but
	-- not a hairline at far range. Style WidthFire ranges 0.3-1.2; this
	-- floor only kicks in for `zipline` (0.30 → 0.35).
	local fireWidth = math.max(style.WidthFire, 0.35)
	beam.Width0 = fireWidth
	beam.Width1 = fireWidth
	beam.Segments = 1
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Transparency = NumberSequence.new(0)
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
	beam.Parent = toPart
	self._grappleBeam = beam
	trove:Add(beam)

	-- Particle bursts at both ends, emitted immediately. Anchor burst at
	-- the target sells the "rope hit something" moment; source burst at
	-- the ghost sells the "you fired" moment. Counts come from the style.
	local impactBurst = Instance.new("ParticleEmitter")
	impactBurst.Name = "GrappleImpactBurst"
	impactBurst.Color = ColorSequence.new(color)
	impactBurst.LightEmission = 1
	impactBurst.LightInfluence = 0
	impactBurst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	impactBurst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	impactBurst.Lifetime = NumberRange.new(0.25, 0.45)
	impactBurst.Speed = NumberRange.new(10, 22)
	impactBurst.SpreadAngle = Vector2.new(180, 180)
	impactBurst.Rotation = NumberRange.new(0, 360)
	impactBurst.Rate = 0
	impactBurst.Drag = 2
	impactBurst.Parent = toPart
	trove:Add(impactBurst)
	impactBurst:Emit(style.AnchorBurst)

	local sourceBurst = Instance.new("ParticleEmitter")
	sourceBurst.Name = "GrappleSourceBurst"
	sourceBurst.Color = ColorSequence.new(color)
	sourceBurst.LightEmission = 1
	sourceBurst.LightInfluence = 0
	sourceBurst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	sourceBurst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sourceBurst.Lifetime = NumberRange.new(0.2, 0.35)
	sourceBurst.Speed = NumberRange.new(8, 16)
	sourceBurst.SpreadAngle = Vector2.new(180, 180)
	sourceBurst.Rotation = NumberRange.new(0, 360)
	sourceBurst.Rate = 0
	sourceBurst.Drag = 2
	sourceBurst.Parent = fromPart
	trove:Add(sourceBurst)
	sourceBurst:Emit(style.WormBurst)

	-- Width morphs WidthFire → WidthPull as the ghost reels in (purely
	-- visual; the actual reel-in is the pull lerp in _updateGrapplePull).
	local pullDur = math.max(style.PullDuration, 0.15)
	local startClock = os.clock()
	trove:Add(RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startClock
		local t = math.clamp(elapsed / pullDur, 0, 1)
		local pullWidth = math.max(style.WidthPull, 0.25)
		local w = fireWidth + (pullWidth - fireWidth) * t
		beam.Width0 = w
		beam.Width1 = w
	end))
end

function WormController:_cleanupBeam()
	if self._grappleVisualTrove then
		self._grappleVisualTrove:Destroy()
		self._grappleVisualTrove = nil
	end
	-- Clear cached references (the trove already destroyed the instances)
	self._grappleBeam = nil
	self._grappleAttachment0 = nil
	self._grappleAttachment1 = nil
end

function WormController:_startGrapplePull(targetHead: BasePart, targetModel: Model)
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	self._grappleState = "PULLING"
	self._grappleTarget = targetHead
	self._grappleTargetName = targetModel.Name
	self._grapplePullStart = os.clock()
	self._grapplePullDuration = GRAPPLE_PULL_DURATION
	self._grapplePullStartPos = hrp.Position

	-- Create beam from ghost to worm head
	self:_createBeam(hrp, targetHead)
end

function WormController:_updateGrapplePull()
	local character = LocalPlayer.Character
	if not character then
		self:_detachGrapple()
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		self:_detachGrapple()
		return
	end

	local elapsed = os.clock() - self._grapplePullStart
	local alpha = math.clamp(elapsed / self._grapplePullDuration, 0, 1)
	local startPos = self._grapplePullStartPos :: Vector3

	-- Ground pull: lerp to static position, then detach (no ride)
	if self._grappleGroundTarget then
		local targetPos = self._grappleGroundTarget + Vector3.new(0, 3, 0) -- land slightly above ground
		hrp.CFrame = CFrame.new(startPos:Lerp(targetPos, alpha))
		if alpha >= 1 then
			self:_detachGrapple()
		end
		return
	end

	-- Worm pull: lerp to moving worm head, then attach/ride
	local targetHead = self._grappleTarget
	if not targetHead or not targetHead.Parent then
		self:_detachGrapple()
		return
	end

	local targetPos = targetHead.Position + Vector3.new(0, 2, 0) -- sit on top
	hrp.CFrame = CFrame.new(startPos:Lerp(targetPos, alpha))

	if alpha >= 1 then
		self:_attachToWorm()
	end
end

function WormController:_attachToWorm()
	local character = LocalPlayer.Character
	if not character then
		self:_detachGrapple()
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		self:_detachGrapple()
		return
	end
	local targetHead = self._grappleTarget
	if not targetHead or not targetHead.Parent then
		self:_detachGrapple()
		return
	end

	-- Position ghost on top of worm head
	hrp.CFrame = targetHead.CFrame * CFrame.new(0, 2, 0)

	-- Weld ghost to worm head
	local weld = Instance.new("WeldConstraint")
	weld.Name = "GrappleWeld"
	weld.Part0 = hrp
	weld.Part1 = targetHead
	weld.Parent = hrp
	self._rideWeld = weld

	-- Remove beam now that we're attached
	self:_cleanupBeam()

	self._grappleState = "RIDING"

	-- Notify server for speed boost tracking
	if self._grappleTargetName then
		self._wormService:GrappleAttached(self._grappleTargetName)
	end

	-- Disable humanoid movement so ghost doesn't walk off
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true
	end
end

function WormController:_detachGrapple()
	-- Notify server before cleanup if we were riding
	if self._grappleState == "RIDING" then
		self._wormService:GrappleDetached()
	end

	local character = LocalPlayer.Character

	-- Clean weld
	if self._rideWeld then
		self._rideWeld:Destroy()
		self._rideWeld = nil
	end

	-- Clean beam
	self:_cleanupBeam()

	-- Clean highlight
	if self._grappleHighlight then
		self._grappleHighlight:Destroy()
		self._grappleHighlight = nil
	end

	-- Re-enable humanoid movement
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.PlatformStand = false
		end
	end

	-- Clean ground anchor part
	if self._grappleGroundPart then
		self._grappleGroundPart:Destroy()
		self._grappleGroundPart = nil
	end

	self._grappleState = "IDLE"
	self._grappleTarget = nil
	self._grappleTargetName = nil
	self._grapplePullStartPos = nil
	self._grappleGroundTarget = nil
end

function WormController:_onKnockoff(knockbackDir: Vector3)
	if not self._inGhostMode then
		return
	end

	-- Detach from worm
	self:_detachGrapple()

	-- Apply knockback impulse
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp:ApplyImpulse(knockbackDir * WormConfig.Ghost.KnockbackForce)
	end

	-- Stun: disable movement temporarily
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		task.delay(WormConfig.Ghost.KnockoffStunDuration, function()
			if humanoid and humanoid.Parent and self._inGhostMode then
				humanoid.WalkSpeed = WormConfig.Ghost.WalkSpeed
				humanoid.JumpPower = WormConfig.Ghost.JumpPower
			end
		end)
	end
end

function WormController:_onGhostGrapple()
	if not self._inGhostMode then
		return
	end

	if self._grappleState == "RIDING" then
		self:_detachGrapple()
		return
	end

	if self._grappleState == "PULLING" then
		return -- Already pulling, ignore
	end

	-- Try to grapple a worm first, then fall back to ground
	local wormHead, wormModel = self:_findWormUnderCursor()
	if wormHead and wormModel then
		self:_startGrapplePull(wormHead, wormModel)
		return
	end

	-- No worm found — try ground grapple
	local groundPos = self:_findGroundUnderCursor()
	if groundPos then
		self:_startGroundGrapplePull(groundPos)
	end
end

function WormController:_onGhostSpace()
	if not self._inGhostMode then
		return
	end
	if self._grappleState == "RIDING" then
		self:_detachGrapple()
	end
end

function WormController:_updateGhostGrapple()
	if not self._inGhostMode then
		return
	end

	if self._grappleState == "PULLING" then
		self:_updateGrapplePull()
		return
	end

	if self._grappleState == "RIDING" then
		-- Check if target worm still exists
		local targetHead = self._grappleTarget
		if not targetHead or not targetHead.Parent then
			self:_detachGrapple()
		end
		return
	end

	-- IDLE state: update targeting highlight
	local wormHead, wormModel = self:_findWormUnderCursor()
	self:_updateGrappleHighlight(wormHead, wormModel)
end

function WormController:_setupGhostInput()
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if not self._inGhostMode then
			return
		end

		-- Right-click / LT = grapple
		if input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			self:_onGhostGrapple()
		elseif input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonB then
			self:_onGhostSpace()
		end
	end)
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

function WormController:IsInGhostMode(): boolean
	return self._inGhostMode
end

function WormController:IsFreeCamActive(): boolean
	return self._freeCamActive
end

-- Public wrapper so touch/mobile UI (e.g. on-screen Grapple button in
-- WormUIController) can trigger the ghost grapple. Grapple is a ghost-only
-- mechanic — alive worms cannot grapple — so this is a no-op when the player
-- isn't currently a ghost.
function WormController:FireGrapple()
	if self._inGhostMode then
		self:_onGhostGrapple()
	end
end

function WormController:GetAliveCount(): number
	local count = 0
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("WormHead") then
			count += 1
		end
	end
	return count
end

function WormController:GetSpectateTarget(): string?
	return self._spectateTarget
end

function WormController:GetLastDeathPosition(): Vector3?
	return self._lastDeathPosition
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
	self:_setupGhostInput()
	self:_connectServerSignals()

	-- Catch up: server may have spawned our worm or ghost before client connected signals
	local ok, data = pcall(function()
		return self._wormService:GetWormData()
	end)
	if ok and data and data.State == "Alive" then
		self._alive = true
		self._segments = data.Segments
		self:_setupCamera()
		self.WormSpawned:Fire(data)
	end

	-- Catch up: check if we're already a ghost (late joiner spawned as ghost)
	local ghostOk, isGhost = pcall(function()
		return self._wormService:IsGhost()
	end)
	if ghostOk and isGhost and not self._inGhostMode then
		self:_enterGhostMode()
	end

	self._trove:Add(RunService.RenderStepped:Connect(function(dt: number)
		self:_onRenderStep(dt)
	end))
end

return WormController
