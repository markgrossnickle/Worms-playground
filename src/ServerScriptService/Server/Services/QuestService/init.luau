--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local QuestConfig = require(ReplicatedStorage.Shared.QuestConfig)

local PlayerDataService -- Set in KnitStart
local CoinService -- Set in KnitStart
local WormService -- Set in KnitStart
local PowerUpService -- Set in KnitStart
local WeaponService -- Set in KnitStart
local RoundService -- Set in KnitStart

type QuestState = {
	Type: string,
	Target: number,
	Progress: number,
	Completed: boolean,
	Reward: number,
	Description: string,
}

type DailyQuestData = {
	Date: string,
	Quests: { QuestState },
}

local QuestService = Knit.CreateService({
	Name = "QuestService",
	Client = {
		QuestProgress = Knit.CreateSignal(), -- (quests: {QuestState})
		QuestCompleted = Knit.CreateSignal(), -- (questIndex: number, reward: number)
	},

	-- Server-side signals for other services
	QuestProgressChanged = Signal.new(), -- (player, questIndex, current, target)
	QuestCompletedSignal = Signal.new(), -- (player, questIndex, reward)

	-- Runtime tracking
	_spawnTimes = {} :: { [Player]: number },
	_boostAccumulators = {} :: { [Player]: number },
})

--------------------------------------------------
-- Helpers
--------------------------------------------------

local function getTodayStr(): string
	return os.date("!%Y-%m-%d") :: string
end

local function selectRandomQuests(): { QuestState }
	local pool = QuestConfig.QuestPool
	local usedTypes: { [string]: boolean } = {}
	local selected: { QuestState } = {}

	-- Shuffle pool indices
	local indices = {}
	for i = 1, #pool do
		table.insert(indices, i)
	end
	for i = #indices, 2, -1 do
		local j = math.random(1, i)
		indices[i], indices[j] = indices[j], indices[i]
	end

	for _, idx in indices do
		if #selected >= QuestConfig.DailyQuestCount then
			break
		end
		local def = pool[idx]
		if not usedTypes[def.Type] then
			usedTypes[def.Type] = true
			table.insert(selected, {
				Type = def.Type,
				Target = def.Target,
				Progress = 0,
				Completed = false,
				Reward = def.Reward,
				Description = QuestConfig.FormatDescription(def),
			})
		end
	end

	return selected
end

--------------------------------------------------
-- Quest data persistence
--------------------------------------------------

function QuestService:_getDailyQuests(player: Player): { QuestState }
	local data = PlayerDataService:Read(player, { "DailyQuests" })
	local today = getTodayStr()

	if data and type(data) == "table" and data.Date == today and data.Quests and #data.Quests > 0 then
		return data.Quests
	end

	local quests = selectRandomQuests()
	local questData: DailyQuestData = {
		Date = today,
		Quests = quests,
	}
	PlayerDataService:Write(player, { "DailyQuests" }, questData)
	return quests
end

function QuestService:_saveQuests(player: Player, quests: { QuestState })
	local today = getTodayStr()
	PlayerDataService:Write(player, { "DailyQuests" }, {
		Date = today,
		Quests = quests,
	})
end

--------------------------------------------------
-- Progress tracking
--------------------------------------------------

function QuestService:_incrementQuest(player: Player, questType: string, amount: number)
	if not player.Parent then
		return
	end

	local quests = self:_getDailyQuests(player)
	local changed = false

	for i, quest in quests do
		if quest.Type == questType and not quest.Completed then
			quest.Progress = math.min(quest.Progress + amount, quest.Target)
			changed = true

			if quest.Progress >= quest.Target then
				quest.Completed = true
				task.spawn(function()
					CoinService:AwardCoins(player, quest.Reward)
				end)
				self.Client.QuestCompleted:Fire(player, i, quest.Reward)
				self.QuestCompletedSignal:Fire(player, i, quest.Reward)
			end

			self.QuestProgressChanged:Fire(player, i, quest.Progress, quest.Target)
			break
		end
	end

	if changed then
		self:_saveQuests(player, quests)
		self.Client.QuestProgress:Fire(player, quests)
	end
end

function QuestService:_setQuestMax(player: Player, questType: string, value: number)
	if not player.Parent then
		return
	end

	local quests = self:_getDailyQuests(player)
	local changed = false

	for i, quest in quests do
		if quest.Type == questType and not quest.Completed then
			if value > quest.Progress then
				quest.Progress = math.min(value, quest.Target)
				changed = true

				if quest.Progress >= quest.Target then
					quest.Completed = true
					task.spawn(function()
						CoinService:AwardCoins(player, quest.Reward)
					end)
					self.Client.QuestCompleted:Fire(player, i, quest.Reward)
					self.QuestCompletedSignal:Fire(player, i, quest.Reward)
				end

				self.QuestProgressChanged:Fire(player, i, quest.Progress, quest.Target)
			end
			break
		end
	end

	if changed then
		self:_saveQuests(player, quests)
		self.Client.QuestProgress:Fire(player, quests)
	end
end

--------------------------------------------------
-- Event wiring
--------------------------------------------------

function QuestService:_wireEvents()
	-- Food eaten — PlayerScoreChanged fires (player, newScore) on each eat
	WormService.PlayerScoreChanged:Connect(function(player: Player, newScore: number)
		self:_incrementQuest(player, "EatFood", 1)
		self:_setQuestMax(player, "ReachSegments", math.floor(newScore))
	end)

	-- Kills
	WormService.PlayerKilled:Connect(function(killer: Player, _deadPlayer: Player)
		self:_incrementQuest(killer, "KillWorms", 1)
	end)

	-- Player died — record survival time and flush boost accumulator
	WormService.PlayerDied:Connect(function(player: Player, _killerName: string?)
		local spawnTime = self._spawnTimes[player]
		if spawnTime then
			local survived = math.floor(os.clock() - spawnTime)
			self:_setQuestMax(player, "Survive", survived)
			self._spawnTimes[player] = nil
		end

		local boostAccum = self._boostAccumulators[player]
		if boostAccum and boostAccum > 0 then
			self:_setQuestMax(player, "UseBoost", math.floor(boostAccum))
		end
		self._boostAccumulators[player] = nil
	end)

	-- Worm spawned — record spawn time
	WormService.WormSpawnedServer:Connect(function(player: Player)
		self._spawnTimes[player] = os.clock()
		self._boostAccumulators[player] = 0
	end)

	-- Power-up collected (server-side signal)
	PowerUpService.PowerUpCollectedServer:Connect(function(ownerName: string, _powerUpType: string)
		local player = Players:FindFirstChild(ownerName) :: Player?
		if player and player:IsA("Player") then
			self:_incrementQuest(player, "CollectPowerUps", 1)
		end
	end)

	-- Weapon assigned (server-side signal)
	WeaponService.WeaponAssignedServer:Connect(function(player: Player, _weaponType: string)
		self:_incrementQuest(player, "CollectWeapons", 1)
	end)

	-- Round ended — check for wins
	RoundService.RoundEndedServer:Connect(function(results: any)
		if type(results) ~= "table" then
			return
		end
		for _, entry in results do
			if not entry.IsBot and entry.Placement == 1 then
				local winner = Players:FindFirstChild(entry.Name) :: Player?
				if winner then
					self:_incrementQuest(winner, "WinRound", 1)
				end
			end
		end
	end)
end

function QuestService:_wireBoostTracking()
	RunService.Heartbeat:Connect(function(dt: number)
		for player, wormData in WormService._worms do
			if wormData.State == "Alive" and wormData.Boosting then
				if self._boostAccumulators[player] == nil then
					self._boostAccumulators[player] = 0
				end
				self._boostAccumulators[player] += dt
			end
		end
	end)
end

function QuestService:_wireGhostKillTracking()
	task.spawn(function()
		local lastCounts: { [Player]: number } = {}
		while true do
			task.wait(1)
			for player, count in WormService._ghostKillCounts do
				local last = lastCounts[player] or 0
				if count > last then
					self:_incrementQuest(player, "GhostKills", count - last)
					lastCounts[player] = count
				end
			end
			for player in lastCounts do
				if not player.Parent then
					lastCounts[player] = nil
				end
			end
		end
	end)
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function QuestService.Client:GetDailyQuests(player: Player): { QuestState }
	return self.Server:_getDailyQuests(player)
end

function QuestService.Client:GetResetTime(_player: Player): number
	local now = os.time()
	local utcHour = tonumber(os.date("!%H", now)) :: number
	local utcMin = tonumber(os.date("!%M", now)) :: number
	local utcSec = tonumber(os.date("!%S", now)) :: number
	local secondsToday = utcHour * 3600 + utcMin * 60 + utcSec
	return 86400 - secondsToday
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function QuestService:KnitInit()
	Players.PlayerRemoving:Connect(function(player: Player)
		self._spawnTimes[player] = nil
		self._boostAccumulators[player] = nil
	end)
end

function QuestService:KnitStart()
	PlayerDataService = Knit.GetService("PlayerDataService")
	CoinService = Knit.GetService("CoinService")
	WormService = require(script.Parent.WormService)
	PowerUpService = require(script.Parent.PowerUpService)
	WeaponService = require(script.Parent.WeaponService)
	RoundService = require(script.Parent.RoundService)

	self:_wireEvents()
	self:_wireBoostTracking()
	self:_wireGhostKillTracking()

	-- Initialize quests for existing players
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			PlayerDataService:WaitForProfile(player)
				:andThen(function()
					self:_getDailyQuests(player)
				end)
				:catch(function(err)
					warn("QuestService: Failed to init quests for", player.Name, err)
				end)
		end)
	end

	-- Initialize quests when profile is ready
	PlayerDataService.ProfileReady:Connect(function(player: Player)
		task.spawn(function()
			task.wait(1)
			if player.Parent then
				self:_getDailyQuests(player)
			end
		end)
	end)
end

return QuestService
