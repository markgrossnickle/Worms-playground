--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------
-- Sound ID catalog
-- Using placeholder IDs (rbxassetid://0) — swap with real asset IDs
--------------------------------------------------

local SoundIds = {
	-- Food / eating
	FoodEaten = "rbxassetid://0", -- soft pop/crunch
	-- Boost
	BoostLoop = "rbxassetid://0", -- whoosh/acceleration loop
	BoostEnd = "rbxassetid://0", -- deceleration wind-down
	-- Death / kill
	PlayerDeath = "rbxassetid://0", -- dramatic explosion/splat
	KillConfirmed = "rbxassetid://0", -- satisfying ding/chime
	-- Power-ups
	PowerUpCollected = "rbxassetid://0", -- magical pickup chime (default)
	PowerUpCollected_SPEED = "rbxassetid://0", -- speed whoosh
	PowerUpCollected_SPEED_BURST = "rbxassetid://0", -- intense speed burst
	PowerUpCollected_MAGNET = "rbxassetid://0", -- magnetic hum
	PowerUpCollected_GHOST = "rbxassetid://0", -- ethereal whisper
	PowerUpCollected_SHIELD = "rbxassetid://0", -- shield clang
	PowerUpCollected_SIZE_BOMB = "rbxassetid://0", -- heavy thump
	PowerUpCollected_FREEZE_RING = "rbxassetid://0", -- ice crack
	PowerUpExpired = "rbxassetid://0", -- subtle fade
	-- Weapons
	WeaponFire_Blaster = "rbxassetid://0", -- laser zap
	WeaponFire_RapidFire = "rbxassetid://0", -- rapid pops
	WeaponFire_HighVoltage = "rbxassetid://0", -- heavy boom
	WeaponFire_Grenade = "rbxassetid://0", -- grenade thunk
	WeaponFire_PowerShot = "rbxassetid://0", -- charge-up whine then blast
	GrenadeBounce = "rbxassetid://0", -- metallic clink
	Explosion = "rbxassetid://0", -- big boom with reverb
	WeaponPickup = "rbxassetid://0", -- item pickup chime
	-- Zone
	ZoneWarning = "rbxassetid://0", -- alarm siren, escalating
	-- Round
	CountdownTick = "rbxassetid://0", -- tick each second
	RoundStart = "rbxassetid://0", -- horn/bell
	RoundVictory = "rbxassetid://0", -- fanfare
	RoundDefeat = "rbxassetid://0", -- sad trombone
	-- Ghost
	GhostSpawn = "rbxassetid://0", -- ethereal whoosh
	GhostEaten = "rbxassetid://0", -- crunch + yelp
	-- Proximity
	NearMiss = "rbxassetid://0", -- tension hum
	-- Music tracks
	MusicLobby = "rbxassetid://0", -- lobby/countdown music
	MusicGameplay = "rbxassetid://0", -- main gameplay loop
	MusicFinalThree = "rbxassetid://0", -- intense final-3 music
	MusicScoreboard = "rbxassetid://0", -- scoreboard/results music
}

--------------------------------------------------
-- Controller
--------------------------------------------------

local AudioController = Knit.CreateController({
	Name = "AudioController",

	_trove = nil :: any,
	_wormService = nil :: any,
	_wormController = nil :: any,
	_weaponController = nil :: any,
	_weaponService = nil :: any,
	_powerUpService = nil :: any,
	_shrinkZoneService = nil :: any,
	_roundService = nil :: any,

	-- Master sound group
	_masterGroup = nil :: SoundGroup?,

	-- Sound pool: reusable Sound instances keyed by name
	_sounds = {} :: { [string]: Sound },

	-- Boost loop reference
	_boostSound = nil :: Sound?,
	_isBoosting = false,

	-- Music crossfade
	_currentMusic = nil :: Sound?,
	_currentMusicKey = nil :: string?,
	_targetMusicVolume = 0.3,
	_musicFading = false,

	-- Mute state
	_muted = false,

	-- Near-miss tracking
	_lastNearMissTime = 0,
})

--------------------------------------------------
-- Safe signal connection helper
--------------------------------------------------

local function safeConnect(trove: any, signal: any, signalName: string, callback: (...any) -> ())
	if signal then
		trove:Add(signal:Connect(callback))
	else
		warn("[AudioController] Signal is nil: " .. signalName)
	end
end

--------------------------------------------------
-- Sound creation helpers
--------------------------------------------------

local function createSoundGroup(): SoundGroup
	local group = Instance.new("SoundGroup")
	group.Name = "GameAudio"
	group.Volume = 1
	group.Parent = SoundService
	return group
end

-- Create a 2D (non-positional) Sound parented to SoundService
function AudioController:_make2D(name: string, soundId: string, props: { [string]: any }?): Sound
	local cached = self._sounds[name]
	if cached and cached.Parent then
		return cached
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.SoundGroup = self._masterGroup
	sound.Parent = SoundService

	if props then
		for k, v in props do
			(sound :: any)[k] = v
		end
	end

	self._sounds[name] = sound
	return sound
end

-- Play a 2D one-shot (cloned so overlapping plays are OK)
function AudioController:_play2D(name: string, soundId: string, props: { [string]: any }?)
	if self._muted then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.SoundGroup = self._masterGroup
	if props then
		for k, v in props do
			(sound :: any)[k] = v
		end
	end
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

-- Play a 3D (positional) sound at a world position
function AudioController:_play3D(name: string, soundId: string, position: Vector3, props: { [string]: any }?)
	if self._muted then
		return
	end

	-- Create a temporary part at position for spatial audio
	local part = Instance.new("Part")
	part.Name = "SoundEmitter"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Position = position
	part.Parent = workspace

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.SoundGroup = self._masterGroup
	sound.RollOffMode = Enum.RollOffMode.Linear
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 200
	if props then
		for k, v in props do
			(sound :: any)[k] = v
		end
	end
	sound.Parent = part
	sound:Play()
	sound.Ended:Once(function()
		part:Destroy()
	end)
end

-- Determine if something happened to the local player (play 2D) or another entity (play 3D)
function AudioController:_playForEntity(
	name: string,
	soundId: string,
	entityName: string,
	fallbackPos: Vector3?,
	props: { [string]: any }?
)
	if entityName == LocalPlayer.Name then
		self:_play2D(name, soundId, props)
	else
		local pos = fallbackPos or self:_findEntityPosition(entityName)
		if pos then
			self:_play3D(name, soundId, pos, props)
		else
			self:_play2D(name, soundId, props)
		end
	end
end

function AudioController:_findEntityPosition(entityName: string): Vector3?
	-- Check players
	for _, player in Players:GetPlayers() do
		if player.Name == entityName and player.Character then
			local hrp = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				return hrp.Position
			end
		end
	end
	-- Check workspace models (bots)
	local model = workspace:FindFirstChild(entityName) :: Model?
	if model and model:IsA("Model") then
		local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			return hrp.Position
		end
	end
	return nil
end

--------------------------------------------------
-- Music system
--------------------------------------------------

function AudioController:_playMusic(key: string)
	local soundId = SoundIds[key]
	if not soundId then
		return
	end
	if self._currentMusicKey == key then
		return
	end

	-- Crossfade: fade out old, fade in new
	local oldMusic = self._currentMusic
	if oldMusic then
		self:_fadeSound(oldMusic, 0, 1.5, true)
	end

	local newMusic = Instance.new("Sound")
	newMusic.Name = "Music_" .. key
	newMusic.SoundId = soundId
	newMusic.SoundGroup = self._masterGroup
	newMusic.Looped = true
	newMusic.Volume = 0
	newMusic.Parent = SoundService

	self._currentMusic = newMusic
	self._currentMusicKey = key

	if not self._muted then
		newMusic:Play()
		self:_fadeSound(newMusic, self._targetMusicVolume, 1.5, false)
	end
end

function AudioController:_stopMusic()
	if self._currentMusic then
		self:_fadeSound(self._currentMusic, 0, 1.0, true)
		self._currentMusic = nil
		self._currentMusicKey = nil
	end
end

function AudioController:_fadeSound(sound: Sound, targetVolume: number, duration: number, destroyAfter: boolean)
	task.spawn(function()
		local startVolume = sound.Volume
		local elapsed = 0
		while elapsed < duration do
			elapsed += task.wait()
			local alpha = math.min(elapsed / duration, 1)
			sound.Volume = startVolume + (targetVolume - startVolume) * alpha
		end
		sound.Volume = targetVolume
		if destroyAfter then
			sound:Stop()
			sound:Destroy()
		end
	end)
end

--------------------------------------------------
-- Boost sound
--------------------------------------------------

function AudioController:_startBoostSound()
	if self._isBoosting then
		return
	end
	self._isBoosting = true

	if self._boostSound and self._boostSound.Parent then
		self._boostSound:Destroy()
	end

	local sound = Instance.new("Sound")
	sound.Name = "BoostLoop"
	sound.SoundId = SoundIds.BoostLoop
	sound.SoundGroup = self._masterGroup
	sound.Looped = true
	sound.Volume = 0.5
	sound.Parent = SoundService
	if not self._muted then
		sound:Play()
	end
	self._boostSound = sound
end

function AudioController:_stopBoostSound()
	if not self._isBoosting then
		return
	end
	self._isBoosting = false

	-- Play deceleration sound
	self:_play2D("BoostEnd", SoundIds.BoostEnd, { Volume = 0.4 })

	if self._boostSound then
		self:_fadeSound(self._boostSound, 0, 0.3, true)
		self._boostSound = nil
	end
end

--------------------------------------------------
-- Near-miss detection (called each frame)
--------------------------------------------------

function AudioController:_checkNearMiss()
	if not self._wormController:IsAlive() then
		return
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local myPos = hrp.Position
	local nearMissRange = 8 -- studs
	local now = os.clock()

	-- Throttle: at most once every 2 seconds
	if now - self._lastNearMissTime < 2 then
		return
	end

	-- Check for nearby worm body segments (not heads, not our own)
	for _, child in workspace:GetChildren() do
		if not child:IsA("Model") or child.Name == LocalPlayer.Name then
			continue
		end
		local segFolder = child:FindFirstChild("WormSegments") :: Folder?
		if not segFolder then
			continue
		end
		for _, seg in segFolder:GetChildren() do
			if seg:IsA("BasePart") and (seg.Position - myPos).Magnitude < nearMissRange then
				self._lastNearMissTime = now
				self:_play2D("NearMiss", SoundIds.NearMiss, { Volume = 0.2 })
				return
			end
		end
	end
end

--------------------------------------------------
-- Mute toggle
--------------------------------------------------

function AudioController:ToggleMute()
	self._muted = not self._muted

	if self._masterGroup then
		self._masterGroup.Volume = if self._muted then 0 else 1
	end

	-- Pause/resume music
	if self._currentMusic then
		if self._muted then
			self._currentMusic:Pause()
		else
			self._currentMusic:Resume()
		end
	end
end

function AudioController:IsMuted(): boolean
	return self._muted
end

--------------------------------------------------
-- Wire to game signals
--------------------------------------------------

function AudioController:_connectWormSignals()
	local wormService = self._wormService
	local wormController = self._wormController

	if not wormService then
		warn("[AudioController] WormService is nil, skipping worm signal connections")
		return
	end
	if not wormController then
		warn("[AudioController] WormController is nil, skipping worm signal connections")
		return
	end

	-- Food eaten (local player only — WormAte fires for local player)
	safeConnect(self._trove, wormService.WormAte, "WormService.WormAte", function(_newSegments: number)
		local pitch = 0.9 + math.random() * 0.2 -- 0.9-1.1
		self:_play2D("FoodEaten", SoundIds.FoodEaten, { PlaybackSpeed = pitch, Volume = 0.3 })
	end)

	-- Worm died (anyone)
	safeConnect(self._trove, wormService.WormDied, "WormService.WormDied", function(deadName: string, killerName: string?)
		-- Death sound
		self:_playForEntity("PlayerDeath", SoundIds.PlayerDeath, deadName, nil, { Volume = 0.7 })

		-- Kill confirmed (if WE killed someone)
		if killerName == LocalPlayer.Name and deadName ~= LocalPlayer.Name then
			self:_play2D("KillConfirmed", SoundIds.KillConfirmed, { Volume = 0.6 })
		end
	end)

	-- Boost tracking
	self._trove:Add(RunService.RenderStepped:Connect(function()
		local isBoosting = wormController:IsBoosting() and wormController:IsAlive()
		if isBoosting and not self._isBoosting then
			self:_startBoostSound()
		elseif not isBoosting and self._isBoosting then
			self:_stopBoostSound()
		end

		-- Near-miss check
		self:_checkNearMiss()
	end))

	-- Ghost spawned
	safeConnect(self._trove, wormService.GhostSpawned, "WormService.GhostSpawned", function(_spawnPos: Vector3)
		self:_play2D("GhostSpawn", SoundIds.GhostSpawn, { Volume = 0.5 })
	end)

	-- Ghost eaten by enemy worm — use GhostDespawned as a proxy
	-- (When a ghost is despawned while in ghost mode, it was eaten)
	safeConnect(self._trove, wormService.GhostDespawned, "WormService.GhostDespawned", function()
		-- The ghost was consumed — play the crunch
		self:_play2D("GhostEaten", SoundIds.GhostEaten, { Volume = 0.5 })
	end)
end

function AudioController:_connectPowerUpSignals()
	local powerUpService = self._powerUpService

	if not powerUpService then
		warn("[AudioController] PowerUpService is nil, skipping power-up signal connections")
		return
	end

	-- Power-up collected
	safeConnect(self._trove, powerUpService.PowerUpCollected, "PowerUpService.PowerUpCollected", function(ownerName: string, powerUpType: string, position: Vector3)
		local specificId = SoundIds["PowerUpCollected_" .. powerUpType]
		local soundId = specificId or SoundIds.PowerUpCollected
		self:_playForEntity("PowerUpCollected", soundId, ownerName, position, { Volume = 0.5 })
	end)

	-- Power-up expired (local player only)
	safeConnect(self._trove, powerUpService.PowerUpExpired, "PowerUpService.PowerUpExpired", function(ownerName: string, _powerUpType: string)
		if ownerName == LocalPlayer.Name then
			self:_play2D("PowerUpExpired", SoundIds.PowerUpExpired, { Volume = 0.3 })
		end
	end)
end

function AudioController:_connectWeaponSignals()
	local weaponService = self._weaponService
	local weaponController = self._weaponController

	if not weaponService then
		warn("[AudioController] WeaponService is nil, skipping weapon signal connections")
		return
	end
	if not weaponController then
		warn("[AudioController] WeaponController is nil, skipping weapon signal connections")
		return
	end

	-- Shot replicated (other players' shots — positional audio)
	safeConnect(self._trove, weaponService.ShotReplicated, "WeaponService.ShotReplicated", function(shooterName: string, origin: Vector3, _hitPos: Vector3, _hitPlayerName: string?)
		if shooterName == LocalPlayer.Name then
			return -- our own shots handled below
		end
		-- Determine weapon type from the shooter — default to Blaster sound
		self:_play3D("WeaponFire", SoundIds.WeaponFire_Blaster, origin, { Volume = 0.5 })
	end)

	-- Local player shot (via WeaponController signals)
	safeConnect(self._trove, weaponController.AmmoChanged, "WeaponController.AmmoChanged", function(_ammo: number)
		local weaponType = weaponController:GetWeaponType()
		if not weaponType then
			return
		end
		local soundId = SoundIds["WeaponFire_" .. weaponType]
		if soundId then
			self:_play2D("WeaponFire_" .. weaponType, soundId, { Volume = 0.5 })
		end
	end)

	-- Hit confirmed
	safeConnect(self._trove, weaponController.HitConfirmed, "WeaponController.HitConfirmed", function(_targetName: string, _damage: number)
		self:_play2D("HitConfirmed", SoundIds.KillConfirmed, { Volume = 0.3, PlaybackSpeed = 1.2 })
	end)

	-- Projectile explosion
	safeConnect(self._trove, weaponService.ProjectileExploded, "WeaponService.ProjectileExploded", function(_projId: number, position: Vector3, _radius: number)
		self:_play3D("Explosion", SoundIds.Explosion, position, { Volume = 0.8 })
	end)

	-- Projectile spawned (grenade bounce detection is done via ProjectileSpawned)
	safeConnect(self._trove, weaponService.ProjectileSpawned, "WeaponService.ProjectileSpawned", function(_projId: number, weaponType: string, position: Vector3, _velocity: Vector3, _size: number)
		local soundId = SoundIds["WeaponFire_" .. weaponType]
		if soundId then
			self:_play3D("WeaponFire_" .. weaponType, soundId, position, { Volume = 0.5 })
		end
	end)

	-- Weapon pickup collected
	safeConnect(self._trove, weaponService.WeaponPickupCollected, "WeaponService.WeaponPickupCollected", function(_id: number)
		self:_play2D("WeaponPickup", SoundIds.WeaponPickup, { Volume = 0.4 })
	end)

	-- Weapon assigned (pickup)
	safeConnect(self._trove, weaponController.WeaponAssigned, "WeaponController.WeaponAssigned", function(_weaponType: string, _ammo: number)
		self:_play2D("WeaponPickup", SoundIds.WeaponPickup, { Volume = 0.4 })
	end)
end

function AudioController:_connectRoundSignals()
	local roundService = self._roundService

	if not roundService then
		warn("[AudioController] RoundService is nil, skipping round signal connections")
		return
	end

	-- Countdown tick
	safeConnect(self._trove, roundService.RoundCountdown, "RoundService.RoundCountdown", function(seconds: number)
		if seconds <= 3 then
			self:_play2D("CountdownTick", SoundIds.CountdownTick, { Volume = 0.6, PlaybackSpeed = if seconds == 1 then 1.2 else 1.0 })
		else
			self:_play2D("CountdownTick", SoundIds.CountdownTick, { Volume = 0.3 })
		end

		-- Switch to lobby music during countdown
		if seconds >= 8 then
			self:_playMusic("MusicLobby")
		end
	end)

	-- Round started
	safeConnect(self._trove, roundService.RoundStarted, "RoundService.RoundStarted", function()
		self:_play2D("RoundStart", SoundIds.RoundStart, { Volume = 0.7 })
		self:_playMusic("MusicGameplay")
	end)

	-- Round ended
	safeConnect(self._trove, roundService.RoundEnded, "RoundService.RoundEnded", function(results: any, _winningTeam: any)
		-- Check if local player won (placement 1)
		local isWinner = false
		if typeof(results) == "table" then
			for _, entry in results :: { any } do
				if typeof(entry) == "table" and entry.Name == LocalPlayer.Name then
					if entry.Placement == 1 then
						isWinner = true
					end
					break
				end
			end
		end

		if isWinner then
			self:_play2D("RoundVictory", SoundIds.RoundVictory, { Volume = 0.7 })
		else
			self:_play2D("RoundDefeat", SoundIds.RoundDefeat, { Volume = 0.5 })
		end

		self:_playMusic("MusicScoreboard")
	end)
end

function AudioController:_connectZoneSignals()
	local shrinkZoneService = self._shrinkZoneService

	if not shrinkZoneService then
		warn("[AudioController] ShrinkZoneService is nil, skipping zone signal connections")
		return
	end

	-- Zone warning
	safeConnect(self._trove, shrinkZoneService.ZoneWarning, "ShrinkZoneService.ZoneWarning", function(_message: string)
		self:_play2D("ZoneWarning", SoundIds.ZoneWarning, { Volume = 0.6 })
	end)
end

--------------------------------------------------
-- Dynamic music intensity
--------------------------------------------------

function AudioController:_updateMusicIntensity()
	if not self._currentMusic or self._muted then
		return
	end

	-- Count nearby worms for intensity scaling
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local nearbyCount = 0
	local checkRange = 80

	for _, child in workspace:GetChildren() do
		if not child:IsA("Model") or child.Name == LocalPlayer.Name then
			continue
		end
		local otherHrp = child:FindFirstChild("HumanoidRootPart") :: BasePart?
		if otherHrp and (otherHrp.Position - hrp.Position).Magnitude < checkRange then
			nearbyCount += 1
		end
	end

	-- Reduce music volume when many worms are nearby (more gameplay sounds)
	local intensityFactor = math.clamp(1 - (nearbyCount * 0.1), 0.15, 1)
	self._targetMusicVolume = 0.3 * intensityFactor
	-- Smoothly adjust (don't snap)
	if self._currentMusic then
		self._currentMusic.Volume += (self._targetMusicVolume - self._currentMusic.Volume) * 0.05
	end
end

--------------------------------------------------
-- Final-3 music detection
--------------------------------------------------

function AudioController:_checkFinalThreeMusic()
	if self._currentMusicKey ~= "MusicGameplay" and self._currentMusicKey ~= "MusicFinalThree" then
		return
	end

	-- Count alive worms in workspace
	local aliveCount = 0
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("WormHead") then
			aliveCount += 1
		end
	end

	if aliveCount <= 3 and self._currentMusicKey ~= "MusicFinalThree" then
		self:_playMusic("MusicFinalThree")
	end
end

--------------------------------------------------
-- Input: mute toggle (M key)
--------------------------------------------------

function AudioController:_setupInput()
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.M then
			self:ToggleMute()
		end
	end)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function AudioController:KnitInit()
	self._trove = Trove.new()
	self._masterGroup = createSoundGroup()
end

function AudioController:KnitStart()
	self._wormService = Knit.GetService("WormService")
	self._wormController = Knit.GetController("WormController")
	self._weaponController = Knit.GetController("WeaponController")
	self._weaponService = Knit.GetService("WeaponService")
	self._powerUpService = Knit.GetService("PowerUpService")
	self._shrinkZoneService = Knit.GetService("ShrinkZoneService")
	self._roundService = Knit.GetService("RoundService")

	self:_setupInput()
	self:_connectWormSignals()
	self:_connectPowerUpSignals()
	self:_connectWeaponSignals()
	self:_connectRoundSignals()
	self:_connectZoneSignals()

	-- Periodic checks (music intensity + final-3 detection)
	self._trove:Add(RunService.Heartbeat:Connect(function()
		self:_updateMusicIntensity()
		self:_checkFinalThreeMusic()
	end))

	-- Start with lobby music
	self:_playMusic("MusicLobby")
end

return AudioController
