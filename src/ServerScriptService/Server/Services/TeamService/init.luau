--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

type TeamData = {
	Name: string,
	Color: Color3,
	Members: { string }, -- player names or bot names
}

local TeamService = Knit.CreateService({
	Name = "TeamService",
	Client = {
		TeamAssigned = Knit.CreateSignal(), -- fires (teamIndex, teamName, teamColor)
		TeamsUpdated = Knit.CreateSignal(), -- fires (teams data)
	},

	_teams = {} :: { [number]: TeamData },
	_memberTeam = {} :: { [string]: number }, -- name -> team index
	_enabled = WormConfig.TeamModeEnabled,

	TeamChanged = Signal.new(),
})

--------------------------------------------------
-- Team management
--------------------------------------------------

function TeamService:IsEnabled(): boolean
	return self._enabled
end

function TeamService:_initTeams()
	for i, teamConfig in WormConfig.TeamColors do
		self._teams[i] = {
			Name = teamConfig.Name,
			Color = teamConfig.Color,
			Members = {},
		}
	end
end

function TeamService:GetTeamForMember(name: string): number?
	return self._memberTeam[name]
end

function TeamService:GetTeamColor(teamIndex: number): Color3?
	local team = self._teams[teamIndex]
	if team then
		return team.Color
	end
	return nil
end

function TeamService:AreTeammates(name1: string, name2: string): boolean
	if not self._enabled then
		return false
	end
	local t1 = self._memberTeam[name1]
	local t2 = self._memberTeam[name2]
	if t1 and t2 then
		return t1 == t2
	end
	return false
end

function TeamService:_findSmallestTeam(): number
	local minSize = math.huge
	local minIndex = 1
	for i, team in self._teams do
		if #team.Members < minSize then
			minSize = #team.Members
			minIndex = i
		end
	end
	return minIndex
end

function TeamService:AssignToTeam(name: string): number
	if not self._enabled then
		return 0
	end

	-- Already assigned?
	if self._memberTeam[name] then
		return self._memberTeam[name]
	end

	local teamIndex = self:_findSmallestTeam()
	local team = self._teams[teamIndex]

	-- Cap at TeamSize per team
	if #team.Members >= WormConfig.TeamSize then
		-- All teams full, still assign to smallest
		teamIndex = self:_findSmallestTeam()
		team = self._teams[teamIndex]
	end

	table.insert(team.Members, name)
	self._memberTeam[name] = teamIndex
	self.TeamChanged:Fire(name, teamIndex)

	return teamIndex
end

function TeamService:RemoveFromTeam(name: string)
	local teamIndex = self._memberTeam[name]
	if not teamIndex then
		return
	end

	local team = self._teams[teamIndex]
	if team then
		for i, member in team.Members do
			if member == name then
				table.remove(team.Members, i)
				break
			end
		end
	end
	self._memberTeam[name] = nil
end

function TeamService:GetTeamScores(
	wormSegments: { [string]: number }
): { { TeamName: string, Color: Color3, Score: number } }
	local scores = {}
	for i, team in self._teams do
		local totalScore = 0
		for _, memberName in team.Members do
			local segs = wormSegments[memberName]
			if segs then
				totalScore += segs
			end
		end
		table.insert(scores, {
			TeamName = team.Name,
			Color = team.Color,
			Score = math.floor(totalScore),
			TeamIndex = i,
		})
	end
	table.sort(scores, function(a, b)
		return a.Score > b.Score
	end)
	return scores
end

function TeamService:ClearAllMembers()
	for _, team in self._teams do
		table.clear(team.Members)
	end
	table.clear(self._memberTeam)
end

function TeamService:GetTeams(): { [number]: TeamData }
	return self._teams
end

function TeamService:GetAliveTeams(aliveNames: { string }): { number }
	local aliveSet: { [string]: boolean } = {}
	for _, name in aliveNames do
		aliveSet[name] = true
	end

	local teamsAlive: { number } = {}
	for i, team in self._teams do
		for _, member in team.Members do
			if aliveSet[member] then
				table.insert(teamsAlive, i)
				break
			end
		end
	end
	return teamsAlive
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function TeamService.Client:GetTeamInfo(_player: Player): { Enabled: boolean, Teams: any }
	return {
		Enabled = self.Server._enabled,
		Teams = self.Server._teams,
	}
end

function TeamService.Client:GetMyTeam(player: Player): { TeamIndex: number, TeamName: string, TeamColor: { number } }?
	local teamIndex = self.Server._memberTeam[player.Name]
	if not teamIndex then
		return nil
	end
	local team = self.Server._teams[teamIndex]
	if not team then
		return nil
	end
	return {
		TeamIndex = teamIndex,
		TeamName = team.Name,
		TeamColor = { team.Color.R, team.Color.G, team.Color.B },
	}
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function TeamService:KnitInit()
	self:_initTeams()
end

function TeamService:KnitStart()
	if not self._enabled then
		return
	end

	-- Assign existing players
	for _, player in Players:GetPlayers() do
		local teamIndex = self:AssignToTeam(player.Name)
		local team = self._teams[teamIndex]
		if team then
			self.Client.TeamAssigned:Fire(player, teamIndex, team.Name, team.Color)
		end
	end

	-- Assign new players
	Players.PlayerAdded:Connect(function(player: Player)
		local teamIndex = self:AssignToTeam(player.Name)
		local team = self._teams[teamIndex]
		if team then
			self.Client.TeamAssigned:Fire(player, teamIndex, team.Name, team.Color)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:RemoveFromTeam(player.Name)
	end)
end

return TeamService
