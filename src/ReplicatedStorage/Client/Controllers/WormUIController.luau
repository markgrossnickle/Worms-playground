--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local PERIODIC_UPDATE_INTERVAL = 2
local KILL_FEED_DURATION = 4
local MAX_KILL_FEED = 5

local POWERUP_COLORS = {
	SPEED = Color3.fromRGB(0, 200, 255),
	SPEED_BURST = Color3.fromRGB(255, 140, 0),
	MAGNET = Color3.fromRGB(255, 0, 200),
	GHOST = Color3.fromRGB(200, 200, 255),
	SHIELD = Color3.fromRGB(255, 220, 0),
	SIZE_BOMB = Color3.fromRGB(255, 80, 0),
	FREEZE_RING = Color3.fromRGB(100, 180, 255),
}

local WormUIController = Knit.CreateController({
	Name = "WormUIController",

	_trove = nil :: any,
	_screenGui = nil :: ScreenGui?,
	_segmentLabel = nil :: TextLabel?,
	_deathFrame = nil :: Frame?,
	_deathLabel = nil :: TextLabel?,
	_killFeedFrame = nil :: Frame?,
	_minimapFrame = nil :: Frame?,
	_minimapArrow = nil :: TextLabel?,
	_boostButton = nil :: ImageButton?,
	_powerUpFrame = nil :: Frame?,
	_powerUpLabel = nil :: TextLabel?,
	_powerUpTimer = nil :: TextLabel?,
	_gameTimerLabel = nil :: TextLabel?,
	_zoneWarningLabel = nil :: TextLabel?,
	_shrinkCircle = nil :: Frame?,
	_wormService = nil :: any,
	_wormController = nil :: any,
	_powerUpService = nil :: any,
	_currentZoneRadius = WormConfig.ArenaSize / 2,
	_activePowerUpEnd = 0,

	-- Ghost mode toggle
	_ghostToggleBtn = nil :: TextButton?,
	_crosshairFrame = nil :: Frame?,

	-- Round UI elements
	_statsLabel = nil :: TextLabel?,
	_spectateSection = nil :: Frame?,
	_spectateLabel = nil :: TextLabel?,
	_spectateButtonPrev = nil :: TextButton?,
	_spectateButtonNext = nil :: TextButton?,
	_finalScoreboardFrame = nil :: Frame?,
	_scoreboardList = nil :: Frame?,
	_scoreboardWinner = nil :: TextLabel?,
	_countdownFrame = nil :: Frame?,
	_countdownLabel = nil :: TextLabel?,

	-- Coin display
	_coinLabel = nil :: TextLabel?,
	_coinService = nil :: any,

	-- Ghost toolbar
	_toolbarFrame = nil :: Frame?,
	_grappleSlot = nil :: TextButton?,
	_grappleHint = nil :: TextLabel?,
	_grappleSlotStroke = nil :: UIStroke?,
	_weaponSlotLabel = nil :: TextLabel?,
	_weaponSlotAmmo = nil :: TextLabel?,
	_weaponSlotStroke = nil :: UIStroke?,
	_weaponController = nil :: any,
	_maxAmmo = 0,

	-- Rider notification (shown to worm player when a ghost rides them)
	_riderNotifyLabel = nil :: TextLabel?,
})

--------------------------------------------------
-- UI construction helpers
--------------------------------------------------

local function createTextLabel(props: {
	Name: string,
	Text: string,
	Size: UDim2,
	Position: UDim2,
	AnchorPoint: Vector2?,
	TextSize: number?,
	TextColor3: Color3?,
	BackgroundTransparency: number?,
	BackgroundColor3: Color3?,
	Font: Enum.Font?,
	Parent: GuiObject?,
	TextXAlignment: Enum.TextXAlignment?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.Name
	label.Text = props.Text
	label.Size = props.Size
	label.Position = props.Position
	label.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	label.TextSize = props.TextSize or 18
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1
	label.BackgroundColor3 = props.BackgroundColor3 or Color3.new(0, 0, 0)
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center
	label.BorderSizePixel = 0
	label.Parent = props.Parent
	return label
end

--------------------------------------------------
-- Build UI
--------------------------------------------------

function WormUIController:_buildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WormUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui
	self._screenGui = gui

	self:_buildSegmentCounter(gui)
	self:_buildDeathScreen(gui)
	self:_buildKillFeed(gui)
	self:_buildMinimap(gui)
	self:_buildBoostButton(gui)
	self:_buildPowerUpDisplay(gui)
	self:_buildGameTimer(gui)
	self:_buildZoneWarning(gui)
	self:_buildFinalScoreboard(gui)
	self:_buildCountdownOverlay(gui)
	self:_buildCoinDisplay(gui)
	self:_buildCrosshair(gui)
	self:_buildToolbar(gui)
	self:_buildRiderNotification(gui)
end

function WormUIController:_buildSegmentCounter(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "SegmentCounter"
	frame.Size = UDim2.new(0, 200, 0, 50)
	frame.Position = UDim2.new(0.5, 0, 0, 10)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	self._segmentLabel = createTextLabel({
		Name = "Count",
		Text = "Segments: " .. WormConfig.InitialSegments,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 24,
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
end

function WormUIController:_buildDeathScreen(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "DeathScreen"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.4
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._deathFrame = frame

	createTextLabel({
		Name = "Title",
		Text = "YOU DIED",
		Size = UDim2.new(0, 400, 0, 60),
		Position = UDim2.fromScale(0.5, 0.3),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 48,
		TextColor3 = Color3.fromRGB(255, 50, 50),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._deathLabel = createTextLabel({
		Name = "Info",
		Text = "",
		Size = UDim2.new(0, 400, 0, 40),
		Position = UDim2.fromScale(0.5, 0.38),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 22,
		Parent = frame,
	})

	-- Stats label: "Max Size: N | Kills: N"
	self._statsLabel = createTextLabel({
		Name = "Stats",
		Text = "",
		Size = UDim2.new(0, 400, 0, 30),
		Position = UDim2.fromScale(0.5, 0.45),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})

	-- Spectate section
	local spectateSection = Instance.new("Frame")
	spectateSection.Name = "SpectateSection"
	spectateSection.Size = UDim2.new(0, 400, 0, 80)
	spectateSection.Position = UDim2.fromScale(0.5, 0.58)
	spectateSection.AnchorPoint = Vector2.new(0.5, 0.5)
	spectateSection.BackgroundTransparency = 1
	spectateSection.BorderSizePixel = 0
	spectateSection.Parent = frame
	self._spectateSection = spectateSection

	createTextLabel({
		Name = "SpectateTitle",
		Text = "SPECTATING",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(150, 150, 150),
		Parent = spectateSection,
	})

	self._spectateLabel = createTextLabel({
		Name = "TargetName",
		Text = "---",
		Size = UDim2.new(0, 200, 0, 30),
		Position = UDim2.fromScale(0.5, 0.4),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 22,
		TextColor3 = Color3.fromRGB(255, 255, 100),
		Parent = spectateSection,
	})

	-- Prev button
	local prevBtn = Instance.new("TextButton")
	prevBtn.Name = "PrevBtn"
	prevBtn.Size = UDim2.new(0, 60, 0, 30)
	prevBtn.Position = UDim2.new(0.5, -110, 1, -5)
	prevBtn.AnchorPoint = Vector2.new(0.5, 1)
	prevBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	prevBtn.BackgroundTransparency = 0.3
	prevBtn.BorderSizePixel = 0
	prevBtn.Text = "< Prev"
	prevBtn.TextColor3 = Color3.new(1, 1, 1)
	prevBtn.TextSize = 14
	prevBtn.Font = Enum.Font.GothamBold
	prevBtn.Parent = spectateSection
	self._spectateButtonPrev = prevBtn

	local prevCorner = Instance.new("UICorner")
	prevCorner.CornerRadius = UDim.new(0, 6)
	prevCorner.Parent = prevBtn

	-- Next button
	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "NextBtn"
	nextBtn.Size = UDim2.new(0, 60, 0, 30)
	nextBtn.Position = UDim2.new(0.5, 110, 1, -5)
	nextBtn.AnchorPoint = Vector2.new(0.5, 1)
	nextBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	nextBtn.BackgroundTransparency = 0.3
	nextBtn.BorderSizePixel = 0
	nextBtn.Text = "Next >"
	nextBtn.TextColor3 = Color3.new(1, 1, 1)
	nextBtn.TextSize = 14
	nextBtn.Font = Enum.Font.GothamBold
	nextBtn.Parent = spectateSection
	self._spectateButtonNext = nextBtn

	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UDim.new(0, 6)
	nextCorner.Parent = nextBtn

	-- Ghost mode toggle button
	local ghostBtn = Instance.new("TextButton")
	ghostBtn.Name = "GhostToggle"
	ghostBtn.Size = UDim2.new(0, 180, 0, 36)
	ghostBtn.Position = UDim2.fromScale(0.5, 0.72)
	ghostBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	ghostBtn.BackgroundColor3 = Color3.fromRGB(80, 100, 160)
	ghostBtn.BackgroundTransparency = 0.2
	ghostBtn.BorderSizePixel = 0
	ghostBtn.Text = "Enter Ghost Mode"
	ghostBtn.TextColor3 = Color3.fromRGB(180, 200, 255)
	ghostBtn.TextSize = 16
	ghostBtn.Font = Enum.Font.GothamBold
	ghostBtn.Parent = frame
	self._ghostToggleBtn = ghostBtn

	local ghostCorner = Instance.new("UICorner")
	ghostCorner.CornerRadius = UDim.new(0, 8)
	ghostCorner.Parent = ghostBtn
end

function WormUIController:_buildKillFeed(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "KillFeed"
	frame.Size = UDim2.new(0, 300, 0, MAX_KILL_FEED * 28)
	frame.Position = UDim2.new(0, 10, 0, 60)
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = parent
	self._killFeedFrame = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame
end

function WormUIController:_buildMinimap(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Minimap"
	frame.Size = UDim2.new(0, 140, 0, 140)
	frame.Position = UDim2.new(1, -10, 1, -10)
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = parent
	self._minimapFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(100, 100, 100)
	stroke.Thickness = 1
	stroke.Parent = frame

	-- Shrink zone circle on minimap
	local shrinkCircle = Instance.new("Frame")
	shrinkCircle.Name = "ShrinkCircle"
	shrinkCircle.Size = UDim2.fromScale(1, 1)
	shrinkCircle.Position = UDim2.fromScale(0.5, 0.5)
	shrinkCircle.AnchorPoint = Vector2.new(0.5, 0.5)
	shrinkCircle.BackgroundTransparency = 1
	shrinkCircle.BorderSizePixel = 0
	shrinkCircle.Parent = frame

	local circleCorner = Instance.new("UICorner")
	circleCorner.CornerRadius = UDim.new(1, 0)
	circleCorner.Parent = shrinkCircle

	local circleStroke = Instance.new("UIStroke")
	circleStroke.Color = Color3.fromRGB(255, 50, 50)
	circleStroke.Thickness = 2
	circleStroke.Parent = shrinkCircle

	self._shrinkCircle = shrinkCircle

	-- Persistent player arrow (updated every frame for smooth rotation)
	local arrow = Instance.new("TextLabel")
	arrow.Name = "PlayerArrow"
	arrow.Text = "\u{25B2}"
	arrow.Size = UDim2.new(0, 22, 0, 22)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.BackgroundTransparency = 1
	arrow.TextColor3 = Color3.fromRGB(100, 255, 100)
	arrow.TextSize = 22
	arrow.Font = Enum.Font.GothamBold
	arrow.Rotation = 0
	arrow.BorderSizePixel = 0
	arrow.ZIndex = 10
	arrow.Parent = frame
	self._minimapArrow = arrow

	-- Shift minimap up on touch devices to make room for boost button
	if UserInputService.TouchEnabled then
		frame.Position = UDim2.new(1, -10, 1, -120)
	end
end

function WormUIController:_buildBoostButton(parent: ScreenGui)
	if not UserInputService.TouchEnabled then
		return
	end

	local button = Instance.new("ImageButton")
	button.Name = "BoostButton"
	button.Size = UDim2.new(0, 100, 0, 100)
	button.Position = UDim2.new(1, -30, 1, -10)
	button.AnchorPoint = Vector2.new(1, 1)
	button.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
	button.BackgroundTransparency = 0.3
	button.BorderSizePixel = 0
	button.Image = ""
	button.AutoButtonColor = false
	button.Parent = parent
	self._boostButton = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local boostStroke = Instance.new("UIStroke")
	boostStroke.Color = Color3.fromRGB(255, 200, 50)
	boostStroke.Thickness = 3
	boostStroke.Parent = button

	createTextLabel({
		Name = "Label",
		Text = "BOOST",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = button,
	})

	-- Wire press/release to WormController boost
	button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.1
			button.BackgroundColor3 = Color3.fromRGB(255, 220, 50)
			if self._wormController then
				self._wormController:SetBoosting(true)
			end
		end
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.3
			button.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
			if self._wormController then
				self._wormController:SetBoosting(false)
			end
		end
	end)
end

function WormUIController:_buildPowerUpDisplay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "PowerUpDisplay"
	frame.Size = UDim2.new(0, 180, 0, 40)
	frame.Position = UDim2.new(0.5, 0, 0, 65)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._powerUpFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	self._powerUpLabel = createTextLabel({
		Name = "TypeLabel",
		Text = "",
		Size = UDim2.new(1, 0, 0.5, 0),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._powerUpTimer = createTextLabel({
		Name = "TimerLabel",
		Text = "",
		Size = UDim2.new(1, 0, 0.5, 0),
		Position = UDim2.fromScale(0, 0.5),
		TextSize = 12,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})
end

function WormUIController:_buildGameTimer(parent: ScreenGui)
	self._gameTimerLabel = createTextLabel({
		Name = "GameTimer",
		Text = "0:00",
		Size = UDim2.new(0, 100, 0, 30),
		Position = UDim2.new(0.5, 110, 0, 15),
		AnchorPoint = Vector2.new(0, 0),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Font = Enum.Font.GothamBold,
		Parent = parent,
	})
end

function WormUIController:_buildZoneWarning(parent: ScreenGui)
	self._zoneWarningLabel = createTextLabel({
		Name = "ZoneWarning",
		Text = "",
		Size = UDim2.new(0, 400, 0, 40),
		Position = UDim2.new(0.5, 0, 0.2, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 28,
		TextColor3 = Color3.fromRGB(255, 80, 80),
		Font = Enum.Font.GothamBold,
		Parent = parent,
	})
end

function WormUIController:_buildFinalScoreboard(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "FinalScoreboard"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 10
	frame.Parent = parent
	self._finalScoreboardFrame = frame

	createTextLabel({
		Name = "Title",
		Text = "ROUND OVER",
		Size = UDim2.new(0, 400, 0, 50),
		Position = UDim2.fromScale(0.5, 0.1),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 40,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._scoreboardWinner = createTextLabel({
		Name = "Winner",
		Text = "",
		Size = UDim2.new(0, 400, 0, 35),
		Position = UDim2.fromScale(0.5, 0.18),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 28,
		TextColor3 = Color3.fromRGB(100, 255, 100),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	-- Header row
	local headerFrame = Instance.new("Frame")
	headerFrame.Name = "Header"
	headerFrame.Size = UDim2.new(0, 540, 0, 30)
	headerFrame.Position = UDim2.fromScale(0.5, 0.26)
	headerFrame.AnchorPoint = Vector2.new(0.5, 0)
	headerFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	headerFrame.BackgroundTransparency = 0.3
	headerFrame.BorderSizePixel = 0
	headerFrame.ZIndex = 11
	headerFrame.Parent = frame

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 4)
	headerCorner.Parent = headerFrame

	createTextLabel({
		Name = "H1",
		Text = "#",
		Size = UDim2.new(0, 40, 1, 0),
		Position = UDim2.fromOffset(5, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H2",
		Text = "Name",
		Size = UDim2.new(0, 200, 1, 0),
		Position = UDim2.fromOffset(50, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H3",
		Text = "Kills",
		Size = UDim2.new(0, 80, 1, 0),
		Position = UDim2.fromOffset(270, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H4",
		Text = "Max Size",
		Size = UDim2.new(0, 80, 1, 0),
		Position = UDim2.fromOffset(360, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H5",
		Text = "Coins",
		Size = UDim2.new(0, 70, 1, 0),
		Position = UDim2.fromOffset(450, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Parent = headerFrame,
	})

	-- Scrolling list container
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "List"
	scrollFrame.Size = UDim2.new(0, 540, 0, 300)
	scrollFrame.Position = UDim2.fromScale(0.5, 0.3)
	scrollFrame.AnchorPoint = Vector2.new(0.5, 0)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 4
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.ZIndex = 11
	scrollFrame.Parent = frame
	self._scoreboardList = scrollFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = scrollFrame
end

function WormUIController:_buildCoinDisplay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "CoinDisplay"
	frame.Size = UDim2.new(0, 140, 0, 40)
	frame.Position = UDim2.new(1, -10, 0, 10)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	-- Coin icon (gold circle)
	local icon = Instance.new("Frame")
	icon.Name = "CoinIcon"
	icon.Size = UDim2.new(0, 24, 0, 24)
	icon.Position = UDim2.new(0, 8, 0.5, 0)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	icon.BorderSizePixel = 0
	icon.Parent = frame

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	self._coinLabel = createTextLabel({
		Name = "CoinCount",
		Text = "0",
		Size = UDim2.new(0, 90, 1, 0),
		Position = UDim2.fromOffset(40, 0),
		TextSize = 20,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
end

function WormUIController:_buildCrosshair(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Crosshair"
	frame.Size = UDim2.new(0, 24, 0, 24)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._crosshairFrame = frame

	-- Horizontal line
	local hLine = Instance.new("Frame")
	hLine.Name = "H"
	hLine.Size = UDim2.new(1, 0, 0, 2)
	hLine.Position = UDim2.fromScale(0, 0.5)
	hLine.AnchorPoint = Vector2.new(0, 0.5)
	hLine.BackgroundColor3 = Color3.fromRGB(0, 200, 255)
	hLine.BorderSizePixel = 0
	hLine.Parent = frame

	-- Vertical line
	local vLine = Instance.new("Frame")
	vLine.Name = "V"
	vLine.Size = UDim2.new(0, 2, 1, 0)
	vLine.Position = UDim2.fromScale(0.5, 0)
	vLine.AnchorPoint = Vector2.new(0.5, 0)
	vLine.BackgroundColor3 = Color3.fromRGB(0, 200, 255)
	vLine.BorderSizePixel = 0
	vLine.Parent = frame

	-- Center dot
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.new(0, 4, 0, 4)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dot.BorderSizePixel = 0
	dot.Parent = frame

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
end

function WormUIController:_buildToolbar(parent: ScreenGui)
	-- Container bar at bottom center
	local toolbar = Instance.new("Frame")
	toolbar.Name = "GhostToolbar"
	toolbar.Size = UDim2.new(0, 400, 0, 60)
	toolbar.Position = UDim2.new(0.5, 0, 1, -10)
	toolbar.AnchorPoint = Vector2.new(0.5, 1)
	toolbar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	toolbar.BackgroundTransparency = 0.4
	toolbar.BorderSizePixel = 0
	toolbar.Visible = false
	toolbar.Parent = parent
	self._toolbarFrame = toolbar

	local toolbarCorner = Instance.new("UICorner")
	toolbarCorner.CornerRadius = UDim.new(0, 10)
	toolbarCorner.Parent = toolbar

	local toolbarStroke = Instance.new("UIStroke")
	toolbarStroke.Color = Color3.fromRGB(80, 80, 80)
	toolbarStroke.Thickness = 1
	toolbarStroke.Parent = toolbar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = toolbar

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = toolbar

	-- Slot 1: Grapple
	local grappleSlot = self:_buildToolbarSlot(toolbar, "1", "GRAPPLE", "LMB to hook", Color3.fromRGB(0, 180, 255))
	self._grappleSlot = grappleSlot.Frame
	self._grappleHint = grappleSlot.Hint
	self._grappleSlotStroke = grappleSlot.Stroke
	-- Grapple starts selected
	self._grappleSlotStroke.Transparency = 0

	-- Divider
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(0, 1, 0.6, 0)
	divider.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
	divider.BorderSizePixel = 0
	divider.LayoutOrder = 2
	divider.Parent = toolbar

	-- Slot 2: Weapon
	local weaponSlot = self:_buildToolbarSlot(toolbar, "2", "---", "LMB to fire", Color3.fromRGB(255, 200, 50))
	weaponSlot.Frame.LayoutOrder = 3
	self._weaponSlotLabel = weaponSlot.Label
	self._weaponSlotAmmo = weaponSlot.Ammo
	self._weaponSlotStroke = weaponSlot.Stroke

	-- Click handlers for cross-platform slot switching (TextButton.Activated works on desktop + mobile)
	grappleSlot.Frame.Activated:Connect(function()
		if self._wormController then
			self._wormController:SetSelectedSlot(1)
		end
	end)
	weaponSlot.Frame.Activated:Connect(function()
		if self._wormController then
			self._wormController:SetSelectedSlot(2)
		end
	end)
end

function WormUIController:_buildRiderNotification(parent: ScreenGui)
	local label = Instance.new("TextLabel")
	label.Name = "RiderNotification"
	label.Text = ""
	label.Size = UDim2.new(0, 350, 0, 30)
	label.Position = UDim2.new(0.5, 0, 0.12, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(100, 220, 255)
	label.Font = Enum.Font.GothamBold
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.5
	label.Parent = parent
	self._riderNotifyLabel = label
end

function WormUIController:_buildToolbarSlot(
	parent: Frame,
	keyHint: string,
	toolName: string,
	actionHint: string,
	accentColor: Color3
): {
	Frame: TextButton,
	Label: TextLabel,
	Hint: TextLabel,
	Ammo: TextLabel,
	Stroke: UIStroke,
}
	local slot = Instance.new("TextButton")
	slot.Name = "Slot" .. keyHint
	slot.Size = UDim2.new(0, 180, 0, 50)
	slot.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	slot.BackgroundTransparency = 0.3
	slot.BorderSizePixel = 0
	slot.LayoutOrder = tonumber(keyHint) or 1
	slot.Text = ""
	slot.AutoButtonColor = false
	slot.Parent = parent

	local slotCorner = Instance.new("UICorner")
	slotCorner.CornerRadius = UDim.new(0, 6)
	slotCorner.Parent = slot

	-- Selection highlight stroke
	local slotStroke = Instance.new("UIStroke")
	slotStroke.Color = accentColor
	slotStroke.Thickness = 2
	slotStroke.Transparency = 1 -- hidden by default
	slotStroke.Parent = slot

	-- Key badge (small square with number)
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.new(0, 20, 0, 20)
	badge.Position = UDim2.new(0, 6, 0, 6)
	badge.BackgroundColor3 = accentColor
	badge.BackgroundTransparency = 0.3
	badge.BorderSizePixel = 0
	badge.Parent = slot

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 4)
	badgeCorner.Parent = badge

	local badgeLabel = Instance.new("TextLabel")
	badgeLabel.Name = "Key"
	badgeLabel.Size = UDim2.fromScale(1, 1)
	badgeLabel.BackgroundTransparency = 1
	badgeLabel.Text = keyHint
	badgeLabel.TextColor3 = Color3.new(1, 1, 1)
	badgeLabel.TextSize = 12
	badgeLabel.Font = Enum.Font.GothamBold
	badgeLabel.Parent = badge

	-- Tool name label
	local nameLabel = createTextLabel({
		Name = "ToolName",
		Text = toolName,
		Size = UDim2.new(0, 120, 0, 20),
		Position = UDim2.new(0, 32, 0, 4),
		TextSize = 16,
		TextColor3 = accentColor,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = slot,
	})

	-- Ammo label (right side, for weapon slot)
	local ammoLabel = createTextLabel({
		Name = "Ammo",
		Text = "",
		Size = UDim2.new(0, 40, 0, 20),
		Position = UDim2.new(1, -8, 0, 4),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = slot,
	})

	-- Action hint (bottom row)
	local hintLabel = createTextLabel({
		Name = "Hint",
		Text = actionHint,
		Size = UDim2.new(1, -12, 0, 16),
		Position = UDim2.new(0, 6, 1, -4),
		AnchorPoint = Vector2.new(0, 1),
		TextSize = 11,
		TextColor3 = Color3.fromRGB(140, 140, 140),
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = slot,
	})

	return {
		Frame = slot,
		Label = nameLabel,
		Hint = hintLabel,
		Ammo = ammoLabel,
		Stroke = slotStroke,
	}
end

function WormUIController:_buildCountdownOverlay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "CountdownOverlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 12
	frame.Parent = parent
	self._countdownFrame = frame

	self._countdownLabel = createTextLabel({
		Name = "CountdownText",
		Text = "",
		Size = UDim2.new(0, 400, 0, 80),
		Position = UDim2.fromScale(0.5, 0.4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 48,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
end

--------------------------------------------------
-- UI updates
--------------------------------------------------

function WormUIController:_updateSegmentCounter(segments: number)
	if self._segmentLabel then
		self._segmentLabel.Text = "Segments: " .. math.floor(segments)
	end
end

function WormUIController:_showDeathScreen(deathInfo: { KillerName: string?, MaxSegments: number, Kills: number })
	if not self._deathFrame or not self._deathLabel then
		return
	end

	if deathInfo.KillerName then
		self._deathLabel.Text = "Killed by " .. deathInfo.KillerName
	else
		self._deathLabel.Text = "Hit the wall!"
	end

	if self._statsLabel then
		self._statsLabel.Text = "Max Size: " .. deathInfo.MaxSegments .. "  |  Kills: " .. deathInfo.Kills
	end

	self._deathFrame.Visible = true
end

function WormUIController:_hideDeathScreen()
	if self._deathFrame then
		self._deathFrame.Visible = false
	end
end

function WormUIController:_showFinalScoreboard(results: { any })
	-- Hide death screen first
	self:_hideDeathScreen()

	if not self._finalScoreboardFrame or not self._scoreboardList or not self._scoreboardWinner then
		return
	end

	-- Set winner
	if #results > 0 then
		self._scoreboardWinner.Text = results[1].Name .. " wins!"
	else
		self._scoreboardWinner.Text = ""
	end

	-- Clear old entries
	for _, child in self._scoreboardList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Populate list
	for i, entry in results do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 28)
		row.LayoutOrder = i
		row.BorderSizePixel = 0
		row.BackgroundTransparency = if i % 2 == 0 then 0.7 else 0.8
		row.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		row.Parent = self._scoreboardList

		local isLocalPlayer = entry.Name == LocalPlayer.Name
		local nameColor = if isLocalPlayer
			then Color3.fromRGB(100, 255, 100)
			elseif i == 1 then Color3.fromRGB(255, 220, 50)
			else Color3.new(1, 1, 1)

		createTextLabel({
			Name = "Place",
			Text = "#" .. entry.Placement,
			Size = UDim2.new(0, 40, 1, 0),
			Position = UDim2.fromOffset(5, 0),
			TextSize = 14,
			TextColor3 = nameColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		createTextLabel({
			Name = "Name",
			Text = entry.Name,
			Size = UDim2.new(0, 200, 1, 0),
			Position = UDim2.fromOffset(50, 0),
			TextSize = 14,
			TextColor3 = nameColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		createTextLabel({
			Name = "Kills",
			Text = tostring(entry.Kills),
			Size = UDim2.new(0, 80, 1, 0),
			Position = UDim2.fromOffset(270, 0),
			TextSize = 14,
			Parent = row,
		})
		createTextLabel({
			Name = "MaxSize",
			Text = tostring(entry.MaxSegments),
			Size = UDim2.new(0, 80, 1, 0),
			Position = UDim2.fromOffset(360, 0),
			TextSize = 14,
			Parent = row,
		})

		local coinsText = if entry.CoinsAwarded and entry.CoinsAwarded > 0
			then "+" .. tostring(entry.CoinsAwarded)
			else ""
		createTextLabel({
			Name = "Coins",
			Text = coinsText,
			Size = UDim2.new(0, 70, 1, 0),
			Position = UDim2.fromOffset(450, 0),
			TextSize = 14,
			TextColor3 = Color3.fromRGB(255, 220, 50),
			Parent = row,
		})
	end

	-- Update canvas size
	self._scoreboardList.CanvasSize = UDim2.new(0, 0, 0, #results * 30)

	self._finalScoreboardFrame.Visible = true
end

function WormUIController:_hideFinalScoreboard()
	if self._finalScoreboardFrame then
		self._finalScoreboardFrame.Visible = false
	end
end

function WormUIController:_showCountdown(seconds: number)
	if not self._countdownFrame or not self._countdownLabel then
		return
	end
	self._countdownLabel.Text = "Next round in: " .. seconds
	self._countdownFrame.Visible = true
end

function WormUIController:_hideCountdown()
	if self._countdownFrame then
		self._countdownFrame.Visible = false
	end
end

function WormUIController:_addKillFeedEntry(deadName: string, killerName: string?)
	local killFeed = self._killFeedFrame
	if not killFeed then
		return
	end

	local text = if killerName then deadName .. " ran into " .. killerName else deadName .. " hit the wall"

	local entry = createTextLabel({
		Name = "Entry",
		Text = text,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.5,
		Parent = killFeed,
	})

	local entryCorner = Instance.new("UICorner")
	entryCorner.CornerRadius = UDim.new(0, 4)
	entryCorner.Parent = entry

	-- Remove after delay
	task.delay(KILL_FEED_DURATION, function()
		if entry.Parent then
			entry:Destroy()
		end
	end)

	-- Trim excess entries
	local children = killFeed:GetChildren()
	local entries = {}
	for _, child in children do
		if child:IsA("TextLabel") then
			table.insert(entries, child)
		end
	end
	while #entries > MAX_KILL_FEED do
		entries[1]:Destroy()
		table.remove(entries, 1)
	end
end

function WormUIController:_updateMinimapArrow()
	local arrow = self._minimapArrow
	if not arrow then
		return
	end

	local character = LocalPlayer.Character
	if not character then
		arrow.Visible = false
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		arrow.Visible = false
		return
	end

	arrow.Visible = true
	local halfArena = WormConfig.ArenaSize / 2
	local pos = hrp.Position
	local nx = (pos.X + halfArena) / WormConfig.ArenaSize
	local nz = (pos.Z + halfArena) / WormConfig.ArenaSize
	arrow.Position = UDim2.fromScale(math.clamp(nx, 0, 1), math.clamp(nz, 0, 1))

	-- In worm mode, use WormController's tracked direction (server CFrame may not
	-- replicate rotation reliably due to network ownership). In ghost mode, HRP
	-- LookVector is correct since the standard Humanoid handles rotation.
	local dir
	local WormController = Knit.GetController("WormController")
	if WormController and WormController._alive and WormController._direction then
		dir = WormController._direction
	else
		dir = hrp.CFrame.LookVector
	end
	arrow.Rotation = math.deg(math.atan2(dir.X, -dir.Z))
end

function WormUIController:_updateMinimap()
	local minimap = self._minimapFrame
	if not minimap then
		return
	end

	-- Clear old dots and arrows (keep ShrinkCircle and UICorner/UIStroke)
	for _, child in minimap:GetChildren() do
		if child.Name == "Dot" and (child:IsA("Frame") or child:IsA("TextLabel")) then
			child:Destroy()
		end
	end

	local halfArena = WormConfig.ArenaSize / 2

	-- Player dots (other players only; local player arrow is updated per-frame)
	for _, player in Players:GetPlayers() do
		if player == LocalPlayer then
			continue
		end

		local character = player.Character
		if not character then
			continue
		end

		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		local pos = hrp.Position
		local nx = (pos.X + halfArena) / WormConfig.ArenaSize
		local nz = (pos.Z + halfArena) / WormConfig.ArenaSize

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.Size = UDim2.new(0, 6, 0, 6)
		dot.Position = UDim2.fromScale(math.clamp(nx, 0, 1), math.clamp(nz, 0, 1))
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BorderSizePixel = 0
		dot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		dot.Parent = minimap

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot
	end

	-- Power-up dots on minimap
	local powerUpsFolder = workspace:FindFirstChild("PowerUps") :: Folder?
	if powerUpsFolder then
		for _, powerUp in powerUpsFolder:GetChildren() do
			if powerUp:IsA("BasePart") then
				local pos = powerUp.Position
				local nx = (pos.X + halfArena) / WormConfig.ArenaSize
				local nz = (pos.Z + halfArena) / WormConfig.ArenaSize

				local dot = Instance.new("Frame")
				dot.Name = "Dot"
				dot.Size = UDim2.new(0, 5, 0, 5)
				dot.Position = UDim2.fromScale(math.clamp(nx, 0, 1), math.clamp(nz, 0, 1))
				dot.AnchorPoint = Vector2.new(0.5, 0.5)
				dot.BorderSizePixel = 0
				dot.BackgroundColor3 = Color3.fromRGB(255, 255, 0)
				dot.Parent = minimap

				local dotCorner = Instance.new("UICorner")
				dotCorner.CornerRadius = UDim.new(1, 0)
				dotCorner.Parent = dot
			end
		end
	end

	-- Update shrink zone circle
	if self._shrinkCircle then
		local radiusFraction = self._currentZoneRadius / halfArena
		self._shrinkCircle.Size = UDim2.fromScale(math.clamp(radiusFraction, 0, 1), math.clamp(radiusFraction, 0, 1))
	end
end

function WormUIController:_showPowerUp(powerUpType: string, duration: number)
	if not self._powerUpFrame or not self._powerUpLabel then
		return
	end

	local displayName = string.gsub(powerUpType, "_", " ")
	local color = POWERUP_COLORS[powerUpType] or Color3.new(1, 1, 1)

	self._powerUpLabel.Text = displayName
	self._powerUpLabel.TextColor3 = color
	self._powerUpFrame.Visible = true

	if duration > 0 then
		self._activePowerUpEnd = os.clock() + duration
	else
		-- Instant effect, flash briefly
		self._activePowerUpEnd = os.clock() + 1
	end
end

function WormUIController:_hidePowerUp()
	if self._powerUpFrame then
		self._powerUpFrame.Visible = false
	end
	self._activePowerUpEnd = 0
end

function WormUIController:_updatePowerUpTimer()
	if self._activePowerUpEnd <= 0 then
		return
	end

	local remaining = self._activePowerUpEnd - os.clock()
	if remaining <= 0 then
		self:_hidePowerUp()
		return
	end

	if self._powerUpTimer then
		self._powerUpTimer.Text = string.format("%.1fs", remaining)
	end
end

function WormUIController:_updateGameTimer(elapsed: number)
	if not self._gameTimerLabel then
		return
	end
	local mins = math.floor(elapsed / 60)
	local secs = math.floor(elapsed % 60)
	self._gameTimerLabel.Text = string.format("%d:%02d", mins, secs)
end

function WormUIController:_showZoneWarning(message: string)
	if not self._zoneWarningLabel then
		return
	end
	self._zoneWarningLabel.Text = message

	-- Auto-hide after 3 seconds
	task.delay(3, function()
		if self._zoneWarningLabel and self._zoneWarningLabel.Text == message then
			self._zoneWarningLabel.Text = ""
		end
	end)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormUIController:KnitInit()
	self._trove = Trove.new()
end

function WormUIController:KnitStart()
	self._wormService = Knit.GetService("WormService")
	self._wormController = Knit.GetController("WormController")
	self._weaponController = Knit.GetController("WeaponController")
	self._powerUpService = Knit.GetService("PowerUpService")
	self._coinService = Knit.GetService("CoinService")

	self:_buildUI()

	-- Wire to WormController signals
	self._trove:Add(self._wormController.SegmentsChanged:Connect(function(segments: number)
		self:_updateSegmentCounter(segments)
	end))

	self._trove:Add(
		self._wormController.WormDied:Connect(
			function(deathInfo: { KillerName: string?, MaxSegments: number, Kills: number })
				self:_showDeathScreen(deathInfo)
			end
		)
	)

	self._trove:Add(self._wormController.WormSpawned:Connect(function(_data: any)
		self:_hideDeathScreen()
		self:_hideFinalScoreboard()
		self:_hideCountdown()
		self:_updateSegmentCounter(WormConfig.InitialSegments)
		-- Clear rider notification on respawn
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = ""
		end
	end))

	-- Power-up signals from WormController
	self._trove:Add(self._wormController.PowerUpActivated:Connect(function(powerUpType: string, duration: number)
		self:_showPowerUp(powerUpType, duration)
	end))

	self._trove:Add(self._wormController.PowerUpExpired:Connect(function()
		self:_hidePowerUp()
	end))

	-- Zone signals from WormController
	self._trove:Add(self._wormController.ZoneUpdate:Connect(function(radius: number, elapsed: number)
		self._currentZoneRadius = radius
		self:_updateGameTimer(elapsed)
	end))

	self._trove:Add(self._wormController.ZoneWarning:Connect(function(message: string)
		self:_showZoneWarning(message)
	end))

	-- Wire kill feed to server signal (skip local player's own death — death screen covers it)
	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		if deadName == LocalPlayer.Name then
			return
		end
		self:_addKillFeedEntry(deadName, killerName)
	end))

	-- Connect food signal (suppress Knit warning)
	self._trove:Add(self._wormService.FoodSpawned:Connect(function(_position: Vector3, _color: Color3) end))

	-- Suppress PlayerKillsUpdated Knit warning (handled by WormController)
	self._trove:Add(self._wormService.PlayerKillsUpdated:Connect(function() end))

	-- Wire spectate buttons
	if self._spectateButtonPrev then
		self._spectateButtonPrev.Activated:Connect(function()
			if self._wormController then
				self._wormController:CycleSpectate(-1)
			end
		end)
	end
	if self._spectateButtonNext then
		self._spectateButtonNext.Activated:Connect(function()
			if self._wormController then
				self._wormController:CycleSpectate(1)
			end
		end)
	end

	-- Wire ghost toggle button
	if self._ghostToggleBtn then
		self._ghostToggleBtn.Activated:Connect(function()
			if self._wormController then
				self._wormController:ToggleGhostMode()
			end
		end)
	end

	-- Ghost mode changed signal — toggle death screen visibility, button text, crosshair, and mouse cursor
	self._trove:Add(self._wormController.GhostModeChanged:Connect(function(inGhost: boolean)
		if inGhost then
			-- Hide death overlay while in ghost mode (player is in first person)
			if self._deathFrame then
				self._deathFrame.Visible = false
			end
		else
			-- Show death screen again when exiting ghost mode
			if self._deathFrame then
				self._deathFrame.Visible = true
			end
		end
		if self._ghostToggleBtn then
			self._ghostToggleBtn.Text = if inGhost then "Exit Ghost Mode" else "Enter Ghost Mode"
		end
		if self._crosshairFrame then
			self._crosshairFrame.Visible = inGhost
		end
		if self._toolbarFrame then
			self._toolbarFrame.Visible = inGhost
		end
		-- Hide mouse cursor when crosshair is active, restore when it's gone
		UserInputService.MouseIconEnabled = not inGhost
		-- Reset weapon slot when leaving ghost mode
		if not inGhost then
			if self._weaponSlotLabel then
				self._weaponSlotLabel.Text = "---"
			end
			if self._weaponSlotAmmo then
				self._weaponSlotAmmo.Text = ""
			end
			if self._grappleHint then
				self._grappleHint.Text = "LMB to hook"
			end
			-- Reset slot highlight
			if self._grappleSlotStroke then
				self._grappleSlotStroke.Transparency = 0
			end
			if self._weaponSlotStroke then
				self._weaponSlotStroke.Transparency = 1
			end
		end
	end))

	-- Wire weapon toolbar signals
	self._trove:Add(self._weaponController.WeaponAssigned:Connect(function(weaponType: string, ammo: number)
		if self._weaponSlotLabel then
			self._weaponSlotLabel.Text = if weaponType then string.upper(weaponType) else ""
		end
		self._maxAmmo = ammo
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = tostring(ammo) .. "/" .. tostring(ammo)
		end
		-- Update grapple hint: with weapon, grapple is only available when not riding
		if self._grappleHint then
			self._grappleHint.Text = "LMB to hook"
		end
	end))

	self._trove:Add(self._weaponController.AmmoChanged:Connect(function(ammo: number)
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = tostring(ammo) .. "/" .. tostring(self._maxAmmo)
		end
	end))

	self._trove:Add(self._weaponController.WeaponCleared:Connect(function()
		if self._weaponSlotLabel then
			self._weaponSlotLabel.Text = "---"
		end
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = ""
		end
		self._maxAmmo = 0
	end))

	-- Wire slot selection highlight
	self._trove:Add(self._wormController.SelectedSlotChanged:Connect(function(slot: number)
		if self._grappleSlotStroke then
			self._grappleSlotStroke.Transparency = if slot == 1 then 0 else 1
		end
		if self._weaponSlotStroke then
			self._weaponSlotStroke.Transparency = if slot == 2 then 0 else 1
		end
		-- Update hint text
		if self._grappleHint then
			self._grappleHint.Text = if slot == 1 then "LMB to hook" else "Press [1]"
		end
	end))

	-- Wire rider notification (shown to alive worm player when a ghost mounts/dismounts)
	self._trove:Add(self._wormService.RiderAttached:Connect(function(_riderName: string)
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = "Ghost riding! +15% speed"
		end
	end))

	self._trove:Add(self._wormService.RiderDetached:Connect(function(_riderName: string)
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = ""
		end
	end))

	-- Wire SpectateChanged to update label
	self._trove:Add(self._wormController.SpectateChanged:Connect(function(name: string)
		if self._spectateLabel then
			self._spectateLabel.Text = name
		end
	end))

	-- Round signals from WormController
	self._trove:Add(self._wormController.RoundEnded:Connect(function(results: any)
		self:_showFinalScoreboard(results)
	end))

	self._trove:Add(self._wormController.RoundCountdown:Connect(function(seconds: number)
		self:_hideFinalScoreboard()
		self:_hideDeathScreen()
		self:_showCountdown(seconds)
	end))

	self._trove:Add(self._wormController.RoundStarted:Connect(function()
		self:_hideDeathScreen()
		self:_hideFinalScoreboard()
		self:_hideCountdown()
	end))

	-- Coin display: initial value + change signal
	task.spawn(function()
		local ok, coins = self._coinService:GetCoins():await()
		if ok and self._coinLabel then
			self._coinLabel.Text = tostring(coins)
		end
	end)

	self._trove:Add(self._coinService.CoinsChanged:Connect(function(newCoins: number)
		if self._coinLabel then
			self._coinLabel.Text = tostring(newCoins)
		end
	end))

	-- Daily reward notification
	self._trove:Add(self._coinService.DailyReward:Connect(function(coins: number, streak: number, isBonus: boolean)
		local msg = "Daily reward: +" .. coins .. " coins!"
		if isBonus then
			msg = msg .. " 7-day streak bonus: +200 coins!"
		elseif streak > 1 then
			msg = msg .. " (Day " .. streak .. " streak)"
		end
		self:_showZoneWarning(msg)
	end))

	-- Per-frame minimap arrow rotation
	self._trove:Connect(RunService.RenderStepped, function()
		self:_updateMinimapArrow()
	end)

	-- Periodic minimap dots + power-up timer updates
	self._trove:Add(task.spawn(function()
		while true do
			self:_updateMinimap()
			self:_updatePowerUpTimer()
			task.wait(PERIODIC_UPDATE_INTERVAL)
		end
	end))
end

return WormUIController
