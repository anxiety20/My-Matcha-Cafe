--[[
    My Matcha Cafe — Auto Harvest / Prepare / Serve / Rewards (WindUI menu)
    =========================================================================
    Version 1.0.0

    Load it with:
        loadstring(game:HttpGet("<raw url of this file>"))()

    What it does:
      1. Cleans up leftover WindUI ScreenGuis, then loads WindUI.
      2. Harvest tab : picks tea leaves automatically.
      3. Kitchen tab : cooks at your PreparationStation automatically.
      4. Serve tab   : takes the drink from your backpack and serves it.
      5. Rewards tab : claims daily, playtime and group rewards.
      6. Config tab  : saves/loads the settings (MatchaCafe/config.json).

    Everything starts switched off, so nothing moves until you turn it on.
    The menu key is rebindable in the Harvest tab.

    Remotes used (the same ones the game itself calls):
        HarvestShootRequest:FireServer(bush, nodeName)
        PreparationRequest:FireServer("Start"|"Repeat"|"Cancel", ...)
        DailyRewardRequest / PlaytimeRewardRequest / GroupRewardRequest
        ServePrompt:fireproximityprompt()   (after equipping the drink)

    Needs an executor with loadstring + HttpGet (+ fireproximityprompt for the
    Serve tab, and writefile/readfile for the saved config).

    Uses WindUI by Footagesus (https://github.com/Footagesus/WindUI).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Remove leftover WindUI ScreenGuis from a previous run
-- (live-reload leaves the old window with Parent = nil)
--------------------------------------------------------------------------------

local function cleanupOldUI()
    local roots = { game:GetService("CoreGui"), player:FindFirstChild("PlayerGui") }

    local okHui, hui = pcall(gethui)
    if okHui and hui then table.insert(roots, hui) end

    local okNil, nils = pcall(getnilinstances)
    if okNil and nils then
        for _, inst in ipairs(nils) do
            if inst:IsA("ScreenGui") and inst.Name:match("^WindUI") then
                inst:Destroy()
            end
        end
    end

    for _, root in ipairs(roots) do
        if root then
            for _, inst in ipairs(root:GetChildren()) do
                if inst:IsA("ScreenGui") and inst.Name:match("^WindUI") then
                    inst:Destroy()
                end
            end
        end
    end
end

cleanupOldUI()

local VERSION = "1.0.0"

local WindUI
do
    local ok, result = pcall(function()
        return loadstring(game:HttpGet(
            "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
    end)

    if not ok or type(result) ~= "table" then
        error("[Matcha] WindUI could not be loaded - check the connection to GitHub "
            .. "and that the executor allows HttpGet. (" .. tostring(result) .. ")", 0)
    end

    WindUI = result
end

if type(fireproximityprompt) ~= "function" then
    print("[Matcha] fireproximityprompt is missing here: the Serve tab will do nothing.")
end

--------------------------------------------------------------------------------
-- Game references
--------------------------------------------------------------------------------

local MatchaPrototype = ReplicatedStorage:WaitForChild("MatchaPrototype")
local Config = MatchaPrototype:WaitForChild("Config")
local ProductCatalog = require(Config:WaitForChild("ProductCatalog"))
local StationConfig = require(Config:WaitForChild("ProductionStationConfig"))

local harvestRequest = MatchaPrototype:WaitForChild("HarvestShootRequest")
local prepRequest = MatchaPrototype:WaitForChild("PreparationRequest")

local MatchaState = player:WaitForChild("MatchaState")
local TeaLeaves = MatchaState:WaitForChild("TeaLeaves")
local Finished = MatchaState:WaitForChild("FinishedProducts")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

-- Everything starts switched off so running the script does not touch the
-- character until you turn something on (or a saved config loads).
local CONFIG = {
    toggleKey = Enum.KeyCode.K,
    autoLoad = true,          -- load the saved config when the script starts

    harvest = {
        on = false,
        pickDelay = 0.25,     -- seconds between picks
        maxDistance = 10,     -- max distance to a node before teleporting (server limit 15)
        autoTeleport = true,
    },
    prepare = {
        on = false,
        recipe = "Auto",      -- "Auto" = follow customer orders
        delay = 0.5,          -- pause after a finished cup
        autoTeleport = true,
    },
    serve = {
        on = false,
        delay = 0.8,
        autoTeleport = true,
    },
    rewards = {
        on = false,
        delay = 30,           -- seconds between reward checks
    },
}

local stats = {
    picks = 0,
    cups = 0,
    sales = 0,
    cashStart = (function()
        local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
        return cash and cash.Value or 0
    end)(),
}

-- Count real sales only (shelf + manual), not just prompt attempts.
MatchaPrototype.ActionFeedback.OnClientEvent:Connect(function(payload)
    if type(payload) == "table" and payload.Code == "Sold" then
        stats.sales = stats.sales + 1
    end
end)

--------------------------------------------------------------------------------
-- Saved config: <executor workspace>/MatchaCafe/config.json
--------------------------------------------------------------------------------

local CONFIG_FILE = "MatchaCafe/config.json"
local HttpService = game:GetService("HttpService")

-- File functions live in the executor env, which is the same table live-reload
-- shares between runs. Look them up there and survive executors that lack them.
local function fileFunction(name)
    local ok, fn = pcall(function() return getgenv()[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

local writeFile = fileFunction("writefile")
local readFile = fileFunction("readfile")
local isFile = fileFunction("isfile")
local makeFolder = fileFunction("makefolder")
local deleteFile = fileFunction("delfile")

local function snapshot()
    return {
        version = 1,
        toggleKey = CONFIG.toggleKey.Name,
        autoLoad = CONFIG.autoLoad,
        harvest = {
            on = CONFIG.harvest.on,
            pickDelay = CONFIG.harvest.pickDelay,
            maxDistance = CONFIG.harvest.maxDistance,
            autoTeleport = CONFIG.harvest.autoTeleport,
        },
        prepare = {
            on = CONFIG.prepare.on,
            recipe = CONFIG.prepare.recipe,
            delay = CONFIG.prepare.delay,
            autoTeleport = CONFIG.prepare.autoTeleport,
        },
        serve = {
            on = CONFIG.serve.on,
            delay = CONFIG.serve.delay,
            autoTeleport = CONFIG.serve.autoTeleport,
        },
        rewards = {
            on = CONFIG.rewards.on,
            delay = CONFIG.rewards.delay,
        },
    }
end

local function saveConfig()
    if not writeFile then return "Saving files is not supported by this executor" end

    local ok, err = pcall(function()
        if makeFolder then pcall(makeFolder, "MatchaCafe") end
        writeFile(CONFIG_FILE, HttpService:JSONEncode(snapshot()))
    end)

    if not ok then return "Save failed: " .. tostring(err) end
    return "Saved to " .. CONFIG_FILE
end

local function readSavedConfig()
    if not readFile or not isFile then return nil end

    local okExists, exists = pcall(isFile, CONFIG_FILE)
    if not okExists or not exists then return nil end

    local okRead, content = pcall(readFile, CONFIG_FILE)
    if not okRead or type(content) ~= "string" then return nil end

    local okDecode, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not okDecode or type(data) ~= "table" then return nil end

    return data
end

local function deleteSavedConfig()
    if not deleteFile then return "Deleting files is not supported by this executor" end

    local ok, err = pcall(deleteFile, CONFIG_FILE)
    if not ok then return "Delete failed: " .. tostring(err) end
    return "Saved config deleted"
end

--------------------------------------------------------------------------------
-- Rewards: daily, playtime and the group gift
--
--   DailyRewardRequest:FireServer("Claim")
--   PlaytimeRewardRequest:FireServer("ClaimAll")
--   GroupRewardRequest:FireServer("Claim")
--
-- The server answers daily and playtime on DailyRewardResult /
-- PlaytimeRewardResult with { Success, Code }.
--------------------------------------------------------------------------------

local DailyRewardResult = MatchaPrototype:WaitForChild("DailyRewardResult")
local PlaytimeRewardResult = MatchaPrototype:WaitForChild("PlaytimeRewardResult")
local dailyRewardRequest = MatchaPrototype:WaitForChild("DailyRewardRequest")
local playtimeRewardRequest = MatchaPrototype:WaitForChild("PlaytimeRewardRequest")
local groupRewardRequest = MatchaPrototype:WaitForChild("GroupRewardRequest")

local rewards = {
    message = "Idle.",
    dailyDay = nil,             -- day id we already asked for
    playtimeSeconds = nil,      -- playtime value we already asked for
    groupTries = 0,
}

local rewardStatusHandle = nil

local function setRewardStatus(text)
    rewards.message = text
    if rewardStatusHandle and rewardStatusHandle.SetDesc then
        pcall(function() rewardStatusHandle:SetDesc(text) end)
    end
end

local function rewardText(kind, payload)
    if payload.Success then return kind .. " reward claimed" end

    local code = tostring(payload.Code)
    if code == "AlreadyClaimed" then return kind .. " already claimed" end
    if code == "NotReady" then return "No " .. kind:lower() .. " reward ready" end
    return kind .. ": " .. code
end

DailyRewardResult.OnClientEvent:Connect(function(payload)
    if type(payload) ~= "table" then return end
    if not payload.Success and tostring(payload.Code) ~= "AlreadyClaimed" then
        rewards.dailyDay = nil  -- let the next check try again
    end
    setRewardStatus(rewardText("Daily", payload))
end)

PlaytimeRewardResult.OnClientEvent:Connect(function(payload)
    if type(payload) ~= "table" then return end
    if payload.Success then
        setRewardStatus("Playtime reward claimed")
    else
        setRewardStatus(rewardText("Playtime", payload))
    end
end)

local function claimRewards()
    local day = tonumber(player:GetAttribute("PlaytimeDayId"))
    local claimedDay = tonumber(player:GetAttribute("DailyLastClaimUtcDay"))

    -- Daily: the attribute holds today's day id once it has been claimed.
    if day and claimedDay ~= day and rewards.dailyDay ~= day then
        rewards.dailyDay = day
        dailyRewardRequest:FireServer("Claim")
    end

    -- Playtime: the server moves PlaytimeDaySeconds forward while you play,
    -- so only ask again when it changed (ClaimAll claims every unlocked tier).
    local seconds = tonumber(player:GetAttribute("PlaytimeDaySeconds"))

    if seconds and seconds ~= rewards.playtimeSeconds then
        rewards.playtimeSeconds = seconds
        playtimeRewardRequest:FireServer("ClaimAll")
    end

    -- Group gift: flips GroupRewardClaimed to true once claimed. Try a few
    -- times only, so a player without the group does not spam the server.
    if player:GetAttribute("GroupRewardClaimed") ~= true and rewards.groupTries < 3 then
        rewards.groupTries = rewards.groupTries + 1
        groupRewardRequest:FireServer("Claim")
    end
end

--------------------------------------------------------------------------------
-- Catalog: product <-> station <-> display name
--------------------------------------------------------------------------------

local recipeStation = {}
local displayToProduct = {}
local recipeList = {}

do
    local seen = {}
    local function addList(list)
        if type(list) ~= "table" then return end
        for _, productId in ipairs(list) do
            if not seen[productId] then
                seen[productId] = true
                recipeList[#recipeList + 1] = productId
            end
        end
    end

    -- GetPreparable includes seasonal recipes (e.g. Pumpkin Spice);
    -- GetRecipesForStation only returns the ones listed for that station.
    pcall(function() addList(ProductCatalog.GetPreparable("MatchaPrep")) end)

    for stationId in pairs(StationConfig) do
        pcall(function()
            addList(ProductCatalog.GetRecipesForStation(stationId, 99, true, function() return true end))
        end)
        pcall(function()
            addList(ProductCatalog.GetRecipesForStation(stationId, 99))
        end)
    end

    for _, productId in ipairs(recipeList) do
        local okGet, product = pcall(function() return ProductCatalog.Get(productId) end)
        if okGet and type(product) == "table" then
            recipeStation[productId] = product.ProductionStation
            if product.DisplayName then
                displayToProduct[product.DisplayName] = productId
            end
        end
    end

    table.sort(recipeList)
end

local function displayName(productId)
    local ok, product = pcall(function() return ProductCatalog.Get(productId) end)
    if ok and type(product) == "table" and product.DisplayName then
        return product.DisplayName
    end
    return productId
end

local function stockOf(productId)
    local value = Finished:FindFirstChild(productId)
    return value and value.Value or 0
end

local function ownsBuild(buildId)
    if not buildId then return true end
    local builds = player:FindFirstChild("CafeBuilds")
    local value = builds and builds:FindFirstChild(buildId)
    return value == nil or value.Value == true
end

local function ingredientCount(name)
    local folder = MatchaState:FindFirstChild("Ingredients")
    local value = folder and folder:FindFirstChild(name)
    return value and value.Value or 0
end

local function canPrepare(productId)
    local product = select(2, pcall(function() return ProductCatalog.Get(productId) end))
    if type(product) ~= "table" then return false end
    if not ownsBuild(product.RequiredCafeBuild) then return false end

    local okUnlocked, unlocked = pcall(function()
        return ProductCatalog.IsUnlocked(productId, MatchaState.MatchaRank.Value, function() return true end)
    end)
    if okUnlocked and unlocked == false then return false end

    local okCost, cost = pcall(function() return ProductCatalog.GetCost(productId) or 0 end)
    if okCost and cost > TeaLeaves.Value then return false end

    -- Extra ingredients (strawberry, brown sugar, ...) must be in stock too
    local okMissing, missing = pcall(function()
        return ProductCatalog.GetMissingIngredients(productId, ingredientCount)
    end)
    if okMissing and type(missing) == "table" and #missing > 0 then return false end

    return recipeStation[productId] ~= nil
end

--------------------------------------------------------------------------------
-- World helpers
--------------------------------------------------------------------------------

local function getRoot()
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getMyPlot()
    local plotId = player:GetAttribute("PlotId")
    local plots = workspace:FindFirstChild("Plots")
    if not plotId or not plots then return nil end
    return plots:FindFirstChild("Plot" .. plotId)
end

-- Station objects carry a ProductionStation attribute
local function findStation(stationId)
    local plotId = player:GetAttribute("PlotId")
    local roots = { getMyPlot() }

    local builds = workspace:FindFirstChild("LocalCafeBuilds")
    if builds and plotId then
        table.insert(roots, builds:FindFirstChild("Plot" .. plotId))
    end

    for _, root in ipairs(roots) do
        if root then
            for _, inst in ipairs(root:GetDescendants()) do
                if inst:GetAttribute("ProductionStation") == stationId
                    and inst:FindFirstChild("PreparePrompt", true) then
                    return inst
                end
            end
        end
    end
    return nil
end

local function positionOf(inst)
    local ok, pivot = pcall(function() return inst:GetPivot().Position end)
    if ok then return pivot end
    local okPos, pos = pcall(function() return inst.Position end)
    return okPos and pos or nil
end

local function moveNear(target)
    local root = getRoot()
    if not root or not target then return end
    root.CFrame = CFrame.new(target + Vector3.new(0, 3, 4), target)
    task.wait(0.35)
end

local function distanceTo(inst)
    local root = getRoot()
    local pos = inst and positionOf(inst)
    if not root or not pos then return math.huge end
    return (root.Position - pos).Magnitude
end

-- Every enabled ServePrompt means a customer is waiting for that drink
local function enabledServePrompts()
    local plot = getMyPlot()
    local list = {}
    if not plot then return list end

    for _, inst in ipairs(plot:GetDescendants()) do
        if inst:IsA("ProximityPrompt") and inst.Name == "ServePrompt" and inst.Enabled then
            local name = string.match(inst.ActionText or "", "^Serve (.+)$")
            local productId = name and displayToProduct[name]
            if productId then
                list[#list + 1] = { prompt = inst, product = productId }
            end
        end
    end
    return list
end

--------------------------------------------------------------------------------
-- Inventory: finished drinks live as Tools with a ProductId attribute
--------------------------------------------------------------------------------

local function findProductTool(productId)
    local containers = { player.Character, player:FindFirstChild("Backpack") }

    for _, container in ipairs(containers) do
        if container then
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") and item:GetAttribute("ProductId") == productId then
                    local count = item:GetAttribute("Count")
                    if type(count) ~= "number" or count > 0 then
                        return item
                    end
                end
            end
        end
    end
    return nil
end

-- Equip the drink so the server sees it in our hands, then the seat prompt
-- can be fired. Returns true when the drink is equipped.
local function equipProduct(productId)
    local held = MatchaState:FindFirstChild("HeldProductId")
    if held and held.Value == productId then
        return true
    end

    local tool = findProductTool(productId)
    if not tool then return false end

    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end

    pcall(function() humanoid:EquipTool(tool) end)

    local deadline = os.clock() + 1.5
    while os.clock() < deadline do
        if (held and held.Value == productId) or tool.Parent == char then
            return true
        end
        task.wait(0.1)
    end
    return false
end

--------------------------------------------------------------------------------
-- Harvest helpers
--------------------------------------------------------------------------------

local function getBushes(plot)
    local list = {}

    local teaBush = plot:FindFirstChild("TeaBush")
    if teaBush then table.insert(list, teaBush) end

    local garden = plot:FindFirstChild("PersonalGardenBushes")
    if garden then
        for _, bush in ipairs(garden:GetChildren()) do
            if bush:GetAttribute("OwnerUserId") == player.UserId then
                table.insert(list, bush)
            end
        end
    end

    return list
end

local function getReadyNodes(bush)
    local ready = {}
    local folder = bush:FindFirstChild("HarvestNodes")
    if not folder then return ready end

    for _, node in ipairs(folder:GetChildren()) do
        if node:GetAttribute("State") == "Ready" then
            table.insert(ready, node)
        end
    end
    return ready
end

local function findBushWithReady()
    local plot = getMyPlot()
    if not plot then return nil end
    local bushes = getBushes(plot)
    for _, bush in ipairs(bushes) do
        if #getReadyNodes(bush) > 0 then return bush end
    end
    return bushes[1]
end

--------------------------------------------------------------------------------
-- Prepare: session tracking
--------------------------------------------------------------------------------

-- Latest session per station, from the server. Payload shape:
-- { Id, ProductId, StationId, State, StartedAt, At, RepeatUntil, Speed }
local sessions = {}

MatchaPrototype.PreparationState.OnClientEvent:Connect(function(payload)
    if type(payload) == "table" and payload.StationId then
        if payload.State == "Finished" then
            sessions[payload.StationId] = nil
        else
            sessions[payload.StationId] = payload
        end
    end
end)

--------------------------------------------------------------------------------
-- Recipe choice
--------------------------------------------------------------------------------

local lastRecipe = nil

local function defaultRecipe()
    if lastRecipe and canPrepare(lastRecipe) then
        return lastRecipe
    end
    for _, productId in ipairs(recipeList) do
        if canPrepare(productId) then
            return productId
        end
    end
    return nil
end

local function chooseRecipe()
    if CONFIG.prepare.recipe ~= "Auto" then
        local fixed = CONFIG.prepare.recipe
        return canPrepare(fixed) and fixed or nil
    end

    -- Auto: cook what a waiting customer wants and we do not carry yet
    for _, order in ipairs(enabledServePrompts()) do
        if canPrepare(order.product) and not findProductTool(order.product) then
            return order.product
        end
    end

    -- Nothing to chase: keep cooking the same recipe (no stock cap)
    return defaultRecipe()
end

--------------------------------------------------------------------------------
-- Prepare: one cup
--------------------------------------------------------------------------------

-- Only one moving task at a time. Harvest, kitchen and serving all pull the
-- character around; running them together makes them fight.
local activity = nil

local function prepareStep()
    local productId = chooseRecipe()
    if not productId then return "No recipe available right now" end

    local stationId = recipeStation[productId]
    local station = findStation(stationId)
    if not station then return "Station " .. tostring(stationId) .. " not found on your plot" end

    -- Some stations (e.g. LatteStation) never write the PreparationState
    -- attribute, so fall back to the PreparationState events.
    local function currentState()
        local attr = station:GetAttribute("PreparationState")
        if attr ~= nil then
            return attr
        end
        local session = sessions[stationId]
        if session and session.State then
            return session.State == "AwaitingRepeat" and "AwaitingRepeat" or "Brewing"
        end
        return "Idle"
    end

    local state = currentState()
    local owner = station:GetAttribute("PreparationOwner")

    if owner and owner ~= 0 and owner ~= player.UserId then
        return "Station is used by another player"
    end

    lastRecipe = productId

    -- Same recipe already open: "Repeat" makes the next cup straight away
    -- (about 2.3s per cup) instead of closing and reopening a session.
    if state == "AwaitingRepeat" then
        local session = sessions[stationId]
        if session and session.Id and session.ProductId == productId then
            local oldId = session.Id
            prepRequest:FireServer("Repeat", oldId, productId)

            local deadline = os.clock() + 15
            while os.clock() < deadline do
                local now = sessions[stationId]
                if now and now.Id ~= oldId and now.State == "AwaitingRepeat" then
                    stats.cups = stats.cups + 1
                    return string.format("%s ready (stock %d)", displayName(productId), stockOf(productId))
                end
                task.wait(0.2)
            end
            return "Repeat got no response"
        end
    end

    -- Different recipe still open: close the session first, otherwise the
    -- next Start is answered with PreparationBusy.
    if state == "AwaitingRepeat" then
        local session = sessions[stationId]
        if session and session.Id then
            prepRequest:FireServer("Cancel", session.Id)

            local deadline = os.clock() + 4
            while os.clock() < deadline do
                if currentState() == "Idle" then break end
                task.wait(0.15)
            end
        else
            -- Session created before this script ran, so we do not know its
            -- Id. The server closes it on its own after RepeatUntil (30s).
            local deadline = os.clock() + 32
            while os.clock() < deadline do
                if currentState() == "Idle" then break end
                task.wait(0.3)
            end
            if currentState() ~= "Idle" then
                return "Old session is still open"
            end
        end
    end

    state = currentState()
    if state ~= "Idle" then
        return "Station is still " .. state
    end

    if CONFIG.prepare.autoTeleport and distanceTo(station) > 8 then
        moveNear(positionOf(station))
    end

    local stockBefore = stockOf(productId)
    local started = os.clock()
    prepRequest:FireServer("Start", productId, stationId)

    -- The server answers through PreparationState almost immediately. If
    -- nothing arrives in 3 seconds the request was rejected (out of reach
    -- or busy) - the server does not send feedback for those.
    while os.clock() - started < 3 do
        if sessions[stationId] or stockOf(productId) > stockBefore then break end
        task.wait(0.1)
    end
    if not sessions[stationId] and stockOf(productId) == stockBefore then
        return "Station did not respond (out of reach or busy)"
    end

    local deadline = os.clock() + 15
    while os.clock() < deadline do
        if currentState() == "AwaitingRepeat" or stockOf(productId) > stockBefore then
            stats.cups = stats.cups + 1
            return string.format("%s ready (stock %d)", displayName(productId), stockOf(productId))
        end
        task.wait(0.2)
    end
    return "Station did not respond"
end

local function prepareOnce()
    if activity == "prepare" then return "Already cooking" end

    activity = "prepare"
    local ok, result = pcall(prepareStep)
    activity = nil

    if not ok then
        return "Error: " .. tostring(result)
    end
    return result
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

local Window = WindUI:CreateWindow({
    Title = "Matcha Cafe",
    Author = "auto farm",
    Icon = "leaf",
    Size = UDim2.fromOffset(480, 470),
    Theme = "Dark",
    Acrylic = false,               -- no blur, keeps FPS stable
    ToggleKey = CONFIG.toggleKey,
})

-- WindUI fires every element Callback once at creation, often with an
-- internal default. This flag holds callbacks until the menu is built.
local callbacksLive = false

-- Element handles, so a loaded config can move the menu controls too.
local ui = {}

-- Apply a config table (from disk or the Config tab) to CONFIG and the menu.
local function applyConfig(data)
    if type(data) ~= "table" then return end

    local function num(value, fallback, min, max)
        if type(value) ~= "number" then return fallback end
        return math.clamp(value, min, max)
    end

    local harvest = type(data.harvest) == "table" and data.harvest or {}
    local prepare = type(data.prepare) == "table" and data.prepare or {}
    local serve = type(data.serve) == "table" and data.serve or {}
    local rewardCfg = type(data.rewards) == "table" and data.rewards or {}

    CONFIG.autoLoad = data.autoLoad ~= false

    CONFIG.harvest.on = harvest.on == true
    CONFIG.harvest.pickDelay = num(harvest.pickDelay, CONFIG.harvest.pickDelay, 0.15, 1)
    CONFIG.harvest.maxDistance = num(harvest.maxDistance, CONFIG.harvest.maxDistance, 5, 15)
    CONFIG.harvest.autoTeleport = harvest.autoTeleport ~= false

    CONFIG.prepare.on = prepare.on == true
    CONFIG.prepare.delay = num(prepare.delay, CONFIG.prepare.delay, 0, 3)
    CONFIG.prepare.autoTeleport = prepare.autoTeleport ~= false
    if type(prepare.recipe) == "string"
        and table.find(ui.recipeOptions or {}, prepare.recipe) then
        CONFIG.prepare.recipe = prepare.recipe
    end

    CONFIG.serve.on = serve.on == true
    CONFIG.serve.delay = num(serve.delay, CONFIG.serve.delay, 0.3, 3)
    CONFIG.serve.autoTeleport = serve.autoTeleport ~= false

    CONFIG.rewards.on = rewardCfg.on == true
    CONFIG.rewards.delay = num(rewardCfg.delay, CONFIG.rewards.delay, 10, 120)

    -- Move the controls so the menu shows the loaded values.
    local function set(handle, ...)
        if handle then
            pcall(function(...) handle:Set(...) end, ...)
        end
    end

    set(ui.harvestOn, CONFIG.harvest.on)
    set(ui.harvestDistance, CONFIG.harvest.maxDistance)
    set(ui.harvestDelay, CONFIG.harvest.pickDelay)
    set(ui.harvestTeleport, CONFIG.harvest.autoTeleport)

    set(ui.prepareOn, CONFIG.prepare.on)
    if ui.recipe then
        pcall(function() ui.recipe:Select(CONFIG.prepare.recipe) end)
    end
    set(ui.prepareDelay, CONFIG.prepare.delay)
    set(ui.prepareTeleport, CONFIG.prepare.autoTeleport)

    set(ui.serveOn, CONFIG.serve.on)
    set(ui.serveDelay, CONFIG.serve.delay)
    set(ui.serveTeleport, CONFIG.serve.autoTeleport)

    set(ui.rewardsOn, CONFIG.rewards.on)
    set(ui.rewardsDelay, CONFIG.rewards.delay)

    set(ui.autoLoad, CONFIG.autoLoad)

    if type(data.toggleKey) == "string" then
        local okKey, keyCode = pcall(function() return Enum.KeyCode[data.toggleKey] end)
        if okKey and keyCode then
            CONFIG.toggleKey = keyCode
            pcall(function() Window:SetToggleKey(keyCode) end)
            if ui.keybind then
                pcall(function() ui.keybind:Set(keyCode) end)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Harvest tab
--------------------------------------------------------------------------------

local HarvestTab = Window:Tab({ Title = "Harvest", Icon = "leaf" })

local harvestStatus
do
    local ok, el = pcall(function()
        return HarvestTab:Paragraph({ Title = "Status", Desc = "Ready." })
    end)
    if ok then harvestStatus = el end
end

local function setHarvestStatus(text)
    if harvestStatus and harvestStatus.SetDesc then
        pcall(function() harvestStatus:SetDesc(text) end)
    end
end

ui.harvestOn = HarvestTab:Toggle({
    Title = "Auto harvest",
    Desc = "Pick every ready node on your own bushes",
    Icon = "sprout",
    Value = CONFIG.harvest.on,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.harvest.on = state
        setHarvestStatus(state and "Running..." or "Stopped.")
    end,
})

ui.harvestDistance = HarvestTab:Slider({
    Title = "Max distance",
    Desc = "Teleport when a node is further than this (server limit is 15)",
    Value = { Min = 5, Max = 15, Default = CONFIG.harvest.maxDistance },
    Step = 1,
    Callback = function(value)
        if not callbacksLive then return end
        CONFIG.harvest.maxDistance = value
    end,
})

ui.harvestDelay = HarvestTab:Slider({
    Title = "Pick delay",
    Desc = "Seconds between picks. Server cooldown is 0.15",
    Value = { Min = 0.15, Max = 1, Default = CONFIG.harvest.pickDelay },
    Step = 0.05,
    Callback = function(value)
        if not callbacksLive then return end
        CONFIG.harvest.pickDelay = value
    end,
})

ui.harvestTeleport = HarvestTab:Toggle({
    Title = "Auto teleport",
    Desc = "Move to the node when it is out of reach",
    Icon = "move",
    Value = CONFIG.harvest.autoTeleport,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.harvest.autoTeleport = state
    end,
})

HarvestTab:Button({
    Title = "Go to bush now",
    Desc = "Move to the nearest bush with a ready node",
    Callback = function()
        if not callbacksLive then return end
        local bush = findBushWithReady()
        if bush then
            moveNear(bush:GetPivot().Position)
            setHarvestStatus("Moved to " .. bush.Name)
        else
            setHarvestStatus("No bush found (plot not ready?)")
        end
    end,
})

HarvestTab:Divider()

-- Rebindable open/close key.
-- WindUI's Keybind only stores the picked key in element.Value; it does not
-- call Callback when a key is picked (Callback fires when the bound key is
-- pressed). So we watch Value and push it to the window ourselves.
local menuKeybind

do
    local ok, el = pcall(function()
        return HarvestTab:Keybind({
            Title = "Menu key",
            Desc = "Click, then press the key you want",
            Value = CONFIG.toggleKey,
            Callback = function() end,
        })
    end)

    if ok then
        menuKeybind = el
        ui.keybind = el
    else
        print("[Matcha] keybind element failed: " .. tostring(el))
    end
end

task.spawn(function()
    local last = menuKeybind and menuKeybind.Value

    while true do
        task.wait(0.3)

        if menuKeybind then
            local picked = menuKeybind.Value

            if picked and picked ~= last then
                last = picked

                local okEnum, keyCode = pcall(function() return Enum.KeyCode[picked] end)
                if okEnum and keyCode then
                    CONFIG.toggleKey = keyCode
                    pcall(function() Window:SetToggleKey(keyCode) end)
                    setHarvestStatus("Menu key: " .. picked)
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Kitchen tab
--------------------------------------------------------------------------------

local PrepTab = Window:Tab({ Title = "Kitchen", Icon = "flame" })

local prepStatus
do
    local ok, el = pcall(function()
        return PrepTab:Paragraph({ Title = "Status", Desc = "Ready." })
    end)
    if ok then prepStatus = el end
end

local function setPrepStatus(text)
    if prepStatus and prepStatus.SetDesc then
        pcall(function() prepStatus:SetDesc(text) end)
    end
end

ui.prepareOn = PrepTab:Toggle({
    Title = "Auto cook",
    Desc = "Cooks continuously at the stations you own",
    Icon = "flame",
    Value = CONFIG.prepare.on,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.prepare.on = state
        setPrepStatus(state and "Starting..." or "Stopped.")
    end,
})

do
    local options = { "Auto" }
    for _, productId in ipairs(recipeList) do
        local product = select(2, pcall(function() return ProductCatalog.Get(productId) end))
        if type(product) == "table" and ownsBuild(product.RequiredCafeBuild) then
            options[#options + 1] = productId
        end
    end

    ui.recipeOptions = options

    local ok, err = pcall(function()
        ui.recipe = PrepTab:Dropdown({
            Title = "Recipe",
            Desc = "Auto = cook what waiting customers need, then keep the last recipe going",
            Values = options,
            Value = CONFIG.prepare.recipe,
            Callback = function(value)
                if not callbacksLive then return end
                CONFIG.prepare.recipe = value
                setPrepStatus("Recipe: " .. tostring(value))
            end,
        })
    end)
    if not ok then
        print("[Matcha] dropdown failed: " .. tostring(err))
    end
end

ui.prepareDelay = PrepTab:Slider({
    Title = "Delay between cups",
    Desc = "Seconds. One cup takes about 2.3 seconds",
    Value = { Min = 0, Max = 3, Default = CONFIG.prepare.delay },
    Step = 0.1,
    Callback = function(value)
        if not callbacksLive then return end
        CONFIG.prepare.delay = value
    end,
})

ui.prepareTeleport = PrepTab:Toggle({
    Title = "Teleport to station",
    Desc = "Move to the station when it is too far",
    Icon = "move",
    Value = CONFIG.prepare.autoTeleport,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.prepare.autoTeleport = state
    end,
})

PrepTab:Button({
    Title = "Cook once",
    Desc = "One cup using the recipe above",
    Callback = function()
        if not callbacksLive then return end
        setPrepStatus(prepareOnce())
    end,
})

--------------------------------------------------------------------------------
-- Serve tab
--------------------------------------------------------------------------------

local ServeTab = Window:Tab({ Title = "Serve", Icon = "coffee" })

local serveStatus
do
    local ok, el = pcall(function()
        return ServeTab:Paragraph({ Title = "Status", Desc = "Ready." })
    end)
    if ok then serveStatus = el end
end

local function setServeStatus(text)
    if serveStatus and serveStatus.SetDesc then
        pcall(function() serveStatus:SetDesc(text) end)
    end
end

ui.serveOn = ServeTab:Toggle({
    Title = "Auto serve",
    Desc = "Take the drink from your backpack and hand it to the customer",
    Icon = "coffee",
    Value = CONFIG.serve.on,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.serve.on = state
        setServeStatus(state and "Looking for customers..." or "Stopped.")
    end,
})

ui.serveDelay = ServeTab:Slider({
    Title = "Serve delay",
    Desc = "Seconds between servings",
    Value = { Min = 0.3, Max = 3, Default = CONFIG.serve.delay },
    Step = 0.1,
    Callback = function(value)
        if not callbacksLive then return end
        CONFIG.serve.delay = value
    end,
})

ui.serveTeleport = ServeTab:Toggle({
    Title = "Teleport to seat",
    Desc = "Move to the seat when it is too far",
    Icon = "move",
    Value = CONFIG.serve.autoTeleport,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.serve.autoTeleport = state
    end,
})

ServeTab:Button({
    Title = "Serve once",
    Desc = "Serve one customer using a drink you carry",
    Callback = function()
        if not callbacksLive then return end

        for _, order in ipairs(enabledServePrompts()) do
            if findProductTool(order.product) then
                if CONFIG.serve.autoTeleport and distanceTo(order.prompt.Parent) > 6 then
                    moveNear(positionOf(order.prompt.Parent))
                end
                if equipProduct(order.product) then
                    local prompt = order.prompt
                    task.spawn(function()
                        pcall(fireproximityprompt, prompt)
                    end)
                    setServeStatus("Serving " .. displayName(order.product))
                else
                    setServeStatus("Could not equip " .. displayName(order.product))
                end
                return
            end
        end
        setServeStatus("No customer order you can fill")
    end,
})

--------------------------------------------------------------------------------
-- Rewards tab
--------------------------------------------------------------------------------

local RewardsTab = Window:Tab({ Title = "Rewards", Icon = "gift" })

do
    local ok, el = pcall(function()
        return RewardsTab:Paragraph({ Title = "Status", Desc = "Idle." })
    end)
    if ok then rewardStatusHandle = el end
end

ui.rewardsOn = RewardsTab:Toggle({
    Title = "Auto claim rewards",
    Desc = "Daily, playtime and the group gift",
    Icon = "gift",
    Value = CONFIG.rewards.on,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.rewards.on = state
        setRewardStatus(state and "Checking rewards..." or "Stopped.")
    end,
})

ui.rewardsDelay = RewardsTab:Slider({
    Title = "Check every",
    Desc = "Seconds between checks. A claim that is not ready is simply skipped",
    Value = { Min = 10, Max = 120, Default = CONFIG.rewards.delay },
    Step = 5,
    Callback = function(value)
        if not callbacksLive then return end
        CONFIG.rewards.delay = value
    end,
})

RewardsTab:Button({
    Title = "Claim now",
    Desc = "Check and claim once",
    Callback = function()
        if not callbacksLive then return end
        claimRewards()
    end,
})

--------------------------------------------------------------------------------
-- Config tab
--------------------------------------------------------------------------------

local ConfigTab = Window:Tab({ Title = "Config", Icon = "save" })

local configStatus
do
    local ok, el = pcall(function()
        return ConfigTab:Paragraph({ Title = "Status", Desc = "No saved config yet." })
    end)
    if ok then configStatus = el end
end

local function setConfigStatus(text)
    if configStatus and configStatus.SetDesc then
        pcall(function() configStatus:SetDesc(text) end)
    end
end

ConfigTab:Button({
    Title = "Save config",
    Desc = "Remembers every toggle, slider, recipe and the menu key",
    Callback = function()
        if not callbacksLive then return end
        setConfigStatus(saveConfig())
    end,
})

ConfigTab:Button({
    Title = "Load config",
    Desc = "Applies the saved settings right now",
    Callback = function()
        if not callbacksLive then return end

        local data = readSavedConfig()
        if not data then
            setConfigStatus("No saved config to load")
            return
        end

        applyConfig(data)
        setConfigStatus("Loaded saved config")
    end,
})

ConfigTab:Button({
    Title = "Delete saved config",
    Desc = "Removes the file, so the next start is all off again",
    Callback = function()
        if not callbacksLive then return end
        setConfigStatus(deleteSavedConfig())
    end,
})

ConfigTab:Divider()

ui.autoLoad = ConfigTab:Toggle({
    Title = "Auto load on start",
    Desc = "Use the saved config every time the script is executed",
    Icon = "download",
    Value = CONFIG.autoLoad,
    Callback = function(state)
        if not callbacksLive then return end
        CONFIG.autoLoad = state
    end,
})

ConfigTab:Paragraph({
    Title = "File",
    Desc = CONFIG_FILE .. " (executor workspace folder)",
})

--------------------------------------------------------------------------------
-- Element creation is done
--------------------------------------------------------------------------------

-- Selecting the tab again after building elements fixes the "This tab is
-- Empty" glitch where the tab container stays hidden.
task.delay(0.3, function()
    pcall(function() HarvestTab:Select() end)
end)

task.delay(0.5, function()
    callbacksLive = true

    -- Autoload the saved config, but only when it asked to be autoloaded.
    local saved = readSavedConfig()
    if not saved then
        setConfigStatus("No saved config yet")
    elseif saved.autoLoad == false then
        -- Show the toggle the way the file has it, so it is obvious why
        -- nothing was applied.
        if ui.autoLoad then
            pcall(function() ui.autoLoad:Set(false) end)
        end
        setConfigStatus("Saved config found (auto load is off)")
    else
        applyConfig(saved)
        setConfigStatus("Loaded saved config")
    end
end)

--------------------------------------------------------------------------------
-- Harvest loop
--------------------------------------------------------------------------------

task.spawn(function()
    local recent = {}

    while true do
        if not CONFIG.harvest.on then
            task.wait(0.3)
            continue
        end

        -- Do not pick or teleport while the kitchen is busy
        if activity then
            task.wait(0.2)
            continue
        end

        local plot = getMyPlot()
        local root = getRoot()

        if plot and root then
            local didWork = false

            for _, bush in ipairs(getBushes(plot)) do
                local targets = {}
                for _, node in ipairs(getReadyNodes(bush)) do
                    local last = recent[node]
                    if not last or os.clock() - last > 1 then
                        table.insert(targets, node)
                    end
                end

                if #targets > 0 then
                    -- Distance is measured to the node: the server checks the
                    -- distance to the node, not to the bush.
                    local nodePos = targets[1]:GetPivot().Position
                    if (root.Position - nodePos).Magnitude > CONFIG.harvest.maxDistance then
                        if CONFIG.harvest.autoTeleport then
                            moveNear(nodePos)
                            root = getRoot()
                            if not root then break end
                        else
                            continue
                        end
                    end

                    for _, node in ipairs(targets) do
                        if not CONFIG.harvest.on then break end

                        -- Re-check the distance right before firing: the
                        -- kitchen may have moved us since the loop started.
                        root = getRoot()
                        if not root then break end

                        local pos = node:GetPivot().Position
                        if (root.Position - pos).Magnitude > CONFIG.harvest.maxDistance then
                            if CONFIG.harvest.autoTeleport then
                                moveNear(pos)
                                root = getRoot()
                                if not root then break end
                            else
                                break
                            end
                        end

                        recent[node] = os.clock()
                        harvestRequest:FireServer(bush, node.Name)
                        stats.picks = stats.picks + 1
                        task.wait(CONFIG.harvest.pickDelay)
                    end

                    didWork = true
                    break
                end
            end

            if not didWork then
                task.wait(0.4)
            end
        else
            task.wait(0.5)
        end
    end
end)

--------------------------------------------------------------------------------
-- Kitchen loop
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        if not CONFIG.prepare.on then
            task.wait(0.4)
            continue
        end

        setPrepStatus(prepareOnce() .. string.format(" — %d cups", stats.cups))
        task.wait(CONFIG.prepare.delay + 0.3)
    end
end)

--------------------------------------------------------------------------------
-- Serve loop
--------------------------------------------------------------------------------

local serveCooldown = {}

task.spawn(function()
    while true do
        if not CONFIG.serve.on then
            task.wait(0.4)
            continue
        end

        local served = false
        local now = os.clock()

        for _, order in ipairs(enabledServePrompts()) do
            local last = serveCooldown[order.prompt]

            if findProductTool(order.product) and (not last or now - last > 5) then
                serveCooldown[order.prompt] = now

                if CONFIG.serve.autoTeleport and distanceTo(order.prompt.Parent) > 6 then
                    moveNear(positionOf(order.prompt.Parent))
                end

                if equipProduct(order.product) then
                    -- fireproximityprompt can yield because the game's own
                    -- prompt handler runs with it, so use its own thread.
                    local prompt = order.prompt
                    task.spawn(function()
                        pcall(fireproximityprompt, prompt)
                    end)
                    setServeStatus("Serving " .. displayName(order.product))
                    served = true
                    task.wait(CONFIG.serve.delay)
                    break
                end
            end
        end

        if not served then
            task.wait(0.5)
        end
    end
end)

--------------------------------------------------------------------------------
-- Rewards loop
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        if not CONFIG.rewards.on then
            task.wait(0.5)
            continue
        end

        claimRewards()
        task.wait(CONFIG.rewards.delay)
    end
end)

--------------------------------------------------------------------------------
-- Status ticker (every 1.5s, not every action, to keep FPS stable)
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(1.5)

        if CONFIG.harvest.on then
            setHarvestStatus(("Running — %d picks"):format(stats.picks))
        end

        local orders = enabledServePrompts()

        local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
        local earned = cash and (cash.Value - stats.cashStart) or 0

        setServeStatus(("Queue: %d | Sold: %d | Cash +%d"):format(#orders, stats.sales, earned))
    end
end)

getgenv().MatchaHarvestMenu = {
    config = CONFIG,
    stats = stats,
    window = Window,
    prepareOnce = prepareOnce,
    teaLeaves = TeaLeaves,
    recipeStation = recipeStation,
    displayToProduct = displayToProduct,
    recipeList = recipeList,
    claimRewards = claimRewards,
    tabs = { harvest = HarvestTab, prepare = PrepTab, serve = ServeTab, rewards = RewardsTab, config = ConfigTab },
}

print("[Matcha] v" .. VERSION .. " ready. Press " .. tostring(CONFIG.toggleKey) .. " to open/close.")
