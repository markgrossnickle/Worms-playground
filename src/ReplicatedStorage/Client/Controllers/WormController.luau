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
	KillConfirmed = Signal.new(),

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
	_grapplePullStart = 0,
	_grapplePullDuration = 0.3,
	_grapplePullStartPos = nil :: Vector3?,
	_rideWeld = nil :: WeldConstraint?,

	-- Tool slot selection (ghost mode)
	_selectedSlot = 1 :: number, -- 1 = Grapple, 2 = Weapon
	SelectedSlotChanged = Signal.new(), -- (slotNumber)

	-- Power-up hiding in ghost mode
	_powerUpHideConn = nil :: RBXScriptConnection?,
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

	-- Keyboard/mouse boost: hold Shift or left mouse button (skip in ghost mode)
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or self._inGhostMode then
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
end

--------------------------------------------------
-- Render loop
--------------------------------------------------

function WormController:_onRenderStep(dt: number)
	if self._alive then
		-- Send direction to server
		local dir = self:_getWorldDirection()
		if dir and self._wormService then
			self._direction = dir
			self._wormService:SetDirection(dir.X, dir.Z)
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

	-- Reset tool selection to grapple
	self._selectedSlot = 1
	self.SelectedSlotChanged:Fire(1)

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

function WormController:_createBeam(fromPart: BasePart, toPart: BasePart)
	-- Clean up old beam
	self:_cleanupBeam()

	local att0 = Instance.new("Attachment")
	att0.Name = "GrappleAtt0"
	att0.Parent = fromPart
	self._grappleAttachment0 = att0

	local att1 = Instance.new("Attachment")
	att1.Name = "GrappleAtt1"
	att1.Parent = toPart
	self._grappleAttachment1 = att1

	local beam = Instance.new("Beam")
	beam.Name = "GrappleBeam"
	beam.Attachment0 = att0
	beam.Attachment1 = att1
	beam.Color = ColorSequence.new(Color3.fromRGB(0, 180, 255))
	beam.Width0 = 0.3
	beam.Width1 = 0.3
	beam.FaceCamera = true
	beam.LightEmission = 0.8
	beam.Transparency = NumberSequence.new(0.2)
	beam.Parent = fromPart
	self._grappleBeam = beam
end

function WormController:_cleanupBeam()
	if self._grappleBeam then
		self._grappleBeam:Destroy()
		self._grappleBeam = nil
	end
	if self._grappleAttachment0 then
		self._grappleAttachment0:Destroy()
		self._grappleAttachment0 = nil
	end
	if self._grappleAttachment1 then
		self._grappleAttachment1:Destroy()
		self._grappleAttachment1 = nil
	end
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
	local targetHead = self._grappleTarget
	if not targetHead or not targetHead.Parent then
		self:_detachGrapple()
		return
	end

	local elapsed = os.clock() - self._grapplePullStart
	local alpha = math.clamp(elapsed / self._grapplePullDuration, 0, 1)

	local startPos = self._grapplePullStartPos :: Vector3
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

	self._grappleState = "IDLE"
	self._grappleTarget = nil
	self._grappleTargetName = nil
	self._grapplePullStartPos = nil
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

function WormController:_onGhostClick()
	if not self._inGhostMode then
		return
	end

	-- Only handle grapple actions when Grapple slot (1) is selected
	if self._selectedSlot ~= 1 then
		return
	end

	if self._grappleState == "RIDING" then
		self:_detachGrapple()
		return
	end

	if self._grappleState == "PULLING" then
		return -- Already pulling, ignore
	end

	-- Try to grapple a worm
	local wormHead, wormModel = self:_findWormUnderCursor()
	if wormHead and wormModel then
		self:_startGrapplePull(wormHead, wormModel)
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

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_onGhostClick()
		elseif input.KeyCode == Enum.KeyCode.Space then
			self:_onGhostSpace()
		elseif input.KeyCode == Enum.KeyCode.One then
			self:SetSelectedSlot(1)
		elseif input.KeyCode == Enum.KeyCode.Two then
			self:SetSelectedSlot(2)
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

function WormController:IsFreeCamActive(): boolean
	return self._freeCamActive
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

function WormController:SetSelectedSlot(slot: number)
	if slot ~= 1 and slot ~= 2 then
		return
	end
	if slot == self._selectedSlot then
		return
	end
	self._selectedSlot = slot
	self.SelectedSlotChanged:Fire(slot)
end

function WormController:GetSelectedSlot(): number
	return self._selectedSlot
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
