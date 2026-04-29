--!strict
-- Minimal easing library for manually-lerped animations (e.g. server-side worm
-- grapple pulls where we compute alpha ourselves instead of using TweenService).
-- All functions take `t` ∈ [0, 1] and return eased output (usually in [0, 1],
-- except overshoot easings like Back which can briefly exceed the range).
--
-- Curves match the canonical easings.net / TweenService Enum.EasingStyle set.

local Easings = {}

function Easings.linear(t: number): number
	return t
end

function Easings.quadIn(t: number): number
	return t * t
end

function Easings.quadOut(t: number): number
	local u = 1 - t
	return 1 - u * u
end

function Easings.cubicIn(t: number): number
	return t * t * t
end

function Easings.cubicOut(t: number): number
	local u = 1 - t
	return 1 - u * u * u
end

function Easings.cubicInOut(t: number): number
	if t < 0.5 then
		return 4 * t * t * t
	end
	local u = -2 * t + 2
	return 1 - (u * u * u) / 2
end

function Easings.quartIn(t: number): number
	return t * t * t * t
end

function Easings.quartOut(t: number): number
	local u = 1 - t
	return 1 - u * u * u * u
end

function Easings.sineOut(t: number): number
	return math.sin((t * math.pi) / 2)
end

-- Back easings overshoot by ~10% before settling at 1.0 (Out) or from 0.0 (In).
-- Great for "yank" and "elastic" feels where the pull briefly goes past the target.
function Easings.backIn(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	return c3 * t * t * t - c1 * t * t
end

function Easings.backOut(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	local u = t - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

return Easings
