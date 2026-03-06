--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local WormService -- Set in KnitStart

local HALF_ARENA = WormConfig.ArenaSize / 2
local POWERUP_TYPES = { "SPEED", "SPEED_BURST", "MAGNET", "GHOST", "SHIELD", "SIZE_BOMB", "FREEZE_RING" }
local POWERUP_COLORS = {
	SPEED = Color3.fromRGB(0, 200, 255),
	SPEED_BURST = Color3.fromRGB(255, 140, 0),
	MAGNET = Color3.fromRGB(255, 0, 200),
	GHOST = Color3.fromRGB(200, 200, 255),
	SHIELD = Color3.fromRGB(255, 220, 0),
	SIZE_BOMB = Color3.fromRGB(255, 80, 0),
	FREEZE_RING = Color3.fromRGB(100, 180, 255),
}

type PowerUpInstance = {
	Part: Part,
	Type: string,
	SpawnTime: number,
	Position: Vector3,
}

type ActivePowerUp = {
	Type: string,
	EndTime: number,
}

local PowerUpService = Knit.CreateService({
	Name = "PowerUpService",
	Client = {
		PowerUpSpawned = Knit.CreateSignal(),
		PowerUpCollected = Knit.CreateSignal(),
		PowerUpActivated = Knit.CreateSignal(),
		PowerUpExpired = Knit.CreateSignal(),
	},

	_powerUpsFolder = nil :: Folder?,
	_powerUps = {} :: { [string]: PowerUpInstance },
	_nextSpawnTime = 0,
	_nextId = 1,

	-- Active power-ups per player name (player name or bot name)
	_activePowerUps = {} :: { [string]: ActivePowerUp },

	-- Freeze Ring slow debuffs: { [targetName] = { EndTime, Factor } }
	_slowDebuffs = {} :: { [string]: { EndTime: number, Factor: number } },
})

--------------------------------------------------
-- Helpers
--------------------------------------------------

local function randomArenaPosition(): Vector3
	-- Spawn within a circle (not square) so power-ups stay inside the zone
	local margin = 100
	local maxRadius = HALF_ARENA - margin
	local angle = math.random() * math.pi * 2
	local dist = math.sqrt(math.random()) * maxRadius
	local x = math.cos(angle) * dist
	local z = math.sin(angle) * dist
	return Vector3.new(x, 1, z)
end

--------------------------------------------------
-- Spawning
--------------------------------------------------

function PowerUpService:_countOnMap(): number
	local count = 0
	for _ in self._powerUps do
		count += 1
	end
	return count
end

function PowerUpService:_spawnPowerUp()
	if self:_countOnMap() >= WormConfig.PowerUpMaxOnMap then
		return
	end

	local powerUpType = POWERUP_TYPES[math.random(1, #POWERUP_TYPES)]
	local color = POWERUP_COLORS[powerUpType]
	local position = randomArenaPosition()
	local id = "PowerUp_" .. self._nextId
	self._nextId += 1

	-- Create visual: sphere + light pillar
	local part = Instance.new("Part")
	part.Name = id
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(3, 3, 3)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = color

	-- Light pillar (tall thin part)
	local pillar = Instance.new("Part")
	pillar.Name = "Pillar"
	pillar.Size = Vector3.new(0.5, 40, 0.5)
	pillar.Position = position + Vector3.new(0, 20, 0)
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = color
	pillar.Transparency = 0.5
	pillar.Parent = part

	-- Point light for glow
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2
	light.Range = 15
	light.Parent = part

	-- Type label
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 100, 0, 25)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.gsub(powerUpType, "_", " ")
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	part.Parent = self._powerUpsFolder

	self._powerUps[id] = {
		Part = part,
		Type = powerUpType,
		SpawnTime = os.clock(),
		Position = position,
	}

	self.Client.PowerUpSpawned:FireAll(id, powerUpType, position, color)
end

function PowerUpService:_removePowerUp(id: string)
	local data = self._powerUps[id]
	if not data then
		return
	end
	data.Part:Destroy()
	self._powerUps[id] = nil
end

--------------------------------------------------
-- Collection & application
--------------------------------------------------

function PowerUpService:_applyPowerUp(ownerName: string, powerUpType: string)
	local config = WormConfig.PowerUpTypes[powerUpType]
	if not config then
		return
	end

	-- SIZE_BOMB is instant
	if powerUpType == "SIZE_BOMB" then
		self:_applySizeBomb(ownerName)
		return
	end

	-- FREEZE_RING is instant area effect
	if powerUpType == "FREEZE_RING" then
		self:_applyFreezeRing(ownerName)
		return
	end

	-- SHIELD has no timer but stays until consumed
	local duration = config.Duration or 0
	if powerUpType == "SHIELD" then
		duration = 30 -- shield lasts 30s max
	end

	-- Replace any existing active power-up
	local prev = self._activePowerUps[ownerName]
	if prev then
		self.Client.PowerUpExpired:FireAll(ownerName, prev.Type)
	end

	self._activePowerUps[ownerName] = {
		Type = powerUpType,
		EndTime = os.clock() + duration,
	}

	self.Client.PowerUpActivated:FireAll(ownerName, powerUpType, duration)
end

function PowerUpService:_applySizeBomb(ownerName: string)
	local segmentsToAdd = WormConfig.PowerUpTypes.SIZE_BOMB.SegmentsAdded

	-- Find the worm (player or bot) and add segments
	WormService:AddSegments(ownerName, segmentsToAdd)
	self.Client.PowerUpActivated:FireAll(ownerName, "SIZE_BOMB", 0)
end

function PowerUpService:_applyFreezeRing(ownerName: string)
	local freezeConfig = WormConfig.PowerUpTypes.FREEZE_RING
	local range = freezeConfig.Range
	local slowFactor = freezeConfig.SlowFactor
	local duration = freezeConfig.Duration

	-- Find owner's head position
	local ownerPos = self:_getHeadPosition(ownerName)
	if not ownerPos then
		return
	end

	-- Apply slow debuff to all nearby worms (not the owner)
	local now = os.clock()
	local endTime = now + duration

	-- Check all players
	for playerName, pos in self:_getAllHeadPositions() do
		if playerName ~= ownerName then
			local dist = (pos - ownerPos).Magnitude
			if dist <= range then
				self._slowDebuffs[playerName] = { EndTime = endTime, Factor = slowFactor }
			end
		end
	end

	-- Create expanding blue ring visual
	task.spawn(function()
		local ring = Instance.new("Part")
		ring.Name = "FreezeRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(100, 180, 255)
		ring.Transparency = 0.5
		ring.Size = Vector3.new(0.5, 1, 1)
		ring.CFrame = CFrame.new(ownerPos) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace

		local expandTime = 0.5
		local elapsed = 0
		while elapsed < expandTime do
			elapsed += task.wait()
			local t = math.min(elapsed / expandTime, 1)
			local diameter = range * 2 * t
			ring.Size = Vector3.new(0.5, diameter, diameter)
			ring.Transparency = 0.5 + 0.5 * t
		end

		ring:Destroy()
	end)

	self.Client.PowerUpActivated:FireAll(ownerName, "FREEZE_RING", 0)
end

function PowerUpService:_getHeadPosition(name: string): Vector3?
	-- Check players
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		if player.Name == name then
			local character = player.Character
			if character then
				local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp then
					return hrp.Position
				end
			end
			return nil
		end
	end
	-- Check bots
	local botModel = workspace:FindFirstChild(name) :: Model?
	if botModel and botModel:IsA("Model") then
		local hrp = botModel:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			return hrp.Position
		end
	end
	return nil
end

function PowerUpService:_getAllHeadPositions(): { [string]: Vector3 }
	local positions = {}
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				positions[player.Name] = hrp.Position
			end
		end
	end
	-- Bots (registered in WormService._botModels, but we can scan workspace)
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("WormHead") and not positions[child.Name] then
			local hrp = child:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				positions[child.Name] = hrp.Position
			end
		end
	end
	return positions
end

function PowerUpService:GetSlowFactor(ownerName: string): number
	local debuff = self._slowDebuffs[ownerName]
	if not debuff then
		return 1
	end
	if os.clock() >= debuff.EndTime then
		self._slowDebuffs[ownerName] = nil
		return 1
	end
	return debuff.Factor
end

function PowerUpService:CollectPowerUp(ownerName: string, headPos: Vector3): boolean
	for id, data in self._powerUps do
		local dist = (data.Position - headPos).Magnitude
		if dist < WormConfig.CollisionRadius + 2 then
			local powerUpType = data.Type
			self:_removePowerUp(id)
			self:_applyPowerUp(ownerName, powerUpType)
			self.Client.PowerUpCollected:FireAll(ownerName, powerUpType, data.Position)
			return true
		end
	end
	return false
end

--------------------------------------------------
-- Query API (used by WormService/BotService)
--------------------------------------------------

function PowerUpService:HasActivePowerUp(ownerName: string, powerUpType: string): boolean
	local active = self._activePowerUps[ownerName]
	if not active then
		return false
	end
	return active.Type == powerUpType and os.clock() < active.EndTime
end

function PowerUpService:ConsumeShield(ownerName: string): boolean
	local active = self._activePowerUps[ownerName]
	if active and active.Type == "SHIELD" then
		self._activePowerUps[ownerName] = nil
		self.Client.PowerUpExpired:FireAll(ownerName, "SHIELD")
		return true
	end
	return false
end

function PowerUpService:GetSpeedMultiplier(ownerName: string): number
	if self:HasActivePowerUp(ownerName, "SPEED") then
		return WormConfig.PowerUpTypes.SPEED.SpeedMultiplier
	end
	if self:HasActivePowerUp(ownerName, "SPEED_BURST") then
		return WormConfig.PowerUpTypes.SPEED_BURST.SpeedMultiplier
	end
	return 1
end

function PowerUpService:GetMagnetRange(ownerName: string): number
	if self:HasActivePowerUp(ownerName, "MAGNET") then
		return WormConfig.PowerUpTypes.MAGNET.Range
	end
	return 0
end

function PowerUpService:IsGhost(ownerName: string): boolean
	return self:HasActivePowerUp(ownerName, "GHOST")
end

function PowerUpService:GetNearestPowerUp(pos: Vector3, range: number): Vector3?
	local bestDist = range
	local bestPos: Vector3? = nil
	for _, data in self._powerUps do
		local dist = (data.Position - pos).Magnitude
		if dist < bestDist then
			bestDist = dist
			bestPos = data.Position
		end
	end
	return bestPos
end

function PowerUpService:ClearActivePowerUp(ownerName: string)
	local active = self._activePowerUps[ownerName]
	if active then
		self.Client.PowerUpExpired:FireAll(ownerName, active.Type)
		self._activePowerUps[ownerName] = nil
	end
end

--------------------------------------------------
-- Round reset
--------------------------------------------------

function PowerUpService:Reset()
	-- Remove all on-map power-ups
	for id in self._powerUps do
		self:_removePowerUp(id)
	end
	-- Clear active effects
	for ownerName, active in self._activePowerUps do
		self.Client.PowerUpExpired:FireAll(ownerName, active.Type)
	end
	self._activePowerUps = {}
	self._slowDebuffs = {}
	self._nextSpawnTime = os.clock() + 5
end

--------------------------------------------------
-- Game loop
--------------------------------------------------

function PowerUpService:_update()
	local now = os.clock()

	-- Spawn new power-ups on schedule
	if now >= self._nextSpawnTime then
		self:_spawnPowerUp()
		self._nextSpawnTime = now
			+ WormConfig.PowerUpSpawnIntervalMin
			+ math.random() * (WormConfig.PowerUpSpawnIntervalMax - WormConfig.PowerUpSpawnIntervalMin)
	end

	-- Despawn expired power-ups
	local toRemove = {}
	for id, data in self._powerUps do
		if now - data.SpawnTime >= WormConfig.PowerUpDespawnTime then
			table.insert(toRemove, id)
		end
	end
	for _, id in toRemove do
		self:_removePowerUp(id)
	end

	-- Expire active power-ups
	local toExpire = {}
	for ownerName, active in self._activePowerUps do
		if now >= active.EndTime then
			table.insert(toExpire, { ownerName, active.Type })
		end
	end
	for _, info in toExpire do
		self._activePowerUps[info[1]] = nil
		self.Client.PowerUpExpired:FireAll(info[1], info[2])
	end
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function PowerUpService:KnitInit()
	self._powerUpsFolder = Instance.new("Folder")
	self._powerUpsFolder.Name = "PowerUps"
	self._powerUpsFolder.Parent = workspace
end

function PowerUpService:KnitStart()
	WormService = require(script.Parent.WormService)

	self._nextSpawnTime = os.clock() + 5 -- first spawn after 5s

	RunService.Heartbeat:Connect(function()
		self:_update()
	end)
end

return PowerUpService
