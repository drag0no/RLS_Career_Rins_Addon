local M = {}

local DEFAULT_MONEY_PERCENT_PER_LEVEL = 0.02
local CIVIL_SERVICE_ATTRIBUTE_KEY = "careerSkills-civilService"
local CIVIL_SERVICE_PATH_IDS = {"careerSkills-civilService"}
local CIVIL_SERVICE_REWARD_CONFIG_PATH = "gameplay/civilService/rewardConfig.json"

local civilServiceRewardConfig

-- Branch APIs can return multiple values; only the first is the level.
local function tonumberFirst(...)
    local value = select(1, ...)
    if value == nil then
        return nil
    end
    return tonumber(value)
end

local function branchLevelFromPath(pathId)
    if not career_branches or not career_branches.getBranchLevel or type(pathId) ~= "string" or pathId == "" then
        return nil
    end
    local branchLevel = career_branches.getBranchLevel(pathId)
    return tonumberFirst(branchLevel)
end

local function branchLevelFromValue(value, pathId)
    if not career_branches or not career_branches.calcBranchLevelFromValue or type(pathId) ~= "string" or pathId == "" then
        return nil
    end
    local branchLevel = career_branches.calcBranchLevelFromValue(value, pathId)
    return tonumberFirst(branchLevel)
end

local function maxBranchLevel(level, pathId)
    local branchLevel = branchLevelFromPath(pathId)
    if branchLevel then
        return math.max(level, branchLevel)
    end
    return level
end

local function maxBranchLevelFromValue(level, value, pathId)
    local branchLevel = branchLevelFromValue(value, pathId)
    if branchLevel then
        return math.max(level, branchLevel)
    end
    return level
end

function M.loadRewardConfig(configPath)
    if type(configPath) ~= "string" or configPath == "" then
        return {}
    end
    return jsonReadFile(configPath) or {}
end

function M.getSkillConfig(rewardConfig)
    if type(rewardConfig) == "table" then
        return rewardConfig.skill or {}
    end
    return {}
end

function M.getAttributeKey(skillConfig, defaultKey)
    local configuredKey = skillConfig and skillConfig.attributeKey
    if type(configuredKey) == "string" and configuredKey ~= "" then
        return configuredKey
    end
    return defaultKey
end

function M.getSkillLevel(attributeKey, pathIds)
    if not career_career or not career_career.isActive() then
        return 1
    end

    local level = 0
    if career_branches and career_branches.getBranchLevel then
        if type(attributeKey) == "string" and attributeKey ~= "" then
            level = maxBranchLevel(level, attributeKey)
        end
        for _, pathId in ipairs(pathIds or {}) do
            level = maxBranchLevel(level, pathId)
        end
    end

    if career_modules_playerAttributes
        and career_modules_playerAttributes.getAttributeValue
        and career_branches
        and career_branches.calcBranchLevelFromValue then
        local skillValue = tonumberFirst(career_modules_playerAttributes.getAttributeValue(attributeKey))
        if skillValue then
            level = maxBranchLevelFromValue(level, skillValue, attributeKey)
            for _, pathId in ipairs(pathIds or {}) do
                level = maxBranchLevelFromValue(level, skillValue, pathId)
            end
        end
    end

    return math.max(1, math.floor(level))
end

function M.getSkillLevelRaw(attributeKey, pathIds)
    if not career_career or not career_career.isActive() then
        return 0
    end

    local level = 0
    if career_branches and career_branches.getBranchLevel then
        if type(attributeKey) == "string" and attributeKey ~= "" then
            level = maxBranchLevel(level, attributeKey)
        end
        for _, pathId in ipairs(pathIds or {}) do
            level = maxBranchLevel(level, pathId)
        end
    end

    if career_modules_playerAttributes
        and career_modules_playerAttributes.getAttributeValue
        and career_branches
        and career_branches.calcBranchLevelFromValue then
        local skillValue = tonumberFirst(career_modules_playerAttributes.getAttributeValue(attributeKey))
        if skillValue then
            level = maxBranchLevelFromValue(level, skillValue, attributeKey)
            for _, pathId in ipairs(pathIds or {}) do
                level = maxBranchLevelFromValue(level, skillValue, pathId)
            end
        end
    end

    return math.max(0, math.floor(level))
end

function M.getMoneyBonusMultiplier(skillConfig, skillLevel)
    local laneIndex = math.floor(tonumber(skillConfig and skillConfig.rewardLaneIndex) or 0)
    local laneCount = math.floor(tonumber(skillConfig and skillConfig.rewardLaneCount) or 0)
    if laneIndex >= 1 and laneCount >= laneIndex then
        local level = math.max(1, math.min(50, math.floor(tonumber(skillLevel) or 1)))
        local bonus = 0
        for unlockedLevel = 2, math.min(49, level) do
            if ((unlockedLevel - 2) % laneCount) + 1 == laneIndex then bonus = bonus + (0.04 * laneCount) end
        end
        if level >= 50 then bonus = bonus + 0.08 end
        return 1 + math.min(2, bonus)
    end
    local configuredPerLevel = tonumber(skillConfig and skillConfig.moneyPercentPerLevel)
    local perLevelPercent = configuredPerLevel or DEFAULT_MONEY_PERCENT_PER_LEVEL
    local effectiveLevelUps = math.max(0, (tonumber(skillLevel) or 1) - 1)
    return 1 + (effectiveLevelUps * perLevelPercent)
end

-- Operator has a gated Quarry Work lane, so its reward order cannot use the
-- generic round-robin schedule. Levels 2-9 alternate the two available lanes;
-- level 10 is unlock-only, then the normal cycle resumes at level 11.
local operatorRewardLaneCycle = {2, 1, 2, 3, 1, 2, 3, 2, 1, 3}

function M.getOperatorRewardLaneForLevel(unlockedLevel)
    local level = math.floor(tonumber(unlockedLevel) or 0)
    if level < 2 or level >= 50 then return nil end
    if level < 10 then
        return level % 2 == 0 and 1 or 3
    end
    if level == 10 then return nil end
    return operatorRewardLaneCycle[((level - 10) % #operatorRewardLaneCycle) + 1]
end

function M.getOperatorMoneyBonusMultiplier(laneIndex, skillLevel)
    local requestedLane = math.floor(tonumber(laneIndex) or 0)
    if requestedLane < 1 or requestedLane > 3 then return 1 end

    local level = math.max(1, math.min(50, math.floor(tonumber(skillLevel) or 1)))
    local bonus = 0
    for unlockedLevel = 2, math.min(49, level) do
        if M.getOperatorRewardLaneForLevel(unlockedLevel) == requestedLane then
            bonus = bonus + 0.12
        end
    end
    if level >= 50 then
        -- Quarry skips the level-10 bonus, so mastery supplies the missing 12%
        -- in addition to the normal 8% capstone shared by the other lanes.
        bonus = bonus + (requestedLane == 2 and 0.20 or 0.08)
    end
    return 1 + math.min(2, bonus)
end

function M.getMoneyBonusPercent(skillConfig, skillLevel)
    return math.floor((M.getMoneyBonusMultiplier(skillConfig, skillLevel) - 1) * 100 + 0.5)
end

function M.getCivilServiceRewardConfig()
    if civilServiceRewardConfig == nil then
        civilServiceRewardConfig = M.loadRewardConfig(CIVIL_SERVICE_REWARD_CONFIG_PATH)
    end
    return civilServiceRewardConfig
end

function M.getCivilServiceSkillConfig()
    return M.getSkillConfig(M.getCivilServiceRewardConfig())
end

function M.getCivilServiceAttributeKey()
    return M.getAttributeKey(M.getCivilServiceSkillConfig(), CIVIL_SERVICE_ATTRIBUTE_KEY)
end

function M.getCivilServiceSkillLevel()
    return M.getSkillLevel(M.getCivilServiceAttributeKey(), CIVIL_SERVICE_PATH_IDS)
end

function M.getMilestonePayMultiplier(skillConfig, skillLevel)
    local base = tonumber(skillConfig and skillConfig.basePayMultiplier)
    if not base then
        return nil
    end
    local tierBonus = tonumber(skillConfig.milestonePayBonusPerTier) or 0.05
    local interval = tonumber(skillConfig.milestoneInterval) or 5
    local level = math.max(1, math.floor(tonumber(skillLevel) or 1))
    local tiers = math.floor(level / interval)
    return base + (tiers * tierBonus)
end

local DEFAULT_LEGACY_PAY_PER_LEVEL = 0.25
local LEGACY_PAY_MAX_LEVEL = 50

local function getLegacyTargetChildPayMultiplier(skillConfig, skillLevel)
    local targetScale = tonumber(skillConfig and skillConfig.legacyPayTargetScale)
    if not targetScale or targetScale <= 0 then
        return nil
    end
    local perLevel = tonumber(skillConfig.legacyPayPerLevel) or DEFAULT_LEGACY_PAY_PER_LEVEL
    local level = math.min(
        LEGACY_PAY_MAX_LEVEL,
        math.max(0, math.floor(tonumber(skillLevel) or 0))
    )
    local legacyMult = 1 + (level * perLevel)
    local childMult = targetScale * legacyMult
    if skillConfig.legacyPayNetOfParent then
        local parentBonus = M.getMoneyBonusMultiplier(M.getCivilServiceSkillConfig(), M.getCivilServiceSkillLevel())
        if parentBonus > 0 then
            childMult = childMult / parentBonus
        end
    end
    return childMult
end

function M.getChildJobPayMultiplier(skillConfig, skillLevel)
    local legacyChild = getLegacyTargetChildPayMultiplier(skillConfig, skillLevel)
    if legacyChild then
        return legacyChild
    end
    local milestoneChild = M.getMilestonePayMultiplier(skillConfig, skillLevel)
    if milestoneChild then
        return milestoneChild
    end
    return M.getMoneyBonusMultiplier(skillConfig, skillLevel)
end

function M.getJobMoneyBonusMultiplier(childSkillConfig, childSkillLevel)
    return M.getMoneyBonusMultiplier(childSkillConfig, childSkillLevel)
end

function M.getJobMoneyBonusPercent(childSkillConfig, childSkillLevel)
    return math.floor((M.getJobMoneyBonusMultiplier(childSkillConfig, childSkillLevel) - 1) * 100 + 0.5)
end

function M.getPoliceLegacyMoneyBonusMultiplier(policeSkillLevel, policeSkillConfig)
    local perLevel = tonumber(policeSkillConfig and policeSkillConfig.legacyPayPerLevel)
        or tonumber(policeSkillConfig and policeSkillConfig.legacyMoneyBonusPerLevel)
    if not perLevel or perLevel <= 0 then
        perLevel = DEFAULT_LEGACY_PAY_PER_LEVEL
    end
    local level = math.min(
        LEGACY_PAY_MAX_LEVEL,
        math.max(0, math.floor(tonumber(policeSkillLevel) or 0))
    )
    return 1 + (level * perLevel)
end

function M.getPoliceJobMoneyBonusMultiplier(policeSkillLevel, policeSkillConfig)
    return M.getJobMoneyBonusMultiplier(policeSkillConfig, policeSkillLevel)
end

function M.getPoliceJobMoneyBonusPercent(policeSkillLevel, policeSkillConfig)
    return M.getJobMoneyBonusPercent(policeSkillConfig, policeSkillLevel)
end

function M.awardJobSkillXp(childAttributeKey, childSkillConfig, payAmount, reason)
    local xpAmount = M.getSkillRewardAmount(childSkillConfig, payAmount)
    if xpAmount <= 0 then
        return 0
    end
    M.awardSkillXp(childAttributeKey, xpAmount, reason)
    return xpAmount
end

function M.awardFlatJobSkillXp(childAttributeKey, xpAmount, reason)
    if not xpAmount or xpAmount <= 0 then
        return 0
    end
    if not career_career or not career_career.isActive() then
        return 0
    end
    if not career_modules_payment or not career_modules_payment.reward then
        return 0
    end

    local rewardData = {}
    M.addJobSkillXpToRewardData(rewardData, childAttributeKey, xpAmount)
    if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
        career_modules_difficultyMode.scalePaymentRewardData(rewardData, { includeMoney = false })
    end
    local awarded = (rewardData[childAttributeKey] and rewardData[childAttributeKey].amount) or 0
    if awarded > 0 then
        career_modules_payment.reward(rewardData, reason or {}, true)
    end
    return awarded
end

function M.isLoanerVehicle(vehId)
    if not vehId or not career_modules_loanerVehicles or not career_modules_loanerVehicles.getLoaningOrgsOfVehicle then
        return false
    end
    local loaningOrgs = career_modules_loanerVehicles.getLoaningOrgsOfVehicle(vehId)
    return loaningOrgs ~= nil and next(loaningOrgs) ~= nil
end

function M.isPlayerOwnedInventoryVehicle(vehId)
    if not vehId or not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
        return false
    end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    if not inventoryId or not career_modules_inventory.getVehicles then
        return false
    end
    local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
    return vehInfo ~= nil and vehInfo.owned == true
end

function M.addJobSkillXpToRewardData(rewardData, childAttributeKey, xpAmount)
    if not rewardData or not xpAmount or xpAmount <= 0 then
        return 0
    end
    local childEntry = rewardData[childAttributeKey]
    local childTotal = (childEntry and tonumber(childEntry.amount)) or 0
    rewardData[childAttributeKey] = { amount = childTotal + xpAmount }
    return xpAmount
end

function M.getSkillRewardAmount(skillConfig, baseAmount)
    local xpConfig = (skillConfig and skillConfig.xpReward) or {}
    local mode = xpConfig.mode or "money"
    local multiplier = tonumber(xpConfig.multiplier) or 1.0
    local minimum = tonumber(xpConfig.minimum) or 1
    local baseValue = 0

    if mode == "money" then
        baseValue = tonumber(baseAmount) or 0
    elseif mode == "reputationScale" then
        local divisor = tonumber(xpConfig.divisor) or 1
        if divisor > 0 then
            baseValue = (tonumber(baseAmount) or 0) / divisor
        end
    end

    local rewardAmount = baseValue * multiplier
    local rounding = xpConfig.rounding or "floor"
    if rounding == "round" then
        rewardAmount = math.floor(rewardAmount + 0.5)
    else
        rewardAmount = math.floor(rewardAmount)
    end

    return math.max(minimum, rewardAmount)
end

function M.awardSkillXp(attributeKey, amount, reason)
    if not amount or amount <= 0 then
        return 0
    end
    if not career_career or not career_career.isActive() then
        return 0
    end
    if not career_modules_payment or not career_modules_payment.reward then
        return 0
    end

    local rewardData = {}
    rewardData[attributeKey] = { amount = amount }
    if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
        career_modules_difficultyMode.scalePaymentRewardData(rewardData, { includeMoney = false })
    end
    local awarded = (rewardData[attributeKey] and rewardData[attributeKey].amount) or amount
    if awarded > 0 then
        career_modules_payment.reward(rewardData, reason or {}, true)
    end
    return awarded
end

return M
