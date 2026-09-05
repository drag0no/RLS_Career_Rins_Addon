-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', "career_modules_log", "util_screenshotCreator", "career_modules_garageManager", "career_modules_computer", "gameplay_tutorial_setup"}

local BASE_TOW_SERVICE_COST = 250
local originComputerId

local dateUtils = require('utils/dateUtils')
local parking = require('gameplay/parking')
local freeroam_facilities = require('freeroam/facilities')
local maintenanceComputerConfig = require('ge/extensions/career/modules/maintenanceComputerConfig')

local minimumVersion = 42

local xVec, yVec, zVec = vec3(1,0,0), vec3(0,1,0), vec3(0,0,1)

local saveAnyVehiclePosDEBUG = true

local slotAmount = 20

local vehicles = {}
local dirtiedVehicles = {}
local vehIdToInventoryId = {}
local inventoryIdToVehId = {}
local currentVehicle
local lastVehicle
local favoriteVehicle
local pendingMigrationCashOutVehicleIds
local pendingMigrationPlan
local pendingMigrationApplication
local pendingMigrationRetry
local currentMigrationSaveFolder
local applyPendingMigration

local loadedVehiclesLocations
local unicycleSavedPosition

local vehicleToEnterId
local vehiclesMovedToStorage
local loanedVehicleReturned
local pendingMaintenanceSeedInventoryIds = {}
local accessTimerAccumulator = 0
local ACCESS_TIMER_UPDATE_INTERVAL = 0.25

local function isMaintenanceFailureType(categoryName, failureType)
  if type(categoryName) ~= "string" or type(failureType) ~= "string" then
    return false
  end
  return string.find(failureType, categoryName, 1, true) ~= nil or string.find(failureType, "break", 1, true) ~= nil
end

local function looksLikeMaintenancePowertrainFailure(categoryName, partCondition)
  local powertrainState = partCondition and partCondition.integrityState and partCondition.integrityState.powertrain
  if type(powertrainState) ~= "table" then
    return false
  end

  for _, deviceState in pairs(powertrainState) do
    if type(deviceState) == "table" then
      if categoryName == "engine" then
        if deviceState.isBroken == true or type(deviceState.thermals) == "table" or deviceState.damageFrictionCoef ~= nil or
            deviceState.damageDynamicFrictionCoef ~= nil or deviceState.damageIdleAVReadErrorRangeCoef ~= nil then
          return true
        end
      elseif categoryName == "radiator" then
        if deviceState.radiatorDamage ~= nil or deviceState.coolantMass ~= nil then
          return true
        end
      elseif categoryName == "transmission" then
        if deviceState.isBroken == true or deviceState.damageGearRatioChangeRateCoef ~= nil or
            deviceState.damageClutchFreePlayCoef ~= nil or deviceState.damageLockTorqueCoef ~= nil or
            deviceState.damageFrictionCoef ~= nil or deviceState.synchroWear ~= nil or
            deviceState.clutchPermanentlyDamaged ~= nil then
          return true
        end
      end
    end
  end

  return false
end

local function sanitizeMaintenanceConditionEntry(categoryName, partCondition, hasMaintenanceMarker)
  if type(partCondition) ~= "table" or not hasMaintenanceMarker then
    return false
  end

  local didSanitize = false
  local integrityValue = tonumber(partCondition.integrityValue)
  if integrityValue ~= nil and integrityValue < 1 then
    partCondition.integrityValue = 1
    didSanitize = true
  end

  if type(partCondition.integrityState) == "table" and partCondition.integrityState.powertrain then
    partCondition.integrityState.powertrain = nil
    if not next(partCondition.integrityState) then
      partCondition.integrityState = nil
    end
    didSanitize = true
  end

  return didSanitize
end

local function sanitizeMaintenancePartConditionsForVehicle(vehicleData, partConditions)
  if type(vehicleData) ~= "table" or type(partConditions) ~= "table" then
    return partConditions
  end

  local maintenanceState = vehicleData.maintenanceState
  if type(maintenanceState) ~= "table" or type(maintenanceState.categories) ~= "table" then
    return partConditions
  end

  for categoryName, categoryState in pairs(maintenanceState.categories) do
    if type(categoryState) == "table" then
      local didSanitizeCategory = false
      local shouldPreservePersistentDamage = categoryState.persistentCareerDamage == true
      local candidatePartIds = {}

      if categoryState.rootPartId then
        table.insert(candidatePartIds, categoryState.rootPartId)
      end

      if type(categoryState.cachedPartIds) == "table" then
        for _, candidatePartId in ipairs(categoryState.cachedPartIds) do
          if candidatePartId ~= categoryState.rootPartId then
            table.insert(candidatePartIds, candidatePartId)
          end
        end
      end

      for _, partId in ipairs(candidatePartIds) do
        local partCondition = partConditions[partId]
        local looksLikeFailure = isMaintenanceFailureType(categoryName, categoryState.lastFailureType) or
                                     looksLikeMaintenancePowertrainFailure(categoryName, partCondition)
        if not shouldPreservePersistentDamage and sanitizeMaintenanceConditionEntry(categoryName, partCondition, looksLikeFailure) then
          partConditions[partId] = partCondition
          didSanitizeCategory = true
        end
      end

      if didSanitizeCategory and not shouldPreservePersistentDamage then
        categoryState.lastFailureType = nil
        categoryState.lastFailureTime = 0
      end
    end
  end

  return partConditions
end

local function isExperimentalMaintenanceEnabled()
  if career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled then
    return career_modules_maintenanceMode.isEnabled() == true
  end

  return true
end

local function sanitizeLoadedVehiclesForDisabledMaintenance()
  if isExperimentalMaintenanceEnabled() then
    return
  end

  for inventoryId, vehicleData in pairs(vehicles) do
    if type(vehicleData) == "table" then
      if type(vehicleData.partConditions) == "table" then
        vehicleData.partConditions = sanitizeMaintenancePartConditionsForVehicle(vehicleData, vehicleData.partConditions)
      end
      if vehicleData.maintenanceState ~= nil then
        vehicleData.maintenanceState = nil
        dirtiedVehicles[inventoryId] = true
      end
    end
  end
end

local function onExperimentalMaintenanceModeChanged(enabled)
  if enabled == true then
    return
  end

  sanitizeLoadedVehiclesForDisabledMaintenance()
end

local function getClosestGarage(pos, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  local facilities = freeroam_facilities.getFacilities(levelName)
  if not facilities or not facilities.garages then return nil end

  local playerPos = pos
  if not playerPos then
    local playerVeh = getPlayerVehicle(0)
    if playerVeh then
      playerPos = playerVeh:getPosition()
    end
  end
  if not playerPos then return nil end

  local closestGarage
  local minDist = math.huge
  for _, garage in pairs(facilities.garages) do
    local garagePos = freeroam_facilities.getAverageDoorPositionForFacility(garage)
    if garagePos then
      local dist = garagePos:distance(playerPos)
      if dist < minDist then
        closestGarage = garage
        minDist = dist
      end
    end
  end
  return closestGarage
end

local function getInventoryMenuGarage(pos, levelName)
  local garageManager = career_modules_garageManager
  if garageManager then
    local computerId = originComputerId
    if not computerId and career_modules_computer and career_modules_computer.getComputerId then
      computerId = career_modules_computer.getComputerId()
    end

    local garageId = computerId and garageManager.computerIdToGarageId(computerId)
    if garageId then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      if garage then
        return garage
      end
    end
  end

  return getClosestGarage(pos, levelName)
end

local function getClosestOwnedGarageWithSpace(pos, levelName)
  local garageManager = career_modules_garageManager
  if not garageManager then return nil end

  -- 1. Check computer link first - this is the highest priority
  if career_modules_computer and career_modules_computer.getComputerId then
    local currentCompId = career_modules_computer.getComputerId()
    if currentCompId then
      local currentGarageId = garageManager.computerIdToGarageId(currentCompId)
      if currentGarageId and garageManager.isPurchasedGarage(currentGarageId)
        and not (garageManager.isGarageForSale and garageManager.isGarageForSale(currentGarageId)) then
        local spaceInfo = garageManager.isGarageSpace(currentGarageId)
        if spaceInfo and spaceInfo[1] then
          return freeroam_facilities.getFacility("garage", currentGarageId)
        end
      end
    end
  end

  levelName = levelName or getCurrentLevelIdentifier()
  local facilities = freeroam_facilities.getFacilities(levelName)
  if not facilities or not facilities.garages then return nil end

  local playerPos = pos
  if not playerPos then
    local playerVeh = getPlayerVehicle(0)
    if playerVeh then
      playerPos = playerVeh:getPosition()
    end
  end
  if not playerPos then return nil end

  -- 2. Find the closest owned garage with space
  local closestGarage
  local minDist = math.huge
  for _, garage in pairs(facilities.garages) do
    if garageManager.isPurchasedGarage(garage.id)
      and not (garageManager.isGarageForSale and garageManager.isGarageForSale(garage.id)) then
      local spaceInfo = garageManager.isGarageSpace(garage.id)
      if spaceInfo and spaceInfo[1] then
        local garagePos = freeroam_facilities.getAverageDoorPositionForFacility(garage)
        if garagePos then
          local dist = garagePos:distance(playerPos)
          if dist < minDist then
            closestGarage = garage
            minDist = dist
          end
        end
      end
    end
  end

  return closestGarage
end

local function getVehicleRetrievalQuote(inventoryId, routePrice)
  local coveredByInsurance = career_modules_insurance_insurance and
    career_modules_insurance_insurance.isRoadSideAssistanceFree and
    career_modules_insurance_insurance.isRoadSideAssistanceFree(inventoryId) or false
  if coveredByInsurance then
    return {cost = 0, coveredByInsurance = true}
  end

  local globalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1
  local baseCost = math.floor(BASE_TOW_SERVICE_COST * globalIndex * 100 + 0.5) / 100
  return {
    cost = baseCost + math.max(0, tonumber(routePrice) or 0),
    coveredByInsurance = false
  }
end

local function useVehicleRetrievalService(inventoryId, routePrice, label)
  local quote = getVehicleRetrievalQuote(inventoryId, routePrice)
  if quote.coveredByInsurance then
    career_modules_insurance_insurance.useRoadsideAssistance(inventoryId)
    ui_message("Roadside assistance tow used.", 5, "Vehicle retrieval", "info")
    return quote
  end

  career_modules_payment.pay(
    {money = {amount = quote.cost, canBeNegative = true}},
    {label = label or "Retrieved vehicle with towing service", tags = {"delivery"}})
  return quote
end

local function getLocalGarageRetrievalRoutePrice()
  local garage = getInventoryMenuGarage()
  if not garage or not career_modules_quickTravel then return 0 end
  return career_modules_quickTravel.getPriceForQuickTravelToGarage(garage) or 0
end

local function getClosestGarageAndSpot(pos, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  local facilities = freeroam_facilities.getFacilities(levelName)
  local closestGarage
  local closestSpot
  local minDist = math.huge

  -- Check each garage
  for _, garage in ipairs(facilities.garages) do
    local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(garage)
    for _, spot in ipairs(parkingSpots) do
      if not spot.vehicle and not spot:hasAnyVehicles() then
        local dist = spot.pos:distance(pos)
        if dist < minDist then
          minDist = dist
          closestGarage = garage
          closestSpot = spot
        end
      end
    end
  end
  return closestGarage, closestSpot, minDist
end

-- Function to parse ISO 8601 date-time string
local function parse_iso8601(datetime)
  local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z"
  local year, month, day, hour, min, sec = datetime:match(pattern)

  -- Convert to Unix timestamp
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false
  })
end

-- Function to calculate time difference
local function time_since(datetime)
  local past = parse_iso8601(datetime)
  local now = os.time(os.date("!*t"))
  local diff = os.difftime(now, past)
  return diff
end

local function getResolvedStartingGarageId(levelName)
  if career_modules_garageManager and career_modules_garageManager.getPrimaryStartingGarageId then
    return career_modules_garageManager.getPrimaryStartingGarageId(levelName)
  end

  local facilities = freeroam_facilities.getFacilities(levelName)
  if not facilities or not facilities.garages then
    return nil
  end

  for _, garage in ipairs(facilities.garages) do
    if garage.starterGarage then
      return garage.id
    end
  end

  return nil
end

local function teleportPlayerToStartingGarage(levelName)
  local spawnGarageId = getResolvedStartingGarageId(levelName)
  if spawnGarageId then
    freeroam_facilities.teleportToGarage(spawnGarageId, getPlayerVehicle(0))
    return spawnGarageId
  end

  local levelGate = scenetree.findObject("Level Gate")
  if levelGate then
    gameplay_walk.setWalkingMode(true)
    spawn.safeTeleport(getPlayerVehicle(0), levelGate:getPosition(), levelGate:getRotation())
    return "levelGate"
  end

  local facilities = freeroam_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
  if facilities then
    for _, facilityListName in ipairs({"dealerships", "privateSellers", "computers"}) do
      local facilityList = facilities[facilityListName]
      if facilityList and facilityList[1] then
        local facility = facilityList[1]
        local pos = freeroam_facilities.getAverageDoorPositionForFacility and freeroam_facilities.getAverageDoorPositionForFacility(facility)
        if pos then
          gameplay_walk.setWalkingMode(true)
          spawn.safeTeleport(getPlayerVehicle(0), pos)
          return facility.id
        end
      end
    end
  end

  return nil
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  inventorySetupDone = false
  lastFailedSpawnPos = nil

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  table.clear(vehicles)
  table.clear(vehIdToInventoryId)
  table.clear(inventoryIdToVehId)

  local saveInfo = jsonReadFile(savePath .. "/info.json")
  if not saveInfo or saveInfo.version < minimumVersion then return end

  -- load the vehicles
  local files = FS:findFiles(savePath .. "/career/vehicles/", '*.json', 0, false, false)
  for i = 1, tableSize(files) do
    local vehicleData = jsonReadFile(files[i])
    if type(vehicleData) == "table" and vehicleData.id ~= nil then
      vehicleData.partConditions = deserialize(vehicleData.partConditions)
      vehicleData.partConditions = sanitizeMaintenancePartConditionsForVehicle(vehicleData, vehicleData.partConditions)
      if vehicleData.timeToAccess then
        vehicleData.timeToAccess = vehicleData.timeToAccess - dateUtils.timeSince(saveInfo.date)
        if vehicleData.timeToAccess <= 0 then
          vehicleData.timeToAccess = nil
          vehicleData.delayReason = nil
        end
      end

      vehicles[vehicleData.id] = vehicleData
      -- Do not use getModel() here: vehicle DB is often still empty during level
      -- load, which falsely marked healthy cars as missingFile and blocked restore.
      local cfg = vehicleData.config or {}
      local configFilename = cfg.partConfigFilename
      local pcExists = type(configFilename) == "string" and configFilename ~= ""
        and (FS:fileExists(configFilename) or FS:fileExists("/" .. configFilename:gsub("^/", "")))
      local hasParts = type(cfg.parts) == "table" and next(cfg.parts) ~= nil
      local hasPartsTree = type(cfg.partsTree) == "table" and next(cfg.partsTree) ~= nil
      if not (pcExists or hasParts or hasPartsTree) then
        vehicleData.missingFile = true
        log("W", "career.inventory", string.format(
          "Vehicle %s marked missingFile (model=%s pc=%s)",
          tostring(vehicleData.id), tostring(vehicleData.model), tostring(configFilename)))
      else
        vehicleData.missingFile = nil
      end
    else
      log("E", "career.inventory", "Skipped unreadable legacy vehicle record: " .. tostring(files[i]))
    end
  end

  local inventoryData = jsonReadFile(savePath .. "/career/inventory.json")

  local levelName = getCurrentLevelIdentifier()
  local generalSaveInfo = jsonReadFile(savePath .. "/career/general.json")
  local justSwitched = generalSaveInfo and generalSaveInfo.justSwitched or false

  if not levelName then
    if generalSaveInfo and generalSaveInfo.level then
      levelName = tostring(generalSaveInfo.level)
    end
  end

  pendingMigrationCashOutVehicleIds = nil
  pendingMigrationPlan = nil
  pendingMigrationApplication = false
  pendingMigrationRetry = false
  currentMigrationSaveFolder = savePath:gsub("[/\\]+$", ""):match("([^/\\]+)$")
  if career_saveMigration and career_saveMigration.getPreparedMigration then
    local migrationPlan = career_saveMigration.getPreparedMigration(saveSlot, currentMigrationSaveFolder)
    if type(migrationPlan) == "table" then
      pendingMigrationPlan = deepcopy(migrationPlan)
      pendingMigrationApplication = migrationPlan.status ~= "applied"
      pendingMigrationRetry = pendingMigrationApplication
      if pendingMigrationApplication then
        pendingMigrationCashOutVehicleIds = deepcopy(migrationPlan.cashOutVehicleIds or {})
      end
      for _, inventoryId in ipairs(migrationPlan.quarantinedVehicleIds or {}) do
        inventoryId = tonumber(inventoryId)
        if inventoryId and vehicles[inventoryId] then
          vehicles[inventoryId].migrationQuarantined = true
          vehicles[inventoryId].missingFile = true
        end
      end
    end
  end

  if inventoryData then
    vehicleToEnterId = tonumber(inventoryData.currentVehicle)
    lastVehicle = tonumber(inventoryData.lastVehicle)
    favoriteVehicle = tonumber(inventoryData.favoriteVehicle)

    if inventoryData.spawnedPlayerVehicles then
      loadedVehiclesLocations = {}
      local rawSpawned = inventoryData.spawnedPlayerVehicles
      -- Numeric Lua keys (inventoryId 1) JSON-encode as an array and drop the id.
      -- Object keys ("1", "2") keep the mapping. Accept both on load.
      local function storeLoadedTransform(inventoryId, transform)
        if not inventoryId or type(transform) ~= "table" or not transform.pos then
          return
        end
        local loaded = {
          pos = vec3(transform.pos),
          rot = quat(transform.rot)
        }
        if not saveAnyVehiclePosDEBUG then
          loaded.option = "garage"
        end
        loadedVehiclesLocations[inventoryId] = loaded
      end

      if rawSpawned[1] and type(rawSpawned[1]) == "table" and rawSpawned[1].pos and rawSpawned["1"] == nil then
        local onlyId = vehicleToEnterId or lastVehicle or favoriteVehicle
        if onlyId and #rawSpawned == 1 then
          storeLoadedTransform(onlyId, rawSpawned[1])
        else
          for index, transform in ipairs(rawSpawned) do
            storeLoadedTransform(tonumber(index), transform)
          end
        end
      else
        for inventoryId, transform in pairs(rawSpawned) do
          storeLoadedTransform(tonumber(inventoryId), transform)
        end
      end
      local spawnCount = 0
      for _ in pairs(loadedVehiclesLocations) do spawnCount = spawnCount + 1 end
      log("I", "career.inventory", string.format(
        "Loaded %d spawnedPlayerVehicles (currentVehicle=%s)",
        spawnCount, tostring(vehicleToEnterId)))
    else
      loadedVehiclesLocations = nil -- will force spawning at garage
      log("I", "career.inventory", "No spawnedPlayerVehicles in save; will use garage/walk restore")
    end

    -- if the last currentVehicle is not spawned, then dont enter it
    if not (loadedVehiclesLocations and loadedVehiclesLocations[vehicleToEnterId]) then
      vehicleToEnterId = nil
    end

    -- Recover older saves where currentVehicle was lost (e.g. realistic walk-enter)
    -- but spawned car positions were still written.
    if not justSwitched and not vehicleToEnterId and loadedVehiclesLocations then
      if lastVehicle and loadedVehiclesLocations[lastVehicle] then
        vehicleToEnterId = lastVehicle
      elseif favoriteVehicle and loadedVehiclesLocations[favoriteVehicle] then
        vehicleToEnterId = favoriteVehicle
      else
        for inventoryId, _ in pairs(loadedVehiclesLocations) do
          vehicleToEnterId = inventoryId
          break
        end
      end
    end

    unicycleSavedPosition = inventoryData.unicyclePos and vec3(inventoryData.unicyclePos) or nil
  end

end

local function updateVehicleThumbnail(inventoryId, filename, callback)
  local vehId = M.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then
    if callback then callback() end
    return
  end
  local vehObj = getObjectByID(vehId)
  if not vehObj then
    if callback then callback() end
    return
  end

  local resolution = vec3(500, 281, 0)
  local fov = 50
  local nearPlane = 0.1
  local camPos, camRot = extensions.util_screenshotCreator.frameVehicle(vehObj, fov, nearPlane, resolution.x / resolution.y, {resolution.x, resolution.y})

  extensions.util_screenshotCreator.takeThumbnailScreenshot(filename, {
    pos = camPos,
    rot = camRot,
    fov = fov,
    nearPlane = nearPlane,
    screenshotDelay = 0.5
  }, callback)
end

local function setVehicleDirty(inventoryId)
  dirtiedVehicles[inventoryId] = true
end

local function isVehicleListedForAuction(inventoryId)
  local v = vehicles[inventoryId]
  return v and v.listedForAuction == true
end

local function getListedVehicleId()
  for id, v in pairs(vehicles) do
    if v.listedForAuction then
      return id
    end
  end
end

local function setVehicleListedForAuction(inventoryId, listed)
  local v = vehicles[inventoryId]
  if not v or not v.owned then
    return false
  end
  if listed then
    if career_modules_insurance_insurance and career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
      ui_message("Repair this vehicle before listing it at auction.", nil, "vehicleInventory")
      return false
    end
    local existing = getListedVehicleId()
    if existing and existing ~= inventoryId then
      return false
    end
    if inventoryIdToVehId[inventoryId] then
      M.updatePartConditions(nil, inventoryId, function()
        v.listedForAuction = true
        if inventoryIdToVehId[inventoryId] then
          M.removeVehicleObject(inventoryId)
        end
        setVehicleDirty(inventoryId)
      end)
      return true
    end
    v.listedForAuction = true
  else
    v.listedForAuction = nil
  end
  setVehicleDirty(inventoryId)
  return true
end

local function clearVehicleAuctionListing(inventoryId)
  local v = vehicles[inventoryId]
  if v then
    v.listedForAuction = nil
    setVehicleDirty(inventoryId)
  end
end

local nextPartConditionBatch = 0
local cancelledPartConditionBatches = {}

local function beginPartConditionBatch()
  nextPartConditionBatch = nextPartConditionBatch + 1
  return nextPartConditionBatch
end

local function cancelPartConditionBatch(batchToken)
  if batchToken then
    cancelledPartConditionBatches[batchToken] = true
  end
end

local function isLivePartConditionBatch(batchToken)
  if batchToken == nil then return true end
  return cancelledPartConditionBatches[batchToken] ~= true
end

local function updatePartConditionsOfSpawnedVehicles(callback)
  local batchToken
  if callback then
    batchToken = beginPartConditionBatch()
  end
  local expectedCount = tableSize(vehIdToInventoryId)
  local callbackCounter = 0
  local function maybeFinish()
    if callback and callbackCounter >= expectedCount then
      callback()
    end
  end
  for vehId, inventoryId in pairs(vehIdToInventoryId) do
    setVehicleDirty(inventoryId)

    M.updatePartConditions(vehId, inventoryId, callback and function()
      if not isLivePartConditionBatch(batchToken) then return end
      callbackCounter = callbackCounter + 1
      maybeFinish()
    end, batchToken)
  end
  if callback and expectedCount == 0 then
    callback()
  end
  return batchToken
end

-- Vehicle switching only needs a condition snapshot from the car the player is
-- leaving. Waiting for every other spawned inventory vehicle makes the switch
-- scale with the number and complexity of cars around the garage. Full saves
-- still use updatePartConditionsOfSpawnedVehicles so background vehicle damage
-- is persisted without holding up normal entry/exit.
local function updatePartConditionsOfCurrentVehicle(callback)
  local inventoryId = currentVehicle
  if not inventoryId then
    if callback then callback() end
    return
  end

  setVehicleDirty(inventoryId)
  M.updatePartConditions(inventoryIdToVehId[inventoryId], inventoryId, callback)
end

local extensionName = "inventory"
local finishedSaveTasks = {}

local function inventorySaveFinished(currentSavePath, generation)
  if not career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, generation) then
    return
  end
  -- if there are more async saving steps waiting for the vehicle save to finish, we need to call registerAsyncSaveExtension inside their onVehicleSaveFinished function first
  extensions.hook("onVehicleSaveFinished", currentSavePath)
  career_saveSystem.asyncSaveExtensionFinished(extensionName, generation)
  guihooks.trigger("saveFinished")
end

local function onSaveCurrentProfileAsyncStart()
  cancelPartConditionBatch(finishedSaveTasks.partConditionsBatch)
  finishedSaveTasks = {
    generation = career_saveSystem.registerAsyncSaveExtension(extensionName)
  }
end

local function checkSaveFinished(currentSavePath, task)
  task = task or finishedSaveTasks
  for key, fin in pairs(task) do
    if key ~= "generation" and key ~= "partConditionsBatch" and not fin then
      return
    end
  end
  inventorySaveFinished(currentSavePath, task.generation)
end

-- Stock takeThumbnailScreenshot hardcodes one render view ("thumbnail").
-- One shared worker across save invocations so overlapping autosaves cannot
-- start a second capture chain while an earlier one is still in flight.
local thumbnailCaptureQueue = {}
local thumbnailCaptureBusy = false

local function pumpThumbnailCaptures()
  if thumbnailCaptureBusy then
    return
  end
  local job = table.remove(thumbnailCaptureQueue, 1)
  if not job then
    return
  end
  thumbnailCaptureBusy = true
  updateVehicleThumbnail(job.id, job.filename, function()
    thumbnailCaptureBusy = false
    if job.onComplete then
      job.onComplete()
    end
    pumpThumbnailCaptures()
  end)
end

local function enqueueThumbnailCapture(inventoryId, filename, onComplete)
  table.insert(thumbnailCaptureQueue, {
    id = inventoryId,
    filename = filename,
    onComplete = onComplete,
  })
  pumpThumbnailCaptures()
end

local function isPersonalInventoryId(inventoryId)
  if type(inventoryId) == "number" then
    return true
  end
  if type(inventoryId) == "string" and tonumber(inventoryId) ~= nil then
    return true
  end
  return false
end

local function saveVehiclesData(currentSavePath, vehiclesThumbnailUpdate, task)
  task = task or finishedSaveTasks
  local vehiclesCopy = deepcopy(vehicles)
  local currentDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

  for id, vehicle in pairs(vehiclesCopy) do
    if isPersonalInventoryId(id) then
      if dirtiedVehicles[id] or not vehicle.dirtyDate then
        vehicles[id].dirtyDate = currentDate
        vehicle.dirtyDate = currentDate
        dirtiedVehicles[id] = nil
      end

      if not isExperimentalMaintenanceEnabled() then
        if type(vehicle.partConditions) == "table" then
          vehicle.partConditions = sanitizeMaintenancePartConditionsForVehicle(vehicle, vehicle.partConditions)
        end
        vehicle.maintenanceState = nil
        vehicles[id].maintenanceState = nil
      end

      vehicle.partConditions = serialize(vehicle.partConditions)

      -- Save parts as a flat pc-style map
      if vehicle.config then
        if vehicle.config.partsTree and core_vehicle_partmgmt and core_vehicle_partmgmt.partsTreeToPartsMap then
          vehicle.config.parts = core_vehicle_partmgmt.partsTreeToPartsMap(vehicle.config.partsTree)
        end
        if core_vehicle_partmgmt then
          vehicle.config.partsTree = nil
        end
      end

      local thumbnailFilename = currentSavePath .. "/career/vehicles/" .. id .. ".jpg"
      if vehiclesThumbnailUpdate and tableContains(vehiclesThumbnailUpdate, id) and inventoryIdToVehId[id] then
        task["thumbnail" .. id] = false
        enqueueThumbnailCapture(id, thumbnailFilename, function()
          task["thumbnail" .. id] = true
          checkSaveFinished(currentSavePath, task)
        end)
        vehicle.defaultThumbnail = nil
        vehicles[id].defaultThumbnail = nil

      elseif not vehicle.defaultThumbnail then
        local _, oldSavePath = career_saveSystem.getCurrentProfile()
        FS:copyFile(oldSavePath .. "/career/vehicles/" .. id .. ".jpg", thumbnailFilename)
      end

      -- save damage state
      career_modules_damageManager.saveDamageState(id, currentSavePath .. "/career/vehicles/damage/" .. id .. "_damageState.json")

      career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicles/" .. id .. ".json", vehicle, true)
    end
  end

  if currentVehicle then
    dirtiedVehicles[currentVehicle] = true
  end

  -- Remove vehicle files for vehicles that have been deleted
  local files = FS:findFiles(currentSavePath .. "/career/vehicles/", '*.json', 0, false, false)
  for i = 1, tableSize(files) do
    local dir, filename, ext = path.split(files[i])
    local fileNameNoExt = string.sub(filename, 1, -6)
    local inventoryId = tonumber(fileNameNoExt)
    if not vehicles[inventoryId] then
      FS:removeFile(dir .. filename)
      FS:removeFile(dir .. inventoryId .. ".jpg")
    end
  end
end

-- TODO update a vehicles part conditions in the table when you exit a vehicle
local function onSaveCurrentProfile(currentSavePath, vehiclesThumbnailUpdate)
  -- Realistic walk-enter (and similar paths) can seat the player in an owned
  -- car without setting currentVehicle. Recover before writing inventory.json
  -- so the next load restores world position instead of the starting garage.
  if not currentVehicle then
    local playerVehId = be and be:getPlayerVehicleID(0)
    if playerVehId and playerVehId > 0 then
      local seatedInvId = vehIdToInventoryId[playerVehId]
      if seatedInvId then
        currentVehicle = seatedInvId
        lastVehicle = seatedInvId
      end
    end
  end

  local data = {}
  data.currentVehicle = currentVehicle
  data.lastVehicle = lastVehicle
  data.favoriteVehicle = favoriteVehicle

  data.spawnedPlayerVehicles = {}
  for inventoryId, vehId in pairs(inventoryIdToVehId) do
    if isPersonalInventoryId(inventoryId) then
      local veh = getObjectByID(vehId)
      if veh then
        -- String keys so JSON keeps an object ({"1":...}) instead of an array.
        data.spawnedPlayerVehicles[tostring(inventoryId)] = {
          pos = veh:getPosition(),
          rot = quat(0,0,1,0) * quat(veh:getRefNodeRotation())
        }
      end
    end
  end

  if gameplay_walk.isWalking() then
    local playerVeh = getPlayerVehicle(0)
    if playerVeh then
      data.unicyclePos = playerVeh:getPosition()
    end
  end

  if career_modules_usedCarAuction and career_modules_usedCarAuction.applyInventorySpawnOverrides then
    career_modules_usedCarAuction.applyInventorySpawnOverrides(data)
  end

  local task = finishedSaveTasks
  task.updatePartConditions = false
  local function finishPartConditionsStep()
    if task.updatePartConditions then
      return
    end
    task.updatePartConditions = true
    saveVehiclesData(currentSavePath, vehiclesThumbnailUpdate, task)
    checkSaveFinished(currentSavePath, task)
  end
  task.partConditionsBatch = updatePartConditionsOfSpawnedVehicles(finishPartConditionsStep)
  core_jobsystem.create(function(job)
    job.sleep(30)
    if not task.updatePartConditions then
      log("W", "inventory", "updatePartConditions timed out during save; continuing without fresh part data")
      cancelPartConditionBatch(task.partConditionsBatch)
      finishPartConditionsStep()
    end
  end)

  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/inventory.json", data, true)
end

local function assignInventoryIdToVehId(inventoryId, vehId)
  if vehIdToInventoryId[vehId] then
    inventoryIdToVehId[vehIdToInventoryId[vehId]] = nil
  end
  vehIdToInventoryId[vehId] = inventoryId
  inventoryIdToVehId[inventoryId] = vehId
end

local getNumberOfFreeSlots = function() 
  return career_modules_garageManager.getFreeSlots()
end

local function hasFreeSlot()
  return getNumberOfFreeSlots() > 0
end

local inventoryIdAfterUpdatingPartConditions
local function addVehicle(vehId, inventoryId, options)
  options = options or {}
  if options.owned == nil then options.owned = true end

  local vehicle = scenetree.findObjectById(vehId)
  local vehicleData = core_vehicle_manager.getVehicleData(vehId)

  if vehicle and vehicleData then
    local takesNoInventorySpace = options.takesNoInventorySpace
    if takesNoInventorySpace == nil and vehicle.JBeam and vehicleData.config and vehicleData.config.partConfigFilename then
      local dir, configName, ext = path.splitWithoutExt(vehicleData.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(vehicle.JBeam, configName)
      takesNoInventorySpace = baseConfig and baseConfig.takesNoInventorySpace
    end
    -- Hardcore (and similar) starter grants run before any garage exists; skip
    -- capacity so the gifted car still enters inventory and persists on save.
    if options.owned and not takesNoInventorySpace and not options.starter and not hasFreeSlot() then
      ui_message("No free garage space for another vehicle.", nil, "vehicleInventory")
      return nil
    end

    if not inventoryId then
      inventoryId = 1
      while vehicles[inventoryId] do
        inventoryId = inventoryId + 1
      end
    end
    -- vdata.information.name is often a locale table (dual-brand configs). Never
    -- persist that raw into inventory/insurance UI — Vue will dump the JSON.
    local niceName
    if vehicleData.vdata and vehicleData.vdata.information then
      niceName = vehicleData.vdata.information.name
    end
    if core_locales and core_locales.translateWithOrWithoutContext then
      local translated = core_locales.translateWithOrWithoutContext(niceName)
      if type(translated) == "string" and translated ~= "" then
        niceName = translated
      end
    end

    vehicles[inventoryId] = vehicles[inventoryId] or {}
    vehicles[inventoryId].model = vehicle.JBeam or ""
    vehicles[inventoryId].config = vehicleData.config
    vehicles[inventoryId].id = inventoryId
    vehicles[inventoryId].config.licenseName = core_vehicles.getVehicleLicenseText(vehicle)
    vehicles[inventoryId].owned = options.owned
    vehicles[inventoryId].defaultThumbnail = true
    vehicles[inventoryId].finalBuyingPrice = options.finalPrice

    if vehicle.JBeam and vehicleData.config and vehicleData.config.partConfigFilename then
      local dir, configName, ext = path.splitWithoutExt(vehicleData.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(vehicle.JBeam, configName)
      local catalogProfile = career_modules_valueCalculator and
        career_modules_valueCalculator.getVehicleCatalogProfile and
        career_modules_valueCalculator.getVehicleCatalogProfile(vehicle.JBeam, configName, baseConfig)
      vehicles[inventoryId].configBaseValue =
        (catalogProfile and catalogProfile.catalogValue) or baseConfig.Value
      vehicles[inventoryId].takesNoInventorySpace = baseConfig.takesNoInventorySpace

      if type(niceName) ~= "string" or niceName == "" then
        local configInfo = baseConfig or core_vehicles.getConfig(vehicle.JBeam, configName)
        if configInfo then
          local configLabel, brand = configInfo.Name, configInfo.Brand
          if core_locales and core_locales.translateWithOrWithoutContext then
            configLabel = core_locales.translateWithOrWithoutContext(configLabel)
            brand = core_locales.translateWithOrWithoutContext(brand)
          end
          if type(configLabel) == "string" and configLabel ~= "" then
            if type(brand) == "string" and brand ~= "" then
              niceName = brand .. " " .. configLabel
            else
              niceName = configLabel
            end
          end
        end
      end
    else
      log("D", "", "Couldnt find base value for added vehicle, so using default value")
      vehicles[inventoryId].configBaseValue = 1000
    end

    if type(niceName) ~= "string" or niceName == "" then
      niceName = vehicle.JBeam or "Vehicle"
    end
    vehicles[inventoryId].niceName = niceName

    assignInventoryIdToVehId(inventoryId, vehId)
    pendingMaintenanceSeedInventoryIds[inventoryId] = options.owned == true and vehicles[inventoryId].maintenanceState == nil

    inventoryIdAfterUpdatingPartConditions = inventoryId
    local serializedInventoryId = serialize(inventoryId)
    if options.skipPartConditionInit then
      vehicle:queueLuaCommand(string.format("obj:queueGameEngineLua('career_modules_inventory.updatePartConditions(%d, %s)')", vehId, serializedInventoryId))
    else
      vehicle:queueLuaCommand(string.format("if not partCondition.getConditions() then partCondition.initConditions() end obj:queueGameEngineLua('career_modules_inventory.updatePartConditions(%d, %s)')", vehId, serializedInventoryId))
    end

    local amountOfVehicles = tableSize(vehicles)
    if amountOfVehicles == 1 then
      M.setFavoriteVehicle(inventoryId)
    end
    if amountOfVehicles >= 3 then
      gameplay_achievement.unlockAchievement("GARAGE_STARTER")
    end
    return inventoryId
  end
end

local skipPartConditionsBeforeWalking
local function clearMapCollisionReferences(vehId)
  if not map or not map.objects then return end
  for _, mapObj in pairs(map.objects) do
    if mapObj and mapObj.objectCollisions then
      mapObj.objectCollisions[vehId] = nil
    end
  end
end

local function removeVehicleObject(inventoryId, skipPartConditions)
  if currentVehicle == inventoryId then
    skipPartConditionsBeforeWalking = true
    currentVehicle = nil
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
  extensions.hook("onInventoryPreRemoveVehicleObject", inventoryId, M.getVehicleIdFromInventoryId(inventoryId))
  -- TODO save part conditions
  local vehId = inventoryIdToVehId[inventoryId]
  if vehId then
    -- Drop traffic tracking before the world object is deleted so police/AI
    -- collision checks don't index a stale getObjectByID nil (loaner return).
    if gameplay_traffic then
      pcall(function() gameplay_traffic.removeTraffic(vehId) end)
    end
    clearMapCollisionReferences(vehId)
    local obj = getObjectByID(vehId)
    if obj and not skipPartConditions then
      career_modules_damageManager.saveDamageState(inventoryId, nil, true) -- remove vehicle
    elseif obj and skipPartConditions then
      obj:delete()
    end
    vehIdToInventoryId[vehId] = nil
  end
  inventoryIdToVehId[inventoryId] = nil
end

local function removeVehicle(inventoryId)
  removeVehicleObject(inventoryId)
  vehicles[inventoryId] = nil
  extensions.hook("onVehicleRemoved", inventoryId)

  if favoriteVehicle == inventoryId then
    M.setFavoriteVehicle(next(vehicles))
  end
end

local function onPartConditionsUpdateFinished()
  if inventoryIdAfterUpdatingPartConditions then
    local completedInventoryId = inventoryIdAfterUpdatingPartConditions
    inventoryIdAfterUpdatingPartConditions = nil
    -- Contract targets use namespaced, non-personal inventory IDs so they can
    -- share normal vehicle condition handling without being serialized as
    -- player-owned vehicles. Career's part inventory assumes numeric IDs and
    -- must not register these temporary targets.
    if isPersonalInventoryId(completedInventoryId) then
      extensions.hook("onVehicleAdded", completedInventoryId)
    end
  end
end

local function seedInitialMaintenanceStateForVehicle(inventoryId)
  local vehicleData = vehicles[inventoryId]
  if not vehicleData or not pendingMaintenanceSeedInventoryIds[inventoryId] then
    return false
  end

  pendingMaintenanceSeedInventoryIds[inventoryId] = nil

  if vehicleData.owned ~= true or vehicleData.maintenanceState ~= nil then
    return false
  end

  local mileageMeters = M.setMileage(inventoryId) or 0
  vehicleData.maintenanceState = maintenanceComputerConfig.buildInitialSnapshotForMileage(mileageMeters, "meters", vehicleData)

  if vehicleMaintenance and vehicleMaintenance.syncVehicleMaintenance then
    vehicleMaintenance.syncVehicleMaintenance(inventoryId)
  end

  return true
end

local function getPartConditionsCallback(partConditions, inventoryId, batchToken)
  if not isLivePartConditionBatch(batchToken) then
    return
  end
  local conditionsType = type(partConditions)
  if conditionsType ~= "table" then
    onPartConditionsUpdateFinished()
    return
  end
  local count = 0
  for _ in pairs(partConditions) do count = count + 1 end
  if not vehicles[inventoryId] then
    onPartConditionsUpdateFinished()
    return
  end
  partConditions = sanitizeMaintenancePartConditionsForVehicle(vehicles[inventoryId], partConditions)
  vehicles[inventoryId].partConditions = partConditions
  seedInitialMaintenanceStateForVehicle(inventoryId)
  extensions.hook("onVehiclePartConditionsChanged", inventoryId)
  onPartConditionsUpdateFinished()
  career_modules_partInventory.updatePartConditionsInInventory(inventoryId)
end

local function updatePartConditions(vehId, inventoryId, callback, batchToken)
  if inventoryId and isVehicleListedForAuction(inventoryId) then
    if callback then callback() end
    return
  end
  local veh
  if vehId then
    veh = getObjectByID(vehId)
  else
    veh = getObjectByID(inventoryIdToVehId[inventoryId])
  end
  if not veh then
    log("E", "", "Couldnt find vehicle object to get part conditions")
    if callback then callback() end
    return
  end

  core_vehicleBridge.requestValue(
    veh,
    function(res)
      getPartConditionsCallback(res.result, inventoryId, batchToken)
      if callback then callback() end
    end,
    'getPartConditions'
  )
end

local function applyPartConditions(inventoryId, vehId)
  local veh = scenetree.findObjectById(vehId or inventoryIdToVehId[inventoryId])
  if not veh then return end
  core_vehicleBridge.executeAction(veh, 'initPartConditions', vehicles[inventoryId].partConditions)
end

-- replaceOption 1: replace the current vehicle object
-- replaceOption 2: replace the vehicle object with the same inventoryId
local function spawnVehicle(inventoryId, replaceOption, callback)
  local vehInfo = vehicles[inventoryId]
  if vehInfo and vehInfo.listedForAuction then
    ui_message("This vehicle is listed at the auction and cannot be spawned.", nil, "vehicleInventory")
    if callback then
      callback()
    end
    return
  end

  if not vehInfo then
    log("E", "career.inventory", string.format("spawnVehicle: no inventory vehicle %s", tostring(inventoryId)))
    return
  end

  local carConfigToLoad = vehInfo.config
  local carModelToLoad = vehInfo.model
  if not carConfigToLoad then
    log("E", "career.inventory", string.format("spawnVehicle: id %s has no config", tostring(inventoryId)))
    return
  end

  local modelMissing = tableIsEmpty(core_vehicles.getModel(carModelToLoad))
  local pcPath = carConfigToLoad.partConfigFilename
  local pcExists = false
  if type(pcPath) == "string" and pcPath ~= "" then
    pcExists = FS:fileExists(pcPath) or FS:fileExists("/" .. pcPath:gsub("^/", ""))
  end
  local hasParts = type(carConfigToLoad.parts) == "table" and next(carConfigToLoad.parts) ~= nil
  local hasPartsTree = type(carConfigToLoad.partsTree) == "table" and next(carConfigToLoad.partsTree) ~= nil

  log("I", "career.inventory", string.format(
    "spawnVehicle: id=%s model=%s pc=%s pcExists=%s hasParts=%s modelMissing=%s missingFile=%s",
    tostring(inventoryId), tostring(carModelToLoad), tostring(pcPath),
    tostring(pcExists), tostring(hasParts or hasPartsTree), tostring(modelMissing),
    tostring(vehInfo.missingFile)))

  if modelMissing then
    log("E", "career.inventory", string.format("spawnVehicle: skip id %s - model missing: %s", tostring(inventoryId), tostring(carModelToLoad)))
    return
  end
  if not pcExists and not hasParts and not hasPartsTree then
    log("E", "career.inventory", string.format(
      "spawnVehicle: skip id %s - no pc and no parts (pc=%s)", tostring(inventoryId), tostring(pcPath)))
    return
  end

  local vehObj
  local vehicleData = {}
  -- Always deepcopy inventory configs so we can safely strip a bad .pc path and
  -- flatten partsTree without mutating the save table in memory.
  local spawnConfig = deepcopy(carConfigToLoad)
  if spawnConfig.partsTree and core_vehicle_partmgmt and core_vehicle_partmgmt.partsTreeToPartsMap then
    spawnConfig.parts = core_vehicle_partmgmt.partsTreeToPartsMap(spawnConfig.partsTree)
    spawnConfig.partsTree = nil
    hasParts = type(spawnConfig.parts) == "table" and next(spawnConfig.parts) ~= nil
  end
  -- Prefer in-save parts over a missing/renamed .pc file.
  if hasParts or (type(spawnConfig.parts) == "table" and next(spawnConfig.parts) ~= nil) then
    if not pcExists then
      spawnConfig.partConfigFilename = nil
    end
  elseif not pcExists then
    spawnConfig.partConfigFilename = nil
  end

  vehicleData.config = spawnConfig
  vehicleData.keepOtherVehRotation = true

  local spawnOk, spawnResult = pcall(function()
    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false})
    if replaceOption == 1 then
      return core_vehicles.replaceVehicle(carModelToLoad, vehicleData)
    elseif replaceOption == 2 then
      local oldVehId = inventoryIdToVehId[inventoryId]
      local oldVehObj = oldVehId and getObjectByID(oldVehId) or nil
      return core_vehicles.replaceVehicle(carModelToLoad, vehicleData, oldVehObj)
    end
    vehicleData.autoEnterVehicle = false
    return core_vehicles.spawnNewVehicle(carModelToLoad, vehicleData)
  end)

  if not spawnOk then
    log("E", "career.inventory", string.format(
      "spawnVehicle: spawn threw for id %s (%s): %s",
      tostring(inventoryId), tostring(carModelToLoad), tostring(spawnResult)))
    return
  end
  vehObj = spawnResult

  if not vehObj then
    log("E", "career.inventory", string.format("Couldnt spawn vehicle id %s (%s)", tostring(inventoryId), tostring(carModelToLoad)))
    return
  end

  local postOk, postErr = pcall(function()
    vehObj:queueLuaCommand("extensions.load('individualRepair')")
    assignInventoryIdToVehId(inventoryId, vehObj:getID())

    if vehInfo.partConditions then
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehInfo.partConditions, 0, 1, 1)
      core_vehicleBridge.requestValue(vehObj, function()
        career_modules_partInventory.updatePartsToMatchSpawnedVehicle(inventoryId)
        if callback then callback() end
      end, 'ping')
    else
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
      core_vehicleBridge.requestValue(vehObj, function(res) career_modules_inventory.updatePartConditions(nil, inventoryId, callback) end, 'ping')
    end

    gameplay_walk.removeVehicleFromBlacklist(vehObj:getId())

    if inventoryId then
      vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
      M.setMileage(inventoryId)
      vehObj:queueLuaCommand(string.format(
        [[
          local cert = {}
          local engines = powertrain.getDevicesByCategory("engine")
          local engine = engines and engines[1]
          cert.power = engine and engine.maxPower or 0
          cert.torque = engine and engine.maxTorque or 0
          cert.weight = obj:calcBeamStats().total_weight
          obj:queueGameEngineLua("career_modules_inventory.setCertifications(%s, " .. serialize(cert) .. ")")
        ]],
        vehObj:getID()))
    end

    local brokenPartCount = vehInfo.partConditions and career_modules_valueCalculator.getNumberOfBrokenParts(vehInfo.partConditions) or 0
    if brokenPartCount > 0 then
      career_modules_damageManager.loadDamageState(inventoryId)
    else
      career_modules_damageManager.clearDamageState(inventoryId)
      vehObj:queueLuaCommand("extensions.load('individualRepair'); if individualRepair then individualRepair.reset(); end")
    end
    if gameplay_traffic and gameplay_traffic.insertTraffic then
      gameplay_traffic.insertTraffic(vehObj:getID(), true, true)
      if gameplay_police and gameplay_police.suppressSpeedingOffense then
        -- Covers spawn-to-garage-teleport window during storage retrieval.
        gameplay_police.suppressSpeedingOffense(vehObj:getID(), 3)
      end
    end
  end)

  if not postOk then
    log("E", "career.inventory", string.format(
      "spawnVehicle: post-spawn setup threw for id %s: %s (vehicle still returned)",
      tostring(inventoryId), tostring(postErr)))
  end

  -- Clear stale missingFile once we successfully spawned from parts/pc.
  vehInfo.missingFile = nil
  log("I", "career.inventory", string.format("spawnVehicle: spawned id %s as vehId %s", tostring(inventoryId), tostring(vehObj:getID())))
  return vehObj
end

local function ensureGameCamera()
  if commands.isFreeCamera and commands.isFreeCamera() then
    commands.setGameCamera()
  end
end

-- Career load (map switch and normal quit/reload) starts freeroam with no
-- player first, so free cam can win a race against enterVehicle / walk teleport.
-- Retry briefly after freeroam/camera settle.
local function ensureGameCameraWithRetry()
  if commands.setGameCamera then
    commands.setGameCamera()
  end
  core_jobsystem.create(function(job)
    for _ = 1, 6 do
      job.sleep(0.5)
      if commands.isFreeCamera and commands.isFreeCamera() and commands.setGameCamera then
        commands.setGameCamera()
      elseif commands.setGameCamera then
        commands.setGameCamera()
      end
    end
  end)
end

-- loadOption 1: dont reload the vehicle
-- loadOption 2: force reload the vehicle
local enterCallbackFunction
local function enterVehicleActual(id, loadOption)
  if not id or loadOption == 1 then
    currentVehicle = id
  elseif inventoryIdToVehId[id] and loadOption ~= 2 then
    -- vehicle is already spawned. enter it
    gameplay_walk.setWalkingMode(false, nil, nil, true)
    be:enterVehicle(0, getObjectByID(inventoryIdToVehId[id]))
    currentVehicle = id
    ensureGameCamera()
  else
    if spawnVehicle(id, 1, enterCallbackFunction) then
      currentVehicle = id
      ensureGameCamera()
    end
    enterCallbackFunction = nil
  end
  if currentVehicle then
    dirtiedVehicles[currentVehicle] = true
  end
  extensions.hook("onEnterVehicleFinished", currentVehicle)

  if enterCallbackFunction then enterCallbackFunction() end
end

-- loadOption 1: dont reload the vehicle
-- loadOption 2: force reload the vehicle
local function enterVehicle(newInventoryId, loadOption, callback)
  local vehInfo = vehicles[newInventoryId]
  if vehInfo and vehInfo.timeToAccess then return end
  if vehInfo and vehInfo.listedForAuction then
    ui_message("This vehicle is listed at the auction.", nil, "vehicleInventory")
    return
  end
  career_modules_log.addLog(string.format("Enter vehicle %s", newInventoryId or "no vehicle"), "inventory")

  enterCallbackFunction = callback
  if loadOption == 1 then
    enterVehicleActual(newInventoryId, loadOption)
    return
  end
  if currentVehicle then
    updatePartConditionsOfCurrentVehicle(function() enterVehicleActual(newInventoryId, loadOption) end)
  else
    enterVehicleActual(newInventoryId, loadOption)
  end
end

local saveCareer
local inventorySetupDone = false
local pendingWalkRestore = false
local lastFailedSpawnPos = nil

-- Career loads freeroam with preventPlayerSpawning, so the unicycle often does
-- not exist yet. Force walking (same as store-car) and keep retrying until it does.
local function teleportWalkFallback(levelName, preferredPos, preferredRot)
  spawn.preventPlayerSpawning = nil
  gameplay_walk.setWalkingMode(true, preferredPos, preferredRot, true)
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    log("W", "career.inventory", "teleportWalkFallback: unicycle not ready yet")
    pendingWalkRestore = true
    return false
  end
  pendingWalkRestore = false

  if preferredPos then
    local ok, err = pcall(function()
      spawn.safeTeleport(playerVeh, preferredPos, preferredRot)
    end)
    if ok then
      log("I", "career.inventory", "Walk restore teleported to saved position")
      ensureGameCameraWithRetry()
      return true
    end
    log("W", "career.inventory", "Walk restore saved-pos teleport failed: " .. tostring(err))
  end

  local levelGate = scenetree.findObject("Level Gate")
  if levelGate then
    pcall(function()
      spawn.safeTeleport(playerVeh, levelGate:getPosition(), levelGate:getRotation())
    end)
    log("I", "career.inventory", "Walk restore teleported to Level Gate")
    ensureGameCameraWithRetry()
    return true
  end

  teleportPlayerToStartingGarage(levelName)
  log("I", "career.inventory", "Walk restore teleported to starting garage")
  ensureGameCameraWithRetry()
  return true
end

local function setupInventory(levelPath)
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then
    log("E", "career.inventory", "setupInventory: no save path")
    return
  end

  local data = jsonReadFile(savePath .. "/info.json")
  local generalData = jsonReadFile(savePath .. "/career/general.json")
  local levelName = generalData and generalData.level or getCurrentLevelIdentifier()
  local justSwitched = generalData and generalData.justSwitched or false
  local tutorialActive = career_career.tutorialEnabled

  local pendingCount = 0
  if loadedVehiclesLocations then
    for _ in pairs(loadedVehiclesLocations) do pendingCount = pendingCount + 1 end
  end
  log("I", "career.inventory", string.format(
    "setupInventory: begin level=%s justSwitched=%s tutorial=%s pendingSpawns=%s current=%s alreadyDone=%s",
    tostring(levelName), tostring(justSwitched), tostring(tutorialActive),
    tostring(pendingCount), tostring(vehicleToEnterId), tostring(inventorySetupDone)))

  -- Allow a second pass while pending world spawns remain, or while walking
  -- restore still has no unicycle (stored-car save).
  if inventorySetupDone and not pendingWalkRestore and not (loadedVehiclesLocations and pendingCount > 0) then
    log("D", "career.inventory", "setupInventory: skip (already completed)")
    return
  end

  if justSwitched
    and career_modules_difficultyMode
    and career_modules_difficultyMode.isHardcoreMode
    and not career_modules_difficultyMode.isHardcoreMode() then
    career_modules_garageManager.purchaseDefaultGarage()
  end

  lastFailedSpawnPos = nil

  if not tutorialActive then
    -- On world-ready retry, re-pick a current vehicle from remaining spawns.
    if not vehicleToEnterId and loadedVehiclesLocations then
      for inventoryId, _ in pairs(loadedVehiclesLocations) do
        if vehicles[inventoryId] then
          vehicleToEnterId = inventoryId
          break
        end
      end
    end

    local remainingSpawns = {}
    if loadedVehiclesLocations then
      for inventoryId, location in pairs(loadedVehiclesLocations) do
        local vehInfo = vehicles[inventoryId]
        if not vehInfo then
          log("E", "career.inventory", string.format("setupInventory: missing vehicle data for spawned id %s", tostring(inventoryId)))
          remainingSpawns[inventoryId] = location
        elseif vehInfo.loanType == "work" then
          career_modules_loanerVehicles.returnVehicle(inventoryId)
          loanedVehicleReturned = true
        else
          local shouldSpawn = (not justSwitched) or (vehicleToEnterId == inventoryId)
          if not shouldSpawn then
            log("I", "career.inventory", string.format(
              "setupInventory: deferring non-current vehicle %s during justSwitched", tostring(inventoryId)))
          else
            local spawnOk, vehOrErr = pcall(function()
              return spawnVehicle(inventoryId)
            end)
            local veh = spawnOk and vehOrErr or nil
            if not spawnOk then
              log("E", "career.inventory", string.format(
                "setupInventory: spawnVehicle threw for %s: %s", tostring(inventoryId), tostring(vehOrErr)))
            end
            if veh then
              local teleportOk, teleportErr = pcall(function()
                local pos, rot = location.pos, location.rot
                if justSwitched then
                  local levelGate = scenetree.findObject("Level Gate")
                  if levelGate then
                    pos = levelGate:getPosition()
                    rot = levelGate:getRotation()
                  end
                end
                spawn.safeTeleport(veh, pos, rot)
              end)
              if not teleportOk then
                log("E", "career.inventory", string.format(
                  "setupInventory: safeTeleport threw for %s: %s", tostring(inventoryId), tostring(teleportErr)))
                remainingSpawns[inventoryId] = location
                if vehicleToEnterId == inventoryId then
                  lastFailedSpawnPos = location.pos
                  vehicleToEnterId = nil
                end
              else
                log("I", "career.inventory", string.format(
                  "setupInventory: restored vehicle %s at saved/world position", tostring(inventoryId)))
              end
            else
              remainingSpawns[inventoryId] = location
              if vehicleToEnterId == inventoryId then
                lastFailedSpawnPos = location and location.pos or nil
                log("W", "career.inventory", string.format(
                  "setupInventory: failed to spawn current vehicle %s; will walk-fallback",
                  tostring(inventoryId)))
                vehicleToEnterId = nil
              end
            end
          end
        end
      end

      if next(remainingSpawns) then
        loadedVehiclesLocations = remainingSpawns
        inventorySetupDone = false
        log("W", "career.inventory", "setupInventory: some spawns remain pending for retry")
      else
        loadedVehiclesLocations = nil
        inventorySetupDone = true
      end
    else
      -- No world-spawned cars: walking restore. Do not mark done until unicycle exists.
      inventorySetupDone = false
    end

    if vehicleToEnterId and inventoryIdToVehId[vehicleToEnterId] then
      local enterOk, enterErr = pcall(function()
        enterVehicle(vehicleToEnterId)
      end)
      if not enterOk then
        log("E", "career.inventory", "setupInventory: enterVehicle threw: " .. tostring(enterErr))
        if teleportWalkFallback(levelName, lastFailedSpawnPos) then
          inventorySetupDone = true
        end
      else
        pendingWalkRestore = false
        inventorySetupDone = true
        ensureGameCameraWithRetry()
      end
    else
      if teleportWalkFallback(levelName, lastFailedSpawnPos or unicycleSavedPosition) then
        inventorySetupDone = true
      end
    end
    extensions.hook("onSetupInventoryFinished")
  else
    gameplay_walk.setWalkingMode(true)
    ensureGameCameraWithRetry()
    inventorySetupDone = true
  end

  local newCareerSave = not data

  -- this means this is a new career save
  if newCareerSave and not tutorialActive then
    saveCareer = 0
  end

  if newCareerSave or tutorialActive then
    if career_career.hardcoreMode then
      local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
      local hardcoreFilter = {
        whiteList = {
          ["Config Type"] = {"Hardcore"}
        }
      }
      local hardcoreVehicleInfos = util_configListGenerator.getRandomVehicleInfos({
        filter = hardcoreFilter
      }, 6, eligibleVehicles, "Population")
      if not hardcoreVehicleInfos or #hardcoreVehicleInfos == 0 then
        log("E", "career.inventory", "Hardcore starter: no vehicles with Config Type Hardcore found")
      else
        log("I", "career.inventory", string.format("Hardcore starter pool size: %d", #hardcoreVehicleInfos))
        local randomVehicleInfo = hardcoreVehicleInfos[math.random(#hardcoreVehicleInfos)]
        local model = randomVehicleInfo.model_key
        -- Prefer pcFilename; fall back to model-root key path (not /configurations/).
        local config = randomVehicleInfo.pcFilename
          or ('/vehicles/' .. model .. '/' .. randomVehicleInfo.key .. '.pc')
        local pos, rot = vec3(-24.026, 609.157, 75.112), quatFromDir(vec3(1, 0, 0))
        local options = {
          config = config,
          licenseText = "Hardcore",
          vehicleName = "First Car",
          pos = pos,
          rot = rot
        }
        local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
        spawningOptions.autoEnterVehicle = false
        local veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
        core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)
        core_vehicles.setPlateText("Uncle's", veh:getID())

        gameplay_walk.setWalkingMode(true)
        -- move walking character into position
        spawn.safeTeleport(getPlayerVehicle(0), vec3(-20.746, 598.736, 75.112))
        gameplay_walk.setRot(vec3(0, 1, 0), vec3(0, 0, 1))
        local mileage = 900000 * 1609.344
        veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, 0.5))
        local inventoryId = M.addVehicle(veh:getID(), nil, {
          starter = true
        })
        if inventoryId then
          -- Starter cars are gifts, not insured purchases.
          extensions.hook("onVehicleAddedToInventory", {
            inventoryId = inventoryId,
            purchaseData = {insuranceId = -1},
          })
          if career_career.setBoughtStarterVehicle then
            career_career.setBoughtStarterVehicle(true)
          end
        else
          log("E", "career.inventory", "Hardcore starter vehicle spawned but failed to enter inventory")
        end
      end
    elseif not tutorialActive then
      teleportPlayerToStartingGarage(levelName)
      career_modules_garageManager.purchaseDefaultGarage()
    else
      local modeData = career_career.getCurrentStartingModeData and career_career.getCurrentStartingModeData()
      local setupInventoryFn = modeData and modeData.setupInventory
      if type(setupInventoryFn) == "function" then
        setupInventoryFn(M)
      else
        log("W", "career.inventory", "No setupInventory hook found for starting mode. Falling back to tutorial setup.")
        gameplay_tutorial_setup.setupVehicles()
      end
      career_modules_garageManager.purchaseDefaultGarage()
    end
  else
    if gameplay_walk.isWalking() then
      if justSwitched then
        local levelGate = scenetree.findObject("Level Gate")
        if levelGate then
          spawn.safeTeleport(getPlayerVehicle(0), levelGate:getPosition(), levelGate:getRotation())
        else
          teleportPlayerToStartingGarage(levelName)
        end
      elseif unicycleSavedPosition then
        spawn.safeTeleport(getPlayerVehicle(0), unicycleSavedPosition)
      elseif lastFailedSpawnPos then
        -- already handled in teleportWalkFallback when spawn failed
      else
        teleportPlayerToStartingGarage(levelName)
      end
      ensureGameCameraWithRetry()
    end
    extensions.hook("onEnterVehicleFinished", currentVehicle)
  end

  commands.setGameCamera()
  log("I", "career.inventory", string.format(
    "setupInventory: end walking=%s current=%s freecam=%s",
    tostring(gameplay_walk.isWalking and gameplay_walk.isWalking()),
    tostring(currentVehicle),
    tostring(commands.isFreeCamera and commands.isFreeCamera())))
end

local function refreshPendingMigration()
  if pendingMigrationApplication then return true end
  if not (career_saveMigration and career_saveMigration.getPreparedMigration) then return false end

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return false end

  local saveFolder = savePath:gsub("[/\\]+$", ""):match("([^/\\]+)$")
  local migrationPlan = career_saveMigration.getPreparedMigration(saveSlot, saveFolder)
  if type(migrationPlan) ~= "table" or migrationPlan.status == "applied" then return false end

  currentMigrationSaveFolder = saveFolder
  pendingMigrationPlan = deepcopy(migrationPlan)
  pendingMigrationCashOutVehicleIds = deepcopy(migrationPlan.cashOutVehicleIds or {})
  pendingMigrationApplication = true
  for _, inventoryId in ipairs(migrationPlan.quarantinedVehicleIds or {}) do
    inventoryId = tonumber(inventoryId)
    if inventoryId and vehicles[inventoryId] then
      vehicles[inventoryId].migrationQuarantined = true
      vehicles[inventoryId].missingFile = true
    end
  end
  return true
end

applyPendingMigration = function()
  if not pendingMigrationApplication and not refreshPendingMigration() then return false end

  local appliedCashOutVehicleIds = {}
  local migrationPlan = pendingMigrationPlan or {}
  if migrationPlan.preprocessed then
    appliedCashOutVehicleIds = deepcopy(pendingMigrationCashOutVehicleIds or {})
  elseif type(pendingMigrationCashOutVehicleIds) == "table" then
    -- Compatibility for copies prepared by the first migration implementation.
    -- Wait for attributes, then liquidate directly and credit one combined
    -- transaction. The normal sellVehicle path saves after every car and is not
    -- safe while Career modules are still activating.
    if not (
      career_modules_playerAttributes
      and career_modules_playerAttributes.getAllAttributes
      and type(career_modules_playerAttributes.getAllAttributes()) == "table"
    ) then
      return false
    end

    local compensation = 0
    for _, inventoryId in ipairs(pendingMigrationCashOutVehicleIds) do
      inventoryId = tonumber(inventoryId)
      local vehicle = inventoryId and vehicles[inventoryId]
      if vehicle and isPersonalInventoryId(inventoryId) then
        if vehicle.owned ~= false then
          compensation = compensation + math.max(0, tonumber(vehicle.configBaseValue) or 0)
        end
        if vehicle.loanType ~= "work" then
          M.removeVehicle(inventoryId)
          table.insert(appliedCashOutVehicleIds, inventoryId)
        end
      end
    end
    if compensation > 0 then
      career_modules_playerAttributes.addAttributes(
        {money = compensation},
        {tags = {"migration", "selling"}, label = "Legacy save vehicle migration"}
      )
    end
  end

  local applied = true
  if career_saveMigration and career_saveMigration.markMigrationApplied then
    local saveSlot = career_saveSystem.getCurrentProfile()
    applied = career_saveMigration.markMigrationApplied(saveSlot, currentMigrationSaveFolder, appliedCashOutVehicleIds)
    if not applied then
      log("E", "career.inventory", "Failed to record the prepared Career migration as applied")
    end
  end

  if not applied then return false end
  pendingMigrationApplication = false
  pendingMigrationPlan = nil
  pendingMigrationCashOutVehicleIds = nil
  return true
end

local function onCareerActive(active)
  if not active then return end
  pendingWalkRestore = false
  local ok, err = pcall(setupInventory)
  if not ok then
    log("E", "career.inventory", "onCareerActive setupInventory threw: " .. tostring(err))
    ensureGameCameraWithRetry()
  end
end

local function onWorldReadyState(state)
  if state ~= 2 or not career_career.isActive() then return end
  -- Retry if first setup raced the vehicle DB / freeroam player spawn gate.
  if loadedVehiclesLocations and next(loadedVehiclesLocations) then
    log("I", "career.inventory", "onWorldReadyState: retrying pending vehicle restore")
    inventorySetupDone = false
    local ok, err = pcall(setupInventory)
    if not ok then
      log("E", "career.inventory", "onWorldReadyState setupInventory threw: " .. tostring(err))
      ensureGameCameraWithRetry()
    end
  elseif pendingWalkRestore then
    log("I", "career.inventory", "onWorldReadyState: retrying walking restore")
    inventorySetupDone = false
    local ok, err = pcall(setupInventory)
    if not ok then
      log("E", "career.inventory", "onWorldReadyState walk restore threw: " .. tostring(err))
      ensureGameCameraWithRetry()
    end
  elseif commands.isFreeCamera and commands.isFreeCamera() then
    ensureGameCameraWithRetry()
  end
end

local function setPartConditionResetSnapshot(veh, callback)
  core_vehicleBridge.executeAction(veh, 'createPartConditionSnapshot', "beforeReset")
  core_vehicleBridge.executeAction(veh, 'setPartConditionResetSnapshotKey', "beforeReset")
  if callback then
    core_vehicleBridge.requestValue(veh, callback, "ping")
  end
end

local function onBigMapActivated()
  if currentVehicle then
    setPartConditionResetSnapshot(getPlayerVehicle(0))
  end
end

local function teleportedFromBigmap()
  if currentVehicle and career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function getCurrentVehicle()
  return currentVehicle
end

local function getLastVehicle()
  return lastVehicle
end

local function getVehicleIdFromInventoryId(inventoryId)
  if inventoryId then
    return inventoryIdToVehId[inventoryId]
  end
end

local function getInventoryIdFromVehicleId(vehId)
  if vehId then
    return vehIdToInventoryId[vehId]
  end
end

local function getMapInventoryIdToVehId()
  return inventoryIdToVehId
end

local function getCurrentVehicleId()
  return getVehicleIdFromInventoryId(currentVehicle)
end

local function isSeatedInsideOwnedVehicle()
  return currentVehicle and true or false
end

local function getVehiclesInGarage(garage, intersecting)
  if not garage then return {} end
  local zones = freeroam_facilities.getZonesForFacility(garage)
  local spawnedVehicles = {}
  local res = {}
  for inventoryId, vehId in pairs(inventoryIdToVehId) do
    spawnedVehicles[inventoryId] = getObjectByID(vehId)
  end
  for _, zone in ipairs(zones) do
    for inventoryId, veh in pairs(spawnedVehicles) do
      if intersecting then
        local vehBB = veh:getWorldBox()
        local vehBBExtents = vehBB:getExtents() * 0.5
        local vehPos = veh:getPosition()
        local zoneExtents = vec3(zone.aabb.xMax - zone.aabb.xMin, zone.aabb.yMax - zone.aabb.yMin, zone.aabb.zMax - zone.aabb.zMin)
        zoneExtents.z = math.min(zoneExtents.z, 10000)
        if overlapsOBB_OBB(vehBB:getCenter(), xVec * vehBBExtents.x, yVec * vehBBExtents.y, zVec * vehBBExtents.z,
                           zone.center, xVec * zoneExtents.x/2, yVec * zoneExtents.y/2, zVec * zoneExtents.z/2) then
          for nodeId = 0, veh:getNodeCount() - 1 do
            if zone:containsPoint2D(veh:getNodePosition(nodeId) + vehPos) then
              res[inventoryId] = true
              break
            end
          end
        end
      elseif zone:containsVehicle(veh) then
        res[inventoryId] = true
      end
    end
  end
  return res
end

local function removeVehiclesFromGarageExcept(inventoryId)
  local garage = getClosestGarage()
  local inventoryIdsInGarage = getVehiclesInGarage(garage, true)
  for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
    if otherInventoryId ~= inventoryId then
      local vehInfo = vehicles[otherInventoryId]
      if vehInfo.owned then
        M.removeVehicleObject(otherInventoryId)
        M.switchGarageSpots(otherInventoryId, inventoryId)
      end
    end
  end
end

local function getDefaultVehicleThumb(vehInfo)
  local model = core_vehicles.getModel(vehInfo.model)
  if not model or not model.configs then return nil end
  local _, configKey = path.splitWithoutExt(vehInfo.config.partConfigFilename)
  local config = model.configs[configKey]
  if not config then return nil end
  return config.preview
end

local function getVehicleThumbnail(inventoryId)
  if not inventoryId then return end
  local vehicle = vehicles[inventoryId]
  if not vehicle then return end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath and savePath:sub(1, 1) ~= "/" then
    savePath = "/" .. savePath
  end
  local thumbnailPath = savePath .. "/career/vehicles/" .. inventoryId .. ".jpg"
  if not vehicle.defaultThumbnail and FS:fileExists(thumbnailPath) then
    return thumbnailPath
  else
    return getDefaultVehicleThumb(vehicle)
  end
end

local menuIsOpen
local buttonsActive = {}
local chooseButtonsData = {}
local menuHeader
local menuBackTarget

local function isVehicleOnSite(inventoryId, garage)
  local vehicle = vehicles[inventoryId]
  if not vehicle or not vehicle.location then
    return
  end
  return vehicle.location == garage.id
end

local function isVehicleStoredAtGarage(inventoryId, garageId)
  local vehicle = vehicles[inventoryId]
  return (vehicle and garageId and not inventoryIdToVehId[inventoryId] and
    (vehicle.location == garageId or vehicle.location == nil)) or false
end

local function processPerformanceData(performanceData)
  if not performanceData then return end

  -- Process drivetrain information
  if performanceData.powertrainLayout then
    local frontWheelDrive = performanceData.powertrainLayout.poweredWheelsFront > 0
    local rearWheelDrive = performanceData.powertrainLayout.poweredWheelsRear > 0
    performanceData.drivetrain = frontWheelDrive and rearWheelDrive and "AWD" or frontWheelDrive and "FWD" or rearWheelDrive and "RWD" or "Unknown"
  end

  -- Process fuel type information
  if performanceData.fuelType then
    if performanceData.fuelType["fuelTank:gasoline"] then
      performanceData.fuelType = "Gasoline"
    elseif performanceData.fuelType["fuelTank:diesel"] then
      performanceData.fuelType = "Diesel"
    elseif performanceData.fuelType["fuelTank:electric"] then
      performanceData.fuelType = "Electric"
    elseif next(performanceData.fuelType) then
      performanceData.fuelType = next(performanceData.fuelType)
    else
      performanceData.fuelType = "Unknown"
    end
  end

  -- Process induction type information
  if performanceData.inductionType then
    if performanceData.inductionType.naturalAspiration then
      performanceData.inductionType = "NA"
    elseif performanceData.inductionType.turbocharger then
      performanceData.inductionType = "Turbocharger"
    elseif next(performanceData.inductionType) then
      performanceData.inductionType = next(performanceData.inductionType)
    else
      performanceData.inductionType = "Unknown"
    end
  end

  if performanceData.lateralAcceleration then
    performanceData.lateralGForce = performanceData.lateralAcceleration.maxAcceleration / 9.81
  end

  career_modules_vehiclePerformance.addScoresToPerformanceData(performanceData)

  if type(performanceData.power) == "table" and performanceData.power.propulsionPowerCombined and performanceData.weight then
    local powerInHP = performanceData.power.propulsionPowerCombined / 735.5
    performanceData.powerPerTon = powerInHP * 1000 / performanceData.weight
    performanceData.power = powerInHP
  end

  career_modules_vehiclePerformance.translatePerformanceDataForUi(performanceData)
end

local function getConfigFallbackNiceName(vehicleData)
  if not vehicleData or not vehicleData.model or not vehicleData.config then return end
  local partConfigFilename = vehicleData.config.partConfigFilename
  if type(partConfigFilename) ~= "string" or partConfigFilename == "" then return end
  local _, configFilename = path.splitWithoutExt(partConfigFilename)
  local configInfo = core_vehicles.getConfig(vehicleData.model, configFilename)
  if not configInfo then return end

  local configName = configInfo.Name
  if core_locales and core_locales.translateWithOrWithoutContext then
    configName = core_locales.translateWithOrWithoutContext(configName)
  end
  if type(configName) ~= "string" or configName == "" then return end

  local brand = configInfo.Brand
  if core_locales and core_locales.translateWithOrWithoutContext then
    brand = core_locales.translateWithOrWithoutContext(brand)
  end
  if type(brand) == "string" and brand ~= "" then
    return brand .. " " .. configName
  end
  return configName
end

local function getVehicleNiceNameTranslated(inventoryId)
  local vehicleData = vehicles[inventoryId]
  if not vehicleData then return end

  local niceName = vehicleData.niceName
  if core_locales and core_locales.translateWithOrWithoutContext then
    niceName = core_locales.translateWithOrWithoutContext(niceName)
  end

  -- Dual-brand locale tables (e.g. md_series) must never reach Vue as objects.
  if type(niceName) == "string" and niceName ~= "" then
    return niceName
  end

  local fallback = getConfigFallbackNiceName(vehicleData)
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end

  if type(vehicleData.model) == "string" and vehicleData.model ~= "" then
    return vehicleData.model
  end
  return "Vehicle"
end

-- Persist minimal vehicle-class display for inventory tiles (Option A: UI prefers this over live certificationData).
local function syncSavedVehicleClassUiSnapshot(inventoryId, certificationDataProcessed)
  if type(inventoryId) ~= "number" or type(certificationDataProcessed) ~= "table" then
    return
  end
  local vc = certificationDataProcessed.vehicleClass
  if type(vc) ~= "table" then
    return
  end
  local pi = tonumber(vc.performanceIndex)
  if not pi then
    return
  end
  local snap = {
    performanceIndex = pi,
    label = type(vc.label) == "string" and vc.label or type(vc.name) == "string" and vc.name or nil,
  }
  local veh = vehicles[inventoryId]
  if not veh then
    return
  end
  local prev = veh.savedVehicleClassUi
  local prevPi = prev and tonumber(prev.performanceIndex)
  local prevLb = prev and prev.label or ""
  local newLb = snap.label or ""
  if not prev or prevPi ~= snap.performanceIndex or prevLb ~= newLb then
    veh.savedVehicleClassUi = snap
    setVehicleDirty(inventoryId)
  end
end

local function getVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice)
  local vehicleData = deepcopy(vehicles[inventoryId])
  if not vehicleData then return end
  local garage = getInventoryMenuGarage()
  local currentGarageId = garage and garage.id
  local currentGarageSpace = currentGarageId and career_modules_garageManager.isGarageSpace(currentGarageId) or {false, 0}

  if not inventoryIdsInGarage then
    inventoryIdsInGarage = garage and getVehiclesInGarage(garage, true) or {}
  end

  vehicleData.niceName = getVehicleNiceNameTranslated(inventoryId)
  vehicleData.value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  vehicleData.marketSellValue = career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  vehicleData.valueRepaired = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  vehicleData.quickRepairExtraPrice = career_modules_insurance_insurance.getQuickRepairExtraPrice()
  vehicleData.initialRepairTime = career_modules_insurance_insurance.getInvVehRepairTime(inventoryId)

  if vehicleData.certifications then
    vehicleData.power = string.format("%d", vehicleData.certifications.power)
    vehicleData.weight = string.format("%d", vehicleData.certifications.weight)
    vehicleData.torque = string.format("%d", vehicleData.certifications.torque)
    vehicleData.powerPerWeight = string.format("%0.3f", vehicleData.certifications.power / vehicleData.certifications.weight)
  else
    vehicleData.power = "N/A"
    vehicleData.weight = "N/A"
    vehicleData.torque = "N/A"
    vehicleData.powerPerWeight = "N/A"
  end

  vehicleData.mileage = M.setMileage(inventoryId)
  vehicleData.location = vehicleData.location or currentGarageId
  vehicleData.niceLocation = vehicleData.niceLocation or (vehicleData.location and career_modules_garageManager.garageIdToName(vehicleData.location)) or "Storage"

  if inventoryIdToVehId[inventoryId] then
    local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
    if vehObj then
      vehicleData.distance = vehObj:getPosition():distance(getPlayerVehicle(0):getPosition())
      vehicleData.inGarage = inventoryIdsInGarage[inventoryId]
    end
    vehicleData.inStorage = false
  else
    vehicleData.inStorage = true
  end

  vehicleData.atCurrentGarage = (currentGarageId and vehicleData.location == currentGarageId) or vehicleData.inGarage

  for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
    if otherInventoryId ~= inventoryId then
      vehicleData.otherVehicleInGarage = true
      break
    end
  end

  vehicleData.needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(vehicleData.id)
  vehicleData.onSite = garage and isVehicleOnSite(inventoryId, garage) or false
  if inventoryId == favoriteVehicle then
    vehicleData.favorite = true
  end

  local vehInsuranceInfo = career_modules_insurance_insurance.getVehInsuranceInfo(inventoryId)
  if vehInsuranceInfo then
    vehicleData.insuranceInfo = vehInsuranceInfo.insuranceInfo
    vehicleData.isInsured = vehInsuranceInfo.isInsured
    vehicleData.insuranceClass = vehInsuranceInfo.insuranceClass
    vehicleData.thumbnail = getVehicleThumbnail(inventoryId)
  end

  vehicleData.junkVehicle = career_modules_permissions.getStatusForTag("junkVehicle", {inventoryId = inventoryId})
  vehicleData.repairPermission = career_modules_permissions.getStatusForTag("vehicleRepair", {inventoryId = inventoryId})
  vehicleData.sellPermission = career_modules_permissions.getStatusForTag("vehicleSelling", {inventoryId = inventoryId})
  vehicleData.favoritePermission = career_modules_permissions.getStatusForTag("vehicleFavorite", {inventoryId = inventoryId})
  vehicleData.storePermission = career_modules_permissions.getStatusForTag("vehicleStoring", {inventoryId = inventoryId})
  local garageHasSpace = currentGarageId and career_modules_garageManager.isGarageSpace(currentGarageId)[1] or false
  local globalGarageHasSpace = hasFreeSlot()
  local vehicleAtGarageLocation = currentGarageId and M.getVehicleLocation(inventoryId) == currentGarageId or false
  vehicleData.storePermission.allow = vehicleData.storePermission.allow and (garageHasSpace or globalGarageHasSpace or vehicleAtGarageLocation or vehicleData.inGarage)
  local freightPickupPending =
    string.find(tostring(vehicleData.location or ""), "freightPickup:", 1, true) == 1
  vehicleData.deliverPermission = {
    allow = not freightPickupPending and
      ((garageHasSpace or globalGarageHasSpace) and
        vehicleData.location ~= currentGarageId and not vehicleData.inGarage)
  }
  local retrieveGarageId = currentGarageId
  local storedAtCurrentGarage = isVehicleStoredAtGarage(inventoryId, retrieveGarageId)
  vehicleData.retrievePermission = {allow = storedAtCurrentGarage}
  local retrievalQuote = storedAtCurrentGarage
    and {cost = 0, coveredByInsurance = false}
    or getVehicleRetrievalQuote(inventoryId, localRetrievalRoutePrice)
  vehicleData.retrievalCost = retrievalQuote.cost
  vehicleData.retrievalCoveredByInsurance = retrievalQuote.coveredByInsurance
  vehicleData.retrievalFree = storedAtCurrentGarage
  local storageTowQuote = (inventoryIdToVehId[inventoryId] and not vehicleData.inGarage)
    and getVehicleRetrievalQuote(inventoryId, localRetrievalRoutePrice)
    or {cost = 0, coveredByInsurance = false}
  vehicleData.storageTowCost = storageTowQuote.cost
  vehicleData.storageTowCoveredByInsurance = storageTowQuote.coveredByInsurance
  vehicleData.storageTowRequired = storageTowQuote.cost > 0 or storageTowQuote.coveredByInsurance
  vehicleData.licensePlateChangePermission = career_modules_permissions.getStatusForTag({"vehicleLicensePlate", "vehicleModification"}, {inventoryId = inventoryId})
  vehicleData.returnLoanerPermission = career_modules_permissions.getStatusForTag("returnLoanedVehicle", {inventoryId = inventoryId})

  local marketplaceListed = career_modules_marketplace.findVehicleListing(inventoryId) ~= nil
  vehicleData.listedForSale = marketplaceListed
  vehicleData.listedForAuction = vehicleData.listedForAuction == true

  for _, performanceData in ipairs(vehicleData.performanceHistory or {}) do
    processPerformanceData(performanceData)
  end

  if vehicleData.certificationData then
    processPerformanceData(vehicleData.certificationData)
    syncSavedVehicleClassUiSnapshot(inventoryId, vehicleData.certificationData)
  end

  local vehStore = vehicles[inventoryId]
  if vehStore and type(vehStore.savedVehicleClassUi) == "table" then
    vehicleData.savedVehicleClassUi = deepcopy(vehStore.savedVehicleClassUi)
  end

  return vehicleData
end

local function sendDataToUi()
  menuIsOpen = true
  local data = {vehicles = {}}
  data.menuHeader = menuHeader
  data.chooseButtonsData = chooseButtonsData
  data.buttonsActive = buttonsActive

  local closestGarage = getInventoryMenuGarage()
  local closestGarageId = closestGarage and closestGarage.id
  local inventoryIdsInGarage = getVehiclesInGarage(closestGarage, true)
  local localRetrievalRoutePrice = getLocalGarageRetrievalRoutePrice()

  for inventoryId, vehicle in pairs(vehicles) do
    if isPersonalInventoryId(inventoryId) then
      data.vehicles[tostring(inventoryId)] =
        getVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice)
    end
  end

  data.numberOfFreeSlots = getNumberOfFreeSlots()
  data.hasGlobalGarageSpace = hasFreeSlot()
  data.originComputerId = originComputerId
  data.currentGarageId = closestGarageId
  if closestGarageId then
    local spaceInfo = career_modules_garageManager.isGarageSpace(closestGarageId)
    data.currentGarageHasSpace = spaceInfo[1]
    data.currentGarageFreeSlots = spaceInfo[2]
  end

  data.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  guihooks.trigger("vehicleInventoryData", data)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  -- Some Career dependencies finish their activation after inventory's own
  -- callback. Retry a detected prepared plan until the first successful apply.
  if pendingMigrationRetry and applyPendingMigration() then
    pendingMigrationRetry = false
  end

  if saveCareer then
    -- we delay the save here so that the part condition initialization is definitely finished beforehand
    if saveCareer >= 10 then
      career_saveSystem.saveCurrent() -- this is the save just after starting a new career
      saveCareer = nil
    else
      saveCareer = saveCareer + 1
    end
  end

  if vehiclesMovedToStorage then
    guihooks.trigger("toastrMsg", {type="warning", label = "vehStored", title = _tr("ui.career.inventory.toast.vehicleStored.title"), msg = _tr("ui.career.inventory.toast.vehicleStored.msg")})
    vehiclesMovedToStorage = nil
  end

  if loanedVehicleReturned then
    guihooks.trigger("toastrMsg", {type="warning", label = "loanReturned", title = _tr("ui.career.inventory.toast.loanReturned.title"), msg = _tr("ui.career.inventory.toast.loanReturned.msg")})
    loanedVehicleReturned = nil
  end

  accessTimerAccumulator = accessTimerAccumulator + math.max(tonumber(dtReal) or 0, 0)
  if accessTimerAccumulator < ACCESS_TIMER_UPDATE_INTERVAL then
    return
  end
  local accessTimerElapsed = accessTimerAccumulator
  accessTimerAccumulator = 0

  for inventoryId, vehInfo in pairs(vehicles) do
    if vehInfo.timeToAccess then
      vehInfo.timeToAccess = vehInfo.timeToAccess - accessTimerElapsed
      setVehicleDirty(inventoryId)
      if vehInfo.timeToAccess < 0 then
        if vehInfo.delayReason == "bought" then
          ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleDeliveredToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
        elseif vehInfo.delayReason == "repair" then
          ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleRepairedReturnedToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
        elseif vehInfo.delayReason == "rented" then
          ui_message(string.format("Your %s has been returned from the Movie Rental.", vehInfo.niceName), nil, "vehicleInventory")
        elseif vehInfo.delayReason == "certification" then
          ui_message(string.format("Your %s has been certified and returned to your vehicle storage.", vehInfo.niceName), nil, "vehicleInventory")
        end
        vehInfo.timeToAccess = nil
        vehInfo.delayReason = nil
        if menuIsOpen then
          sendDataToUi()
        end
      end
    end
  end
end

local function onBeforeWalkingModeToggled(enabled, vehicleInFrontVehId)
  if enabled then
    enterVehicle(nil, skipPartConditionsBeforeWalking and 1 or nil)
  elseif vehIdToInventoryId[vehicleInFrontVehId] then
    enterVehicle(vehIdToInventoryId[vehicleInFrontVehId], 1)
  end
  skipPartConditionsBeforeWalking = nil
end

local function getInventoryIdsInClosestGarage(onlyFirst)
  -- get closest garage
  local closestGarage = getClosestGarage()

  -- check if a vehicle is in the zone of the closest garage
  local inventoryIdsInGarage = getVehiclesInGarage(closestGarage, true)
  local inventoryIdsList = {}
  for inventoryId, _ in pairs(inventoryIdsInGarage) do
    table.insert(inventoryIdsList, inventoryId)
  end

  if getPlayerVehicle(0) then
    local playerPos = getPlayerVehicle(0):getPosition()
    table.sort(inventoryIdsList, function(id1, id2)
      local veh1 = getObjectByID(inventoryIdToVehId[id1])
      local veh2 = getObjectByID(inventoryIdToVehId[id2])
      return veh1:getPosition():distance(playerPos) < veh2:getPosition():distance(playerPos)
    end)
  end

  if onlyFirst then
    return next(inventoryIdsInGarage)
  else
    return inventoryIdsList
  end
end

local callbackAfterFade
local function onScreenFadeState(state)
  if callbackAfterFade and state == 1 then
    career_modules_vehicleDeletionService.deleteFlaggedVehicles()
    callbackAfterFade()
    callbackAfterFade = nil
  end
end

local function openMenu(_chooseButtonsData, header, _buttonsActive, _backTarget)
  menuBackTarget = _backTarget
  buttonsActive = _buttonsActive or {}
  if buttonsActive.repairEnabled == nil then buttonsActive.repairEnabled = true end
  if buttonsActive.sellEnabled == nil then buttonsActive.sellEnabled = true end
  if buttonsActive.favoriteEnabled == nil then buttonsActive.favoriteEnabled = true end
  if buttonsActive.storingEnabled == nil then buttonsActive.storingEnabled = true end
  if buttonsActive.returnLoanerEnabled == nil then buttonsActive.returnLoanerEnabled = true end
  menuHeader = header or _tr("ui.career.computer.functions.vehicleInventory")

  chooseButtonsData = _chooseButtonsData or {{}}
  for _, buttonData in ipairs(chooseButtonsData) do
    buttonData.buttonText = buttonData.buttonText or _tr("ui.career.inventory.button.chooseVehicle")
    if buttonData.repairRequired == nil then buttonData.repairRequired = false end
    if buttonData.insuranceRequired == nil then buttonData.insuranceRequired = false end
    if buttonData.ownedRequired == nil then buttonData.ownedRequired = false end
    buttonData.callback = buttonData.callback or function() end
  end

  -- Always open the inventory picker route; 4th arg is where Back returns (0.39).
  extensions.ui_router.navigate("career.computer.vehicleInventory")
  updatePartConditionsOfSpawnedVehicles()
end

local function closeMenu()
  if closeMenuCallback then
    closeMenuCallback()
  else
    career_career.closeAllMenus()
  end
end

local function requestPickerExit()
  return extensions.ui_router.navigate(menuBackTarget or "career.computer")
end

local function spawnVehicleAfterFade(enterAfterSpawn, inventoryId, callback)
  ui_fadeScreen.start(0.5)
  callbackAfterFade = function()
    if enterAfterSpawn then
      enterVehicle(inventoryId, nil, callback)
    else
      -- if the vehicle is already spawned, call the callback directly
      if inventoryIdToVehId[inventoryId] then
        callback()
      else
        spawnVehicle(inventoryId, nil, callback)
      end
    end
  end
end

local function spawnVehicleAndTeleportToGarage(enterAfterSpawn, inventoryId, replaceOthers)
  if inventoryId == currentVehicle then return end
  spawnVehicleAfterFade(enterAfterSpawn, inventoryId,
  function()
    if replaceOthers then
      removeVehiclesFromGarageExcept(inventoryId)
    end
    local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
    setPartConditionResetSnapshot(vehObj,
      function()
        local closestGarage = getInventoryMenuGarage()
        if not closestGarage or not closestGarage.id then
          log("E", "inventory", string.format("Unable to retrieve inventory vehicle %s: no destination garage", tostring(inventoryId)))
          ui_message("Could not find the current garage.", 5, "Vehicle retrieval", "error")
          ui_fadeScreen.stop(0.5)
          return
        end
        freeroam_facilities.teleportToGarage(closestGarage.id, vehObj, false)
        career_modules_fuel.minimumRefuelingCheck(vehObj:getId())
        setVehicleDirty(inventoryId)
        guihooks.trigger('ChangeState', {state = 'play'})
        ui_fadeScreen.stop(0.5)

        local pos, _ = freeroam_facilities.getGaragePosRot(closestGarage, vehObj)
        career_modules_playerDriving.showPosition(pos)

        career_modules_log.addLog(string.format("Spawned vehicle %d in garage %s. replaceOthers == %s", inventoryId, closestGarage.id, replaceOthers), "inventory")
      end)
  end)
end

local function retrieveVehicleFromStorage(inventoryId, replaceOthers)
  local currentGarage = getInventoryMenuGarage()
  local storedAtCurrentGarage =
    currentGarage and isVehicleStoredAtGarage(inventoryId, currentGarage.id)
  if not storedAtCurrentGarage then
    useVehicleRetrievalService(
      inventoryId,
      getLocalGarageRetrievalRoutePrice(),
      "Retrieved vehicle with towing service")
  end
  spawnVehicleAndTeleportToGarage(false, inventoryId, replaceOthers)
end

local function deliverAndReplace(inventoryId)
  M.deliverVehicle(inventoryId, 5000)
  local closestGarage = getInventoryMenuGarage()
  if closestGarage then
    M.moveVehicleToGarage(inventoryId, closestGarage.id)
  end
  sendDataToUi()
end

local function openMenuFromComputer(_originComputerId)
  originComputerId = _originComputerId
  openMenu(
    {
      {
        callback = function(inventoryId) retrieveVehicleFromStorage(inventoryId, false) end,
        buttonText = _tr("ui.career.inventory.button.retrieve"),
        retrievalAction = true,
        insuranceRequired = true,
        requiredVehicleNotInGarage = true,
        requireAtCurrentGarage = true
      },
      {
        callback = function(inventoryId) retrieveVehicleFromStorage(inventoryId, true) end,
        buttonText = _tr("ui.career.inventory.button.replaceCurrentVehicle"),
        retrievalAction = true,
        insuranceRequired = true,
        requiredOtherVehicleInGarage = true,
        requireAtCurrentGarage = true
      },
      {
        callback = function(inventoryId) M.deliverVehicle(inventoryId, 5000) end,
        buttonText = "Deliver",
        insuranceRequired = true,
        requiredVehicleNotInGarage = true,
        requireAtDifferentGarage = true
      },
      {
        callback = function(inventoryId) deliverAndReplace(inventoryId) end,
        buttonText = "Deliver and replace",
        insuranceRequired = true,
        requiredVehicleNotInGarage = true,
        requiredOtherVehicleInGarage = true,
        requireAtDifferentGarage = true
      },
      {
        callback = function(inventoryId)
          career_modules_vehiclePerformance.openMenu({inventoryId = inventoryId, computerId = originComputerId})
        end,
        buttonText = _tr("ui.career.shared.pathPerformanceIndex"),
        repairRequired = false
      }
    },
    _tr("ui.career.inventory.menu.spawnVehicle"), nil
  )
  career_modules_log.addLog(string.format("Opened vehicle inventory from computer %s", originComputerId), "inventory")
end

local function chooseVehicleFromMenu(inventoryId, buttonIndex, repairPrevVeh)
  chooseButtonsData[buttonIndex].callback(inventoryId, repairPrevVeh)
end

local function openInventoryMenuForChoosingListing()
  openMenu(
    {{
      callback = function(inventoryId)
        guihooks.trigger('addListing', {inventoryId = inventoryId})
      end,
      buttonText = _tr("ui.career.inventory.button.listForSale"),
      repairRequired = false,
      ownedRequired = true,
      notForSaleRequired = true,
    }}, _tr("ui.career.inventory.menu.listForSale"),
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    },
    "career.computer.vehicleShopping"
  )
end

local function onExitVehicleInventory()
  menuIsOpen = false
  menuHeader = nil
  menuBackTarget = nil
end

local function onEnterVehicleFinished(inventoryId)
  if inventoryId then
    lastVehicle = inventoryId
  end
end

local function getVehicles()
  return vehicles
end

local function getVehicle(inventoryId)
  return vehicles[inventoryId]
end

local function getVehicleTimeToAccess(inventoryId)
  return vehicles[inventoryId].timeToAccess
end

local function sellVehicle(inventoryId, price)
  local vehicle = vehicles[inventoryId]
  if not vehicle then return end

  -- Prevent selling vehicles that are currently being rented or otherwise delayed
  if vehicle.timeToAccess then
    local reasonText = vehicle.delayReason == "rented" and "the vehicle is currently rented to the movie studio" or "the vehicle is not currently accessible"
    log("W", "inventory", string.format("Cannot sell vehicle %d because %s", inventoryId, reasonText))
    return false
  end
  if vehicle.listedForAuction then
    return false
  end

  local value = price or career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  extensions.hook("onBeforeVehicleSell", {inventoryId = inventoryId, price = value})
  career_modules_playerAttributes.addAttributes({money=value}, {tags={"vehicleSold","selling"}, label = {txt = "ui.career.inventory.log.soldVehicle", context = {vehicleName = vehicle.niceName or "ui.career.inventory.unnamedVehicle"}}}, true)
  removeVehicle(inventoryId)
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')

  if vehicle.finalBuyingPrice and value > vehicle.finalBuyingPrice then
    gameplay_achievement.unlockAchievement("FLIP_PROFIT")
  end

  career_modules_log.addLog(string.format("Sold vehicle %d for %f", inventoryId, value), "inventory")
  career_saveSystem.saveCurrent()
  return true
end

local function sellVehicleFromInventory(inventoryId)
  if sellVehicle(inventoryId) then
    career_saveSystem.saveCurrent()
    sendDataToUi()
  end
end

local function returnLoanedVehicleFromInventory(inventoryId)
  career_modules_loanerVehicles.returnVehicle(inventoryId, function()
    career_saveSystem.saveCurrent()
    sendDataToUi()
  end)
end

local function expediteRepairFromInventory(inventoryId, price)
  if isVehicleListedForAuction(inventoryId) then
    return
  end
  career_modules_insurance_insurance.expediteRepair(inventoryId, price)
  career_saveSystem.saveCurrent()
  sendDataToUi()
end

local function delayVehicleAccess(inventoryId, delay, reason)
  local vehInfo = vehicles[inventoryId]
  if not vehInfo or delay <= 0 then return end
  vehInfo.timeToAccess = delay
  vehInfo.delayReason = reason
end

local function onAvailableMissionsSentToUi()
  if not currentVehicle then return end
  updatePartConditions(inventoryIdToVehId[currentVehicle], currentVehicle,
  function()
    guihooks.trigger('gameContextPlayerVehicleDamageInfo', {needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(currentVehicle)})
  end)
end

local function setFavoriteVehicle(inventoryId)
  if vehicles[inventoryId] and not vehicles[inventoryId].listedForAuction then
    favoriteVehicle = inventoryId
  end
end

local function getFavoriteVehicle()
  return favoriteVehicle
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  local computerFunctionData = {
    id = "vehicleInventory",
    routeTarget = "career.computer.vehicleInventory",
    label = _tr("ui.career.shared.myVehicles"),
    callback = function() openMenuFromComputer(menuData.computerFacility.id) end,
    order = 1
  }
  if not menuData.hasBoughtStarterVehicle then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
  end
  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function setLicensePlateText(inventoryId, text)
  if isVehicleListedForAuction(inventoryId) then
    return
  end
  local vehId = getVehicleIdFromInventoryId(inventoryId)
  if inventoryId then
    core_vehicles.setPlateText(text, vehId)
  end
  vehicles[inventoryId].config.licenseName = text
end

local function getLicensePlateText(vehId)
  local inventoryId = getInventoryIdFromVehicleId(vehId)
  return inventoryId and vehicles[inventoryId] and vehicles[inventoryId].config.licenseName or nil
end

local function purchaseLicensePlateText(inventoryId, text, money)
  if isVehicleListedForAuction(inventoryId) then
    return
  end
  local price = {money = {amount = money}}
  if not career_modules_payment.canPay(price) then return end
  career_modules_payment.pay(price, {label = _tr("ui.career.inventory.payment.changeLicensePlateText"), tags = {"licensePlate", "buying"}})
  setLicensePlateText(inventoryId, text)
  gameplay_achievement.unlockAchievement("NOW_ITS_MINE")
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  setVehicleDirty(inventoryId)
end

local permissionTags = {
  notOwned = {
    vehicleSelling = "forbidden", --selling a vehicle
    vehicleRepair = "forbidden",
    interactMission = "forbidden", --use the mission POI to start a mission
    painting = "forbidden",
    partBuying = "forbidden",
    vehicleLicensePlate = "forbidden",
    tuning = "forbidden",
    vehicleStoring = "forbidden",
    partSwapping = "forbidden",
    recoveryTowToGarage = "forbidden",
    returnLoanedVehicle = "allowed",
    vehicleFavorite = "forbidden",
    junkVehicle = "hidden"
  }
}

local function onCheckPermission(tags, permissions, additionalData)
  if not additionalData or not additionalData.inventoryId then return end
  local vehData = vehicles[additionalData.inventoryId]
  if not vehData then return end

  for _, tag in ipairs(tags) do
    if not vehData.owned then
      if permissionTags.notOwned[tag] then
        table.insert(permissions, {permission = permissionTags.notOwned[tag]})
      end
    elseif tag == "returnLoanedVehicle" then
      table.insert(permissions, {permission = "hidden"})
    end
    if tag == "junkVehicle" and not vehData.missingFile then
      table.insert(permissions, {permission = "allowed"})
    end
    if tag == "vehicleRepair" and (vehData.timeToAccess or vehData.missingFile) then
      table.insert(permissions, {permission = "forbidden"})
    end
    if tag == "vehicleSelling" and vehData.timeToAccess then
      table.insert(permissions, {permission = "forbidden"})
    end
    if vehData.listedForAuction then
      if tag == "vehicleSelling" or tag == "vehicleFavorite" or tag == "vehicleStoring"
        or tag == "vehicleRepair" or tag == "tuning" or tag == "partSwapping"
        or tag == "painting" or tag == "vehicleModification" or tag == "vehicleLicensePlate"
        or tag == "junkVehicle" or tag == "partBuying" then
        table.insert(permissions, {permission = "forbidden"})
      end
    end
    if tag == "vehicleFavorite" and (vehData.favorite or vehData.missingFile) then
      table.insert(permissions, {permission = "forbidden"})
    end
    if tag == "vehicleStoring" and not inventoryIdToVehId[additionalData.inventoryId] then
      table.insert(permissions, {permission = "forbidden"})
    end
  end
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  if next(inventoryIdToVehId) then
    for invId, vehId in pairs(inventoryIdToVehId) do
      if be:getPlayerVehicleID(0) ~= vehId then -- don't display the current player's vehicle
        if map.objects[vehId] then
          local desc = _tr("ui.career.inventory.bigmap.playerVehicle")
          if vehicles[invId] and vehicles[invId].loanType then
            desc = _tr("ui.career.inventory.bigmap.loanedVehicle")
          end

          local id = "plVeh"..vehId
          if not map.objects[vehId] then goto continue end
          local dist, distUnit = translateDistance(map.objects[vehId].pos:distance(getPlayerVehicle(0):getPosition()), true)
          local plate = (vehicles[invId] and vehicles[invId].config and vehicles[invId].config.licenseName) or "Unknown"
          local odometer, odoUnit = translateDistance(career_modules_valueCalculator.getVehicleMileageById(invId), true)

          desc = core_locales.contextTranslate("ui.career.inventory.bigmap.description", {
            desc = desc,
            dist = dist,
            distUnit = distUnit,
            plate = plate,
            odometer = odometer,
            odoUnit = odoUnit
          })
          table.insert(elements, {
            id = id,
            data = {type = "playerVehicle", id = id},
            markerInfo = {
              bigmapMarker = {
                pos = map.objects[vehId].pos,
                icon = "vehicle_marker_outlined",
                name = core_locales.translateWithOrWithoutContext(vehicles[invId].niceName),
                description = desc,
                thumbnail = getVehicleThumbnail(invId),
                previews = {getVehicleThumbnail(invId)},
                cluster = false
              }
            }
          })
        end
      end
      ::continue::
    end
  end
end

local function getDirtiedVehicles()
  return dirtiedVehicles
end

local function isEmpty()
  return tableIsEmpty(vehicles)
end

local function isLicensePlateValid(text)
  return core_vehicles.isLicensePlateValid(text)
end

local function isVehicleNameValid(text)
  if not text or text == "" then return false end
  return not text:find('["\\\b\f\n\r\t]')
end

local function renameVehicle(inventoryId, name)
  if not isVehicleNameValid(name) then
    log("E", "inventory", "Invalid characters in vehicle name: " .. name)
    return false
  end
  if isVehicleListedForAuction(inventoryId) then
    return false
  end
  vehicles[inventoryId].niceName = name
  setVehicleDirty(inventoryId)
  return true
end

local function debugRespawnCurrentVehicle()
  local inventoryId = getCurrentVehicle()
  if not inventoryId then return end

  career_modules_inventory.updatePartConditions(nil, inventoryId, function()
    spawnVehicle(inventoryId, 2)
  end)
end

-- RLS Extra Vehicle Stats

local function setVehicleRole(inventoryId, role)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].role = role
end

local function getVehicleRole(inventoryId)
  return vehicles[inventoryId] and vehicles[inventoryId].role or nil
end

local function addMeetReputation(inventoryId, amount)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].meetReputation = (vehicles[inventoryId].meetReputation or 0) + amount
end

local function getMeetReputation(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].meetReputation or 0
end

local function addAccident(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].accidents = (vehicles[inventoryId].accidents or 0) + 1
end

local function getAccidents(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].accidents or 0
end

local function addArrest(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].arrests = (vehicles[inventoryId].arrests or 0) + 1
end

local function getArrests(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].arrests or 0
end

local function addTicket(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].tickets = (vehicles[inventoryId].tickets or 0) + 1
end

local function getTickets(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].tickets or 0
end

local function addEvade(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].evades = (vehicles[inventoryId].evades or 0) + 1
end

local function getEvades(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].evades or 0
end

local function addTaxiDropoff(inventoryId, passengers)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].taxiDropoffs = (vehicles[inventoryId].taxiDropoffs or 0) + passengers
end

local function getTaxiDropoffs(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].taxiDropoffs or 0
end

local function addRepossession(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].repos = (vehicles[inventoryId].repos or 0) + 1
end

local function getRepossessions(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].repos or 0
end

local function addMovieRental(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].movieRentals = (vehicles[inventoryId].movieRentals or 0) + 1
end

local function getMovieRentals(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].movieRentals or 0
end

function M.setCertifications(vehId, certifications)
  local invId = getInventoryIdFromVehicleId(vehId)
  if not invId then return end
  vehicles[invId].certifications = certifications
end

M.getCertifications = function()
  local invId = getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  local veh = vehicles[invId]
  if not veh then return {} end
  return veh.certifications
end

function M.addDeliveredItems(inventoryId, amount)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].deliveredItems = vehicles[inventoryId].deliveredItems or 0
  vehicles[inventoryId].deliveredItems = vehicles[inventoryId].deliveredItems + amount
end

function M.getDeliveredItems(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].deliveredItems or 0
end

function M.addSuspectCaught(inventoryId)
  if not vehicles[inventoryId] then return end
  vehicles[inventoryId].suspectsCaught = (vehicles[inventoryId].suspectsCaught or 0) + 1
end

function M.getSuspectsCaught(inventoryId)
  if not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].suspectsCaught or 0
end

-- RLS Marketplace Functions

function M.setMileage(inventoryId)
  if not inventoryId then inventoryId = currentVehicle end
  local vehicle = vehicles[inventoryId]
  if not vehicle or not vehicle.partConditions then
    return 0 -- Or nil, or handle the case where there are no part conditions
  end

  local maxOdometer = 0
  local partConditions = vehicle.partConditions

  for partName, conditionData in pairs(partConditions) do
    if conditionData.odometer then
      maxOdometer = math.max(maxOdometer, conditionData.odometer)
    end
  end
  vehicle.mileage = maxOdometer
  return maxOdometer
end

-- RLS FRE Functions

local lastRaceName = nil
local lastRaceTime = nil
local currentSession = 0

local function saveFRETimeToVehicle(raceName, inventoryId, time, driftScore)
  local veh = vehicles[inventoryId]
  if not veh then return end
  veh.FRETimes = veh.FRETimes or {}
  veh.FRECompletions = veh.FRECompletions or {}
  if veh.FRETimes[raceName] then
    if driftScore and driftScore ~= 0 then
      veh.FRETimes[raceName] = math.max(veh.FRETimes[raceName], driftScore)
    else
      veh.FRETimes[raceName] = math.min(veh.FRETimes[raceName], time)
    end
  else
    if driftScore and driftScore ~= 0 then
      veh.FRETimes[raceName] = driftScore
    else
      veh.FRETimes[raceName] = time
    end
  end
  veh.FRECompletions[raceName] = veh.FRECompletions[raceName] or {}
  veh.FRECompletions[raceName].total = (veh.FRECompletions[raceName].total or 0) + 1
  if lastRaceName == raceName then
    local pausedTime = career_modules_pauseTime.getTotalPauseTime()
    local totalTime = time + pausedTime
    if lastRaceTime and os.time() - lastRaceTime < totalTime + 10 then
      currentSession = currentSession + 1
      if not veh.FRECompletions[raceName].consecutive or veh.FRECompletions[raceName].consecutive < currentSession then
        veh.FRECompletions[raceName].consecutive = currentSession
      end
    end
    lastRaceTime = os.time()
  else
    lastRaceName = raceName
    lastRaceTime = os.time()
    currentSession = 1
    if not veh.FRECompletions[raceName].consecutive then
      veh.FRECompletions[raceName].consecutive = 1
    end
  end
  career_modules_pauseTime.resetPauseTime()
end

local function getFRETimeToVehicle(raceName, inventoryId)
  local veh = vehicles[inventoryId]
  if not veh then return nil end
  return veh.FRETimes and veh.FRETimes[raceName] or nil
end

local function getFRECompletions(raceName, inventoryId)
  local veh = vehicles[inventoryId]
  if not veh then return nil end
  return veh.FRECompletions and veh.FRECompletions[raceName] or nil
end

local function storeVehicleAtClosestGarage(inventoryId)
  local veh = vehicles[inventoryId]
  if not veh then return false end
  if isVehicleListedForAuction(inventoryId) then
    return false
  end

  local garage = getInventoryMenuGarage()
  if not garage or not garage.id then return false end

  local inGarage = getVehiclesInGarage(garage, true)[inventoryId]
  local alreadyAssigned = veh.location == garage.id
  if not alreadyAssigned then
    if not inGarage then
      ui_message("Vehicle must be in the current garage to store it.", nil, "vehicleInventory")
      return false
    end

    local spaceInfo = career_modules_garageManager.isGarageSpace(garage.id)
    if spaceInfo and spaceInfo[1] then
      veh.location = garage.id
      veh.niceLocation = career_modules_garageManager.garageIdToName(garage.id)
    elseif hasFreeSlot() then
      if not M.moveVehicleToGarage(inventoryId) then
        return false
      end
    else
      ui_message("This garage is full.", nil, "vehicleInventory")
      return false
    end
  elseif inventoryIdToVehId[inventoryId] and not inGarage then
    useVehicleRetrievalService(
      inventoryId,
      getLocalGarageRetrievalRoutePrice(),
      "Towed vehicle into storage")
  end

  removeVehicleObject(inventoryId)
  sendDataToUi()
  if career_modules_computer and career_modules_computer.refreshMenu then
    career_modules_computer.refreshMenu(true)
  end
  return true
end

M.getAllFRETimes = function()
  local invId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  if not invId then return {} end
  return vehicles[invId].FRETimes
end

M.getAllFRECompletions = function()
  local invId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  if not invId then return {} end
  return vehicles[invId].FRECompletions
end

-- Garage Localization

M.moveVehicleToGarage = function(id, garage)
  if isVehicleListedForAuction(id) then
    return false
  end
  local garageManager = career_modules_garageManager
  if not garageManager then return false end

  if garage and garageManager.isGarageForSale and garageManager.isGarageForSale(garage) then
    log("W", "Inventory", string.format("Cannot move vehicle ID %d to garage %s - garage is listed for sale", id, tostring(garage)))
    garage = nil
  end

  if not garage or not (garageManager.isGarageSpace(garage) and garageManager.isGarageSpace(garage)[1]) then
    local bestGarage = getClosestOwnedGarageWithSpace()
    if bestGarage then
      garage = bestGarage.id
    end
  end

  -- Reject foreign-map garage ids (owned elsewhere) so we do not stamp a
  -- current-map vehicle with starterApartment / etc. when resolving space.
  if garage then
    local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
      or function(type, id) return freeroam_facilities.getFacility(type, id, true) end
    if not getFacilityIfExists("garage", garage) then
      garage = nil
      local bestGarage = getClosestOwnedGarageWithSpace()
      if bestGarage then
        garage = bestGarage.id
      else
        garage = garageManager.getNextAvailableSpace()
      end
    end
  end

  if not garage then
    garage = garageManager.getNextAvailableSpace()
  end

  if not garage then
    local availabilityReason = garageManager.getGarageAvailabilityReason and garageManager.getGarageAvailabilityReason() or "full"
    if availabilityReason == "none" then
      ui_message("You need to buy or rent a garage before storing vehicles.", nil, "vehicleInventory")
    else
      ui_message("No garage space is available for this vehicle.", nil, "vehicleInventory")
    end
    log("W", "Inventory", string.format("No available garage space found for vehicle ID %d (reason: %s)", id, tostring(availabilityReason)))
    return false
  end

  if vehicles[id] then
    vehicles[id].location = garage
    vehicles[id].niceLocation = garageManager.garageIdToName(garage)
    log("I", "Inventory", string.format("Vehicle ID %d moved to garage: %s", id, garage))
    return true
  else
    log("W", "Inventory", string.format("Vehicle ID %d not found in inventory", id))
    return false
  end
end

M.deliverVehicle = function(id, money)
  if isVehicleListedForAuction(id) then
    return
  end
  if not M.moveVehicleToGarage(id) then
    return
  end
  local price = {money = {amount = money, canBeNegative = true}}
  career_modules_payment.pay(price, {label = string.format("Delivering vehicle to garage"), tags = {"delivery"}})
  delayVehicleAccess(id, 120, "delivery")
  sendDataToUi()
end

M.storeVehicle = function(id)
  return M.moveVehicleToGarage(id)
end

M.switchGarageSpots = function(first, second)
  if isVehicleListedForAuction(first) or isVehicleListedForAuction(second) then
    return nil
  end
  local spot1 = vehicles[first].location
  local spot2 = vehicles[second].location
  if not spot1 or not spot2 then return nil end
  vehicles[first].location = spot2
  vehicles[first].niceLocation = career_modules_garageManager.garageIdToName(spot2)
  vehicles[second].location = spot1
  vehicles[second].niceLocation = career_modules_garageManager.garageIdToName(spot1)
  return true
end

M.getVehicleLocation = function(id)
  if not vehicles[id] then return nil end
  return vehicles[id].location
end

M.saveFRETimeToVehicle = saveFRETimeToVehicle
M.getFRETimeToVehicle = getFRETimeToVehicle
M.getFRECompletions = getFRECompletions

M.addVehicle = addVehicle
M.removeVehicle = removeVehicle
M.enterVehicle = enterVehicle
M.sellVehicle = sellVehicle
M.sellVehicleFromInventory = sellVehicleFromInventory
M.returnLoanedVehicleFromInventory = returnLoanedVehicleFromInventory
M.expediteRepairFromInventory = expediteRepairFromInventory
M.updatePartConditions = updatePartConditions
M.updatePartConditionsOfSpawnedVehicles = updatePartConditionsOfSpawnedVehicles
M.removeVehicleObject = removeVehicleObject
M.openMenu = openMenu
M.closeMenu = closeMenu
M.requestPickerExit = requestPickerExit
M.openMenuFromComputer = openMenuFromComputer
M.chooseVehicleFromMenu = chooseVehicleFromMenu
M.delayVehicleAccess = delayVehicleAccess
M.hasFreeSlot = hasFreeSlot
M.getNumberOfFreeSlots = getNumberOfFreeSlots
M.setFavoriteVehicle = setFavoriteVehicle
M.getFavoriteVehicle = getFavoriteVehicle
M.sendDataToUi = sendDataToUi
M.setVehicleRole = setVehicleRole
M.getVehicleRole = getVehicleRole
M.setLicensePlateText = setLicensePlateText
M.getLicensePlateText = getLicensePlateText
M.purchaseLicensePlateText = purchaseLicensePlateText
M.getVehicleThumbnail = getVehicleThumbnail
M.renameVehicle = renameVehicle
M.isLicensePlateValid = isLicensePlateValid
M.isVehicleNameValid = isVehicleNameValid
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onBigMapActivated = onBigMapActivated
M.onUpdate = onUpdate
M.onBeforeWalkingModeToggled = onBeforeWalkingModeToggled
M.onCareerActive = onCareerActive
M.onWorldReadyState = onWorldReadyState
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExitVehicleInventory = onExitVehicleInventory
M.onScreenFadeState = onScreenFadeState
M.onAvailableMissionsSentToUi = onAvailableMissionsSentToUi
M.onComputerAddFunctions = onComputerAddFunctions
M.onSaveCurrentProfileAsyncStart = onSaveCurrentProfileAsyncStart
M.onExperimentalMaintenanceModeChanged = onExperimentalMaintenanceModeChanged
M.onCheckPermission = onCheckPermission
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.openInventoryMenuForChoosingListing = openInventoryMenuForChoosingListing
M.getVehicleNiceNameTranslated = getVehicleNiceNameTranslated

M.getPartConditionsCallback = getPartConditionsCallback
M.applyPartConditions = applyPartConditions
M.teleportedFromBigmap = teleportedFromBigmap
M.setVehicleDirty = setVehicleDirty
M.getDirtiedVehicles = getDirtiedVehicles
M.getVehicles = getVehicles
M.getVehicle = getVehicle
M.isEmpty = isEmpty
M.spawnVehicle = spawnVehicle
M.getInventoryIdsInClosestGarage = getInventoryIdsInClosestGarage
M.getClosestGarage = getClosestGarage
M.isSeatedInsideOwnedVehicle = isSeatedInsideOwnedVehicle
M.storeVehicleAtClosestGarage = storeVehicleAtClosestGarage

-- Debug
M.getCurrentVehicle = getCurrentVehicle
M.getCurrentVehicleId = getCurrentVehicleId
M.getLastVehicle = getLastVehicle
M.getVehicleIdFromInventoryId = getVehicleIdFromInventoryId
M.getInventoryIdFromVehicleId = getInventoryIdFromVehicleId
M.getMapInventoryIdToVehId = getMapInventoryIdToVehId
M.debugRespawnCurrentVehicle = debugRespawnCurrentVehicle
M.applyPreparedMigration = applyPendingMigration

M.getVehicleUiData = getVehicleUiData

-- RLS
M.getVehicleTimeToAccess = getVehicleTimeToAccess
M.addMeetReputation = addMeetReputation
M.getMeetReputation = getMeetReputation
M.addAccident = addAccident
M.getAccidents = getAccidents
M.addArrest = addArrest
M.addTicket = addTicket
M.getArrests = getArrests
M.getTickets = getTickets
M.addEvade = addEvade
M.getEvades = getEvades
M.addTaxiDropoff = addTaxiDropoff
M.getTaxiDropoffs = getTaxiDropoffs
M.addRepossession = addRepossession
M.getRepossessions = getRepossessions
M.addMovieRental = addMovieRental
M.getMovieRentals = getMovieRentals
M.getClosestOwnedGarageWithSpace = getClosestOwnedGarageWithSpace
M.getVehicleRetrievalQuote = getVehicleRetrievalQuote
M.useVehicleRetrievalService = useVehicleRetrievalService

M.isVehicleListedForAuction = isVehicleListedForAuction
M.getListedVehicleId = getListedVehicleId
M.setVehicleListedForAuction = setVehicleListedForAuction
M.clearVehicleAuctionListing = clearVehicleAuctionListing
return M
