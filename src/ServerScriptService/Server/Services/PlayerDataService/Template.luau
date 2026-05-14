--!strict
--[=[
	@class PlayerData
	@server
]=]

export type QuestState = {
	Type: string,
	Target: number,
	Progress: number,
	Completed: boolean,
	Reward: number,
	Description: string,
}

export type DailyQuestData = {
	Date: string,
	Quests: { QuestState },
}

export type PlayerData = {
	Coins: number,
	XP: number,
	Level: number,
	LastLoginDate: string,
	LoginStreak: number,
	HasCompletedTutorial: boolean,
	Milestones: {
		FirstJoin: boolean,
		FirstWin: boolean,
		FirstPurchase: boolean,
		ReachedLevel5: boolean,
		ReachedLevel10: boolean,
	},
	DailyQuests: DailyQuestData,
}

local playerDataTemplate: PlayerData = {
	Coins = 0,
	XP = 0,
	Level = 1,
	LastLoginDate = "",
	LoginStreak = 0,
	HasCompletedTutorial = false,
	Milestones = {
		FirstJoin = false,
		FirstWin = false,
		FirstPurchase = false,
		ReachedLevel5 = false,
		ReachedLevel10 = false,
	},
}

return playerDataTemplate
