--!strict
--
-- CrownService — Worm King mode objective.
--
-- A single Crown spawns at the map centroid. Any living worm can pick it up by
-- touching it. While carried, the carrier's team earns +1 point per second
-- (configurable via WormConfig.WormKing.CrownScorePerSec). If the carrier dies,
-- the Crown drops at their death position. Dropped Crowns auto-return to the
-- centroid after CrownLostResetDelay seconds if no one picks them up.
--
-- Win condition: the first team to reach WormConfig.WormKing.ScoreThreshold
-- triggers a win (reported via TeamWon signal). RoundService listens and ends
-- the round.
--
-- State machine:
--   "Inactive"  — not spawned yet (pre-round / post-round)
--   "Dropped"   — on the ground, awaiting pickup (or auto-return timer)
--   "Carried"   — attached to a carrier's head
--
-- Server authority: Crown position is a cached data field written every
-- Heartbeat; the actual Part CFrame is flushed at ~10Hz to match the rest of
-- the "Server Brain, Client Body" network pattern.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local TeamBase = require(ReplicatedStorage.Shared.TeamBase)
local TerrainHeight = require(ReplicatedStorage.Shared.TerrainHeight)

local WormService -- Set in KnitStart
local BotService -- Set in KnitStart
local TeamService -- Set in KnitStart

type CrownStateName = "Inactive" | "Dropped" | "Carried"

type CrownState = {
	Name: CrownStateName,
	Position: Vector3, -- World position (used every frame for gameplay reads)
	CarrierName: string?, -- player name or bot name
	CarrierIsPlayer: boolean,
	DropTime: number, -- os.clock() of most recent drop (used for auto-return)
	AttachedAt: number, -- os.clock() when carrier picked up (used for grace delay before re-pickup)
}

local PICKUP_RADIUS = 5 -- studs
local PICKUP_GRACE_AFTER_DROP = 0.4 -- seconds before a dropped Crown becomes eligible for pickup again
local CARRY_OFFSET_Y = 4.5 -- studs above the carrier's head position

local CrownService = Knit.CreateService({
	Name = "CrownService",
	Client = {
		-- Position snapshots + state changes sent to all clients.
		CrownSpawned = Knit.CreateSignal(), -- (position, teamIndex?=nil)
		CrownPickedUp = Knit.CreateSignal(), -- (carrierName, isPlayer, teamIndex)
		CrownDropped = Knit.CreateSignal(), -- (position)
		CrownReturned = Knit.CreateSignal(), -- (position) — auto-return to centroid
		-- NOTE: no per-tick position signal. The Crown Part auto-replicates at 10Hz
		-- (the `_broadcastTick % 6 == 0` CFrame flush below), so clients read the
		-- current carry position straight from `workspace.Crown.PrimaryPart.Position`.
		ScoreUpdate = Knit.CreateSignal(), -- (teamScoresArray)
		TeamWon = Knit.CreateSignal(), -- (teamIndex, teamName, teamColor)
	},

	_state = {
		Name = "Inactive" :: CrownStateName,
		Position = Vector3.zero,
		CarrierName = nil :: string?,
		CarrierIsPlayer = false,
		DropTime = 0,
		AttachedAt = 0,
	} :: CrownState,

	_crownModel = nil :: Model?,
	_crownPart = nil :: BasePart?,
	_teamScores = {} :: { [number]: number }, -- teamIndex -> score
	_lastScoreTick = 0,
	_broadcastTick = 0,
	_heartbeatConnection = nil :: RBXScriptConnection?,
	_roundWon = false,

	-- Server-side signals for RoundService and others to react to.
	TeamWonSignal = Signal.new(), -- (teamIndex)
	CrownPickedUpSignal = Signal.new(), -- (carrierName, isPlayer, teamIndex)
	CrownDroppedSignal = Signal.new(), -- (position)
})

--------------------------------------------------
-- Crown visual
--------------------------------------------------

function CrownService:_createCrownModel(): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Crown"

	-- Pedestal/base part (yellow neon cylinder)
	local crown = Instance.new("Part")
	crown.Name = "CrownBody"
	crown.Shape = Enum.PartType.Cylinder
	crown.Size = Vector3.new(2.5, 4.5, 4.5)
	crown.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(90))
	crown.Anchored = true
	crown.CanCollide = false
	crown.CanQuery = false
	crown.Material = Enum.Material.Neon
	crown.Color = Color3.fromRGB(255, 220, 60)
	crown.Transparency = 0.05
	crown.Parent = model

	-- Top spikes (three small parts for silhouette readability)
	for i = 1, 5 do
		local spike = Instance.new("Part")
		spike.Name = "Spike" .. i
		spike.Shape = Enum.PartType.Ball
		spike.Size = Vector3.new(1, 1, 1)
		local angle = (i - 1) * (2 * math.pi / 5)
		spike.CFrame = CFrame.new(math.cos(angle) * 1.8, 2.5, math.sin(angle) * 1.8)
		spike.Anchored = true
		spike.CanCollide = false
		spike.CanQuery = false
		spike.Material = Enum.Material.Neon
		spike.Color = Color3.fromRGB(255, 240, 100)
		spike.Parent = model
	end

	-- Glow
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 60)
	light.Brightness = 4
	light.Range = 30
	light.Parent = crown

	-- Pillar of light pointing up so the Crown is findable from far away
	local pillar = Instance.new("Part")
	pillar.Name = "CrownPillar"
	pillar.Size = Vector3.new(2, 80, 2)
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = Color3.fromRGB(255, 220, 60)
	pillar.Transparency = 0.7
	pillar.Shape = Enum.PartType.Block
	pillar.CFrame = CFrame.new(0, 40, 0)
	pillar.Parent = model

	-- BillboardGui label
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 40)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = crown

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 24
	label.Text = "CROWN"
	label.TextColor3 = Color3.fromRGB(255, 220, 60)
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard

	model.PrimaryPart = crown
	model.Parent = workspace

	return model, crown
end

function CrownService:_destroyCrownModel()
	if self._crownModel then
		self._crownModel:Destroy()
		self._crownModel = nil
		self._crownPart = nil
	end
end

function CrownService:_positionCrownModel(pos: Vector3)
	local model = self._crownModel
	if not model or not model.PrimaryPart then
		return
	end
	model:PivotTo(CFrame.new(pos))
end

-- Toggle the "beacon" visuals (pillar beam, point light glow, big "CROWN" label)
-- that make the Crown findable while on the ground. When carried, these become
-- distracting — the crown is already visibly stuck to the carrier's head.
function CrownService:_setBeaconVisible(visible: boolean)
	local model = self._crownModel
	if not model then
		return
	end
	local pillar = model:FindFirstChild("CrownPillar") :: BasePart?
	if pillar then
		pillar.Transparency = if visible then 0.7 else 1
	end
	local crown = model.PrimaryPart
	if crown then
		local light = crown:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = visible
		end
		local billboard = crown:FindFirstChildOfClass("BillboardGui")
		if billboard then
			billboard.Enabled = visible
		end
	end
end

--------------------------------------------------
-- State transitions
--------------------------------------------------

function CrownService:_setDropped(pos: Vector3, isAutoReturn: boolean)
	self._state.Name = "Dropped"
	self._state.Position = pos
	self._state.CarrierName = nil
	self._state.CarrierIsPlayer = false
	self._state.DropTime = os.clock()
	self._state.AttachedAt = 0

	-- Restore the beacon visuals so the dropped crown is easy to spot from far away.
	self:_setBeaconVisible(true)
	self:_positionCrownModel(pos)
	if isAutoReturn then
		self.Client.CrownReturned:FireAll(pos)
	else
		self.Client.CrownDropped:FireAll(pos)
		self.CrownDroppedSignal:Fire(pos)
	end
end

function CrownService:_setCarried(carrierName: string, isPlayer: boolean)
	self._state.Name = "Carried"
	self._state.CarrierName = carrierName
	self._state.CarrierIsPlayer = isPlayer
	self._state.AttachedAt = os.clock()

	-- Kill the pillar beam / point light / "CROWN" billboard while carried.
	-- The crown is already visibly pinned to the worm's head by the client loop,
	-- so the extra beacon visuals just clutter the scene and draw aggro.
	self:_setBeaconVisible(false)

	local teamIndex: number = 0
	if TeamService and TeamService:IsEnabled() then
		teamIndex = TeamService:GetTeamForMember(carrierName) or 0
	end
	self.Client.CrownPickedUp:FireAll(carrierName, isPlayer, teamIndex)
	self.CrownPickedUpSignal:Fire(carrierName, isPlayer, teamIndex)
end

--------------------------------------------------
-- Position queries
--------------------------------------------------

-- Returns the current carrier's head position (nil if none or missing).
function CrownService:_getCarrierHeadPosition(): Vector3?
	local state = self._state
	if state.Name ~= "Carried" or not state.CarrierName then
		return nil
	end
	if state.CarrierIsPlayer then
		local player = Players:FindFirstChild(state.CarrierName) :: Player?
		if not player then
			return nil
		end
		local wormData = WormService:GetWormData_Server(player)
		if not wormData or wormData.State ~= "Alive" then
			return nil
		end
		return wormData.HeadPosition
	else
		return BotService:GetBotHeadPosition(state.CarrierName)
	end
end

-- Iterate all alive worms (players + bots) and call `fn(name, isPlayer, headPos, teamIndex)`.
function CrownService:_forEachAliveWorm(fn: (string, boolean, Vector3, number) -> ())
	-- Players
	for _, player in WormService:GetAlivePlayers() do
		local wd = WormService:GetWormData_Server(player)
		if wd and wd.State == "Alive" then
			local teamIndex = 0
			if TeamService and TeamService:IsEnabled() then
				teamIndex = TeamService:GetTeamForMember(player.Name) or 0
			end
			fn(player.Name, true, wd.HeadPosition, teamIndex)
		end
	end
	-- Bots
	for _, botName in BotService:GetAliveBotNames() do
		local pos = BotService:GetBotHeadPosition(botName)
		if pos then
			local teamIndex = 0
			if TeamService and TeamService:IsEnabled() then
				teamIndex = TeamService:GetTeamForMember(botName) or 0
			end
			fn(botName, false, pos, teamIndex)
		end
	end
end

--------------------------------------------------
-- Pickup detection
--------------------------------------------------

function CrownService:_checkPickup()
	if self._state.Name ~= "Dropped" then
		return
	end
	if os.clock() - self._state.DropTime < PICKUP_GRACE_AFTER_DROP then
		return
	end

	local crownPos = self._state.Position
	local bestName: string? = nil
	local bestIsPlayer = false
	local bestDist = PICKUP_RADIUS

	self:_forEachAliveWorm(function(name: string, isPlayer: boolean, headPos: Vector3, _teamIndex: number)
		local d = (headPos - crownPos).Magnitude
		if d < bestDist then
			bestDist = d
			bestName = name
			bestIsPlayer = isPlayer
		end
	end)

	if bestName then
		self:_setCarried(bestName, bestIsPlayer)
	end
end

function CrownService:_checkAutoReturn()
	if self._state.Name ~= "Dropped" then
		return
	end
	local elapsed = os.clock() - self._state.DropTime
	if elapsed >= WormConfig.WormKing.CrownLostResetDelay then
		local centroid = TeamBase.getCentroid()
		self:_setDropped(centroid, true)
	end
end

--------------------------------------------------
-- Scoring
--------------------------------------------------

function CrownService:_tickScoring(dt: number)
	if self._state.Name ~= "Carried" then
		return
	end
	if self._roundWon then
		return
	end

	local carrierName = self._state.CarrierName
	if not carrierName then
		return
	end

	local teamIndex: number? = nil
	if TeamService and TeamService:IsEnabled() then
		teamIndex = TeamService:GetTeamForMember(carrierName)
	end
	if not teamIndex or teamIndex <= 0 then
		return
	end

	local perSec = WormConfig.WormKing.CrownScorePerSec
	self._teamScores[teamIndex] = (self._teamScores[teamIndex] or 0) + perSec * dt

	-- Check score win condition
	local threshold = WormConfig.WormKing.ScoreThreshold
	if self._teamScores[teamIndex] >= threshold then
		self._roundWon = true
		self.Client.TeamWon:FireAll(teamIndex)
		self.TeamWonSignal:Fire(teamIndex)
	end
end

function CrownService:_buildScoreSnapshot(): { { TeamIndex: number, Score: number } }
	local snapshot = {}
	for idx = 1, #WormConfig.TeamColors do
		local s = self._teamScores[idx] or 0
		table.insert(snapshot, { TeamIndex = idx, Score = math.floor(s) })
	end
	return snapshot
end

function CrownService:_broadcastScore()
	self.Client.ScoreUpdate:FireAll(self:_buildScoreSnapshot())
end

function CrownService:GetScoreSnapshot(): { { TeamIndex: number, Score: number } }
	return self:_buildScoreSnapshot()
end

--------------------------------------------------
-- Public API
--------------------------------------------------

-- Called by RoundService at round start: reset state, respawn Crown at centroid.
function CrownService:ResetAndSpawn()
	self._roundWon = false
	for i = 1, #WormConfig.TeamColors do
		self._teamScores[i] = 0
	end

	self:_destroyCrownModel()
	local model, crownPart = self:_createCrownModel()
	self._crownModel = model
	self._crownPart = crownPart

	local centroid = TeamBase.getCentroid()
	self:_setDropped(centroid, false) -- fires CrownDropped; use separate Spawned signal for HUD
	self.Client.CrownSpawned:FireAll(centroid)
	self:_broadcastScore()
end

-- Called by RoundService at round end: hide Crown until next round.
function CrownService:Despawn()
	self._state.Name = "Inactive"
	self._state.CarrierName = nil
	self._state.CarrierIsPlayer = false
	self:_destroyCrownModel()
end

-- Called externally when the carrier dies. Drops the Crown at the provided
-- position (usually the carrier's last head position) so the Crown doesn't
-- teleport to wherever the next frame's cached position ends up.
function CrownService:OnCarrierDeath(carrierName: string, dropPos: Vector3?)
	if self._state.Name ~= "Carried" or self._state.CarrierName ~= carrierName then
		return
	end
	local pos = dropPos or self._state.Position
	-- Snap to terrain so the crown sits on the ground on drop
	pos = Vector3.new(pos.X, TerrainHeight.getSmoothSurfaceY(pos.X, pos.Z) + 1.5, pos.Z)
	self:_setDropped(pos, false)
end

function CrownService:GetState(): CrownState
	return self._state
end

function CrownService:IsCarriedBy(name: string): boolean
	return self._state.Name == "Carried" and self._state.CarrierName == name
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function CrownService.Client:GetState(_player: Player): {
	StateName: string,
	Position: { number },
	CarrierName: string?,
	CarrierIsPlayer: boolean,
	Scores: { { TeamIndex: number, Score: number } },
}
	local state = self.Server._state
	return {
		StateName = state.Name,
		Position = { state.Position.X, state.Position.Y, state.Position.Z },
		CarrierName = state.CarrierName,
		CarrierIsPlayer = state.CarrierIsPlayer,
		Scores = self.Server:_buildScoreSnapshot(),
	}
end

--------------------------------------------------
-- Heartbeat loop
--------------------------------------------------

function CrownService:_heartbeat(dt: number)
	self._broadcastTick += 1

	if self._state.Name == "Carried" then
		-- Attach to carrier's head every frame (data side); write Part CFrame at 10Hz.
		local headPos = self:_getCarrierHeadPosition()
		if not headPos then
			-- Carrier vanished without a death signal — drop at last known pos
			self:OnCarrierDeath(self._state.CarrierName or "", self._state.Position)
		else
			self._state.Position = headPos + Vector3.new(0, CARRY_OFFSET_Y, 0)
		end
		self:_tickScoring(dt)
	elseif self._state.Name == "Dropped" then
		self:_checkPickup()
		self:_checkAutoReturn()
	end

	-- Flush Part CFrame at 10Hz to match replication budget.
	-- While carried, we intentionally skip the server flush: the client runs a
	-- RenderStepped loop that pins the crown to the carrier's head every frame
	-- locally, which avoids the 10Hz jumping that replicated writes would cause.
	if self._crownModel and self._crownPart and self._state.Name ~= "Carried" and self._broadcastTick % 6 == 0 then
		self:_positionCrownModel(self._state.Position)
	end

	-- Score broadcasts at 2Hz. Position is carried by the Crown Part's auto-replication
	-- (flushed above at 10Hz) — no separate signal needed.
	if os.clock() - self._lastScoreTick >= 0.5 then
		self._lastScoreTick = os.clock()
		if self._state.Name ~= "Inactive" then
			self:_broadcastScore()
		end
	end
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function CrownService:KnitInit()
	for i = 1, #WormConfig.TeamColors do
		self._teamScores[i] = 0
	end
end

function CrownService:KnitStart()
	WormService = require(script.Parent.WormService)
	BotService = require(script.Parent.BotService)
	TeamService = require(script.Parent.TeamService)

	-- React to carrier deaths (both players and bots).
	WormService.PlayerDied:Connect(function(deadPlayer: Player, _killerName: string?)
		if self._state.Name == "Carried" and self._state.CarrierName == deadPlayer.Name then
			local wd = WormService:GetWormData_Server(deadPlayer)
			local dropPos = if wd then wd.HeadPosition else self._state.Position
			self:OnCarrierDeath(deadPlayer.Name, dropPos)
		end
	end)

	BotService.BotKilled:Connect(function(botName: string, _killerName: string?)
		if self._state.Name == "Carried" and self._state.CarrierName == botName then
			-- Bot's head pos may already be gone; use last known crown pos as fallback
			local pos = BotService:GetBotHeadPosition(botName) or self._state.Position
			self:OnCarrierDeath(botName, pos)
		end
	end)

	self._heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
		self:_heartbeat(dt)
	end)
end

return CrownService
