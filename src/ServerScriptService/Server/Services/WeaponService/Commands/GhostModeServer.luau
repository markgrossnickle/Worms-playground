--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

return function(context)
	local player = context.Executor
	local WormService = Knit.GetService("WormService")

	local wormData = WormService:GetWormData_Server(player)
	if not wormData then
		return "No worm data found for " .. player.Name
	end

	-- If alive, kill the worm so it can transition to ghost
	if wormData.State == "Alive" then
		WormService:_killWorm(player, nil, nil)
	end

	WormService:SpawnGhost(player)
	return "Ghost mode entered"
end
