--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Trove = require(ReplicatedStorage.Packages.Trove)
local SkinConfig = require(ReplicatedStorage.Shared.SkinConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local RARITY_COLORS = SkinConfig.RarityColors

local ShopController = Knit.CreateController({
	Name = "ShopController",

	_trove = nil :: any,
	_skinService = nil :: any,
	_coinService = nil :: any,
	_screenGui = nil :: ScreenGui?,
	_shopFrame = nil :: Frame?,
	_gridFrame = nil :: ScrollingFrame?,
	_coinLabel = nil :: TextLabel?,
	_isOpen = false,
	_ownedSkins = {} :: { string },
	_equippedSkin = "default",
	_coins = 0,
	_skinCards = {} :: { [string]: Frame },
})

--------------------------------------------------
-- UI helpers
--------------------------------------------------

local function createCorner(parent: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = parent
end

local function createStroke(parent: GuiObject, color: Color3, thickness: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 1
	stroke.Parent = parent
end

--------------------------------------------------
-- Shop UI construction
--------------------------------------------------

function ShopController:_buildShopUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShopUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Enabled = false
	gui.Parent = PlayerGui
	self._screenGui = gui

	-- Main frame
	local shopFrame = Instance.new("Frame")
	shopFrame.Name = "ShopFrame"
	shopFrame.Size = UDim2.new(0, 700, 0, 500)
	shopFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	shopFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	shopFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	shopFrame.BackgroundTransparency = 0.05
	shopFrame.BorderSizePixel = 0
	shopFrame.Parent = gui
	self._shopFrame = shopFrame

	createCorner(shopFrame, 12)
	createStroke(shopFrame, Color3.fromRGB(80, 80, 120), 2)

	-- Title bar
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 50)
	titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 50)
	titleBar.BackgroundTransparency = 0.2
	titleBar.BorderSizePixel = 0
	titleBar.Parent = shopFrame

	createCorner(titleBar, 12)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Text = "Skin Shop"
	titleLabel.Size = UDim2.new(0.5, 0, 1, 0)
	titleLabel.Position = UDim2.new(0, 16, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.TextSize = 24
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = titleBar

	-- Coin display
	local coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinLabel"
	coinLabel.Text = "0 Coins"
	coinLabel.Size = UDim2.new(0, 150, 0, 30)
	coinLabel.Position = UDim2.new(1, -170, 0.5, 0)
	coinLabel.AnchorPoint = Vector2.new(0, 0.5)
	coinLabel.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
	coinLabel.BackgroundTransparency = 0.3
	coinLabel.TextColor3 = Color3.fromRGB(255, 220, 50)
	coinLabel.TextSize = 16
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.BorderSizePixel = 0
	coinLabel.Parent = titleBar
	self._coinLabel = coinLabel

	createCorner(coinLabel, 6)

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Text = "X"
	closeBtn.Size = UDim2.new(0, 36, 0, 36)
	closeBtn.Position = UDim2.new(1, -8, 0.5, 0)
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
	closeBtn.BackgroundTransparency = 0.3
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.TextSize = 18
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.BorderSizePixel = 0
	closeBtn.Parent = titleBar

	createCorner(closeBtn, 6)

	closeBtn.Activated:Connect(function()
		self:ToggleShop()
	end)

	-- Scrolling grid
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "SkinGrid"
	grid.Size = UDim2.new(1, -20, 1, -60)
	grid.Position = UDim2.new(0, 10, 0, 55)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 140)
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.Parent = shopFrame
	self._gridFrame = grid

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0, 155, 0, 210)
	gridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.Parent = grid

	local gridPadding = Instance.new("UIPadding")
	gridPadding.PaddingTop = UDim.new(0, 5)
	gridPadding.PaddingBottom = UDim.new(0, 5)
	gridPadding.Parent = grid

	-- Build skin cards
	for i, skin in SkinConfig.Skins do
		self:_buildSkinCard(grid, skin, i)
	end
end

function ShopController:_buildSkinCard(parent: ScrollingFrame, skin: SkinConfig.SkinDef, layoutOrder: number)
	local rarityColor = RARITY_COLORS[skin.rarity] or Color3.fromRGB(180, 180, 180)

	local card = Instance.new("Frame")
	card.Name = "Card_" .. skin.id
	card.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	card.LayoutOrder = layoutOrder
	card.Parent = parent

	createCorner(card, 8)
	createStroke(card, rarityColor, 2)

	-- Skin preview area
	local previewFrame = Instance.new("Frame")
	previewFrame.Name = "Preview"
	previewFrame.Size = UDim2.new(1, -16, 0, 80)
	previewFrame.Position = UDim2.new(0, 8, 0, 8)
	previewFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
	previewFrame.BackgroundTransparency = 0.2
	previewFrame.BorderSizePixel = 0
	previewFrame.Parent = card

	createCorner(previewFrame, 6)

	-- Mini worm preview (head + segments as colored circles)
	self:_buildWormPreview(previewFrame, skin)

	-- Rarity badge
	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "Rarity"
	rarityLabel.Text = skin.rarity
	rarityLabel.Size = UDim2.new(0, 70, 0, 18)
	rarityLabel.Position = UDim2.new(0.5, 0, 0, 92)
	rarityLabel.AnchorPoint = Vector2.new(0.5, 0)
	rarityLabel.BackgroundColor3 = rarityColor
	rarityLabel.BackgroundTransparency = 0.3
	rarityLabel.TextColor3 = Color3.new(1, 1, 1)
	rarityLabel.TextSize = 11
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.BorderSizePixel = 0
	rarityLabel.Parent = card

	createCorner(rarityLabel, 4)

	-- Name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "SkinName"
	nameLabel.Text = skin.name
	nameLabel.Size = UDim2.new(1, -10, 0, 20)
	nameLabel.Position = UDim2.new(0, 5, 0, 114)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Price label
	local priceText = if skin.price == 0 then "Free" else tostring(skin.price) .. " Coins"
	local priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "Price"
	priceLabel.Text = priceText
	priceLabel.Size = UDim2.new(1, -10, 0, 16)
	priceLabel.Position = UDim2.new(0, 5, 0, 136)
	priceLabel.BackgroundTransparency = 1
	priceLabel.TextColor3 = Color3.fromRGB(255, 220, 50)
	priceLabel.TextSize = 12
	priceLabel.Font = Enum.Font.Gotham
	priceLabel.TextXAlignment = Enum.TextXAlignment.Center
	priceLabel.Parent = card

	-- Action button
	local actionBtn = Instance.new("TextButton")
	actionBtn.Name = "ActionBtn"
	actionBtn.Text = "Buy"
	actionBtn.Size = UDim2.new(1, -20, 0, 32)
	actionBtn.Position = UDim2.new(0, 10, 1, -42)
	actionBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
	actionBtn.TextColor3 = Color3.new(1, 1, 1)
	actionBtn.TextSize = 14
	actionBtn.Font = Enum.Font.GothamBold
	actionBtn.BorderSizePixel = 0
	actionBtn.Parent = card

	createCorner(actionBtn, 6)

	actionBtn.Activated:Connect(function()
		self:_onCardAction(skin.id)
	end)

	-- Equipped checkmark (hidden by default)
	local checkmark = Instance.new("TextLabel")
	checkmark.Name = "Checkmark"
	checkmark.Text = "Equipped"
	checkmark.Size = UDim2.new(1, -20, 0, 32)
	checkmark.Position = UDim2.new(0, 10, 1, -42)
	checkmark.BackgroundColor3 = Color3.fromRGB(60, 60, 100)
	checkmark.BackgroundTransparency = 0.3
	checkmark.TextColor3 = Color3.fromRGB(100, 255, 100)
	checkmark.TextSize = 14
	checkmark.Font = Enum.Font.GothamBold
	checkmark.BorderSizePixel = 0
	checkmark.Visible = false
	checkmark.Parent = card

	createCorner(checkmark, 6)

	self._skinCards[skin.id] = card
end

function ShopController:_buildWormPreview(parent: Frame, skin: SkinConfig.SkinDef)
	local dotCount = 5 -- 1 head + 4 segments
	local circleSize = 14
	local spacing = 3
	local totalLength = dotCount * circleSize + (dotCount - 1) * spacing

	for i = 0, dotCount - 1 do
		local circle = Instance.new("Frame")
		circle.Name = "PreviewDot" .. i
		circle.Size = UDim2.new(0, circleSize, 0, circleSize)
		circle.Position = UDim2.new(0.5, -totalLength / 2 + i * (circleSize + spacing), 0.5, -circleSize / 2)
		circle.BackgroundColor3 = if i == 0 then skin.headColor else skin.segmentColor
		circle.BorderSizePixel = 0
		circle.Parent = parent

		createCorner(circle, circleSize / 2)
	end
end

--------------------------------------------------
-- Card state management
--------------------------------------------------

function ShopController:_isOwned(skinId: string): boolean
	for _, id in self._ownedSkins do
		if id == skinId then
			return true
		end
	end
	return false
end

function ShopController:_updateAllCards()
	for _, skin in SkinConfig.Skins do
		self:_updateCard(skin.id)
	end
end

function ShopController:_updateCard(skinId: string)
	local card = self._skinCards[skinId]
	if not card then
		return
	end

	local actionBtn = card:FindFirstChild("ActionBtn") :: TextButton?
	local checkmark = card:FindFirstChild("Checkmark") :: TextLabel?
	if not actionBtn or not checkmark then
		return
	end

	local skinDef = SkinConfig.SkinsById[skinId]
	if not skinDef then
		return
	end

	local owned = self:_isOwned(skinId)
	local equipped = self._equippedSkin == skinId

	if equipped then
		actionBtn.Visible = false
		checkmark.Visible = true
	elseif owned then
		actionBtn.Visible = true
		checkmark.Visible = false
		actionBtn.Text = "Equip"
		actionBtn.BackgroundColor3 = Color3.fromRGB(60, 100, 180)
	else
		actionBtn.Visible = true
		checkmark.Visible = false
		local canAfford = self._coins >= skinDef.price
		actionBtn.Text = "Buy"
		actionBtn.BackgroundColor3 = if canAfford then Color3.fromRGB(60, 140, 60) else Color3.fromRGB(100, 100, 100)
	end
end

function ShopController:_updateCoinDisplay()
	if self._coinLabel then
		self._coinLabel.Text = tostring(self._coins) .. " Coins"
	end
end

--------------------------------------------------
-- Actions
--------------------------------------------------

function ShopController:_onCardAction(skinId: string)
	local owned = self:_isOwned(skinId)

	if owned then
		-- Equip
		local ok, result = self._skinService:EquipSkin(skinId):await()
		if ok then
			if not result then
				warn("ShopController: Equip failed")
			end
		end
	else
		-- Purchase
		local ok, result = self._skinService:PurchaseSkin(skinId):await()
		if ok then
			if not result then
				warn("ShopController: Purchase failed")
			end
		end
	end
end

function ShopController:ToggleShop()
	self._isOpen = not self._isOpen
	if self._screenGui then
		self._screenGui.Enabled = self._isOpen
	end
	if self._isOpen then
		self:_refreshData()
	end
end

function ShopController:_refreshData()
	-- Fetch latest owned skins and equipped skin
	local okOwned, owned = self._skinService:GetOwnedSkins():await()
	if okOwned and owned then
		self._ownedSkins = owned
	end

	local okEquipped, equipped = self._skinService:GetEquippedSkin():await()
	if okEquipped and equipped then
		self._equippedSkin = equipped
	end

	local okCoins, coins = self._coinService:GetCoins():await()
	if okCoins and coins then
		self._coins = coins
	end

	self:_updateCoinDisplay()
	self:_updateAllCards()
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function ShopController:KnitInit()
	self._trove = Trove.new()
end

function ShopController:KnitStart()
	self._skinService = Knit.GetService("SkinService")
	self._coinService = Knit.GetService("CoinService")

	self:_buildShopUI()

	-- Toggle shop with B key
	self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			self:ToggleShop()
		end
	end)

	-- Listen for skin purchased
	self._trove:Add(self._skinService.SkinPurchased:Connect(function(skinId: string)
		table.insert(self._ownedSkins, skinId)
		self:_updateCard(skinId)
	end))

	-- Listen for skin equipped
	self._trove:Add(self._skinService.SkinEquipped:Connect(function(skinId: string)
		local oldEquipped = self._equippedSkin
		self._equippedSkin = skinId
		self:_updateCard(oldEquipped)
		self:_updateCard(skinId)
	end))

	-- Listen for coin changes
	self._trove:Add(self._coinService.CoinsChanged:Connect(function(newCoins: number)
		self._coins = newCoins
		self:_updateCoinDisplay()
		self:_updateAllCards()
	end))

	-- Fetch initial data
	task.spawn(function()
		self:_refreshData()
	end)
end

return ShopController
