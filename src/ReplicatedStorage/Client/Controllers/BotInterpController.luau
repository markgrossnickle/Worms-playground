--!strict
-- BotInterpController — smooths bot worm rendering on the client.
--
-- The problem: bot worm Parts are server-anchored, and the server writes
-- their CFrames at a discrete cadence (30Hz, every 2nd Heartbeat in
-- BotService). Roblox's automatic anchored-Part replication is snap-only —
-- when the client receives a new CFrame it just sets it, with no
-- interpolation. So even at 30Hz updates clients see the bot teleport in
-- ~33ms steps. From a smooth camera baseline this reads as visible jumpiness.
--
-- The fix: this controller runs every frame on the client and lerps each
-- bot Part's CFrame from where it currently is toward where the server
-- last replicated it to. Since the server writes ≤30Hz and we lerp at the
-- frame rate (≥60Hz), each replicated snap gets smoothly distributed across
-- the next ~2-3 frames instead of jumping in one frame.
--
-- Detection of "the server just replicated a new value":
--   We track `lastWrite` per Part — the CFrame *we* most recently set.
--   At the start of each frame, if `part.CFrame` differs from `lastWrite`,
--   the only thing that could have changed it is the server replication
--   layer (anchored parts have no physics simulation). That's our new
--   target. We then lerp `displayed → target` and write the result.
--
-- Bots are identified by the `IsBotWorm` attribute on the Model
-- (see BotService:_createBotModel). Player worms are NOT smoothed — the
-- local player's own worm is jumpy in absolute terms but the camera
-- follows it, so the relative motion looks smooth; smoothing would
-- actually break input → camera responsiveness.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)

-- Lerp speed in 1/sec. Higher = snappier (more aggressive catch-up to the
-- server's latest snapshot). 18 means we close ~70% of the gap to target
-- in 60ms, which is a good balance between "smooth" and "responsive."
local SMOOTH_RATE = 18

-- Anything farther than this from the target is treated as a teleport
-- (e.g. respawn, knockoff, anti-cheat correction) and snapped instantly
-- without interpolation. Otherwise a bot that respawns across the map
-- would lerp visibly across the whole arena.
local TELEPORT_THRESHOLD = 25

type PartState = {
	displayed: CFrame,
	target: CFrame,
	lastWrite: CFrame,
}

local BotInterpController = Knit.CreateController({
	Name = "BotInterpController",

	-- Per-Part interpolation state. Keyed by BasePart, value is PartState.
	_parts = {} :: { [BasePart]: PartState },
	-- Per-Model trove holding DescendantAdded/Removing connections so they
	-- get cleaned up when the model is reparented or destroyed (avoids the
	-- leak path where ChildRemoved doesn't fire because the model was just
	-- moved out of workspace, not destroyed).
	_modelTroves = {} :: { [Model]: any },
})

function BotInterpController:_isBotModel(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	if instance:GetAttribute("IsBotWorm") ~= true then
		return false
	end
	-- Defensive: skip if a player owns this model (shouldn't happen, but
	-- anchored-Part tracking on a player worm would interfere with input).
	if Players:GetPlayerFromCharacter(instance) ~= nil then
		return false
	end
	return true
end

function BotInterpController:_registerPart(part: BasePart)
	if self._parts[part] then
		return
	end
	local cf = part.CFrame
	self._parts[part] = {
		displayed = cf,
		target = cf,
		lastWrite = cf,
	}
end

function BotInterpController:_unregisterPart(part: BasePart)
	self._parts[part] = nil
end

function BotInterpController:_registerModel(model: Model)
	if self._modelTroves[model] then
		return -- already registered
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			self:_registerPart(descendant)
		end
	end
	-- Track DescendantAdded/Removing connections in a Trove keyed by Model.
	-- Without this, a Model being reparented (not destroyed) would orphan
	-- the connections AND leave its parts registered indefinitely.
	local trove = Trove.new()
	trove:Connect(model.DescendantAdded, function(descendant)
		if descendant:IsA("BasePart") then
			self:_registerPart(descendant)
		end
	end)
	trove:Connect(model.DescendantRemoving, function(descendant)
		if descendant:IsA("BasePart") then
			self:_unregisterPart(descendant)
		end
	end)
	-- Also clean up when the model itself is destroyed/leaves workspace.
	trove:Connect(model.AncestryChanged, function(_, parent)
		if parent == nil or not parent:IsDescendantOf(workspace) then
			self:_unregisterModel(model)
		end
	end)
	self._modelTroves[model] = trove
end

function BotInterpController:_unregisterModel(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			self:_unregisterPart(descendant)
		end
	end
	local trove = self._modelTroves[model]
	if trove then
		trove:Destroy()
		self._modelTroves[model] = nil
	end
end

function BotInterpController:KnitInit() end

function BotInterpController:KnitStart()
	-- Register every bot already in workspace at start time.
	for _, child in workspace:GetChildren() do
		if self:_isBotModel(child) then
			self:_registerModel(child :: Model)
		end
	end

	-- Watch for bots that arrive later (per round, per spawn).
	workspace.ChildAdded:Connect(function(child)
		if self:_isBotModel(child) then
			self:_registerModel(child :: Model)
		end
	end)
	workspace.ChildRemoved:Connect(function(child)
		if child:IsA("Model") and self._modelTroves[child] then
			self:_unregisterModel(child)
		end
	end)

	-- Per-frame smoothing pass. RenderStepped runs after replication for the
	-- frame is applied, so reads of part.CFrame here see the latest value
	-- the server pushed.
	--
	-- Performance: we use `workspace:BulkMoveTo` instead of writing
	-- `part.CFrame = ...` individually. With ~24 bots × ~30 parts each,
	-- per-Part writes produce ~43,000 CFrame writes/sec at 60fps and each
	-- one fires property-changed events. BulkMoveTo is a single C++ batched
	-- call that takes parallel `parts` + `cframes` arrays and (with
	-- FireCFrameChanged) only fires CFrame events, skipping Position and
	-- Rotation. This was the dominant client-side hot spot per script
	-- profiler.
	--
	-- We also skip parts that are already at target (no observable lerp
	-- progress), so stationary or fully-converged bots cost ~zero per frame.
	--
	-- Iteration safety: dead keys are collected into `toRemove` rather than
	-- assigning nil to `self._parts[part]` mid-loop. Lua's generic-for over
	-- a table has undefined behavior when a key is set to nil during
	-- traversal — entries can be skipped or visited twice.
	local toRemove: { BasePart } = {}
	local partsBuf: { BasePart } = {}
	local cframesBuf: { CFrame } = {}
	-- Anything below this delta from target is treated as "already there"
	-- and skipped. 0.01 stud / ~0.01 deg is well below per-pixel visibility.
	local CONVERGED_EPSILON = 0.01

	RunService.RenderStepped:Connect(function(dt: number)
		local alpha = math.min(1, dt * SMOOTH_RATE)

		-- Reusable scratch buffers — clear and refill each frame. table.clear
		-- keeps the backing array allocated, so subsequent table.insert
		-- doesn't allocate. This is the standard Lua pattern for per-frame
		-- staging buffers.
		table.clear(partsBuf)
		table.clear(cframesBuf)

		for part, state in self._parts do
			if not part.Parent then
				table.insert(toRemove, part)
				continue
			end

			local replicated = part.CFrame

			-- If `replicated` differs from `lastWrite`, the server pushed a
			-- new authoritative value since our last frame's write. Adopt it
			-- as the new target.
			--
			-- FuzzyEq tolerance is intentionally generous (0.05 studs / ~0.05 deg)
			-- so floating-point round-trip noise on our own writes doesn't
			-- get misidentified as a server snap.
			if not replicated:FuzzyEq(state.lastWrite, 0.05) then
				-- Big jump = teleport, not a normal motion update. Snap.
				if (replicated.Position - state.target.Position).Magnitude > TELEPORT_THRESHOLD then
					state.displayed = replicated
				end
				state.target = replicated
			end

			-- Skip stationary / converged parts entirely — no lerp, no write.
			if state.displayed:FuzzyEq(state.target, CONVERGED_EPSILON) then
				continue
			end

			-- Lerp displayed → target by alpha. Queue for batched write.
			local newDisplayed = state.displayed:Lerp(state.target, alpha)
			state.displayed = newDisplayed
			state.lastWrite = newDisplayed
			table.insert(partsBuf, part)
			table.insert(cframesBuf, newDisplayed)
		end

		-- Batched CFrame write. FireCFrameChanged fires only the CFrame
		-- property changed signal (skipping Position / Rotation events) —
		-- C++ batched, much cheaper than per-Part assignment. This was the
		-- dominant client-side hot spot per script profiler before batching.
		if #partsBuf > 0 then
			workspace:BulkMoveTo(partsBuf, cframesBuf, Enum.BulkMoveMode.FireCFrameChanged)
		end

		if #toRemove > 0 then
			for _, part in toRemove do
				self._parts[part] = nil
			end
			table.clear(toRemove)
		end
	end)
end

return BotInterpController
