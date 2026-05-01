--!strict
-- GhostHealthBar — small floating health bar attached above a ghost's
-- head. Both player ghosts (WormService:SpawnGhost) and bot ghosts
-- (BotService:_spawnBotGhost) use the same module so the visual is
-- consistent and there's exactly one place to tune the look.
--
-- The server owns both creation and updates. Updating fill.Size on the
-- server replicates to every client, so we don't need a client controller
-- to listen for HP-attribute changes — the bar stays in sync naturally.
--
-- Lookup: we cache the fill Frame as a model attribute (`_HealthBarFill`)
-- via SetAttribute is not great for Instance refs, so instead we just
-- FindFirstChild on update. Update is called only on damage events
-- (rare), so the lookup cost is irrelevant.

local GhostHealthBar = {}

local BAR_NAME = "GhostHealthBar"
local BAR_WIDTH = 80
local BAR_HEIGHT = 10
local BAR_OFFSET_Y = 3.5 -- studs above head

local function pickFillColor(pct: number): Color3
	if pct > 0.6 then
		return Color3.fromRGB(80, 220, 100)
	elseif pct > 0.3 then
		return Color3.fromRGB(220, 200, 80)
	else
		return Color3.fromRGB(220, 80, 80)
	end
end

-- Attach a health bar BillboardGui above the model's head. Returns the
-- Fill Frame so the caller can cache it if they want, but updates can
-- also go through `Update(model, hp, maxHp)` which re-finds it.
function GhostHealthBar.Attach(model: Model, maxHp: number): Frame?
	-- Anchor preference: visible Head (most accurate height), else HRP.
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		head = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	if not head then
		return nil
	end

	-- Don't double-attach (defensive — bot ghost / player ghost flows
	-- both call us; rare double-call shouldn't make two bars).
	local existing = head:FindFirstChild(BAR_NAME) :: BillboardGui?
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = BAR_NAME
	billboard.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
	billboard.StudsOffset = Vector3.new(0, BAR_OFFSET_Y, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = head

	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	bg.BackgroundTransparency = 0.3
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = pickFillColor(1)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	-- Mirror current state in attributes so any client / debug tools
	-- can read it. Auto-replicates.
	model:SetAttribute("HP", maxHp)
	model:SetAttribute("MaxHP", maxHp)

	return fill
end

-- Update the fill size + color from a new HP value. Safe to call even
-- if the bar wasn't attached or the model is mid-tear-down.
function GhostHealthBar.Update(model: Model, hp: number, maxHp: number)
	if maxHp <= 0 then
		return
	end
	model:SetAttribute("HP", math.max(0, hp))

	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		head = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	if not head then
		return
	end
	local billboard = head:FindFirstChild(BAR_NAME) :: BillboardGui?
	if not billboard then
		return
	end
	local bg = billboard:FindFirstChild("BG") :: Frame?
	if not bg then
		return
	end
	local fill = bg:FindFirstChild("Fill") :: Frame?
	if not fill then
		return
	end

	local pct = math.clamp(hp / maxHp, 0, 1)
	fill.Size = UDim2.fromScale(pct, 1)
	fill.BackgroundColor3 = pickFillColor(pct)
end

return GhostHealthBar
