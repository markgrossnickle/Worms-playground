--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local TerrainHeight = require(ReplicatedStorage.Shared.TerrainHeight)
local TeamBase = require(ReplicatedStorage.Shared.TeamBase)

local WormService -- Set in KnitStart via require
local PowerUpService -- Set in KnitStart via require
local ShrinkZoneService -- Set in KnitStart via require
local TeamService -- Set in KnitStart via require
local SandTideService -- Set in KnitStart via require

local HALF_ARENA = WormConfig.ArenaSize / 2
local MIN_RECORD_DISTANCE = 0.5
local ENTRIES_PER_SEGMENT = math.ceil(WormConfig.SegmentSpacing / MIN_RECORD_DISTANCE)

local BOT_SEGMENT_LERP_DURATION = 0.4
local BOT_SEGMENT_LERP_DELAY = 0.08

local TARGET_TOTAL_WORMS = 24
local FOOD_SEEK_RANGE = 30
local POWERUP_SEEK_RANGE = 20
local FLEE_RANGE = 20
local CHASE_RANGE = 15
local DIRECTION_CHANGE_MIN = 1
local DIRECTION_CHANGE_MAX = 3
local BOOST_CHANCE = 0.1
local BOOST_DURATION_MIN = 0.5
local BOOST_DURATION_MAX = 2
local SPAWN_CHECK_INTERVAL = 2

-- Random UserIds for bot avatar heads (diverse catalog of real Roblox avatars)
local BOT_AVATAR_IDS = {
	1,
	2,
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	156,
	261,
	4042,
	13656,
	36498,
	50210,
	71608,
	80254,
	95382,
	123456,
	261035,
	370580,
	491633,
	567811,
	698704,
	812341,
	929020,
	1087263,
	1234567,
	2345678,
}

local BOT_NAMES = {
	"Slinky",
	"Noodle",
	"Zigzag",
	"Speedy",
	"Wiggle",
	"Slither",
	"Chompy",
	"Fang",
	"Viper",
	"Cobra",
	"Python",
	"Mamba",
	"Sidewinder",
	"Rattler",
	"Coil",
	"Twister",
	"Squirm",
	"Crawler",
	"Glider",
	"Snapper",
}

type BotData = {
	Name: string,
	Model: Model,
	State: string,
	Segments: number,
	MaxSegments: number,
	Direction: Vector3, -- Target direction (set by AI)
	CurrentDirection: Vector3, -- Actual facing direction (interpolated toward Direction)
	Boosting: boolean,
	Color: Color3,
	Kills: number,
	PositionHistory: { [number]: Vector3 },
	HistoryStart: number,
	HistoryEnd: number,
	LastRecordedPos: Vector3,
	NextDirectionChange: number,
	BoostEndTime: number,
	LerpingSegments: { [number]: { StartTime: number, StartPos: Vector3 } }?, -- indices currently lerping after mid-body hit
	-- Bandwidth optimization: server-side source-of-truth positions.
	-- Updated every Heartbeat, but only flushed to Parts at 10Hz to reduce replication.
	HeadPosition: Vector3,
	HeadDirection: Vector3,
	SegmentPositions: { [number]: Vector3 },
}

local BotService = Knit.CreateService({
	Name = "BotService",
	Client = {},

	_bots = {} :: { [string]: BotData },
	_usedNames = {} :: { [string]: boolean },
	_roundActive = false,
	_roundBotStats = {} :: { [string]: { Kills: number, MaxSegments: number } },
	_broadcastTick = 0,

	BotKilled = Signal.new(),
})

--------------------------------------------------
-- Helpers
--------------------------------------------------

local function randomArenaPosition(): Vector3
	-- Spawn within a circle (not square) so bots don't land outside the zone
	local margin = 50
	local maxRadius = HALF_ARENA - margin
	local angle = math.random() * math.pi * 2
	local dist = math.sqrt(math.random()) * maxRadius
	local x = math.cos(angle) * dist
	local z = math.sin(angle) * dist
	return Vector3.new(x, TerrainHeight.getSmoothSurfaceY(x, z) + WormConfig.SegmentSize / 2, z)
end

local function randomColor(): Color3
	return Color3.fromHSV(math.random(), 0.8, 0.9)
end

local function randomDirection(): Vector3
	local angle = math.random() * math.pi * 2
	return Vector3.new(math.cos(angle), 0, math.sin(angle)).Unit
end

--------------------------------------------------
-- Bot model creation
--------------------------------------------------

function BotService:_createBotModel(name: string, color: Color3, spawnPos: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("IsBotWorm", true)

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 2)
	hrp.Transparency = 1
	hrp.Anchored = true
	hrp.CanCollide = false
	hrp.CanQuery = false -- Don't block weapon raycasts
	hrp.CFrame = CFrame.new(spawnPos)
	hrp.Parent = model
	model.PrimaryPart = hrp

	-- Bot head: load a random Roblox avatar head from catalog
	local headSize = WormConfig.SegmentSize + 0.5
	local wormHead: BasePart = nil

	-- Try to load a random avatar head
	local avatarUserId = BOT_AVATAR_IDS[math.random(1, #BOT_AVATAR_IDS)]
	local avatarLoaded = false

	local success, avatarModel = pcall(function()
		return Players:CreateHumanoidModelFromUserId(avatarUserId)
	end)

	if success and avatarModel then
		local avatarHead = avatarModel:FindFirstChild("Head")
		if avatarHead and avatarHead:IsA("BasePart") then
			wormHead = avatarHead:Clone()
			wormHead.Name = "WormHead"
			wormHead.Size = Vector3.new(headSize, headSize, headSize)
			wormHead.Anchored = true
			wormHead.CanCollide = false
			wormHead.CanQuery = false
			wormHead.CFrame = CFrame.new(spawnPos)

			-- Remove any Motor6D joints from the cloned head
			for _, child in wormHead:GetDescendants() do
				if child:IsA("Motor6D") or child:IsA("Weld") then
					child:Destroy()
				end
			end

			-- Keep face decals and mesh, clone accessories attached to head
			for _, child in avatarModel:GetDescendants() do
				if child:IsA("Accessory") then
					local handle = child:FindFirstChild("Handle")
					if handle then
						local att = handle:FindFirstChildOfClass("Attachment")
						if
							att and att.Name:find("Hat")
							or att and att.Name:find("Hair")
							or att and att.Name:find("Face")
						then
							local accClone = child:Clone()
							accClone.Parent = wormHead
						end
					end
				end
			end

			avatarLoaded = true
		end
		avatarModel:Destroy()
	end

	-- Fallback: classic Roblox head mesh if avatar loading fails
	if not avatarLoaded then
		wormHead = Instance.new("Part")
		wormHead.Name = "WormHead"
		wormHead.Size = Vector3.new(headSize, headSize, headSize)
		wormHead.Color = color
		wormHead.Material = Enum.Material.SmoothPlastic
		wormHead.Transparency = 0
		wormHead.Anchored = true
		wormHead.CanCollide = false
		wormHead.CFrame = CFrame.new(spawnPos)

		local headMesh = Instance.new("SpecialMesh")
		headMesh.MeshType = Enum.MeshType.Head
		headMesh.Scale = Vector3.new(1.25, 1.25, 1.25)
		headMesh.Parent = wormHead

		local face = Instance.new("Decal")
		face.Name = "face"
		face.Texture = "rbxasset://textures/face.png"
		face.Face = Enum.NormalId.Front
		face.Parent = wormHead
	end

	wormHead.Parent = model

	-- Name billboard above head so bots are distinguishable
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameLabel"
	billboard.Size = UDim2.new(0, 120, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = wormHead

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = name
	nameLabel.TextColor3 = color
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Parent = billboard

	local segFolder = Instance.new("Folder")
	segFolder.Name = "WormSegments"
	segFolder.Parent = model

	model.Parent = workspace
	return model
end

function BotService:_createSegment(botData: BotData, index: number)
	local model = botData.Model
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local segFolder = model:FindFirstChild("WormSegments") :: Folder?
	if not hrp or not segFolder then
		return
	end

	local seg = Instance.new("Part")
	seg.Name = "Segment" .. index
	seg.Shape = Enum.PartType.Ball
	seg.Size = Vector3.new(WormConfig.SegmentSize, WormConfig.SegmentSize, WormConfig.SegmentSize)
	seg.Anchored = true
	seg.CanCollide = false
	seg.Material = Enum.Material.SmoothPlastic
	seg.Color = botData.Color
	seg:SetAttribute("MaxHP", WormConfig.SegmentHP)
	seg:SetAttribute("HP", WormConfig.SegmentHP)

	-- Prefer server-side HeadPosition (updated every Heartbeat) over hrp.Position
	-- which only reflects the most recent 10Hz flush.
	local headPos = if botData.HeadPosition ~= Vector3.zero then botData.HeadPosition else hrp.Position
	if botData.HistoryEnd >= botData.HistoryStart then
		local histIndex = botData.HistoryEnd - index * ENTRIES_PER_SEGMENT
		if histIndex >= botData.HistoryStart and botData.PositionHistory[histIndex] then
			seg.Position = botData.PositionHistory[histIndex]
		else
			seg.Position = headPos - botData.Direction * (index * WormConfig.SegmentSpacing)
		end
	else
		seg.Position = headPos - Vector3.new(0, 0, index * WormConfig.SegmentSpacing)
	end

	-- Seed the SegmentPositions data table so the source of truth matches the Part.
	botData.SegmentPositions[index] = seg.Position

	seg.Parent = segFolder
end

--------------------------------------------------
-- Position history
--------------------------------------------------

function BotService:_initPositionHistory(botData: BotData, spawnPos: Vector3)
	botData.PositionHistory = {}
	botData.HistoryStart = 1
	botData.HistoryEnd = 0

	local numEntries = (WormConfig.InitialSegments + 1) * ENTRIES_PER_SEGMENT
	for j = numEntries, 0, -1 do
		local behindDist = j * MIN_RECORD_DISTANCE
		local pos = spawnPos - botData.Direction * behindDist
		botData.HistoryEnd += 1
		botData.PositionHistory[botData.HistoryEnd] =
			Vector3.new(pos.X, TerrainHeight.getSmoothSurfaceY(pos.X, pos.Z) + WormConfig.SegmentSize / 2, pos.Z)
	end

	botData.LastRecordedPos = spawnPos
end

function BotService:_recordPosition(botData: BotData, pos: Vector3)
	local distMoved = (pos - botData.LastRecordedPos).Magnitude
	if distMoved < MIN_RECORD_DISTANCE then
		return
	end

	botData.HistoryEnd += 1
	botData.PositionHistory[botData.HistoryEnd] = pos
	botData.LastRecordedPos = pos

	local maxEntries = (math.ceil(botData.Segments) + 2) * ENTRIES_PER_SEGMENT
	local trimTo = botData.HistoryEnd - maxEntries
	while botData.HistoryStart <= trimTo do
		botData.PositionHistory[botData.HistoryStart] = nil
		botData.HistoryStart += 1
	end
end

--------------------------------------------------
-- Bot lifecycle
--------------------------------------------------

function BotService:_pickBotName(): string
	for _, name in BOT_NAMES do
		if not self._usedNames[name] then
			self._usedNames[name] = true
			return name
		end
	end
	local name = "Bot" .. math.random(1000, 9999)
	self._usedNames[name] = true
	return name
end

function BotService:_spawnBot()
	local name = self:_pickBotName()
	local color = randomColor()

	-- Worm King: assign team FIRST so spawn pos + facing can use it.
	local teamIndex: number? = nil
	if TeamService:IsEnabled() then
		teamIndex = TeamService:AssignToTeam(name)
	end

	-- Spawn at the team base if teamed; face toward centroid. Fall back to random otherwise.
	local spawnPos: Vector3
	local direction: Vector3
	if teamIndex and teamIndex > 0 then
		-- Bases ride the sand tide scale — use current scale for spawn positioning.
		local scale = if SandTideService then SandTideService:GetScale() else 1.0
		spawnPos = TeamBase.getScaledSpawnPosition(teamIndex, scale, nil)
		-- Facing direction is invariant under uniform scale about origin (centroid).
		local baseXZ = TeamBase.getBasePositionXZ(teamIndex)
		local toCenter = Vector3.new(-baseXZ.X, 0, -baseXZ.Z)
		direction = if toCenter.Magnitude > 0.001 then toCenter.Unit else randomDirection()
	else
		spawnPos = randomArenaPosition()
		direction = randomDirection()
	end

	local model = self:_createBotModel(name, color, spawnPos)

	local botData: BotData = {
		Name = name,
		Model = model,
		State = "Alive",
		Segments = WormConfig.InitialSegments,
		MaxSegments = WormConfig.InitialSegments,
		Direction = direction,
		CurrentDirection = direction,
		Boosting = false,
		Color = color,
		Kills = 0,
		PositionHistory = {},
		HistoryStart = 1,
		HistoryEnd = 0,
		LastRecordedPos = Vector3.zero,
		NextDirectionChange = os.clock() + math.random() * DIRECTION_CHANGE_MAX + DIRECTION_CHANGE_MIN,
		BoostEndTime = 0,
		HeadPosition = Vector3.zero,
		HeadDirection = Vector3.new(0, 0, -1),
		SegmentPositions = {},
	}

	self:_initPositionHistory(botData, spawnPos)

	-- Seed the bandwidth-optimization head data with the actual spawn pose.
	botData.HeadPosition = spawnPos
	botData.HeadDirection = direction

	for i = 1, WormConfig.InitialSegments do
		self:_createSegment(botData, i)
	end
	-- _createSegment seeds botData.SegmentPositions[i] internally.

	self._bots[name] = botData
	WormService:RegisterBot(name, model, botData.Segments)

	-- Apply team color (team assignment already happened above, before spawn pos calc)
	if teamIndex and teamIndex > 0 then
		local teamColor = TeamService:GetTeamColor(teamIndex)
		if teamColor then
			botData.Color = teamColor
			-- Recolor head and segments
			local wormHead = model:FindFirstChild("WormHead") :: BasePart?
			if wormHead then
				wormHead.Color = teamColor
				-- Update name label color
				local billboard = wormHead:FindFirstChild("NameLabel")
				if billboard then
					local nameLabel = billboard:FindFirstChildOfClass("TextLabel")
					if nameLabel then
						nameLabel.TextColor3 = teamColor
					end
				end
			end
			local segFolder = model:FindFirstChild("WormSegments") :: Folder?
			if segFolder then
				for _, seg in segFolder:GetChildren() do
					if seg:IsA("BasePart") then
						seg.Color = teamColor
					end
				end
			end
		end
	end
end

function BotService:_killBot(botName: string, killerName: string?)
	local botData = self._bots[botName]
	if not botData or botData.State ~= "Alive" then
		return
	end

	-- Shield power-up: consume shield instead of dying
	if PowerUpService:ConsumeShield(botName) then
		return
	end

	botData.State = "Dead"

	-- Save round stats before cleanup
	self._roundBotStats[botName] = {
		Kills = botData.Kills,
		MaxSegments = math.floor(botData.MaxSegments),
	}

	-- Credit killer (look up killer as bot or player)
	if killerName then
		-- Check if killer is a bot
		local killerBot = self._bots[killerName]
		if killerBot and killerBot.State == "Alive" then
			killerBot.Kills += 1
		end
		-- Player kill crediting is handled in WormService._killWorm
	end

	-- Clear any active power-up
	PowerUpService:ClearActivePowerUp(botName)

	local segmentsToDrop = math.floor(botData.Segments * 0.7)
	WormService:DropFoodFromModel(botData.Model, segmentsToDrop)

	WormService:FireBotDeath(botName, killerName)
	WormService:UnregisterBot(botName)

	-- Remove from team
	if TeamService:IsEnabled() then
		TeamService:RemoveFromTeam(botName)
	end

	botData.Model:Destroy()

	self._usedNames[botName] = nil
	self._bots[botName] = nil

	-- Fire signal for RoundService to track eliminations
	self.BotKilled:Fire(botName, killerName)
end

function BotService:DamageBot(
	botName: string,
	damage: number,
	killerName: string?,
	hitSegmentIndex: number?,
	isWeaponHit: boolean?
)
	local botData = self._bots[botName]
	if not botData or botData.State ~= "Alive" then
		return
	end

	local model = botData.Model
	local prevFloor = math.floor(botData.Segments)
	if damage <= 0 or prevFloor <= 0 then
		return
	end

	local segFolder = model:FindFirstChild("WormSegments") :: Folder?

	-- Weapon hits deplete segment HP starting at the hit segment and cascade toward tail.
	-- Non-weapon damage (collisions, shrink zone) still removes whole tail segments.
	local removeStart: number
	local removeEnd: number
	local actualRemoved = 0

	if isWeaponHit and hitSegmentIndex and hitSegmentIndex >= 1 and hitSegmentIndex <= prevFloor and segFolder then
		removeStart = hitSegmentIndex + 1
		removeEnd = hitSegmentIndex
		local remaining = damage
		local idx = hitSegmentIndex
		while remaining > 0 and idx <= prevFloor do
			local seg = segFolder:FindFirstChild("Segment" .. idx) :: BasePart?
			if not seg then
				break
			end
			local hp = tonumber(seg:GetAttribute("HP")) or WormConfig.SegmentHP
			if remaining >= hp then
				remaining -= hp
				seg:SetAttribute("HP", 0)
				if actualRemoved == 0 then
					removeStart = idx
				end
				removeEnd = idx
				actualRemoved += 1
				idx += 1
			else
				seg:SetAttribute("HP", hp - remaining)
				remaining = 0
			end
		end

		if actualRemoved == 0 then
			-- Damage absorbed by segment HP — nothing destroyed
			return
		end
	else
		actualRemoved = math.min(damage, prevFloor)
		if actualRemoved <= 0 then
			return
		end
		removeEnd = prevFloor
		removeStart = prevFloor - actualRemoved + 1
	end

	botData.Segments = math.max(0, botData.Segments - actualRemoved)
	local newFloor = math.floor(botData.Segments)

	-- Drop food from removed segment positions
	if actualRemoved > 0 then
		WormService:DropFoodFromModel(model, actualRemoved)
	end

	-- Destroy hit segments and renumber tail to fill the gap
	local isMidBodyHit = isWeaponHit == true and removeEnd < prevFloor
	if segFolder then
		for i = removeStart, removeEnd do
			local seg = segFolder:FindFirstChild("Segment" .. i)
			if seg then
				seg:Destroy()
			end
		end
		if removeEnd < prevFloor then
			for i = removeEnd + 1, prevFloor do
				local seg = segFolder:FindFirstChild("Segment" .. i)
				if seg then
					seg.Name = "Segment" .. (i - actualRemoved)
				end
			end
		end
	end

	-- Rebuild SegmentPositions to match the renumbered Parts so the data table
	-- stays consistent with the visual indices.
	do
		local oldPositions = botData.SegmentPositions
		local newPositions: { [number]: Vector3 } = {}
		for oldIdx, pos in oldPositions do
			if oldIdx >= removeStart and oldIdx <= removeEnd then
				-- Destroyed — drop entry.
				continue
			elseif oldIdx > removeEnd then
				local shifted = oldIdx - actualRemoved
				if shifted >= 1 and shifted <= newFloor then
					newPositions[shifted] = pos
				end
			else
				if oldIdx <= newFloor then
					newPositions[oldIdx] = pos
				end
			end
		end
		botData.SegmentPositions = newPositions
	end

	if isMidBodyHit then
		local oldLerping = botData.LerpingSegments
		local newLerping: { [number]: { StartTime: number, StartPos: Vector3 } } = {}

		-- Shift existing lerp entries down (indices decreased due to renumbering)
		if oldLerping then
			for oldIdx, entry in oldLerping do
				if oldIdx > removeEnd then
					local shifted = oldIdx - actualRemoved
					if shifted >= 1 then
						newLerping[shifted] = entry
					end
				end
			end
		end

		-- Add new lerp entries for segments that just shifted to fill this gap.
		-- Prefer the SegmentPositions data table (source of truth) over Part.Position
		-- since Parts only reflect the most recent 10Hz flush.
		local lerpStartTime = os.clock() + BOT_SEGMENT_LERP_DELAY
		for newIdx = removeStart, prevFloor - actualRemoved do
			if not newLerping[newIdx] then
				local startPos: Vector3 = botData.SegmentPositions[newIdx] or Vector3.zero
				if startPos == Vector3.zero then
					local seg = segFolder and segFolder:FindFirstChild("Segment" .. newIdx) :: BasePart?
					if seg then
						startPos = seg.Position
					end
				end
				newLerping[newIdx] = { StartTime = lerpStartTime, StartPos = startPos }
			end
		end

		botData.LerpingSegments = newLerping
	end

	if newFloor < prevFloor then
		WormService:UpdateBotSegments(botName, newFloor)
	end

	-- Kill if segments reach 0
	if botData.Segments <= 0 then
		self:_killBot(botName, killerName)
	end
end

-- Apply explosion damage to a bot worm. See WormService:ExplodeWorm for the
-- per-segment radial logic — this mirrors it for bots.
function BotService:ExplodeBot(
	botName: string,
	center: Vector3,
	radius: number,
	baseDamage: number,
	killerName: string?
)
	local botData = self._bots[botName]
	if not botData or botData.State ~= "Alive" then
		return
	end
	local segFolder = botData.Model:FindFirstChild("WormSegments") :: Folder?
	if not segFolder then
		return
	end
	local segCount = math.floor(botData.Segments)
	local primaryHit: number? = nil
	local extraDamage = 0
	for i = 1, segCount do
		local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
		-- Use server-side source of truth (Part position only flushed at 10Hz).
		local segPos = botData.SegmentPositions[i] or (seg and seg.Position)
		if seg and segPos and (segPos - center).Magnitude <= radius then
			if not primaryHit then
				primaryHit = i
			else
				local hp = tonumber(seg:GetAttribute("HP")) or WormConfig.SegmentHP
				extraDamage += hp
			end
		end
	end
	if not primaryHit then
		primaryHit = segCount
	end
	self:DamageBot(botName, baseDamage + extraDamage, killerName, primaryHit, true)
end

--------------------------------------------------
-- AI decision making
--------------------------------------------------

function BotService:_findNearestFood(botPos: Vector3): Vector3?
	local foodFolder = WormService._foodFolder :: Folder?
	if not foodFolder then
		return nil
	end

	local nearestDist = FOOD_SEEK_RANGE
	local nearestPos: Vector3? = nil

	for _, food in foodFolder:GetChildren() do
		if food:IsA("BasePart") then
			local dist = (food.Position - botPos).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestPos = food.Position
			end
		end
	end

	return nearestPos
end

function BotService:_findNearestWormThreat(botName: string, botPos: Vector3, botSegments: number): (Vector3?, boolean)
	local fleeTarget: Vector3? = nil
	local fleeDist = FLEE_RANGE
	local chaseTarget: Vector3? = nil
	local chaseDist = CHASE_RANGE

	-- Check player worms
	for player, wormData in WormService._worms do
		if wormData.State ~= "Alive" then
			continue
		end
		-- Skip teammates
		if TeamService:AreTeammates(botName, player.Name) then
			continue
		end
		local char = player.Character
		if not char then
			continue
		end
		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		local dist = (hrp.Position - botPos).Magnitude
		if wormData.Segments > botSegments and dist < fleeDist then
			fleeDist = dist
			fleeTarget = hrp.Position
		elseif wormData.Segments < botSegments * 0.7 and dist < chaseDist then
			chaseDist = dist
			chaseTarget = hrp.Position
		end
	end

	-- Check other bots
	for otherName, otherData in self._bots do
		if otherName == botName or otherData.State ~= "Alive" then
			continue
		end
		-- Skip teammates
		if TeamService:AreTeammates(botName, otherName) then
			continue
		end
		local otherHrp = otherData.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not otherHrp then
			continue
		end

		local dist = (otherHrp.Position - botPos).Magnitude
		if otherData.Segments > botSegments and dist < fleeDist then
			fleeDist = dist
			fleeTarget = otherHrp.Position
		elseif otherData.Segments < botSegments * 0.7 and dist < chaseDist then
			chaseDist = dist
			chaseTarget = otherHrp.Position
		end
	end

	if fleeTarget then
		return fleeTarget, true
	elseif chaseTarget then
		return chaseTarget, false
	end

	return nil, false
end

function BotService:_updateAI(botData: BotData, now: number)
	local hrp = botData.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Read from server-side source of truth (updated every Heartbeat) rather than
	-- the Part, which only reflects the most recent 10Hz flush.
	local botPos = botData.HeadPosition

	-- Shrink zone avoidance (highest priority)
	local zoneRadius = ShrinkZoneService:GetCurrentRadius()
	local distFromCenter = Vector3.new(botPos.X, 0, botPos.Z).Magnitude
	local zoneMargin = 50
	if distFromCenter > zoneRadius - zoneMargin and zoneRadius < HALF_ARENA then
		-- Move toward center
		local toCenter = (Vector3.zero - Vector3.new(botPos.X, 0, botPos.Z))
		if toCenter.Magnitude > 0.1 then
			botData.Direction = toCenter.Unit
			botData.NextDirectionChange = now + 0.5
			-- Boost if getting close to edge
			if distFromCenter > zoneRadius - 20 and botData.Segments > WormConfig.MinBoostSegments + 2 then
				botData.Boosting = true
				botData.BoostEndTime = now + 1
			end
			return
		end
	end

	-- Wall avoidance
	local margin = 50
	local awayDir = Vector3.zero
	if botPos.X > HALF_ARENA - margin then
		awayDir += Vector3.new(-1, 0, 0)
	elseif botPos.X < -HALF_ARENA + margin then
		awayDir += Vector3.new(1, 0, 0)
	end
	if botPos.Z > HALF_ARENA - margin then
		awayDir += Vector3.new(0, 0, -1)
	elseif botPos.Z < -HALF_ARENA + margin then
		awayDir += Vector3.new(0, 0, 1)
	end

	if awayDir.Magnitude > 0 then
		botData.Direction = awayDir.Unit
		botData.NextDirectionChange = now + 0.5
		return
	end

	-- Flee larger worms / chase smaller worms
	local threatPos, shouldFlee = self:_findNearestWormThreat(botData.Name, botPos, botData.Segments)
	if threatPos then
		local diff = (threatPos - botPos) * Vector3.new(1, 0, 1)
		if diff.Magnitude > 0.1 then
			if shouldFlee then
				botData.Direction = (-diff).Unit
				if botData.Segments > WormConfig.MinBoostSegments + 2 and not botData.Boosting then
					botData.Boosting = true
					botData.BoostEndTime = now
						+ BOOST_DURATION_MIN
						+ math.random() * (BOOST_DURATION_MAX - BOOST_DURATION_MIN)
				end
			else
				botData.Direction = diff.Unit
			end
			botData.NextDirectionChange = now + 0.3
			return
		end
	end

	-- Pursue nearby power-ups
	local powerUpPos = PowerUpService:GetNearestPowerUp(botPos, POWERUP_SEEK_RANGE)
	if powerUpPos then
		local diff = (powerUpPos - botPos) * Vector3.new(1, 0, 1)
		if diff.Magnitude > 0.1 then
			botData.Direction = diff.Unit
			botData.NextDirectionChange = now + 0.3
			return
		end
	end

	-- Seek nearby food
	local foodPos = self:_findNearestFood(botPos)
	if foodPos then
		local diff = (foodPos - botPos) * Vector3.new(1, 0, 1)
		if diff.Magnitude > 0.1 then
			botData.Direction = diff.Unit
			botData.NextDirectionChange = now + 0.5
			return
		end
	end

	-- Random wander
	if now >= botData.NextDirectionChange then
		botData.Direction = randomDirection()
		botData.NextDirectionChange = now
			+ DIRECTION_CHANGE_MIN
			+ math.random() * (DIRECTION_CHANGE_MAX - DIRECTION_CHANGE_MIN)

		if math.random() < BOOST_CHANCE and botData.Segments > WormConfig.MinBoostSegments + 2 then
			botData.Boosting = true
			botData.BoostEndTime = now + BOOST_DURATION_MIN + math.random() * (BOOST_DURATION_MAX - BOOST_DURATION_MIN)
		end
	end

	-- Stop boosting after duration
	if botData.Boosting and now >= botData.BoostEndTime then
		botData.Boosting = false
	end
end

--------------------------------------------------
-- Movement and game logic
--------------------------------------------------

function BotService:_updateBotMovement(botData: BotData, dt: number)
	local model = botData.Model
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Apply speed power-up multiplier, size scaling, and freeze slow
	local sizeScale = 1 / (1 + botData.Segments * WormConfig.SpeedScaleFactor)
	local slowFactor = PowerUpService:GetSlowFactor(botData.Name)
	local speed = WormConfig.BaseSpeed * sizeScale * PowerUpService:GetSpeedMultiplier(botData.Name) * slowFactor
	if botData.Boosting and botData.Segments > WormConfig.MinBoostSegments then
		speed = WormConfig.BoostSpeed * sizeScale * PowerUpService:GetSpeedMultiplier(botData.Name) * slowFactor
		local prevFloor = math.floor(botData.Segments)
		local segmentsToLose = WormConfig.BoostSegmentCostPerSec * dt
		botData.Segments = math.max(WormConfig.MinBoostSegments, botData.Segments - segmentsToLose)
		local newFloor = math.floor(botData.Segments)

		if newFloor < prevFloor then
			local segFolder = model:FindFirstChild("WormSegments") :: Folder?
			if segFolder then
				for _, seg in segFolder:GetChildren() do
					local idx = tonumber(string.match(seg.Name, "%d+"))
					if idx and idx > newFloor then
						seg:Destroy()
					end
				end
			end
			WormService:UpdateBotSegments(botData.Name, newFloor)
		end
	else
		botData.Boosting = false
	end

	-- Interpolate current direction toward target direction with turn rate
	local targetDir = botData.Direction
	local currentDir = botData.CurrentDirection
	local currentAngle = math.atan2(currentDir.X, currentDir.Z)
	local targetAngle = math.atan2(targetDir.X, targetDir.Z)
	local angleDiff = targetAngle - currentAngle
	while angleDiff > math.pi do
		angleDiff -= 2 * math.pi
	end
	while angleDiff < -math.pi do
		angleDiff += 2 * math.pi
	end
	local maxTurn = WormConfig.TurnRate * dt
	local actualTurn = math.clamp(angleDiff, -maxTurn, maxTurn)
	local newAngle = currentAngle + actualTurn
	local dir = Vector3.new(math.sin(newAngle), 0, math.cos(newAngle))
	botData.CurrentDirection = dir

	local move = dir * speed * dt
	local newPos = botData.HeadPosition + move
	newPos = Vector3.new(
		newPos.X,
		TerrainHeight.getSmoothSurfaceY(newPos.X, newPos.Z) + WormConfig.SegmentSize / 2,
		newPos.Z
	)

	-- Always update server-side source of truth (cheap data write).
	botData.HeadPosition = newPos
	botData.HeadDirection = dir

	-- Only flush to actual Parts at 10Hz to throttle replication bandwidth.
	if self._broadcastTick % 6 == 0 then
		local newCFrame = CFrame.new(newPos, newPos + dir)
		hrp.CFrame = newCFrame

		local wormHead = model:FindFirstChild("WormHead") :: BasePart?
		if wormHead then
			wormHead.CFrame = newCFrame
		end
	end

	self:_recordPosition(botData, newPos)
end

function BotService:_updateBotSegments(botData: BotData)
	local model = botData.Model
	local segFolder = model:FindFirstChild("WormSegments") :: Folder?
	if not segFolder then
		return
	end

	local shouldFlush = self._broadcastTick % 6 == 0
	local lerping = botData.LerpingSegments
	local segCount = math.floor(botData.Segments)
	for i = 1, segCount do
		local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
		if not seg then
			continue
		end

		local histIndex = botData.HistoryEnd - i * ENTRIES_PER_SEGMENT
		if histIndex >= botData.HistoryStart and botData.PositionHistory[histIndex] then
			local target = botData.PositionHistory[histIndex]
			local lerpEntry = lerping and lerping[i] or nil
			local desiredPos: Vector3? = nil
			if lerpEntry then
				local now = os.clock()
				if now >= lerpEntry.StartTime then
					local elapsed = now - lerpEntry.StartTime
					local t = math.min(1, elapsed / BOT_SEGMENT_LERP_DURATION)
					desiredPos = lerpEntry.StartPos:Lerp(target, t)
					if t >= 1 then
						lerping[i] = nil
					end
				end
				-- Pre-delay: leave segment in place (gap briefly visible)
			else
				-- Not lerping: snap to target position from history
				desiredPos = target
			end

			if desiredPos then
				-- Always update server-side source of truth (cheap data write).
				botData.SegmentPositions[i] = desiredPos
				-- Only flush to actual Parts at 10Hz to throttle replication.
				if shouldFlush then
					seg.Position = desiredPos
				end
			end
		end
	end

	-- Clear stale entries for segments that no longer exist (e.g. after damage shrinks the worm).
	for idx in botData.SegmentPositions do
		if idx > segCount then
			botData.SegmentPositions[idx] = nil
		end
	end

	if lerping and next(lerping) == nil then
		botData.LerpingSegments = nil
	end
end

function BotService:_checkBotFoodCollection(botData: BotData)
	local hrp = botData.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Use server-side source of truth (HRP is only flushed at 10Hz).
	local headPos = botData.HeadPosition

	-- Check power-up collection first
	PowerUpService:CollectPowerUp(botData.Name, headPos)

	-- Food magnet: passive pull + power-up pull
	local powerUpMagnetRange = PowerUpService:GetMagnetRange(botData.Name)
	local effectiveRange = math.max(WormConfig.PassiveMagnetRange, powerUpMagnetRange)
	local pullSpeed = if powerUpMagnetRange > 0 then WormConfig.PowerUpMagnetPull else WormConfig.PassiveMagnetPull

	local foodFolder = WormService._foodFolder :: Folder?
	if not foodFolder then
		return
	end

	-- Gate Part.Position writes to 10Hz (every 6th Heartbeat) to stay within the
	-- "Server Brain, Client Body" replication budget. Mirrors the logic in
	-- WormService:_checkFoodCollection — pullSpeed is 6× to preserve stud/s rate.
	local magnetFlush = (self._broadcastTick % 6 == 0)
	for _, food in foodFolder:GetChildren() do
		if food:IsA("BasePart") then
			local diff = food.Position - headPos
			local dist = diff.Magnitude

			-- Pull nearby food toward head
			if
				magnetFlush
				and effectiveRange > 0
				and dist < effectiveRange
				and dist > WormConfig.CollisionRadius + 1
			then
				local pullDir = -diff.Unit
				food.Position = food.Position + pullDir * (pullSpeed * 6)
			end

			if dist < WormConfig.CollisionRadius + 1 then
				local foodValue = food:GetAttribute("FoodValue") or WormConfig.FoodValue
				if WormService:ConsumeFood(food) then
					local prevFloor = math.floor(botData.Segments)
					botData.Segments += foodValue
					if botData.Segments > botData.MaxSegments then
						botData.MaxSegments = botData.Segments
					end
					local newFloor = math.floor(botData.Segments)
					for i = prevFloor + 1, newFloor do
						self:_createSegment(botData, i)
					end
					WormService:UpdateBotSegments(botData.Name, newFloor)
				end
			end
		end
	end
end

function BotService:_checkBotCollisions(botData: BotData)
	local hrp = botData.Model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Use server-side source of truth (HRP is only flushed at 10Hz).
	local headPos = botData.HeadPosition

	-- Ghost power-up: skip collisions
	if PowerUpService:IsGhost(botData.Name) then
		return
	end

	-- Check against player segments
	for player, wormData in WormService._worms do
		if wormData.State ~= "Alive" then
			continue
		end
		-- Skip teammates
		if TeamService:AreTeammates(botData.Name, player.Name) then
			continue
		end
		local char = player.Character
		if not char then
			continue
		end
		local segFolder = char:FindFirstChild("WormSegments") :: Folder?
		if not segFolder then
			continue
		end

		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				local segDist = (seg.Position - headPos).Magnitude
				if segDist < WormConfig.CollisionRadius * 2 then
					self:_killBot(botData.Name, player.Name)
					return
				end
			end
		end
	end

	-- Check against other bot segments. Use the other bot's server-side
	-- SegmentPositions table (source of truth) rather than reading Part.Position,
	-- which only reflects the most recent 10Hz flush.
	for otherName, otherData in self._bots do
		if otherName == botData.Name or otherData.State ~= "Alive" then
			continue
		end
		-- Skip teammates
		if TeamService:AreTeammates(botData.Name, otherName) then
			continue
		end

		for _, segPos in otherData.SegmentPositions do
			local segDist = (segPos - headPos).Magnitude
			if segDist < WormConfig.CollisionRadius * 2 then
				self:_killBot(botData.Name, otherName)
				return
			end
		end
	end

	-- Check static arena bounds
	if math.abs(headPos.X) > HALF_ARENA or math.abs(headPos.Z) > HALF_ARENA then
		self:_killBot(botData.Name, nil)
		return
	end

	-- Check shrink zone bounds
	if ShrinkZoneService:IsOutsideZone(headPos) then
		self:_killBot(botData.Name, nil)
	end
end

--------------------------------------------------
-- Round API (called by RoundService)
--------------------------------------------------

function BotService:_fillBots()
	local playerCount = #Players:GetPlayers()
	local botCount = 0
	for _ in self._bots do
		botCount += 1
	end

	local totalWorms = playerCount + botCount
	local botsNeeded = TARGET_TOTAL_WORMS - totalWorms

	for _ = 1, math.max(0, botsNeeded) do
		self:_spawnBot()
	end
end

function BotService:SetRoundActive(active: boolean)
	self._roundActive = active
end

function BotService:GetAliveCount(): number
	local count = 0
	for _, botData in self._bots do
		if botData.State == "Alive" then
			count += 1
		end
	end
	return count
end

function BotService:GetAliveBotNames(): { string }
	local names = {}
	for name, botData in self._bots do
		if botData.State == "Alive" then
			table.insert(names, name)
		end
	end
	return names
end

-- Worm King helper: return a live bot's current head position, or nil if missing/dead.
function BotService:GetBotHeadPosition(name: string): Vector3?
	local botData = self._bots[name]
	if not botData or botData.State ~= "Alive" then
		return nil
	end
	return botData.HeadPosition
end

function BotService:KillAllBots()
	local toKill = {}
	for name, botData in self._bots do
		if botData.State == "Alive" then
			table.insert(toKill, name)
		end
	end
	for _, name in toKill do
		local botData = self._bots[name]
		if botData then
			-- Save stats
			self._roundBotStats[name] = {
				Kills = botData.Kills,
				MaxSegments = math.floor(botData.MaxSegments),
			}
			PowerUpService:ClearActivePowerUp(name)
			WormService:UnregisterBot(name)
			if TeamService:IsEnabled() then
				TeamService:RemoveFromTeam(name)
			end
			botData.Model:Destroy()
			self._usedNames[name] = nil
			self._bots[name] = nil
		end
	end
end

function BotService:ClearRoundStats()
	self._roundBotStats = {}
end

function BotService:SpawnBotsToFill()
	self:_fillBots()
end

function BotService:GetRoundStats(): { [string]: { Kills: number, MaxSegments: number } }
	-- Combine alive bot stats + saved dead bot stats
	local stats = {}
	for name, botData in self._bots do
		stats[name] = {
			Kills = botData.Kills,
			MaxSegments = math.floor(botData.MaxSegments),
		}
	end
	for name, savedStats in self._roundBotStats do
		if not stats[name] then
			stats[name] = savedStats
		end
	end
	return stats
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function BotService:KnitInit() end

function BotService:KnitStart()
	WormService = require(script.Parent.WormService)
	PowerUpService = require(script.Parent.PowerUpService)
	ShrinkZoneService = require(script.Parent.ShrinkZoneService)
	TeamService = require(script.Parent.TeamService)
	SandTideService = require(script.Parent.SandTideService)

	-- Spawn management loop — only fills when round is active
	task.spawn(function()
		-- Small delay to let WormService finish initializing
		task.wait(1)

		while true do
			if self._roundActive then
				self:_fillBots()
			end

			task.wait(SPAWN_CHECK_INTERVAL)
		end
	end)

	-- Game loop for bot movement and AI
	RunService.Heartbeat:Connect(function(dt: number)
		self._broadcastTick += 1
		local now = os.clock()

		-- Collect bot names first to avoid modifying table during iteration
		local botNames = {}
		for name, botData in self._bots do
			if botData.State == "Alive" then
				table.insert(botNames, name)
			end
		end

		for _, name in botNames do
			local botData = self._bots[name]
			if not botData or botData.State ~= "Alive" then
				continue
			end

			self:_updateAI(botData, now)
			self:_updateBotMovement(botData, dt)
			self:_updateBotSegments(botData)
			self:_checkBotFoodCollection(botData)
			self:_checkBotCollisions(botData)
		end
	end)
end

return BotService
