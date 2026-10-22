local L = {}

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

L._prepCreep = nil
L._prepStartLAT = -100
L._prepExpire = 0

local RAZE_SPECS = {
    { slot = "nevermore_shadowraze1", idx = 0, dist = 200, radius = 250 },
    { slot = "nevermore_shadowraze2", idx = 1, dist = 450, radius = 250 },
    { slot = "nevermore_shadowraze3", idx = 2, dist = 700, radius = 250 },
}

local function BuildAllAttackers(bot, enemyCreeps, allyCreeps, enemyTowers, allyTowers, enemyHero)
    local enemySide = {} -- Units attacking OUR creeps (for denies)
    local allySide  = {} -- Units attacking ENEMY creeps (for last hits)
    for _, c in pairs(enemyCreeps or {}) do
        if U.CanQuery(c) then enemySide[#enemySide + 1] = c end
    end
    for _, t in pairs(enemyTowers or {}) do
        if U.CanQuery(t) then enemySide[#enemySide + 1] = t end
    end
    if enemyHero and U.CanQuery(enemyHero) then
        enemySide[#enemySide + 1] = enemyHero
        allySide[#allySide + 1]   = enemyHero -- Rival denies count on contested enemy creeps!
    end
    for _, c in pairs(allyCreeps or {}) do
        if U.CanQuery(c) then allySide[#allySide + 1] = c end
    end
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then allySide[#allySide + 1] = t end
    end
    return allySide, enemySide
end
L.BuildAllAttackers = BuildAllAttackers

local function IsPositionLethalFromEnemy(bot, checkLoc, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    local maxHP = math.max(1, bot:GetMaxHealth())
    local hpPct = hp / maxHP
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local d = U.DistanceBetweenLocations(checkLoc, eLoc)
    local dNow = U.DistanceBetweenLocations(bLoc, eLoc)
    local enPotMana = U.GetPotentialManaForRaze(enemyHero)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0

    -- 0. Shadowraze Debuff Stack Discipline (`R1_2039` `01:59.73..02:03.03` Root Cause!):
    --   (a) With >= 2 active stacks (`myRem > 0.35s`) and enemy `enPotMana >= 75` ( INCLUDING Mango/Stick in inventory! ),
    --       a 3rd coil hits for `210..380+` magic damage up to `950u` — NEVER turn around toward a creep inside `965u`!
    --   (b) With 1 stack about to expire in `<= 2.15s`, NEVER step forward inside `760u` before the stack burns off!
    if myStacks >= 2 and myRem > 0.35 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        if d < 965 then return true end
    end
    if myStacks == 1 and myRem > 0.20 and myRem <= 2.15 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        if d < 760 then return true end
    end

    -- 1. NEVER walk into an actively casting enemy Shadowraze circle when raze puts us in combo range or < 55% HP!
    if enemyHero:IsUsingAbility() then
        local eFace = (enemyHero.GetFacing and enemyHero:GetFacing()) or 0
        local rad = math.rad(eFace)
        for _, rz in ipairs({ 200, 450, 700 }) do
            local spot = Vector(eLoc.x + math.cos(rad) * rz, eLoc.y + math.sin(rad) * rz, eLoc.z or 128)
            if U.DistanceBetweenLocations(checkLoc, spot) <= 255 then
                local oneR = (race and race.valid and race.oneRaze) or 220
                if hp <= oneR * 1.85 or hpPct <= 0.58 or myStacks >= 1 then
                    return true
                end
            end
        end
    end
    -- 2. Live 30Hz `K.Race` Combo & Boots Run-Down Protection (`Death #1 @ 721 HP / 657u` & `Death #2 @ 554 HP / 608u`):
    if race and race.valid and not race.canKillNow and not (race.canKillSoon and (race.edge or 0) >= -25) then
        if race.heCanKillNow then
            if d < math.max(845, (race.minSafeDist or 860) - 55) then return true end
        elseif race.heCanKillSoon and not race.canKillSoon then
            local twoR = race.twoRaze or ((race.oneRaze or 180) * 2.2)
            local outLeveledOrBootless = race.heHasBootsLead or ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
            if outLeveledOrBootless and hp <= twoR + 165 then
                if d < 835 then return true end
            elseif hp <= twoR + 40 and d < 650 then
                return true
            end
        end
    end
    -- 3. Low-HP lethal burst fallback (includes enemy Mango + Stick burst mana!)
    if hp <= 250 or (hpPct <= 0.44 and enPotMana >= 150) then
        if d < 625 then return true end
    end
    -- 4. No Walk-Through-Enemy for Out-of-Range Back-Wave Creep (`R1_2039` `02:35` & `R2_2044` `02:31` Fix!):
    -- If reaching `checkLoc` requires WALKING closer to a live non-lethal `enemyHero` (`moveDist > 25` & `d < dNow - 15`),
    -- NEVER walk straight through `enemyHero` (`d < 340`) or into active right-click focus when behind in HP!
    local moveDist = U.DistanceBetweenLocations(bLoc, checkLoc)
    local enHp = enemyHero:GetHealth() or 999
    if moveDist > 25 and d < dNow - 15 and enHp > 205 then
        if d < 340 then return true end
        local beingHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.5))
        if beingHit and d < 560 and (hp < enHp + 80 or hp <= 360) then
            return true
        end
    end
    return false
end
L.IsPositionLethalFromEnemy = IsPositionLethalFromEnemy

-- Evaluate every enemy & ally creep on exact 30 Hz integer trajectory ticks
function L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, enemyHero, race)
    local candidates = {}

    local function evalList(list, isDeny, attackers)
        for _, c in pairs(list or {}) do
            if U.CanQuery(c) and c:GetHealth() > 0 then
                local kOpen, kTargetImpact, effClose, gamble, ctx = U.GetExactKillableInfo(bot, c, attackers)
                if kOpen ~= -2 then -- -2 = already fatally struck by our own mid-air projectile!
                    local totalT, launchT, wT, fT, turnT, walkT, cdT = U.GetExactBallisticTicks(bot, c)
                    local bLoc = bot:GetLocation()
                    local cLoc = c:GetLocation()
                    local distNow = U.DistanceBetweenLocations(bLoc, cLoc)
                    local reqLoc = bLoc
                    local maxR = (bot:GetAttackRange() or 525) + 18
                    if distNow > maxR then
                        reqLoc = cLoc + (bLoc - cLoc):Normalized() * (maxR - 12)
                    end
                    local lethalRightClick = IsPositionLethalFromEnemy(bot, reqLoc, enemyHero, race)
                    local nm = c:GetUnitName() or ""
                    local isRangedCreep = nm:find("ranged") ~= nil
                    local isSiegeCreep  = nm:find("siege") ~= nil
                    candidates[#candidates + 1] = {
                        creep = c,
                        isDeny = isDeny,
                        isRanged = isRangedCreep,
                        isSiege = isSiegeCreep,
                        kOpen = kOpen,
                        kTargetImpact = kTargetImpact,
                        effClose = effClose,
                        gamble = gamble,
                        ctx = ctx,
                        totalT = totalT,
                        launchT = launchT,
                        wT = wT,
                        fT = fT,
                        turnT = turnT,
                        walkT = walkT,
                        cdT = cdT,
                        distNow = distNow,
                        lethalRightClick = lethalRightClick,
                    }
                end
            end
        end
    end

    evalList(enemyCreeps, false, allySideAttackers)
    evalList(allyCreeps, true, enemySideAttackers)
    return candidates
end

-- Select optimal right-click target with strict Last-Hit > Deny collision arbitration
function L.SelectBestRightClickPlan(bot, candidates)
    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Earliest enemy last-hit opening tick so a deny NEVER steals attack cooldown from an imminent last hit!
    local earliestEnemyOpen = 9999
    local earliestEnemyTotal = 18
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and not cand.lethalRightClick and cand.kOpen >= 0 and cand.kOpen < 900 then
            if cand.totalT <= cand.effClose + 1 and cand.kOpen < earliestEnemyOpen then
                earliestEnemyOpen = cand.kOpen
                earliestEnemyTotal = cand.totalT
            end
        end
    end

    local best = nil
    local bestScore = -1e9

    for _, cand in ipairs(candidates) do
        -- Enemy CS reserves sacred horizon (`kOpen <= 68`) so attack CD is NEVER wasted right before gold/soul CS;
        -- Ally Denies (`cand.isDeny`) activate STRICTLY inside immediate windup window (`kTargetImpact - totalT <= 3`, `<= 0.10s`)
        -- so SF NEVER stands idle beside a `<50% HP` ally creep waiting `1.8s` for it to fall — SF continuously attacks enemy T1 /
        -- pressures enemy hero and snaps onto the ally deny ONLY on the exact opening tick (`9056774541.dem` `01:45` fix)!
        local horizonOk = (not cand.isDeny and cand.kOpen >= 0 and cand.kOpen <= 68)
            or (cand.isDeny and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= 3)
        if not cand.lethalRightClick and horizonOk then
            -- Must be reachable before the creep dies (+1 tick margin for ranged/melee order)
            if cand.totalT <= cand.effClose + 1 then
                -- If this candidate is an ALLY DENY, check if firing it now locks our attack cooldown
                -- right across an upcoming ENEMY LAST HIT!
                local blocksEnemyLH = false
                if cand.isDeny and earliestEnemyOpen < 900 then
                    local denyLaunch = math.max(cand.launchT, cand.kTargetImpact - cand.fT)
                    local nextReadyImpact = denyLaunch + spaTicks + earliestEnemyTotal
                    if nextReadyImpact > earliestEnemyOpen + 2 then
                        blocksEnemyLH = true
                    end
                end

                if not blocksEnemyLH then
                    -- Exact Urgency Score:
                    -- 1. Enemy Last-Hit strongly beats simultaneous Deny (+400 priority)
                    -- 2. Earlier kTargetImpact comes first so multiple creeps in sequence get 100% chained!
                    -- 3. Ranged / Flagbearer / Siege tie-break bonus
                    local typePrio = cand.isDeny and 0.0 or 400.0
                    local valueBonus = (cand.isRanged or cand.isSiege) and 22.0 or 0.0
                    local gamblePen = cand.gamble and -6.0 or 0.0
                    local score = typePrio + valueBonus + gamblePen - (cand.kTargetImpact * 3.0)
                    if score > bestScore then
                        bestScore = score
                        best = cand
                    end
                end
            end
        end
    end

    return best
end

-- Backwards-compatible public helper used by legacy callers in bot_nevermore.lua
function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    U.BeginPredictionFrame()
    local cands = L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allyAttackers, enemyAttackers, nil, nil)
    local best = L.SelectBestRightClickPlan(bot, cands)
    if best then
        return best.creep, best.isDeny, best
    end
    return nil, false, nil
end

-- Dual-Value Shadowraze CS (`Enemy Hero + Creep in Same 250u Coil`) + Exact Pre-Impact Alive Check:
-- Verified on live replay `auto-20261021-1713-start-ShaNachnetsya.dem` (`tk=14946 -> 14950 -> 14964`):
--   1. NEVER waste Shadowraze on a solo creep when the enemy hero is NOT inside that same 250u coil!
--   2. ONLY cast Shadowraze for CS when:
--      (A) PRIMARY DUAL-VALUE COIL (`heroInSameCoil == true`): `enemyHero` is alive, visible,
--          AND inside `235u` of `rSpot` BOTH right now AND at impact (`+0.55s`), taking BOTH
--          the +43g creep last-hit AND full Hero Shadowraze nuke + stack in a single 75-mana cast!
--      (B) SIMULTANEOUS MULTI-CREEP RESCUE (`multiKills >= 2` with `mana >= 165`): 2+ enemy creeps
--          dying simultaneously in the same 250u circle that right-click cooldown CANNOT reach both.
--   3. STRICT PRE-IMPACT ALIVE CHECK: `hpAlive > 10` at `(castTotalT - 1)` ticks is MANDATORY
--      (NO `or cand.effClose >= castTotalT` bypass!) so we NEVER start a 0.55s coil on a creep
--      already doomed to an incoming tower/creep projectile (`tk=14950`), AND every cast invokes
--      `startRazeCb(ab, c, rSpot, 250, true)` for 0-tick `Action_ClearActions(true)` S-cancel!
function L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb)
    local mana = bot:GetMana() or 0
    if mana < 75 then return false end
    local razeCastTicks = (C.BALLISTIC and C.BALLISTIC.RAZE_CAST_TICKS) or 17
    local bLoc = bot:GetLocation()
    local curYaw = (bot.GetFacing and bot:GetFacing()) or 0
    local degPerTick = math.deg((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90)
    local hasHero = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    -- Stack-Discipline Self-Root Guard (`R1_2039` `01:59.73` Fix!):
    -- NEVER self-root `0.55s` casting a non-hero-kill creep raze when:
    --   (a) we carry `>= 2` enemy raze stacks (`myRem > 0.3s`), OR
    --   (b) our 1st enemy raze stack is `<= 2.20s` from expiring completely while enemy can follow up with `W`/`Q`!
    if hasHero then
        local mySt, myRem = U.GetShadowrazeDebuff(bot)
        local enPotMana = U.GetPotentialManaForRaze(enemyHero)
        local dHero = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
        if enPotMana >= 75 then
            if (mySt or 0) >= 2 and (myRem or 0) > 0.30 and dHero < 1020 then
                return false
            end
            if (mySt or 0) == 1 and (myRem or 0) > 0.20 and (myRem or 0) <= 2.20 and dHero < 810 then
                return false
            end
        end
    end

    local bestAb, bestCand, bestSpot, bestAng, bestScore = nil, nil, nil, 0, -1
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.creep and U.CanQuery(cand.creep)
            and cand.creep:IsAlive() and cand.creep:GetHealth() > 0 then
            local c = cand.creep
            local cLoc = c:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, cLoc)
            local wantYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
            local ang = math.abs(((wantYaw - curYaw + 180) % 360) - 180)
            local turnT = (ang > 11.5) and math.ceil((ang - 11.5) / degPerTick) or 0
            local castTotalT = turnT + razeCastTicks

            for _, spec in ipairs(RAZE_SPECS) do
                if math.abs(d - spec.dist) <= (spec.radius - 28) then
                    local ab = bot:GetAbilityByName(spec.slot)
                    if ab and ab:IsFullyCastable() then
                        local baseDmg = 0
                        if ab.GetSpecialValueInt then
                            local ok, v = pcall(ab.GetSpecialValueInt, ab, "shadowraze_damage")
                            if ok and type(v) == "number" then baseDmg = v end
                        end
                        if baseDmg <= 0 and ab.GetAbilityDamage then
                            local ok, v = pcall(ab.GetAbilityDamage, ab)
                            if ok and type(v) == "number" then baseDmg = v end
                        end
                        if baseDmg <= 0 then baseDmg = 30 + 60 * ab:GetLevel() end
                        local magicDmg = math.floor(c:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                        local tImpact = castTotalT / 30.0
                        local tBefore = math.max(0.033, (castTotalT - 1) / 30.0)
                        local hpAtCast = U.PredictHPWithContext(cand.ctx, c, tImpact, "max")
                        local hpAlive  = U.PredictHPWithContext(cand.ctx, c, tBefore, "min")

                        -- Mandatory: creep MUST still have > 10 HP 1 tick before impact AND die to coil!
                        if hpAlive > 10 and hpAtCast > 0 and hpAtCast <= magicDmg then
                            local rad = math.rad(wantYaw)
                            local rSpot = Vector(bLoc.x + math.cos(rad) * spec.dist, bLoc.y + math.sin(rad) * spec.dist, bLoc.z or 128)

                            -- Check Dual-Value Hero Hit in the EXACT SAME 250u Shadowraze circle!
                            local heroInSameCoil = false
                            if hasHero then
                                local hNow = enemyHero:GetLocation()
                                local hPred = U.PredictPosition(enemyHero, tImpact)
                                if U.DistanceBetweenLocations(rSpot, hNow) <= 242
                                    and U.DistanceBetweenLocations(rSpot, hPred) <= 232 then
                                    heroInSameCoil = true
                                end
                            end

                            -- AoE Splash Safety + Multi-Creep Kill Count across all enemy creeps
                            local ruinsOtherCreep = false
                            local multiKills = 1
                            for _, oc in ipairs(candidates) do
                                if not oc.isDeny and oc.creep ~= c and U.CanQuery(oc.creep) and oc.creep:IsAlive() then
                                    if U.DistanceBetweenLocations(rSpot, oc.creep:GetLocation()) <= 255 then
                                        local oDmg = math.floor(oc.creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                                        local oRem = oc.creep:GetHealth() - oDmg
                                        local oMin = U.SFDamageRange(bot, oc.creep).min
                                        if oRem <= 0 then
                                            multiKills = multiKills + 1
                                        elseif oRem > 0 and oRem <= oMin + 28 then
                                            ruinsOtherCreep = true
                                            break
                                        end
                                    end
                                end
                            end

                            local rightClickImpossible = cand.lethalRightClick
                                or (cand.kOpen == -1 and cand.effClose >= castTotalT)
                                or (cand.kOpen >= 0 and cand.totalT > cand.effClose + 1)
                            local allowDoubleCreepRescue = (not heroInSameCoil)
                                and multiKills >= 2
                                and rightClickImpossible
                                and mana >= 165

                            if not ruinsOtherCreep and (heroInSameCoil or allowDoubleCreepRescue) then
                                local score = (heroInSameCoil and 1000 or 200)
                                    + multiKills * 90
                                    + (cand.isRanged and 55 or 20)
                                    - turnT * 8
                                if score > bestScore then
                                    bestAb = ab
                                    bestCand = cand
                                    bestSpot = rSpot
                                    bestAng = ang
                                    bestScore = score
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if bestAb and bestCand and bestSpot then
        local cLoc = bestCand.creep:GetLocation()
        if bestAng > degPerTick + 11.5 then
            bot:Action_MoveToLocation(bLoc + (cLoc - bLoc):Normalized() * 28)
        else
            if startRazeCb then
                startRazeCb(bestAb, bestCand.creep, bestSpot, 250, true)
            else
                bot:Action_UseAbility(bestAb)
            end
        end
        return true
    end
    return false
end

-- Exact Algebraic Under-Tower HP Prep Solver (Zero Over-Attack Guarantee via m_flLastAttackTime lock)
function L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, allyTowers, enemyTowers, candidates, enemyHero, race)
    local curLAT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
    if L._prepExpire and GameTime() < L._prepExpire - 2.0 then
        L._prepCreep = nil
        L._prepExpire = 0
    end
    -- CRITICAL (`9056469656.dem` `01:20` Root Cause!):
    -- Valve C++ `CDOTA_BaseNPC::StartAttack` stamps `m_flLastAttackTime` on TICK 1 of windup (`0.46s` BEFORE launch!),
    -- so checking `curLAT > L._prepStartLAT` S-cancelled 100% of under-tower prep swings on frame 2 without firing 1 bolt!
    -- Instead, detect actual projectile release directly from `L._prepCreep:GetIncomingTrackingProjectiles()` (`p.caster == bot`)!
    if L._prepCreep then
        local launched = false
        if U.CanQuery(L._prepCreep) then
            for _, p in pairs(L._prepCreep:GetIncomingTrackingProjectiles() or {}) do
                if p.is_attack and p.caster == bot then
                    launched = true
                    break
                end
            end
        end
        if not U.CanQuery(L._prepCreep) or GameTime() > L._prepExpire or launched then
            if launched then
                bot:Action_ClearActions(true)
            end
            L._prepCreep = nil
            L._prepExpire = 0
        else
            -- Keep finishing the single locked prep swing unless an urgent CS just opened
            return true
        end
    end

    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Never start a prep hit if ANY creep needs a real last hit / deny within spaTicks + 16 ticks!
    for _, cand in ipairs(candidates) do
        if cand.kOpen >= 0 and cand.kOpen <= spaTicks + 16 and not cand.lethalRightClick then
            return false
        end
    end

    -- Never distract SF from executing a low-HP enemy hero (`<= 350 HP`, e.g. `S29` `02:32.92` `284 HP` ramp brawl!),
    -- nor swing prep hits while low HP & being poked (`2:48` fix!)
    if enemyHero and U.CanQuery(enemyHero) and (enemyHero:GetHealth() or 9999) <= 350
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 700 then
        return false
    end
    local beingPokedNow = enemyHero and U.CanQuery(enemyHero)
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    if beingPokedNow and (bot:GetHealth() or 9999) <= 380 then
        return false
    end

    -- Exact 1- & 2-Step Ballistic Modular Under-Tower Prep (`9056469656.dem` `01:20` Lvl 2 `58..64` vs `550 HP` Fix!):
    -- Why `k in {1, 2}` prep steps is mandatory under T1:
    --   - At Lvl 2 (`myMin = 58, myAvg = 61`) vs `550 HP` melee under T1 (`tDmg = 97`):
    --     * `0` preps -> `550 - 5*97 = 65 HP > 58` (T1 steals 3/3 melee creeps at `01:20`!).
    --     * `1` prep  -> `550 - 61 - 4*97 = 101 HP` -> `101 - 97 = 4 HP` (still needs a 2nd prep!).
    --     * `2` preps -> `550 - 2*61 - 4*97 = 40 HP` inside `[5, 56]` -> `100%` clean 1-shot CS!
    --   - Meanwhile, on Ranged creeps (`300 - 2*109 = 82 <= 84` or `300 - 3*97 = 9 <= 58`), `rem0` ALREADY lies in
    --     `[1, myMin]`, so `remNow > myMin` is `false` -> `0` preps fired, NEVER breaking an already clean 1-shot!
    local mySpa = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then
            local _, _, towerRawAvg = U.SampleRawDamageRange(t)
            local tSpa = (t.GetSecondsPerAttack and t:GetSecondsPerAttack()) or 0.818
            if tSpa <= 0.1 then tSpa = 0.818 end
            local okTT, tCurTarget = false, nil
            if t.GetAttackTarget then okTT, tCurTarget = pcall(t.GetAttackTarget, t) end
            if not okTT then tCurTarget = nil end
            local towerActivelyFiring = (tCurTarget ~= nil)
            if not towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        for _, p in pairs(c:GetIncomingTrackingProjectiles() or {}) do
                            if p.is_attack and p.caster == t then towerActivelyFiring = true; break end
                        end
                    end
                    if towerActivelyFiring then break end
                end
            end

            -- CRITICAL (`9056469656.dem` `01:20` Fix!): NEVER prep unless `t` is ACTUALLY firing at creeps,
            -- and sort strictly by C++ `CDOTA_BaseNPC_Tower` kill order (`tCurTarget` first, then closest to `t`)!
            local orderedUnderT1 = {}
            if towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        local dT = GetUnitToLocationDistance(t, c:GetLocation())
                        if dT <= 730 then
                            orderedUnderT1[#orderedUnderT1 + 1] = { c = c, d = dT, active = (c == tCurTarget) }
                        end
                    end
                end
            end
            table.sort(orderedUnderT1, function(a, b)
                if a.active ~= b.active then return a.active end
                return a.d < b.d
            end)

            for _, entry in ipairs(orderedUnderT1) do
                local c = entry.c
                if not IsPositionLethalFromEnemy(bot, bot:GetLocation(), enemyHero, race) then
                    local tDmg = U.CalcExactIntDamage(t, c, towerRawAvg)
                    local sfRange = U.SFDamageRange(bot, c)
                    local myMin, myAvg = sfRange.min, sfRange.avg
                    -- Account for ALL projectiles ALREADY in flight (`tower` AND `bot` prep bolt!)
                    local hpEff = c:GetHealth()
                    local hasTowerBoltInAir = false
                    for _, p in pairs(c:GetIncomingTrackingProjectiles() or {}) do
                        if p.is_attack then
                            if p.caster == t then
                                hpEff = hpEff - tDmg
                                hasTowerBoltInAir = true
                            elseif p.caster == bot then
                                hpEff = hpEff - myAvg
                            end
                        end
                    end
                    if tDmg > 0 and hpEff > myMin + 6 then
                        local kShotsRaw = math.max(1, math.floor(hpEff / tDmg))
                        -- Exact Stochastic Drift + Creep Regen Margin (`+0.5 HP/s` regen + T1 min-roll spread over `kShots`!):
                        -- Without this margin, `550 - 5*96 = 70 <= 71` and `300 - 2*108 = 84 <= 84` looked "safe",
                        -- then `+2 HP` creep regen + T1 low rolls pushed actual post-T1 HP to `74..76` & `87 HP`,
                        -- leaving `1–5 HP` slivers on EVERY creep under T1 (`s30_probe`: `c4: 87 -> 1 HP` at `tk=5768`!)!
                        -- Also guard against the opposite edge (`remNow <= 8`, where a high T1 roll `98` kills `98 -> 0` directly!).
                        local driftMargin = math.min(18, kShotsRaw * 2 + 4)
                        local safeNoPrepCeil = math.max(8, myMin - driftMargin)
                        local remNow = hpEff % tDmg
                        if remNow == 0 then remNow = tDmg end
                        if remNow > safeNoPrepCeil then
                            local totalTicksNow = U.GetExactBallisticTicks(bot, c)
                            local upperClean = math.max(8, myMin - math.min(12, kShotsRaw * 2 + 2))
                            local bestPrep = false
                            for nPreps = 1, 2 do
                                local hpAfterN = hpEff - nPreps * myAvg
                                -- STRICT INVARIANT: `hpAfterN >= tDmg + 8` guarantees at least `1` FULL non-lethal T1 bolt
                                -- survives after our prep (`EarlyHit == 0`), while window closes on `(towerShotsToOpen + 0.70) * tSpa`!
                                if hpAfterN >= tDmg + 8 then
                                    local remN = hpAfterN % tDmg
                                    if remN == 0 then remN = tDmg end
                                    if remN >= 4 and remN <= upperClean then
                                        local towerShotsToOpen = math.max(1, math.floor((hpAfterN - remN) / tDmg + 0.5))
                                        local timeUntilSteal = entry.active
                                            and ((towerShotsToOpen + 0.70) * tSpa)
                                            or ((towerShotsToOpen + 2.0) * tSpa)
                                        local reloadNeed = nPreps * mySpa + (totalTicksNow / 30.0) + 0.05
                                        if timeUntilSteal >= reloadNeed then
                                            bestPrep = true
                                            break
                                        end
                                    end
                                end
                            end
                            if bestPrep then
                                L._prepCreep = c
                                L._prepStartLAT = curLAT
                                L._prepExpire = GameTime() + 1.1
                                bot:Action_AttackUnit(c, true)
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Exact 30.000 Hz Zero-Cancel Phase-Locked Ballistic Controller (`0–1` Tick Arrival, `0` Fake Swing Cancels!)
function L.ExecutePhaseLockedCS(bot, plan, s, P)
    local target = plan.creep
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack[bot]
    local dmgRange = U.SFDamageRange(bot, target)
    local myMinDmg = dmgRange.min
    local maxHP = math.max(1, target:GetMaxHealth())

    -- 1. If our bot is ALREADY mid-windup on `target`, inspect exact arrival tick of THIS active swing!
    if rec and rec.wasAnim and rec.launchTick and rec.launchTick >= curTick and bot:GetAttackTarget() == target then
        local predImpact = (rec.launchTick - curTick) + plan.fT
        local hpAtPred = U.PredictHPWithContext(plan.ctx, target, predImpact / 30.0, "max")
        local legalDeny = (not plan.isDeny) or (hpAtPred * 2 < maxHP)

        -- THIS SWING IS LOCKED ON TARGET TO HIT IN [0, 1] TICKS OF KILLABLE -> DO NOT TOUCH IT!
        if predImpact >= plan.kTargetImpact or (hpAtPred > 0 and hpAtPred <= myMinDmg and legalDeny) then
            return true
        end

        -- ONLY abort an already-started swing if the creep unexpectedly stopped taking damage and our bolt
        -- would genuinely arrive BEFORE killable threshold (`hpAtPred > myMinDmg`)!
        if (rec.launchTick - curTick) <= 1 then
            bot:Action_ClearActions(true)
            return true
        end
        return true
    end

    -- 2. Not mid-windup on `target` right now: compute exact integer slack `freshDelta`
    local freshDelta = plan.kTargetImpact - plan.totalT

    -- Move off river lowground (`25%` uphill miss!) or closer (`175u`, `4–5` flight ticks) while we have slack!
    if freshDelta >= 7 and P and P.GetLasthitPosition then
        local optPos = P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, "NEUTRAL")
        if optPos and U.DistanceBetweenLocations(bot:GetLocation(), optPos) > 32 then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    -- Exact firing tick (`freshDelta <= 0`): ONE clean swing -> ONE projectile -> ZERO self-cancels!
    if freshDelta <= 0 then
        bot:Action_AttackUnit(target, true)
        return true
    end

    -- Pre-align hero yaw to `0.00 deg` toward `target` smoothly WITHOUT fake attack-swing spam (`0` `SCancel`!):
    -- Align strictly at `freshDelta >= 3` down to `<= 2.5 deg` so on ticks `freshDelta == 2, 1, 0` hero stands dead-still at `0.0 deg`!
    local bLoc = bot:GetLocation()
    local cLoc = target:GetLocation()
    local wantYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
    local curYaw = (bot.GetFacing and bot:GetFacing()) or wantYaw
    local angErr = math.abs(((wantYaw - curYaw + 180) % 360) - 180)

    if freshDelta >= 3 and angErr > 5.5 and U.DistanceBetweenLocations(bLoc, cLoc) > 125 then
        bot:Action_MoveToLocation(bLoc + (cLoc - bLoc):Normalized() * 15)
        return true
    end

    if freshDelta >= 4 and P and P.GetLasthitPosition then
        local optPos = P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, "NEUTRAL")
        if optPos and U.DistanceBetweenLocations(bLoc, optPos) > 28 then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    if U.IsAttackingAction(bot) then
        bot:Action_ClearActions(true)
    end
    return true
end

-- Master Top-Priority 30.000 Hz Sacred CS & Spacing Entry Point
function L.RunSacredCS(bot, s, race, P, startRazeCb)
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    local enemyHero   = s.enemy
    if #enemyCreeps == 0 and #allyCreeps == 0 then
        return false, false
    end

    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk = BuildAllAttackers(
        bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, enemyHero
    )
    -- Smart 1v1 Ally Deny Policy (`9055695956.dem` `6:05` + `9056774541.dem` `01:45` Fix):
    --   1. NEVER deny our own creeps when the enemy hero is dead or outside XP range (`0` XP denied anyway — keep full tank wave!).
    --   2. When sieging enemy T1 WITH the enemy hero inside XP range: ONLY allow denying an ally creep if `>= 2` live ally creeps
    --      are inside `755u` of enemy T1 (never kill our last T1 tank!), AND because `SelectBestRightClickPlan` restricts denies
    --      to `kTargetImpact - totalT <= 3`, SF hits enemy T1 continuously and snaps to deny ONLY on the exact opening tick!
    local enemyInXpRange = (s.enemyAlive ~= false)
        and ((s.enemyVisible and (s.enemyDist or 9999) <= 1650)
            or (not s.enemyVisible and (s.enemyAbsentFor or 0) <= 3.0))
    local allowAllyDenies = enemyInXpRange
    if allowAllyDenies and s.enemyT1Alive and s.enemyT1Loc then
        if GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1150 then
            local shieldCreeps = 0
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and (ac:GetHealth() or 0) > 25
                    and GetUnitToLocationDistance(ac, s.enemyT1Loc) <= 755 then
                    shieldCreeps = shieldCreeps + 1
                end
            end
            if shieldCreeps < 2 then
                allowAllyDenies = false
            end
        end
    end
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, allowAllyDenies and allyCreeps or {}, allySideAtk, enemySideAtk, enemyHero, race
    )

    -- 1. First execute Dual-Value Hero+Creep Shadowraze (or 2+ simultaneous creep rescue) with S-cancel hook!
    if L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb) then
        return true, true
    end

    -- 2. Select highest-priority right-click last-hit / deny within the sacred 1.80s (54-tick) horizon
    local bestPlan = L.SelectBestRightClickPlan(bot, candidates)
    if bestPlan then
        return L.ExecutePhaseLockedCS(bot, bestPlan, s, P), true
    end

    -- 3. No CS needed in next ~1.70s: solve exact algebraic Under-Tower HP Prep hits!
    if L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAtk, enemySideAtk, s.allyTowers, s.enemyTowers, candidates, enemyHero, race) then
        return true, false
    end

    -- 4. Low-HP Safe Lane Spacing — STRICTLY GATED so it NEVER hijacks lethal kills (`9056469656.dem` Death #2
    --    `04:08.05–04:11.52`: `Bot 167 HP, 152 MP` vs `182 HP, 2 MP` `ShaNachnetsya`!) AND NEVER retreats from a
    --    0-mana enemy (`< 75 MP`) when we hold spell/soul advantage (`01:45–02:02`, `Sha 12–44 MP` vs `Bot Lvl 3`!):
    local hp = bot:GetHealth()
    local enemyManaAvail = (enemyHero and U.CanQuery(enemyHero))
        and ((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) or 0
    local canFinishEnemy = enemyHero and U.CanQuery(enemyHero)
        and (U.CanQuickTurnKillWithRaze(bot, enemyHero)
            or U.CanOneShotEnemyHero(bot, enemyHero)
            or (enemyHero:GetHealth() <= U.GetNRazeDamage(bot, enemyHero, 1) + 75 and (bot:GetMana() or 0) >= 75)
            or (race and race.valid and race.canKillNow))
    local weHoldDryAdvantage = enemyManaAvail < 75 and hp >= 215
        and (((bot:GetMana() or 0) >= 75)
            or (hp >= math.max(300, (enemyHero and U.CanQuery(enemyHero) and enemyHero:GetHealth() or 999) + 60)))
    local pokedLow = enemyHero and U.CanQuery(enemyHero) and hp >= 155 and hp <= 345
        and not canFinishEnemy and not weHoldDryAdvantage
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    if enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy and not weHoldDryAdvantage
        and ((hp >= 165 and hp <= 280) or pokedLow) and (#enemyCreeps > 0 or #allyCreeps > 0) then
        local lethalRace = race and race.valid and (race.heCanKillSoon or race.losingHard)
        if not lethalRace or pokedLow then
            local eLoc = enemyHero:GetLocation()
            local bLoc = bot:GetLocation()
            local fnt = P.GetFountain(bot)
            local targetGap = pokedLow and 830 or 900
            local safeAnchor = eLoc + (fnt - eLoc):Normalized() * targetGap
            if U.DistanceBetweenLocations(bLoc, safeAnchor) > 45 then
                bot:Action_MoveToLocation(safeAnchor)
            end
            return true, false
        end
    end

    -- 5. Uncontested Wave Equilibrium Stance Discipline:
    -- When uncontested (enemy absent / dead / TPing), hold crisp 175u highground CS anchor
    -- across the entire wave so walkTicks == 0 and fTicks == 4 on 100% of creeps; when an
    -- enemy hero IS live in lane and no creep opens within 68 ticks, yield to combat/spacing!
    local siegingEnemyT1Now = s.enemyT1Alive and s.enemyT1Loc and #allyCreeps >= 1
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1120
    if not siegingEnemyT1Now and (not enemyHero or not U.CanQuery(enemyHero)) and #enemyCreeps >= 2 and P and P.GetLasthitPosition then
        local anchor = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, "NEUTRAL")
        if anchor and U.DistanceBetweenLocations(bot:GetLocation(), anchor) > 32 then
            bot:Action_MoveToLocation(anchor)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, true
    end

    -- Check whether any creep is below 72% HP so `HandlePriorityPush` does NOT blind-auto-attack mid-wave!
    local waveHasDamagedCreep = false
    for _, c in pairs(enemyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.72 then
            waveHasDamagedCreep = true
            break
        end
    end
    for _, c in pairs(allyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.65 then
            waveHasDamagedCreep = true
            break
        end
    end
    return false, waveHasDamagedCreep
end

return L
