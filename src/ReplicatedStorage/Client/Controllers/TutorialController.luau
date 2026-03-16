--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local STEP_AUTO_ADVANCE = 5
local FADE_TIME = 0.3
local TIP_DISPLAY_TIME = 5
local CONTROLS_OVERLAY_ZINDEX = 20
local TUTORIAL_OVERLAY_ZINDEX = 15

--------------------------------------------------
-- Tutorial step definitions
--------------------------------------------------

local TUTORIAL_STEPS = {
	{
		Title = "Welcome to Worms!",
		Body = "Eat food to grow. Be the last worm standing!",
	},
	{
		Title = "Steering",
		Body = nil, -- set dynamically based on platform
	},
	{
		Title = "Eat to Grow",
		Body = "Eat the glowing orbs scattered around the arena to grow longer.",
	},
	{
		Title = "Boost",
		Body = nil, -- set dynamically based on platform
	},
	{
		Title = "Collision",
		Body = "If your head hits another worm's body, you die!\nBut if THEY hit YOU, they die.",
	},
	{
		Title = "Power-Ups",
		Body = "Collect power-ups for special abilities:\nSpeed, Magnet, Ghost, Shield, and more!",
	},
	{
		Title = "Ghost Mode",
		Body = "When you die, you become a ghost!\nGrapple onto living worms or pick up weapons.",
	},
	{
		Title = "The Zone",
		Body = "The safe zone shrinks over time.\nStay inside or take damage!",
	},
}

local TutorialController = Knit.CreateController({
	Name = "TutorialController",

	_trove = nil :: any,
	_tutorialService = nil :: any,
	_wormController = nil :: any,
	_weaponController = nil :: any,

	-- Tutorial state
	_tutorialGui = nil :: ScreenGui?,
	_overlayFrame = nil :: Frame?,
	_titleLabel = nil :: TextLabel?,
	_bodyLabel = nil :: TextLabel?,
	_nextButton = nil :: TextButton?,
	_skipButton = nil :: TextButton?,
	_dotsFrame = nil :: Frame?,
	_currentStep = 0,
	_tutorialActive = false,
	_autoAdvanceThread = nil :: thread?,

	-- Contextual tips (shown once per session)
	_tipsGui = nil :: ScreenGui?,
	_tipLabel = nil :: TextLabel?,
	_shownTips = {} :: { [string]: boolean },
	_tipThread = nil :: thread?,

	-- Controls overlay
	_controlsGui = nil :: ScreenGui?,
	_controlsFrame = nil :: Frame?,
	_controlsVisible = false,

	_isTouchDevice = false,
})

--------------------------------------------------
-- UI helpers
--------------------------------------------------

local function addStroke(label: TextLabel)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label
end

local function fadeIn(guiObject: GuiObject, duration: number?)
	guiObject.Visible = true
	guiObject.BackgroundTransparency = 1
	local tween = TweenService:Create(guiObject, TweenInfo.new(duration or FADE_TIME), {
		BackgroundTransparency = 0.6,
	})
	tween:Play()
end

local function fadeOut(guiObject: GuiObject, duration: number?, callback: (() -> ())?)
	local tween = TweenService:Create(guiObject, TweenInfo.new(duration or FADE_TIME), {
		BackgroundTransparency = 1,
	})
	tween:Play()
	tween.Completed:Once(function()
		guiObject.Visible = false
		if callback then
			callback()
		end
	end)
end

--------------------------------------------------
-- Tutorial UI
--------------------------------------------------

function TutorialController:_buildTutorialUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TutorialUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = TUTORIAL_OVERLAY_ZINDEX
	gui.Enabled = false
	gui.Parent = PlayerGui
	self._tutorialGui = gui

	-- Semi-transparent overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.6
	overlay.BorderSizePixel = 0
	overlay.Parent = gui
	self._overlayFrame = overlay

	-- Content container (centered card)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.new(0, 500, 0, 260)
	card.Position = UDim2.fromScale(0.5, 0.45)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	card.BackgroundTransparency = 0.15
	card.BorderSizePixel = 0
	card.Parent = overlay

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 12)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(80, 120, 200)
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.4
	cardStroke.Parent = card

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -40, 0, 40)
	title.Position = UDim2.new(0, 20, 0, 20)
	title.BackgroundTransparency = 1
	title.Text = ""
	title.TextSize = 30
	title.TextColor3 = Color3.fromRGB(100, 180, 255)
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Parent = card
	addStroke(title)
	self._titleLabel = title

	-- Body
	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.Size = UDim2.new(1, -40, 0, 100)
	body.Position = UDim2.new(0, 20, 0, 70)
	body.BackgroundTransparency = 1
	body.Text = ""
	body.TextSize = 20
	body.TextColor3 = Color3.new(1, 1, 1)
	body.Font = Enum.Font.Gotham
	body.TextWrapped = true
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextXAlignment = Enum.TextXAlignment.Center
	body.Parent = card
	addStroke(body)
	self._bodyLabel = body

	-- Next button
	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "NextBtn"
	nextBtn.Size = UDim2.new(0, 120, 0, 40)
	nextBtn.Position = UDim2.new(1, -20, 1, -20)
	nextBtn.AnchorPoint = Vector2.new(1, 1)
	nextBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 230)
	nextBtn.BorderSizePixel = 0
	nextBtn.Text = "Next"
	nextBtn.TextSize = 18
	nextBtn.TextColor3 = Color3.new(1, 1, 1)
	nextBtn.Font = Enum.Font.GothamBold
	nextBtn.Parent = card
	self._nextButton = nextBtn

	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UDim.new(0, 8)
	nextCorner.Parent = nextBtn

	nextBtn.Activated:Connect(function()
		self:_advanceStep()
	end)

	-- Skip button
	local skipBtn = Instance.new("TextButton")
	skipBtn.Name = "SkipBtn"
	skipBtn.Size = UDim2.new(0, 80, 0, 30)
	skipBtn.Position = UDim2.new(0, 20, 1, -25)
	skipBtn.AnchorPoint = Vector2.new(0, 1)
	skipBtn.BackgroundTransparency = 1
	skipBtn.Text = "Skip"
	skipBtn.TextSize = 16
	skipBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
	skipBtn.Font = Enum.Font.Gotham
	skipBtn.Parent = card
	self._skipButton = skipBtn

	skipBtn.Activated:Connect(function()
		self:_endTutorial()
	end)

	-- Progress dots
	local dotsFrame = Instance.new("Frame")
	dotsFrame.Name = "Dots"
	dotsFrame.Size = UDim2.new(0, #TUTORIAL_STEPS * 18, 0, 12)
	dotsFrame.Position = UDim2.new(0.5, 0, 1, 10)
	dotsFrame.AnchorPoint = Vector2.new(0.5, 0)
	dotsFrame.BackgroundTransparency = 1
	dotsFrame.Parent = card

	local dotsLayout = Instance.new("UIListLayout")
	dotsLayout.FillDirection = Enum.FillDirection.Horizontal
	dotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	dotsLayout.Padding = UDim.new(0, 6)
	dotsLayout.Parent = dotsFrame

	for i = 1, #TUTORIAL_STEPS do
		local dot = Instance.new("Frame")
		dot.Name = "Dot" .. i
		dot.Size = UDim2.new(0, 10, 0, 10)
		dot.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
		dot.BorderSizePixel = 0
		dot.Parent = dotsFrame

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot
	end
	self._dotsFrame = dotsFrame
end

--------------------------------------------------
-- Tutorial flow
--------------------------------------------------

function TutorialController:_startTutorial()
	if self._tutorialActive then
		return
	end
	self._tutorialActive = true
	self._currentStep = 0

	if self._tutorialGui then
		self._tutorialGui.Enabled = true
	end
	if self._overlayFrame then
		fadeIn(self._overlayFrame)
	end

	self:_advanceStep()
end

function TutorialController:_advanceStep()
	-- Cancel auto-advance timer
	if self._autoAdvanceThread then
		task.cancel(self._autoAdvanceThread)
		self._autoAdvanceThread = nil
	end

	self._currentStep += 1
	if self._currentStep > #TUTORIAL_STEPS then
		self:_endTutorial()
		return
	end

	local step = TUTORIAL_STEPS[self._currentStep]
	local title = step.Title
	local body = step.Body

	-- Dynamic text for platform-specific steps
	if self._currentStep == 2 then
		if self._isTouchDevice then
			body = "Drag anywhere on screen to steer your worm."
		else
			body = "Move your mouse to steer your worm.\nYour worm follows your cursor."
		end
	elseif self._currentStep == 4 then
		if self._isTouchDevice then
			body = "Tap the BOOST button to speed up!\nBoosting costs segments, so use it wisely."
		else
			body = "Hold LEFT CLICK or SHIFT to boost!\nBoosting costs segments, so use it wisely."
		end
	end

	if self._titleLabel then
		self._titleLabel.Text = title
	end
	if self._bodyLabel then
		self._bodyLabel.Text = body
	end

	-- Update Next button text on last step
	if self._nextButton then
		self._nextButton.Text = if self._currentStep == #TUTORIAL_STEPS then "Got it!" else "Next"
	end

	-- Update progress dots
	self:_updateDots()

	-- Auto-advance timer
	self._autoAdvanceThread = task.delay(STEP_AUTO_ADVANCE, function()
		self._autoAdvanceThread = nil
		if self._tutorialActive then
			self:_advanceStep()
		end
	end)
end

function TutorialController:_updateDots()
	if not self._dotsFrame then
		return
	end
	for i = 1, #TUTORIAL_STEPS do
		local dot = self._dotsFrame:FindFirstChild("Dot" .. i) :: Frame?
		if dot then
			dot.BackgroundColor3 = if i == self._currentStep
				then Color3.fromRGB(100, 180, 255)
				elseif i < self._currentStep then Color3.fromRGB(150, 150, 150)
				else Color3.fromRGB(60, 60, 60)
		end
	end
end

function TutorialController:_endTutorial()
	if not self._tutorialActive then
		return
	end
	self._tutorialActive = false

	if self._autoAdvanceThread then
		task.cancel(self._autoAdvanceThread)
		self._autoAdvanceThread = nil
	end

	if self._overlayFrame then
		fadeOut(self._overlayFrame, FADE_TIME, function()
			if self._tutorialGui then
				self._tutorialGui.Enabled = false
			end
		end)
	end

	-- Mark as completed on server
	task.spawn(function()
		pcall(function()
			self._tutorialService:CompleteTutorial()
		end)
	end)
end

function TutorialController:ReplayTutorial()
	self:_startTutorial()
end

--------------------------------------------------
-- Contextual tips
--------------------------------------------------

function TutorialController:_buildTipsUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TipsUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = TUTORIAL_OVERLAY_ZINDEX - 1
	gui.Parent = PlayerGui
	self._tipsGui = gui

	local label = Instance.new("TextLabel")
	label.Name = "Tip"
	label.Size = UDim2.new(0, 500, 0, 50)
	label.Position = UDim2.new(0.5, 0, 0.85, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundColor3 = Color3.fromRGB(10, 10, 20)
	label.BackgroundTransparency = 0.35
	label.BorderSizePixel = 0
	label.Text = ""
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(255, 255, 200)
	label.Font = Enum.Font.GothamBold
	label.TextWrapped = true
	label.Visible = false
	label.Parent = gui

	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 8)
	tipCorner.Parent = label

	addStroke(label)

	self._tipLabel = label

	-- Dismiss on click
	local clickButton = Instance.new("TextButton")
	clickButton.Name = "Dismiss"
	clickButton.Size = UDim2.fromScale(1, 1)
	clickButton.BackgroundTransparency = 1
	clickButton.Text = ""
	clickButton.Parent = label
	clickButton.Activated:Connect(function()
		self:_hideTip()
	end)
end

function TutorialController:_showTip(key: string, text: string)
	if self._shownTips[key] then
		return
	end
	if self._tutorialActive then
		return
	end
	self._shownTips[key] = true

	if self._tipThread then
		task.cancel(self._tipThread)
		self._tipThread = nil
	end

	if self._tipLabel then
		self._tipLabel.Text = text
		self._tipLabel.Visible = true
	end

	self._tipThread = task.delay(TIP_DISPLAY_TIME, function()
		self._tipThread = nil
		self:_hideTip()
	end)
end

function TutorialController:_hideTip()
	if self._tipThread then
		task.cancel(self._tipThread)
		self._tipThread = nil
	end
	if self._tipLabel then
		self._tipLabel.Visible = false
	end
end

--------------------------------------------------
-- Controls overlay
--------------------------------------------------

function TutorialController:_buildControlsUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ControlsUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = CONTROLS_OVERLAY_ZINDEX
	gui.Parent = PlayerGui
	self._controlsGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "ControlsFrame"
	frame.Size = UDim2.new(0, 400, 0, 340)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui
	self._controlsFrame = frame

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 12)
	frameCorner.Parent = frame

	local frameStroke = Instance.new("UIStroke")
	frameStroke.Color = Color3.fromRGB(80, 120, 200)
	frameStroke.Thickness = 2
	frameStroke.Transparency = 0.4
	frameStroke.Parent = frame

	-- Title
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -20, 0, 36)
	titleLabel.Position = UDim2.new(0, 10, 0, 10)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "Controls"
	titleLabel.TextSize = 26
	titleLabel.TextColor3 = Color3.fromRGB(100, 180, 255)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.Parent = frame

	-- Controls list
	local controls
	if self._isTouchDevice then
		controls = {
			{ "Drag Screen", "Steer worm" },
			{ "Boost Button", "Speed boost (costs segments)" },
			{ "Tap (Ghost)", "Grapple / Fire weapon" },
			{ "Slot 1 / Slot 2", "Switch ghost tools" },
		}
	else
		controls = {
			{ "Mouse", "Steer worm" },
			{ "Left Click / Shift", "Boost (costs segments)" },
			{ "Left Click (Ghost)", "Grapple onto worm" },
			{ "Right Click (Ghost)", "Fire weapon" },
			{ "1 / 2", "Switch ghost tools" },
			{ "Space (Ghost)", "Detach from worm" },
			{ "Tab / ?", "Toggle this overlay" },
			{ "M", "Mute" },
		}
	end

	local yOffset = 56
	for _, entry in controls do
		local keyLabel = Instance.new("TextLabel")
		keyLabel.Size = UDim2.new(0, 170, 0, 28)
		keyLabel.Position = UDim2.new(0, 20, 0, yOffset)
		keyLabel.BackgroundTransparency = 1
		keyLabel.Text = entry[1]
		keyLabel.TextSize = 16
		keyLabel.TextColor3 = Color3.fromRGB(200, 220, 255)
		keyLabel.Font = Enum.Font.GothamBold
		keyLabel.TextXAlignment = Enum.TextXAlignment.Right
		keyLabel.Parent = frame

		local descLabel = Instance.new("TextLabel")
		descLabel.Size = UDim2.new(0, 180, 0, 28)
		descLabel.Position = UDim2.new(0, 210, 0, yOffset)
		descLabel.BackgroundTransparency = 1
		descLabel.Text = entry[2]
		descLabel.TextSize = 15
		descLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		descLabel.Font = Enum.Font.Gotham
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.Parent = frame

		yOffset += 30
	end

	-- Close hint
	local closeHint = Instance.new("TextLabel")
	closeHint.Size = UDim2.new(1, -20, 0, 24)
	closeHint.Position = UDim2.new(0, 10, 1, -10)
	closeHint.AnchorPoint = Vector2.new(0, 1)
	closeHint.BackgroundTransparency = 1
	closeHint.Text = if self._isTouchDevice then "Tap anywhere to close" else "Press Tab or ? to close"
	closeHint.TextSize = 13
	closeHint.TextColor3 = Color3.fromRGB(120, 120, 120)
	closeHint.Font = Enum.Font.Gotham
	closeHint.TextXAlignment = Enum.TextXAlignment.Center
	closeHint.Parent = frame

	-- Close button for touch
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Size = UDim2.new(0, 30, 0, 30)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "X"
	closeBtn.TextSize = 20
	closeBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Parent = frame
	closeBtn.Activated:Connect(function()
		self:ToggleControls()
	end)
end

function TutorialController:ToggleControls()
	if not self._controlsFrame then
		return
	end
	self._controlsVisible = not self._controlsVisible
	self._controlsFrame.Visible = self._controlsVisible
end

--------------------------------------------------
-- Contextual tip triggers
--------------------------------------------------

function TutorialController:_connectContextualTips()
	-- First death tip
	self._trove:Add(self._wormController.WormDied:Connect(function()
		self:_showTip("first_death", "You're now a ghost! Grapple onto worms or pick up weapons.")
	end))

	-- First power-up
	self._trove:Add(self._wormController.PowerUpActivated:Connect(function(powerUpType: string, duration: number)
		local name = string.gsub(powerUpType, "_", " ")
		name = string.lower(name)
		local text = "Power-up active! " .. name
		if duration > 0 then
			text = text .. " for " .. duration .. "s"
		end
		self:_showTip("first_powerup", text)
	end))

	-- Zone warning
	self._trove:Add(self._wormController.ZoneWarning:Connect(function()
		self:_showTip("zone_edge", "Warning! Stay inside the safe zone or you'll take damage.")
	end))

	-- Ghost mode weapon pickup
	self._trove:Add(self._weaponController.WeaponAssigned:Connect(function(_weaponType: string, ammo: number)
		local tip
		if self._isTouchDevice then
			tip = "Weapon equipped! Select slot 2 and tap to fire. You have " .. ammo .. " shots."
		else
			tip = "Weapon equipped! Press 2 then right-click to fire. You have " .. ammo .. " shots."
		end
		self:_showTip("ghost_weapon", tip)
	end))

	-- First boost tip (show after first spawn, once they have enough segments)
	self._trove:Add(self._wormController.SegmentsChanged:Connect(function(segments: number)
		if segments >= 6 then
			local tip
			if self._isTouchDevice then
				tip = "You're big enough to boost! Tap the BOOST button to speed up (costs segments)."
			else
				tip = "You're big enough to boost! Hold LEFT CLICK to speed up (costs segments)."
			end
			self:_showTip("first_boost", tip)
		end
	end))
end

--------------------------------------------------
-- Input bindings
--------------------------------------------------

function TutorialController:_setupInput()
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end

		if input.KeyCode == Enum.KeyCode.Tab then
			self:ToggleControls()
		elseif input.KeyCode == Enum.KeyCode.Slash then
			-- "?" is Shift+/ but we check for "/" key press (Slash)
			if
				UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			then
				self:ToggleControls()
			end
		end
	end)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function TutorialController:KnitInit()
	self._trove = Trove.new()
	self._isTouchDevice = UserInputService.TouchEnabled
end

function TutorialController:KnitStart()
	self._tutorialService = Knit.GetService("TutorialService")
	self._wormController = Knit.GetController("WormController")
	self._weaponController = Knit.GetController("WeaponController")

	self:_buildTutorialUI()
	self:_buildTipsUI()
	self:_buildControlsUI()
	self:_setupInput()
	self:_connectContextualTips()

	-- Check if first-time player
	task.spawn(function()
		local ok, hasCompleted = pcall(function()
			return self._tutorialService:HasCompletedTutorial():expect()
		end)
		if ok and not hasCompleted then
			-- Small delay so the player sees the game world first
			task.wait(2)
			self:_startTutorial()
		end
	end)
end

return TutorialController
