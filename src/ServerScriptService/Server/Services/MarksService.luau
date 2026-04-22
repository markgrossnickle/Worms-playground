--!strict
--
-- MarksService — Worm King "Marks" currency (Phase 3).
--
-- Ghosts earn Marks by contributing to team kills; they spend Marks to
-- respawn as a worm at their team base. Marks reset every round.
--
-- Earn rules (see WormConfig.WormKing.Marks):
--   * Killer of an enemy worm           → KillEnemy   (default 3)
--   * Killer of the Crown carrier       → KillCarrier (default 5)
--   * Ghost on killer's team (assist)   → AssistEnemy / AssistCarrier
--
-- Spend: RespawnCost (default 10) to go from Ghost → Worm.
-- Locked out during the final lockdown window (RespawnLockoutStart).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local WormService -- set in KnitStart
local BotService -- set in KnitStart
local CrownService -- set in KnitStart
local TeamService -- set in KnitStart
local RoundService -- set in KnitStart

local MarksService = Knit.CreateService({
	Name = "MarksService",
	Client = {
		MarksChanged = Knit.CreateSignal(), -- (newMarks)
		RequestRespawn = Knit.CreateSignal(), -- (client → server) request respawn as worm
		RespawnResult = Knit.CreateSignal(), -- (ok: boolean, reason: string?)
	},

	_marks = {} :: { [string]: number },
})

--------------------------------------------------
-- Currency
--------------------------------------------------

local function clampMarks(n: number): number
	if n < 0 then
		return 0
	end
	return math.floor(n)
end

function MarksService:GetMarks(name: string): number
	return self._marks[name] or 0
end

function MarksService:_setMarks(name: string, amount: number)
	self._marks[name] = clampMarks(amount)
	local player = Players:FindFirstChild(name)
	if player and player:IsA("Player") then
		self.Client.MarksChanged:Fire(player, self._marks[name])
	end
end

function MarksService:AwardMarks(name: string, amount: number)
	if amount <= 0 then
		return
	end
	self:_setMarks(name, (self._marks[name] or 0) + amount)
end

function MarksService:SpendMarks(name: string, amount: number): boolean
	if (self._marks[name] or 0) < amount then
		return false
	end
	self:_setMarks(name, (self._marks[name] or 0) - amount)
	return true
end

function MarksService:ResetAll()
	self._marks = {}
	-- Fire zero to all players so UIs reset immediately on round start.
	for _, player in Players:GetPlayers() do
		self.Client.MarksChanged:Fire(player, 0)
	end
end

--------------------------------------------------
-- Award helpers
--------------------------------------------------

-- Returns true if the killed worm was the Crown carrier at time of kill.
function MarksService:_victimWasCarrier(victimName: string): boolean
	if not CrownService then
		return false
	end
	return CrownService:IsCarriedBy(victimName)
end

-- Given a killer name, award direct kill Marks + assist Marks to any ghosts on
-- the killer's team. `victimName` is used to detect Crown-carrier bonus.
function MarksService:_awardForKill(killerName: string, victimName: string)
	if killerName == "" or killerName == victimName then
		return
	end

	local marks = WormConfig.WormKing.Marks
	local carrierKill = self:_victimWasCarrier(victimName)
	local directReward = if carrierKill then marks.KillCarrier else marks.KillEnemy
	local assistReward = if carrierKill then marks.AssistCarrier else marks.AssistEnemy

	-- Direct kill reward — only players accumulate Marks (bots can't spend them).
	local killerIsPlayer = Players:FindFirstChild(killerName) ~= nil
	if killerIsPlayer then
		self:AwardMarks(killerName, directReward)
	end

	-- Assist: ghost teammates of the killer get a smaller reward.
	if not TeamService or not TeamService:IsEnabled() or assistReward <= 0 then
		return
	end
	local killerTeam = TeamService:GetTeamForMember(killerName)
	if not killerTeam then
		return
	end
	if not WormService then
		return
	end

	for _, player in Players:GetPlayers() do
		if player.Name == killerName then
			continue -- killer already rewarded above
		end
		if not WormService:IsGhostPlayer(player) then
			continue
		end
		local teammateIdx = TeamService:GetTeamForMember(player.Name)
		if teammateIdx == killerTeam then
			self:AwardMarks(player.Name, assistReward)
		end
	end
end

--------------------------------------------------
-- Respawn flow
--------------------------------------------------

-- Reason codes returned to the client:
--   RoundInactive, NotGhost, Locked, NoMarks
function MarksService:_canRespawn(player: Player): string?
	if not RoundService or not RoundService:IsRoundActive() then
		return "RoundInactive"
	end
	if not WormService or not WormService:IsGhostPlayer(player) then
		return "NotGhost"
	end
	local elapsed = RoundService:GetRoundElapsed()
	if elapsed >= WormConfig.WormKing.RespawnLockoutStart then
		return "Locked"
	end
	if (self._marks[player.Name] or 0) < WormConfig.WormKing.RespawnCost then
		return "NoMarks"
	end
	return nil
end

function MarksService:_doRespawn(player: Player): (boolean, string?)
	local reason = self:_canRespawn(player)
	if reason then
		return false, reason
	end
	if not self:SpendMarks(player.Name, WormConfig.WormKing.RespawnCost) then
		return false, "NoMarks"
	end
	-- Ghost → Worm: despawn ghost first so SpawnWormForRound reclaims the slot cleanly.
	WormService:DespawnGhost(player)
	WormService:SpawnWormForRound(player)
	return true, nil
end

function MarksService.Client:GetMarks(player: Player): number
	return self.Server._marks[player.Name] or 0
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function MarksService:KnitInit() end

function MarksService:KnitStart()
	WormService = require(script.Parent.WormService)
	BotService = require(script.Parent.BotService)
	CrownService = require(script.Parent.CrownService)
	TeamService = require(script.Parent.TeamService)
	RoundService = require(script.Parent.RoundService)

	-- Player vs. player/bot kills — use server-side PlayerKilled signal.
	WormService.PlayerKilled:Connect(function(killer: Player, victim: Player)
		if not killer or not victim then
			return
		end
		self:_awardForKill(killer.Name, victim.Name)
	end)

	-- Bot deaths where the killer is a Player (BotService fires killerName string).
	BotService.BotKilled:Connect(function(botName: string, killerName: string?)
		if not killerName or killerName == "" then
			return
		end
		-- Only award when the killer is a human player (bots killing bots: no-op).
		if Players:FindFirstChild(killerName) then
			self:_awardForKill(killerName, botName)
		end
	end)

	-- Client requests a respawn → validate, spend, spawn worm.
	self.Client.RequestRespawn:Connect(function(player: Player)
		local ok, reason = self:_doRespawn(player)
		self.Client.RespawnResult:Fire(player, ok, reason)
	end)

	-- Clean up on leave.
	Players.PlayerRemoving:Connect(function(player: Player)
		self._marks[player.Name] = nil
	end)
end

return MarksService
