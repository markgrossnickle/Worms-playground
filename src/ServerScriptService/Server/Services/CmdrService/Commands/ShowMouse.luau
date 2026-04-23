local UserInputService = game:GetService("UserInputService")

-- Ghost mode flips MouseIconEnabled to false (WormUIController wires it to
-- `not inGhost`). In Studio that makes it awkward to reach toolbar buttons
-- like the script profiler without Esc'ing out. This command forces the
-- cursor back on without touching ghost state. The next worm state change
-- may flip it back off, but that's usually enough to click whatever you
-- needed to click.
return {
	Name = "show-mouse",
	Aliases = { "mouse", "cursor" },
	Description = "Force UserInputService.MouseIconEnabled = true (useful in Studio during ghost mode)",
	Group = "group",
	Args = {},
	ClientRun = function(_context)
		UserInputService.MouseIconEnabled = true
		return "Mouse icon enabled"
	end,
}
