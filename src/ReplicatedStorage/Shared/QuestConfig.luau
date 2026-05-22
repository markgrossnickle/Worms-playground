--!strict

export type QuestDifficulty = "Easy" | "Medium" | "Hard"

export type QuestDefinition = {
	Type: string,
	Description: string, -- Use {target} as placeholder
	Difficulty: QuestDifficulty,
	Target: number,
	Reward: number,
}

local REWARDS: { [QuestDifficulty]: number } = {
	Easy = 25,
	Medium = 50,
	Hard = 100,
}

local QuestConfig = {}

QuestConfig.Rewards = REWARDS

QuestConfig.QuestPool: { QuestDefinition } = {
	-- Eat N food
	{ Type = "EatFood", Description = "Eat {target} food items", Difficulty = "Easy", Target = 10, Reward = REWARDS.Easy },
	{ Type = "EatFood", Description = "Eat {target} food items", Difficulty = "Medium", Target = 25, Reward = REWARDS.Medium },
	{ Type = "EatFood", Description = "Eat {target} food items", Difficulty = "Hard", Target = 50, Reward = REWARDS.Hard },

	-- Reach N segments
	{ Type = "ReachSegments", Description = "Reach {target} segments in a single life", Difficulty = "Easy", Target = 20, Reward = REWARDS.Easy },
	{ Type = "ReachSegments", Description = "Reach {target} segments in a single life", Difficulty = "Medium", Target = 40, Reward = REWARDS.Medium },
	{ Type = "ReachSegments", Description = "Reach {target} segments in a single life", Difficulty = "Hard", Target = 60, Reward = REWARDS.Hard },

	-- Survive N seconds
	{ Type = "Survive", Description = "Survive {target} seconds in a round", Difficulty = "Easy", Target = 60, Reward = REWARDS.Easy },
	{ Type = "Survive", Description = "Survive {target} seconds in a round", Difficulty = "Medium", Target = 120, Reward = REWARDS.Medium },
	{ Type = "Survive", Description = "Survive {target} seconds in a round", Difficulty = "Hard", Target = 180, Reward = REWARDS.Hard },

	-- Kill N worms
	{ Type = "KillWorms", Description = "Kill {target} worms", Difficulty = "Easy", Target = 1, Reward = REWARDS.Easy },
	{ Type = "KillWorms", Description = "Kill {target} worms", Difficulty = "Medium", Target = 3, Reward = REWARDS.Medium },
	{ Type = "KillWorms", Description = "Kill {target} worms", Difficulty = "Hard", Target = 5, Reward = REWARDS.Hard },

	-- Collect N power-ups
	{ Type = "CollectPowerUps", Description = "Collect {target} power-ups", Difficulty = "Easy", Target = 2, Reward = REWARDS.Easy },
	{ Type = "CollectPowerUps", Description = "Collect {target} power-ups", Difficulty = "Medium", Target = 5, Reward = REWARDS.Medium },
	{ Type = "CollectPowerUps", Description = "Collect {target} power-ups", Difficulty = "Hard", Target = 8, Reward = REWARDS.Hard },

	-- Win a round
	{ Type = "WinRound", Description = "Win a round (place 1st)", Difficulty = "Hard", Target = 1, Reward = REWARDS.Hard },

	-- Ghost kills
	{ Type = "GhostKills", Description = "Get {target} kills as a ghost", Difficulty = "Easy", Target = 2, Reward = REWARDS.Easy },
	{ Type = "GhostKills", Description = "Get {target} kills as a ghost", Difficulty = "Medium", Target = 4, Reward = REWARDS.Medium },
	{ Type = "GhostKills", Description = "Get {target} kills as a ghost", Difficulty = "Hard", Target = 6, Reward = REWARDS.Hard },

	-- Use boost for N seconds
	{ Type = "UseBoost", Description = "Use boost for {target} seconds", Difficulty = "Easy", Target = 10, Reward = REWARDS.Easy },
	{ Type = "UseBoost", Description = "Use boost for {target} seconds", Difficulty = "Medium", Target = 20, Reward = REWARDS.Medium },
	{ Type = "UseBoost", Description = "Use boost for {target} seconds", Difficulty = "Hard", Target = 30, Reward = REWARDS.Hard },

	-- Collect weapon pickups (assigned on ghost spawn)
	{ Type = "CollectWeapons", Description = "Collect {target} weapon pickups", Difficulty = "Easy", Target = 3, Reward = REWARDS.Easy },
	{ Type = "CollectWeapons", Description = "Collect {target} weapon pickups", Difficulty = "Medium", Target = 5, Reward = REWARDS.Medium },
}

QuestConfig.DailyQuestCount = 3

function QuestConfig.FormatDescription(quest: QuestDefinition): string
	return string.gsub(quest.Description, "{target}", tostring(quest.Target))
end

return QuestConfig
