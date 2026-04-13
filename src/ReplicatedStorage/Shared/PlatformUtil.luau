--!strict

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local PlatformUtil = {}

PlatformUtil.IsTouchDevice = UserInputService.TouchEnabled
PlatformUtil.IsConsole = GuiService:IsTenFootInterface()
PlatformUtil.IsGamepad = PlatformUtil.IsConsole or (#UserInputService:GetConnectedGamepads() > 0)
PlatformUtil.IsDesktop = not PlatformUtil.IsTouchDevice and not PlatformUtil.IsConsole

-- VFX scale factor: 50% reduction on mobile devices
PlatformUtil.ParticleScale = if PlatformUtil.IsTouchDevice then 0.5 else 1.0

-- Returns platform-appropriate action label
function PlatformUtil.ActionLabel(desktop: string, touch: string, gamepad: string?): string
	if PlatformUtil.IsTouchDevice then
		return touch
	elseif PlatformUtil.IsConsole then
		return gamepad or desktop
	end
	return desktop
end

-- Returns minimum touch-friendly size (48px minimum on touch devices)
function PlatformUtil.MinTouchSize(desktopSize: number): number
	if PlatformUtil.IsTouchDevice then
		return math.max(desktopSize, 48)
	end
	return desktopSize
end

return PlatformUtil
