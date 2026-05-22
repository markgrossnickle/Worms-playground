--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local QuestConfig = require(ReplicatedStorage.Shared.QuestConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local QUEST_KEY = Enum.KeyCode.Q
local TOAST_DURATION = 3
local TOAST_COMPLETE_DURATION = 4
local PROGRESS_BAR_COLOR = Color3.fromRGB(0, 180, 80)
local PROGRESS_BAR_COMPLETE_COLOR = Color3.fromRGB(255, 200, 0)
local PANEL_BG = Color3.fromRGB(20, 20, 30)
local CARD_BG = Color3.fromRGB(35, 35, 50)
local ACCENT_COLOR = Color3.fromRGB(0, 180, 80)

type QuestState = {
	Type: string,
	Target: number,
	Progress: number,
	Completed: boolean,
	Reward: number,
	Description: string,
}

local QuestController = Knit.CreateController({
	Name = "QuestController",

	_trove = nil :: any,
	_questService = nil :: any,
	_screenGui = nil :: ScreenGui?,
	_panelFrame = nil :: Frame?,
	_panelVisible = false,
	_questCards = {} :: { Frame },
	_progressBars = {} :: { Frame },
	_progressLabels = {} :: { TextLabel },
	_statusLabels = {} :: { TextLabel },
	_timerLabel = nil :: TextLabel?,
	_toastFrame = nil :: Frame?,
	_toastLabel = nil :: TextLabel?,
	_hudIndicator = nil :: TextButton?,
	_hudCount = nil :: TextLabel?,
	_quests = {} :: { QuestState },
	_resetTime = 0,
})

--------------------------------------------------
-- UI helpers
--------------------------------------------------

local function createLabel(props: {
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
	TextWrapped: boolean?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.Name
	label.Text = props.Text
	label.Size = props.Size
	label.Position = props.Position
	label.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	label.TextSize = props.TextSize or 16
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1
	label.BackgroundColor3 = props.BackgroundColor3 or Color3.new(0, 0, 0)
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.BorderSizePixel = 0
	label.TextWrapped = props.TextWrapped or false
	label.Parent = props.Parent
	return label
end

--------------------------------------------------
-- Build quest panel
--------------------------------------------------

function QuestController:_buildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuestUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = PlayerGui
	self._screenGui = gui

	self:_buildPanel(gui)
	self:_buildToast(gui)
	self:_buildHudIndicator(gui)
end

function QuestController:_buildPanel(parent: ScreenGui)
	local panel = Instance.new("Frame")
	panel.Name = "QuestPanel"
	panel.Size = UDim2.new(0, 360, 0, 420)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = PANEL_BG
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = parent
	self._panelFrame = panel

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = ACCENT_COLOR
	panelStroke.Thickness = 2
	panelStroke.Transparency = 0.3
	panelStroke.Parent = panel

	-- Title
	createLabel({
		Name = "Title",
		Text = "DAILY QUESTS",
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.new(0, 10, 0, 8),
		TextSize = 22,
		TextColor3 = ACCENT_COLOR,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = panel,
	})

	-- Reset timer
	self._timerLabel = createLabel({
		Name = "Timer",
		Text = "Resets in --:--:--",
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.new(0, 10, 0, 46),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(160, 160, 180),
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = panel,
	})

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.new(0, 30, 0, 30)
	closeBtn.Position = UDim2.new(1, -38, 0, 8)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "X"
	closeBtn.TextSize = 18
	closeBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Parent = panel
	closeBtn.Activated:Connect(function()
		self:_togglePanel(false)
	end)

	-- Quest cards container
	local cardContainer = Instance.new("Frame")
	cardContainer.Name = "Cards"
	cardContainer.Size = UDim2.new(1, -20, 0, 320)
	cardContainer.Position = UDim2.new(0, 10, 0, 76)
	cardContainer.BackgroundTransparency = 1
	cardContainer.BorderSizePixel = 0
	cardContainer.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = cardContainer

	for i = 1, QuestConfig.DailyQuestCount do
		self:_buildQuestCard(cardContainer, i)
	end
end

function QuestController:_buildQuestCard(parent: Frame, index: number)
	local card = Instance.new("Frame")
	card.Name = "Quest" .. index
	card.Size = UDim2.new(1, 0, 0, 95)
	card.BackgroundColor3 = CARD_BG
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	card.LayoutOrder = index
	card.Parent = parent

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card

	-- Description
	local descLabel = createLabel({
		Name = "Desc",
		Text = "Loading...",
		Size = UDim2.new(1, -16, 0, 36),
		Position = UDim2.new(0, 8, 0, 6),
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		TextWrapped = true,
		Parent = card,
	})
	descLabel.Name = "Desc"

	-- Reward
	local rewardLabel = createLabel({
		Name = "Reward",
		Text = "",
		Size = UDim2.new(0, 100, 0, 20),
		Position = UDim2.new(1, -108, 0, 6),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = card,
	})
	rewardLabel.Name = "Reward"

	-- Progress bar background
	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, -16, 0, 16)
	barBg.Position = UDim2.new(0, 8, 0, 46)
	barBg.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
	barBg.BorderSizePixel = 0
	barBg.Parent = card

	local barBgCorner = Instance.new("UICorner")
	barBgCorner.CornerRadius = UDim.new(0, 6)
	barBgCorner.Parent = barBg

	-- Progress bar fill
	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = PROGRESS_BAR_COLOR
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	local barFillCorner = Instance.new("UICorner")
	barFillCorner.CornerRadius = UDim.new(0, 6)
	barFillCorner.Parent = barFill

	-- Progress text
	local progressLabel = createLabel({
		Name = "ProgressText",
		Text = "0/0",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.fromScale(0, 0),
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = barBg,
	})

	-- Status label
	local statusLabel = createLabel({
		Name = "Status",
		Text = "",
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, 68),
		TextSize = 14,
		TextColor3 = PROGRESS_BAR_COMPLETE_COLOR,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = card,
	})

	self._questCards[index] = card
	self._progressBars[index] = barFill
	self._progressLabels[index] = progressLabel
	self._statusLabels[index] = statusLabel
end

function QuestController:_buildToast(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "QuestToast"
	frame.Size = UDim2.new(0, 400, 0, 44)
	frame.Position = UDim2.new(0.5, 0, 1, -80)
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._toastFrame = frame

	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 8)
	toastCorner.Parent = frame

	local toastStroke = Instance.new("UIStroke")
	toastStroke.Color = ACCENT_COLOR
	toastStroke.Thickness = 1
	toastStroke.Transparency = 0.5
	toastStroke.Parent = frame

	self._toastLabel = createLabel({
		Name = "Text",
		Text = "",
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
	})
end

function QuestController:_buildHudIndicator(parent: ScreenGui)
	local btn = Instance.new("TextButton")
	btn.Name = "QuestHud"
	btn.Size = UDim2.new(0, 44, 0, 44)
	btn.Position = UDim2.new(0, 10, 0.5, -22)
	btn.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	btn.BackgroundTransparency = 0.3
	btn.BorderSizePixel = 0
	btn.Text = "Q"
	btn.TextSize = 20
	btn.TextColor3 = ACCENT_COLOR
	btn.Font = Enum.Font.GothamBold
	btn.Parent = parent
	self._hudIndicator = btn

	local hudCorner = Instance.new("UICorner")
	hudCorner.CornerRadius = UDim.new(0, 10)
	hudCorner.Parent = btn

	local hudStroke = Instance.new("UIStroke")
	hudStroke.Color = ACCENT_COLOR
	hudStroke.Thickness = 2
	hudStroke.Transparency = 0.4
	hudStroke.Parent = btn

	-- Incomplete count badge
	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "Count"
	countLabel.Size = UDim2.new(0, 20, 0, 20)
	countLabel.Position = UDim2.new(1, -4, 0, -4)
	countLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	countLabel.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
	countLabel.BackgroundTransparency = 0
	countLabel.BorderSizePixel = 0
	countLabel.Text = "3"
	countLabel.TextSize = 12
	countLabel.TextColor3 = Color3.new(1, 1, 1)
	countLabel.Font = Enum.Font.GothamBold
	countLabel.Parent = btn
	self._hudCount = countLabel

	local countCorner = Instance.new("UICorner")
	countCorner.CornerRadius = UDim.new(1, 0)
	countCorner.Parent = countLabel

	btn.Activated:Connect(function()
		self:_togglePanel()
	end)
end

--------------------------------------------------
-- Panel logic
--------------------------------------------------

function QuestController:_togglePanel(forceState: boolean?)
	local show = if forceState ~= nil then forceState else not self._panelVisible
	self._panelVisible = show
	if self._panelFrame then
		self._panelFrame.Visible = show
	end
	if show then
		self:_refreshPanel()
	end
end

function QuestController:_refreshPanel()
	for i, quest in self._quests do
		local card = self._questCards[i]
		if not card then
			continue
		end

		local descLabel = card:FindFirstChild("Desc") :: TextLabel?
		local rewardLabel = card:FindFirstChild("Reward") :: TextLabel?
		local barFill = self._progressBars[i]
		local progressLabel = self._progressLabels[i]
		local statusLabel = self._statusLabels[i]

		if descLabel then
			descLabel.Text = quest.Description
		end
		if rewardLabel then
			rewardLabel.Text = "+" .. quest.Reward .. " coins"
		end

		local fraction = if quest.Target > 0 then math.clamp(quest.Progress / quest.Target, 0, 1) else 0
		if barFill then
			barFill.Size = UDim2.fromScale(fraction, 1)
			barFill.BackgroundColor3 = if quest.Completed then PROGRESS_BAR_COMPLETE_COLOR else PROGRESS_BAR_COLOR
		end
		if progressLabel then
			progressLabel.Text = quest.Progress .. "/" .. quest.Target
		end
		if statusLabel then
			statusLabel.Text = if quest.Completed then "Completed!" else ""
		end
	end

	-- Hide unused cards
	for i = #self._quests + 1, QuestConfig.DailyQuestCount do
		local card = self._questCards[i]
		if card then
			card.Visible = false
		end
	end

	self:_updateResetTimer()
end

function QuestController:_updateHudCount()
	local incomplete = 0
	for _, quest in self._quests do
		if not quest.Completed then
			incomplete += 1
		end
	end
	if self._hudCount then
		self._hudCount.Text = tostring(incomplete)
		self._hudCount.Visible = incomplete > 0
	end
end

function QuestController:_updateResetTimer()
	if self._resetTime <= 0 or not self._timerLabel then
		return
	end

	local remaining = self._resetTime
	local hours = math.floor(remaining / 3600)
	local mins = math.floor((remaining % 3600) / 60)
	local secs = math.floor(remaining % 60)
	self._timerLabel.Text = string.format("Resets in %02d:%02d:%02d", hours, mins, secs)
end

--------------------------------------------------
-- Toast notifications
--------------------------------------------------

function QuestController:_showToast(message: string, duration: number, isComplete: boolean?)
	if not self._toastFrame or not self._toastLabel then
		return
	end

	self._toastLabel.Text = message
	self._toastLabel.TextColor3 = if isComplete then PROGRESS_BAR_COMPLETE_COLOR else Color3.new(1, 1, 1)
	self._toastFrame.Visible = true

	if isComplete then
		self._toastFrame.Size = UDim2.new(0, 440, 0, 52)
		self._toastFrame.Position = UDim2.new(0.5, 0, 0.5, 60)
		self._toastFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		self._toastLabel.TextSize = 20
	else
		self._toastFrame.Size = UDim2.new(0, 400, 0, 44)
		self._toastFrame.Position = UDim2.new(0.5, 0, 1, -80)
		self._toastFrame.AnchorPoint = Vector2.new(0.5, 1)
		self._toastLabel.TextSize = 15
	end

	task.delay(duration, function()
		if self._toastFrame and self._toastLabel and self._toastLabel.Text == message then
			self._toastFrame.Visible = false
		end
	end)
end

function QuestController:_pulseHud()
	if not self._hudIndicator then
		return
	end
	local original = self._hudIndicator.BackgroundTransparency
	self._hudIndicator.BackgroundTransparency = 0
	task.delay(0.3, function()
		if self._hudIndicator then
			self._hudIndicator.BackgroundTransparency = original
		end
	end)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function QuestController:KnitInit()
	self._trove = Trove.new()
end

function QuestController:KnitStart()
	self._questService = Knit.GetService("QuestService")

	self:_buildUI()

	-- Fetch initial quest data
	task.spawn(function()
		local ok, quests = self._questService:GetDailyQuests():await()
		if ok and quests then
			self._quests = quests
			self:_refreshPanel()
			self:_updateHudCount()
		end
	end)

	-- Fetch reset time
	task.spawn(function()
		local ok, resetTime = self._questService:GetResetTime():await()
		if ok and resetTime then
			self._resetTime = resetTime
		end
	end)

	-- Quest progress updates
	self._trove:Add(self._questService.QuestProgress:Connect(function(quests: { QuestState })
		local previousQuests = self._quests
		self._quests = quests
		self:_updateHudCount()
		self:_pulseHud()

		-- Find which quest changed and show toast
		for i, quest in quests do
			local prev = previousQuests[i]
			if prev and quest.Progress > prev.Progress and not quest.Completed then
				self:_showToast(
					"Quest: " .. quest.Description .. " -- " .. quest.Progress .. "/" .. quest.Target,
					TOAST_DURATION,
					false
				)
				break
			end
		end

		if self._panelVisible then
			self:_refreshPanel()
		end
	end))

	-- Quest completed
	self._trove:Add(self._questService.QuestCompleted:Connect(function(questIndex: number, reward: number)
		self:_showToast("Quest Complete! +" .. reward .. " coins", TOAST_COMPLETE_DURATION, true)
		self:_updateHudCount()

		if self._panelVisible then
			self:_refreshPanel()
		end
	end))

	-- Keyboard shortcut
	self._trove:Add(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == QUEST_KEY then
			self:_togglePanel()
		end
	end))

	-- Reset timer countdown
	self._trove:Add(task.spawn(function()
		while true do
			task.wait(1)
			if self._resetTime > 0 then
				self._resetTime -= 1
				if self._panelVisible then
					self:_updateResetTimer()
				end
				if self._resetTime <= 0 then
					task.spawn(function()
						local ok2, quests = self._questService:GetDailyQuests():await()
						if ok2 and quests then
							self._quests = quests
							self:_refreshPanel()
							self:_updateHudCount()
						end
						local ok3, resetTime = self._questService:GetResetTime():await()
						if ok3 and resetTime then
							self._resetTime = resetTime
						end
					end)
				end
			end
		end
	end))
end

return QuestController
