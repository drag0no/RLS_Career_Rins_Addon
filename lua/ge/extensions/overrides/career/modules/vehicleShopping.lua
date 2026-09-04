-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies =
  {'career_career', 'career_modules_inspectVehicle', 'career_modules_valueCalculator', 'util_configListGenerator',
   'freeroam_organizations', 'career_modules_bank', 'career_modules_business_businessInventory'}

local moduleVersion = 69
local valuationSchemaVersion = 12
M.limitedMileageDealerSchemaVersion = 1

-- Configuration constants
local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 10 * 60
local timeToRemoveSoldVehicle = 5 * 60
local dealershipTimeBetweenOffers = 1 * 60
local vehiclesPerDealership = vehicleOfferTimeToLive / dealershipTimeBetweenOffers
local salesTax = 0.07
local customLicensePlatePrice = 300
local dealershipPurchaseReputationGain = 2000
local missingYearsFallbackModelYear = 2023
local refreshInterval = 5
local tetherRange = 4
local POLICE_DEALERSHIP_UNLOCK_LEVEL = 10
local POLICE_DEALERSHIP_IDS = {
  policeDealership = true,
  poliziaAuto = true
}
local MILES_TO_METERS = 1609.344
local BASE_ANNUAL_MILES = 11500
local MAX_USED_MILES = 300000
local FACTORY_MIN_MILES = 5
local FACTORY_MAX_MILES = 500
local REMOTE_PURCHASE_LEVEL = 2
local DELIVERY_DISCOUNT_LEVEL = 3
local DELIVERY_DISCOUNT_AT_LEVEL_3 = 0.25

-- Mileage is generated from exact age first, then shaped by the seller.  These
-- profiles are intentionally independent from the catalog filters: filters
-- decide what can be stocked while profiles decide what a plausible example
-- of that vehicle looks like.
local mileageProfiles = {
  fastAutomotiveDealership = {annualMiles = 2500, minFactor = 0.5, maxFactor = 1.4, minMiles = 2000, maxMiles = 40000, wearFactor = 3.0},
  jeffersonmotors = {minFactor = 0.28, maxFactor = 0.62, minMiles = 18000, maxMiles = 130000, timeCapsuleChance = 0.05},
  belascoAuto = {minFactor = 0.70, maxFactor = 1.05, minMiles = 250, maxMiles = 220000},
  richsmotorcompany = {minFactor = 0.22, maxFactor = 0.60, minMiles = 1000, maxMiles = 80000, timeCapsuleChance = 0.05},
  quarrysideAutoSales = {minFactor = 1.00, maxFactor = 1.45, minMiles = 60000, maxMiles = 280000},
  discountedDealership = {minFactor = 1.15, maxFactor = 1.75, minMiles = 70000, maxMiles = 350000},
  policeDealership = {annualMiles = 18000, minFactor = 0.85, maxFactor = 1.25, minMiles = 60000, maxMiles = 180000},
  serviceDealership = {annualMiles = 17000, minFactor = 0.85, maxFactor = 1.30, minMiles = 50000, maxMiles = 200000},
  frameDealership = {minFactor = 1.05, maxFactor = 1.65, minMiles = 90000, maxMiles = 320000},
  trailerShop = {annualMiles = 7000, minFactor = 0.65, maxFactor = 1.25, minMiles = 10000, maxMiles = 150000},
  truckShop = {annualMiles = 30000, minFactor = 0.85, maxFactor = 1.35, minMiles = 80000, maxMiles = 600000},
  importDealer = {minFactor = 0.75, maxFactor = 1.20, minMiles = 10000, maxMiles = 300000},
  loanerDealership = {annualMiles = 18000, minFactor = 0.95, maxFactor = 1.35, minMiles = 80000, maxMiles = 240000},
  joesJunkDealership = {minFactor = 1.35, maxFactor = 2.05, minMiles = 120000, maxMiles = 400000},
  raceTab = {annualMiles = 2500, minFactor = 0.50, maxFactor = 1.00, minMiles = 10000, maxMiles = 40000},
  asotv = {annualMiles = 2500, minFactor = 0.50, maxFactor = 1.00, minMiles = 10000, maxMiles = 40000},
  private = {minFactor = 0.75, maxFactor = 1.55, minMiles = 500, maxMiles = 350000, timeCapsuleChance = 0.015}
}
local POLICE_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"}

-- Module state
local vehicleShopDirtyDate
local vehiclesInShop = {}
local sellersInfos = {}
local otherMapsData = {}
local discoveredDealers = {}
local lastMap
local currentSeller
local purchaseData
local tether
local rtBizId
local vehicleWatchlist = {}
local currentUiState
local selectedSellerId
local shoppingScreenTag
local buyingAvailable = true
local marketplaceAvailable = true
local getSellerAccessInfo
local isDealerDiscovered

-- Delta tracking system
local lastSnapshotByShopId = {}
local lastDelta = {
  seq = 0,
  added = {},
  removed = {},
  sold = {},
  updated = {}
}
local deltaSeq = 0
local pendingSoldShopIds = {}
local soldVehicles = {}
local uiOpen = false
local shoppingUiOpenCount = 0
local refreshAccumulator = 0
local nextShopUpdateTime = 0
local rtPendingFleetPurchases = {}
local rtPendingFleetProcessing = false
local rtPendingTimerFailureGraceSec = 20
local rtPendingDriveStaleSec = 20 * 60

-- Vehicle cache system
local vehicleCache = {
  regularVehicles = {},
  dealershipCache = {},
  lastCacheTime = 0,
  cacheValid = false
}

local badConfigQuarantine = {}
local badConfigLogOnce = {}
local validationStats = {
  quarantined = 0,
  loadDropped = 0,
  cacheDropped = 0,
  generationDropped = 0
}

-- State tracking
local purchaseMenuOpen = false
local inspectingVehicleShopId = nil

-- Utility functions
local function generateShopId()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    local found = false
    for _, vehInfo in ipairs(vehiclesInShop) do
      if vehInfo.shopId == shopId then
        found = true
        break
      end
    end
    if not found then
      return shopId
    end
  end
end

local function getBranchLevelByPathIds(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

local function getPoliceSkillLevel()
  local level = getBranchLevelByPathIds(POLICE_SKILL_PATH_IDS)
  if level > 0 then
    return level
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber(career_modules_playerAttributes.getAttributeValue("careerSkills-emergency")) or 0
    for _, skillPathId in ipairs(POLICE_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      level = math.max(level, tonumber(branchLevel) or 0)
    end
  end

  return math.max(0, math.floor(level))
end

local function isPoliceDealershipLocked(dealershipId)
  return POLICE_DEALERSHIP_IDS[dealershipId] and getPoliceSkillLevel() < POLICE_DEALERSHIP_UNLOCK_LEVEL or false
end

local function getPoliceDealershipLockLabel()
  return string.format("Police Dealership requires Police Skill level %d", POLICE_DEALERSHIP_UNLOCK_LEVEL)
end

local function getVehicleInfoByShopId(shopId)
  if not shopId then
    return nil
  end
  local numShopId = tonumber(shopId)
  if not numShopId then
    log("W", "Career", "getVehicleInfoByShopId: Invalid shopId type: " .. tostring(shopId))
    return nil
  end
  for _, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == numShopId then
      return vehInfo
    end
  end
  return nil
end

local function isCarMeetShopVehicle(vehicleInfo)
  return vehicleInfo and (vehicleInfo.source == "carMeet" or vehicleInfo.sellerId == "carMeet")
end

local function normalizeVehicleShopTiming(vehicleInfo, currentTime)
  if not vehicleInfo then return end
  currentTime = currentTime or os.time()
  vehicleInfo.generationTime = tonumber(vehicleInfo.generationTime) or currentTime
  vehicleInfo.offerTTL = tonumber(vehicleInfo.offerTTL) or (24 * 60 * 60)
end

local getRoundedPrice

local function registerCarMeetVehicle(vehicleInfo)
  if not vehicleInfo then return nil end
  local info = deepcopy(vehicleInfo)
  info.shopId = info.shopId or generateShopId()
  info.sellerId = "carMeet"
  info.sellerName = info.sellerName or "Car Meet Owner"
  info.negotiationPossible = true
  info.playerStartsNegotiation = true
  info.hideMarketValue = true
  info.tax = tonumber(info.tax) or 0
  info.fees = tonumber(info.fees) or 0
  info.Value = tonumber(info.Value) or tonumber(info.marketValue) or 10000
  info.marketValue = tonumber(info.marketValue) or info.Value
  info.marketValueBase = info.marketValue
  info.Mileage = tonumber(info.Mileage) or 0
  info.mapId = getCurrentLevelIdentifier()
  normalizeVehicleShopTiming(info)
  if career_modules_marketplace and career_modules_marketplace.generatePersonality then
    info.negotiationPersonality = info.negotiationPersonality or career_modules_marketplace.generatePersonality(false)
    if info.negotiationPersonality and info.negotiationPersonality.name then
      info.sellerName = info.negotiationPersonality.name
    end
  end
  local priceMultiplier = (info.negotiationPersonality and info.negotiationPersonality.priceMultiplier) or 1
  priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
  info.priceMultiplier = priceMultiplier
  info.valueBase = tonumber(info.valueBase) or info.marketValue * priceMultiplier
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  info.Value = getRoundedPrice(info.valueBase * vehicleBuyMult, info.priceRoundingType or "private")
  table.insert(vehiclesInShop, info)
  return info.shopId
end

local function removeCarMeetVehicles()
  for i = #vehiclesInShop, 1, -1 do
    if vehiclesInShop[i].sellerId == "carMeet" or vehiclesInShop[i].source == "carMeet" then
      table.remove(vehiclesInShop, i)
    end
  end
end

local function generateSoldVehicleValue(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return 0 end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

getRoundedPrice = function(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    return math.ceil(value / 20) * 20
  else
    return math.ceil(value / 10) * 10
  end
end

local function getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

local privateSellersPreview = "/levels/west_coast_usa/facilities/privateSeller_dealership.jpg"
local TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID = "apmStarterVehicles"
local function getUiDealershipsData(unsoldVehicles)
  local dealerships = freeroam_facilities.getFacilitiesByType("dealership")
  local isInTutorial = career_modules_tutorial and career_modules_tutorial.isActive()
    and career_modules_tutorial.getCurrentStep() == "09spmSignup"
  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    if not isCarMeetShopVehicle(vehicle) then
      vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
    end
  end
  local data = {}
  if dealerships then
    for _, dealership in ipairs(dealerships) do
      local policeLocked = isPoliceDealershipLocked(dealership.id)
      local tutorialLocked = isInTutorial and dealership.id ~= TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID
      local discovered = isDealerDiscovered(dealership)
      local accessInfo = getSellerAccessInfo(dealership)
      table.insert(data, {
        id = dealership.id,
        name = _tr(dealership.name),
        description = _tr(dealership.description),
        vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
        preview = dealership.preview,
        icon = "carDealer",
        remotePurchaseOnly = dealership.remotePurchaseOnly or false,
        hiddenFromDealerList = dealership.hiddenFromDealerList or not discovered,
        undiscovered = not discovered,
        salesChannel = accessInfo.salesChannel,
        remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
        garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
        deliveryDiscount = accessInfo.deliveryDiscount,
        disabled = policeLocked or tutorialLocked,
        disabledReason = policeLocked and getPoliceDealershipLockLabel()
          or (tutorialLocked and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil),
      })
    end
  end
  table.sort(data, function(a,b) return a.name < b.name end)
  table.insert(data, {
    id = "private",
    name = _tr("ui.career.vehicleShopping.privateSellers"),
    vehicleCount = vehicleCountPerDealership["private"] or 0,
    preview = privateSellersPreview,
    icon = "personSolid",
    disabled = isInTutorial,
    disabledReason = isInTutorial and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil,
  })
  return data
end

local function sanitizeVehicleForUi(v)
  local t = {}
  t.shopId = v.shopId

  for k, val in pairs(v) do
    local ty = type(val)
    if k == "pos" then
      if val and val.x then
        t.pos = {
          x = val.x,
          y = val.y,
          z = val.z
        }
      end
    elseif k == "precomputedFilter" or k == "filter" or k == "distanceVec" then
    elseif ty == "function" or ty == "userdata" then
    else
      t[k] = val
    end
  end
  return t
end

local function convertKeysToStrings(t)
  local unsoldVehicles = {}
  local soldVehiclesResult = {}
  for k, v in ipairs(t) do
    if v.soldViewCounter and v.soldViewCounter > 0 then
      table.insert(soldVehiclesResult, v)
    else
      table.insert(unsoldVehicles, v)
    end
  end
  return unsoldVehicles, soldVehiclesResult
end

local function sanitizeOrganizationForUi(org)
  if not org then
    return nil
  end

  local sanitizedOrg = {
    reputationLevels = {},
    reputation = {}
  }

  if org.reputation then
    local repLevel = org.reputation.level or 0
    if type(repLevel) ~= "number" then
      repLevel = 0
    end
    repLevel = math.max(0, repLevel)
    sanitizedOrg.reputation.level = repLevel
    sanitizedOrg.reputation.levelIndex = repLevel + 2
    sanitizedOrg.reputation.value = org.reputation.value
    sanitizedOrg.reputation.curLvlProgress = org.reputation.curLvlProgress
    sanitizedOrg.reputation.neededForNext = org.reputation.neededForNext
    sanitizedOrg.reputation.prevThreshold = org.reputation.prevThreshold
    sanitizedOrg.reputation.nextThreshold = org.reputation.nextThreshold
  else
    sanitizedOrg.reputation.level = 0
    sanitizedOrg.reputation.levelIndex = 2
  end

  if org.reputationLevels then
    for idx, lvl in pairs(org.reputationLevels) do
      sanitizedOrg.reputationLevels[idx] = {
        hiddenFromDealerList = lvl and lvl.hiddenFromDealerList or nil
      }
    end
  end

  return sanitizedOrg
end

local function collectOrganizationsForUi(facilities)
  local organizations = {}
  if not facilities or not facilities.dealerships then
    return organizations
  end

  local organizationsById = freeroam_organizations.getOrganizations()
  for _, dealer in ipairs(facilities.dealerships) do
    local orgId = dealer.associatedOrganization
    if orgId and not organizations[orgId] then
      local org = organizationsById and organizationsById[orgId]
      local sanitizedOrg = sanitizeOrganizationForUi(org)
      if sanitizedOrg then
        organizations[orgId] = sanitizedOrg
      end
    end
  end

  return organizations
end

local function getVisualValueFromMileage(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

local function getDeliveryDelay(distance)
  distance = math.max(0, tonumber(distance) or 0)
  return clamp(vehicleDeliveryDelay + math.floor((distance / 1000) * 10 + 0.5), vehicleDeliveryDelay, 600)
end

local function getSellerReputationLevel(dealership)
  if not dealership or not dealership.associatedOrganization then return 0 end
  local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
  local level = org and org.reputation and tonumber(org.reputation.level) or 0
  return math.max(0, math.floor(level or 0))
end

getSellerAccessInfo = function(dealership)
  dealership = dealership or {}
  local salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory" or "local")
  local repLevel = getSellerReputationLevel(dealership)
  local isOnline = salesChannel == "factory" or salesChannel == "remanufactured"
  local remotePurchaseAllowed = isOnline or repLevel >= (tonumber(dealership.remotePurchaseLevel) or REMOTE_PURCHASE_LEVEL)
  local garageDeliveryAllowed = repLevel >= (tonumber(dealership.garageDeliveryLevel) or REMOTE_PURCHASE_LEVEL)
  local discount = 0
  if type(dealership.deliveryDiscounts) == "table" then
    for requiredLevel, configuredDiscount in pairs(dealership.deliveryDiscounts) do
      if repLevel >= (tonumber(requiredLevel) or math.huge) then
        discount = math.max(discount, tonumber(configuredDiscount) or 0)
      end
    end
  elseif repLevel >= (tonumber(dealership.deliveryDiscountLevel) or DELIVERY_DISCOUNT_LEVEL) then
    discount = tonumber(dealership.deliveryDiscount) or DELIVERY_DISCOUNT_AT_LEVEL_3
  end
  return {
    salesChannel = salesChannel,
    reputationLevel = repLevel,
    isOnline = isOnline,
    remotePurchaseAllowed = remotePurchaseAllowed,
    garageDeliveryAllowed = garageDeliveryAllowed,
    deliveryDiscount = clamp(discount, 0, 0.95)
  }
end

local function getExpectedMileageMiles(age, annualMiles)
  age = math.max(0, tonumber(age) or 0)
  annualMiles = tonumber(annualMiles) or BASE_ANNUAL_MILES
  if age <= 25 then
    return age * annualMiles
  end
  -- Survivors accumulate much more slowly after 25 years. This avoids turning
  -- every classic into a 400k-mile car while preserving a broad driver market.
  return 25 * annualMiles + (age - 25) * math.min(annualMiles, 2500)
end

local function generateAgeDrivenMileage(seller, vehicleInfo, year)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local age = math.max(0, currentYear - (tonumber(year) or currentYear))
  local channel = seller.salesChannel or "local"

  if channel == "factory" then
    return (FACTORY_MIN_MILES + math.random() * (FACTORY_MAX_MILES - FACTORY_MIN_MILES)) * MILES_TO_METERS,
      nil, "factoryDelivery"
  end

  if channel == "remanufactured" then
    local commercial = seller.remanCommercial == true
    local minMiles = commercial and 60000 or 20000
    local maxMiles = commercial and 180000 or 80000
    return (minMiles + randomGauss3() / 3 * (maxMiles - minMiles)) * MILES_TO_METERS,
      nil, commercial and "commercialReman" or "certifiedReman"
  end

  local profile = mileageProfiles[seller.id] or {}
  local configType = tostring(vehicleInfo["Config Type"] or "")
  local bodyStyle = tostring(vehicleInfo["Body Style"] or "")
  if configType == "Race" or configType == "Rally" then
    profile = mileageProfiles.fastAutomotiveDealership
  elseif configType == "Frame" then
    profile = mileageProfiles.frameDealership
  elseif bodyStyle == "Semi Truck" or bodyStyle == "Tanker Truck" or bodyStyle == "Dump Truck" then
    profile = mileageProfiles.truckShop
  end

  if age >= 25 and math.random() < (tonumber(profile.timeCapsuleChance) or 0) then
    return (5000 + randomGauss3() / 3 * 15000) * MILES_TO_METERS, nil, "timeCapsule"
  end

  local expected = getExpectedMileageMiles(age, profile.annualMiles)
  local minFactor = tonumber(profile.minFactor) or 0.75
  local maxFactor = tonumber(profile.maxFactor) or 1.25
  local factor = minFactor + randomGauss3() / 3 * (maxFactor - minFactor)
  local miles = expected * factor

  if age == 0 then
    miles = math.max(50, math.min(miles, 15000))
  elseif age >= 15 then
    miles = math.max(miles, tonumber(profile.minMiles) or 5000)
  end
  miles = clamp(miles, tonumber(profile.minMiles) or 0, tonumber(profile.maxMiles) or MAX_USED_MILES)
  if miles >= MAX_USED_MILES then
    -- Compress extreme-use vehicles into a varied 270k-300k survivor band
    -- instead of stacking every listing on the same hard-cap odometer.
    miles = MAX_USED_MILES - math.random() * 30000
  end

  local odometer = math.max(0, miles * MILES_TO_METERS)
  local wearMileage = nil
  local mileageCategory = "ageCurve"
  if profile.wearFactor and profile.wearFactor > 1 then
    wearMileage = odometer * profile.wearFactor
    mileageCategory = "competitionWear"
  elseif seller.id == "jeffersonmotors" and age >= 25 then
    if math.random() < 0.35 then
      wearMileage = math.max(5000 * MILES_TO_METERS, odometer * 0.25)
      mileageCategory = "restoredClassic"
    else
      wearMileage = odometer * 0.70
      mileageCategory = "collectorDriver"
    end
  end
  return odometer, wearMileage, mileageCategory
end

local function getDiscoveredDealersForMap(mapId)
  mapId = mapId or getCurrentLevelIdentifier()
  discoveredDealers[mapId] = discoveredDealers[mapId] or {}
  return discoveredDealers[mapId]
end

isDealerDiscovered = function(dealership)
  if not dealership then return false end
  local accessInfo = getSellerAccessInfo(dealership)
  if dealership.discoverable == false or accessInfo.isOnline then return true end
  return getDiscoveredDealersForMap()[dealership.id] == true
end

local function discoverDealer(dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership or dealership.discoverable == false then return false end
  if getSellerAccessInfo(dealership).isOnline then return false end
  local mapDiscoveries = getDiscoveredDealersForMap()
  if mapDiscoveries[dealershipId] then return false end
  mapDiscoveries[dealershipId] = true
  -- Discovery is durable career progress. Queue a save now instead of relying
  -- on an unrelated purchase or later autosave to eventually flush it.
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  ui_message(string.format("%s is now available in the vehicle-shopping computer.",
    dealership.name or "Dealership"), 6, "Dealership discovered", "info")
  return true
end

local function applyPurchaseAdjustedMarketValue(vehicleInfo)
  if not vehicleInfo then return end
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  local marketValue = vehicleInfo.marketValueBase or vehicleInfo.marketValue or vehicleInfo.Value
  vehicleInfo.marketValueAdjusted = math.floor((marketValue or 0) * vehicleBuyMult + 0.5)

  local valueBase = vehicleInfo.valueBase
  if not valueBase then
    if vehicleInfo.marketValue and vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier then
      valueBase = vehicleInfo.marketValue * vehicleInfo.negotiationPersonality.priceMultiplier
    else
      valueBase = vehicleInfo.Value
    end
  end
  if valueBase then
    vehicleInfo.valueAdjusted = getRoundedPrice(valueBase * vehicleBuyMult, vehicleInfo.priceRoundingType or "default")
  else
    vehicleInfo.valueAdjusted = vehicleInfo.Value
  end
end

local function getOrgLevelData(org, offset)
  if not org then
    return nil
  end
  local repLevel = (org.reputation and org.reputation.level) or 0
  if type(repLevel) ~= "number" then
    repLevel = 0
  end
  repLevel = math.max(0, repLevel)
  local levels = org.reputationLevels
  if not levels then
    return nil
  end
  local arrayIndex = repLevel + 2 + (offset or 0)
  if arrayIndex < 1 or arrayIndex > #levels then
    return nil
  end
  return levels[arrayIndex]
end

M.addModelBlacklistToLookup = function(lookup, filter)
  local modelKeys = type(filter) == "table" and type(filter.blackList) == "table" and
    filter.blackList.model_key or nil
  if type(modelKeys) ~= "table" then return end

  for _, modelKey in ipairs(modelKeys) do
    local normalized = string.lower(tostring(modelKey or ""))
    if normalized ~= "" then
      lookup[normalized] = true
    end
  end
end

-- Saved offers can outlive a facility edit or an organization level change.
-- Remove listings that the seller's current global model blacklist no longer
-- permits before counting stock and drawing replacements from the rebuilt cache.
M.pruneBlacklistedSellerStock = function(sellers)
  local blacklistedBySeller = {}
  for _, seller in ipairs(sellers or {}) do
    local lookup = {}
    M.addModelBlacklistToLookup(lookup, seller.filter)

    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = getOrgLevelData(org)
      if level then
        M.addModelBlacklistToLookup(lookup, level.filter)
      end
    end

    if next(lookup) ~= nil then
      blacklistedBySeller[seller.id] = lookup
    end
  end

  local removed = 0
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local lookup = blacklistedBySeller[vehicleInfo.sellerId]
    local modelKey = string.lower(tostring(vehicleInfo.model_key or vehicleInfo.model or ""))
    if lookup and lookup[modelKey] then
      if vehicleInfo.shopId ~= nil then
        vehicleWatchlist[vehicleInfo.shopId] = nil
      end
      table.remove(vehiclesInShop, i)
      removed = removed + 1
    end
  end

  if removed > 0 then
    log("I", "Career", string.format("Removed %d dealer listings blocked by current model blacklists", removed))
  end
  return removed
end

local function resetVehicleValidationState()
  badConfigQuarantine = {}
  badConfigLogOnce = {}
  validationStats = {
    quarantined = 0,
    loadDropped = 0,
    cacheDropped = 0,
    generationDropped = 0
  }
end

local function incrementValidationStat(statKey, amount)
  if statKey and validationStats[statKey] ~= nil then
    validationStats[statKey] = validationStats[statKey] + (amount or 1)
  end
end

local function getVehicleConfigId(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end
  if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
    return nil
  end
  if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
    return nil
  end
  return vehicleInfo.model_key .. "|" .. vehicleInfo.key
end

local function getVehicleConfigTrackingKey(vehicleInfo)
  local configId = getVehicleConfigId(vehicleInfo)
  if configId then
    return configId
  end

  if type(vehicleInfo) ~= "table" then
    return "invalid:" .. tostring(vehicleInfo)
  end

  return string.format("invalid:%s|%s", tostring(vehicleInfo.model_key), tostring(vehicleInfo.key))
end

local function quarantineVehicleConfig(vehicleInfo, reason, context)
  local configId = getVehicleConfigId(vehicleInfo) or getVehicleConfigTrackingKey(vehicleInfo)
  if not badConfigQuarantine[configId] then
    badConfigQuarantine[configId] = true
    validationStats.quarantined = validationStats.quarantined + 1
  end

  if not badConfigLogOnce[configId] then
    badConfigLogOnce[configId] = true
    log("W", "Career", string.format("Quarantined vehicle config %s during %s: %s",
      tostring(configId), tostring(context), tostring(reason)))
  end

  return configId
end

local function isQuarantined(vehicleInfo)
  local trackingKey = getVehicleConfigTrackingKey(vehicleInfo)
  return badConfigQuarantine[trackingKey] == true
end

local function isValidVehicleInfoShape(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return false, "vehicleInfo is not a table"
  end
  if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
    return false, "missing model_key"
  end
  if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
    return false, "missing key"
  end
  if type(vehicleInfo.Value) ~= "number" then
    local profile = career_modules_valueCalculator.getVehicleCatalogProfile and
      career_modules_valueCalculator.getVehicleCatalogProfile(
        vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
    if profile and tonumber(profile.catalogValue) and profile.catalogValue > 0 then
      vehicleInfo.Value = profile.catalogValue
    else
      return false, "missing numeric Value and no parts-derived catalog"
    end
  end

  if vehicleInfo.aggregates == nil then
    vehicleInfo.aggregates = {}
  elseif type(vehicleInfo.aggregates) ~= "table" then
    return false, "malformed aggregates"
  end

  if type(vehicleInfo.Brand) ~= "string" then
    vehicleInfo.Brand = ""
  end
  if type(vehicleInfo.Name) ~= "string" then
    vehicleInfo.Name = ""
  end

  return true
end

local function safeYearsRange(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local function normalizeYears(years)
    if type(years) ~= "table" then
      return nil
    end
    local minYear = tonumber(years.min)
    local maxYear = tonumber(years.max)
    if not minYear or not maxYear or minYear > maxYear then
      return nil
    end
    return {min = minYear, max = maxYear}
  end

  return normalizeYears(vehicleInfo.Years) or
    normalizeYears(type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates.Years or nil)
end

local function safeNumericAttribute(vehicleInfo, attrName)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local directValue = tonumber(vehicleInfo[attrName])
  if directValue then
    return directValue
  end

  local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[attrName] or nil
  if type(aggregateValue) == "table" then
    return tonumber(aggregateValue.min)
  end

  return nil
end

local function normalizeVehicleCatalogValue(vehicleInfo, logContext)
  if type(vehicleInfo) ~= "table" then
    return false
  end

  local rawCatalogValue = tonumber(vehicleInfo.rawCatalogValue)
  if rawCatalogValue == nil then
    rawCatalogValue = tonumber(vehicleInfo.Value)
  end

  local profile = career_modules_valueCalculator.getVehicleCatalogProfile and
    career_modules_valueCalculator.getVehicleCatalogProfile(
      vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
  local cachedPartsValue = profile and profile.partsRetailValue
    or career_modules_valueCalculator.getVehiclePcPartsCatalogSum(
      vehicleInfo.model_key, vehicleInfo.key, logContext)
    or 0
  local partsCatalogValue = profile and profile.catalogValue
    or (career_modules_valueCalculator.getVehiclePartsCatalogValue and
      career_modules_valueCalculator.getVehiclePartsCatalogValue(cachedPartsValue))
    or 0
  if rawCatalogValue == nil and partsCatalogValue <= 0 then
    return false
  end
  rawCatalogValue = rawCatalogValue or 0
  local effectiveCatalogValue = partsCatalogValue > 0 and partsCatalogValue or rawCatalogValue

  vehicleInfo.rawCatalogValue = rawCatalogValue
  vehicleInfo.cachedPartsValue = cachedPartsValue
  vehicleInfo.partsCatalogValue = partsCatalogValue
  vehicleInfo.catalogValueSource = profile and profile.catalogSource or
    (partsCatalogValue > 0 and "parts" or "configFallback")
  vehicleInfo.haloScore = profile and profile.haloScore or 0
  vehicleInfo.haloSignals = profile and profile.haloSignals or nil
  vehicleInfo.haloCohortSize = profile and profile.cohortSize or 0
  vehicleInfo.effectiveCatalogValue = effectiveCatalogValue
  vehicleInfo.Value = vehicleInfo.effectiveCatalogValue
  return true
end

M.isRichsStreetVehicle = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return false
  end

  -- Some otherwise-factory configs are competition cars in their names and
  -- descriptions. Keep Rich's focused on valuable street cars.
  local identity = string.lower(table.concat({
    tostring(vehicleInfo["Config Type"] or ""),
    tostring(vehicleInfo.Configuration or ""),
    tostring(vehicleInfo.Name or ""),
    tostring(vehicleInfo.key or "")
  }, " "))
  local excludedWords = {
    "race", "rally", "drag", "drift", "police", "service",
    "commercial", "semi", "trailer", "frame", "taxi",
    "nascar", "track car", "cup car"
  }
  for _, word in ipairs(excludedWords) do
    if string.find(identity, "%f[%a]" .. word) then
      return false
    end
  end

  local aggregates = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates or {}
  local configTypes = type(aggregates["Config Type"]) == "table" and aggregates["Config Type"] or {}
  local vehicleTypes = type(aggregates.Type) == "table" and aggregates.Type or {}
  local isFactory = vehicleInfo["Config Type"] == "Factory" or configTypes.Factory == true
  local isCar = vehicleInfo.Type == "Car" or vehicleTypes.Car == true
  return isFactory and isCar
end

M.buildRichsTopTrimLookup = function(vehicleInfos)
  local modelGroups = {}
  for _, vehicleInfo in ipairs(vehicleInfos or {}) do
    local years = safeYearsRange(vehicleInfo)
    if M.isRichsStreetVehicle(vehicleInfo) and years and years.max >= 2000 then
      local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
      local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
      local bestCatalogValue = math.max(effectiveValue, originalValue)
      local haloScore = tonumber(vehicleInfo.haloScore) or 0
      local insuranceClasses = type(vehicleInfo.aggregates) == "table"
        and vehicleInfo.aggregates.InsuranceClass or nil
      local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

      -- Rich's still has a price floor: being the best trim of an economy car
      -- is not enough unless that trim is genuinely special.
      if bestCatalogValue >= 45000
          or (bestCatalogValue >= 35000 and (haloScore >= 0.75 or prestigeClass)) then
        local modelKey = vehicleInfo.model_key
        modelGroups[modelKey] = modelGroups[modelKey] or {}
        table.insert(modelGroups[modelKey], {
          key = getVehicleConfigTrackingKey(vehicleInfo),
          value = bestCatalogValue,
          score = bestCatalogValue * (1 + 0.35 * haloScore) + (prestigeClass and 7500 or 0)
        })
      end
    end
  end

  local lookup = {}
  for _, configs in pairs(modelGroups) do
    table.sort(configs, function(a, b)
      if a.score == b.score then
        return tostring(a.key) < tostring(b.key)
      end
      return a.score > b.score
    end)

    local selectedCount = math.max(1, math.min(5, math.ceil(#configs * 0.20)))
    for rank = 1, selectedCount do
      local config = configs[rank]
      lookup[config.key] = {
        rank = rank,
        cohortSize = #configs,
        score = config.score,
        value = config.value
      }
    end
  end
  return lookup
end

M.isRichsPrestigeVehicle = function(vehicleInfo, topTrimLookup)
  if not M.isRichsStreetVehicle(vehicleInfo) then
    return false
  end

  local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
  local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
  local haloScore = tonumber(vehicleInfo.haloScore) or 0
  local insuranceClasses = type(vehicleInfo.aggregates) == "table"
    and vehicleInfo.aggregates.InsuranceClass or nil
  local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

  local bestCatalogValue = math.max(effectiveValue, originalValue)
  local topTrimData = type(topTrimLookup) == "table"
    and topTrimLookup[getVehicleConfigTrackingKey(vehicleInfo)] or nil
  if topTrimData then
    return true, "modernTopTrim", topTrimData
  end
  if bestCatalogValue >= 100000 then
    return true, "sixFigureCatalog"
  end

  local years = safeYearsRange(vehicleInfo)
  if years and years.max < 2000 and bestCatalogValue >= 50000
      and (haloScore >= 0.75 or prestigeClass) then
    return true, "collectorHalo"
  end
  return false
end

local function safeBoundingBoxDimensions(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local boundingBox = vehicleInfo.BoundingBox
  local dimensions = type(boundingBox) == "table" and boundingBox[2] or nil
  if type(dimensions) ~= "table" then
    return nil
  end

  local x = tonumber(dimensions[1])
  local y = tonumber(dimensions[2])
  local z = tonumber(dimensions[3])
  if not x or not y or not z then
    return nil
  end

  return x, y, z
end

local function safeVehicleOp(context, vehicleInfo, fn)
  local ok, result = pcall(fn)
  if not ok then
    quarantineVehicleConfig(vehicleInfo, result, context)
    return nil, result
  end
  return result, nil
end

local function sanitizeVehicleInfoList(rawVehicles, context, dropStatKey)
  local sanitizedVehicles = {}
  local summary = {
    raw = 0,
    kept = 0,
    malformed = 0,
    quarantined = 0
  }

  if type(rawVehicles) ~= "table" then
    return sanitizedVehicles, summary
  end

  for _, vehicleInfo in ipairs(rawVehicles) do
    summary.raw = summary.raw + 1
    if isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      incrementValidationStat(dropStatKey)
    else
      local ok, reason = isValidVehicleInfoShape(vehicleInfo)
      if not ok then
        summary.malformed = summary.malformed + 1
        incrementValidationStat(dropStatKey)
        quarantineVehicleConfig(vehicleInfo, reason, context)
      else
        normalizeVehicleCatalogValue(vehicleInfo, context)
        table.insert(sanitizedVehicles, vehicleInfo)
        summary.kept = summary.kept + 1
      end
    end
  end

  return sanitizedVehicles, summary
end

local function logVehicleSanitizationSummary(context, summary)
  local logLevel = (summary.kept > 0 or summary.raw == 0) and "I" or "W"
  log(logLevel, "Career", string.format("%s summary: raw=%d kept=%d malformed=%d quarantined=%d",
    tostring(context), summary.raw, summary.kept, summary.malformed, summary.quarantined))
end

local function validateSavedVehicleRuntimeFields(vehicleInfo)
  local sellerIdType = type(vehicleInfo.sellerId)
  if (sellerIdType ~= "string" and sellerIdType ~= "number") or tostring(vehicleInfo.sellerId) == "" then
    return false, "missing saved sellerId"
  end

  local generationTime = tonumber(vehicleInfo.generationTime)
  if not generationTime then
    return false, "missing saved generationTime"
  end

  local offerTTL = tonumber(vehicleInfo.offerTTL)
  if not offerTTL then
    return false, "missing saved offerTTL"
  end

  local shopId = tonumber(vehicleInfo.shopId)
  if not shopId then
    return false, "missing saved shopId"
  end

  local fees = vehicleInfo.fees
  if fees == nil then
    fees = 0
  else
    fees = tonumber(fees)
    if not fees or fees < 0 then
      return false, "invalid saved fees"
    end
  end

  local tax = vehicleInfo.tax
  if tax == nil then
    tax = salesTax
  else
    tax = tonumber(tax)
    if not tax or tax < 0 then
      return false, "invalid saved tax"
    end
  end

  vehicleInfo.generationTime = generationTime
  vehicleInfo.offerTTL = offerTTL
  vehicleInfo.shopId = shopId
  vehicleInfo.fees = fees
  vehicleInfo.tax = tax

  return true
end

local function coerceVehiclePricingFields(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return 0, salesTax
  end

  local fees = tonumber(vehicleInfo.fees)
  if not fees or fees < 0 then
    fees = 0
  end

  local tax = tonumber(vehicleInfo.tax)
  if not tax or tax < 0 then
    tax = salesTax
  end

  vehicleInfo.fees = fees
  vehicleInfo.tax = tax
  return fees, tax
end

local function sanitizeSavedVehicleEntries(savedVehicles, context)
  local sanitizedVehicles = {}
  local summary = {
    raw = 0,
    kept = 0,
    malformed = 0,
    quarantined = 0
  }

  if type(savedVehicles) ~= "table" then
    return sanitizedVehicles, summary
  end

  for _, vehicleInfo in ipairs(savedVehicles) do
    summary.raw = summary.raw + 1
    if isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      incrementValidationStat("loadDropped")
    else
      local ok, reason = isValidVehicleInfoShape(vehicleInfo)
      if ok then
        ok, reason = validateSavedVehicleRuntimeFields(vehicleInfo)
      end
      if not ok then
        local logKey = "loaddrop:" .. getVehicleConfigTrackingKey(vehicleInfo)
        summary.malformed = summary.malformed + 1
        incrementValidationStat("loadDropped")
        if not badConfigLogOnce[logKey] then
          badConfigLogOnce[logKey] = true
          log("W", "Career", string.format("Dropped malformed saved vehicle entry %s during %s: %s",
            tostring(getVehicleConfigTrackingKey(vehicleInfo)), tostring(context), tostring(reason)))
        end
      else
        table.insert(sanitizedVehicles, vehicleInfo)
        summary.kept = summary.kept + 1
      end
    end
  end

  for _, vehicleInfo in ipairs(sanitizedVehicles) do
    if vehicleInfo.pos ~= nil then
      local posOk, posOrErr = pcall(function()
        return vec3(vehicleInfo.pos)
      end)
      if posOk then
        vehicleInfo.pos = posOrErr
      else
        local posLogKey = getVehicleConfigTrackingKey(vehicleInfo) .. "|savedPos"
        if not badConfigLogOnce[posLogKey] then
          badConfigLogOnce[posLogKey] = true
          log("W", "Career", string.format("Clearing malformed saved vehicle position for %s during %s: %s",
            tostring(getVehicleConfigId(vehicleInfo) or getVehicleConfigTrackingKey(vehicleInfo)),
            tostring(context), tostring(posOrErr)))
        end
        vehicleInfo.pos = nil
      end
    end
  end

  return sanitizedVehicles, summary
end

-- Delta tracking functions
local function buildSnapshot()
  local snap = {}
  for _, veh in ipairs(vehiclesInShop) do
    if not isCarMeetShopVehicle(veh) then
      snap[veh.shopId] = veh
    end
  end
  return snap
end

local function commitDelta(newSnap, justExpiredShopIds)
  justExpiredShopIds = justExpiredShopIds or {}
  local added, removed, sold, updated = {}, {}, {}, {}
  for shopId, veh in pairs(newSnap) do
    if not lastSnapshotByShopId[shopId] then
      table.insert(added, sanitizeVehicleForUi(veh))
    end
  end
  for shopId, veh in pairs(newSnap) do
    local prev = lastSnapshotByShopId[shopId]
    if prev and veh then
      local wasMarkedSold = prev.markedSold == true
      local isMarkedSold = veh.markedSold == true
      local prevSold = (prev.soldViewCounter or 0)
      local currSold = (veh.soldViewCounter or 0)

      if justExpiredShopIds[shopId] or (isMarkedSold and not wasMarkedSold) or (currSold > prevSold) then
        local soldVeh = sanitizeVehicleForUi(veh)
        soldVeh.__sold = true
        table.insert(updated, soldVeh)
      end
    end
  end
  for shopId, _ in pairs(lastSnapshotByShopId) do
    if not newSnap[shopId] then
      if pendingSoldShopIds[shopId] then
        local prevVeh = lastSnapshotByShopId[shopId]
        if prevVeh then
          local soldVeh = sanitizeVehicleForUi(prevVeh)
          soldVeh.shopId = shopId
          soldVeh.__sold = true
          table.insert(sold, soldVeh)
        else
          table.insert(sold, shopId)
        end
        pendingSoldShopIds[shopId] = nil
      else
        table.insert(removed, shopId)
      end
    end
  end
  lastSnapshotByShopId = newSnap
  deltaSeq = deltaSeq + 1
  lastDelta = {
    seq = deltaSeq,
    added = added,
    removed = removed,
    sold = sold,
    updated = updated,
    organizations = collectOrganizationsForUi(freeroam_facilities.getFacilities(getCurrentLevelIdentifier())),
    dealershipPurchaseReputationGain = dealershipPurchaseReputationGain
  }
end

-- UI state management
-- Phone buy and computer shop both restock through this. Count so closing one
-- does not stop refresh while the other is still open.
local function setShoppingUiOpen(isOpen)
  if isOpen then
    shoppingUiOpenCount = shoppingUiOpenCount + 1
  else
    shoppingUiOpenCount = math.max(0, shoppingUiOpenCount - 1)
  end
  uiOpen = shoppingUiOpenCount > 0
  refreshAccumulator = 0
  if isOpen then
    M.updateVehicleList(false)
    nextShopUpdateTime = 0
  end
end

local function onUiChangedState(toState)
  currentUiState = toState
end

local processPendingRacingTeamFleetPurchases

local function onUpdate(dt)
  processPendingRacingTeamFleetPurchases()
  refreshAccumulator = refreshAccumulator + dt
  if refreshAccumulator < 5 then
    return
  end
  refreshAccumulator = 0

  -- Watchlist expiration check
  if not tableIsEmpty(vehicleWatchlist) and (not currentUiState or currentUiState == "play") then
    local currentTime = os.time()
    local inspectedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
    for shopId, status in pairs(vehicleWatchlist) do
      if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
        local vehicleInfo = getVehicleInfoByShopId(shopId)
        if vehicleInfo then
          normalizeVehicleShopTiming(vehicleInfo, currentTime)
          local offerTime = currentTime - vehicleInfo.generationTime
          if offerTime > vehicleInfo.offerTTL then
            vehicleInfo.soldFor = generateSoldVehicleValue(shopId)
            vehicleWatchlist[shopId] = "sold"
            guihooks.trigger("toastrMsg", {type="info", title="A vehicle you were interested in has been sold.", msg = vehicleInfo.Name .. " for $" .. string.format("%.2f", vehicleInfo.soldFor)})
            break
          end
        end
      end
    end
  end

  -- UI refresh logic
  if not uiOpen then
    return
  end
  local now = os.time()
  if (nextShopUpdateTime == 0) or (now >= nextShopUpdateTime) then
    M.updateVehicleList(false)
  end

  M.checkSpawnedVehicleStatus()
end

-- Data access functions
local function rtFleetCap(bid)
  local obj = career_modules_business_businessManager
    and career_modules_business_businessManager.getBusinessObject("racingTeam")
  if obj and obj.getMaxActiveJobs then
    return tonumber(obj.getMaxActiveJobs(bid)) or 3
  end
  return 3
end

local function getRacingTeamGarageZones(businessId)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessGarage then return nil end
  local garage = inv.getBusinessGarage("racingTeam", businessId)
  if not garage or not garage.sitesFile then return nil end
  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  return sites and sites.zones or nil
end

local function isVehicleInRacingTeamGarageZone(businessId, vehId)
  if not businessId or not vehId then return false end
  local vehObj = be:getObjectByID(vehId)
  if not vehObj then return false end
  local pos = vehObj:getPosition()
  if not pos then return false end
  local zones = getRacingTeamGarageZones(businessId)
  if not zones or not zones.sorted then return false end
  for _, zone in ipairs(zones.sorted or {}) do
    if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
      return true
    end
  end
  return false
end

local function getRacingTeamDeliveryDelaySeconds(businessId, vehicleInfo)
  if not vehicleInfo or not vehicleInfo.pos then
    return 1
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessGarage then
    return 1
  end
  local garage = inv.getBusinessGarage("racingTeam", businessId)
  if not garage or not freeroam_facilities or not freeroam_facilities.getAverageDoorPositionForFacility then
    return 1
  end
  local garagePos = freeroam_facilities.getAverageDoorPositionForFacility(garage)
  if not garagePos then
    return 1
  end
  return getDeliveryDelay(vehicleInfo.pos:distance(garagePos))
end

local function storeRacingTeamFleetVehicleFromPending(businessId, pending)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.storeVehicle then
    return false
  end
  local ok, vehicleId = inv.storeVehicle(businessId, {
    vehicleConfig = {
      model_key = pending.model_key,
      key = pending.key
    },
    mileage = pending.mileage or 0,
    purchasePrice = pending.purchasePrice or 0
  })
  if not ok then
    return false
  end
  local rtmod = rawget(_G, "career_modules_business_racingTeam")
  if rtmod and rtmod.notifyFleetFromShop then
    rtmod.notifyFleetFromShop(businessId)
  end

  return true, vehicleId
end

local function addPendingRacingTeamFleetPurchase(businessId, entry)
  local bid = tostring(businessId)
  rtPendingFleetPurchases[bid] = rtPendingFleetPurchases[bid] or {}
  entry = entry or {}
  entry.purchasedEpoch = tonumber(entry.purchasedEpoch) or os.time()
  table.insert(rtPendingFleetPurchases[bid], entry)
end

processPendingRacingTeamFleetPurchases = function()
  if rtPendingFleetProcessing or not next(rtPendingFleetPurchases) then
    return
  end
  rtPendingFleetProcessing = true
  local ok, err = pcall(function()
  local now = os.time()
  for bid, entries in pairs(rtPendingFleetPurchases) do
    if type(entries) == "table" then
      local keep = {}
      for _, pending in ipairs(entries) do
        local handled = false
        local purchasedEpoch = tonumber(pending and pending.purchasedEpoch) or now
        if pending.kind == "timer" then
          local dueEpoch = tonumber(pending.dueEpoch) or 0
          if dueEpoch > 0 and now >= dueEpoch then
            local stored, fleetVehicleId = storeRacingTeamFleetVehicleFromPending(bid, pending)
            handled = stored == true
            if handled and fleetVehicleId then
              local inv = career_modules_business_businessInventory
              if inv and inv.deliverFleetVehicleAtPurchase then
                inv.deliverFleetVehicleAtPurchase("racingTeam", bid, fleetVehicleId)
              end
            end
            if not handled then
              local overdue = now - dueEpoch
              if overdue >= rtPendingTimerFailureGraceSec then
                -- Prevent perma-"finalizing delivery" cards for invalid/failed timer entries.
                handled = true
                log("W", "Career", string.format(
                  "Dropping stale racing-team timer pending entry for business %s after %ds overdue.",
                  tostring(bid), math.floor(overdue)
                ))
              end
            end
          end
        elseif pending.kind == "drive" then
          local spawnedVehId = tonumber(pending.spawnedVehId)
          if spawnedVehId and isVehicleInRacingTeamGarageZone(bid, spawnedVehId) then
            local stored, fleetVehicleId = storeRacingTeamFleetVehicleFromPending(bid, pending)
            if stored then
              handled = true
              local inv = career_modules_business_businessInventory
              if fleetVehicleId and inv and inv.registerFleetVehicleDeliveredDriveIn then
                inv.registerFleetVehicleDeliveredDriveIn("racingTeam", bid, fleetVehicleId, spawnedVehId)
                if inv.requestFleetVehicleStatsRead then
                  inv.requestFleetVehicleStatsRead(bid, fleetVehicleId)
                end
              end
            end
          else
            local age = now - purchasedEpoch
            if age >= rtPendingDriveStaleSec then
              -- Stale drive-in pending entries can survive across sessions after world-vehicle loss.
              handled = true
              log("W", "Career", string.format(
                "Dropping stale racing-team drive pending entry for business %s after %ds age.",
                tostring(bid), math.floor(age)
              ))
            end
          end
        end
        if not handled then
          table.insert(keep, pending)
        end
      end
      if #keep > 0 then
        rtPendingFleetPurchases[bid] = keep
      else
        rtPendingFleetPurchases[bid] = nil
      end
    end
  end
  end)
  rtPendingFleetProcessing = false
  if not ok then
    log("E", "Career", "processPendingRacingTeamFleetPurchases failed: " .. tostring(err))
  end
end

local function clearPendingRacingTeamFleetPurchases(businessId)
  if businessId == nil then return end
  local bid = tostring(tonumber(businessId) or businessId)
  rtPendingFleetPurchases[bid] = nil
end

local function getPendingRacingTeamFleetPurchases(businessId)
  -- Ensure UI never sees stale pending entries after delivery.
  processPendingRacingTeamFleetPurchases()
  if businessId == nil then
    return {}
  end
  local bid = tostring(tonumber(businessId) or businessId)
  local list = rtPendingFleetPurchases[bid]
  if type(list) ~= "table" then
    return {}
  end
  local out = {}
  local now = os.time()
  for i, p in ipairs(list) do
    if type(p) == "table" then
      out[#out + 1] = {
        pendingId = tostring(p.purchasedEpoch or now) .. "_" .. tostring(i),
        kind = p.kind,
        dueEpoch = tonumber(p.dueEpoch),
        secondsRemaining = math.max(0, math.floor((tonumber(p.dueEpoch) or now) - now)),
        model_key = p.model_key,
        key = p.key,
        mileage = p.mileage or 0,
        purchasePrice = p.purchasePrice or 0,
        spawnedVehId = tonumber(p.spawnedVehId),
        purchasedEpoch = tonumber(p.purchasedEpoch) or now
      }
    end
  end
  return out
end

local function getShoppingData()
  local data = {}

  local unsoldVehicles, soldVehiclesResult = convertKeysToStrings(vehiclesInShop)
  for i = #unsoldVehicles, 1, -1 do
    if isCarMeetShopVehicle(unsoldVehicles[i]) then
      table.remove(unsoldVehicles, i)
    end
  end
  for i = #soldVehiclesResult, 1, -1 do
    if isCarMeetShopVehicle(soldVehiclesResult[i]) then
      table.remove(soldVehiclesResult, i)
    end
  end
  for _, vehicleInfo in ipairs(unsoldVehicles) do
    applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  for _, vehicleInfo in ipairs(soldVehiclesResult) do
    applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  data.vehiclesInShop = unsoldVehicles
  data.soldVehicles = soldVehiclesResult
  data.uiDealershipsData = getUiDealershipsData(unsoldVehicles)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    if dealership then
      data.currentSellerNiceName = dealership.name
    end
  end
  data.selectedSellerId = selectedSellerId
  data.screenTag = shoppingScreenTag
  data.buyingAvailable = buyingAvailable
  data.marketplaceAvailable = marketplaceAvailable
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  if rtBizId and career_modules_bank and career_modules_bank.getBusinessAccount then
    local acct = career_modules_bank.getBusinessAccount("racingTeam", rtBizId)
    local bal = acct and (tonumber(acct.balance) or tonumber(acct.balanceMoney))
    if bal == nil and type(acct) == "table" then
      bal = tonumber(acct.money)
    end
    bal = tonumber(bal) or 0
    data.racingTeamBusinessId = rtBizId
    data.racingTeamBusinessMoney = bal
    local inv = career_modules_business_businessInventory
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(rtBizId) or {})
    end
    local cap = rtFleetCap(rtBizId)
    data.inventoryHasFreeSlot = n < cap
    data.numberOfFreeSlots = math.max(0, cap - n)
  else
    data.racingTeamBusinessId = nil
    data.racingTeamBusinessMoney = nil
    data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
    data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()
  end

  -- Racing-team shop: do not expose personal wallet in playerAttributes (UI uses racingTeamBusinessMoney).
  -- Taxi / personal fees still use playerPersonalMoneyForTaxi when present.
  if rtBizId then
    data.playerPersonalMoneyForTaxi = career_modules_playerAttributes.getAttributeValue("money")
    if data.playerAttributes then
      data.playerAttributes = deepcopy(data.playerAttributes)
      if type(data.playerAttributes.money) == "table" then
        data.playerAttributes.money = deepcopy(data.playerAttributes.money)
        data.playerAttributes.money.value = nil
      else
        data.playerAttributes.money = nil
      end
    end
  end

  data.cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false
  data.dealershipPurchaseReputationGain = dealershipPurchaseReputationGain

  data.tutorialPurchase = (not career_career.hasBoughtStarterVehicle()) or nil
  data.hasboughtStarterVehicle = career_career.hasBoughtStarterVehicle()

  data.disableShopping = false
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    data.disableShopping = true
  end
  if reason.permission ~= "allowed" then
    data.disableShoppingReason = reason.label or "not allowed (TODO)"
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  data.dealerships = {}
  data.dealershipDiscovery = {discovered = 0, total = 0}
  data.organizations = collectOrganizationsForUi(facilities)
  if facilities and facilities.dealerships then
    for _, d in ipairs(facilities.dealerships) do
      local policeLocked = isPoliceDealershipLocked(d.id)
      local discovered = isDealerDiscovered(d)
      local accessInfo = getSellerAccessInfo(d)
      if d.discoverable ~= false and not accessInfo.isOnline then
        data.dealershipDiscovery.total = data.dealershipDiscovery.total + 1
        if discovered then
          data.dealershipDiscovery.discovered = data.dealershipDiscovery.discovered + 1
        end
      end
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or policeLocked or not discovered,
        undiscovered = not discovered,
        salesChannel = accessInfo.salesChannel,
        remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
        garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
        deliveryDiscount = accessInfo.deliveryDiscount,
        associatedOrganization = d.associatedOrganization,
        disabled = policeLocked,
        disabledReason = policeLocked and getPoliceDealershipLockLabel() or nil
      })
    end
  end

  if facilities and facilities.privateSellers then
    for _, d in ipairs(facilities.privateSellers) do
      local policeLocked = isPoliceDealershipLocked(d.id)
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or policeLocked,
        associatedOrganization = d.associatedOrganization,
        disabled = policeLocked,
        disabledReason = policeLocked and getPoliceDealershipLockLabel() or nil
      })
    end
  end

  -- Seller access changes with reputation, while shop listings can persist across
  -- sessions. Copy the freshly computed dealer access onto every existing card,
  -- not only stock generated after the reputation change.
  for _, vehicleInfo in ipairs(data.vehiclesInShop) do
    for _, dealership in ipairs(data.dealerships) do
      if dealership.id == vehicleInfo.sellerId then
        vehicleInfo.salesChannel = dealership.salesChannel
        vehicleInfo.remotePurchaseAllowed = dealership.remotePurchaseAllowed
        vehicleInfo.garageDeliveryAllowed = dealership.garageDeliveryAllowed
        vehicleInfo.deliveryDiscount = dealership.deliveryDiscount
        break
      end
    end
  end

  -- Strip vec3 userdata so the phone can read shop stock without the computer
  -- having already sent a sanitized vehicleShopDelta.
  local sanitizedUnsold = {}
  for _, vehicleInfo in ipairs(data.vehiclesInShop) do
    table.insert(sanitizedUnsold, sanitizeVehicleForUi(vehicleInfo))
  end
  local sanitizedSold = {}
  for _, vehicleInfo in ipairs(data.soldVehicles) do
    table.insert(sanitizedSold, sanitizeVehicleForUi(vehicleInfo))
  end
  data.vehiclesInShop = sanitizedUnsold
  data.soldVehicles = sanitizedSold

  return data
end

local function sendShoppingDataToUI()
  guihooks.trigger("vehicleShoppingData", getShoppingData())
end

-- Price calculation functions
local function getRandomizedPrice(price, range)
  local boundedRange = career_modules_valueCalculator.getVehicleListingPriceRange and
    career_modules_valueCalculator.getVehicleListingPriceRange(range) or
    {tailLow = 0.70, normalLow = 0.88, normalHigh = 1.12, tailHigh = 1.30}
  local normalLow = boundedRange.normalLow
  local normalHigh = boundedRange.normalHigh

  if isReallyRandom then
    math.randomseed(os.time() + os.clock() * 10000)
    for _ = 1, 3 do
      math.random()
    end
  end

  local rand = math.random(0, 1000) / 1000
  if rand < 0 then
    rand = 0
  end
  if rand > 1 then
    rand = 1
  end

  local multiplier
  local priceBand
  if rand <= 0.01 then
    multiplier = boundedRange.tailLow + (normalLow - boundedRange.tailLow) * (rand / 0.01)
    priceBand = "lowTail"
  elseif rand <= 0.99 then
    multiplier = normalLow + (normalHigh - normalLow) * ((rand - 0.01) / 0.98)
    priceBand = "normal"
  else
    multiplier = normalHigh + (boundedRange.tailHigh - normalHigh) * ((rand - 0.99) / 0.01)
    priceBand = "highTail"
  end

  local finalPriceInt = math.floor(multiplier * price + 0.5)
  return math.max(finalPriceInt, 500), priceBand, multiplier
end

-- Vehicle filtering and processing functions
local function normalizePopulations(configs, scalingFactor)
  if not configs or tableIsEmpty(configs) then
    return
  end
  local sum = 0
  for _, configInfo in ipairs(configs) do
    configInfo.adjustedPopulation = tonumber(configInfo.Population) or 1
    sum = sum + configInfo.adjustedPopulation
  end
  local count = tableSize(configs)
  if count == 0 then
    return
  end
  local average = sum / count
  for _, configInfo in ipairs(configs) do
    local distanceFromAverage = configInfo.adjustedPopulation - average
    configInfo.adjustedPopulation = round(configInfo.adjustedPopulation - scalingFactor * distanceFromAverage)
  end
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then
    return false
  end

  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = safeYearsRange(vehicleInfo)
      if not vehicleYears then
        return false
      end
      local minYear = parameters.min ~= nil and tonumber(parameters.min) or nil
      local maxYear = parameters.max ~= nil and tonumber(parameters.max) or nil
      if (parameters.min ~= nil and not minYear) or (parameters.max ~= nil and not maxYear) then
        return false
      end
      if (minYear and vehicleYears.max < minYear) or (maxYear and vehicleYears.min > maxYear) then
        return false
      end
    elseif filterName ~= "Mileage" then
      if type(parameters) == "table" and (parameters.min ~= nil or parameters.max ~= nil) then
        local value = safeNumericAttribute(vehicleInfo, filterName)
        if not value or type(value) ~= "number" then
          return false
        end
        local minValue = parameters.min ~= nil and tonumber(parameters.min) or nil
        local maxValue = parameters.max ~= nil and tonumber(parameters.max) or nil
        if (parameters.min ~= nil and not minValue) or (parameters.max ~= nil and not maxValue) then
          return false
        end
        if (minValue and value < minValue) or (maxValue and value > maxValue) then
          return false
        end
      else
        if type(parameters) ~= "table" then
          return false
        end

        -- Empty filter objects are emitted by the facility editor to mean
        -- "no constraint" (for example the private-market Value field).
        if next(parameters) ~= nil then
          local passed = false
          local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[filterName] or nil
          for _, value in ipairs(parameters) do
            if vehicleInfo[filterName] == value or (type(aggregateValue) == "table" and aggregateValue[value]) then
              passed = true
              break
            end
          end
          if not passed then
            return false
          end
        end
      end
    end
  end
  return true
end

local function doesVehiclePassFilter(vehicleInfo, filter)
  if type(filter) ~= "table" then
    return false
  end
  if filter.whiteList and not doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then
    return false
  end
  if filter.blackList and doesVehiclePassFiltersList(vehicleInfo, filter.blackList) then
    return false
  end
  return true
end

-- A configuration can match more than one sub-filter (for example a model
-- produced across two decades). Keep one cache entry per real configuration,
-- while preserving the combined probability and the matching filters used to
-- generate attributes such as model year.
function M.addVehicleToDealerCache(cache, cacheIndexByConfig, vehicleInfo)
  local configKey = getVehicleConfigTrackingKey(vehicleInfo)
  local probability = math.max(0, tonumber(vehicleInfo.subFilterProbability) or 1)
  local matchingFilter = {
    filter = vehicleInfo.precomputedFilter,
    probability = probability,
    selectionIndex = vehicleInfo.precomputedFilter and vehicleInfo.precomputedFilter._selectionIndex or 1
  }
  local existingIndex = cacheIndexByConfig[configKey]

  if existingIndex then
    local existing = cache[existingIndex]
    existing.subFilterProbability = (tonumber(existing.subFilterProbability) or 0) + probability
    existing.precomputedFilters = existing.precomputedFilters or {}
    table.insert(existing.precomputedFilters, matchingFilter)
    return false
  end

  vehicleInfo.subFilterProbability = probability
  vehicleInfo.precomputedFilters = {matchingFilter}
  table.insert(cache, vehicleInfo)
  cacheIndexByConfig[configKey] = #cache
  return true
end

function M.choosePrecomputedFilter(vehicleInfo)
  local filters = vehicleInfo and vehicleInfo.precomputedFilters
  if type(filters) ~= "table" or tableIsEmpty(filters) then
    return vehicleInfo and vehicleInfo.precomputedFilter or nil
  end

  -- The stock lottery may already have selected a weighted sub-filter. Keep
  -- the generated year and other filter-derived attributes in that category.
  if vehicleInfo.selectedSubFilterIndex then
    for _, entry in ipairs(filters) do
      local selectionIndex = entry.selectionIndex or (entry.filter and entry.filter._selectionIndex) or 1
      if selectionIndex == vehicleInfo.selectedSubFilterIndex then
        return entry.filter
      end
    end
  end

  local totalWeight = 0
  for _, entry in ipairs(filters) do
    totalWeight = totalWeight + math.max(0, tonumber(entry.probability) or 1)
  end
  if totalWeight <= 0 then
    return filters[math.random(#filters)].filter
  end

  local cursor = math.random() * totalWeight
  local accumulated = 0
  for _, entry in ipairs(filters) do
    accumulated = accumulated + math.max(0, tonumber(entry.probability) or 1)
    if accumulated >= cursor then
      return entry.filter
    end
  end
  return filters[#filters].filter
end

-- Cache management functions
local function cacheDealers()
  local startTime = os.clock()
  vehicleCache.cacheValid = false
  vehicleCache.dealershipCache = {}
  local totalPartsCalculated = 0

  local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
  local regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(rawEligibleVehicles, "cacheDealers",
    "cacheDropped")
  logVehicleSanitizationSummary("cacheDealers eligible vehicles", eligibleSummary)
  normalizePopulations(regularEligibleVehicles, 0.4)
  vehicleCache.regularVehicles = regularEligibleVehicles
  local richsTopTrimLookup = M.buildRichsTopTrimLookup(regularEligibleVehicles)

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())

  if facilities and facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      local dealershipId = dealership.id

      local filter = dealership.filter or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.filter then
          filter = deepcopy(filter)
          tableMergeRecursive(filter, level.filter)
        end
      end

      local subFilters = dealership.subFilters or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.subFilters then
          subFilters = level.subFilters
        end
      end
      if dealershipId == "richsmotorcompany" then
        -- Rich's prestige rule is value/halo driven and intentionally spans
        -- all model years. Reputation changes stock and terms, not eligibility.
        subFilters = {}
      end

      if filter or subFilters then
        local filteredRegular = {}
        local filteredRegularByConfig = {}
        local filters = {}
        local droppedForDealership = 0

        if subFilters and not tableIsEmpty(subFilters) then
          for selectionIndex, subFilter in ipairs(subFilters) do
            local aggregateFilter = deepcopy(filter or {})
            tableMergeRecursive(aggregateFilter, subFilter)
            aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
            aggregateFilter._selectionIndex = selectionIndex
            table.insert(filters, aggregateFilter)
          end
        else
          local aggregateFilter = deepcopy(filter or {})
          aggregateFilter._probability = 1
          aggregateFilter._selectionIndex = 1
          table.insert(filters, aggregateFilter)
        end

        for _, filter in ipairs(filters) do
          local subProb = filter._probability or filter.probability or 1
          for _, vehicleInfo in ipairs(regularEligibleVehicles) do
            if not isQuarantined(vehicleInfo) then
              local cachedVehicle, err = safeVehicleOp("cacheDealers", vehicleInfo, function()
                if not doesVehiclePassFilter(vehicleInfo, filter) then
                  return false
                end

                local cacheEntry = deepcopy(vehicleInfo)
                cacheEntry.precomputedFilter = filter
                cacheEntry.subFilterProbability = subProb
                normalizeVehicleCatalogValue(cacheEntry, "cacheDealers")
                if dealershipId == "richsmotorcompany" then
                  local qualifies, reason, topTrimData =
                    M.isRichsPrestigeVehicle(cacheEntry, richsTopTrimLookup)
                  if not qualifies then return false end
                  cacheEntry.richsSelectionReason = reason
                  cacheEntry.richsTopTrimData = topTrimData
                end
                return cacheEntry
              end)

              if err then
                droppedForDealership = droppedForDealership + 1
                incrementValidationStat("cacheDropped")
              elseif cachedVehicle then
                if M.addVehicleToDealerCache(filteredRegular, filteredRegularByConfig, cachedVehicle) then
                  totalPartsCalculated = totalPartsCalculated + 1
                end
              end
            end
          end
        end

        vehicleCache.dealershipCache[dealershipId] = vehicleCache.dealershipCache[dealershipId] or {}
        if tableIsEmpty(filteredRegular) then
          log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
            droppedForDealership))
          vehicleCache.dealershipCache[dealershipId].notConfigured = true
        end
        vehicleCache.dealershipCache[dealershipId].regularVehicles = filteredRegular
        vehicleCache.dealershipCache[dealershipId].filters = filters

        log("I", "Career", string.format("cacheDealers dealership %s: kept=%d dropped=%d",
          tostring(dealershipId), #filteredRegular, droppedForDealership))
      end
    end
  end

  local privateVehicles = {}
  local privateVehiclesByConfig = {}
  local privateDropped = 0
  local privateSeller = facilities and facilities.privateSellers and facilities.privateSellers[1] or nil
  local privateBaseFilter = privateSeller and privateSeller.filter or {}
  local privateSubFilters = privateSeller and privateSeller.subFilters or {}
  local privateFilters = {}
  if privateSubFilters and not tableIsEmpty(privateSubFilters) then
    for selectionIndex, subFilter in ipairs(privateSubFilters) do
      local aggregateFilter = deepcopy(privateBaseFilter)
      tableMergeRecursive(aggregateFilter, subFilter)
      aggregateFilter._probability = tonumber(subFilter.probability) or 1
      aggregateFilter._selectionIndex = selectionIndex
      table.insert(privateFilters, aggregateFilter)
    end
  else
    local aggregateFilter = deepcopy(privateBaseFilter)
    aggregateFilter._probability = 1
    aggregateFilter._selectionIndex = 1
    table.insert(privateFilters, aggregateFilter)
  end

  for _, privateFilter in ipairs(privateFilters) do
    for _, sourceVehicle in ipairs(regularEligibleVehicles) do
      local cachedVehicle, err = safeVehicleOp("cacheDealers:private", sourceVehicle, function()
        if not doesVehiclePassFilter(sourceVehicle, privateFilter) then return false end
        local vehicleInfo = deepcopy(sourceVehicle)
        normalizeVehicleCatalogValue(vehicleInfo, "cacheDealers:private")
        vehicleInfo.precomputedFilter = privateFilter
        vehicleInfo.subFilterProbability = privateFilter._probability or 1
        return vehicleInfo
      end)
      if err then
        privateDropped = privateDropped + 1
        incrementValidationStat("cacheDropped")
      elseif cachedVehicle then
        M.addVehicleToDealerCache(privateVehicles, privateVehiclesByConfig, cachedVehicle)
      end
    end
  end
  totalPartsCalculated = totalPartsCalculated + #privateVehicles

  vehicleCache.dealershipCache["private"] = {
    regularVehicles = privateVehicles,
    filters = privateFilters
  }
  if tableIsEmpty(privateVehicles) then
    vehicleCache.dealershipCache["private"].notConfigured = true
  end

  vehicleCache.lastCacheTime = os.time()
  vehicleCache.cacheValid = true
  log("I", "Career", string.format(
    "cacheDealers complete: raw=%d kept=%d malformed=%d quarantined=%d privateKept=%d privateDropped=%d partsCalculated=%d time=%.3fs",
    eligibleSummary.raw, eligibleSummary.kept, eligibleSummary.malformed, eligibleSummary.quarantined,
    #privateVehicles, privateDropped, totalPartsCalculated, os.clock() - startTime))
end

local function getRandomVehicleFromCache(sellerId, count, excludedConfigKeys)
  if not vehicleCache.cacheValid then
    log("W", "Career", "Vehicle cache invalid, rebuilding...")
    cacheDealers()
  end

  local dealershipData = vehicleCache.dealershipCache[sellerId]
  if not dealershipData then
    log("W", "Career", "No cached data for seller: " .. tostring(sellerId))
    return {}
  end

  local sourceVehicles
  sourceVehicles = dealershipData.regularVehicles or {}

  local sanitizedSourceVehicles, sourceSummary = sanitizeVehicleInfoList(sourceVehicles, "getRandomVehicleFromCache",
    "cacheDropped")
  if sourceSummary.malformed > 0 or sourceSummary.quarantined > 0 then
    logVehicleSanitizationSummary("getRandomVehicleFromCache " .. tostring(sellerId), sourceSummary)
  end

  if tableIsEmpty(sanitizedSourceVehicles) then
    log("W", "Career", "No cached vehicles available for seller: " .. tostring(sellerId))
    return {}
  end

  local selectedVehicles = {}
  local availableVehicles = {}
  local seenConfigKeys = {}
  for _, vehicle in ipairs(sanitizedSourceVehicles) do
    local configKey = getVehicleConfigTrackingKey(vehicle)
    if not seenConfigKeys[configKey] and not (excludedConfigKeys and excludedConfigKeys[configKey]) then
      seenConfigKeys[configKey] = true
      table.insert(availableVehicles, deepcopy(vehicle))
    end
  end

  local requestedCount = math.max(0, math.floor(tonumber(count) or 0))
  local targetCount = math.min(requestedCount, #availableVehicles)
  local selectedModelCounts = {}

  while #selectedVehicles < targetCount do
    for j = #availableVehicles, 1, -1 do
      local vehicle = availableVehicles[j]
      if isQuarantined(vehicle) then
        table.remove(availableVehicles, j)
        incrementValidationStat("cacheDropped")
      else
        local ok, reason = isValidVehicleInfoShape(vehicle)
        if not ok then
          quarantineVehicleConfig(vehicle, reason, "getRandomVehicleFromCache")
          table.remove(availableVehicles, j)
          incrementValidationStat("cacheDropped")
        end
      end
    end

    if tableIsEmpty(availableVehicles) then
      break
    end

    -- Honor the dealership's weighted sub-filters before choosing a model.
    -- Within the selected category every eligible model still gets exactly one
    -- lottery ticket, so adding configurations to a mod cannot increase that
    -- model's chance. Population only chooses a config after the model wins.
    local candidatesByCategory = {}
    local hasUnusedRichsModel = false
    for index, vehicle in ipairs(availableVehicles) do
      if sellerId == "richsmotorcompany" and not selectedModelCounts[vehicle.model_key] then
        hasUnusedRichsModel = true
      end

      local matchingFilters = vehicle.precomputedFilters
      if type(matchingFilters) ~= "table" or tableIsEmpty(matchingFilters) then
        matchingFilters = {{
          filter = vehicle.precomputedFilter,
          probability = vehicle.subFilterProbability or 1,
          selectionIndex = vehicle.precomputedFilter and vehicle.precomputedFilter._selectionIndex or 1
        }}
      end

      for _, matchingFilter in ipairs(matchingFilters) do
        local selectionIndex = matchingFilter.selectionIndex
          or (matchingFilter.filter and matchingFilter.filter._selectionIndex) or 1
        local category = candidatesByCategory[selectionIndex]
        if not category then
          category = {
            probability = math.max(0, tonumber(matchingFilter.probability) or 1),
            candidatesByModel = {}
          }
          candidatesByCategory[selectionIndex] = category
        end
        local modelCandidates = category.candidatesByModel[vehicle.model_key]
        if not modelCandidates then
          modelCandidates = {}
          category.candidatesByModel[vehicle.model_key] = modelCandidates
        end
        table.insert(modelCandidates, index)
      end
    end

    local selectableCategories = {}
    local totalCategoryWeight = 0
    for selectionIndex, category in pairs(candidatesByCategory) do
      category.modelKeys = {}
      for modelKey in pairs(category.candidatesByModel) do
        if not hasUnusedRichsModel or not selectedModelCounts[modelKey] then
          table.insert(category.modelKeys, modelKey)
        end
      end
      table.sort(category.modelKeys)
      if not tableIsEmpty(category.modelKeys) then
        table.insert(selectableCategories, selectionIndex)
        totalCategoryWeight = totalCategoryWeight + category.probability
      end
    end
    table.sort(selectableCategories)
    if tableIsEmpty(selectableCategories) then break end

    local selectedCategoryIndex
    if totalCategoryWeight <= 0 then
      selectedCategoryIndex = selectableCategories[math.random(#selectableCategories)]
    else
      local cursor = math.random() * totalCategoryWeight
      local accumulated = 0
      for _, selectionIndex in ipairs(selectableCategories) do
        accumulated = accumulated + candidatesByCategory[selectionIndex].probability
        if accumulated >= cursor then
          selectedCategoryIndex = selectionIndex
          break
        end
      end
      selectedCategoryIndex = selectedCategoryIndex or selectableCategories[#selectableCategories]
    end

    local selectedCategory = candidatesByCategory[selectedCategoryIndex]
    local modelKeys = selectedCategory.modelKeys
    local selectedModel = modelKeys[math.random(#modelKeys)]
    local candidateIndices = selectedCategory.candidatesByModel[selectedModel]
    local totalWeight = 0
    for _, index in ipairs(candidateIndices) do
      local vehicle = availableVehicles[index]
      local population = math.max(0, tonumber(vehicle.adjustedPopulation) or 1)
      totalWeight = totalWeight + population
    end

    local selectedIndex
    if totalWeight <= 0 then
      selectedIndex = candidateIndices[math.random(#candidateIndices)]
    else
      local cursor = math.random() * totalWeight
      local accumulated = 0
      for _, index in ipairs(candidateIndices) do
        local vehicle = availableVehicles[index]
        local population = math.max(0, tonumber(vehicle.adjustedPopulation) or 1)
        accumulated = accumulated + population
        if accumulated >= cursor then
          selectedIndex = index
          break
        end
      end
      selectedIndex = selectedIndex or candidateIndices[#candidateIndices]
    end

    local selectedVehicle = availableVehicles[selectedIndex]
    selectedVehicle.selectedSubFilterIndex = selectedCategoryIndex
    table.insert(selectedVehicles, selectedVehicle)
    selectedModelCounts[selectedVehicle.model_key] = (selectedModelCounts[selectedVehicle.model_key] or 0) + 1
    table.remove(availableVehicles, selectedIndex)
  end

  return selectedVehicles
end

local function invalidateVehicleCache()
  vehicleCache.cacheValid = false
  vehicleCache.regularVehicles = {}
  vehicleCache.dealershipCache = {}
  career_modules_valueCalculator.clearVehiclePcPartsCatalogSumCache()
  resetVehicleValidationState()
end

local function rebuildDealershipCache(dealershipId)
  if not vehicleCache.cacheValid then
    cacheDealers()
    return
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilities or not facilities.dealerships then
    return
  end

  local dealership = nil
  for _, d in ipairs(facilities.dealerships) do
    if d.id == dealershipId then
      dealership = d
      break
    end
  end

  if not dealership then
    return
  end

  local regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(vehicleCache.regularVehicles or {},
    "rebuildDealershipCache:cachedEligible", "cacheDropped")
  if eligibleSummary.raw > 0 then
    vehicleCache.regularVehicles = regularEligibleVehicles
  end
  if not regularEligibleVehicles or tableIsEmpty(regularEligibleVehicles) then
    local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
    regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(rawEligibleVehicles, "rebuildDealershipCache",
      "cacheDropped")
    logVehicleSanitizationSummary("rebuildDealershipCache eligible vehicles", eligibleSummary)
    normalizePopulations(regularEligibleVehicles, 0.4)
    vehicleCache.regularVehicles = regularEligibleVehicles
  end
  local richsTopTrimLookup = M.buildRichsTopTrimLookup(regularEligibleVehicles)

  local filter = dealership.filter or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = getOrgLevelData(org)
    if level and level.filter then
      filter = deepcopy(filter)
      tableMergeRecursive(filter, level.filter)
    end
  end

  local subFilters = dealership.subFilters or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = getOrgLevelData(org)
    if level and level.subFilters then
      subFilters = level.subFilters
    end
  end
  if dealershipId == "richsmotorcompany" then
    subFilters = {}
  end

  local filteredRegular = {}
  local filteredRegularByConfig = {}
  local filters = {}
  local droppedForDealership = 0

  if subFilters and not tableIsEmpty(subFilters) then
    for selectionIndex, subFilter in ipairs(subFilters) do
      local aggregateFilter = deepcopy(filter or {})
      tableMergeRecursive(aggregateFilter, subFilter)
      aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
      aggregateFilter._selectionIndex = selectionIndex
      table.insert(filters, aggregateFilter)
    end
  else
    local aggregateFilter = deepcopy(filter or {})
    aggregateFilter._probability = 1
    aggregateFilter._selectionIndex = 1
    table.insert(filters, aggregateFilter)
  end

  for _, f in ipairs(filters) do
    local subProb = f._probability or f.probability or 1
    for _, vehicleInfo in ipairs(regularEligibleVehicles) do
      if not isQuarantined(vehicleInfo) then
        local cachedVehicle, err = safeVehicleOp("rebuildDealershipCache", vehicleInfo, function()
          if not doesVehiclePassFilter(vehicleInfo, f) then
            return false
          end

          local cacheEntry = deepcopy(vehicleInfo)
          cacheEntry.precomputedFilter = f
          cacheEntry.subFilterProbability = subProb
          normalizeVehicleCatalogValue(cacheEntry, "rebuildDealershipCache")
          if dealershipId == "richsmotorcompany" then
            local qualifies, reason, topTrimData =
              M.isRichsPrestigeVehicle(cacheEntry, richsTopTrimLookup)
            if not qualifies then return false end
            cacheEntry.richsSelectionReason = reason
            cacheEntry.richsTopTrimData = topTrimData
          end
          return cacheEntry
        end)

        if err then
          droppedForDealership = droppedForDealership + 1
          incrementValidationStat("cacheDropped")
        elseif cachedVehicle then
          M.addVehicleToDealerCache(filteredRegular, filteredRegularByConfig, cachedVehicle)
        end
      end
    end
  end

  local notConfigured = tableIsEmpty(filteredRegular)
  if notConfigured then
    log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
      droppedForDealership))
  end

  vehicleCache.dealershipCache[dealershipId] = {
    regularVehicles = filteredRegular,
    filters = filters,
    notConfigured = notConfigured
  }

  log("I", "Career", string.format(
    "Rebuilt cache for dealership %s: kept=%d dropped=%d rawEligible=%d validEligible=%d malformed=%d quarantined=%d",
    dealershipId, #filteredRegular, droppedForDealership, eligibleSummary.raw, eligibleSummary.kept,
    eligibleSummary.malformed, eligibleSummary.quarantined))
end

-- Vehicle list management functions
local function updateVehicleList(fromScratch)
  fromScratch = not not fromScratch
  local sellers = {}
  local currentMap = getCurrentLevelIdentifier()
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()
  local changed = false
  local updateSummary = {
    attempted = 0,
    inserted = 0,
    dropped = 0
  }

  if fromScratch then
    invalidateVehicleCache()
    vehiclesInShop = {}
    sellersInfos = {}
    vehicleWatchlist = {}
    changed = true
  end

  -- If there are already vehicles in the shop, don't generate starter vehicles
  if onlyStarterVehicles and not tableIsEmpty(vehiclesInShop) then
    nextShopUpdateTime = os.time() + 3600
    return
  end

  local filteredVehiclesInShop = {}
  for i, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.mapId == currentMap then
      table.insert(filteredVehiclesInShop, vehicleInfo)
    else
      changed = true
    end
  end
  vehiclesInShop = filteredVehiclesInShop

  local filteredSellersInfos = {}
  for sellerId, sellerInfo in pairs(sellersInfos) do
    if sellerInfo.mapId == currentMap then
      filteredSellersInfos[sellerId] = sellerInfo
    else
      changed = true
    end
  end
  sellersInfos = filteredSellersInfos

  if not vehicleCache.cacheValid then
    cacheDealers()
    changed = true
  end

  local facilitiesData = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilitiesData then
    log("W", "Career", "No facilities data available for current map; skipping vehicle list update")
    nextShopUpdateTime = os.time() + 60
    return
  end
  local facilities = facilitiesData

  if facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      if onlyStarterVehicles then
        if dealership.containsStarterVehicles then
          table.insert(sellers, {
            id = dealership.id,
            name = dealership.name,
            description = dealership.description,
            preview = dealership.preview,
            hiddenFromDealerList = dealership.hiddenFromDealerList or isPoliceDealershipLocked(dealership.id),
            associatedOrganization = dealership.associatedOrganization,
            vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
            stock = dealership.stock,
            range = dealership.range,
            fees = dealership.fees,
            salesTax = dealership.salesTax,
            priceRoundingType = dealership.priceRoundingType,
            filter = {whiteList = {careerStarterVehicle = {true}}},
            subFilters = nil
          })
        end
      else
        table.insert(sellers, {
          id = dealership.id,
          name = dealership.name,
          description = dealership.description,
          preview = dealership.preview,
          hiddenFromDealerList = dealership.hiddenFromDealerList or isPoliceDealershipLocked(dealership.id),
          associatedOrganization = dealership.associatedOrganization,
          vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
          stock = dealership.stock,
          range = dealership.range,
          fees = dealership.fees,
          salesTax = dealership.salesTax,
            priceRoundingType = dealership.priceRoundingType,
            salesChannel = dealership.salesChannel,
            mileageProfile = dealership.mileageProfile,
            remanCommercial = dealership.remanCommercial,
            remotePurchaseLevel = dealership.remotePurchaseLevel,
            garageDeliveryLevel = dealership.garageDeliveryLevel,
            deliveryDiscountLevel = dealership.deliveryDiscountLevel,
            deliveryDiscount = dealership.deliveryDiscount,
            freightPickupSpotNames = dealership.freightPickupSpotNames,
            filter = dealership.filter or {},
            subFilters = dealership.subFilters
        })
      end
    end
  end

  if not onlyStarterVehicles and facilities.privateSellers then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, {
        id = dealership.id,
        name = dealership.name,
        description = dealership.description,
        preview = dealership.preview,
        hiddenFromDealerList = dealership.hiddenFromDealerList,
        associatedOrganization = dealership.associatedOrganization,
        vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
        stock = dealership.stock,
        range = dealership.range,
        fees = dealership.fees,
        salesTax = dealership.salesTax,
          priceRoundingType = dealership.priceRoundingType,
          salesChannel = dealership.salesChannel or "private",
          filter = dealership.filter or {},
          subFilters = dealership.subFilters
      })
    end
  end
  table.sort(sellers, function(a, b)
    return a.id < b.id
  end)

  if M.pruneBlacklistedSellerStock(sellers) > 0 then
    changed = true
  end

  local currentTime = os.time()

  -- Track which vehicles are being marked as sold this update
  local justExpiredShopIds = {}

  -- Remove vehicles that have expired using v38 watchlist logic
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    normalizeVehicleShopTiming(vehicleInfo, currentTime)
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      if vehicleWatchlist[vehicleInfo.shopId] then
        if type(vehicleWatchlist[vehicleInfo.shopId]) ~= "number" then
          vehicleWatchlist[vehicleInfo.shopId] = currentTime + timeToRemoveSoldVehicle
          if not vehicleInfo.soldFor then
            vehicleInfo.soldFor = generateSoldVehicleValue(vehicleInfo.shopId)
          end
        end
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
        vehicleInfo.markedSold = true
        justExpiredShopIds[vehicleInfo.shopId] = true
        changed = true
        if currentTime > vehicleWatchlist[vehicleInfo.shopId] then
          vehicleWatchlist[vehicleInfo.shopId] = nil
          table.remove(vehiclesInShop, i)
          changed = true
        end
      else
        table.remove(vehiclesInShop, i)
        changed = true
      end
    end
  end

  local unsoldCountBySellerId = {}
  local stockedConfigsBySeller = {}
  local duplicateStockRemoved = 0
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    if vehicleInfo.sellerId and not vehicleInfo.soldViewCounter then
      if isCarMeetShopVehicle(vehicleInfo) then
        unsoldCountBySellerId[vehicleInfo.sellerId] = (unsoldCountBySellerId[vehicleInfo.sellerId] or 0) + 1
      else
        local sellerConfigKeys = stockedConfigsBySeller[vehicleInfo.sellerId] or {}
        stockedConfigsBySeller[vehicleInfo.sellerId] = sellerConfigKeys
        local configKey = getVehicleConfigTrackingKey(vehicleInfo)
        if sellerConfigKeys[configKey] then
          table.remove(vehiclesInShop, i)
          duplicateStockRemoved = duplicateStockRemoved + 1
          changed = true
        else
          sellerConfigKeys[configKey] = true
          unsoldCountBySellerId[vehicleInfo.sellerId] = (unsoldCountBySellerId[vehicleInfo.sellerId] or 0) + 1
        end
      end
    end
  end
  if duplicateStockRemoved > 0 then
    log("I", "Career", string.format("Removed %d duplicate dealer configuration listings", duplicateStockRemoved))
  end

  local sellerMeta = {}

  for _, seller in ipairs(sellers) do
    local sellerAttemptedStart = updateSummary.attempted
    local sellerInsertedStart = updateSummary.inserted
    local sellerDroppedStart = updateSummary.dropped
    local dealershipData = vehicleCache.dealershipCache[seller.id]
    if dealershipData and dealershipData.notConfigured then
      goto continue
    end

    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap,
        lastOrgLevel = nil
      }
      changed = true
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    local currentVehicleCount = unsoldCountBySellerId[seller.id] or 0
    local stockedConfigKeys = {}
    for _, stockedVehicle in ipairs(vehiclesInShop) do
      if stockedVehicle.sellerId == seller.id and not stockedVehicle.soldViewCounter then
        stockedConfigKeys[getVehicleConfigTrackingKey(stockedVehicle)] = true
      end
    end

    local function drawUnstockedSellerVehicles(drawCount)
      local selected = getRandomVehicleFromCache(seller.id, drawCount, stockedConfigKeys)
      for _, selectedVehicle in ipairs(selected) do
        stockedConfigKeys[getVehicleConfigTrackingKey(selectedVehicle)] = true
      end
      return selected
    end

    local currentOrgLevel = nil
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      if org and org.reputation then
        local repLevel = org.reputation.level or 0
        if type(repLevel) ~= "number" then
          repLevel = 0
        end
        currentOrgLevel = math.max(0, repLevel)
      end
    end

    local storedLevel = sellersInfos[seller.id].lastOrgLevel
    local levelChanged = (currentOrgLevel ~= nil) and (storedLevel ~= nil) and (storedLevel ~= currentOrgLevel)

    local maxStock = tonumber(seller.stock) or 10
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = getOrgLevelData(org)
      local levelStock = level and tonumber(level.stock) or nil
      if levelStock then
        maxStock = levelStock
      end
    end
    maxStock = math.max(math.floor(maxStock), 1)
    local availableSlots = math.max(0, maxStock - currentVehicleCount)

    local numberOfVehiclesToGenerate = 0
    local adjustedTimeBetweenOffers = vehicleOfferTimeToLive / maxStock
    local generationMultiplier = tonumber(seller.vehicleGenerationMultiplier)
    if generationMultiplier and generationMultiplier > 0 then
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers / generationMultiplier
    end

    if onlyStarterVehicles then
      -- Generate the starter vehicles
      local eligibleVehiclesStarterRaw = util_configListGenerator.getEligibleVehicles(onlyStarterVehicles) or {}
      local eligibleVehiclesStarter, starterSummary = sanitizeVehicleInfoList(eligibleVehiclesStarterRaw,
        "updateVehicleList:starterEligible", "generationDropped")
      if starterSummary.malformed > 0 or starterSummary.quarantined > 0 then
        logVehicleSanitizationSummary("updateVehicleList starter eligible vehicles", starterSummary)
      end
      randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 3, eligibleVehiclesStarter,
        "adjustedPopulation") or {}
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local maxVehicles = math.floor(vehicleOfferTimeToLive / adjustedTimeBetweenOffers)
      numberOfVehiclesToGenerate = math.min(math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / adjustedTimeBetweenOffers), maxVehicles)

      if levelChanged then
        rebuildDealershipCache(seller.id)
        numberOfVehiclesToGenerate = availableSlots
        sellersInfos[seller.id].lastGenerationTime = 0
        log("I", "Career", string.format("Level changed for %s (from %d to %d), restocking to %d vehicles", 
          seller.id, storedLevel, currentOrgLevel, availableSlots))
      elseif fromScratch or sellersInfos[seller.id].lastGenerationTime == 0 then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      elseif availableSlots > 0 and numberOfVehiclesToGenerate < availableSlots then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Stock below target for %s: generating %d vehicles to reach %d", seller.id, availableSlots, maxStock))
      end

      -- Generate unique configurations that are not already stocked by this seller.
      local newRandomVehicleInfos = drawUnstockedSellerVehicles(numberOfVehiclesToGenerate)
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("W", "Career", string.format(
          "Seller %s is short %d unique eligible configurations; leaving those stock slots empty",
          tostring(seller.id), numberOfMissingVehicles))
      end
    end

    local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
    local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}
    local targetVehicleCount = onlyStarterVehicles and tableSize(randomVehicleInfos) or numberOfVehiclesToGenerate
    local successfulGenerationsForSeller = 0
    local replacementCycles = 0
    local maxReplacementCycles = onlyStarterVehicles and 0 or 2
    local nextBatchStartIndex = 1
    local attemptedGenerationForSeller = false

    if onlyStarterVehicles then
      attemptedGenerationForSeller = not tableIsEmpty(randomVehicleInfos)
    elseif numberOfVehiclesToGenerate > 0 then
      attemptedGenerationForSeller = true
    end

    while nextBatchStartIndex <= #randomVehicleInfos and successfulGenerationsForSeller < targetVehicleCount do
      local batchEndIndex = #randomVehicleInfos
      for i = nextBatchStartIndex, batchEndIndex do
        if successfulGenerationsForSeller >= targetVehicleCount then
          break
        end

        local randomVehicleInfo = randomVehicleInfos[i]
        updateSummary.attempted = updateSummary.attempted + 1
        if isQuarantined(randomVehicleInfo) then
          updateSummary.dropped = updateSummary.dropped + 1
          incrementValidationStat("generationDropped")
        else
          local shapeOk, shapeReason = isValidVehicleInfoShape(randomVehicleInfo)
          if not shapeOk then
            quarantineVehicleConfig(randomVehicleInfo, shapeReason, "updateVehicleList")
            updateSummary.dropped = updateSummary.dropped + 1
            incrementValidationStat("generationDropped")
          else
            local generatedVehicle, err = safeVehicleOp("updateVehicleList", randomVehicleInfo, function()
              randomVehicleInfo.generationTime = currentTime - (successfulGenerationsForSeller * adjustedTimeBetweenOffers)
              randomVehicleInfo.offerTTL = onlyStarterVehicles and math.huge or vehicleOfferTimeToLive

              randomVehicleInfo.sellerId = seller.id
              randomVehicleInfo.sellerName = seller.name
              randomVehicleInfo.salesChannel = seller.salesChannel or (seller.id == "private" and "private" or "local")

              local filter = M.choosePrecomputedFilter(randomVehicleInfo)
              if not filter and seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.filter then
                  filter = level.filter
                end
              end
              filter = filter or (seller.filter or {})
              randomVehicleInfo.filter = filter

              local years = safeYearsRange(randomVehicleInfo)

              if not onlyStarterVehicles then
                if years then
                  local minYear = years.min
                  local filterMinYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.min)
                  if filterMinYear then
                    minYear = math.max(minYear, filterMinYear)
                  end
                  local maxYear = years.max
                  local filterMaxYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.max)
                  if filterMaxYear then
                    maxYear = math.min(maxYear, filterMaxYear)
                  end
                  if minYear > maxYear then
                    error("invalid year bounds after filtering")
                  end
                  randomVehicleInfo.year = math.random(minYear, maxYear)
                else
                  randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or missingYearsFallbackModelYear
                end

                randomVehicleInfo.Mileage, randomVehicleInfo.wearMileage, randomVehicleInfo.mileageClass =
                  generateAgeDrivenMileage(seller, randomVehicleInfo, randomVehicleInfo.year)
              else
                randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
                if not randomVehicleInfo.year then
                  if years then
                    randomVehicleInfo.year = math.random(years.min, years.max)
                  else
                    randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or missingYearsFallbackModelYear
                  end
                end
                randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key] or 100000000
              end

              local valuationYear = tonumber(os.date("%Y")) or 2026
              local vehicleAge = math.max(0, valuationYear - (tonumber(randomVehicleInfo.year) or valuationYear))
              local catalogBaseValue = randomVehicleInfo.effectiveCatalogValue or randomVehicleInfo.Value
              local valuation = career_modules_valueCalculator.getVehicleValuation and
                career_modules_valueCalculator.getVehicleValuation({
                  catalogBaseValue = catalogBaseValue,
                  mileageMeters = randomVehicleInfo.Mileage,
                  age = vehicleAge,
                  modelName = randomVehicleInfo.model_key,
                  configKey = randomVehicleInfo.key,
                  configInfo = randomVehicleInfo,
                  partsCatalogSum = randomVehicleInfo.cachedPartsValue,
                  logContext = "updateVehicleList",
                  applyVehicleBuyMarket = false
                }) or nil
              local baseValue = valuation and valuation.bookValue or
                career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
                catalogBaseValue = catalogBaseValue,
                mileageMeters = randomVehicleInfo.Mileage,
                age = vehicleAge,
                modelName = randomVehicleInfo.model_key,
                configKey = randomVehicleInfo.key,
                partsCatalogSum = randomVehicleInfo.cachedPartsValue,
                logContext = "updateVehicleList",
                applyVehicleBuyMarket = false
              }) or math.max(1500,
                math.floor(career_modules_valueCalculator.getAdjustedVehicleBaseValue(catalogBaseValue, {
                  mileage = randomVehicleInfo.Mileage,
                  age = vehicleAge
                }) / 1000) * 1000)
              randomVehicleInfo.valuation = valuation
              if valuation then
                randomVehicleInfo.haloScore = valuation.haloScore
                randomVehicleInfo.haloSignals = valuation.haloSignals
              end

              local range = seller.range
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.range then
                  range = level.range
                end
              end

              if seller.id == "private" then
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
                  randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality.name
                end
              else
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  local personalityKey = seller.id
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false,
                    {personalityKey})
                end
              end

              local randomizedValue, priceBand, dealerPriceMultiplier = getRandomizedPrice(baseValue, range)
              randomVehicleInfo.marketValue = randomizedValue
              randomVehicleInfo.marketValueBase = randomVehicleInfo.marketValue
              randomVehicleInfo.priceRoundingType = seller.priceRoundingType
              randomVehicleInfo.priceBand = priceBand
              randomVehicleInfo.dealerPriceMultiplier = dealerPriceMultiplier

              local priceMultiplier = (randomVehicleInfo.negotiationPersonality and
                                        randomVehicleInfo.negotiationPersonality.priceMultiplier) or 1
              priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
              local combinedMultiplier = dealerPriceMultiplier * priceMultiplier
              if priceBand == "lowTail" then
                combinedMultiplier = math.max(0.70, math.min(0.88, combinedMultiplier))
              elseif priceBand == "highTail" then
                combinedMultiplier = math.max(1.12, math.min(1.30, combinedMultiplier))
              else
                combinedMultiplier = math.max(0.88, math.min(1.12, combinedMultiplier))
              end
              randomVehicleInfo.valueBase = baseValue * combinedMultiplier
              randomVehicleInfo.priceMultiplier = priceMultiplier
              randomVehicleInfo.combinedSellerMultiplier = combinedMultiplier

              local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
              randomVehicleInfo.Value = getRoundedPrice(randomVehicleInfo.valueBase * vehicleBuyMult,
                seller.priceRoundingType)

              randomVehicleInfo.negotiationPossible = not onlyStarterVehicles
              randomVehicleInfo.shopId = generateShopId()
              randomVehicleInfo.associatedOrganization = seller.associatedOrganization
              local dealership = freeroam_facilities.getDealership(seller.id)
              local accessInfo = getSellerAccessInfo(dealership)
              randomVehicleInfo.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
              randomVehicleInfo.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
              randomVehicleInfo.deliveryDiscount = accessInfo.deliveryDiscount

              local fees = seller.fees or 0
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.fees ~= nil then
                  fees = level.fees
                end
              end
              fees = tonumber(fees)
              randomVehicleInfo.fees = fees or 0

              local tax = seller.salesTax or salesTax
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.tax ~= nil then
                  tax = level.tax
                end
              end
              tax = tonumber(tax)
              randomVehicleInfo.tax = tax or salesTax

              if seller.id == "private" then
                local parkingData = gameplay_parking.getParkingSpots()
                local parkingSpots = parkingData and parkingData.byName or {}
                local sizeMatches, allowedSpots = {}, {}
                local boxX, boxY, boxZ = safeBoundingBoxDimensions(randomVehicleInfo)
                for name, spot in pairs(parkingSpots) do
                  local tags = (spot.customFields and spot.customFields.tags) or {}
                  if not tags.notprivatesale then
                    table.insert(allowedSpots, {
                      name = name,
                      spot = spot
                    })
                    if boxX and spot.boxFits and spot:boxFits(boxX, boxY, boxZ) then
                      table.insert(sizeMatches, {
                        name = name,
                        spot = spot
                      })
                    end
                  end
                end

                local pool = (#sizeMatches > 0) and sizeMatches or allowedSpots
                local chosen = nil
                if #pool > 0 then
                  chosen = pool[math.random(#pool)]
                end
                if chosen then
                  randomVehicleInfo.parkingSpotName = chosen.name
                  randomVehicleInfo.pos = chosen.spot.pos
                else
                  log("W", "Career",
                    string.format("No parking spot available for private sale vehicle %s",
                      tostring(randomVehicleInfo.shopId)))
                end
              else
                local dealership = freeroam_facilities.getDealership(seller.id)
                randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
              end

              if career_modules_insurance_insurance and
                career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData then
                local vehicleInsuranceClass =
                  career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
                if vehicleInsuranceClass then
                  randomVehicleInfo.insuranceClass = vehicleInsuranceClass
                end
              end

              if career_modules_insurance and career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData then
                local requiredInsurance =
                  career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
                if requiredInsurance then
                  randomVehicleInfo.requiredInsurance = requiredInsurance
                end
              end

              randomVehicleInfo.mapId = currentMap
              return randomVehicleInfo
            end)

            if err or not generatedVehicle then
              updateSummary.dropped = updateSummary.dropped + 1
              incrementValidationStat("generationDropped")
            else
              table.insert(vehiclesInShop, generatedVehicle)
              if generatedVehicle.sellerId and not generatedVehicle.soldViewCounter then
                unsoldCountBySellerId[generatedVehicle.sellerId] = (unsoldCountBySellerId[generatedVehicle.sellerId] or 0) + 1
              end
              changed = true
              updateSummary.inserted = updateSummary.inserted + 1
              successfulGenerationsForSeller = successfulGenerationsForSeller + 1
            end
          end
        end
      end

      nextBatchStartIndex = batchEndIndex + 1
      if successfulGenerationsForSeller >= targetVehicleCount or replacementCycles >= maxReplacementCycles then
        break
      end

      local replacementCount = targetVehicleCount - successfulGenerationsForSeller
      if replacementCount <= 0 then
        break
      end

      replacementCycles = replacementCycles + 1
      local replacementVehicles = drawUnstockedSellerVehicles(replacementCount)
      if tableIsEmpty(replacementVehicles) then
        break
      end

      attemptedGenerationForSeller = true
      arrayConcat(randomVehicleInfos, replacementVehicles)
    end
    if successfulGenerationsForSeller >= targetVehicleCount then
      sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    elseif attemptedGenerationForSeller and targetVehicleCount == 0 then
      sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    end
    if updateSummary.attempted > sellerAttemptedStart then
      log("I", "Career", string.format("updateVehicleList seller %s: attempted=%d inserted=%d dropped=%d",
        tostring(seller.id),
        updateSummary.attempted - sellerAttemptedStart,
        updateSummary.inserted - sellerInsertedStart,
        updateSummary.dropped - sellerDroppedStart))
    end

    if currentOrgLevel ~= nil then
      sellersInfos[seller.id].lastOrgLevel = currentOrgLevel
    end

    sellerMeta[seller.id] = {
      maxStock = maxStock,
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers
    }

    ::continue::
  end

  local minNext = math.huge
  for _, veh in ipairs(vehiclesInShop) do
    if veh.generationTime and veh.offerTTL then
      local expiryTime = veh.generationTime + veh.offerTTL
      if expiryTime > currentTime and expiryTime < minNext then
        minNext = expiryTime
      end
    end
  end
  for _, seller in ipairs(sellers) do
    local meta = sellerMeta[seller.id]
    local fallbackMaxStock = math.max(math.floor(tonumber(seller.stock) or 10), 1)
    local maxStock = meta and meta.maxStock or fallbackMaxStock
    local currentCount = unsoldCountBySellerId[seller.id] or 0
    local availableSlotsAfter = math.max(0, maxStock - currentCount)
    if availableSlotsAfter > 0 then
      local lastGen = (sellersInfos[seller.id] and sellersInfos[seller.id].lastGenerationTime) or 0
      local interval = meta and meta.adjustedTimeBetweenOffers or (vehicleOfferTimeToLive / maxStock)
      local nextGen = (lastGen > 0 and (lastGen + interval)) or currentTime
      if nextGen < minNext then
        minNext = nextGen
      end
    end
  end
  if minNext == math.huge then
    minNext = currentTime + 60
  end
  nextShopUpdateTime = minNext

  if not changed then
    return
  end

  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
  log("I", "Career", string.format("updateVehicleList summary: attempted=%d inserted=%d dropped=%d",
    updateSummary.attempted, updateSummary.inserted, updateSummary.dropped))

  local newSnap = buildSnapshot()
  commitDelta(newSnap, justExpiredShopIds)
  guihooks.trigger("vehicleShopDelta", lastDelta)
end

-- Vehicle spawning and delivery functions
local spawnFollowUpActions
local canPurchaseCarMeetVehicle

-- Private listings advertise a real parking spot (chosen in updateVehicleList) - that is the spot
-- the taxi and the route marker point at, so a bought vehicle has to actually turn up there.
function M.moveVehicleToListingSpot(vehObj, vehicleInfo)
  if not vehObj or not vehicleInfo or not vehicleInfo.parkingSpotName then return false end
  local parkingData = gameplay_parking.getParkingSpots()
  local spot = parkingData and parkingData.byName and parkingData.byName[vehicleInfo.parkingSpotName]
  if not spot then
    log("D", "Career", "Listing parking spot '" .. tostring(vehicleInfo.parkingSpotName) .. "' not found")
    return false
  end
  spot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
  return true
end

-- Not every seller has a facility: private sellers park in the world, so getDealership("private")
-- returns nil and the old unguarded chain threw while spawning a just-purchased vehicle.
-- Leave the vehicle where it spawned rather than taking the whole purchase down with it.
local function moveVehicleToDealership(vehObj, dealershipId, useFreightPickup)
  if not vehObj or not dealershipId then return false end
  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    log("D", "Career", "No dealership facility for '" .. tostring(dealershipId) .. "'; leaving vehicle at spawn")
    return false
  end
  if useFreightPickup and type(dealership.freightPickupSpotNames) == "table" then
    dealership = deepcopy(dealership)
    dealership.parkingSpotNames = dealership.freightPickupSpotNames
  end
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  if not parkingSpots or not next(parkingSpots) then return false end
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  if not parkingSpot then return false end
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
  return true
end

local function moveVehicleToRewardTransform(vehObj, transform)
  if not vehObj or type(transform) ~= "table" then return end

  local pos = transform.pos or transform.position
  if not pos then return end

  local rot = transform.rot or transform.rotation or {}
  local px = tonumber(pos.x or pos[1])
  local py = tonumber(pos.y or pos[2])
  local pz = tonumber(pos.z or pos[3])
  if not px or not py or not pz then return end

  local qx = tonumber(rot.x or rot[1]) or 0
  local qy = tonumber(rot.y or rot[2]) or 0
  local qz = tonumber(rot.z or rot[3]) or 0
  local qw = tonumber(rot.w or rot[4]) or 1
  if spawn and spawn.safeTeleport then
    -- safeTeleport applies BeamNG's vehicle-facing 180 degree correction internally.
    -- Pre-correct the input so reward vehicles retain the heading stored in the report.
    local rewardRot = quat(qx, qy, qz, qw)
    local safeTeleportRot = quat(0, 0, -1, 0) * rewardRot
    spawn.safeTeleport(vehObj, vec3(px, py, pz), safeTeleportRot, false, nil, false, true, true)
  else
    vehObj:setPosRot(px, py, pz + 0.5, qx, qy, qz, qw)
    vehObj:resetBrokenFlexMesh()
  end
end

local function getConfigKeyFromPath(configPath)
  if type(configPath) ~= "string" then return nil end
  local normalized = configPath:gsub("\\", "/")
  local key = normalized:match("/configurations/([^/]+)%.pc$")
  if key then return key end
  return normalized:match("/([^/]+)%.pc$")
end

local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
  if not options or not modelKey then return nil end
  if not core_vehiclePaints or not core_vehiclePaints.getRandomPaints then return nil end

  local paintResult = core_vehiclePaints.getRandomPaints(modelKey, getConfigKeyFromPath(configPath))
  if type(paintResult) ~= "table" then return nil end

  local modelData = core_vehicles.getModel(modelKey)
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= "table" then return nil end

  local paintNames = {
    paintResult.paintName1,
    paintResult.paintName2 or paintResult.paintName1,
    paintResult.paintName3 or paintResult.paintName2 or paintResult.paintName1
  }
  if not paintNames[1] or not modelPaints[paintNames[1]] then return nil end

  options.paintName = paintNames[1]
  options.paintName2 = paintNames[2]
  options.paintName3 = paintNames[3]
  options.paint = deepcopy(modelPaints[paintNames[1]])
  options.paint2 = paintNames[2] and modelPaints[paintNames[2]] and deepcopy(modelPaints[paintNames[2]]) or nil
  options.paint3 = paintNames[3] and modelPaints[paintNames[3]] and deepcopy(modelPaints[paintNames[3]]) or nil

  if type(configPath) == "string" then
    local cfg = jsonReadFile(configPath)
    if type(cfg) == "table" and cfg.format ~= 4 then
      cfg = deepcopy(cfg)
      cfg.partConfigFilename = configPath
      cfg.colors = nil
      local paints = type(cfg.paints) == "table" and deepcopy(cfg.paints) or {}
      paints[1] = deepcopy(options.paint)
      if options.paint2 then paints[2] = deepcopy(options.paint2) end
      if options.paint3 then paints[3] = deepcopy(options.paint3) end
      cfg.paints = paints
      options.config = cfg
    end
  end

  return paintNames
end

local function applyRandomPaintToSpawnedVehicle(vehId, modelKey, paintNames)
  if not vehId or type(paintNames) ~= "table" or not paintNames[1] then return end
  if not core_vehicle_manager or not core_vehicle_manager.setVehiclePaintsNames then return end

  core_vehicle_manager.setVehiclePaintsNames(vehId, paintNames)

  local vehicleData = core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or type(vehicleData.config) ~= "table" then return end

  local modelData = modelKey and core_vehicles.getModel(modelKey) or nil
  if not modelData and vehicleData.ioCtx and vehicleData.ioCtx.modelKey then
    modelData = core_vehicles.getModel(vehicleData.ioCtx.modelKey)
  end
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= "table" then return end

  local config = vehicleData.config
  config.colors = nil
  local paints = type(config.paints) == "table" and deepcopy(config.paints) or {}
  for i, paintName in ipairs(paintNames) do
    if paintName and modelPaints[paintName] then
      paints[i] = deepcopy(modelPaints[paintName])
    end
  end
  config.paints = paints
  config.paintName = paintNames[1]
  config.paintName2 = paintNames[2]
  config.paintName3 = paintNames[3]
end

-- spawnFinishedCallbackName: exported M function name (e.g. onVehicleSpawnFinished adds personal inventory).
local function spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, spawnFinishedCallbackName, rewardTransform, randomPaint, useFreightPickup)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local randomPaintNames
  if randomPaint then
    randomPaintNames = applyRandomPaintToSpawnOptions(spawnOptions, vehicleInfo.model_key, vehicleInfo.key)
  end
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if rewardTransform then
    moveVehicleToRewardTransform(newVeh, rewardTransform)
  elseif dealershipToMoveTo then
    moveVehicleToDealership(newVeh, dealershipToMoveTo, useFreightPickup)
  else
    -- no dealership lot: put it on the listing's own parking spot so it is where the map said
    M.moveVehicleToListingSpot(newVeh, vehicleInfo)
  end
  core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format(
    "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.%s(%d)')",
    vehicleInfo.wearMileage or vehicleInfo.Mileage,
    getVisualValueFromMileage(vehicleInfo.wearMileage or vehicleInfo.Mileage),
    spawnFinishedCallbackName, newVeh:getID()))
  return newVeh, randomPaintNames
end

local function spawnVehicle(vehicleInfo, dealershipToMoveTo, useFreightPickup)
  return spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "onVehicleSpawnFinished", nil, nil, useFreightPickup)
end

-- Racing team fleet drive-in: world vehicle only until business inventory takes ownership (no personal addVehicle).
local function rtFleetSpawnVehicle(vehicleInfo, dealershipToMoveTo)
  return spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "onRacingTeamFleetVehicleSpawnFinished")
end

local function onRacingTeamFleetVehicleSpawnFinished(_vehId)
end

function M.completeFreightPickup(inventoryId)
  local inventoryVehicle = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  if not inventoryVehicle or
    string.find(tostring(inventoryVehicle.location or ""), "freightPickup:", 1, true) ~= 1 then
    return false
  end

  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehObj = vehId and getObjectByID(vehId)
  local closestGarage = not inventoryVehicle.freightHomeGarageId and
    career_modules_inventory.getClosestOwnedGarageWithSpace(
      vehObj and vehObj:getPosition() or nil) or nil
  if not career_modules_inventory.moveVehicleToGarage(
    inventoryId, inventoryVehicle.freightHomeGarageId or (closestGarage and closestGarage.id) or nil) then
    return false
  end
  inventoryVehicle.freightHomeGarageId = nil

  if core_groundMarkers then
    core_groundMarkers.setPath(nil)
  end
  ui_message(
    "Freight pickup complete. Home garage: " ..
      tostring(inventoryVehicle.niceLocation or "Assigned garage") .. ".",
    6, "Vehicle collected", "info")
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
  return true
end

local function onVehicleSpawnFinished(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId)

  if spawnFollowUpActions then
    if spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, spawnFollowUpActions.delayAccess, "bought")
    end
    if spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, spawnFollowUpActions.licensePlateText)
    end
    if spawnFollowUpActions.dealershipId and
      (spawnFollowUpActions.dealershipId == "policeDealership" or spawnFollowUpActions.dealershipId == "poliziaAuto") then
      career_modules_inventory.setVehicleRole(inventoryId, "police")
    end
    if spawnFollowUpActions.policyId ~= nil then
      local policyId = tonumber(spawnFollowUpActions.policyId) or 0
      if career_modules_insurance and career_modules_insurance.changeVehPolicy then
        career_modules_insurance.changeVehPolicy(inventoryId, policyId)
      end
    end
    if spawnFollowUpActions.freightPickup then
      local inventoryVehicle = career_modules_inventory.getVehicles()[inventoryId]
      if inventoryVehicle then
        inventoryVehicle.location = "freightPickup:" .. tostring(spawnFollowUpActions.dealershipId or "online")
        inventoryVehicle.niceLocation = "Freight Pickup"
        inventoryVehicle.freightHomeGarageId = spawnFollowUpActions.targetGarageId
      end
      local freightVehicle = getObjectByID(vehId)
      if freightVehicle then
        if core_groundMarkers then
          core_groundMarkers.setPath(freightVehicle:getPosition())
        end
        if career_modules_playerDriving and career_modules_playerDriving.showPosition then
          career_modules_playerDriving.showPosition(freightVehicle:getPosition())
        end
      end
      ui_message("Order ready at Freight Pickup. It is listed in Vehicle Inventory under Freight Pickup, and a route has been set.", 10,
        "Freight order ready", "info")
    else
      career_modules_inventory.moveVehicleToGarage(inventoryId, spawnFollowUpActions.targetGarageId)
    end
    spawnFollowUpActions = nil
  end
end

local rewardVehicleGrantData

local function onRewardVehicleSpawnFinished(vehId)
  local data = rewardVehicleGrantData or {}
  rewardVehicleGrantData = nil

  if data.randomPaintNames then
    applyRandomPaintToSpawnedVehicle(vehId, data.vehicleInfo and data.vehicleInfo.model_key, data.randomPaintNames)
  end

  local addOptions = { owned = true }
  if data.ignoreGarageLimit then
    addOptions.takesNoInventorySpace = true
  end
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, addOptions)
  if not inventoryId then return end

  local inventoryVehicle = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()[inventoryId]
  if inventoryVehicle then
    local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
    if vehicleData and type(vehicleData.config) == "table" then
      inventoryVehicle.config = deepcopy(vehicleData.config)
    end
    inventoryVehicle.mileage = data.vehicleInfo and data.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
    inventoryVehicle.year = data.vehicleInfo and data.vehicleInfo.year or inventoryVehicle.year
    inventoryVehicle.purchasePrice = 0
    inventoryVehicle.rewardSource = data.source or "Reward"
  end

  -- Reward grants are not dealership purchases; start uninsured like car-meet buys.
  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = data.vehicleInfo,
    purchaseData = {insuranceId = -1},
  })

  local vehObj = getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand('ai.setMode("disabled")')
    vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
    vehObj:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
    vehObj:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
  end

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function grantRewardVehicle(vehicleInfo, source, options)
  if not vehicleInfo or not vehicleInfo.model_key or not vehicleInfo.key then return false end
  options = options or {}
  if not options.ignoreGarageLimit and not canPurchaseCarMeetVehicle(true) then return false end
  if rewardVehicleGrantData then return false end

  rewardVehicleGrantData = {
    vehicleInfo = deepcopy(vehicleInfo),
    source = source or "Reward",
    ignoreGarageLimit = options.ignoreGarageLimit == true
  }
  local _, randomPaintNames = spawnShopVehicleInternal(vehicleInfo, nil, "onRewardVehicleSpawnFinished", options.spawnTransform, options.randomPaint == true)
  rewardVehicleGrantData.randomPaintNames = randomPaintNames
  return true
end

-- Purchase and payment functions
-- Trade-in surplus past vehicle+fees reduces finalPrice below zero (cash back to the player).
-- Tax is still only charged on a non-negative taxable base.
function M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
  tradeInValue = tonumber(tradeInValue) or 0
  local vehicleAndFees = (tonumber(vehicleShopInfo.Value) or 0) + (tonumber(vehicleShopInfo.fees) or 0)
  local taxes = math.max((vehicleAndFees - tradeInValue) * (vehicleShopInfo.tax or salesTax), 0)
  if vehicleShopInfo.sellerId == "discountedDealership" or vehicleShopInfo.sellerId == "joesJunkDealership" then
    taxes = 0
  end
  return taxes, vehicleAndFees + taxes - tradeInValue
end

function M.tradeInFreesInventorySlot()
  local info = purchaseData and purchaseData.tradeInVehicleInfo
  return info ~= nil and info.id ~= nil and not info.takesNoInventorySpace
end

function M.hasInventorySlotForPurchase()
  return career_modules_inventory.hasFreeSlot() or M.tradeInFreesInventorySlot()
end

function M.applyDeliveryCharge(quote)
  local previousDelivery = tonumber(purchaseData.prices.delivery) or 0
  local deliveryPrice = tonumber(quote and quote.finalPrice) or 0
  purchaseData.prices.finalPrice =
    (tonumber(purchaseData.prices.finalPrice) or 0) - previousDelivery + deliveryPrice
  purchaseData.prices.delivery = deliveryPrice
end

-- Validate before removing a trade-in so a failed purchase cannot eat the traded vehicle.
function M.canCompletePersonalVehiclePurchase(options)
  options = options or {}
  local cheats = career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode()
  local prices = purchaseData.prices or {}
  local price = (tonumber(prices.finalPrice) or 0) - (tonumber(prices.delivery) or 0)
  if options.makeDelivery then
    local quote = M.getDeliveryQuote(options.targetGarageId)
    if not quote or quote.disabled then
      return false, "delivery"
    end
    price = price + (tonumber(quote.finalPrice) or 0)
  end
  if options.licensePlateText then
    price = price + (tonumber(prices.customLicensePlate) or 0)
  end
  if not cheats and (tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0) < price then
    return false, "funds"
  end
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and
                               career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if garageAvailability == "none" then
    return false, "garage"
  end
  if not M.hasInventorySlotForPurchase() then
    return false, "slot"
  end
  return true
end

local function payForVehicle()
  if rtBizId then
    return
  end
  local label = string.format("Bought a vehicle: %s", purchaseData.vehicleInfo.niceName)
  if purchaseData.tradeInVehicleInfo then
    label = label .. string.format(" and traded in vehicle id %d: %s", purchaseData.tradeInVehicleInfo.id,
      purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({
    money = -purchaseData.prices.finalPrice
  }, {
    tags = {"vehicleBought", "buying"},
    label = label
  })
  if career_modules_carmeets and career_modules_carmeets.addTransactionReputation then
    local vehicleInfo = purchaseData.vehicleInfo or {}
    local marketValue = vehicleInfo.marketValue or vehicleInfo.Value or purchaseData.prices.finalPrice
    career_modules_carmeets.addTransactionReputation("buy", purchaseData.prices.finalPrice, marketValue)
  end
  if purchaseData.vehicleInfo and purchaseData.vehicleInfo.source == "carMeet" and career_modules_carmeets and career_modules_carmeets.onCarMeetVehiclePurchased then
    career_modules_carmeets.onCarMeetVehiclePurchased(purchaseData.shopId, purchaseData.keepCarMeetWorldVehicle == true)
  end
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  vehicleWatchlist[purchaseData.shopId] = nil
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  if rtBizId then
    return false
  end
  local targetGarageId = options and options.targetGarageId
  local targetGarage = targetGarageId and freeroam_facilities.getFacility("garage", targetGarageId) or nil
  if not targetGarage or not career_modules_garageManager.isPurchasedGarage(targetGarageId) then
    return false
  end
  local spaceInfo = career_modules_garageManager.isGarageSpace(targetGarageId)
  if not spaceInfo or not spaceInfo[1] then
    return false
  end
  local quote = M.getDeliveryQuote(targetGarageId)
  if not quote or quote.disabled then
    return false
  end
  M.applyDeliveryCharge(quote)
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or
    career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return false
  end
  payForVehicle()
  spawnFollowUpActions = {
    delayAccess = quote.etaSeconds,
    targetGarageId = targetGarageId,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
    policyId = options.policyId
  }
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
  return true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if rtBizId then
    return false
  end
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return false
  end
  payForVehicle()

  local dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId)
  local dealership = dealershipId and freeroam_facilities.getDealership(dealershipId) or nil
  local freightPickup = dealership and getSellerAccessInfo(dealership).isOnline or false
  local targetGarage =
    career_modules_inventory.getClosestOwnedGarageWithSpace() or career_modules_inventory.getClosestGarage()

  spawnFollowUpActions = {
    targetGarageId = targetGarage and targetGarage.id or nil,
    licensePlateText = options.licensePlateText,
    dealershipId = dealershipId,
    freightPickup = freightPickup,
    policyId = options.policyId
  }
  -- "private" is a seller id, not a facility, so it must not be used as a dealership to move to
  local sellerId = purchaseData.vehicleInfo.sellerId
  local moveToDealership = (sellerId ~= "private" and sellerId ~= "carMeet") and dealershipId or nil
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, moveToDealership, freightPickup)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
  return true
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
local originComputerId
local function openShop(seller, _originComputerId, screenTag)
  if seller and isPoliceDealershipLocked(seller) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  if seller then discoverDealer(seller) end
  currentSeller = seller
  originComputerId = _originComputerId

  if not career_modules_inspectVehicle.getSpawnedVehicleInfo() then
    updateVehicleList()
  end

  local sellerInfos = {}
  for id, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.pos then
      if vehicleInfo.sellerId ~= "private" then
        local sellerInfo = sellerInfos[vehicleInfo.sellerId]
        if sellerInfo then
          vehicleInfo.distance = sellerInfo.distance
          vehicleInfo.quickTravelPrice = sellerInfo.quicktravelPrice
        else
          local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
          sellerInfos[vehicleInfo.sellerId] = {
            distance = distance,
            quicktravelPrice = quicktravelPrice
          }
          vehicleInfo.distance = distance
          vehicleInfo.quickTravelPrice = quicktravelPrice
        end
      else
        local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
        vehicleInfo.distance = distance
        vehicleInfo.quickTravelPrice = quicktravelPrice
      end
    else
      vehicleInfo.distance = 0
    end
  end

  local computer
  if currentSeller then
    local dealership = freeroam_facilities.getFacility("dealership", currentSeller)
    local tetherPos
    if dealership then
      tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
    else
      for _, vehicleInfo in ipairs(vehiclesInShop) do
        if vehicleInfo.sellerId == currentSeller and vehicleInfo.pos then
          tetherPos = vehicleInfo.pos
          break
        end
      end
    end
    if tetherPos then
      tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)
    end
  elseif originComputerId then
    computer = freeroam_facilities.getFacility("computer", originComputerId)
    tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  shoppingScreenTag = screenTag
  buyingAvailable = (not computer or computer.functions.vehicleShop) and true or false
  marketplaceAvailable = (career_career.hasBoughtStarterVehicle() and not currentSeller) and true or false
  selectedSellerId = currentSeller

  if currentSeller then
    extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
  else
    extensions.ui_router.navigate("career.computer.vehicleShopping")
  end
  extensions.hook("onVehicleShoppingMenuOpened", {
    seller = currentSeller
  })
end

local function navigateToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  navigateToPos(pos)
end

local function taxiToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  career_modules_quickTravel.quickTravelToPos(pos, true,
    string.format("Took a taxi to %s", dealership.name or "dealership"))
  -- Racing team computer shop: player is now at the lot; scope shopping to this seller so
  -- inspect/instant purchase matches in-person flow (Vue refreshes shopping data after taxi).
  if rtBizId then
    currentSeller = dealershipId
    originComputerId = nil
  end
end

local function getTaxiPriceToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    return 0
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    log("W", "Career", "getTaxiPriceToDealership: Dealership not found: " .. tostring(dealershipId))
    return 0
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    log("W", "Career", "getTaxiPriceToDealership: No position found for dealership: " .. tostring(dealershipId))
    return 0
  end

  local playerPos = getPlayerVehicle(0):getPosition()
  local distance = (pos - playerPos):length()

  local price, calcDistance = career_modules_quickTravel.getPriceForQuickTravel(pos)

  if (not price or price <= 0) and (calcDistance and calcDistance > 0) then
    local basePrice = 5
    local pricePerM = 0.08
    local est = basePrice + round(calcDistance * pricePerM * 100) / 100
    log("W", "Career",
      string.format("getTaxiPriceToDealership: fallback price used=%.2f (distance=%.2f)", est, calcDistance))
    price = est
  end

  return price * 5 or 0
end

local function endShopping()
  career_career.closeAllMenus()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

local function cancelShopping()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function requestExit()
  if rtBizId then
    local businessId = rtBizId
    rtBizId = nil
    currentSeller = nil
    originComputerId = nil
    selectedSellerId = nil
    return extensions.ui_router.navigate("business-computer", {
      businessType = "racingTeam",
      businessId = tostring(businessId)
    })
  end
  return cancelShopping()
end

local function onRouteMount(context, toRoute, fromRoute, data)
  sendShoppingDataToUI()
end

local function selectSeller(sellerId)
  if type(sellerId) ~= "string" or sellerId == "" then return end
  if isPoliceDealershipLocked(sellerId) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end
  local dealership = freeroam_facilities.getDealership(sellerId)
  if dealership and not isDealerDiscovered(dealership) then return end
  selectedSellerId = sellerId
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", sellerId)
  sendShoppingDataToUI()
  return extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
end

local function clearSelectedSeller()
  selectedSellerId = nil
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", nil)
  sendShoppingDataToUI()
end

local function requestVehicleListExit()
  if currentSeller then
    return cancelShopping()
  end
  clearSelectedSeller()
  return extensions.ui_router.navigate("career.computer.vehicleShopping")
end

local function getSelectedSellerBreadcrumbTitle()
  if not selectedSellerId then return nil end
  if selectedSellerId == "private" then
    return _tr("ui.career.vehicleShopping.privateSellers")
  end
  local dealership = freeroam_facilities.getDealership(selectedSellerId)
  if dealership and dealership.name then
    return _tr(dealership.name)
  end
  return nil
end

local function onShoppingMenuClosed()
  if tether then
    tether.remove = true
    tether = nil
  end
  inspectingVehicleShopId = nil
  purchaseMenuOpen = false
end

local function getVehiclesInShop()
  return vehiclesInShop
end

local removeNonUsedPlayerVehicles
local function removeUnusedPlayerVehicles()
  for inventoryId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId()) do
    if inventoryId ~= career_modules_inventory.getCurrentVehicle() then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end
end

local function buySpawnedVehicle(buyVehicleOptions)
  if rtBizId then
    return false
  end
  buyVehicleOptions = buyVehicleOptions or {}
  local deliveryQuote
  if buyVehicleOptions.makeDelivery then
    deliveryQuote = M.getDeliveryQuote(buyVehicleOptions.targetGarageId)
    if not deliveryQuote or deliveryQuote.disabled then
      return false
    end
    M.applyDeliveryCharge(deliveryQuote)
  end
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if not canAfford then
    return false
  end
  if garageAvailability == "none" then
    ui_message("Buy or rent a garage before purchasing a vehicle.", nil, "vehicleShopping")
    return false
  end
  if not career_modules_inventory.hasFreeSlot() then
    return false
  end

  local vehObj = getObjectByID(purchaseData.vehId)
  if not vehObj then
    return false
  end
  payForVehicle()
  local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID())
  local inventoryVehicle = career_modules_inventory.getVehicles and
                             career_modules_inventory.getVehicles()[newInventoryId] or nil
  if inventoryVehicle and vehicleMaintenance and vehicleMaintenance.applyInspectionSnapshotToVehicleData then
    vehicleMaintenance.applyInspectionSnapshotToVehicleData(purchaseData.vehicleInfo, inventoryVehicle)
  end
  if buyVehicleOptions.licensePlateText then
    career_modules_inventory.setLicensePlateText(newInventoryId, buyVehicleOptions.licensePlateText)
  end
  if buyVehicleOptions.dealershipId == "policeDealership" then
    career_modules_inventory.setVehicleRole(newInventoryId, "police")
  end
  local stored
  if deliveryQuote then
    stored = career_modules_inventory.moveVehicleToGarage(newInventoryId, buyVehicleOptions.targetGarageId)
    if stored then
      career_modules_inventory.delayVehicleAccess(newInventoryId, deliveryQuote.etaSeconds, "bought")
    end
  else
    stored = career_modules_inventory.storeVehicle(newInventoryId)
  end
  if not stored then
    return false
  end
  removeNonUsedPlayerVehicles = true
  if not deliveryQuote and be:getPlayerVehicleID(0) == vehObj:getID() then
    career_modules_inventory.enterVehicle(newInventoryId)
  end
  return true
end

local function getDeliveryOrigin(dealership)
  if not dealership then return nil, "Dealership is unavailable." end
  local accessInfo = getSellerAccessInfo(dealership)
  if accessInfo.isOnline then
    local freightFacility = dealership
    if type(dealership.freightPickupSpotNames) == "table" then
      freightFacility = deepcopy(dealership)
      freightFacility.parkingSpotNames = dealership.freightPickupSpotNames
    end
    local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(freightFacility) or {}
    if not parkingSpots[1] then
      return nil, "This map has no freight pickup point configured for online vehicle orders."
    end
    return parkingSpots[1].pos
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then return nil, "The dealership has no delivery origin configured." end
  return pos
end

local function getDeliveryGarages(dealership)
  local result = {}
  if not dealership or not getSellerAccessInfo(dealership).garageDeliveryAllowed then return result end
  local capacityData = career_modules_garageManager.getGarageCapacityData() or {}
  for garageId, info in pairs(capacityData) do
    if (tonumber(info.capacity) or 0) > (tonumber(info.count) or 0) then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      if garage then
        table.insert(result, {
          id = tostring(garageId),
          name = garage.name or info.name or tostring(garageId),
          freeSlots = (tonumber(info.capacity) or 0) - (tonumber(info.count) or 0)
        })
      end
    end
  end
  table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return result
end

local function getDeliveryQuote(garageId)
  if not purchaseData or not purchaseData.vehicleInfo then
    return {disabled = true, reason = "No active vehicle purchase."}
  end
  local dealership = freeroam_facilities.getDealership(purchaseData.vehicleInfo.sellerId)
  local accessInfo = getSellerAccessInfo(dealership)
  if not accessInfo.garageDeliveryAllowed then
    return {disabled = true, reason = "Garage delivery unlocks at dealer reputation level 2."}
  end
  if not garageId or not career_modules_garageManager.isPurchasedGarage(garageId) then
    return {disabled = true, reason = "Choose an owned garage."}
  end
  local spaceInfo = career_modules_garageManager.isGarageSpace(garageId)
  if not spaceInfo or not spaceInfo[1] then
    return {disabled = true, reason = "The selected garage has no free space."}
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  local garagePos = garage and freeroam_facilities.getGaragePosRot(garage) or nil
  local origin, reason = getDeliveryOrigin(dealership)
  if not origin or not garagePos then
    return {disabled = true, reason = reason or "Delivery route is unavailable."}
  end
  local routeQuote = career_modules_quickTravel.getRoadRouteQuote(origin, garagePos)
  local fullPrice = routeQuote.price
  local roadDistance = routeQuote.roadDistance
  local discount = accessInfo.deliveryDiscount
  local finalPrice = math.floor((tonumber(fullPrice) or 0) * (1 - discount) * 100 + 0.5) / 100
  return {
    disabled = false,
    garageId = tostring(garageId),
    garageName = garage.name or tostring(garageId),
    roadDistance = roadDistance or 0,
    fullPrice = fullPrice or 0,
    discount = discount,
    finalPrice = finalPrice,
    etaSeconds = getDeliveryDelay(roadDistance)
  }
end

local function sendPurchaseDataToUi()
  local rtBid = purchaseData.racingTeamBusinessId or rtBizId
  local vehicleShopInfo = deepcopy(getVehicleInfoByShopId(purchaseData.shopId))
  if not vehicleShopInfo then
    log("E", "Career", "sendPurchaseDataToUi: Vehicle not found for shopId: " .. tostring(purchaseData.shopId))
    return
  end
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  applyPurchaseAdjustedMarketValue(vehicleShopInfo)
  vehicleShopInfo.Value = vehicleShopInfo.valueAdjusted or vehicleShopInfo.Value
  coerceVehiclePricingFields(vehicleShopInfo)
  purchaseData.vehicleInfo = vehicleShopInfo

  local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
  local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
  purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = customLicensePlatePrice}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  -- Insurance options from v38
  if vehicleShopInfo.source == "carMeet" then
    purchaseData.insuranceId = -1
  elseif not purchaseData.insuranceId then
    if vehicleShopInfo.insuranceClass and vehicleShopInfo.insuranceClass.id then
      if career_modules_insurance_insurance and career_modules_insurance_insurance.getDefaultInsuranceForClassId then
        local defaultInsurance = career_modules_insurance_insurance.getDefaultInsuranceForClassId(vehicleShopInfo.insuranceClass.id)
        if defaultInsurance then
          purchaseData.insuranceId = defaultInsurance.id
        end
      end
    end
  end

  purchaseData.insuranceOptions = {
    insuranceId = purchaseData.insuranceId,
    shopId = purchaseData.shopId,
  }

  if purchaseData.insuranceId and purchaseData.insuranceId >= 0 then
    if career_modules_insurance_insurance and career_modules_insurance_insurance.getInsuranceDataById then
      local insuranceInfo = career_modules_insurance_insurance.getInsuranceDataById(purchaseData.insuranceId)
      if insuranceInfo then
        purchaseData.insuranceOptions.spendingReason = string.format("Insurance Policy: \"%s\"", insuranceInfo.name)
        if career_modules_insurance_insurance.calculateAddVehiclePrice then
          purchaseData.insuranceOptions.priceMoney = career_modules_insurance_insurance.calculateAddVehiclePrice(purchaseData.insuranceId, purchaseData.vehicleInfo.Value)
        end
      end
    end
  end

  local playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  local racingTeamBusinessMoney = nil
  local invFree = career_modules_inventory.hasFreeSlot()
  if rtBid and career_modules_bank and career_modules_bank.getBusinessAccount then
    local acct = career_modules_bank.getBusinessAccount("racingTeam", rtBid)
    racingTeamBusinessMoney = tonumber(acct and acct.balance) or tonumber(acct and acct.balanceMoney) or tonumber(acct and acct.money) or 0
    local inv = career_modules_business_businessInventory
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(rtBid) or {})
    end
    invFree = n < rtFleetCap(rtBid)
  end

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = playerMoney,
    racingTeamBusinessMoney = racingTeamBusinessMoney,
    racingTeamFleetPurchase = rtBid ~= nil,
    inventoryHasFreeSlot = invFree,
    garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok",
    purchaseType = purchaseData.purchaseType,
    forceTradeIn = (not rtBid) and (not career_career.hasBoughtStarterVehicle()) or nil,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    prices = purchaseData.prices,
    dealershipId = vehicleShopInfo.sellerId,
    alreadyDidTestDrive = career_modules_inspectVehicle.getDidTestDrive() or false,
    vehId = purchaseData.vehId,
    cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false,
    insuranceOptions = purchaseData.insuranceOptions
  }
  local dealership = freeroam_facilities.getDealership(vehicleShopInfo.sellerId)
  local accessInfo = getSellerAccessInfo(dealership)
  local _, freightReason = getDeliveryOrigin(dealership)
  data.salesChannel = accessInfo.salesChannel
  data.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
  data.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
  data.deliveryDiscount = accessInfo.deliveryDiscount
  data.deliveryGarages = getDeliveryGarages(dealership)
  data.freightAvailable = not accessInfo.isOnline or freightReason == nil
  data.freightUnavailableReason = accessInfo.isOnline and freightReason or nil

  if not data.vehicleInfo.requiredInsurance then
    data.ownsRequiredInsurance = false
  else
    if career_modules_insurance and career_modules_insurance.getPlayerPolicyData then
      local playerInsuranceData = career_modules_insurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
      if playerInsuranceData then
        data.ownsRequiredInsurance = playerInsuranceData.owned
      else
        data.ownsRequiredInsurance = false
      end
    else
      data.ownsRequiredInsurance = false
    end
  end

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or
                         (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  if atDealership and not rtBid and vehicleShopInfo.source ~= "carMeet" then
    data.tradeInEnabled = true
  end

  if (atDealership or accessInfo.isOnline or accessInfo.remotePurchaseAllowed or vehicleShopInfo.sellerId == "private")
      and vehicleShopInfo.source ~= "carMeet" then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

local function updateInsuranceSelection(insuranceId)
  if purchaseData then
    purchaseData.insuranceId = insuranceId
    sendPurchaseDataToUi()
  end
end

local function onClientStartMission()
  vehiclesInShop = {}
end

local function onAddedVehiclePartsToInventory(inventoryId, newParts)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  vehicle.year = purchaseData and purchaseData.vehicleInfo.year or 1990

  vehicle.originalParts = {}
  local allSlotsInVehicle = {
    main = true
  }

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    vehicle.originalParts[part.containingSlot] = {
      name = part.name,
      value = part.value
    }

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
  end

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()

  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = purchaseData and purchaseData.vehicleInfo,
    selectedPolicyId = purchaseData and purchaseData.selectedPolicyId,
    purchaseData = purchaseData
  })

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function onEnterVehicleFinished(inventoryId)
  if removeNonUsedPlayerVehicles then
    removeNonUsedPlayerVehicles = nil
  end
  M.completeFreightPickup(inventoryId)
end

local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle)
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  extensions.ui_router.navigate("play")
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  inspectingVehicleShopId = vehicleInfo.shopId

  extensions.hook("onVehicleShoppingVehicleShown", {
    vehicleInfo = vehicleInfo
  })
end

-- Navigation functions
local function navigateToPos(pos, shopId)
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))

  if shopId then
    local vehicleInfo = getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
      return
    end
    core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, false)
  else
    extensions.ui_router.navigate("play")
  end
end

local function showVehicle(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function quickTravelToVehicle(shopId)
  if not shopId then
    log("E", "Career", "quickTravelToVehicle: shopId is nil")
    return
  end
  log("D", "Career", "quickTravelToVehicle called with shopId: " .. tostring(shopId) .. " (type: " .. type(shopId) .. ")")
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for quick travel with shopId: " .. tostring(shopId))
    log("D", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
    if tableSize(vehiclesInShop) > 0 then
      log("D", "Career", "Sample shopIds in vehiclesInShop:")
      for i = 1, math.min(5, #vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(vehiclesInShop[i].shopId) .. " (type: " .. type(vehiclesInShop[i].shopId) .. ")")
      end
    end
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId, insuranceId, silent)
  log("D", "Career",
    "openPurchaseMenu called with purchaseType: " .. tostring(purchaseType) .. ", shopId: " .. tostring(shopId))

  if not purchaseType then
    log("E", "Career", "openPurchaseMenu: purchaseType is nil")
    return
  end

  if not shopId then
    log("E", "Career", "openPurchaseMenu: shopId is nil")
    return
  end

  local vehicle = getVehicleInfoByShopId(shopId)
  if not vehicle then
    log("E", "Career", "Failed to find vehicle for purchase with shopId: " .. tostring(shopId))
    if #vehiclesInShop > 0 then
      log("D", "Career", "Available vehicles in shop:")
      for i, v in ipairs(vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(v.shopId) .. ", key=" .. tostring(v.key))
      end
    else
      log("E", "Career", "No vehicles available in shop")
    end
    return
  end
  if purchaseType == "instant" and not currentSeller and vehicle.sellerId ~= "private" and vehicle.source ~= "carMeet" then
    local dealership = freeroam_facilities.getDealership(vehicle.sellerId)
    local accessInfo = getSellerAccessInfo(dealership)
    if not accessInfo.remotePurchaseAllowed then
      ui_message("Visit this dealership to purchase. Remote checkout unlocks at reputation level 2.",
        6, "In-person purchase required", "info")
      return
    end
    if accessInfo.isOnline then
      local origin, reason = getDeliveryOrigin(dealership)
      if not origin then
        ui_message(reason, 8, "Online ordering unavailable", "warning")
        return
      end
    end
  end

  vehicleWatchlist[shopId] = "unsold"
  -- Snapshot before switching UI: leaving vehicle shopping can remount the view and clear global rtBizId.
  local racingTeamPurchaseBizId = rtBizId

  local vehicleShopInfo = deepcopy(vehicle)
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  coerceVehiclePricingFields(vehicleShopInfo)

  local distance = vehicleShopInfo.distance
  if not distance or type(distance) ~= "number" then
    if vehicleShopInfo.pos then
      local qtPrice, dist = career_modules_quickTravel.getPriceForQuickTravel(vehicleShopInfo.pos)
      vehicleShopInfo.quickTravelPrice = vehicleShopInfo.quickTravelPrice or qtPrice
      distance = dist
    else
      distance = 0
    end
    vehicleShopInfo.distance = distance
  end
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(distance)

  local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, 0)

  purchaseData = {
    shopId = shopId,
    purchaseType = purchaseType,
    vehicleInfo = vehicleShopInfo,
    insuranceId = vehicleShopInfo.source == "carMeet" and -1 or insuranceId,
    racingTeamBusinessId = racingTeamPurchaseBizId,
    prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = customLicensePlatePrice
    }
  }

  if racingTeamPurchaseBizId then
    purchaseData.insuranceId = -1
  end

  purchaseMenuOpen = true
  log("D", "Career", "Successfully opened purchase menu for vehicle: " .. tostring(shopId))
  if not silent then
    extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles.vehiclePurchase")
    extensions.hook("onVehicleShoppingPurchaseMenuOpened", {
      purchaseType = purchaseType,
      shopId = shopId
    })
  end
end

local function buyFromPurchaseMenu(purchaseType, options)
  options = options or {}

  if not purchaseData then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData is nil")
    return
  end
  if not purchaseData.vehicleInfo then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData.vehicleInfo is nil")
    return
  end
  if options.makeDelivery then
    local quote = getDeliveryQuote(options.targetGarageId)
    if not quote or quote.disabled then
      ui_message(quote and quote.reason or "Delivery quote is unavailable.", 6, "Delivery unavailable", "warning")
      return
    end
  end
  if not purchaseData.prices then
    log("W", "Career", "buyFromPurchaseMenu: purchaseData.prices is nil, calculating prices as fallback")
    local vehicleShopInfo = purchaseData.vehicleInfo
    coerceVehiclePricingFields(vehicleShopInfo)
    local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
    local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
    purchaseData.prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = customLicensePlatePrice
    }
  end

  local bid = purchaseData.racingTeamBusinessId or rtBizId
  if bid then
    local inv = career_modules_business_businessInventory
    local cap = rtFleetCap(bid)
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(bid) or {})
    end
    if n >= cap then
      return
    end
    local price = tonumber(purchaseData.prices.finalPrice) or 0
    if options.licensePlateText then
      price = price + (tonumber(purchaseData.prices.customLicensePlate) or 0)
    end
    -- Racing team purchases always debit the business account; cheats mode does not waive this.
    local bank = career_modules_bank
    local acct = bank and bank.getBusinessAccount and bank.getBusinessAccount("racingTeam", bid)
    local accountId = acct and (acct.id or acct.accountId)
    if not bank or not bank.payFromAccount or not accountId then
      return
    end
    local paid = bank.payFromAccount({
      money = { amount = price, canBeNegative = false }
    }, accountId, "Vehicle Purchase", "Racing team fleet vehicle")
    if not paid then
      return
    end
    local orgId = purchaseData.vehicleInfo and purchaseData.vehicleInfo.associatedOrganization
    if not orgId then
      local dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId)
      if dealershipId and dealershipId ~= "private" then
        local dealership = freeroam_facilities.getDealership(dealershipId)
        orgId = dealership and dealership.associatedOrganization
      end
    end
    if orgId then
      local org = freeroam_organizations.getOrganization(orgId)
      if org then
        career_modules_playerAttributes.addAttributes({
          [orgId .. "Reputation"] = dealershipPurchaseReputationGain
        }, {
          tags = {"buying"},
          label = string.format("Bought vehicle from %s", orgId)
        })
      end
    end
    local vehInfo = purchaseData.vehicleInfo
    local spawnedVehId = tonumber(purchaseData.vehId) or purchaseData.vehId
    -- Match the same in-person dealership detection used by purchase UI wiring:
    -- - instant purchase while currently at a seller
    -- - inspect purchase for non-private seller vehicles
    local effectivePurchaseType = purchaseType or purchaseData.purchaseType
    local isInPersonSellerFlow =
      (effectivePurchaseType == "inspect") or
      ((effectivePurchaseType == "instant" and currentSeller ~= nil) and vehInfo and vehInfo.sellerId ~= "private")
    if isInPersonSellerFlow then
      local spawnedVehObj = spawnedVehId and be and be:getObjectByID(spawnedVehId) or nil
      if not spawnedVehObj then
        local dealershipId = options.dealershipId or (vehInfo and vehInfo.sellerId)
        local respawnedVehObj = rtFleetSpawnVehicle(vehInfo, dealershipId)
        spawnedVehId = respawnedVehObj and respawnedVehObj:getID() or nil
      end
      if not spawnedVehId then
        local delay = getRacingTeamDeliveryDelaySeconds(bid, vehInfo)
        addPendingRacingTeamFleetPurchase(bid, {
          kind = "timer",
          dueEpoch = os.time() + delay,
          model_key = vehInfo.model_key,
          key = vehInfo.key,
          mileage = vehInfo.Mileage or 0,
          purchasePrice = price,
          purchasedEpoch = os.time()
        })
      else
      addPendingRacingTeamFleetPurchase(bid, {
        kind = "drive",
        spawnedVehId = spawnedVehId,
        model_key = vehInfo.model_key,
        key = vehInfo.key,
        mileage = vehInfo.Mileage or 0,
        purchasePrice = price,
        purchasedEpoch = os.time()
      })
      -- Clear inspect/test-drive state without deleting the purchased world vehicle.
      if career_modules_inspectVehicle.leaveSaleCallback then
        career_modules_inspectVehicle.leaveSaleCallback(
          "dontDespawn",
          false,
          false,
          "You purchased the vehicle."
        )
      end
      end
    else
      local delay = getRacingTeamDeliveryDelaySeconds(bid, vehInfo)
      addPendingRacingTeamFleetPurchase(bid, {
        kind = "timer",
        dueEpoch = os.time() + delay,
        model_key = vehInfo.model_key,
        key = vehInfo.key,
        mileage = vehInfo.Mileage or 0,
        purchasePrice = price,
        purchasedEpoch = os.time()
      })
      -- Remote/instant flow has no world car to drive; keep inspect cleanup behavior if present.
      if effectivePurchaseType ~= "inspect" and career_modules_inspectVehicle.leaveSaleCallback then
        career_modules_inspectVehicle.leaveSaleCallback(
          "despawn",
          false,
          false,
          "You purchased the vehicle."
        )
      end
    end
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
    vehicleWatchlist[purchaseData.shopId] = nil
    local targetShopId = tonumber(purchaseData.shopId) or purchaseData.shopId
    for i, v in ipairs(vehiclesInShop) do
      local vid = tonumber(v.shopId) or v.shopId
      if vid == targetShopId then
        v.markedSold = true
        v.soldViewCounter = 1
        pendingSoldShopIds[purchaseData.shopId] = true
        table.remove(vehiclesInShop, i)
        break
      end
    end
    purchaseMenuOpen = false
    inspectingVehicleShopId = nil
    if uiOpen then
      commitDelta(buildSnapshot())
      guihooks.trigger("vehicleShopDelta", lastDelta)
    end
    career_career.closeAllMenus()
    return
  end

  local canPurchase, blockReason = M.canCompletePersonalVehiclePurchase(options)
  if not canPurchase then
    if blockReason == "garage" then
      ui_message("Buy or rent a garage before purchasing a vehicle.", nil, "vehicleShopping")
    elseif blockReason == "slot" then
      ui_message("No free garage space for another vehicle.", nil, "vehicleShopping")
    end
    return
  end

  -- Only remove the trade-in after purchase preconditions pass.
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local selectedPolicyId = options.policyId or 0
  if options.purchaseInsurance and selectedPolicyId > 0 then
    if career_modules_insurance and career_modules_insurance.purchasePolicy then
      career_modules_insurance.purchasePolicy(selectedPolicyId)
    end
  end

  purchaseData.selectedPolicyId = selectedPolicyId
  local buyVehicleOptions = {
    makeDelivery = options.makeDelivery == true,
    targetGarageId = options.targetGarageId,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId),
    policyId = selectedPolicyId
  }
  local purchaseSucceeded = false
  if purchaseType == "inspect" then
    if options.makeDelivery then
      deleteAddedVehicle = true
    end
    purchaseSucceeded = career_modules_inspectVehicle.buySpawnedVehicle(buyVehicleOptions) == true
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if options.makeDelivery then
      purchaseSucceeded = buyVehicleAndSendToGarage(buyVehicleOptions) == true
    else
      purchaseSucceeded = buyVehicleAndSpawnInParkingSpot(buyVehicleOptions) == true
    end
  end

  if not purchaseSucceeded then
    log("E", "Career", "buyFromPurchaseMenu: purchase failed after trade-in was removed")
    return
  end

  local orgId = purchaseData.vehicleInfo and purchaseData.vehicleInfo.associatedOrganization
  if not orgId then
    local dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId)
    if dealershipId and dealershipId ~= "private" then
      local dealership = freeroam_facilities.getDealership(dealershipId)
      if dealership and dealership.associatedOrganization then
        orgId = dealership.associatedOrganization
      end
    end
  end

  if orgId then
    local org = freeroam_organizations.getOrganization(orgId)
    if org then
      career_modules_playerAttributes.addAttributes({
        [orgId .. "Reputation"] = dealershipPurchaseReputationGain
      }, {
        tags = {"buying"},
        label = string.format("Bought vehicle from %s", orgId)
      })
    end
  end

  if options.licensePlateText then
    career_modules_playerAttributes.addAttributes({
      money = -purchaseData.prices.customLicensePlate
    }, {
      tags = {"buying"},
      label = string.format("Bought custom license plate for new vehicle")
    })
  end

  -- Remove the vehicle from the shop
  local targetShopId = tonumber(purchaseData.shopId) or purchaseData.shopId
  for i, vehInfo in ipairs(vehiclesInShop) do
    local vehShopId = tonumber(vehInfo.shopId) or vehInfo.shopId
    if vehShopId == targetShopId then
      vehInfo.markedSold = true
      vehInfo.soldViewCounter = 1
      pendingSoldShopIds[purchaseData.shopId] = true
      table.remove(vehiclesInShop, i)
      break
    end
  end

  purchaseMenuOpen = false
  inspectingVehicleShopId = nil
  rtPendingFleetPurchases = {}

  if uiOpen then
    commitDelta(buildSnapshot())
    guihooks.trigger("vehicleShopDelta", lastDelta)
  end
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    career_career.closeAllMenus()
  end
end

local function cancelPurchase(purchaseType)
  purchaseMenuOpen = false
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    -- Phone-initiated purchases open this screen without the computer shop UI
    -- (uiOpen). Routing back to vehicleShopping.vehicles leaves an orphan
    -- computer route that blocks the phone with no computer on screen.
    if uiOpen then
      extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
    else
      career_career.closeAllMenus()
    end
  end
end

local function requestPurchaseExit()
  local purchaseType = purchaseData and purchaseData.purchaseType
  purchaseMenuOpen = false
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
    return
  end
  if uiOpen then
    return extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
  end
  return career_career.closeAllMenus()
end

local function getCarMeetPurchaseBlockReason()
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if garageAvailability == "none" then
    return "Buy or rent a garage before purchasing a vehicle."
  end
  if not career_modules_inventory.hasFreeSlot() then
    return "No free garage space for another vehicle."
  end
  return nil
end

canPurchaseCarMeetVehicle = function(showMessage)
  local reason = getCarMeetPurchaseBlockReason()
  if reason then
    if showMessage then
      ui_message(reason, nil, "vehicleShopping")
    end
    return false
  end
  return true
end

local function buyCarMeetVehicleNow(shopId)
  local function fail(reason)
    return false, reason
  end

  openPurchaseMenu("instant", shopId, -1, true)
  if not purchaseData or not purchaseData.vehicleInfo or purchaseData.vehicleInfo.source ~= "carMeet" then
    return fail("This vehicle is no longer available for purchase.")
  end

  local blockReason = getCarMeetPurchaseBlockReason()
  if blockReason then
    return fail(blockReason)
  end

  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if not canAfford then
    return fail("You cannot afford this vehicle.")
  end

  purchaseData.keepCarMeetWorldVehicle = true
  local vehId
  if career_modules_carmeets and career_modules_carmeets.prepareCarMeetVehicleForPurchase then
    vehId = career_modules_carmeets.prepareCarMeetVehicleForPurchase(shopId, purchaseData.vehicleInfo)
  else
    vehId = career_modules_carmeets and career_modules_carmeets.getCarMeetVehicleIdForShopId and career_modules_carmeets.getCarMeetVehicleIdForShopId(shopId)
    if career_modules_carmeets and career_modules_carmeets.snapshotCarMeetVehicleForPurchase then
      career_modules_carmeets.snapshotCarMeetVehicleForPurchase(vehId)
    end
  end
  local vehObj = vehId and getObjectByID(vehId)
  if not vehObj then
    return fail("The vehicle could not be found at the meet. Try again before the event ends.")
  end

  -- Use the normal inventory initialization path so the installed parts are
  -- registered with partInventory before this vehicle can be modified later.
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {owned = true})
  if not inventoryId then
    return fail("Could not add the vehicle to your garage.")
  end

  local inventoryVehicle = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()[inventoryId]
  if inventoryVehicle then
    local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
    if vehicleData and type(vehicleData.config) == "table" then
      inventoryVehicle.config = deepcopy(vehicleData.config)
    end
    inventoryVehicle.mileage = purchaseData.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
    inventoryVehicle.year = purchaseData.vehicleInfo.year or inventoryVehicle.year
    inventoryVehicle.purchasePrice = purchaseData.prices and purchaseData.prices.finalPrice or purchaseData.vehicleInfo.Value
  end

  if not career_modules_inventory.moveVehicleToGarage(inventoryId) then
    career_modules_inventory.removeVehicle(inventoryId)
    return fail("No free garage space for another vehicle.")
  end

  vehObj:queueLuaCommand('ai.setMode("disabled")')
  vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
  vehObj:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
  vehObj:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')

  payForVehicle()

  -- Register with insurance as uninsured; coverage can be added later at a garage/computer.
  purchaseData.insuranceId = -1
  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = purchaseData.vehicleInfo,
    selectedPolicyId = 0,
    purchaseData = purchaseData
  })

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end

  local targetShopId = tonumber(purchaseData.shopId) or purchaseData.shopId
  for i, vehInfo in ipairs(vehiclesInShop) do
    local vehShopId = tonumber(vehInfo.shopId) or vehInfo.shopId
    if vehShopId == targetShopId then
      vehInfo.markedSold = true
      vehInfo.soldViewCounter = 1
      pendingSoldShopIds[purchaseData.shopId] = true
      table.remove(vehiclesInShop, i)
      break
    end
  end

  purchaseMenuOpen = false
  inspectingVehicleShopId = nil
  career_career.closeAllMenus()
  return true
end

local function removeTradeInVehicle()
  purchaseData.tradeInVehicleInfo = nil
  sendPurchaseDataToUi()
end

local function openInventoryMenuForTradeIn()
  career_modules_inventory.openMenu({{
    callback = function(inventoryId)
      local vehicle = career_modules_inventory.getVehicles()[inventoryId]
      if vehicle then
        local niceName = career_modules_inventory.getVehicleNiceNameTranslated
          and career_modules_inventory.getVehicleNiceNameTranslated(inventoryId)
        if type(niceName) ~= "string" or niceName == "" then
          niceName = vehicle.niceName
        end
        if type(niceName) == "table" and core_locales and core_locales.translateWithOrWithoutContext then
          niceName = core_locales.translateWithOrWithoutContext(niceName)
        end
        if type(niceName) ~= "string" then
          niceName = tostring(niceName or "Trade-In Vehicle")
        end
        purchaseData.tradeInVehicleInfo = {
          id = inventoryId,
          niceName = niceName,
          Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) *
            (career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode() and 0.33 or 0.66),
          takesNoInventorySpace = vehicle.takesNoInventorySpace
        }
        guihooks.trigger('UINavigation', 'back', 1)
        sendPurchaseDataToUi()
      end
    end,
    buttonText = "Trade-In",
    repairRequired = true,
    ownedRequired = true
  }}, "Trade-In", {
    repairEnabled = false,
    sellEnabled = false,
    favoriteEnabled = false,
    storingEnabled = false,
    returnLoanerEnabled = false
  }, "career.computer.vehicleShopping.vehicles.vehiclePurchase")
end

local function onExtensionLoaded()
  if not career_career.isActive() then
    return false
  end

  resetVehicleValidationState()
  cacheDealers()

  purchaseMenuOpen = false
  inspectingVehicleShopId = nil

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end

  local savedData = jsonReadFile(savePath .. "/career/vehicleShop.json")
  -- vehicleShop.json owns moduleVersion. info.json uses the independent career
  -- save-system version, so comparing that value to moduleVersion made every
  -- current save look outdated (for example, save-system 64 vs shop module 69).
  local outdated = not savedData or (tonumber(savedData.version) or 0) < moduleVersion

  -- Discovery is durable player progress, not generated shop inventory. Load it
  -- even when a career/module version or valuation schema change invalidates the
  -- saved offers below.
  discoveredDealers = savedData and type(savedData.discoveredDealers) == "table"
    and savedData.discoveredDealers or {}

  local data = not outdated and savedData
  if data and tonumber(data.valuationSchemaVersion) ~= valuationSchemaVersion then
    log("I", "vehicleShopping", string.format(
      "Discarding saved shop offers from valuation schema %s; current schema is %d",
      tostring(data.valuationSchemaVersion), valuationSchemaVersion))
    data = nil
    otherMapsData = {}
    vehiclesInShop = {}
    sellersInfos = {}
    vehicleWatchlist = {}
  end
  if data then
    local currentMap = getCurrentLevelIdentifier()
    local limitedMileageSchemaOutdated =
      tonumber(data.limitedMileageDealerSchemaVersion) ~= M.limitedMileageDealerSchemaVersion
    vehicleWatchlist = data.vehicleWatchlist or {}
    rtPendingFleetPurchases = data.rtPendingFleetPurchases or {}

    -- New format with 'maps' key
    if data.maps then
      otherMapsData = data.maps
      for mapId, mapData in pairs(otherMapsData) do
        if mapData.vehiclesInShop then
          local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(mapData.vehiclesInShop,
            "load:" .. tostring(mapId))
          if limitedMileageSchemaOutdated then
            for i = #sanitizedVehicles, 1, -1 do
              local sellerId = sanitizedVehicles[i].sellerId
              if sellerId == "raceTab" or sellerId == "asotv" then
                table.remove(sanitizedVehicles, i)
              end
            end
          end
          mapData.vehiclesInShop = sanitizedVehicles
          if loadSummary.raw > 0 then
            logVehicleSanitizationSummary("saved vehicle load " .. tostring(mapId), loadSummary)
          end
        end
      end
    else
      -- Migration from old flat format
      local oldVehicles = data.vehiclesInShop or {}
      local oldSellers = data.sellersInfos or {}
      local oldDirtyDate = data.dirtyDate

      for _, vehicleInfo in ipairs(oldVehicles) do
        local sanitizedVehicles, _ = sanitizeSavedVehicleEntries({vehicleInfo}, "load:migration")
        local sanitizedVehicle = sanitizedVehicles[1]
        if sanitizedVehicle and not (limitedMileageSchemaOutdated and
          (sanitizedVehicle.sellerId == "raceTab" or sanitizedVehicle.sellerId == "asotv")) then
          local mId = sanitizedVehicle.mapId or currentMap
          if not otherMapsData[mId] then otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
          table.insert(otherMapsData[mId].vehiclesInShop, sanitizedVehicle)
        end
      end

      for sellerId, sellerInfo in pairs(oldSellers) do
        local mId = sellerInfo.mapId or currentMap
        if not otherMapsData[mId] then otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
        otherMapsData[mId].sellersInfos[sellerId] = sellerInfo
      end
      
      -- Assign dirty date to the current map if it was migration
      if otherMapsData[currentMap] then
        otherMapsData[currentMap].dirtyDate = oldDirtyDate
      end
    end

    -- Set current map data
    local currentData = otherMapsData[currentMap] or {}
    local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
      "load:current:" .. tostring(currentMap))
    if loadSummary.raw > 0 then
      logVehicleSanitizationSummary("saved vehicle load current " .. tostring(currentMap), loadSummary)
    end
    currentData.vehiclesInShop = sanitizedVehicles
    vehiclesInShop = sanitizedVehicles
    sellersInfos = currentData.sellersInfos or {}
    vehicleShopDirtyDate = currentData.dirtyDate
    lastMap = currentMap
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local currentMap = getCurrentLevelIdentifier()
  
  -- Update the stash for the current map
  otherMapsData[currentMap] = {
    vehiclesInShop = vehiclesInShop,
    sellersInfos = sellersInfos,
    dirtyDate = vehicleShopDirtyDate
  }

  local data = {}
  data.maps = otherMapsData
  data.vehicleWatchlist = vehicleWatchlist
  data.rtPendingFleetPurchases = rtPendingFleetPurchases
  data.discoveredDealers = discoveredDealers
  data.version = moduleVersion
  data.valuationSchemaVersion = valuationSchemaVersion
  data.limitedMileageDealerSchemaVersion = M.limitedMileageDealerSchemaVersion
  
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

local function getCurrentSellerId()
  return currentSeller
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    label = "Vehicle Marketplace",
    routeTarget = "career.computer.vehicleShopping",
    callback = function()
      openShop(nil, menuData.computerFacility.id)
    end,
    order = 10
  }
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function onModActivated()
  resetVehicleValidationState()
  cacheDealers()
end

local function onWorldReadyState(state)
  if state == 2 then
    local currentMap = getCurrentLevelIdentifier()

    -- Stash previous map data if it exists
    if lastMap and lastMap ~= currentMap then
      otherMapsData[lastMap] = {
        vehiclesInShop = vehiclesInShop,
        sellersInfos = sellersInfos,
        dirtyDate = vehicleShopDirtyDate
      }
    end

    -- Load new map data
    if otherMapsData[currentMap] then
      local currentData = otherMapsData[currentMap]
      local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
        "onWorldReadyState:" .. tostring(currentMap))
      if loadSummary.raw > 0 then
        logVehicleSanitizationSummary("world load " .. tostring(currentMap), loadSummary)
      end
      currentData.vehiclesInShop = sanitizedVehicles
      vehiclesInShop = sanitizedVehicles
      sellersInfos = currentData.sellersInfos or {}
      vehicleShopDirtyDate = currentData.dirtyDate
    else
      -- If no data for this map, start fresh but keep watchlist
      vehiclesInShop = {}
      sellersInfos = {}
      vehicleShopDirtyDate = nil
    end

    lastMap = currentMap
    cacheDealers()

    -- Repair freight purchases made before pickup completion assigned a home
    -- garage. A current/last vehicle proves the player has already collected it.
    local collectedInventoryId =
      (career_modules_inventory.getCurrentVehicle and career_modules_inventory.getCurrentVehicle()) or
      (career_modules_inventory.getLastVehicle and career_modules_inventory.getLastVehicle())
    M.completeFreightPickup(collectedInventoryId)
  end
end

-- Statistics and utility functions
local function getCacheStats()
  if not vehicleCache.cacheValid then
    return {
      valid = false,
      message = "Cache not initialized"
    }
  end

  local stats = {
    valid = true,
    cacheTime = vehicleCache.lastCacheTime,
    dealerships = {},
    totalVehicles = 0
  }

  for dealershipId, data in pairs(vehicleCache.dealershipCache) do
    local regularCount = data.regularVehicles and #data.regularVehicles or 0
    stats.dealerships[dealershipId] = {
      regularVehicles = regularCount,
      total = regularCount
    }
    stats.totalVehicles = stats.totalVehicles + regularCount
  end

  return stats
end

local function getMapStats()
  local stats = {
    currentMap = getCurrentLevelIdentifier(),
    vehiclesByMap = {},
    sellersByMap = {},
    totalVehicles = #vehiclesInShop,
    totalSellers = tableSize(sellersInfos)
  }

  for _, vehicleInfo in ipairs(vehiclesInShop) do
    local mapId = vehicleInfo.mapId or "unknown"
    stats.vehiclesByMap[mapId] = (stats.vehiclesByMap[mapId] or 0) + 1
  end

  for sellerId, sellerInfo in pairs(sellersInfos) do
    local mapId = sellerInfo.mapId or "unknown"
    stats.sellersByMap[mapId] = (stats.sellersByMap[mapId] or 0) + 1
  end

  return stats
end

local function clearDataFromOtherMaps(targetMap)
  targetMap = targetMap or getCurrentLevelIdentifier()

  local filteredVehicles = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.mapId == targetMap then
      table.insert(filteredVehicles, vehicleInfo)
    end
  end
  local removedVehicles = #vehiclesInShop - #filteredVehicles
  vehiclesInShop = filteredVehicles

  local filteredSellers = {}
  local removedSellers = 0
  for sellerId, sellerInfo in pairs(sellersInfos) do
    if sellerInfo.mapId == targetMap then
      filteredSellers[sellerId] = sellerInfo
    else
      removedSellers = removedSellers + 1
    end
  end
  sellersInfos = filteredSellers

  return {
    vehiclesRemoved = removedVehicles,
    sellersRemoved = removedSellers
  }
end

-- Public API
M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.navigateToDealership = navigateToDealership
M.taxiToDealership = taxiToDealership
M.getTaxiPriceToDealership = getTaxiPriceToDealership
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendShoppingDataToUI = sendShoppingDataToUI
M.onRouteMount = onRouteMount
M.selectSeller = selectSeller
M.getSelectedSellerBreadcrumbTitle = getSelectedSellerBreadcrumbTitle
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getDeliveryQuote = getDeliveryQuote
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage
M.invalidateVehicleCache = invalidateVehicleCache
M.getLastDelta = function()
  return lastDelta
end
M.setShoppingUiOpen = setShoppingUiOpen
M.getVehicleInfoByShopId = getVehicleInfoByShopId
M.registerCarMeetVehicle = registerCarMeetVehicle
M.removeCarMeetVehicles = removeCarMeetVehicles
M.canPurchaseCarMeetVehicle = canPurchaseCarMeetVehicle
M.getCarMeetPurchaseBlockReason = getCarMeetPurchaseBlockReason
M.buyCarMeetVehicleNow = buyCarMeetVehicleNow
M.grantRewardVehicle = grantRewardVehicle
M.getPendingRacingTeamFleetPurchases = getPendingRacingTeamFleetPurchases
M.clearPendingRacingTeamFleetPurchases = clearPendingRacingTeamFleetPurchases

M.openPurchaseMenu = openPurchaseMenu
M.updateInsuranceSelection = updateInsuranceSelection
M.buyFromPurchaseMenu = buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = openInventoryMenuForTradeIn
M.removeTradeInVehicle = removeTradeInVehicle

M.endShopping = endShopping
M.cancelShopping = cancelShopping
M.requestExit = requestExit
M.requestVehicleListExit = requestVehicleListExit
M.cancelPurchase = cancelPurchase
M.requestPurchaseExit = requestPurchaseExit

M.getVehiclesInShop = getVehiclesInShop

M.onWorldReadyState = onWorldReadyState
M.onModActivated = onModActivated
M.onClientStartMission = onClientStartMission
M.onVehicleSpawnFinished = onVehicleSpawnFinished
M.onRewardVehicleSpawnFinished = onRewardVehicleSpawnFinished
M.onRacingTeamFleetVehicleSpawnFinished = onRacingTeamFleetVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onShoppingMenuClosed = onShoppingMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions
M.onUpdate = onUpdate
M.onUiChangedState = onUiChangedState

M.onVehicleInspectionFinished = function(shopId)
  if inspectingVehicleShopId == shopId then
    inspectingVehicleShopId = nil
    log("D", "Career", "Inspection finished for vehicle: " .. tostring(shopId))
  end
end

M.checkSpawnedVehicleStatus = function()
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo and inspectingVehicleShopId and spawnedVehicleInfo.shopId == inspectingVehicleShopId then
    return true
  elseif inspectingVehicleShopId then
    log("D", "Career", "Clearing inspection state for vehicle: " .. tostring(inspectingVehicleShopId))
    inspectingVehicleShopId = nil
    return false
  end
  return false
end

M.cacheDealers = cacheDealers
M.rebuildDealershipCache = rebuildDealershipCache
M.getRandomVehicleFromCache = getRandomVehicleFromCache
M.getCacheStats = getCacheStats
M.getMapStats = getMapStats
M.clearDataFromOtherMaps = clearDataFromOtherMaps
M.getEligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles

function M.setRtBiz(id)
  if id == nil or id == "" then
    rtBizId = nil
    -- Do not clear currentSeller/originComputerId here:
    -- VehicleShoppingMain always calls setRtBiz(""), including normal in-person dealer flow.
    -- Clearing seller scope here unintentionally widens in-person shopping to global marketplace.
    return true
  end
  rtBizId = tonumber(id) or id
  -- Entering the racing team computer's vehicle shopping context; drop any stale
  -- dealer scope so the shop isn't silently filtered to the last visited dealer.
  currentSeller = nil
  originComputerId = nil
  selectedSellerId = nil
  shoppingScreenTag = "buying"
  buyingAvailable = true
  marketplaceAvailable = false
  sendShoppingDataToUI()
  return true
end

return M
