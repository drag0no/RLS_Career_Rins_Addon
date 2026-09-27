local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'gameplay_sites_sitesManager',
  'core_vehicles',
  'core_vehicleBridge',
  'freeroam_facilities',
  'career_modules_business_businessPartConditions',
}

local businessVehicles = {}
local pulledOutVehicles = {}
local spawnedBusinessVehicles = {}
local vehicleIdCounters = {}
local pendingConfigCallbacks = {}

local putAwayVehicle

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function getSpawnedVehicleId(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  if spawnedBusinessVehicles[businessId] and spawnedBusinessVehicles[businessId][vehicleId] then
    return spawnedBusinessVehicles[businessId][vehicleId]
  end
  return nil
end

local function clearCachesForStoredVehicle(businessId, vehicle)
  if not vehicle or vehicle.vehicleId == nil then
    return
  end
  if career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessCachesForVehicle then
    career_modules_business_businessComputer.clearBusinessCachesForVehicle(businessId, vehicle.vehicleId)
  end
end

local function getBusinessVehiclesPath(businessId)
  if not career_career.isActive() then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/vehicles.json"
end

local function loadBusinessVehicles(businessId)
  if not businessId then
    return {}
  end

  businessId = normalizeBusinessId(businessId)
  if businessVehicles[businessId] then
    return businessVehicles[businessId]
  end

  local filePath = getBusinessVehiclesPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  businessVehicles[businessId] = data.vehicles or {}

  for _, vehicle in ipairs(businessVehicles[businessId]) do
    if vehicle.vehicleId then
      vehicle.vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end

  local maxId = 0
  for _, vehicle in ipairs(businessVehicles[businessId]) do
    local vehId = tonumber(vehicle.vehicleId)
    if vehId and vehId > maxId then
      maxId = vehId
    end
  end
  vehicleIdCounters[businessId] = math.max((vehicleIdCounters[businessId] or 1), maxId + 1)

  return businessVehicles[businessId]
end

local function getNextVehicleId(businessId)
  businessId = normalizeBusinessId(businessId)
  vehicleIdCounters[businessId] = vehicleIdCounters[businessId] or 1
  local nextId = vehicleIdCounters[businessId]
  vehicleIdCounters[businessId] = nextId + 1
  return nextId
end

local function saveBusinessVehicles(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not businessVehicles[businessId] or not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/businesses/" .. businessId .. "/vehicles.json"

  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  local data = {
    vehicles = businessVehicles[businessId]
  }
  jsonWriteFile(filePath, data, true)
end

local function getBusinessVehicles(businessId)
  return loadBusinessVehicles(businessId)
end

local function storeVehicle(businessId, vehicleData)
  if not businessId or not vehicleData then
    return false
  end

  businessId = normalizeBusinessId(businessId)
  local vehicles = loadBusinessVehicles(businessId)

  local vehicleId = vehicleData.vehicleId
  if vehicleId == nil then
    vehicleId = getNextVehicleId(businessId)
  end
  vehicleId = tonumber(vehicleId) or vehicleId
  if type(vehicleId) == "number" then
    local nextId = vehicleId + 1
    vehicleIdCounters[businessId] = math.max(vehicleIdCounters[businessId] or nextId, nextId)
  end
  vehicleData.vehicleId = vehicleId
  vehicleData.storedTime = os.time()

  table.insert(vehicles, vehicleData)
  businessVehicles[businessId] = vehicles

  return true, vehicleId
end

local function removeVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)

  for i, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      table.remove(vehicles, i)
      businessVehicles[businessId] = vehicles
      return true
    end
  end

  return false
end

local function getVehicleById(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)

  for _, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      return vehicle
    end
  end

  return nil
end

local function normalizeVehicleId(vehicleId)
  if vehicleId == nil then
    return nil
  end
  return tonumber(vehicleId) or vehicleId
end

local function ensurePulledOutState(businessId)
  businessId = normalizeBusinessId(businessId)
  if not pulledOutVehicles[businessId] then
    pulledOutVehicles[businessId] = {
      vehicles = {},
      activeVehicleId = nil,
      spotAssignments = {}
    }
  end
  return pulledOutVehicles[businessId]
end

local function findPulledOutVehicleIndex(state, vehicleId)
  if not state or not state.vehicles then
    return nil
  end
  for index, vehicle in ipairs(state.vehicles) do
    if normalizeVehicleId(vehicle.vehicleId) == vehicleId then
      return index
    end
  end
  return nil
end

local function getPulledOutVehicles(businessId)
  businessId = normalizeBusinessId(businessId)
  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return {}
  end
  return state.vehicles
end

local function getActiveVehicle(businessId)
  businessId = normalizeBusinessId(businessId)
  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return nil
  end
  if state.activeVehicleId then
    local index = findPulledOutVehicleIndex(state, state.activeVehicleId)
    if index then
      return state.vehicles[index]
    end
  end
  return state.vehicles[1]
end

local function setActiveVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end
  businessId = normalizeBusinessId(businessId)
  local state = pulledOutVehicles[businessId]
  if not state then
    return false
  end
  local normalizedId = normalizeVehicleId(vehicleId)
  local index = findPulledOutVehicleIndex(state, normalizedId)
  if not index then
    return false
  end
  state.activeVehicleId = normalizedId
  return true
end

local function getPulledOutVehicle(businessId)
  return getActiveVehicle(businessId)
end

local function getBusinessGarage(businessType, businessId)
  local business = freeroam_facilities.getFacility(businessType, businessId)
  if not business then
    return nil
  end

  if not business.businessGarageId then
    return nil
  end

  local businessGarages = freeroam_facilities.getFacilitiesByType("businessGarage")
  if not businessGarages then
    return nil
  end

  for _, garage in ipairs(businessGarages) do
    if garage.id == business.businessGarageId then
      return garage
    end
  end

  return nil
end

local function getBusinessGarageParkingSpots(businessType, businessId)
  local garage = getBusinessGarage(businessType, businessId)
  if not garage then
    return {}
  end

  if not garage.sitesFile then
    return {}
  end

  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  if not sites or not sites.parkingSpots then
    return {}
  end

  local spots = {}
  for _, spotName in ipairs(garage.parkingSpotNames or {}) do
    local spot = sites.parkingSpots.byName[spotName]
    if spot and not spot.missing then
      table.insert(spots, spot)
    end
  end

  return spots
end

local function getBusinessGaragePosRot(businessType, businessId, veh, spotIndex)
  veh = veh or getPlayerVehicle(0)
  local garage = getBusinessGarage(businessType, businessId)
  if not garage or not freeroam_facilities or not freeroam_facilities.getParkingSpotsForFacility then
    return nil, nil
  end

  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(garage)
  if not parkingSpots or #parkingSpots == 0 then
    return nil, nil
  end

  if spotIndex and parkingSpots[spotIndex] then
    local spot = parkingSpots[spotIndex]
    return spot.pos, spot.rot
  end

  if not veh then
    local spot = parkingSpots[1]
    if spot then
      return spot.pos, spot.rot
    end
    return nil, nil
  end

  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end

  return parkingSpots[1].pos, parkingSpots[1].rot
end

local function getVisualValueFromMileage(mileage)
  if not mileage then
    return nil
  end
  return career_modules_vehicleShopping.getVisualValueFromMileage(mileage)
end

local function requestAndStorePartConditions(vehicle, vehObj)
  if not vehObj or not vehicle then
    return
  end
  core_vehicleBridge.requestValue(vehObj, function(res)
    if not res or not res.result then
      return
    end
    vehicle.partConditions = deepcopy(res.result)
  end, 'getPartConditions')
end

local function primeFleetRepairSnapshots(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return 0
  end
  local vehicles = getBusinessVehicles(businessId) or {}
  local primed = 0
  for _, vehicle in ipairs(vehicles) do
    local vehicleId = tonumber(vehicle and vehicle.vehicleId) or (vehicle and vehicle.vehicleId)
    if vehicleId then
      local sid = getSpawnedVehicleId(businessId, vehicleId)
      local vehObj = sid and getObjectByID(sid)
      if vehObj then
        requestAndStorePartConditions(vehicle, vehObj)
        primed = primed + 1
      end
    end
  end
  return primed
end

local function getPartConditionApplyOpts(vehicle)
  local partsTree = vehicle and vehicle.config and vehicle.config.partsTree
  if not partsTree or not career_modules_business_businessPartConditions then
    return nil
  end
  return {
    validPartKeys = career_modules_business_businessPartConditions.collectPartConditionKeysFromPartsTree(partsTree),
  }
end

local function applyPartConditionsForVehicle(vehicle, vehObj)
  if not vehObj or not vehicle then
    return
  end

  if vehicle.partConditions then
    career_modules_business_businessPartConditions.applyInitPartConditions(
      vehObj, vehicle.partConditions, 0, 1, 1, getPartConditionApplyOpts(vehicle))
    return
  end

  local mileage = tonumber(vehicle.mileage or 0)
  if mileage > 0 then
    local visualValue = getVisualValueFromMileage(mileage) or 1
    vehObj:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, visualValue))
    requestAndStorePartConditions(vehicle, vehObj)
    return
  end

  requestAndStorePartConditions(vehicle, vehObj)
end

function M.getSavedPartConditionFlags(vehicle)
  local hasSnapshot = false
  local looksDamaged = false
  local pc = vehicle and vehicle.partConditions
  if type(pc) ~= "table" then
    return false, false
  end
  for _ in pairs(pc) do
    hasSnapshot = true
    break
  end
  if not hasSnapshot then
    return false, false
  end
  for _, cond in pairs(pc) do
    if type(cond) == "table" then
      local iv = tonumber(cond.integrityValue)
      if iv ~= nil and iv < 0.999 then
        looksDamaged = true
        break
      end
      local vs = cond.visualState
      if type(vs) == "table" and type(vs.jbeam) == "table" and vs.jbeam.needsReplacement then
        looksDamaged = true
        break
      end
    end
  end
  return hasSnapshot, looksDamaged
end

local FLEET_INSURANCE_DEDUCTIBLE = 750

function M.getFleetInsuranceRepairQuote(businessId, vehicleId)
  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then
    return nil
  end
  local _, looksDamaged = M.getSavedPartConditionFlags(vehicle)
  return {
    needsRepair = looksDamaged == true,
    deductible = FLEET_INSURANCE_DEDUCTIBLE,
  }
end

local function repairSpawnedBusinessVehicle(businessId, vehicleId)
  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return false
  end
  local oldSid = getSpawnedVehicleId(businessId, vehicleId)
  local oldVehObj = oldSid and getObjectByID(oldSid)
  if not oldVehObj then
    return false
  end
  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key
  if not modelKey or not configKey then
    return false
  end
  local vehicleData = {
    config = configKey,
    autoEnterVehicle = false,
    keepLoaded = true,
    keepOtherVehRotation = true,
  }
  if vehicle.config and vehicle.config.partsTree then
    vehicleData.config = deepcopy(vehicle.config)
    if vehicle.vars then
      vehicleData.config.vars = deepcopy(vehicle.vars)
    end
  elseif vehicle.vars then
    vehicleData.config = {
      key = configKey,
      vars = deepcopy(vehicle.vars),
    }
  end
  local newVehObj = core_vehicles.replaceVehicle(modelKey, vehicleData, oldVehObj)
  if not newVehObj then
    return false
  end
  if not spawnedBusinessVehicles[businessId] then
    spawnedBusinessVehicles[businessId] = {}
  end
  spawnedBusinessVehicles[businessId][vehicleId] = newVehObj:getID()
  newVehObj:queueLuaCommand("extensions.load('individualRepair')")
  core_vehicleBridge.requestValue(newVehObj, function()
    core_vehicleBridge.executeAction(newVehObj, 'initPartConditions', {}, 0, 1, 1)
    requestAndStorePartConditions(vehicle, newVehObj)
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveBusinessVehicles(businessId, savePath)
    end
  end, 'ping')
  local playerVid = be:getPlayerVehicleID(0)
  if playerVid == oldSid then
    be:enterVehicle(0, newVehObj)
  end
  return true
end

function M.repairFleetVehicleInsuranceStyle(businessId, vehicleId, businessType)
  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local quote = M.getFleetInsuranceRepairQuote(businessId, vehicleId)
  if not quote or not quote.needsRepair then
    return { success = false, errorCode = "nothingToRepair" }
  end
  if not businessType then
    return { success = false, errorCode = "unknownBusiness" }
  end
  local cost = math.max(0, math.floor(tonumber(quote.deductible) or FLEET_INSURANCE_DEDUCTIBLE))
  if cost > 0 then
    if not career_modules_bank then
      return { success = false, errorCode = "noBank" }
    end
    local account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if not account then
      return { success = false, errorCode = "noAccount" }
    end
    local paid = career_modules_bank.payFromAccount({
      money = { amount = cost, canBeNegative = false },
    }, account.id, "Fleet insurance", "Vehicle repair deductible")
    if not paid then
      return { success = false, errorCode = "noFunds", cost = cost }
    end
  end
  local sid = getSpawnedVehicleId(businessId, vehicleId)
  if sid then
    local ok = repairSpawnedBusinessVehicle(businessId, vehicleId)
    if not ok then
      if cost > 0 and career_modules_bank then
        local account = career_modules_bank.getBusinessAccount(businessType, businessId)
        if account then
          career_modules_bank.rewardToAccount({ money = { amount = cost } }, account.id, "Refund", "Repair failed")
        end
      end
      return { success = false, errorCode = "repairFailed", cost = cost }
    end
  else
    local v = getVehicleById(businessId, vehicleId)
    if not v then
      if cost > 0 and career_modules_bank then
        local account = career_modules_bank.getBusinessAccount(businessType, businessId)
        if account then
          career_modules_bank.rewardToAccount({ money = { amount = cost } }, account.id, "Refund", "Repair failed")
        end
      end
      return { success = false, errorCode = "noVehicle" }
    end
    v.partConditions = nil
    clearCachesForStoredVehicle(businessId, v)
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveBusinessVehicles(businessId, savePath)
    end
  end
  if ui_message then
    ui_message(string.format("Vehicle repaired. Insurance deductible: $%d.", cost), 5, "Business Computer", "info")
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return { success = true, cost = cost }
end

local function spawnBusinessVehicle(businessId, vehicleId)
  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId

  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then
    return nil
  end

  local existingSpawnId = getSpawnedVehicleId(businessId, vehicleId)
  if existingSpawnId then
    local existingObj = getObjectByID(existingSpawnId)
    if existingObj then
      return existingObj
    end
  end

  if not vehicle.vehicleConfig then
    return nil
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local configKey = vehicle.vehicleConfig.key or vehicle.config_key

  if not modelKey or not configKey then
    return nil
  end

  local vehicleData = {
    config = configKey,
    autoEnterVehicle = false,
    keepLoaded = true
  }

  local usingCustomConfig = false
  if vehicle.config and vehicle.config.partsTree then
    vehicleData.config = deepcopy(vehicle.config)
    if vehicle.vars then
      vehicleData.config.vars = deepcopy(vehicle.vars)
    end
    usingCustomConfig = true
  elseif vehicle.vars then
    vehicleData.config = {
      key = configKey,
      vars = deepcopy(vehicle.vars)
    }
  end

  local vehObj = core_vehicles.spawnNewVehicle(modelKey, vehicleData)

  if not vehObj then
    return nil
  end

  vehObj:queueLuaCommand("extensions.load('individualRepair')")

  if core_vehicleBridge and core_vehicleBridge.requestValue then
    core_vehicleBridge.requestValue(vehObj, function()
      applyPartConditionsForVehicle(vehicle, vehObj)
    end, 'ping')
  else
    applyPartConditionsForVehicle(vehicle, vehObj)
  end

  if not spawnedBusinessVehicles[businessId] then
    spawnedBusinessVehicles[businessId] = {}
  end
  spawnedBusinessVehicles[businessId][vehicleId] = vehObj:getID()

  if career_modules_tireSystem and career_modules_tireSystem.registerBusinessVehicle then
    career_modules_tireSystem.registerBusinessVehicle(businessId, vehicleId, vehObj:getID())
  end

  return vehObj
end

local function getGroundHeight(pos)
  local rayStart = vec3(pos.x, pos.y, pos.z + 5)
  local rayDir = vec3(0, 0, -1)
  local rayDist = 15

  local hitDist = castRayStatic(rayStart, rayDir, rayDist)
  local heightOffset = -0.5

  if hitDist < rayDist then
    local groundZ = rayStart.z - hitDist
    return groundZ + heightOffset
  end

  return pos.z + heightOffset
end

local function isSpotBlocked(veh, pos, rot)
  if not veh or not pos or not rot then
    return true
  end

  local vehId = veh:getID()
  local adjustedRot = rot

  local bb = veh:getSpawnWorldOOBB()
  if not bb then
    return false
  end

  local halfExtents = bb:getHalfExtents()
  local groundZ = getGroundHeight(pos)
  
  local vehicleCenterPos = vec3(pos.x, pos.y, groundZ + halfExtents.z)

  local axis0, axis1, axis2 = adjustedRot * vec3(1,0,0), adjustedRot * vec3(0,1,0), adjustedRot * vec3(0,0,1)

  for otherId, otherVeh in activeVehiclesIterator() do
    if otherId ~= vehId then
      local otherBB = otherVeh:getWorldBox()
      if otherBB then
        local otherCenter = otherBB:getCenter()
        local otherHalfExtents = otherBB:getExtents() / 2
        if overlapsOBB_OBB(vehicleCenterPos, axis0 * halfExtents.x, axis1 * halfExtents.y, axis2 * halfExtents.z,
                           otherCenter, vec3(1,0,0) * otherHalfExtents.x, vec3(0,1,0) * otherHalfExtents.y, vec3(0,0,1) * otherHalfExtents.z) then
          return true
        end
      end
    end
  end

  return false
end

local function getBoundingBoxOffsets(veh)
  local bb = veh:getSpawnWorldOOBB()
  if not bb then
    return vec3(0, 0, 0), 0
  end

  local currentPos = veh:getPosition()
  local currentRot = quat(veh:getRotation())
  local bbCenter = bb:getCenter()
  local halfExtents = bb:getHalfExtents()
  
  local worldOffset = bbCenter - currentPos
  local localOffset = currentRot:inversed() * worldOffset

  local xyOffset = vec3(localOffset.x, localOffset.y, 0)
  local bottomZOffsetRelative = halfExtents.z - localOffset.z

  return xyOffset, bottomZOffsetRelative
end

local function computeGroundedRefNodePose(veh, pos, rot, applyHeadingFlip)
  if not veh or not pos or not rot then
    return nil, nil
  end
  local adjustedRot = (applyHeadingFlip == true) and (quat(0, 0, 1, 0) * rot) or rot
  local groundZ = getGroundHeight(pos)
  local xyOffset, bottomZOffsetRelative = getBoundingBoxOffsets(veh)
  local rotatedXYOffset = adjustedRot * xyOffset
  local targetXYCenter = vec3(pos.x, pos.y, 0)
  local targetBottomZ = groundZ
  local refNodeXY = targetXYCenter - vec3(rotatedXYOffset.x, rotatedXYOffset.y, 0)
  local refNodeZ = targetBottomZ + bottomZOffsetRelative
  local refNodePos = vec3(refNodeXY.x, refNodeXY.y, refNodeZ)
  return refNodePos, adjustedRot
end

local function teleportVehicleExact(veh, pos, rot, resetVeh, applyHeadingFlip)
  local refNodePos, adjustedRot = computeGroundedRefNodePose(veh, pos, rot, applyHeadingFlip)
  if not refNodePos then
    return false
  end

  if resetVeh then
    veh:setPosRot(refNodePos.x, refNodePos.y, refNodePos.z, adjustedRot.x, adjustedRot.y, adjustedRot.z, adjustedRot.w)
    veh:resetBrokenFlexMesh()
  else
    veh:setClusterPosRelRot(veh:getRefNodeId(), refNodePos.x, refNodePos.y, refNodePos.z, adjustedRot.x, adjustedRot.y, adjustedRot.z, adjustedRot.w)
    veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
  end

  return true
end

local function teleportToBusinessGarage(businessType, businessId, veh, resetVeh, spotIndex)
  resetVeh = resetVeh or false
  if not veh then
    return false
  end

  local garage = getBusinessGarage(businessType, businessId)
  if not garage or not freeroam_facilities or not freeroam_facilities.getParkingSpotsForFacility then
    return false
  end

  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(garage)
  if not parkingSpots or #parkingSpots == 0 then
    return false
  end

  local usedIdxSet = {}
  local state = pulledOutVehicles[normalizeBusinessId(businessId)]
  if state and type(state.spotAssignments) == "table" then
    for _, idx in pairs(state.spotAssignments) do
      local n = tonumber(idx)
      if n then usedIdxSet[n] = true end
    end
  end

  local filteredSpots = {}
  local filteredToOriginalIdx = {}
  for idx, sp in ipairs(parkingSpots) do
    if not usedIdxSet[idx] then
      table.insert(filteredSpots, sp)
      filteredToOriginalIdx[#filteredSpots] = idx
    end
  end

  local parkingSpot
  if #filteredSpots > 0 then
    parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), filteredSpots)
  end
  if not parkingSpot then
    parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  end
  if not parkingSpot then
    parkingSpot = parkingSpots[1]
  end
  if not parkingSpot or not parkingSpot.pos or not parkingSpot.rot then
    return false
  end

  local adjustedRot = quat(0, 0, 1, 0) * parkingSpot.rot
  local p = parkingSpot.pos

  if businessType == "racingTeam" then
    veh:setPosRot(p.x, p.y, p.z, adjustedRot.x, adjustedRot.y, adjustedRot.z, adjustedRot.w)
  else
    local refNodePos, groundedRot = computeGroundedRefNodePose(veh, parkingSpot.pos, parkingSpot.rot, true)
    if not refNodePos then
      return false
    end
    veh:setPosRot(refNodePos.x, refNodePos.y, refNodePos.z, groundedRot.x, groundedRot.y, groundedRot.z, groundedRot.w)
  end
  if resetVeh then
    veh:resetBrokenFlexMesh()
  else
    veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
  end
  if core_camera and core_camera.resetCamera then
    core_camera.resetCamera(0)
  end

  local chosenIdx = 1
  for idx, sp in ipairs(parkingSpots) do
    if sp == parkingSpot then
      chosenIdx = idx
      break
    end
  end

  return true, chosenIdx
end

local function removeBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return
  end

  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  if not spawnedBusinessVehicles[businessId] or not spawnedBusinessVehicles[businessId][vehicleId] then
    return
  end

  local vehId = spawnedBusinessVehicles[businessId][vehicleId]
  local vehObj = getObjectByID(vehId)
  if vehObj then
    if career_modules_tireSystem and career_modules_tireSystem.unregisterBusinessVehicle then
      career_modules_tireSystem.unregisterBusinessVehicle(businessId, vehicleId, vehId)
    end
    local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
    if playerVehId and playerVehId == vehId and gameplay_walk and gameplay_walk.setWalkingMode then
      gameplay_walk.setWalkingMode(true, nil, nil, true)
    end
    vehObj:delete()
  end

  spawnedBusinessVehicles[businessId][vehicleId] = nil
end

local function clearBusinessInventory(businessId)
  if not businessId then
    return false
  end

  businessId = normalizeBusinessId(businessId)
  local vehicles = loadBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    clearCachesForStoredVehicle(businessId, vehicle)
    if vehicle and vehicle.vehicleId ~= nil then
      removeBusinessVehicleObject(businessId, vehicle.vehicleId)
    end
  end

  if spawnedBusinessVehicles[businessId] then
    local spawnedVehicleIds = {}
    for vehicleId, _ in pairs(spawnedBusinessVehicles[businessId]) do
      spawnedVehicleIds[#spawnedVehicleIds + 1] = vehicleId
    end
    for _, vehicleId in ipairs(spawnedVehicleIds) do
      removeBusinessVehicleObject(businessId, vehicleId)
    end
  end

  businessVehicles[businessId] = {}
  pulledOutVehicles[businessId] = nil
  spawnedBusinessVehicles[businessId] = nil
  vehicleIdCounters[businessId] = 1

  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveBusinessVehicles(businessId, savePath)
  end
  return true
end

local function registerFleetVehicleDeliveredDriveIn(businessType, businessId, fleetVehicleId, spawnedGameId)
  if not businessType or not businessId or not fleetVehicleId or not spawnedGameId then
    return false
  end
  businessId = normalizeBusinessId(businessId)
  fleetVehicleId = normalizeVehicleId(fleetVehicleId)
  spawnedGameId = tonumber(spawnedGameId) or spawnedGameId
  local vehObj = getObjectByID(spawnedGameId)
  if not vehObj then
    return false
  end
  local vehicleRow = getVehicleById(businessId, fleetVehicleId)
  if not vehicleRow then
    return false
  end
  if not spawnedBusinessVehicles[businessId] then
    spawnedBusinessVehicles[businessId] = {}
  end
  spawnedBusinessVehicles[businessId][fleetVehicleId] = spawnedGameId

  local state = ensurePulledOutState(businessId)
  if not findPulledOutVehicleIndex(state, fleetVehicleId) then
    table.insert(state.vehicles, vehicleRow)
  end
  state.activeVehicleId = fleetVehicleId
  state.spotAssignments = state.spotAssignments or {}
  local parkingSpots = getBusinessGarageParkingSpots(businessType, businessId)
  if parkingSpots and #parkingSpots > 0 then
    local pos = vehObj:getPosition()
    local bestIdx, bestDist = nil, math.huge
    for idx, sp in ipairs(parkingSpots) do
      if sp and sp.pos then
        local d = pos:distance(sp.pos)
        if d < bestDist then
          bestDist = d
          bestIdx = idx
        end
      end
    end
    if bestIdx then
      state.spotAssignments[fleetVehicleId] = bestIdx
    end
  end
  return true
end

local function getAvailableParkingSpotIndex(businessType, businessId, state)
  local parkingSpots = getBusinessGarageParkingSpots(businessType, businessId)
  if #parkingSpots == 0 then
    return nil
  end
  local used = {}
  for _, index in pairs(state.spotAssignments or {}) do
    if index then
      used[index] = true
    end
  end
  for idx = 1, #parkingSpots do
    if not used[idx] then
      return idx
    end
  end
  return ((#state.vehicles) % #parkingSpots) + 1
end

local function pullOutVehicle(businessType, businessId, vehicleId)
  if not businessType or not businessId or not vehicleId then
    log('D', 'businessInventory.pullOut', 'abort: missing businessType, businessId, or vehicleId')
    return false
  end

  businessId = normalizeBusinessId(businessId)
  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  if not normalizedVehicleId then
    log('D', 'businessInventory.pullOut',
      string.format('abort: bad vehicleId businessId=%s raw=%s', tostring(businessId), tostring(vehicleId)))
    return false
  end

  local vehicle = getVehicleById(businessId, normalizedVehicleId)
  if not vehicle then
    log('D', 'businessInventory.pullOut',
      string.format('abort: no stored vehicle row businessId=%s vehicleId=%s', tostring(businessId),
        tostring(normalizedVehicleId)))
    return false
  end

  local state = ensurePulledOutState(businessId)
  local existingIndex = findPulledOutVehicleIndex(state, normalizedVehicleId)
  if existingIndex then
    local existingSpawnId = getSpawnedVehicleId(businessId, normalizedVehicleId)
    local existingObj = existingSpawnId and getObjectByID(existingSpawnId) or nil
    if existingObj then
      state.activeVehicleId = normalizedVehicleId
      return true
    end

    -- Ghost lift: bookkeeping says pulled out, but the world object is gone.
    table.remove(state.vehicles, existingIndex)
    if state.spotAssignments then
      state.spotAssignments[normalizedVehicleId] = nil
    end
    if spawnedBusinessVehicles[businessId] then
      spawnedBusinessVehicles[businessId][normalizedVehicleId] = nil
    end
    if state.activeVehicleId == normalizedVehicleId then
      state.activeVehicleId = state.vehicles[1] and normalizeVehicleId(state.vehicles[1].vehicleId) or nil
    end
    if #state.vehicles == 0 then
      pulledOutVehicles[businessId] = nil
      state = ensurePulledOutState(businessId)
    end
  end

  local vehObj = spawnBusinessVehicle(businessId, normalizedVehicleId)
  if not vehObj then
    log('D', 'businessInventory.pullOut',
      string.format('spawnBusinessVehicle failed businessId=%s vehicleId=%s', tostring(businessId),
        tostring(normalizedVehicleId)))
    if spawnedBusinessVehicles[businessId] then
      spawnedBusinessVehicles[businessId][normalizedVehicleId] = nil
    end
    if #state.vehicles == 0 then
      pulledOutVehicles[businessId] = nil
    end
    return false
  end

  state.spotAssignments = state.spotAssignments or {}
  local preferredSpotIndex = getAvailableParkingSpotIndex(businessType, businessId, state)
  local teleportSuccess, actualSpotIndex = teleportToBusinessGarage(businessType, businessId, vehObj, false, preferredSpotIndex)

  if not teleportSuccess then
    log('D', 'businessInventory.pullOut',
      string.format('teleportToBusinessGarage failed businessId=%s vehicleId=%s spotIndex=%s',
        tostring(businessId), tostring(normalizedVehicleId), tostring(preferredSpotIndex)))
    vehObj:delete()
    if spawnedBusinessVehicles[businessId] then
      spawnedBusinessVehicles[businessId][normalizedVehicleId] = nil
    end
    if #state.vehicles == 0 then
      pulledOutVehicles[businessId] = nil
    end
    return false
  end

  table.insert(state.vehicles, vehicle)
  state.activeVehicleId = normalizedVehicleId
  state.spotAssignments[normalizedVehicleId] = actualSpotIndex

  local callbackId = tostring(businessId) .. "_" .. tostring(normalizedVehicleId) .. "_" .. tostring(os.time())
  pendingConfigCallbacks[callbackId] = {
    businessId = businessId,
    vehicleId = normalizedVehicleId
  }

  if not vehicle.config then
    vehObj:queueLuaCommand([[
        local configData = serialize(v.config)
        obj:queueGameEngineLua("career_modules_business_businessInventory.onVehicleConfigReceived(']] .. callbackId ..
                             [[', " .. configData .. ")")
      ]])
  end

  return true
end

-- Delivers a freshly-purchased fleet vehicle by actually spawning it at the
-- garage, then issuing a real power/weight read so race-offer eligibility has
-- authoritative HP+weight from a real spawn. When the garage is at capacity
-- (rare multi-purchase edge case) the vehicle is still spawned for the read
-- and then put away on a short timer so we don't visibly stack cars on a spot.
local function deliverFleetVehicleAtPurchase(businessType, businessId, vehicleId)
  if not businessType or not businessId or vehicleId == nil then
    return false
  end
  businessId = normalizeBusinessId(businessId)
  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  if not businessId or not normalizedVehicleId then
    return false
  end

  local parkingSpots = getBusinessGarageParkingSpots(businessType, businessId)
  local totalSpots = parkingSpots and #parkingSpots or 0
  local usedSpots = 0
  local existingState = pulledOutVehicles[businessId]
  if existingState and type(existingState.spotAssignments) == "table" then
    for _, idx in pairs(existingState.spotAssignments) do
      if idx then usedSpots = usedSpots + 1 end
    end
  end
  local hasFreeSpot = (totalSpots == 0) or (usedSpots < totalSpots)

  if not pullOutVehicle(businessType, businessId, normalizedVehicleId) then
    return false
  end

  local spawnedId = getSpawnedVehicleId(businessId, normalizedVehicleId)
  local vehObj = spawnedId and getObjectByID(spawnedId) or nil
  if not vehObj then
    return true
  end

  local function fireStatsReadAndMaybeStow()
    if career_modules_business_businessPartCustomization
        and career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase then
      career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase(businessId, normalizedVehicleId)
    end
    if not hasFreeSpot and core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job)
        job.sleep(2)
        putAwayVehicle(businessId, normalizedVehicleId)
      end)
    end
  end

  if core_vehicleBridge and core_vehicleBridge.requestValue then
    core_vehicleBridge.requestValue(vehObj, fireStatsReadAndMaybeStow, 'ping')
  else
    fireStatsReadAndMaybeStow()
  end

  return true
end

-- Issues a power/weight read against an already-spawned fleet vehicle (used by
-- the drive-in delivery path where the player drove the car to the garage and
-- it's already a live scene object).
local function requestFleetVehicleStatsRead(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return false
  end
  businessId = normalizeBusinessId(businessId)
  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  if not businessId or not normalizedVehicleId then
    return false
  end
  local spawnedId = getSpawnedVehicleId(businessId, normalizedVehicleId)
  local vehObj = spawnedId and getObjectByID(spawnedId) or nil
  if not vehObj then
    return false
  end
  local function fire()
    if career_modules_business_businessPartCustomization
        and career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase then
      career_modules_business_businessPartCustomization.requestVehiclePowerWeightAfterPurchase(businessId, normalizedVehicleId)
    end
  end
  if core_vehicleBridge and core_vehicleBridge.requestValue then
    core_vehicleBridge.requestValue(vehObj, fire, 'ping')
  else
    fire()
  end
  return true
end

local function persistSpawnedVehiclePartConditions(businessId, normalizedVehicleId, onDone)
  if onDone == nil then
    onDone = function() end
  end
  businessId = normalizeBusinessId(businessId)
  normalizedVehicleId = normalizeVehicleId(normalizedVehicleId)
  if not businessId or not normalizedVehicleId then
    onDone()
    return
  end
  local stored = getVehicleById(businessId, normalizedVehicleId)
  local spawnedId = getSpawnedVehicleId(businessId, normalizedVehicleId)
  local vehObj = spawnedId and getObjectByID(spawnedId)
  if not vehObj or not core_vehicleBridge or not core_vehicleBridge.requestValue then
    onDone()
    return
  end
  core_vehicleBridge.requestValue(vehObj, function(res)
    if stored and res and res.result and type(res.result) == "table" then
      stored.partConditions = deepcopy(res.result)
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        saveBusinessVehicles(businessId, savePath)
      end
    end
    onDone()
  end, 'getPartConditions')
end

putAwayVehicle = function(businessId, vehicleId, onComplete, opts)
  if not businessId then
    if onComplete then
      onComplete(false)
    end
    return false
  end

  local skipPersist = opts and opts.skipPartConditionPersist == true

  local function runComplete(ok)
    if onComplete then
      onComplete(ok ~= false)
    end
  end

  businessId = normalizeBusinessId(businessId)

  local function tryPutAwayOrphanSpawnedFleetForFleetId(normalizedFleetId)
    if not normalizedFleetId or not getSpawnedVehicleId(businessId, normalizedFleetId) then
      return false
    end
    local vehicleRow = getVehicleById(businessId, normalizedFleetId)
    local function finishOrphan()
      if vehicleRow then
        clearCachesForStoredVehicle(businessId, vehicleRow)
      elseif career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessCachesForVehicle then
        pcall(function()
          career_modules_business_businessComputer.clearBusinessCachesForVehicle(businessId, normalizedFleetId)
        end)
      end
      removeBusinessVehicleObject(businessId, vehicleRow and vehicleRow.vehicleId or normalizedFleetId)
      runComplete(true)
    end
    if skipPersist then
      finishOrphan()
    else
      persistSpawnedVehiclePartConditions(businessId, normalizedFleetId, finishOrphan)
    end
    return true
  end

  if not vehicleId then
    local state = pulledOutVehicles[businessId]
    if not state or not state.vehicles then
      pulledOutVehicles[businessId] = nil
      runComplete(true)
      return true
    end
    local list = {}
    for _, vehicle in ipairs(state.vehicles) do
      table.insert(list, vehicle)
    end
    if #list == 0 then
      pulledOutVehicles[businessId] = nil
      runComplete(true)
      return true
    end
    if skipPersist then
      for _, vehicle in ipairs(list) do
        clearCachesForStoredVehicle(businessId, vehicle)
        removeBusinessVehicleObject(businessId, vehicle.vehicleId)
      end
      pulledOutVehicles[businessId] = nil
      runComplete(true)
      return true
    end
    local idx = 1
    local function chainPersistAll()
      if idx > #list then
        for _, vehicle in ipairs(list) do
          clearCachesForStoredVehicle(businessId, vehicle)
          removeBusinessVehicleObject(businessId, vehicle.vehicleId)
        end
        pulledOutVehicles[businessId] = nil
        runComplete(true)
        return
      end
      local vehicle = list[idx]
      local vid = normalizeVehicleId(vehicle.vehicleId)
      idx = idx + 1
      persistSpawnedVehiclePartConditions(businessId, vid, chainPersistAll)
    end
    chainPersistAll()
    return true
  end

  local normalizedVehicleId = normalizeVehicleId(vehicleId)
  if not normalizedVehicleId then
    runComplete(false)
    return false
  end

  local state = pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    pulledOutVehicles[businessId] = nil
    if tryPutAwayOrphanSpawnedFleetForFleetId(normalizedVehicleId) then
      return true
    end
    runComplete(true)
    return true
  end

  local index = findPulledOutVehicleIndex(state, normalizedVehicleId)
  if not index then
    if tryPutAwayOrphanSpawnedFleetForFleetId(normalizedVehicleId) then
      return true
    end
    runComplete(false)
    return false
  end

  local vehicle = state.vehicles[index]
  local spawnedId = getSpawnedVehicleId(businessId, normalizedVehicleId)
  local liveObj = spawnedId and getObjectByID(spawnedId) or nil
  -- Missing world object: clear ghost lift state without trying to read part conditions.
  if not liveObj then
    skipPersist = true
  end

  local function afterPersistOrSkip()
    clearCachesForStoredVehicle(businessId, vehicle)
    removeBusinessVehicleObject(businessId, vehicle.vehicleId)
    table.remove(state.vehicles, index)
    if state.spotAssignments then
      state.spotAssignments[normalizedVehicleId] = nil
    end
    if state.activeVehicleId == normalizedVehicleId then
      state.activeVehicleId = state.vehicles[1] and normalizeVehicleId(state.vehicles[1].vehicleId) or nil
    end
    if #state.vehicles == 0 then
      pulledOutVehicles[businessId] = nil
    end
    runComplete(true)
  end

  if skipPersist then
    afterPersistOrSkip()
    return true
  end

  persistSpawnedVehiclePartConditions(businessId, normalizedVehicleId, afterPersistOrSkip)

  return true
end

-- Re-spawn a pulled-out fleet vehicle when replaceVehicle left a ghost / dead object.
local function emergencyRespawnPulledOutVehicle(businessType, businessId, vehicleId, restoreConfig, partConditions)
  if not businessId or vehicleId == nil then
    return nil
  end

  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId

  local vehicle = getVehicleById(businessId, vehicleId)
  if not vehicle then
    return nil
  end

  removeBusinessVehicleObject(businessId, vehicleId)

  if restoreConfig then
    vehicle.config = deepcopy(restoreConfig)
  end
  if partConditions then
    vehicle.partConditions = deepcopy(partConditions)
  end

  local vehObj = spawnBusinessVehicle(businessId, vehicleId)
  if not vehObj then
    log('E', 'businessInventory.emergencyRespawn',
      string.format('spawn failed businessId=%s vehicleId=%s', tostring(businessId), tostring(vehicleId)))
    return nil
  end

  if businessType then
    local state = pulledOutVehicles[businessId]
    local preferredSpotIndex = state and state.spotAssignments and state.spotAssignments[vehicleId] or nil
    teleportToBusinessGarage(businessType, businessId, vehObj, false, preferredSpotIndex)
  end

  log('I', 'businessInventory.emergencyRespawn',
    string.format('respawned businessId=%s vehicleId=%s', tostring(businessId), tostring(vehicleId)))
  return vehObj
end

local function teleportSpawnedBusinessVehicleToSpot(businessId, vehicleId, spot)
  if not businessId or not vehicleId or not spot or not spot.pos or not spot.rot then
    return false
  end
  businessId = normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local sid = getSpawnedVehicleId(businessId, vehicleId)
  local vehObj = sid and getObjectByID(sid)
  if not vehObj then
    vehObj = spawnBusinessVehicle(businessId, vehicleId)
  end
  if not vehObj then
    return false
  end
  local pos = spot.pos
  local r = spot.rot
  local q = quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
  teleportVehicleExact(vehObj, vec3(pos[1], pos[2], pos[3]), q, true, true)
  if core_camera and core_camera.resetCamera then
    core_camera.resetCamera(0)
  end
  return true
end

local function getBusinessVehicleIdentifier(businessId, vehicleId)
  return "business_" .. tostring(businessId) .. "_" .. tostring(vehicleId)
end

local function getBusinessJobIdentifier(businessId, jobId)
  return "business_" .. tostring(businessId) .. "_job_" .. tostring(jobId)
end

local function getJobIdFromVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = getVehicleById(businessId, vehicleId)
  if vehicle and vehicle.jobId then
    return vehicle.jobId
  end
  return nil
end

local function getInventoryVehicleIdForJobId(businessId, jobId)
  if not businessId or not jobId then
    return nil
  end
  local want = tonumber(jobId) or jobId
  local vehicles = getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    if v.jobId ~= nil then
      local vj = tonumber(v.jobId) or v.jobId
      if vj == want or tostring(v.jobId) == tostring(jobId) then
        return tonumber(v.vehicleId) or v.vehicleId
      end
    end
  end
  return nil
end

local function tryResolveBusinessVehicleFromCareerInventory(spawnedVehicleId)
  if not spawnedVehicleId then
    return nil, nil
  end
  if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
    return nil, nil
  end
  local invId = career_modules_inventory.getInventoryIdFromVehicleId(spawnedVehicleId)
  if not invId or type(invId) ~= "string" or invId:sub(1, 9) ~= "business_" then
    return nil, nil
  end

  local rest = invId:sub(10)
  local bizId, fleetVid

  if rest:find("_job_", 1, true) then
    local jb, jj = rest:match("^(.+)_job_(.+)$")
    if jb and jj then
      jb = normalizeBusinessId(jb)
      local wantJob = tonumber(jj) or jj
      for _, v in ipairs(getBusinessVehicles(jb)) do
        if v.jobId ~= nil then
          local vj = tonumber(v.jobId) or v.jobId
          if vj == wantJob then
            bizId = jb
            fleetVid = tonumber(v.vehicleId) or v.vehicleId
            break
          end
        end
      end
    end
  else
    local underscorePos
    for i = #rest, 1, -1 do
      if rest:sub(i, i) == "_" then
        local tail = rest:sub(i + 1)
        if tail:match("^%d+$") then
          underscorePos = i
          break
        end
      end
    end
    if underscorePos then
      local candBiz = normalizeBusinessId(rest:sub(1, underscorePos - 1))
      local candVid = tonumber(rest:sub(underscorePos + 1))
      if candBiz and candVid and getVehicleById(candBiz, candVid) then
        bizId, fleetVid = candBiz, candVid
      end
    end
  end

  if not bizId or not fleetVid then
    return nil, nil
  end

  if not spawnedBusinessVehicles[bizId] then
    spawnedBusinessVehicles[bizId] = {}
  end
  spawnedBusinessVehicles[bizId][fleetVid] = spawnedVehicleId
  return bizId, fleetVid
end

local function getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if not spawnedVehicleId then
    return nil, nil
  end

  for businessId, vehicles in pairs(spawnedBusinessVehicles) do
    for vehicleId, spawnedId in pairs(vehicles) do
      if spawnedId == spawnedVehicleId then
        return businessId, vehicleId
      end
    end
  end

  return tryResolveBusinessVehicleFromCareerInventory(spawnedVehicleId)
end

local function resolveFreeroamLeaderboardInventoryId(spawnedVehicleId)
  if not spawnedVehicleId then
    return spawnedVehicleId
  end
  local businessId, vehicleId = getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if businessId and vehicleId then
    return getBusinessVehicleIdentifier(businessId, vehicleId)
  end
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    return career_modules_inventory.getInventoryIdFromVehicleId(spawnedVehicleId) or spawnedVehicleId
  end
  return spawnedVehicleId
end

local function onCareerActivated()
  businessVehicles = {}
  pulledOutVehicles = {}
  spawnedBusinessVehicles = {}
  vehicleIdCounters = {}
end

local function onSaveCurrentProfile(currentSavePath)
  for businessId, _ in pairs(businessVehicles) do
    saveBusinessVehicles(businessId, currentSavePath)
  end
end

local function updateVehicle(businessId, vehicleId, vehicleData)
  if not businessId or not vehicleId or not vehicleData then
    return false
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = loadBusinessVehicles(businessId)

  for i, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      for key, value in pairs(vehicleData) do
        vehicle[key] = value
      end
      businessVehicles[businessId] = vehicles
      return true
    end
  end

  return false
end

local function onVehicleConfigReceived(callbackId, config)
  local callbackData = pendingConfigCallbacks[callbackId]
  if not callbackData then
    return
  end

  pendingConfigCallbacks[callbackId] = nil

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId

  if not config then
    return
  end

  updateVehicle(businessId, vehicleId, {
    config = config,
    vars = config.vars
  })
end

M.onCareerActivated = onCareerActivated
M.getBusinessVehicles = getBusinessVehicles
M.clearBusinessInventory = clearBusinessInventory
M.storeVehicle = storeVehicle
M.removeVehicle = removeVehicle
M.getVehicleById = getVehicleById
M.updateVehicle = updateVehicle
M.pullOutVehicle = pullOutVehicle
M.putAwayVehicle = putAwayVehicle
M.persistSpawnedFleetVehiclePartConditions = persistSpawnedVehiclePartConditions
M.getPulledOutVehicle = getPulledOutVehicle
M.getPulledOutVehicles = getPulledOutVehicles
M.getActiveVehicle = getActiveVehicle
M.setActiveVehicle = setActiveVehicle
M.getBusinessGarage = getBusinessGarage
M.getBusinessGarageParkingSpots = getBusinessGarageParkingSpots
M.getBusinessGaragePosRot = getBusinessGaragePosRot
M.spawnBusinessVehicle = spawnBusinessVehicle
M.saveBusinessVehicles = saveBusinessVehicles
M.teleportToBusinessGarage = teleportToBusinessGarage
M.removeBusinessVehicleObject = removeBusinessVehicleObject
M.registerFleetVehicleDeliveredDriveIn = registerFleetVehicleDeliveredDriveIn
M.deliverFleetVehicleAtPurchase = deliverFleetVehicleAtPurchase
M.requestFleetVehicleStatsRead = requestFleetVehicleStatsRead
M.getSpawnedVehicleId = getSpawnedVehicleId
M.emergencyRespawnPulledOutVehicle = emergencyRespawnPulledOutVehicle
M.teleportSpawnedBusinessVehicleToSpot = teleportSpawnedBusinessVehicleToSpot
M.repairSpawnedBusinessVehicle = repairSpawnedBusinessVehicle
M.getBusinessVehicleIdentifier = getBusinessVehicleIdentifier
M.getBusinessJobIdentifier = getBusinessJobIdentifier
M.getJobIdFromVehicle = getJobIdFromVehicle
M.getInventoryVehicleIdForJobId = getInventoryVehicleIdForJobId
M.getBusinessVehicleFromSpawnedId = getBusinessVehicleFromSpawnedId
M.resolveFreeroamLeaderboardInventoryId = resolveFreeroamLeaderboardInventoryId
M.onVehicleConfigReceived = onVehicleConfigReceived
M.onSaveCurrentProfile = onSaveCurrentProfile
M.primeFleetRepairSnapshots = primeFleetRepairSnapshots

return M
