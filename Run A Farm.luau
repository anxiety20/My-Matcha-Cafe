--[[
    RunAFarm Auto Farm (WindUI)
    ------------------------------------------------------------
    All actions use official game paths:
      - plant   : ProximityPrompt "Plant Seeds" (within 11 studs)
      - harvest : touch MeshPart of ripe crops
      - sell    : Warehouse DropZone (Workspace.World.Warehouse.DropZone)
      - eggs    : CollectZone coop -> StockZone stand
      - quest   : Action "claimQuest"
      - upgrade : step on pad (PadId attribute) + Action "upgradeStand"

    Anti-cheat bypass (no memory modification):
      1. teleport always within valid prompt/zone radius
      2. action delay serialized + random (0.45-0.7s)
      3. backoff retry on server "Slow down" responses
      4. 0.1-0.4s random delay after teleport to avoid instant jumps
      5. "emptyBasket" is never called

    Toggle window: RightShift
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local RAF = ReplicatedStorage:WaitForChild("RunAFarm", 30)
if not RAF then
    error("RunAFarm not found. Run script in game.")
end
local Remotes = RAF:WaitForChild("Remotes")
local ActionRemote = Remotes:WaitForChild("Action")
local StateRemote = Remotes:WaitForChild("GetState")

local STATE = STATE

local function stillAlive()
    if STATE and type(STATE.alive) == "function" then
        local ok, res = pcall(function()
            return STATE:alive()
        end)
        if ok then
            return res ~= false
        end
    end
    return true
end

-- ============================================================
-- PERSISTENT STATE (persists from live-reload)
-- ============================================================
local ENV = getgenv()
local BOT = ENV.__RAF_BOT
if type(BOT) ~= "table" then
    BOT = {}
    ENV.__RAF_BOT = BOT
end

local cfg = BOT.cfg
if type(cfg) ~= "table" then
    cfg = {}
    BOT.cfg = cfg
end

local DEFAULTS = {
    enabled = true,
    crop = "wheat",
    autoPlant = true,
    autoHarvest = true,
    autoSell = true,
    autoEggs = true,
    autoDeposit = true,
    autoQuests = true,
    autoUpgrades = false,
    autoChickens = false,
    seedKeep = 3,
    sellAt = 80,
    eggMin = 8,
    chickenReserve = 800,
    toggleKey = "RightShift",
    actionDelay = 0.45,
    jitter = 0.25,
}
for k, v in pairs(DEFAULTS) do
    if cfg[k] == nil then
        cfg[k] = v
    end
end

local stats = BOT.stats
if type(stats) ~= "table" then
    stats = {}
    BOT.stats = stats
end
local STAT_DEFAULTS = {
    harvest = 0,
    eggs = 0,
    money = 0,
    quests = 0,
    upgrades = 0,
    chickens = 0,
    actions = 0,
    slow = 0,
    errors = 0,
    firstSeen = os.time(),
}
for k, v in pairs(STAT_DEFAULTS) do
    if stats[k] == nil then
        stats[k] = v
    end
end

-- runtime only for this session
local rt = {
    status = "Loading...",
    actions = 0,
    slow = 0,
    errors = 0,
    unloaded = false,
    nextQuest = 0,
    nextUpgrade = 0,
    nextChicken = 0,
    nextEggs = 0,
    para = nil,
    questPara = nil,
    window = nil,
    conn = nil,
    lastNotify = 0,
    plantGuard = {},
    ui = nil,
}

local function shutdown()
    rt.unloaded = true
    if rt.conn then
        pcall(function() rt.conn:Disconnect() end)
        rt.conn = nil
    end
    if rt.window then
        pcall(function() rt.window:Destroy() end)
        rt.window = nil
    end
end

if type(BOT.cleanup) == "function" then
    pcall(BOT.cleanup)
end
BOT.cleanup = shutdown

local function setStatus(text)
    rt.status = text
end

local CONTROL = Workspace
local function pushControl()
    pcall(function()
        CONTROL:SetAttribute("RAF_STATUS", rt.status)
        CONTROL:SetAttribute("RAF_ACTIONS", rt.actions)
    end)
end

local function syncControl()
    local v = CONTROL:GetAttribute("RAF_ENABLED")
    if type(v) == "boolean" and v ~= cfg.enabled then
        cfg.enabled = v
    end
end

local function log(msg)
    print("[RAF] " .. tostring(msg))
    local now = os.clock()
    if rt.ui and rt.window and now - rt.lastNotify > 2.5 then
        rt.lastNotify = now
        pcall(function()
            rt.ui:Notify({
                Title = "RunAFarm",
                Content = tostring(msg),
                Icon = "info",
                Duration = 4,
            })
        end)
    end
end

local function rnd(a, b)
    return a + math.random() * (b - a)
end

-- ============================================================
-- REMOTE ACTION WRAPPER
-- ============================================================
local lastActionAt = 0

local function Action(name, ...)
    local args = table.pack(...)
    for attempt = 1, 3 do
        local target = lastActionAt + cfg.actionDelay + math.random() * cfg.jitter
        local now = os.clock()
        if now < target then
            task.wait(target - now)
        end

        local ok, a, b = pcall(function()
            return ActionRemote:InvokeServer(name, table.unpack(args, 1, args.n))
        end)
        lastActionAt = os.clock()
        stats.actions = stats.actions + 1
        rt.actions = rt.actions + 1

        if ok then
            if a then
                return true, a, b
            end
            local msg = tostring(b)
            local low = string.lower(msg)
            if string.find(low, "slow down", 1, true) or string.find(low, "slow", 1, true) then
                stats.slow = stats.slow + 1
                rt.slow = rt.slow + 1
                task.wait(0.7 * attempt + rnd(0.1, 0.5))
            else
                log(name .. " failed: " .. msg)
                return false, a, b
            end
        else
            stats.errors = stats.errors + 1
            rt.errors = rt.errors + 1
            task.wait(0.3 * attempt)
        end
    end
    return false
end

-- ============================================================
-- CHARACTER & TELEPORT
-- ============================================================
local function getChar()
    local ch = LocalPlayer.Character
    if not ch then return nil end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return nil end
    return ch, hrp, hum
end

local function teleport(pos, spread, settle)
    local _, hrp = getChar()
    if not hrp then return false end
    spread = spread or 0
    local off = Vector3.new(rnd(-spread, spread), 0, rnd(-spread, spread))
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3.2, 0) + off)
    task.wait(settle or rnd(0.12, 0.25))
    return true
end

local function firePrompt(prompt)
    local fpp = fireproximityprompt
    if type(fpp) == "function" then
        return pcall(fpp, prompt)
    end
    if type(prompt) == "userdata" or typeof(prompt) == "Instance" then
        pcall(function() prompt:InputHoldBegin() end)
        task.wait((prompt.HoldDuration or 0) + 0.05)
        pcall(function() prompt:InputHoldEnd() end)
        return true
    end
    return false
end

-- ============================================================
-- GAME STATE
-- ============================================================
local stateCache, stateTime = nil, 0

local function getState(force)
    local now = os.clock()
    if not force and stateCache and (now - stateTime) < 1.0 then
        return stateCache
    end
    local ok, s = pcall(function()
        return StateRemote:InvokeServer()
    end)
    if ok and type(s) == "table" then
        stateCache, stateTime = s, now
        return s
    end
    rt.errors = rt.errors + 1
    return stateCache
end

local function myPlot()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, p in ipairs(plots:GetChildren()) do
        if p:GetAttribute("OwnerId") == LocalPlayer.UserId then
            return p
        end
    end
    return nil
end

local function fieldStatus(field)
    local screen = field:FindFirstChild("Screen")
    local display = screen and screen:FindFirstChild("Display")
    local lbl = display and display:FindFirstChild("Status")
    return lbl and lbl.Text or ""
end

local function fieldPrompt(field)
    local att = field:FindFirstChild("PlantPromptAttachment", true)
    local prompt = att and att:FindFirstChildOfClass("ProximityPrompt")
    return prompt
end

local function ownedFields(plot, s)
    local list = {}
    local fields = plot:FindFirstChild("Fields")
    if not fields then return list end
    s = s or getState(false)
    for _, f in ipairs(fields:GetChildren()) do
        local owned = s and s.owned and s.owned[f.Name]
        if owned == nil and (not s or not s.owned) then
            local status = fieldStatus(f)
            owned = status ~= "" and not string.find(status, "For sale")
        end
        if owned then
            list[#list + 1] = f
        end
    end
    table.sort(list, function(a, b)
        return (tonumber(a.Name:match("%d+")) or 99) < (tonumber(b.Name:match("%d+")) or 99)
    end)
    return list
end

-- ============================================================
-- FARMING ACTIONS
-- ============================================================
local function ensureSeeds(needed)
    local s = getState(true)
    if not s then return false end
    local crop = cfg.crop
    if s.selected ~= crop then Action("selectSeed", crop) end
    local have = (s.seeds and s.seeds[crop]) or 0
    if have < needed then
        local qty = math.max(needed, cfg.seedKeep) - have
        if qty > 0 then
            Action("buySeeds", crop, qty)
            task.wait(0.15)
            s = getState(true)
            have = (s and s.seeds and s.seeds[crop]) or 0
        end
    end
    return have > 0
end

local function plantField(field)
    local guardKey = field:GetFullName()
    local last = rt.plantGuard[guardKey]
    if last and os.clock() - last < 3 then return false end

    local screen = field:FindFirstChild("Screen")
    local target = screen and screen.Position or field:GetPivot().Position
    if not teleport(target + Vector3.new(0, -1.6, 5.0), 1.2, rnd(0.28, 0.45)) then return false end

    local prompt = fieldPrompt(field)
    local waited = 0
    while (not prompt) and waited < 1.2 do
        task.wait(0.2)
        waited = waited + 0.2
        prompt = fieldPrompt(field)
    end
    if not prompt or not prompt.Enabled then return false end

    local fired = firePrompt(prompt)
    rt.plantGuard[guardKey] = os.clock()
    task.wait(rnd(0.35, 0.6))
    return fired and #field.Crops:GetChildren() > 0
end

local function harvestSweep(field)
    local crops = field:FindFirstChild("Crops")
    if not crops or #crops:GetChildren() == 0 then return 0 end
    local s = getState(true)
    if s and s.basketUsed >= s.basketCap then return 0 end

    local harvested = 0
    local stagnant = 0
    local loops = 0
    while stillAlive() and not rt.unloaded do
        loops = loops + 1
        if loops > 60 then break end
        local list = crops:GetChildren()
        if #list == 0 then break end

        local before = #list
        local batch = math.min(#list, 8)
        for i = 1, batch do
            local c = list[i]
            if c and c.Parent then teleport(c.Position, 0.7, rnd(0.075, 0.13)) end
        end
        task.wait(rnd(0.18, 0.3))
        local after = #crops:GetChildren()
        harvested = harvested + math.max(0, before - after)
        if after >= before then stagnant = stagnant + 1 else stagnant = 0 end
        if stagnant >= 3 then break end
    end
    stats.harvest = stats.harvest + harvested
    return harvested
end

local function sellCrops()
    local s = getState(true)
    if not s then return false end
    local cropCount = 0
    for item, n in pairs(s.basket or {}) do
        if item ~= "egg" then cropCount = cropCount + (tonumber(n) or 0) end
    end
    if cropCount <= 0 then return false end

    local world = Workspace:FindFirstChild("World")
    local warehouse = world and world:FindFirstChild("Warehouse")
    local zone = warehouse and warehouse:FindFirstChild("DropZone", true)
    if not zone then
        setStatus("Warehouse DropZone not found")
        return false
    end

    local cashBefore = s.cash or 0
    teleport(zone.Position, 1.5, rnd(0.2, 0.35))
    task.wait(rnd(1.0, 1.4))
    s = getState(true)
    if s then
        local gained = math.max(0, (s.cash or cashBefore) - cashBefore)
        stats.money = stats.money + gained
        if gained > 0 then log("Sold harvest: +$" .. tostring(gained)) end
    end
    return true
end

-- ============================================================
-- EGGS
-- ============================================================
local function coopList(plot, s)
    local out = {}
    local fy = plot:FindFirstChild("Farmyard")
    local coops = fy and fy:FindFirstChild("Coops")
    if not coops then return out end
    for _, coop in ipairs(coops:GetChildren()) do
        local idx = coop:GetAttribute("Coop") or tonumber(coop.Name:match("%d+")) or 0
        local eggs = coop:GetAttribute("Eggs") or 0
        local chickens = coop:GetAttribute("Chickens") or 0
        local owned = coop:GetAttribute("Owned")
        local st = s and s.coops and s.coops[tostring(idx)]
        if st then eggs, chickens = st.eggs or eggs, st.chickens or chickens end
        out[#out + 1] = { model = coop, index = idx, eggs = eggs, chickens = chickens, owned = owned ~= false, zone = coop:FindFirstChild("CollectZone") }
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
end

local function collectEggs(plot, budget)
    local s = getState(true)
    if not s then return false end
    local any = false
    for _, c in ipairs(coopList(plot, s)) do
        if c.zone and c.owned and c.chickens > 0 and c.eggs >= cfg.eggMin then
            if c.eggs <= budget then
                teleport(c.zone.Position, 1.0, rnd(0.15, 0.3))
                task.wait(rnd(0.28, 0.45))
                budget = budget - c.eggs
                any = true
            end
        end
    end
    if any then
        task.wait(rnd(0.4, 0.7))
        stats.eggs = stats.eggs + 1
    end
    return any
end

local function depositEggs(plot)
    local s = getState(true)
    if not s then return false end
    local egg = (s.basket and s.basket.egg) or 0
    if egg <= 0 then return false end
    local stand = plot:FindFirstChild("Farmyard") and plot.Farmyard:FindFirstChild("Stand")
    local zone = stand and stand:FindFirstChild("StockZone", true)
    if not zone then setStatus("Stand StockZone not found") return false end
    teleport(zone.Position, 0.8, rnd(0.2, 0.35))
    task.wait(rnd(1.0, 1.5))
    local fresh = getState(true)
    local now = (fresh and fresh.basket and fresh.basket.egg) or 0
    local moved = egg - now
    if moved > 0 then
        stats.deposited = (stats.deposited or 0) + moved
        log("Deposited " .. moved .. " eggs to stand")
    end
    return true
end

-- ============================================================
-- QUESTS, UPGRADES, CHICKENS
-- ============================================================
local function claimQuests()
    local s = getState(true)
    if not s or type(s.quests) ~= "table" then return end
    for i, q in ipairs(s.quests) do
        if q.have and q.goal and q.have >= q.goal then
            local ok, _, msg = Action("claimQuest", i)
            if ok then
                stats.quests = stats.quests + 1
                log("Quest #" .. i .. " Claimed: " .. tostring(msg))
            end
        end
    end
end

local KIND_PRIORITY = { field = 1, coop = 2, stand = 3, fertilizer = 4, sprinkler = 5, automation = 6, mine = 7, barn = 8, silo = 9, drone = 10, other = 20, decor = 99 }

local function buyUpgrades(plot)
    local s = getState(true)
    if not s then return end
    local config = RAF:FindFirstChild("Config")
    local buttons = config and config:FindFirstChild("Buttons")
    if not buttons then return end
    local ok, defs = pcall(require, buttons)
    if not ok or type(defs) ~= "table" or type(defs.byId) ~= "table" then return end

    local pads = plot:FindFirstChild("Pads")
    if not pads then return end

    local best, bestPrice, bestPrio
    for _, pad in ipairs(pads:GetChildren()) do
        local id = pad:GetAttribute("PadId")
        local info = id and defs.byId[id]
        if info and info.price and (s.cash or 0) >= info.price then
            local kind = info.kind or "other"
            if kind ~= "decor" then
                local prio = KIND_PRIORITY[kind] or KIND_PRIORITY.other
                if not best or (prio < bestPrio) or (prio == bestPrio and info.price < bestPrice) then
                    best, bestPrice, bestPrio = pad, info.price, prio
                end
            end
        end
    end
    if not best then
        for _, pad in ipairs(plot:GetChildren()) do
            if pad.Name:match("^Field") or pad.Name:match("^Coop") or pad.Name:match("^Button") or pad:GetAttribute("PadId") then
                local id = pad:GetAttribute("PadId") or pad.Name
                local info = defs.byId[id] or { price = 500, kind = "field" }
                if info.price and (s.cash or 0) >= info.price then
                    best, bestPrice = pad, info.price
                    break
                end
            end
        end
    end
    if not best then return end

    local pos = best:IsA("BasePart") and best.Position or best:GetPivot().Position
    setStatus("Buying upgrade " .. best.Name .. " ($" .. tostring(bestPrice) .. ")")
    teleport(pos, 1.0, rnd(0.1, 0.25))
    task.wait(rnd(0.5, 1.0))
    local s2 = getState(true)
    if s2 and (s2.cash or 0) < (s.cash or 0) then
        stats.upgrades = stats.upgrades + 1
        log("Buy upgrade: " .. best.Name .. " ($" .. tostring(bestPrice) .. ")")
    else
        setStatus("Upgrade failed or not affordable")
    end
end

local function buyChicken(s)
    if (s.cash or 0) < cfg.chickenReserve + 400 then return end
    for i = 1, 4 do
        local c = s.coops and s.coops[tostring(i)]
        if c and (c.chickens or 0) < 4 then
            local ok, _, msg = Action("buyChicken", i)
            if ok then
                stats.chickens = stats.chickens + 1
                log("Buy chicken coop " .. i .. ": " .. tostring(msg))
            end
            return
        end
    end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local function farmTick()
    local plot = myPlot()
    if not plot then setStatus("Plot not loaded, waiting...") return 1.5 end

    local s = getState(false)
    local fields = ownedFields(plot, s)
    if #fields == 0 then setStatus("No active fields") return 2.0 end

    local cap = (s and s.basketCap) or 100
    local used = (s and s.basketUsed) or 0
    local egg = (s and s.basket and s.basket.egg) or 0
    local cropsInBasket = math.max(0, used - egg)

    if cfg.autoSell and cropsInBasket > 0 and used >= cfg.sellAt then
        setStatus("Basket " .. used .. "/" .. cap .. " - selling...")
        sellCrops()
        return 0.3
    end

    local standCap = (s and s.standCap) or 0
    local standUsed = (s and s.standUsed) or 0
    local standRoom = math.max(0, standCap - standUsed)

    if cfg.autoDeposit and egg > 0 and standRoom > 0 then
        local fresh = getState(true)
        if fresh and fresh.basket and (fresh.basket.egg or 0) > 0 then
            setStatus("Depositing eggs to stand...")
            depositEggs(plot)
            return 0.3
        end
    end

    if cfg.autoEggs and standRoom >= 20 and os.clock() >= rt.nextEggs then
        local budget = math.min(standRoom - 4, cap - used - 4)
        if budget > 0 and collectEggs(plot, budget) then
            rt.nextEggs = os.clock() + 12
            return 0.3
        end
    end

    if cfg.autoQuests and os.clock() >= rt.nextQuest then
        rt.nextQuest = os.clock() + 6
        claimQuests()
    end

    local ripe, empty = {}, {}
    for _, f in ipairs(fields) do
        local st = fieldStatus(f)
        local n = #f.Crops:GetChildren()
        if n > 0 and string.find(st, "Ripe") then ripe[#ripe + 1] = f
        elseif n == 0 and (string.find(st, "Empty") or st == "") then empty[#empty + 1] = f end
    end

    if #ripe > 0 and cfg.autoHarvest then
        if used >= cap - 5 then
            setStatus("Basket full, selling...")
            sellCrops()
            return 0.3
        end
        setStatus("Harvesting " .. #ripe .. " fields...")
        for _, f in ipairs(ripe) do
            harvestSweep(f)
            local st = getState(false)
            if st and st.basketUsed >= st.basketCap then break end
        end
        return 0.3
    end

    if #empty > 0 and cfg.autoPlant then
        if not ensureSeeds(#empty) then setStatus("Out of seeds / insufficient cash") return 2.0 end
        setStatus("Planting " .. #empty .. " fields...")
        for _, f in ipairs(empty) do
            plantField(f)
            task.wait(rnd(0.25, 0.45))
        end
        return 0.5
    end

    if cfg.autoUpgrades and os.clock() >= rt.nextUpgrade then
        rt.nextUpgrade = os.clock() + 15
        buyUpgrades(plot)
    end

    if cfg.autoChickens and os.clock() >= rt.nextChicken then
        rt.nextChicken = os.clock() + 20
        local cur = getState(true)
        if cur then buyChicken(cur) end
    end

    setStatus("Waiting for crops...")
    return 1.0
end

-- ============================================================
-- UI
-- ============================================================
local function formatMoney(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return out
end

local function buildUI()
    local ok, err = pcall(function()
        local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
        rt.ui = WindUI
        local Window = WindUI:CreateWindow({
            Title = "RunAFarm Auto",
            Author = "Auto Farm",
            Icon = "wheat",
            Size = UDim2.fromOffset(620, 480),
            Theme = "Dark",
            ToggleKey = Enum.KeyCode[cfg.toggleKey] or Enum.KeyCode.RightShift,
        })
        rt.window = Window

        local tabDash = Window:Tab({ Title = "Dashboard", Icon = "layout-dashboard" })
        rt.para = tabDash:Paragraph({ Title = "Summary", Desc = "Loading game data..." })

        tabDash:Button({ Title = "Refresh Data", Desc = "Re-read server state", Icon = "refresh-cw", Callback = function() stateTime = 0; getState(true); stateTime = 0 end })
        tabDash:Button({ Title = "Sell Crops Now", Desc = "Teleport to warehouse", Icon = "coins", Callback = function() sellCrops() end })
        tabDash:Button({ Title = "Deposit Eggs Now", Desc = "Teleport to stand", Icon = "egg", Callback = function() local p = myPlot(); if p then depositEggs(p) end end })
        tabDash:Button({ Title = "Claim Completed Quests", Desc = "Claim quests", Icon = "scroll-text", Callback = function() claimQuests() end })

        local tabFarm = Window:Tab({ Title = "Farm", Icon = "sprout" })
        tabFarm:Section({ Title = "Agriculture", Icon = "wheat" })
        
        local st = getState(true)
        local cropNames = { "wheat" }
        if st and st.unlocked then
            local order = { "wheat", "carrot", "corn", "potato", "pumpkin", "strawberry", "tomato", "watermelon", "pineapple", "dragonfruit", "apple", "peach", "cherry", "goldenapple" }
            for _, c in ipairs(order) do if st.unlocked[c] then cropNames[#cropNames + 1] = c end end
        end
        tabFarm:Dropdown({ Title = "Crop", Desc = "Seeds to plant", Values = cropNames, Value = cfg.crop, Callback = function(v) cfg.crop = v end })
        tabFarm:Slider({ Title = "Min seed reserve", Desc = "Buy seeds if below this", Value = { Min = 0, Max = 20, Default = cfg.seedKeep }, Step = 1, Callback = function(v) cfg.seedKeep = math.floor(v) end })
        tabFarm:Toggle({ Title = "Auto Plant", Icon = "sprout", Value = cfg.autoPlant, Callback = function(v) cfg.autoPlant = v end })
        tabFarm:Toggle({ Title = "Auto Harvest", Icon = "wheat", Value = cfg.autoHarvest, Callback = function(v) cfg.autoHarvest = v end })

        local tabSell = Window:Tab({ Title = "Sales", Icon = "coins" })
        tabSell:Section({ Title = "Harvest", Icon = "coins" })
        tabSell:Toggle({ Title = "Auto Sell", Desc = "Sell to warehouse when full", Icon = "truck", Value = cfg.autoSell, Callback = function(v) cfg.autoSell = v end })
        tabSell:Slider({ Title = "Sell threshold (%)", Value = { Min = 30, Max = 100, Default = cfg.sellAt }, Step = 5, Callback = function(v) cfg.sellAt = math.floor(v) end })
        tabSell:Section({ Title = "Eggs", Icon = "egg" })
        tabSell:Toggle({ Title = "Auto Take Eggs", Desc = "Collect from coops", Icon = "egg", Value = cfg.autoEggs, Callback = function(v) cfg.autoEggs = v end })
        tabSell:Toggle({ Title = "Auto Deposit Eggs", Desc = "Deposit to stand", Icon = "package", Value = cfg.autoDeposit, Callback = function(v) cfg.autoDeposit = v end })
        tabSell:Slider({ Title = "Take eggs if >= count", Value = { Min = 1, Max = 60, Default = cfg.eggMin }, Step = 1, Callback = function(v) cfg.eggMin = math.floor(v) end })

        local tabUp = Window:Tab({ Title = "Upgrade", Icon = "hammer" })
        tabUp:Section({ Title = "Automation", Icon = "shopping-cart" })
        tabUp:Toggle({ Title = "Auto Buy Upgrades", Desc = "Buy all affordable upgrades", Icon = "hammer", Value = cfg.autoUpgrades, Callback = function(v) cfg.autoUpgrades = v end })
        tabUp:Toggle({ Title = "Auto Buy Chickens", Desc = "Buy chickens when cash reserve allows", Icon = "bird", Value = cfg.autoChickens, Callback = function(v) cfg.autoChickens = v end })
        tabUp:Slider({ Title = "Chicken Cash Reserve", Value = { Min = 0, Max = 50000, Default = cfg.chickenReserve }, Step = 500, Callback = function(v) cfg.chickenReserve = math.floor(v) end })
        tabUp:Button({ Title = "Upgrade Egg Price (+1)", Icon = "trending-up", Callback = function() Action("upgradeStand", "price") end })
        tabUp:Button({ Title = "Buy Field 2", Icon = "grid-2x2", Callback = function() local p = myPlot(); local pad = p and p.Pads:FindFirstChild("Field2"); if pad then teleport(pad.Position, 1.5, 0.5) end end })

        local tabQuest = Window:Tab({ Title = "Quest", Icon = "scroll-text" })
        tabQuest:Toggle({ Title = "Auto Claim Quests", Icon = "check", Value = cfg.autoQuests, Callback = function(v) cfg.autoQuests = v end })
        rt.questPara = tabQuest:Paragraph({ Title = "Active Quests", Desc = "-" })
        tabQuest:Button({ Title = "Claim Now", Icon = "check-check", Callback = function() claimQuests() end })

        local tabSet = Window:Tab({ Title = "Settings", Icon = "settings" })
        tabSet:Section({ Title = "Humanizer", Icon = "shield" })
        tabSet:Dropdown({ Title = "UI Toggle Key", Desc = "Choose keyboard key", Values = { "RightShift", "LeftShift", "RightControl", "LeftControl", "Insert", "Home", "End", "F4", "F6", "F8", "F10" }, Value = cfg.toggleKey, Callback = function(v)
            if Enum.KeyCode[v] then
                cfg.toggleKey = v
                Window:SetToggleKey(Enum.KeyCode[v])
            end
        end })
        tabSet:Slider({ Title = "Action Delay (s)", Value = { Min = 0.2, Max = 1.5, Default = cfg.actionDelay }, Step = 0.05, Callback = function(v) cfg.actionDelay = v end })
        tabSet:Slider({ Title = "Random Jitter (s)", Value = { Min = 0, Max = 0.8, Default = cfg.jitter }, Step = 0.05, Callback = function(v) cfg.jitter = v end })
        tabSet:Paragraph({ Title = "Bypass info", Desc = "Runs on official remotes. No memory modifications." })
        tabSet:Button({ Title = "Stop & Close", Icon = "power-off", Color = "Red", Callback = function() rt.unloaded = true; Window:Destroy() end })

        Window:SelectTab(1); Window:Open(); Window:SetToggleKey(Enum.KeyCode.RightShift)

        rt.conn = RunService.Heartbeat:Connect(function(dt)
            local acc = (rt.acc or 0) + dt
            if acc < 0.5 then rt.acc = acc return end
            rt.acc = 0
            local s = getState(false)
            if not s then return end

            local p = myPlot()
            local fields = p and ownedFields(p, s) or {}
            local ripe, empty = 0, 0
            for _, f in ipairs(fields) do
                local n = #f.Crops:GetChildren()
                if n > 0 and string.find(fieldStatus(f), "Ripe") then ripe = ripe + 1
                elseif n == 0 then empty = empty + 1 end
            end

            local lines = { "Status: " .. rt.status, "Cash: $" .. formatMoney(s.cash), "Basket: " .. s.basketUsed .. "/" .. s.basketCap }
            lines[#lines+1] = "Stand: " .. (s.standUsed or 0) .. "/" .. (s.standCap or 0)
            lines[#lines+1] = "Fields: " .. #fields .. " active | " .. ripe .. " ripe | " .. empty .. " empty"
            lines[#lines+1] = "Total: " .. stats.harvest .. " harvests | " .. stats.eggs .. " egg collections | " .. stats.quests .. " quests | +$" .. formatMoney(stats.money)
            if rt.para then rt.para.ParagraphFrame:SetDesc(table.concat(lines, "\n")) end

            if rt.questPara and s.quests then
                local qLines = {}
                for i, q in ipairs(s.quests) do
                    qLines[#qLines+1] = "Quest #" .. i .. ": " .. tostring(q.kind) .. " " .. tostring(q.item) .. " (" .. tostring(q.have) .. "/" .. tostring(q.goal) .. ") - reward $" .. tostring(q.reward)
                end
                rt.questPara.ParagraphFrame:SetDesc(table.concat(qLines, "\n"))
            end
        end)
    end)
    if not ok then warn("[RAF] UI failed: " .. tostring(err)) end
end

local function mainLoop()
    while stillAlive() and not rt.unloaded do
        syncControl(); pushControl()
        local ok, err = pcall(function()
            if not getChar() then setStatus("Waiting for character..."); task.wait(1.0) return end
            task.wait(farmTick() or 0.5)
        end)
        if not ok then stats.errors = stats.errors + 1; setStatus("Error: " .. tostring(err)); task.wait(1.5) end
    end
end

buildUI()
if STATE and type(STATE.onCleanup) == "function" then STATE.onCleanup(shutdown) end
task.spawn(mainLoop)
log("Bot started. Toggle UI: RightShift")
