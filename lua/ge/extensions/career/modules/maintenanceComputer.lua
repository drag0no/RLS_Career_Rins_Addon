local M = {}

M.dependencies = {
  'career_career',
  'career_modules_business_businessInventory',
  'career_modules_business_businessManager',
  'career_modules_maintenanceMode',
  'career_modules_payment',
  'career_modules_tireSystem',
  'career_modules_valueCalculator',
  'career_saveSystem',
}

local config = require('ge/extensions/career/modules/maintenanceComputerConfig')

local floor = math.floor
local max = math.max
local metersToMiles = 1 / 1609.344

local originComputerId
local activeInventoryId
local returnRoute = nil

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

local function roundMoney(amount)
  return floor((tonumber(amount) or 0) * 100 + 0.5) / 100
end

local function roundWholeMoney(amount)
  return floor((tonumber(amount) or 0) + 0.5)
end

local function roundPercent(value)
  return floor((max(0, math.min(1, tonumber(value) or 0)) * 100) + 0.5)
end

local function isMaintenanceEnabled()
  return career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled and
             career_modules_maintenanceMode.isEnabled() == true
end

local function getVehicleData(inventoryId)
  if not career_modules_inventory or not career_modules_inventory.getVehicle then
    return nil
  end
  return career_modules_inventory.getVehicle(tonumber(inventoryId))
end

local function getBusinessVehicleData(businessId, vehicleId)
  return career_modules_business_businessInventory and career_modules_business_businessInventory.getVehicleById and
           career_modules_business_businessInventory.getVehicleById(businessId, vehicleId) or nil
end

local function markVehicleDirty(inventoryId)
  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(tonumber(inventoryId))
  end
end

local function persistVehicleMutation(inventoryId)
  markVehicleDirty(inventoryId)
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

local function ensureMaintenanceComputerState(vehicleData)
  local changed = false
  if type(vehicleData.maintenanceComputerState) ~= "table" then
    vehicleData.maintenanceComputerState = {}
    changed = true
  end

  local state = vehicleData.maintenanceComputerState
  if type(state.revealed) ~= "table" then
    state.revealed = {}
    changed = true
  end
  if type(state.jobs) ~= "table" then
    state.jobs = {}
    changed = true
  end

  for _, categoryName in ipairs(config.categoryOrder) do
    if type(state.revealed[categoryName]) ~= "table" then
      state.revealed[categoryName] = {}
      changed = true
    end
  end

  return state, changed
end

local function normalizeVehicleMaintenanceState(vehicleData)
  local normalized = config.normalizeSnapshot(vehicleData.maintenanceState, vehicleData)
  local changed = false

  local currentSignature = type(serialize) == "function" and serialize(vehicleData.maintenanceState) or nil
  local nextSignature = type(serialize) == "function" and serialize(normalized) or nil
  if currentSignature ~= nextSignature then
    vehicleData.maintenanceState = normalized
    changed = true
  elseif vehicleData.maintenanceState ~= normalized then
    vehicleData.maintenanceState = normalized
  end

  return vehicleData.maintenanceState, changed
end

local function matchesKeywords(partInfo, keywords)
  local haystacks = {
    string.lower(partInfo.partId or ""),
    string.lower(partInfo.partName or ""),
    string.lower(partInfo.slotPath or ""),
  }

  for _, keyword in ipairs(keywords or {}) do
    local lowerKeyword = string.lower(keyword)
    for _, haystack in ipairs(haystacks) do
      if string.find(haystack, lowerKeyword, 1, true) then
        return true
      end
    end
  end

  return false
end

local function containsAnyKeyword(text, keywords)
  if text == "" then
    return false
  end
  for _, keyword in ipairs(keywords or {}) do
    if string.find(text, string.lower(keyword), 1, true) then
      return true
    end
  end
  return false
end

local function getImmediateSlotName(path)
  return string.lower(tostring(path or ""):match("([^/]+)/?$") or "")
end

local function endsWithKeywordToken(text, keyword)
  text = string.lower(tostring(text or ""))
  keyword = string.lower(tostring(keyword or ""))
  if keyword == "" or #text < #keyword or text:sub(-#keyword) ~= keyword then
    return false
  end

  local prefixLength = #text - #keyword
  return prefixLength == 0 or not text:sub(prefixLength, prefixLength):match("[%w]")
end

local function matchesInstalledHardware(categoryDefinition, partName, slotName)
  local excludeKeywords = categoryDefinition.installedExcludeKeywords
  local lowerPartName = string.lower(tostring(partName or ""))
  local lowerSlotName = string.lower(tostring(slotName or ""))
  local haystacks = {lowerPartName, lowerSlotName}

  for _, haystack in ipairs(haystacks) do
    if containsAnyKeyword(haystack, categoryDefinition.installedKeywords) and
       not containsAnyKeyword(haystack, excludeKeywords) then
      return true, haystack
    end
  end

  if not containsAnyKeyword(lowerSlotName, excludeKeywords) then
    for _, suffix in ipairs(categoryDefinition.installedSlotSuffixes or {}) do
      if endsWithKeywordToken(lowerSlotName, suffix) then
        return true, lowerSlotName
      end
    end
  end

  return false
end

local function categoryHardwareIsInstalled(vehicleData, categoryName)
  local categoryDefinition = config.categoryDefinitions[categoryName]
  local installedKeywords = categoryDefinition and categoryDefinition.installedKeywords
  if not installedKeywords then
    return true
  end

  local found = false
  local foundMatch = nil

  local function walkNode(node, currentPath)
    if found or type(node) ~= "table" then
      return
    end

    currentPath = currentPath or "/"
    local nodePath = node.path or currentPath
    local chosenPartName = node.chosenPartName
    if type(chosenPartName) == "string" and chosenPartName ~= "" then
      local lowerSlotName = getImmediateSlotName(nodePath)
      local matched, haystack = matchesInstalledHardware(categoryDefinition, chosenPartName, lowerSlotName)
      if matched then
        found = true
        foundMatch = {
          source = "partsTree",
          partName = chosenPartName,
          slotName = lowerSlotName,
          path = nodePath,
          haystack = haystack,
        }
        return
      end
    end

    for slotName, child in pairs(node.children or {}) do
      walkNode(child, (nodePath or currentPath) .. tostring(slotName) .. "/")
    end
  end

  local partsTree = vehicleData and vehicleData.config and vehicleData.config.partsTree
  if type(partsTree) == "table" and next(partsTree) ~= nil then
    walkNode(partsTree, "/")
  else
    local flatParts = vehicleData and vehicleData.config and vehicleData.config.parts
    if type(flatParts) == "table" then
      for slotName, chosenPartName in pairs(flatParts) do
        if type(chosenPartName) == "string" and chosenPartName ~= "" then
          local immediateSlotName = getImmediateSlotName(slotName)
          local matched, haystack = matchesInstalledHardware(categoryDefinition, chosenPartName, immediateSlotName)
          if matched then
            found = true
            foundMatch = {
              source = "parts",
              partName = chosenPartName,
              slotName = immediateSlotName,
              path = slotName,
              haystack = haystack,
            }
            break
          end
        end
      end
    end
  end

  if log and foundMatch then
    log("D", "maintenanceComputer", string.format("categoryHardwareIsInstalled(%s) = true via %s: partName=%s slotName=%s path=%s haystack=%s",
      categoryName, tostring(foundMatch.source), tostring(foundMatch.partName), tostring(foundMatch.slotName),
      tostring(foundMatch.path), tostring(foundMatch.haystack)))
  end

  return found
end

local function buildPartClassification(vehicleData)
  local categories = {}
  local partInfosById = {}
  for _, categoryName in ipairs(config.categoryOrder) do
    categories[categoryName] = {}
  end

  local function addPart(categoryName, partInfo)
    categories[categoryName][partInfo.partId] = partInfo
  end

  local function classifyPart(partInfo)
    if matchesKeywords(partInfo, config.categoryDefinitions.radiator.keywords) then
      addPart("radiator", partInfo)
    elseif matchesKeywords(partInfo, config.categoryDefinitions.transmission.keywords) then
      addPart("transmission", partInfo)
    elseif matchesKeywords(partInfo, config.categoryDefinitions.engine.keywords) then
      addPart("engine", partInfo)
    end
  end

  local function walkNode(node, currentPath)
    if type(node) ~= "table" then
      return
    end

    currentPath = currentPath or "/"
    local nodePath = node.path or currentPath
    local chosenPartName = node.chosenPartName
    if type(chosenPartName) == "string" and chosenPartName ~= "" then
      local partId = node.partPath or (nodePath .. chosenPartName)
      local partInfo = {
        partId = partId,
        partName = chosenPartName,
        slotPath = partId:match("^(.*[/])[^/]+$") or "/",
        treePath = node.path or currentPath,
      }
      partInfosById[partId] = partInfo
      classifyPart(partInfo)
    end

    local childKeys = {}
    for slotName in pairs(node.children or {}) do
      table.insert(childKeys, slotName)
    end
    table.sort(childKeys)
    for _, slotName in ipairs(childKeys) do
      walkNode(node.children[slotName], (nodePath or currentPath) .. tostring(slotName) .. "/")
    end
  end

  if type(vehicleData.config) == "table" and type(vehicleData.config.partsTree) == "table" then
    walkNode(vehicleData.config.partsTree, "/")
  end

  local orderedCategoryParts = {}
  for _, categoryName in ipairs(config.categoryOrder) do
    orderedCategoryParts[categoryName] = {}
    for partId in pairs(categories[categoryName]) do
      table.insert(orderedCategoryParts[categoryName], partId)
    end
    table.sort(orderedCategoryParts[categoryName])
  end

  return orderedCategoryParts, partInfosById
end

local function listsEqual(a, b)
  if #a ~= #b then
    return false
  end
  for index = 1, #a do
    if a[index] ~= b[index] then
      return false
    end
  end
  return true
end

local function getTrackedPartData(vehicleData, maintenanceState)
  local rebuiltPartIdsByCategory, partInfosById = buildPartClassification(vehicleData)
  local changed = false
  local trackedPartIdsByCategory = {}

  for _, categoryName in ipairs(config.categoryOrder) do
    local categoryState = maintenanceState.categories[categoryName]
    local validSet = {}
    for _, rebuiltPartId in ipairs(rebuiltPartIdsByCategory[categoryName] or {}) do
      validSet[rebuiltPartId] = true
    end

    local primaryPartIds = {}
    local seen = {}
    local function tryAdd(partId)
      if partId and validSet[partId] and not seen[partId] then
        seen[partId] = true
        table.insert(primaryPartIds, partId)
      end
    end

    for _, cachedPartId in ipairs(categoryState.cachedPartIds or {}) do
      tryAdd(cachedPartId)
    end
    tryAdd(categoryState.rootPartId)
    table.sort(primaryPartIds)

    if #primaryPartIds == 0 then
      primaryPartIds = deepCopy(rebuiltPartIdsByCategory[categoryName] or {})
      table.sort(primaryPartIds)
    end

    trackedPartIdsByCategory[categoryName] = primaryPartIds

    if not listsEqual(categoryState.cachedPartIds or {}, primaryPartIds) then
      categoryState.cachedPartIds = deepCopy(primaryPartIds)
      changed = true
    end

    local nextRootPartId = categoryState.rootPartId
    if not nextRootPartId or not seen[nextRootPartId] then
      nextRootPartId = primaryPartIds[1]
    end
    if categoryState.rootPartId ~= nextRootPartId then
      categoryState.rootPartId = nextRootPartId
      changed = true
    end
  end

  return trackedPartIdsByCategory, partInfosById, changed
end

local function getFallbackPartValue(vehicleData, partId, partInfo)
  local baseValue = 700
  local activeParts = vehicleData.vdata and vehicleData.vdata.activeParts or nil
  local activePartsData = vehicleData.vdata and vehicleData.vdata.activePartsData or nil
  local activePartIdx = activeParts and activeParts[partId] or nil
  if activePartIdx and activePartsData and activePartsData[activePartIdx] and activePartsData[activePartIdx].information then
    baseValue = activePartsData[activePartIdx].information.value or baseValue
  end

  return {
    name = partInfo and partInfo.partName or partId,
    value = baseValue,
    partCondition = vehicleData.partConditions and vehicleData.partConditions[partId] or nil,
    vehicleModel = vehicleData.model,
  }
end

local function calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
  local trackedPartIdsByCategory, partInfosById, cacheChanged = getTrackedPartData(vehicleData, maintenanceState)
  local trackedPartIds = trackedPartIdsByCategory[categoryName] or {}
  local totalValue = 0

  for _, partId in ipairs(trackedPartIds) do
    local partCondition = vehicleData.partConditions and vehicleData.partConditions[partId] or nil
    if partCondition then
      local partInfo = partInfosById[partId]
      local part = nil
      local isBusinessRecord = vehicleData.vehicleId ~= nil and vehicleData.id == nil
      if not isBusinessRecord and career_modules_partInventory and career_modules_partInventory.getPart and
         partInfo and partInfo.treePath then
        part = career_modules_partInventory.getPart(vehicleData.id, partInfo.treePath)
      end
      part = deepCopy(part or getFallbackPartValue(vehicleData, partId, partInfo))
      part.partCondition = partCondition
      part.vehicleModel = vehicleData.model
      local partValue = 0
      if career_modules_valueCalculator and career_modules_valueCalculator.getPartValue then
        local success, result = pcall(career_modules_valueCalculator.getPartValue, part, true)
        if success then
          partValue = tonumber(result) or 0
        else
          partValue = tonumber(part.value) or 0
          if log then
            log("W", "maintenanceComputer", string.format("Failed to value maintenance part '%s': %s", tostring(partId), tostring(result)))
          end
        end
      end
      totalValue = totalValue + partValue
    end
  end

  return roundMoney(totalValue), trackedPartIds, cacheChanged
end

local function roundServicePrice(amount)
  amount = max(tonumber(amount) or 0, 0)
  local increment = amount < 500 and 5 or 10
  return floor(amount / increment + 0.5) * increment
end

local function calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
  local profile = maintenanceState and maintenanceState.profile or {}
  local capacities = type(profile.capacities) == "table" and profile.capacities or {}
  local itemName = itemDefinition and itemDefinition.name or ""
  local currentValue = maintenanceState and maintenanceState.categories and maintenanceState.categories[categoryName] and
                           maintenanceState.categories[categoryName].maintenance[itemName] or 1
  local powerHp = tonumber(profile.powerHp) or tonumber(vehicleData and vehicleData.certifications and vehicleData.certifications.power) or 0
  if powerHp > 10000 then
    powerHp = powerHp / 745.7
  end
  local gradeMultiplier = (profile.isDiesel == true or profile.fuelType == "diesel" or powerHp >= 700) and 1.25 or 1
  if powerHp >= 3000 then
    gradeMultiplier = 2
  elseif powerHp >= 1500 then
    gradeMultiplier = 1.5
  end

  local labor, filter, materialRate, fluidLiters = 0, 0, 0, 0
  if itemName == "oilLevel" then
    labor, materialRate = 15, 11
    fluidLiters = max(tonumber(capacities.oil) or 4, 0) * (1 - max(0, math.min(1, tonumber(currentValue) or 0)))
  elseif itemName == "oilCondition" then
    labor, filter, materialRate, fluidLiters = 75, 25, 11, max(tonumber(capacities.oil) or 4, 0)
  elseif itemName == "coolantLevel" then
    labor, materialRate = 15, 8
    fluidLiters = max(tonumber(capacities.coolant) or 5, 0) * (1 - max(0, math.min(1, tonumber(currentValue) or 0)))
  elseif itemName == "coolantIntegrity" then
    labor, materialRate, fluidLiters = 85, 13, max(tonumber(capacities.coolant) or 5, 0)
  elseif itemName == "fluidLevel" then
    labor, materialRate = 25, 16
    fluidLiters = max(tonumber(capacities.transmission) or 6, 0) * (1 - max(0, math.min(1, tonumber(currentValue) or 0)))
  elseif itemName == "fluidCondition" then
    labor, filter, materialRate, fluidLiters = 105, 50, 16, max(tonumber(capacities.transmission) or 6, 0)
  else
    local rawFallback = (tonumber(trackedPartsValue) or 0) * ((tonumber(itemDefinition and itemDefinition.servicePricePct) or 0) / 100)
    local floorPrice = tonumber(itemDefinition and itemDefinition.servicePriceFloor) or 0
    return max(floorPrice, roundWholeMoney(rawFallback)), {legacy = true}
  end

  local complexity = 0
  local trackedValue = max(tonumber(trackedPartsValue) or 0, 0)
  if itemName == "oilCondition" then
    complexity = math.min(max(trackedValue - 10000, 0) * 0.005, 250)
  elseif itemName == "coolantIntegrity" then
    complexity = math.min(max(trackedValue - 5000, 0) * 0.005, 200)
  elseif itemName == "fluidCondition" then
    complexity = math.min(max(trackedValue - 8000, 0) * 0.0075, 350)
  end
  local material = fluidLiters * materialRate * gradeMultiplier
  local rawPrice = labor + filter + material + complexity
  return roundServicePrice(rawPrice), {
    labor = roundMoney(labor),
    filter = roundMoney(filter),
    material = roundMoney(material),
    materialRate = materialRate,
    fluidLiters = roundMoney(fluidLiters),
    gradeMultiplier = gradeMultiplier,
    complexity = roundMoney(complexity),
    rawPrice = roundMoney(rawPrice),
  }
end

local function invalidateRevealedState(uiState, maintenanceState)
  local changed = false
  for _, categoryName in ipairs(config.categoryOrder) do
    local categoryRevealed = uiState.revealed[categoryName] or {}
    local maintenance = maintenanceState.categories[categoryName].maintenance
    for _, itemDefinition in ipairs(config.categoryDefinitions[categoryName].items) do
      local revealedState = categoryRevealed[itemDefinition.name]
      if type(revealedState) == "table" then
        local currentRoundedPercent = roundPercent(maintenance[itemDefinition.name] or 0)
        if tonumber(revealedState.roundedPercent) ~= currentRoundedPercent then
          categoryRevealed[itemDefinition.name] = nil
          changed = true
        end
      end
    end
    uiState.revealed[categoryName] = categoryRevealed
  end
  return changed
end

local function syncRuntimeState(inventoryId)
  if vehicleMaintenance and vehicleMaintenance.syncVehicleMaintenance then
    vehicleMaintenance.syncVehicleMaintenance(tonumber(inventoryId))
  end
end

local function syncDriveLock(inventoryId)
  if vehicleMaintenance and vehicleMaintenance.syncMaintenanceDriveLock then
    vehicleMaintenance.syncMaintenanceDriveLock(tonumber(inventoryId))
  end
end

local function revealMaintenanceItem(uiState, categoryName, itemName, roundedPercent)
  local categoryRevealed = uiState.revealed[categoryName]
  if type(categoryRevealed) ~= "table" then
    categoryRevealed = {}
    uiState.revealed[categoryName] = categoryRevealed
  end

  categoryRevealed[itemName] = {roundedPercent = tonumber(roundedPercent) or 100}
end

local function completeServiceJob(uiState, categoryState, job, itemDefinition)
  categoryState.maintenance[job.item] = 1
  revealMaintenanceItem(uiState, job.category, job.item, 100)

  local filledItemName = itemDefinition and itemDefinition.fillsItem or nil
  if filledItemName and categoryState.maintenance[filledItemName] ~= nil then
    categoryState.maintenance[filledItemName] = 1
    revealMaintenanceItem(uiState, job.category, filledItemName, 100)
  end
end

-- Maintenance checks and services used to be timed jobs. Existing service jobs
-- were paid for when they were queued, so complete every legacy job once during
-- normalization rather than making a player wait or charging them again.
local function migrateLegacyJobs(vehicleData, maintenanceState, uiState, runtimeInventoryId)
  local changed = false
  local didService = false

  local sortedJobKeys = {}
  for jobKey in pairs(uiState.jobs or {}) do
    table.insert(sortedJobKeys, jobKey)
  end
  table.sort(sortedJobKeys)

  for _, jobKey in ipairs(sortedJobKeys) do
    local job = uiState.jobs[jobKey]
    local definition = job and config.getItemDefinition(job.category, job.item) or nil
    local categoryState = job and maintenanceState.categories[job.category] or nil
    if type(job) == "table" and definition and categoryState then
      if job.kind == "service" then
        completeServiceJob(uiState, categoryState, job, definition)
        didService = true
      else
        revealMaintenanceItem(uiState, job.category, job.item, roundPercent(categoryState.maintenance[job.item] or 0))
      end
    end
    uiState.jobs[jobKey] = nil
    changed = true
  end

  if changed and didService then
    if runtimeInventoryId then syncRuntimeState(runtimeInventoryId) end
  end

  if changed then
    if runtimeInventoryId then syncDriveLock(runtimeInventoryId) end
  end

  return changed
end

local function prepareVehicleState(inventoryId, options)
  options = options or {}
  local vehicleData = getVehicleData(inventoryId)
  if not vehicleData then
    return nil
  end

  local maintenanceState, maintenanceChanged = normalizeVehicleMaintenanceState(vehicleData)
  local uiState, uiChanged = ensureMaintenanceComputerState(vehicleData)
  local cacheChanged = false
  local trackedPartIdsByCategory

  uiChanged = invalidateRevealedState(uiState, maintenanceState) or uiChanged
  local jobsChanged = migrateLegacyJobs(vehicleData, maintenanceState, uiState, inventoryId)
  trackedPartIdsByCategory, _, cacheChanged = getTrackedPartData(vehicleData, maintenanceState)

  if maintenanceChanged or uiChanged or jobsChanged or cacheChanged then
    if options.persistChanges == false then
      if jobsChanged and options.persistCompletedJobs ~= false then
        persistVehicleMutation(vehicleData.id)
      elseif options.markDirtyOnChange ~= false then
        markVehicleDirty(vehicleData.id)
      end
    else
      persistVehicleMutation(vehicleData.id)
    end
  end

  return vehicleData, maintenanceState, uiState, trackedPartIdsByCategory
end

local function prepareBusinessVehicleState(businessId, vehicleId)
  local vehicleData = getBusinessVehicleData(businessId, vehicleId)
  if not vehicleData then return nil end
  local maintenanceState, maintenanceChanged = normalizeVehicleMaintenanceState(vehicleData)
  local uiState, uiChanged = ensureMaintenanceComputerState(vehicleData)
  uiChanged = invalidateRevealedState(uiState, maintenanceState) or uiChanged
  local jobsChanged = migrateLegacyJobs(vehicleData, maintenanceState, uiState, nil)
  local _, _, cacheChanged = getTrackedPartData(vehicleData, maintenanceState)
  if maintenanceChanged or uiChanged or jobsChanged or cacheChanged then
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  end
  return vehicleData, maintenanceState, uiState
end

local function getPlayerMoney()
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    return career_modules_playerAttributes.getAttributeValue("money") or 0
  end
  return 0
end

local function buildFacilityName()
  if originComputerId and freeroam_facilities and freeroam_facilities.getFacility then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    return computer and computer.name or "Maintenance"
  end
  return "Maintenance"
end

local function buildUiRow(vehicleData, maintenanceState, uiState, categoryName, itemDefinition)
  local itemValue = maintenanceState.categories[categoryName].maintenance[itemDefinition.name] or 0
  local roundedValue = roundPercent(itemValue)
  local revealedState = uiState.revealed[categoryName][itemDefinition.name]
  local trackedPartsValue, trackedPartIds = calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
  local servicePrice, pricingBreakdown = calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
  local canAffordService = true

  if servicePrice > 0 and career_modules_payment and career_modules_payment.canPay then
    canAffordService = career_modules_payment.canPay({money = {amount = servicePrice, canBeNegative = false}})
  end

  return {
    category = categoryName,
    item = itemDefinition.name,
    label = itemDefinition.label,
    actionLabel = itemDefinition.actionLabel,
    roundedPercent = roundedValue,
    revealedPercent = type(revealedState) == "table" and tonumber(revealedState.roundedPercent) or nil,
    isRevealed = type(revealedState) == "table",
    servicePricePct = itemDefinition.servicePricePct,
    servicePrice = servicePrice,
    pricingBreakdown = pricingBreakdown,
    canAffordService = canAffordService,
    fillsItem = itemDefinition.fillsItem,
    trackedPartsValue = trackedPartsValue,
    trackedPartCount = #(trackedPartIds or {}),
  }
end

local function buildCategoryUiData(vehicleData, maintenanceState, uiState, categoryName)
  local categoryState = maintenanceState.categories[categoryName]
  local rows = {}
  for _, itemDefinition in ipairs(config.categoryDefinitions[categoryName].items) do
    table.insert(rows, buildUiRow(vehicleData, maintenanceState, uiState, categoryName, itemDefinition))
  end

  return {
    name = categoryName,
    label = config.categoryDefinitions[categoryName].label,
    avgMiles = roundMoney((tonumber(categoryState.avgOdometer) or 0) * metersToMiles),
    wearRatio = math.min(1, max(0, ((tonumber(categoryState.avgOdometer) or 0) * metersToMiles) / 250000)),
    rows = rows,
  }
end

local function buildMaintenanceUiDataForInventory(inventoryId)
  if not isMaintenanceEnabled() then
    return {enabled = false}
  end

  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return {enabled = false}
  end

  local vehicleData, maintenanceState, uiState = prepareVehicleState(inventoryId, {
    persistChanges = false,
    persistCompletedJobs = true,
    markDirtyOnChange = true,
  })
  if not vehicleData then
    return {enabled = false}
  end

  local vehicleUiData = deepCopy(vehicleData)
  if career_modules_inventory and career_modules_inventory.getVehicleUiData then
    local success, result = pcall(career_modules_inventory.getVehicleUiData, inventoryId)
    if success and result then
      vehicleUiData = result
    elseif log then
      log("W", "maintenanceComputer", string.format("Falling back to raw vehicle data for inventory %s UI build: %s",
        tostring(inventoryId), tostring(result)))
    end
  end
  local categories = {}
  for _, categoryName in ipairs(config.categoryOrder) do
    if categoryHardwareIsInstalled(vehicleData, categoryName) then
      table.insert(categories, buildCategoryUiData(vehicleData, maintenanceState, uiState, categoryName))
    end
  end

  return {
    enabled = true,
    facilityName = buildFacilityName(),
    inventoryId = tostring(inventoryId),
    vehicle = vehicleUiData,
    maintenanceProfile = deepCopy(maintenanceState.profile),
    categories = categories,
    playerMoney = getPlayerMoney(),
    tireShop = career_modules_tireSystem and career_modules_tireSystem.buildUiData and
                 career_modules_tireSystem.buildUiData(inventoryId) or {available = false},
  }
end

local function buildMaintenanceUiDataForBusinessVehicle(vehicleId, businessType, businessId)
  if not isMaintenanceEnabled() then return {enabled = false} end
  if not businessType or businessId == nil or vehicleId == nil then
    return {enabled = false, errorMessage = "Business vehicle context is missing."}
  end
  if not career_modules_business_businessManager.isPurchasedBusiness(businessType, businessId) then
    return {enabled = false, errorMessage = "Business ownership could not be verified."}
  end
  local vehicleData, maintenanceState, uiState = prepareBusinessVehicleState(businessId, vehicleId)
  if not vehicleData then return {enabled = false, errorMessage = "Fleet vehicle not found."} end
  local categories = {}
  for _, categoryName in ipairs(config.categoryOrder) do
    if categoryHardwareIsInstalled(vehicleData, categoryName) then
      table.insert(categories, buildCategoryUiData(vehicleData, maintenanceState, uiState, categoryName))
    end
  end
  return {
    enabled = true,
    facilityName = buildFacilityName(),
    inventoryId = tostring(vehicleId),
    vehicle = deepCopy(vehicleData),
    maintenanceProfile = deepCopy(maintenanceState.profile),
    categories = categories,
    playerMoney = getPlayerMoney(),
    tireShop = career_modules_tireSystem.buildBusinessUiData(businessId, vehicleId),
  }
end

local function getMaintenanceUiData()
  return buildMaintenanceUiDataForInventory(activeInventoryId)
end

local function getMaintenanceUiDataForInventory(inventoryId)
  return buildMaintenanceUiDataForInventory(inventoryId)
end

local function getMaintenanceUiDataForInventorySafe(inventoryId)
  local success, result = xpcall(function()
    return getMaintenanceUiDataForInventory(inventoryId)
  end, debug.traceback)
  if success then
    return result
  end

  if log then
    log("E", "maintenanceComputer", tostring(result))
  end

  return {
    enabled = false,
    errorMessage = "Maintenance data failed to load.",
    debugError = tostring(result),
  }
end

local function getMaintenanceUiDataForBusinessVehicleSafe(vehicleId, businessType, businessId)
  local success, result = xpcall(function()
    return buildMaintenanceUiDataForBusinessVehicle(vehicleId, businessType, businessId)
  end, debug.traceback)
  if success then return result end
  if log then log("E", "maintenanceComputer", tostring(result)) end
  return {enabled = false, errorMessage = "Business maintenance data failed to load.", debugError = tostring(result)}
end

local function getMaintenanceUiDataSafe()
  local success, result = xpcall(getMaintenanceUiData, debug.traceback)
  if success then
    return result
  end

  if log then
    log("E", "maintenanceComputer", tostring(result))
  end

  return {
    enabled = false,
    errorMessage = "Maintenance data failed to load.",
    debugError = tostring(result),
  }
end

local function buildErrorResult(message)
  return {ok = false, message = message}
end

local function payServicePrice(price, itemDefinition, paymentContext)
  local amount = tonumber(price) or 0
  if amount <= 0 then
    return true
  end

  local mode = paymentContext and paymentContext.mode or "player"
  if mode == "businessAccount" then
    local businessType = paymentContext and paymentContext.businessType or nil
    local businessId = paymentContext and paymentContext.businessId or nil
    if not businessType or businessId == nil or businessId == "" then
      return false, "Business account context is missing."
    end
    if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.payFromAccount then
      return false, "Business bank system is unavailable."
    end
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if not account then
      return false, "Business account not found."
    end
    local paid = career_modules_bank.payFromAccount({
      money = { amount = amount, canBeNegative = false },
    }, account.id, "Vehicle Maintenance", string.format("Maintenance: %s %s", itemDefinition.actionLabel, itemDefinition.label))
    if not paid then
      return false, "Not enough funds in business account."
    end
    return true
  end

  local priceData = {money = {amount = amount, canBeNegative = false}}
  if career_modules_payment and career_modules_payment.canPay and not career_modules_payment.canPay(priceData) then
    return false, "Not enough money."
  end
  if career_modules_payment and career_modules_payment.pay and not career_modules_payment.pay(priceData, {
    label = string.format("Maintenance: %s %s", itemDefinition.actionLabel, itemDefinition.label),
    tags = {"maintenance", "vehicleMaintenance", "buying"},
  }) then
    return false, "Payment failed."
  end

  return true
end

local function refundServicePrice(price, itemDefinition, paymentContext)
  local amount = tonumber(price) or 0
  if amount <= 0 then
    return true
  end

  local label = string.format("Maintenance refund: %s %s", itemDefinition.actionLabel, itemDefinition.label)
  if paymentContext and paymentContext.mode == "businessAccount" then
    local account = career_modules_bank and career_modules_bank.getBusinessAccount and
                      career_modules_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
    if account and career_modules_bank.rewardToAccount then
      return career_modules_bank.rewardToAccount({money = {amount = amount}}, account.id, "Vehicle Maintenance Refund", label)
    end
    return false
  end

  if career_modules_payment and career_modules_payment.reward then
    return career_modules_payment.reward({money = {amount = amount}}, {
      label = label,
      tags = {"maintenance", "vehicleMaintenance", "refund"},
    }, true)
  end
  return false
end

local function prepareAction(inventoryId, categoryName, itemName)
  if not isMaintenanceEnabled() then
    return nil, nil, nil, nil, buildErrorResult("Maintenance mode is not enabled.")
  end

  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return nil, nil, nil, nil, buildErrorResult("Invalid vehicle.")
  end

  local itemDefinition = config.getItemDefinition(categoryName, itemName)
  if not itemDefinition then
    return nil, nil, nil, nil, buildErrorResult("Unknown maintenance item.")
  end

  local vehicleData, maintenanceState, uiState = prepareVehicleState(inventoryId)
  if not vehicleData then
    return nil, nil, nil, nil, buildErrorResult("Vehicle not found.")
  end

  if not categoryHardwareIsInstalled(vehicleData, categoryName) then
    return nil, nil, nil, nil, buildErrorResult("That system is not installed on this vehicle.")
  end

  local categoryState = maintenanceState.categories[categoryName]
  if not categoryState or categoryState.maintenance[itemName] == nil then
    return nil, nil, nil, nil, buildErrorResult("Maintenance state unavailable for this item.")
  end

  return vehicleData, maintenanceState, uiState, itemDefinition
end

local function prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
  if not isMaintenanceEnabled() then
    return nil, nil, nil, nil, buildErrorResult("Maintenance mode is not enabled.")
  end
  if not career_modules_business_businessManager.isPurchasedBusiness(businessType, businessId) then
    return nil, nil, nil, nil, buildErrorResult("Business ownership could not be verified.")
  end
  local itemDefinition = config.getItemDefinition(categoryName, itemName)
  if not itemDefinition then return nil, nil, nil, nil, buildErrorResult("Unknown maintenance item.") end
  local vehicleData, maintenanceState, uiState = prepareBusinessVehicleState(businessId, vehicleId)
  if not vehicleData then return nil, nil, nil, nil, buildErrorResult("Fleet vehicle not found.") end
  if not categoryHardwareIsInstalled(vehicleData, categoryName) then
    return nil, nil, nil, nil, buildErrorResult("That system is not installed on this vehicle.")
  end
  local categoryState = maintenanceState.categories[categoryName]
  if not categoryState or categoryState.maintenance[itemName] == nil then
    return nil, nil, nil, nil, buildErrorResult("Maintenance state unavailable for this item.")
  end
  return vehicleData, maintenanceState, uiState, itemDefinition
end

local function performBusinessCheck(vehicleId, categoryName, itemName, businessType, businessId)
  local vehicleData, maintenanceState, uiState, itemDefinition, errorResult =
    prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
  if errorResult then return errorResult end
  local roundedValue = roundPercent(maintenanceState.categories[categoryName].maintenance[itemName])
  revealMaintenanceItem(uiState, categoryName, itemName, roundedValue)
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  return {ok = true, completed = true, category = categoryName, item = itemDefinition.name,
    revealedPercent = roundedValue, price = 0}
end

local function performBusinessService(vehicleId, categoryName, itemName, businessType, businessId)
  local vehicleData, maintenanceState, uiState, itemDefinition, errorResult =
    prepareBusinessAction(vehicleId, categoryName, itemName, businessType, businessId)
  if errorResult then return errorResult end
  local trackedPartsValue = calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
  local price = calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
  local stateBefore = deepCopy(vehicleData.maintenanceState)
  local computerStateBefore = deepCopy(vehicleData.maintenanceComputerState)
  local paymentContext = {mode = "businessAccount", businessType = businessType, businessId = businessId}
  local paid, paymentMessage = payServicePrice(price, itemDefinition, paymentContext)
  if not paid then return buildErrorResult(paymentMessage or "Payment failed.") end
  local committed, commitError = xpcall(function()
    completeServiceJob(uiState, maintenanceState.categories[categoryName], {
      kind = "service", category = categoryName, item = itemName,
    }, itemDefinition)
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  end, debug.traceback)
  if not committed then
    vehicleData.maintenanceState = stateBefore
    vehicleData.maintenanceComputerState = computerStateBefore
    refundServicePrice(price, itemDefinition, paymentContext)
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
    if log then log("E", "maintenanceComputer", "Immediate business service rolled back: " .. tostring(commitError)) end
    return buildErrorResult("Maintenance service failed; payment was refunded.")
  end
  return {ok = true, completed = true, category = categoryName, item = itemName, price = price}
end

local function performCheck(inventoryId, categoryName, itemName)
  local vehicleData, maintenanceState, uiState, itemDefinition, errorResult = prepareAction(inventoryId, categoryName, itemName)
  if errorResult then
    return errorResult
  end

  local value = maintenanceState.categories[categoryName].maintenance[itemName]
  local roundedValue = roundPercent(value)
  revealMaintenanceItem(uiState, categoryName, itemName, roundedValue)
  persistVehicleMutation(vehicleData.id)
  return {
    ok = true,
    completed = true,
    category = categoryName,
    item = itemDefinition.name,
    revealedPercent = roundedValue,
    price = 0,
  }
end

local function performService(inventoryId, categoryName, itemName, paymentContext)
  local vehicleData, maintenanceState, uiState, itemDefinition, errorResult = prepareAction(inventoryId, categoryName, itemName)
  if errorResult then
    return errorResult
  end

  local trackedPartsValue = calculateTrackedPartsValue(vehicleData, maintenanceState, categoryName)
  local price = calculateServicePrice(vehicleData, maintenanceState, categoryName, itemDefinition, trackedPartsValue)
  local stateBefore = deepCopy(vehicleData.maintenanceState)
  local computerStateBefore = deepCopy(vehicleData.maintenanceComputerState)
  local paid, paymentMessage = payServicePrice(price, itemDefinition, paymentContext)
  if not paid then
    return buildErrorResult(paymentMessage or "Payment failed.")
  end

  local committed, commitError = xpcall(function()
    completeServiceJob(uiState, maintenanceState.categories[categoryName], {
      kind = "service",
      category = categoryName,
      item = itemName,
    }, itemDefinition)
    syncRuntimeState(vehicleData.id)
    persistVehicleMutation(vehicleData.id)
  end, debug.traceback)

  if not committed then
    vehicleData.maintenanceState = stateBefore
    vehicleData.maintenanceComputerState = computerStateBefore
    refundServicePrice(price, itemDefinition, paymentContext)
    markVehicleDirty(vehicleData.id)
    if log then
      log("E", "maintenanceComputer", "Immediate service rolled back: " .. tostring(commitError))
    end
    return buildErrorResult("Maintenance service failed; payment was refunded.")
  end

  return {
    ok = true,
    completed = true,
    category = categoryName,
    item = itemName,
    price = price,
  }
end

local function startCheck(inventoryId, categoryName, itemName)
  local success, result = xpcall(function()
    return performCheck(inventoryId, categoryName, itemName)
  end, debug.traceback)
  if success then
    return result
  end
  if log then
    log("E", "maintenanceComputer", tostring(result))
  end
  return buildErrorResult("Failed to complete maintenance check.")
end

local function startCheckForBusinessVehicle(vehicleId, categoryName, itemName, businessType, businessId)
  local success, result = xpcall(function()
    return performBusinessCheck(vehicleId, categoryName, itemName, businessType, businessId)
  end, debug.traceback)
  if success then
    return result
  end
  if log then
    log("E", "maintenanceComputer", tostring(result))
  end
  return buildErrorResult("Failed to complete maintenance check.")
end

local function startService(inventoryId, categoryName, itemName)
  local success, result = xpcall(function()
    return performService(inventoryId, categoryName, itemName)
  end, debug.traceback)
  if success then
    return result
  end
  if log then
    log("E", "maintenanceComputer", tostring(result))
  end
  return buildErrorResult("Failed to complete maintenance service.")
end

local function startServiceForBusinessVehicle(inventoryId, categoryName, itemName, businessType, businessId)
  local success, result = xpcall(function()
    return performBusinessService(inventoryId, categoryName, itemName, businessType, businessId)
  end, debug.traceback)
  if success then
    return result
  end
  if log then
    log("E", "maintenanceComputer", tostring(result))
  end
  return buildErrorResult("Failed to complete business maintenance service.")
end

local function tableToList(value)
  if type(value) ~= "table" then
    return {}
  end
  if value[1] ~= nil then
    local list = {}
    for i = 1, #value do
      list[i] = value[i]
    end
    return list
  end
  local list = {}
  for _, nested in pairs(value) do
    table.insert(list, nested)
  end
  return list
end

local function filterCartServices(rawServices)
  local byKey = {}
  local ordered = {}
  for _, entry in ipairs(tableToList(rawServices)) do
    local categoryName = entry and entry.category
    local itemName = entry and entry.item
    local definition = config.getItemDefinition(categoryName, itemName)
    if definition then
      local key = tostring(categoryName) .. ":" .. tostring(itemName)
      if not byKey[key] then
        local filtered = {
          category = categoryName,
          item = itemName,
          definition = definition,
        }
        byKey[key] = filtered
        table.insert(ordered, filtered)
      end
    end
  end

  local covered = {}
  for _, entry in ipairs(ordered) do
    if entry.definition.fillsItem then
      covered[entry.category .. ":" .. entry.definition.fillsItem] = true
    end
  end

  local filtered = {}
  for _, entry in ipairs(ordered) do
    if not covered[entry.category .. ":" .. entry.item] then
      table.insert(filtered, entry)
    end
  end
  return filtered
end

local function payCartTotal(amount, paymentContext)
  amount = tonumber(amount) or 0
  if amount <= 0 then
    return true
  end
  return payServicePrice(amount, {actionLabel = "Checkout", label = "cart"}, paymentContext)
end

local function refundCartTotal(amount, paymentContext)
  amount = tonumber(amount) or 0
  if amount <= 0 then
    return true
  end
  return refundServicePrice(amount, {actionLabel = "Checkout", label = "cart"}, paymentContext)
end

local function performCartCheckout(inventoryId, cart)
  cart = cart or {}
  local services = filterCartServices(cart.services)
  local tireAxleIds = tableToList(cart.tireAxleIds)
  if #services == 0 and #tireAxleIds == 0 then
    return buildErrorResult("Cart is empty.")
  end

  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return buildErrorResult("Invalid vehicle.")
  end

  local vehicleData, maintenanceState, uiState = prepareVehicleState(inventoryId)
  if not vehicleData then
    return buildErrorResult("Vehicle not found.")
  end

  local serviceTotal = 0
  for _, entry in ipairs(services) do
    local categoryState = maintenanceState.categories[entry.category]
    if not categoryState or categoryState.maintenance[entry.item] == nil then
      return buildErrorResult("Maintenance state unavailable for " .. entry.definition.label .. ".")
    end
    local trackedPartsValue = calculateTrackedPartsValue(vehicleData, maintenanceState, entry.category)
    entry.price = calculateServicePrice(vehicleData, maintenanceState, entry.category, entry.definition, trackedPartsValue)
    serviceTotal = serviceTotal + (tonumber(entry.price) or 0)
  end

  local tireTotal = 0
  if #tireAxleIds > 0 then
    local tireUi = career_modules_tireSystem and career_modules_tireSystem.buildUiData and
                     career_modules_tireSystem.buildUiData(inventoryId) or {available = false}
    if not tireUi.available then
      return buildErrorResult(tireUi.message or "Tire replacement is unavailable.")
    end
    if not tireUi.inspected then
      return buildErrorResult("Check all tires before replacing them.")
    end
    if tostring(cart.quoteRevision or "") ~= tostring(tireUi.quoteRevision or "") then
      return {ok = false, staleQuote = true, message = "Tire condition or pricing changed. Review the updated quote."}
    end
    local wanted = {}
    for _, axleId in ipairs(tireAxleIds) do
      wanted[tostring(axleId)] = true
    end
    local matched = 0
    for _, axle in ipairs(tireUi.axles or {}) do
      if wanted[tostring(axle.id)] then
        tireTotal = tireTotal + (tonumber(axle.subtotal) or 0)
        matched = matched + 1
        wanted[tostring(axle.id)] = nil
      end
    end
    if matched == 0 then
      return buildErrorResult("Select at least one axle.")
    end
  end

  local total = serviceTotal + tireTotal
  local stateBefore = deepCopy(vehicleData.maintenanceState)
  local computerStateBefore = deepCopy(vehicleData.maintenanceComputerState)
  local paid, paymentMessage = payCartTotal(total)
  if not paid then
    return buildErrorResult(paymentMessage or "Payment failed.")
  end

  local committed, commitError = xpcall(function()
    for _, entry in ipairs(services) do
      completeServiceJob(uiState, maintenanceState.categories[entry.category], {
        kind = "service",
        category = entry.category,
        item = entry.item,
      }, entry.definition)
    end

    if #tireAxleIds > 0 then
      local tireResult = career_modules_tireSystem.checkout(inventoryId, tireAxleIds, cart.quoteRevision, {skipPayment = true})
      if not tireResult or not tireResult.ok then
        error(tireResult and tireResult.message or "Tire replacement failed.")
      end
    else
      syncRuntimeState(vehicleData.id)
      persistVehicleMutation(vehicleData.id)
    end
  end, debug.traceback)

  if not committed then
    vehicleData.maintenanceState = stateBefore
    vehicleData.maintenanceComputerState = computerStateBefore
    refundCartTotal(total)
    markVehicleDirty(vehicleData.id)
    if log then
      log("E", "maintenanceComputer", "Cart checkout rolled back: " .. tostring(commitError))
    end
    return buildErrorResult("Maintenance checkout failed; payment was refunded.")
  end

  pcall(closeMenu)
  return {
    ok = true,
    completed = true,
    price = total,
    serviceCount = #services,
    tireCount = #tireAxleIds,
  }
end

local function decodeCartPayload(cartOrServices, tireAxleIds, quoteRevision)
  if type(cartOrServices) == "string" then
    local decoded = jsonDecode and jsonDecode(cartOrServices) or nil
    if type(decoded) ~= "table" then
      return nil, buildErrorResult("Invalid checkout payload.")
    end
    return decoded
  end
  if type(cartOrServices) == "table" and (cartOrServices.services ~= nil or cartOrServices.tireAxleIds ~= nil) then
    return cartOrServices
  end
  return {
    services = cartOrServices,
    tireAxleIds = tireAxleIds,
    quoteRevision = quoteRevision,
  }
end

local function checkoutCart(inventoryId, cartOrServices, tireAxleIds, quoteRevision)
  local cart, payloadError = decodeCartPayload(cartOrServices, tireAxleIds, quoteRevision)
  if payloadError then
    return payloadError
  end
  local success, result = xpcall(function()
    return performCartCheckout(inventoryId, cart)
  end, debug.traceback)
  if success then
    return result
  end
  if log then
    log("E", "maintenanceComputer", tostring(result))
  end
  return buildErrorResult("Failed to complete maintenance checkout.")
end

local function inspectTires(inventoryId)
  local success, result = xpcall(function()
    return career_modules_tireSystem.inspectAll(inventoryId)
  end, debug.traceback)
  if success then return result end
  if log then log("E", "maintenanceComputer", tostring(result)) end
  return buildErrorResult("Failed to inspect tires.")
end

local function inspectBusinessVehicleTires(vehicleId, businessType, businessId)
  local success, result = xpcall(function()
    if not career_modules_business_businessManager.isPurchasedBusiness(businessType, businessId) then
      return buildErrorResult("Business ownership could not be verified.")
    end
    return career_modules_tireSystem.inspectBusiness(businessId, vehicleId)
  end, debug.traceback)
  if success then return result end
  if log then log("E", "maintenanceComputer", tostring(result)) end
  return buildErrorResult("Failed to inspect fleet tires.")
end

local function checkoutTires(inventoryId, axleIds, quoteRevision)
  local success, result = xpcall(function()
    return career_modules_tireSystem.checkout(inventoryId, axleIds, quoteRevision)
  end, debug.traceback)
  if success then return result end
  if log then log("E", "maintenanceComputer", tostring(result)) end
  return buildErrorResult("Failed to replace tires.")
end

local function checkoutTiresForBusinessVehicle(inventoryId, axleIds, quoteRevision, businessType, businessId)
  local success, result = xpcall(function()
    return career_modules_tireSystem.checkoutBusiness(businessType, businessId, inventoryId, axleIds, quoteRevision)
  end, debug.traceback)
  if success then return result end
  if log then log("E", "maintenanceComputer", tostring(result)) end
  return buildErrorResult("Failed to replace business vehicle tires.")
end

local function openMenuFromComputer(inventoryId, computerId, _returnRoute)
  if not isMaintenanceEnabled() then
    return false
  end

  activeInventoryId = tonumber(inventoryId)
  originComputerId = computerId
  returnRoute = _returnRoute
  if not activeInventoryId then
    return false
  end

  extensions.ui_router.navigate('maintenance')
  return true
end

local function closeMenu()
  local route = returnRoute
  returnRoute = nil

  if route and extensions.ui_router and extensions.ui_router.navigate then
    pcall(extensions.ui_router.navigate, route)
    return
  end

  local opened = false
  if originComputerId and freeroam_facilities and freeroam_facilities.getFacility and career_modules_computer and career_modules_computer.openMenu then
    local ok, computer = pcall(freeroam_facilities.getFacility, "computer", originComputerId, true)
    if ok and computer then
      opened = pcall(career_modules_computer.openMenu, computer)
    end
  end
  if not opened and extensions.ui_router and extensions.ui_router.navigate then
    pcall(extensions.ui_router.navigate, "career.computer")
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not isMaintenanceEnabled() then
    return
  end
  if not menuData.computerFacility.functions["vehicleInventory"] then
    return
  end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    computerFunctions.vehicleSpecific[inventoryId].maintenance = {
      id = "maintenance",
      label = "Maintenance",
      callback = function(computerId)
        openMenuFromComputer(inventoryId, computerId or menuData.computerFacility.id)
      end,
      order = 6,
    }
  end
end

local function migrateAllLegacyJobs()
  if not career_modules_inventory or not career_modules_inventory.getVehicles then
    return
  end
  for inventoryId, vehicleData in pairs(career_modules_inventory.getVehicles() or {}) do
    local jobs = vehicleData and vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.jobs
    if type(jobs) == "table" and next(jobs) then
      prepareVehicleState(inventoryId)
    end
  end
  local purchased = career_modules_business_businessManager and
                      career_modules_business_businessManager.getAllPurchasedBusinesses and
                      career_modules_business_businessManager.getAllPurchasedBusinesses() or {}
  for _, businessesById in pairs(purchased) do
    for businessId, owned in pairs(businessesById or {}) do
      if owned == true or type(owned) == "table" then
        for _, vehicleData in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
          local jobs = vehicleData and vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.jobs
          if type(jobs) == "table" and next(jobs) then
            prepareBusinessVehicleState(businessId, vehicleData.vehicleId)
          end
        end
      end
    end
  end
end

M.onComputerAddFunctions = onComputerAddFunctions
M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.getMaintenanceUiData = getMaintenanceUiDataSafe
M.getMaintenanceUiDataForInventory = getMaintenanceUiDataForInventorySafe
M.getMaintenanceUiDataForBusinessVehicle = getMaintenanceUiDataForBusinessVehicleSafe
M.categoryHardwareIsInstalled = categoryHardwareIsInstalled
M.startCheck = startCheck
M.startCheckForBusinessVehicle = startCheckForBusinessVehicle
M.startService = startService
M.startServiceForBusinessVehicle = startServiceForBusinessVehicle
M.inspectTires = inspectTires
M.inspectBusinessVehicleTires = inspectBusinessVehicleTires
M.checkoutTires = checkoutTires
M.checkoutTiresForBusinessVehicle = checkoutTiresForBusinessVehicle
M.checkoutCart = checkoutCart
M.onCareerActive = migrateAllLegacyJobs
return M
