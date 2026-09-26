local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'core_vehicles', 'core_jobsystem', 'career_modules_business_businessHelpers', 'career_modules_business_racingTeamRaceFlow'}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local vehicleInfoCache = nil
local partsTreeCache = {}
local businessContexts = {}

local function normalizePartsCacheKey(cacheKey)
  if cacheKey == nil then
    return "nokey"
  end
  return tostring(cacheKey)
end

local function getPartsCacheBucket(businessId, createIfMissing)
  if not businessId then
    return nil
  end
  local bucket = partsTreeCache[businessId]
  if not bucket and createIfMissing then
    bucket = {}
    partsTreeCache[businessId] = bucket
  end
  return bucket
end

local function getCachedPartsTree(businessId, cacheKey)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return nil
  end
  return bucket[normalizePartsCacheKey(cacheKey)]
end

local function setCachedPartsTree(businessId, cacheKey, data)
  if not businessId then
    return
  end
  local bucket = getPartsCacheBucket(businessId, true)
  bucket[normalizePartsCacheKey(cacheKey)] = data
end

local function clearPartsTreeCacheForKey(businessId, cacheKey)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return
  end
  bucket[normalizePartsCacheKey(cacheKey)] = nil
  if not next(bucket) then
    partsTreeCache[businessId] = nil
  end
end

local function setBusinessContext(businessType, businessId)
  if not businessType or not businessId then
    return
  end
  -- Bridge may send string ids; Lua may use number keys.
  businessContexts[businessId] = businessType
  businessContexts[tostring(businessId)] = businessType
  local n = tonumber(businessId)
  if n ~= nil then
    businessContexts[n] = businessType
  end
end

local function clearBusinessContext(businessId)
  if not businessId then return end
  businessContexts[businessId] = nil
  businessContexts[tostring(businessId)] = nil
  local n = tonumber(businessId)
  if n ~= nil then
    businessContexts[n] = nil
  end
  partsTreeCache[businessId] = nil
  partsTreeCache[tostring(businessId)] = nil
  if n ~= nil then
    partsTreeCache[n] = nil
  end
end

local function getBusinessModule(businessType)
  if not businessType then
    return nil
  end
  return _G["career_modules_business_" .. tostring(businessType)]
end

local function purchasedBusinessTypeForId(businessId)
  if not career_modules_business_businessManager or not career_modules_business_businessManager.getAllPurchasedBusinesses then
    return nil, nil
  end
  local all = career_modules_business_businessManager.getAllPurchasedBusinesses()
  if type(all) ~= "table" then
    return nil, nil
  end
  local function idMatchesKey(a, b)
    if a == nil or b == nil then
      return false
    end
    if a == b then
      return true
    end
    if tostring(a) == tostring(b) then
      return true
    end
    local na, nb = tonumber(a), tonumber(b)
    if na ~= nil and nb ~= nil and na == nb then
      return true
    end
    return false
  end
  for btype, list in pairs(all) do
    if type(list) == "table" then
      for k, _ in pairs(list) do
        if idMatchesKey(businessId, k) then
          return btype, k
        end
      end
    end
  end
  return nil, nil
end

local function racingTeamRaceFlowModule()
  return rawget(_G, "career_modules_business_racingTeamRaceFlow")
end

local function resolveBusinessTypeOnly(businessId)
  if not businessId then
    return nil
  end
  local businessType = businessContexts[businessId]
  if not businessType then
    businessType = businessContexts[tostring(businessId)]
  end
  if not businessType and type(businessId) == "string" then
    local n = tonumber(businessId)
    if n ~= nil then
      businessType = businessContexts[n]
    end
  end
  if not businessType then
    local btype, matchedKey = purchasedBusinessTypeForId(businessId)
    if btype and matchedKey then
      setBusinessContext(btype, matchedKey)
      setBusinessContext(btype, businessId)
      businessType = btype
    end
  end
  return businessType
end

local function resolveBusinessModule(businessId)
  if not businessId then
    return nil, nil
  end
  local businessType = resolveBusinessTypeOnly(businessId)
  if not businessType then
    log('E', 'businessComputer', 'No business context for businessId=' .. tostring(businessId))
    return nil, nil
  end
  local module = getBusinessModule(businessType)
  if not module then
    log('E', 'businessComputer', 'Missing business module career_modules_business_' .. tostring(businessType))
    return nil, businessType
  end
  return module, businessType
end

local function invalidateVehicleInfoCache()
  vehicleInfoCache = nil
end

local function clearVehicleDataCaches()
  partsTreeCache = {}
  if career_modules_business_businessVehicleTuning then
    career_modules_business_businessVehicleTuning.clearTuningDataCache()
  end
end

local function isPersonalVehicleId(vehicleId)
  if not vehicleId then
    return false
  end
  local str = tostring(vehicleId)
  return str:sub(1, 9) == "personal_"
end

local getInventoryIdFromPersonalVehicleId

local function partsTreeCacheKeyForBusinessVehicle(businessId, vehicleIdStr, initialVehicle, isPersonal)
  if isPersonal then
    local invId = getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
    if invId then
      return "personal_" .. tostring(invId)
    end
    local str = tostring(vehicleIdStr)
    if str:sub(1, 9) == "personal_" then
      return str
    end
    return "personal_unknown"
  end
  if initialVehicle and initialVehicle.vehicleId ~= nil then
    return tostring(tonumber(initialVehicle.vehicleId) or initialVehicle.vehicleId)
  end
  return tostring(tonumber(vehicleIdStr) or vehicleIdStr)
end

local function clearCachesForVehicle(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return
  end
  local key
  if isPersonalVehicleId(vehicleId) then
    local invId = getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
    key = invId and ("personal_" .. tostring(invId)) or tostring(vehicleId)
  else
    key = tostring(tonumber(vehicleId) or vehicleId)
  end
  clearPartsTreeCacheForKey(businessId, key)
  if career_modules_business_businessVehicleTuning and
    career_modules_business_businessVehicleTuning.clearTuningDataCacheForVehicle then
    career_modules_business_businessVehicleTuning.clearTuningDataCacheForVehicle(businessId, key)
  end
end

local function getDamageThreshold(businessId)
  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getDamageThreshold then
      return businessObj.getDamageThreshold(businessId)
    end
  end
  return 1500
end

local function isRacingTeamBusinessId(businessId)
  return resolveBusinessTypeOnly(businessId) == "racingTeam"
end

local function getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not vehicleId then
    return nil
  end
  local str = tostring(vehicleId)
  if str:sub(1, 9) ~= "personal_" then
    return nil
  end
  local spawnedIdStr = str:sub(10)
  return tonumber(spawnedIdStr)
end

local function getActivePersonalVehicleRecord(vehicleId, businessId)
  if not isPersonalVehicleId(vehicleId) or not businessId then
    return nil
  end
  local _, businessType = resolveBusinessModule(businessId)
  if not businessType then
    return nil
  end
  local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if not businessObj or not businessObj.getActivePersonalVehicle then
    return nil
  end
  local activePersonal = businessObj.getActivePersonalVehicle(businessId)
  if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) then
    return activePersonal
  end
  return nil
end

local function getPersonalVehicleData(vehicleId, businessId)
  return getActivePersonalVehicleRecord(vehicleId, businessId)
end

getInventoryIdFromPersonalVehicleId = function(vehicleId, businessId)
  local rec = getActivePersonalVehicleRecord(vehicleId, businessId)
  return rec and rec.inventoryId or nil
end

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if isPersonalVehicleId(vehicleId) then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if spawnedId then
      return getObjectByID(spawnedId)
    end
    return nil
  end

  if career_modules_business_businessInventory then
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end
  end

  return nil
end

local function getVehicleDamageByVehId(vehId)
  if not vehId or not map or not map.objects then
    return 0
  end

  local objectData = map.objects[vehId]
  if not objectData then
    return 0
  end

  return objectData.damage or 0
end

local function normalizeVehicleIdValue(vehicleId)
  if vehicleId == nil then
    return nil
  end
  local num = tonumber(vehicleId)
  if num then
    return num
  end
  return vehicleId
end

local function getPulledOutVehiclesList(businessId)
  if not career_modules_business_businessInventory then
    return {}
  end
  if career_modules_business_businessInventory.getPulledOutVehicles then
    return career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
  end
  local vehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
  if vehicle then
    return {vehicle}
  end
  return {}
end

local function getActiveBusinessVehicle(businessId)
  if not businessId then
    return nil
  end

  if career_modules_business_businessInventory then
    if career_modules_business_businessInventory.getActiveVehicle then
      local active = career_modules_business_businessInventory.getActiveVehicle(businessId)
      if active then
        log("D", "businessComputer.getActiveBusinessVehicle", "Using active business vehicle for businessId=" .. tostring(businessId))
        return active
      end
    end
    local pulled = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
    if pulled then
      log("D", "businessComputer.getActiveBusinessVehicle", "Using pulled-out business vehicle for businessId=" .. tostring(businessId))
      return pulled
    end
  end

  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getActivePersonalVehicle then
      local personalVehicle = businessObj.getActivePersonalVehicle(businessId)
      if personalVehicle then
        log("D", "businessComputer.getActiveBusinessVehicle", "Using personal vehicle for businessId=" .. tostring(businessId))
        return personalVehicle
      end
    end
  end

  log("D", "businessComputer.getActiveBusinessVehicle", "No active vehicle found for businessId=" .. tostring(businessId))
  return nil
end

local function isDamageLocked(businessId, vehicleId)
  local threshold = getDamageThreshold(businessId)
  local lockInfo = {
    locked = false,
    damage = 0,
    threshold = threshold
  }

  if not businessId or not vehicleId then
    return lockInfo
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return lockInfo
  end

  local vehId = vehObj:getID()
  if not vehId then
    return lockInfo
  end

  local damage = getVehicleDamageByVehId(vehId)
  lockInfo.damage = damage
  lockInfo.locked = damage >= threshold

  return lockInfo
end

local function getDamageLockedVehicleInfo(businessId, vehicleId)
  if not businessId then
    return nil
  end

  if vehicleId then
    local lockInfo = isDamageLocked(businessId, vehicleId)
    if lockInfo.locked then
      lockInfo.vehicleId = vehicleId
      return lockInfo
    end
    return nil
  end

  for _, vehicle in ipairs(getPulledOutVehiclesList(businessId)) do
    local vId = normalizeVehicleIdValue(vehicle.vehicleId)
    local lockInfo = isDamageLocked(businessId, vId)
    if lockInfo.locked then
      lockInfo.vehicleId = vId
      return lockInfo
    end
  end

  return nil
end

local function notifyDamageLocked(lockInfo)
  if not lockInfo or not lockInfo.locked then
    return
  end

  local message = string.format("Vehicle damage (%.0f) exceeds the %d limit. Abandon the job to continue.",
    lockInfo.damage or 0, lockInfo.threshold or 1500)
  if ui_message then
    ui_message(message, 5, "Business Computer", "error")
  else
    log('W', 'businessComputer', message)
  end
end

local function shouldPreventVehicleOperation(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end
  if isRacingTeamBusinessId(businessId) then
    return false
  end

  local lockInfo = isDamageLocked(businessId, vehicleId)
  if lockInfo.locked then
    notifyDamageLocked(lockInfo)
    return true
  end

  return false
end

local function normalizeConfigKey(configKey)
  if not configKey then
    return nil
  end
  if configKey:find("/") then
    local parts = {}
    for part in configKey:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    if #parts > 0 then
      local filename = parts[#parts]
      local name, ext = filename:match("^(.+)%.(.+)$")
      return name or filename
    end
  else
    local name, ext = configKey:match("^(.+)%.(.+)$")
    return name or configKey
  end
  return configKey
end

local function getVehicleInfo(modelKey, configKey)
  if not modelKey or not configKey then
    return nil
  end

  local normalizedConfigKey = normalizeConfigKey(configKey)

  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    if not vehicleInfoCache then
      vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
    end

    for _, vehicleInfo in ipairs(vehicleInfoCache) do
      if vehicleInfo.model_key == modelKey then
        local vehicleKey = normalizeConfigKey(vehicleInfo.key)
        if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
          return vehicleInfo
        end
      end
    end
  end

  if core_vehicles and core_vehicles.getConfig then
    local model = core_vehicles.getModel(modelKey)
    if model and not tableIsEmpty(model) then
      local configName = normalizedConfigKey
      local configInfo = core_vehicles.getConfig(modelKey, configName)
      if configInfo then
        return {
          model_key = modelKey,
          key = configKey,
          Name = configInfo.Name or modelKey,
          Brand = configInfo.Brand or "",
          Years = configInfo.Years or {
            min = 1990,
            max = 2025
          },
          preview = configInfo.preview
        }
      end
    end
  end

  return nil
end

local function formatJobForUI(job, businessId)
  if not job then
    return nil
  end

  local vehicleConfig = job.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or "unknown"
  local configKey = vehicleConfig.key or "unknown"

  local name, vehicleYear, vehicleType, vehicleImage =
    career_modules_business_businessHelpers.extractDisplayInfo(getVehicleInfo(modelKey, configKey))
  local vehicleName = name or modelKey

  local timeUnit = "s"
  if job.raceType == "track" or job.raceType == "trackAlt" then
    timeUnit = "min"
  end

  local goalTimeFormatted = ""
  local goalTimeSeconds = job.targetTime or 0
  local decimalPlaces = job.decimalPlaces or 0
  if goalTimeSeconds >= 60 then
    local minutes = math.floor(goalTimeSeconds / 60)
    local seconds = math.floor(goalTimeSeconds % 60 + 0.5)
    if seconds >= 1 then
      goalTimeFormatted = string.format("%d min %d s", minutes, seconds)
    else
      goalTimeFormatted = string.format("%d min", minutes)
    end
  else
    if decimalPlaces > 0 then
      goalTimeFormatted = string.format("%." .. decimalPlaces .. "f s", goalTimeSeconds)
    else
      goalTimeFormatted = string.format("%d s", math.floor(goalTimeSeconds + 0.5))
    end
  end

  local goal = goalTimeFormatted .. " " .. (job.raceLabel or "")

  local baselineTime = job.baseTime or 0
  local currentTime = job.currentTime or job.baseTime or 0
  local goalTime = job.targetTime or 0

  local lbVehicleId = job.storedVehicleId
  if (not lbVehicleId) and job.jobId and career_modules_business_businessInventory and
    career_modules_business_businessInventory.getInventoryVehicleIdForJobId then
    lbVehicleId = career_modules_business_businessInventory.getInventoryVehicleIdForJobId(businessId, job.jobId)
  end
  if job.raceLabel and businessId and lbVehicleId then
    local bestTime = career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, lbVehicleId, job.raceType,
      job.raceLabel)
    if bestTime then
      currentTime = bestTime
    end
  end

  local penalty = math.floor((job.reward or 20000) * 0.5)

  return {
    id = tostring(job.jobId),
    jobId = job.jobId,
    storedVehicleId = job.storedVehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear or "Unknown",
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    goal = goal,
    reward = job.reward or 20000,
    status = job.status or "new",
    baselineTime = tonumber(string.format("%.1f", baselineTime)),
    currentTime = tonumber(string.format("%.1f", currentTime)),
    goalTime = tonumber(string.format("%.1f", goalTime)),
    timeUnit = timeUnit,
    raceType = job.raceType,
    raceLabel = job.raceLabel,
    decimalPlaces = job.decimalPlaces or 0,
    deadline = job.deadline or "7 days",
    priority = job.priority or "medium",
    penalty = penalty
  }
end

local function formatVehicleForUI(vehicle, businessId)
  if not vehicle then
    return nil
  end

  local vehicleConfig = vehicle.vehicleConfig or {}
  local modelKey = vehicleConfig.model_key or vehicle.model_key or "unknown"
  local configKey = vehicleConfig.key or vehicle.config_key or "unknown"

  local name, vehicleYear, vehicleType, vehicleImage =
    career_modules_business_businessHelpers.extractDisplayInfo(getVehicleInfo(modelKey, configKey))
  local vehicleName = name or modelKey

  local kitInstallLocked = false
  local kitInstallTimeRemaining = 0
  local kitInstallKitName = nil
  if businessId then
    local _, businessType = resolveBusinessModule(businessId)
    local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj then
      if businessObj.isVehicleKitLocked then
        kitInstallLocked = businessObj.isVehicleKitLocked(businessId, vehicle.vehicleId) or false
      end
      if businessObj.getKitInstallTimeRemaining then
        kitInstallTimeRemaining = businessObj.getKitInstallTimeRemaining(businessId, vehicle.vehicleId) or 0
      end
      if businessObj.getKitInstallLock then
        local lockInfo = businessObj.getKitInstallLock(businessId, vehicle.vehicleId)
        if lockInfo then
          kitInstallKitName = lockInfo.kitName
        end
      end
    end
  end

  local fleetRepairNeeded = false
  local fleetRepairDeductible = 750
  if businessId and isRacingTeamBusinessId(businessId) and career_modules_business_businessInventory
    and career_modules_business_businessInventory.getFleetInsuranceRepairQuote then
    local fq = career_modules_business_businessInventory.getFleetInsuranceRepairQuote(businessId, vehicle.vehicleId)
    if fq then
      fleetRepairNeeded = fq.needsRepair == true
      fleetRepairDeductible = math.max(0, math.floor(tonumber(fq.deductible) or 750))
    end
  end

  return {
    id = tostring(vehicle.vehicleId),
    vehicleId = vehicle.vehicleId,
    jobId = vehicle.jobId,
    storedVehicleId = vehicle.storedVehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    storedTime = vehicle.storedTime,
    kitInstallLocked = kitInstallLocked,
    kitInstallTimeRemaining = kitInstallTimeRemaining,
    kitInstallKitName = kitInstallKitName,
    fleetRepairNeeded = fleetRepairNeeded,
    fleetRepairDeductible = fleetRepairDeductible
  }
end

local function getBusinessComputerUIData(businessType, businessId)
  if not businessType or not businessId then
    return nil
  end

  setBusinessContext(businessType, businessId)

  if businessType == "racingTeam"
    and career_modules_business_businessInventory
    and career_modules_business_businessInventory.primeFleetRepairSnapshots then
    pcall(career_modules_business_businessInventory.primeFleetRepairSnapshots, businessId)
  end

  local module = getBusinessModule(businessType)
  if not module or not module.getUIData then
    log('E', 'businessComputer', 'Business module missing getUIData for type ' .. tostring(businessType))
    return nil
  end

  local ok, result = pcall(module.getUIData, businessId)
  if not ok then
    log('E', 'businessComputer', 'Error getting UI data for type ' .. tostring(businessType) .. ': ' .. tostring(result))
    return nil
  end

  if type(result) == "table" then
    local maintenanceEnabled = false
    if career_career and career_career.experimentalMaintenanceEnabled ~= nil then
      maintenanceEnabled = career_career.experimentalMaintenanceEnabled == true
    elseif career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled then
      maintenanceEnabled = career_modules_maintenanceMode.isEnabled() == true
    end
    result.experimentalMaintenanceEnabled = maintenanceEnabled
  end

  return result
end

local function requestPartInventory(businessId)
  if not businessId then
    if guihooks then
      guihooks.trigger('businessComputer:onPartInventoryData', {
        success = false,
        error = "Missing businessId"
      })
    end
    return
  end

  if not career_modules_business_businessPartInventory then
    if guihooks then
      guihooks.trigger('businessComputer:onPartInventoryData', {
        success = false,
        error = "Inventory module not available",
        businessId = businessId
      })
    end
    return
  end

  local data = career_modules_business_businessPartInventory.getUIData(businessId) or {}
  data.businessId = businessId
  data.success = true

  if guihooks then
    guihooks.trigger('businessComputer:onPartInventoryData', data)
  end
end

local function sellPart(businessId, partId)
  if not businessId or not partId then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local success, price = career_modules_business_businessPartInventory.sellPart(partId, businessId)
  if not success or price <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = price
        }
      }, account.id, "Sold Parts", "Sold part")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(price))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function sellAllParts(businessId)
  if not businessId then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local success, totalPrice = career_modules_business_businessPartInventory.sellAllParts(businessId)
  if not success or totalPrice <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = totalPrice
        }
      }, account.id, "Sold Parts", "Sold all parts")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(totalPrice))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function sellPartsByVehicle(businessId, vehicleNiceName)
  if not businessId or not vehicleNiceName then
    return false
  end

  if not career_modules_business_businessPartInventory then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local vehicleModel = nil
  local inventory = career_modules_business_businessPartInventory.getInventory()
  for _, part in pairs(inventory) do
    if part and part.vehicleModel and tostring(part.businessId or "") == tostring(businessId) then
      local modelData = core_vehicles.getModel(part.vehicleModel)
      if modelData and modelData.model then
        local brand = modelData.model.Brand or ""
        local name = modelData.model.Name
        local niceName = (brand .. " " .. name):match("^%s*(.-)%s*$")
        if niceName == vehicleNiceName then
          vehicleModel = part.vehicleModel
          break
        end
      end
    end
  end

  if not vehicleModel then
    return false
  end

  local success, totalPrice = career_modules_business_businessPartInventory.sellPartsByVehicle(vehicleModel, businessId)
  if not success or totalPrice <= 0 then
    return false
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      career_modules_bank.rewardToAccount({
        money = {
          amount = totalPrice
        }
      }, account.id, "Sold Parts", "Sold " .. vehicleNiceName .. " parts")
      if ui_message then
        ui_message(string.format("Sold parts $%s", tostring(math.floor(totalPrice))), 3, "Parts Inventory", "info")
      end
    end
  end

  career_modules_business_businessPartInventory.saveInventory()
  requestPartInventory(businessId)

  return true
end

local function acceptJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.acceptJob then
    local success = module.acceptJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobAccepted', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        newJobs = jobsData.newJobs,
        maxActiveJobs = jobsData.maxActiveJobs,
        vehicles = vehiclesData.vehicles
      })
    end
    return success
  end
  return false
end

local function acceptRacingTeamRaceOffer(businessId, offerId, techId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.acceptRacingTeamRaceOffer then
    return false
  end
  local success = module.acceptRacingTeamRaceOffer(businessId, offerId, techId)
  if success == true and guihooks then
    local uid = module.getUIData and module.getUIData(businessId)
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end
  return success
end

local function listLeague1FleetVehiclesForSanctionedOffer(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.listLeague1FleetVehiclesForSanctionedOffer then
    return {}
  end
  return module.listLeague1FleetVehiclesForSanctionedOffer(businessId, offerId) or {}
end

local function listLeague2FleetVehiclesForSanctionedOffer(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.listLeague2FleetVehiclesForSanctionedOffer then
    return {}
  end
  return module.listLeague2FleetVehiclesForSanctionedOffer(businessId, offerId) or {}
end

local function acceptRacingTeamRaceOfferAsPlayer(businessId, offerId, fleetVehicleId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.acceptRacingTeamRaceOfferAsPlayer then
    return false
  end
  local success = module.acceptRacingTeamRaceOfferAsPlayer(businessId, offerId, fleetVehicleId)
  if success == true and guihooks then
    local uid = module.getUIData and module.getUIData(businessId)
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end
  return success
end

local function acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(businessId, offerId, fleetVehicleId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy then
    return false
  end
  local success = module.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(businessId, offerId, fleetVehicleId)
  if success == true and guihooks then
    local uid = {}
    if type(module.getUIData) == "function" then
      local ok, data = pcall(module.getUIData, businessId)
      if ok and type(data) == "table" then
        uid = data
      end
    end
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end
  return success
end

local function declineRacingTeamRaceOffer(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.declineRacingTeamRaceOffer then
    return false
  end
  local success = module.declineRacingTeamRaceOffer(businessId, offerId)
  if success and guihooks then
    local uid = module.getUIData and module.getUIData(businessId)
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end
  return success
end

local function requestProxyDriverRace(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = opts.businessId
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.requestProxyDriverRace then
    return { ok = false, err = "not_racing_team" }
  end
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.requestProxyDriverRace then
    return rtFlow.requestProxyDriverRace(opts)
  end
  return module.requestProxyDriverRace(opts)
end

local function clearProxyDriverRaceRequest(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.clearProxyDriverRaceRequest then
    return
  end
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.clearProxyDriverRaceRequest then
    return rtFlow.clearProxyDriverRaceRequest(businessId)
  end
  module.clearProxyDriverRaceRequest(businessId)
end

local function getProxyDriverRaceRequest(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.getProxyDriverRaceRequest then
    return nil
  end
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.getProxyDriverRaceRequest then
    return rtFlow.getProxyDriverRaceRequest(businessId)
  end
  return module.getProxyDriverRaceRequest(businessId)
end

local function acceptLeague2Invite(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.acceptLeague2Invite then
    return false, "not_racing_team"
  end
  return module.acceptLeague2Invite(businessId)
end

local function declineLeague2Invite(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.declineLeague2Invite then
    return false
  end
  return module.declineLeague2Invite(businessId)
end

local function racingTeamMilestoneLeague2Later(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.racingTeamMilestoneLeague2Later then
    return false
  end
  return module.racingTeamMilestoneLeague2Later(businessId)
end

local function racingTeamMilestoneLeague2Accept(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.racingTeamMilestoneLeague2Accept then
    return false, "not_racing_team"
  end
  return module.racingTeamMilestoneLeague2Accept(businessId)
end

local function racingTeamMilestoneLeague2WelcomeContinue(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.racingTeamMilestoneLeague2WelcomeContinue then
    return false
  end
  return module.racingTeamMilestoneLeague2WelcomeContinue(businessId)
end

local function racingTeamMilestonePurchaseContinue(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.racingTeamMilestonePurchaseContinue then
    return false
  end
  return module.racingTeamMilestonePurchaseContinue(businessId)
end

local function racingTeamMilestoneCareerFinaleContinue(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.racingTeamMilestoneCareerFinaleContinue then
    return false
  end
  return module.racingTeamMilestoneCareerFinaleContinue(businessId)
end

local function assignRolledProxyRaceToDriver(businessId, techId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.assignRolledProxyRaceToDriver then
    return false
  end
  return module.assignRolledProxyRaceToDriver(businessId, techId)
end

local function acceptRacingTeamSponsorOffer(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.acceptRacingTeamSponsorOffer then
    return false
  end
  return module.acceptRacingTeamSponsorOffer(businessId, offerId)
end

local function declineRacingTeamSponsorOffer(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.declineRacingTeamSponsorOffer then
    return false
  end
  return module.declineRacingTeamSponsorOffer(businessId, offerId)
end

local function dropRacingTeamSponsorActive(businessId, offerId)
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module or not module.dropRacingTeamSponsorActive then
    return false
  end
  return module.dropRacingTeamSponsorActive(businessId, offerId)
end

local function findProxyDriverRaceRequestForLevel(levelId)
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.findProxyDriverRaceRequestForLevel then
    return rtFlow.findProxyDriverRaceRequestForLevel(levelId)
  end
  local module = career_modules_business_racingTeam
  if not module or not module.findProxyDriverRaceRequestForLevel then
    return nil, nil
  end
  return module.findProxyDriverRaceRequestForLevel(levelId)
end

local function enterRacingTeamProxyStagingLoadingEarly()
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf and ctf.enterRacingTeamProxyStagingLoadingEarly then
    ctf.enterRacingTeamProxyStagingLoadingEarly()
  end
end

local function preflightRacingTeamProxySpectateUi(businessId)
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf and ctf.preflightRacingTeamProxySpectateUi then
    ctf.preflightRacingTeamProxySpectateUi(businessId)
  end
end

local function refreshRacingTeamProxySpectatorUiMinimal()
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf and ctf.refreshRacingTeamProxySpectatorUiMinimalIfActive then
    ctf.refreshRacingTeamProxySpectatorUiMinimalIfActive()
  end
end

local function beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  if not businessId then
    return { ok = false, err = "no_business" }
  end
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.beginRacingTeamProxyRaceFromBusinessComputer then
    return rtFlow.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if not ctf or not ctf.beginRacingTeamProxyRaceFromBusinessComputer then
    return { ok = false, err = "no_track_flow" }
  end
  return ctf.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
end

local function simulateRacingTeamProxyRace(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = opts.businessId
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module then
    return { ok = false, err = "not_racing_team" }
  end
  local rtFlow = racingTeamRaceFlowModule()
  if rtFlow and rtFlow.simulateRacingTeamProxyRace then
    return rtFlow.simulateRacingTeamProxyRace(opts)
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  local armOpts = {}
  for k, v in pairs(opts) do
    armOpts[k] = v
  end
  armOpts.spectateStaging = true
  local armRes = requestProxyDriverRace(armOpts)
  if not armRes or armRes.ok ~= true then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
    return armRes or { ok = false, err = "request_failed" }
  end
  local beginRes = beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  if type(beginRes) ~= "table" then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
    return { ok = false, err = "begin_failed" }
  end
  if beginRes.ok ~= true then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
  end
  return beginRes
end

local function sendRacingTeamDriverWithManager(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = opts.businessId
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module then
    return { ok = false, err = "not_racing_team" }
  end
  if module.sendDriverWithManager then
    return module.sendDriverWithManager(businessId, opts.driverId)
  end
  return { ok = false, err = "not_supported" }
end

local function setRacingTeamAutoStartBackgroundRaces(opts)
  if type(opts) ~= "table" then
    return false
  end
  local businessId = opts.businessId
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module then
    return false
  end
  if module.setAutoStartBackgroundRaces then
    return module.setAutoStartBackgroundRaces(businessId, opts.enabled)
  end
  return false
end

local function cancelRacingTeamBackgroundRace(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = opts.businessId
  local module, businessType = resolveBusinessModule(businessId)
  if businessType ~= "racingTeam" or not module then
    return { ok = false, err = "not_racing_team" }
  end
  if module.cancelBackgroundRaceSim then
    return module.cancelBackgroundRaceSim(businessId, opts.driverId, opts.reason)
  end
  return { ok = false, err = "not_supported" }
end

local function isProxyScheduledDriverFleetOverpowered(businessId, driverId)
  if not businessId or driverId == nil then
    return { overpowered = false }
  end
  local rt = career_modules_business_racingTeam
  if not rt or not rt.isProxyScheduledDriverFleetOverpowered then
    return { overpowered = false }
  end
  return rt.isProxyScheduledDriverFleetOverpowered(businessId, driverId) or { overpowered = false }
end

local function isArmedProxyFleetOverpoweredForRequest(businessId)
  if not businessId then
    return { overpowered = false }
  end
  local rt = career_modules_business_racingTeam
  if not rt or not rt.isArmedProxyFleetOverpoweredForRequest then
    return { overpowered = false }
  end
  return rt.isArmedProxyFleetOverpoweredForRequest(businessId) or { overpowered = false }
end

local function cancelRacingTeamProxySession(businessId)
  if not businessId then
    return { ok = false, err = "no_business" }
  end
  local req = getProxyDriverRaceRequest(businessId)
  local fleeId = req and (tonumber(req.fleetVehicleId) or req.fleetVehicleId)
  local fe = gameplay_events_freeroamEvents
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  local rbd = gameplay_raceBusinessDriver
  local inv = career_modules_business_businessInventory
  local abandoned = false
  if fe and fe.forceAbandonActiveTrackRace then
    abandoned = fe.forceAbandonActiveTrackRace("Team race cancelled") == true
  end
  if not abandoned then
    if ctf and ctf.cancelCompetitiveGridFlow then
      ctf.cancelCompetitiveGridFlow()
    end
    if fe and fe.clearSanctionedDispatchStaging then
      fe.clearSanctionedDispatchStaging()
    end
    if ctf and ctf.leaveTrackFlowAfterRace then
      ctf.leaveTrackFlowAfterRace()
    end
    if rbd and rbd.endRideAlongSession then
      rbd.endRideAlongSession()
    end
    if rbd and rbd.hasPreRaceWorldState and rbd.hasPreRaceWorldState() and rbd.restorePreRaceWorldState then
      rbd.restorePreRaceWorldState()
    end
    if fleeId and inv and inv.removeBusinessVehicleObject then
      inv.removeBusinessVehicleObject(businessId, fleeId)
    end
  end
  local rt = career_modules_business_racingTeam
  if rt and rt.clearRacingTeamProxyDriverAssignment then
    rt.clearRacingTeamProxyDriverAssignment(businessId, { returnOfferToBoard = true, proxyRequest = req })
  end
  clearProxyDriverRaceRequest(businessId)
  if guihooks and guihooks.trigger then
    if ctf and ctf.relayRacingTeamProxyOverlay then
      ctf.relayRacingTeamProxyOverlay({ visible = false })
    else
      guihooks.trigger("racingTeamProxyOverlay", { visible = false })
    end
    local module = career_modules_business_racingTeam
    if module and module.getUIData then
      local uid = module.getUIData(businessId)
      guihooks.trigger("businessComputer:onRaceOffersUpdated", {
        businessId = businessId,
        raceOffers = uid and uid.raceOffers or {},
        raceOffersLevelId = uid and uid.raceOffersLevelId,
        raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
        raceOffersMessage = uid and uid.raceOffersMessage,
        racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
      })
    end
  end
  return { ok = true }
end

local function cancelRacingTeamProxyScheduledRace(businessId, driverId)
  businessId = tonumber(businessId) or businessId
  local isPlayer = tostring(driverId) == "player"
  local numDriverId = tonumber(driverId)
  if not businessId or (not isPlayer and not numDriverId) then
    return { ok = false, err = "missing_business_or_driver" }
  end
  local req = getProxyDriverRaceRequest(businessId)
  if not isPlayer and req and req.racingTeamProxyRace == true and tonumber(req.driverId) == numDriverId then
    return cancelRacingTeamProxySession(businessId)
  end
  local rt = career_modules_business_racingTeam
  if not rt or not rt.cancelUnarmedScheduledRacingTeamProxyRace then
    return { ok = false, err = "no_racing_team" }
  end
  return rt.cancelUnarmedScheduledRacingTeamProxyRace(businessId, isPlayer and "player" or numDriverId)
end

local function cancelRacingTeamPlayerRace(businessId)
  businessId = tonumber(businessId) or businessId
  if not businessId then
    return { ok = false, err = "missing_business" }
  end
  local rt = career_modules_business_racingTeam
  if not rt or not rt.cancelUnarmedScheduledRacingTeamPlayerRace then
    return { ok = false, err = "no_racing_team" }
  end
  return rt.cancelUnarmedScheduledRacingTeamPlayerRace(businessId)
end

local function startRacingTeamVehicleAssessment(businessId, vehicleId)
  businessId = tonumber(businessId) or businessId
  vehicleId = tonumber(vehicleId) or vehicleId
  if not businessId or vehicleId == nil then
    return { ok = false, err = "missing_business_or_vehicle" }
  end
  local rt = career_modules_business_racingTeam
  if not rt or not rt.startVehicleAssessment then
    return { ok = false, err = "no_racing_team_assess" }
  end
  return rt.startVehicleAssessment(businessId, vehicleId)
end

local function isScheduledRaceReadyForDriver(businessId, techId)
  local module = career_modules_business_racingTeam
  if not module or not module.isScheduledRaceReadyForDriver then
    return true
  end
  return module.isScheduledRaceReadyForDriver(businessId, techId)
end

local function getRacingTeamCareerSimTime()
  local rt = rawget(_G, "career_modules_business_racingTeam")
  if rt and rt.getCareerSimTime then
    return rt.getCareerSimTime()
  end
  return nil
end

local function tickRacingTeamScheduledRaceToasts()
  local rt = rawget(_G, "career_modules_business_racingTeam")
  if rt and rt.tickScheduledRaceReadyToasts then
    rt.tickScheduledRaceReadyToasts()
  end
end

local function declineJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.declineJob then
    local success = module.declineJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      guihooks.trigger('businessComputer:onJobDeclined', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        newJobs = jobsData.newJobs
      })
    end
    return success
  end
  return false
end

local function abandonJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.abandonJob then
    local success = module.abandonJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobAbandoned', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles
      })
    end
    return success
  end
  return false
end

local function sellVehicle(businessId, vehicleId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module or not module.sellVehicle then
    return false
  end
  local success = module.sellVehicle(businessId, vehicleId)
  if success and guihooks then
    local vehiclesData = M.getVehiclesOnly(businessId)
    guihooks.trigger('businessComputer:onVehicleSold', {
      businessType = businessType,
      businessId = businessId,
      vehicleId = vehicleId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles
    })
  end
  return success
end

local function assignTechToJob(businessId, techId, jobId)
  if not businessId or not techId or not jobId then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local module = getBusinessModule(businessType)
  if module and module.assignJobToTech then
    local ok, result = pcall(module.assignJobToTech, businessId, techId, jobId)
    if not ok then
      log('E', 'businessComputer', 'assignTechToJob failed: ' .. tostring(result))
      return false
    end
    if result and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local techsData = M.getTechsOnly(businessId)
      guihooks.trigger('businessComputer:onTechAssigned', {
        businessType = businessType,
        businessId = businessId,
        techId = techId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        techs = techsData.techs
      })
    end
    return result
  end

  return false
end

local function renameTech(businessId, techId, newName)
  if not businessId or not techId then
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    return false
  end

  local module = getBusinessModule(businessType)
  if module and module.updateTechName then
    local ok, result = pcall(module.updateTechName, businessId, techId, newName)
    if not ok then
      log('E', 'businessComputer', 'renameTech failed: ' .. tostring(result))
      return false
    end
    return result
  end

  return false
end

local function pullOutVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    log('D', 'businessComputer.pullOut', 'abort: missing businessId or vehicleId')
    return false
  end

  local businessType = businessContexts[businessId]
  if not businessType then
    log('E', 'businessComputer',
      'Cannot pull out vehicle, unknown business type for businessId=' .. tostring(businessId))
    return {
      success = false,
      errorCode = "unknownBusiness"
    }
  end

  log('D', 'businessComputer.pullOut',
    string.format('start businessId=%s vehicleId=%s businessType=%s', tostring(businessId), tostring(vehicleId),
      tostring(businessType)))

  local module = getBusinessModule(businessType)
  local maxPulledOut = 1
  if module and module.getMaxPulledOutVehicles then
    maxPulledOut = tonumber(module.getMaxPulledOutVehicles(businessId)) or 1
  end
  if maxPulledOut < 1 then
    maxPulledOut = 1
  end

  if not isRacingTeamBusinessId(businessId) then
    local lockInfo = getDamageLockedVehicleInfo(businessId)
    if lockInfo then
      log('D', 'businessComputer.pullOut', 'return damageLocked businessId=' .. tostring(businessId))
      notifyDamageLocked(lockInfo)
      return {
        success = false,
        errorCode = "damageLocked"
      }
    end
  end

  local normalizedVehicleId = normalizeVehicleIdValue(vehicleId)
  local raceSimModule = rawget(_G, "career_modules_business_racingTeamRaceSim")
  local raceSimData = raceSimModule and raceSimModule.getActiveSim(businessId)
  if raceSimData and tonumber(raceSimData.fleetVehicleId) == tonumber(normalizedVehicleId) then
    log('D', 'businessComputer.pullOut', string.format('vehicle currently in background sim race: businessId=%s, vehicleId=%s', tostring(businessId), tostring(vehicleId)))
    return {
      success = false,
      errorCode = "simRacingLocked"
    }
  end

  local pulledOutVehiclesList = getPulledOutVehiclesList(businessId)
  for _, current in ipairs(pulledOutVehiclesList) do
    local currentId = normalizeVehicleIdValue(current.vehicleId)
    if currentId == normalizedVehicleId then
      if career_modules_business_businessInventory.setActiveVehicle then
        career_modules_business_businessInventory.setActiveVehicle(businessId, normalizedVehicleId)
      end
      return true
    end
  end

  if module and module.isJobLockedByTech and career_modules_business_businessInventory then
    local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
    for _, stored in ipairs(vehicles) do
      local storedId = normalizeVehicleIdValue(stored.vehicleId)
      if storedId == normalizedVehicleId then
        local jobId = tonumber(stored.jobId) or stored.jobId
        if jobId and module.isJobLockedByTech(businessId, jobId) then
          log('D', 'businessComputer.pullOut',
            string.format('return jobLocked businessId=%s vehicleId=%s jobId=%s', tostring(businessId),
              tostring(normalizedVehicleId), tostring(jobId)))
          return {
            success = false,
            errorCode = "jobLocked"
          }
        end
        break
      end
    end
  end

  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.isVehicleKitLocked then
    if businessObj.isVehicleKitLocked(businessId, normalizedVehicleId) then
      local remaining = businessObj.getKitInstallTimeRemaining and businessObj.getKitInstallTimeRemaining(businessId, normalizedVehicleId) or 0
      log('D', 'businessComputer.pullOut',
        string.format('return kitInstallLocked businessId=%s vehicleId=%s remaining=%s', tostring(businessId),
          tostring(normalizedVehicleId), tostring(remaining)))
      return {
        success = false,
        errorCode = "kitInstallLocked",
        timeRemaining = remaining
      }
    end
  end

  if isRacingTeamBusinessId(businessId) then
    local fq = career_modules_business_businessInventory.getFleetInsuranceRepairQuote(businessId, normalizedVehicleId)
    if fq and fq.needsRepair then
      log('D', 'businessComputer.pullOut',
        string.format('return repairRequired businessId=%s vehicleId=%s', tostring(businessId), tostring(normalizedVehicleId)))
      return {
        success = false,
        errorCode = "repairRequired",
        message = "Vehicle must be repaired before pulling out."
      }
    end
  end

  if #pulledOutVehiclesList >= maxPulledOut then
    local message = string.format("All %d lift slots are in use. Put away a vehicle first.", maxPulledOut)
    log('D', 'businessComputer.pullOut',
      string.format('return maxVehicles businessId=%s pulledOut=%d max=%d', tostring(businessId),
        #pulledOutVehiclesList, maxPulledOut))
    return {
      success = false,
      errorCode = "maxVehicles",
      message = message
    }
  end

  local result = career_modules_business_businessInventory.pullOutVehicle(businessType, businessId, vehicleId)
  log('D', 'businessComputer.pullOut',
    string.format('inventory.pullOutVehicle result=%s businessId=%s vehicleId=%s', tostring(result),
      tostring(businessId), tostring(vehicleId)))
  if result and career_modules_business_businessInventory.setActiveVehicle then
    career_modules_business_businessInventory.setActiveVehicle(businessId, normalizedVehicleId)
  end
  if result and guihooks then
    local vehiclesData = M.getVehiclesOnly(businessId)
    guihooks.trigger('businessComputer:onVehiclePulledOut', {
      businessType = businessType,
      businessId = businessId,
      vehicleId = normalizedVehicleId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
    })
  end
  return result
end

local function putAwayVehicle(businessId, vehicleId)
  if not businessId then
    return false
  end

  local businessType = businessContexts[businessId]
  local targetVehicleId = vehicleId
  if not targetVehicleId then
    local activeVehicle = getActiveBusinessVehicle(businessId)
    targetVehicleId = activeVehicle and activeVehicle.vehicleId
  end

  if targetVehicleId then
    local normalizedVehicleId = normalizeVehicleIdValue(targetVehicleId)
    if not isRacingTeamBusinessId(businessId) then
      local lockInfo = getDamageLockedVehicleInfo(businessId, normalizedVehicleId)
      if lockInfo then
        notifyDamageLocked(lockInfo)
        return {
          success = false,
          errorCode = "damageLocked"
        }
      end
    end
    local result = career_modules_business_businessInventory.putAwayVehicle(businessId, normalizedVehicleId, function()
      if guihooks then
        local vehiclesData = M.getVehiclesOnly(businessId)
        guihooks.trigger('businessComputer:onVehiclePutAway', {
          businessType = businessType,
          businessId = businessId,
          vehicleId = normalizedVehicleId,
          vehicles = vehiclesData.vehicles,
          pulledOutVehicles = vehiclesData.pulledOutVehicles,
          maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
        })
      end
    end)
    return result
  end

  if not isRacingTeamBusinessId(businessId) then
    local lockInfo = getDamageLockedVehicleInfo(businessId)
    if lockInfo then
      notifyDamageLocked(lockInfo)
      return {
        success = false,
        errorCode = "damageLocked"
      }
    end
  end

  local result = career_modules_business_businessInventory.putAwayVehicle(businessId, nil, function()
    if guihooks then
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onVehiclePutAway', {
        businessType = businessType,
        businessId = businessId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles,
        maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
      })
    end
  end)
  return result
end

local function computeBusinessVehicleRepairCost(businessId, vehicleId)
  local threshold = getDamageThreshold(businessId)
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return nil
  end
  local vid = vehObj:getID()
  local damage = getVehicleDamageByVehId(vid)
  if damage < 1 then
    return 0, damage, threshold
  end
  local ratio = math.min(1, damage / math.max(1, threshold))
  return math.floor(150 + ratio * 5500), damage, threshold
end

local function repairBusinessVehicleDamage(businessId, vehicleId)
  if not businessId or not vehicleId then
    return { success = false, errorCode = "badArgs" }
  end
  local businessType = resolveBusinessTypeOnly(businessId)
  if not businessType then
    return { success = false, errorCode = "unknownBusiness" }
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getSpawnedVehicleId or not inv.repairSpawnedBusinessVehicle then
    return { success = false, errorCode = "noInventory" }
  end
  if isRacingTeamBusinessId(businessId) and inv.repairFleetVehicleInsuranceStyle then
    return inv.repairFleetVehicleInsuranceStyle(businessId, vehicleId, businessType)
  end
  local sid = inv.getSpawnedVehicleId(businessId, vehicleId)
  if not sid then
    return { success = false, errorCode = "notPulledOut" }
  end
  local cost, damage, thr = computeBusinessVehicleRepairCost(businessId, vehicleId)
  if cost == nil then
    return { success = false, errorCode = "noVehicle" }
  end
  if cost <= 0 then
    return { success = true, cost = 0, damage = damage or 0, threshold = thr }
  end
  if not career_modules_bank then
    return { success = false, errorCode = "noBank" }
  end
  local account = career_modules_bank.getBusinessAccount(businessType, businessId)
  if not account then
    return { success = false, errorCode = "noAccount" }
  end
  local paid = career_modules_bank.payFromAccount({
    money = { amount = cost, canBeNegative = false },
  }, account.id, "Vehicle Repair", "Garage vehicle repair")
  if not paid then
    return { success = false, errorCode = "noFunds", cost = cost }
  end
  local ok = inv.repairSpawnedBusinessVehicle(businessId, vehicleId)
  if not ok then
    career_modules_bank.rewardToAccount({ money = { amount = cost } }, account.id, "Refund", "Repair failed")
    return { success = false, errorCode = "repairFailed", cost = cost }
  end
  if ui_message then
    ui_message(string.format("Vehicle repaired for $%d.", cost), 5, "Business Computer", "info")
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return { success = true, cost = cost, damage = damage, threshold = thr }
end

local function startVehiclePainting(businessId, vehicleId)
  if not businessId or not vehicleId then
    return { success = false, errorCode = "badArgs" }
  end
  local businessType = resolveBusinessTypeOnly(businessId)
  if not businessType then
    return { success = false, errorCode = "unknownBusiness" }
  end
  if not isRacingTeamBusinessId(businessId) then
    return { success = false, errorCode = "unsupportedBusiness" }
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getSpawnedVehicleId then
    return { success = false, errorCode = "noInventory" }
  end
  local sid = inv.getSpawnedVehicleId(businessId, vehicleId)
  if not sid or not getObjectByID(sid) then
    return { success = false, errorCode = "notPulledOut" }
  end
  if not career_modules_painting or not career_modules_painting.startForBusinessVehicle then
    return { success = false, errorCode = "paintingUnavailable" }
  end
  local ok, reason = career_modules_painting.startForBusinessVehicle(businessId, vehicleId, nil)
  if not ok then
    return { success = false, errorCode = reason or "paintingFailed" }
  end
  return { success = true }
end

local function startVehicleRefueling(businessId, vehicleId)
  if not businessId or not vehicleId then
    return { success = false, errorCode = "badArgs" }
  end
  local businessType = resolveBusinessTypeOnly(businessId)
  if not businessType then
    return { success = false, errorCode = "unknownBusiness" }
  end
  if not isRacingTeamBusinessId(businessId) then
    return { success = false, errorCode = "unsupportedBusiness" }
  end

  local skillTree = career_modules_business_businessSkillTree
  if skillTree and skillTree.getNodeProgress then
    local ok, lv = pcall(skillTree.getNodeProgress, businessId, "team-operations", "pit-fuel")
    if not ok or (tonumber(lv) or 0) < 1 then
      return { success = false, errorCode = "pitFuelLocked" }
    end
  end

  local inv = career_modules_business_businessInventory
  if not inv or not inv.getSpawnedVehicleId then
    return { success = false, errorCode = "noInventory" }
  end
  local sid = inv.getSpawnedVehicleId(businessId, vehicleId)
  if not sid or not getObjectByID(sid) then
    return { success = false, errorCode = "notPulledOut" }
  end
  if not career_modules_fuel or not career_modules_fuel.startForBusinessVehicle then
    return { success = false, errorCode = "fuelingUnavailable" }
  end
  local ok, reason = career_modules_fuel.startForBusinessVehicle(businessId, vehicleId)
  if not ok then
    return { success = false, errorCode = reason or "fuelingFailed" }
  end
  return { success = true }
end

local function getActiveJobs(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getActiveJobs then
    return module.getActiveJobs(businessId)
  end
  return {}
end

local function getNewJobs(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getNewJobs then
    return module.getNewJobs(businessId)
  end
  return {}
end

local function getBrandSelection(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getBrandSelection then
    return module.getBrandSelection(businessId)
  end
  return nil
end

local function setBrandSelection(businessId, brand)
  local module = resolveBusinessModule(businessId)
  if module and module.setBrandSelection then
    return module.setBrandSelection(businessId, brand)
  end
  return false
end

local function getRaceSelection(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getRaceSelection then
    return module.getRaceSelection(businessId)
  end
  return nil
end

local function setRaceSelection(businessId, raceType)
  local module = resolveBusinessModule(businessId)
  if module and module.setRaceSelection then
    return module.setRaceSelection(businessId, raceType)
  end
  return false
end

local function getAvailableBrands()
  local ts = career_modules_business_tuningShop
  if ts and ts.getAvailableBrands then
    return ts.getAvailableBrands()
  end
  return {}
end

local function getAvailableRaceTypes()
  local ts = career_modules_business_tuningShop
  if ts and ts.getAvailableRaceTypes then
    return ts.getAvailableRaceTypes()
  end
  return {}
end

local function requestAvailableBrands()
  local ts = career_modules_business_tuningShop
  if ts and ts.requestAvailableBrands then
    ts.requestAvailableBrands()
  end
end

local function requestAvailableRaceTypes(businessId)
  if not businessId then
    return
  end
  local ts = career_modules_business_tuningShop
  if ts and ts.requestAvailableRaceTypes then
    ts.requestAvailableRaceTypes(businessId)
  end
end

local function getPartSupplierDiscountMultiplier(businessId)
  if not businessId then
    return 1.0
  end

  local _, businessType = resolveBusinessModule(businessId)
  if businessType then
    local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
    if businessObj and businessObj.getPartSupplierDiscountMultiplier then
      return businessObj.getPartSupplierDiscountMultiplier(businessId)
    end
  end

  return 1.0
end

local function buildOwnedPartsLookup(inventoryParts, vehicleModel)
  if not inventoryParts then
    return nil
  end
  local lookup = {}
  for _, part in ipairs(inventoryParts) do
    if part and part.name then
      if not part.vehicleModel or part.vehicleModel == vehicleModel then
        local mileage = part.mileage
        if not mileage and part.partCondition and part.partCondition.odometer then
          mileage = part.partCondition.odometer / 1609.344
        end
        local variant = {
          partId = part.partId,
          name = part.name,
          partCondition = part.partCondition,
          finalValue = part.finalValue,
          value = part.value,
          mileage = mileage
        }
        lookup[part.name] = lookup[part.name] or {}
        table.insert(lookup[part.name], variant)
      end
    end
  end
  return lookup
end

local function findRemovedPartsFromCart(businessId, vehicleId, cartParts, baselinePartList, baselinePartConditions)
  if not businessId or not vehicleId or not cartParts then
    return {}
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return {}
  end

  local vehicleModel = vehicle.vehicleConfig and vehicle.vehicleConfig.model_key or vehicle.model_key

  local originalPartList = baselinePartList or vehicle.partList or {}
  local partConditions = baselinePartConditions or vehicle.partConditions or {}

  if next(originalPartList) == nil and not baselinePartList then
    local vehObj = getBusinessVehicleObject(businessId, vehicleId)
    if vehObj then
      local vehId = vehObj:getID()
      local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if vehicleData and vehicleData.config and vehicleData.config.partsTree then
        local function extractParts(tree, path)
          path = path or "/"
          if tree.chosenPartName and tree.path then
            originalPartList[tree.path] = tree.chosenPartName
          end
          if tree.children then
            for slotName, child in pairs(tree.children) do
              local childPath = path .. slotName .. "/"
              extractParts(child, childPath)
            end
          end
        end
        extractParts(vehicleData.config.partsTree)
        
        if vehicleData.partConditions then
          partConditions = vehicleData.partConditions
        end
      end
    end
  end

  local cartPartsBySlot = {}
  for _, part in ipairs(cartParts) do
    if part.slotPath and part.partName and part.partName ~= "" then
      cartPartsBySlot[part.slotPath] = part.partName
    elseif part.slotPath and part.emptyPlaceholder then
      cartPartsBySlot[part.slotPath] = ""
    end
  end

  local removedParts = {}
  for slotPath, originalPartName in pairs(originalPartList) do
    if originalPartName and originalPartName ~= "" then
      local cartPartName = cartPartsBySlot[slotPath]
      if cartPartName ~= nil and cartPartName ~= originalPartName then
        local partCondition = partConditions[slotPath .. originalPartName]
        if not partCondition then
          partCondition = {
            integrityValue = 1,
            visualValue = 1,
            odometer = 0
          }
        end

        local partData = {
          name = originalPartName,
          containingSlot = slotPath,
          slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
          vehicleModel = vehicleModel,
          year = vehicle.year,
          partCondition = partCondition,
          partPath = slotPath .. originalPartName,
          rlsTireState = vehicle.rlsTireStateByPartPath and
                           deepcopy(vehicle.rlsTireStateByPartPath[slotPath .. originalPartName]) or nil,
        }

        if career_modules_valueCalculator then
          partData.value = career_modules_valueCalculator.getPartValue(partData, true) or 0
        else
          partData.value = 100
        end

        table.insert(removedParts, partData)
      end
    end
  end

  return removedParts
end

local function formatPartsTreeForUI(node, slotName, slotInfo, availableParts, slotsNiceName, partsNiceName, pathPrefix,
  parentSlotName, ioCtx, businessId, vehicleData, vehicleModel, ownedPartsByName)
  if not node then
    return {}
  end

  local result = {}
  local currentPath = node.path or pathPrefix or "/"

  local isRootNode = (currentPath == "/" or currentPath == "" or slotName == "")

  local slotNiceName = node.slotNiceName or ""
  if not slotNiceName and slotInfo then
    slotNiceName = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description or
                     slotName or ""
  elseif not slotNiceName and slotName and slotsNiceName[slotName] then
    slotNiceName = type(slotsNiceName[slotName]) == "table" and slotsNiceName[slotName].description or
                     slotsNiceName[slotName] or slotName
  elseif not slotNiceName and slotName then
    slotNiceName = slotName
  end

  local partNiceName = node.chosenPartNiceName or ""
  if node.chosenPartName and availableParts[node.chosenPartName] then
    local partInfo = availableParts[node.chosenPartName]
    local desc = partInfo.description
    partNiceName = type(desc) == "table" and desc.description or desc or node.chosenPartName
    partsNiceName[node.chosenPartName] = partNiceName
  elseif node.chosenPartName then
    partNiceName = node.chosenPartName
  end

  local partInfo = nil
  if node.chosenPartName and availableParts[node.chosenPartName] then
    partInfo = availableParts[node.chosenPartName]
  end

  local currentSlotInfo = slotInfo
  if not currentSlotInfo and partInfo and partInfo.slotInfoUi and slotName then
    currentSlotInfo = partInfo.slotInfoUi[slotName]
  end

  if not isRootNode and node.suitablePartNames and #node.suitablePartNames > 0 then
    local availablePartsList = {}
    local addedPartNames = {}

    for _, partName in ipairs(node.suitablePartNames) do
      local partInfoData = availableParts[partName]
      if partInfoData then
        local desc = partInfoData.description
        local niceName = type(desc) == "table" and desc.description or desc or partName

        local value = 100
        local baseValue = 100
        if ioCtx then
          local jbeamData = jbeamIO.getPart(ioCtx, partName)
          if jbeamData and jbeamData.information and jbeamData.information.value then
            baseValue = jbeamData.information.value
          elseif partInfoData.information and partInfoData.information.value then
            baseValue = partInfoData.information.value
          end
        elseif partInfoData.information and partInfoData.information.value then
          baseValue = partInfoData.information.value
        end

        if career_modules_valueCalculator and vehicleModel then
          local partForValueCalc = {
            name = partName,
            value = baseValue,
            partCondition = {
              integrityValue = 1,
              odometer = 0,
              visualValue = 1
            },
            vehicleModel = vehicleModel
          }
          value = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
        else
          value = baseValue
        end

        if businessId and value > 0 then
          local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
          value = value * discountMultiplier
        end

        table.insert(availablePartsList, {
          name = partName,
          niceName = niceName,
          value = value,
          installed = (node.chosenPartName == partName)
        })
        addedPartNames[partName] = true
      end
    end

    local slotCompatibleVariants = {}
    if ownedPartsByName then
      for _, partName in ipairs(node.suitablePartNames) do
        local variants = ownedPartsByName[partName]
        if variants and #variants > 0 then
          local existingEntry = nil
          for _, entry in ipairs(availablePartsList) do
            if entry.name == partName then
              existingEntry = entry
              break
            end
          end
          if not existingEntry then
            local partInfoData = availableParts[partName]
            local niceName = partName
            if partInfoData then
              local desc = partInfoData.description
              niceName = type(desc) == "table" and desc.description or desc or partName
            end
            existingEntry = {
              name = partName,
              niceName = niceName,
              value = 0,
              installed = false,
              fromInventory = true,
              isOwned = true
            }
            table.insert(availablePartsList, existingEntry)
          end
          existingEntry.hasOwnedVariants = true
          existingEntry.ownedVariants = variants
          for _, variant in ipairs(variants) do
            table.insert(slotCompatibleVariants, variant)
          end
        end
      end
    end

    table.sort(availablePartsList, function(a, b)
      local nameA = string.lower(a.niceName or a.name or "")
      local nameB = string.lower(b.niceName or b.name or "")
      return nameA < nameB
    end)

    if #availablePartsList > 0 then
      local canRemove = false
      if currentSlotInfo then
        if not currentSlotInfo.coreSlot and node.chosenPartName and node.chosenPartName ~= "" then
          canRemove = true
        end
      end

      table.insert(result, {
        id = currentPath,
        path = currentPath,
        slotName = slotName or "",
        slotNiceName = slotNiceName,
        chosenPartName = node.chosenPartName or "",
        partNiceName = partNiceName,
        canRemove = canRemove,
        availableParts = availablePartsList,
        compatibleInventoryParts = slotCompatibleVariants,
        parentSlotName = parentSlotName
      })
    end
  end

  if node.children then
    for childSlotName, childNode in pairs(node.children) do
      local childPath = (currentPath == "/" and "" or currentPath) .. childSlotName .. "/"
      local childSlotInfo = nil
      if partInfo and partInfo.slotInfoUi and partInfo.slotInfoUi[childSlotName] then
        childSlotInfo = partInfo.slotInfoUi[childSlotName]
      end
      local childResults = formatPartsTreeForUI(childNode, childSlotName, childSlotInfo, availableParts, slotsNiceName,
        partsNiceName, childPath, slotNiceName, ioCtx, businessId, vehicleData, vehicleModel, ownedPartsByName)
      for _, childResult in ipairs(childResults) do
        table.insert(result, childResult)
      end
    end
  end

  return result
end

local function requestVehiclePartsTree(businessId, vehicleId)
  if not businessId or not vehicleId then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  local isPersonal = isPersonalVehicleId(vehicleId)
  
  if isPersonal then
    local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not spawnedId then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Invalid personal vehicle ID"
      })
      return
    end
    
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedId)
    
    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "No parts tree found for personal vehicle"
      })
      return
    end
    
    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
    local slotsNiceName = {}
    local partsNiceName = {}
    
    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
        end
      end
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end
    
    local vehObj = be:getObjectByID(spawnedId)
    local personalVehicleModel = vehObj and vehObj:getJBeamFilename() or nil
    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName, partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, personalVehicleModel, nil)
    
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName,
      isPersonal = true
    })
    return
  end

  local normalizedVehicleId = tonumber(vehicleId) or vehicleId
  local initialVehicle = career_modules_business_businessInventory.getVehicleById(businessId, normalizedVehicleId)
  if not initialVehicle then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = false,
      error = "Vehicle not found"
    })
    return
  end

  local partsCacheKey = partsTreeCacheKeyForBusinessVehicle(businessId, vehicleId, initialVehicle, false)

  local spawnedVehicleId = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, normalizedVehicleId)
  end

  if spawnedVehicleId then
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(spawnedVehicleId)
    if vehicleData and vehicleData.config and vehicleData.config.partsTree then
      local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
      local slotsNiceName = {}
      local partsNiceName = {}
      
      for partName, partInfo in pairs(availableParts) do
        if partInfo.slotInfoUi then
          for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
            slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
          end
        end
        local desc = partInfo.description
        partsNiceName[partName] = type(desc) == "table" and desc.description or desc
      end
      
      local spawnedVehicleModel = initialVehicle.vehicleConfig and initialVehicle.vehicleConfig.model_key or initialVehicle.model_key
      local ownedPartsLookup = nil
      if career_modules_business_businessPartInventory and spawnedVehicleModel then
        local inventoryParts = career_modules_business_businessPartInventory.getPartsByModel(spawnedVehicleModel, businessId)
        ownedPartsLookup = buildOwnedPartsLookup(inventoryParts, spawnedVehicleModel)
      end
      local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName, partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, spawnedVehicleModel, ownedPartsLookup)
      
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = true,
        businessId = businessId,
        vehicleId = vehicleId,
        partsTree = partsTreeList,
        slotsNiceName = slotsNiceName,
        partsNiceName = partsNiceName
      })
      return
    end
  end

  local previewConfig = nil
  if career_modules_business_businessPartCustomization then
    previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
  end

  local cachedEntry = getCachedPartsTree(businessId, partsCacheKey)
  if cachedEntry and cachedEntry.vehicleId == initialVehicle.vehicleId and not previewConfig then
    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = cachedEntry.partsTree,
      slotsNiceName = cachedEntry.slotsNiceName,
      partsNiceName = cachedEntry.partsNiceName
    })
    return
  end

  core_jobsystem.create(function(job)
    local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, normalizedVehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Vehicle not found"
      })
      return
    end

    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key

    if not modelKey or not configKey then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Invalid vehicle config"
      })
      return
    end

    local configToUse = configKey
    if career_modules_business_businessPartCustomization then
      local previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
      if previewConfig then
        configToUse = previewConfig
      end
    end

    local vehicleObj = core_vehicles.spawnNewVehicle(modelKey, {
      config = configToUse,
      pos = vec3(0, 0, -1000),
      rot = quat(0, 0, 0, 1),
      keepLoaded = true,
      autoEnterVehicle = false
    })

    if not vehicleObj then
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "Failed to spawn vehicle"
      })
      return
    end

    local vehId = vehicleObj:getID()
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)

    if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
      log("W", "businessComputer", "requestVehiclePartsTree: No parts tree for business vehicle")
      vehicleObj:delete()
      guihooks.trigger('businessComputer:onVehiclePartsTree', {
        success = false,
        error = "No parts tree found"
      })
      return
    end

    local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
    local slotsNiceName = {}
    local partsNiceName = {}

    for partName, partInfo in pairs(availableParts) do
      if partInfo.slotInfoUi then
        for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
          slotsNiceName[slotName] = type(slotInfo.description) == "table" and slotInfo.description.description or slotInfo.description
        end
      end
      local desc = partInfo.description
      partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    end

    local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key
    local ownedPartsLookup = nil
    if career_modules_business_businessPartInventory and vehicleModel then
      local inventoryParts = career_modules_business_businessPartInventory.getPartsByModel(vehicleModel, businessId)
      ownedPartsLookup = buildOwnedPartsLookup(inventoryParts, vehicleModel)
    end

    local partsTreeList = formatPartsTreeForUI(vehicleData.config.partsTree, "", nil, availableParts, slotsNiceName,
      partsNiceName, "/", nil, vehicleData.ioCtx, businessId, vehicleData, vehicleModel, ownedPartsLookup)

    vehicleObj:delete()

    local cacheKey = partsTreeCacheKeyForBusinessVehicle(businessId, vehicleId, vehicle, false)
    setCachedPartsTree(businessId, cacheKey, {
      vehicleId = vehicle.vehicleId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName
    })

    guihooks.trigger('businessComputer:onVehiclePartsTree', {
      success = true,
      businessId = businessId,
      vehicleId = vehicleId,
      partsTree = partsTreeList,
      slotsNiceName = slotsNiceName,
      partsNiceName = partsNiceName,
      isPersonal = false
    })
  end)
end

local function requestVehicleTuningData(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.requestVehicleTuningData(businessId, vehicleId)
  end
end

local function getVehicleTuningData(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return nil
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.getVehicleTuningData(businessId, vehicleId)
  end
  return nil
end

local function applyTuningToVehicle(businessId, vehicleId, tuningVars)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.applyTuningToVehicle(businessId, vehicleId, tuningVars)
  end
  return false
end

local activeWheelDataVehicles = {}

local function loadWheelDataExtension(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehicleObj then
    return false
  end

  local vehId = vehicleObj:getID()
  local key = businessId .. "_" .. tostring(vehicleId)

  for oldVehId, entry in pairs(activeWheelDataVehicles) do
    if entry.key == key and oldVehId ~= vehId then
      local oldVehicleObj = be:getObjectByID(oldVehId)
      if oldVehicleObj then
        oldVehicleObj:queueLuaCommand([[
          if extensions.businessWheelData then
            extensions.businessWheelData.disableWheelData()
          end
          extensions.unload("businessWheelData")
        ]])
      end
      activeWheelDataVehicles[oldVehId] = nil
    end
  end

  vehicleObj:queueLuaCommand([[
    if extensions.businessWheelData then
      extensions.businessWheelData.disableWheelData()
    end
    extensions.unload("businessWheelData")
  ]])

  vehicleObj:queueLuaCommand([[
    extensions.load("businessWheelData")
    if extensions.businessWheelData then
      extensions.businessWheelData.enableWheelData()
    end
  ]])

  activeWheelDataVehicles[vehId] = {
    businessId = businessId,
    vehicleId = vehicleId,
    key = key
  }

  return true
end

local function unloadWheelDataExtension(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicleObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehicleObj then
    return false
  end

  local vehId = vehicleObj:getID()
  if not activeWheelDataVehicles[vehId] then
    return false
  end

  vehicleObj:queueLuaCommand([[
    if extensions.businessWheelData then
      extensions.businessWheelData.disableWheelData()
    end
    extensions.unload("businessWheelData")
  ]])

  activeWheelDataVehicles[vehId] = nil

  return true
end

local function onVehicleWheelDataUpdate(vehId, dataStr)
  local vehicleInfo = activeWheelDataVehicles[vehId]
  if not vehicleInfo then
    return
  end

  local data = {}
  if dataStr and dataStr ~= "{}" then
    local success, decoded = pcall(function()
      return jsonDecode(dataStr)
    end)
    if success and decoded then
      data = decoded
    end
  end

  guihooks.trigger('businessComputer:onVehicleWheelData', {
    success = true,
    businessId = vehicleInfo.businessId,
    vehicleId = tonumber(vehicleInfo.vehicleId),
    wheelData = data
  })
end

local function calculateTuningCost(businessId, vehicleId, tuningVars, originalVars)
  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.calculateTuningCost(businessId, vehicleId, tuningVars,
      originalVars)
  end
  return 0
end

local function getTuningShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  if career_modules_business_businessVehicleTuning then
    return
      career_modules_business_businessVehicleTuning.getShoppingCart(businessId, vehicleId, tuningVars, originalVars)
  end
  return {
    items = {},
    total = 0,
    taxes = 0
  }
end

local function addTuningToCart(businessId, vehicleId, currentTuningVars, baselineTuningVars)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return {}
  end

  if career_modules_business_businessVehicleTuning then
    return career_modules_business_businessVehicleTuning.addTuningToCart(businessId, vehicleId, currentTuningVars,
      baselineTuningVars)
  end
  return {}
end

local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  if career_modules_business_businessPartCustomization then
    return
      career_modules_business_businessPartCustomization.getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  end
  return {}
end

local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return currentCart or {}
  end

  if career_modules_business_businessPartCustomization then
    return
      career_modules_business_businessPartCustomization.addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  end
  return currentCart or {}
end

local function applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessVehicleTuning then
    return
      career_modules_business_businessVehicleTuning.applyVehicleTuning(businessId, vehicleId, tuningVars, accountId)
  end
  return false
end

local function initializePreviewVehicle(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicleId)
  end
  return false
end

local function resetVehicleToOriginal(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.resetVehicleToOriginal(businessId, vehicleId)
  end
  return false
end

local function applyPartsToVehicle(businessId, vehicleId, parts)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyPartsToVehicle(businessId, vehicleId, parts)
  end
  return false
end

local function applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    if onComplete then
      onComplete(false)
    end
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete)
  end
  if onComplete then
    onComplete(false)
  end
  return false
end

local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return false
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.installPartOnVehicle(businessId, vehicleId, partName,
      slotPath)
  end
  return false
end

local function invalidateTuningShopJobCompletionIfNeeded(businessId, vehicleId)
  if not businessId or not vehicleId or not career_modules_business_businessInventory then
    return
  end

  local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
  if not jobId then
    return
  end

  if career_modules_business_tuningShop and career_modules_business_tuningShop.invalidateJobCompletionProof then
    career_modules_business_tuningShop.invalidateJobCompletionProof(businessId, jobId)
  end
end

local function purchaseCartItems(businessId, accountId, cartData)
  if not businessId or not accountId or not cartData then
    return false
  end
  if not career_modules_bank then
    return false
  end

  local parts = cartData.parts or {}
  local tuning = cartData.tuning or {}

  local salesTax = 0.07

  local subtotal = 0

  for _, part in ipairs(parts) do
    subtotal = subtotal + (part.price or 0)
  end

  if #tuning > 0 then
    local vehicle = getActiveBusinessVehicle(businessId)
    if vehicle and vehicle.vehicleId then
      local originalVars = vehicle.vars or {}

      local tuningVars = {}
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end

      local tuningCost = calculateTuningCost(businessId, vehicle.vehicleId, tuningVars, originalVars)
      subtotal = subtotal + tuningCost
    else
      local variableCount = 0
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          variableCount = variableCount + 1
        end
      end
      subtotal = subtotal + (50 * variableCount)
    end
  end

  local taxAmount = subtotal * salesTax
  local totalCost = subtotal + taxAmount

  local hasItems = (#parts > 0) or (#tuning > 0)
  if not hasItems then
    return false
  end

  if totalCost > 0 then
    local success = career_modules_bank.payFromAccount({
      money = {
        amount = totalCost,
        canBeNegative = false
      }
    }, accountId, "Shop Purchase", "Purchased parts/tuning")
    if not success then
      log("E", "businessComputer", "purchaseCartItems: Payment failed for amount " .. tostring(totalCost))
      return false
    end

    if career_modules_bank then
      local businessTypeFromAccount, businessIdFromAccount = accountId:match("^business_(.+)_(.+)$")
      if businessTypeFromAccount and businessIdFromAccount then
        local account = career_modules_bank.getBusinessAccount(businessTypeFromAccount, businessIdFromAccount)
        if account then
          local accountData = {
            accountId = account.id,
            balance = account.balance or 0,
            accountType = account.type or "unknown",
            businessType = account.businessType,
            businessId = account.businessId,
            name = account.name or "Account"
          }
          guihooks.trigger('bank:onAccountUpdate', accountData)
        end
      end
    end
  end

  local vehicle = getActiveBusinessVehicle(businessId)
  local deferPurchaseFinalize = false

  local function runPurchaseFinalize()
    if not vehicle or not vehicle.vehicleId then
      return
    end
    local vehicleIdStr = tostring(vehicle.vehicleId)
    local isPersonalVehicle = isPersonalVehicleId(vehicleIdStr)

    M.exitShoppingVehicle(businessId)

    if isPersonalVehicle then
      if career_modules_business_businessPartCustomization then
        career_modules_business_businessPartCustomization.clearPreviewVehicle(businessId)
      end
      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end
      local inventoryId = getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
      if inventoryId then
        career_saveSystem.saveCurrent({inventoryId})
      end
    else
      career_modules_business_businessVehicleModificationUtil.finalizePurchase(businessId, vehicle.vehicleId, nop)
    end
  end

  if vehicle and vehicle.vehicleId then
    local vehicleIdStr = tostring(vehicle.vehicleId)
    local isPersonalVehicle = isPersonalVehicleId(vehicleIdStr)

    if #parts > 0 then
      local function persistPurchasedPreviewConfig(promoteSessionInitial)
        local previewConfig = nil
        if career_modules_business_businessPartCustomization then
          previewConfig = career_modules_business_businessPartCustomization.getPreviewVehicleConfig(businessId)
        end
        if not previewConfig then
          return
        end

        previewConfig = deepcopy(previewConfig)
        vehicle.config = previewConfig
        if vehicle.vars then
          vehicle.config.vars = deepcopy(vehicle.vars)
        end

        local partList = {}
        local function extractParts(tree)
          if not tree then
            return
          end
          if tree.chosenPartName and tree.path then
            partList[tree.path] = tree.chosenPartName
          end
          if tree.children then
            for _, child in pairs(tree.children) do
              extractParts(child)
            end
          end
        end
        extractParts(previewConfig.partsTree or {})
        vehicle.partList = partList

        if isPersonalVehicle then
          local inventoryId = getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
          if inventoryId and career_modules_inventory then
            local inventoryVehicles = career_modules_inventory.getVehicles()
            if inventoryVehicles and inventoryVehicles[inventoryId] then
              inventoryVehicles[inventoryId].config = vehicle.config
              if career_modules_inventory.setVehicleDirty then
                career_modules_inventory.setVehicleDirty(inventoryId)
              end
            end
          end
        elseif career_modules_business_businessInventory then
          career_modules_business_businessInventory.updateVehicle(businessId, vehicle.vehicleId, {
            config = vehicle.config,
            partList = vehicle.partList
          })

          if career_modules_business_businessInventory.getPulledOutVehicles then
            local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
            local targetId = normalizeVehicleIdValue(vehicle.vehicleId)
            for _, pulled in ipairs(pulledVehicles) do
              local pulledId = normalizeVehicleIdValue(pulled.vehicleId)
              if pulledId == targetId then
                pulled.config = vehicle.config
                pulled.partList = vehicle.partList
                break
              end
            end
          elseif career_modules_business_businessInventory.getPulledOutVehicle then
            local pulledOutVehicle = career_modules_business_businessInventory.getPulledOutVehicle(businessId)
            if pulledOutVehicle and pulledOutVehicle.vehicleId == vehicle.vehicleId then
              pulledOutVehicle.config = vehicle.config
              pulledOutVehicle.partList = vehicle.partList
            end
          end
        end

        if promoteSessionInitial and career_modules_business_businessPartCustomization and
          career_modules_business_businessPartCustomization.commitSessionInitialFromPreview then
          career_modules_business_businessPartCustomization.commitSessionInitialFromPreview(businessId, vehicle.vehicleId)
        end
      end

      local inventorySnapshot = nil

      local function snapshotInventoryConfig()
        if isPersonalVehicle or not vehicle then
          return
        end
        inventorySnapshot = {
          config = vehicle.config and deepcopy(vehicle.config) or nil,
          partList = vehicle.partList and deepcopy(vehicle.partList) or nil,
          partConditions = vehicle.partConditions and deepcopy(vehicle.partConditions) or nil
        }
      end

      local function restoreInventorySnapshot()
        if isPersonalVehicle or not inventorySnapshot or not career_modules_business_businessInventory or not vehicle then
          return
        end

        career_modules_business_businessInventory.updateVehicle(businessId, vehicle.vehicleId, {
          config = inventorySnapshot.config,
          partList = inventorySnapshot.partList
        })

        vehicle.config = inventorySnapshot.config and deepcopy(inventorySnapshot.config) or vehicle.config
        vehicle.partList = inventorySnapshot.partList and deepcopy(inventorySnapshot.partList) or vehicle.partList

        if career_modules_business_businessInventory.getPulledOutVehicles then
          local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
          local targetId = normalizeVehicleIdValue(vehicle.vehicleId)
          for _, pulled in ipairs(pulledVehicles) do
            local pulledId = normalizeVehicleIdValue(pulled.vehicleId)
            if pulledId == targetId then
              pulled.config = vehicle.config
              pulled.partList = vehicle.partList
              break
            end
          end
        end

        if career_modules_business_businessPartCustomization and
          career_modules_business_businessPartCustomization.initializePreviewVehicle then
          career_modules_business_businessPartCustomization.initializePreviewVehicle(businessId, vehicle.vehicleId)
        end
      end

      local function commitPurchasedPartsInventory()
        if isPersonalVehicle or not career_modules_business_businessPartInventory then
          return
        end

        local removedParts = {}
        if career_modules_business_businessPartCustomization then
          removedParts = career_modules_business_businessPartCustomization.findRemovedParts(businessId, vehicle.vehicleId) or {}
        end
        if #removedParts == 0 then
          if inventorySnapshot and inventorySnapshot.partList then
            removedParts = findRemovedPartsFromCart(businessId, vehicle.vehicleId, parts, inventorySnapshot.partList,
              inventorySnapshot.partConditions) or {}
          else
            removedParts = findRemovedPartsFromCart(businessId, vehicle.vehicleId, parts) or {}
          end
        end
        if #removedParts > 0 then
          career_modules_business_businessPartInventory.addParts(removedParts, businessId)
        end

        local partsRemovedFromInventory = false
        for _, part in ipairs(parts) do
          if part.fromInventory and part.partId then
            local storedPart = career_modules_business_businessPartInventory.getInventory()[part.partId]
            if storedPart and storedPart.rlsTireState and vehicle then
              local installedPath = tostring(part.slotPath or part.containingSlot or "") ..
                                      tostring(part.partName or storedPart.name or "")
              vehicle.rlsTireStateByPartPath = vehicle.rlsTireStateByPartPath or {}
              vehicle.rlsTireStateByPartPath[installedPath] = deepcopy(storedPart.rlsTireState)
            end
            career_modules_business_businessPartInventory.removePart(part.partId, businessId)
            partsRemovedFromInventory = true
          elseif vehicle and (part.slotPath or part.containingSlot) and part.partName then
            -- A newly purchased part has fresh condition. Remove any same-path
            -- tire state so the provider initializes it from the new part.
            local installedPath = tostring(part.slotPath or part.containingSlot) .. tostring(part.partName)
            if vehicle.rlsTireStateByPartPath then
              vehicle.rlsTireStateByPartPath[installedPath] = nil
            end
          end
        end

        if (#removedParts > 0) or partsRemovedFromInventory then
          requestPartInventory(businessId)
        end
      end

      snapshotInventoryConfig()
      persistPurchasedPreviewConfig(false)

      local partsApplied = applyCartPartsToVehicle(businessId, vehicle.vehicleId, parts, function(ok)
        if ok then
          if not isPersonalVehicle then
            invalidateTuningShopJobCompletionIfNeeded(businessId, vehicle.vehicleId)
          end
          commitPurchasedPartsInventory()
          persistPurchasedPreviewConfig(true)
          if not isPersonalVehicle then
            local module, businessType = resolveBusinessModule(businessId)
            if businessType == "racingTeam" and module and module.notifyBusinessVehiclePartsPurchased then
              module.notifyBusinessVehiclePartsPurchased(businessId, parts)
            end
          end
          if deferPurchaseFinalize then
            deferPurchaseFinalize = false
            runPurchaseFinalize()
          end
        else
          restoreInventorySnapshot()
          if totalCost > 0 and career_modules_bank and career_modules_bank.rewardToAccount then
            career_modules_bank.rewardToAccount({
              money = {
                amount = totalCost
              }
            }, accountId, "Shop Refund", "Part change could not be applied")
          end
          if deferPurchaseFinalize then
            deferPurchaseFinalize = false
          end
        end
      end)
      if partsApplied then
        deferPurchaseFinalize = true
      elseif #tuning == 0 then
        -- Sync reject already ran onComplete(false) (refund). Do not finalize a failed parts-only purchase.
        if vehicle then
          clearCachesForVehicle(businessId, vehicle.vehicleId)
        end
        return false
      end
    elseif not isPersonalVehicle and (#tuning > 0) then
      invalidateTuningShopJobCompletionIfNeeded(businessId, vehicle.vehicleId)
    end

    if #tuning > 0 then
      local tuningVars = {}
      for _, change in ipairs(tuning) do
        if change.type == "variable" and change.varName and change.value ~= nil then
          tuningVars[change.varName] = change.value
        end
      end
      -- Do not assign vehicle.vars = tuningVars here (applyVehicleTuning merges into saved vars).
      applyVehicleTuning(businessId, vehicle.vehicleId, tuningVars, nil)
    end

    if not deferPurchaseFinalize then
      runPurchaseFinalize()
    end
  else
    log("W", "businessComputer", "purchaseCartItems: No active vehicle found for businessId=" .. tostring(businessId))
  end

  if vehicle then
    clearCachesForVehicle(businessId, vehicle.vehicleId)
  end

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  return true
end

local function getBusinessAccountBalance(businessType, businessId)
  if not businessType or not businessId then
    return 0
  end

  if career_modules_bank then
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      return career_modules_bank.getAccountBalance(account.id)
    end
  end

  return 0
end

local function getBusinessXP(businessType, businessId)
  if not businessType or not businessId then
    return 0
  end

  setBusinessContext(businessType, businessId)

  local module = getBusinessModule(businessType)
  if module and module.getBusinessXP then
    return module.getBusinessXP(businessId)
  end

  return 0
end

local function onPowerWeightReceived(requestId, power, weight)
  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.onPowerWeightReceived(requestId, power, weight)
  end
end

local function getVehiclePowerWeight(businessId, vehicleId)
  if shouldPreventVehicleOperation(businessId, vehicleId) then
    return nil
  end

  if career_modules_business_businessPartCustomization then
    return career_modules_business_businessPartCustomization.getVehiclePowerWeight(businessId, vehicleId)
  end
  return nil
end

local function completeJob(businessId, jobId)
  local module, businessType = resolveBusinessModule(businessId)
  if module and module.completeJob then
    local success = module.completeJob(businessId, jobId)
    if success and guihooks then
      local jobsData = M.getJobsOnly(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onJobCompleted', {
        businessType = businessType,
        businessId = businessId,
        jobId = jobId,
        activeJobs = jobsData.activeJobs,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles
      })
    end
    return success
  end
  return false
end

local function setActiveVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local lockInfo = getDamageLockedVehicleInfo(businessId, vehicleId)
  if lockInfo then
    notifyDamageLocked(lockInfo)
    return {
      success = false,
      errorCode = "damageLocked"
    }
  end

  if isPersonalVehicleId(vehicleId) then
    local normalizedVehicleId = normalizeVehicleIdValue(vehicleId)
    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.selectPersonalVehicle then
        local spawnedId = getSpawnedIdFromPersonalVehicleId(vehicleId)
        if spawnedId and businessObj.getInventoryVehiclesInGarageZone then
          local inventoryVehiclesInZone = businessObj.getInventoryVehiclesInGarageZone(businessId) or {}
          for _, invVeh in ipairs(inventoryVehiclesInZone) do
            if invVeh.spawnedId == spawnedId then
              local result = businessObj.selectPersonalVehicle(businessId, invVeh.inventoryId)
              if result and result.success and guihooks then
                local vehiclesData = M.getVehiclesOnly(businessId)
                local matchingVehicleId = nil
                for _, veh in ipairs(vehiclesData.pulledOutVehicles) do
                  if veh.isPersonal and normalizeVehicleIdValue(veh.vehicleId) == normalizedVehicleId then
                    matchingVehicleId = veh.vehicleId
                    break
                  end
                end
                if matchingVehicleId then
                  guihooks.trigger('businessComputer:onVehiclePulledOut', {
                    businessType = businessType,
                    businessId = businessId,
                    vehicleId = matchingVehicleId,
                    vehicles = vehiclesData.vehicles,
                    pulledOutVehicles = vehiclesData.pulledOutVehicles,
                    maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles,
                    isPersonalVehicle = true
                  })
                end
              end
              return result and result.success or false
            end
          end
        end
      end
    end
    return false
  end

  if career_modules_business_businessInventory and career_modules_business_businessInventory.setActiveVehicle then
    local result = career_modules_business_businessInventory.setActiveVehicle(businessId, vehicleId)
    if result and guihooks then
      local _, resolvedBusinessType = resolveBusinessModule(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      local normalizedVehicleId = normalizeVehicleIdValue(vehicleId)
      local matchingVehicleId = normalizedVehicleId
      for _, veh in ipairs(vehiclesData.pulledOutVehicles) do
        if normalizeVehicleIdValue(veh.vehicleId) == normalizedVehicleId then
          matchingVehicleId = veh.vehicleId
          break
        end
      end
      guihooks.trigger('businessComputer:onVehiclePulledOut', {
        businessType = resolvedBusinessType,
        businessId = businessId,
        vehicleId = matchingVehicleId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles,
        maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
      })
    end
    return result
  end

  return false
end

local function getActiveVehicle(businessId)
  return getActiveBusinessVehicle(businessId)
end

local function enterShoppingVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    log("W", "businessComputer", "enterShoppingVehicle: Missing businessId or vehicleId")
    return false
  end
  
  local spawnedVehId = nil
  
  if isPersonalVehicleId(vehicleId) then
    spawnedVehId = getSpawnedIdFromPersonalVehicleId(vehicleId)
  else
    if not career_modules_business_businessInventory then
      log("W", "businessComputer", "enterShoppingVehicle: businessInventory module not available")
      return false
    end
    spawnedVehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  end
  
  if not spawnedVehId or spawnedVehId == 0 then
    return false
  end
  
  local vehObj = be:getObjectByID(spawnedVehId)
  if not vehObj then
    return false
  end
  
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(vehObj)
  else
    be:enterVehicle(0, vehObj)
  end
  return true
end

local function exitShoppingVehicle(businessId)
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    return false
  end
  if businessId then
    local playerVehId = playerVeh:getID()
    local isValidVehicle = false

    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.getActivePersonalVehicle then
        local activePersonal = businessObj.getActivePersonalVehicle(businessId)
        if activePersonal and activePersonal.spawnedVehicleId == playerVehId then
          isValidVehicle = true
        end
      end
    end

    if not isValidVehicle and career_modules_business_businessInventory then
      local pulledOutList = getPulledOutVehiclesList(businessId)
      for _, vehicle in ipairs(pulledOutList) do
        local spawnedId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicle.vehicleId)
        if spawnedId and spawnedId == playerVehId then
          isValidVehicle = true
          break
        end
      end
    end

    if not isValidVehicle then
      return false
    end
  end
  if gameplay_walk then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end

  if businessId then
    local _, businessType = resolveBusinessModule(businessId)
    if businessType then
      local businessObj = career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
      if businessObj and businessObj.clearActivePersonalVehicle then
        businessObj.clearActivePersonalVehicle(businessId)
        log("D", "businessComputer.exitShoppingVehicle", "Cleared personal selection for businessId=" .. tostring(businessId))
      end
    end
  end
  return true
end

local function getJobCompletionStatus(businessId, jobId)
  local module = resolveBusinessModule(businessId)
  if module and module.getJobCompletionStatus then
    return module.getJobCompletionStatus(businessId, jobId)
  end
  return {
    canComplete = false,
    goalTimeMet = false,
    buildChanged = false,
    blockedMessage = nil
  }
end

local function canCompleteJob(businessId, jobId)
  local module = resolveBusinessModule(businessId)
  if module and module.canCompleteJob then
    return module.canCompleteJob(businessId, jobId)
  end
  return false
end

local function getAbandonPenalty(businessId, jobId)
  local module = resolveBusinessModule(businessId)
  if module and module.getAbandonPenalty then
    return module.getAbandonPenalty(businessId, jobId)
  end
  return 0
end

local function getJobsOnly(businessId)
  local module = resolveBusinessModule(businessId)
  if not module then
    return { activeJobs = {}, newJobs = {} }
  end
  local activeJobs = {}
  local newJobs = {}
  if module.getActiveJobs then
    activeJobs = module.getActiveJobs(businessId) or {}
  end
  if module.getNewJobs then
    newJobs = module.getNewJobs(businessId) or {}
  end
  local maxActiveJobs = 2
  if module.getMaxActiveJobs then
    maxActiveJobs = module.getMaxActiveJobs(businessId) or 2
  end
  return {
    businessId = businessId,
    activeJobs = activeJobs,
    newJobs = newJobs,
    maxActiveJobs = maxActiveJobs
  }
end

local function getVehiclesOnly(businessId)
  if not businessId or not career_modules_business_businessInventory then
    return { vehicles = {}, pulledOutVehicles = {} }
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local pulledOutVehiclesRaw = getPulledOutVehiclesList(businessId)

  local module, businessType = resolveBusinessModule(businessId)
  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  local formatterFunc = (businessObj and businessObj.formatVehicleForUIEntry) or (module and module.formatVehicleForUI) or formatVehicleForUI

  local formattedVehicles = {}
  for _, vehicle in ipairs(vehicles) do
    table.insert(formattedVehicles, formatterFunc(vehicle, businessId))
  end
  
  local formattedPulledOut = {}
  for _, vehicle in ipairs(pulledOutVehiclesRaw) do
    local formatted = formatVehicleForUI(vehicle, businessId)
    if formatted then
      local vehicleDamageInfo = isDamageLocked(businessId, vehicle.vehicleId)
      formatted.damage = vehicleDamageInfo.damage
      formatted.damageLocked = vehicleDamageInfo.locked
      if isRacingTeamBusinessId(businessId) then
        formatted.damageLocked = false
      end
      formatted.damageThreshold = vehicleDamageInfo.threshold
      table.insert(formattedPulledOut, formatted)
    end
  end
  
  local maxPulledOut = 1
  if module and module.getMaxPulledOutVehicles then
    maxPulledOut = module.getMaxPulledOutVehicles(businessId) or 1
  end
  if module and module.getFormattedPersonalVehiclesInZone then
    local personalVehicles = module.getFormattedPersonalVehiclesInZone(businessId) or {}
    for _, personalVehicle in ipairs(personalVehicles) do
      table.insert(formattedPulledOut, personalVehicle)
    end
  end
  return {
    businessId = businessId,
    vehicles = formattedVehicles,
    pulledOutVehicles = formattedPulledOut,
    maxPulledOutVehicles = maxPulledOut
  }
end

local function getTechsOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module then
    return { techs = {} }
  end
  local techs = {}
  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.getTechsForBusiness then
    local rawTechs = businessObj.getTechsForBusiness(businessId) or {}
    if businessObj.formatTechForUIEntry then
      for _, tech in ipairs(rawTechs) do
        local formattedTech = businessObj.formatTechForUIEntry(businessId, tech)
        if formattedTech then
          table.insert(techs, formattedTech)
        end
      end
    else
      techs = rawTechs
    end
  elseif module.getTechsForBusiness then
    techs = module.getTechsForBusiness(businessId) or {}
  end
  return {
    businessId = businessId,
    techs = techs
  }
end

local function getStatsOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module then
    return { stats = {} }
  end
  local kits = {}
  local businessObj = businessType and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessObject(businessType)
  if businessObj and businessObj.loadBusinessKits then
    kits = businessObj.loadBusinessKits(businessId) or {}
  end
  local vehicles = {}
  if career_modules_business_businessInventory then
    vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  end
  return {
    businessId = businessId,
    stats = {
      totalVehicles = #vehicles,
      kits = kits
    }
  }
end

local function getManagerDataOnly(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module or not module.getManagerData then
    return nil
  end
  return module.getManagerData(businessId)
end

M.getBusinessComputerUIData = getBusinessComputerUIData
M.acceptJob = acceptJob
M.acceptRacingTeamRaceOffer = acceptRacingTeamRaceOffer
M.acceptRacingTeamRaceOfferAsPlayer = acceptRacingTeamRaceOfferAsPlayer
M.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = acceptRacingTeamRaceOfferAsPlayerAlongsideProxy
M.listLeague1FleetVehiclesForSanctionedOffer = listLeague1FleetVehiclesForSanctionedOffer
M.listLeague2FleetVehiclesForSanctionedOffer = listLeague2FleetVehiclesForSanctionedOffer
M.declineRacingTeamRaceOffer = declineRacingTeamRaceOffer
M.requestProxyDriverRace = requestProxyDriverRace
M.clearProxyDriverRaceRequest = clearProxyDriverRaceRequest
M.getProxyDriverRaceRequest = getProxyDriverRaceRequest
M.acceptLeague2Invite = acceptLeague2Invite
M.declineLeague2Invite = declineLeague2Invite
M.racingTeamMilestoneLeague2Later = racingTeamMilestoneLeague2Later
M.racingTeamMilestoneLeague2Accept = racingTeamMilestoneLeague2Accept
M.racingTeamMilestoneLeague2WelcomeContinue = racingTeamMilestoneLeague2WelcomeContinue
M.racingTeamMilestonePurchaseContinue = racingTeamMilestonePurchaseContinue
M.racingTeamMilestoneCareerFinaleContinue = racingTeamMilestoneCareerFinaleContinue
M.assignRolledProxyRaceToDriver = assignRolledProxyRaceToDriver
M.acceptRacingTeamSponsorOffer = acceptRacingTeamSponsorOffer
M.declineRacingTeamSponsorOffer = declineRacingTeamSponsorOffer
M.dropRacingTeamSponsorActive = dropRacingTeamSponsorActive
M.findProxyDriverRaceRequestForLevel = findProxyDriverRaceRequestForLevel
M.beginRacingTeamProxyRaceFromBusinessComputer = beginRacingTeamProxyRaceFromBusinessComputer
M.enterRacingTeamProxyStagingLoadingEarly = enterRacingTeamProxyStagingLoadingEarly
M.preflightRacingTeamProxySpectateUi = preflightRacingTeamProxySpectateUi
M.refreshRacingTeamProxySpectatorUiMinimal = refreshRacingTeamProxySpectatorUiMinimal
M.simulateRacingTeamProxyRace = simulateRacingTeamProxyRace
M.sendRacingTeamDriverWithManager = sendRacingTeamDriverWithManager
M.setRacingTeamAutoStartBackgroundRaces = setRacingTeamAutoStartBackgroundRaces
M.cancelRacingTeamBackgroundRace = cancelRacingTeamBackgroundRace
M.isProxyScheduledDriverFleetOverpowered = isProxyScheduledDriverFleetOverpowered
M.isArmedProxyFleetOverpoweredForRequest = isArmedProxyFleetOverpoweredForRequest
M.cancelRacingTeamProxySession = cancelRacingTeamProxySession
M.cancelRacingTeamProxyScheduledRace = cancelRacingTeamProxyScheduledRace
M.cancelRacingTeamPlayerRace = cancelRacingTeamPlayerRace
M.startRacingTeamVehicleAssessment = startRacingTeamVehicleAssessment
M.isScheduledRaceReadyForDriver = isScheduledRaceReadyForDriver
M.getRacingTeamCareerSimTime = getRacingTeamCareerSimTime
M.tickRacingTeamScheduledRaceToasts = tickRacingTeamScheduledRaceToasts
M.declineJob = declineJob
M.abandonJob = abandonJob
M.sellVehicle = sellVehicle
M.assignTechToJob = assignTechToJob
M.renameTech = renameTech
M.completeJob = completeJob
M.canCompleteJob = canCompleteJob
M.getJobCompletionStatus = getJobCompletionStatus
M.getAbandonPenalty = getAbandonPenalty
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
M.repairBusinessVehicleDamage = repairBusinessVehicleDamage
M.startVehiclePainting = startVehiclePainting
M.startVehicleRefueling = startVehicleRefueling
M.getBusinessVehicleRepairQuote = function(businessId, vehicleId)
  local cost, damage, thr = computeBusinessVehicleRepairCost(businessId, vehicleId)
  if cost == nil then
    return nil
  end
  return { cost = cost, damage = damage, threshold = thr }
end
M.setActiveVehicle = setActiveVehicle
M.getActiveVehicle = getActiveVehicle
M.getActiveJobs = getActiveJobs
M.getNewJobs = getNewJobs
M.requestVehiclePartsTree = requestVehiclePartsTree
M.getVehicleTuningData = getVehicleTuningData
M.requestVehicleTuningData = requestVehicleTuningData
M.applyVehicleTuning = applyVehicleTuning
M.loadWheelDataExtension = loadWheelDataExtension
M.unloadWheelDataExtension = unloadWheelDataExtension
M.clearVehicleDataCaches = clearVehicleDataCaches
M.clearBusinessCachesForVehicle = clearCachesForVehicle
M.getBusinessTypeForId = resolveBusinessTypeOnly
M.getBusinessAccountBalance = getBusinessAccountBalance
M.getBusinessXP = getBusinessXP
M.purchaseCartItems = purchaseCartItems
M.installPartOnVehicle = installPartOnVehicle
M.initializePreviewVehicle = initializePreviewVehicle
M.applyTuningToVehicle = applyTuningToVehicle
M.calculateTuningCost = calculateTuningCost
M.getTuningShoppingCart = getTuningShoppingCart
M.addTuningToCart = addTuningToCart
M.getVehiclePowerWeight = getVehiclePowerWeight
M.resetVehicleToOriginal = resetVehicleToOriginal
M.applyPartsToVehicle = applyPartsToVehicle
M.applyCartPartsToVehicle = applyCartPartsToVehicle
M.getAllRequiredParts = getAllRequiredParts
M.addPartToCart = addPartToCart
M.onVehicleWheelDataUpdate = onVehicleWheelDataUpdate
M.onPowerWeightReceived = onPowerWeightReceived
M.requestPartInventory = requestPartInventory
M.requestFinancesData = function(businessType, businessId)
  if not businessType or not businessId then
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Missing parameters"
      })
    end
    return
  end

  local module = getBusinessModule(businessType)
  if module and module.requestFinancesData then
    module.requestFinancesData(businessId)
  else
    if guihooks then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Finances not available for this business type",
        businessType = businessType,
        businessId = businessId
      })
    end
  end
end
M.requestSimulationTime = function()
  local ts = career_modules_business_tuningShop
  if ts and ts.requestSimulationTime then
    ts.requestSimulationTime()
    return
  end
  if guihooks then
    guihooks.trigger('businessComputer:onSimulationTime', {
      success = true,
      simulationTime = os.time()
    })
  end
end
M.sellPart = sellPart
M.sellAllParts = sellAllParts
M.sellPartsByVehicle = sellPartsByVehicle
M.getBrandSelection = getBrandSelection
M.setBrandSelection = setBrandSelection
M.getRaceSelection = getRaceSelection
M.setRaceSelection = setRaceSelection
M.getAvailableBrands = getAvailableBrands
M.getAvailableRaceTypes = getAvailableRaceTypes
M.requestAvailableBrands = requestAvailableBrands
M.requestAvailableRaceTypes = requestAvailableRaceTypes
M.getPartSupplierDiscountMultiplier = getPartSupplierDiscountMultiplier
M.getJobsOnly = getJobsOnly
M.getVehiclesOnly = getVehiclesOnly
M.getTechsOnly = getTechsOnly
M.getStatsOnly = getStatsOnly
M.getManagerDataOnly = getManagerDataOnly

M.setBusinessName = function(businessType, businessId, name)
  if not career_modules_business_businessManager or not career_modules_business_businessManager.setBusinessName then
    if guihooks then
      guihooks.trigger('businessComputer:onBusinessNameUpdated', { success = false, error = "setBusinessName not available" })
    end
    return
  end
  local ok = career_modules_business_businessManager.setBusinessName(businessType, businessId, name)
  if guihooks then
    guihooks.trigger('businessComputer:onBusinessNameUpdated', {
      success = ok,
      businessType = businessType,
      businessId = businessId,
      businessName = ok and name or nil
    })
  end
end

M.createKit = function(businessId, jobId, kitName)
  local module = resolveBusinessModule(businessId)
  if module and module.createKit then
    return module.createKit(businessId, jobId, kitName)
  end
  return false
end

M.deleteKit = function(businessId, kitId)
  local module = resolveBusinessModule(businessId)
  if module and module.deleteKit then
    return module.deleteKit(businessId, kitId)
  end
  return false
end

M.applyKit = function(businessId, vehicleId, kitId)
  local module = resolveBusinessModule(businessId)
  if module and module.applyKit then
    return module.applyKit(businessId, vehicleId, kitId)
  end
  return {
    success = false,
    error = "Module not found"
  }
end

local function onCareerModulesActivated()
  if career_modules_business_businessManager then
    local purchased = career_modules_business_businessManager.getAllPurchasedBusinesses()
    for businessType, businesses in pairs(purchased) do
      for businessId, _ in pairs(businesses) do
        setBusinessContext(businessType, businessId)
      end
    end
  end
end

local function onExtensionLoaded()
  businessContexts = {}
  return true
end

local function getTechData(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.getTechData then
    return module.getTechData(businessId)
  end
  return nil
end

local function getManagerData(businessId)
  local module, businessType = resolveBusinessModule(businessId)
  if not module or not businessType then
    return nil
  end

  setBusinessContext(businessType, businessId)

  if not module.getManagerData then
    return nil
  end

  local ok, result = pcall(module.getManagerData, businessId)
  if not ok then
    log('E', 'businessComputer',
      'Error getting manager data for businessId ' .. tostring(businessId) .. ': ' .. tostring(result))
    return nil
  end

  return result
end

local function selectPersonalVehicle(businessId, inventoryId)
  local module = resolveBusinessModule(businessId)
  if module and module.selectPersonalVehicle then
    return module.selectPersonalVehicle(businessId, inventoryId)
  end
  return { success = false, errorCode = "notSupported", message = "Personal vehicles not supported for this business type" }
end

local function isPersonalUseUnlocked(businessId)
  local module = resolveBusinessModule(businessId)
  if module and module.isPersonalUseUnlocked then
    return module.isPersonalUseUnlocked(businessId)
  end
  return false
end

M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated
M.setBusinessContext = setBusinessContext
M.clearBusinessContext = clearBusinessContext
M.getTechData = getTechData
M.getManagerData = getManagerData
M.enterShoppingVehicle = enterShoppingVehicle
M.exitShoppingVehicle = exitShoppingVehicle
M.selectPersonalVehicle = selectPersonalVehicle
M.isPersonalUseUnlocked = isPersonalUseUnlocked
M.getPersonalVehicleData = getPersonalVehicleData
M.getInventoryIdFromPersonalVehicleId = getInventoryIdFromPersonalVehicleId

local function getRtFleetOpts(businessId)
  local rows = {}
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessVehicles then
    return rows
  end
  for _, v in ipairs(inv.getBusinessVehicles(businessId) or {}) do
    local vc = v.vehicleConfig or {}
    table.insert(rows, {
      vehicleId = v.vehicleId,
      label = tostring(vc.model_key or "?") .. " / " .. tostring(vc.key or "?")
    })
  end
  return rows
end
M.getRtFleetOpts = getRtFleetOpts

local function racingTeamDevConsole()
  return require("ge/extensions/career/modules/business/racingTeamDevConsole")
end

M.devConsoleRacingTeamClearCooldowns = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.clearCooldowns then
    return dc.clearCooldowns(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamRefreshRaceOffers = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.refreshRaceOffers then
    return dc.refreshRaceOffers(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamForceLeagueInvite = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.forceLeagueInvite then
    return dc.forceLeagueInvite(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamCompleteCurrentGoal = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.completeCurrentGoal then
    return dc.completeCurrentGoal(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamCompleteAllLeagueGoals = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.completeAllLeagueGoals then
    return dc.completeAllLeagueGoals(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamResetCurrentLeagueGoals = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.resetCurrentLeagueGoals then
    return dc.resetCurrentLeagueGoals(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamMaxAllSkills = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.maxAllSkills then
    return dc.maxAllSkills(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamGetDevLog = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.getDevLog then
    return dc.getDevLog(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamClearDevLog = function()
  local dc = racingTeamDevConsole()
  if dc and dc.clearDevLog then
    return dc.clearDevLog()
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamResetBusiness = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.resetBusiness then
    return dc.resetBusiness(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamResetBusinessSoft = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.resetBusinessSoft then
    return dc.resetBusinessSoft(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamResetBusinessHard = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.resetBusinessHard then
    return dc.resetBusinessHard(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamInjectXp = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.injectXp then
    return dc.injectXp(businessId)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamInjectMoney = function(businessId)
  local dc = racingTeamDevConsole()
  if dc and dc.injectMoney then
    return dc.injectMoney(businessId)
  end
  return { ok = false, error = "unavailable" }
end

return M
