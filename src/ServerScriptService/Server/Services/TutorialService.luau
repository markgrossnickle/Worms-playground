--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local PlayerDataService

local TutorialService = Knit.CreateService({
	Name = "TutorialService",
	Client = {},
})

function TutorialService.Client:HasCompletedTutorial(player: Player): boolean
	local ok, value = pcall(function()
		return PlayerDataService:Read(player, { "HasCompletedTutorial" })
	end)
	if ok and value == true then
		return true
	end
	return false
end

function TutorialService.Client:CompleteTutorial(player: Player)
	pcall(function()
		PlayerDataService:Write(player, { "HasCompletedTutorial" }, true)
	end)
end

function TutorialService:KnitInit() end

function TutorialService:KnitStart()
	PlayerDataService = Knit.GetService("PlayerDataService")
end

return TutorialService
