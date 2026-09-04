-- Shared delivery calculation functions
-- Extracted from career/modules/delivery/generator.lua
-- These are pure functions that do NOT require career mode to be active.

local M = {}
local xpConfig = require('gameplay/delivery/logisticsXPConfig')

local legacyHardcoreMultiplier = 1

local function getProgressionMultiplier()
  if career_modules_difficultyMode and career_modules_difficultyMode.getXPMultiplierForKey then
    return career_modules_difficultyMode.getXPMultiplierForKey("logistics-delivery")
  end
  if career_modules_difficultyMode and career_modules_difficultyMode.getXPMultiplier then
    return career_modules_difficultyMode.getXPMultiplier()
  end
  return legacyHardcoreMultiplier
end

local parcelItemMoneyMultiplier = 1
local parcelHandlingRewardPerSlot = 1.15
local parcelDistanceRewardMultiplier = 1.075

-- A dry van carries 32 128-slot freight boxes. These payload bounds are cargo
-- mass only and correspond to 30,000-40,000 lb across all 4,096 slots.
local PARCEL_FREIGHT_SLOT_CAPACITY = 32 * 128
local PARCEL_FREIGHT_MIN_PAYLOAD_KG = 30000 * 0.45359237
local PARCEL_FREIGHT_MAX_PAYLOAD_KG = 40000 * 0.45359237
local PARCEL_FREIGHT_MIN_KG_PER_SLOT = PARCEL_FREIGHT_MIN_PAYLOAD_KG / PARCEL_FREIGHT_SLOT_CAPACITY
local PARCEL_FREIGHT_MAX_KG_PER_SLOT = PARCEL_FREIGHT_MAX_PAYLOAD_KG / PARCEL_FREIGHT_SLOT_CAPACITY

local TRAILER_XP_GROUP_BY_TAG = {
  emptySmallTrailers = "small",
  loadedSmallTrailers = "small",
  trailerBoxutility = "small",
  trailerBoxutilityLarge = "small",
  trailerTsfb = "small",
  trailerCaravan = "small",
  emptyMediumTrailers = "medium",
  loadedMediumTrailers = "medium",
  trailerCargotrailer = "medium",
  trailerTiltdeck = "medium",
  trailerHeavyHitch = "heavyHitch",
  trailerDolly = "dryvan",
  trailerDryvan = "dryvan",
  emptyLargeTrailer = "flatbed",
  loadedLargeTrailers = "flatbed",
  trailerFlatbed = "flatbed",
  trailerFramelessDump = "flatbed",
  trailerTanker = "tanker",
  trailerContainer = "container",
  trailerLogTrailer = "log"
}

local TRAILER_XP_LEVEL_BY_GROUP = {
  small = 1,
  medium = 6,
  heavyHitch = 14,
  dryvan = 25,
  flatbed = 30,
  tanker = 35,
  container = 37,
  log = 40
}

local VEHICLE_XP_TAGS = {
  junkerVeh = true,
  smallVeh = true,
  fleetVeh = true,
  highEndVeh = true,
  exoticVeh = true,
  heavyVeh = true,
  largeVeh = true
}

local function applyMoneyRounding(value)
  return xpConfig.applyRounding(value, xpConfig.getConfig().rounding.moneyFinal)
end

local function getVehicleBaseXP(rules, filter)
  if type(rules.vehicleXPByTag) ~= "table" or not filter or not filter.unlockTag then
    return rules.baseXP
  end

  local tag = filter.unlockTag
  if not VEHICLE_XP_TAGS[tag] then
    return rules.baseXP
  end

  local tagXP = rules.vehicleXPByTag[tag]
  if type(tagXP) == "number" then
    return tagXP
  end

  return rules.baseXP
end

local function getTrailerBaseXP(rules, filter)
  if not filter or not filter.unlockTag then
    return rules.baseXP
  end

  local unlockGroup = TRAILER_XP_GROUP_BY_TAG[filter.unlockTag]
  if not unlockGroup then
    return rules.baseXP
  end

  if type(rules.trailerXPByUnlockGroup) == "table" then
    local groupXP = rules.trailerXPByUnlockGroup[unlockGroup]
    if type(groupXP) == "number" then
      return groupXP
    end
  end

  if type(rules.trailerXPByUnlockLevel) == "table" then
    local unlockLevel = TRAILER_XP_LEVEL_BY_GROUP[unlockGroup]
    local levelXP = rules.trailerXPByUnlockLevel[tostring(unlockLevel)]
    if type(levelXP) == "number" then
      return levelXP
    end
  end

  return rules.baseXP
end

local function getTrailerMoneyMultiplier(rules, filter)
  if not filter or not filter.unlockTag then
    return 1
  end

  local unlockGroup = TRAILER_XP_GROUP_BY_TAG[filter.unlockTag]
  local multipliers = rules.trailerMoneyMultiplierByUnlockGroup
  if not unlockGroup or type(multipliers) ~= "table" then
    return 1
  end

  local multiplier = multipliers[unlockGroup]
  return type(multiplier) == "number" and multiplier or 1
end

local function getMaterialBaseXP(rules, materialType)
  if type(rules.baseXPByType) ~= "table" or type(materialType) ~= "string" then
    return rules.baseXP
  end

  local overrideXP = rules.baseXPByType[materialType]
  if type(overrideXP) == "number" then
    return overrideXP
  end

  return rules.baseXP
end

local function getParcelBaseXP(slots)
  local rules = xpConfig.getParcelRules()

  if type(rules.slotXPBySize) == "table" and #rules.slotXPBySize > 0 then
    local tierXP = rules.baseXP
    for _, tier in ipairs(rules.slotXPBySize) do
      if slots >= tier.slots then
        tierXP = tier.xp
      else
        break
      end
    end
    return tierXP, rules
  end

  local baseXP = rules.baseXP
  for _, threshold in ipairs(rules.slotMilestones) do
    if slots >= threshold then
      baseXP = baseXP + 1
    end
  end
  return baseXP, rules
end

local function getParcelDistanceXP(distance, baseXP, rules)
  local distanceTerm = xpConfig.applyRounding(distance / rules.distanceDivisor, rules.distanceRounding)
  return (baseXP + distanceTerm) * getProgressionMultiplier()
end

function M.setHardcoreMultiplier(val)
  legacyHardcoreMultiplier = val or 1
end

function M.getHardcoreMultiplier()
  return legacyHardcoreMultiplier
end

function M.setParcelItemMoneyMultiplier(val)
  parcelItemMoneyMultiplier = val or 1
end

-------------------------------
-- Parcel Money Reward
-------------------------------
local function getParcelRewardWeight(item)
  -- This is an economic calibration value inherited from the old templates.
  -- Never fall back to physical item.weight: vehicle mass must not affect pay.
  return math.max(0, tonumber(item.data and item.data.rewardWeight) or 0)
end

local function getParcelWeightRate(rewardWeight)
  if rewardWeight <= 10 then
    return math.pow(rewardWeight, 0.9)
  end
  return math.pow(10, 0.9) + 4.7 * math.log(1 + (rewardWeight - 10) / 10)
end

-- Returns physical kilograms for a generated parcel. Lightweight cargo keeps
-- its authored mass; freight scales by slots so 32 128-slot boxes total
-- 30,000-40,000 lb. The seed makes save migration stable and repeatable.
function M.getPhysicalWeightForParcel(template, slots, authoredWeight, seed)
  local slotCount = math.max(0, tonumber(slots) or 0)
  local physicalWeightClass = template and template.physicalWeightClass
  if not physicalWeightClass then
    local isPost = template and template.modChance and (tonumber(template.modChance.post) or 0) > 0
    -- Expansion maps predate physicalWeightClass. Treat their 128-slot boxes as
    -- freight by default, but never turn authored postal cargo into freight.
    physicalWeightClass = slotCount >= 128 and not isPost and "freight" or "light"
  end
  if physicalWeightClass ~= "freight" then
    return math.max(0, tonumber(authoredWeight) or 0)
  end

  local stableSeed = math.abs(math.floor(tonumber(seed) or 0))
  local densityFraction = (stableSeed % 10000) / 9999
  local kgPerSlot = PARCEL_FREIGHT_MIN_KG_PER_SLOT
    + (PARCEL_FREIGHT_MAX_KG_PER_SLOT - PARCEL_FREIGHT_MIN_KG_PER_SLOT) * densityFraction
  return slotCount * kgPerSlot
end

function M.getMoneyRewardForParcelItem(item, distance)
  local slots = math.max(1, tonumber(item.slots) or 1)
  local distanceKm = math.max(0, tonumber(distance) or 0) / 1000
  local rewardWeight = getParcelRewardWeight(item)
  local slotRate = math.pow(3, 0.30 + math.sqrt(slots) / 100)
  local minimumReward = 10 + 2 * math.sqrt(slots)
  local handlingReward = slots * parcelHandlingRewardPerSlot
  local rewardPerKm = slotRate * (5 + getParcelWeightRate(rewardWeight)) * parcelDistanceRewardMultiplier
  local baseReward = math.max(minimumReward, handlingReward + distanceKm * rewardPerKm)
  local modMultiplier = 1
  for _, mod in ipairs(item.modifiers or {}) do
    modMultiplier = modMultiplier * (mod.moneyMultipler or 1)
  end

  item.data = item.data or {}
  item.data.rewardFormulaVersion = 4

  return baseReward * parcelItemMoneyMultiplier * modMultiplier, minimumReward, rewardPerKm
end

-------------------------------
-- Parcel XP Reward
-------------------------------
-- Exact copy from finalizeParcelItemDistanceAndRewards ~line 160
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   orgMultiplier: override for org delivery bonus money multiplier
--   economyMultiplier: override for economy adjuster multiplier
function M.getXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local rewards = {
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    -- Try to get org delivery bonus multiplier
    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier then
      rewards.moneyMultiplier = appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 182)
  if economyMultiplier then
    rewards.economyMultiplier = economyMultiplier
  elseif career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    rewards.economyMultiplier = career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end

  return rewards
end

-------------------------------
-- Parcel Full Reward
-------------------------------
-- Combines money + XP + org + economy into a complete rewards table.
-- This mirrors the full finalizeParcelItemDistanceAndRewards from generator.lua.
function M.getParcelReward(item, distance, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(item.slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local money = M.getMoneyRewardForParcelItem(item, distance)

  local rewards = {
    money = money,
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier then
      rewards.money = rewards.money * appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 182)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    ecoMult = career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end
  if ecoMult then
    if type(rewards.economyBaseMoney) ~= "number" then
      rewards.economyBaseMoney = rewards.money
    end
    rewards.money = applyMoneyRounding(rewards.economyBaseMoney * ecoMult)
    rewards.economyMultiplier = ecoMult
  else
    rewards.economyMultiplier = 1
  end

  return rewards
end

-------------------------------
-- Vehicle/Trailer Offer Reward
-------------------------------
-- Exact copy from finalizeVehicleOffer ~line 425
-- filter must have .baseReward and .rewardPerKm fields
-- offerType is "vehicle" or "trailer"
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   economyMultiplier: override for economy adjuster multiplier
function M.getVehicleOfferReward(filter, distance, offerType, orgId, economyMultiplier)
  local rules = xpConfig.getVehicleRules()
  local moneyDistanceTerm = xpConfig.applyRounding((filter.rewardPerKm or 0) * distance / rules.moneyDistanceDivisor, rules.moneyDistanceRounding)
  local xpDistanceTerm = xpConfig.applyRounding(distance / rules.xpDistanceDivisor, rules.xpDistanceRounding)
  local deliveryBaseXP = rules.baseXP
  local trailerMoneyMultiplier = 1
  if offerType == "trailer" then
    deliveryBaseXP = getTrailerBaseXP(rules, filter)
    trailerMoneyMultiplier = getTrailerMoneyMultiplier(rules, filter)
  elseif offerType == "vehicle" then
    deliveryBaseXP = getVehicleBaseXP(rules, filter)
  end
  local baseXP = deliveryBaseXP + xpDistanceTerm
  local rewards = {
    money = applyMoneyRounding(((filter.baseReward or 0) + moneyDistanceTerm) * trailerMoneyMultiplier),
    logistics = baseXP * getProgressionMultiplier()
  }
  if offerType == "vehicle" then
    rewards["logistics-delivery"] = baseXP * getProgressionMultiplier()
  elseif offerType == "trailer" then
    rewards["logistics-delivery"] = baseXP * getProgressionMultiplier()
  end

  -- Organization reputation (from generator.lua ~line 556)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (deliveryBaseXP + repDistance) * getProgressionMultiplier()
  end

  -- Economy adjuster (from generator.lua ~line 559)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = offerType == "vehicle" and "delivery_vehicle" or "delivery_trailer"
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult then
    if type(rewards.economyBaseMoney) ~= "number" then
      rewards.economyBaseMoney = rewards.money
    end
    rewards.money = applyMoneyRounding(rewards.economyBaseMoney * ecoMult)
    rewards.economyMultiplier = ecoMult
  else
    rewards.economyMultiplier = 1
  end

  return rewards
end

-------------------------------
-- Material Reward (bulk material batch)
-------------------------------
function M.getMaterialMoneyPerKg(materialData)
  if not materialData then return 0 end
  if materialData.moneyPerKg ~= nil then
    return tonumber(materialData.moneyPerKg) or 0
  end
  local density = tonumber(materialData.density) or 0
  if density <= 0 then return 0 end
  return (tonumber(materialData.money) or 0) / density
end

-- Distances are in metres. Nil keeps the neutral factor used by source cards
-- before the player chooses a destination. Explicit routes scale linearly so
-- every additional kilometre changes the payout.
function M.getMaterialRouteFactor(distance)
  if distance == nil then return 1 end
  local rules = xpConfig.getMaterialRules()
  local routeKm = math.max(0, (tonumber(distance) or 0) / 1000)
  return rules.moneyBaseFactor + rules.moneyFactorPerKm * routeKm
end

function M.getMaterialReward(materialData, amount, distance)
  local density = tonumber(materialData and materialData.density) or 0
  local cargoAmount = math.max(0, tonumber(amount) or 0)
  local baseReward = cargoAmount * density * M.getMaterialMoneyPerKg(materialData)
  return {
    money = baseReward * M.getMaterialRouteFactor(distance),
  }
end

-------------------------------
-- Material Distance XP Reward
-------------------------------
-- Exact copy from finalizeMaterialDistanceRewards ~line 605
-- (3+(max(0,($D24/2000)-1))) * (E$23/400)
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   orgMultiplier: override for org delivery bonus money multiplier
--   economyMultiplier: override for economy adjuster multiplier
--   moneyReward: base money reward to apply org/economy multipliers to
--   materialType: material type string for economy adjuster section key (e.g. "fluid", "dryBulk")
function M.getMaterialXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier, moneyReward, materialType)
  local rules = xpConfig.getMaterialRules()
  local materialBaseXP = getMaterialBaseXP(rules, materialType)
  local xpFormula = (materialBaseXP + math.max(0, (distance / rules.distanceDivisor) + rules.distanceOffset)) * (slots / rules.slotsDivisor)
  local xpAmount = xpConfig.applyRounding(xpFormula, rules.xpRounding) * getProgressionMultiplier()
  local rewards = {
    logistics = xpAmount,
    ["logistics-delivery"] = xpAmount
  }

  local money = moneyReward and moneyReward * M.getMaterialRouteFactor(distance) or nil

  -- Organization reputation and delivery bonus (from generator.lua ~line 1082)
  if orgId then
    rewards[orgId .. "Reputation"] = xpAmount

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier and money then
      money = money * appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 1091)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = "delivery_" .. (materialType or "fluid")
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult and money then
    money = money * ecoMult
  end

  if money then
    rewards.money = applyMoneyRounding(money)
  end
  rewards.economyMultiplier = ecoMult or 1

  return rewards
end

-------------------------------
-- Hardcore Multiplier
-------------------------------
function M.applyHardcoreMultiplier(reward, multiplier)
  return reward * (multiplier or getProgressionMultiplier())
end

-------------------------------
-- Economy Adjuster (safe)
-------------------------------
-- Safely checks if career_economyAdjuster exists before using it.
-- Falls back to returning the reward unchanged.
-- Returns: adjustedReward, economyMultiplier
function M.applyEconomyAdjuster(reward, sectionKey)
  local multiplier = 1
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    multiplier = career_economyAdjuster.getSectionMultiplier(sectionKey) or 1
    reward = reward * multiplier
    reward = applyMoneyRounding(reward)
  end
  return reward, multiplier
end

-- Re-apply a new economy multiplier onto an already-baked rewards table.
-- Persists unrounded pre-multiplier money in economyBaseMoney on first rebake.
-- Returns true if money changed.
function M.rebakeRewardEconomy(rewards, newMult)
  if type(rewards) ~= "table" or type(rewards.money) ~= "number" then return false end
  local oldMult = tonumber(rewards.economyMultiplier) or 1
  if oldMult < 1e-6 then oldMult = 1 end
  newMult = tonumber(newMult) or 1
  if type(rewards.economyBaseMoney) ~= "number" then
    rewards.economyBaseMoney = rewards.money / oldMult
  end
  if math.abs(oldMult - newMult) < 1e-6 then
    rewards.economyMultiplier = newMult
    return false
  end
  rewards.money = applyMoneyRounding(rewards.economyBaseMoney * newMult)
  rewards.economyMultiplier = newMult
  return true
end

return M
