--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local WormService -- Set in KnitStart
local BotService -- Set in KnitStart
local ShrinkZoneService -- Set in KnitStart
local PowerUpService -- Set in KnitStart
local CoinService -- Set in KnitStart
local TeamService -- Set in KnitStart

local PLACEMENT_REWARDS = { [1] = 100, [2] = 60, [3] = 40, [4] = 25 }
local DEFAULT_REWARD = 10

type EliminationEntry = {
	Name: string,
	IsBot: boolean,
	Placement: number,
	Kills: number,
	MaxSegments: number,
}

local RoundService = Knit.CreateService({
	Name = "RoundService",
	Client = {
		RoundEnded = Knit.CreateSignal(),
		RoundCountdown = Knit.CreateSignal(),
		RoundStarted = Knit.CreateSignal(),
		ForceSpectate = Knit.CreateSignal(),
	},

	_roundActive = false,
	_eliminationOrder = {} :: { EliminationEntry },
	_pollConnection = nil :: RBXScriptConnection?,
	_winningTeamIndex = nil :: number?,
})

--------------------------------------------------
-- Round lifecycle
--------------------------------------------------

function RoundService:_startRound()
	self._eliminationOrder = {}
	self._roundActive = true
	self._winningTeamIndex = nil

	-- Reset game state
	ShrinkZoneService:Reset()
	PowerUpService:Reset()
	WormService:ResetFood()

	-- Tell services the round is active
	WormService:SetRoundActive(true)
	BotService:SetRoundActive(true)

	-- Clear bot stats from previous round
	BotService:ClearRoundStats()

	-- Reset team assignments so teams are balanced for the new round
	if TeamService:IsEnabled() then
		TeamService:ClearAllMembers()
	end

	-- Spawn all current players (pcall so one failure doesn't block bot spawning)
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(function()
			WormService:SpawnWormForRound(player)
		end)
		if not ok then
			warn("[RoundService] Failed to spawn worm for " .. player.Name .. ": " .. tostring(err))
		end
	end

	-- Spawn bots to fill
	BotService:SpawnBotsToFill()

	-- Notify clients
	self.Client.RoundStarted:FireAll()

	-- Start polling win condition
	self:_startPollWinCondition()
end

function RoundService:_getAllAliveNames(): { string }
	local names = {}
	for _, player in WormService:GetAlivePlayers() do
		table.insert(names, player.Name)
	end
	for _, botName in BotService:GetAliveBotNames() do
		table.insert(names, botName)
	end
	return names
end

function RoundService:_startPollWinCondition()
	if self._pollConnection then
		task.cancel(self._pollConnection)
		self._pollConnection = nil
	end

	self._pollConnection = task.spawn(function()
		-- Small delay before first check to let spawns complete
		task.wait(2)

		while self._roundActive do
			local totalAlive = WormService:GetAliveCount() + BotService:GetAliveCount()

			if TeamService:IsEnabled() then
				local aliveTeams = TeamService:GetAliveTeams(self:_getAllAliveNames())
				if #aliveTeams <= 1 then
					self._winningTeamIndex = if #aliveTeams == 1 then aliveTeams[1] else nil
					self:_endRound()
					return
				end
			else
				if totalAlive <= 1 then
					self:_endRound()
					return
				end
			end

			task.wait(0.5)
		end
	end) :: any
end

function RoundService:_endRound()
	self._roundActive = false
	WormService:SetRoundActive(false)
	BotService:SetRoundActive(false)

	-- Collect survivor stats (the last one(s) standing)
	local alivePlayers = WormService:GetAlivePlayers()
	local aliveBotNames = BotService:GetAliveBotNames()

	local playerStats = WormService:GetRoundStats()
	local botStats = BotService:GetRoundStats()

	-- Add survivors to elimination order (they get best placement)
	for _, player in alivePlayers do
		local stats = playerStats[player.Name]
		table.insert(self._eliminationOrder, {
			Name = player.Name,
			IsBot = false,
			Placement = 0, -- will be assigned below
			Kills = if stats then stats.Kills else 0,
			MaxSegments = if stats then stats.MaxSegments else 0,
		})
	end
	for _, botName in aliveBotNames do
		local stats = botStats[botName]
		table.insert(self._eliminationOrder, {
			Name = botName,
			IsBot = true,
			Placement = 0,
			Kills = if stats then stats.Kills else 0,
			MaxSegments = if stats then stats.MaxSegments else 0,
		})
	end

	-- Assign placements: survivors = 1, eliminated in reverse death order
	-- eliminationOrder: entries added later = survived longer = better placement
	local totalEntries = #self._eliminationOrder
	for i, entry in self._eliminationOrder do
		-- First eliminated = worst placement, last = best (1)
		entry.Placement = totalEntries - i + 1
	end

	-- Build sorted results (placement 1 first)
	local results = {}
	for _, entry in self._eliminationOrder do
		table.insert(results, {
			Name = entry.Name,
			IsBot = entry.IsBot,
			Placement = entry.Placement,
			Kills = entry.Kills,
			MaxSegments = entry.MaxSegments,
			CoinsAwarded = 0,
		})
	end
	table.sort(results, function(a, b)
		return a.Placement < b.Placement
	end)

	-- Award coins based on placement
	for _, entry in results do
		if not entry.IsBot then
			local player = Players:FindFirstChild(entry.Name) :: Player?
			if player then
				local reward = PLACEMENT_REWARDS[entry.Placement] or DEFAULT_REWARD
				entry.CoinsAwarded = reward
				task.spawn(function()
					CoinService:AwardCoins(player, reward)
				end)
			end
		end
	end

	-- Build winning team info if team mode
	local winningTeam = nil
	if TeamService:IsEnabled() and self._winningTeamIndex then
		local teams = TeamService:GetTeams()
		local team = teams[self._winningTeamIndex]
		if team then
			winningTeam = {
				TeamIndex = self._winningTeamIndex,
				TeamName = team.Name,
				TeamColor = { team.Color.R, team.Color.G, team.Color.B },
			}
		end
	end

	-- Fire round ended to all clients
	self.Client.RoundEnded:FireAll(results, winningTeam)

	-- Kill all remaining worms/bots
	WormService:KillAllWorms()
	BotService:KillAllBots()

	-- Wait for scoreboard duration, then run countdown
	task.wait(WormConfig.RoundScoreboardDuration)
	self:_runCountdown()
end

function RoundService:_runCountdown()
	for i = WormConfig.RoundCountdownDuration, 1, -1 do
		self.Client.RoundCountdown:FireAll(i)
		task.wait(1)
	end

	self:_startRound()
end

function RoundService:_recordElimination(name: string, isBot: boolean, kills: number, maxSegments: number)
	table.insert(self._eliminationOrder, {
		Name = name,
		IsBot = isBot,
		Placement = 0, -- assigned at round end
		Kills = kills,
		MaxSegments = maxSegments,
	})
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function RoundService:KnitInit() end

function RoundService:KnitStart()
	WormService = require(script.Parent.WormService)
	BotService = require(script.Parent.BotService)
	ShrinkZoneService = require(script.Parent.ShrinkZoneService)
	PowerUpService = require(script.Parent.PowerUpService)
	CoinService = require(script.Parent.CoinService)
	TeamService = require(script.Parent.TeamService)

	-- Track ALL player deaths (walls, zone, and player-kills-player)
	-- PlayerDied fires server-side for every player death
	WormService.PlayerDied:Connect(function(deadPlayer: Player, _killerName: string?)
		-- Avoid double-recording: check if already in elimination order
		for _, entry in self._eliminationOrder do
			if entry.Name == deadPlayer.Name then
				return
			end
		end
		local wormData = WormService:GetWormData_Server(deadPlayer)
		self:_recordElimination(
			deadPlayer.Name,
			false,
			if wormData then wormData.Kills else 0,
			if wormData then math.floor(wormData.MaxSegments) else 0
		)
	end)

	-- Track bot eliminations
	BotService.BotKilled:Connect(function(botName: string, _killerName: string?)
		local botStats = BotService:GetRoundStats()
		local stats = botStats[botName]
		self:_recordElimination(botName, true, if stats then stats.Kills else 0, if stats then stats.MaxSegments else 0)
	end)

	-- Handle players leaving mid-round
	Players.PlayerRemoving:Connect(function(player: Player)
		if not self._roundActive then
			return
		end
		-- Check if they were alive
		local wormData = WormService:GetWormData_Server(player)
		if wormData and wormData.State == "Alive" then
			-- Record elimination as if they died
			self:_recordElimination(player.Name, false, wormData.Kills, math.floor(wormData.MaxSegments))
		end
	end)

	-- Handle late joiners during a round — spawn as ghost immediately
	Players.PlayerAdded:Connect(function(player: Player)
		if self._roundActive then
			-- Wait for WormService to register the player and client to set up
			task.wait(2)
			if not self._roundActive then
				return
			end
			WormService:SpawnGhost(player)
		end
	end)

	-- Start first round after a short delay
	task.delay(3, function()
		self:_startRound()
	end)
end

return RoundService
