--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local LEADERBOARD_UPDATE_INTERVAL = 2
local KILL_FEED_DURATION = 4
local MAX_KILL_FEED = 5

local POWERUP_COLORS = {
	SPEED = Color3.fromRGB(0, 200, 255),
	MAGNET = Color3.fromRGB(255, 0, 200),
	GHOST = Color3.fromRGB(200, 200, 255),
	SHIELD = Color3.fromRGB(255, 220, 0),
	SIZE_BOMB = Color3.fromRGB(255, 80, 0),
}

local WormUIController = Knit.CreateController({
	Name = "WormUIController",

	_trove = nil :: any,
	_screenGui = nil :: ScreenGui?,
	_segmentLabel = nil :: TextLabel?,
	_deathFrame = nil :: Frame?,
	_deathLabel = nil :: TextLabel?,
	_killFeedFrame = nil :: Frame?,
	_leaderboardFrame = nil :: Frame?,
	_minimapFrame = nil :: Frame?,
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
	self:_buildLeaderboard(gui)
	self:_buildMinimap(gui)
	self:_buildBoostButton(gui)
	self:_buildPowerUpDisplay(gui)
	self:_buildGameTimer(gui)
	self:_buildZoneWarning(gui)
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
		Position = UDim2.fromScale(0.5, 0.35),
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
		Position = UDim2.fromScale(0.5, 0.45),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 22,
		Parent = frame,
	})

	createTextLabel({
		Name = "Respawn",
		Text = "Respawning in " .. WormConfig.RespawnDelay .. "s...",
		Size = UDim2.new(0, 300, 0, 30),
		Position = UDim2.fromScale(0.5, 0.55),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})
end

function WormUIController:_buildKillFeed(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "KillFeed"
	frame.Size = UDim2.new(0, 300, 0, MAX_KILL_FEED * 28)
	frame.Position = UDim2.new(1, -10, 0, 60)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = parent
	self._killFeedFrame = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame
end

function WormUIController:_buildLeaderboard(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Leaderboard"
	frame.Size = UDim2.new(0, 220, 0, 230)
	frame.Position = UDim2.new(0, 10, 0, 60)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = parent
	self._leaderboardFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	createTextLabel({
		Name = "Title",
		Text = "Leaderboard",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromScale(0, 0),
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		BackgroundTransparency = 0.7,
		BackgroundColor3 = Color3.fromRGB(40, 40, 40),
		Parent = frame,
	})

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.new(1, 0, 1, -28)
	list.Position = UDim2.new(0, 0, 0, 28)
	list.BackgroundTransparency = 1
	list.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 1)
	layout.Parent = list
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

--------------------------------------------------
-- UI updates
--------------------------------------------------

function WormUIController:_updateSegmentCounter(segments: number)
	if self._segmentLabel then
		self._segmentLabel.Text = "Segments: " .. math.floor(segments)
	end
end

function WormUIController:_showDeathScreen(killerName: string?)
	if not self._deathFrame or not self._deathLabel then
		return
	end

	if killerName then
		self._deathLabel.Text = "Killed by " .. killerName
	else
		self._deathLabel.Text = "Hit the wall!"
	end

	self._deathFrame.Visible = true
end

function WormUIController:_hideDeathScreen()
	if self._deathFrame then
		self._deathFrame.Visible = false
	end
end

function WormUIController:_addKillFeedEntry(deadName: string, killerName: string?)
	local killFeed = self._killFeedFrame
	if not killFeed then
		return
	end

	local text = if killerName then killerName .. " ate " .. deadName else deadName .. " hit the wall"

	local entry = createTextLabel({
		Name = "Entry",
		Text = text,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
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

function WormUIController:_updateLeaderboard()
	if not self._wormService or not self._leaderboardFrame then
		return
	end

	local ok, board = pcall(function()
		return self._wormService:GetLeaderboard()
	end)
	if not ok or not board then
		return
	end

	local list = self._leaderboardFrame:FindFirstChild("List") :: Frame?
	if not list then
		return
	end

	-- Clear old entries
	for _, child in list:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	-- Add top 10
	for i = 1, math.min(#board, 10) do
		local entry = board[i]
		local segments = tonumber(entry.Segments) or 0

		local isLocal = entry.Name == LocalPlayer.Name
		local color = if isLocal then Color3.fromRGB(255, 255, 100) else Color3.new(1, 1, 1)

		createTextLabel({
			Name = "Entry" .. i,
			Text = i .. ". " .. entry.Name .. " - " .. segments,
			Size = UDim2.new(1, -8, 0, 20),
			Position = UDim2.new(0, 4, 0, 0),
			TextSize = 13,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = list,
		})
	end
end

function WormUIController:_updateMinimap()
	local minimap = self._minimapFrame
	if not minimap then
		return
	end

	-- Clear old dots (keep ShrinkCircle and UICorner/UIStroke)
	for _, child in minimap:GetChildren() do
		if child:IsA("Frame") and child.Name == "Dot" then
			child:Destroy()
		end
	end

	local halfArena = WormConfig.ArenaSize / 2

	-- Player dots
	for _, player in Players:GetPlayers() do
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
		dot.Parent = minimap

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		if player == LocalPlayer then
			dot.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
			dot.Size = UDim2.new(0, 8, 0, 8)
		else
			dot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		end
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
	self._powerUpService = Knit.GetService("PowerUpService")

	self:_buildUI()

	-- Wire to WormController signals
	self._trove:Add(self._wormController.SegmentsChanged:Connect(function(segments: number)
		self:_updateSegmentCounter(segments)
	end))

	self._trove:Add(self._wormController.WormDied:Connect(function(killerName: string?)
		self:_showDeathScreen(killerName)
	end))

	self._trove:Add(self._wormController.WormSpawned:Connect(function(_data: any)
		self:_hideDeathScreen()
		self:_updateSegmentCounter(WormConfig.InitialSegments)
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

	-- Wire kill feed to server signal
	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		self:_addKillFeedEntry(deadName, killerName)
	end))

	-- Connect food signal (suppress Knit warning)
	self._trove:Add(self._wormService.FoodSpawned:Connect(function(_position: Vector3, _color: Color3) end))

	-- Periodic leaderboard + minimap + power-up timer updates
	self._trove:Add(task.spawn(function()
		while true do
			self:_updateLeaderboard()
			self:_updateMinimap()
			self:_updatePowerUpTimer()
			task.wait(LEADERBOARD_UPDATE_INTERVAL)
		end
	end))
end

return WormUIController
