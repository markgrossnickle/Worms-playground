--!strict

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local PlatformUtil = require(ReplicatedStorage.Shared.PlatformUtil)
local TeamBase = require(ReplicatedStorage.Shared.TeamBase)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local PERIODIC_UPDATE_INTERVAL = 2
local KILL_FEED_DURATION = 4
local MAX_KILL_FEED = 5

-- Crown carry offset (studs above carrier head). Must match the value in
-- CrownService on the server. While the Crown is Carried we position it on
-- the client every frame so it follows the head smoothly without 10Hz jitter.
local CROWN_CARRY_OFFSET_Y = 4.5

-- Vertical offset to add to top-anchored HUD elements so they clear the Roblox
-- topbar (and the iPhone/Android notch area). ScreenGui has IgnoreGuiInset=true
-- so (0,0,0,0) is the absolute top-left of the screen; GetGuiInset().Y returns
-- the reserved topbar height (~36pt, larger on notch devices).
local TOP_INSET = GuiService:GetGuiInset().Y

local POWERUP_COLORS = {
	SPEED = Color3.fromRGB(0, 200, 255),
	SPEED_BURST = Color3.fromRGB(255, 140, 0),
	MAGNET = Color3.fromRGB(255, 0, 200),
	GHOST = Color3.fromRGB(200, 200, 255),
	SHIELD = Color3.fromRGB(255, 220, 0),
	SIZE_BOMB = Color3.fromRGB(255, 80, 0),
	FREEZE_RING = Color3.fromRGB(100, 180, 255),
}

local WormUIController = Knit.CreateController({
	Name = "WormUIController",

	_trove = nil :: any,
	_screenGui = nil :: ScreenGui?,
	_segmentLabel = nil :: TextLabel?,
	_deathFrame = nil :: Frame?,
	_deathLabel = nil :: TextLabel?,
	_killFeedFrame = nil :: Frame?,
	_minimapFrame = nil :: Frame?,
	_minimapArrow = nil :: Frame?,
	_boostButton = nil :: ImageButton?,
	_grappleButton = nil :: ImageButton?,
	_powerUpFrame = nil :: Frame?,
	_powerUpLabel = nil :: TextLabel?,
	_powerUpTimer = nil :: TextLabel?,
	_gameTimerLabel = nil :: TextLabel?,
	_zoneWarningLabel = nil :: TextLabel?,
	_shrinkCircle = nil :: Frame?,
	_wormService = nil :: any,
	_wormController = nil :: any,
	_powerUpService = nil :: any,
	_currentZoneRadius = WormConfig.ArenaSize / 2,
	_activePowerUpEnd = 0,

	-- Ghost mode toggle
	_ghostToggleBtn = nil :: TextButton?,
	_crosshairFrame = nil :: Frame?,

	-- Round UI elements
	_statsLabel = nil :: TextLabel?,
	_spectateSection = nil :: Frame?,
	_spectateLabel = nil :: TextLabel?,
	_spectateButtonPrev = nil :: TextButton?,
	_spectateButtonNext = nil :: TextButton?,
	_finalScoreboardFrame = nil :: Frame?,
	_scoreboardList = nil :: Frame?,
	_scoreboardWinner = nil :: TextLabel?,
	_countdownFrame = nil :: Frame?,
	_countdownLabel = nil :: TextLabel?,

	-- Coin display
	_coinLabel = nil :: TextLabel?,
	_coinService = nil :: any,

	-- Ghost toolbar
	_toolbarFrame = nil :: Frame?,
	_grappleSlot = nil :: TextButton?,
	_grappleHint = nil :: TextLabel?,
	_grappleSlotStroke = nil :: UIStroke?,
	_weaponSlotLabel = nil :: TextLabel?,
	_weaponSlotAmmo = nil :: TextLabel?,
	_weaponSlotStroke = nil :: UIStroke?,
	_weaponController = nil :: any,
	_maxAmmo = 0,

	-- Rider notification (shown to worm player when a ghost rides them)
	_riderNotifyLabel = nil :: TextLabel?,

	-- Worm King: Marks HUD + respawn button (ghost mode)
	_marksService = nil :: any,
	_ghostHudFrame = nil :: Frame?,
	_marksLabel = nil :: TextLabel?,
	_respawnBtn = nil :: TextButton?,
	_respawnStatusLbl = nil :: TextLabel?,
	_currentMarks = 0,

	-- Worm King: match timer + lockdown banner
	_roundService = nil :: any,
	_matchTimerFrame = nil :: Frame?,
	_matchTimerLabel = nil :: TextLabel?,
	_matchTimerStroke = nil :: UIStroke?,
	_lockdownBanner = nil :: Frame?,
	_lockdownLabel = nil :: TextLabel?,
	_matchPhase = "Active",

	-- Worm King: sand tide state (cached scale broadcast from SandTideService)
	_sandTideService = nil :: any,
	_sandTideScale = 1.0,
	_teamModeActive = false, -- true when the round is a Worm King (team) match
})

--------------------------------------------------
-- UI construction helpers
--------------------------------------------------

local function createTextLabel(props: {
	Name: string,
	Text: string,
	Size: UDim2,
	Position: UDim2,
	AnchorPoint: Vector2?,
	TextSize: number?,
	TextColor3: Color3?,
	BackgroundTransparency: number?,
	BackgroundColor3: Color3?,
	Font: Enum.Font?,
	Parent: GuiObject?,
	TextXAlignment: Enum.TextXAlignment?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.Name
	label.Text = props.Text
	label.Size = props.Size
	label.Position = props.Position
	label.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	label.TextSize = props.TextSize or 18
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1
	label.BackgroundColor3 = props.BackgroundColor3 or Color3.new(0, 0, 0)
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center
	label.BorderSizePixel = 0
	label.Parent = props.Parent
	return label
end

--------------------------------------------------
-- Build UI
--------------------------------------------------

function WormUIController:_buildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WormUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui
	self._screenGui = gui

	self:_buildSegmentCounter(gui)
	self:_buildDeathScreen(gui)
	self:_buildKillFeed(gui)
	self:_buildMinimap(gui)
	self:_buildBoostButton(gui)
	self:_buildGrappleButton(gui)
	self:_buildPowerUpDisplay(gui)
	self:_buildGameTimer(gui)
	self:_buildZoneWarning(gui)
	self:_buildFinalScoreboard(gui)
	self:_buildCountdownOverlay(gui)
	self:_buildCoinDisplay(gui)
	self:_buildCrosshair(gui)
	self:_buildToolbar(gui)
	self:_buildRiderNotification(gui)
	self:_buildTeamScoreHUD(gui)
	self:_buildCrownCarrierBanner(gui)
	self:_buildGhostHud(gui)
	self:_buildMatchTimerHUD(gui)
	self:_buildLockdownBanner(gui)
end

-- Worm King: large countdown clock at top-left (out of the SegmentCounter's way).
-- Red-glow when ≤ 60s remain; border turns red during Lockdown.
function WormUIController:_buildMatchTimerHUD(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "MatchTimer"
	frame.Size = UDim2.new(0, 110, 0, 44)
	frame.Position = UDim2.new(0, 10, 0, 10 + TOP_INSET)
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 4
	frame.Parent = parent
	self._matchTimerFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(140, 180, 255)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = frame
	self._matchTimerStroke = stroke

	local lbl = createTextLabel({
		Name = "Clock",
		Text = "8:00",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.fromScale(0, 0),
		TextSize = 26,
		TextColor3 = Color3.fromRGB(235, 240, 255),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
	lbl.ZIndex = 5
	self._matchTimerLabel = lbl
end

-- Worm King: full-width banner shown below the team score chips when lockdown begins.
function WormUIController:_buildLockdownBanner(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "LockdownBanner"
	-- Width is 95% of screen up to a max of 420pt so the banner shrinks on
	-- narrow screens (e.g. iPhone SE at 375pt) instead of bleeding off-edge.
	frame.Size = UDim2.new(0.95, 0, 0, 34)
	frame.Position = UDim2.new(0.5, 0, 0, 120 + TOP_INSET)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(160, 30, 30)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 4
	frame.Parent = parent
	self._lockdownBanner = frame

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(420, math.huge)
	sizeConstraint.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 200, 200)
	stroke.Thickness = 1.4
	stroke.Transparency = 0.1
	stroke.Parent = frame

	local lbl = createTextLabel({
		Name = "Text",
		Text = "⚠ LOCKDOWN — LAST TEAM STANDING WINS ⚠",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
	lbl.ZIndex = 5
	self._lockdownLabel = lbl
end

-- Update match timer text + color based on remaining seconds.
function WormUIController:_updateMatchTimer(remaining: number, phase: string)
	if not self._matchTimerFrame then
		return
	end
	self._matchTimerFrame.Visible = true
	self._matchPhase = phase

	if self._matchTimerLabel then
		local total = math.max(0, math.floor(remaining + 0.5))
		local mins = math.floor(total / 60)
		local secs = total % 60
		self._matchTimerLabel.Text = string.format("%d:%02d", mins, secs)

		-- Color urgency: last 60s = red, last 10s = flashing red
		if remaining <= 10 then
			self._matchTimerLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		elseif remaining <= 60 or phase == "Lockdown" then
			self._matchTimerLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
		else
			self._matchTimerLabel.TextColor3 = Color3.fromRGB(235, 240, 255)
		end
	end

	if self._matchTimerStroke then
		self._matchTimerStroke.Color = if phase == "Lockdown"
			then Color3.fromRGB(255, 140, 140)
			else Color3.fromRGB(140, 180, 255)
	end

	-- Lockdown banner visibility toggles with phase
	if self._lockdownBanner then
		self._lockdownBanner.Visible = (phase == "Lockdown")
	end
end

function WormUIController:_hideMatchTimer()
	if self._matchTimerFrame then
		self._matchTimerFrame.Visible = false
	end
	if self._lockdownBanner then
		self._lockdownBanner.Visible = false
	end
end

-- Worm King: compact widget at top-center showing Marks + Respawn button.
-- Visible whenever the local player is a ghost OR on the death screen.
function WormUIController:_buildGhostHud(parent: ScreenGui)
	-- GhostHud sits below the CrownCarrierBanner (banner is 32px tall at y=130,
	-- so start this frame at y=175 to leave a 13px gap). Internal layout:
	--   marks (24) + gap(4) + respawn button (btnH) + gap(4) + status (18)
	-- so total = 54 + btnH. Height grows on touch for the 48pt button.
	local btnHeight = PlatformUtil.MinTouchSize(32)
	local ghostHudHeight = 54 + btnHeight
	local frame = Instance.new("Frame")
	frame.Name = "GhostHud"
	frame.Size = UDim2.new(0, 260, 0, ghostHudHeight)
	frame.Position = UDim2.new(0.5, 0, 0, 175 + TOP_INSET)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 4
	frame.Parent = parent
	self._ghostHudFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 180, 255)
	stroke.Thickness = 1.2
	stroke.Transparency = 0.4
	stroke.Parent = frame

	-- Marks counter (top row)
	local marksLabel = createTextLabel({
		Name = "Marks",
		Text = "★ 0 Marks",
		Size = UDim2.new(1, -16, 0, 24),
		Position = UDim2.new(0, 8, 0, 4),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 220, 100),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	marksLabel.ZIndex = 5
	self._marksLabel = marksLabel

	-- Respawn button. Apple HIG + Google Material both recommend a 44–48pt
	-- minimum touch target; MinTouchSize(32) gives 32pt on desktop and 48pt on
	-- touch so finger taps don't miss. Uses btnHeight computed at frame-level.
	local btn = Instance.new("TextButton")
	btn.Name = "RespawnBtn"
	btn.Size = UDim2.new(1, -16, 0, btnHeight)
	btn.Position = UDim2.new(0, 8, 0, 32)
	btn.AnchorPoint = Vector2.new(0, 0)
	btn.BackgroundColor3 = Color3.fromRGB(40, 140, 70)
	btn.BackgroundTransparency = 0.15
	btn.BorderSizePixel = 0
	btn.Text = string.format("Respawn as Worm (%d Marks)", WormConfig.WormKing.RespawnCost)
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 16
	btn.Font = Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.ZIndex = 5
	btn.Parent = frame

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 8)
	btnCorner.Parent = btn

	self._respawnBtn = btn

	-- Reason/status line (shown under button on failure, or during lockout).
	local statusLbl = createTextLabel({
		Name = "Status",
		Text = "",
		Size = UDim2.new(1, -16, 0, 18),
		Position = UDim2.new(0, 8, 1, -20),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(255, 120, 120),
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = frame,
	})
	statusLbl.ZIndex = 5
	self._respawnStatusLbl = statusLbl
end

-- Update text + button enabled state based on current Marks total.
function WormUIController:_updateMarksUI(marks: number)
	self._currentMarks = marks
	if self._marksLabel then
		self._marksLabel.Text = string.format("★ %d Marks", marks)
	end
	if self._respawnBtn then
		local cost = WormConfig.WormKing.RespawnCost
		local canAfford = marks >= cost
		self._respawnBtn.BackgroundColor3 = if canAfford
			then Color3.fromRGB(40, 140, 70)
			else Color3.fromRGB(70, 70, 70)
		self._respawnBtn.AutoButtonColor = canAfford
	end
end

-- Show/hide the ghost hud (called on death, spawn, ghost toggle).
function WormUIController:_setGhostHudVisible(visible: boolean)
	if self._ghostHudFrame then
		self._ghostHudFrame.Visible = visible
	end
	if not visible and self._respawnStatusLbl then
		self._respawnStatusLbl.Text = ""
	end
end

-- Display a brief status line under the respawn button (e.g. "Not enough Marks").
function WormUIController:_showRespawnStatus(text: string, isError: boolean)
	if not self._respawnStatusLbl then
		return
	end
	self._respawnStatusLbl.Text = text
	self._respawnStatusLbl.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(180, 220, 180)
end

-- Worm King: horizontal row of 3 colored team score chips, top center under segment counter.
function WormUIController:_buildTeamScoreHUD(parent: ScreenGui)
	local container = Instance.new("Frame")
	container.Name = "TeamScoreHUD"
	-- 95% of screen width capped at 420pt — 3 team chips (120pt each + 8pt gaps)
	-- fit in 376pt, so on phones narrower than ~396pt this will compress.
	container.Size = UDim2.new(0.95, 0, 0, 44)
	container.Position = UDim2.new(0.5, 0, 0, 70 + TOP_INSET)
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.BackgroundTransparency = 1
	container.Parent = parent
	self._teamScoreHUD = container

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(420, math.huge)
	sizeConstraint.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = container

	self._teamScoreChips = {}
	for i, teamCfg in WormConfig.TeamColors do
		local chip = Instance.new("Frame")
		chip.Name = "ScoreChip_" .. teamCfg.Name
		chip.Size = UDim2.new(0, 120, 0, 40)
		chip.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		chip.BackgroundTransparency = 0.35
		chip.BorderSizePixel = 0
		chip.Parent = container
		chip.LayoutOrder = i

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = chip

		local stroke = Instance.new("UIStroke")
		stroke.Color = teamCfg.Color
		stroke.Thickness = 2
		stroke.Parent = chip

		local nameLbl = createTextLabel({
			Name = "TeamName",
			Text = teamCfg.Name,
			Size = UDim2.new(0.5, -4, 1, 0),
			Position = UDim2.new(0, 6, 0, 0),
			TextSize = 14,
			TextColor3 = teamCfg.Color,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = chip,
		})
		nameLbl.Font = Enum.Font.GothamBold

		local scoreLbl = createTextLabel({
			Name = "Score",
			Text = "0",
			Size = UDim2.new(0.5, -6, 1, 0),
			Position = UDim2.new(0.5, 0, 0, 0),
			TextSize = 22,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = chip,
		})
		scoreLbl.Font = Enum.Font.GothamBold

		self._teamScoreChips[i] = scoreLbl
	end

	-- Threshold caption
	local thresh = createTextLabel({
		Name = "Threshold",
		Text = "First to " .. tostring(WormConfig.WormKing.ScoreThreshold),
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, 2),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = container,
	})
	thresh.Font = Enum.Font.Gotham
end

-- Worm King: banner shown across the top of the screen announcing the Crown carrier.
function WormUIController:_buildCrownCarrierBanner(parent: ScreenGui)
	local banner = Instance.new("Frame")
	banner.Name = "CrownCarrierBanner"
	banner.Size = UDim2.new(0.9, 0, 0, 32)
	banner.Position = UDim2.new(0.5, 0, 0, 130 + TOP_INSET)
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	banner.BackgroundTransparency = 0.4
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.Parent = parent
	self._crownCarrierBanner = banner

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(380, math.huge)
	sizeConstraint.Parent = banner

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = banner

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 220, 60)
	stroke.Thickness = 2
	stroke.Parent = banner

	local label = createTextLabel({
		Name = "CarrierText",
		Text = "",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 220, 60),
		Parent = banner,
	})
	label.Font = Enum.Font.GothamBold
	self._crownCarrierLabel = label
end

function WormUIController:_updateTeamScores(snapshot: { { TeamIndex: number, Score: number } })
	if not self._teamScoreChips then
		return
	end
	for _, entry in snapshot do
		local lbl = self._teamScoreChips[entry.TeamIndex]
		if lbl then
			lbl.Text = tostring(entry.Score)
		end
	end
end

function WormUIController:_updateCrownCarrier(carrierName: string?, isPlayer: boolean?, teamIndex: number?)
	local banner = self._crownCarrierBanner
	local label = self._crownCarrierLabel
	if not banner or not label then
		return
	end

	if not carrierName then
		banner.Visible = false
		return
	end

	local color = Color3.fromRGB(255, 220, 60)
	if teamIndex and teamIndex > 0 and WormConfig.TeamColors[teamIndex] then
		color = WormConfig.TeamColors[teamIndex].Color
	end

	if carrierName == LocalPlayer.Name then
		label.Text = "★ YOU HAVE THE CROWN ★"
		label.TextColor3 = Color3.fromRGB(255, 240, 100)
	else
		local suffix = if isPlayer == false then " (bot)" else ""
		label.Text = string.format("%s has the Crown%s", carrierName, suffix)
		label.TextColor3 = color
	end
	banner.Visible = true
end

function WormUIController:_buildSegmentCounter(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "SegmentCounter"
	frame.Size = UDim2.new(0.15, 0, 0, PlatformUtil.MinTouchSize(50))
	frame.Position = UDim2.new(0.5, 0, 0, 10 + TOP_INSET)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	self._segmentLabel = createTextLabel({
		Name = "Count",
		Text = "Segments: " .. WormConfig.InitialSegments,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 24,
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
end

function WormUIController:_buildDeathScreen(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "DeathScreen"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.4
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._deathFrame = frame

	createTextLabel({
		Name = "Title",
		Text = "YOU DIED",
		Size = UDim2.new(0.6, 0, 0, 60),
		Position = UDim2.fromScale(0.5, 0.3),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 48,
		TextColor3 = Color3.fromRGB(255, 50, 50),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._deathLabel = createTextLabel({
		Name = "Info",
		Text = "",
		Size = UDim2.new(0.6, 0, 0, 40),
		Position = UDim2.fromScale(0.5, 0.38),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 22,
		Parent = frame,
	})

	-- Stats label: "Max Size: N | Kills: N"
	self._statsLabel = createTextLabel({
		Name = "Stats",
		Text = "",
		Size = UDim2.new(0.6, 0, 0, 30),
		Position = UDim2.fromScale(0.5, 0.45),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})

	-- Spectate section
	local spectateSection = Instance.new("Frame")
	spectateSection.Name = "SpectateSection"
	spectateSection.Size = UDim2.new(0.6, 0, 0, 100)
	spectateSection.Position = UDim2.fromScale(0.5, 0.58)
	spectateSection.AnchorPoint = Vector2.new(0.5, 0.5)
	spectateSection.BackgroundTransparency = 1
	spectateSection.BorderSizePixel = 0
	spectateSection.Parent = frame
	self._spectateSection = spectateSection

	createTextLabel({
		Name = "SpectateTitle",
		Text = "SPECTATING",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(150, 150, 150),
		Parent = spectateSection,
	})

	self._spectateLabel = createTextLabel({
		Name = "TargetName",
		Text = "---",
		Size = UDim2.new(0.5, 0, 0, 30),
		Position = UDim2.fromScale(0.5, 0.3),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 22,
		TextColor3 = Color3.fromRGB(255, 255, 100),
		Parent = spectateSection,
	})

	-- Prev button (48px min height for touch)
	local specBtnH = PlatformUtil.MinTouchSize(30)
	local prevBtn = Instance.new("TextButton")
	prevBtn.Name = "PrevBtn"
	prevBtn.Size = UDim2.new(0, PlatformUtil.MinTouchSize(60), 0, specBtnH)
	prevBtn.Position = UDim2.new(0.3, 0, 1, -5)
	prevBtn.AnchorPoint = Vector2.new(0.5, 1)
	prevBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	prevBtn.BackgroundTransparency = 0.3
	prevBtn.BorderSizePixel = 0
	prevBtn.Text = "< Prev"
	prevBtn.TextColor3 = Color3.new(1, 1, 1)
	prevBtn.TextSize = 14
	prevBtn.Font = Enum.Font.GothamBold
	prevBtn.Parent = spectateSection
	self._spectateButtonPrev = prevBtn

	local prevCorner = Instance.new("UICorner")
	prevCorner.CornerRadius = UDim.new(0, 6)
	prevCorner.Parent = prevBtn

	-- Next button (48px min height for touch)
	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "NextBtn"
	nextBtn.Size = UDim2.new(0, PlatformUtil.MinTouchSize(60), 0, specBtnH)
	nextBtn.Position = UDim2.new(0.7, 0, 1, -5)
	nextBtn.AnchorPoint = Vector2.new(0.5, 1)
	nextBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	nextBtn.BackgroundTransparency = 0.3
	nextBtn.BorderSizePixel = 0
	nextBtn.Text = "Next >"
	nextBtn.TextColor3 = Color3.new(1, 1, 1)
	nextBtn.TextSize = 14
	nextBtn.Font = Enum.Font.GothamBold
	nextBtn.Parent = spectateSection
	self._spectateButtonNext = nextBtn

	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UDim.new(0, 6)
	nextCorner.Parent = nextBtn

	-- Ghost mode toggle button (48px min height for touch)
	local ghostBtn = Instance.new("TextButton")
	ghostBtn.Name = "GhostToggle"
	ghostBtn.Size = UDim2.new(0, PlatformUtil.MinTouchSize(180), 0, PlatformUtil.MinTouchSize(36))
	ghostBtn.Position = UDim2.fromScale(0.5, 0.72)
	ghostBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	ghostBtn.BackgroundColor3 = Color3.fromRGB(80, 100, 160)
	ghostBtn.BackgroundTransparency = 0.2
	ghostBtn.BorderSizePixel = 0
	ghostBtn.Text = "Enter Ghost Mode"
	ghostBtn.TextColor3 = Color3.fromRGB(180, 200, 255)
	ghostBtn.TextSize = 16
	ghostBtn.Font = Enum.Font.GothamBold
	ghostBtn.Parent = frame
	self._ghostToggleBtn = ghostBtn

	local ghostCorner = Instance.new("UICorner")
	ghostCorner.CornerRadius = UDim.new(0, 8)
	ghostCorner.Parent = ghostBtn
end

function WormUIController:_buildKillFeed(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "KillFeed"
	frame.Size = UDim2.new(0.2, 0, 0, MAX_KILL_FEED * 28)
	frame.Position = UDim2.new(0, 10, 0, 60)
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = parent
	self._killFeedFrame = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame
end

function WormUIController:_buildMinimap(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Minimap"
	frame.Size = UDim2.new(0, 140, 0, 140)
	frame.Position = UDim2.new(1, -10, 1, -10)
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = parent
	self._minimapFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(100, 100, 100)
	stroke.Thickness = 1
	stroke.Parent = frame

	-- Shrink zone circle on minimap
	local shrinkCircle = Instance.new("Frame")
	shrinkCircle.Name = "ShrinkCircle"
	shrinkCircle.Size = UDim2.fromScale(1, 1)
	shrinkCircle.Position = UDim2.fromScale(0.5, 0.5)
	shrinkCircle.AnchorPoint = Vector2.new(0.5, 0.5)
	shrinkCircle.BackgroundTransparency = 1
	shrinkCircle.BorderSizePixel = 0
	shrinkCircle.Parent = frame

	local circleCorner = Instance.new("UICorner")
	circleCorner.CornerRadius = UDim.new(1, 0)
	circleCorner.Parent = shrinkCircle

	local circleStroke = Instance.new("UIStroke")
	circleStroke.Color = Color3.fromRGB(255, 50, 50)
	circleStroke.Thickness = 2
	circleStroke.Parent = shrinkCircle

	self._shrinkCircle = shrinkCircle

	-- Persistent player arrow (updated every frame for smooth rotation).
	-- Uses a pure Frame-based needle — no text or image rendering at all.
	-- Text/image elements flicker when rotated per-frame because Roblox
	-- re-rasterises the glyph at each angle. A coloured Frame has zero
	-- rasterisation cost and rotates flicker-free.
	local arrow = Instance.new("Frame")
	arrow.Name = "PlayerArrow"
	arrow.Size = UDim2.new(0, 14, 0, 14)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.BackgroundTransparency = 1
	arrow.BorderSizePixel = 0
	arrow.Rotation = 0
	arrow.ZIndex = 10
	arrow.Parent = frame

	-- Elongated green needle pointing "up" (local Y-) within the arrow frame
	local needle = Instance.new("Frame")
	needle.Name = "Needle"
	needle.Size = UDim2.new(0, 4, 0, 12)
	needle.Position = UDim2.fromScale(0.5, 0.5)
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
	needle.BorderSizePixel = 0
	needle.ZIndex = 11
	needle.Parent = arrow

	local needleCorner = Instance.new("UICorner")
	needleCorner.CornerRadius = UDim.new(0.5, 0)
	needleCorner.Parent = needle

	-- Small bright tip at the top of the needle to show direction
	local tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.Size = UDim2.new(0, 6, 0, 6)
	tip.Position = UDim2.new(0.5, 0, 0, -1)
	tip.AnchorPoint = Vector2.new(0.5, 0.5)
	tip.BackgroundColor3 = Color3.fromRGB(180, 255, 180)
	tip.BorderSizePixel = 0
	tip.ZIndex = 12
	tip.Parent = arrow

	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(1, 0)
	tipCorner.Parent = tip

	self._minimapArrow = arrow

	-- Shift minimap up on touch devices to make room for boost button
	if UserInputService.TouchEnabled then
		frame.Position = UDim2.new(1, -10, 1, -120)
	end
end

function WormUIController:_buildBoostButton(parent: ScreenGui)
	if not UserInputService.TouchEnabled then
		return
	end

	local button = Instance.new("ImageButton")
	button.Name = "BoostButton"
	button.Size = UDim2.new(0, 100, 0, 100)
	button.Position = UDim2.new(1, -30, 1, -10)
	button.AnchorPoint = Vector2.new(1, 1)
	button.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
	button.BackgroundTransparency = 0.3
	button.BorderSizePixel = 0
	button.Image = ""
	button.AutoButtonColor = false
	button.Parent = parent
	self._boostButton = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local boostStroke = Instance.new("UIStroke")
	boostStroke.Color = Color3.fromRGB(255, 200, 50)
	boostStroke.Thickness = 3
	boostStroke.Parent = button

	createTextLabel({
		Name = "Label",
		Text = "BOOST",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = button,
	})

	-- Wire press/release to WormController boost
	button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.1
			button.BackgroundColor3 = Color3.fromRGB(255, 220, 50)
			if self._wormController then
				self._wormController:SetBoosting(true)
			end
		end
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.3
			button.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
			if self._wormController then
				self._wormController:SetBoosting(false)
			end
		end
	end)
end

-- Touch-only on-screen Grapple button. Sits to the left of the BoostButton so
-- the right thumb can alternate between the two without re-gripping. On
-- desktop the grapple is bound to RMB / E (alive) or RMB / L2 (ghost); this
-- button is the mobile-friendly parallel and works in both alive and ghost
-- states (WormController:FireGrapple dispatches internally).
function WormUIController:_buildGrappleButton(parent: ScreenGui)
	if not UserInputService.TouchEnabled then
		return
	end

	local button = Instance.new("ImageButton")
	button.Name = "GrappleButton"
	button.Size = UDim2.new(0, 90, 0, 90)
	-- BoostButton anchors at (1,1) with offset (-30,-10) and size 100x100, so its
	-- left edge sits ~130px in. Place the Grapple button ~20px further left.
	button.Position = UDim2.new(1, -150, 1, -15)
	button.AnchorPoint = Vector2.new(1, 1)
	button.BackgroundColor3 = Color3.fromRGB(80, 180, 255)
	button.BackgroundTransparency = 0.3
	button.BorderSizePixel = 0
	button.Image = ""
	button.AutoButtonColor = false
	button.Parent = parent
	self._grappleButton = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(150, 220, 255)
	stroke.Thickness = 3
	stroke.Parent = button

	createTextLabel({
		Name = "Label",
		Text = "GRAPPLE",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.new(1, 1, 1),
		Parent = button,
	})

	-- Fire on press down (matches the keyboard binding being InputBegan, not
	-- Activated — keeps perceived latency consistent between mouse and touch).
	button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.1
			button.BackgroundColor3 = Color3.fromRGB(140, 210, 255)
			if self._wormController then
				self._wormController:FireGrapple()
			end
		end
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.3
			button.BackgroundColor3 = Color3.fromRGB(80, 180, 255)
		end
	end)
end

function WormUIController:_buildPowerUpDisplay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "PowerUpDisplay"
	frame.Size = UDim2.new(0.13, 0, 0, 40)
	frame.Position = UDim2.new(0.5, 0, 0, 65)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._powerUpFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	self._powerUpLabel = createTextLabel({
		Name = "TypeLabel",
		Text = "",
		Size = UDim2.new(1, 0, 0.5, 0),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._powerUpTimer = createTextLabel({
		Name = "TimerLabel",
		Text = "",
		Size = UDim2.new(1, 0, 0.5, 0),
		Position = UDim2.fromScale(0, 0.5),
		TextSize = 12,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Parent = frame,
	})
end

function WormUIController:_buildGameTimer(parent: ScreenGui)
	self._gameTimerLabel = createTextLabel({
		Name = "GameTimer",
		Text = "0:00",
		Size = UDim2.new(0.06, 0, 0, 30),
		Position = UDim2.new(0.575, 4, 0, 15),
		AnchorPoint = Vector2.new(0, 0),
		TextSize = 18,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Font = Enum.Font.GothamBold,
		Parent = parent,
	})
end

function WormUIController:_buildZoneWarning(parent: ScreenGui)
	self._zoneWarningLabel = createTextLabel({
		Name = "ZoneWarning",
		Text = "",
		Size = UDim2.new(0.5, 0, 0, 40),
		Position = UDim2.new(0.5, 0, 0.2, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 28,
		TextColor3 = Color3.fromRGB(255, 80, 80),
		Font = Enum.Font.GothamBold,
		Parent = parent,
	})
end

function WormUIController:_buildFinalScoreboard(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "FinalScoreboard"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 10
	frame.Parent = parent
	self._finalScoreboardFrame = frame

	createTextLabel({
		Name = "Title",
		Text = "ROUND OVER",
		Size = UDim2.new(0, 400, 0, 50),
		Position = UDim2.fromScale(0.5, 0.1),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 40,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	self._scoreboardWinner = createTextLabel({
		Name = "Winner",
		Text = "",
		Size = UDim2.new(0, 400, 0, 35),
		Position = UDim2.fromScale(0.5, 0.18),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 28,
		TextColor3 = Color3.fromRGB(100, 255, 100),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})

	-- Header row
	local headerFrame = Instance.new("Frame")
	headerFrame.Name = "Header"
	headerFrame.Size = UDim2.new(0.7, 0, 0, 30)
	headerFrame.Position = UDim2.fromScale(0.5, 0.26)
	headerFrame.AnchorPoint = Vector2.new(0.5, 0)
	headerFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	headerFrame.BackgroundTransparency = 0.3
	headerFrame.BorderSizePixel = 0
	headerFrame.ZIndex = 11
	headerFrame.Parent = frame

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 4)
	headerCorner.Parent = headerFrame

	createTextLabel({
		Name = "H1",
		Text = "#",
		Size = UDim2.new(0.08, 0, 1, 0),
		Position = UDim2.fromScale(0.01, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H2",
		Text = "Name",
		Size = UDim2.new(0.38, 0, 1, 0),
		Position = UDim2.fromScale(0.09, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H3",
		Text = "Kills",
		Size = UDim2.new(0.15, 0, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H4",
		Text = "Max Size",
		Size = UDim2.new(0.17, 0, 1, 0),
		Position = UDim2.fromScale(0.66, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		Parent = headerFrame,
	})
	createTextLabel({
		Name = "H5",
		Text = "Coins",
		Size = UDim2.new(0.14, 0, 1, 0),
		Position = UDim2.fromScale(0.84, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Parent = headerFrame,
	})

	-- Scrolling list container
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "List"
	scrollFrame.Size = UDim2.new(0.7, 0, 0.4, 0)
	scrollFrame.Position = UDim2.fromScale(0.5, 0.3)
	scrollFrame.AnchorPoint = Vector2.new(0.5, 0)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 4
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.ZIndex = 11
	scrollFrame.Parent = frame
	self._scoreboardList = scrollFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = scrollFrame
end

function WormUIController:_buildCoinDisplay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "CoinDisplay"
	frame.Size = UDim2.new(0.1, 0, 0, 40)
	frame.Position = UDim2.new(1, -10, 0, 10 + TOP_INSET)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	-- Coin icon (gold circle)
	local icon = Instance.new("Frame")
	icon.Name = "CoinIcon"
	icon.Size = UDim2.new(0, 24, 0, 24)
	icon.Position = UDim2.new(0, 8, 0.5, 0)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	icon.BorderSizePixel = 0
	icon.Parent = frame

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	self._coinLabel = createTextLabel({
		Name = "CoinCount",
		Text = "0",
		Size = UDim2.new(0, 90, 1, 0),
		Position = UDim2.fromOffset(40, 0),
		TextSize = 20,
		TextColor3 = Color3.fromRGB(255, 220, 50),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
end

function WormUIController:_buildCrosshair(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Crosshair"
	frame.Size = UDim2.new(0, 24, 0, 24)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	self._crosshairFrame = frame

	-- Horizontal line
	local hLine = Instance.new("Frame")
	hLine.Name = "H"
	hLine.Size = UDim2.new(1, 0, 0, 2)
	hLine.Position = UDim2.fromScale(0, 0.5)
	hLine.AnchorPoint = Vector2.new(0, 0.5)
	hLine.BackgroundColor3 = Color3.fromRGB(0, 200, 255)
	hLine.BorderSizePixel = 0
	hLine.Parent = frame

	-- Vertical line
	local vLine = Instance.new("Frame")
	vLine.Name = "V"
	vLine.Size = UDim2.new(0, 2, 1, 0)
	vLine.Position = UDim2.fromScale(0.5, 0)
	vLine.AnchorPoint = Vector2.new(0.5, 0)
	vLine.BackgroundColor3 = Color3.fromRGB(0, 200, 255)
	vLine.BorderSizePixel = 0
	vLine.Parent = frame

	-- Center dot
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.new(0, 4, 0, 4)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dot.BorderSizePixel = 0
	dot.Parent = frame

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
end

function WormUIController:_buildToolbar(parent: ScreenGui)
	-- Container bar at bottom center
	local toolbar = Instance.new("Frame")
	toolbar.Name = "GhostToolbar"
	toolbar.Size = UDim2.new(0.35, 0, 0, PlatformUtil.MinTouchSize(60))
	toolbar.Position = UDim2.new(0.5, 0, 1, -10)
	toolbar.AnchorPoint = Vector2.new(0.5, 1)
	toolbar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	toolbar.BackgroundTransparency = 0.4
	toolbar.BorderSizePixel = 0
	toolbar.Visible = false
	toolbar.Parent = parent
	self._toolbarFrame = toolbar

	local toolbarCorner = Instance.new("UICorner")
	toolbarCorner.CornerRadius = UDim.new(0, 10)
	toolbarCorner.Parent = toolbar

	local toolbarStroke = Instance.new("UIStroke")
	toolbarStroke.Color = Color3.fromRGB(80, 80, 80)
	toolbarStroke.Thickness = 1
	toolbarStroke.Parent = toolbar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = toolbar

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = toolbar

	-- Slot 1: Grapple
	local grappleHintText = PlatformUtil.ActionLabel("RMB to hook", "Tap to hook", "LT to hook")
	local grappleSlot = self:_buildToolbarSlot(toolbar, "1", "GRAPPLE", grappleHintText, Color3.fromRGB(0, 180, 255))
	self._grappleSlot = grappleSlot.Frame
	self._grappleHint = grappleSlot.Hint
	self._grappleSlotStroke = grappleSlot.Stroke
	-- Grapple starts selected
	self._grappleSlotStroke.Transparency = 0

	-- Divider
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(0, 1, 0.6, 0)
	divider.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
	divider.BorderSizePixel = 0
	divider.LayoutOrder = 2
	divider.Parent = toolbar

	-- Slot 2: Weapon
	local weaponHintText = PlatformUtil.ActionLabel("LMB to fire", "Tap to fire", "RT to fire")
	local weaponSlot = self:_buildToolbarSlot(toolbar, "2", "---", weaponHintText, Color3.fromRGB(255, 200, 50))
	weaponSlot.Frame.LayoutOrder = 3
	self._weaponSlotLabel = weaponSlot.Label
	self._weaponSlotAmmo = weaponSlot.Ammo
	self._weaponSlotStroke = weaponSlot.Stroke
end

function WormUIController:_buildRiderNotification(parent: ScreenGui)
	local label = Instance.new("TextLabel")
	label.Name = "RiderNotification"
	label.Text = ""
	label.Size = UDim2.new(0.4, 0, 0, 30)
	label.Position = UDim2.new(0.5, 0, 0.12, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(100, 220, 255)
	label.Font = Enum.Font.GothamBold
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.5
	label.Parent = parent
	self._riderNotifyLabel = label
end

function WormUIController:_buildToolbarSlot(
	parent: Frame,
	keyHint: string,
	toolName: string,
	actionHint: string,
	accentColor: Color3
): {
	Frame: TextButton,
	Label: TextLabel,
	Hint: TextLabel,
	Ammo: TextLabel,
	Stroke: UIStroke,
}
	local slot = Instance.new("TextButton")
	slot.Name = "Slot" .. keyHint
	slot.Size = UDim2.new(0.45, 0, 0, PlatformUtil.MinTouchSize(50))
	slot.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	slot.BackgroundTransparency = 0.3
	slot.BorderSizePixel = 0
	slot.LayoutOrder = tonumber(keyHint) or 1
	slot.Text = ""
	slot.AutoButtonColor = false
	slot.Parent = parent

	local slotCorner = Instance.new("UICorner")
	slotCorner.CornerRadius = UDim.new(0, 6)
	slotCorner.Parent = slot

	-- Selection highlight stroke
	local slotStroke = Instance.new("UIStroke")
	slotStroke.Color = accentColor
	slotStroke.Thickness = 2
	slotStroke.Transparency = 1 -- hidden by default
	slotStroke.Parent = slot

	-- Key badge (small square with number)
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.new(0, 20, 0, 20)
	badge.Position = UDim2.new(0, 6, 0, 6)
	badge.BackgroundColor3 = accentColor
	badge.BackgroundTransparency = 0.3
	badge.BorderSizePixel = 0
	badge.Parent = slot

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 4)
	badgeCorner.Parent = badge

	local badgeLabel = Instance.new("TextLabel")
	badgeLabel.Name = "Key"
	badgeLabel.Size = UDim2.fromScale(1, 1)
	badgeLabel.BackgroundTransparency = 1
	badgeLabel.Text = keyHint
	badgeLabel.TextColor3 = Color3.new(1, 1, 1)
	badgeLabel.TextSize = 12
	badgeLabel.Font = Enum.Font.GothamBold
	badgeLabel.Parent = badge

	-- Tool name label
	local nameLabel = createTextLabel({
		Name = "ToolName",
		Text = toolName,
		Size = UDim2.new(0, 120, 0, 20),
		Position = UDim2.new(0, 32, 0, 4),
		TextSize = 16,
		TextColor3 = accentColor,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = slot,
	})

	-- Ammo label (right side, for weapon slot)
	local ammoLabel = createTextLabel({
		Name = "Ammo",
		Text = "",
		Size = UDim2.new(0, 40, 0, 20),
		Position = UDim2.new(1, -8, 0, 4),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(200, 200, 200),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = slot,
	})

	-- Action hint (bottom row)
	local hintLabel = createTextLabel({
		Name = "Hint",
		Text = actionHint,
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 6, 1, -4),
		AnchorPoint = Vector2.new(0, 1),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(140, 140, 140),
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = slot,
	})

	return {
		Frame = slot,
		Label = nameLabel,
		Hint = hintLabel,
		Ammo = ammoLabel,
		Stroke = slotStroke,
	}
end

function WormUIController:_buildCountdownOverlay(parent: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "CountdownOverlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 12
	frame.Parent = parent
	self._countdownFrame = frame

	self._countdownLabel = createTextLabel({
		Name = "CountdownText",
		Text = "",
		Size = UDim2.new(0.5, 0, 0, 80),
		Position = UDim2.fromScale(0.5, 0.4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 48,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		Parent = frame,
	})
end

--------------------------------------------------
-- UI updates
--------------------------------------------------

function WormUIController:_updateSegmentCounter(segments: number)
	if self._segmentLabel then
		self._segmentLabel.Text = "Segments: " .. math.floor(segments)
	end
end

function WormUIController:_showDeathScreen(deathInfo: { KillerName: string?, MaxSegments: number, Kills: number })
	if not self._deathFrame or not self._deathLabel then
		return
	end

	if deathInfo.KillerName then
		self._deathLabel.Text = "Killed by " .. deathInfo.KillerName
	else
		self._deathLabel.Text = "Hit the wall!"
	end

	if self._statsLabel then
		self._statsLabel.Text = "Max Size: " .. deathInfo.MaxSegments .. "  |  Kills: " .. deathInfo.Kills
	end

	self._deathFrame.Visible = true
end

function WormUIController:_hideDeathScreen()
	if self._deathFrame then
		self._deathFrame.Visible = false
	end
end

function WormUIController:_showFinalScoreboard(results: { any })
	-- Hide death screen first
	self:_hideDeathScreen()

	if not self._finalScoreboardFrame or not self._scoreboardList or not self._scoreboardWinner then
		return
	end

	-- Set winner
	if #results > 0 then
		self._scoreboardWinner.Text = results[1].Name .. " wins!"
	else
		self._scoreboardWinner.Text = ""
	end

	-- Clear old entries
	for _, child in self._scoreboardList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Populate list
	for i, entry in results do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 28)
		row.LayoutOrder = i
		row.BorderSizePixel = 0
		row.BackgroundTransparency = if i % 2 == 0 then 0.7 else 0.8
		row.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		row.Parent = self._scoreboardList

		local isLocalPlayer = entry.Name == LocalPlayer.Name
		local nameColor = if isLocalPlayer
			then Color3.fromRGB(100, 255, 100)
			elseif i == 1 then Color3.fromRGB(255, 220, 50)
			else Color3.new(1, 1, 1)

		createTextLabel({
			Name = "Place",
			Text = "#" .. entry.Placement,
			Size = UDim2.new(0.08, 0, 1, 0),
			Position = UDim2.fromScale(0.01, 0),
			TextSize = 14,
			TextColor3 = nameColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		createTextLabel({
			Name = "Name",
			Text = entry.Name,
			Size = UDim2.new(0.38, 0, 1, 0),
			Position = UDim2.fromScale(0.09, 0),
			TextSize = 14,
			TextColor3 = nameColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		createTextLabel({
			Name = "Kills",
			Text = tostring(entry.Kills),
			Size = UDim2.new(0.15, 0, 1, 0),
			Position = UDim2.fromScale(0.5, 0),
			TextSize = 14,
			Parent = row,
		})
		createTextLabel({
			Name = "MaxSize",
			Text = tostring(entry.MaxSegments),
			Size = UDim2.new(0.17, 0, 1, 0),
			Position = UDim2.fromScale(0.66, 0),
			TextSize = 14,
			Parent = row,
		})

		local coinsText = if entry.CoinsAwarded and entry.CoinsAwarded > 0
			then "+" .. tostring(entry.CoinsAwarded)
			else ""
		createTextLabel({
			Name = "Coins",
			Text = coinsText,
			Size = UDim2.new(0.14, 0, 1, 0),
			Position = UDim2.fromScale(0.84, 0),
			TextSize = 14,
			TextColor3 = Color3.fromRGB(255, 220, 50),
			Parent = row,
		})
	end

	-- Update canvas size
	self._scoreboardList.CanvasSize = UDim2.new(0, 0, 0, #results * 30)

	self._finalScoreboardFrame.Visible = true
end

function WormUIController:_hideFinalScoreboard()
	if self._finalScoreboardFrame then
		self._finalScoreboardFrame.Visible = false
	end
end

function WormUIController:_showCountdown(seconds: number)
	if not self._countdownFrame or not self._countdownLabel then
		return
	end
	self._countdownLabel.Text = "Next round in: " .. seconds
	self._countdownFrame.Visible = true
end

function WormUIController:_hideCountdown()
	if self._countdownFrame then
		self._countdownFrame.Visible = false
	end
end

function WormUIController:_addKillFeedEntry(deadName: string, killerName: string?)
	local killFeed = self._killFeedFrame
	if not killFeed then
		return
	end

	local text = if killerName then deadName .. " ran into " .. killerName else deadName .. " hit the wall"

	local entry = createTextLabel({
		Name = "Entry",
		Text = text,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromScale(0, 0),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.5,
		Parent = killFeed,
	})

	local entryCorner = Instance.new("UICorner")
	entryCorner.CornerRadius = UDim.new(0, 4)
	entryCorner.Parent = entry

	-- Remove after delay
	task.delay(KILL_FEED_DURATION, function()
		if entry.Parent then
			entry:Destroy()
		end
	end)

	-- Trim excess entries
	local children = killFeed:GetChildren()
	local entries = {}
	for _, child in children do
		if child:IsA("TextLabel") then
			table.insert(entries, child)
		end
	end
	while #entries > MAX_KILL_FEED do
		entries[1]:Destroy()
		table.remove(entries, 1)
	end
end

-- While the Crown is Carried, the server stops flushing the Crown Part's CFrame
-- (at 10Hz that looked choppy). We pin the Crown to the carrier's head every
-- frame locally — for remote carriers this still matches Roblox's per-frame
-- interpolation of their replicated head, so the crown reads as smooth.
function WormUIController:_updateCrownCarryPosition()
	local snap = self._crownSnapshot
	if not snap or snap.StateName ~= "Carried" or not snap.CarrierName then
		return
	end
	local crownModel = workspace:FindFirstChild("Crown")
	if not crownModel or not crownModel:IsA("Model") then
		return
	end
	local carrierModel = workspace:FindFirstChild(snap.CarrierName)
	if not carrierModel or not carrierModel:IsA("Model") then
		return
	end
	local head = carrierModel:FindFirstChild("WormHead") :: BasePart?
	if not head then
		return
	end
	crownModel:PivotTo(CFrame.new(head.Position + Vector3.new(0, CROWN_CARRY_OFFSET_Y, 0)))
end

function WormUIController:_updateMinimapArrow()
	local arrow = self._minimapArrow
	if not arrow then
		return
	end

	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart? or nil
	if not hrp then
		if arrow.Visible then
			arrow.Visible = false
		end
		return
	end

	if not arrow.Visible then
		arrow.Visible = true
	end
	local WormController = Knit.GetController("WormController")
	local isAlive = WormController and WormController._alive

	-- Two minimap modes:
	-- Worm mode (alive): camera-relative — reads live camera axes so minimap
	--   matches the top-down view exactly (proven working).
	-- Ghost mode (first-person): fixed axes — the live camera spins with the
	--   player which would make the minimap unusable, so we use fixed world axes.
	local halfArena = WormConfig.ArenaSize / 2
	local pos = hrp.Position
	local minimapX: number
	local minimapY: number

	if isAlive then
		-- Camera-relative: project world position onto camera's screen axes
		local cam = workspace.CurrentCamera
		local camRight = cam.CFrame.RightVector
		local camUp = cam.CFrame.UpVector
		local screenRightXZ = Vector3.new(camRight.X, 0, camRight.Z)
		local screenUpXZ = Vector3.new(camUp.X, 0, camUp.Z)
		if screenRightXZ.Magnitude > 0.01 then
			screenRightXZ = screenRightXZ.Unit
		end
		if screenUpXZ.Magnitude > 0.01 then
			screenUpXZ = screenUpXZ.Unit
		end
		local worldXZ = Vector3.new(pos.X, 0, pos.Z)
		local rightDot = worldXZ:Dot(screenRightXZ)
		local upDot = worldXZ:Dot(screenUpXZ)
		minimapX = (rightDot + halfArena) / WormConfig.ArenaSize
		minimapY = 1 - (upDot + halfArena) / WormConfig.ArenaSize
	else
		-- Ghost mode: fixed axes (world +X = right, world -Z = up)
		minimapX = (pos.X + halfArena) / WormConfig.ArenaSize
		minimapY = (-pos.Z + halfArena) / WormConfig.ArenaSize
	end

	arrow.Position = UDim2.fromScale(math.clamp(minimapX, 0, 1), math.clamp(minimapY, 0, 1))

	-- Direction for arrow rotation
	local dir: Vector3
	if isAlive and WormController._direction then
		dir = WormController._direction
	else
		dir = hrp.CFrame.LookVector
	end
	if dir.Magnitude < 0.01 then
		return
	end

	if isAlive then
		-- Camera-relative rotation
		local cam = workspace.CurrentCamera
		local camRight = cam.CFrame.RightVector
		local camUp = cam.CFrame.UpVector
		local screenRightXZ = Vector3.new(camRight.X, 0, camRight.Z)
		local screenUpXZ = Vector3.new(camUp.X, 0, camUp.Z)
		if screenRightXZ.Magnitude > 0.01 then
			screenRightXZ = screenRightXZ.Unit
		end
		if screenUpXZ.Magnitude > 0.01 then
			screenUpXZ = screenUpXZ.Unit
		end
		local dirRight = dir:Dot(screenRightXZ)
		local dirUp = dir:Dot(screenUpXZ)
		arrow.Rotation = math.deg(math.atan2(dirRight, dirUp))
	else
		-- Ghost mode: fixed axes rotation
		arrow.Rotation = math.deg(math.atan2(dir.X, -dir.Z))
	end
end

-- Minimap helper: converts a world position to minimap [0,1] scale.
-- Uses camera-relative axes when alive, fixed axes in ghost mode.
function WormUIController:_worldToMinimapScale(worldPos: Vector3): (number, number)
	local halfArena = WormConfig.ArenaSize / 2
	local WormController = Knit.GetController("WormController")
	local isAlive = WormController and WormController._alive

	if isAlive then
		local cam = workspace.CurrentCamera
		local camRight = cam.CFrame.RightVector
		local camUp = cam.CFrame.UpVector
		local screenRightXZ = Vector3.new(camRight.X, 0, camRight.Z)
		local screenUpXZ = Vector3.new(camUp.X, 0, camUp.Z)
		if screenRightXZ.Magnitude > 0.01 then
			screenRightXZ = screenRightXZ.Unit
		end
		if screenUpXZ.Magnitude > 0.01 then
			screenUpXZ = screenUpXZ.Unit
		end
		local worldXZ = Vector3.new(worldPos.X, 0, worldPos.Z)
		local rightDot = worldXZ:Dot(screenRightXZ)
		local upDot = worldXZ:Dot(screenUpXZ)
		local mx = (rightDot + halfArena) / WormConfig.ArenaSize
		local my = 1 - (upDot + halfArena) / WormConfig.ArenaSize
		return math.clamp(mx, 0, 1), math.clamp(my, 0, 1)
	else
		local mx = (worldPos.X + halfArena) / WormConfig.ArenaSize
		local my = (-worldPos.Z + halfArena) / WormConfig.ArenaSize
		return math.clamp(mx, 0, 1), math.clamp(my, 0, 1)
	end
end

-- Worm King: draw the sand tide triangle (3 edges) on the minimap at the current scale.
-- Each edge is a thin UDim2-based Frame rotated to connect two minimap-space vertices.
function WormUIController:_drawMinimapTriangle(minimap: Frame, scale: number)
	-- Compute world-space scaled vertices, then convert each to minimap fraction.
	local vs = TeamBase.getScaledVertices(scale)
	local mw = minimap.AbsoluteSize.X
	local mh = minimap.AbsoluteSize.Y
	if mw <= 0 or mh <= 0 then
		return
	end
	local pts: { { x: number, y: number } } = {}
	for _, v in vs do
		local mx, my = self:_worldToMinimapScale(v)
		table.insert(pts, { x = mx * mw, y = my * mh })
	end

	-- Edge color: orange (warning) when past the first contraction threshold, red when close to min.
	local edgeColor = Color3.fromRGB(255, 180, 50)
	if scale <= 0.35 then
		edgeColor = Color3.fromRGB(255, 60, 60)
	elseif scale >= 0.9 then
		edgeColor = Color3.fromRGB(255, 220, 120)
	end

	for i = 1, 3 do
		local a = pts[i]
		local b = pts[(i % 3) + 1]
		local dx = b.x - a.x
		local dy = b.y - a.y
		local length = math.sqrt(dx * dx + dy * dy)
		if length < 1 then
			continue
		end
		local angle = math.deg(math.atan2(dy, dx))
		local midX = (a.x + b.x) * 0.5
		local midY = (a.y + b.y) * 0.5

		local edge = Instance.new("Frame")
		edge.Name = "TideEdge"
		edge.AnchorPoint = Vector2.new(0.5, 0.5)
		edge.Position = UDim2.fromOffset(midX, midY)
		edge.Size = UDim2.fromOffset(length, 2)
		edge.Rotation = angle
		edge.BackgroundColor3 = edgeColor
		edge.BorderSizePixel = 0
		edge.ZIndex = 6
		edge.Parent = minimap
	end
end

function WormUIController:_updateMinimap()
	local minimap = self._minimapFrame
	if not minimap then
		return
	end

	-- Clear old dots, arrows, and triangle edges (keep ShrinkCircle and UICorner/UIStroke)
	for _, child in minimap:GetChildren() do
		if (child.Name == "Dot" or child.Name == "TideEdge") and (child:IsA("Frame") or child:IsA("TextLabel")) then
			child:Destroy()
		end
	end

	-- Player dots (other players only; local player arrow is updated per-frame)
	for _, player in Players:GetPlayers() do
		if player == LocalPlayer then
			continue
		end

		local character = player.Character
		if not character then
			continue
		end

		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		local mx, my = self:_worldToMinimapScale(hrp.Position)

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.Size = UDim2.new(0, 6, 0, 6)
		dot.Position = UDim2.fromScale(mx, my)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BorderSizePixel = 0
		dot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		dot.Parent = minimap

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot
	end

	-- Bot enemy dots
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("IsBotWorm") then
			local hrp = child:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hrp then
				continue
			end

			local mx, my = self:_worldToMinimapScale(hrp.Position)

			local dot = Instance.new("Frame")
			dot.Name = "Dot"
			dot.Size = UDim2.new(0, 6, 0, 6)
			dot.Position = UDim2.fromScale(mx, my)
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.BorderSizePixel = 0
			dot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
			dot.Parent = minimap

			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
		end
	end

	-- Power-up dots on minimap
	local powerUpsFolder = workspace:FindFirstChild("PowerUps") :: Folder?
	if powerUpsFolder then
		for _, powerUp in powerUpsFolder:GetChildren() do
			if powerUp:IsA("BasePart") then
				local mx, my = self:_worldToMinimapScale(powerUp.Position)

				local dot = Instance.new("Frame")
				dot.Name = "Dot"
				dot.Size = UDim2.new(0, 5, 0, 5)
				dot.Position = UDim2.fromScale(mx, my)
				dot.AnchorPoint = Vector2.new(0.5, 0.5)
				dot.BorderSizePixel = 0
				dot.BackgroundColor3 = Color3.fromRGB(255, 255, 0)
				dot.Parent = minimap

				local dotCorner = Instance.new("UICorner")
				dotCorner.CornerRadius = UDim.new(1, 0)
				dotCorner.Parent = dot
			end
		end
	end

	-- Update shrink zone circle (hidden in Worm King team mode — sand tide triangle replaces it)
	if self._shrinkCircle then
		if self._teamModeActive then
			self._shrinkCircle.Visible = false
		else
			self._shrinkCircle.Visible = true
			local halfArena = WormConfig.ArenaSize / 2
			local radiusFraction = self._currentZoneRadius / halfArena
			self._shrinkCircle.Size =
				UDim2.fromScale(math.clamp(radiusFraction, 0, 1), math.clamp(radiusFraction, 0, 1))
		end
	end

	-- Worm King: sand tide triangle edges. Draw the 3 scaled vertices connected
	-- by thin rotated Frames so players see the contracting playable area.
	if self._teamModeActive then
		self:_drawMinimapTriangle(minimap, self._sandTideScale)
	end

	-- Worm King: Crown marker (gold dot). Read position directly from the workspace
	-- Crown Part (auto-replicated at 10Hz by the server). Hidden while Inactive —
	-- the CrownPickedUp/Dropped/Returned/Spawned signals still drive `StateName`.
	local crownSnap = self._crownSnapshot
	if crownSnap and crownSnap.StateName ~= "Inactive" then
		local crownModel = workspace:FindFirstChild("Crown") :: Model?
		local crownPart = if crownModel then crownModel.PrimaryPart else nil
		if crownPart then
			local cmx, cmy = self:_worldToMinimapScale(crownPart.Position)

			local crownDot = Instance.new("Frame")
			crownDot.Name = "Dot"
			crownDot.Size = UDim2.new(0, 10, 0, 10)
			crownDot.Position = UDim2.fromScale(cmx, cmy)
			crownDot.AnchorPoint = Vector2.new(0.5, 0.5)
			crownDot.BorderSizePixel = 0
			crownDot.BackgroundColor3 = Color3.fromRGB(255, 215, 0)
			crownDot.ZIndex = 5
			crownDot.Parent = minimap

			local crownCorner = Instance.new("UICorner")
			crownCorner.CornerRadius = UDim.new(1, 0)
			crownCorner.Parent = crownDot

			local crownStroke = Instance.new("UIStroke")
			crownStroke.Color = Color3.fromRGB(80, 50, 0)
			crownStroke.Thickness = 1
			crownStroke.Parent = crownDot
		end
	end
end

function WormUIController:_showPowerUp(powerUpType: string, duration: number)
	if not self._powerUpFrame or not self._powerUpLabel then
		return
	end

	local displayName = string.gsub(powerUpType, "_", " ")
	local color = POWERUP_COLORS[powerUpType] or Color3.new(1, 1, 1)

	self._powerUpLabel.Text = displayName
	self._powerUpLabel.TextColor3 = color
	self._powerUpFrame.Visible = true

	if duration > 0 then
		self._activePowerUpEnd = os.clock() + duration
	else
		-- Instant effect, flash briefly
		self._activePowerUpEnd = os.clock() + 1
	end
end

function WormUIController:_hidePowerUp()
	if self._powerUpFrame then
		self._powerUpFrame.Visible = false
	end
	self._activePowerUpEnd = 0
end

function WormUIController:_updatePowerUpTimer()
	if self._activePowerUpEnd <= 0 then
		return
	end

	local remaining = self._activePowerUpEnd - os.clock()
	if remaining <= 0 then
		self:_hidePowerUp()
		return
	end

	if self._powerUpTimer then
		self._powerUpTimer.Text = string.format("%.1fs", remaining)
	end
end

function WormUIController:_updateGameTimer(elapsed: number)
	if not self._gameTimerLabel then
		return
	end
	local mins = math.floor(elapsed / 60)
	local secs = math.floor(elapsed % 60)
	self._gameTimerLabel.Text = string.format("%d:%02d", mins, secs)
end

function WormUIController:_showZoneWarning(message: string)
	if not self._zoneWarningLabel then
		return
	end
	self._zoneWarningLabel.Text = message

	-- Auto-hide after 3 seconds
	task.delay(3, function()
		if self._zoneWarningLabel and self._zoneWarningLabel.Text == message then
			self._zoneWarningLabel.Text = ""
		end
	end)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormUIController:KnitInit()
	self._trove = Trove.new()
end

function WormUIController:KnitStart()
	self._wormService = Knit.GetService("WormService")
	self._wormController = Knit.GetController("WormController")
	self._weaponController = Knit.GetController("WeaponController")
	self._powerUpService = Knit.GetService("PowerUpService")
	self._coinService = Knit.GetService("CoinService")
	self._crownService = Knit.GetService("CrownService")
	self._marksService = Knit.GetService("MarksService")
	self._roundService = Knit.GetService("RoundService")
	self._sandTideService = Knit.GetService("SandTideService")

	-- Cached Crown snapshot used by _updateMinimap to decide whether to draw the
	-- gold Crown marker. Position comes from the workspace Crown Part directly,
	-- so only `StateName` and `CarrierName` are tracked here.
	self._crownSnapshot = {
		StateName = "Inactive",
		CarrierName = nil :: string?,
	}

	self:_buildUI()

	-- Worm King: seed team scores + Crown state on start
	task.spawn(function()
		local ok, state = self._crownService:GetState():await()
		if not ok or typeof(state) ~= "table" then
			return
		end
		if state.Scores then
			self:_updateTeamScores(state.Scores)
		end
		self._crownSnapshot.StateName = state.StateName or "Inactive"
		self._crownSnapshot.CarrierName = state.CarrierName
		if state.StateName == "Carried" and state.CarrierName then
			-- teamIndex unknown from snapshot; banner will refresh on next CrownPickedUp signal
			self:_updateCrownCarrier(state.CarrierName, state.CarrierIsPlayer, nil)
		else
			self:_updateCrownCarrier(nil)
		end
	end)

	-- Worm King: score chip updates
	self._trove:Add(self._crownService.ScoreUpdate:Connect(function(snapshot: { { TeamIndex: number, Score: number } })
		self:_updateTeamScores(snapshot)
	end))

	-- Worm King: Crown pickup/drop/return → carrier banner
	self._trove:Add(
		self._crownService.CrownPickedUp:Connect(function(carrierName: string, isPlayer: boolean, teamIndex: number)
			self._crownSnapshot.StateName = "Carried"
			self._crownSnapshot.CarrierName = carrierName
			self:_updateCrownCarrier(carrierName, isPlayer, teamIndex)
		end)
	)

	self._trove:Add(self._crownService.CrownDropped:Connect(function(_position: Vector3)
		self._crownSnapshot.StateName = "Dropped"
		self._crownSnapshot.CarrierName = nil
		self:_updateCrownCarrier(nil)
	end))

	self._trove:Add(self._crownService.CrownReturned:Connect(function(_position: Vector3)
		self._crownSnapshot.StateName = "Dropped"
		self._crownSnapshot.CarrierName = nil
		self:_updateCrownCarrier(nil)
	end))

	self._trove:Add(self._crownService.CrownSpawned:Connect(function(_position: Vector3)
		self._crownSnapshot.StateName = "Dropped"
		self._crownSnapshot.CarrierName = nil
		self:_updateCrownCarrier(nil)
	end))

	-- Crown position: the Crown Part's CFrame auto-replicates at 10Hz from the server,
	-- so the minimap reads `workspace.Crown.PrimaryPart.Position` directly inside
	-- `_updateMinimap` instead of maintaining a separate signal.

	-- Worm King: a team won → end-of-round handled server-side; banner clears via RoundEnded
	self._trove:Add(self._crownService.TeamWon:Connect(function(_teamIndex: number, _teamName: string?, _teamColor: any)
		self:_updateCrownCarrier(nil)
	end))

	-- Worm King: Marks currency — seed + wire changes
	task.spawn(function()
		local ok, marks = self._marksService:GetMarks():await()
		if ok and type(marks) == "number" then
			self:_updateMarksUI(marks)
		end
	end)

	self._trove:Add(self._marksService.MarksChanged:Connect(function(newMarks: number)
		self:_updateMarksUI(newMarks)
	end))

	-- Respawn button click → ask server
	if self._respawnBtn then
		self._respawnBtn.Activated:Connect(function()
			self._marksService.RequestRespawn:Fire()
		end)
	end

	-- Respawn result feedback
	self._trove:Add(self._marksService.RespawnResult:Connect(function(ok: boolean, reason: string?)
		if ok then
			self:_showRespawnStatus("Respawning…", false)
			self:_setGhostHudVisible(false)
		else
			local msg = "Respawn failed"
			if reason == "NoMarks" then
				msg = string.format("Need %d Marks", WormConfig.WormKing.RespawnCost)
			elseif reason == "Locked" then
				msg = "Respawn locked (final 90s)"
			elseif reason == "NotGhost" then
				msg = "Enter ghost mode first"
			elseif reason == "RoundInactive" then
				msg = "Round not active"
			end
			self:_showRespawnStatus(msg, true)
		end
	end))

	-- Wire to WormController signals
	self._trove:Add(self._wormController.SegmentsChanged:Connect(function(segments: number)
		self:_updateSegmentCounter(segments)
	end))

	self._trove:Add(
		self._wormController.WormDied:Connect(
			function(deathInfo: { KillerName: string?, MaxSegments: number, Kills: number })
				-- Delay showing death screen so DeathCamController can play first
				task.delay(3.0, function()
					if not self._wormController:IsAlive() and not self._wormController._inGhostMode then
						self:_showDeathScreen(deathInfo)
						-- Worm King: reveal ghost HUD (Marks + respawn) alongside death screen
						self:_setGhostHudVisible(true)
					end
				end)
			end
		)
	)

	self._trove:Add(self._wormController.WormSpawned:Connect(function(_data: any)
		self:_hideDeathScreen()
		self:_hideFinalScoreboard()
		self:_hideCountdown()
		self:_updateSegmentCounter(WormConfig.InitialSegments)
		-- Clear rider notification on respawn
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = ""
		end
		-- Worm King: hide ghost HUD when alive as a worm
		self:_setGhostHudVisible(false)
	end))

	-- Power-up signals from WormController
	self._trove:Add(self._wormController.PowerUpActivated:Connect(function(powerUpType: string, duration: number)
		self:_showPowerUp(powerUpType, duration)
	end))

	self._trove:Add(self._wormController.PowerUpExpired:Connect(function()
		self:_hidePowerUp()
	end))

	-- Zone signals from WormController
	self._trove:Add(self._wormController.ZoneUpdate:Connect(function(radius: number, elapsed: number)
		self._currentZoneRadius = radius
		self:_updateGameTimer(elapsed)
	end))

	self._trove:Add(self._wormController.ZoneWarning:Connect(function(message: string)
		self:_showZoneWarning(message)
	end))

	-- Wire kill feed to server signal (skip local player's own death — death screen covers it)
	self._trove:Add(self._wormService.WormDied:Connect(function(deadName: string, killerName: string?)
		if deadName == LocalPlayer.Name then
			return
		end
		self:_addKillFeedEntry(deadName, killerName)
	end))

	-- Connect food signal (suppress Knit warning)
	self._trove:Add(self._wormService.FoodSpawned:Connect(function(_position: Vector3, _color: Color3) end))

	-- Suppress PlayerKillsUpdated Knit warning (handled by WormController)
	self._trove:Add(self._wormService.PlayerKillsUpdated:Connect(function() end))

	-- Wire spectate buttons
	if self._spectateButtonPrev then
		self._spectateButtonPrev.Activated:Connect(function()
			if self._wormController then
				self._wormController:CycleSpectate(-1)
			end
		end)
	end
	if self._spectateButtonNext then
		self._spectateButtonNext.Activated:Connect(function()
			if self._wormController then
				self._wormController:CycleSpectate(1)
			end
		end)
	end

	-- Wire ghost toggle button
	if self._ghostToggleBtn then
		self._ghostToggleBtn.Activated:Connect(function()
			if self._wormController then
				self._wormController:ToggleGhostMode()
			end
		end)
	end

	-- Ghost mode changed signal — toggle death screen visibility, button text, crosshair, and mouse cursor
	self._trove:Add(self._wormController.GhostModeChanged:Connect(function(inGhost: boolean)
		if inGhost then
			-- Hide death overlay while in ghost mode (player is in first person)
			if self._deathFrame then
				self._deathFrame.Visible = false
			end
		else
			-- Show death screen again when exiting ghost mode
			if self._deathFrame then
				self._deathFrame.Visible = true
			end
		end
		-- Worm King: Marks HUD stays visible whenever the player is not alive.
		if not self._wormController:IsAlive() then
			self:_setGhostHudVisible(true)
		end
		if self._ghostToggleBtn then
			self._ghostToggleBtn.Text = if inGhost then "Exit Ghost Mode" else "Enter Ghost Mode"
		end
		if self._crosshairFrame then
			self._crosshairFrame.Visible = inGhost
		end
		if self._toolbarFrame then
			self._toolbarFrame.Visible = inGhost
		end
		-- Hide mouse cursor when crosshair is active, restore when it's gone
		UserInputService.MouseIconEnabled = not inGhost
		-- Reset weapon slot when leaving ghost mode
		if not inGhost then
			if self._weaponSlotLabel then
				self._weaponSlotLabel.Text = "---"
			end
			if self._weaponSlotAmmo then
				self._weaponSlotAmmo.Text = ""
			end
			if self._grappleHint then
				self._grappleHint.Text = PlatformUtil.ActionLabel("LMB to hook", "Tap to hook", "RT to hook")
			end
			-- Reset slot highlight
			if self._grappleSlotStroke then
				self._grappleSlotStroke.Transparency = 0
			end
			if self._weaponSlotStroke then
				self._weaponSlotStroke.Transparency = 1
			end
		end
	end))

	-- Wire weapon toolbar signals
	self._trove:Add(self._weaponController.WeaponAssigned:Connect(function(weaponType: string, ammo: number)
		if self._weaponSlotLabel then
			self._weaponSlotLabel.Text = if weaponType then string.upper(weaponType) else ""
		end
		self._maxAmmo = ammo
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = tostring(ammo) .. "/" .. tostring(ammo)
		end
		-- Update grapple hint: with weapon, grapple is only available when not riding
		if self._grappleHint then
			self._grappleHint.Text = PlatformUtil.ActionLabel("LMB to hook", "Tap to hook", "RT to hook")
		end
	end))

	self._trove:Add(self._weaponController.AmmoChanged:Connect(function(ammo: number)
		if self._weaponSlotAmmo then
			if self._weaponController:IsReloading() then
				self._weaponSlotAmmo.Text = "RELOADING..."
				self._weaponSlotAmmo.TextColor3 = Color3.fromRGB(255, 180, 50)
			else
				self._weaponSlotAmmo.Text = tostring(ammo) .. "/" .. tostring(self._maxAmmo)
				self._weaponSlotAmmo.TextColor3 = Color3.fromRGB(255, 255, 255)
			end
		end
	end))

	self._trove:Add(self._weaponController.ReloadStarted:Connect(function(_duration: number)
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = "RELOADING..."
			self._weaponSlotAmmo.TextColor3 = Color3.fromRGB(255, 180, 50)
		end
	end))

	self._trove:Add(self._weaponController.ReloadFinished:Connect(function()
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = tostring(self._weaponController:GetAmmo()) .. "/" .. tostring(self._maxAmmo)
			self._weaponSlotAmmo.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end))

	self._trove:Add(self._weaponController.WeaponCleared:Connect(function()
		if self._weaponSlotLabel then
			self._weaponSlotLabel.Text = "---"
		end
		if self._weaponSlotAmmo then
			self._weaponSlotAmmo.Text = ""
		end
		self._maxAmmo = 0
	end))

	-- Both slots always highlighted (left-click = shoot, right-click = grapple)
	if self._grappleSlotStroke then
		self._grappleSlotStroke.Transparency = 0
	end
	if self._weaponSlotStroke then
		self._weaponSlotStroke.Transparency = 0
	end

	-- Wire rider notification (shown to alive worm player when a ghost mounts/dismounts)
	self._trove:Add(self._wormService.RiderAttached:Connect(function(_riderName: string)
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = "Ghost riding! +15% speed"
		end
	end))

	self._trove:Add(self._wormService.RiderDetached:Connect(function(_riderName: string)
		if self._riderNotifyLabel then
			self._riderNotifyLabel.Text = ""
		end
	end))

	-- Wire SpectateChanged to update label
	self._trove:Add(self._wormController.SpectateChanged:Connect(function(name: string)
		if self._spectateLabel then
			self._spectateLabel.Text = name
		end
	end))

	-- Round signals from WormController
	self._trove:Add(self._wormController.RoundEnded:Connect(function(results: any)
		self:_showFinalScoreboard(results)
		self:_setGhostHudVisible(false)
		self:_hideMatchTimer()
		-- Worm King: reset triangle overlay so BR rounds get the shrink circle back.
		self._teamModeActive = false
		self._sandTideScale = 1.0
	end))

	self._trove:Add(self._wormController.RoundCountdown:Connect(function(seconds: number)
		self:_hideFinalScoreboard()
		self:_hideDeathScreen()
		self:_showCountdown(seconds)
		self:_setGhostHudVisible(false)
		self:_hideMatchTimer()
	end))

	self._trove:Add(self._wormController.RoundStarted:Connect(function()
		self:_hideDeathScreen()
		self:_hideFinalScoreboard()
		self:_hideCountdown()
		self:_setGhostHudVisible(false)
	end))

	-- Worm King: match timer tick (elapsed, remaining, phase). MatchTick only fires in team mode,
	-- so receiving it is a reliable signal that the active round is Worm King.
	self._trove:Add(self._roundService.MatchTick:Connect(function(_elapsed: number, remaining: number, phase: string)
		self._teamModeActive = true
		self:_updateMatchTimer(remaining, phase)
	end))

	-- Worm King: sand tide scale — cached for minimap triangle rendering
	task.spawn(function()
		local ok, scale = self._sandTideService:GetScale():await()
		if ok and type(scale) == "number" then
			self._sandTideScale = scale
		end
	end)

	self._trove:Add(self._sandTideService.ScaleUpdate:Connect(function(newScale: number)
		if type(newScale) == "number" then
			self._sandTideScale = newScale
		end
	end))

	-- Worm King: reuse the zone-warning label for tide alerts (tide rising / accelerating).
	self._trove:Add(self._sandTideService.TideWarning:Connect(function(message: string)
		self:_showZoneWarning(message)
	end))

	-- Coin display: initial value + change signal
	task.spawn(function()
		local ok, coins = self._coinService:GetCoins():await()
		if ok and self._coinLabel then
			self._coinLabel.Text = tostring(coins)
		end
	end)

	self._trove:Add(self._coinService.CoinsChanged:Connect(function(newCoins: number)
		if self._coinLabel then
			self._coinLabel.Text = tostring(newCoins)
		end
	end))

	-- Daily reward notification
	self._trove:Add(self._coinService.DailyReward:Connect(function(coins: number, streak: number, isBonus: boolean)
		local msg = "Daily reward: +" .. coins .. " coins!"
		if isBonus then
			msg = msg .. " 7-day streak bonus: +200 coins!"
		elseif streak > 1 then
			msg = msg .. " (Day " .. streak .. " streak)"
		end
		self:_showZoneWarning(msg)
	end))

	-- Per-frame minimap arrow rotation + smooth crown carry follow
	self._trove:Connect(RunService.RenderStepped, function()
		self:_updateMinimapArrow()
		self:_updateCrownCarryPosition()
	end)

	-- Fast minimap updates so enemies track smoothly
	self._trove:Add(task.spawn(function()
		while true do
			self:_updateMinimap()
			task.wait(0.25)
		end
	end))

	-- Slower periodic power-up timer updates
	self._trove:Add(task.spawn(function()
		while true do
			self:_updatePowerUpTimer()
			task.wait(PERIODIC_UPDATE_INTERVAL)
		end
	end))
end

return WormUIController
