--!strict
--[=[
	@class PlayerData
	@server
]=]

export type PlayerData = {
	Coins: number,
	XP: number,
	Level: number,
	Milestones: {
		FirstJoin: boolean,
		FirstWin: boolean,
		FirstPurchase: boolean,
		ReachedLevel5: boolean,
		ReachedLevel10: boolean,
	},
}

local playerDataTemplate: PlayerData = {
	Coins = 0,
	XP = 0,
	Level = 1,
	Milestones = {
		FirstJoin = false,
		FirstWin = false,
		FirstPurchase = false,
		ReachedLevel5 = false,
		ReachedLevel10 = false,
	},
}

return playerDataTemplate
