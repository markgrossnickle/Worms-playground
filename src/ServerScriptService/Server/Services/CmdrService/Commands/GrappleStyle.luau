--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GrappleStyles = require(ReplicatedStorage.Shared.GrappleStyles)

return {
	Name = "grapple-style",
	Aliases = { "grapple", "gs" },
	Description = "Switch the grapple feel preset. Valid: " .. table.concat(GrappleStyles.names(), ", "),
	Group = "group",
	Args = {
		{
			Type = "string",
			Name = "style",
			Description = "classic | elastic | zipline | yeet | chain",
		},
	},
}
