local M = {}

local categoryOrder = {"engine", "radiator", "transmission"}
local max = math.max
local min = math.min
local metersToMiles = 1 / 1609.344
local milesToMeters = 1609.344
local initialWearSeedStartMiles = 50000
local initialWearSeedFullRangeMiles = 250000
local initialWearSeedMinimumValue = 0.70
local normalizeSnapshot

local classDefaultCapacities = {
  passenger = {oil = 4, coolant = 5, transmission = 6},
  lightTruck = {oil = 6, coolant = 8, transmission = 9},
  mediumTruck = {oil = 10, coolant = 15, transmission = 14},
  heavyTruck = {oil = 18, coolant = 25, transmission = 20},
}

local categoryDefinitions = {
  engine = {
    label = "Engine",
    keywords = {"engine", "longblock", "cylinderhead", "headgasket", "block", "oilpan", "turbo", "supercharger", "intake", "exhaust"},
    installedKeywords = {"longblock", "cylinderhead", "headgasket", "block"},
    installedSlotSuffixes = {"engine"},
    installedExcludeKeywords = {"subframe", "mount"},
    items = {
      {
        name = "oilLevel",
        label = "Oil Level",
        actionLabel = "Fill",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 60,
        servicePricePct = 0.5,
        servicePriceFloor = 10,
      },
      {
        name = "oilCondition",
        label = "Oil Quality",
        actionLabel = "Replace",
        fillsItem = "oilLevel",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 180,
        servicePricePct = 2.0,
        servicePriceFloor = 50,
      },
      {
        name = "ignitionService",
        label = "Ignition/Injectors",
        actionLabel = "Replace",
        checkDurationSeconds = 300,
        serviceDurationSeconds = 600,
        servicePricePct = 10.0,
        servicePriceFloor = 200,
      },
    },
  },
  radiator = {
    label = "Cooling",
    keywords = {"radiator", "cooler", "coolant", "hose", "fan", "shroud"},
    installedKeywords = {"radiator"},
    installedExcludeKeywords = {"fan", "hose", "shroud", "intercooler", "oilcooler"},
    items = {
      {
        name = "coolantLevel",
        label = "Coolant Level",
        actionLabel = "Fill",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 60,
        servicePricePct = 10.0,
        servicePriceFloor = 10,
      },
      {
        name = "coolantIntegrity",
        label = "Coolant Quality",
        actionLabel = "Replace",
        fillsItem = "coolantLevel",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 180,
        servicePricePct = 40.0,
        servicePriceFloor = 30,
      },
    },
  },
  transmission = {
    label = "Transmission",
    keywords = {"gearbox", "transmission", "transaxle", "clutch", "torqueconverter", "torque_converter", "dct", "rangebox", "cvt", "manual"},
    installedKeywords = {"gearbox", "transmission", "transaxle", "dct", "cvt", "rangebox"},
    installedExcludeKeywords = {"mount", "shifter", "linkage", "tunnel"},
    items = {
      {
        name = "fluidLevel",
        label = "Transmission Fluid Level",
        actionLabel = "Fill",
        checkDurationSeconds = 180,
        serviceDurationSeconds = 120,
        servicePricePct = 2.0,
        servicePriceFloor = 20,
      },
      {
        name = "fluidCondition",
        label = "Transmission Fluid Quality",
        actionLabel = "Replace",
        fillsItem = "fluidLevel",
        checkDurationSeconds = 180,
        serviceDurationSeconds = 300,
        servicePricePct = 10.0,
        servicePriceFloor = 75,
      },
    },
  },
}

local function deepCopy(value)
  if type(deepcopy) == "function" then
    return deepcopy(value)
  end
  if type(value) ~= "table" then
    return value
  end

  local result = {}
  for key, nestedValue in pairs(value) do
    result[key] = deepCopy(nestedValue)
  end
  return result
end

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function linearScale(value, valueA, valueB, scaleA, scaleB)
  if valueA == valueB then
    return scaleB
  end
  local t = clamp((value - valueA) / (valueB - valueA), 0, 1)
  return scaleA + ((scaleB - scaleA) * t)
end

local function getWearBandName(avgMiles)
  avgMiles = max(tonumber(avgMiles) or 0, 0)
  if avgMiles <= 100000 then
    return "fresh"
  elseif avgMiles <= 200000 then
    return "aged"
  end
  return "worn"
end

local function normalizeClassName(value)
  local text = string.lower(tostring(value or "")):gsub("[^%w]", "")
  local aliases = {
    passenger = "passenger", car = "passenger", commuter = "passenger",
    lighttruck = "lightTruck", pickup = "lightTruck", suv = "lightTruck",
    mediumtruck = "mediumTruck", boxtruck = "mediumTruck",
    heavytruck = "heavyTruck", semi = "heavyTruck", semitruck = "heavyTruck", tractor = "heavyTruck",
  }
  return aliases[text]
end

local function flattenMetadata(value, result)
  result = result or {}
  if type(value) == "table" then
    for key, nested in pairs(value) do
      if type(key) == "string" then
        table.insert(result, string.lower(key))
      end
      flattenMetadata(nested, result)
    end
  elseif value ~= nil then
    table.insert(result, string.lower(tostring(value)))
  end
  return table.concat(result, " ")
end

local function classifyVehicleProfile(vehicleData, existingProfile)
  vehicleData = type(vehicleData) == "table" and vehicleData or {}
  existingProfile = type(existingProfile) == "table" and existingProfile or {}
  local information = vehicleData.vdata and vehicleData.vdata.information or {}
  local explicitClass = normalizeClassName(vehicleData.maintenanceClass or information.maintenanceClass or
                                             information["Maintenance Class"])
  local bodyText = flattenMetadata({information["Body Style"], information.BodyStyle, information.Type,
                                     vehicleData.bodyStyle, vehicleData.vehicleType})
  local modelText = string.lower(tostring(vehicleData.model or existingProfile.modelFamily or ""))
  local existingCurbWeightKg = tonumber(existingProfile.curbWeightKg) or 0
  local curbWeightKg = existingCurbWeightKg > 0 and existingCurbWeightKg or
                         tonumber(vehicleData.certifications and vehicleData.certifications.weight) or tonumber(vehicleData.weight) or 0
  local className = explicitClass
  local classSource = explicitClass and "maintenanceClass" or nil

  if not className and (existingProfile.classSource == "maintenanceClass" or existingProfile.classSource == "bodyStyle") then
    className = normalizeClassName(existingProfile.class)
    classSource = existingProfile.classSource
  end

  if not className and bodyText ~= "" then
    if bodyText:find("semi", 1, true) or bodyText:find("tractor", 1, true) or bodyText:find("bus", 1, true) then
      className, classSource = "heavyTruck", "bodyStyle"
    elseif bodyText:find("medium truck", 1, true) or bodyText:find("box truck", 1, true) then
      className, classSource = "mediumTruck", "bodyStyle"
    elseif bodyText:find("pickup", 1, true) or bodyText:find("suv", 1, true) or bodyText:find("van", 1, true) or
        bodyText:find("off-road", 1, true) then
      className, classSource = "lightTruck", "bodyStyle"
    end
  end
  if not className then
    if modelText:find("tseries", 1, true) or modelText:find("semi", 1, true) then
      className, classSource = "heavyTruck", "modelFamily"
    elseif modelText:find("mdseries", 1, true) then
      className, classSource = "mediumTruck", "modelFamily"
    elseif modelText:find("pickup", 1, true) or modelText:find("dseries", 1, true) or
        modelText:find("roamer", 1, true) or modelText:find("hopper", 1, true) or modelText:find("van", 1, true) then
      className, classSource = "lightTruck", "modelFamily"
    end
  end
  if not className and curbWeightKg > 0 then
    if curbWeightKg >= 8000 then
      className = "heavyTruck"
    elseif curbWeightKg >= 3500 then
      className = "mediumTruck"
    elseif curbWeightKg >= 2300 then
      className = "lightTruck"
    else
      className = "passenger"
    end
    classSource = "curbWeight"
  end
  className = className or normalizeClassName(existingProfile.class) or "passenger"
  classSource = classSource or existingProfile.classSource or "default"

  local capacities = deepCopy(classDefaultCapacities[className])
  if existingProfile.class == className and type(existingProfile.capacities) == "table" then
    for kind, defaultValue in pairs(capacities) do
      local value = tonumber(existingProfile.capacities[kind])
      capacities[kind] = value and value > 0 and value or defaultValue
    end
  end
  local explicitCapacities = vehicleData.maintenanceCapacities or information.maintenanceCapacities
  if type(explicitCapacities) == "table" then
    for kind, defaultValue in pairs(capacities) do
      local value = tonumber(explicitCapacities[kind])
      capacities[kind] = value and value > 0 and value or defaultValue
    end
  end

  local fuelText = flattenMetadata({information["Fuel Type"], information.fuelType, vehicleData.fuelType,
                                    existingProfile.fuelType})
  local isDiesel = fuelText:find("diesel", 1, true) ~= nil or existingProfile.isDiesel == true
  local existingPowerHp = tonumber(existingProfile.powerHp) or 0
  local existingTorqueNm = tonumber(existingProfile.torqueNm) or 0
  local powerHp = existingPowerHp > 0 and existingPowerHp or tonumber(vehicleData.certifications and vehicleData.certifications.power) or 0
  local torqueNm = existingTorqueNm > 0 and existingTorqueNm or tonumber(vehicleData.certifications and vehicleData.certifications.torque) or 0
  return {
    class = className,
    classSource = classSource,
    capacities = capacities,
    fuelType = isDiesel and "diesel" or "gasoline",
    isDiesel = isDiesel,
    curbWeightKg = max(curbWeightKg, 0),
    engineMassKg = max(tonumber(existingProfile.engineMassKg) or 0, 0),
    powerHp = max(powerHp, 0),
    torqueNm = max(torqueNm, 0),
    modelFamily = vehicleData.model or existingProfile.modelFamily,
  }
end

local function convertMileageToMeters(mileage, unit)
  mileage = max(tonumber(mileage) or 0, 0)
  if unit == "miles" then
    return mileage * milesToMeters
  end
  return mileage
end

local function buildDefaultSnapshot(vehicleData)
  local categories = {}
  for _, categoryName in ipairs(categoryOrder) do
    local maintenance = {}
    for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
      maintenance[itemDefinition.name] = 1
    end

    categories[categoryName] = {
      avgOdometer = 0,
      wearBand = "fresh",
      lastFailureTime = 0,
      lastFailureType = nil,
      persistentCareerDamage = false,
      persistentDamageReason = nil,
      rootPartId = nil,
      cachedPartIds = {},
      maintenance = maintenance,
    }
  end

  return {
    version = 3,
    lastSyncMileage = 0,
    lastHardFailureTime = 0,
    profile = classifyVehicleProfile(vehicleData),
    categories = categories,
  }
end

local function buildInitialSnapshotForMileage(mileage, unit, vehicleData)
  local mileageMeters = convertMileageToMeters(mileage, unit)
  local avgMiles = mileageMeters * metersToMiles
  local snapshot = buildDefaultSnapshot(vehicleData)
  local seededMinimum = 1

  if avgMiles > initialWearSeedStartMiles then
    seededMinimum = linearScale(
      avgMiles,
      initialWearSeedStartMiles,
      initialWearSeedFullRangeMiles,
      1,
      initialWearSeedMinimumValue
    )
  end

  snapshot.lastSyncMileage = mileageMeters

  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = snapshot.categories[categoryName]
    categoryState.avgOdometer = mileageMeters
    categoryState.wearBand = getWearBandName(avgMiles)

    for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
      if avgMiles <= initialWearSeedStartMiles then
        categoryState.maintenance[itemDefinition.name] = 1
      else
        categoryState.maintenance[itemDefinition.name] = clamp(
          seededMinimum + (math.random() * (1 - seededMinimum)),
          seededMinimum,
          1
        )
      end
    end
  end

  return normalizeSnapshot(snapshot, vehicleData)
end

normalizeSnapshot = function(snapshot, vehicleData)
  local normalized = deepCopy(snapshot)
  if type(normalized) ~= "table" then
    normalized = buildDefaultSnapshot(vehicleData)
  end

  normalized.version = 3
  normalized.lastSyncMileage = tonumber(normalized.lastSyncMileage) or 0
  normalized.lastHardFailureTime = tonumber(normalized.lastHardFailureTime) or 0
  normalized.categories = type(normalized.categories) == "table" and normalized.categories or {}

  normalized.profile = classifyVehicleProfile(vehicleData, normalized.profile)

  local defaultSnapshot = buildDefaultSnapshot(vehicleData)
  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = type(normalized.categories[categoryName]) == "table" and normalized.categories[categoryName] or {}
    local defaultCategoryState = defaultSnapshot.categories[categoryName]
    categoryState.avgOdometer = tonumber(categoryState.avgOdometer) or defaultCategoryState.avgOdometer
    categoryState.wearBand = categoryState.wearBand or defaultCategoryState.wearBand
    categoryState.lastFailureTime = tonumber(categoryState.lastFailureTime) or defaultCategoryState.lastFailureTime
    categoryState.lastFailureType = categoryState.lastFailureType
    categoryState.persistentCareerDamage = categoryState.persistentCareerDamage == true
    categoryState.persistentDamageReason = categoryState.persistentDamageReason
    categoryState.rootPartId = categoryState.rootPartId
    categoryState.cachedPartIds = type(categoryState.cachedPartIds) == "table" and categoryState.cachedPartIds or {}
    categoryState.maintenance = type(categoryState.maintenance) == "table" and categoryState.maintenance or {}

    for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
      local itemValue = tonumber(categoryState.maintenance[itemDefinition.name])
      if itemValue == nil then
        categoryState.maintenance[itemDefinition.name] = 1
      elseif itemValue < 0 then
        categoryState.maintenance[itemDefinition.name] = 0
      elseif itemValue > 1 then
        categoryState.maintenance[itemDefinition.name] = 1
      else
        categoryState.maintenance[itemDefinition.name] = itemValue
      end
    end

    normalized.categories[categoryName] = categoryState
  end

  return normalized
end

local function getItemDefinition(categoryName, itemName)
  local categoryDefinition = categoryDefinitions[categoryName]
  if not categoryDefinition then
    return nil
  end

  for _, itemDefinition in ipairs(categoryDefinition.items) do
    if itemDefinition.name == itemName then
      return itemDefinition
    end
  end

  return nil
end

M.categoryOrder = categoryOrder
M.categoryDefinitions = categoryDefinitions
M.buildDefaultSnapshot = buildDefaultSnapshot
M.buildInitialSnapshotForMileage = buildInitialSnapshotForMileage
M.normalizeSnapshot = normalizeSnapshot
M.getItemDefinition = getItemDefinition
M.classifyVehicleProfile = classifyVehicleProfile

return M
