--!strict

--[[
	@class MilestoneService
	@server

	Tracks player milestones (one-time achievements) and fires analytics events
	when they are reached. Uses DataStorePath pattern from PlayerDataService.

	TODO: Wire milestone checks to actual game events.
	TODO: Add badge awards for milestone completion.
	TODO: Connect to MTAnalyticsService for milestone tracking.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local t = require(ReplicatedStorage.Packages.t)

local MilestoneService = Knit.CreateService({
	Name = "MilestoneService",
	MilestoneReached = Signal.new(), -- (player: Player, milestoneName: string)
	Client = {
		MilestoneReached = Knit.CreateSignal(), -- (milestoneName: string)
	},
})

-- DataStorePaths for each milestone (built in KnitStart after PlayerDataService is available)
local MilestonePaths = {} :: { [string]: any }

local PlayerDataService

--[[
	Milestone definitions — add new milestones here.
	Each key must match a field in the PlayerData.Milestones table.

	Fields:
		- DisplayName: Human-readable name for UI/analytics
		- Description: What the player did to earn this milestone

	TODO: Add your game-specific milestones here.
]]
local MILESTONES = {
	FirstJoin = {
		DisplayName = "Welcome!",
		Description = "Joined the game for the first time",
	},
	FirstWin = {
		DisplayName = "Winner!",
		Description = "Won a game for the first time",
	},
	FirstPurchase = {
		DisplayName = "Big Spender",
		Description = "Made a purchase for the first time",
	},
	ReachedLevel5 = {
		DisplayName = "Getting Started",
		Description = "Reached level 5",
	},
	ReachedLevel10 = {
		DisplayName = "Veteran",
		Description = "Reached level 10",
	},
}

--[=[
	Check if a player has already completed a milestone.
	@param player Player
	@param milestoneName string -- Key from MILESTONES table
	@return boolean
]=]
function MilestoneService:HasMilestone(player: Player, milestoneName: string): boolean
	assert(t.instanceOf("Player")(player))
	assert(MILESTONES[milestoneName], `Unknown milestone: {milestoneName}`)

	local path = MilestonePaths[milestoneName]
	if not path then
		return false
	end

	return path:Read(player) == true
end

--[=[
	Award a milestone to a player if they haven't already earned it.
	@param player Player
	@param milestoneName string -- Key from MILESTONES table
	@return boolean -- true if the milestone was newly awarded
]=]
function MilestoneService:AwardMilestone(player: Player, milestoneName: string): boolean
	assert(t.instanceOf("Player")(player))
	assert(MILESTONES[milestoneName], `Unknown milestone: {milestoneName}`)

	local path = MilestonePaths[milestoneName]
	if not path then
		warn(`[MilestoneService] No DataStorePath for milestone: {milestoneName}`)
		return false
	end

	if path:Read(player) == true then
		return false -- Already earned
	end

	path:Write(player, true)

	local milestoneData = MILESTONES[milestoneName]
	print(`[MilestoneService] {player.Name} earned milestone: {milestoneData.DisplayName}`)

	self.MilestoneReached:Fire(player, milestoneName)
	self.Client.MilestoneReached:Fire(player, milestoneName)

	-- TODO: Award corresponding badge via BadgeService
	-- local BadgeService = Knit.GetService("BadgeService")
	-- BadgeService:AwardBadge(player, MILESTONE_BADGE_MAP[milestoneName])

	-- TODO: Log to analytics via MTAnalyticsService
	-- local MTAnalyticsService = Knit.GetService("MTAnalyticsService")
	-- MTAnalyticsService:LogCustomEvent(player, "MilestoneReached", 1, { milestone = milestoneName })

	return true
end

--[=[
	Get all milestone statuses for a player.
	@param player Player
	@return { [string]: boolean }
]=]
function MilestoneService:GetAllMilestones(player: Player): { [string]: boolean }
	assert(t.instanceOf("Player")(player))

	local milestones = {}
	for milestoneName in MILESTONES do
		milestones[milestoneName] = self:HasMilestone(player, milestoneName)
	end
	return milestones
end

function MilestoneService.Client:GetAllMilestones(player: Player)
	return self.Server:GetAllMilestones(player)
end

function MilestoneService:KnitInit() end

function MilestoneService:KnitStart()
	PlayerDataService = Knit.GetService("PlayerDataService")

	-- Build DataStorePaths for each milestone
	for milestoneName in MILESTONES do
		MilestonePaths[milestoneName] =
			PlayerDataService:BuildDataStorePath({ "Milestones", milestoneName }, false, t.boolean)
	end

	-- TODO: Wire milestone checks to game events. Examples:
	--
	-- Award "FirstJoin" when profile loads:
	--   PlayerDataService.ProfileReady:Connect(function(player)
	--       self:AwardMilestone(player, "FirstJoin")
	--   end)
	--
	-- Award "FirstWin" when a player wins:
	--   local GameService = Knit.GetService("GameService")
	--   GameService.PlayerWon:Connect(function(player)
	--       self:AwardMilestone(player, "FirstWin")
	--   end)
	--
	-- Award "ReachedLevel5" when player levels up:
	--   local LevelPath = PlayerDataService:BuildDataStorePath({ "Level" }, 1, t.number)
	--   PlayerDataService.PathWritten:Connect(function(player, path, value)
	--       if path[1] == "Level" and value >= 5 then
	--           self:AwardMilestone(player, "ReachedLevel5")
	--       end
	--       if path[1] == "Level" and value >= 10 then
	--           self:AwardMilestone(player, "ReachedLevel10")
	--       end
	--   end)
end

return MilestoneService
