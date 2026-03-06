--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local CAMERA_ANGLE = 70

-- Death cam timing
local DEATH_FREEZE_DURATION = 0.5
local DEATH_ZOOM_DURATION = 1.5
local DEATH_TOTAL_DURATION = 3.0

-- Kill cam timing
local KILLCAM_DURATION = 1.0
local KILLCAM_SHAKE_INTENSITY = 0.8
local KILLCAM_SHAKE_DURATION = 0.3
local BIG_WORM_THRESHOLD = 20

-- Round end timing
local ROUND_END_ZOOM_DURATION = 1.5

local DeathCamController = Knit.CreateController({
	Name = "DeathCamController",

	_trove = nil :: any,
	_wormController = nil :: any,
	_screenGui = nil :: ScreenGui?,

	-- Death cam state
	_deathCamActive = false,
	_deathCamGui = nil :: Frame?,
	_eliminatedLabel = nil :: TextLabel?,
	_deathStatsLabel = nil :: TextLabel?,

	-- Kill cam state
	_killPopupFrame = nil :: Frame?,
	_killPopupLabel = nil :: TextLabel?,
	_killBonusLabel = nil :: TextLabel?,
	_killCamShaking = false,

	-- Spectate HUD
	_spectateHudFrame = nil :: Frame?,
	_spectateNameLabel = nil :: TextLabel?,
	_spectateSegLabel = nil :: TextLabel?,
	_spectateAliveLabel = nil :: TextLabel?,
	_spectateFreeCamLabel = nil :: TextLabel?,

	-- Round end state
	_roundEndActive = false,
	_roundEndGui = nil :: Frame?,
	_roundWinnerLabel = nil :: TextLabel?,
	_confettiEmitters = {} :: { ParticleEmitter },
})

--------------------------------------------------
-- UI Construction
--------------------------------------------------

local function createLabel(props: {
	Name: string,
	Text: string,
	Size: UDim2,
	Position: UDim2,
	AnchorPoint: Vector2?,
	TextSize: number?,
	TextColor3: Color3?,
	Font: Enum.Font?,
	Parent: GuiObject?,
	BackgroundTransparency: number?,
	TextStrokeTransparency: number?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.Name
	label.Text = props.Text
	label.Size = props.Size
	label.Position = props.Position
	label.AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5)
	label.TextSize = props.TextSize or 24
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.Font = props.Font or Enum.Font.GothamBold
	label.BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BorderSizePixel = 0
	label.TextStrokeTransparency = props.TextStrokeTransparency or 0.5
	label.Parent = props.Parent
	return label
end

function DeathCamController:_buildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DeathCamUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	self._screenGui = gui

	self:_buildDeathCamOverlay(gui)
	self:_buildKillPopup(gui)
	self:_buildSpectateHud(gui)
	self:_buildRoundEndOverlay(gui)
end

function DeathCamController:_buildDeathCamOverlay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "DeathCamOverlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._deathCamGui = frame

	self._eliminatedLabel = createLabel({
		Name = "Eliminated",
		Text = "",
		Size = UDim2.new(1, 0, 0, 60),
		Position = UDim2.fromScale(0.5, 0.35),
		TextSize = 52,
		TextColor3 = Color3.fromRGB(255, 60, 60),
		Font = Enum.Font.GothamBlack,
		Parent = frame,
		TextStrokeTransparency = 0,
	})

	self._deathStatsLabel = createLabel({
		Name = "DeathStats",
		Text = "",
		Size = UDim2.new(1, 0, 0, 35),
		Position = UDim2.fromScale(0.5, 0.42),
		TextSize = 20,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})
end

function DeathCamController:_buildKillPopup(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "KillPopup"
	frame.Size = UDim2.new(0, 350, 0, 80)
	frame.Position = UDim2.fromScale(0.5, 0.2)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._killPopupFrame = frame

	self._killPopupLabel = createLabel({
		Name = "KillText",
		Text = "+1 KILL",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromScale(0.5, 0.3),
		TextSize = 36,
		TextColor3 = Color3.fromRGB(50, 255, 50),
		Font = Enum.Font.GothamBlack,
		Parent = frame,
		TextStrokeTransparency = 0,
	})

	self._killBonusLabel = createLabel({
		Name = "BonusText",
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromScale(0.5, 0.75),
		TextSize = 22,
		TextColor3 = Color3.fromRGB(255, 200, 50),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
end

function DeathCamController:_buildSpectateHud(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "SpectateHud"
	frame.Size = UDim2.new(0, 400, 0, 100)
	frame.Position = UDim2.fromScale(0.5, 0.92)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._spectateHudFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	self._spectateNameLabel = createLabel({
		Name = "SpectateName",
		Text = "Spectating: ---",
		Size = UDim2.new(1, -20, 0, 28),
		Position = UDim2.fromScale(0.5, 0.2),
		TextSize = 22,
		TextColor3 = Color3.fromRGB(100, 200, 255),
		Parent = frame,
	})

	self._spectateSegLabel = createLabel({
		Name = "SpectateSeg",
		Text = "Segments: 0",
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.fromScale(0.5, 0.5),
		TextSize = 16,
		Parent = frame,
	})

	self._spectateAliveLabel = createLabel({
		Name = "SpectateAlive",
		Text = "",
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromScale(0.5, 0.72),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		Parent = frame,
	})

	self._spectateFreeCamLabel = createLabel({
		Name = "FreeCamHint",
		Text = "[V] Free Cam  |  [Left/Right] Cycle Players",
		Size = UDim2.new(1, -20, 0, 18),
		Position = UDim2.fromScale(0.5, 0.92),
		TextSize = 12,
		TextColor3 = Color3.fromRGB(140, 140, 140),
		Parent = frame,
	})
end

function DeathCamController:_buildRoundEndOverlay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "RoundEndOverlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._roundEndGui = frame

	self._roundWinnerLabel = createLabel({
		Name = "WinnerText",
		Text = "",
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromScale(0.5, 0.3),
		TextSize = 56,
		TextColor3 = Color3.fromRGB(255, 215, 0),
		Font = Enum.Font.GothamBlack,
		Parent = frame,
		TextStrokeTransparency = 0,
	})
end

--------------------------------------------------
-- Death Cam
--------------------------------------------------

function DeathCamController:_startDeathCam(deathInfo: {
	KillerName: string?,
	KillerSegments: number,
	MaxSegments: number,
	Kills: number,
	SurvivalTime: number,
	DeathPosition: Vector3,
})
	self._deathCamActive = true

	if not self._deathCamGui or not self._eliminatedLabel or not self._deathStatsLabel then
		return
	end

	local deathPos = deathInfo.DeathPosition

	-- Set up text
	if deathInfo.KillerName then
		local sizeText = if deathInfo.KillerSegments > 0 then " (" .. deathInfo.KillerSegments .. " segments)" else ""
		self._eliminatedLabel.Text = "ELIMINATED BY " .. string.upper(deathInfo.KillerName) .. sizeText
	else
		self._eliminatedLabel.Text = "ELIMINATED BY THE ZONE"
	end

	self._deathStatsLabel.Text = "You survived "
		.. deathInfo.SurvivalTime
		.. "s  |  "
		.. deathInfo.MaxSegments
		.. " max size  |  "
		.. deathInfo.Kills
		.. " kills"

	-- Phase 1: Freeze camera at death location (0.5s)
	Camera.CameraType = Enum.CameraType.Scriptable
	local frozenCFrame = Camera.CFrame

	-- Show overlay with fade-in
	self._deathCamGui.BackgroundTransparency = 1
	self._deathCamGui.Visible = true
	self._eliminatedLabel.TextTransparency = 1
	self._deathStatsLabel.TextTransparency = 1

	task.delay(DEATH_FREEZE_DURATION, function()
		if not self._deathCamActive then
			return
		end

		-- Phase 2: Dramatic zoom on death position
		local zoomHeight = 25
		local angleRad = math.rad(CAMERA_ANGLE)
		local targetOffset = Vector3.new(0, zoomHeight * math.sin(angleRad), zoomHeight * math.cos(angleRad) * 0.3)
		local targetCFrame = CFrame.new(deathPos + targetOffset, deathPos)

		local tweenInfo = TweenInfo.new(DEATH_ZOOM_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- Tween camera via NumberValue proxy
		local camProxy = Instance.new("NumberValue")
		camProxy.Value = 0
		local startCFrame = frozenCFrame
		camProxy:GetPropertyChangedSignal("Value"):Connect(function()
			if self._deathCamActive then
				Camera.CFrame = startCFrame:Lerp(targetCFrame, camProxy.Value)
			end
		end)
		local camTween = TweenService:Create(camProxy, tweenInfo, { Value = 1 })
		camTween:Play()
		camTween.Completed:Connect(function()
			camProxy:Destroy()
		end)

		-- Fade in overlay and text
		local bgTween = TweenService:Create(
			self._deathCamGui,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad),
			{ BackgroundTransparency = 0.5 }
		)
		bgTween:Play()

		task.delay(0.3, function()
			if not self._deathCamActive or not self._eliminatedLabel or not self._deathStatsLabel then
				return
			end
			local textTween1 = TweenService:Create(
				self._eliminatedLabel,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad),
				{ TextTransparency = 0 }
			)
			local textTween2 = TweenService:Create(
				self._deathStatsLabel,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad),
				{ TextTransparency = 0 }
			)
			textTween1:Play()
			textTween2:Play()
		end)
	end)

	-- Phase 3: After DEATH_TOTAL_DURATION, hide death cam
	task.delay(DEATH_TOTAL_DURATION, function()
		self:_endDeathCam()
	end)
end

function DeathCamController:_endDeathCam()
	self._deathCamActive = false
	if self._deathCamGui then
		self._deathCamGui.Visible = false
	end
end

--------------------------------------------------
-- Kill Cam (popup when you kill someone)
--------------------------------------------------

function DeathCamController:_showKillPopup(victimName: string, victimSegments: number)
	if not self._killPopupFrame or not self._killPopupLabel or not self._killBonusLabel then
		return
	end

	self._killPopupLabel.Text = "+1 KILL  " .. victimName
	if victimSegments >= BIG_WORM_THRESHOLD then
		self._killBonusLabel.Text = "MASSIVE TAKEDOWN!"
		self._killBonusLabel.TextColor3 = Color3.fromRGB(255, 100, 50)
	else
		self._killBonusLabel.Text = ""
	end

	-- Reset and show
	self._killPopupFrame.Visible = true
	self._killPopupLabel.TextTransparency = 0
	self._killBonusLabel.TextTransparency = 0

	-- Camera shake
	self:_doCameraShake()

	-- Fade out after duration
	task.delay(KILLCAM_DURATION * 0.6, function()
		if not self._killPopupLabel or not self._killBonusLabel then
			return
		end
		local fadeTween1 = TweenService:Create(
			self._killPopupLabel,
			TweenInfo.new(KILLCAM_DURATION * 0.4, Enum.EasingStyle.Quad),
			{ TextTransparency = 1 }
		)
		local fadeTween2 = TweenService:Create(
			self._killBonusLabel,
			TweenInfo.new(KILLCAM_DURATION * 0.4, Enum.EasingStyle.Quad),
			{ TextTransparency = 1 }
		)
		fadeTween1:Play()
		fadeTween2:Play()
		fadeTween1.Completed:Connect(function()
			if self._killPopupFrame then
				self._killPopupFrame.Visible = false
			end
		end)
	end)
end

function DeathCamController:_doCameraShake()
	if self._killCamShaking then
		return
	end
	self._killCamShaking = true

	local startTime = os.clock()
	local conn: RBXScriptConnection?
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		if elapsed > KILLCAM_SHAKE_DURATION then
			self._killCamShaking = false
			if conn then
				conn:Disconnect()
			end
			return
		end

		local intensity = KILLCAM_SHAKE_INTENSITY * (1 - elapsed / KILLCAM_SHAKE_DURATION)
		local shakeOffset = Vector3.new((math.random() - 0.5) * 2 * intensity, (math.random() - 0.5) * 2 * intensity, 0)
		Camera.CFrame = Camera.CFrame + shakeOffset
	end)
end

--------------------------------------------------
-- Spectate HUD
--------------------------------------------------

function DeathCamController:_updateSpectateHud()
	if not self._wormController then
		return
	end

	local isAlive = self._wormController:IsAlive()
	local isGhost = self._wormController._inGhostMode
	local freeCam = self._wormController:IsFreeCamActive()
	local spectateTarget = self._wormController:GetSpectateTarget()

	-- Show spectate HUD only when dead, not in ghost mode, and not during overlays
	local shouldShow = not isAlive and not isGhost and not self._deathCamActive and not self._roundEndActive
	if self._spectateHudFrame then
		self._spectateHudFrame.Visible = shouldShow
	end

	if not shouldShow then
		return
	end

	-- Update free cam label
	if self._spectateFreeCamLabel then
		if freeCam then
			self._spectateFreeCamLabel.Text = "[V] Exit Free Cam  |  WASD + QE to fly"
		else
			self._spectateFreeCamLabel.Text = "[V] Free Cam  |  [Left/Right] Cycle Players"
		end
	end

	-- Update alive count
	if self._spectateAliveLabel then
		local aliveCount = self._wormController:GetAliveCount()
		self._spectateAliveLabel.Text = aliveCount .. " players remaining"
	end

	if freeCam then
		if self._spectateNameLabel then
			self._spectateNameLabel.Text = "Free Camera"
		end
		if self._spectateSegLabel then
			self._spectateSegLabel.Text = ""
		end
		return
	end

	-- Update spectated player info
	if spectateTarget then
		if self._spectateNameLabel then
			self._spectateNameLabel.Text = "Spectating: " .. spectateTarget
		end

		local segments = 0
		local model = workspace:FindFirstChild(spectateTarget) :: Model?
		if not model then
			for _, player in Players:GetPlayers() do
				if player.Name == spectateTarget and player.Character then
					model = player.Character
					break
				end
			end
		end
		if model then
			local segFolder = model:FindFirstChild("WormSegments") :: Folder?
			if segFolder then
				segments = #segFolder:GetChildren()
			end
		end

		if self._spectateSegLabel then
			self._spectateSegLabel.Text = "Segments: " .. segments
		end
	else
		if self._spectateNameLabel then
			self._spectateNameLabel.Text = "No players to spectate"
		end
		if self._spectateSegLabel then
			self._spectateSegLabel.Text = ""
		end
	end
end

--------------------------------------------------
-- Round End Camera
--------------------------------------------------

function DeathCamController:_startRoundEndCamera(results: { any })
	if not results or #results == 0 then
		return
	end

	self._roundEndActive = true
	self:_endDeathCam()

	local winner = results[1]
	if not winner then
		return
	end

	-- Set winner text
	if self._roundWinnerLabel then
		if WormConfig.TeamModeEnabled then
			self._roundWinnerLabel.Text = "WINNING TEAM: " .. string.upper(winner.Name)
		else
			self._roundWinnerLabel.Text = "WINNER: " .. string.upper(winner.Name)
		end
		self._roundWinnerLabel.TextTransparency = 1
	end

	-- Find winner model
	local winnerModel: Model? = nil
	local winnerPos = Vector3.new(0, 1, 0)

	for _, player in Players:GetPlayers() do
		if player.Name == winner.Name and player.Character then
			winnerModel = player.Character
			break
		end
	end
	if not winnerModel then
		winnerModel = workspace:FindFirstChild(winner.Name) :: Model?
	end

	if winnerModel then
		local hrp = winnerModel:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			winnerPos = hrp.Position
		end

		-- Spotlight effect on winner
		local spotlight = Instance.new("SpotLight")
		spotlight.Name = "WinnerSpotlight"
		spotlight.Brightness = 5
		spotlight.Range = 60
		spotlight.Angle = 45
		spotlight.Color = Color3.fromRGB(255, 215, 0)
		local headPart = winnerModel:FindFirstChild("WormHead") :: BasePart?
		if headPart then
			spotlight.Parent = headPart
			self:_spawnConfetti(headPart)
		end

		-- Clean up after scoreboard
		task.delay(WormConfig.RoundScoreboardDuration, function()
			spotlight:Destroy()
			self:_cleanupConfetti()
		end)
	end

	-- Zoom camera to winner
	Camera.CameraType = Enum.CameraType.Scriptable
	local zoomHeight = 30
	local angleRad = math.rad(CAMERA_ANGLE)
	local targetOffset = Vector3.new(0, zoomHeight * math.sin(angleRad), zoomHeight * math.cos(angleRad) * 0.3)
	local targetCFrame = CFrame.new(winnerPos + targetOffset, winnerPos)

	local startCFrame = Camera.CFrame
	local camProxy = Instance.new("NumberValue")
	camProxy.Value = 0
	camProxy:GetPropertyChangedSignal("Value"):Connect(function()
		if self._roundEndActive then
			Camera.CFrame = startCFrame:Lerp(targetCFrame, camProxy.Value)
		end
	end)

	local tweenInfo = TweenInfo.new(ROUND_END_ZOOM_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local camTween = TweenService:Create(camProxy, tweenInfo, { Value = 1 })
	camTween:Play()
	camTween.Completed:Connect(function()
		camProxy:Destroy()
	end)

	-- Show overlay
	if self._roundEndGui then
		self._roundEndGui.Visible = true
		self._roundEndGui.BackgroundTransparency = 1
		local bgTween = TweenService:Create(
			self._roundEndGui,
			TweenInfo.new(0.8, Enum.EasingStyle.Quad),
			{ BackgroundTransparency = 0.6 }
		)
		bgTween:Play()
	end

	-- Fade in winner text
	task.delay(0.5, function()
		if self._roundWinnerLabel and self._roundEndActive then
			local textTween = TweenService:Create(
				self._roundWinnerLabel,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad),
				{ TextTransparency = 0 }
			)
			textTween:Play()
		end
	end)
end

function DeathCamController:_endRoundEndCamera()
	self._roundEndActive = false
	if self._roundEndGui then
		self._roundEndGui.Visible = false
	end
	self:_cleanupConfetti()
end

function DeathCamController:_spawnConfetti(parent: BasePart)
	self:_cleanupConfetti()

	local colors = {
		Color3.fromRGB(255, 50, 50),
		Color3.fromRGB(50, 255, 50),
		Color3.fromRGB(50, 50, 255),
		Color3.fromRGB(255, 215, 0),
		Color3.fromRGB(255, 100, 200),
	}

	for i = 1, 3 do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Confetti" .. i
		emitter.Rate = 30
		emitter.Lifetime = NumberRange.new(1.5, 3)
		emitter.Speed = NumberRange.new(10, 25)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.RotSpeed = NumberRange.new(-200, 200)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0.2),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.8, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Color = ColorSequence.new(colors[i], colors[i + 1] or colors[1])
		emitter.LightEmission = 0.3
		emitter.Parent = parent
		table.insert(self._confettiEmitters, emitter)
	end
end

function DeathCamController:_cleanupConfetti()
	for _, emitter in self._confettiEmitters do
		emitter:Destroy()
	end
	self._confettiEmitters = {}
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function DeathCamController:KnitInit()
	self._trove = Trove.new()
end

function DeathCamController:KnitStart()
	self._wormController = Knit.GetController("WormController")
	self:_buildUI()

	-- Death cam: triggered when local player dies
	self._trove:Add(self._wormController.WormDied:Connect(function(deathInfo: any)
		self:_startDeathCam(deathInfo)
	end))

	-- Kill confirmation popup
	self._trove:Add(self._wormController.KillConfirmed:Connect(function(victimName: string, victimSegments: number)
		self:_showKillPopup(victimName, victimSegments)
	end))

	-- Hide death cam on respawn
	self._trove:Add(self._wormController.WormSpawned:Connect(function()
		self:_endDeathCam()
		self:_endRoundEndCamera()
	end))

	-- Round end camera
	self._trove:Add(self._wormController.RoundEnded:Connect(function(results: any)
		self:_startRoundEndCamera(results)
	end))

	-- Clean up round end on new round
	self._trove:Add(self._wormController.RoundStarted:Connect(function()
		self:_endRoundEndCamera()
	end))

	self._trove:Add(self._wormController.RoundCountdown:Connect(function()
		self:_endRoundEndCamera()
	end))

	-- Ghost mode hides death cam
	self._trove:Add(self._wormController.GhostModeChanged:Connect(function(inGhost: boolean)
		if inGhost then
			self:_endDeathCam()
			if self._spectateHudFrame then
				self._spectateHudFrame.Visible = false
			end
		end
	end))

	-- Free cam and spectate changes update HUD
	self._trove:Add(self._wormController.FreeCamChanged:Connect(function()
		self:_updateSpectateHud()
	end))

	self._trove:Add(self._wormController.SpectateChanged:Connect(function()
		self:_updateSpectateHud()
	end))

	-- Periodic spectate HUD update (segment counts change over time)
	local hudUpdateTimer = 0
	self._trove:Add(RunService.Heartbeat:Connect(function(dt: number)
		hudUpdateTimer += dt
		if hudUpdateTimer >= 1 then
			hudUpdateTimer = 0
			if self._spectateHudFrame and self._spectateHudFrame.Visible then
				self:_updateSpectateHud()
			end
		end
	end))
end

return DeathCamController
