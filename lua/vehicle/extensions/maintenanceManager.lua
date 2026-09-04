local M = {}

local common = require('vehicle/extensions/maintenance/common')
local engineCategory = require('vehicle/extensions/maintenance/engine')
local radiatorCategory = require('vehicle/extensions/maintenance/radiator')
local transmissionCategory = require('vehicle/extensions/maintenance/transmission')

local abs = math.abs
local floor = math.floor
local max = math.max
local min = math.min

local categoryModules = {
  engine = engineCategory,
  radiator = radiatorCategory,
  transmission = transmissionCategory
}

local keywordSets = {
  engine = {"engine", "longblock", "cylinderhead", "headgasket", "block", "oilpan", "turbo", "supercharger", "intake", "exhaust"},
  radiator = {"radiator", "cooler", "coolant", "hose", "fan", "shroud"},
  transmission = {"gearbox", "transmission", "clutch", "torqueconverter", "torque_converter", "dct", "rangebox", "cvt", "manual"}
}

local rootKeywordSets = {
  engine = {"engine", "longblock", "block", "cylinderhead", "headgasket"},
  radiator = {"radiator", "coolant", "hose"},
  transmission = {"gearbox", "transmission", "clutch", "torqueconverter", "dct", "cvt"}
}

local categoryOrder = {"engine", "radiator", "transmission"}
local categoryLabels = {
  engine = "Engine",
  radiator = "Cooling",
  transmission = "Transmission"
}
local maintenanceLabels = {
  oilCondition = "Oil quality",
  oilLevel = "Oil level",
  ignitionService = "Ignition service",
  coolantLevel = "Coolant level",
  coolantIntegrity = "Coolant integrity",
  fluidCondition = "Fluid quality",
  fluidLevel = "Fluid level"
}
local symptomLabels = {
  roughRunning = "Mechanical roughness",
  ticking = "Mechanical roughness",
  roughIdle = "Rough idle",
  torqueDip = "Torque dip",
  powerFade = "Power fade",
  stall = "Stall",
  coolantSeep = "Coolant seep",
  fanOverwork = "Fan overwork",
  roughShift = "Rough shift",
  shiftDelay = "Shift delay",
  slip = "Slip"
}
local categoryColors = {
  engine = "#f08b49",
  radiator = "#57b8d8",
  transmission = "#b8d75c"
}

local state = nil
local runtimeState = nil
local categoryCache = nil
local deviceContexts = nil
local activePartInfos = nil
local partTypeTags = nil
local inventoryId = nil
local updateTimer = 0
local syncTimer = 0
local dirtyState = false
local runtimeDisabled = true
local runtimeReadOnly = false
local trackedPartConditions = nil
local trackedPartConditionsSignature = nil
local lastAppliedPartConditionsSignature = nil
local debugStreamTimer = 0
local debugStreamInterval = 0.25
local debugStreamDirty = true
local debugStreamCache = nil
local debugStreamBuildCount = 0
local debugStreamSendCount = 0
local updateState
local getNumericValue
local buildEnvironmentSnapshot
local getScenarioPresetDefinition
local buildScenarioPresetList
local buildScenarioInputsFromLiveSnapshot
local normalizeScenarioInputs
local mergeScenarioInputs
local ensureScenarioInputs
local buildScenarioEnvironment
local buildPreviewCategoryState

local scenarioPresetDefinitions = {
  {
    id = "highMileageLowOil",
    label = "High-mileage low-oil car",
    description = "Older engine with neglected oil and moderate stress.",
    inputs = {
      avgMiles = 210000,
      loadFactor = 0.62,
      rpmFactor = 0.58,
      heatFactor = 0.45,
      powerHp = 320,
      torqueNm = 460,
      maintenance = {
        engine = {oilCondition = 0.42, oilLevel = 0.24, ignitionService = 0.55},
        radiator = {coolantLevel = 0.72, coolantIntegrity = 0.68},
        transmission = {fluidCondition = 0.74, fluidLevel = 0.84}
      }
    }
  },
  {
    id = "enduranceRace",
    label = "Endurance race car",
    description = "Healthy car under sustained but reasonable race stress.",
    inputs = {
      avgMiles = 18000,
      loadFactor = 0.74,
      rpmFactor = 0.76,
      heatFactor = 0.42,
      powerHp = 320,
      torqueNm = 410,
      maintenance = {
        engine = {oilCondition = 0.92, oilLevel = 0.9, ignitionService = 0.9},
        radiator = {coolantLevel = 0.95, coolantIntegrity = 0.94},
        transmission = {fluidCondition = 0.92, fluidLevel = 0.94}
      }
    }
  },
  {
    id = "overheatedCooling",
    label = "Overheated cooling system",
    description = "Cooling system on the edge with active thermal stress.",
    inputs = {
      avgMiles = 125000,
      loadFactor = 0.78,
      rpmFactor = 0.71,
      heatFactor = 0.92,
      powerHp = 360,
      torqueNm = 500,
      maintenance = {
        engine = {oilCondition = 0.72, oilLevel = 0.8, ignitionService = 0.76},
        radiator = {coolantLevel = 0.36, coolantIntegrity = 0.42},
        transmission = {fluidCondition = 0.86, fluidLevel = 0.88}
      }
    }
  },
  {
    id = "wornTowRig",
    label = "Worn towing transmission",
    description = "Load-heavy drivetrain with overdue transmission fluid service.",
    inputs = {
      avgMiles = 165000,
      loadFactor = 0.88,
      rpmFactor = 0.54,
      heatFactor = 0.36,
      powerHp = 420,
      torqueNm = 980,
      maintenance = {
        engine = {oilCondition = 0.76, oilLevel = 0.84, ignitionService = 0.78},
        radiator = {coolantLevel = 0.82, coolantIntegrity = 0.8},
        transmission = {fluidCondition = 0.38, fluidLevel = 0.52}
      }
    }
  },
  {
    id = "extremeDrag",
    label = "Extreme high-hp drag build",
    description = "Very high output engine where service life falls rapidly.",
    inputs = {
      avgMiles = 26000,
      loadFactor = 0.96,
      rpmFactor = 0.93,
      heatFactor = 0.62,
      powerHp = 2200,
      torqueNm = 2400,
      maintenance = {
        engine = {oilCondition = 0.74, oilLevel = 0.82, ignitionService = 0.68},
        radiator = {coolantLevel = 0.84, coolantIntegrity = 0.8},
        transmission = {fluidCondition = 0.66, fluidLevel = 0.72}
      }
    }
  }
}

local function buildDefaultCategoryState(categoryName)
  return {
    avgOdometer = 0,
    wearBand = "fresh",
    lastFailureTime = 0,
    lastFailureType = nil,
    persistentCareerDamage = false,
    persistentDamageReason = nil,
    rootPartId = nil,
    cachedPartIds = {},
    maintenance = categoryModules[categoryName].getDefaultMaintenance()
  }
end

local function buildDefaultProfile()
  return {
    class = 'passenger',
    classSource = 'default',
    capacities = common.getClassDefaultCapacities('passenger'),
    fuelType = 'gasoline',
    isDiesel = false,
    curbWeightKg = 0,
    engineMassKg = 0,
    powerHp = 0,
    torqueNm = 0,
    modelFamily = nil
  }
end

local function normalizeProfile(source)
  local profile = buildDefaultProfile()
  source = type(source) == 'table' and source or {}
  local validClasses = {passenger = true, lightTruck = true, mediumTruck = true, heavyTruck = true}
  profile.class = validClasses[source.class] and source.class or profile.class
  profile.classSource = source.classSource or profile.classSource
  profile.capacities = common.getClassDefaultCapacities(profile.class)
  if type(source.capacities) == 'table' then
    for _, kind in ipairs({'oil', 'coolant', 'transmission'}) do
      local value = tonumber(source.capacities[kind])
      if value and value > 0 then
        profile.capacities[kind] = value
      end
    end
  end
  profile.fuelType = string.lower(tostring(source.fuelType or profile.fuelType))
  profile.isDiesel = source.isDiesel == true or string.find(string.lower(profile.fuelType), 'diesel', 1, true) ~= nil
  if profile.isDiesel then
    profile.fuelType = 'diesel'
  end
  profile.curbWeightKg = max(tonumber(source.curbWeightKg) or 0, 0)
  profile.engineMassKg = max(tonumber(source.engineMassKg) or 0, 0)
  profile.powerHp = max(tonumber(source.powerHp) or 0, 0)
  profile.torqueNm = max(tonumber(source.torqueNm) or 0, 0)
  profile.modelFamily = source.modelFamily
  return profile
end

local function buildDefaultState()
  return {
    version = 3,
    lastSyncMileage = 0,
    lastHardFailureTime = 0,
    profile = buildDefaultProfile(),
    categories = {
      engine = buildDefaultCategoryState('engine'),
      radiator = buildDefaultCategoryState('radiator'),
      transmission = buildDefaultCategoryState('transmission')
    }
  }
end

local function resetRuntimeState()
  runtimeState = {
    engine = {},
    radiator = {},
    transmission = {},
    debug = {
      scenarioPresetId = nil,
      scenarioInputs = nil,
      scenarioUpdatedAt = 0
    },
    shared = {
      wasWarm = false,
      warmupEventCount = 0,
      cooldownEventCount = 0,
      totalHotRuntimeSeconds = 0,
      totalOverheatingRuntimeSeconds = 0,
      lastCoolantTemp = nil
    }
  }
end

local function markDebugStreamDirty()
  debugStreamDirty = true
end

local function markStateDirty()
  dirtyState = true
  syncTimer = 0
  markDebugStreamDirty()
end

local function getTrackedPartConditions()
  if type(trackedPartConditions) == "table" then
    return trackedPartConditions
  end
  return partCondition.getConditions() or {}
end

local function clearTrackedPartConditions()
  trackedPartConditions = nil
  trackedPartConditionsSignature = nil
  lastAppliedPartConditionsSignature = nil
end

local function setTrackedPartConditions(partConditions, signature)
  if type(partConditions) ~= "table" then
    clearTrackedPartConditions()
    return
  end

  trackedPartConditions = common.deepCopy(partConditions)
  trackedPartConditionsSignature = signature
end

local function normalizeState(snapshot)
  local normalized = buildDefaultState()
  if type(snapshot) ~= "table" then
    return normalized
  end

  normalized.version = 3
  normalized.lastSyncMileage = tonumber(snapshot.lastSyncMileage) or 0
  normalized.lastHardFailureTime = tonumber(snapshot.lastHardFailureTime) or 0
  normalized.profile = normalizeProfile(snapshot.profile)
  for categoryName, categoryState in pairs(normalized.categories) do
    local source = snapshot.categories and snapshot.categories[categoryName] or nil
    if type(source) == "table" then
      categoryState.avgOdometer = tonumber(source.avgOdometer) or 0
      categoryState.wearBand = source.wearBand or categoryState.wearBand
      categoryState.lastFailureTime = tonumber(source.lastFailureTime) or 0
      categoryState.lastFailureType = source.lastFailureType
      categoryState.persistentCareerDamage = source.persistentCareerDamage == true
      categoryState.persistentDamageReason = source.persistentDamageReason
      categoryState.rootPartId = source.rootPartId
      categoryState.cachedPartIds = type(source.cachedPartIds) == "table" and common.deepCopy(source.cachedPartIds) or {}
      categoryState.maintenance = categoryModules[categoryName].getDefaultMaintenance()
      if type(source.maintenance) == "table" then
        for itemName, itemValue in pairs(source.maintenance) do
          if categoryState.maintenance[itemName] ~= nil then
            categoryState.maintenance[itemName] = common.clamp(tonumber(itemValue) or categoryState.maintenance[itemName] or 1, 0, 1)
          end
        end
      end
    end
  end
  return normalized
end

local function splitTag(tag)
  local parts = {}
  if type(tag) ~= "string" then
    return parts
  end
  for piece in string.gmatch(tag, "[^:]+") do
    table.insert(parts, piece)
  end
  return parts
end

local function lookForPowertrainClues(partId, partData)
  local tags
  for key, value in pairs(partData or {}) do
    if type(value) == "table" then
      if key == "powertrain" then
        local previousPartPath
        for index = 2, #value do
          if value[index].partPath then
            previousPartPath = value[index].partPath
          elseif #value[index] > 1 then
            local deviceName = value[index][2]
            local taggedPartId = previousPartPath or partId
            tags = tags or {}
            tags[taggedPartId] = tags[taggedPartId] or {}
            table.insert(tags[taggedPartId], "powertrainDevice:" .. deviceName)
          end
        end
      else
        if value.radiatorArea and not value.inertia then
          tags = tags or {}
          tags[partId] = tags[partId] or {}
          table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "radiator"))
        elseif value.torqueModExhaust and not value.inertia then
          tags = tags or {}
          tags[partId] = tags[partId] or {}
          table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "exhaust"))
        elseif value.turbocharger and not value.inertia then
          tags = tags or {}
          tags[partId] = tags[partId] or {}
          table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "turbocharger"))
        end
      end
    end
  end
  return tags
end

local function preparePartMetadata()
  activePartInfos = {}
  partTypeTags = {}

  for partId, partTypeName in pairs(v.data.activeParts or {}) do
    local partInfo = activePartInfos[partId] or {}
    local slotPath = partId:match("^(.*[/])[^/]+$") or "/"
    partInfo.partId = partId
    partInfo.slotPath = slotPath
    partInfo.partName = partId:match("([^/]+)$") or partId
    activePartInfos[partId] = partInfo

    local activePartData = v.data.activePartsData and v.data.activePartsData[partTypeName] or nil
    local clueTags = lookForPowertrainClues(partId, activePartData)
    if clueTags then
      for taggedPartId, tags in pairs(clueTags) do
        partTypeTags[taggedPartId] = partTypeTags[taggedPartId] or {}
        for _, tag in ipairs(tags) do
          table.insert(partTypeTags[taggedPartId], tag)
        end
      end
    end
  end

  local function walkTree(node, path)
    if type(node) ~= "table" then
      return
    end

    path = path or "/"
    local chosenPartName = node.chosenPartName
    if chosenPartName and chosenPartName ~= "" then
      local partId = path .. chosenPartName
      activePartInfos[partId] = activePartInfos[partId] or {}
      activePartInfos[partId].partId = partId
      activePartInfos[partId].partName = chosenPartName
      activePartInfos[partId].slotPath = path
    end

    if node.children then
      for slotName, child in pairs(node.children) do
        walkTree(child, path .. slotName .. "/")
      end
    end
  end

  walkTree(v.config and v.config.partsTree or {}, "/")
end

local function ensureCategoryCache()
  categoryCache = {
    engine = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil},
    radiator = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil},
    transmission = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil}
  }
end

local function addPartToCategory(categoryName, partId, deviceName, subSystem)
  if not categoryCache[categoryName] or not partId then
    return
  end
  local cache = categoryCache[categoryName]
  if not cache.partIdSet[partId] then
    cache.partIdSet[partId] = true
    table.insert(cache.partIds, partId)
  end
  cache.partLinks[partId] = cache.partLinks[partId] or {}
  if deviceName then
    table.insert(cache.partLinks[partId], {deviceName = deviceName, subSystem = subSystem})
  end
end

local function matchesKeywordSet(partInfo, keywords)
  local haystacks = {
    string.lower(partInfo.partId or ""),
    string.lower(partInfo.partName or ""),
    string.lower(partInfo.slotPath or "")
  }
  for _, keyword in ipairs(keywords) do
    for _, haystack in ipairs(haystacks) do
      if string.find(haystack, keyword, 1, true) then
        return true
      end
    end
  end
  return false
end

local function classifyPart(partId, partInfo)
  local tags = partTypeTags[partId] or {}
  local foundExplicit = false

  for _, tag in ipairs(tags) do
    local pieces = splitTag(tag)
    if pieces[1] == "powertrainDevice" then
      local deviceName = pieces[2]
      local subSystem = pieces[3]
      local device = deviceName and powertrain.getDevice(deviceName) or nil
      if subSystem == "radiator" then
        addPartToCategory('radiator', partId, deviceName, subSystem)
        foundExplicit = true
      elseif device and device.deviceCategories and device.deviceCategories.engine then
        addPartToCategory('engine', partId, deviceName, subSystem)
        foundExplicit = true
      elseif device and device.deviceCategories and (device.deviceCategories.gearbox or device.deviceCategories.clutchlike or
                                                         device.deviceCategories.clutch) then
        addPartToCategory('transmission', partId, deviceName, subSystem)
        foundExplicit = true
      end
    end
  end

  if foundExplicit then
    return
  end

  if matchesKeywordSet(partInfo, keywordSets.radiator) then
    addPartToCategory('radiator', partId)
  elseif matchesKeywordSet(partInfo, keywordSets.transmission) then
    addPartToCategory('transmission', partId)
  elseif matchesKeywordSet(partInfo, keywordSets.engine) then
    addPartToCategory('engine', partId)
  end
end

local function chooseRootPart(categoryName)
  local cache = categoryCache[categoryName]
  if not cache then
    return
  end

  local bestScore = -1
  local bestPartId = nil
  local bestDeviceName = nil
  for _, partId in ipairs(cache.partIds) do
    local info = activePartInfos[partId] or {}
    local score = 0
    if matchesKeywordSet(info, rootKeywordSets[categoryName]) then
      score = score + 10
    end
    if matchesKeywordSet(info, keywordSets[categoryName]) then
      score = score + 2
    end
    local links = cache.partLinks[partId]
    if links and #links > 0 then
      score = score + 5
      for _, link in ipairs(links) do
        local device = powertrain.getDevice(link.deviceName)
        if categoryName == 'radiator' and link.subSystem == 'radiator' then
          score = score + 5
        elseif categoryName == 'engine' and device and device.deviceCategories and device.deviceCategories.engine then
          score = score + 4
        elseif categoryName == 'transmission' and device and device.deviceCategories and device.deviceCategories.gearbox then
          score = score + 4
        elseif categoryName == 'transmission' and device and device.deviceCategories and device.deviceCategories.clutch then
          score = score + 2
        end
      end
    end

    if score > bestScore then
      bestScore = score
      bestPartId = partId
      if links and links[1] then
        bestDeviceName = links[1].deviceName
      end
    end
  end

  cache.rootPartId = bestPartId or cache.partIds[1]
  cache.rootDeviceName = bestDeviceName
end

local function rebuildCategoryCache()
  preparePartMetadata()
  ensureCategoryCache()
  for partId, partInfo in pairs(activePartInfos or {}) do
    classifyPart(partId, partInfo)
  end
  for _, categoryName in ipairs(categoryOrder) do
    chooseRootPart(categoryName)
  end
end

local function buildDeviceEntry(device)
  local entry = {device = device, base = {}}
  entry.base.maxTorque = device.maxTorque or (device.torqueData and device.torqueData.maxTorque) or 0
  entry.base.maxPower = device.maxPower or (device.torqueData and device.torqueData.maxPower) or 0
  entry.base.maxAV = device.maxAV or 0
  entry.base.originalMaxTorqueLimit = device.maxTorqueLimit or math.huge
  entry.base.idleAVReadErrorRangeHalf = device.idleAVReadErrorRangeHalf or 0
  entry.base.idleAVReadErrorRange = device.idleAVReadErrorRange or 0
  entry.base.friction = device.friction
  entry.base.dynamicFriction = device.dynamicFriction
  entry.base.gearRatioChangeRate = device.gearRatioChangeRate
  entry.base.lockTorque = device.lockTorque
  entry.base.clutchFreePlay = device.clutchFreePlay
  entry.base.damageFrictionCoef = device.damageFrictionCoef
  entry.base.damageDynamicFrictionCoef = device.damageDynamicFrictionCoef
  entry.base.damageIdleAVReadErrorRangeCoef = device.damageIdleAVReadErrorRangeCoef
  entry.base.fastIgnitionErrorChance = device.fastIgnitionErrorChance
  entry.base.slowIgnitionErrorChance = device.slowIgnitionErrorChance
  entry.base.damageGearRatioChangeRateCoef = device.damageGearRatioChangeRateCoef
  entry.base.damageLockTorqueCoef = device.damageLockTorqueCoef
  entry.base.damageClutchFreePlayCoef = device.damageClutchFreePlayCoef
  entry.base.clutchPermanentlyDamaged = device.clutchPermanentlyDamaged
  entry.base.maxTorqueRating = tonumber(device.maxTorqueRating) or tonumber(device.torqueData and device.torqueData.maxTorqueRating) or 0
  entry.base.requiredEnergyType = device.requiredEnergyType or device.energyType
  entry.base.oilVolume = tonumber(device.oilVolume) or tonumber(device.thermals and device.thermals.oilVolume)

  local thermalData = device.thermals and device.thermals.debugData and device.thermals.debugData.engineThermalData or nil
  if thermalData then
    entry.base.coolantMass = thermalData.coolantMass or entry.base.coolantMass or 1
    entry.base.oilVolume = tonumber(thermalData.oilVolume) or entry.base.oilVolume
  end
  return entry
end

local function rebuildDeviceContexts()
  deviceContexts = {
    engine = {devices = {}},
    radiator = {devices = {}},
    transmission = {gearboxes = {}, clutches = {}}
  }

  for _, device in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
    local entry = buildDeviceEntry(device)
    table.insert(deviceContexts.engine.devices, entry)
    table.insert(deviceContexts.radiator.devices, entry)
  end

  for _, device in ipairs(powertrain.getDevicesByCategory("gearbox") or {}) do
    table.insert(deviceContexts.transmission.gearboxes, buildDeviceEntry(device))
  end

  for _, device in ipairs(powertrain.getDevicesByCategory("clutch") or {}) do
    table.insert(deviceContexts.transmission.clutches, buildDeviceEntry(device))
  end
end

local function getVehicleMassKg()
  local total = 0
  for _, nodeData in pairs(v and v.data and v.data.nodes or {}) do
    total = total + max(tonumber(nodeData and nodeData.nodeWeight) or 0, 0)
  end
  return total
end

local function getEngineBlockMassKg(engine)
  local total = 0
  local seen = {}
  for key, value in pairs(engine and engine.engineBlockNodes or {}) do
    local nodeId = type(value) == 'number' and value or (type(key) == 'number' and key or nil)
    if nodeId ~= nil and not seen[nodeId] then
      local nodeData = v and v.data and v.data.nodes and v.data.nodes[nodeId] or nil
      total = total + max(tonumber(nodeData and nodeData.nodeWeight) or 0, 0)
      seen[nodeId] = true
    end
  end
  return total
end

local function classifyLiveVehicle(modelFamily, curbWeightKg, engineMassKg)
  local model = string.lower(tostring(modelFamily or ''))
  if string.find(model, 'tseries', 1, true) or string.find(model, 'semi', 1, true) then
    return 'heavyTruck', 'modelFamily'
  end
  if string.find(model, 'mdseries', 1, true) or string.find(model, 'medium', 1, true) then
    return 'mediumTruck', 'modelFamily'
  end
  for _, token in ipairs({'pickup', 'dseries', 'roamer', 'hopper', 'van'}) do
    if string.find(model, token, 1, true) then
      return 'lightTruck', 'modelFamily'
    end
  end
  if curbWeightKg >= 8000 then
    return 'heavyTruck', 'curbWeight'
  elseif curbWeightKg >= 3500 then
    return 'mediumTruck', 'curbWeight'
  elseif curbWeightKg >= 2300 then
    return 'lightTruck', 'curbWeight'
  elseif curbWeightKg > 0 then
    return 'passenger', 'curbWeight'
  end
  if engineMassKg >= 650 then
    return 'heavyTruck', 'engineMass'
  elseif engineMassKg >= 350 then
    return 'mediumTruck', 'engineMass'
  elseif engineMassKg >= 220 then
    return 'lightTruck', 'engineMass'
  end
  return 'passenger', 'default'
end

local function buildLiveVehicleProfile(existing)
  existing = normalizeProfile(existing)
  local engineEntry = deviceContexts and deviceContexts.engine and deviceContexts.engine.devices[1] or nil
  local engine = engineEntry and engineEntry.device or nil
  local vehicleDirectory = v and v.data and v.data.vehicleDirectory or nil
  local normalizedDirectory = vehicleDirectory and string.lower(tostring(vehicleDirectory)):gsub('\\', '/') or ''
  local modelFamily = normalizedDirectory:match('/vehicles/([^/]+)') or normalizedDirectory:match('vehicles/([^/]+)') or
                          (v and v.data and (v.data.model or v.data.name)) or existing.modelFamily
  local liveCurbWeightKg = getVehicleMassKg()
  local curbWeightKg = existing.curbWeightKg > 0 and existing.curbWeightKg or liveCurbWeightKg
  local engineMassKg = getEngineBlockMassKg(engine)
  local lockedClass = existing.classSource == 'maintenanceClass' or existing.classSource == 'bodyStyle'
  local className, classSource = classifyLiveVehicle(modelFamily, curbWeightKg, engineMassKg)
  if lockedClass then
    className = existing.class
    classSource = existing.classSource
  end

  local profile = normalizeProfile({
    class = className,
    classSource = classSource,
    capacities = existing.class == className and existing.capacities or common.getClassDefaultCapacities(className),
    fuelType = engineEntry and engineEntry.base.requiredEnergyType or existing.fuelType,
    isDiesel = existing.isDiesel,
    curbWeightKg = curbWeightKg,
    engineMassKg = engineMassKg,
    powerHp = existing.powerHp,
    torqueNm = existing.torqueNm,
    modelFamily = modelFamily
  })
  local oilVolume = engineEntry and tonumber(engineEntry.base.oilVolume) or nil
  local coolantMass = engineEntry and tonumber(engineEntry.base.coolantMass) or nil
  if oilVolume and oilVolume >= 0.25 and oilVolume <= 100 then
    profile.capacities.oil = oilVolume
  end
  if coolantMass and coolantMass >= 0.25 and coolantMass <= 100 then
    profile.capacities.coolant = coolantMass
  end
  local rawPower = engineEntry and tonumber(engineEntry.base.maxPower) or 0
  profile.powerHp = rawPower > 10000 and rawPower / 745.7 or rawPower * 0.98632
  profile.torqueNm = engineEntry and max(tonumber(engineEntry.base.maxTorque) or 0, 0) or 0
  return profile
end

local function buildSnapshot()
  return common.deepCopy(state or buildDefaultState())
end

local function serializeValue(value)
  if type(serialize) ~= "function" then
    return nil
  end
  return serialize(value)
end

local function getSerializedSignature(value)
  return serializeValue(value)
end

local function roundValue(value, places)
  local precision = 10 ^ (places or 0)
  return floor((tonumber(value) or 0) * precision + 0.5) / precision
end

local function maintenanceChanged(previousMaintenance, nextMaintenance)
  if type(previousMaintenance) ~= "table" or type(nextMaintenance) ~= "table" then
    return previousMaintenance ~= nextMaintenance
  end

  for itemName, itemValue in pairs(nextMaintenance) do
    if abs((previousMaintenance[itemName] or 0) - (itemValue or 0)) > 0.0001 then
      return true
    end
  end

  for itemName, itemValue in pairs(previousMaintenance) do
    if abs((nextMaintenance[itemName] or 0) - (itemValue or 0)) > 0.0001 then
      return true
    end
  end

  return false
end

local function sendStateToGE()
  if not inventoryId or not state or type(serialize) ~= "function" then
    return
  end
  obj:queueGameEngineLua("if vehicleMaintenance and vehicleMaintenance.onVehicleMaintenanceStateChanged then vehicleMaintenance.onVehicleMaintenanceStateChanged(" ..
                             tostring(inventoryId) .. ", " .. serialize(buildSnapshot()) .. ") end")
end

local function buildMatchedPartsDebug(cache, partConditions)
  local matchedParts = {}
  for _, partId in ipairs(cache.partIds or {}) do
    local condition = partConditions and partConditions[partId] or nil
    table.insert(matchedParts, {
      partId = partId,
      miles = (tonumber(condition and condition.odometer) or 0) * common.metersToMiles,
      odometer = tonumber(condition and condition.odometer) or 0,
      integrityValue = tonumber(condition and condition.integrityValue),
      isRoot = cache.rootPartId == partId
    })
  end

  table.sort(matchedParts, function(a, b)
    if a.isRoot ~= b.isRoot then
      return a.isRoot
    end
    if math.abs((a.miles or 0) - (b.miles or 0)) > 0.001 then
      return (a.miles or 0) > (b.miles or 0)
    end
    return tostring(a.partId or "") < tostring(b.partId or "")
  end)

  return matchedParts
end

local function getRuntimeSymptom(runtimeCategory)
  if runtimeCategory and runtimeCategory.activeSymptom and (runtimeCategory.symptomTimer or 0) > 0 then
    return runtimeCategory.activeSymptom
  end
end

local function getSymptomLabel(symptom)
  if type(symptom) ~= "string" or symptom == "" then
    return nil
  end
  return symptomLabels[symptom] or symptom
end

local function getEngineSymptomModifiers(symptom)
  local modifiers = {
    torqueCoef = 1,
    powerCoef = 1,
    frictionCoef = 1,
    roughnessCoef = 1,
    ignitionBonus = 0
  }

  if symptom == 'roughRunning' or symptom == 'ticking' then
    modifiers.roughnessCoef = 1.1
  elseif symptom == 'roughIdle' then
    modifiers.roughnessCoef = 1.32
    modifiers.ignitionBonus = 0.018
  elseif symptom == 'torqueDip' then
    modifiers.torqueCoef = 0.94
  elseif symptom == 'powerFade' then
    modifiers.powerCoef = 0.9
    modifiers.torqueCoef = 0.96
    modifiers.frictionCoef = 1.03
  elseif symptom == 'stall' then
    modifiers.powerCoef = 0.7
    modifiers.torqueCoef = 0.65
    modifiers.roughnessCoef = 1.55
    modifiers.frictionCoef = 1.05
    modifiers.ignitionBonus = 0.045
  end

  return modifiers
end

local function getRadiatorSymptomModifiers(symptom)
  local modifiers = {
    torqueCoef = 1,
    frictionCoef = 1
  }

  if symptom == 'coolantSeep' then
    modifiers.torqueCoef = 0.95
    modifiers.frictionCoef = 1.015
  elseif symptom == 'fanOverwork' then
    modifiers.torqueCoef = 0.97
    modifiers.frictionCoef = 1.01
  end

  return modifiers
end

local function getTransmissionSymptomModifiers(symptom)
  local modifiers = {
    frictionCoef = 1,
    dynamicFrictionCoef = 1,
    shiftSpeedCoef = 1,
    lockTorqueCoef = 1,
    clutchFreePlayCoef = 1
  }

  if symptom == 'roughShift' then
    modifiers.frictionCoef = 1.03
    modifiers.dynamicFrictionCoef = 1.04
    modifiers.clutchFreePlayCoef = 1.08
  elseif symptom == 'shiftDelay' then
    modifiers.shiftSpeedCoef = 0.82
  elseif symptom == 'slip' then
    modifiers.frictionCoef = 1.06
    modifiers.dynamicFrictionCoef = 1.08
    modifiers.shiftSpeedCoef = 0.88
    modifiers.lockTorqueCoef = 0.9
    modifiers.clutchFreePlayCoef = 1.22
  end

  return modifiers
end

local function buildMetricRow(key, label, value, valueType, severity, detail)
  return {
    key = key,
    label = label,
    value = value,
    valueType = valueType,
    severity = severity,
    detail = detail
  }
end

local function buildRiskFlag(key, label, severity, detail)
  return {
    key = key,
    label = label,
    severity = severity,
    detail = detail
  }
end

local function getMinDueMiles(serviceDueMilesRemaining)
  local best = math.huge
  for _, dueMiles in pairs(serviceDueMilesRemaining or {}) do
    if tonumber(dueMiles) and dueMiles < best then
      best = dueMiles
    end
  end

  if best == math.huge then
    return nil
  end
  return best
end

local function captureLiveMetrics(categoryName, runtimeCategory, derived)
  if categoryName == 'engine' then
    local entry = deviceContexts.engine.devices[1]
    if not entry or not entry.device then
      return {}
    end

    local engine = entry.device
    local base = entry.base or {}
    local baseMaxTorque = max(tonumber(base.maxTorque) or tonumber(engine.maxTorque) or 0, 0)
    local baseMaxPowerRaw = max(tonumber(base.maxPower) or tonumber(engine.maxPower) or 0, 0)
    local baseMaxPowerWatts = common.getBeamPowerWatts(baseMaxPowerRaw)
    local currentAV = max(abs(getNumericValue(engine.outputAV1 or engine.inputAV or engine.outputAV2)), 0)
    local redlineAV = max(tonumber(base.maxAV) or tonumber(engine.maxAV) or 0, 1)
    local rpmCapacity = currentAV / redlineAV
    local torqueLimit = tonumber(engine.maxTorqueLimit) or base.originalMaxTorqueLimit or math.huge
    local symptom = getRuntimeSymptom(runtimeCategory)
    local liveTorqueHoldCoef = engineCategory.getLiveTorqueHoldCoef(
      tonumber(derived and derived.torqueHoldCoef) or 1,
      tonumber(derived and derived.loadFactor) or 0,
      rpmCapacity
    )
    local expectedTorqueCap = baseMaxTorque * liveTorqueHoldCoef * getEngineSymptomModifiers(symptom).torqueCoef
    local powerCapActive = runtimeCategory and runtimeCategory.lastPowerLimitActive
    if powerCapActive == nil then
      powerCapActive = baseMaxPowerWatts > 0 and currentAV > 220 and torqueLimit < (expectedTorqueCap - 0.001)
    end

    return {
      currentAV = currentAV,
      rpmCapacity = rpmCapacity,
      loadFactor = tonumber(derived and derived.loadFactor) or 0,
      baseMaxPowerRaw = baseMaxPowerRaw,
      baseMaxPowerWatts = baseMaxPowerWatts,
      liveTorqueHoldCoef = liveTorqueHoldCoef,
      torqueLimitCoef = baseMaxTorque > 0 and torqueLimit / baseMaxTorque or nil,
      frictionCoef = base.friction and base.friction ~= 0 and (tonumber(engine.friction) or base.friction) / base.friction or nil,
      dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(engine.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil,
      roughnessCoef = base.idleAVReadErrorRange and base.idleAVReadErrorRange ~= 0 and
          (tonumber(engine.idleAVReadErrorRange) or base.idleAVReadErrorRange) / base.idleAVReadErrorRange or nil,
      ignitionErrorChance = tonumber(engine.fastIgnitionErrorChance) or tonumber(derived and derived.ignitionErrorChance) or 0,
      powerCapActive = powerCapActive,
      powerLimitReason = runtimeCategory and runtimeCategory.lastPowerLimitReason or nil
    }
  elseif categoryName == 'radiator' then
    local entry = deviceContexts.radiator.devices[1]
    if not entry or not entry.device then
      return {}
    end

    local engine = entry.device
    local base = entry.base or {}
    local baseMaxTorque = max(tonumber(base.maxTorque) or tonumber(engine.maxTorque) or 0, 0)
    local torqueLimit = tonumber(engine.maxTorqueLimit) or base.originalMaxTorqueLimit or math.huge
    return {
      torqueLimitCoef = baseMaxTorque > 0 and torqueLimit / baseMaxTorque or nil,
      powerLimitActive = runtimeCategory and runtimeCategory.lastPowerLimitActive == true or false,
      powerLimitReason = runtimeCategory and runtimeCategory.lastPowerLimitReason or nil,
      frictionCoef = base.friction and base.friction ~= 0 and (tonumber(engine.friction) or base.friction) / base.friction or nil,
      dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(engine.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil
    }
  elseif categoryName == 'transmission' then
    local gearboxEntry = deviceContexts.transmission.gearboxes[1]
    local clutchEntry = deviceContexts.transmission.clutches[1]
    local metrics = {}

    if gearboxEntry and gearboxEntry.device then
      local gearbox = gearboxEntry.device
      local base = gearboxEntry.base or {}
      metrics.frictionCoef = base.friction and base.friction ~= 0 and (tonumber(gearbox.friction) or base.friction) / base.friction or nil
      metrics.dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(gearbox.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil
      metrics.shiftSpeedCoef = base.gearRatioChangeRate and base.gearRatioChangeRate ~= 0 and
          (tonumber(gearbox.gearRatioChangeRate) or base.gearRatioChangeRate) / base.gearRatioChangeRate or nil
      metrics.gearboxLockTorqueCoef = base.lockTorque and base.lockTorque ~= 0 and
          (tonumber(gearbox.lockTorque) or base.lockTorque) / base.lockTorque or nil
    end

    if clutchEntry and clutchEntry.device then
      local clutch = clutchEntry.device
      local base = clutchEntry.base or {}
      metrics.clutchLockTorqueCoef = base.lockTorque and base.lockTorque ~= 0 and
          (tonumber(clutch.lockTorque) or base.lockTorque) / base.lockTorque or nil
      metrics.clutchFreePlayCoef = base.clutchFreePlay and base.clutchFreePlay ~= 0 and
          (tonumber(clutch.clutchFreePlay) or base.clutchFreePlay) / base.clutchFreePlay or nil
    end

    return metrics
  end

  return {}
end

local function buildMaintenanceItems(categoryState, derived)
  local items = {}
  for itemName, itemValue in pairs(categoryState.maintenance or {}) do
    table.insert(items, {
      name = itemName,
      label = maintenanceLabels[itemName] or itemName,
      value = roundValue(itemValue, 4),
      targetValue = roundValue(derived.serviceTargets and derived.serviceTargets[itemName] or 0, 4),
      dueMiles = roundValue(derived.serviceDueMilesRemaining and derived.serviceDueMilesRemaining[itemName] or 0, 1),
      effectiveIntervalMiles = roundValue(derived.effectiveIntervals and derived.effectiveIntervals[itemName] or 0, 1)
    })
  end

  table.sort(items, function(a, b)
    return tostring(a.label) < tostring(b.label)
  end)

  return items
end

local function buildCurrentEffects(categoryName, categoryState, runtimeCategory, derived, liveMetrics, isPreview)
  local symptom = getRuntimeSymptom(runtimeCategory)
  local effects = {}

  if categoryName == 'engine' then
    local modifiers = getEngineSymptomModifiers(symptom)
    local previewRpmCapacity = derived.rpmCapacity or derived.rpmFactor or 0
    local liveTorqueHoldCoef = liveMetrics.liveTorqueHoldCoef or
                                   engineCategory.getLiveTorqueHoldCoef(derived.torqueHoldCoef or 1, derived.loadFactor or 0, previewRpmCapacity)
    local torqueLimitCoef = liveMetrics.torqueLimitCoef or (liveTorqueHoldCoef * modifiers.torqueCoef)
    local roughnessCoef = liveMetrics.roughnessCoef or ((derived.roughnessCoef or 1) * modifiers.roughnessCoef)
    local ignitionErrorChance = liveMetrics.ignitionErrorChance or common.clamp((derived.ignitionErrorChance or 0) + modifiers.ignitionBonus, 0, 0.12)
    local frictionCoef = liveMetrics.frictionCoef or ((derived.frictionCoef or 1) * modifiers.frictionCoef)
    local symptomLabel = getSymptomLabel(symptom)

    table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
      symptom and "high" or "ok"))
    table.insert(effects, buildMetricRow("torqueLimitCoef", "Torque limit hold", roundValue(torqueLimitCoef or 1, 4), "ratio",
      (torqueLimitCoef or 1) < 0.8 and "high" or ((torqueLimitCoef or 1) < 0.92 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("liveTorqueHoldCoef", "Live torque hold", roundValue(liveTorqueHoldCoef or 1, 4), "ratio",
      (liveTorqueHoldCoef or 1) < 0.8 and "high" or ((liveTorqueHoldCoef or 1) < 0.92 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("powerCapActive", "Power limit active", liveMetrics.powerCapActive == true, "boolean",
      liveMetrics.powerCapActive and "medium" or "ok"))
    table.insert(effects, buildMetricRow("powerLimitReason", "Power limit reason", liveMetrics.powerLimitReason or "none", "text",
      liveMetrics.powerLimitReason and "medium" or "ok"))
    table.insert(effects, buildMetricRow("baseMaxPowerRaw", "Beam max power raw", roundValue(liveMetrics.baseMaxPowerRaw or 0, 1), "number", "ok"))
    table.insert(effects, buildMetricRow("baseMaxPowerWatts", "Beam max power watts", roundValue(liveMetrics.baseMaxPowerWatts or 0, 1), "number", "ok"))
    table.insert(effects, buildMetricRow("rpmCapacity", "RPM percent", roundValue(liveMetrics.rpmCapacity or previewRpmCapacity or 0, 4), "ratio",
      (liveMetrics.rpmCapacity or previewRpmCapacity or 0) > 0.92 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("loadFactor", "Load percent", roundValue(liveMetrics.loadFactor or derived.loadFactor or 0, 4), "ratio",
      (liveMetrics.loadFactor or derived.loadFactor or 0) > 0.85 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("roughnessCoef", "Roughness", roundValue(roughnessCoef or 1, 4), "ratio",
      (roughnessCoef or 1) > 1.25 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("ignitionErrorChance", "Ignition error chance", roundValue(ignitionErrorChance, 5), "chance",
      ignitionErrorChance > 0.02 and "high" or (ignitionErrorChance > 0.01 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("frictionCoef", "Friction", roundValue(frictionCoef or 1, 4), "ratio",
      (frictionCoef or 1) > 1.04 and "medium" or "ok"))
  elseif categoryName == 'radiator' then
    local modifiers = getRadiatorSymptomModifiers(symptom)
    local symptomLabel = getSymptomLabel(symptom)

    table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
      symptom and "medium" or "ok"))
    table.insert(effects, buildMetricRow("coolantMassCoef", "Coolant mass", roundValue(derived.coolantMassCoef or 1, 4), "ratio",
      (derived.coolantMassCoef or 1) < 0.88 and "high" or ((derived.coolantMassCoef or 1) < 0.95 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("coolingPowerLimitActive", "Power limit active", liveMetrics.powerLimitActive == true, "boolean",
      liveMetrics.powerLimitActive and "high" or "ok"))
    table.insert(effects, buildMetricRow("coolingPowerLimitReason", "Power limit reason", liveMetrics.powerLimitReason or "none", "text",
      liveMetrics.powerLimitReason and "high" or "ok"))
    table.insert(effects, buildMetricRow("isOverheating", "Overheating", derived.isOverheating == true, "boolean",
      derived.isOverheating and "high" or "ok"))
    table.insert(effects, buildMetricRow("frictionCoef", "Cooling friction bump", roundValue(modifiers.frictionCoef, 4), "ratio",
      modifiers.frictionCoef > 1 and "medium" or "ok"))
  elseif categoryName == 'transmission' then
    local symptomModifiers = getTransmissionSymptomModifiers(symptom)
    local lockTorqueCoef = liveMetrics.clutchLockTorqueCoef or liveMetrics.gearboxLockTorqueCoef or
        common.clamp((derived.lockTorqueCoef or 1) * symptomModifiers.lockTorqueCoef, 0, 1)
    local symptomLabel = getSymptomLabel(symptom)

    table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
      symptom and "medium" or "ok"))
    table.insert(effects, buildMetricRow("transmissionHeatFactor", "Transmission heat", roundValue(derived.transmissionHeatFactor or 0, 4), "ratio",
      (derived.transmissionHeatFactor or 0) >= 1 and "high" or ((derived.transmissionHeatFactor or 0) >= 0.65 and "medium" or "ok"),
      string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
    table.insert(effects, buildMetricRow("slipSeverity", "Slip pressure", roundValue(derived.slipSeverity or 0, 4), "ratio",
      (derived.slipSeverity or 0) >= 1 and "high" or ((derived.slipSeverity or 0) >= 0.65 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("shiftSpeedCoef", "Shift speed", roundValue(liveMetrics.shiftSpeedCoef or
      common.clamp((derived.shiftSpeedCoef or 1) * symptomModifiers.shiftSpeedCoef, 0.25, 1), 4), "ratio",
      (liveMetrics.shiftSpeedCoef or derived.shiftSpeedCoef or 1) < 0.78 and "high" or
          ((liveMetrics.shiftSpeedCoef or derived.shiftSpeedCoef or 1) < 0.88 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("lockTorqueCoef", "Lock torque", roundValue(lockTorqueCoef, 4), "ratio",
      lockTorqueCoef < 0.86 and "high" or (lockTorqueCoef < 0.94 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("clutchFreePlayCoef", "Clutch free play", roundValue(liveMetrics.clutchFreePlayCoef or
      common.clamp((derived.clutchFreePlayCoef or 1) * symptomModifiers.clutchFreePlayCoef, 1, 5.0), 4), "ratio",
      (liveMetrics.clutchFreePlayCoef or derived.clutchFreePlayCoef or 1) > 1.7 and "high" or
          ((liveMetrics.clutchFreePlayCoef or derived.clutchFreePlayCoef or 1) > 1.3 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("frictionCoef", "Drivetrain friction", roundValue(liveMetrics.frictionCoef or
      ((derived.frictionCoef or 1) * symptomModifiers.frictionCoef), 4), "ratio",
      (liveMetrics.frictionCoef or derived.frictionCoef or 1) > 1.06 and "medium" or "ok"))
  end

  return effects
end

local function buildRiskFlags(categoryName, categoryState, derived)
  local flags = {}

  for itemName, targetValue in pairs(derived.serviceTargets or {}) do
    local currentValue = tonumber(categoryState.maintenance and categoryState.maintenance[itemName]) or 1
    if currentValue <= targetValue then
      table.insert(flags, buildRiskFlag(itemName .. "_due", (maintenanceLabels[itemName] or itemName) .. " is past service target",
        currentValue < (targetValue - 0.12) and "high" or "medium",
        string.format("%.0f%% value vs %.0f%% target", currentValue * 100, targetValue * 100)))
    end
  end

  if (derived.driveMultiplier or 1) >= 1.45 then
    table.insert(flags, buildRiskFlag("wear_spike", "Current stress is accelerating wear", "medium",
      string.format("Drive multiplier %.2fx", tonumber(derived.driveMultiplier) or 1)))
  end

  if categoryName == 'engine' then
    if (derived.integrityValue or 1) <= 0.45 then
      table.insert(flags, buildRiskFlag("engine_integrity", "Engine integrity is critically low", "high",
        string.format("%.0f%% integrity remaining", (tonumber(derived.integrityValue) or 0) * 100)))
    elseif (derived.integrityValue or 1) <= 0.7 then
      table.insert(flags, buildRiskFlag("engine_integrity", "Engine integrity is lowering failure margin", "medium",
        string.format("%.0f%% integrity remaining", (tonumber(derived.integrityValue) or 0) * 100)))
    end
    if derived.catastrophicOilStarvation then
      table.insert(flags, buildRiskFlag("oil_starvation_catastrophic", "Catastrophic oil starvation", "high",
        "Oil level and oil quality are effectively gone; hard engine failure is imminent."))
    elseif derived.severeOilStarvation then
      table.insert(flags, buildRiskFlag("oil_starvation", "Severe oil starvation", "high",
        "The engine is running with critically low oil reserve and will not survive continued load."))
    end
    if (derived.outputStressFactor or 0) >= 1 then
      table.insert(flags, buildRiskFlag("high_output", "High-output build is amplifying engine wear", "medium",
        string.format("%.0f hp / %.0f Nm", tonumber(derived.powerHp) or 0, tonumber(derived.torqueNm) or 0)))
    end
    if derived.pistonRingsDamaged == true then
      table.insert(flags, buildRiskFlag("piston_rings", "Damaged piston rings are consuming oil", "high",
        string.format("%.6f per sec", tonumber(derived.pistonRingOilConsumptionRate) or 0)))
    end
  elseif categoryName == 'radiator' then
    if derived.catastrophicCoolingLoss then
      table.insert(flags, buildRiskFlag("cooling_catastrophic", "Catastrophic coolant loss", "high",
        "Coolant reserve and integrity are both effectively gone; engine overheating failure is imminent."))
    elseif derived.severeCoolingLoss then
      table.insert(flags, buildRiskFlag("cooling_severe", "Severe cooling loss", "high",
        "Cooling reserve is critically low and heat will escalate rapidly under load."))
    end
    if derived.isOverheating == true then
      table.insert(flags, buildRiskFlag("overheating", "Cooling system is actively overheating", "high",
        string.format("%.1f C coolant", tonumber(derived.coolantTemp) or 0)))
    elseif (derived.criticalCoolantTempFactor or 0) > 0 then
      table.insert(flags, buildRiskFlag("critical_heat", "Coolant temperature is in rapid-loss territory", "medium",
        string.format("%.1f C coolant", tonumber(derived.coolantTemp) or 0)))
    end
  elseif categoryName == 'transmission' then
    if (derived.limitStressFactor or 0) >= 0.9 then
      table.insert(flags, buildRiskFlag("limit_stress", "Transmission is operating near its limits", "medium",
        string.format("Limit stress %.2f", tonumber(derived.limitStressFactor) or 0)))
    end
    if (derived.transmissionOverheatFactor or 0) >= 0.45 then
      table.insert(flags, buildRiskFlag("transmission_overheat", "Transmission heat is in breakage territory", "high",
        string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
    elseif (derived.transmissionHeatFactor or 0) >= 0.7 then
      table.insert(flags, buildRiskFlag("transmission_heat", "Transmission heat is accelerating wear", "medium",
        string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
    end
    if derived.criticalFluidCondition then
      table.insert(flags, buildRiskFlag("fluid_quality_critical", "Transmission fluid quality is causing harsh shifting", "high",
        string.format("%.0f%% quality remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidCondition) or 0) * 100)))
    elseif (derived.fluidConditionSeverity or 0) >= 0.8 then
      table.insert(flags, buildRiskFlag("fluid_quality_low", "Transmission fluid quality is degrading shift behavior", "medium",
        string.format("%.0f%% quality remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidCondition) or 0) * 100)))
    end
    if (derived.loadFactor or 0) >= 0.8 and (derived.maintenancePenalty or 0) >= 0.2 then
      table.insert(flags, buildRiskFlag("slip_risk", "Load and maintenance neglect are raising slip risk", "high",
        string.format("Load %.0f%%", (tonumber(derived.loadFactor) or 0) * 100)))
    end
    if derived.criticalFluidLoss then
      table.insert(flags, buildRiskFlag("fluid_loss", "Transmission fluid reserve is critically low", "high",
        string.format("%.0f%% fluid remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidLevel) or 0) * 100)))
    elseif (derived.fluidLevelSeverity or 0) >= 0.8 then
      table.insert(flags, buildRiskFlag("fluid_low", "Low transmission fluid is cutting clutch hold margin", "high",
        string.format("%.0f%% fluid remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidLevel) or 0) * 100)))
    end
    if (derived.hardFailureRate or 0) >= 0.01 then
      table.insert(flags, buildRiskFlag("failure_window", "Transmission hard-failure chance is now active", "high",
        string.format("%.3f / sec", tonumber(derived.hardFailureRate) or 0)))
    elseif (derived.hardFailureRate or 0) > 0 then
      table.insert(flags, buildRiskFlag("failure_window", "Transmission hard-failure chance is non-zero", "medium",
        string.format("%.3f / sec", tonumber(derived.hardFailureRate) or 0)))
    end
  end

  return flags
end

local function buildCurvePreview(categoryName, categoryState, derived)
  local datasets = {}
  local xMaxMiles = 0
  local palette = {"#f08b49", "#57b8d8", "#d7c45c", "#91e075"}
  local orderedItems = buildMaintenanceItems(categoryState, derived)

  for index, item in ipairs(orderedItems) do
    local effectiveIntervalMiles = max(tonumber(item.effectiveIntervalMiles) or 0, 0.1)
    local targetValue = common.clamp(tonumber(item.targetValue) or 0.5, 0, 1)
    local dueMiles = max(tonumber(item.dueMiles) or 0, 0)
    local maxMiles = max(dueMiles * 1.35, effectiveIntervalMiles * 0.85, 40)
    local stepMiles = max(maxMiles / 24, 1)
    local currentValue = common.clamp(tonumber(item.value) or 1, 0, 1)
    local simulatedValue = currentValue
    local points = {
      {0, roundValue(simulatedValue * 100, 2)}
    }

    for stepIndex = 1, 24 do
      simulatedValue = common.applyIntervalWear(simulatedValue, effectiveIntervalMiles, stepMiles, 1, targetValue)
      table.insert(points, {roundValue(stepIndex * stepMiles, 1), roundValue(simulatedValue * 100, 2)})
    end

    xMaxMiles = max(xMaxMiles, maxMiles)
    table.insert(datasets, {
      key = item.name,
      label = item.label,
      color = palette[((index - 1) % #palette) + 1],
      currentValue = currentValue,
      targetValue = targetValue,
      dueMiles = dueMiles,
      effectiveIntervalMiles = effectiveIntervalMiles,
      points = points
    })
  end

  return {
    xMaxMiles = roundValue(xMaxMiles, 1),
    datasets = datasets
  }
end

local function buildCategoryPreview(categoryName, scenarioInputs)
  local previewState = buildPreviewCategoryState(categoryName, scenarioInputs)
  local previewEnv = buildScenarioEnvironment(categoryName, scenarioInputs)
  local previewDerived = categoryModules[categoryName].buildDerived(previewState, previewEnv)
  previewDerived.rpmCapacity = previewEnv.rpmCapacity or previewEnv.rpmFactor
  previewDerived.rpmFactor = previewEnv.rpmFactor
  previewDerived.loadFactor = previewEnv.loadFactor
  previewDerived.heatFactor = previewEnv.heatFactor
  previewDerived.torqueNm = previewEnv.torqueNm
  previewDerived.torqueFactor = previewEnv.torqueFactor
  previewDerived.powerHp = previewEnv.powerHp
  previewDerived.powerFactor = previewEnv.powerFactor
  previewDerived.outputStressFactor = previewEnv.outputStressFactor
  previewDerived.coolantTemp = previewEnv.coolantTemp
  previewDerived.isOverheating = previewEnv.isOverheating
  previewDerived.overheatFactor = previewEnv.overheatFactor

  return {
    avgMiles = roundValue(scenarioInputs.avgMiles or 0, 1),
    maintenanceAverage = roundValue(previewDerived.maintenanceAvg or 1, 4),
    driveMultiplier = roundValue(previewDerived.driveMultiplier or 1, 4),
    serviceDueMiles = roundValue(getMinDueMiles(previewDerived.serviceDueMilesRemaining) or 0, 1),
    maintenanceItems = buildMaintenanceItems(previewState, previewDerived),
    currentEffects = buildCurrentEffects(categoryName, previewState, {}, previewDerived, {}, true),
    riskFlags = buildRiskFlags(categoryName, previewState, previewDerived),
    curvePreview = buildCurvePreview(categoryName, previewState, previewDerived)
  }
end

local function buildOverviewSummary(categories)
  local overview = {
    activeIssues = {},
    categorySummary = {},
    highestSeverity = "ok"
  }
  local severityRank = {ok = 0, medium = 1, high = 2}

  for _, categoryName in ipairs(categoryOrder) do
    local categoryData = categories[categoryName]
    if categoryData then
      local severityScore = (1 - (tonumber(categoryData.maintenanceAverage) or 1)) * 65
      if categoryData.activeSymptom then
        severityScore = severityScore + 20
        table.insert(overview.activeIssues, string.format("%s: %s", categoryLabels[categoryName] or categoryName, categoryData.activeSymptomLabel or categoryData.activeSymptom))
      end

      for _, risk in ipairs(categoryData.riskFlags or {}) do
        severityScore = severityScore + (risk.severity == "high" and 15 or 8)
        if severityRank[risk.severity] > severityRank[overview.highestSeverity] then
          overview.highestSeverity = risk.severity
        end
      end

      local dueMiles = getMinDueMiles(categoryData.serviceDueMilesRemaining)
      overview.categorySummary[categoryName] = {
        label = categoryLabels[categoryName] or categoryName,
        severityScore = roundValue(common.clamp(severityScore, 0, 100), 1),
        activeSymptom = categoryData.activeSymptomLabel or categoryData.activeSymptom,
        dueMiles = dueMiles and roundValue(dueMiles, 1) or nil,
        maintenanceAverage = roundValue(categoryData.maintenanceAverage or 1, 4),
        riskCount = #(categoryData.riskFlags or {})
      }
    end
  end

  return overview
end

local function buildCategoryDebugData(categoryName, categoryState, runtimeCategory, cache, partConditions)
  local derived = runtimeCategory.derived or {}
  local liveMetrics = captureLiveMetrics(categoryName, runtimeCategory, derived)
  local activeSymptom = getRuntimeSymptom(runtimeCategory)
  return {
    label = categoryLabels[categoryName] or categoryName,
    color = categoryColors[categoryName] or "#ffffff",
    avgMiles = (categoryState.avgOdometer or 0) * common.metersToMiles,
    wearBand = categoryState.wearBand,
    maintenance = common.deepCopy(categoryState.maintenance),
    maintenanceItems = buildMaintenanceItems(categoryState, derived),
    lastFailureTime = categoryState.lastFailureTime or 0,
    lastFailureType = categoryState.lastFailureType,
    rootPartId = cache.rootPartId,
    matchedPartCount = #(cache.partIds or {}),
    matchedPartIds = common.deepCopy(cache.partIds or {}),
    matchedParts = buildMatchedPartsDebug(cache, partConditions),
    activeSymptom = activeSymptom,
    activeSymptomLabel = getSymptomLabel(activeSymptom),
    symptomCooldown = runtimeCategory.cooldownTimer or 0,
    symptomTimer = runtimeCategory.symptomTimer or 0,
    symptomRate = derived.symptomRate or 0,
    hardFailureRate = derived.hardFailureRate or 0,
    maintenanceAverage = derived.maintenanceAvg or 1,
    neglectSeverity = derived.neglectSeverity or 0,
    integrityValue = derived.integrityValue or 1,
    integritySeverity = derived.integritySeverity or 0,
    driveMultiplier = derived.driveMultiplier or 1,
    driveMultipliers = common.deepCopy(derived.driveMultipliers or {}),
    rawDriveMultipliers = common.deepCopy(derived.rawDriveMultipliers or {}),
    serviceTargets = common.deepCopy(derived.serviceTargets or {}),
    effectiveIntervals = common.deepCopy(derived.effectiveIntervals or {}),
    serviceDueMilesRemaining = common.deepCopy(derived.serviceDueMilesRemaining or {}),
    torqueHoldCoef = derived.torqueHoldCoef or 1,
    liveTorqueHoldCoef = liveMetrics.liveTorqueHoldCoef or
        engineCategory.getLiveTorqueHoldCoef(derived.torqueHoldCoef or 1, derived.loadFactor or 0, derived.rpmCapacity or derived.rpmFactor or 0),
    powerHoldCoef = derived.powerHoldCoef or 1,
    roughnessCoef = derived.roughnessCoef or 1,
    coolantMassCoef = derived.coolantMassCoef or 1,
    radiatorDamage = derived.radiatorDamage or 0,
    shiftSpeedCoef = derived.shiftSpeedCoef or 1,
    lockTorqueCoef = derived.lockTorqueCoef or 1,
    clutchFreePlayCoef = derived.clutchFreePlayCoef or 1,
    rpmFactor = derived.rpmFactor or 0,
    loadFactor = derived.loadFactor or 0,
    heatFactor = derived.heatFactor or 0,
    torqueNm = derived.torqueNm or 0,
    torqueFactor = derived.torqueFactor or 0,
    powerHp = derived.powerHp or 0,
    powerFactor = derived.powerFactor or 0,
    outputStressFactor = derived.outputStressFactor or 0,
    profile = common.deepCopy(derived.profile or state.profile or {}),
    mileageAgeIndex = derived.mileageAgeIndex or 1,
    levelMileageMultiplier = derived.oilLevelMileageMultiplier or derived.coolantLevelMileageMultiplier or
                                 derived.fluidLevelMileageMultiplier or 1,
    capacityFactor = derived.oilCapacityFactor or derived.coolantCapacityFactor or derived.fluidCapacityFactor or 1,
    classConditionIntervalMultiplier = derived.classConditionIntervalMultiplier or 1,
    lowFluidConditionMultiplier = derived.lowOilConditionMultiplier or derived.lowFluidConditionMultiplier or 1,
    oilTemperatureMultiplier = derived.oilTemperatureMultiplier or 1,
    torqueCapacityStress = derived.torqueCapacityStress or 0,
    torqueCapacityRatio = derived.torqueCapacityRatio,
    combustionTorque = derived.combustionTorque or 0,
    maxTorqueRating = derived.maxTorqueRating or 0,
    extremeOutputGate = derived.extremeOutputGate or 0,
    extremePowerMultiplier = derived.extremePowerMultiplier or 1,
    ageWearSeverity = derived.ageWearSeverity or 0,
    ageWearFrictionCoef = derived.ageWearFrictionCoef or 1,
    ageWearDynamicFrictionCoef = derived.ageWearDynamicFrictionCoef or 1,
    ageWearIdleErrorCoef = derived.ageWearIdleErrorCoef or 1,
    rpmCapacity = derived.rpmCapacity or 0,
    engineRunningSeconds = derived.engineRunningSeconds or 0,
    pistonRingsDamaged = derived.pistonRingsDamaged or false,
    coolantTemp = derived.coolantTemp or 0,
    oilTemp = derived.oilTemp or 0,
    oilHeatFactor = derived.oilHeatFactor or 0,
    oilOverheatFactor = derived.oilOverheatFactor or 0,
    isOverheating = derived.isOverheating or false,
    overheatFactor = derived.overheatFactor or 0,
    hotRuntimeSeconds = derived.hotRuntimeSeconds or 0,
    overheatingRuntimeSeconds = derived.overheatingRuntimeSeconds or 0,
    totalHotRuntimeSeconds = derived.totalHotRuntimeSeconds or 0,
    totalOverheatingRuntimeSeconds = derived.totalOverheatingRuntimeSeconds or 0,
    warmupEvent = derived.warmupEvent or false,
    cooldownEvent = derived.cooldownEvent or false,
    warmupEventCount = derived.warmupEventCount or 0,
    cooldownEventCount = derived.cooldownEventCount or 0,
    liveMetrics = liveMetrics,
    currentEffects = buildCurrentEffects(categoryName, categoryState, runtimeCategory, derived, liveMetrics, false),
    riskFlags = buildRiskFlags(categoryName, categoryState, derived),
    curvePreview = buildCurvePreview(categoryName, categoryState, derived)
  }
end

local function buildDebugStream()
  local partConditions = getTrackedPartConditions()
  local scenarioInputs = ensureScenarioInputs(buildEnvironmentSnapshot(0))
  local categories = {}
  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = state.categories and state.categories[categoryName] or nil
    if categoryState then
      local cache = categoryCache[categoryName] or {}
      local runtimeCategory = runtimeState[categoryName] or {}
      categories[categoryName] = buildCategoryDebugData(categoryName, categoryState, runtimeCategory, cache, partConditions)
    end
  end

  local scenarioPreview = {
    presetId = runtimeState and runtimeState.debug and runtimeState.debug.scenarioPresetId or nil,
    categories = {}
  }
  for _, categoryName in ipairs(categoryOrder) do
    scenarioPreview.categories[categoryName] = buildCategoryPreview(categoryName, scenarioInputs)
  end

  return {
    inventoryId = inventoryId,
    vehicleId = obj:getId(),
    profile = common.deepCopy(state.profile or buildDefaultProfile()),
    lastSyncMileageMiles = (state.lastSyncMileage or 0) * common.metersToMiles,
    overview = buildOverviewSummary(categories),
    categories = categories,
    scenarioInputs = common.deepCopy(scenarioInputs),
    scenarioPresets = buildScenarioPresetList(),
    scenarioPreview = scenarioPreview,
    currentEffects = {
      engine = common.deepCopy(categories.engine and categories.engine.currentEffects or {}),
      radiator = common.deepCopy(categories.radiator and categories.radiator.currentEffects or {}),
      transmission = common.deepCopy(categories.transmission and categories.transmission.currentEffects or {})
    },
    riskFlags = {
      engine = common.deepCopy(categories.engine and categories.engine.riskFlags or {}),
      radiator = common.deepCopy(categories.radiator and categories.radiator.riskFlags or {}),
      transmission = common.deepCopy(categories.transmission and categories.transmission.riskFlags or {})
    },
    curvePreview = {
      engine = common.deepCopy(categories.engine and categories.engine.curvePreview or {}),
      radiator = common.deepCopy(categories.radiator and categories.radiator.curvePreview or {}),
      transmission = common.deepCopy(categories.transmission and categories.transmission.curvePreview or {})
    },
    debugMeta = {
      builtAt = os.time(),
      streamIntervalSeconds = debugStreamInterval,
      buildCount = debugStreamBuildCount,
      sendCount = debugStreamSendCount,
      usingTrackedPartConditions = type(trackedPartConditions) == "table",
      trackedPartConditionSignatureLength = trackedPartConditionsSignature and string.len(trackedPartConditionsSignature) or 0,
      scenarioUpdatedAt = runtimeState and runtimeState.debug and runtimeState.debug.scenarioUpdatedAt or 0
    }
  }
end

local function sendDebugStream(force)
  if streams and streams.willSend and streams.willSend("vehicleMaintenanceDebugData") then
    if force or debugStreamDirty or not debugStreamCache then
      debugStreamBuildCount = debugStreamBuildCount + 1
      debugStreamCache = buildDebugStream()
      debugStreamDirty = false
      if debugStreamCache and debugStreamCache.debugMeta then
        debugStreamCache.debugMeta.buildCount = debugStreamBuildCount
      end
    end

    if debugStreamCache then
      debugStreamSendCount = debugStreamSendCount + 1
      if debugStreamCache.debugMeta then
        debugStreamCache.debugMeta.sendCount = debugStreamSendCount
      end
      gui.send("vehicleMaintenanceDebugData", debugStreamCache)
    end
  end
end

local function syncPartConditions(partConditions)
  if type(partConditions) ~= "table" then
    return false
  end

  local signature = getSerializedSignature(partConditions)
  setTrackedPartConditions(partConditions, signature)
  markDebugStreamDirty()

  if not inventoryId or type(serialize) ~= "function" then
    return false
  end

  if signature and signature == lastAppliedPartConditionsSignature then
    return true
  end

  obj:queueGameEngineLua("if vehicleMaintenance and vehicleMaintenance.applyMaintenancePartConditions then vehicleMaintenance.applyMaintenancePartConditions(" ..
                             tostring(inventoryId) .. ", " .. serialize(partConditions) .. ", " .. tostring(obj:getId()) ..
                             ") end")
  lastAppliedPartConditionsSignature = signature
  return true
end

local function sendDisabledStateToGE()
  if not inventoryId then
    return
  end

  obj:queueGameEngineLua("if vehicleMaintenance and vehicleMaintenance.onVehicleMaintenanceStateChanged then vehicleMaintenance.onVehicleMaintenanceStateChanged(" ..
                             tostring(inventoryId) .. ", nil) end")
end

local function getRootDeviceForCategory(categoryName)
  local cache = categoryCache[categoryName] or {}
  if cache.rootDeviceName then
    local device = powertrain.getDevice(cache.rootDeviceName)
    if device then
      return device
    end
  end

  if categoryName == 'engine' or categoryName == 'radiator' then
    return deviceContexts.engine.devices[1] and deviceContexts.engine.devices[1].device or nil
  end
  return deviceContexts.transmission.gearboxes[1] and deviceContexts.transmission.gearboxes[1].device or
             (deviceContexts.transmission.clutches[1] and deviceContexts.transmission.clutches[1].device or nil)
end

local function getPowertrainDeviceState(rootEntry, rootDevice)
  local powertrainState = rootEntry and rootEntry.integrityState and rootEntry.integrityState.powertrain
  if type(powertrainState) ~= "table" then
    return nil
  end

  local deviceState = rootDevice and powertrainState[rootDevice.name] or nil
  if type(deviceState) ~= "table" then
    for _, candidate in pairs(powertrainState) do
      if type(candidate) == "table" then
        deviceState = candidate
        break
      end
    end
  end

  if type(deviceState) ~= "table" then
    return nil
  end

  return deviceState
end

local function getDeviceEntryByName(entries, deviceName)
  if type(entries) ~= "table" or not deviceName then
    return nil
  end

  for _, entry in ipairs(entries) do
    if entry.device and entry.device.name == deviceName then
      return entry
    end
  end

  return nil
end

getNumericValue = function(value)
  if type(value) == "table" then
    value = value.val or value.value or value[1]
  end
  return tonumber(value) or 0
end

buildEnvironmentSnapshot = function(dt)
  local throttleValue = (input and input.state and input.state.throttle) or
                            (electrics and electrics.values and electrics.values.throttle) or 0
  local shared = runtimeState and runtimeState.shared or {}
  local env = {
    loadFactor = common.clamp(getNumericValue(throttleValue), 0, 1),
    rpmFactor = 0,
    heatFactor = 0,
    torqueNm = 0,
    combustionTorque = 0,
    maxTorqueRating = 0,
    torqueFactor = 0,
    coolantTemp = 0,
    oilTemp = 0,
    oilHeatFactor = 0,
    oilOverheatFactor = 0,
    powerHp = 0,
    powerFactor = 0,
    outputStressFactor = 0,
    rpmCapacity = 0,
    engineRunningSeconds = 0,
    idleRuntimeSeconds = 0,
    profile = common.deepCopy(state and state.profile or buildDefaultProfile()),
    pistonRingsDamaged = false,
    isOverheating = false,
    overheatFactor = 0,
    warmupEvent = false,
    cooldownEvent = false,
    hotRuntimeSeconds = 0,
    overheatingRuntimeSeconds = 0,
    totalHotRuntimeSeconds = tonumber(shared.totalHotRuntimeSeconds) or 0,
    totalOverheatingRuntimeSeconds = tonumber(shared.totalOverheatingRuntimeSeconds) or 0,
    warmupEventCount = tonumber(shared.warmupEventCount) or 0,
    cooldownEventCount = tonumber(shared.cooldownEventCount) or 0
  }

  local engineEntry = deviceContexts.engine.devices[1]
  local engine = engineEntry and engineEntry.device or nil
  if not engine then
    return env
  end

  env.loadFactor = common.clamp(max(getNumericValue(engine.engineLoad or engine.instantEngineLoad), env.loadFactor), 0, 1)

  local currentAV = max(abs(getNumericValue(engine.outputAV1 or engine.inputAV or engine.outputAV2)), 0)
  local redlineAV = max(getNumericValue(engineEntry.base.maxAV or engine.maxAV), 1)
  local rpmCapacity = currentAV / redlineAV
  env.rpmCapacity = common.clamp(rpmCapacity, 0, 1.5)
  env.rpmFactor = common.clamp(common.linearScale(rpmCapacity, 0.35, 0.85, 0, 1), 0, 1)
  env.engineRunningSeconds = currentAV > 20 and max(tonumber(dt) or 0, 0) or 0
  env.idleRuntimeSeconds = env.engineRunningSeconds > 0 and env.loadFactor <= 0.15 and env.rpmCapacity <= 0.32 and
                               env.engineRunningSeconds or 0

  env.coolantTemp = getNumericValue(engine.thermals and engine.thermals.coolantTemperature or nil)
  env.oilTemp = getNumericValue(engine.thermals and engine.thermals.oilTemperature or nil)
  local engineRootPartId = categoryCache and categoryCache.engine and categoryCache.engine.rootPartId or nil
  local engineRootEntry = nil
  if engineRootPartId then
    local partConditions = getTrackedPartConditions()
    engineRootEntry = partConditions[engineRootPartId]
  end
  local engineDeviceState = getPowertrainDeviceState(engineRootEntry, engine)
  local thermalFailureState = engineDeviceState and engineDeviceState.thermals or nil
  env.pistonRingsDamaged = engine.thermals and engine.thermals.pistonRingsDamaged == true or
                               type(thermalFailureState) == "table" and thermalFailureState.pistonRingsDamaged == true or false
  env.heatFactor = common.clamp(common.linearScale(env.coolantTemp, 90, 125, 0, 1), 0, 1)
  env.overheatFactor = common.clamp(common.linearScale(env.coolantTemp, 115, 135, 0, 1), 0, 1)
  env.oilHeatFactor = common.clamp(common.linearScale(env.oilTemp, 105, 145, 0, 1), 0, 1)
  env.oilOverheatFactor = common.clamp(common.linearScale(env.oilTemp, 135, 170, 0, 1), 0, 1)
  env.isOverheating = env.overheatFactor > 0

  env.torqueNm = max(getNumericValue(engineEntry.base.maxTorque or engine.maxTorque or 0), 0)
  env.combustionTorque = max(abs(getNumericValue(engine.combustionTorque)), 0)
  env.maxTorqueRating = max(getNumericValue(engine.maxTorqueRating or engineEntry.base.maxTorqueRating), 0)
  env.torqueFactor = common.getTorqueFactor(env.torqueNm)
  local basePower = getNumericValue(engineEntry.base.maxPower or engine.maxPower or 0)
  local normalizedPowerHp = basePower > 10000 and basePower / 745.7 or basePower * 0.98632
  env.powerHp = max(tonumber(state and state.profile and state.profile.powerHp) or normalizedPowerHp, 0)
  env.powerFactor = common.getPowerFactor(env.powerHp)
  env.outputStressFactor = max(env.powerFactor, env.torqueFactor) + min(env.powerFactor, env.torqueFactor) * 0.35

  local isWarmNow = env.coolantTemp >= 80
  local isCoolNow = env.coolantTemp <= 70
  if shared.wasWarm ~= true and isWarmNow then
    shared.wasWarm = true
    shared.warmupEventCount = (tonumber(shared.warmupEventCount) or 0) + 1
    env.warmupEvent = true
  elseif shared.wasWarm == true and isCoolNow then
    shared.wasWarm = false
    shared.cooldownEventCount = (tonumber(shared.cooldownEventCount) or 0) + 1
    env.cooldownEvent = true
  elseif isWarmNow then
    shared.wasWarm = true
  end

  env.hotRuntimeSeconds = env.heatFactor > 0 and max(tonumber(dt) or 0, 0) or 0
  env.overheatingRuntimeSeconds = env.isOverheating and max(tonumber(dt) or 0, 0) or 0
  shared.totalHotRuntimeSeconds = (tonumber(shared.totalHotRuntimeSeconds) or 0) + env.hotRuntimeSeconds
  shared.totalOverheatingRuntimeSeconds = (tonumber(shared.totalOverheatingRuntimeSeconds) or 0) + env.overheatingRuntimeSeconds
  shared.lastCoolantTemp = env.coolantTemp

  env.totalHotRuntimeSeconds = shared.totalHotRuntimeSeconds
  env.totalOverheatingRuntimeSeconds = shared.totalOverheatingRuntimeSeconds
  env.warmupEventCount = shared.warmupEventCount or 0
  env.cooldownEventCount = shared.cooldownEventCount or 0

  return env
end

local function buildEnvironment(categoryName, avgMiles, snapshot)
  local env = {
    avgMiles = avgMiles,
    loadFactor = snapshot and snapshot.loadFactor or 0,
    rpmFactor = snapshot and snapshot.rpmFactor or 0,
    heatFactor = snapshot and snapshot.heatFactor or 0,
    torqueNm = snapshot and snapshot.torqueNm or 0,
    combustionTorque = snapshot and snapshot.combustionTorque or 0,
    maxTorqueRating = snapshot and snapshot.maxTorqueRating or 0,
    torqueFactor = snapshot and snapshot.torqueFactor or 0,
    coolantTemp = snapshot and snapshot.coolantTemp or 0,
    oilTemp = snapshot and snapshot.oilTemp or 0,
    oilHeatFactor = snapshot and snapshot.oilHeatFactor or 0,
    oilOverheatFactor = snapshot and snapshot.oilOverheatFactor or 0,
    powerHp = snapshot and snapshot.powerHp or 0,
    powerFactor = snapshot and snapshot.powerFactor or 0,
    outputStressFactor = snapshot and snapshot.outputStressFactor or 0,
    rpmCapacity = snapshot and snapshot.rpmCapacity or 0,
    engineRunningSeconds = snapshot and snapshot.engineRunningSeconds or 0,
    idleRuntimeSeconds = snapshot and snapshot.idleRuntimeSeconds or 0,
    profile = common.deepCopy(snapshot and snapshot.profile or state and state.profile or buildDefaultProfile()),
    integrityValue = 1,
    pistonRingsDamaged = snapshot and snapshot.pistonRingsDamaged or false,
    isOverheating = snapshot and snapshot.isOverheating or false,
    overheatFactor = snapshot and snapshot.overheatFactor or 0,
    warmupEvent = snapshot and snapshot.warmupEvent or false,
    cooldownEvent = snapshot and snapshot.cooldownEvent or false,
    hotRuntimeSeconds = snapshot and snapshot.hotRuntimeSeconds or 0,
    overheatingRuntimeSeconds = snapshot and snapshot.overheatingRuntimeSeconds or 0,
    totalHotRuntimeSeconds = snapshot and snapshot.totalHotRuntimeSeconds or 0,
    totalOverheatingRuntimeSeconds = snapshot and snapshot.totalOverheatingRuntimeSeconds or 0,
    warmupEventCount = snapshot and snapshot.warmupEventCount or 0,
    cooldownEventCount = snapshot and snapshot.cooldownEventCount or 0
  }

  if categoryName ~= 'radiator' then
    env.warmupEvent = false
    env.cooldownEvent = false
  end

  local rootPartId = categoryCache and categoryCache[categoryName] and categoryCache[categoryName].rootPartId or nil
  if rootPartId then
    local partConditions = getTrackedPartConditions()
    local rootEntry = partConditions and partConditions[rootPartId] or nil
    if rootEntry and tonumber(rootEntry.integrityValue) ~= nil then
      env.integrityValue = common.clamp(tonumber(rootEntry.integrityValue), 0, 1)
    end
  end

  return env
end

getScenarioPresetDefinition = function(presetId)
  for _, preset in ipairs(scenarioPresetDefinitions) do
    if preset.id == presetId then
      return preset
    end
  end
end

buildScenarioPresetList = function()
  local presets = {}
  for _, preset in ipairs(scenarioPresetDefinitions) do
    table.insert(presets, {
      id = preset.id,
      label = preset.label,
      description = preset.description
    })
  end
  return presets
end

local function getCurrentAverageMiles()
  local total = 0
  local count = 0
  if type(state) == "table" and type(state.categories) == "table" then
    for _, categoryName in ipairs(categoryOrder) do
      local categoryState = state.categories[categoryName]
      if type(categoryState) == "table" then
        total = total + ((tonumber(categoryState.avgOdometer) or 0) * common.metersToMiles)
        count = count + 1
      end
    end
  end
  if count <= 0 then
    return 0
  end
  return total / count
end

buildScenarioInputsFromLiveSnapshot = function(snapshot)
  local maintenance = {}
  for _, categoryName in ipairs(categoryOrder) do
    maintenance[categoryName] = common.deepCopy(state and state.categories and state.categories[categoryName] and
                                                    state.categories[categoryName].maintenance or
                                                    categoryModules[categoryName].getDefaultMaintenance())
  end

  return {
    avgMiles = roundValue(getCurrentAverageMiles(), 1),
    loadFactor = common.clamp(snapshot and snapshot.loadFactor or 0, 0, 1),
    rpmFactor = common.clamp(snapshot and snapshot.rpmFactor or 0, 0, 1),
    heatFactor = common.clamp(snapshot and snapshot.heatFactor or 0, 0, 1),
    powerHp = roundValue(snapshot and snapshot.powerHp or 0, 1),
    torqueNm = roundValue(snapshot and snapshot.torqueNm or 0, 1),
    maintenance = maintenance
  }
end

normalizeScenarioInputs = function(inputs)
  local normalized = inputs and common.deepCopy(inputs) or {}
  normalized.avgMiles = max(tonumber(normalized.avgMiles) or 0, 0)
  normalized.loadFactor = common.clamp(tonumber(normalized.loadFactor) or 0, 0, 1)
  normalized.rpmFactor = common.clamp(tonumber(normalized.rpmFactor) or 0, 0, 1)
  normalized.heatFactor = common.clamp(tonumber(normalized.heatFactor) or 0, 0, 1)
  normalized.powerHp = max(tonumber(normalized.powerHp) or 0, 0)
  normalized.torqueNm = max(tonumber(normalized.torqueNm) or 0, 0)
  normalized.maintenance = type(normalized.maintenance) == "table" and normalized.maintenance or {}

  for _, categoryName in ipairs(categoryOrder) do
    local categoryMaintenance = normalized.maintenance[categoryName]
    local defaultMaintenance = categoryModules[categoryName].getDefaultMaintenance()
    normalized.maintenance[categoryName] = {}
    for itemName, defaultValue in pairs(defaultMaintenance) do
      normalized.maintenance[categoryName][itemName] = common.clamp(
        tonumber(type(categoryMaintenance) == "table" and categoryMaintenance[itemName] or nil) or tonumber(defaultValue) or 1,
        0,
        1
      )
    end
  end

  return normalized
end

mergeScenarioInputs = function(baseInputs, updateInputs)
  local merged = normalizeScenarioInputs(baseInputs)
  if type(updateInputs) ~= "table" then
    return merged
  end

  for key, value in pairs(updateInputs) do
    if key == "maintenance" and type(value) == "table" then
      merged.maintenance = merged.maintenance or {}
      for categoryName, maintenanceValues in pairs(value) do
        if type(maintenanceValues) == "table" then
          merged.maintenance[categoryName] = merged.maintenance[categoryName] or {}
          for itemName, itemValue in pairs(maintenanceValues) do
            merged.maintenance[categoryName][itemName] = itemValue
          end
        end
      end
    else
      merged[key] = value
    end
  end

  return normalizeScenarioInputs(merged)
end

ensureScenarioInputs = function(snapshot)
  runtimeState.debug = runtimeState.debug or {}
  if type(runtimeState.debug.scenarioInputs) ~= "table" then
    runtimeState.debug.scenarioInputs = normalizeScenarioInputs(buildScenarioInputsFromLiveSnapshot(snapshot))
    runtimeState.debug.scenarioUpdatedAt = os.time()
  end
  return runtimeState.debug.scenarioInputs
end

buildScenarioEnvironment = function(categoryName, inputs)
  inputs = normalizeScenarioInputs(inputs)
  local avgMiles = max(tonumber(inputs.avgMiles) or 0, 0)
  local coolantTemp = common.lerp(70, 135, inputs.heatFactor or 0)
  local oilTemp = common.lerp(85, 165, inputs.heatFactor or 0)
  local env = buildEnvironment(categoryName, avgMiles, {
    loadFactor = inputs.loadFactor,
    rpmFactor = inputs.rpmFactor,
    heatFactor = inputs.heatFactor,
    torqueNm = inputs.torqueNm,
    torqueFactor = common.getTorqueFactor(inputs.torqueNm),
    coolantTemp = coolantTemp,
    oilTemp = oilTemp,
    oilHeatFactor = common.clamp(common.linearScale(oilTemp, 105, 145, 0, 1), 0, 1),
    oilOverheatFactor = common.clamp(common.linearScale(oilTemp, 135, 170, 0, 1), 0, 1),
    powerHp = inputs.powerHp,
    powerFactor = common.getPowerFactor(inputs.powerHp),
    outputStressFactor = max(common.getPowerFactor(inputs.powerHp), common.getTorqueFactor(inputs.torqueNm)) +
        min(common.getPowerFactor(inputs.powerHp), common.getTorqueFactor(inputs.torqueNm)) * 0.35,
    rpmCapacity = common.clamp(common.linearScale(inputs.rpmFactor or 0, 0, 1, 0.35, 1.05), 0, 1.5),
    engineRunningSeconds = 0,
    pistonRingsDamaged = false,
    isOverheating = coolantTemp >= 115,
    overheatFactor = common.clamp(common.linearScale(coolantTemp, 115, 135, 0, 1), 0, 1),
    warmupEvent = false,
    cooldownEvent = false,
    hotRuntimeSeconds = 0,
    overheatingRuntimeSeconds = 0,
    totalHotRuntimeSeconds = 0,
    totalOverheatingRuntimeSeconds = 0,
    warmupEventCount = 0,
    cooldownEventCount = 0
  })

  return env
end

buildPreviewCategoryState = function(categoryName, inputs)
  inputs = normalizeScenarioInputs(inputs)
  return {
    maintenance = common.deepCopy(inputs.maintenance and inputs.maintenance[categoryName] or
                                      categoryModules[categoryName].getDefaultMaintenance())
  }
end

local function getOverallMileage(partConditions)
  local maxOdometer = 0
  for _, conditionData in pairs(partConditions or {}) do
    maxOdometer = max(maxOdometer, tonumber(conditionData.odometer) or 0)
  end
  return maxOdometer
end

local function getAverageOdometer(partIds, partConditions, fallbackOdometer)
  local total = 0
  local count = 0
  for _, partId in ipairs(partIds or {}) do
    local partConditionData = partConditions[partId]
    if partConditionData and partConditionData.odometer then
      total = total + partConditionData.odometer
      count = count + 1
    end
  end
  if count == 0 then
    return fallbackOdometer or 0
  end
  return total / count
end

local function getCategoryAgeMiles(categoryName, categoryOdometers)
  local odometer = tonumber(categoryOdometers[categoryName]) or 0
  if categoryName == 'radiator' then
    -- coolant also circulates through the engine, so an old block keeps its leak paths
    odometer = max(odometer, tonumber(categoryOdometers.engine) or 0)
  end
  return odometer * common.metersToMiles
end

local function isCategoryBroken(categoryName, partConditions)
  local cache = categoryCache[categoryName]
  if not cache or not cache.rootPartId then
    return false
  end

  local rootCondition = partConditions and partConditions[cache.rootPartId] or nil
  return rootCondition and tonumber(rootCondition.integrityValue) ~= nil and tonumber(rootCondition.integrityValue) <= 0 or false
end

local function isMaintenanceFailureType(categoryName, failureType)
  if type(failureType) ~= "string" then
    return false
  end
  return string.find(failureType, categoryName, 1, true) ~= nil or string.find(failureType, "break", 1, true) ~= nil
end

local function refreshLastHardFailureTime()
  if not state or type(state.categories) ~= "table" then
    return
  end

  local latestTimestamp = 0
  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = state.categories[categoryName]
    if categoryState and isMaintenanceFailureType(categoryName, categoryState.lastFailureType) then
      latestTimestamp = max(latestTimestamp, tonumber(categoryState.lastFailureTime) or 0)
    end
  end

  state.lastHardFailureTime = latestTimestamp
end

local function getCategoryCandidatePartIds(categoryName)
  local candidatePartIds = {}
  local seen = {}

  local function addCandidate(partId)
    if not partId or seen[partId] then
      return
    end
    seen[partId] = true
    table.insert(candidatePartIds, partId)
  end

  local cache = categoryCache and categoryCache[categoryName] or nil
  local categoryState = state and state.categories and state.categories[categoryName] or nil
  addCandidate(cache and cache.rootPartId or nil)
  addCandidate(categoryState and categoryState.rootPartId or nil)

  for _, partId in ipairs(cache and cache.partIds or {}) do
    addCandidate(partId)
  end

  for _, partId in ipairs(categoryState and categoryState.cachedPartIds or {}) do
    addCandidate(partId)
  end

  return candidatePartIds
end

local function hasMaintenanceFailureState(categoryName, rootEntry, rootDevice)
  local deviceState = getPowertrainDeviceState(rootEntry, rootDevice)
  if type(deviceState) ~= "table" then
    return false
  end

  if categoryName == 'engine' then
    return deviceState.isBroken == true or type(deviceState.thermals) == "table" or deviceState.damageFrictionCoef ~= nil or
               deviceState.damageDynamicFrictionCoef ~= nil or deviceState.damageIdleAVReadErrorRangeCoef ~= nil
  elseif categoryName == 'radiator' then
    return deviceState.radiatorDamage ~= nil or deviceState.coolantMass ~= nil
  elseif categoryName == 'transmission' then
    return deviceState.isBroken == true or deviceState.damageGearRatioChangeRateCoef ~= nil or
               deviceState.damageClutchFreePlayCoef ~= nil or deviceState.damageLockTorqueCoef ~= nil or
               deviceState.damageFrictionCoef ~= nil or deviceState.synchroWear ~= nil or
               deviceState.clutchPermanentlyDamaged ~= nil
  end

  return false
end

local function sanitizeMaintenanceConditionEntry(rootEntry, hasMaintenanceMarker)
  if type(rootEntry) ~= "table" or not hasMaintenanceMarker then
    return false
  end

  local didSanitize = false
  local integrityValue = tonumber(rootEntry.integrityValue)
  if integrityValue ~= nil and integrityValue < 1 then
    rootEntry.integrityValue = 1
    didSanitize = true
  end

  if type(rootEntry.integrityState) == "table" and rootEntry.integrityState.powertrain then
    rootEntry.integrityState.powertrain = nil
    if not next(rootEntry.integrityState) then
      rootEntry.integrityState = nil
    end
    didSanitize = true
  end

  return didSanitize
end

local function sanitizeCategoryBreakage(partConditions, categoryName, clearFailureHistory)
  if not state or type(partConditions) ~= "table" then
    return false
  end

  local categoryState = state.categories and state.categories[categoryName] or nil
  if type(categoryState) ~= "table" then
    return false
  end
  if categoryState.persistentCareerDamage == true then
    return false
  end

  local rootDevice = getRootDeviceForCategory(categoryName)
  local didSanitize = false

  for _, partId in ipairs(getCategoryCandidatePartIds(categoryName)) do
    local rootEntry = partConditions[partId]
    local looksLikeOurFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                    hasMaintenanceFailureState(categoryName, rootEntry, rootDevice)

    if sanitizeMaintenanceConditionEntry(rootEntry, looksLikeOurFailure) then
      partConditions[partId] = rootEntry
      didSanitize = true
    end
  end

  if didSanitize or clearFailureHistory then
    categoryState.lastFailureType = nil
    categoryState.lastFailureTime = 0
  end

  return didSanitize
end

local function clearCategoryMaintenanceState(partConditions, categoryName, clearFailureHistory, ignorePersistentDamage)
  if not state or type(partConditions) ~= "table" then
    return false
  end

  local categoryState = state.categories and state.categories[categoryName] or nil
  if type(categoryState) ~= "table" then
    return false
  end
  if categoryState.persistentCareerDamage == true and not ignorePersistentDamage then
    return false
  end

  local rootDevice = getRootDeviceForCategory(categoryName)
  local didSanitize = false
  local didResetFlags = false

  for _, partId in ipairs(getCategoryCandidatePartIds(categoryName)) do
    local rootEntry = partConditions[partId]
    local hasPowertrainState = type(rootEntry) == "table" and type(rootEntry.integrityState) == "table" and
                                   rootEntry.integrityState.powertrain ~= nil
    local looksLikeOurFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                    hasMaintenanceFailureState(categoryName, rootEntry, rootDevice) or
                                    (ignorePersistentDamage and hasPowertrainState)

    if sanitizeMaintenanceConditionEntry(rootEntry, looksLikeOurFailure) then
      partConditions[partId] = rootEntry
      didSanitize = true
    end
  end

  if ignorePersistentDamage and (categoryState.persistentCareerDamage == true or categoryState.persistentDamageReason ~= nil) then
    categoryState.persistentCareerDamage = false
    categoryState.persistentDamageReason = nil
    didResetFlags = true
  end

  if didSanitize or clearFailureHistory then
    if categoryState.lastFailureType ~= nil or (categoryState.lastFailureTime or 0) ~= 0 then
      didResetFlags = true
    end
    categoryState.lastFailureType = nil
    categoryState.lastFailureTime = 0
  end

  return didSanitize or didResetFlags
end

local function clearMaintenanceBreakage()
  if not state then
    return false
  end

  local partConditions = getTrackedPartConditions()
  local didSanitize = false

  for _, categoryName in ipairs(categoryOrder) do
    didSanitize = sanitizeCategoryBreakage(partConditions, categoryName, false) or didSanitize
  end

  if didSanitize then
    syncPartConditions(partConditions)
    refreshLastHardFailureTime()
    dirtyState = true
  end

  return didSanitize
end

local function clearLiveMaintenanceFailureState(categoryName)
  local function shouldClear(targetCategoryName)
    if categoryName and targetCategoryName ~= categoryName then
      return false
    end
    local categoryState = state and state.categories and state.categories[targetCategoryName] or nil
    return not (type(categoryState) == "table" and categoryState.persistentCareerDamage == true)
  end

  if shouldClear('engine') and categoryModules.engine and categoryModules.engine.clearFailureRuntime then
    categoryModules.engine.clearFailureRuntime(deviceContexts.engine or {})
  end
  if shouldClear('radiator') and categoryModules.radiator and categoryModules.radiator.clearFailureRuntime then
    categoryModules.radiator.clearFailureRuntime(deviceContexts.radiator or {})
  end
  if shouldClear('transmission') and categoryModules.transmission and categoryModules.transmission.clearFailureRuntime then
    categoryModules.transmission.clearFailureRuntime(deviceContexts.transmission or {})
  end
end

local function resetCategoryStateForNewRoot(categoryName, partConditions, overallMileage)
  if not state or not state.categories or not categoryCache or not categoryCache[categoryName] then
    return false
  end

  local categoryState = state.categories[categoryName]
  local cache = categoryCache[categoryName]
  local newRootPartId = cache.rootPartId
  local oldRootPartId = categoryState.rootPartId

  if not newRootPartId or newRootPartId == oldRootPartId then
    return false
  end

  categoryState.maintenance = categoryModules[categoryName].getDefaultMaintenance()
  categoryState.avgOdometer = getAverageOdometer(cache.partIds, partConditions, overallMileage)
  categoryState.wearBand = "fresh"
  categoryState.lastFailureType = nil
  categoryState.lastFailureTime = 0
  categoryState.persistentCareerDamage = false
  categoryState.persistentDamageReason = nil
  categoryState.rootPartId = newRootPartId
  categoryState.cachedPartIds = common.deepCopy(cache.partIds or {})
  runtimeState[categoryName] = {}

  markStateDirty()
  return true
end

local function buildHardFailurePowertrainState(categoryName, reason)
  local powertrainState = {}

  if categoryName == 'engine' then
    local rootDevice = getRootDeviceForCategory(categoryName)
    if rootDevice and categoryModules.engine.getHardFailureState then
      powertrainState[rootDevice.name] = common.deepCopy(categoryModules.engine.getHardFailureState(reason))
    end
  elseif categoryName == 'radiator' then
    local rootDevice = getRootDeviceForCategory(categoryName)
    local entry = rootDevice and getDeviceEntryByName(deviceContexts.radiator.devices, rootDevice.name) or
                      deviceContexts.radiator.devices[1]
    if rootDevice and categoryModules.radiator.getHardFailureState then
      powertrainState[rootDevice.name] = common.deepCopy(categoryModules.radiator.getHardFailureState(entry and entry.base or nil))
    end
  elseif categoryName == 'transmission' then
    for _, entry in ipairs(deviceContexts.transmission.gearboxes or {}) do
      if entry.device and categoryModules.transmission.getHardFailureStateForDevice then
        powertrainState[entry.device.name] = common.deepCopy(categoryModules.transmission.getHardFailureStateForDevice(entry.device))
      end
    end
    for _, entry in ipairs(deviceContexts.transmission.clutches or {}) do
      if entry.device and categoryModules.transmission.getHardFailureStateForDevice then
        powertrainState[entry.device.name] = common.deepCopy(categoryModules.transmission.getHardFailureStateForDevice(entry.device))
      end
    end
  end

  return next(powertrainState) and powertrainState or nil
end

local function applyHardFailure(categoryName, options)
  if not state or not state.categories[categoryName] then
    return false
  end

  local cache = categoryCache and categoryCache[categoryName] or nil
  if not cache or not cache.rootPartId then
    return false
  end

  local partConditions = getTrackedPartConditions()
  local categoryState = state.categories[categoryName]
  local rootEntry = partConditions[cache.rootPartId] or {}
  local persistentCareerDamage = type(options) == "table" and options.persistentCareerDamage == true
  local persistentDamageReason = type(options) == "table" and options.reason or nil
  local powertrainState = buildHardFailurePowertrainState(categoryName, persistentDamageReason)

  rootEntry.odometer = tonumber(rootEntry.odometer) or tonumber(categoryState.avgOdometer) or tonumber(state.lastSyncMileage) or 0
  rootEntry.integrityValue = 0
  rootEntry.visualValue = rootEntry.visualValue or 1
  rootEntry.integrityState = type(rootEntry.integrityState) == "table" and rootEntry.integrityState or {}

  if powertrainState then
    rootEntry.integrityState.powertrain = powertrainState
  elseif not next(rootEntry.integrityState) then
    rootEntry.integrityState = nil
  end

  partConditions[cache.rootPartId] = rootEntry
  syncPartConditions(partConditions)

  runtimeState[categoryName] = {}
  categoryState.lastFailureTime = os.time()
  categoryState.lastFailureType = persistentCareerDamage and string.format("%s_lockup", categoryName) or
                                      string.format("%s_break", categoryName)
  categoryState.persistentCareerDamage = persistentCareerDamage
  categoryState.persistentDamageReason = persistentDamageReason
  refreshLastHardFailureTime()

  markStateDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
  return true
end

updateState = function(dt)
  if not state then
    return
  end

  local partConditions = getTrackedPartConditions()
  local previousProfileSignature = getSerializedSignature(state.profile)
  state.profile = buildLiveVehicleProfile(state.profile)
  if previousProfileSignature ~= getSerializedSignature(state.profile) then
    dirtyState = true
  end
  local environmentSnapshot = buildEnvironmentSnapshot(dt)
  local overallMileage = runtimeReadOnly and (tonumber(state.lastSyncMileage) or 0) or
                           getOverallMileage(partConditions)
  local previousOverallMileage = tonumber(state.lastSyncMileage) or overallMileage
  local drivenDeltaMiles = previousOverallMileage > 0 and max((overallMileage - previousOverallMileage) * common.metersToMiles, 0) or 0
  local pendingHardFailure = nil
  if abs((state.lastSyncMileage or 0) - overallMileage) > 0.0001 then
    dirtyState = true
  end
  state.lastSyncMileage = overallMileage

  local categoryOdometers = {}
  for _, categoryName in ipairs(categoryOrder) do
    local cache = categoryCache[categoryName]
    local categoryState = state.categories[categoryName]
    categoryOdometers[categoryName] = runtimeReadOnly and (tonumber(categoryState.avgOdometer) or overallMileage) or
                                        getAverageOdometer(cache.partIds, partConditions, overallMileage)
  end

  for _, categoryName in ipairs(categoryOrder) do
    local module = categoryModules[categoryName]
    local cache = categoryCache[categoryName]
    local categoryState = state.categories[categoryName]
    local previousFailureTime = categoryState.lastFailureTime
    local previousFailureType = categoryState.lastFailureType
    local previousWearBand = categoryState.wearBand
    local previousMaintenance = common.deepCopy(categoryState.maintenance)
    local previousPartCount = #(categoryState.cachedPartIds or {})
    local currentOdometer = categoryOdometers[categoryName]
    local deltaMiles = runtimeReadOnly and 0 or drivenDeltaMiles
    local avgMiles = getCategoryAgeMiles(categoryName, categoryOdometers)

    categoryState.avgOdometer = currentOdometer
    categoryState.rootPartId = cache and cache.rootPartId or nil
    categoryState.cachedPartIds = common.deepCopy(cache.partIds)
    -- a category with no parts has no hardware to wear out, and the player cannot
    -- service what the shop never shows them
    local hasHardware = cache and cache.partIds and #cache.partIds > 0
    local env = buildEnvironment(categoryName, avgMiles, environmentSnapshot)
    if not runtimeReadOnly and hasHardware then
      categoryState.maintenance = module.drainMaintenance(categoryState.maintenance, deltaMiles, avgMiles, env)
    end

    local runtimeCategory = runtimeState[categoryName]
    local derived = module.buildDerived(categoryState, env)
    derived.rpmFactor = env.rpmFactor
    derived.loadFactor = env.loadFactor
    derived.heatFactor = env.heatFactor
    derived.torqueNm = env.torqueNm
    derived.combustionTorque = env.combustionTorque
    derived.maxTorqueRating = env.maxTorqueRating
    derived.torqueFactor = env.torqueFactor
    derived.powerHp = env.powerHp
    derived.powerFactor = env.powerFactor
    derived.outputStressFactor = env.outputStressFactor
    derived.rpmCapacity = env.rpmCapacity
    derived.engineRunningSeconds = env.engineRunningSeconds
    derived.idleRuntimeSeconds = env.idleRuntimeSeconds
    derived.profile = common.deepCopy(env.profile)
    derived.pistonRingsDamaged = env.pistonRingsDamaged
    derived.coolantTemp = env.coolantTemp
    derived.oilTemp = env.oilTemp
    derived.oilHeatFactor = env.oilHeatFactor
    derived.oilOverheatFactor = env.oilOverheatFactor
    derived.isOverheating = env.isOverheating
    derived.overheatFactor = env.overheatFactor
    derived.hotRuntimeSeconds = env.hotRuntimeSeconds
    derived.overheatingRuntimeSeconds = env.overheatingRuntimeSeconds
    derived.totalHotRuntimeSeconds = env.totalHotRuntimeSeconds
    derived.totalOverheatingRuntimeSeconds = env.totalOverheatingRuntimeSeconds
    derived.warmupEvent = env.warmupEvent
    derived.cooldownEvent = env.cooldownEvent
    derived.warmupEventCount = env.warmupEventCount
    derived.cooldownEventCount = env.cooldownEventCount
    runtimeCategory.derived = derived
    categoryState.wearBand = derived.wear.bandName

    local categoryBroken = isCategoryBroken(categoryName, partConditions)
    if categoryBroken or not hasHardware then
      runtimeCategory.activeSymptom = nil
      runtimeCategory.symptomTimer = 0
      runtimeCategory.cooldownTimer = 0
    else
      module.stepRuntime(runtimeCategory, categoryState, derived, env, dt)
      local forcedHardFailureTarget = runtimeCategory.forceHardFailureTarget
      local canRollHardFailure = avgMiles >= (tonumber(module.minimumHardFailureMileage) or math.huge)
      if categoryName == 'engine' and not canRollHardFailure then
        canRollHardFailure = (derived.severeOilStarvation == true or derived.catastrophicOilStarvation == true) or
                                 ((derived.oilStarvationSeverity or 0) >= 0.3 and (derived.integritySeverity or 0) >= 0.25) or
                                 ((derived.oilConditionSeverity or 0) >= 0.28 and
                                     ((derived.loadFactor or 0) >= 0.65 or (derived.rpmFactor or 0) >= 0.65))
      end
      if type(forcedHardFailureTarget) == "string" then
        pendingHardFailure = pendingHardFailure or {
          categoryName = forcedHardFailureTarget,
          persistentCareerDamage = runtimeCategory.forceHardFailurePersistent == true,
          reason = runtimeCategory.forceHardFailureReason
        }
      elseif canRollHardFailure and common.rollChance(derived.hardFailureRate, dt) then
        pendingHardFailure = pendingHardFailure or {categoryName = categoryName}
      end
    end

    if hasHardware and not categoryBroken and not pendingHardFailure then
      if categoryName == 'engine' then
        module.apply(deviceContexts.engine, categoryState, runtimeCategory, runtimeCategory.derived)
      elseif categoryName == 'radiator' then
        module.apply(deviceContexts.radiator, categoryState, runtimeCategory, runtimeCategory.derived)
      else
        module.apply(deviceContexts.transmission, categoryState, runtimeCategory, runtimeCategory.derived)
      end
      if module.updateAudio then
        if categoryName == 'engine' then
          module.updateAudio(deviceContexts.engine, runtimeCategory, runtimeCategory.derived, dt)
        elseif categoryName == 'radiator' then
          module.updateAudio(deviceContexts.radiator, runtimeCategory, runtimeCategory.derived, dt)
        else
          module.updateAudio(deviceContexts.transmission, runtimeCategory, runtimeCategory.derived, dt)
        end
      end
    end

    if deltaMiles > 0 or previousWearBand ~= categoryState.wearBand or previousFailureType ~= categoryState.lastFailureType or
        previousFailureTime ~= categoryState.lastFailureTime or previousPartCount ~= #(categoryState.cachedPartIds or {}) or
        abs((previousAverageOdometer or 0) - (categoryState.avgOdometer or 0)) > 0.0001 or
        maintenanceChanged(previousMaintenance, categoryState.maintenance) then
      dirtyState = true
      markDebugStreamDirty()
    end
  end

  if pendingHardFailure then
    applyHardFailure(pendingHardFailure.categoryName, pendingHardFailure)
    return
  end
end

local function markDirty()
  markStateDirty()
end

local function initFromSave(snapshot, newInventoryId, readOnly)
  runtimeDisabled = false
  runtimeReadOnly = readOnly == true
  if runtimeReadOnly then
    inventoryId = nil
  else
    inventoryId = tonumber(newInventoryId) or inventoryId
  end
  state = normalizeState(snapshot)
  resetRuntimeState()
  clearTrackedPartConditions()
  rebuildCategoryCache()
  rebuildDeviceContexts()
  debugStreamCache = nil
  debugStreamTimer = 0
  markDebugStreamDirty()
  clearLiveMaintenanceFailureState()
  clearMaintenanceBreakage()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function refreshFromCurrentPartConditions()
  runtimeDisabled = false
  if not state then
    state = buildDefaultState()
  end
  clearTrackedPartConditions()
  local partConditions = getTrackedPartConditions()
  rebuildCategoryCache()
  rebuildDeviceContexts()
  debugStreamCache = nil
  markDebugStreamDirty()

  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = state.categories and state.categories[categoryName] or nil
    if type(categoryState) == "table" and categoryState.persistentCareerDamage == true and
        not isCategoryBroken(categoryName, partConditions) then
      categoryState.persistentCareerDamage = false
      categoryState.persistentDamageReason = nil
      categoryState.lastFailureType = nil
      categoryState.lastFailureTime = 0
      markStateDirty()
    end
  end

  clearLiveMaintenanceFailureState()
  clearMaintenanceBreakage()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function clearForDisabledSave(newInventoryId)
  inventoryId = tonumber(newInventoryId) or inventoryId
  runtimeDisabled = true
  runtimeReadOnly = false
  state = buildDefaultState()
  resetRuntimeState()
  clearTrackedPartConditions()
  rebuildCategoryCache()
  rebuildDeviceContexts()
  updateTimer = 0
  syncTimer = 0
  debugStreamTimer = 0
  debugStreamCache = nil
  markDebugStreamDirty()

  local partConditions = getTrackedPartConditions()
  local overallMileage = getOverallMileage(partConditions)
  local didSanitize = false

  for _, categoryName in ipairs(categoryOrder) do
    local categoryState = state.categories and state.categories[categoryName] or nil
    local cache = categoryCache and categoryCache[categoryName] or nil
    if categoryState and cache then
      categoryState.rootPartId = cache.rootPartId
      categoryState.cachedPartIds = common.deepCopy(cache.partIds or {})
      categoryState.avgOdometer = getAverageOdometer(cache.partIds, partConditions, overallMileage)
    end

    didSanitize = clearCategoryMaintenanceState(partConditions, categoryName, true, true) or didSanitize
  end

  clearLiveMaintenanceFailureState()
  refreshLastHardFailureTime()
  if didSanitize then
    syncPartConditions(partConditions)
  end
  dirtyState = false
  sendDisabledStateToGE()
  sendDebugStream(true)
end

local function getSnapshot()
  return buildSnapshot()
end

local function setPartIdsMileage(partConditions, partIds, targetMiles)
  local targetMeters = max(tonumber(targetMiles) or 0, 0) * common.milesToMeters
  for _, partId in ipairs(partIds or {}) do
    local entry = partConditions[partId] or {odometer = 0, integrityValue = 1, visualValue = 1}
    entry.odometer = targetMeters
    entry.integrityValue = entry.integrityValue or 1
    entry.visualValue = entry.visualValue or 1
    partConditions[partId] = entry
  end
end

local function debugSetMaintenance(categoryName, itemName, value)
  if not state or not state.categories[categoryName] then
    return
  end

  local maintenance = state.categories[categoryName].maintenance
  value = common.clamp(tonumber(value) or 1, 0, 1)
  if itemName and maintenance[itemName] ~= nil then
    maintenance[itemName] = value
  else
    for maintenanceItem in pairs(maintenance) do
      maintenance[maintenanceItem] = value
    end
  end

  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugSetCategoryMileage(categoryName, targetMiles)
  if not state or not categoryCache[categoryName] then
    return
  end

  local partConditions = getTrackedPartConditions()
  setPartIdsMileage(partConditions, categoryCache[categoryName].partIds or {}, targetMiles)
  syncPartConditions(partConditions)
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugSetScenario(configTable)
  runtimeState.debug = runtimeState.debug or {}
  local baseInputs = ensureScenarioInputs(buildEnvironmentSnapshot(0))
  local mergedInputs = baseInputs
  local presetId = nil

  if type(configTable) ~= "table" then
    return
  end

  if type(configTable.presetId) == "string" then
    local preset = getScenarioPresetDefinition(configTable.presetId)
    if preset and type(preset.inputs) == "table" then
      mergedInputs = mergeScenarioInputs(mergedInputs, preset.inputs)
      presetId = preset.id
    end
  end

  if type(configTable.inputs) == "table" then
    mergedInputs = mergeScenarioInputs(mergedInputs, configTable.inputs)
  else
    local directInputs = common.deepCopy(configTable)
    directInputs.presetId = nil
    mergedInputs = mergeScenarioInputs(mergedInputs, directInputs)
  end

  runtimeState.debug.scenarioPresetId = presetId
  runtimeState.debug.scenarioInputs = normalizeScenarioInputs(mergedInputs)
  runtimeState.debug.scenarioUpdatedAt = os.time()
  markDebugStreamDirty()
  sendDebugStream(true)
end

local function debugApplyScenario()
  if not state then
    return
  end

  local inputs = ensureScenarioInputs(buildEnvironmentSnapshot(0))
  local partConditions = getTrackedPartConditions()
  local allPartIds = {}
  local seen = {}

  for _, categoryName in ipairs(categoryOrder) do
    for _, partId in ipairs(categoryCache[categoryName] and categoryCache[categoryName].partIds or {}) do
      if not seen[partId] then
        seen[partId] = true
        table.insert(allPartIds, partId)
      end
    end

    if state.categories[categoryName] and inputs.maintenance and inputs.maintenance[categoryName] then
      state.categories[categoryName].maintenance = common.deepCopy(inputs.maintenance[categoryName])
    end
  end

  setPartIdsMileage(partConditions, allPartIds, inputs.avgMiles)
  syncPartConditions(partConditions)
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugAdjustMaintenance(categoryName, itemName, delta)
  if not state or not state.categories[categoryName] then
    return
  end
  local maintenance = state.categories[categoryName].maintenance
  delta = tonumber(delta) or 0
  if itemName and maintenance[itemName] ~= nil then
    maintenance[itemName] = common.clamp((maintenance[itemName] or 1) + delta, 0, 1)
  else
    for maintenanceItem, value in pairs(maintenance) do
      maintenance[maintenanceItem] = common.clamp((value or 1) + delta, 0, 1)
    end
  end
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugAdjustMileage(categoryName, miles)
  if not state or not categoryCache[categoryName] then
    return
  end
  local deltaMeters = (tonumber(miles) or 0) * common.milesToMeters
  local partConditions = getTrackedPartConditions()
  for _, partId in ipairs(categoryCache[categoryName].partIds or {}) do
    local entry = partConditions[partId] or {odometer = 0, integrityValue = 1, visualValue = 1}
    entry.odometer = max((tonumber(entry.odometer) or 0) + deltaMeters, 0)
    entry.integrityValue = entry.integrityValue or 1
    entry.visualValue = entry.visualValue or 1
    partConditions[partId] = entry
  end
  syncPartConditions(partConditions)
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugForceFailure(categoryName, mode)
  if not runtimeState or not runtimeState[categoryName] then
    return
  end
  mode = mode or "symptom"
  if mode == "hard" then
    applyHardFailure(categoryName)
    return
  end
  if categoryName == 'engine' then
    runtimeState[categoryName].activeSymptom = 'powerFade'
  elseif categoryName == 'radiator' then
    runtimeState[categoryName].activeSymptom = 'coolantSeep'
  else
    runtimeState[categoryName].activeSymptom = 'slip'
  end
  runtimeState[categoryName].symptomTimer = 8
  runtimeState[categoryName].cooldownTimer = 16
  state.categories[categoryName].lastFailureTime = os.time()
  state.categories[categoryName].lastFailureType = runtimeState[categoryName].activeSymptom
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function serviceCategory(categoryName)
  if not state or not state.categories[categoryName] then
    return
  end

  local partConditions = getTrackedPartConditions()
  if clearCategoryMaintenanceState(partConditions, categoryName, true, true) then
    syncPartConditions(partConditions)
  end

  state.categories[categoryName].maintenance = categoryModules[categoryName].getDefaultMaintenance()
  runtimeState[categoryName] = {}
  clearLiveMaintenanceFailureState(categoryName)
  refreshLastHardFailureTime()
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function debugResetCategory(categoryName)
  if not state or not state.categories[categoryName] then
    return
  end

  local partConditions = getTrackedPartConditions()
  if clearCategoryMaintenanceState(partConditions, categoryName, true, true) then
    syncPartConditions(partConditions)
  end

  state.categories[categoryName].maintenance = categoryModules[categoryName].getDefaultMaintenance()
  runtimeState[categoryName] = {}
  clearLiveMaintenanceFailureState(categoryName)
  refreshLastHardFailureTime()
  markDirty()
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function refreshParts()
  if not state then
    return
  end
  local partConditions = getTrackedPartConditions()
  local overallMileage = getOverallMileage(partConditions)
  rebuildCategoryCache()
  rebuildDeviceContexts()
  local didResetCategory = false
  for _, categoryName in ipairs(categoryOrder) do
    didResetCategory = resetCategoryStateForNewRoot(categoryName, partConditions, overallMileage) or didResetCategory
  end
  clearTrackedPartConditions()
  debugStreamCache = nil
  markDebugStreamDirty()
  clearLiveMaintenanceFailureState()
  clearMaintenanceBreakage()
  if didResetCategory then
    refreshLastHardFailureTime()
  end
  updateState(0)
  sendDebugStream(true)
  sendStateToGE()
end

local function onExtensionLoaded()
  state = buildDefaultState()
  resetRuntimeState()
  clearTrackedPartConditions()
  rebuildCategoryCache()
  rebuildDeviceContexts()
  debugStreamCache = nil
  markDebugStreamDirty()
end

local function onReset()
  if runtimeDisabled then
    clearForDisabledSave(inventoryId)
    return
  end

  resetRuntimeState()
  clearTrackedPartConditions()
  rebuildCategoryCache()
  rebuildDeviceContexts()
  updateTimer = 0
  syncTimer = 0
  debugStreamTimer = 0
  debugStreamCache = nil
  markDebugStreamDirty()
  if state then
    updateState(0)
    sendDebugStream(true)
  end
end

local function updateGFX(dt)
  if runtimeDisabled or not state then
    return
  end

  updateTimer = updateTimer + dt
  syncTimer = syncTimer + dt

  if updateTimer >= 0.5 then
    updateState(updateTimer)
    updateTimer = 0
  end

  if dirtyState and syncTimer >= 2 then
    sendStateToGE()
    dirtyState = false
    syncTimer = 0
  end

  debugStreamTimer = debugStreamTimer + dt
  if debugStreamTimer >= debugStreamInterval then
    sendDebugStream(false)
    debugStreamTimer = 0
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

M.initFromSave = initFromSave
M.refreshFromCurrentPartConditions = refreshFromCurrentPartConditions
M.clearForDisabledSave = clearForDisabledSave
M.getSnapshot = getSnapshot
M.refreshParts = refreshParts
M.debugAdjustMileage = debugAdjustMileage
M.debugSetCategoryMileage = debugSetCategoryMileage
M.debugAdjustMaintenance = debugAdjustMaintenance
M.debugSetMaintenance = debugSetMaintenance
M.debugForceFailure = debugForceFailure
M.debugSetScenario = debugSetScenario
M.debugApplyScenario = debugApplyScenario
M.serviceCategory = serviceCategory
M.debugResetCategory = debugResetCategory

return M
