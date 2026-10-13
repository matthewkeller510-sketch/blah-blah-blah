--!strict
-- Earned-coin trade and developer-product receipts (section 21).
-- Quartermaster: a PLACEHOLDER counter in the depot equipment room standing in for N03 Ines Vidal.
-- Developer products: navigation packs only. No product IDs are configured in this repository; the store stays
-- disabled until an authorized test/live configuration sets them. Prices are read from the platform, never
-- hard-coded. Receipts are deduplicated and granted only after a durable save.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDefs = require(Shared.Data.ItemDefs)
local WorldDefs = require(Shared.Data.WorldDefs)
local Inventory = require(Shared.Logic.Inventory)
local Commerce = require(Shared.Logic.Commerce)

local EconomyService = {}
local services: any

-- Coin prices (PROPOSED, see docs/ECONOMY.md). Everything here is also obtainable by scavenging.
local SHOP = {
	{ itemId = "power.cell", price = 15 },
	{ itemId = "med.cloth_dressing", price = 6 },
	{ itemId = "med.bandage", price = 14 },
	{ itemId = "nav.chalk", price = 2 },
	{ itemId = "nav.sign", price = 6 },
	{ itemId = "nav.rope", price = 4 },
	{ itemId = "light.expedition_flashlight", price = 120 },
	{ itemId = "tool.stun_device", price = 90 },
}

-- Developer products: productId -> contents. EMPTY on purpose (do not create live products from this brief).
local PRODUCTS: { [number]: { name: string, contents: { [string]: number } } } = {
	-- [1234567890] = { name = "Chalk & Signs Pack", contents = { ["nav.chalk"] = 20, ["nav.sign"] = 4 } },
}

local TRADE_RANGE = 14

local function nearQuartermaster(player: Player): boolean
	local p = services.PlayerService.position(player)
	local er = WorldDefs.Depot.equipmentRoom
	return p ~= nil and (p - Vector3.new(er.pos.x, er.pos.y + 2, er.pos.z)).Magnitude < TRADE_RANGE
end

function EconomyService.pushShop(player: Player)
	local s = services.PlayerService.get(player)
	if not s then
		return
	end
	local buy = {}
	for _, e in SHOP do
		local d = ItemDefs.require(e.itemId)
		table.insert(buy, { itemId = e.itemId, name = d.displayName, price = e.price, have = Inventory.count(s.profile.inventory, e.itemId), limit = d.stackLimit })
	end
	local sell = {}
	for id, entry in s.profile.inventory do
		local d = ItemDefs.get(id)
		if d and (d.category == "treasure") and not d.unique then
			table.insert(sell, { itemId = id, name = d.displayName, value = d.sellValue, have = entry.loadout + entry.expedition })
		end
	end
	local products = {}
	for pid, pr in PRODUCTS do
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(pid, Enum.InfoType.Product)
		end)
		table.insert(products, { productId = pid, name = pr.name, contents = pr.contents, price = ok and info.PriceInRobux or nil })
	end
	services.PlayerService.send(player, "shop", { coins = s.profile.coins, buy = buy, sell = sell, products = products, storeConfigured = next(PRODUCTS) ~= nil })
end

function EconomyService.buy(player: Player, itemId: string)
	local s = services.PlayerService.get(player)
	if not s or not nearQuartermaster(player) then
		return
	end
	local entry
	for _, e in SHOP do
		if e.itemId == itemId then
			entry = e
		end
	end
	if not entry then
		return
	end
	if s.profile.coins < entry.price then
		services.PlayerService.notify(player, "Not enough coins. Rescues and treasures earn coins.", "warn")
		return
	end
	-- Bought at the surface depot, so it is loadout equipment.
	if Inventory.add(s.profile.inventory, ItemDefs.get, itemId, 1, "loadout") ~= 1 then
		services.PlayerService.notify(player, "You cannot carry more of that.", "warn")
		return
	end
	s.profile.coins -= entry.price
	if itemId == "tool.stun_device" then
		s.profile.toolCharges[itemId] = (ItemDefs.require(itemId)).stunCharges or 3
	end
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	EconomyService.pushShop(player)
end

function EconomyService.sell(player: Player, itemId: string)
	local s = services.PlayerService.get(player)
	local d = ItemDefs.get(itemId)
	if not s or not d or d.category ~= "treasure" or d.unique or not nearQuartermaster(player) then
		return
	end
	if not Inventory.remove(s.profile.inventory, itemId, 1) then
		return
	end
	s.profile.coins += d.sellValue
	services.SaveService.markDirty(player)
	services.PlayerService.pushInventory(player)
	EconomyService.pushShop(player)
end

function EconomyService.promptProduct(player: Player, productId: number)
	if PRODUCTS[productId] then
		MarketplaceService:PromptProductPurchase(player, productId)
	end
end

local function processReceipt(info): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	local s = player and services.PlayerService.get(player)
	local product = PRODUCTS[info.ProductId]
	if not player or not s or not product then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local pid = tostring(info.PurchaseId)
	if Commerce.alreadyGranted(s.profile.receipts, pid) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	-- Identical items to earned ones; overflow goes to escrow so nothing paid for is lost.
	local leftover = Inventory.addContents(s.profile.inventory, ItemDefs.get, product.contents, "loadout")
	for id, n in leftover do
		s.profile.escrow[id] = (s.profile.escrow[id] or 0) + n
	end
	Commerce.recordGrant(s.profile.receipts, pid)
	services.SaveService.markDirty(player)
	if not services.SaveService.commit(player) then
		-- Roll back the in-memory grant; Roblox will retry the receipt later.
		s.profile.receipts[pid] = nil
		for id, n in product.contents do
			local fromInv = n - (leftover[id] or 0)
			Inventory.remove(s.profile.inventory, id, fromInv)
			if leftover[id] then
				s.profile.escrow[id] -= leftover[id]
				if s.profile.escrow[id] <= 0 then
					s.profile.escrow[id] = nil
				end
			end
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	services.PlayerService.pushInventory(player)
	services.PlayerService.notify(player, "Purchase delivered: " .. product.name .. ".", "info")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function EconomyService.init(s)
	services = s
end

function EconomyService.start()
	MarketplaceService.ProcessReceipt = processReceipt
	local room = services.WorldBuilder.folder("R00"):FindFirstChild("EquipmentRoom")
	local shelf = room and room:FindFirstChild("Shelf")
	if shelf then
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Trade"
		pp.ObjectText = "Quartermaster (placeholder)"
		pp.MaxActivationDistance = 10
		pp.RequiresLineOfSight = false
		pp.Parent = shelf
		pp.Triggered:Connect(EconomyService.pushShop)
	end
end

return EconomyService
