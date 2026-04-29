--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GrappleStyles = require(ReplicatedStorage.Shared.GrappleStyles)

return function(_context, style: string)
	local lower = string.lower(style)
	if not GrappleStyles.Styles[lower] then
		return "Unknown style '" .. style .. "'. Valid: " .. table.concat(GrappleStyles.names(), ", ")
	end
	GrappleStyles.setCurrent(lower)
	local preset = GrappleStyles.get(lower)
	return "Grapple style → " .. lower .. " (" .. preset.Description .. ")"
end
