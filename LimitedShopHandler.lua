--Discord connected with GitHub
-- have admin in the game group as proof 
--discord user = toji7y2
--roblox user = bunny7y16

local LimitedShopHandler = {}

local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RepAssets = ReplicatedStorage:WaitForChild("ReplicatedStorageAssets")
local Events = RepAssets:WaitForChild("Events")
local ModuleScripts = RepAssets:WaitForChild("ModuleScripts")

local Config = require(ModuleScripts:WaitForChild("LimitedShopConfig"))
local ToolConfig = require(ServerStorage.ServerAssets.ServerScripts.ToolConfig)
local BulldozerServer = require(game.ServerScriptService.Server.Misc.BulldozerServer)

local StockStore = DataStoreService:GetDataStore(Config.StockStoreName)
local ShowNotification = Events:WaitForChild("ShowNotification")

-- caching this so we're not spamming the datastore every time
local stockCache = {}

-- receipt only gives us the product id so need this reverse lookup built once
local productToOffer = {}

-- so config can just say "Workspace.Foo.Bar" instead of me hardcoding refs everywhere
local function getInstanceFromPath(path)
	local current = game

	for part in string.gmatch(path, "[^%.]+") do
		current = current:FindFirstChild(part)
		if not current then
			return nil
		end
	end

	return current
end

-- need this backwards too, receipt only gives us the product id not the offer
local function buildProductLookup()
	for offerId, offer in pairs(Config.Offers) do
		productToOffer[offer.ProductId] = offerId
	end
end

-- just centralizing the key string in one spot
local function getStockKey(offerId)
	return "Stock_" .. offerId
end

-- cache first, datastore if not, starting stock if even that fails lol
local function getStock(offerId)
	if stockCache[offerId] ~= nil then
		return stockCache[offerId]
	end

	local offer = Config.Offers[offerId]
	if not offer then return 0 end

	local success, value = pcall(function()
		return StockStore:GetAsync(getStockKey(offerId))
	end)

	if success and typeof(value) == "number" then
		stockCache[offerId] = value
	else
		stockCache[offerId] = offer.StartingStock
	end

	return stockCache[offerId]
end

local function setStock(offerId, amount)
	stockCache[offerId] = amount
	-- client reads this attribute for the stock text so gotta keep it synced
	ReplicatedStorage:SetAttribute("LimitedStock_" .. offerId, amount)
end

-- using UpdateAsync here so two people buying at the same time cant both grab the last one
-- get+set would race, this works off the datastore's actual current value instead
local function consumeStock(offerId)
	local offer = Config.Offers[offerId]
	if not offer then return false end

	local success, newValue = pcall(function()
		return StockStore:UpdateAsync(getStockKey(offerId), function(oldValue)
			local current = typeof(oldValue) == "number" and oldValue or offer.StartingStock
			if current <= 0 then
				return nil -- nil = abort, stays sold out
			end

			return current - 1
		end)
	end)

	if success and typeof(newValue) == "number" then
		setStock(offerId, newValue)
		return true
	end

	return false
end

-- just grabs whatever labels exist by name and updates them
local function updatePlatformText(platform, offerId)
	local offer = Config.Offers[offerId]
	if not offer then return end

	local stock = getStock(offerId)

	local function setTextIfFound(name, text)
		for _, descendant in ipairs(platform:GetDescendants()) do
			if descendant:IsA("TextLabel") and descendant.Name == name then
				descendant.Text = text
			end
		end
	end

	setTextIfFound("brainrot_name", offer.DisplayName)
	setTextIfFound("Stock", tostring(stock) .. " / " .. tostring(offer.StartingStock) .. " LEFT!")

	-- pulling price live instead of hardcoding it, prices can change on the website
	local priceText = "R$ ?"
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(offer.ProductId, Enum.InfoType.Product)
	end)

	if ok and info and info.PriceInRobux then
		priceText = "R$ " .. tostring(info.PriceInRobux)
	end

	setTextIfFound("Price", priceText)
end

-- clears old one first so restarting Start() doesnt just stack duplicates
local function clearOldDisplay(platform)
	local old = platform:FindFirstChild("LimitedDisplayModel")
	if old then
		old:Destroy()
	end
end

-- rigged stuff has motor6ds, plain models/parts dont, thats the whole check
local function hasMotor6D(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			return true
		end
	end

	return false
end

-- trying to find the part to move for rigged stuff (bulldozers etc)
-- kinda messy fallback chain but it works for now
local function getDisplayAnchor(instance)
	if not instance:IsA("Model") then return nil end

	local bull = instance:FindFirstChild("Bull")
	local bullPart = bull and bull:FindFirstChild("Bulldozer", true)

	if bullPart and bullPart:IsA("BasePart") then
		return bullPart
	end

	if hasMotor6D(instance) then
		-- part0 is basically the "driving" side of the joint so first match is our best guess at root
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("Motor6D") and descendant.Part0 and descendant.Part0:IsDescendantOf(instance) then
				return descendant.Part0
			end
		end

		local fakeRootPart = instance:FindFirstChild("FakeRootPart")
		if fakeRootPart and fakeRootPart:IsA("BasePart") then
			return fakeRootPart
		end

		local rootPart = instance:FindFirstChild("RootPart")
		if rootPart and rootPart:IsA("BasePart") then
			return rootPart
		end

		if instance.PrimaryPart then
			return instance.PrimaryPart
		end

		return instance:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

-- anchor everything except the one part we're moving, otherwise rigs fall apart
local function freezeDisplayModel(instance)
	local displayAnchor = getDisplayAnchor(instance)

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			-- no anchor part = not rigged, so just anchor the whole thing
			descendant.Anchored = displayAnchor == nil or descendant == displayAnchor
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			-- massless so the unanchored parts dont add weight to the one part holding them
			descendant.Massless = displayAnchor ~= nil and descendant ~= displayAnchor
		end
	end
end

-- plays idle anim if theres one under Anims, otherwise just skip it
local function playDisplayIdle(model)
	local animationController = model:FindFirstChildOfClass("AnimationController")
	if not animationController then return end

	local animator = animationController:FindFirstChildOfClass("Animator")
	if not animator then
		-- some models have the controller but no animator under it yet
		animator = Instance.new("Animator")
		animator.Parent = animationController
	end

	local anims = model:FindFirstChild("Anims")
	local idleAnimation = anims and anims:FindFirstChild("Idle")

	if not idleAnimation or not idleAnimation:IsA("Animation") then
		return
	end

	local track = animator:LoadAnimation(idleAnimation)
	track.Looped = true
	track:Play()
end

-- lil wobble effect just for the hacker block, purely cosmetic
local function playLuckyBlockDisplayMotion(model)
	local rootPart = model:FindFirstChild("FakeRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then return end

	local motorData = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Motor6D") and descendant.Part0 == rootPart and descendant.Part1 then
			table.insert(motorData, {
				Motor = descendant,
				C0 = descendant.C0,
				Phase = #motorData * 0.65, -- offset so parts dont all move the same at once
			})
		end
	end

	if #motorData == 0 then return end

	local startTime = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		-- model or root gone means bail, dont wanna leave a dead connection running forever
		if not model.Parent or not rootPart.Parent then
			connection:Disconnect()
			return
		end

		local time = os.clock() - startTime
		for _, data in ipairs(motorData) do
			if data.Motor.Parent then
				local bob = math.sin((time * 2.8) + data.Phase) * 0.08
				local tilt = math.sin((time * 2.2) + data.Phase) * 0.12
				local twist = math.cos((time * 2.4) + data.Phase) * 0.16

				-- always building off the original C0 so this doesnt drift over time
				data.Motor.C0 = data.C0 * CFrame.new(0, bob, 0) * CFrame.Angles(tilt, twist, -tilt * 0.5)
			end
		end
	end)
end

-- hover + spin for the pedestal display, works for models and single parts
local function playDisplayHover(instance)
	local anchorPart = instance:IsA("Model") and getDisplayAnchor(instance) or nil
	local basePivot

	if anchorPart then
		basePivot = anchorPart.CFrame
	elseif instance:IsA("Model") then
		basePivot = instance:GetPivot()
	elseif instance:IsA("BasePart") then
		basePivot = instance.CFrame
	else
		return
	end

	-- no anchor part means we gotta move every part ourselves relative to the pivot
	local partOffsets = nil
	if not anchorPart and instance:IsA("Model") then
		partOffsets = {}
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(partOffsets, {
					Part = descendant,
					Offset = basePivot:ToObjectSpace(descendant.CFrame),
				})
			end
		end
	end

	local basePosition = basePivot.Position
	-- stripping position leaves just rotation so we can spin without messing up orientation
	local baseRotation = basePivot - basePosition
	local hoverHeight = 0.35
	local hoverSpeed = 2.2
	local spinSpeed = math.rad(25)
	local startTime = os.clock()

	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not instance.Parent or (anchorPart and not anchorPart.Parent) then
			connection:Disconnect()
			return
		end

		local time = os.clock() - startTime
		local hover = math.sin(time * hoverSpeed) * hoverHeight
		local spin = time * spinSpeed
		-- order matters, move then spin then reapply rotation or itll spin wrong
		local targetPivot = CFrame.new(basePosition + Vector3.new(0, hover, 0)) * CFrame.Angles(0, spin, 0) * baseRotation

		if anchorPart then
			anchorPart.CFrame = targetPivot
		elseif partOffsets then
			for _, data in ipairs(partOffsets) do
				if data.Part.Parent then
					data.Part.CFrame = targetPivot * data.Offset
				end
			end
		elseif instance:IsA("BasePart") then
			instance.CFrame = targetPivot
		end
	end)
end

-- clones the reward onto the display point and lines it up using the bounding box
local function spawnDisplayModel(platform, offerId)
	local offer = Config.Offers[offerId]
	if not offer then return end

	local displayPoint = platform:FindFirstChild("DisplayPoint")
	if not displayPoint then return end

	local template = getInstanceFromPath(offer.DisplayModelPath)
	if not template then
		warn("[LimitedShop] Missing display model:", offer.DisplayModelPath)
		return
	end

	clearOldDisplay(platform)

	local clone = template:Clone()
	clone.Name = "LimitedDisplayModel"
	freezeDisplayModel(clone)
	clone.Parent = platform

	local floatOffset = 1.25

	if clone:IsA("Model") then
		local clonePivot = clone:GetPivot()
		-- keeping the model's own rotation, only moving position to the display point
		clone:PivotTo(displayPoint.CFrame * (clonePivot - clonePivot.Position))

		-- pivot isnt always at the bottom so nudge it to actually sit on the display point
		-- measuring the bounding box instead of trusting pivot since every asset's pivot is different
		local boundsCFrame, boundsSize = clone:GetBoundingBox()
		local boundsBottomY = boundsCFrame.Position.Y - (boundsSize.Y * 0.5)
		local targetBottomY = displayPoint.Position.Y + floatOffset
		local correction = Vector3.new(
			displayPoint.Position.X - boundsCFrame.Position.X,
			targetBottomY - boundsBottomY,
			displayPoint.Position.Z - boundsCFrame.Position.Z
		)

		clone:PivotTo(clone:GetPivot() + correction)
	elseif clone:IsA("BasePart") then
		clone.CFrame = displayPoint.CFrame
		clone.Position = Vector3.new(
			displayPoint.Position.X,
			displayPoint.Position.Y + floatOffset + (clone.Size.Y * 0.5),
			displayPoint.Position.Z
		)
	end

	playDisplayIdle(clone)

	-- only the hacker block gets this, its just a one off gimmick for that item
	if offerId == "HackerLuckyBlock" and clone:IsA("Model") then
		playLuckyBlockDisplayMotion(clone)
	end

	playDisplayHover(clone)
end

-- some platforms have the prompt buried in weird spots so just checking a few places
local function getPromptPart(platform)
	local direct = platform:FindFirstChild("PromptPart")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	local brainrot = platform:FindFirstChild("Brainrot")
	if brainrot then
		local nested = brainrot:FindFirstChild("PromptPart")
		if nested and nested:IsA("BasePart") then
			return nested
		end
	end

	local nested = platform:FindFirstChild("PromptPart", true)
	if nested and nested:IsA("BasePart") then
		return nested
	end

	-- worst case just grab any basepart lol
	return platform:FindFirstChildWhichIsA("BasePart", true)
end

local function setupPrompt(platform, offerId)
	local promptPart = getPromptPart(platform)
	if not promptPart then return end

	-- reuse if one already exists instead of making dupes on repeat runs
	local prompt = promptPart:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = promptPart
	end

	prompt.ActionText = "Buy"
	prompt.ObjectText = Config.Offers[offerId].DisplayName
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.Enabled = true

	prompt.Triggered:Connect(function(player)
		-- just a quick client side check for instant feedback, real check happens in ProcessReceipt
		if getStock(offerId) <= 0 then
			ShowNotification:FireClient(player, "This limited item is sold out!", "Error")
			return
		end

		MarketplaceService:PromptProductPurchase(player, Config.Offers[offerId].ProductId)
	end)
end

-- makes the actual tool and chucks it in the backpack
local function giveBrainrotTool(player, offer)
	local reward = getInstanceFromPath(offer.RewardPath)
	if not reward then
		warn("[LimitedShop] Missing reward:", offer.RewardPath)
		return false
	end

	-- waiting since backpack can be nil for a sec right after join/respawn
	local backpack = player:WaitForChild("Backpack", 5)
	if not backpack then return false end

	-- checking both attribute names, older reward templates used a different one
	local production = reward:GetAttribute("BaseProduction") or reward:GetAttribute("Production") or 1

	local tool = ToolConfig.CreateToolFromAttributes({
		Rarity = offer.Rarity or "God",
		ToolName = reward.Name,
		Production = production,
		Mutation = "None",
		Weather = "None",
		Level = 1,
	})

	if not tool then
		warn("[LimitedShop] Could not create tool for:", reward.Name)
		return false
	end

	-- tagging so other systems can tell this came from a limited drop
	tool:SetAttribute("Limited", true)
	tool.Parent = backpack
	return true
end

-- skin also needs to exist on the client side or it wont render right
local function giveBulldozerSkin(player, offer)
	local reward = getInstanceFromPath(offer.RewardPath)
	if not reward then
		warn("[LimitedShop] Missing bulldozer reward:", offer.RewardPath)
		return false
	end

	local replicatedBulldozers = ReplicatedStorage
		:WaitForChild("ReplicatedStorageAssets")
		:WaitForChild("Misc")
		:WaitForChild("Bulldozers")

	-- failing loud here so we dont grant a skin that'll never actually show up for them
	if not replicatedBulldozers:FindFirstChild(reward.Name) then
		warn("[LimitedShop] Bulldozer skin must also exist in ReplicatedStorageAssets.Misc.Bulldozers:", reward.Name)
		return false
	end

	BulldozerServer.GrantRobuxBulldozer(player, reward.Name)
	return true
end

-- just picks the right reward function depending on offer type
local function giveReward(player, offer)
	if offer.RewardType == "Brainrot" or offer.RewardType == "LuckyBlock" then
		return giveBrainrotTool(player, offer)
	end

	if offer.RewardType == "BulldozerSkin" then
		return giveBulldozerSkin(player, offer)
	end

	warn("[LimitedShop] Unknown reward type:", offer.RewardType)
	return false
end

-- standard receipt callback, roblox fires this for every dev product buy
function LimitedShopHandler.ProcessReceipt(receiptInfo)
	local offerId = productToOffer[receiptInfo.ProductId]
	if not offerId then
		-- nil means not our product, other systems might handle their own receipts too
		return nil
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- player probably left mid purchase, let roblox retry it later
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local offer = Config.Offers[offerId]
	if not offer then
		-- config got removed after someone already bought it, retry instead of losing the sale
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not consumeStock(offerId) then
		-- sold out right as they bought it, basically a refund situation
		-- still marking as granted since robux already got charged through roblox
		ShowNotification:FireClient(player, "This limited item is sold out!", "Error")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if not giveReward(player, offer) then
		-- retry later if something broke handing out the item, dont want them paying for nothing
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	ShowNotification:FireClient(player, "Purchased " .. offer.DisplayName .. "!", "Success")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- runs on server start, sets up stock, displays, prompts, all of it
function LimitedShopHandler.Start()
	buildProductLookup()

	local limitedShop = workspace:WaitForChild("LimitedShop")

	for offerId in pairs(Config.Offers) do
		-- forcing the get->set roundtrip so the replicated attribute is set immediately on startup
		setStock(offerId, getStock(offerId))

		for _, platform in ipairs(limitedShop:GetChildren()) do
			-- matching by attribute instead of name so platforms can be rearranged freely in studio
			if platform:IsA("Model") and platform:GetAttribute("OfferId") == offerId then
				spawnDisplayModel(platform, offerId)
				updatePlatformText(platform, offerId)
				setupPrompt(platform, offerId)
			end
		end
	end
end

return LimitedShopHandler
