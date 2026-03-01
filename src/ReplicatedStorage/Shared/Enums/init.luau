--!strict

local Environment = require(script.Environment)
local WormState = require(script.WormState)

local Enums = {
	Environment = Environment,
	WormState = WormState,
}

export type Enums = typeof(Enums)

export type Environment = Environment.Environment
export type WormState = WormState.WormState

return Enums
