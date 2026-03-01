--!strict

--[[
	LeaderboardDisplayComponent — Client-side component that renders leaderboard data.

	Attach the "LeaderboardDisplay" tag to any GUI instance in your game. The tagged
	instance must contain a child Frame named "Frame" with:
		- A TextLabel named "Title" (optional, shows "Property - Period")
		- A ScrollingFrame or Frame named "EntriesFrame" (holds the entry rows)

	Configure behavior via Instance attributes:
		- Property (string): Which config property to show (e.g., "Score1")
		- Period (string): Which period to show ("AllTime", "Weekly", etc.)
		- MaxEntries (number?): Override max visible entries (auto-calculated if nil)
		- TopPlayerRankThreshold (number): Ranks <= this use the top-player template (default 1)
		- RotateProperty (bool): Cycle through all properties automatically
		- RotatePeriod (bool): Cycle through enabled periods for the current property
		- RotationInterval (number): Seconds between rotations (default 10)
		- ExcludedProperties (string): Comma-separated property names to skip during rotation
		- ExcludedPeriods (string): Comma-separated period names to skip during rotation

	Required UI templates at ReplicatedStorage.Assets.UIs.Templates:
		- LeaderboardEntry_TopPlayer
		- LeaderboardEntry
		- LeaderboardEntry_LocalPlayer
		- LeaderboardSeparator

	Each entry template must have children: Rank (TextLabel), Username (TextLabel), Amount (TextLabel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Component = require(ReplicatedStorage.Packages.Component)
local Trove = require(ReplicatedStorage.Packages.Trove)

local LocalPlayer = Players.LocalPlayer

local LeaderboardConfig = require(ReplicatedStorage.Shared.Configs.LeaderboardConfig)

local TEMPLATES_PATH = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("UIs"):WaitForChild("Templates")
local TEMPLATE_NAMES = {
	TOP_PLAYER = "LeaderboardEntry_TopPlayer",
	REGULAR = "LeaderboardEntry",
	LOCAL_PLAYER = "LeaderboardEntry_LocalPlayer",
	SEPARATOR = "LeaderboardSeparator",
}

local LeaderboardDisplayComponent = Component.new({
	Tag = "LeaderboardDisplay",
})

local playerNameCache: { [number]: string } = {}

local function formatScore(score: number?): string
	if not score then
		return "0"
	end

	if score >= 1000000 then
		return string.format("%.2fm", score / 1000000)
	elseif score >= 1000 then
		return string.format("%.2fk", score / 1000)
	else
		return tostring(score)
	end
end

local function getPlayerName(userId: number): string
	if playerNameCache[userId] then
		return playerNameCache[userId]
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		playerNameCache[userId] = player.DisplayName
		return player.DisplayName
	end

	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)

	if success and name then
		playerNameCache[userId] = name
		return name
	end

	return "Player " .. userId
end

local function populateEntry(entryFrame: Instance, rank: number?, userId: number, score: number)
	local rankText = entryFrame:FindFirstChild("Rank") :: TextLabel
	assert(rankText, "Rank not found in entry")
	if rank then
		rankText.Text = tostring(rank)
	else
		rankText.Text = "--"
	end

	local usernameText = entryFrame:FindFirstChild("Username") :: TextLabel
	assert(usernameText, "Username not found in entry")
	task.spawn(function()
		usernameText.Text = getPlayerName(userId)
	end)

	local amountText = entryFrame:FindFirstChild("Amount") :: TextLabel
	assert(amountText, "Amount not found in entry")
	amountText.Text = formatScore(score)

	local icon = amountText:FindFirstChild("Icon")
	if icon then
		(icon :: GuiObject).Visible = false
	end
end

local function parseExclusionList(exclusionString: string?): { [string]: boolean }
	if not exclusionString or exclusionString == "" then
		return {}
	end

	local excluded: { [string]: boolean } = {}
	for item in string.gmatch(exclusionString :: string, "[^,]+") do
		local trimmed = string.match(item, "^%s*(.-)%s*$")
		if trimmed then
			excluded[trimmed] = true
		end
	end
	return excluded
end

local REFRESH_COOLDOWN = 5

function LeaderboardDisplayComponent:Construct()
	self._trove = Trove.new()
	self._entriesTrove = Trove.new()
	self._refreshing = false
	self._lastRefreshTime = 0
	self._pendingRefresh = false

	self._frame = self.Instance:WaitForChild("Frame")

	self._property = self.Instance:GetAttribute("Property") or "Score1"
	self._period = self.Instance:GetAttribute("Period") or "AllTime"
	self._topPlayerRankThreshold = self.Instance:GetAttribute("TopPlayerRankThreshold") or 1

	self._rotateProperty = self.Instance:GetAttribute("RotateProperty") or false
	self._rotatePeriod = self.Instance:GetAttribute("RotatePeriod") or false
	self._rotationInterval = self.Instance:GetAttribute("RotationInterval") or 10
	self._excludedProperties = parseExclusionList(self.Instance:GetAttribute("ExcludedProperties"))
	self._excludedPeriods = parseExclusionList(self.Instance:GetAttribute("ExcludedPeriods"))

	self._currentRotationIndex = 1
end

function LeaderboardDisplayComponent:_getAvailableProperties(): { string }
	local available: { string } = {}
	for propertyName in LeaderboardConfig.Properties do
		if not self._excludedProperties[propertyName] then
			table.insert(available, propertyName)
		end
	end
	return available
end

function LeaderboardDisplayComponent:_getAvailablePeriods(): { string }
	local propertyData = LeaderboardConfig.Properties[self._property]
	if not propertyData then
		return {}
	end

	local available: { string } = {}
	for periodName, enabled in propertyData.Periods do
		if enabled and not self._excludedPeriods[periodName] then
			table.insert(available, periodName)
		end
	end
	return available
end

function LeaderboardDisplayComponent:_startRotation()
	if self._rotationThread then
		return
	end

	self._rotationThread = task.spawn(function()
		while true do
			task.wait(self._rotationInterval)

			if self._rotateProperty then
				local availableProperties = self:_getAvailableProperties()
				if #availableProperties > 1 then
					self._currentRotationIndex = (self._currentRotationIndex % #availableProperties) + 1
					self.Instance:SetAttribute("Property", availableProperties[self._currentRotationIndex])
				end
			elseif self._rotatePeriod then
				local availablePeriods = self:_getAvailablePeriods()
				if #availablePeriods > 1 then
					self._currentRotationIndex = (self._currentRotationIndex % #availablePeriods) + 1
					self.Instance:SetAttribute("Period", availablePeriods[self._currentRotationIndex])
				end
			end
		end
	end)

	self._trove:Add(function()
		if self._rotationThread then
			task.cancel(self._rotationThread)
			self._rotationThread = nil
		end
	end)
end

function LeaderboardDisplayComponent:Start()
	self._leaderboardService = Knit.GetService("LeaderboardService")

	local entriesFrame = self._frame:FindFirstChild("EntriesFrame")
	assert(entriesFrame, "EntriesFrame not found in leaderboard")

	if entriesFrame:IsA("ScrollingFrame") then
		(entriesFrame :: ScrollingFrame).ScrollingEnabled = false
		(entriesFrame :: ScrollingFrame).ScrollBarThickness = 0
	end

	for _, child in entriesFrame:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") and not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end

	self._trove:Add(self.Instance.AttributeChanged:Connect(function(attributeName)
		if attributeName == "Property" then
			self._property = self.Instance:GetAttribute("Property")
			self:_scheduleRefresh()
		elseif attributeName == "Period" then
			self._period = self.Instance:GetAttribute("Period")
			self:_scheduleRefresh()
		elseif attributeName == "RotateProperty" then
			self._rotateProperty = self.Instance:GetAttribute("RotateProperty")
		elseif attributeName == "RotatePeriod" then
			self._rotatePeriod = self.Instance:GetAttribute("RotatePeriod")
		elseif attributeName == "RotationInterval" then
			self._rotationInterval = self.Instance:GetAttribute("RotationInterval")
		elseif attributeName == "ExcludedProperties" then
			self._excludedProperties = parseExclusionList(self.Instance:GetAttribute("ExcludedProperties"))
		elseif attributeName == "ExcludedPeriods" then
			self._excludedPeriods = parseExclusionList(self.Instance:GetAttribute("ExcludedPeriods"))
		end
	end))

	-- Handle batched LeaderboardUpdated signal
	self._trove:Add(self._leaderboardService.LeaderboardUpdated:Connect(function(updatedCombos)
		for _, combo in updatedCombos do
			if combo[1] == self._property and combo[2] == self._period then
				self:_scheduleRefresh()
				break
			end
		end
	end))

	if self._rotateProperty or self._rotatePeriod then
		self:_startRotation()
	end

	-- Initial refresh
	self:_scheduleRefresh()
end

function LeaderboardDisplayComponent:_calculateMaxEntries(): number
	local maxEntries = self.Instance:GetAttribute("MaxEntries")
	if maxEntries then
		return maxEntries
	end

	local entriesFrame = self._frame:FindFirstChild("EntriesFrame")
	if not entriesFrame then
		return 1
	end

	local entryTemplate = TEMPLATES_PATH:FindFirstChild(TEMPLATE_NAMES.REGULAR)
	if not entryTemplate then
		return 1
	end

	local containerHeight = (entriesFrame :: GuiObject).AbsoluteSize.Y
	local entryHeight = (entryTemplate :: GuiObject).Size.Y.Offset

	if entryHeight > 0 then
		return math.floor(containerHeight / entryHeight)
	end

	return 1
end

function LeaderboardDisplayComponent:_scheduleRefresh()
	if self._pendingRefresh then
		return
	end
	self._pendingRefresh = true

	local elapsed = tick() - self._lastRefreshTime
	local delay = math.max(0, REFRESH_COOLDOWN - elapsed)

	task.delay(delay, function()
		self._pendingRefresh = false
		self:_doRefresh()
	end)
end

function LeaderboardDisplayComponent:_doRefresh()
	if self._refreshing then
		return
	end
	self._refreshing = true
	self._lastRefreshTime = tick()

	self._frame.Visible = true

	local maxEntries = self:_calculateMaxEntries()

	local titleText = self._frame:FindFirstChild("Title") :: TextLabel?
	if titleText then
		titleText.Text = string.format("%s - %s", self._property, self._period)
	end

	local entriesFrame = self._frame:FindFirstChild("EntriesFrame")
	assert(entriesFrame, "EntriesFrame not found in leaderboard")

	self._entriesTrove:Clean()

	self._leaderboardService
		:GetLeaderboardData(self._property, self._period, 1, maxEntries)
		:andThen(function(result)
			if not self._refreshing then
				return
			end

			self._entriesTrove:Clean()

			local dataEntries = result.topPlayers.entries
			local playerData = result.playerRank
			local localPlayerInList = result.playerInList

			local entriesToShow = dataEntries
			local showLocalPlayerSeparately = false

			if not localPlayerInList and playerData and (playerData.rank or playerData.score) then
				showLocalPlayerSeparately = true
				local limitedEntries = {}
				for i = 1, math.min(#dataEntries, maxEntries - 1) do
					table.insert(limitedEntries, dataEntries[i])
				end
				entriesToShow = limitedEntries
			end

			for i, entry in entriesToShow do
				local isLocalPlayer = entry.userId == LocalPlayer.UserId
				local isTopPlayer = entry.rank <= self._topPlayerRankThreshold

				local templateName
				if isTopPlayer then
					templateName = TEMPLATE_NAMES.TOP_PLAYER
				elseif isLocalPlayer then
					templateName = TEMPLATE_NAMES.LOCAL_PLAYER
				else
					templateName = TEMPLATE_NAMES.REGULAR
				end

				local template = TEMPLATES_PATH:FindFirstChild(templateName)
				assert(template, string.format("Template %s not found", templateName))

				local entryFrame = template:Clone()
				entryFrame.Name = "Entry_" .. i
				entryFrame.Visible = true
				entryFrame.Parent = entriesFrame

				populateEntry(entryFrame, entry.rank, entry.userId, entry.score)

				self._entriesTrove:Add(entryFrame)
			end

			if showLocalPlayerSeparately then
				local separatorTemplate = TEMPLATES_PATH:FindFirstChild(TEMPLATE_NAMES.SEPARATOR)
				assert(separatorTemplate, "Separator template not found")

				local separator = separatorTemplate:Clone()
				separator.Name = "Separator"
				separator.Visible = true
				separator.LayoutOrder = 9998
				separator.Parent = entriesFrame

				self._entriesTrove:Add(separator)

				local localTemplate = TEMPLATES_PATH:FindFirstChild(TEMPLATE_NAMES.LOCAL_PLAYER)
				assert(localTemplate, "Local player template not found")

				local entryFrame = localTemplate:Clone()
				entryFrame.Name = "Entry_LocalPlayer"
				entryFrame.Visible = true
				entryFrame.LayoutOrder = 9999
				entryFrame.Parent = entriesFrame

				populateEntry(entryFrame, playerData.rank, LocalPlayer.UserId, playerData.score or 0)

				self._entriesTrove:Add(entryFrame)
			end

			self._refreshing = false
		end)
		:catch(function(_err)
			self._refreshing = false
		end)
end

function LeaderboardDisplayComponent:Stop()
	self._entriesTrove:Destroy()
	self._trove:Destroy()
end

return LeaderboardDisplayComponent
