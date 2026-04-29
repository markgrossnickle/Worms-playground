local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- Ghost mode forces first-person camera by setting
-- `LocalPlayer.CameraMode = LockFirstPerson`. That in turn makes Roblox pin
-- `UserInputService.MouseBehavior = LockCenter`, which glues the cursor to
-- screen center — so even after `MouseIconEnabled = true` puts the sprite
-- back on screen, the cursor won't actually MOVE.
--
-- To genuinely hand control back (e.g. to click the Studio script profiler)
-- we have to break all three: release the camera lock, reset MouseBehavior,
-- and re-enable the icon. The next time ghost mode changes state it will
-- re-apply its own overrides, so this is a one-shot escape.
return {
	Name = "show-mouse",
	Aliases = { "mouse", "cursor" },
	Description = "Fully unlock the mouse (restores cursor visibility, movement, and releases first-person lock)",
	Group = "group",
	Args = {},
	ClientRun = function(_context)
		UserInputService.MouseIconEnabled = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		local localPlayer = Players.LocalPlayer
		if localPlayer then
			localPlayer.CameraMode = Enum.CameraMode.Classic
		end
		return "Mouse unlocked (icon + behavior + camera mode)"
	end,
}
