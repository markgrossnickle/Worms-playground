--!strict
--
-- SandTideService — Worm King map contraction (Phase 5).
--
-- The equilateral triangle inscribed in the arena shrinks from scale 1.0 down
-- to SandTideMinScale across the match timeline:
--
--   [0, SandTideStart)            -> scale 1.0 (no tide)
--   [SandTideStart, FastPhase)    -> linear 1.0 → 0.5 (slow)
--   [FastPhase, SandTideEnd)      -> linear 0.5 → MinScale (fast)
--   [SandTideEnd, ∞)              -> MinScale (fully contracted)
--
-- A worm (player or bot) whose head is outside the current triangle AND not in
-- any team's scaled base safe-zone takes SandTideDamagePerSec HP/sec.
--
-- Bases physically ride the scale — WormService / BotService fetch spawn
-- positions via `getScaledSpawnPosition(teamIndex, GetScale())`.
--
-- Service is only active when TeamService:IsEnabled() (Worm King mode).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local TeamBase = require(ReplicatedStorage.Shared.TeamBase)
local TerrainHeight = require(ReplicatedStorage.Shared.TerrainHeight)

local WormService -- set in KnitStart
local BotService -- set in KnitStart
local TeamService -- set in KnitStart
local RoundService -- set in KnitStart

local CLIENT_UPDATE_INTERVAL = 0.5 -- broadcast scale to clients at 2Hz
local DAMAGE_TICK_INTERVAL = 1.0 -- apply tide damage at 1Hz

-- Triangle edge tuning — the edges ARE the physical arena boundary in Worm King
-- mode (CanCollide=true), replacing the old square walls. Height matches the old
-- walls so ghosts can't hop out; thickness bumped for reliable collision.
local EDGE_HEIGHT = 40 -- studs tall — matches old square boundary walls
local EDGE_THICKNESS = 4 -- studs — thick enough for reliable physical collision
local EDGE_COLOR = Color3.fromRGB(255, 180, 80) -- sandy orange
local EDGE_TRANSPARENCY = 0.35

local SandTideService = Knit.CreateService({
	Name = "SandTideService",
	Client = {
		ScaleUpdate = Knit.CreateSignal(), -- (scale)
		TideWarning = Knit.CreateSignal(), -- (message)
	},

	_scale = 1.0,
	_lastClientUpdate = 0,
	_lastDamageTick = 0,
	_lastEdgeUpdate = 0,
	_warnedStart = false,
	_warnedFast = false,
	_heartbeatConn = nil :: RBXScriptConnection?,
	_edgeFolder = nil :: Folder?,
	_edgeParts = {} :: { BasePart },
})

--------------------------------------------------
-- Scale progression
--------------------------------------------------

local function computeScale(elapsed: number): number
	local C = WormConfig.WormKing
	if elapsed < C.SandTideStart then
		return 1.0
	end
	if elapsed >= C.SandTideEnd then
		return C.SandTideMinScale
	end
	if elapsed < C.SandTideFastPhase then
		-- slow phase: 1.0 → 0.5 over [Start, FastPhase)
		local t = (elapsed - C.SandTideStart) / (C.SandTideFastPhase - C.SandTideStart)
		return 1.0 + (0.5 - 1.0) * t
	end
	-- fast phase: 0.5 → MinScale over [FastPhase, End)
	local t = (elapsed - C.SandTideFastPhase) / (C.SandTideEnd - C.SandTideFastPhase)
	return 0.5 + (C.SandTideMinScale - 0.5) * t
end

function SandTideService:GetScale(): number
	return self._scale
end

--------------------------------------------------
-- 3D triangle edge walls
--
-- Three glowing wall segments trace the inscribed equilateral triangle. They
-- ride the sand-tide scale so players can see (and physically feel) the
-- boundary contract in real time. In Worm King mode these ARE the arena
-- boundary — the old square BoundaryWalls are skipped in WormService.
-- Created once in KnitStart, repositioned every time the scale changes
-- (throttled to 2Hz so we aren't writing CFrame every heartbeat).
--------------------------------------------------

function SandTideService:_createEdges()
	local folder = Instance.new("Folder")
	folder.Name = "SandTideBoundary"
	folder.Parent = workspace
	self._edgeFolder = folder

	for i = 1, 3 do
		local part = Instance.new("Part")
		part.Name = "TriEdge" .. i
		part.Anchored = true
		-- Physical boundary: worms and ghosts collide with the triangle edges.
		-- CanQuery stays false so weapon raycasts pass through the wall.
		part.CanCollide = true
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = EDGE_COLOR
		part.Transparency = EDGE_TRANSPARENCY
		part.Parent = folder
		self._edgeParts[i] = part
	end

	self:_updateEdgeVisual()
end

function SandTideService:_updateEdgeVisual()
	local verts = TeamBase.getScaledVertices(self._scale)
	for i = 1, 3 do
		local a = verts[i]
		local b = verts[(i % 3) + 1]
		local edge = self._edgeParts[i]
		if not edge or not edge.Parent then
			continue
		end
		local midXZ = (a + b) * 0.5
		local dir = b - a
		local length = dir.Magnitude
		if length < 0.01 then
			continue
		end
		-- Sample terrain at midpoint so the wall sits on the ground; height is
		-- fixed (dune variation along the edge is acceptable for a sand wall).
		local terrainY = TerrainHeight.getHeight(midXZ.X, midXZ.Z)
		local centerY = terrainY + EDGE_HEIGHT / 2
		local yaw = math.atan2(dir.X, dir.Z) -- rotate so part's +Z points along the edge
		edge.Size = Vector3.new(EDGE_THICKNESS, EDGE_HEIGHT, length)
		edge.CFrame = CFrame.new(midXZ.X, centerY, midXZ.Z) * CFrame.Angles(0, yaw, 0)
	end
end

--------------------------------------------------
-- Damage tick
--------------------------------------------------

local function inAnyScaledSafeZone(pos: Vector3, scale: number): boolean
	for i = 1, 3 do
		if TeamBase.isInsideScaledSafeZone(i, pos, scale) then
			return true
		end
	end
	return false
end

function SandTideService:_applyDamageTick()
	if not WormService or not BotService then
		return
	end
	local scale = self._scale
	local dmg = WormConfig.WormKing.SandTideDamagePerSec

	-- Player worms
	for _, player in WormService:GetAlivePlayers() do
		local data = WormService:GetWormData_Server(player)
		if not data then
			continue
		end
		local head = data.HeadPosition
		if not head then
			continue
		end
		if TeamBase.isInsideTriangle(head.X, head.Z, scale) then
			continue
		end
		if inAnyScaledSafeZone(head, scale) then
			continue
		end
		WormService:DamageWorm(player, dmg, nil)
	end

	-- Bots
	for _, botName in BotService:GetAliveBotNames() do
		local headPos = BotService:GetBotHeadPosition(botName)
		if not headPos then
			continue
		end
		if TeamBase.isInsideTriangle(headPos.X, headPos.Z, scale) then
			continue
		end
		if inAnyScaledSafeZone(headPos, scale) then
			continue
		end
		BotService:DamageBot(botName, dmg, nil)
	end
end

--------------------------------------------------
-- Per-heartbeat update
--------------------------------------------------

function SandTideService:_update()
	if not TeamService or not TeamService:IsEnabled() then
		return
	end
	if not RoundService or not RoundService:IsRoundActive() then
		return
	end

	local elapsed = RoundService:GetRoundElapsed()
	self._scale = computeScale(elapsed)

	local C = WormConfig.WormKing

	-- Warnings: 10s prior to start of slow phase and 10s prior to fast phase
	if not self._warnedStart and elapsed >= C.SandTideStart - 10 and elapsed < C.SandTideStart then
		self._warnedStart = true
		self.Client.TideWarning:FireAll("Sand tide rising in 10s!")
	end
	if not self._warnedFast and elapsed >= C.SandTideFastPhase - 10 and elapsed < C.SandTideFastPhase then
		self._warnedFast = true
		self.Client.TideWarning:FireAll("Sand tide accelerating!")
	end

	local now = os.clock()

	-- Broadcast scale + reposition the 3D triangle edges at 2Hz.
	-- Server writes three Part CFrames which auto-replicate at the normal
	-- networking budget — 10Hz is overkill for something that only changes
	-- when the scale tweens by fractions of a stud.
	if now - self._lastClientUpdate >= CLIENT_UPDATE_INTERVAL then
		self._lastClientUpdate = now
		self.Client.ScaleUpdate:FireAll(self._scale)
		self:_updateEdgeVisual()
	end

	-- Damage tick at 1Hz (only once contraction has actually started)
	if elapsed >= C.SandTideStart and now - self._lastDamageTick >= DAMAGE_TICK_INTERVAL then
		self._lastDamageTick = now
		self:_applyDamageTick()
	end
end

--------------------------------------------------
-- Round lifecycle hook
--------------------------------------------------

function SandTideService:Reset()
	self._scale = 1.0
	self._lastClientUpdate = 0
	self._lastDamageTick = 0
	self._warnedStart = false
	self._warnedFast = false
	self.Client.ScaleUpdate:FireAll(self._scale)
	self:_updateEdgeVisual()
end

--------------------------------------------------
-- Client-side state seeding
--------------------------------------------------

function SandTideService.Client:GetScale(_player: Player): number
	return self.Server._scale
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function SandTideService:KnitInit() end

function SandTideService:KnitStart()
	WormService = require(script.Parent.WormService)
	BotService = require(script.Parent.BotService)
	TeamService = require(script.Parent.TeamService)
	RoundService = require(script.Parent.RoundService)

	-- Triangle edges are only relevant in Worm King mode; in solo mode the
	-- sand tide doesn't run, so spawning the parts would just be clutter.
	if TeamService and TeamService:IsEnabled() then
		self:_createEdges()
	end

	self._heartbeatConn = RunService.Heartbeat:Connect(function()
		self:_update()
	end)
end

return SandTideService
