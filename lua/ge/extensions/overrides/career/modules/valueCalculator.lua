-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local jbeamIO = require('jbeam/io')

local ASSEMBLED_VEHICLE_FACTOR = 0.72
local USED_PART_SELLER_RECOVERY = 0.55
local ADDED_PART_VALUE_FACTOR = 0.60
local PARTS_DERIVED_VALUE_FLOOR = 0.30
local MIN_PC_PARTS_FOR_PARTS_CATALOG = 3
local CLASSIC_MODEL_YEAR = 1985
local EXPECTED_ANNUAL_MILES = 10000
local EXPECTED_MILEAGE_CAP = 250000
local CLASSIC_BASE_RETENTION_FLOOR = 0.31
local CLASSIC_PRESERVATION_MAX_FACTOR = 0.90
local CLASSIC_TIME_CAPSULE_PREMIUM = 0.35
local CLASSIC_TIME_CAPSULE_DECAY_MILES = 30000
local CLASSIC_LOW_MILEAGE_PREMIUM = 0.18
local CLASSIC_LOW_MILEAGE_DECAY_MILES = 100000
local CUSTOM_CLASSIC_BASE_FLOOR = 0.65
local CUSTOM_CLASSIC_MAX_FLOOR = 1.20
local LOW_MILEAGE_PRESERVATION_START_AGE = 25
local LOW_MILEAGE_PRESERVATION_FULL_AGE = 45
local LOW_MILEAGE_PRESERVATION_MAX_FACTOR = 0.72
local LOW_MILEAGE_PRESERVATION_DECAY_MILES = 60000
local COMMERCIAL_DURABILITY_START_AGE = 12
local COMMERCIAL_DURABILITY_FULL_AGE = 25
local COMMERCIAL_AGE_RETENTION_FLOOR = 0.46
local DIESEL_TRUCK_AGE_RETENTION_FLOOR = 0.42
local DIESEL_TRUCK_VALUE_MODIFIER = 1.06
local DIESEL_TRUCK_VALUE_START_AGE = 5
local DIESEL_TRUCK_VALUE_FULL_AGE = 15
local MANUAL_TRANSMISSION_MODIFIER = 1.01
local HIGH_PERFORMANCE_POWER_START = 600
local HIGH_PERFORMANCE_POWER_SPAN = 600
local HIGH_PERFORMANCE_DENSITY_START = 0.30
local HIGH_PERFORMANCE_DENSITY_FULL = 0.48
local HIGH_PERFORMANCE_RETENTION_GAIN = 1.50
local HIGH_PERFORMANCE_SCORE_EXPONENT = 1.20
local HIGH_PERFORMANCE_FACTORY_MAX_FLOOR = 1.10
local HIGH_PERFORMANCE_START_AGE = 1
local HIGH_PERFORMANCE_FULL_AGE = 5
local ANTIQUE_APPRECIATION_START_AGE = 55
local ANTIQUE_APPRECIATION_FULL_AGE = 70
local ANTIQUE_AGE_RETENTION_FLOOR = 0.39
local pcPartsCatalogCache = {}
local pcPartsCatalogBadLogOnce = {}
local vehicleCatalogProfileCache = {}
local configInfoIndex

-- Optional, deliberately small escape hatch for significance that cannot be
-- inferred from vehicle metadata. Keys are "model|config".
local haloOverrides = {
  -- ["model|config"] = {add = 0.10},
  -- ["model|config"] = {score = 0.85},
}

local function isHardcoreMode()
  return career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode()
end

-- vehicle damage related variables
local repairTimePerPart = 60 -- amount of seconds needed to repair one part
local brokenPartsThreshold = 3 -- a vehicle is considered to need repair after x broken parts
local minimumCarValue = 500
local minimumCarValueRelativeToNew = 0.05

local function getPartNamesFromTree(Tree)
  local partNames = {}
  for _, part in ipairs(Tree) do
    if part.children then
      local result = getPartNamesFromTree(part.children)
      if result then
        for _, partName in ipairs(result) do
          table.insert(partNames, partName)
        end
      end
    else
      table.insert(partNames, part.chosenPartName)
    end
  end
  return partNames
end

local function getVehicleMileageById(inventoryId)
  return career_modules_inventory.getVehicles()[inventoryId].mileage or 0
end


local AGE_RETENTION_POINTS = {
  {0, 1.00},
  {1, 0.92},
  {3, 0.84},
  {5, 0.75},
  {10, 0.58},
  {15, 0.46},
  {20, 0.37},
  {30, 0.27},
  {40, 0.22},
  {60, 0.18},
}

local MILEAGE_RETENTION_POINTS = {
  {0, 1.00},
  {50000, 0.95},
  {150000, 0.80},
  {300000, 0.55},
  {500000, 0.35},
}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function smoothstep(value, edge0, edge1)
  if edge0 == edge1 then return value >= edge1 and 1 or 0 end
  local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

local function interpolateRetention(points, value, logLinear)
  value = math.max(0, tonumber(value) or 0)
  for i = 1, #points - 1 do
    local left, right = points[i], points[i + 1]
    if value <= right[1] then
      local t = (value - left[1]) / (right[1] - left[1])
      if logLinear then
        return math.exp(math.log(left[2]) + (math.log(right[2]) - math.log(left[2])) * t)
      end
      return left[2] + (right[2] - left[2]) * t
    end
  end
  return points[#points][2]
end

local function getOrdinaryAgeRetention(age)
  age = math.max(0, tonumber(age) or 0)
  if age <= AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][1] then
    return interpolateRetention(AGE_RETENTION_POINTS, age, true)
  end
  local yearsPastSixty = age - AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][1]
  return math.max(0.15, AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][2] * (0.995 ^ yearsPastSixty))
end

local function getMileageRetention(mileageMeters)
  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / 1609.344
  return interpolateRetention(MILEAGE_RETENTION_POINTS, mileageMiles, false)
end

local function getClassicActivation(age)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local classicThresholdAge = math.max(0, currentYear - CLASSIC_MODEL_YEAR)
  return smoothstep(tonumber(age) or 0, classicThresholdAge, classicThresholdAge + 7)
end

local function getExpectedMileageMiles(age)
  return math.min(EXPECTED_MILEAGE_CAP, math.max(0, tonumber(age) or 0) * EXPECTED_ANNUAL_MILES)
end

-- Mileage on a late-model vehicle remains absolute. As a vehicle ages, the
-- same odometer reading is judged increasingly against the mileage normally
-- accumulated over its lifetime. This avoids charging an old car twice for
-- both age and ordinary-for-its-age mileage while remaining monotonic.
local function getVehicleMileageRetention(mileageMeters, age, commercialDurable)
  local absoluteFactor = getMileageRetention(mileageMeters)
  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / 1609.344
  local expectedMiles = getExpectedMileageMiles(age)
  if expectedMiles <= 0 then
    return absoluteFactor, absoluteFactor, expectedMiles, absoluteFactor, absoluteFactor
  end

  local expectedFactor = interpolateRetention(MILEAGE_RETENTION_POINTS, expectedMiles, false)
  local relativeFactor = clamp(absoluteFactor / math.max(0.01, expectedFactor), 0.45, 1.30)
  local relativeBlend = smoothstep(tonumber(age) or 0, 8, 25)
  local effectiveFactor = absoluteFactor + (relativeFactor - absoluteFactor) * relativeBlend
  -- Age-relative mileage prevents an ordinary older car from being charged
  -- twice for age and use, but it must not erase genuinely high odometer wear.
  -- Preserve existing prices below 100k, then phase that relief out by 200k.
  local highMileageWearActivation = smoothstep(mileageMiles, 100000, 200000)
  effectiveFactor = effectiveFactor +
    (absoluteFactor - effectiveFactor) * highMileageWearActivation
  local commercialMileageFactor = effectiveFactor
  if commercialDurable then
    local commercialActivation = smoothstep(
      tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
    local dutyCycleFactor = 0.75 + 0.40 * math.exp(-mileageMiles / 500000)
    commercialMileageFactor = effectiveFactor +
      (math.max(effectiveFactor, dutyCycleFactor) - effectiveFactor) * commercialActivation
    effectiveFactor = commercialMileageFactor
  end
  return effectiveFactor, absoluteFactor, expectedMiles, relativeFactor, commercialMileageFactor
end

local function getLowMileagePreservationFloor(age, mileageMeters, baseAgeFactor, haloScore, targetFactor)
  local activation = smoothstep(
    tonumber(age) or 0, LOW_MILEAGE_PRESERVATION_START_AGE, LOW_MILEAGE_PRESERVATION_FULL_AGE)
  if activation <= 0 then return 0, activation, 0 end

  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / 1609.344
  local strength = math.exp(-mileageMiles / LOW_MILEAGE_PRESERVATION_DECAY_MILES)
  targetFactor = tonumber(targetFactor) or
    (LOW_MILEAGE_PRESERVATION_MAX_FACTOR + 0.15 * clamp(tonumber(haloScore) or 0, 0, 1))
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local preservationFloor = baseAgeFactor +
    math.max(0, targetFactor - baseAgeFactor) * activation * strength
  return preservationFloor, activation, strength
end

local function getCommercialAgeFloor(age, baseAgeFactor, commercialDurable, retentionFloor)
  if not commercialDurable then return 0, 0 end
  local activation = smoothstep(
    tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  retentionFloor = tonumber(retentionFloor) or COMMERCIAL_AGE_RETENTION_FLOOR
  local commercialFloor = baseAgeFactor +
    math.max(0, retentionFloor - baseAgeFactor) * activation
  return commercialFloor, activation
end

local function getDieselTruckAgeFloor(age, baseAgeFactor, dieselTruck)
  if not dieselTruck then return 0, 0 end
  local activation = smoothstep(
    tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local dieselTruckFloor = baseAgeFactor +
    math.max(0, DIESEL_TRUCK_AGE_RETENTION_FLOOR - baseAgeFactor) * activation
  return dieselTruckFloor, activation
end

local function getPowertrainValueModifiers(age, transmission, dieselTruck)
  local transmissionLower = string.lower(tostring(transmission or ""))
  local manualModifier =
    string.find(transmissionLower, "manual", 1, true) and MANUAL_TRANSMISSION_MODIFIER or 1
  local dieselActivation = dieselTruck and smoothstep(
    tonumber(age) or 0, DIESEL_TRUCK_VALUE_START_AGE, DIESEL_TRUCK_VALUE_FULL_AGE) or 0
  local dieselModifier = 1 + (DIESEL_TRUCK_VALUE_MODIFIER - 1) * dieselActivation
  return manualModifier, dieselModifier, dieselActivation
end

local function getHighPerformanceScore(hp, weight, configType)
  -- Modified/competition configurations already carry the value of their
  -- installed parts. Applying another power-to-weight premium here made drag
  -- builds appreciate twice and badly overstated their used value.
  if configType ~= "Factory" then return 0 end
  hp = tonumber(hp)
  weight = tonumber(weight)
  if not hp or not weight or hp <= 0 or weight <= 0 then return 0 end

  local powerScore = clamp(
    (hp - HIGH_PERFORMANCE_POWER_START) / HIGH_PERFORMANCE_POWER_SPAN, 0, 1)
  local powerDensity = hp / weight
  local densityEligibility = smoothstep(
    powerDensity, HIGH_PERFORMANCE_DENSITY_START, HIGH_PERFORMANCE_DENSITY_FULL)
  return powerScore * densityEligibility
end

local function getHighPerformanceRetentionFloor(
  age, baseAgeFactor, highPerformanceScore, configType)
  highPerformanceScore = clamp(tonumber(highPerformanceScore) or 0, 0, 1)
  if configType ~= "Factory" or highPerformanceScore <= 0 then return 0, 0 end

  local activation = smoothstep(
    tonumber(age) or 0, HIGH_PERFORMANCE_START_AGE, HIGH_PERFORMANCE_FULL_AGE)
  if activation <= 0 then return 0, activation end

  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local targetFloor = math.min(
    HIGH_PERFORMANCE_FACTORY_MAX_FLOOR,
    baseAgeFactor +
      HIGH_PERFORMANCE_RETENTION_GAIN *
      (highPerformanceScore ^ HIGH_PERFORMANCE_SCORE_EXPONENT))
  local floor = baseAgeFactor + math.max(0, targetFloor - baseAgeFactor) * activation
  return floor, activation
end

local function getCommodityDepreciationMultiplier(age, haloScore, factoryConfig)
  if not factoryConfig then return 1, 0 end
  local activation =
    smoothstep(tonumber(age) or 0, 10, 16) *
    (1 - smoothstep(tonumber(age) or 0, 22, 28))
  local haloProtection = clamp(tonumber(haloScore) or 0, 0, 1)
  local multiplier = 1 - activation * 0.55 * (1 - haloProtection)
  return multiplier, activation
end

local function getAntiqueAgeFloor(age, baseAgeFactor)
  local activation = smoothstep(
    tonumber(age) or 0, ANTIQUE_APPRECIATION_START_AGE, ANTIQUE_APPRECIATION_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local floor = baseAgeFactor +
    math.max(0, ANTIQUE_AGE_RETENTION_FLOOR - baseAgeFactor) * activation
  return floor, activation
end

local function getClassicAgeFloor(age, mileageMeters, baseAgeFactor, customClassicScore)
  local activation = getClassicActivation(age)
  if activation <= 0 then
    return 0, activation, 0, 0
  end

  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / 1609.344
  -- A preserved classic is special because of its absolute mileage, but the
  -- curve stays broad enough that 10 miles and 10,000 miles are not separate
  -- economic worlds.
  local timeCapsulePremium =
    CLASSIC_TIME_CAPSULE_PREMIUM *
    math.exp(-mileageMiles / CLASSIC_TIME_CAPSULE_DECAY_MILES)
  local lowMileagePremium =
    CLASSIC_LOW_MILEAGE_PREMIUM *
    math.exp(-mileageMiles / CLASSIC_LOW_MILEAGE_DECAY_MILES)
  local preservationStrength = clamp(
    (timeCapsulePremium + lowMileagePremium) /
    math.max(0.001, CLASSIC_PRESERVATION_MAX_FACTOR - CLASSIC_BASE_RETENTION_FLOOR),
    0, 1)
  local preservationRatio = preservationStrength
  local targetFloor =
    CLASSIC_BASE_RETENTION_FLOOR + timeCapsulePremium + lowMileagePremium

  if customClassicScore ~= nil then
    local customFloor = CUSTOM_CLASSIC_BASE_FLOOR +
      (CUSTOM_CLASSIC_MAX_FLOOR - CUSTOM_CLASSIC_BASE_FLOOR) *
      clamp(tonumber(customClassicScore) or 0, 0, 1)
    targetFloor = math.max(targetFloor, customFloor)
  end

  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local classicFloor = baseAgeFactor
  if targetFloor > baseAgeFactor then
    classicFloor = baseAgeFactor + (targetFloor - baseAgeFactor) * activation
  end
  return classicFloor, activation, preservationRatio, preservationStrength
end

local function getVehicleListingPriceRange(range)
  range = type(range) == "table" and range or {0.70, 0.88, 1.12, 1.30}
  local normalLowSource = tonumber(range[2]) or 0.88
  local normalHighSource = tonumber(range[3]) or 1.12
  local center = clamp((normalLowSource + normalHighSource) * 0.5, 0.95, 1.05)
  return {
    tailLow = 0.70,
    normalLow = math.max(0.88, center - 0.12),
    normalHigh = math.min(1.12, center + 0.12),
    tailHigh = 1.30,
    center = center
  }
end

local function getAgeRetention(age, haloScore)
  local ordinary = getOrdinaryAgeRetention(age)
  haloScore = clamp(tonumber(haloScore) or 0, 0, 1)
  local haloExponent = 1 - 0.55 * haloScore
  local haloAgeFactor = ordinary ^ haloExponent
  local collectorActivation = smoothstep(tonumber(age) or 0, 18, 35)
  local collectorFloor = collectorActivation * haloScore * (0.25 + 0.25 * haloScore)
  return math.max(haloAgeFactor, collectorFloor), ordinary, collectorFloor
end

local function getAdjustedVehicleBaseValue(value, vehicleCondition)
  vehicleCondition = vehicleCondition or {}
  local baseValue = tonumber(value) or 10000
  local age = vehicleCondition.age or 0
  local mileage = vehicleCondition.mileage or 0
  local ageFactor = getAgeRetention(age, vehicleCondition.haloScore or 0)
  local preservationFloor = getLowMileagePreservationFloor(
    age, mileage, ageFactor, vehicleCondition.haloScore or 0)
  local classicFloor = getClassicAgeFloor(age, mileage, ageFactor)
  local dieselTruckFloor = getDieselTruckAgeFloor(
    age, ageFactor, vehicleCondition.dieselTruck)
  local highPerformanceFloor = getHighPerformanceRetentionFloor(
    age, ageFactor, vehicleCondition.highPerformanceScore, vehicleCondition.configType)
  ageFactor = math.max(
    ageFactor, preservationFloor, classicFloor, dieselTruckFloor, highPerformanceFloor)
  local mileageFactor = getVehicleMileageRetention(mileage, age, vehicleCondition.commercialDurable)
  local manualModifier, dieselModifier = getPowertrainValueModifiers(
    age, vehicleCondition.transmission, vehicleCondition.dieselTruck)
  return math.max(0, baseValue * ageFactor * mileageFactor * manualModifier * dieselModifier)
end

local function getPartDifference(originalParts, newParts, changedSlots)
  local addedParts = {}
  local removedParts = {}
  if not originalParts then return addedParts, removedParts end
  newParts = newParts or {}
  changedSlots = changedSlots or {}
  for slotName, oldPart in pairs(originalParts) do
    if newParts then
      local newPart = newParts[slotName]
      if newPart ~= oldPart.name then
        if oldPart.name ~= "" then
          -- part was removed
          removedParts[slotName] = oldPart.name
        end
        if newPart ~= "" then
          -- part was added
          addedParts[slotName] = newPart
        end
      end
    end
  end

  for slotName, newPart in pairs(newParts) do
    local oldPart = originalParts[slotName]
    if newPart ~= "" then
      if not oldPart then
        -- part was added
        addedParts[slotName] = newPart
      end

      -- using part condition to see if there was another of the same part installed
      if changedSlots[slotName] and oldPart and newPart == oldPart.name then
        addedParts[slotName] = newPart
        removedParts[slotName] = originalParts[slotName]
      end
    end
  end

  return addedParts, removedParts
end

local function getDepreciatedPartValue(value, mileage)
  local mileageMiles = math.max(0, tonumber(mileage) or 0) / 1609.344
  local mileageFactor = 0.25 + 0.75 * math.exp(-mileageMiles / 120000)
  return math.max(0, tonumber(value) or 0) * mileageFactor
end

local function getVehicleBuyMarketMultiplier()
  if career_modules_globalEconomy and career_modules_globalEconomy.getVehicleBuyMultiplier then
    return career_modules_globalEconomy.getVehicleBuyMultiplier()
  end
  return 1.0
end

local function getVehicleSellMarketMultiplier()
  if career_modules_globalEconomy and career_modules_globalEconomy.getVehicleSellMultiplier then
    return career_modules_globalEconomy.getVehicleSellMultiplier()
  end
  return 1.0
end

local function applyVehicleBuyMarketToMoney(amount)
  local mult = getVehicleBuyMarketMultiplier()
  return math.floor((tonumber(amount) or 0) * mult + 0.5)
end

local function clearVehiclePcPartsCatalogSumCache()
  table.clear(pcPartsCatalogCache)
  table.clear(pcPartsCatalogBadLogOnce)
  table.clear(vehicleCatalogProfileCache)
  configInfoIndex = nil
end

local function getVehiclePcPartsCatalogStats(modelName, configKey, logContext)
  if not modelName or not configKey then
    return {total = 0, highest = 0, count = 0}
  end
  local cacheKey = tostring(modelName) .. "|" .. tostring(configKey)
  if pcPartsCatalogCache[cacheKey] ~= nil then
    return pcPartsCatalogCache[cacheKey]
  end
  local ioCtx = jbeamIO.startLoading({
    "/vehicles/" .. modelName .. "/",
    "/vehicles/common/"
  })
  local candidatePcPaths = {
    "/vehicles/" .. modelName .. "/" .. configKey .. ".pc",
    "/vehicles/" .. modelName .. "/configurations/" .. configKey .. ".pc",
  }
  local pcPath, pcData
  for _, candidate in ipairs(candidatePcPaths) do
    local ok, data = pcall(jsonReadFile, candidate)
    if ok and data and type(data.parts) == "table" then
      pcPath = candidate
      pcData = data
      break
    end
  end
  if not pcData or type(pcData.parts) ~= "table" then
    local logKey = cacheKey .. "|partsMissing"
    if not pcPartsCatalogBadLogOnce[logKey] then
      pcPartsCatalogBadLogOnce[logKey] = true
      log("W", "valueCalculator", string.format(
        "PC parts unreadable for %s during %s (%s)",
        cacheKey, tostring(logContext or "pcParts"), table.concat(candidatePcPaths, ", ")))
    end
    pcPartsCatalogCache[cacheKey] = {total = 0, highest = 0, count = 0}
    return pcPartsCatalogCache[cacheKey]
  end
  local valueOk, stats = pcall(function()
    local accumulatedValue = 0
    local highestValue = 0
    local partCount = 0
    for _, partName in pairs(pcData.parts) do
      if partName and partName ~= "" then
        local partData = jbeamIO.getPart(ioCtx, partName)
        if partData and partData.information and partData.information.value then
          local partValue = math.max(0, tonumber(partData.information.value) or 0)
          accumulatedValue = accumulatedValue + partValue
          highestValue = math.max(highestValue, partValue)
          partCount = partCount + 1
        end
      end
    end
    return {total = accumulatedValue, highest = highestValue, count = partCount}
  end)
  if not valueOk then
    local logKey = cacheKey .. "|partsValueError"
    if not pcPartsCatalogBadLogOnce[logKey] then
      pcPartsCatalogBadLogOnce[logKey] = true
      log("W", "valueCalculator", string.format(
        "PC parts jbeam lookup failed for %s (%s): %s",
        cacheKey, tostring(logContext or "pcParts"), tostring(stats)))
    end
    pcPartsCatalogCache[cacheKey] = {total = 0, highest = 0, count = 0}
    return pcPartsCatalogCache[cacheKey]
  end
  pcPartsCatalogCache[cacheKey] = stats
  return stats
end

local function getVehiclePcPartsCatalogSum(modelName, configKey, logContext)
  return getVehiclePcPartsCatalogStats(modelName, configKey, logContext).total
end

local function getVehiclePartsCatalogValue(partsCatalogSum)
  local partsBase = tonumber(partsCatalogSum) or 0
  if partsBase <= 0 then
    return 0
  end
  return math.floor(partsBase * ASSEMBLED_VEHICLE_FACTOR + 0.5)
end

local function median(values)
  if not values or #values == 0 then return nil end
  table.sort(values)
  local middle = math.floor(#values / 2)
  if #values % 2 == 1 then
    return values[middle + 1]
  end
  return (values[middle] + values[middle + 1]) * 0.5
end

local function getConfigType(configInfo)
  if type(configInfo) ~= "table" then return nil end
  local direct = configInfo.configType or configInfo["Config Type"]
  if type(direct) == "string" then return direct end
  if type(direct) == "table" then
    for key, enabled in pairs(direct) do
      if enabled then return key end
    end
  end
  local aggregate = configInfo.aggregates and configInfo.aggregates["Config Type"]
  if type(aggregate) == "string" then return aggregate end
  if type(aggregate) == "table" then
    for key, enabled in pairs(aggregate) do
      if enabled then return key end
    end
  end
  return nil
end

local function getConfigYears(configInfo)
  if type(configInfo) ~= "table" then return nil end
  local years = configInfo.Years or (configInfo.aggregates and configInfo.aggregates.Years)
  if type(years) ~= "table" then return nil end
  local minYear = tonumber(years.min)
  local maxYear = tonumber(years.max)
  if not minYear or not maxYear then return nil end
  if minYear > maxYear then minYear, maxYear = maxYear, minYear end
  return {min = minYear, max = maxYear}
end

local function yearsOverlap(left, right)
  return left and right and left.min <= right.max and right.min <= left.max
end

local function getConfigInfoIndex()
  if configInfoIndex then return configInfoIndex end
  configInfoIndex = {}
  local configList = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList() or {}
  local configs = configList.configs or configList
  for _, configInfo in pairs(configs or {}) do
    if type(configInfo) == "table" and configInfo.model_key and configInfo.key then
      configInfoIndex[tostring(configInfo.model_key) .. "|" .. tostring(configInfo.key)] = configInfo
    end
  end
  return configInfoIndex
end

local function getConfigInfo(modelName, configKey, suppliedInfo)
  if type(suppliedInfo) == "table" then return suppliedInfo end
  return getConfigInfoIndex()[tostring(modelName) .. "|" .. tostring(configKey)]
end

local function getConfigNumber(configInfo, key)
  if type(configInfo) ~= "table" then return nil end
  local value = tonumber(configInfo[key])
  if value then return value end
  local aggregate = configInfo.aggregates and configInfo.aggregates[key]
  if type(aggregate) == "table" then
    return tonumber(aggregate.max) or tonumber(aggregate.min)
  end
  return tonumber(aggregate)
end

local function getConfigString(configInfo, key)
  if type(configInfo) ~= "table" then return nil end
  local direct = configInfo[key]
  if type(direct) == "string" then return direct end
  local aggregate = configInfo.aggregates and configInfo.aggregates[key]
  if type(aggregate) == "string" then return aggregate end
  if type(aggregate) == "table" then
    for value, enabled in pairs(aggregate) do
      if enabled == true then return tostring(value) end
    end
  end
  return nil
end

local function inferBodyStyle(configInfo)
  local bodyStyle = getConfigString(configInfo, "Body Style")
  if bodyStyle then return bodyStyle end
  local name = string.lower(tostring(configInfo and configInfo.Name or ""))
  if string.find(name, "wagon", 1, true) then return "Wagon" end
  if string.find(name, "coupe", 1, true) then return "Coupe" end
  if string.find(name, "sedan", 1, true) then return "Sedan" end
  if string.find(name, "mixer", 1, true) or string.find(name, "cement", 1, true) then
    return "Mixer Truck"
  end
  return nil
end

local function getFactoryPeerInfos(modelName, configInfo)
  if getConfigType(configInfo) ~= "Factory" then return {} end
  local candidateYears = getConfigYears(configInfo)
  if not candidateYears then return {} end
  local peers = {}
  for _, peer in pairs(getConfigInfoIndex()) do
    if peer.model_key == modelName
      and getConfigType(peer) == "Factory"
      and yearsOverlap(candidateYears, getConfigYears(peer)) then
      table.insert(peers, peer)
    end
  end
  return peers
end

local function getVehicleCatalogProfile(modelName, configKey, configInfo)
  if not modelName or not configKey then return nil end
  local cacheKey = tostring(modelName) .. "|" .. tostring(configKey)
  if vehicleCatalogProfileCache[cacheKey] then
    return vehicleCatalogProfileCache[cacheKey]
  end

  configInfo = getConfigInfo(modelName, configKey, configInfo)
  local partsStats = getVehiclePcPartsCatalogStats(modelName, configKey, "catalogProfile")
  local fallbackValue = configInfo and tonumber(configInfo.Value) or 0
  local configType = getConfigType(configInfo)
  local fuelType = getConfigString(configInfo, "Fuel Type")
  local bodyStyle = inferBodyStyle(configInfo)
  local drivetrain = getConfigString(configInfo, "Drivetrain")
  local transmission = getConfigString(configInfo, "Transmission")
  local hp = getConfigNumber(configInfo, "Power")
  local weight = getConfigNumber(configInfo, "Weight")
  local bodyStyleLower = string.lower(tostring(bodyStyle or ""))
  local mixerUpfit =
    string.find(bodyStyleLower, "mixer", 1, true) ~= nil or
    string.find(bodyStyleLower, "cement", 1, true) ~= nil
  local vocationalUpfit =
    string.find(bodyStyleLower, "dump", 1, true) ~= nil or
    mixerUpfit or
    string.find(bodyStyleLower, "tanker", 1, true) ~= nil
  local catalogValue
  local catalogSource
  local rawPartsCatalogValue = getVehiclePartsCatalogValue(partsStats.total)
  local sparsePartsCatalog =
    partsStats.count < MIN_PC_PARTS_FOR_PARTS_CATALOG and
    fallbackValue and fallbackValue > 0
  if sparsePartsCatalog then
    catalogValue = fallbackValue
    catalogSource = "configFallbackSparseParts"
    local logKey = cacheKey .. "|sparsePartsCatalogFallback"
    if not pcPartsCatalogBadLogOnce[logKey] then
      pcPartsCatalogBadLogOnce[logKey] = true
      log("W", "valueCalculator", string.format(
        "Using config Value fallback for %s because the PC provided only %d valued parts (parts-derived %.0f, config %.0f)",
        cacheKey, partsStats.count, rawPartsCatalogValue, fallbackValue))
    end
  elseif partsStats.total > 0 then
    catalogValue = rawPartsCatalogValue
    catalogSource = "parts"
    if mixerUpfit and fallbackValue and fallbackValue > 0 and catalogValue > fallbackValue * 1.10 then
      catalogValue = math.floor(fallbackValue * 1.10 + 0.5)
      catalogSource = "partsCappedVocationalOutlier"
      local logKey = cacheKey .. "|vocationalCatalogCap"
      if not pcPartsCatalogBadLogOnce[logKey] then
        pcPartsCatalogBadLogOnce[logKey] = true
        log("W", "valueCalculator", string.format(
          "Capped anomalous mixer catalog for %s from %.0f to %.0f (config reference %.0f)",
          cacheKey, rawPartsCatalogValue, catalogValue, fallbackValue))
      end
    end
  elseif fallbackValue and fallbackValue > 0 then
    catalogValue = fallbackValue
    catalogSource = "configFallback"
    local logKey = cacheKey .. "|catalogFallback"
    if not pcPartsCatalogBadLogOnce[logKey] then
      pcPartsCatalogBadLogOnce[logKey] = true
      log("W", "valueCalculator", string.format(
        "Using config Value fallback for %s because no valid parts-derived catalog was available", cacheKey))
    end
  else
    catalogValue = 0
    catalogSource = "missing"
  end

  local signals = {
    hpDistinct = 0,
    powerWeight = 0,
    performance = 0,
    catalogDistinct = 0,
    partDistinct = 0,
    rarity = 0,
    distinctiveness = 0
  }
  local peers = getFactoryPeerInfos(modelName, configInfo)
  if #peers >= 3 then
    local hpValues, powerWeightValues, catalogValues, highestPartValues, populationValues = {}, {}, {}, {}, {}
    for _, peer in ipairs(peers) do
      local hp = getConfigNumber(peer, "Power")
      local weight = getConfigNumber(peer, "Weight")
      local population = getConfigNumber(peer, "Population")
      local peerStats = getVehiclePcPartsCatalogStats(peer.model_key, peer.key, "haloPeer")
      if hp and hp > 0 then table.insert(hpValues, hp) end
      if hp and hp > 0 and weight and weight > 0 then table.insert(powerWeightValues, hp / weight) end
      if peerStats.total > 0 then
        table.insert(catalogValues, getVehiclePartsCatalogValue(peerStats.total))
        if peerStats.highest > 0 then table.insert(highestPartValues, peerStats.highest) end
      end
      if population and population > 0 then table.insert(populationValues, population) end
    end

    local hp = getConfigNumber(configInfo, "Power")
    local weight = getConfigNumber(configInfo, "Weight")
    local population = getConfigNumber(configInfo, "Population")
    local medianHp = #hpValues >= 3 and median(hpValues) or nil
    local medianPowerWeight = #powerWeightValues >= 3 and median(powerWeightValues) or nil
    local medianCatalog = #catalogValues >= 3 and median(catalogValues) or nil
    local medianHighestPart = #highestPartValues >= 3 and median(highestPartValues) or nil
    local medianPopulation = #populationValues >= 3 and median(populationValues) or nil

    if hp and hp > 0 and medianHp and medianHp > 0 then
      signals.hpDistinct = clamp(((hp / medianHp) - 1) / 0.60, 0, 1)
    end
    if hp and hp > 0 and weight and weight > 0 and medianPowerWeight and medianPowerWeight > 0 then
      signals.powerWeight = clamp((((hp / weight) / medianPowerWeight) - 1) / 0.50, 0, 1)
    end
    signals.performance = 0.30 * signals.hpDistinct + 0.70 * signals.powerWeight
    if partsStats.total > 0 and medianCatalog and medianCatalog > 0 then
      signals.catalogDistinct = clamp(((catalogValue / medianCatalog) - 1) / 0.75, 0, 1)
    end
    if partsStats.highest > 0 and medianHighestPart and medianHighestPart > 0 then
      signals.partDistinct = clamp(((partsStats.highest / medianHighestPart) - 1) / 1.50, 0, 1)
    end
    if population and population > 0 and medianPopulation and medianPopulation > 0 then
      signals.rarity = clamp(1 - population / medianPopulation, 0, 1)
    end
    signals.distinctiveness =
      0.50 * signals.catalogDistinct +
      0.25 * signals.partDistinct +
      0.25 * signals.rarity
  end

  local haloScore = clamp(
    0.25 * signals.performance +
    0.55 * signals.distinctiveness +
    0.20 * math.sqrt(signals.performance * signals.distinctiveness),
    0, 1)
  local haloOverride = haloOverrides[cacheKey]
  if haloOverride then
    if haloOverride.score ~= nil then haloScore = clamp(tonumber(haloOverride.score) or haloScore, 0, 1) end
    if haloOverride.add ~= nil then haloScore = clamp(haloScore + (tonumber(haloOverride.add) or 0), 0, 1) end
  end

  local commercialDurable =
    string.lower(tostring(fuelType or "")) == "diesel" and
    weight ~= nil and weight >= 4500 and
    not vocationalUpfit
  local dieselFuel = string.lower(tostring(fuelType or "")) == "diesel"
  local truckBody =
    string.find(bodyStyleLower, "truck", 1, true) ~= nil or
    string.find(bodyStyleLower, "pickup", 1, true) ~= nil or
    string.find(bodyStyleLower, "tractor", 1, true) ~= nil
  local dieselTruck =
    dieselFuel and not vocationalUpfit and
    (commercialDurable or truckBody or (weight ~= nil and weight >= 2500))
  local highPerformanceScore = getHighPerformanceScore(hp, weight, configType)
  local classicCustomScore = 0

  -- Preservation is primarily age/rarity driven. Horsepower is represented by
  -- the parts catalog and only contributes mildly through a factory halo score.
  local preservationTargetFactor = 0.62 + 0.18 * haloScore
  local isFwd = string.lower(tostring(drivetrain or "")) == "fwd"
  if isFwd then
    preservationTargetFactor = preservationTargetFactor * 0.68
  end
  preservationTargetFactor = clamp(preservationTargetFactor, 0.45, 0.80)

  local commercialRetentionFloor = COMMERCIAL_AGE_RETENTION_FLOOR
  if commercialDurable and weight then
    commercialRetentionFloor = commercialRetentionFloor +
      0.12 * clamp((weight - 6000) / 1800, 0, 1)
  end

  local profile = {
    partsRetailValue = partsStats.total,
    highestPartValue = partsStats.highest,
    installedPartCount = partsStats.count,
    catalogValue = catalogValue,
    catalogSource = catalogSource,
    rawPartsCatalogValue = rawPartsCatalogValue,
    haloScore = haloScore,
    haloSignals = signals,
    cohortSize = #peers,
    configType = configType,
    classicCustomScore = classicCustomScore,
    preservationTargetFactor = preservationTargetFactor,
    fuelType = fuelType,
    bodyStyle = bodyStyle,
    drivetrain = drivetrain,
    transmission = transmission,
    power = hp,
    weight = weight,
    highPerformanceScore = highPerformanceScore,
    commercialDurable = commercialDurable,
    dieselTruck = dieselTruck,
    commercialRetentionFloor = commercialRetentionFloor,
    vocationalUpfit = vocationalUpfit,
    mixerUpfit = mixerUpfit
  }
  vehicleCatalogProfileCache[cacheKey] = profile
  return profile
end

local function getVehicleValuation(opts)
  if type(opts) ~= "table" then return nil end
  local profile
  if opts.modelName and opts.configKey then
    profile = getVehicleCatalogProfile(opts.modelName, opts.configKey, opts.configInfo)
  end
  local catalogValue = profile and tonumber(profile.catalogValue) or 0
  if catalogValue <= 0 then catalogValue = tonumber(opts.catalogBaseValue) or 0 end
  if catalogValue <= 0 then return nil end

  local age = math.max(0, tonumber(opts.age) or 0)
  local mileageMeters = math.max(0, tonumber(opts.mileageMeters) or tonumber(opts.mileage) or 0)
  local haloScore = clamp(tonumber(opts.haloScore) or (profile and profile.haloScore) or 0, 0, 1)
  local baseAgeFactor, ordinaryAgeFactor, collectorFloor = getAgeRetention(age, haloScore)
  local commodityMultiplier, commodityActivation = getCommodityDepreciationMultiplier(
    age, haloScore, profile and profile.configType == "Factory")
  baseAgeFactor = baseAgeFactor * commodityMultiplier
  local preservationFloor, preservationActivation, lowMileagePreservationStrength =
    getLowMileagePreservationFloor(
      age, mileageMeters, baseAgeFactor, haloScore, profile and profile.preservationTargetFactor)
  local customClassicScore = nil
  local classicFloor, classicActivation, preservationRatio, preservationStrength =
    getClassicAgeFloor(age, mileageMeters, baseAgeFactor, customClassicScore)
  local antiqueFloor, antiqueActivation = getAntiqueAgeFloor(age, baseAgeFactor)
  local commercialDurable = opts.commercialDurable
  if commercialDurable == nil then commercialDurable = profile and profile.commercialDurable or false end
  local commercialAgeFloor, commercialActivation =
    getCommercialAgeFloor(
      age, baseAgeFactor, commercialDurable, profile and profile.commercialRetentionFloor)
  local dieselTruck = opts.dieselTruck
  if dieselTruck == nil then dieselTruck = profile and profile.dieselTruck or false end
  local dieselTruckAgeFloor, dieselTruckAgeActivation =
    getDieselTruckAgeFloor(age, baseAgeFactor, dieselTruck)
  local highPerformanceScore = tonumber(opts.highPerformanceScore) or
    (profile and profile.highPerformanceScore) or 0
  local highPerformanceConfigType =
    opts.configType or (profile and profile.configType)
  local highPerformanceFloor, highPerformanceActivation =
    getHighPerformanceRetentionFloor(
      age, baseAgeFactor, highPerformanceScore, highPerformanceConfigType)
  local ageFactor = math.max(
    baseAgeFactor, preservationFloor, classicFloor, antiqueFloor,
    commercialAgeFloor, dieselTruckAgeFloor, highPerformanceFloor)
  local mileageFactor, absoluteMileageFactor, expectedMileageMiles, relativeMileageFactor,
    commercialMileageFactor = getVehicleMileageRetention(mileageMeters, age, commercialDurable)
  local transmission = opts.transmission or (profile and profile.transmission)
  local manualModifier, dieselTruckModifier, dieselTruckValueActivation =
    getPowertrainValueModifiers(age, transmission, dieselTruck)
  local modificationAdjustment = tonumber(opts.modificationAdjustment) or 0
  local damageAdjustment = math.max(0, tonumber(opts.damageAdjustment) or 0)
  local depreciatedValue =
    catalogValue * ageFactor * mileageFactor * manualModifier * dieselTruckModifier
  -- Reliable installed-parts data provides a universal part-out floor. This is
  -- a minimum, not a bonus, and deliberately ignores config type and power.
  local partsValueFloor = profile and profile.catalogSource == "parts" and
    catalogValue * PARTS_DERIVED_VALUE_FLOOR or 0
  local preDamageFloor = math.max(
    500, catalogValue * 0.05, partsValueFloor, tonumber(opts.minBookValue) or 0)
  local preDamageValue = math.max(preDamageFloor, depreciatedValue + modificationAdjustment)
  local bookValue = math.max(0, preDamageValue - damageAdjustment)
  if opts.applyVehicleBuyMarket then
    bookValue = bookValue * getVehicleBuyMarketMultiplier()
  end

  return {
    catalogValue = catalogValue,
    catalogSource = profile and profile.catalogSource or "providedFallback",
    partsRetailValue = profile and profile.partsRetailValue or tonumber(opts.partsCatalogSum) or 0,
    haloScore = haloScore,
    haloSignals = profile and profile.haloSignals or nil,
    cohortSize = profile and profile.cohortSize or 0,
    ordinaryAgeFactor = ordinaryAgeFactor,
    collectorFloor = collectorFloor,
    commodityMultiplier = commodityMultiplier,
    commodityActivation = commodityActivation,
    preservationFloor = preservationFloor,
    preservationActivation = preservationActivation,
    lowMileagePreservationStrength = lowMileagePreservationStrength,
    classicFloor = classicFloor,
    classicActivation = classicActivation,
    preservationRatio = preservationRatio,
    preservationStrength = preservationStrength,
    classicCustomScore = customClassicScore or 0,
    antiqueFloor = antiqueFloor,
    antiqueActivation = antiqueActivation,
    commercialDurable = commercialDurable,
    commercialAgeFloor = commercialAgeFloor,
    commercialActivation = commercialActivation,
    dieselTruck = dieselTruck,
    dieselTruckAgeFloor = dieselTruckAgeFloor,
    dieselTruckAgeActivation = dieselTruckAgeActivation,
    dieselTruckModifier = dieselTruckModifier,
    dieselTruckValueActivation = dieselTruckValueActivation,
    transmission = transmission,
    manualModifier = manualModifier,
    highPerformanceScore = highPerformanceScore,
    highPerformanceFloor = highPerformanceFloor,
    highPerformanceActivation = highPerformanceActivation,
    ageFactor = ageFactor,
    mileageFactor = mileageFactor,
    absoluteMileageFactor = absoluteMileageFactor,
    relativeMileageFactor = relativeMileageFactor,
    commercialMileageFactor = commercialMileageFactor,
    expectedMileageMiles = expectedMileageMiles,
    modificationAdjustment = modificationAdjustment,
    damageAdjustment = damageAdjustment,
    partsValueFloor = partsValueFloor,
    preDamageValue = preDamageValue,
    bookValue = bookValue
  }
end

local function getVehicleCatalogIntrinsicBookValue(opts)
  local valuation = getVehicleValuation(opts)
  if not valuation then return nil end
  return math.floor(valuation.bookValue + 0.5)
end

local function getPartMarketMultiplier()
  if career_modules_globalEconomy and career_modules_globalEconomy.getPartPriceMultiplier then
    return career_modules_globalEconomy.getPartPriceMultiplier()
  end
  return 1.0
end

local function getPartValue(part, sell)
  part = part or {}
  local mileage   = part.partCondition and part.partCondition.odometer or 0
  local baseValue = part.value or 0
  local value = getDepreciatedPartValue(baseValue, mileage)
  local partYear = tonumber(part.year)
  if partYear then
    local currentYear = tonumber(os.date("%Y")) or 2026
    local partAge = math.max(0, currentYear - partYear)
    local ageMarketFactor = 0.15 + 0.85 * getOrdinaryAgeRetention(partAge)
    value = value * ageMarketFactor
  end

  if part.primered then
    value = value * 0.95
  end

  if part.repairCount then
    value = value - value * (part.repairCount/(part.repairCount + 1)) * 0.2
  end

  local integrity = part.partCondition and part.partCondition.integrityValue
  if integrity == nil then integrity = part.integrityValue end
  if integrity ~= nil then
    value = value * (clamp(tonumber(integrity) or 0, 0, 1) ^ 1.5)
  end

  local tireState = part.rlsTireState or (part.tags and part.tags.rlsTireState)
  if type(tireState) == "table" and type(tireState.wheels) == "table" then
    local total, count = 0, 0
    for _, wheel in pairs(tireState.wheels) do
      if type(wheel) == "table" then
        count = count + 1
        if wheel.flat == true then
          total = total + 0
        else
          total = total + clamp(tonumber(wheel.remaining) or 1, 0, 1)
        end
      end
    end
    if count > 0 then
      value = value * math.max(0.05, total / count)
    end
  end

  value = value * getPartMarketMultiplier()

  if sell then
    value = value * USED_PART_SELLER_RECOVERY
    if isHardcoreMode() then
      value = value * 0.66
    end
  end

  return value
end

-- for now every damaged part needs to be replaced
local function getDamagedParts(vehInfo)
  local damagedParts = {
    partsToBeReplaced = {}
  }

  local function traversePartsTree(node)
    if not node.partPath then return end
    if not vehInfo.partConditions then return end

    local partCondition = vehInfo.partConditions[node.partPath]
    if partCondition and partCondition.integrityValue and partCondition.integrityValue == 0 then
      local part = career_modules_partInventory.getPart(vehInfo.id, node.path)
      table.insert(damagedParts.partsToBeReplaced, part)
    end

    if node.children then
      for childSlotName, childNode in pairs(node.children) do
        traversePartsTree(childNode)
      end
    end
  end

  if vehInfo.config.partsTree then
    traversePartsTree(vehInfo.config.partsTree)
  end

  return damagedParts
end

local function getRepairDetails(invVehInfo)
  local details = {
    price = 0,
    repairTime = 0,
    partsCountToBeReplaced = 0
  }

  local damagedParts = getDamagedParts(invVehInfo)
  for _, part in pairs(damagedParts.partsToBeReplaced) do
    local price = (part.value or 700) * getPartMarketMultiplier()
    if isHardcoreMode() then
      details.price = math.floor((details.price + price * 1.25) * 100) / 100
    else
      details.price = math.floor((details.price + price * 0.9) * 100) / 100
    end
    details.repairTime = details.repairTime + repairTimePerPart
    details.partsCountToBeReplaced = details.partsCountToBeReplaced + 1
  end

  return details
end

-- IMPORTANT the pc file of a config does not contain the correct list of parts in the vehicle. there might be old unused slots/parts there and there might be slots/parts missing that are in the vehicle
-- the empty strings in the pc file are important, because otherwise the game will use the default part

local function getTableSize(t)
  local count = 0
  if not t then return 0 end
  for _ in pairs(t) do
      count = count + 1
  end
  return count
end

local function getOriginalInstalledPartCount(originalParts)
  local count = 0
  for _, part in pairs(originalParts or {}) do
    if part and part.name and part.name ~= "" then
      count = count + 1
    end
  end
  return count
end

local function getVehicleConfigKey(vehicle)
  if not vehicle or not vehicle.config then return nil end
  local configPath = vehicle.config.partConfigFilename
  if configPath then
    local _, configKey = path.splitWithoutExt(configPath)
    return configKey
  end
  return vehicle.config.key
end

local function getVehicleValue(configBaseValue, vehicle, ignoreDamage)
  local mileage = vehicle.mileage or 0

  local partInventory = career_modules_partInventory.getInventory()

  local newParts = {}
  -- Loop through partInventory to find parts belonging to this vehicle
  for _, part in pairs(partInventory) do
    if part.location == vehicle.id then
      newParts[part.containingSlot] = part.name
    end
  end
  local originalParts = vehicle.originalParts
  local changedSlots = vehicle.changedSlots
  local addedParts, removedParts = getPartDifference(originalParts, newParts, changedSlots)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local vehicleAge = math.max(0, currentYear - (tonumber(vehicle.year) or currentYear))
  local configKey = getVehicleConfigKey(vehicle)
  local valuation = getVehicleValuation({
    modelName = vehicle.model,
    configKey = configKey,
    catalogBaseValue = configBaseValue,
    mileageMeters = mileage,
    age = vehicleAge
  })
  local adjustedBaseValue = valuation and valuation.bookValue
    or getAdjustedVehicleBaseValue(configBaseValue, {mileage = mileage, age = vehicleAge})
  local ageFactor = valuation and valuation.ageFactor or getAgeRetention(vehicleAge, 0)
  local mileageFactor = valuation and valuation.mileageFactor or getMileageRetention(mileage)
  local modificationAdjustment = 0
  local installedPartSaleValue = 0

  for _, part in pairs(partInventory) do
    if part.location == vehicle.id then
      installedPartSaleValue = installedPartSaleValue + getPartValue(part, true)
    end
  end

  if addedParts then
    for slot, partName in pairs(addedParts) do
      local part = career_modules_partInventory.getPart(vehicle.id, slot)
      if part then
        modificationAdjustment = modificationAdjustment + ADDED_PART_VALUE_FACTOR * getPartValue(part)
      end
    end
  end

  if removedParts then
    for slot, partName in pairs(removedParts) do
      local originalValue = tonumber(vehicle.originalParts[slot] and vehicle.originalParts[slot].value) or 0
      modificationAdjustment = modificationAdjustment -
        originalValue * ASSEMBLED_VEHICLE_FACTOR * ageFactor * mileageFactor
    end
  end
  adjustedBaseValue = adjustedBaseValue + modificationAdjustment

  local repairDetails = getRepairDetails(vehicle)
  if ignoreDamage then
    repairDetails.price = 0
  end

  local value
  if originalParts and (getOriginalInstalledPartCount(originalParts) / 2) < getTableSize(removedParts) then
    value = installedPartSaleValue
  else
    value = adjustedBaseValue - repairDetails.price
  end
  return math.max(value, 0)
end

local function getInventoryVehicleValue(inventoryId, ignoreDamage)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not vehicle then return end
  local value = math.max(getVehicleValue(vehicle.configBaseValue, vehicle, ignoreDamage), 0)
  local meetReputation = career_modules_inventory.getMeetReputation(inventoryId)
  local accidents = career_modules_inventory.getAccidents(inventoryId) or 0
  local accidentMultiplier = isHardcoreMode() and 0.9 or 0.95
  local desirabilityMultiplier = (1 + (tonumber(meetReputation) or 0) * 0.01) * (accidentMultiplier ^ accidents)
  return value * clamp(desirabilityMultiplier, 0.85, 1.15)
end

local function getInventoryVehicleSellValue(inventoryId, options)
  local value = getInventoryVehicleValue(inventoryId, options and options.ignoreDamage)
  if not value then return end
  return value * getVehicleSellMarketMultiplier()
end

local function getNumberOfBrokenParts(partConditions)
  if not partConditions then return 0 end
  local counter = 0
  for partPath, info in pairs(partConditions) do
    if info.integrityValue and info.integrityValue == 0 then
      counter = counter + 1
    end
  end
  return counter
end

local function isPartException(partPath)
  for _, exception in ipairs(repairExceptions) do
    if string.find(partPath, exception) then
      return true
    end
  end
end

local function partConditionsNeedRepair(partConditions)
  -- Stock rule: only fully broken parts (integrityValue == 0) count, and the
  -- vehicle needs repair once brokenPartsThreshold (3) is reached.
  -- Do NOT treat ordinary wear (integrity/visual < 1) or integrityState noise
  -- as "needs repair" — that falsely flags mint cars / loaners with $0 cost.
  return getNumberOfBrokenParts(partConditions) >= brokenPartsThreshold
end

local function getBrokenPartsThreshold()
  return brokenPartsThreshold
end

local function getSpawnedVehicleRepairPrice(vehId, partConditions)
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not partConditions then return 0 end

  local price = 0
  local function walkTree(node)
    if not node.partPath then return end
    local pc = partConditions[node.partPath]
    if pc and pc.integrityValue and pc.integrityValue == 0 then
      local partValue = 700
      local activePartIdx = vehicleData.vdata.activeParts[node.partPath]
      if activePartIdx and vehicleData.vdata.activePartsData[activePartIdx] then
        partValue = vehicleData.vdata.activePartsData[activePartIdx].information.value or 700
      end
      local partPrice = partValue * getPartMarketMultiplier()
      if isHardcoreMode() then
        price = math.floor((price + partPrice * 1.25) * 100) / 100
      else
        price = math.floor((price + partPrice * 0.9) * 100) / 100
      end
    end
    if node.children then
      for _, child in pairs(node.children) do
        walkTree(child)
      end
    end
  end

  if vehicleData.config and vehicleData.config.partsTree then
    walkTree(vehicleData.config.partsTree)
  end
  return price
end

M.getPartDifference = getPartDifference

M.getInventoryVehicleValue = getInventoryVehicleValue
M.getPartValue = getPartValue
M.getDepreciatedPartValue = getDepreciatedPartValue
M.getAdjustedVehicleBaseValue = getAdjustedVehicleBaseValue
-- Age + mileage valuation for a vehicle record that is not loaded (profile
-- screen). Keeps the age datum next to the curve that uses it.
M.getQuickVehicleValue = function(baseValue, year, mileageMeters)
  return getAdjustedVehicleBaseValue(tonumber(baseValue) or 0, {
    mileage = tonumber(mileageMeters) or 0,
    age = math.max(0, 2023 - (tonumber(year) or 2023)),
  })
end
M.getVehicleMileageById = getVehicleMileageById
M.getInventoryVehicleSellValue = getInventoryVehicleSellValue
M.getBrokenPartsThreshold = getBrokenPartsThreshold
M.getVehiclePcPartsCatalogSum = getVehiclePcPartsCatalogSum
M.getVehiclePartsCatalogValue = getVehiclePartsCatalogValue
M.clearVehiclePcPartsCatalogSumCache = clearVehiclePcPartsCatalogSumCache
M.getVehicleCatalogProfile = getVehicleCatalogProfile
M.getVehicleValuation = getVehicleValuation
M.getVehicleCatalogIntrinsicBookValue = getVehicleCatalogIntrinsicBookValue
M.getOrdinaryAgeRetention = getOrdinaryAgeRetention
M.getMileageRetention = getMileageRetention
M.getVehicleMileageRetention = getVehicleMileageRetention
M.getLowMileagePreservationFloor = getLowMileagePreservationFloor
M.getCommercialAgeFloor = getCommercialAgeFloor
M.getDieselTruckAgeFloor = getDieselTruckAgeFloor
M.getPowertrainValueModifiers = getPowertrainValueModifiers
M.getHighPerformanceScore = getHighPerformanceScore
M.getHighPerformanceRetentionFloor = getHighPerformanceRetentionFloor
M.getCommodityDepreciationMultiplier = getCommodityDepreciationMultiplier
M.getAntiqueAgeFloor = getAntiqueAgeFloor
M.getClassicActivation = getClassicActivation
M.getClassicAgeFloor = getClassicAgeFloor
M.getAgeRetention = getAgeRetention
M.getVehicleListingPriceRange = getVehicleListingPriceRange
M.getVehicleBuyMarketMultiplier = getVehicleBuyMarketMultiplier
M.getVehicleSellMarketMultiplier = getVehicleSellMarketMultiplier
M.applyVehicleBuyMarketToMoney = applyVehicleBuyMarketToMoney

M.getRepairDetails = getRepairDetails
M.getNumberOfBrokenParts = getNumberOfBrokenParts
M.partConditionsNeedRepair = partConditionsNeedRepair
M.getSpawnedVehicleRepairPrice = getSpawnedVehicleRepairPrice
return M
