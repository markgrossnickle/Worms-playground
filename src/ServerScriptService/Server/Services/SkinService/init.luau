--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local SkinConfig = require(ReplicatedStorage.Shared.SkinConfig)

local PlayerDataService -- Set in KnitStart
local CoinService -- Set in KnitStart

local SkinService = Knit.CreateService({
	Name = "SkinService",
	Client = {
		SkinEquipped = Knit.CreateSignal(),
		SkinPurchased = Knit.CreateSignal(),
	},

	-- Server-side signals for other services to listen to
	SkinEquipped = Signal.new(),
	SkinPurchased = Signal.new(),
})

function SkinService:GetOwnedSkins(player: Player): { string }
	local owned = PlayerDataService:Read(player, { "OwnedSkins" })
	if owned == nil then
		return { "default" }
	end
	return owned
end

function SkinService:GetEquippedSkin(player: Player): string
	local equipped = PlayerDataService:Read(player, { "EquippedSkin" })
	if equipped == nil or equipped == "" then
		return "default"
	end
	return equipped
end

function SkinService:_playerOwnsSkin(player: Player, skinId: string): boolean
	local owned = self:GetOwnedSkins(player)
	for _, id in owned do
		if id == skinId then
			return true
		end
	end
	return false
end

function SkinService:PurchaseSkin(player: Player, skinId: string): (boolean, string?)
	local skinDef = SkinConfig.SkinsById[skinId]
	if not skinDef then
		return false, "Invalid skin"
	end

	if self:_playerOwnsSkin(player, skinId) then
		return false, "Already owned"
	end

	local coins = CoinService:GetCoins(player)
	if coins < skinDef.price then
		return false, "Not enough coins"
	end

	-- Deduct coins
	local newCoins = coins - skinDef.price
	PlayerDataService:Write(player, { "Coins" }, newCoins)
	CoinService.Client.CoinsChanged:Fire(player, newCoins)

	-- Add skin to owned list
	local owned = self:GetOwnedSkins(player)
	table.insert(owned, skinId)
	PlayerDataService:Write(player, { "OwnedSkins" }, owned)

	-- Fire signals
	self.Client.SkinPurchased:Fire(player, skinId)
	self.SkinPurchased:Fire(player, skinId)

	return true, nil
end

function SkinService:EquipSkin(player: Player, skinId: string): (boolean, string?)
	if not self:_playerOwnsSkin(player, skinId) then
		return false, "Skin not owned"
	end

	local skinDef = SkinConfig.SkinsById[skinId]
	if not skinDef then
		return false, "Invalid skin"
	end

	PlayerDataService:Write(player, { "EquippedSkin" }, skinId)

	self.Client.SkinEquipped:Fire(player, skinId)
	self.SkinEquipped:Fire(player, skinId)

	return true, nil
end

function SkinService:GetSkinDef(player: Player): SkinConfig.SkinDef
	local skinId = self:GetEquippedSkin(player)
	local skinDef = SkinConfig.SkinsById[skinId]
	if not skinDef then
		return SkinConfig.SkinsById["default"]
	end
	return skinDef
end

--------------------------------------------------
-- Client-facing methods
--------------------------------------------------

function SkinService.Client:PurchaseSkin(player: Player, skinId: string): (boolean, string?)
	return self.Server:PurchaseSkin(player, skinId)
end

function SkinService.Client:EquipSkin(player: Player, skinId: string): (boolean, string?)
	return self.Server:EquipSkin(player, skinId)
end

function SkinService.Client:GetOwnedSkins(player: Player): { string }
	return self.Server:GetOwnedSkins(player)
end

function SkinService.Client:GetEquippedSkin(player: Player): string
	return self.Server:GetEquippedSkin(player)
end

--------------------------------------------------
-- Knit lifecycle
--------------------------------------------------

function SkinService:KnitInit() end

function SkinService:KnitStart()
	PlayerDataService = Knit.GetService("PlayerDataService")
	CoinService = Knit.GetService("CoinService")
end

return SkinService
