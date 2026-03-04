--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local PlayerDataService -- Set in KnitStart

local DAILY_LOGIN_REWARD = 50
local STREAK_BONUS_DAY = 7
local STREAK_BONUS_AMOUNT = 200

local CoinService = Knit.CreateService({
	Name = "CoinService",
	Client = {
		CoinsChanged = Knit.CreateSignal(),
		DailyReward = Knit.CreateSignal(), -- fires (coins, streak, isBonus)
	},
})

function CoinService:AwardCoins(player: Player, amount: number)
	local currentCoins = PlayerDataService:Read(player, { "Coins" })
	if currentCoins == nil then
		currentCoins = 0
	end
	local newCoins = currentCoins + amount
	PlayerDataService:Write(player, { "Coins" }, newCoins)
	self.Client.CoinsChanged:Fire(player, newCoins)
end

function CoinService:GetCoins(player: Player): number
	local coins = PlayerDataService:Read(player, { "Coins" })
	return if coins then coins else 0
end

function CoinService.Client:GetCoins(player: Player): number
	return self.Server:GetCoins(player)
end

function CoinService:_checkDailyLogin(player: Player)
	local today = os.date("!%Y-%m-%d")
	local lastLogin = PlayerDataService:Read(player, { "LastLoginDate" })
	local streak = PlayerDataService:Read(player, { "LoginStreak" })

	if lastLogin == nil then
		lastLogin = ""
	end
	if streak == nil then
		streak = 0
	end

	if lastLogin == today then
		return -- Already logged in today
	end

	-- Check if yesterday (consecutive day)
	local todayTime = os.time({
		year = tonumber(os.date("!%Y")),
		month = tonumber(os.date("!%m")),
		day = tonumber(os.date("!%d")),
		hour = 0,
		min = 0,
		sec = 0,
	})
	local yesterdayStr = os.date("!%Y-%m-%d", todayTime - 86400)

	local newStreak
	if lastLogin == yesterdayStr then
		newStreak = streak + 1
	else
		newStreak = 1
	end

	-- Award daily coins
	self:AwardCoins(player, DAILY_LOGIN_REWARD)

	-- Check streak bonus
	local isBonus = false
	if newStreak >= STREAK_BONUS_DAY then
		self:AwardCoins(player, STREAK_BONUS_AMOUNT)
		newStreak = 0
		isBonus = true
	end

	-- Update login data
	PlayerDataService:Write(player, { "LastLoginDate" }, today)
	PlayerDataService:Write(player, { "LoginStreak" }, newStreak)

	-- Notify client
	self.Client.DailyReward:Fire(player, DAILY_LOGIN_REWARD, newStreak, isBonus)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function CoinService:KnitInit() end

function CoinService:KnitStart()
	PlayerDataService = Knit.GetService("PlayerDataService")

	-- Check daily login for each player when their profile is ready
	PlayerDataService.ProfileReady:Connect(function(player: Player)
		task.spawn(function()
			-- Small delay to ensure profile is fully loaded
			task.wait(1)
			if player.Parent then
				self:_checkDailyLogin(player)
			end
		end)
	end)

	-- Handle existing players (Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			PlayerDataService:WaitForProfile(player)
				:andThen(function()
					task.wait(1)
					if player.Parent then
						self:_checkDailyLogin(player)
					end
				end)
				:catch(function(err)
					warn("CoinService: Failed to check daily login for", player.Name, err)
				end)
		end)
	end
end

return CoinService
