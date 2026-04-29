--!strict
-- GrappleStyles — 5 grapple "feel" presets selectable at runtime.
--
-- Switch via cmdr: `grapple-style <name>` (classic | elastic | zipline | yeet | chain).
-- The current style is stored on ReplicatedStorage as a string attribute and
-- replicates automatically to clients. Both WormService (server) and
-- WormController (client) read the current preset each time a grapple fires,
-- so switching takes effect on the very next right-click.
--
-- Each preset drives:
--   * Phase durations: Fire (hook fly-out) → Pull (lerp to target) → Fling (post-pull ballistic)
--   * Easings for Snap (CurveSize → 0) and Pull (startPos → targetPos)
--   * Rope visuals: color, widths, sag factor
--   * Camera feedback: FOV punch, shake magnitude
--   * Particle burst counts at each endpoint
--
-- FlingFactor ∈ [0, 1.5] — fraction of pull-phase peak velocity preserved into
-- the post-target ballistic phase. 0 = stop dead at target, 1 = continue at
-- pull speed for FlingDuration, decaying exponentially. >1 = launch-pad feel.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Easings = require(ReplicatedStorage.Shared.Easings)

export type GrappleStyle = {
	Description: string,

	-- Phase durations (seconds)
	FireDuration: number, -- hook fly-out
	PullDuration: number, -- lerp from start to target
	FlingDuration: number, -- ballistic post-target overshoot

	-- Post-pull momentum (0 = no overshoot, 1 = continue at peak speed, >1 = launch)
	FlingFactor: number,

	-- Visual — rope
	Color: Color3,
	WidthFire: number, -- beam width during fire phase
	WidthPull: number, -- beam width during pull phase
	SagFactor: number, -- CurveSize magnitude = SagFactor * ropeLength (scales with distance)

	-- Easings (functions from Easings module)
	SnapEasing: (number) -> number, -- CurveSize slack → 0 on impact
	PullEasing: (number) -> number, -- startPos → targetPos

	-- Camera feedback
	ShakeMagnitude: number, -- peak rotational offset in degrees-ish (roughly 0.01 rad per unit)
	ShakeDuration: number,
	FovPunch: number, -- FOV add during snap (max Δ from default)

	-- Particle burst counts
	AnchorBurst: number,
	WormBurst: number,

	-- Post-pull oscillation (elastic mode only — rope wiggles before detaching)
	PostPullWiggleCount: number?,
}

local GrappleStyles = {}

GrappleStyles.DEFAULT = "classic"

GrappleStyles.Styles = {} :: { [string]: GrappleStyle }

-- 1. Balanced physical rope — the "default" grapple feel.
GrappleStyles.Styles.classic = {
	Description = "Balanced — sag, snap, modest fling. Physical rope feel.",
	FireDuration = 0.20,
	PullDuration = 0.50,
	FlingDuration = 0.30,
	FlingFactor = 0.50,
	Color = Color3.fromRGB(0, 200, 255),
	WidthFire = 0.6,
	WidthPull = 0.4,
	SagFactor = 0.18,
	SnapEasing = Easings.quartIn,
	PullEasing = Easings.quartOut,
	ShakeMagnitude = 4,
	ShakeDuration = 0.4,
	FovPunch = 12,
	AnchorBurst = 20,
	WormBurst = 15,
}

-- 2. Bungee cord — overshoots target then bounces back, no fling, subtle wiggle.
GrappleStyles.Styles.elastic = {
	Description = "Bungee — overshoots then settles. Rubbery.",
	FireDuration = 0.15,
	PullDuration = 0.55,
	FlingDuration = 0, -- no fling — the overshoot IS the Back-easing on pull
	FlingFactor = 0,
	Color = Color3.fromRGB(120, 255, 120),
	WidthFire = 0.5,
	WidthPull = 0.5,
	SagFactor = 0.12,
	SnapEasing = Easings.cubicOut,
	PullEasing = Easings.backOut, -- overshoots 1.0 around t=0.7 then settles
	ShakeMagnitude = 2,
	ShakeDuration = 0.3,
	FovPunch = 8,
	AnchorBurst = 12,
	WormBurst = 10,
	PostPullWiggleCount = 3, -- rope wiggles 3x before detaching
}

-- 3. Industrial cable — minimal sag, mechanical constant-speed pull, no fling.
GrappleStyles.Styles.zipline = {
	Description = "Industrial — taut cable, linear constant-speed pull.",
	FireDuration = 0.10,
	PullDuration = 0.40,
	FlingDuration = 0.15,
	FlingFactor = 0.20,
	Color = Color3.fromRGB(255, 200, 80),
	WidthFire = 0.30,
	WidthPull = 0.30,
	SagFactor = 0.04, -- nearly straight
	SnapEasing = Easings.quadOut,
	PullEasing = Easings.linear,
	ShakeMagnitude = 2,
	ShakeDuration = 0.25,
	FovPunch = 8,
	AnchorBurst = 10,
	WormBurst = 5,
}

-- 4. Launch pad — short hard pull, massive fling past the target.
GrappleStyles.Styles.yeet = {
	Description = "YEET — short pull, massive overshoot. Launch-pad feel.",
	FireDuration = 0.15,
	PullDuration = 0.25,
	FlingDuration = 0.70,
	FlingFactor = 1.20, -- worm continues faster than pull speed
	Color = Color3.fromRGB(255, 60, 200),
	WidthFire = 0.80,
	WidthPull = 0.20,
	SagFactor = 0.22,
	SnapEasing = Easings.quartIn,
	PullEasing = Easings.backIn, -- slams into the target
	ShakeMagnitude = 8,
	ShakeDuration = 0.5,
	FovPunch = 22,
	AnchorBurst = 30,
	WormBurst = 25,
}

-- 5. Heavy chain — deep sag, slow cubic-inout pull, weighty feel.
GrappleStyles.Styles.chain = {
	Description = "Heavy chain — deep sag, slow pull, weighty fling.",
	FireDuration = 0.30,
	PullDuration = 0.80,
	FlingDuration = 0.40,
	FlingFactor = 0.35,
	Color = Color3.fromRGB(200, 80, 60),
	WidthFire = 1.20,
	WidthPull = 0.80,
	SagFactor = 0.32,
	SnapEasing = Easings.cubicIn,
	PullEasing = Easings.cubicInOut,
	ShakeMagnitude = 6,
	ShakeDuration = 0.5,
	FovPunch = 10,
	AnchorBurst = 25,
	WormBurst = 20,
}

-- List of valid style names, for cmdr argument validation + error messages.
function GrappleStyles.names(): { string }
	local out = {}
	for name in GrappleStyles.Styles do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- Fetch a style by name, falling back to the default if unknown/nil.
function GrappleStyles.get(name: string?): GrappleStyle
	if name and GrappleStyles.Styles[name] then
		return GrappleStyles.Styles[name]
	end
	return GrappleStyles.Styles[GrappleStyles.DEFAULT]
end

-- Read the currently-active style from the replicated attribute on
-- ReplicatedStorage. Both server and client use this so they never disagree.
function GrappleStyles.getCurrent(): GrappleStyle
	local name = ReplicatedStorage:GetAttribute("GrappleStyle")
	return GrappleStyles.get(if type(name) == "string" then name else nil)
end

-- Server-only: set the active style. Replicates automatically via the attribute.
function GrappleStyles.setCurrent(name: string)
	if not GrappleStyles.Styles[name] then
		error("Unknown grapple style: " .. tostring(name))
	end
	ReplicatedStorage:SetAttribute("GrappleStyle", name)
end

return GrappleStyles
