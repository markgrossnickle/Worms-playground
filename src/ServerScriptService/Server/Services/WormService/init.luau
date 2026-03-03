--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

type WormState = Enums.WormState
type WormData = {
	State: WormState,
	Segments: number,
	Direction: Vector3,
	Boosting: boolean,
	Color: Color3,
	Kills: number,
	PositionHistory: { [number]: Vector3 },
	HistoryStart: number,
	HistoryEnd: number,
	LastRecordedPos: Vector3,
}

local PowerUpService -- Set in KnitStart
local ShrinkZoneService -- Set in KnitStart
local TeamService -- Set in KnitStart

local HALF_ARENA = WormConfig.ArenaSize / 2

-- Position history: record a position every MIN_RECORD_DISTANCE studs.
-- Each segment reads ENTRIES_PER_SEGMENT entries behind the head in the buffer.
local MIN_RECORD_DISTANCE = 0.5
local ENTRIES_PER_SEGMENT = math.ceil(WormConfig.SegmentSpacing / MIN_RECORD_DISTANCE)

local WormService = Knit.CreateService({
	Name = "WormService",
	Client = {
		WormSpawned = Knit.CreateSignal(),
		WormDied = Knit.CreateSignal(),
		WormAte = Knit.CreateSignal(),
		FoodSpawned = Knit.CreateSignal(),
	},

	_worms = {} :: { [Player]: WormData },
	_troves = {} :: { [Player]: any },
	_foodFolder = nil :: Folder?,
	_wormFolder = nil :: Folder?,
	_foodCount = 0,
	_gameLoopConnection = nil :: RBXScriptConnection?,
	_botModels = {} :: { [string]: { Model: Model, Segments: number } },

	-- Signals for other services to listen to
	PlayerKilled = Signal.new(),
	PlayerScoreChanged = Signal.new(),
})

--------------------------------------------------
-- Private helpers
--------------------------------------------------

function WormService:_randomArenaPosition(): Vector3
	local x = math.random(-HALF_ARENA, HALF_ARENA)
	local z = math.random(-HALF_ARENA, HALF_ARENA)
	return Vector3.new(x, 1, z)
end

function WormService:_randomColor(): Color3
	return Color3.fromHSV(math.random(), 0.8, 0.9)
end

function WormService:_createArena()
	-- Remove default Studio baseplate to avoid z-fighting
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end

	local arena = Instance.new("Part")
	arena.Name = "Arena"
	arena.Size = Vector3.new(WormConfig.ArenaSize, 1, WormConfig.ArenaSize)
	arena.Position = Vector3.new(0, -0.5, 0)
	arena.Anchored = true
	arena.Material = Enum.Material.SmoothPlastic
	arena.Color = Color3.fromRGB(30, 30, 30)
	arena.Parent = workspace

	-- Boundary walls
	local wallHeight = 20
	local wallThickness = 4
	local wallData = {
		{ Vector3.new(WormConfig.ArenaSize, wallHeight, wallThickness), Vector3.new(0, wallHeight / 2, HALF_ARENA) },
		{ Vector3.new(WormConfig.ArenaSize, wallHeight, wallThickness), Vector3.new(0, wallHeight / 2, -HALF_ARENA) },
		{ Vector3.new(wallThickness, wallHeight, WormConfig.ArenaSize), Vector3.new(HALF_ARENA, wallHeight / 2, 0) },
		{ Vector3.new(wallThickness, wallHeight, WormConfig.ArenaSize), Vector3.new(-HALF_ARENA, wallHeight / 2, 0) },
	}
	for i, data in wallData do
		local wall = Instance.new("Part")
		wall.Name = "Wall" .. i
		wall.Size = data[1]
		wall.Position = data[2]
		wall.Anchored = true
		wall.Material = Enum.Material.SmoothPlastic
		wall.Color = Color3.fromRGB(80, 0, 0)
		wall.Transparency = 0.5
		wall.Parent = workspace
	end
end

function WormService:_spawnFood()
	if self._foodCount >= WormConfig.MaxFoodOnMap then
		return
	end

	local food = Instance.new("Part")
	food.Name = "Food"
	food.Shape = Enum.PartType.Ball
	food.Size = Vector3.new(1.5, 1.5, 1.5)
	food.Position = self:_randomArenaPosition()
	food.Anchored = true
	food.CanCollide = false
	food.Material = Enum.Material.Neon
	food.Color = Color3.fromHSV(math.random(), 0.9, 1)
	food.Parent = self._foodFolder

	self._foodCount += 1
	self.Client.FoodSpawned:FireAll(food.Position, food.Color)
end

function WormService:_spawnFoodBatch(count: number)
	for _ = 1, count do
		self:_spawnFood()
	end
end

function WormService:_dropFoodFromWorm(player: Player, count: number)
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local basePos = hrp.Position
	for _ = 1, count do
		local offset = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
		local food = Instance.new("Part")
		food.Name = "Food"
		food.Shape = Enum.PartType.Ball
		food.Size = Vector3.new(1.5, 1.5, 1.5)
		food.Position = basePos + offset
		food.Anchored = true
		food.CanCollide = false
		food.Material = Enum.Material.Neon
		food.Color = Color3.fromHSV(math.random(), 0.9, 1)
		food.Parent = self._foodFolder
		self._foodCount += 1
	end
end

function WormService:_setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Clean up any existing worm visuals (prevents duplicate from CharacterAdded double-call)
	local existingHead = character:FindFirstChild("WormHead")
	if existingHead then
		existingHead:Destroy()
	end
	local existingSegs = character:FindFirstChild("WormSegments")
	if existingSegs then
		existingSegs:Destroy()
	end

	-- Anchor HRP so server CFrame sets are authoritative (no physics fighting)
	hrp.Anchored = true

	-- Find the actual avatar Head before hiding parts
	local head = character:FindFirstChild("Head") :: BasePart?

	-- Hide all character parts EXCEPT the Head (which becomes the worm head)
	-- Keep face decals on the Head visible
	for _, desc in character:GetDescendants() do
		if desc:IsA("BasePart") then
			if desc ~= head then
				desc.Transparency = 1
				desc.CanCollide = false
			end
		elseif desc:IsA("Decal") then
			if desc.Parent ~= head then
				desc.Transparency = 1
			end
		end
	end

	-- Hide any parts that load late (accessories, layered clothing, etc.)
	character.DescendantAdded:Connect(function(desc)
		local wormHead = character:FindFirstChild("WormHead")
		if desc:IsA("BasePart") and desc.Name ~= "WormHead" and not string.match(desc.Name, "^Segment") then
			desc.Transparency = 1
			desc.CanCollide = false
		elseif desc:IsA("Decal") then
			if desc.Parent ~= wormHead then
				desc.Transparency = 1
			end
		end
	end)

	local wormData = self._worms[player]
	local color = if wormData then wormData.Color else Color3.new(1, 1, 1)

	-- Use the avatar Head as the worm head: break rig, anchor, rename
	local headSize = WormConfig.SegmentSize + 0.5
	if head then
		-- Destroy all Motor6Ds that connect to the Head (Neck joint, etc.)
		for _, desc in character:GetDescendants() do
			if desc:IsA("Motor6D") and (desc.Part0 == head or desc.Part1 == head) then
				desc:Destroy()
			end
		end

		head.Anchored = true
		head.CanCollide = false
		head.Transparency = 0
		head.Size = Vector3.new(headSize, headSize, headSize)
		head.CFrame = hrp.CFrame
		head.Name = "WormHead" -- Rename so all existing FindFirstChild("WormHead") code works
	else
		-- Fallback: create a ball if Head somehow doesn't exist
		local wormHead = Instance.new("Part")
		wormHead.Name = "WormHead"
		wormHead.Shape = Enum.PartType.Ball
		wormHead.Size = Vector3.new(headSize, headSize, headSize)
		wormHead.Color = color
		wormHead.Material = Enum.Material.Neon
		wormHead.Transparency = 0
		wormHead.Anchored = true
		wormHead.CanCollide = false
		wormHead.CFrame = hrp.CFrame
		wormHead.Parent = character
	end

	-- Create body segments folder under character
	local segFolder = Instance.new("Folder")
	segFolder.Name = "WormSegments"
	segFolder.Parent = character

	if wormData then
		for i = 1, wormData.Segments do
			self:_createSegment(character, player, i, color)
		end
	end
end

function WormService:_createSegment(character: Model, player: Player, index: number, color: Color3): Part
	local wormData = self._worms[player]
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if not hrp or not segFolder then
		error("Cannot create segment: missing HumanoidRootPart or WormSegments folder")
	end

	local seg = Instance.new("Part")
	seg.Name = "Segment" .. index
	seg.Shape = Enum.PartType.Ball
	seg.Size = Vector3.new(WormConfig.SegmentSize, WormConfig.SegmentSize, WormConfig.SegmentSize)
	seg.Anchored = true
	seg.CanCollide = false
	seg.Material = Enum.Material.SmoothPlastic
	seg.Color = color

	-- Position from history if available, otherwise behind head in current direction
	if wormData and wormData.HistoryEnd >= wormData.HistoryStart then
		local histIndex = wormData.HistoryEnd - index * ENTRIES_PER_SEGMENT
		if histIndex >= wormData.HistoryStart and wormData.PositionHistory[histIndex] then
			seg.Position = wormData.PositionHistory[histIndex]
		else
			seg.Position = hrp.Position - wormData.Direction * (index * WormConfig.SegmentSpacing)
		end
	else
		seg.Position = hrp.Position - Vector3.new(0, 0, index * WormConfig.SegmentSpacing)
	end

	seg.Parent = segFolder
	return seg
end

--------------------------------------------------
-- Position history
--------------------------------------------------

function WormService:_initPositionHistory(wormData: WormData, spawnPos: Vector3)
	wormData.PositionHistory = {}
	wormData.HistoryStart = 1
	wormData.HistoryEnd = 0

	-- Seed with positions trailing behind spawn in the initial direction
	local numEntries = (WormConfig.InitialSegments + 1) * ENTRIES_PER_SEGMENT
	for j = numEntries, 0, -1 do
		local behindDist = j * MIN_RECORD_DISTANCE
		local pos = spawnPos - wormData.Direction * behindDist
		wormData.HistoryEnd += 1
		wormData.PositionHistory[wormData.HistoryEnd] = Vector3.new(pos.X, 1, pos.Z)
	end

	wormData.LastRecordedPos = spawnPos
end

function WormService:_recordPosition(wormData: WormData, pos: Vector3)
	local distMoved = (pos - wormData.LastRecordedPos).Magnitude
	if distMoved < MIN_RECORD_DISTANCE then
		return
	end

	wormData.HistoryEnd += 1
	wormData.PositionHistory[wormData.HistoryEnd] = pos
	wormData.LastRecordedPos = pos

	-- Trim old entries we no longer need
	local maxEntries = (math.ceil(wormData.Segments) + 2) * ENTRIES_PER_SEGMENT
	local trimTo = wormData.HistoryEnd - maxEntries
	while wormData.HistoryStart <= trimTo do
		wormData.PositionHistory[wormData.HistoryStart] = nil
		wormData.HistoryStart += 1
	end
end

--------------------------------------------------
-- Worm lifecycle
--------------------------------------------------

function WormService:_spawnWorm(player: Player)
	local wormData = self._worms[player]
	if not wormData then
		return
	end

	wormData.State = "Alive" :: WormState
	wormData.Segments = WormConfig.InitialSegments
	wormData.Direction = Vector3.new(0, 0, -1)
	wormData.Boosting = false
	wormData.Kills = 0

	-- Respawn character at random arena position
	local spawnPos = self:_randomArenaPosition()
	player.RespawnLocation = nil
	player:LoadCharacter()

	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	hrp.CFrame = CFrame.new(spawnPos)

	-- Initialize position history before setting up character (so segments can read from it)
	self:_initPositionHistory(wormData, spawnPos)

	self:_setupCharacter(player, character)

	-- Assign team if team mode is active
	if TeamService:IsEnabled() then
		TeamService:AssignToTeam(player.Name)
	end

	self.Client.WormSpawned:Fire(player, {
		Segments = wormData.Segments,
		Color = { wormData.Color.R, wormData.Color.G, wormData.Color.B },
		Position = { spawnPos.X, spawnPos.Y, spawnPos.Z },
	})
end

function WormService:_killWorm(player: Player, killer: Player?, killerBotName: string?)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Clear any active power-up
	PowerUpService:ClearActivePowerUp(player.Name)

	local segmentsToDrop = math.floor(wormData.Segments * 0.7)
	self:_dropFoodFromWorm(player, segmentsToDrop)

	wormData.State = "Dead" :: WormState

	-- Credit killer
	if killer and killer ~= player then
		local killerData = self._worms[killer]
		if killerData then
			killerData.Kills += 1
		end
		self.PlayerKilled:Fire(killer, player)
	end

	local killerDisplayName = if killer then killer.Name elseif killerBotName then killerBotName else nil
	self.Client.WormDied:FireAll(player.Name, killerDisplayName)

	-- Clean up character visuals
	local character = player.Character
	if character then
		local segFolder = character:FindFirstChild("WormSegments")
		if segFolder then
			segFolder:Destroy()
		end
		local wormHead = character:FindFirstChild("WormHead")
		if wormHead then
			wormHead:Destroy()
		end
		local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
		if humanoid then
			humanoid.Health = 0
		end
	end

	-- Respawn after delay
	task.delay(WormConfig.RespawnDelay, function()
		if player.Parent and self._worms[player] then
			self:_spawnWorm(player)
		end
	end)
end

--------------------------------------------------
-- Game loop
--------------------------------------------------

function WormService:_checkFoodCollection(player: Player, headPos: Vector3)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Magnet power-up: pull nearby food toward head
	local magnetRange = PowerUpService:GetMagnetRange(player.Name)

	local foodFolder = self._foodFolder :: Folder
	for _, food in foodFolder:GetChildren() do
		if food:IsA("BasePart") then
			local diff = food.Position - headPos
			local dist = diff.Magnitude

			-- Magnet: pull food toward head
			if magnetRange > 0 and dist < magnetRange and dist > WormConfig.CollisionRadius + 1 then
				local pullDir = -diff.Unit
				food.Position = food.Position + pullDir * 2 -- pull 2 studs per frame
			end

			if dist < WormConfig.CollisionRadius + 1 then
				-- Guard against double-consumption
				if food:GetAttribute("Consumed") then
					continue
				end
				food:SetAttribute("Consumed", true)
				food:Destroy()
				self._foodCount -= 1
				wormData.Segments += WormConfig.FoodValue

				-- Add new segment to character
				local character = player.Character
				if character then
					self:_createSegment(character, player, math.floor(wormData.Segments), wormData.Color)
				end

				self.Client.WormAte:Fire(player, wormData.Segments)
				self.PlayerScoreChanged:Fire(player, wormData.Segments)
			end
		end
	end

	-- Check power-up collection
	PowerUpService:CollectPowerUp(player.Name, headPos)
end

function WormService:_checkWormCollisions(player: Player, headPos: Vector3)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	-- Ghost power-up: skip all collision checks
	if PowerUpService:IsGhost(player.Name) then
		return
	end

	-- Check against other player segments
	for otherPlayer, otherData in self._worms do
		if otherPlayer == player or otherData.State ~= "Alive" then
			continue
		end

		-- Team mode: skip teammate collisions
		if TeamService:AreTeammates(player.Name, otherPlayer.Name) then
			continue
		end

		local otherChar = otherPlayer.Character
		if not otherChar then
			continue
		end

		local segFolder = otherChar:FindFirstChild("WormSegments") :: Folder?
		if not segFolder then
			continue
		end

		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				local segDist = (seg.Position - headPos).Magnitude
				if segDist < WormConfig.CollisionRadius * 2 then
					-- Shield power-up: consume shield instead of dying
					if PowerUpService:ConsumeShield(player.Name) then
						return
					end
					self:_killWorm(player, otherPlayer)
					return
				end
			end
		end
	end

	-- Check against bot segments
	for botName, botInfo in self._botModels do
		-- Team mode: skip teammate collisions
		if TeamService:AreTeammates(player.Name, botName) then
			continue
		end

		local segFolder = botInfo.Model:FindFirstChild("WormSegments") :: Folder?
		if not segFolder then
			continue
		end

		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") then
				local segDist = (seg.Position - headPos).Magnitude
				if segDist < WormConfig.CollisionRadius * 2 then
					if PowerUpService:ConsumeShield(player.Name) then
						return
					end
					self:_killWorm(player, nil, botName)
					return
				end
			end
		end
	end
end

function WormService:_checkBounds(player: Player, headPos: Vector3)
	-- Static arena wall check
	if math.abs(headPos.X) > HALF_ARENA or math.abs(headPos.Z) > HALF_ARENA then
		self:_killWorm(player, nil)
		return
	end

	-- Shrink zone check
	if ShrinkZoneService:IsOutsideZone(headPos) then
		self:_killWorm(player, nil)
	end
end

function WormService:_updateSegments(player: Player)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local segFolder = character:FindFirstChild("WormSegments") :: Folder?
	if not segFolder then
		return
	end

	-- Place each segment at the position the head was at (index * ENTRIES_PER_SEGMENT) entries ago
	local segCount = math.floor(wormData.Segments)
	for i = 1, segCount do
		local seg = segFolder:FindFirstChild("Segment" .. i) :: BasePart?
		if not seg then
			continue
		end

		local histIndex = wormData.HistoryEnd - i * ENTRIES_PER_SEGMENT
		if histIndex >= wormData.HistoryStart and wormData.PositionHistory[histIndex] then
			seg.Position = wormData.PositionHistory[histIndex]
		end
	end
end

function WormService:_updateMovement(player: Player, dt: number)
	local wormData = self._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Handle boosting and power-up speed
	local speed = WormConfig.BaseSpeed * PowerUpService:GetSpeedMultiplier(player.Name)
	if wormData.Boosting and wormData.Segments > WormConfig.MinBoostSegments then
		speed = WormConfig.BoostSpeed * PowerUpService:GetSpeedMultiplier(player.Name)
		local prevFloor = math.floor(wormData.Segments)
		local segmentsToLose = WormConfig.BoostSegmentCostPerSec * dt
		wormData.Segments = math.max(WormConfig.MinBoostSegments, wormData.Segments - segmentsToLose)
		local newFloor = math.floor(wormData.Segments)

		-- Remove excess segments and notify client when a visible segment is lost
		if newFloor < prevFloor then
			local segFolder = character:FindFirstChild("WormSegments") :: Folder?
			if segFolder then
				for _, seg in segFolder:GetChildren() do
					local idx = tonumber(string.match(seg.Name, "%d+"))
					if idx and idx > newFloor then
						seg:Destroy()
					end
				end
			end
			self.Client.WormAte:Fire(player, newFloor)
		end
	end

	-- Move HRP in direction (anchored, so CFrame set is authoritative)
	local dir = wormData.Direction
	local move = dir * speed * dt
	local newPos = hrp.Position + move
	newPos = Vector3.new(newPos.X, 1, newPos.Z) -- Keep on ground

	local newCFrame = CFrame.new(newPos, newPos + dir)
	hrp.CFrame = newCFrame

	-- Move visual worm head to match
	local wormHead = character:FindFirstChild("WormHead") :: BasePart?
	if wormHead then
		wormHead.CFrame = newCFrame
	end

	-- Record position in history for segment following
	self:_recordPosition(wormData, newPos)
end

function WormService:_gameStep(dt: number)
	-- Spawn food to maintain target count
	local foodDeficit = WormConfig.MaxFoodOnMap - self._foodCount
	if foodDeficit > 0 then
		local toSpawn = math.min(foodDeficit, 10) -- Spawn up to 10 per frame
		self:_spawnFoodBatch(toSpawn)
	end

	-- Update all alive worms
	for player, wormData in self._worms do
		if wormData.State ~= "Alive" then
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

		self:_updateMovement(player, dt)
		self:_updateSegments(player)

		local headPos = hrp.Position
		self:_checkFoodCollection(player, headPos)
		self:_checkWormCollisions(player, headPos)
		self:_checkBounds(player, headPos)
	end
end

--------------------------------------------------
-- Bot integration (called by BotService)
--------------------------------------------------

function WormService:RegisterBot(name: string, model: Model, segments: number)
	self._botModels[name] = { Model = model, Segments = segments }
end

function WormService:UnregisterBot(name: string)
	self._botModels[name] = nil
end

function WormService:UpdateBotSegments(name: string, segments: number)
	local bot = self._botModels[name]
	if bot then
		bot.Segments = segments
	end
end

function WormService:ConsumeFood(food: BasePart): boolean
	-- Guard against double-consumption in the same frame
	if food:GetAttribute("Consumed") then
		return false
	end
	food:SetAttribute("Consumed", true)
	food:Destroy()
	self._foodCount -= 1
	return true
end

function WormService:DropFoodAtPosition(position: Vector3, count: number)
	for _ = 1, count do
		local offset = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
		local food = Instance.new("Part")
		food.Name = "Food"
		food.Shape = Enum.PartType.Ball
		food.Size = Vector3.new(1.5, 1.5, 1.5)
		food.Position = position + offset
		food.Anchored = true
		food.CanCollide = false
		food.Material = Enum.Material.Neon
		food.Color = Color3.fromHSV(math.random(), 0.9, 1)
		food.Parent = self._foodFolder
		self._foodCount += 1
	end
end

function WormService:FireBotDeath(botName: string, killerName: string?)
	self.Client.WormDied:FireAll(botName, killerName)
end

-- Used by PowerUpService (SIZE_BOMB)
function WormService:AddSegments(ownerName: string, count: number)
	-- Check if it's a player
	for player, wormData in self._worms do
		if player.Name == ownerName and wormData.State == "Alive" then
			wormData.Segments += count
			local character = player.Character
			if character then
				for i = math.floor(wormData.Segments - count) + 1, math.floor(wormData.Segments) do
					self:_createSegment(character, player, i, wormData.Color)
				end
			end
			self.Client.WormAte:Fire(player, wormData.Segments)
			self.PlayerScoreChanged:Fire(player, wormData.Segments)
			return
		end
	end

	-- Check if it's a bot
	local botInfo = self._botModels[ownerName]
	if botInfo then
		botInfo.Segments += count
	end
end

--------------------------------------------------
-- Client methods
--------------------------------------------------

function WormService.Client:SetDirection(player: Player, dirX: number, dirZ: number)
	local wormData = self.Server._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	local dir = Vector3.new(dirX, 0, dirZ)
	if dir.Magnitude > 0 then
		wormData.Direction = dir.Unit
	end
end

function WormService.Client:SetBoosting(player: Player, boosting: boolean)
	local wormData = self.Server._worms[player]
	if not wormData or wormData.State ~= "Alive" then
		return
	end

	wormData.Boosting = boosting
end

function WormService.Client:GetLeaderboard(_player: Player): { { Name: string, Segments: number } }
	local board = {}
	for p, data in self.Server._worms do
		if data.State == "Alive" then
			table.insert(board, { Name = p.Name, Segments = math.floor(data.Segments) })
		end
	end
	-- Include bots in leaderboard
	for botName, botInfo in self.Server._botModels do
		table.insert(board, { Name = botName, Segments = math.floor(botInfo.Segments) })
	end
	table.sort(board, function(a, b)
		return a.Segments > b.Segments
	end)
	return board
end

function WormService.Client:GetWormData(player: Player): { Segments: number, State: string }?
	local wormData = self.Server._worms[player]
	if not wormData then
		return nil
	end
	return { Segments = math.floor(wormData.Segments), State = wormData.State }
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function WormService:KnitInit()
	self._foodFolder = Instance.new("Folder")
	self._foodFolder.Name = "Food"
	self._foodFolder.Parent = workspace

	self._wormFolder = Instance.new("Folder")
	self._wormFolder.Name = "Worms"
	self._wormFolder.Parent = workspace
end

local function newWormData(color: Color3): WormData
	return {
		State = "Dead" :: WormState,
		Segments = WormConfig.InitialSegments,
		Direction = Vector3.new(0, 0, -1),
		Boosting = false,
		Color = color,
		Kills = 0,
		PositionHistory = {},
		HistoryStart = 1,
		HistoryEnd = 0,
		LastRecordedPos = Vector3.zero,
	}
end

function WormService:KnitStart()
	PowerUpService = require(script.Parent.PowerUpService)
	ShrinkZoneService = require(script.Parent.ShrinkZoneService)
	TeamService = require(script.Parent.TeamService)

	self:_createArena()
	self:_spawnFoodBatch(WormConfig.MaxFoodOnMap)

	-- Handle players joining
	Players.PlayerAdded:Connect(function(player: Player)
		local trove = Trove.new()
		self._troves[player] = trove

		self._worms[player] = newWormData(self:_randomColor())

		trove:Connect(player.CharacterAdded, function(character: Model)
			task.wait(0.1) -- Let character load
			-- Skip if _spawnWorm already set up this character (prevents double-call)
			if character:FindFirstChild("WormHead") then
				return
			end
			if self._worms[player] and self._worms[player].State == "Alive" then
				self:_setupCharacter(player, character)
			end
		end)

		self:_spawnWorm(player)
	end)

	-- Handle players leaving
	Players.PlayerRemoving:Connect(function(player: Player)
		local wormData = self._worms[player]
		if wormData and wormData.State == "Alive" then
			self:_dropFoodFromWorm(player, math.floor(wormData.Segments * 0.5))
		end
		self._worms[player] = nil

		local trove = self._troves[player]
		if trove then
			trove:Destroy()
			self._troves[player] = nil
		end
	end)

	-- Existing players (Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			local trove = Trove.new()
			self._troves[player] = trove

			self._worms[player] = newWormData(self:_randomColor())

			trove:Connect(player.CharacterAdded, function(character: Model)
				task.wait(0.1)
				if character:FindFirstChild("WormHead") then
					return
				end
				if self._worms[player] and self._worms[player].State == "Alive" then
					self:_setupCharacter(player, character)
				end
			end)

			self:_spawnWorm(player)
		end)
	end

	-- Start game loop
	self._gameLoopConnection = RunService.Heartbeat:Connect(function(dt: number)
		self:_gameStep(dt)
	end)
end

return WormService
