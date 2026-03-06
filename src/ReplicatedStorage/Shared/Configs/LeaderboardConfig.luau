--!strict

--[[
	LeaderboardConfig — Define your leaderboard properties here.

	Each property represents a stat that players compete on (e.g., Score, Kills, Level).
	For each property, enable the time periods you want leaderboards for:
		- AllTime:  Permanent, never resets
		- Monthly:  Resets at the start of each calendar month (UTC)
		- Weekly:   Resets every 7 days (Unix epoch weeks)
		- Daily:    Resets at midnight UTC each day

	Example: A "Kills" property with AllTime and Weekly:
		Kills = {
			Name = "Total Kills",   -- Display name shown in UI
			Periods = {
				AllTime = true,
				Monthly = false,
				Weekly = true,
				Daily = false,
			},
		},
]]

return {
	Properties = {
		-- TODO: Replace these placeholders with your game's leaderboard properties.
		-- The key (e.g., "Score1") is used internally for DataStore names and API calls.
		-- The Name field is the human-readable display name.

		Score1 = {
			Name = "Score",
			Periods = {
				AllTime = true,
				Monthly = false,
				Weekly = true,
				Daily = false,
			},
		},
		Score2 = {
			Name = "Level",
			Periods = {
				AllTime = true,
				Monthly = false,
				Weekly = false,
				Daily = false,
			},
		},
		GhostKills = {
			Name = "Ghost Kills",
			Periods = {
				AllTime = true,
				Monthly = false,
				Weekly = true,
				Daily = false,
			},
		},
		RideTime = {
			Name = "Ride Time",
			Periods = {
				AllTime = true,
				Monthly = false,
				Weekly = true,
				Daily = false,
			},
		},
	},
}
