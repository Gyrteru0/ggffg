-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")

local P = require("bots/nevermore/positioning")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    -- Early lane stat + EHP spike (modeled 1:1 on live 1v1 Immortal SF benchmark `ShaNachnetsya`):
    -- 2x Bracer (`+10 STR, +4 AGI, +4 INT, +6 DMG, +2 HP/s`) + kept starting Iron Branch (`+1 all`)
    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",

    -- Rush Boots of Speed IMMEDIATELY after 2x Bracer (`300g` earlier than v3.1.0, zero backpack overflow!)
    -- Eliminates the Level 5-6 `-45 MS` (`305 vs 350`) run-down death window across mid river!
    "item_boots",
    "item_magic_stick",

    -- Rush Power Treads with Belt of Strength FIRST (`+132 HP` in lane!) then Gloves of Haste
    "item_belt_of_strength",
    "item_gloves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}


-- Gets or creates the purchase state for a specific bot
local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            extraMango = 0, extraSalve = 0,
            recoveryWindowAt = -1000, recoverySpent = 0, lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
        }
    end

    return BotPurchaseState[pid]
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() - state.lastShopAttempt < 0.25 then return end
    state.lastShopAttempt = GameTime()
    local gold = bot:GetGold()

    -- 0. WARD AT 4:30 (270 seconds) — never buy a duplicate if starting ward is still in inventory!
    if DotaTime() >= 270 and not state.bought5MinWard then
        local alreadyHasWard = false
        for s = 0, 14 do
            local it = bot:GetItemInSlot(s)
            if it and it:GetName() == "item_ward_observer" then alreadyHasWard = true; break end
        end
        if alreadyHasWard then
            state.bought5MinWard = true
        else
            bot:ActionImmediate_PurchaseItem("item_ward_observer")
            state.bought5MinWard = true
        end
    end

    -- Inventory + stash + dedicated TP slot + personal courier: do not duplicate an item in delivery.
    local function owns(name)
        if name == "item_tpscroll" or name == "item_teleport_scroll" then
            return U.HasAnyTPScroll(bot)
        end
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then return true end
        end
        for i = 0, GetNumCouriers() - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() and courier:GetPlayerID() == bot:GetPlayerID() then
                for slot = 0, 8 do
                    local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                    if ok and it and it:GetName() == name then return true end
                end
            end
        end
        return false
    end
    -- Unconditional Pro Lane Reset Priority:
    -- NEVER sit below 66% HP (`missingHP >= 320`) in lane without a Healing Salve just because the
    -- enemy hero died (e.g. post-First-Blood `104/1034 HP` with `238g`) or stepped into night fog!
    local now = GameTime()
    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 150) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
    end
    local fntLoc = P.GetFountain(bot)
    local nearFountain = bot:HasModifier("modifier_fountain_aura_buff")
        or (fntLoc and GetUnitToLocationDistance(bot, fntLoc) <= 2000)
    local missingHP = bot:GetMaxHealth() - bot:GetHealth()
    local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    local recoveryBought = false
    if DotaTime() > 0 and not nearFountain then
        -- Priority A: Urgent Healing Salve whenever missing >= 320 HP (or <= 55% HP) with neither Salve nor Tango active!
        local salveCD = cfg.RECOVERY_COOLDOWN or 22
        if (missingHP >= 320 or hpPctNow <= 0.55)
            and not bot:HasModifier("modifier_flask_healing")
            and not owns("item_flask")
            and now - state.lastSalveBuyTime >= salveCD then
            local cost = GetItemCost("item_flask")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end

        -- Priority B: Urgent Enchanted Mango replenishment after 1st Bracer so we never play 0-mana against 3-raze SF!
        if not recoveryBought and state.currentItemIndex > 9
            and now - state.lastRecoveryBuy >= salveCD
            and K.MyManaBudget(bot, true) < 140
            and (bot:GetMaxMana() - bot:GetMana()) >= 105
            and hpPctNow >= 0.52
            and not owns("item_enchanted_mango") then
            local cost = GetItemCost("item_enchanted_mango")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and state.recoverySpent + cost <= (cfg.RECOVERY_BUDGET or 340) and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- Main build has priority, especially both bracers. Advance only on success.
    local nextItem = PurchaseTable[state.currentItemIndex]
    if nextItem and gold >= GetItemCost(nextItem) then
        local result = bot:ActionImmediate_PurchaseItem(nextItem)
        if result == (PURCHASE_ITEM_SUCCESS or 0) then
            state.currentItemIndex = state.currentItemIndex + 1
        end
        gold = bot:GetGold()
    end

    local early = state.currentItemIndex <= 11 -- both bracers not yet ordered
    local interval = early and 120 or 90
    if not recoveryBought and DotaTime() > 0 and GameTime() - state.lastSalveBuyTime >= interval
        and not bot:HasModifier("modifier_fountain_aura_buff") then
        local hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local name
        if hp < 0.35 and not bot:HasModifier("modifier_flask_healing")
            and (not early or state.extraSalve < 1) then
            name = "item_flask"
        elseif bot:GetMana() < 75 and hp >= 0.50 and (not early or state.extraMango < 1) then
            name = "item_enchanted_mango"
        end
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = math.max(210, nextBuild and GetItemCost(nextBuild) or 0)
        if name and not owns(name) and gold >= GetItemCost(name) + reserve then
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount(name) > 0
            if inStock then
                local result = bot:ActionImmediate_PurchaseItem(name)
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = GameTime()
                    if name == "item_flask" then state.extraSalve = state.extraSalve + 1
                    else state.extraMango = state.extraMango + 1 end
                end
            end
        end
    end

    -- 3. SMART COURIER (strictly personal, 0.25s instant dispatch + in-transit transfer protection)
    if GameTime() - state.lastCourierCallTime > 0.35 then
        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = GetNumCouriers()
        local myCourier = nil

        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() then
                if c:GetPlayerID() == pid then
                    myCourier = c
                    break
                end
            end
        end
        -- Dota 2 1v1 Mid / Dedicated Server C++ quirk: `CDOTA_Unit_Courier:GetPlayerID()` may return `-1`
        -- or spawn multiple team couriers (`idx=1308, 1393..1528` in `9056469656.dem`); select our own team's active courier!
        if not myCourier then
            for i = 0, numCouriers - 1 do
                local c = GetCourier(i)
                if c and not c:IsNull() and (not c.GetTeam or c:GetTeam() == bot:GetTeam()) then
                    myCourier = c
                    break
                end
            end
        end
        if not myCourier and numCouriers == 1 then
            local c0 = GetCourier(0)
            if c0 and not c0:IsNull() then myCourier = c0 end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)
            local stashItemsCount = 0
            local onlyWardInStash = true
            local urgentCourier = false
            local stashHasFlask = false
            local courierHasFlask = false

            for i = 9, 14 do
                local item = bot:GetItemInSlot(i)
                if item then
                    stashItemsCount = stashItemsCount + 1
                    local nm = item:GetName()
                    if nm ~= "item_ward_observer" then
                        onlyWardInStash = false
                    end
                    if nm == "item_flask" then stashHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local courierItemsCount = 0
            for slot = 0, 8 do
                local okI, cItem = pcall(myCourier.GetItemInSlot, myCourier, slot)
                if okI and cItem then
                    courierItemsCount = courierItemsCount + 1
                    local nm = cItem:GetName()
                    if nm == "item_flask" then courierHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local hasStash = stashItemsCount > 0 or (bot.GetStashValue and (bot:GetStashValue() or 0) > 0)
            local hasOnCourier = courierItemsCount > 0 or (bot.GetCourierValue and (bot:GetCourierValue() or 0) > 0)
            local courierDistFnt = fntLoc and GetUnitToLocationDistance(myCourier, fntLoc) or math.huge
            local courierNearBase = courierDistFnt <= 1500
            -- `9056469656.dem` `02:38.78` fix: NEVER let an outbound courier without `item_flask` walk 9,700u round-trip
            -- leaving `s9:Flask` stranded in Stash for 58s across post-kill + enemy TP! Turn back once if still in home half!
            local needFlaskTurnback = stashHasFlask and not courierHasFlask
                and not U.HasItem(bot, "item_flask") and not bot:HasModifier("modifier_flask_healing")
                and courierDistFnt <= 4800
            if hasStash and not (stashItemsCount == 1 and onlyWardInStash and DotaTime() < 285) then
                if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                    or (state_c == COURIER_STATE_RETURNING_TO_BASE and courierNearBase)
                    or needFlaskTurnback then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    if urgentCourier and COURIER_ACTION_BURST then
                        pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                    end
                    state.lastCourierCallTime = GameTime()
                end
            elseif hasOnCourier and (state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                or state_c == COURIER_STATE_RETURNING_TO_BASE) then
                bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TRANSFER_ITEMS)
                if urgentCourier and COURIER_ACTION_BURST then
                    pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                end
                state.lastCourierCallTime = GameTime()
            end
        end
    end
end
