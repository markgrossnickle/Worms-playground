--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local WormConfig = require(ReplicatedStorage.Shared.WormConfig)

local HALF_ARENA = WormConfig.ArenaSize / 2
local RING_SEGMENTS = 64
local RING_HEIGHT = 15
local CLIENT_UPDATE_INTERVAL = 0.5 -- Send zone updates to clients at 2Hz

local ShrinkZoneService = Knit.CreateService({
	Name = "ShrinkZoneService",
	Client = {
		ZoneUpdate = Knit.CreateSignal(), -- fires (radius, elapsed)
		ZoneWarning = Knit.CreateSignal(), -- fires (message)
	},

	_gameStartTime = 0,
	_currentRadius = HALF_ARENA,
	_ringParts = {} :: { BasePart },
	_ringFolder = nil :: Folder?,
	_warnedStart = false,
	_warned30s = false,
	_lastClientUpdate = 0,
})

--------------------------------------------------
-- Ring visual
--------------------------------------------------

function ShrinkZoneService:_createRing()
	local folder = Instance.new("Folder")
	folder.Name = "ShrinkZone"
	folder.Parent = workspace
	self._ringFolder = folder

	for i = 1, RING_SEGMENTS do
		local part = Instance.new("Part")
		part.Name = "Ring" .. i
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false -- Don't block weapon raycasts
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 50, 50)
		part.Transparency = 0.4
		part.Parent = folder
		table.insert(self._ringParts, part)
	end

	self:_updateRingVisual()
end

function ShrinkZoneService:_updateRingVisual()
	local radius = self._currentRadius
	local segAngle = (2 * math.pi) / RING_SEGMENTS
	-- Each segment is a thin wall section
	local arcLength = 2 * radius * math.sin(segAngle / 2)

	for i, part in self._ringParts do
		if not part or not part.Parent then
			continue
		end
		local angle = segAngle * (i - 1)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		part.Size = Vector3.new(math.max(arcLength + 0.5, 0.5), RING_HEIGHT, 1)
		part.CFrame = CFrame.new(Vector3.new(x, RING_HEIGHT / 2, z)) * CFrame.Angles(0, -angle + math.pi / 2, 0)
	end
end

--------------------------------------------------
-- Zone logic
--------------------------------------------------

function ShrinkZoneService:GetCurrentRadius(): number
	return self._currentRadius
end

function ShrinkZoneService:GetElapsedTime(): number
	return os.clock() - self._gameStartTime
end

function ShrinkZoneService:IsOutsideZone(position: Vector3): boolean
	local dist = Vector3.new(position.X, 0, position.Z).Magnitude
	return dist > self._currentRadius
end

function ShrinkZoneService:_update()
	local elapsed = self:GetElapsedTime()
	local now = os.clock()

	-- Warnings
	if not self._warnedStart and elapsed >= WormConfig.ShrinkStartTime - 10 then
		self._warnedStart = true
		self.Client.ZoneWarning:FireAll("Zone shrinking in 10 seconds!")
	end

	if not self._warned30s and elapsed >= WormConfig.ShrinkEndTime - 30 then
		self._warned30s = true
		self.Client.ZoneWarning:FireAll("Zone closing in 30 seconds!")
	end

	-- Calculate radius
	local minRadius = WormConfig.ShrinkMinRadius
	if elapsed < WormConfig.ShrinkStartTime then
		self._currentRadius = HALF_ARENA
	elseif elapsed >= WormConfig.ShrinkEndTime then
		self._currentRadius = minRadius
	else
		-- Linear interpolation from full to minimum radius
		local t = (elapsed - WormConfig.ShrinkStartTime) / (WormConfig.ShrinkEndTime - WormConfig.ShrinkStartTime)
		self._currentRadius = HALF_ARENA + (minRadius - HALF_ARENA) * t
	end

	self:_updateRingVisual()

	-- Throttle client updates to avoid network spam
	if now - self._lastClientUpdate >= CLIENT_UPDATE_INTERVAL then
		self._lastClientUpdate = now
		self.Client.ZoneUpdate:FireAll(self._currentRadius, elapsed)
	end
end

--------------------------------------------------
-- Round reset
--------------------------------------------------

function ShrinkZoneService:Reset()
	self._gameStartTime = os.clock()
	self._currentRadius = HALF_ARENA
	self._warnedStart = false
	self._warned30s = false
	self._lastClientUpdate = 0
	self:_updateRingVisual()
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function ShrinkZoneService:KnitInit()
	self:_createRing()
end

function ShrinkZoneService:KnitStart()
	self._gameStartTime = os.clock()

	RunService.Heartbeat:Connect(function()
		self:_update()
	end)
end

return ShrinkZoneService
