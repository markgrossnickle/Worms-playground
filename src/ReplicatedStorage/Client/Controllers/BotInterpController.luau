--!strict
-- BotInterpController — smooths worm rendering on the client (despite the
-- name, it now handles BOTH bot worms AND other-player worms).
--
-- The problem: server-anchored worm Parts have their CFrames written at a
-- discrete cadence (30Hz for bots in BotService, 10Hz for player worms in
-- WormService). Roblox's automatic anchored-Part replication is snap-only —
-- when the client receives a new CFrame it just sets it, with no
-- interpolation. So clients see worms teleport in 33-100ms steps. From a
-- smooth camera baseline this reads as visible choppiness, especially
-- with many worms on screen.
--
-- The fix: this controller runs every frame on the client and lerps each
-- worm Part's CFrame from where it currently is toward where the server
-- last replicated it to. Since the server writes infrequently and we lerp
-- at the frame rate, each replicated snap gets smoothly distributed
-- across the next ~2-3 frames instead of jumping in one frame.
--
-- Detection of "the server just replicated a new value":
--   We track `lastWrite` per Part — the CFrame *we* most recently set.
--   At the start of each frame, if `part.CFrame` differs from `lastWrite`,
--   the only thing that could have changed it is the server replication
--   layer (anchored parts have no physics simulation). That's our new
--   target. We then lerp `displayed → target` and write the result.
--
-- We smooth: bot worms (IsBotWorm) + other-player worms (IsPlayerWorm,
-- excluding the local player). The LOCAL player's own worm is NOT
-- smoothed — the camera follows it, so the relative motion already looks
-- correct, and smoothing would lag input→camera responsiveness.
--
-- Performance: writes are batched via workspace:BulkMoveTo with
-- FireCFrameChanged so the per-frame cost stays flat regardless of how
-- many worms are on screen.

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

-- Should we smooth this Model? True for: any Model with IsBotWorm
-- (server-controlled bot), OR any Model with IsPlayerWorm that isn't the
-- local player's own character.
function BotInterpController:_shouldSmoothModel(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	if instance:GetAttribute("IsBotWorm") then
		-- Defensive: bot models shouldn't have a Player owner, but be safe.
		if Players:GetPlayerFromCharacter(instance) == nil then
			return true
		end
		return false
	end
	if instance:GetAttribute("IsPlayerWorm") then
		-- Skip the local player's own character — the camera tracks it
		-- and smoothing would introduce input→camera lag.
		local owner = Players:GetPlayerFromCharacter(instance)
		if owner and owner ~= Players.LocalPlayer then
			return true
		end
	end
	return false
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
	-- Register every smooth-eligible model already in workspace at start.
	for _, child in workspace:GetChildren() do
		if self:_shouldSmoothModel(child) then
			self:_registerModel(child :: Model)
		end
	end

	-- For models that arrive later, register immediately if they already
	-- qualify; otherwise (player characters arrive in workspace BEFORE the
	-- server sets IsPlayerWorm) subscribe to the attribute change and
	-- register when it lands. The attribute subscription auto-cleans up
	-- if the model leaves workspace before the attribute is set.
	workspace.ChildAdded:Connect(function(child)
		if self:_shouldSmoothModel(child) then
			self:_registerModel(child :: Model)
			return
		end
		if not child:IsA("Model") then
			return
		end
		local owner = Players:GetPlayerFromCharacter(child)
		if owner and owner ~= Players.LocalPlayer then
			local attrConn: RBXScriptConnection? = nil
			local function check()
				if self:_shouldSmoothModel(child) then
					self:_registerModel(child :: Model)
					if attrConn then
						attrConn:Disconnect()
						attrConn = nil
					end
				end
			end
			attrConn = child:GetAttributeChangedSignal("IsPlayerWorm"):Connect(check)
			-- Re-check now in case the attribute was set in the same frame
			check()
			-- Defensive cleanup if the character leaves before the tag lands
			child.AncestryChanged:Once(function(_, parent)
				if parent == nil and attrConn then
					attrConn:Disconnect()
					attrConn = nil
				end
			end)
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
